// DYYYLiveBoardCapsule.m — 见 DYYYLiveBoardCapsule.h。
// 2.2-9-92：直播间左上角“人气榜”小胶囊按钮（用户 2026-11-11 23:36 选方案一）。
// 挂载与位置做法照抄 -7 开播时长胶囊（DYYY.xm）：
//   挂在 audienceVC.view 上，associated object 挂在 root 上；
//   位置按中心百分比存 NSUserDefaults，横竖屏分别记；
//   默认位置在左上角主播名下方（安全区顶部 +120 / 横屏 +46，悬浮榜同款
//   找不到时长胶囊时的 fallback 位置——时长胶囊在 safeTop+86，胶囊
//   在 +120 不会跟它重叠；不按 accessibilityIdentifier 找任何原生视图，
//   -85..-90 找视图的路已经证明不可靠）。
// 样式（2.2-9-98）：黑色半透明底 + 白字，跟抖音原生“人气榜”胶囊
// 一致；背景透明度与字号由用户在设置页调——键
// DYYYLiveBoardCapsuleBackgroundOpacityKey（0.10–1.00，默认 0.42）与
// DYYYLiveBoardCapsuleFontSizeKey（11–18pt，默认 13），默认值即 -97
// 的样子；高度 = 字号 + 13，圆角 = 高度 / 2。改动实时生效：设置页
// 写键即发 StoreChanged，watcher 重走 InstallOnView 调 applyStyle，
// 胶囊自己的 1 秒 tick 也每跳调一次 applyStyle（只在值变了才打日志）。
// 拖动、位置记忆、跟清屏走、只认总开关一律不动。
// 内部布局用 Auto Layout，不在 layoutSubviews 里改帧（-53/-57 教训）；
// 胶囊自身的 frame 只在安装/拖动结束时直接赋值。
// 清屏跟藏：DYYY 一键清屏走 DYYYRefreshViewsAfterClearToggle（按 identifier，
// 见 DYYYFloatClearButton.xm）；抖音原生清屏走每秒 tick 里的可见标签启发式
// （-80 同款，DYYYLiveBoardRootHasVisibleNativeLabel 在 Overlay.m 里公开；
// 胶囊自己的 label 已加进那条启发式的跳过清单，不会把自己算成房间 UI）。
#import "DYYYLiveBoardCapsule.h"
#import "DYYYLiveBoardAudienceEntry.h"
#import "DYYYLiveBoardModel.h"
#import "DYYYLiveBoardOverlay.h"
#import "DYYYLiveBoardStore.h"
#import "DYYYFloatClearButton.h"
#import "DYYYUtils.h"
#import <objc/message.h>
#import <objc/runtime.h>

static const void *kDYYYLiveBoardCapsuleViewKey = &kDYYYLiveBoardCapsuleViewKey;
static NSString *const kDYYYLiveBoardCapsuleCenterXPercentKey = @"DYYYLiveBoardCapsuleCenterXPercent";
static NSString *const kDYYYLiveBoardCapsuleCenterYPercentKey = @"DYYYLiveBoardCapsuleCenterYPercent";
static NSString *const kDYYYLiveBoardCapsuleLandscapeCenterXPercentKey = @"DYYYLiveBoardCapsuleLandscapeCenterXPercent";
static NSString *const kDYYYLiveBoardCapsuleLandscapeCenterYPercentKey = @"DYYYLiveBoardCapsuleLandscapeCenterYPercent";
static __weak UIView *sDYYYLiveBoardCapsuleLastRoot;
static id sDYYYLiveBoardCapsuleWatcherToken;
@class DYYYLiveBoardCapsuleView;
// 2.2-9-96：全局单例——同一时刻最多一个胶囊。安装点（容器/wrapper/
// inner feed cell/房间 VC）可能解析到同一房间的不同 root 视图，
// 只靠每个 root 自己的 associated object 去重会在两张 root 上各装
// 一个（用户截图：两个“人气榜”胶囊，一张上下叠、一张左右并排）。
static __weak DYYYLiveBoardCapsuleView *sDYYYLiveBoardCapsuleGlobal;

#pragma mark - 位置（照抄时长胶囊的钳制/百分比存取）

static UIEdgeInsets DYYYLiveBoardCapsuleSafeInsets(UIView *root) {
    return [root respondsToSelector:@selector(safeAreaInsets)] ? root.safeAreaInsets : UIEdgeInsetsZero;
}

static CGPoint DYYYLiveBoardCapsuleClampedCenter(CGPoint center, CGSize viewSize, UIView *root) {
    if (!root) return center;
    UIEdgeInsets safeInsets = DYYYLiveBoardCapsuleSafeInsets(root);
    CGFloat halfWidth = viewSize.width / 2.0;
    CGFloat halfHeight = viewSize.height / 2.0;
    CGFloat minX = safeInsets.left + halfWidth + 4.0;
    CGFloat maxX = fmax(minX, CGRectGetWidth(root.bounds) - safeInsets.right - halfWidth - 4.0);
    CGFloat minY = safeInsets.top + halfHeight + 4.0;
    CGFloat maxY = fmax(minY, CGRectGetHeight(root.bounds) - safeInsets.bottom - halfHeight - 4.0);
    return CGPointMake(fmin(fmax(center.x, minX), maxX), fmin(fmax(center.y, minY), maxY));
}

static CGRect DYYYLiveBoardCapsuleDefaultFrame(UIView *root) {
    UIEdgeInsets safeInsets = DYYYLiveBoardCapsuleSafeInsets(root);
    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    BOOL isLandscape = rootWidth > rootHeight;
    // 2.2-9-98：字号与高度走设置（默认 13pt → 高 26，与 -97 相同）。
    CGFloat fontSize = (CGFloat)[DYYYLiveBoardStore.shared capsuleFontSize];
    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightMedium];
    CGSize textSize = [@"人气榜" sizeWithAttributes:@{NSFontAttributeName : font}];
    CGFloat width = ceil(textSize.width + 20.0);
    CGFloat height = fontSize + 13.0;
    CGFloat minX = safeInsets.left + 4.0;
    CGFloat maxX = fmax(minX, rootWidth - safeInsets.right - width - 4.0);
    CGFloat minY = safeInsets.top + 4.0;
    CGFloat maxY = fmax(minY, rootHeight - safeInsets.bottom - height - 4.0);
    CGFloat x = fmin(fmax(safeInsets.left + 12.0, minX), maxX);
    CGFloat y = fmin(fmax(safeInsets.top + (isLandscape ? 46.0 : 120.0), minY), maxY);
    return CGRectIntegral(CGRectMake(x, y, width, height));
}

#pragma mark - 胶囊视图

@interface DYYYLiveBoardCapsuleView : UIView
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, assign, getter=isDragging) BOOL dragging;
@property(nonatomic, assign, getter=isHiddenByNativeClear) BOOL hiddenByNativeClear;
@property(nonatomic, assign) NSInteger nativeClearGraceTicks;
@property(nonatomic, strong, nullable) NSTimer *tickTimer;
// 2.2-9-98：上次已应用的样式值，applyStyle 只在值变了才打日志（tick 每秒调一次，不刷屏）。
@property(nonatomic, assign) double lastAppliedOpacity;
@property(nonatomic, assign) double lastAppliedFontSize;
- (void)applyStyle;
- (void)startTick;
- (void)stopTick;
- (CGRect)frameByApplyingSavedPositionToFrame:(CGRect)frame inRoot:(UIView *)root;
@end

@implementation DYYYLiveBoardCapsuleView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = YES;
        // 2.2-9-98：样式走设置（applyStyle 现读），默认值即 -97 的样子
        // （黑底 0.42、白字 13pt、圆角 13）；0.5pt 白描边不动。
        self.layer.masksToBounds = YES;
        self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25].CGColor;
        self.layer.borderWidth = 0.5;
        self.accessibilityIdentifier = @"dyyy_live_board_capsule";

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.text = @"人气榜";
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.75;
        _titleLabel.shadowColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        _titleLabel.shadowOffset = CGSizeMake(0.0, 1.0);
        [self addSubview:_titleLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:7.0],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-7.0],
        ]];
        // 样式定稿（背景透明度/字号/白字/圆角/尺寸）全在 applyStyle 里；
        // init 时还没有 superview，只定颜色字号圆角，尺寸等装上后再算。
        [self applyStyle];

        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tapGesture];
        UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:panGesture];

        // 2.2-9-80 同款宽限：进房间时 UI 还没铺好，第一跳可能暂时没标签。
        _nativeClearGraceTicks = 1;
    }
    return self;
}

// 2.2-9-98：按设置重算样式并实时生效。背景黑底透明度与字号现读
// store（默认值即 -97 的样子）；高度 = 字号 + 13，圆角 = 高度 / 2，
// 宽度按当前字号的文字宽 + 20；中心不动（拖动记的位置不丢），只在
// 有 superview 且不在拖动时改 frame——拖动中只改颜色字号，松手后
// 下一跳再改尺寸。只在值变了才打 [DYYY-98] 日志，tick 每秒调一次
// 也不刷屏；字色每次都显式重申白色（-97 查清：全库只有这里改
// _titleLabel 的颜色，-96 真机黑字的同款是 -85 入口按钮）。
- (void)applyStyle {
    double opacity = [DYYYLiveBoardStore.shared capsuleBackgroundOpacity];
    double fontSize = [DYYYLiveBoardStore.shared capsuleFontSize];
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:(CGFloat)opacity];
    self.titleLabel.font = [UIFont systemFontOfSize:(CGFloat)fontSize weight:UIFontWeightMedium];
    self.titleLabel.textColor = [UIColor whiteColor];
    CGFloat height = (CGFloat)fontSize + 13.0;
    self.layer.cornerRadius = height / 2.0;
    UIView *root = self.superview;
    if (root && !self.isDragging) {
        CGSize textSize = [@"人气榜" sizeWithAttributes:@{NSFontAttributeName : self.titleLabel.font}];
        CGFloat width = ceil(textSize.width + 20.0);
        CGPoint center = self.center;
        self.frame = CGRectIntegral(CGRectMake(center.x - width / 2.0, center.y - height / 2.0, width, height));
        self.center = DYYYLiveBoardCapsuleClampedCenter(self.center, self.bounds.size, root);
    }
    if (fabs(opacity - self.lastAppliedOpacity) > 0.001 || fabs(fontSize - self.lastAppliedFontSize) > 0.001) {
        NSLog(@"[DYYY-98] applyStyle: bg %.2f, font %.0f", opacity, fontSize);
        self.lastAppliedOpacity = opacity;
        self.lastAppliedFontSize = fontSize;
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    UIView *root = self.superview;
    if (!root) return;
    UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:root];
    if (!vc) {
        NSLog(@"[DYYY-92] tap: no view controller for room view");
        return;
    }
    NSLog(@"[DYYY-93] tap: opening compact board");
    DYYYLiveBoardPresentCompactBoardFromViewController(vc);
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *root = self.superview;
    if (!root) return;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        self.alpha = 0.8;
    }
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:root];
        CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        self.center = DYYYLiveBoardCapsuleClampedCenter(newCenter, self.bounds.size, root);
        [gesture setTranslation:CGPointZero inView:root];
    }
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        self.dragging = NO;
        self.alpha = 1.0;
        [self savePosition];
        NSLog(@"[DYYY-92] dragged to (%.0f, %.0f)", self.center.x, self.center.y);
    }
}

// 横竖屏分别记位置（时长胶囊同款做法）。竖屏用旧的两个键，横屏用新加的两个键。
- (NSString *)centerXPercentKeyForRoot:(UIView *)root {
    return CGRectGetWidth(root.bounds) > CGRectGetHeight(root.bounds)
        ? kDYYYLiveBoardCapsuleLandscapeCenterXPercentKey : kDYYYLiveBoardCapsuleCenterXPercentKey;
}

- (NSString *)centerYPercentKeyForRoot:(UIView *)root {
    return CGRectGetWidth(root.bounds) > CGRectGetHeight(root.bounds)
        ? kDYYYLiveBoardCapsuleLandscapeCenterYPercentKey : kDYYYLiveBoardCapsuleCenterYPercentKey;
}

- (void)savePosition {
    UIView *root = self.superview;
    if (!root) return;
    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    if (rootWidth <= 0.0 || rootHeight <= 0.0) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:self.center.x / rootWidth forKey:[self centerXPercentKeyForRoot:root]];
    [defaults setDouble:self.center.y / rootHeight forKey:[self centerYPercentKeyForRoot:root]];
}

- (CGRect)frameByApplyingSavedPositionToFrame:(CGRect)frame inRoot:(UIView *)root {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *xKey = [self centerXPercentKeyForRoot:root];
    NSString *yKey = [self centerYPercentKeyForRoot:root];
    if (![defaults objectForKey:xKey] || ![defaults objectForKey:yKey]) return frame;
    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    if (rootWidth <= 0.0 || rootHeight <= 0.0) return frame;
    CGFloat centerXPercent = fmin(fmax([defaults doubleForKey:xKey], 0.0), 1.0);
    CGFloat centerYPercent = fmin(fmax([defaults doubleForKey:yKey], 0.0), 1.0);
    CGPoint center = CGPointMake(centerXPercent * rootWidth, centerYPercent * rootHeight);
    center = DYYYLiveBoardCapsuleClampedCenter(center, frame.size, root);
    return CGRectIntegral(CGRectMake(center.x - frame.size.width / 2.0, center.y - frame.size.height / 2.0, frame.size.width, frame.size.height));
}

#pragma mark - 每秒 tick（只跟清屏，不做网络请求）

// 2.2-9-80 同款：原生清屏跟随。DYYY 清屏激活时直接让位（hidden 归
// DYYYRefreshViewsAfterClearToggle 那条路管，本方法不记录也不改状态，
// DYYY 清屏退出后下一跳重新算）。
- (void)updateNativeClearState {
    if (DYYYClearButtonIsHiding()) return;
    UIView *root = self.superview;
    if (!root) return;
    BOOL hasLabel = DYYYLiveBoardRootHasVisibleNativeLabel(root);
    if (self.nativeClearGraceTicks > 0) {
        self.nativeClearGraceTicks--;
        if (hasLabel) return;
        if (self.nativeClearGraceTicks > 0) return;
        // 宽限刚用完仍无标签：往下走，藏起来。
    }
    BOOL cleared = !hasLabel;
    if (cleared == self.isHiddenByNativeClear) return;
    self.hiddenByNativeClear = cleared;
    self.hidden = cleared;
}

- (void)startTick {
    [self stopTick];
    __weak typeof(self) weakSelf = self;
    self.tickTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        DYYYLiveBoardCapsuleView *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.window) return;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        [strongSelf updateNativeClearState];
        // 2.2-9-98：设置页改了胶囊样式后 1 秒内跟上（StoreChanged 的
        // watcher 重走 InstallOnView 也会调 applyStyle，两条路互为兜底）。
        [strongSelf applyStyle];
        if (strongSelf.isDragging) return;
        UIView *root = strongSelf.superview;
        if (root && root.subviews.lastObject != strongSelf) [root bringSubviewToFront:strongSelf];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.tickTimer forMode:NSRunLoopCommonModes];
}

- (void)stopTick {
    [self.tickTimer invalidate];
    self.tickTimer = nil;
}

@end

#pragma mark - 安装 / 拆除

void DYYYLiveBoardCapsuleInstallOnView(UIView *root) {
    if (!root) return;
    // 记住最后一次见到的房间 root（弱引用），StoreChanged 的 watcher 补装用。
    sDYYYLiveBoardCapsuleLastRoot = root;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardCapsuleInstallOnView(root); });
        return;
    }
    DYYYLiveBoardCapsuleView *capsule = objc_getAssociatedObject(root, kDYYYLiveBoardCapsuleViewKey);
    if (![DYYYLiveBoardStore.shared enabled]) {
        if (capsule) {
            [capsule stopTick];
            [capsule removeFromSuperview];
            objc_setAssociatedObject(root, kDYYYLiveBoardCapsuleViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
            NSLog(@"[DYYY-92] removed: board disabled");
        }
        if (sDYYYLiveBoardCapsuleGlobal == capsule) sDYYYLiveBoardCapsuleGlobal = nil;
        return;
    }
    // 2.2-9-96：全局去重——同一时刻最多一个胶囊。先处理已在别的
    // root 上的胶囊，再按本 root 装。
    DYYYLiveBoardCapsuleView *global = sDYYYLiveBoardCapsuleGlobal;
    if (global && global.superview && global.superview != root) {
        UIView *oldRoot = global.superview;
        [global stopTick];
        [global removeFromSuperview];
        objc_setAssociatedObject(oldRoot, kDYYYLiveBoardCapsuleViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
        sDYYYLiveBoardCapsuleGlobal = nil;
        NSLog(@"[DYYY-96] removed capsule from other root, installing on new root");
        global = nil;
    }
    if (global && global.superview == root) {
        // 本 root 上已有全局胶囊：复用它，顺手拆掉 associated object
        // 里可能残留的第二个实例。
        if (capsule && capsule != global) {
            [capsule stopTick];
            [capsule removeFromSuperview];
        }
        capsule = global;
        objc_setAssociatedObject(root, kDYYYLiveBoardCapsuleViewKey, capsule, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!capsule || capsule.superview != root) {
        capsule = [[DYYYLiveBoardCapsuleView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(root, kDYYYLiveBoardCapsuleViewKey, capsule, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [root addSubview:capsule];
        CGRect frame = DYYYLiveBoardCapsuleDefaultFrame(root);
        capsule.frame = [capsule frameByApplyingSavedPositionToFrame:frame inRoot:root];
        NSLog(@"[DYYY-98] capsule added (bg/font from settings)");
    }
    // 2.2-9-98：新建与复用都走一遍 applyStyle——设置页改值后
    // StoreChanged 的 watcher 重走 InstallOnView，胶囊实时变样式。
    [capsule applyStyle];
    sDYYYLiveBoardCapsuleGlobal = capsule;
    [root bringSubviewToFront:capsule];
    // 2.2-9-80 同款：DYYY 清屏已激活时才装上的胶囊也要跟着藏。
    if (DYYYClearButtonIsHiding()) capsule.hidden = YES;
    else capsule.hidden = capsule.isHiddenByNativeClear;
    [capsule startTick];
}

void DYYYLiveBoardCapsuleRemoveFromView(UIView *root) {
    if (!root) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardCapsuleRemoveFromView(root); });
        return;
    }
    DYYYLiveBoardCapsuleView *capsule = objc_getAssociatedObject(root, kDYYYLiveBoardCapsuleViewKey);
    [capsule stopTick];
    [capsule removeFromSuperview];
    objc_setAssociatedObject(root, kDYYYLiveBoardCapsuleViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    if (sDYYYLiveBoardCapsuleGlobal == capsule) sDYYYLiveBoardCapsuleGlobal = nil;
}

static UIViewController *DYYYLiveBoardCapsuleAudienceVC(id container) {
    UIViewController *viewController = nil;
    @try {
        viewController = [container valueForKey:@"audienceVC"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if (![viewController isKindOfClass:UIViewController.class] && [container respondsToSelector:@selector(audienceViewController)]) {
        @try {
            viewController = ((id (*)(id, SEL))objc_msgSend)(container, @selector(audienceViewController));
        } @catch (__unused NSException *exception) {
            viewController = nil;
        }
    }
    return [viewController isKindOfClass:UIViewController.class] ? viewController : nil;
}

void DYYYLiveBoardCapsuleInstallFromContainer(id container) {
    UIViewController *viewController = DYYYLiveBoardCapsuleAudienceVC(container);
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardCapsuleInstallOnView(viewController.view);
}

void DYYYLiveBoardCapsuleInstallFromAudienceWrapper(id wrapper) {
    UIViewController *viewController = nil;
    @try {
        viewController = [wrapper valueForKey:@"audienceViewController"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardCapsuleInstallOnView(viewController.view);
}

void DYYYLiveBoardCapsuleInstallFromInnerFeedCell(id cell) {
    UIViewController *viewController = nil;
    @try {
        viewController = [cell valueForKey:@"audienceVC"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardCapsuleInstallOnView(viewController.view);
}

void DYYYLiveBoardCapsuleRemoveFromContainer(id container) {
    UIViewController *viewController = DYYYLiveBoardCapsuleAudienceVC(container);
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardCapsuleRemoveFromView(viewController.view);
}

void DYYYLiveBoardCapsuleRemoveFromAudienceWrapper(id wrapper) {
    UIViewController *viewController = nil;
    @try {
        viewController = [wrapper valueForKey:@"audienceViewController"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardCapsuleRemoveFromView(viewController.view);
}

void DYYYLiveBoardCapsuleRemoveFromInnerFeedCell(id cell) {
    UIViewController *viewController = nil;
    @try {
        viewController = [cell valueForKey:@"audienceVC"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardCapsuleRemoveFromView(viewController.view);
}

// 房间里改了总开关后，给正在开着的房间补装悬浮榜同款 watcher
// （只在 lastRoot 还在窗口里时装；安装本身幂等）。
void DYYYLiveBoardCapsuleStartWatcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDYYYLiveBoardCapsuleWatcherToken = [NSNotificationCenter.defaultCenter addObserverForName:DYYYLiveBoardStoreChanged object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            UIView *root = sDYYYLiveBoardCapsuleLastRoot;
            if (!root || !root.window) return;
            DYYYLiveBoardCapsuleInstallOnView(root);
        }];
    });
}
