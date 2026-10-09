// ============================================================================
//  Bottom-x 白条点击返回 (HomeTapBackSwipe)  Tweak.xm  —— v0.5.0
// ----------------------------------------------------------------------------
//  SpringBoard 层：
//    - 保留原版"点击底部白条 = 返回上一级"的核心工作方式。
//    - 把可点击的"白条区域"加宽（默认覆盖屏幕底部中央 70%），
//      并在设置里提供两个可调项：
//        ① 点击区域宽度 (TapAreaWidth)   —— 白条可点击区域有多宽
//        ② 反应速度 (TapSensitivity)     —— 多快算一次"点击"（区分点击/上滑）
//    - 检测到加宽区域的白条单击后：
//        ① 发 com.doubao.swipeback.back → App 层(SwipeBackApp) 执行返回上一级（可靠）
//        ② 发 com.hometapback.hometap   → 原版 HomeTapBackApp 兜底
//    - 到 App 最上级再点：App 层发回桌面请求，本层用最可靠方式返回桌面。
//    - 上滑中间=后台 / 上滑到顶=回桌面 由系统处理，本层不拦截滑动。
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
static NSString *const kMasterEnabled   = @"MasterEnabled";
static NSString *const kTapAreaWidth    = @"TapAreaWidth";     // 点击区域宽度 (0~1)
static NSString *const kTapSensitivity  = @"TapSensitivity";   // 反应速度 (0~1)

static NSString *const kNotifyHomeTap = @"com.hometapback.hometap";
static NSString *const kNotifyGoHome  = @"com.hometapback.gohome";

static BOOL    g_enabled    = NO;
static CGFloat g_areaWidth  = 0.70f;
static CGFloat g_sens       = 0.60f;

static CGFloat bx_lerp(CGFloat a, CGFloat b, CGFloat t) {
    if (t < 0) t = 0; if (t > 1) t = 1;
    return a + (b - a) * t;
}

static void bx_loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.colorblack.bottomx"];
    [d synchronize];
    g_enabled   = [d boolForKey:kMasterEnabled];
    g_areaWidth = [d floatForKey:kTapAreaWidth];
    if (g_areaWidth < 0.1f) g_areaWidth = 0.70f;   // 默认加宽到 70%
    g_sens      = [d floatForKey:kTapSensitivity];
    if (g_sens < 0.01f) g_sens = 0.60f;
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

// 前台 App / 锁屏 判断
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

// 点击点是否在"加宽的白条区域"（屏幕底部，横向从中央向两侧展开 areaWidth 比例）
static BOOL bx_inTapArea(CGPoint start) {
    if (!g_enabled) return NO;
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat cover = bx_lerp(0.30f, 1.00f, g_areaWidth);   // 横向覆盖率：窄30% ~ 全宽100%，默认70%
    CGFloat zoneH = bx_lerp(80.f, 220.f, g_areaWidth);    // 底部高度 pt（点击生效区）
    if (start.y < b.size.height - zoneH) return NO;
    CGFloat half = b.size.width * cover / 2.0;
    return fabs(start.x - b.size.width / 2.0) <= half;
}

// 发"返回上一级"通知给 App 层
static void bx_sendBackNotify(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.doubao.swipeback.back"), NULL, NULL, true);
}
// 兜底：发原版 hometap 通知（HomeTapBackApp 执行返回）
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

// 返回桌面（App 最上级再点）：按最可靠方式依次尝试
static void bx_goHome(void) {
    bx_log(@"[HomeTapBackSwipe] ACTION go-home");
    @try {
        Class disp = NSClassFromString(@"BXHomeDispatcher");
        id d = bx_sharedInstanceForClass(disp);
        if (!d && disp) d = [[disp alloc] init];
        SEL dgh = NSSelectorFromString(@"dispatchGoHome");
        if (d && [d respondsToSelector:dgh]) {
            ((void (*)(id, SEL))[d methodForSelector:dgh])(d, dgh);
            bx_log(@"[HomeTapBackSwipe] go-home via BXHomeDispatcher");
            return;
        }
    } @catch (...) {}
    @try {
        Class w = NSClassFromString(@"SBMainWorkspace");
        id ws = bx_sharedInstanceForClass(w);
        SEL t = NSSelectorFromString(@"transitionToHomeScreenWithCompletion:");
        if (ws && [ws respondsToSelector:t]) {
            ((void (*)(id, SEL, id))[ws methodForSelector:t])(ws, t, nil);
            bx_log(@"[HomeTapBackSwipe] go-home via transitionToHomeScreen");
            return;
        }
    } @catch (...) {}
    @try {
        Class sbui = NSClassFromString(@"SBUIController");
        id c = bx_sharedInstanceForClass(sbui);
        SEL m = NSSelectorFromString(@"handleMenuButtonTap");
        if (c && [c respondsToSelector:m]) {
            ((void (*)(id, SEL))[c methodForSelector:m])(c, m);
            bx_log(@"[HomeTapBackSwipe] go-home via handleMenuButtonTap");
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
                bx_log(@"[HomeTapBackSwipe] go-home via %@", sn);
                return;
            }
        }
    } @catch (...) {}
    @try {
        notify_post([kNotifyGoHome UTF8String]);
        notify_post("com.colorblack.bottomx.gohome");
        bx_log(@"[HomeTapBackSwipe] go-home via notify");
    } @catch (...) {}
}

#pragma mark - 钩子：加宽白条区域的白条单击返回
%hook SBHomeGesturePanGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    UIGestureRecognizer *gr = (UIGestureRecognizer *)self;
    UITouch *t = touches.anyObject;
    if (t && gr.view) {
        CGPoint p = [t locationInView:gr.view];
        objc_setAssociatedObject(self, @selector(bxTapStart),
                                 [NSValue valueWithCGPoint:p], OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(self, @selector(bxTapStartT),
                                 [NSDate date], OBJC_ASSOCIATION_RETAIN);
    }
    objc_setAssociatedObject(self, @selector(bxTapHandled), @(NO), OBJC_ASSOCIATION_RETAIN);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    // 桌面/锁屏 或 未启用：完全放行
    if (!bx_hasForegroundApp() || bx_isLocked()) return;
    if (!g_enabled) return;
    NSNumber *handled = objc_getAssociatedObject(self, @selector(bxTapHandled));
    if (handled.boolValue) return;

    UIGestureRecognizer *gr = (UIGestureRecognizer *)self;
    UITouch *t = touches.anyObject;
    NSValue *sv = objc_getAssociatedObject(self, @selector(bxTapStart));
    NSDate *t0  = objc_getAssociatedObject(self, @selector(bxTapStartT));
    if (!sv || !t0) return;
    CGPoint start = sv.CGPointValue;
    if (start.x < 0) return;
    CGPoint cur = (t && gr.view) ? [t locationInView:gr.view] : start;

    // 反应速度（灵敏度）控制"点击"判定：
    //   灵敏度高 → 位移阈值小、时间阈值短（快速轻点即触发）
    //   灵敏度低 → 位移阈值大、时间阈值长（需要明确的点按）
    CGFloat maxMove = bx_lerp(40.f, 7.f, g_sens);     // 最大位移 pt
    CGFloat maxDur  = bx_lerp(1.4f, 0.35f, g_sens);   // 最大时长 s
    CGFloat dx = cur.x - start.x, dy = cur.y - start.y;
    CGFloat dist = sqrt(dx * dx + dy * dy);
    NSTimeInterval dur = [[NSDate date] timeIntervalSinceDate:t0];

    if (dist <= maxMove && dur <= maxDur && bx_inTapArea(start)) {
        objc_setAssociatedObject(self, @selector(bxTapHandled), @(YES), OBJC_ASSOCIATION_RETAIN);
        bx_sendBackNotify();            // App 层执行返回上一级（可靠）
        bx_sendOriginalBackNotify();    // 原版 HomeTapBackApp 兜底
        bx_log(@"[HomeTapBackSwipe] white-bar tap -> back (areaWidth=%.2f sens=%.2f dist=%.1f dur=%.2f)",
               g_areaWidth, g_sens, dist, dur);
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    objc_setAssociatedObject(self, @selector(bxTapHandled), @(NO), OBJC_ASSOCIATION_RETAIN);
    %orig;
}
%end

// 收到 App 层"已到最上级、请回桌面"通知 -> 执行返回桌面
static void bxOnGoHomeNotify(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    bx_log(@"[HomeTapBackSwipe] got go-home notify from App layer");
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
        bx_log(@"[HomeTapBackSwipe] LOADED into SpringBoard, enabled=%d areaWidth=%.2f sens=%.2f",
               g_enabled, g_areaWidth, g_sens);
    } @catch (...) {}

    // 监听回桌面请求（我的通知 + 原版通知双保险）
    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(nc, NULL, bxOnGoHomeNotify, CFSTR("com.doubao.swipeback.gohome"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(nc, NULL, bxOnGoHomeNotify, CFSTR("com.hometapback.gohome"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    @try {
        NSString *marker = [NSString stringWithFormat:@"%@ pid=%d\n", [NSDate date], (int)getpid()];
        [marker writeToFile:@"/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
        [marker writeToFile:@"/var/jb/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}
}
