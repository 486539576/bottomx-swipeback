// ============================================================================
//  Bottom-x 上滑返回 (HomeTapBackSwipe)  Tweak.xm  —— v0.2.97
// ----------------------------------------------------------------------------
//  修复"角落上滑返回上一级不生效"：
//    之前自创的返回通知(App 不认随机 senderID)，现改为直接触发原版
//    BarYHomeTapBackSB 的返回链路(handleHomeButtonSinglePressUp)，让前台 App
//    用"可返回数据"真正执行返回上一级。
//  拦截提前到 touchesMoved：手指一上滑就吞掉系统手势，App 不被带动。
//  新增三个独立灵敏度：
//    角落返回灵敏度   SwipeBackBackSensitivity    角落大小/上滑位移阈值
//    中间后台灵敏度   SwipeBackMiddleSensitivity  上滑到多高算触发后台
//    回桌面灵敏度     SwipeBackHomeSensitivity    二次上滑回桌面的位移阈值
// ============================================================================

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
static NSString *const kSwipeBackMiddleSens     = @"SwipeBackMiddleSensitivity";
static NSString *const kSwipeBackHomeSens       = @"SwipeBackHomeSensitivity";
static NSString *const kSwipeBackHomeConfirm    = @"SwipeBackHomeConfirm";
static NSString *const kSwipeBackMiddleSwitcher = @"SwipeBackMiddleSwitcher";

static NSString *const kNotifyHomeTap = @"com.hometapback.hometap";
static NSString *const kNotifyGoHome  = @"com.hometapback.gohome";

typedef NS_ENUM(NSInteger, BXSwipeArea) { BXSwipeAreaLeft=0, BXSwipeAreaRight=1, BXSwipeAreaBoth=2 };

static BOOL        g_enabled        = NO;
static BXSwipeArea g_area           = BXSwipeAreaBoth;
static CGFloat     g_backSens       = 0.6f;
static CGFloat     g_midSens        = 0.6f;
static CGFloat     g_homeSens       = 0.6f;
static BOOL        g_homeConfirm    = YES;
static BOOL        g_middleSwitcher = YES;

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
    g_backSens  = bx_lerp(0, 1, [d floatForKey:kSwipeBackBackSens]);
    g_midSens   = bx_lerp(0, 1, [d floatForKey:kSwipeBackMiddleSens]);
    g_homeSens  = bx_lerp(0, 1, [d floatForKey:kSwipeBackHomeSens]);
    // 兼容旧单一"灵敏度"键
    if ([d objectForKey:@"SwipeBackSensitivity"] && ![d objectForKey:kSwipeBackBackSens]) {
        g_backSens = bx_lerp(0, 1, [d floatForKey:@"SwipeBackSensitivity"]);
    }
    g_homeConfirm    = [d boolForKey:kSwipeBackHomeConfirm];
    g_middleSwitcher = [d boolForKey:kSwipeBackMiddleSwitcher];
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

// 核心：角落上滑时发"返回上一级"通知，由 App 层(SwipeBackApp)在主线程执行返回
// （不再依赖原版 HomeTapBackApp 的 senderID 校验，改用自己的 App 层返回链路）
static void bx_sendBackNotify(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.doubao.swipeback.back"), NULL, NULL, true);
    bx_log(@"[SwipeBack] back-notify posted com.doubao.swipeback.back");
}

// 兜底：同时发原版 hometap 通知（兼容原版 HomeTapBackApp，若它能处理）
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
    bx_log(@"[SwipeBack] original back-notify posted -> %@", kNotifyHomeTap);
}

// 返回桌面（App 最上级再上滑时的终点）：按最可靠方式依次尝试，确保至少一个生效
static void bx_goHome(void) {
    bx_log(@"[SwipeBack] ACTION go-home");
    // 1) 原版 BXHomeDispatcher.dispatchGoHome（最贴近原插件回桌面）
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
    // 2) SBMainWorkspace.transitionToHomeScreenWithCompletion:（iOS 正规回主屏）
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
    // 3) SBUIController.handleMenuButtonTap（Home 键 tap）
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
    // 4) 系统 Home 键单按派发
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
    // 5) 发原版 gohome 通知 + 系统 home 通知兜底
    @try {
        notify_post([kNotifyGoHome UTF8String]);
        notify_post("com.colorblack.bottomx.gohome");
        bx_log(@"[SwipeBack] go-home via notify");
    } @catch (...) {}
}

// 触发后台 (App Switcher)
static void bx_triggerAppSwitcher(void) {
    bx_log(@"[SwipeBack] ACTION app-switcher (上滑到中间)");
    NSArray<NSString *> *classes = @[@"SBAppSwitcherController", @"SBMainWorkspace",
                                     @"SBUIController", @"SBWorkspace"];
    NSArray<NSString *> *sels = @[@"_showAppSwitcher", @"toggleAppSwitcher",
                                  @"showAppSwitcher", @"enterAppSwitcher", @"_launchAppSwitcher"];
    for (NSString *cn in classes) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        id obj = bx_sharedInstanceForClass(cls) ?: cls;
        for (NSString *sn in sels) {
            SEL sel = NSSelectorFromString(sn);
            if ([obj respondsToSelector:sel]) {
                ((void (*)(id, SEL))[obj methodForSelector:sel])(obj, sel);
                return;
            }
        }
    }
}

// 判定起点是否在触发角落（用角落返回灵敏度）
static BOOL bx_inCorner(CGPoint start) {
    if (!g_enabled) return NO;
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat zoneW = bx_lerp(0.14f, 0.34f, g_backSens);   // 侧向宽度占比（灵敏度越高角落越宽）
    CGFloat zoneH = bx_lerp(120.f, 240.f, g_backSens);   // 底部高度 pt（灵敏度越高越高）
    BOOL inBottom = start.y >= b.size.height - zoneH;
    BOOL inLeft   = inBottom && start.x <= b.size.width * zoneW;
    BOOL inRight  = inBottom && start.x >= b.size.width * (1.0f - zoneW);
    return (g_area == BXSwipeAreaBoth)  ? (inLeft || inRight)
         : (g_area == BXSwipeAreaLeft)  ? inLeft
                                        : inRight;
}

#pragma mark - 手势控制器（状态机）
@interface BXUpSwipeController : NSObject
+ (instancetype)shared;
- (void)resetPending;
- (void)startPendingHome;
- (BOOL)isPendingHome;
@end

@implementation BXUpSwipeController {
    BOOL     _pendingHome;
    NSTimer *_pendingTimer;
}
+ (instancetype)shared {
    static id instance; static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}
- (void)resetPending {
    _pendingHome = NO;
    [_pendingTimer invalidate];
    _pendingTimer = nil;
}
- (void)startPendingHome {
    if (!g_homeConfirm) return;
    _pendingHome = YES;
    [_pendingTimer invalidate];
    _pendingTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                     target:self
                                                   selector:@selector(resetPending)
                                                   userInfo:nil repeats:NO];
}
- (BOOL)isPendingHome { return _pendingHome; }
@end

#pragma mark - 吞掉手势（阻止系统识别回桌面/进后台/带动App）
static void bx_swallowGesture(UIPanGestureRecognizer *gr) {
    if (!gr) return;
    @try {
        [gr setValue:@(UIGestureRecognizerStateFailed) forKey:@"state"];
        bx_log(@"swallow: gesture failed (not going home)");
    } @catch (NSException *e) {
        bx_log(@"swallow failed: %@", e.name);
    }
}

// ---- 是否锁屏 / 是否有前台 App（用于只在 App 前台时拦截上滑，桌面/锁屏放行）----
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
    // SB 的 frontMostApplication 返回当前前台 App；nil 表示在主屏（无前台 App）
    @try {
        id app = [[UIApplication sharedApplication] valueForKey:@"frontMostApplication"];
        return app != nil;
    } @catch (NSException *e) { return YES; }
}

#pragma mark - 钩子：拦截系统 Home 手势
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
    // 上滑返回已停用：恢复系统原生上滑手势（上滑中间=后台、上滑到顶=回桌面由系统处理）。
    // 左右两侧滑动返回改由 App 层(SwipeBackApp)通过边缘触摸检测实现。
    %orig;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 恢复系统原生上滑手势处理
    %orig;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    objc_setAssociatedObject(self, @selector(bxSwipeHandled), @(NO), OBJC_ASSOCIATION_RETAIN);
    %orig;
}
%end

// 收到 App 层"已到最上级、请回桌面"通知 -> 执行返回桌面（一路返回的终点）
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
        bx_log(@"[SwipeBack] LOADED into SpringBoard, enabled=%d area=%ld backSens=%.2f midSens=%.2f homeSens=%.2f",
               g_enabled, (long)g_area, g_backSens, g_midSens, g_homeSens);
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
