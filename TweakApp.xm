// ============================================================================
//  上滑返回 —— App 层 (SwipeBackApp)  注入所有 App (filter com.apple.UIKit)
//  功能：监听 SB 层发来的 "com.doubao.swipeback.back" 通知，在主线程直接执行
//  "返回上一级"（导航栈 pop / 模态 dismiss / webview 返回）。
//  不抢手势、不影响系统（手势由 SB 层 HomeTapBackSwipe 拦截）。
// ============================================================================

#import <UIKit/UIKit.h>
#import <os/log.h>

static void bx_log(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    os_log(OS_LOG_DEFAULT, "%{public}@", msg);
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

    // 1) 优先 pop 导航栈（从 top 向父级找能返回的 UINavigationController，最多6层）
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
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.doubao.swipeback.gohome"), NULL, NULL, true);
        bx_log(@"[SwipeBackApp] at root page -> request go-home");
    }
}

// ---- 收到 SB 层"角落上滑"通知 -> 主线程执行返回上一级 ----
static void bxOnBackNotify(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    bx_log(@"[SwipeBackApp] received back-notify");
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIWindow *> *wins = [UIApplication sharedApplication].windows;
        for (UIWindow *w in wins) {
            if (w.isKeyWindow || w.rootViewController) {
                bxTriggerBack(w);
                break;
            }
        }
    });
}

#pragma mark - 构造
%ctor {
    @try {
        // 加载标记文件：确认 App 层 dylib 注入成功
        NSString *marker = [NSString stringWithFormat:@"%@ pid=%d app=%@\n",
                            [NSDate date], (int)getpid(),
                            [[NSBundle mainBundle] bundleIdentifier]];
        [marker writeToFile:@"/var/mobile/swipebackapp_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
        [marker writeToFile:@"/var/jb/var/mobile/swipebackapp_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}

    // 监听 SB 层"角落上滑返回"通知
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    bxOnBackNotify, CFSTR("com.doubao.swipeback.back"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    bx_log(@"[SwipeBackApp] LOADED into App");
}
