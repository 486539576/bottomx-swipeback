// ============================================================================
//  Bottom-x 左右滑动返回 (HomeTapBackSwipe)  Tweak.xm  —— v0.4.0
// ----------------------------------------------------------------------------
//  作用：
//    - 不再拦截系统上滑手势（上滑中间=后台、上滑到顶=回桌面由系统处理）。
//    - "左右两侧滑动返回"由 App 层(SwipeBackApp)通过 UIWindow 边缘触摸检测实现。
//    - 本层只负责：监听 App 层在"到达 App 最上级"时发来的回桌面请求，
//      用最可靠的方式真正返回桌面（复用原版 dispatchGoHome / 系统正规回主屏）。
// ============================================================================

#import <UIKit/UIKit.h>
#import <notify.h>
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

static NSString *const kNotifyGoHome  = @"com.hometapback.gohome";

static BOOL        g_enabled        = NO;
static CGFloat     g_homeSens       = 0.6f;

static CGFloat bx_lerp(CGFloat a, CGFloat b, CGFloat t) {
    if (t < 0) t = 0; if (t > 1) t = 1;
    return a + (b - a) * t;
}

static void bx_loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.colorblack.bottomx"];
    [d synchronize];
    g_enabled = [d boolForKey:kSwipeBackEnabled];
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

// 返回桌面：按最可靠方式依次尝试，确保至少一个生效
static void bx_goHome(void) {
    bx_log(@"[SwipeBack] ACTION go-home");
    // 1) 原版 BXHomeDispatcher.dispatchGoHome（最贴近原插件回桌面，小白条点击可靠）
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
    // 5) 发原版 gohome 通知兜底
    @try {
        notify_post([kNotifyGoHome UTF8String]);
        notify_post("com.colorblack.bottomx.gohome");
        bx_log(@"[SwipeBack] go-home via notify");
    } @catch (...) {}
}

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
        bx_log(@"[SwipeBack] LOADED into SpringBoard (回桌面监听), enabled=%d homeSens=%.2f",
               g_enabled, g_homeSens);
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
