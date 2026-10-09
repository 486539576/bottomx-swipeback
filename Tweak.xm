// ============================================================================
//  Bottom-x 上滑返回 (HomeTapBackSwipe)  Tweak.xm  —— 严谨改进版 v0.2.96
// ----------------------------------------------------------------------------
//  SpringBoard 层重新解释"底部上滑"手势，解决 iOS 原生 Home 手势冲突。
//
//  关键改进：拦截时机从 touchesEnded 提前到 touchesMoved
//  （iOS 系统在手指移动过程中就识别"回桌面/带动App"，touchesEnded 已太晚；
//   现在手指一上滑就吞掉手势，阻止系统回桌面、App 不被带动）。
//
//  新方案（按起点分类）：
//    A) 起点在触发角落 + 上滑              -> 返回上一级（通知前台 App 执行）
//    B) 起点在触发角落 + 1.2s 内再次上滑     -> 二次确认返回桌面
//    C) 起点在屏幕中间 + 上滑到中部         -> 触发后台 (App Switcher)
//    D) 触发区外 / 未启用                   -> 交给系统原生
// ============================================================================

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <objc/runtime.h>
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
static NSString *const kSwipeBackSensitivity    = @"SwipeBackSensitivity";
static NSString *const kSwipeBackHomeConfirm    = @"SwipeBackHomeConfirm";
static NSString *const kSwipeBackMiddleSwitcher = @"SwipeBackMiddleSwitcher";

static NSString *const kNotifyHomeTap = @"com.hometapback.hometap";  // SB -> App 请求返回
static NSString *const kNotifyGoHome  = @"com.hometapback.gohome";

typedef NS_ENUM(NSInteger, BXSwipeArea)   { BXSwipeAreaLeft=0, BXSwipeAreaRight=1, BXSwipeAreaBoth=2 };
typedef NS_ENUM(NSInteger, BXSwipeClass)  { BXSwipeClassNone=0, BXSwipeClassBack=1,
                                            BXSwipeClassSwitcher=2, BXSwipeClassHome=3 };

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
    if      ([area isEqualToString:@"Left"])  g_area = BXSwipeAreaLeft;
    else if ([area isEqualToString:@"Right"]) g_area = BXSwipeAreaRight;
    else                                      g_area = BXSwipeAreaBoth;
    CGFloat s = [d floatForKey:kSwipeBackSensitivity];
    if (s < 0.f) s = 0.f;
    if (s > 1.f) s = 1.f;
    g_sens = s;
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

// 返回上一级：darwin 通知请求前台 App 执行返回
static void bx_sendBackRequest(void) {
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
    bx_log(@"[SwipeBack] ACTION back-request posted -> %@", kNotifyHomeTap);
}

// 返回桌面：优先走插件自身 go-home，回退系统 home 派发
static void bx_goHome(void) {
    bx_log(@"[SwipeBack] ACTION go-home (二次确认)");
    Class disp = NSClassFromString(@"BXHomeDispatcher");
    id d = bx_sharedInstanceForClass(disp);
    SEL dgh = NSSelectorFromString(@"dispatchGoHome");
    if (d && [d respondsToSelector:dgh]) {
        ((void (*)(id, SEL))[d methodForSelector:dgh])(d, dgh);
        return;
    }
    Class sbui = NSClassFromString(@"SBUIController");
    id c = bx_sharedInstanceForClass(sbui);
    SEL s1 = NSSelectorFromString(@"handleHomeButtonSinglePressUp");
    SEL s2 = NSSelectorFromString(@"_handleHomeButtonSinglePressUp");
    if (c && [c respondsToSelector:s1])      ((void (*)(id, SEL))[c methodForSelector:s1])(c, s1);
    else if (c && [c respondsToSelector:s2]) ((void (*)(id, SEL))[c methodForSelector:s2])(c, s2);
    else                                      notify_post([kNotifyGoHome UTF8String]);
}

// 触发后台 (App Switcher)，多候选回退
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

// 判定起点是否在触发角落
static BOOL bx_inCorner(CGPoint start) {
    if (!g_enabled) return NO;
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat zoneW = bx_lerp(0.16f, 0.30f, g_sens);
    CGFloat zoneH = bx_lerp(130.f, 210.f, g_sens);
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
- (void)startPendingHome;      // 进入"二次确认回桌面"待确认状态
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
    objc_setAssociatedObject(self, @selector(bxSwipeHandled),
                             @(NO), OBJC_ASSOCIATION_RETAIN);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UIPanGestureRecognizer *gr = (UIPanGestureRecognizer *)self;
    UITouch *t = touches.anyObject;
    NSValue *sv = objc_getAssociatedObject(self, @selector(bxSwipeStart));
    NSNumber *handled = objc_getAssociatedObject(self, @selector(bxSwipeHandled));
    CGPoint start = sv ? sv.CGPointValue : CGPointMake(-1.f, -1.f);
    CGPoint cur   = (t && gr.view) ? [t locationInView:gr.view] : start;

    if (g_enabled && !handled.boolValue && start.x >= 0) {
        CGFloat dy = start.y - cur.y;
        if (dy > 10.f) {                        // 确实在向上滑
            if (bx_inCorner(start)) {           // 起点在角落
                objc_setAssociatedObject(self, @selector(bxSwipeHandled), @(YES), OBJC_ASSOCIATION_RETAIN);
                BXUpSwipeController *c = [BXUpSwipeController shared];
                if (g_homeConfirm && [c isPendingHome]) {   // 1.2s 内第二次上滑 -> 回桌面
                    [c resetPending];
                    bx_swallowGesture(gr);
                    bx_goHome();
                    return;                     // 不 %orig，吞掉
                }
                [c startPendingHome];           // 第一次 -> 进入待确认
                bx_swallowGesture(gr);          // 阻止系统回桌面 / 带动 App
                bx_sendBackRequest();           // 返回上一级
                return;                         // 不 %orig，吞掉
            }
        }
    }
    %orig;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UIPanGestureRecognizer *gr = (UIPanGestureRecognizer *)self;
    NSNumber *handled = objc_getAssociatedObject(self, @selector(bxSwipeHandled));
    // 起点在角落已由 touchesMoved 处理过（返回/回桌面），这里跳过
    if (g_enabled && !handled.boolValue) {
        UITouch *t = touches.anyObject;
        NSValue *sv = objc_getAssociatedObject(self, @selector(bxSwipeStart));
        CGPoint start = sv ? sv.CGPointValue : CGPointMake(-1.f, -1.f);
        CGPoint end   = (t && gr.view) ? [t locationInView:gr.view] : start;
        CGPoint vel   = CGPointZero;
        if (gr.view && [gr respondsToSelector:@selector(velocityInView:)])
            vel = [gr velocityInView:gr.view];
        // 起点不在角落：判断是否上滑到中间 -> 后台
        CGRect b = [UIScreen mainScreen].bounds;
        if (start.x >= 0 && end.y <= b.size.height * 0.5f) {
            if (g_middleSwitcher) {
                bx_swallowGesture(gr);
                bx_triggerAppSwitcher();
                return;                         // 不 %orig
            }
        }
    }
    %orig;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    objc_setAssociatedObject(self, @selector(bxSwipeHandled), @(NO), OBJC_ASSOCIATION_RETAIN);
    %orig;
}
%end

#pragma mark - 构造
%ctor {
    @try {
        bx_loadPrefs();
        bx_log(@"[SwipeBack] LOADED into SpringBoard, enabled=%d area=%ld sens=%.2f homeConfirm=%d middleSwitcher=%d",
               g_enabled, (long)g_area, g_sens, g_homeConfirm, g_middleSwitcher);
    } @catch (...) {}

    // 加载标记文件（一锤定音区分"没加载"和"逻辑 bug"）
    @try {
        NSString *marker = [NSString stringWithFormat:@"%@ pid=%d\n", [NSDate date], (int)getpid()];
        [marker writeToFile:@"/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
        [marker writeToFile:@"/var/jb/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    NULL, NULL, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
