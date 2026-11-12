// DYYYLiveBoardSheet.m — 见 DYYYLiveBoardSheet.h。
// 只做底页呈现这一件事：下三分之二、圆角顶边、小横条、无遮罩、
// 点外面收回、下滑收回。不改任何原生 view 的 frame，不钩 layoutSubviews，
// 不订阅任何通知。
#import "DYYYLiveBoardSheet.h"

// 底页占容器高度的 2/3；下滑超过 120pt 或速度超过 800pt/s 就收回。
static const CGFloat kDYYYLiveBoardSheetHeightFraction = 2.0 / 3.0;
static const CGFloat kDYYYLiveBoardSheetCornerRadius = 14.0;
static const CGFloat kDYYYLiveBoardSheetDismissDistance = 120.0;
static const CGFloat kDYYYLiveBoardSheetDismissVelocity = 800.0;

@interface DYYYLiveBoardSheetPresentationController ()
@property(nonatomic, strong, nullable) UIView *outsideTapView;
@property(nonatomic, strong, nullable) UIView *grabber;
@property(nonatomic, strong, nullable) UIPanGestureRecognizer *panGesture;
@property(nonatomic, assign) CGRect panStartFrame;
@property(nonatomic, assign) BOOL panActive;
@end

@implementation DYYYLiveBoardSheetPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect bounds = self.containerView.bounds;
    CGFloat height = CGRectGetHeight(bounds) * kDYYYLiveBoardSheetHeightFraction;
    return CGRectMake(0, CGRectGetHeight(bounds) - height, CGRectGetWidth(bounds), height);
}

- (void)presentationTransitionWillBegin {
    UIView *containerView = self.containerView;
    UIView *presentedView = self.presentedView;
    if (!containerView || !presentedView) return;

    // 点外面收回：全容器透明层，盖在底页下面、直播间上面；
// 底页本身盖住下三分之二，点上面三分之一就落到这层上收回。
    // 背景是全透明的，不给直播间加任何遮罩。
    UIView *outside = [[UIView alloc] initWithFrame:containerView.bounds];
    outside.backgroundColor = UIColor.clearColor;
    outside.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSheet)];
    [outside addGestureRecognizer:tap];
    [containerView insertSubview:outside belowSubview:presentedView];
    self.outsideTapView = outside;

    // 圆角只切顶边。
    presentedView.layer.cornerRadius = kDYYYLiveBoardSheetCornerRadius;
    presentedView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    presentedView.layer.masksToBounds = YES;

    // 小横条：贴在底页顶部中央、导航栏上方 8pt 处（标题在 44pt 栏内居中，
// 横条 6–11pt，不盖住标题文字）。
    UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake(0, 8, 36, 5)];
    grabber.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    grabber.layer.cornerRadius = 2.5;
    grabber.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    grabber.center = CGPointMake(CGRectGetMidX(presentedView.bounds), 10.5);
    [presentedView addSubview:grabber];
    self.grabber = grabber;

    // 下滑收回：只挂在小横条和导航栏上，不挂在整张底页上——
// 表格区域的下滑留给表格自己滚动，不抢手势。
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    self.panGesture = pan;
    [grabber addGestureRecognizer:pan];
    if ([self.presentedViewController isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)self.presentedViewController;
        [nav.navigationBar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];
    }

    // 从屏幕下方滑上来（和系统底页同款进场）。
    CGRect finalFrame = [self frameOfPresentedViewInContainerView];
    presentedView.frame = CGRectOffset(finalFrame, 0, CGRectGetHeight(finalFrame));
    id<UIViewControllerTransitionCoordinator> coordinator = self.presentedViewController.transitionCoordinator;
    [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        presentedView.frame = finalFrame;
    } completion:nil];
}

- (void)dismissalTransitionWillBegin {
    UIView *presentedView = self.presentedView;
    if (!presentedView || !self.containerView) return;
    CGRect finalFrame = presentedView.frame;
    finalFrame.origin.y = CGRectGetHeight(self.containerView.bounds);
    id<UIViewControllerTransitionCoordinator> coordinator = self.presentedViewController.transitionCoordinator;
    [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        presentedView.frame = finalFrame;
    } completion:nil];
}

- (void)dismissalTransitionDidEnd:(BOOL)completed {
    if (completed) {
        [self.outsideTapView removeFromSuperview];
        self.outsideTapView = nil;
        [self.grabber removeFromSuperview];
        self.grabber = nil;
    }
}

- (void)containerViewDidLayoutSubviews {
    [super containerViewDidLayoutSubviews];
    self.outsideTapView.frame = self.containerView.bounds;
    // 旋转时重算底页位置；正在下滑拖动时不动帧（手势自己管）。
    if (!self.panActive) self.presentedView.frame = [self frameOfPresentedViewInContainerView];
}

- (void)dismissSheet {
    [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *presentedView = self.presentedView;
    if (!presentedView) return;
    CGPoint translation = [pan translationInView:self.containerView];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            self.panActive = YES;
            self.panStartFrame = presentedView.frame;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat dy = translation.y;
            if (dy < 0) dy = 0;
            presentedView.frame = CGRectOffset(self.panStartFrame, 0, dy);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            self.panActive = NO;
            CGFloat dy = translation.y;
            CGFloat velocity = [pan velocityInView:self.containerView].y;
            if (pan.state == UIGestureRecognizerStateEnded && (dy > kDYYYLiveBoardSheetDismissDistance || velocity > kDYYYLiveBoardSheetDismissVelocity)) {
                [self dismissSheet];
            } else {
                CGRect finalFrame = [self frameOfPresentedViewInContainerView];
                [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    presentedView.frame = finalFrame;
                } completion:nil];
            }
            break;
        }
        default:
            break;
    }
}

@end

@implementation DYYYLiveBoardSheetTransitioningDelegate

- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented
                                                     presentingViewController:(UIViewController *)presenting
                                                         sourceViewController:(UIViewController *)source {
    return [[DYYYLiveBoardSheetPresentationController alloc] initWithPresentedViewController:presented
                                                                     presentingViewController:presenting];
}

@end
