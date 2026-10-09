// ============================================================================
//  Bottom-x 白条点击返回（区域加宽） HomeTapBackSwipe  —— v0.6.0
// ----------------------------------------------------------------------------
//  SpringBoard 层：
//    只做一件事：把"小白条可点击区域"加宽一点点，其余全部恢复原版默认。
//    - 在加宽后的白条区域单击 → 发返回通知给 App 层(SwipeBackApp)，
//      由它在 App 内直接执行"返回上一级 / 一路返回到桌面"。
//    - 点白条=返回上一级、到最上级再点=回桌面，跟原版手感完全一致。
//    - 设置里无新增项（完全恢复原版设置界面）。
//      白条点击区域在代码里固定加宽一点点（横向覆盖约60%），不可调。
//    - 上滑中间=后台、上滑到顶=回桌面，完全交给系统，本层不拦截滑动。
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

static NSString *const kMasterEnabled  = @"MasterEnabled";

static BOOL    g_enabled = NO;
static CGFloat g_areaW   = 0.60f;   // 固定加宽一点点：横向覆盖 lerp(0.30,1.00,0.60)≈72%

static CGFloat bx_lerp(CGFloat a, CGFloat b, CGFloat t) {
    if (t < 0) t = 0; if (t > 1) t = 1;
    return a + (b - a) * t;
}

static void bx_loadPrefs(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.colorblack.bottomx"];
    [d synchronize];
    g_enabled = [d boolForKey:kMasterEnabled];
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

// 点击点是否在"加宽的白条区域"（屏幕底部，横向向两侧展开）
static BOOL bx_inTapArea(CGPoint p) {
    if (!g_enabled) return NO;
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat cover = bx_lerp(0.30f, 1.00f, g_areaW);   // 横向覆盖：窄30% ~ 全宽100%
    CGFloat zoneH = bx_lerp(80.f, 220.f, g_areaW);    // 底部高度 pt
    if (p.y < b.size.height - zoneH) return NO;
    CGFloat half = b.size.width * cover / 2.0;
    return fabs(p.x - b.size.width / 2.0) <= half;
}

// 发"返回上一级"通知给 App 层(SwipeBackApp)，由它在 App 内直接 pop/dismiss 返回
static void bx_sendBackNotify(CGPoint point) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.doubao.swipeback.back"), NULL, NULL, true);
    bx_log(@"[HomeTapBackSwipe] white-bar tap -> App layer back notify");
}

#pragma mark - 钩子：加宽白条区域的单击返回
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
    if (bx_isLocked()) return;   // 锁屏完全放行
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

    // 固定"点击"判定（轻点=返回，上滑不触发）：位移 ≤20pt 且时长 ≤0.7s
    CGFloat maxMove = 20.f;
    CGFloat maxDur  = 0.7f;
    CGFloat dx = cur.x - start.x, dy = cur.y - start.y;
    CGFloat dist = sqrt(dx * dx + dy * dy);
    NSTimeInterval dur = [[NSDate date] timeIntervalSinceDate:t0];

    if (dist <= maxMove && dur <= maxDur && bx_inTapArea(start)) {
        objc_setAssociatedObject(self, @selector(bxTapHandled), @(YES), OBJC_ASSOCIATION_RETAIN);
        bx_sendBackNotify(start);
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    objc_setAssociatedObject(self, @selector(bxTapHandled), @(NO), OBJC_ASSOCIATION_RETAIN);
    %orig;
}
%end

#pragma mark - 构造
%ctor {
    @try {
        bx_loadPrefs();
        bx_log(@"[HomeTapBackSwipe] LOADED, enabled=%d areaW=%.2f", g_enabled, g_areaW);
    } @catch (...) {}
    @try {
        NSString *marker = [NSString stringWithFormat:@"%@ pid=%d\n", [NSDate date], (int)getpid()];
        [marker writeToFile:@"/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
        [marker writeToFile:@"/var/jb/var/mobile/hometapback_loaded.txt" atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    } @catch (...) {}
}
