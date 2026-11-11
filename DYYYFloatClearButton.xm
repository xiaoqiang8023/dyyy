/*
 * Tweak Name: 1KeyHideDYUI
 * Target App: com.ss.iphone.ugc.Aweme
 * Dev: @c00kiec00k 曲奇的坏品味🍻
 * iOS Version: 16.5
 */
#import "DYYYFloatSpeedButton.h"
#import "DYYYFloatClearButton.h"
#import "DYYYUtils.h"
#import "DYYYLiveBoardStore.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <signal.h>

void updateClearButtonVisibility(void);
void showClearButton(void);
void hideClearButton(void);

BOOL isInPlayInteractionVC = NO;
BOOL isPureViewVisible = NO;
BOOL clearButtonForceHidden = NO;
BOOL isAppActive = YES;
BOOL dyyyIsPerformingFloatClearOperation = NO;

static NSInteger dyyyClearButtonMutationDepth = 0;

static inline void DYYYBeginClearButtonMutation(void) {
    dyyyClearButtonMutationDepth++;
    dyyyIsPerformingFloatClearOperation = YES;
}

static inline void DYYYEndClearButtonMutation(void) {
    if (dyyyClearButtonMutationDepth > 0) {
        dyyyClearButtonMutationDepth--;
    }
    dyyyIsPerformingFloatClearOperation = dyyyClearButtonMutationDepth > 0;
}

static void DYYYPerformClearButtonMutation(dispatch_block_t block) {
    if (!block) {
        return;
    }
    DYYYBeginClearButtonMutation();
    @try {
        block();
    } @finally {
        DYYYEndClearButtonMutation();
    }
}


HideUIButton *hideButton;
BOOL isAppInTransition = NO;
NSArray *targetClassNames;
static CGFloat DYGetGlobalAlpha(void) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYGlobalTransparency"];
    CGFloat a = value.length ? value.floatValue : 1.0;
    return (a >= 0.0 && a <= 1.0) ? a : 1.0;
}
static void findViewsOfClassHelper(UIView *view, Class viewClass, NSMutableArray *result) {
    if ([view isKindOfClass:viewClass]) {
        [result addObject:view];
    }
    for (UIView *subview in view.subviews) {
        findViewsOfClassHelper(subview, viewClass, result);
    }
}
UIWindow *getKeyWindow(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    return keyWindow;
}

static void DYYYApplyClearButtonHiddenState(HideUIButton *button, BOOL hidden) {
    if (!button) {
        return;
    }
    void (^applyBlock)(HideUIButton *) = ^(HideUIButton *target) {
        if (!target) {
            return;
        }
        if (target.hidden != hidden) {
            target.hidden = hidden;
        }
    };

    if ([NSThread isMainThread]) {
        applyBlock(button);
    } else {
        __weak HideUIButton *weakButton = button;
        dispatch_async(dispatch_get_main_queue(), ^{
            applyBlock(weakButton);
        });
    }
}

static BOOL DYYYShouldHideClearButton(void) {
    BOOL clearModeActive = (hideButton && hideButton.isElementsHidden);
    if (clearModeActive) {
        if (!isAppActive) {
            return YES;
        }
        return clearButtonForceHidden;
    }
    if (!isAppActive) {
        return YES;
    }
    if (!dyyyInteractionViewVisible) {
        return YES;
    }
    if (dyyyCommentViewVisible) {
        return YES;
    }
    if (isPureViewVisible) {
        return YES;
    }
    if (clearButtonForceHidden) {
        return YES;
    }
    return NO;
}

void updateClearButtonVisibility() {
    if (!hideButton) {
        return;
    }
    DYYYApplyClearButtonHiddenState(hideButton, DYYYShouldHideClearButton());
}

void showClearButton(void) {
    clearButtonForceHidden = NO;
    updateClearButtonVisibility(); // Call the central visibility logic
}

void hideClearButton(void) {
    clearButtonForceHidden = YES;
    updateClearButtonVisibility();
}

// 2.2-9-80：悬浮榜读 DYYY 清屏是否激活。注意 DYYY 的圆形清屏按钮
// 只在推荐页可见（dyyyInteractionViewVisible 只在
// AWEPlayInteractionViewController 里置 YES），直播间里按不到它，
// 但它一旦在推荐页点下，isElementsHidden 会一直保持到再点一次——
// 这期间进直播间新装上的面板也要跟着藏，不能默认显示出来。
BOOL DYYYClearButtonIsHiding(void) {
    return hideButton && hideButton.isElementsHidden;
}

static void forceResetAllUIElements(void) {
    DYYYPerformClearButtonMutation(^{
        UIWindow *window = getKeyWindow();
        if (!window)
            return;
        Class StackViewClass = NSClassFromString(@"AWEElementStackView");
        for (NSString *className in targetClassNames) {
            Class viewClass = NSClassFromString(className);
            if (!viewClass)
                continue;
            NSMutableArray *views = [NSMutableArray array];
            findViewsOfClassHelper(window, viewClass, views);
            for (UIView *view in views) {
                if ([view isKindOfClass:NSClassFromString(@"AWEAwemePlayVideoPauseIcon")]) {
                    view.hidden = NO;
                } else if ([view isKindOfClass:StackViewClass]) {
                    view.alpha = 1.0; // 基础透明度交给全局透明度处理，避免重复乘
                } else {
                    view.alpha = 1.0; // 恢复透明度
                }
            }
        }
    });
}
static void reapplyHidingToAllElements(HideUIButton *button) {
    if (!button || !button.isElementsHidden)
        return;
    [button hideUIElements];
}
void initTargetClassNames(void) {
    NSMutableArray<NSString *> *list = [@[
        @"AWEHPTopBarCTAContainer", @"AWEHPDiscoverFeedEntranceView", @"AWELeftSideBarEntranceView", @"DUXBadge", @"AWEBaseElementView", @"AWEElementStackView", @"AWEPlayInteractionDescriptionLabel",
        @"AWEUserNameLabel", @"ACCEditTagStickerView", @"AWEFeedTemplateAnchorView", @"AWESearchFeedTagView", @"AWEPlayInteractionSearchAnchorView", @"AFDRecommendToFriendTagView",
        @"AWELandscapeFeedEntryView", @"AWEFeedAnchorContainerView", @"AFDAIbumFolioView", @"DUXPopover", @"AWEMixVideoPanelMoreView", @"AWEHotSearchInnerBottomView", @"AWEHPSegmentControlScrollView"
    ] mutableCopy];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideTabBar"]) {
        [list addObject:@"AWENormalModeTabBar"];
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideDanmaku"]) {
        [list addObject:@"AWEVideoPlayDanmakuContainerView"];
        [list addObject:@"AWEDanmakuContainerView"];
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideSlider"]) {
        [list addObject:@"AWEStoryProgressSlideView"];
        [list addObject:@"AWEStoryProgressContainerView"];
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideChapter"]) {
        [list addObject:@"AWEDemaciaChapterProgressSlider"];
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHidePauseVideoIcon"]) {
        // 视频中央的播放/暂停图标（Wtrwx 同名开关；huami 清屏时才隐藏，见 findAndHideViews 的 hidden 处理）
        [list addObject:@"AWEAwemePlayVideoPauseIcon"];
    }

    targetClassNames = [list copy];
}
// 2.2-9-9 新增：清屏切换后刷新状态栏与时长小条
// - 状态栏：清屏隐藏状态栏开关开着、且全局隐藏顶栏关着时，通知所有 window 的 VC 重新评估状态栏显隐
// - 时长小条：按 accessibilityIdentifier 找到时长视图，清屏时立即隐藏、退出时立即恢复（仍受 DYYYShowLiveDuration 开关控制；
//   计时器每秒的 UpdateView 也会按 hideButton 状态纠正一次，所以这里只做立即刷新，不改变时长逻辑）
// - 2.2-9-72：悬浮人气榜同款处理（identifier dyyy_live_board_overlay_view，
//   仍受总开关 + 悬浮开关控制；悬浮榜自己的通知刷新只改内容，不碰 hidden）
static void DYYYRefreshViewsAfterClearToggle(BOOL isCleared) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideStatusBarOnClear"] &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideStatusbar"]) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            UIViewController *rootVC = window.rootViewController;
            if (!rootVC) continue;
            [rootVC setNeedsStatusBarAppearanceUpdate];
            for (UIViewController *child in rootVC.childViewControllers) {
                [child setNeedsStatusBarAppearanceUpdate];
            }
        }
    }
    BOOL durationOn = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYShowLiveDuration"];
    BOOL overlayOn = [DYYYLiveBoardStore.shared enabled] && [DYYYLiveBoardStore.shared overlayEnabled];
    // 2.2-9-92：人气榜小胶囊（identifier dyyy_live_board_capsule），只认总开关。
    BOOL capsuleOn = [DYYYLiveBoardStore.shared enabled];
    if (!durationOn && !overlayOn && !capsuleOn) {
        return;
    }
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        // 递归查找时长小条 / 悬浮人气榜（identifier 由视图自身设置）
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count > 0) {
            UIView *view = [stack lastObject];
            [stack removeLastObject];
            if (durationOn && [view.accessibilityIdentifier isEqualToString:@"dyyy_live_duration_view"]) {
                view.hidden = isCleared;
                continue;
            }
            if (overlayOn && [view.accessibilityIdentifier isEqualToString:@"dyyy_live_board_overlay_view"]) {
                view.hidden = isCleared;
                continue;
            }
            // 2.2-9-75：右滑隐藏后留下的“人气榜”小标签（identifier
            // dyyy_live_board_overlay_tab），清屏时跟面板一起藏、退出
            // 清屏一起恢复；面板没藏着时小标签根本不在界面上，这里是 no-op。
            if (overlayOn && [view.accessibilityIdentifier isEqualToString:@"dyyy_live_board_overlay_tab"]) {
                view.hidden = isCleared;
                continue;
            }
            // 2.2-9-77：左边缘隐形条（identifier dyyy_live_board_overlay_edge），
            // 只在面板藏着时存在，清屏联动与小标签同款。
            if (overlayOn && [view.accessibilityIdentifier isEqualToString:@"dyyy_live_board_overlay_edge"]) {
                view.hidden = isCleared;
                continue;
            }
            // 2.2-9-92：人气榜小胶囊（identifier dyyy_live_board_capsule），
            // 清屏时跟时长胶囊一起藏、退出清屏一起恢复；只认总开关。
            if (capsuleOn && [view.accessibilityIdentifier isEqualToString:@"dyyy_live_board_capsule"]) {
                view.hidden = isCleared;
                continue;
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

@implementation HideUIButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.masksToBounds = YES;
        self.isElementsHidden = NO;
        self.hiddenViewsList = [NSMutableArray array];

        self.originalAlpha = 1.0;
        self.alpha = 0.5;
        
        [self loadLockState];
        [self loadIcons];
        [self setImage:self.showIcon forState:UIControlStateNormal];
        
        UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:panGesture];
        
        [self addTarget:self action:@selector(handleTap) forControlEvents:UIControlEventTouchUpInside];
        [self addTarget:self action:@selector(handleTouchDown) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(handleTouchUpInside) forControlEvents:UIControlEventTouchUpInside];
        [self addTarget:self action:@selector(handleTouchUpOutside) forControlEvents:UIControlEventTouchUpOutside];
        
        UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        [self addGestureRecognizer:longPressGesture];
        
        [self startPeriodicCheck];
        [self resetFadeTimer];

        // Start as hidden, will be shown by updateClearButtonVisibility if conditions are met
        self.hidden = YES;
    }
    return self;
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        [self loadSavedPosition];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self stopTimers];
        return;
    }
    [self startPeriodicCheck];
    [self resetFadeTimer];
}

- (void)startPeriodicCheck {
    if (self.checkTimer) {
        [self.checkTimer invalidate];
        self.checkTimer = nil;
    }
    __weak __typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
                                                        __strong __typeof(weakSelf) strongSelf = weakSelf;
                                                        if (!strongSelf) {
                                                            return;
                                                        }
                                                        if (strongSelf.isElementsHidden) {
                                                            [strongSelf hideUIElements];
                                                        }
                                                      }];
    self.checkTimer = timer;
}

- (void)resetFadeTimer {
    if (self.fadeTimer) {
        [self.fadeTimer invalidate];
        self.fadeTimer = nil;
    }
    __weak __typeof(self) weakSelf = self;
    NSTimer *fadeTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                         repeats:NO
                                                           block:^(NSTimer *timer) {
                                                             __strong __typeof(weakSelf) strongSelf = weakSelf;
                                                             if (!strongSelf) {
                                                                 return;
                                                             }
                                                             [UIView animateWithDuration:0.3
                                                                              animations:^{
                                                                                strongSelf.alpha = 0.5;
                                                                              }];
                                                             strongSelf.fadeTimer = nil;
                                                           }];
    self.fadeTimer = fadeTimer;
    if (self.alpha != self.originalAlpha) {
        [UIView animateWithDuration:0.2
                         animations:^{
                           self.alpha = self.originalAlpha;
                         }];
    }
}

- (void)stopTimers {
    if (self.checkTimer) {
        [self.checkTimer invalidate];
        self.checkTimer = nil;
    }
    if (self.fadeTimer) {
        [self.fadeTimer invalidate];
        self.fadeTimer = nil;
    }
}

- (void)saveButtonPosition {
    if (self.superview) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        CGFloat centerXPercent = self.center.x / self.superview.bounds.size.width;
        CGFloat centerYPercent = self.center.y / self.superview.bounds.size.height;
        
        [defaults setFloat:centerXPercent forKey:@"DYYYHideButtonCenterXPercent"];
        [defaults setFloat:centerYPercent forKey:@"DYYYHideButtonCenterYPercent"];
    }
}

- (void)loadSavedPosition {
    if (!self.superview) {
        return;
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    float centerXPercent = [defaults floatForKey:@"DYYYHideButtonCenterXPercent"];
    float centerYPercent = [defaults floatForKey:@"DYYYHideButtonCenterYPercent"];
    
    if (centerXPercent > 0 && centerYPercent > 0) {
        self.center = CGPointMake(centerXPercent * self.superview.bounds.size.width,
                                  centerYPercent * self.superview.bounds.size.height);
    } else {
        self.center = CGPointMake(self.superview.bounds.size.width / 2.0f,
                                  self.superview.bounds.size.height / 3.0f);
    }
}

- (void)saveLockState {
    [[NSUserDefaults standardUserDefaults] setBool:self.isLocked forKey:@"DYYYHideUIButtonLockState"];
}

- (void)loadLockState {
    self.isLocked = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideUIButtonLockState"];
}

- (void)loadIcons {
    NSString *documentsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *iconPath = [documentsPath stringByAppendingPathComponent:@"DYYY/qingping.gif"];
    NSData *gifData = [NSData dataWithContentsOfFile:iconPath];

    NSArray<UIImage *> *frames = nil;
    CGFloat totalDuration = 0.0;
    BOOL hasFrames = gifData.length > 0 &&
                     [DYYYUtils framesFromAnimatedData:gifData
                                                scale:[UIScreen mainScreen].scale
                                               images:&frames
                                        totalDuration:&totalDuration];

    if (hasFrames && frames.count > 0) {
        UIImageView *animatedImageView = [[UIImageView alloc] initWithFrame:self.bounds];
        animatedImageView.animationImages = frames;
        animatedImageView.animationDuration = totalDuration;
        animatedImageView.animationRepeatCount = 0;
        [self addSubview:animatedImageView];

        animatedImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [animatedImageView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor], [animatedImageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [animatedImageView.widthAnchor constraintEqualToAnchor:self.widthAnchor], [animatedImageView.heightAnchor constraintEqualToAnchor:self.heightAnchor]
        ]];

        [animatedImageView startAnimating];
        return;
    }

    [self setTitle:@"隐藏" forState:UIControlStateNormal];
    [self setTitle:@"显示" forState:UIControlStateSelected];
    self.titleLabel.font = [UIFont systemFontOfSize:10];
}

- (void)handleTouchDown {
    [self resetFadeTimer];
}

- (void)handleTouchUpInside {
    [self resetFadeTimer];
}

- (void)handleTouchUpOutside {
    [self resetFadeTimer];
}

- (UIViewController *)findViewController:(UIView *)view {
    __weak UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = [responder nextResponder];
        if (!responder)
            break;
    }
    return nil;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (self.isLocked)
        return;

    [self resetFadeTimer];
    CGPoint translation = [gesture translationInView:self.superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    newCenter.x = MAX(self.frame.size.width / 2, MIN(newCenter.x, self.superview.frame.size.width - self.frame.size.width / 2));
    newCenter.y = MAX(self.frame.size.height / 2, MIN(newCenter.y, self.superview.frame.size.height - self.frame.size.height / 2));
    self.center = newCenter;
    [gesture setTranslation:CGPointZero inView:self.superview];

    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [self saveButtonPosition];
    }
}

- (void)handleTap {
    if (isAppInTransition)
        return;
    [self resetFadeTimer];
    if (!self.isElementsHidden) {
        [self hideUIElements];
        self.isElementsHidden = YES;
        self.selected = YES;

        BOOL hideSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideSpeed"];
        if (hideSpeed) {
            hideSpeedButton();
        }
    } else {
        forceResetAllUIElements();
        [self restoreAWEPlayInteractionProgressContainerView];
        self.isElementsHidden = NO;
        [self.hiddenViewsList removeAllObjects];
        self.selected = NO;

        BOOL hideSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideSpeed"];
        if (hideSpeed) {
            showSpeedButton();
        }
    }    DYYYRefreshViewsAfterClearToggle(self.isElementsHidden);
}

- (void)restoreAWEPlayInteractionProgressContainerView {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYRemoveTimeProgress"] || [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideTimeProgress"]) {
        DYYYPerformClearButtonMutation(^{
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                [self recursivelyRestoreAWEPlayInteractionProgressContainerViewInView:window];
            }
        });
    }
}

- (void)recursivelyRestoreAWEPlayInteractionProgressContainerViewInView:(UIView *)view {
    if ([view isKindOfClass:NSClassFromString(@"AWEPlayInteractionProgressContainerView")]) {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYRemoveTimeProgress"]) {
            view.hidden = NO;
        } else {
            view.alpha = DYGetGlobalAlpha();
        }
        return;
    }

    for (UIView *subview in view.subviews) {
        [self recursivelyRestoreAWEPlayInteractionProgressContainerViewInView:subview];
    }
}
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self resetFadeTimer];
        self.isLocked = !self.isLocked;
        [self saveLockState];
        NSString *toastMessage = self.isLocked ? @"按钮已锁定" : @"按钮已解锁";
        [DYYYUtils showToast:toastMessage];
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [generator prepare];
            [generator impactOccurred];
        }
    }
}
- (void)hideUIElements {
    DYYYPerformClearButtonMutation(^{
        [self.hiddenViewsList removeAllObjects];
        [self findAndHideViews:targetClassNames];
        [self hideAWEPlayInteractionProgressContainerView];
        self.isElementsHidden = YES;
        // self.hidden should be managed by updateClearButtonVisibility
        updateClearButtonVisibility();
        if (self.superview) {
            [self.superview bringSubviewToFront:self];
        }
    });
}

- (void)hideAWEPlayInteractionProgressContainerView {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYRemoveTimeProgress"] || [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideTimeProgress"]) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            [self recursivelyHideAWEPlayInteractionProgressContainerViewInView:window];
        }
    }
}

- (void)recursivelyHideAWEPlayInteractionProgressContainerViewInView:(UIView *)view {
    if ([view isKindOfClass:NSClassFromString(@"AWEPlayInteractionProgressContainerView")]) {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYRemoveTimeProgress"]) {
            view.hidden = YES;
        } else {
            view.tag = DYYY_IGNORE_GLOBAL_ALPHA_TAG;
            view.alpha = 0.0;
        }
        [self.hiddenViewsList addObject:view];
        return;
    }

    for (UIView *subview in view.subviews) {
        [self recursivelyHideAWEPlayInteractionProgressContainerViewInView:subview];
    }
}
- (void)findAndHideViews:(NSArray *)classNames {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        for (NSString *className in classNames) {
            Class viewClass = NSClassFromString(className);
            if (!viewClass)
                continue;
            NSMutableArray *views = [NSMutableArray array];
            findViewsOfClassHelper(window, viewClass, views);
            for (UIView *view in views) {
                if ([view isKindOfClass:[UIView class]]) {
                    if (view == self)
                        continue;
                    if ([view isKindOfClass:NSClassFromString(@"AWELeftSideBarEntranceView")]) {
                        UIViewController *controller = [self findViewController:view];
                        if (![controller isKindOfClass:NSClassFromString(@"AWEFeedContainerViewController")]) {
                            continue;
                        }
                    }
                    [self.hiddenViewsList addObject:view];
                    if ([view isKindOfClass:NSClassFromString(@"AWEAwemePlayVideoPauseIcon")]) {
                        view.hidden = YES;
                    } else {
                        view.alpha = 0.0;
                    }
                }
            }
        }
    }
}
- (void)safeResetState {
    forceResetAllUIElements();
    DYYYRefreshViewsAfterClearToggle(NO);
    self.isElementsHidden = NO;
    [self.hiddenViewsList removeAllObjects];
    self.selected = NO;

    if (self.superview) {
        [self.superview bringSubviewToFront:self];
    }

    BOOL hideSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideSpeed"];
    if (hideSpeed) {
        showSpeedButton();
    }
}
- (void)dealloc {
    [self stopTimers];
}
@end
