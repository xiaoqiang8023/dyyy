// DYYYLiveBoardAudienceEntry.m — 见 DYYYLiveBoardAudienceEntry.h。
// 只做两件事：① 在“在线观众”标题栏左侧加“人气榜”入口按钮；
// ② 点按钮打开榜单页（包一层导航控制器 modal 全屏呈现，带“关闭”按钮）。
// 硬约束：不改任何原生 view 的 frame，不在 layoutSubviews 里做任何事，
// 不订阅任何通知；按钮只用自己的 Auto Layout 约束定位；找不到标题栏时
// 静默返回，不弹提示、不写 defaults。
#import "DYYYLiveBoardAudienceEntry.h"
#import "DYYYLiveBoardStore.h"
#import "DYYYLiveBoardUI.h"
#import <objc/runtime.h>

static const NSInteger kDYYYLiveBoardAudienceEntryTag = 987601;
static const CGFloat kDYYYLiveBoardAudienceEntryHeight = 26.0;
static const CGFloat kDYYYLiveBoardAudienceEntryLeading = 16.0;
// 标题栏左侧要留出的最小空间：左边距 + 按钮宽 + 与标题的间距。
static const CGFloat kDYYYLiveBoardAudienceEntryGapToTitle = 8.0;

// 上次装好的入口按钮（弱引用）：还在窗口里时后续安装直接快路返回，
// 不用每次都全树扫一遍；面板容器重建/房间切换后它随旧容器一起释放，
// 弱引用归零，下次安装重新扫。
static __weak UIButton *gInstalledEntryButton = nil;

// 点入口后打开榜单页的 target：UIControl 不 retain target，所以这个
// 对象用关联对象挂在按钮上保活；它只弱引用观众 VC，不成环。
@interface DYYYLiveBoardAudienceEntryTarget : NSObject
@property(nonatomic, weak, nullable) UIViewController *audienceVC;
- (void)openBoard:(id)sender;
- (void)closeBoard:(id)sender;
@end

@implementation DYYYLiveBoardAudienceEntryTarget

- (void)openBoard:(id)sender {
    UIViewController *from = self.audienceVC;
    if (!from) return;
    // 走到最上层已呈现的控制器再 present：在线观众面板本身可能就是一层
    // sheet，直接从 room VC present 会被面板盖住；从最上层 present 一定在最前面。
    UIViewController *top = from;
    while (top.presentedViewController) top = top.presentedViewController;
    DYYYLiveBoardViewController *boardVC = [[DYYYLiveBoardViewController alloc] init];
    // modal 呈现没有返回栈，榜单页自己没有关闭按钮，这里补一个“关闭”。
    // 只在 presenter 这里设，不改榜单页本身。
    boardVC.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(closeBoard:)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:boardVC];
    // 全屏呈现：榜单是表格页（加人/长按菜单/改名字），半屏卡片下不好操作；
    // 与星牌 modal 全屏的做法一致。
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)closeBoard:(id)sender {
    UIViewController *from = self.audienceVC;
    if (!from) return;
    UIViewController *top = from;
    while (top.presentedViewController) top = top.presentedViewController;
    [top dismissViewControllerAnimated:YES completion:nil];
}

@end

// 在一棵子树里找文字是“在线观众”的 UILabel（标题栏的标题）。
// 不要求可见：面板可能是预建好藏着的，按钮装进它自己的容器里，
// 面板藏着按钮跟着藏、面板出来按钮跟着出来，没有副作用。
static UILabel *DYYYLiveBoardFindAudienceTitleLabel(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if ([label.text isEqualToString:@"在线观众"]) return label;
    }
    for (UIView *sub in view.subviews) {
        UILabel *found = DYYYLiveBoardFindAudienceTitleLabel(sub);
        if (found) return found;
    }
    return nil;
}

// 从标题 label 往上找标题栏：第一层足够宽、且标题左缘留得出入口位置的祖先。
// 标题在面板里居中，左侧空白 = 标题左缘在容器里的 x；要放得下左边距 +
// 按钮宽 + 与标题的间距。最多往上走 3 层；高度也卡一道（30–120pt），
// 防止一路走到房间根视图（整屏高）上——按钮不能挂在房间根视图上，
// 否则面板关了它还留在屏幕上。
// 找不到合适的容器返回 nil（调用方静默跳过，不强行贴上去盖住标题）。
static UIView *DYYYLiveBoardEntryContainerForTitleLabel(UILabel *titleLabel, CGFloat buttonWidth) {
    UIView *candidate = titleLabel.superview;
    for (NSInteger level = 0; level < 3 && candidate; level++) {
        CGFloat containerWidth = CGRectGetWidth(candidate.bounds);
        CGFloat containerHeight = CGRectGetHeight(candidate.bounds);
        if (containerWidth >= 200.0 && containerHeight >= 30.0 && containerHeight <= 120.0) {
            CGRect titleFrameInContainer = [titleLabel convertRect:titleLabel.bounds toView:candidate];
            CGFloat leftSpace = CGRectGetMinX(titleFrameInContainer);
            if (leftSpace >= kDYYYLiveBoardAudienceEntryLeading + buttonWidth + kDYYYLiveBoardAudienceEntryGapToTitle) {
                return candidate;
            }
        }
        candidate = candidate.superview;
    }
    return nil;
}

static UIButton *DYYYLiveBoardMakeEntryButton(void) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.tag = kDYYYLiveBoardAudienceEntryTag;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    // 跟抖音原生标题栏 / tab pill 接近的浅灰胶囊，别太扎眼。
    button.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];
    [button setTitle:@"人气榜" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:0.15 alpha:1.0] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    button.layer.cornerRadius = kDYYYLiveBoardAudienceEntryHeight / 2.0;
    button.layer.masksToBounds = YES;
    return button;
}

void DYYYLiveBoardAudienceEntryInstall(UIViewController *audienceVC) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardAudienceEntryInstall(audienceVC); });
        return;
    }
    // 门控：人气榜总开关关着时不显示入口（榜单页本身也没数据）。
    if (![DYYYLiveBoardStore.shared enabled]) return;
    // 快路：上次装的按钮还在窗口里，就不用再扫整棵树。
    if (gInstalledEntryButton && gInstalledEntryButton.window) return;
    if (!audienceVC) return;

    UILabel *titleLabel = DYYYLiveBoardFindAudienceTitleLabel(audienceVC.view);
    if (!titleLabel) {
        // 面板可能是单独呈现的 sheet，不在 room VC 子树里；再扫各 window。
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            titleLabel = DYYYLiveBoardFindAudienceTitleLabel(window);
            if (titleLabel) break;
        }
    }
    if (!titleLabel) return;

    UIButton *button = DYYYLiveBoardMakeEntryButton();
    CGFloat buttonWidth = button.intrinsicContentSize.width;
    UIView *container = DYYYLiveBoardEntryContainerForTitleLabel(titleLabel, buttonWidth);
    if (!container) return;
    // 同一标题栏只加一次（面板重建时会换新容器，旧按钮随旧容器一起走）。
    if ([container viewWithTag:kDYYYLiveBoardAudienceEntryTag]) return;

    DYYYLiveBoardAudienceEntryTarget *target = [[DYYYLiveBoardAudienceEntryTarget alloc] init];
    target.audienceVC = audienceVC;
    [button addTarget:target action:@selector(openBoard:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, @selector(openBoard:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [container addSubview:button];
    // 只给按钮自己加约束：左贴标题栏、纵向与标题对齐、定高 26；
    // 不改标题、不改标题栏、不碰任何原生 view 的 frame 或约束。
    [NSLayoutConstraint activateConstraints:@[
        [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:kDYYYLiveBoardAudienceEntryLeading],
        [button.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [button.heightAnchor constraintEqualToConstant:kDYYYLiveBoardAudienceEntryHeight],
    ]];
    gInstalledEntryButton = button;
}
