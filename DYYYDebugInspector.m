//
//  DYYYDebugInspector.m
//  DYYY
//
//  全局扳手入口：独立高层级 window 承载调试按钮，点扳手导出整页快照。
//  移植自 DYKiller 0.7.1 DKDebugInspector，仅改前缀，并删掉两处 DYYY 不移植
//  的东西：
//  · 音频专项导出（DKAudioProbe / DKAudioRuntime 的采样与“导出音频专项 zip”
//    菜单项）——那是 DYKiller 音频可视化的配套探针，DYYY 没有这功能；
//  · DKTabBarProbe 的底栏诊断（probe/tabbar.txt）——改成主线程生成的通用
//    前台窗口一览（probe/windows.txt），找“面板在哪个窗口里”时直接看它。
//  没有点选检查：扳手菜单里只有“导出本页 zip”，永远整页快照。
//  没有定时器/轮询；开关变化只靠设置页 switchChangedBlock 与窗口变化钩子刷新。
//

#import "DYYYDebugInspector.h"
#import "DYYYDebugCapture.h"
#import "DYYYDebugExport.h"

NSString *const DYYYDebugInspectorEnabledKey = @"DYYYDebugInspectorEnabled";

/// 读总开关（未写过即 OFF，与上游 DKPrefBool 同款语义）。
static BOOL DYYYDebugInspectorEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:DYYYDebugInspectorEnabledKey];
}

@interface DYYYDebugOverlayView : UIView
@end

@implementation DYYYDebugOverlayView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

@end

@interface DYYYDebugOverlayWindow : UIWindow
@end

@interface DYYYDebugOverlayViewController : UIViewController
@property (nonatomic, strong) UIButton *wrenchButton;
@property (nonatomic, assign) BOOL didPlaceButton;
- (BOOL)capturesOverlayTouches;
- (void)exportWholePage;
@end

@implementation DYYYDebugOverlayWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    DYYYDebugOverlayViewController *controller = [self.rootViewController isKindOfClass:DYYYDebugOverlayViewController.class]
                                                 ? (DYYYDebugOverlayViewController *)self.rootViewController
                                                 : nil;
    if ([controller capturesOverlayTouches]) return [super pointInside:point withEvent:event];
    CGPoint p = [controller.wrenchButton convertPoint:point fromView:self];
    return [controller.wrenchButton pointInside:p withEvent:event];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    DYYYDebugOverlayViewController *controller = [self.rootViewController isKindOfClass:DYYYDebugOverlayViewController.class]
                                                 ? (DYYYDebugOverlayViewController *)self.rootViewController
                                                 : nil;
    if ([controller capturesOverlayTouches]) return hit ?: controller.view;
    if (!hit || hit == controller.view || hit == self) return nil;
    return hit;
}

@end

static DYYYDebugOverlayWindow *DYYYDebugWindow;
static DYYYDebugOverlayViewController *DYYYDebugController;
static BOOL DYYYDebugInstalled;
static BOOL DYYYDebugExportBusy;

#pragma mark - UI 工具

static BOOL DYYYIsDebugOverlayWindow(UIWindow *window) {
    return [NSStringFromClass(window.class) hasPrefix:@"DYYYDebug"];
}

static void DYYYPresentError(UIViewController *presenter, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导出失败"
                                                                       message:message ?: @"未知错误"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

// 把 underlying 与保留下来的工作目录一并展开：只显示顶层描述的话，
// ZIP 的 -3/-4/-5 三种失败在界面上长得一模一样，等于没有诊断。
static NSString *DYYYExportErrorMessage(NSError *error, NSString *fallback) {
    if (!error) return fallback;
    NSMutableString *message = [NSMutableString stringWithString:error.localizedDescription ?: fallback];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (underlying) {
        [message appendFormat:@"\n\n[%@ %ld] %@", underlying.domain ?: @"",
         (long)underlying.code, underlying.localizedDescription ?: @""];
    }
    NSString *workingDirectory = error.userInfo[DYYYDebugExportWorkingDirectoryKey];
    if (workingDirectory.length) {
        [message appendFormat:@"\n\n工作目录已保留:\n%@", workingDirectory];
    }
    return message;
}

static void DYYYShareExport(DYYYDebugExportResult *result, UIViewController *presenter, UIView *sourceView) {
    if (!result.zipURL) {
        DYYYDebugCleanupExport(result);
        DYYYPresentError(presenter, @"ZIP 文件不存在");
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[result.zipURL]
                                                                          applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = sourceView ?: presenter.view;
        activity.popoverPresentationController.sourceRect = (sourceView ?: presenter.view).bounds;
    }
    activity.completionWithItemsHandler = ^(__unused UIActivityType activityType,
                                            __unused BOOL completed,
                                            __unused NSArray *returnedItems,
                                            __unused NSError *activityError) {
        DYYYDebugCleanupExport(result);
    };
    [presenter presentViewController:activity animated:YES completion:nil];
}

static void DYYYSetProgress(UIAlertController *alert, NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        alert.message = text ?: @"处理中...";
    });
}

// 通用前台窗口一览（替代上游 DKTabBarProbeReport 的底栏诊断，写进 probe/windows.txt）。
// 必须在主线程调用（读 UIKit），后台导出只落盘。找“面板到底在哪个窗口里”时先看它。
static NSString *DYYYWindowSummaryText(void) {
    NSMutableString *text = [NSMutableString stringWithString:@"DYYY Debug Windows\n"];
    for (UIWindow *window in DYYYDebugActiveWindows()) {
        UIViewController *top = DYYYDebugTopPresenter(window);
        [text appendFormat:@"- %@ %p level=%.0f key=%@ frame=%@ rootVC=%@ topVC=%@\n",
         NSStringFromClass(window.class),
         (__bridge const void *)window,
         window.windowLevel,
         window.isKeyWindow ? @"YES" : @"NO",
         NSStringFromCGRect(window.frame),
         window.rootViewController ? NSStringFromClass(window.rootViewController.class) : @"",
         top ? NSStringFromClass(top.class) : @""];
    }
    return text;
}

static void DYYYCreateExportInBackground(DYYYDebugExportContext *context,
                                         DYYYDebugExportMode mode,
                                         UIAlertController *progressAlert) {
    UIViewController *presenter = context.presenter ?: DYYYDebugController;
    if (!presenter) {
        DYYYDebugExportBusy = NO;
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *exportError = nil;
        DYYYDebugExportResult *result = DYYYDebugCreateExport(context, mode, ^(NSString *text) {
            DYYYSetProgress(progressAlert, text);
        }, &exportError);
        dispatch_async(dispatch_get_main_queue(), ^{
            DYYYDebugExportBusy = NO;
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                if (result) {
                    DYYYShareExport(result, presenter, context.sourceView ?: presenter.view);
                } else {
                    DYYYPresentError(presenter, DYYYExportErrorMessage(exportError, @"没有生成 ZIP 文件"));
                }
            }];
        });
    });
}

static void DYYYStartExport(DYYYDebugExportContext *context, DYYYDebugExportMode mode) {
    UIViewController *presenter = context.presenter ?: DYYYDebugController;
    if (!presenter) return;
    if (DYYYDebugExportBusy) {
        DYYYPresentError(presenter, @"已有调试采集或导出正在进行");
        return;
    }
    DYYYDebugExportBusy = YES;

    // 探针读 UIKit，必须在主线程生成后塞进上下文；后台任务只做序列化与压缩。
    context.probeText = DYYYWindowSummaryText() ?: @"";

    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"DYYY Debug"
                                                                           message:@"准备导出..."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:progressAlert animated:YES completion:^{
        DYYYCreateExportInBackground(context, mode, progressAlert);
    }];
}

static UIWindowScene *DYYYDebugForegroundScene(void) {
    if (@available(iOS 13.0, *)) {
        UIWindow *target = DYYYDebugTargetWindow();
        if (target.windowScene) return target.windowScene;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static CGRect DYYYDebugScreenBounds(void) {
    UIWindow *target = DYYYDebugTargetWindow();
    if (target) return target.bounds;
    return UIScreen.mainScreen.bounds;
}

static void DYYYEnsureDebugWindow(void) {
    if (DYYYDebugWindow && DYYYDebugController) {
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = DYYYDebugForegroundScene();
            if (scene && DYYYDebugWindow.windowScene != scene) DYYYDebugWindow.windowScene = scene;
        }
        return;
    }

    DYYYDebugController = [DYYYDebugOverlayViewController new];
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = DYYYDebugForegroundScene();
        DYYYDebugWindow = scene ? [[DYYYDebugOverlayWindow alloc] initWithWindowScene:scene]
                                : [[DYYYDebugOverlayWindow alloc] initWithFrame:DYYYDebugScreenBounds()];
    } else {
        DYYYDebugWindow = [[DYYYDebugOverlayWindow alloc] initWithFrame:DYYYDebugScreenBounds()];
    }
    DYYYDebugWindow.backgroundColor = UIColor.clearColor;
    DYYYDebugWindow.opaque = NO;
    DYYYDebugWindow.windowLevel = UIWindowLevelAlert + 100000.0;
    DYYYDebugWindow.rootViewController = DYYYDebugController;
    DYYYDebugWindow.hidden = YES;
}

#pragma mark - 浮层控制器

@implementation DYYYDebugOverlayViewController

- (void)loadView {
    DYYYDebugOverlayView *view = [[DYYYDebugOverlayView alloc] initWithFrame:DYYYDebugScreenBounds()];
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.wrenchButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.wrenchButton.frame = CGRectMake(0, 0, 48, 48);
    self.wrenchButton.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.82];
    self.wrenchButton.tintColor = UIColor.whiteColor;
    self.wrenchButton.layer.cornerRadius = 24;
    self.wrenchButton.layer.shadowColor = UIColor.blackColor.CGColor;
    self.wrenchButton.layer.shadowOpacity = 0.24;
    self.wrenchButton.layer.shadowRadius = 8;
    self.wrenchButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.wrenchButton.accessibilityLabel = @"DYYY Debug";

    UIImage *image = nil;
    if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) image = [UIImage systemImageNamed:@"wrench.fill"];
    if (image) {
        [self.wrenchButton setImage:image forState:UIControlStateNormal];
    } else {
        [self.wrenchButton setTitle:@"W" forState:UIControlStateNormal];
        self.wrenchButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    }
    [self.wrenchButton addTarget:self action:@selector(showDebugMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.wrenchButton];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleWrenchPan:)];
    [self.wrenchButton addGestureRecognizer:pan];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.didPlaceButton) {
        UIEdgeInsets insets = self.view.safeAreaInsets;
        CGFloat x = self.view.bounds.size.width - insets.right - 12.0 - 24.0;
        CGFloat y = insets.top + 12.0 + 24.0;
        self.wrenchButton.center = CGPointMake(x, y);
        self.didPlaceButton = YES;
    }
    [self clampWrenchButton];
}

- (void)clampWrenchButton {
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat halfW = self.wrenchButton.bounds.size.width / 2.0;
    CGFloat halfH = self.wrenchButton.bounds.size.height / 2.0;
    CGFloat minX = insets.left + halfW + 6.0;
    CGFloat maxX = self.view.bounds.size.width - insets.right - halfW - 6.0;
    CGFloat minY = insets.top + halfH + 6.0;
    CGFloat maxY = self.view.bounds.size.height - insets.bottom - halfH - 6.0;
    CGPoint c = self.wrenchButton.center;
    c.x = MIN(MAX(c.x, minX), maxX);
    c.y = MIN(MAX(c.y, minY), maxY);
    self.wrenchButton.center = c;
}

- (void)handleWrenchPan:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self.view];
    self.wrenchButton.center = CGPointMake(self.wrenchButton.center.x + delta.x,
                                           self.wrenchButton.center.y + delta.y);
    [pan setTranslation:CGPointZero inView:self.view];
    [self clampWrenchButton];
}

- (void)showDebugMenu {
    if (!DYYYDebugInspectorEnabled()) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"DYYY Debug"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"导出本页 zip"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self exportWholePage];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.wrenchButton;
        alert.popoverPresentationController.sourceRect = self.wrenchButton.bounds;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportWholePage {
    UIWindow *targetWindow = DYYYDebugTargetWindow();
    if (!targetWindow) {
        DYYYPresentError(self, @"没有找到可导出的 App 窗口");
        return;
    }

    // 调试浮层始终置顶、无需选元素：直接快照整页（selectedView=nil 即整窗）。
    DYYYDebugExportContext *context = DYYYDebugCaptureContext(targetWindow, CGPointZero, nil);
    context.presenter = self;
    context.sourceView = self.wrenchButton;
    DYYYStartExport(context, DYYYDebugExportModePage);
}

- (BOOL)capturesOverlayTouches {
    return self.presentedViewController != nil;
}

@end

#pragma mark - 对外入口

void DYYYDebugInspectorRefreshOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL enabled = DYYYDebugInspectorEnabled();
        if (!enabled) {
            if (DYYYDebugWindow) {
                DYYYDebugWindow.hidden = YES;
                [DYYYDebugTargetWindow() makeKeyWindow];
            }
            return;
        }

        DYYYEnsureDebugWindow();
        DYYYDebugWindow.frame = DYYYDebugScreenBounds();
        DYYYDebugWindow.hidden = NO;
        UIWindow *targetWindow = DYYYDebugTargetWindow();
        if (targetWindow && !targetWindow.isKeyWindow) [targetWindow makeKeyWindow];
    });
}

void DYYYDebugInspectorInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (DYYYDebugInstalled) {
            DYYYDebugInspectorRefreshOverlay();
            return;
        }
        DYYYDebugInstalled = YES;

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (DYYYIsDebugOverlayWindow((UIWindow *)note.object)) return;
            DYYYDebugInspectorRefreshOverlay();
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            DYYYDebugInspectorRefreshOverlay();
        }];
        DYYYDebugInspectorRefreshOverlay();
    });
}
