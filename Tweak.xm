// ============================================================================
//  Bottom-x 上滑返回 (HomeTapBackSwipe)  Tweak.xm
// ----------------------------------------------------------------------------
//  SpringBoard 层重新解释"底部上滑"手势，解决 iOS 原生 Home 手势冲突
//  （原生：任意底部上滑 -> 回桌面 / 上滑并停留 -> 后台）。
//
//  新方案（按上滑轨迹分类）：
//    A) 触发区域内上滑（角落上滑、未越过屏幕中间）  -> 返回上一级
//       —— 通过插件 SB<->App 的 darwin 通知通道请求前台 App 执行返回，
//          完全复用 App 侧"可返回数据"（导航栈/可返回控件/WKWebView）。
//    B) 上滑到屏幕中间（到达纵向中部）             -> 触发后台 (App Switcher)
//    C) 返回桌面                                   -> 需连续两次上滑确认
//       （当 A 的返回请求判定前台已在最顶层时，进入"待确认"状态，
//         短时间内的第二次上滑才真正回桌面，避免误触直接回桌面。）
//
//  依赖：com.colorblack.bottomx 的 HomeTapBackApp.dylib 已加载（App 侧执行返回）。
//
//  设置项（defaults 域 com.colorblack.bottomx）：
//    SwipeBackEnabled        BOOL    启用上滑返回
//    SwipeBackArea           String  Left|Right|Both   触发区域（左下/右下/双侧）
//    SwipeBackSensitivity    Float   0.0~1.0   灵敏度
//    SwipeBackHomeConfirm    BOOL    返回桌面需二次上滑确认（默认开）
//    SwipeBackMiddleSwitcher BOOL    上滑到中间触发后台（默认开）
//  变更通知：com.colorblack.bottomx.settings.changed
//
//  ⚠️ 注意事项（需真机调参）：
//  - SBHomeGesturePanGestureRecognizer 的钩取、以及"触发后台(App Switcher)"
//    依赖 SpringBoard 私有 API，不同 iOS 版本可能变化；源码已做多候选回退，
//    仍建议在目标系统真机核对与微调。
//  - SB<->App 通知 payload 键名按逆向所得，若返回无响应可据插件 DebugLog 调整。
// ============================================================================

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <objc/runtime.h>
#import <os/log.h>

// 设备端日志：装上后可用 `log stream --predicate 'subsystem == "com.colorblack.bottomx.swipeback"'`
// 或 Console App 观察，便于定位每一步是否触发。
static void bx_log(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    os_log(OS_LOG_DEFAULT, "%{public}@", msg);
}

#pragma mark - 设置键
static NSString *const kSwipeBackEnabled         = @"SwipeBackEnabled";
static NSString *const kSwipeBackArea            = @"SwipeBackArea";
static NSString *const kSwipeBackSensitivity     = @"SwipeBackSensitivity";
static NSString *const kSwipeBackHomeConfirm     = @"SwipeBackHomeConfirm";
static NSString *const kSwipeBackMiddleSwitcher  = @"SwipeBackMiddleSwitcher";

// 与插件一致的 darwin 通知名
static NSString *const kNotifyHomeTap  = @"com.hometapback.hometap";         // SB -> App 请求返回
static NSString *const kNotifyResult   = @"com.colorblack.bottomx.hometap.result";
static NSString *const kNotifyGoHome   = @"com.hometapback.gohome";

typedef NS_ENUM(NSInteger, BXSwipeArea) {
    BXSwipeAreaLeft  = 0,
    BXSwipeAreaRight = 1,
    BXSwipeAreaBoth  = 2,
};
typedef NS_ENUM(NSInteger, BXSwipeClass) {
    BXSwipeClassNone     = 0,   // 未处理，交给系统
    BXSwipeClassBack     = 1,   // 返回上一级
    BXSwipeClassSwitcher = 2,   // 触发后台
    BXSwipeClassHome     = 3,   // 返回桌面（二次确认）
};

static BOOL        g_enabled        = NO;
static BXSwipeArea g_area           = BXSwipeAreaBoth;
static CGFloat     g_sens           = 0.5f;
static BOOL        g_homeConfirm    = YES;
static BOOL        g_middleSwitcher = YES;

static CGFloat bx_lerp(CGFloat a, CGFloat b, CGFloat t) { return a + (b - a) * t; }

static void bx_loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.colorblack.bottomx"];
    [d synchronize];

    g_enabled = [d boolForKey:kSwipeBackEnabled];

    NSString *area = [d stringForKey:kSwipeBackArea] ?: @"Both";
    if ([area isEqualToString:@"Left"])       g_area = BXSwipeAreaLeft;
    else if ([area isEqualToString:@"Right"]) g_area = BXSwipeAreaRight;
    else                                      g_area = BXSwipeAreaBoth;

    CGFloat s = [d floatForKey:kSwipeBackSensitivity];
    if (s < 0.f) s = 0.f;
    if (s > 1.f) s = 1.f;
    g_sens = s;

    g_homeConfirm    = [d boolForKey:kSwipeBackHomeConfirm];
    g_middleSwitcher = [d boolForKey:kSwipeBackMiddleSwitcher];
}

// 常用单例 selector
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
    SEL hsel = NSSelectorFromString(@"_bx_sharedInstanceForClassName:");
    if ([cls respondsToSelector:hsel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id obj = [cls performSelector:hsel withObject:NSStringFromClass(cls)];
#pragma clang diagnostic pop
        if (obj) return obj;
    }
    return nil;
}

#pragma mark - 动作：返回上一级（复用可返回数据）
// 通过插件 SB<->App 的 darwin 通知通道，请求前台 App 用"可返回数据"执行返回。
// payload 键名按逆向所得（point/bundle/senderID/tapID/sequence/stamp），
// 若真机上 App 侧无响应，需按插件 DebugLog 调整键名。
static void bx_sendBackRequest(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"point"]    = @{ @"x": @0.0, @"y": @0.0 };   // 占位；可按需改成手势点
    info[@"bundle"]   = @"";
    info[@"senderID"] = @((uint64_t)(((uint64_t)arc4random() << 32) | arc4random()));
    info[@"tapID"]    = @((uint64_t)(((uint64_t)arc4random() << 32) | arc4random()));
    info[@"sequence"] = @1;
    info[@"stamp"]    = @((uint64_t)([NSProcessInfo processInfo].systemUptime * 1000.0));

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kNotifyHomeTap, NULL,
                                         (__bridge CFDictionaryRef)info, true);
    bx_log(@"[SwipeBack] ACTION back-request posted -> %@", kNotifyHomeTap);
    // 注：CFNotificationCenterGetDarwinNotifyCenter 本身就是 darwin 通知，
    // 不需要再 notify_post，避免同一通知重复触发两次返回。
}

#pragma mark - 动作：返回桌面（复用插件 SB 侧 go-home 派发）
static void bx_goHome(void) {
    bx_log(@"[SwipeBack] ACTION go-home (二次确认)");
    // 优先走插件自身的 dispatchGoHome（SB methname 中确有该 selector）
    Class disp = NSClassFromString(@"BXHomeDispatcher");
    id d = bx_sharedInstanceForClass(disp);
    SEL dgh = NSSelectorFromString(@"dispatchGoHome");
    if (d && [d respondsToSelector:dgh]) {
        ((void (*)(id, SEL))[d methodForSelector:dgh])(d, dgh);
        return;
    }
    // 回退：SpringBoard 原生 home 按键派发链（best-effort）
    Class sbui = NSClassFromString(@"SBUIController");
    id c = bx_sharedInstanceForClass(sbui);
    SEL s1 = NSSelectorFromString(@"handleHomeButtonSinglePressUp");
    SEL s2 = NSSelectorFromString(@"_handleHomeButtonSinglePressUp");
    if (c && [c respondsToSelector:s1]) {
        ((void (*)(id, SEL))[c methodForSelector:s1])(c, s1);
    } else if (c && [c respondsToSelector:s2]) {
        ((void (*)(id, SEL))[c methodForSelector:s2])(c, s2);
    } else {
        notify_post([kNotifyGoHome UTF8String]);
    }
}

#pragma mark - 动作：触发后台 (App Switcher)
// 私有 API 因系统版本而异，做多候选回退；全部失败则放行系统原生处理。
static void bx_triggerAppSwitcher(void) {
    bx_log(@"[SwipeBack] ACTION app-switcher (上滑到中间)");
    NSArray<NSString *> *classes = @[@"SBAppSwitcherController",
                                     @"SBMainWorkspace",
                                     @"SBUIController",
                                     @"SBWorkspace"];
    NSArray<NSString *> *sels = @[@"_showAppSwitcher",
                                  @"toggleAppSwitcher",
                                  @"showAppSwitcher",
                                  @"enterAppSwitcher",
                                  @"_launchAppSwitcher"];
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
    // 无可用私有 API：不吞掉，交由系统原生（上滑+停留也能进后台）
}

#pragma mark - 手势控制器（状态机）
@interface BXUpSwipeController : NSObject
+ (instancetype)shared;
- (BXSwipeClass)onGestureEndedAt:(CGPoint)end velocity:(CGPoint)vel start:(CGPoint)start;
- (void)resetPending;
- (void)onResultAction:(NSString *)action;
@end

@implementation BXUpSwipeController {
    BOOL     _pendingHome;
    NSTimer *_pendingTimer;
}

+ (instancetype)shared {
    static id instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)resetPending {
    _pendingHome = NO;
    [_pendingTimer invalidate];
    _pendingTimer = nil;
}

// 主分类：返回上一级 / 触发后台 / 返回桌面(二次确认) / 交给系统
- (BXSwipeClass)onGestureEndedAt:(CGPoint)end velocity:(CGPoint)vel start:(CGPoint)start {
    if (!g_enabled) return BXSwipeClassNone;

    CGRect b = [UIScreen mainScreen].bounds;
    if (b.size.width < 1.f || b.size.height < 1.f) return BXSwipeClassNone;

    // 只处理"向上"的滑动（需达到最小位移，阈值随灵敏度缩放）
    CGFloat dy = start.y - end.y;
    if (dy < bx_lerp(50.f, 20.f, g_sens)) return BXSwipeClassNone;

    // 1) 上滑到屏幕中间 -> 触发后台
    if (end.y <= b.size.height * 0.5f) {
        if (g_middleSwitcher) {
            [self resetPending];
            return BXSwipeClassSwitcher;
        }
        return BXSwipeClassNone;   // 关闭则放行系统
    }

    // 2) 未到中间：判定角落触发区
    CGFloat zoneW = bx_lerp(0.16f, 0.30f, g_sens);    // 底部侧向宽度占比
    CGFloat zoneH = bx_lerp(130.f, 210.f, g_sens);    // 底部高度(pt)
    BOOL inBottom = start.y >= b.size.height - zoneH;
    BOOL inLeft   = inBottom && start.x <= b.size.width * zoneW;
    BOOL inRight  = inBottom && start.x >= b.size.width * (1.0f - zoneW);
    BOOL corner   = (g_area == BXSwipeAreaBoth)  ? (inLeft || inRight)
                   : (g_area == BXSwipeAreaLeft) ? inLeft
                                                 : inRight;
    if (!corner) return BXSwipeClassNone;   // 触发区外 -> 交给系统

    // 3) 角落上滑：二次确认返回桌面 / 返回上一级
    if (g_homeConfirm && _pendingHome) {
        [self resetPending];
        return BXSwipeClassHome;    // 已是第二次上滑 -> 确认返回桌面
    }
    return BXSwipeClassBack;        // 第一次：先请求返回上一级
}

// 处理 App 返回结果，判断是否进入"待确认回桌面"状态
- (void)onResultAction:(NSString *)action {
    if (!g_homeConfirm || !action) return;
    // App 返回结果含 "AtRoot"/"RootHome" 表示已在最顶层、本应回桌面
    if ([action containsString:@"AtRoot"] || [action containsString:@"RootHome"]) {
        _pendingHome = YES;
        [_pendingTimer invalidate];
        _pendingTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                        target:self
                                                      selector:@selector(resetPending)
                                                      userInfo:nil
                                                       repeats:NO];
        AudioServicesPlaySystemSound(1519);   // 轻震动，提示"再上滑一次返回桌面"
    }
}
@end

#pragma mark - 钩子：拦截系统 Home 手势
// 目的：在系统把上滑判定为"回桌面/进后台"之前，先按我们的方案重新分类；
// 命中则吞掉触摸（不 %orig）并强制手势失败，阻止系统触发原生回桌面/进后台。
// 说明：仅 hook touchesEnded 并 return 不足以阻止系统，因为手势识别器仍可能
// 自行进入"已识别"状态去触发 home 动作；必须显式把 state 置为 Failed/Cancelled。
static void bx_swallowGesture(UIPanGestureRecognizer *gr) {
    if (!gr) return;
    @try {
        // state 在 UIKit 公开头里是 readonly，但 setter 存在，用 KVC 设置。
        // Failed 会让识别器终止、不触发 target-action（也就不会回桌面/进后台）。
        [gr setValue:@(UIGestureRecognizerStateFailed) forKey:@"state"];
        bx_log(@"swallow: gesture failed (not going home)");
    } @catch (NSException *e) {
        bx_log(@"swallow failed: %@", e.name);
    }
}

%hook SBHomeGesturePanGestureRecognizer

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;   // 先放行系统手势进入，同时记录起点
    UIPanGestureRecognizer *gr = (UIPanGestureRecognizer *)self;   // SBHomeGesture... 是私有类，按父类访问
    UITouch *t = touches.anyObject;
    if (t && gr.view) {
        CGPoint p = [t locationInView:gr.view];
        objc_setAssociatedObject(self, @selector(bxSwipeStart),
                                 [NSValue valueWithCGPoint:p], OBJC_ASSOCIATION_RETAIN);
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UIPanGestureRecognizer *gr = (UIPanGestureRecognizer *)self;
    UITouch *t = touches.anyObject;
    NSValue *sv = objc_getAssociatedObject(self, @selector(bxSwipeStart));
    CGPoint start = sv ? sv.CGPointValue : CGPointMake(-1.f, -1.f);
    CGPoint end = (t && gr.view) ? [t locationInView:gr.view] : start;
    CGPoint vel = CGPointZero;
    if (gr.view && [gr respondsToSelector:@selector(velocityInView:)]) {
        vel = [gr velocityInView:gr.view];
    }

    BXSwipeClass cls = [[BXUpSwipeController shared] onGestureEndedAt:end velocity:vel start:start];
    if (g_enabled) {
        bx_log(@"swipe end=(%.0f,%.0f) vel=(%.0f,%.0f) start=(%.0f,%.0f) class=%ld",
               end.x, end.y, vel.x, vel.y, start.x, start.y, (long)cls);
    }
    if (cls == BXSwipeClassBack) {
        bx_swallowGesture(gr);           // 先让手势"失败"，系统才不会回桌面
        bx_sendBackRequest();            // 返回上一级（复用可返回数据）
        return;                          // 不 %orig，吞掉
    }
    if (cls == BXSwipeClassHome) {
        bx_swallowGesture(gr);
        bx_goHome();                     // 二次上滑确认 -> 返回桌面
        return;
    }
    if (cls == BXSwipeClassSwitcher) {
        bx_swallowGesture(gr);
        bx_triggerAppSwitcher();         // 上滑到中间 -> 触发后台
        return;                          // 已处理则吞掉；私有API失败会内部放行
    }
    %orig;                               // 触发区外/未启用 -> 交给系统原生
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [[BXUpSwipeController shared] resetPending];
    %orig;
}
%end

#pragma mark - 监听 App 返回结果（用于二次确认回桌面）
static void bx_resultCallback(CFNotificationCenterRef c, void *o, CFStringRef n,
                              const void *obj, CFDictionaryRef userInfo) {
    if (!userInfo) return;
    id action = [(__bridge NSDictionary *)userInfo objectForKey:@"action"];
    if ([action isKindOfClass:NSString.class]) {
        [[BXUpSwipeController shared] onResultAction:action];
    }
}

#pragma mark - 设置变更回调
static void bx_settingsChanged(CFNotificationCenterRef c, void *o, CFStringRef n,
                               const void *obj, CFDictionaryRef ui) {
    bx_loadPrefs();
}

#pragma mark - 悬浮返回按钮（加载可视化 + 兜底触发）
// 作用：
//  1) 能看到这个按钮 = dylib 已成功注入加载（比震动可靠）；
//  2) 点它 = 触发"返回上一级"，用于验证返回链路、并在手势不理想时兜底。
//  建议先装一版带按钮的确认注入是否成功，再做手势微调。
static void bx_floatingTapped(void) {
    bx_log(@"floating button tapped -> back");
    AudioServicesPlaySystemSound(1511);
    bx_sendBackRequest();
}

@interface BXFloatingButton : UIButton
@end
@implementation BXFloatingButton
- (void)bx_onTap {
    bx_floatingTapped();
}
@end

static void bx_addFloatingButton(void) {
    @autoreleasepool {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;
        // 选面积最大的主窗口（SpringBoard 主屏窗口），避免加到隐藏/系统窗口上
        UIWindow *win = nil;
        CGFloat bestArea = 0;
        for (UIWindow *w in app.windows) {
            CGFloat a = w.bounds.size.width * w.bounds.size.height;
            if (a > bestArea) { bestArea = a; win = w; }
        }
        if (!win) {
            // 窗口还没就绪，稍后重试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ bx_addFloatingButton(); });
            return;
        }
        CGRect fr = win.bounds;
        CGFloat side = 46.0f;
        // 用 initWithFrame 直接创建 BXFloatingButton 子类实例（buttonWithType: 返回普通 UIButton）
        BXFloatingButton *b = [[BXFloatingButton alloc] initWithFrame:CGRectMake(fr.size.width - side - 14, fr.size.height - side - 20, side, side)];
        b.layer.cornerRadius = side / 2.0f;
        b.layer.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.3 alpha:0.85].CGColor;
        b.layer.borderColor = [UIColor whiteColor].CGColor;
        b.layer.borderWidth = 1.5f;
        [b setTitle:@"返回" forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        b.accessibilityLabel = @"HomeTapBackSwipe按钮";
        [b addTarget:b action:@selector(bx_onTap) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:b];
        [win bringSubviewToFront:b];
        bx_log(@"floating button added at (%.0f,%.0f)", b.frame.origin.x, b.frame.origin.y);
    }
}


#pragma mark - 构造
%ctor {
    @try {
        bx_loadPrefs();
        bx_log(@"[SwipeBack] LOADED into SpringBoard, enabled=%d area=%ld sens=%.2f homeConfirm=%d middleSwitcher=%d",
               g_enabled, (long)g_area, g_sens, g_homeConfirm, g_middleSwitcher);
    } @catch (...) {}

    // 写入加载标记文件：注销后如果手机上出现这个文件 = dylib 确实被加载执行了
    // （用于一锤定音区分"没加载"和"按钮/手势 bug"；能用 Filza 在 /var/mobile/ 查看）
    @try {
        NSString *marker = [NSString stringWithFormat:@"%@ pid=%d\n", [NSDate date], (int)getpid()];
        [marker writeToFile:@"/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
        // 也在越狱根写一份（如果权限允许）
        [marker writeToFile:@"/var/jb/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}

    // 主线程延迟添加悬浮返回按钮：能看到按钮 = dylib 已注入成功，点它=返回
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ bx_addFloatingButton(); });
        });
    } @catch (...) {}

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    &bx_resultCallback,
                                    (__bridge CFStringRef)kNotifyResult,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    &bx_settingsChanged,
                                    CFSTR("com.colorblack.bottomx.settings.changed"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
