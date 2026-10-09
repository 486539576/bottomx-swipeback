// ============================================================================
//  左右两侧滑动返回 —— App 层 (SwipeBackApp)  注入所有 App (filter com.apple.UIKit)
//  功能：在 App 内检测"左右边缘向内滑动"手势：
//      - 左边缘向右滑 = 返回上一级
//      - 右边缘向左滑 = 返回上一级
//  返回直接由 App 层执行（导航 pop / 模态 dismiss / webview 返回）。
//  到 App 最上级再滑动 = 请求 SpringBoard 回桌面（一路返回的终点）。
//  不抢系统上滑手势：上滑中间=后台、上滑到顶=回桌面仍由系统处理。
// ============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

static void bx_log(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    os_log(OS_LOG_DEFAULT, "%{public}@", msg);
}

// ---- 设置缓存（与 Root.plist key 对齐）----
static BOOL       bx_masterEnabled = NO;
static BOOL       bx_swipeEnabled  = NO;
static NSString  *bx_area          = @"Both";
static CGFloat    bx_backSens      = 0.6f;

static void bx_loadPrefs(void) {
    @try {
        NSString *p = @"/var/mobile/Library/Preferences/com.colorblack.bottomx.plist";
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d || d.count == 0)
            d = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.colorblack.bottomx.plist"];
        if (!d) d = @{};
        bx_masterEnabled = [d[@"MasterEnabled"] boolValue];
        bx_swipeEnabled  = [d[@"SwipeBackEnabled"] boolValue];
        bx_area          = d[@"SwipeBackArea"] ?: @"Both";
        bx_backSens      = [d[@"SwipeBackBackSensitivity"] floatValue];
        if (bx_backSens < 0.05f || bx_backSens > 1.f) bx_backSens = 0.6f;
        bx_log(@"[SwipeBackApp] prefs: master=%d swipe=%d area=%s sens=%.2f",
               bx_masterEnabled, bx_swipeEnabled, bx_area.UTF8String, bx_backSens);
    } @catch (...) {}
}

static BOOL bx_active(void) {
    // 左右滑动返回只由"启用左右滑动返回"(SwipeBackEnabled) 这一个开关控制，
    // 不依赖原版 MasterEnabled（用户不必开原版总开关）。
    return bx_swipeEnabled;
}

static void bxOnSettingsChanged(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    bx_loadPrefs();
}

// ---- 系统标准边缘滑动手势识别器（与系统边缘返回同机制，最可靠）----
static void bxTriggerBack(UIView *view);   // 前向声明
@interface BXEdgeProxy : NSObject
@end
@implementation BXEdgeProxy
- (void)bxEdgeLeft:(UIScreenEdgePanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) {
        UIWindow *w = (UIWindow *)g.view;
        dispatch_async(dispatch_get_main_queue(), ^{ bxTriggerBack(w); });
        bx_log(@"[SwipeBackApp] edge(recognizer) LEFT -> back");
    }
}
- (void)bxEdgeRight:(UIScreenEdgePanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) {
        UIWindow *w = (UIWindow *)g.view;
        dispatch_async(dispatch_get_main_queue(), ^{ bxTriggerBack(w); });
        bx_log(@"[SwipeBackApp] edge(recognizer) RIGHT -> back");
    }
}
@end

static BXEdgeProxy *bxProxy = nil;

static void bxInstallEdges(void) {
    if (!bx_active()) return;
    UIWindow *win = [UIApplication sharedApplication].windows.firstObject;   // 主窗口（keyWindow 已废弃）
    if (!win || !win.rootViewController) return;
    static char kL, kR;
    if (!objc_getAssociatedObject(win, &kL)) {
        UIScreenEdgePanGestureRecognizer *l = [[UIScreenEdgePanGestureRecognizer alloc]
            initWithTarget:bxProxy action:@selector(bxEdgeLeft:)];
        l.edges = UIRectEdgeLeft;
        [win addGestureRecognizer:l];
        objc_setAssociatedObject(win, &kL, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        bx_log(@"[SwipeBackApp] installed LEFT edge recognizer");
    }
    if (!objc_getAssociatedObject(win, &kR)) {
        UIScreenEdgePanGestureRecognizer *r = [[UIScreenEdgePanGestureRecognizer alloc]
            initWithTarget:bxProxy action:@selector(bxEdgeRight:)];
        r.edges = UIRectEdgeRight;
        [win addGestureRecognizer:r];
        objc_setAssociatedObject(win, &kR, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        bx_log(@"[SwipeBackApp] installed RIGHT edge recognizer");
    }
}

// ---- 找到当前最上层可返回的控制器 ----
static UIViewController *bxTopViewController(UIViewController *root) {
    UIViewController *t = root;
    while (t.presentedViewController) t = t.presentedViewController;
    if ([t isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = ((UITabBarController *)t).selectedViewController;
        if (sel) t = sel;
    }
    if ([t isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)t;
        if (nav.viewControllers.count > 0) t = nav.topViewController;
    }
    return t;
}

// ---- 执行返回上一级（导航 pop / dismiss / webview）----
static void bxTriggerBack(UIView *view) {
    UIWindow *win = (UIWindow *)view;
    UIViewController *root = win.rootViewController;
    if (!root) return;

    UIViewController *top = bxTopViewController(root);
    BOOL handled = NO;

    // 1) 优先 pop 导航栈
    UIViewController *c = top;
    for (int i = 0; i < 6 && c; i++) {
        UINavigationController *nav = [c isKindOfClass:[UINavigationController class]]
            ? (UINavigationController *)c : c.navigationController;
        if (nav && nav.viewControllers.count > 1) {
            [nav popViewControllerAnimated:YES];
            bx_log(@"[SwipeBackApp] popped nav (%ld -> %ld)",
                   (long)nav.viewControllers.count, (long)nav.viewControllers.count - 1);
            handled = YES;
            break;
        }
        c = c.navigationController ?: c.parentViewController;
    }

    // 2) dismiss 模态
    if (!handled && top.presentingViewController && ![top isKindOfClass:[UIAlertController class]]) {
        [top dismissViewControllerAnimated:YES completion:nil];
        bx_log(@"[SwipeBackApp] dismissed modal");
        handled = YES;
    }

    // 3) webview 内可返回
    if (!handled && [top respondsToSelector:@selector(webView)]) {
        id wv = [top valueForKey:@"webView"];
        if (wv && [wv respondsToSelector:@selector(canGoBack)] && [wv canGoBack]) {
            [wv goBack];
            bx_log(@"[SwipeBackApp] webview goBack");
            handled = YES;
        }
    }

    // 4) 已到 App 最上级、无返回可执行 -> 请求 SB 层回桌面（一路返回的终点）
    if (!handled) {
        @try {
            NSString *marker = [NSString stringWithFormat:@"%@ root->gohome %@\n",
                                [NSDate date], [[NSBundle mainBundle] bundleIdentifier]];
            [marker writeToFile:@"/var/mobile/swipeback_gohome_sent.txt" atomically:YES
                       encoding:NSUTF8StringEncoding error:nil];
        } @catch (...) {}
        // 触发原版可靠回桌面链路 + 我的链路
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterPostNotification(nc, CFSTR("com.hometapback.gohome"), NULL, NULL, true);
        CFNotificationCenterPostNotification(nc, CFSTR("com.colorblack.bottomx.hometap.ack"), NULL, NULL, true);
        CFNotificationCenterPostNotification(nc, CFSTR("com.doubao.swipeback.gohome"), NULL, NULL, true);
        bx_log(@"[SwipeBackApp] at root page -> request go-home");
    }
}

#pragma mark - 左右边缘滑动返回检测（App 层，不抢系统上滑）
// iOS 触摸事件经 UIWindow -sendEvent: 分发，触摸本身被交给 hit-test 到的子视图，
// UIWindow 的 touchesBegan/Moved 不会被调用。因此在 sendEvent: 里检测边缘滑动最可靠。
%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (!bx_active()) return;
    NSSet *touches = event.allTouches;
    for (UITouch *t in touches) {
        UITouchPhase ph = t.phase;
        if (ph == UITouchPhaseBegan) {
            CGPoint p = [t locationInView:self];
            objc_setAssociatedObject(t, @selector(bxTouchStart),
                                     [NSValue valueWithCGPoint:p], OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(t, @selector(bxTouchDone), @(NO), OBJC_ASSOCIATION_RETAIN);
        } else if (ph == UITouchPhaseMoved) {
            NSValue *sv = objc_getAssociatedObject(t, @selector(bxTouchStart));
            NSNumber *dn = objc_getAssociatedObject(t, @selector(bxTouchDone));
            if (!sv || dn.boolValue) continue;
            CGPoint start = sv.CGPointValue;
            CGPoint cur   = [t locationInView:self];
            CGRect  b     = self.bounds;
            if (b.size.width <= 0) continue;

            CGFloat zoneW  = MIN(b.size.width * (0.08f + 0.12f * bx_backSens), 140.f); // 边缘宽度(灵敏度)
            CGFloat thresh = 18.f + 34.f * (1.0f - bx_backSens);                        // 滑动距离阈值(灵敏度)
            CGFloat dx     = cur.x - start.x;
            BOOL inLeft    = start.x <= zoneW;
            BOOL inRight   = start.x >= b.size.width - zoneW;
            BOOL okArea = [bx_area isEqualToString:@"Left"] ? inLeft
                        : [bx_area isEqualToString:@"Right"] ? inRight
                        : (inLeft || inRight);
            BOOL okDir = (inLeft && dx > thresh) || (inRight && dx < -thresh);
            if (okArea && okDir) {
                objc_setAssociatedObject(t, @selector(bxTouchDone), @(YES), OBJC_ASSOCIATION_RETAIN);
                UIWindow *win = self;
                dispatch_async(dispatch_get_main_queue(), ^{ bxTriggerBack(win); });
                bx_log(@"[SwipeBackApp] edge swipe -> back (area=%s dir=%s)", bx_area.UTF8String,
                       (inLeft ? "right" : "left"));
                break;
            }
        }
    }
}
%end

#pragma mark - 构造
%ctor {
    @try {
        NSString *marker = [NSString stringWithFormat:@"%@ pid=%d app=%@\n",
                            [NSDate date], (int)getpid(),
                            [[NSBundle mainBundle] bundleIdentifier]];
        [marker writeToFile:@"/var/mobile/swipebackapp_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
        [marker writeToFile:@"/var/jb/var/mobile/swipebackapp_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}

    bx_loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    bxOnSettingsChanged, CFSTR("com.colorblack.bottomx.settings.changed"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    // 系统标准边缘滑动手势：App 进入前台、主窗口就绪后安装到 keyWindow
    bxProxy = [[BXEdgeProxy alloc] init];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        // 多试几次，等 rootViewController 就绪
        for (int i = 1; i <= 4; i++) {
            double delay = 0.6 * i;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ bxInstallEdges(); });
        }
    }];
    bx_log(@"[SwipeBackApp] LOADED (edge-swipe back, recognizer+sendEvent)");
}
