// ============================================================================
//  Bottom-x 左右滑动返回 (HomeTapBackSwipe)  Tweak.xm  —— v0.4.3
// ----------------------------------------------------------------------------
//  SpringBoard 层（系统级，注入一定成功）：
//    - 在屏幕底部左右角检测"横向滑动"（左角向右滑 / 右角向左滑），
//      触发后发 back 通知，由 App 层(SwipeBackApp)执行返回上一级。
//    - 到 App 最上级：App 层会发回桌面请求，本层用最可靠方式返回桌面
//      （复用原版 dispatchGoHome / 系统正规回主屏）。
//    - 上滑中间=后台、上滑到顶=回桌面 仍由系统处理，不拦截。
// ============================================================================

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <os/log.h>

static void bx_log(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    os_log(OS_LOG_DEFAULT, "%{public}@", msg);
}

#pragma mark - 设置键
static NSString *const kSwipeBackEnabled        = @"SwipeBackEnabled";
static NSString *const kSwipeBackArea           = @"SwipeBackArea";
static NSString *const kSwipeBackBackSens       = @"SwipeBackBackSensitivity";
static NSString *const kSwipeBackHomeSens       = @"SwipeBackHomeSensitivity";

static NSString *const kNotifyHomeTap = @"com.hometapback.hometap";
static NSString *const kNotifyGoHome  = @"com.hometapback.gohome";

typedef NS_ENUM(NSInteger, BXSwipeArea) { BXSwipeAreaLeft=0, BXSwipeAreaRight=1, BXSwipeAreaBoth=2 };

static BOOL        g_enabled  = NO;
static BXSwipeArea g_area     = BXSwipeAreaBoth;
static CGFloat     g_backSens = 0.6f;
static CGFloat     g_homeSens = 0.6f;

static CGFloat bx_lerp(CGFloat a, CGFloat b, CGFloat t) {
    if (t < 0) t = 0; if (t > 1) t = 1;
    return a + (b - a) * t;
}

static void bx_loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.colorblack.bottomx"];
    [d synchronize];
    g_enabled = [d boolForKey:kSwipeBackEnabled];
    NSString *area = [d stringForKey:kSwipeBackArea] ?: @"Both";
    if      ([area isEqualToString:@"Left"])  g_area = BXSwipeAreaLeft;
    else if ([area isEqualToString:@"Right"]) g_area = BXSwipeAreaRight;
    else                                      g_area = BXSwipeAreaBoth;
    g_backSens = bx_lerp(0, 1, [d floatForKey:kSwipeBackBackSens]);
    if (g_backSens <= 0) g_backSens = 0.6f;
    g_homeSens = bx_lerp(0, 1, [d floatForKey:kSwipeBackHomeSens]);
    if (g_homeSens <= 0) g_homeSens = 0.6f;
}

static id bx_sharedInstanceForClass(Class cls) {
    if (!cls) return nil;
    NSArray<NSString *> *sels = @[@"shared", @"sharedInstance", @"sharedManager",
                                  @"sharedController", @"current", @"instance"];
    for (NSString *s in sels) {
        SEL sel = NSSelectorFromString(s);
        if (![cls respondsToSelector:sel]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id obj = [cls performSelector:sel];
#pragma clang diagnostic pop
        if (obj) return obj;
    }
    return nil;
}

// 前台 App 判断 / 锁屏判断
static BOOL bx_isLocked(void) {
    Class lm = NSClassFromString(@"SBLockScreenManager");
    id inst = bx_sharedInstanceForClass(lm);
    if (inst) {
        if ([inst respondsToSelector:@selector(isUILocked)])
            return ((BOOL (*)(id, SEL))objc_msgSend)(inst, @selector(isUILocked));
        if ([inst respondsToSelector:@selector(isLocked)])
            return ((BOOL (*)(id, SEL))objc_msgSend)(inst, @selector(isLocked));
    }
    return NO;
}
static BOOL bx_hasForegroundApp(void) {
    @try {
        id app = [[UIApplication sharedApplication] valueForKey:@"frontMostApplication"];
        return app != nil;
    } @catch (NSException *e) { return YES; }
}

// 起点是否在底部左右角（横向滑动触发区）
static BOOL bx_inCorner(CGPoint start) {
    if (!g_enabled) return NO;
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat zoneW = bx_lerp(0.10f, 0.25f, g_backSens);   // 角宽度（灵敏度）
    CGFloat zoneH = bx_lerp(90.f, 170.f, g_backSens);    // 底部高度 pt（灵敏度）
    BOOL inBottom = start.y >= b.size.height - zoneH;
    BOOL inLeft   = inBottom && start.x <= b.size.width * zoneW;
    BOOL inRight  = inBottom && start.x >= b.size.width * (1.0f - zoneW);
    return (g_area == BXSwipeAreaBoth)  ? (inLeft || inRight)
         : (g_area == BXSwipeAreaLeft)  ? inLeft
                                        : inRight;
}

// 吞掉手势（避免系统把横向滑动当别的）
static void bx_swallowGesture(UIGestureRecognizer *gr) {
    if (!gr) return;
    @try {
        [gr setValue:@(UIGestureRecognizerStateFailed) forKey:@"state"];
    } @catch (NSException *e) {}
}

// 发"返回上一级"通知（App 层执行返回）
static void bx_sendBackNotify(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.doubao.swipeback.back"), NULL, NULL, true);
}
// 兜底：发原版 hometap 通知
static void bx_sendOriginalBackNotify(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"point"]    = @{ @"x": @0.0, @"y": @0.0 };
    info[@"bundle"]   = @"";
    info[@"senderID"] = @((uint64_t)(((uint64_t)arc4random() << 32) | arc4random()));
    info[@"tapID"]    = @((uint64_t)(((uint64_t)arc4random() << 32) | arc4random()));
    info[@"sequence"] = @1;
    info[@"stamp"]    = @((uint64_t)([NSProcessInfo processInfo].systemUptime * 1000.0));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kNotifyHomeTap, NULL,
                                         (__bridge CFDictionaryRef)info, true);
}

// 返回桌面（App 最上级再滑动时）：按最可靠方式依次尝试
static void bx_goHome(void) {
    bx_log(@"[SwipeBack] ACTION go-home");
    @try {
        Class disp = NSClassFromString(@"BXHomeDispatcher");
        id d = bx_sharedInstanceForClass(disp);
        if (!d && disp) d = [[disp alloc] init];
        SEL dgh = NSSelectorFromString(@"dispatchGoHome");
        if (d && [d respondsToSelector:dgh]) {
            ((void (*)(id, SEL))[d methodForSelector:dgh])(d, dgh);
            bx_log(@"[SwipeBack] go-home via BXHomeDispatcher");
            return;
        }
    } @catch (...) {}
    @try {
        Class w = NSClassFromString(@"SBMainWorkspace");
        id ws = bx_sharedInstanceForClass(w);
        SEL t = NSSelectorFromString(@"transitionToHomeScreenWithCompletion:");
        if (ws && [ws respondsToSelector:t]) {
            ((void (*)(id, SEL, id))[ws methodForSelector:t])(ws, t, nil);
            bx_log(@"[SwipeBack] go-home via SBMainWorkspace.transitionToHomeScreen");
            return;
        }
    } @catch (...) {}
    @try {
        Class sbui = NSClassFromString(@"SBUIController");
        id c = bx_sharedInstanceForClass(sbui);
        SEL m = NSSelectorFromString(@"handleMenuButtonTap");
        if (c && [c respondsToSelector:m]) {
            ((void (*)(id, SEL))[c methodForSelector:m])(c, m);
            bx_log(@"[SwipeBack] go-home via handleMenuButtonTap");
            return;
        }
    } @catch (...) {}
    @try {
        Class sbui = NSClassFromString(@"SBUIController");
        id c = bx_sharedInstanceForClass(sbui);
        for (NSString *sn in @[@"handleHomeButtonSinglePressUp", @"_handleHomeButtonSinglePressUp"]) {
            SEL s = NSSelectorFromString(sn);
            if (c && [c respondsToSelector:s]) {
                ((void (*)(id, SEL))[c methodForSelector:s])(c, s);
                bx_log(@"[SwipeBack] go-home via %@", sn);
                return;
            }
        }
    } @catch (...) {}
    @try {
        notify_post([kNotifyGoHome UTF8String]);
        notify_post("com.colorblack.bottomx.gohome");
        bx_log(@"[SwipeBack] go-home via notify");
    } @catch (...) {}
}

#pragma mark - 钩子：检测底部左右角横向滑动
%hook SBHomeGesturePanGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    UIPanGestureRecognizer *gr = (UIPanGestureRecognizer *)self;
    UITouch *t = touches.anyObject;
    if (t && gr.view) {
        CGPoint p = [t locationInView:gr.view];
        objc_setAssociatedObject(self, @selector(bxSwipeStart),
                                 [NSValue valueWithCGPoint:p], OBJC_ASSOCIATION_RETAIN);
    }
    objc_setAssociatedObject(self, @selector(bxSwipeHandled), @(NO), OBJC_ASSOCIATION_RETAIN);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    // 桌面/锁屏 或 未启用：不处理，完全放行系统
    if (!bx_hasForegroundApp() || bx_isLocked()) return;
    if (!g_enabled) return;
    NSNumber *handled = objc_getAssociatedObject(self, @selector(bxSwipeHandled));
    if (handled.boolValue) return;
    NSValue *sv = objc_getAssociatedObject(self, @selector(bxSwipeStart));
    CGPoint start = sv ? sv.CGPointValue : CGPointMake(-1.f, -1.f);
    if (start.x < 0) return;
    if (!bx_inCorner(start)) return;

    UIGestureRecognizer *gr = (UIGestureRecognizer *)self;
    UITouch *t = touches.anyObject;
    CGPoint cur = (t && gr.view) ? [t locationInView:gr.view] : start;
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat zoneW = bx_lerp(0.10f, 0.25f, g_backSens);
    BOOL inLeft  = start.x <= b.size.width * zoneW;
    BOOL inRight = start.x >= b.size.width * (1.0f - zoneW);
    CGFloat dx = cur.x - start.x;
    CGFloat thresh = bx_lerp(42.f, 14.f, g_backSens);   // 横向位移阈值（灵敏度高→滑一点就触发）
    BOOL dirOK = (inLeft && dx > thresh) || (inRight && dx < -thresh);
    if (dirOK) {
        objc_setAssociatedObject(self, @selector(bxSwipeHandled), @(YES), OBJC_ASSOCIATION_RETAIN);
        bx_swallowGesture(gr);          // 取消系统手势，避免被当后台/其他
        bx_sendBackNotify();            // 通知 App 层执行返回；最上级则自动回桌面
        bx_sendOriginalBackNotify();    // 兼容原版 HomeTapBackApp
        bx_log(@"[SwipeBack] horizontal swipe -> back (left=%d dir=%s)",
               inLeft, (inLeft ? "right" : "left"));
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    objc_setAssociatedObject(self, @selector(bxSwipeHandled), @(NO), OBJC_ASSOCIATION_RETAIN);
    %orig;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    objc_setAssociatedObject(self, @selector(bxSwipeHandled), @(NO), OBJC_ASSOCIATION_RETAIN);
    %orig;
}
%end

// 收到 App 层"已到最上级、请回桌面"通知 -> 执行返回桌面
static void bxOnGoHomeNotify(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    bx_log(@"[SwipeBack] got go-home notify from App layer");
    @try {
        NSString *marker = [NSString stringWithFormat:@"%@ SB got gohome\n", [NSDate date]];
        [marker writeToFile:@"/var/mobile/swipeback_gohome_got.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}
    dispatch_async(dispatch_get_main_queue(), ^{ bx_goHome(); });
}

#pragma mark - 构造
%ctor {
    @try {
        bx_loadPrefs();
        bx_log(@"[SwipeBack] LOADED into SpringBoard, enabled=%d area=%ld backSens=%.2f",
               g_enabled, (long)g_area, g_backSens);
    } @catch (...) {}

    // 监听回桌面请求（我的通知 + 原版通知双保险）
    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, bxOnGoHomeNotify, CFSTR("com.doubao.swipeback.gohome"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, bxOnGoHomeNotify, CFSTR("com.hometapback.gohome"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, bxOnGoHomeNotify, CFSTR("com.colorblack.bottomx.hometap.ack"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    @try {
        NSString *marker = [NSString stringWithFormat:@"%@ pid=%d\n", [NSDate date], (int)getpid()];
        [marker writeToFile:@"/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
        [marker writeToFile:@"/var/jb/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}
}
