// DYYYLiveBoardLongPressEntry.m — 见 DYYYLiveBoardLongPressEntry.h。
// 只做一件事：在长按底部菜单的“推荐直播”行下面贴一行“人气榜”行，点一下
// 打开榜单页（走 DYYYLiveBoardPresentBoardFromViewController，全屏导航 +
// “关闭”按钮，与在线观众入口同一条路）。
// 硬约束：不改任何原生 view 的 frame，不在 layoutSubviews 里做任何事，
// 不订阅任何通知；新行只用自己的 Auto Layout 约束定位；父容器是
// UITableView 时绝不硬贴（表不会为手动加的子视图重排，会盖住下一行——
// 表格驱动的菜单走 DYYYLongPressPanel.xm 里的模型注入）；找不到锚点时
// 静默返回，只写诊断、不弹提示。
#import "DYYYLiveBoardLongPressEntry.h"
#import "DYYYLiveBoardAudienceEntry.h"
#import "DYYYLiveBoardStore.h"
#import <objc/runtime.h>

static const NSInteger kDYYYLiveBoardLongPressEntryTag = 987602;

// 上次装好的行（弱引用）：还在窗口里且可见时后续安装直接快路返回；
// 菜单容器重建后它随旧容器一起释放，弱引用归零，下次安装重新扫。
static __weak UIButton *gInstalledLongPressRow = nil;

// 点行后打开榜单页的 target：UIButton 不 retain target，关联对象挂在行上保活。
@interface DYYYLiveBoardLongPressEntryTarget : NSObject
@property(nonatomic, weak, nullable) UIViewController *sheetVC;
- (void)openBoard:(id)sender;
@end

@implementation DYYYLiveBoardLongPressEntryTarget

- (void)openBoard:(id)sender {
    DYYYLiveBoardPresentBoardFromViewController(self.sheetVC);
}

@end

static BOOL DYYYLiveBoardLongPressRowIsVisible(UIButton *row) {
    if (!row || !row.window || row.hidden || row.alpha <= 0.01) return NO;
    for (UIView *v = row.superview; v; v = v.superview) {
        if (v.hidden || v.alpha <= 0.01) return NO;
    }
    return YES;
}

// 在一棵子树里找文字是“推荐直播”的 UILabel（长按菜单里的那一行）。
// attributedText 也认（-86 同款兜底）。
static UILabel *DYYYLiveBoardFindRecommendLiveLabel(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if ([label.text isEqualToString:@"推荐直播"]) return label;
        if (label.text.length == 0 && [label.attributedText.string isEqualToString:@"推荐直播"]) return label;
    }
    for (UIView *sub in view.subviews) {
        UILabel *found = DYYYLiveBoardFindRecommendLiveLabel(sub);
        if (found) return found;
    }
    return nil;
}

static UILabel *DYYYLiveBoardLongPressFindLabel(UIView *rootView) {
    UILabel *found = DYYYLiveBoardFindRecommendLiveLabel(rootView);
    if (found) return found;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        found = DYYYLiveBoardFindRecommendLiveLabel(window);
        if (found) return found;
    }
    return nil;
}

// 从“推荐直播” label 往上找行容器：第一层足够宽、且行高在 30–120pt 的祖先。
// 最多往上走 5 层（-85/-86 同款 guard），防止一路走到整屏高的根视图上。
static UIView *DYYYLiveBoardLongPressRowContainerForLabel(UILabel *label) {
    UIView *candidate = label.superview;
    for (NSInteger level = 0; level < 5 && candidate; level++) {
        CGFloat w = CGRectGetWidth(candidate.bounds);
        CGFloat h = CGRectGetHeight(candidate.bounds);
        if (w >= 200.0 && h >= 30.0 && h <= 120.0) return candidate;
        candidate = candidate.superview;
    }
    return nil;
}

// 新行：UIButton 作整行容器（点按走 UIControl），里面按原生“推荐直播”行
// 的样子摆：左绿圆图标（白字“榜”）、标题“人气榜”、右灰副标题
// “查看在播主播 · 在线人数”、最右灰色箭头“›”，顶部一条 0.5pt 分隔线。
static UIButton *DYYYLiveBoardMakeLongPressRow(void) {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.tag = kDYYYLiveBoardLongPressEntryTag;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor whiteColor];

    UIView *icon = [[UIView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
    icon.layer.cornerRadius = 14.0;
    icon.layer.masksToBounds = YES;
    icon.userInteractionEnabled = NO;
    [row addSubview:icon];

    UILabel *iconGlyph = [[UILabel alloc] init];
    iconGlyph.translatesAutoresizingMaskIntoConstraints = NO;
    iconGlyph.text = @"榜";
    iconGlyph.font = [UIFont boldSystemFontOfSize:15];
    iconGlyph.textColor = [UIColor whiteColor];
    iconGlyph.textAlignment = NSTextAlignmentCenter;
    [icon addSubview:iconGlyph];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"人气榜";
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    title.textColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    [row addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"查看在播主播 · 在线人数";
    subtitle.font = [UIFont systemFontOfSize:13];
    subtitle.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    [row addSubview:subtitle];

    UILabel *chevron = [[UILabel alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.text = @"›";
    chevron.font = [UIFont systemFontOfSize:20 weight:UIFontWeightLight];
    chevron.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    [row addSubview:chevron];

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1.0];
    [row addSubview:separator];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:28],
        [icon.heightAnchor constraintEqualToConstant:28],
        [iconGlyph.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor],
        [iconGlyph.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [title.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8],
        [subtitle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [separator.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [separator.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:row.topAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5],
    ]];
    // 副标题太长时先压副标题、不压标题和箭头。
    [subtitle setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [title setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return row;
}


void DYYYLiveBoardLongPressEntryInstall(UIViewController *sheetVC) {
    DYYYLiveBoardLongPressEntryInstallWithDiag(sheetVC, YES);
}

// recordDiag=YES：生命周期/present 触发的尝试，失败也记诊断。recordDiag=NO：
// watcher 每跳，只在真正装上时记，找不到锚点/开关关时不记（菜单没开时本来
// 就找不到，写了会冲掉真实记录；与在线观众入口 InstallWithDiag 同款规矩）。
void DYYYLiveBoardLongPressEntryInstallWithDiag(UIViewController *sheetVC, BOOL recordDiag) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardLongPressEntryInstall(sheetVC); });
        return;
    }
    // 自家页面触发时跳过（榜单页/设置页里不可能有长按菜单）。
    if (DYYYLiveBoardAudienceEntryIsOwnViewController(sheetVC)) return;
    if (!sheetVC) return;
    // 门控：人气榜总开关关着时不显示入口。
    if (![DYYYLiveBoardStore.shared enabled]) {
        if (recordDiag) {
            DYYYLiveBoardEntryRecordDiagLine(@"长按行：总开关关", sheetVC);
            NSLog(@"[DYYY-90] LongPressEntry skip: board disabled");
        }
        return;
    }
    // 快路：上次装的行还在窗口里且真的可见，就不用再扫。
    if (DYYYLiveBoardLongPressRowIsVisible(gInstalledLongPressRow)) return;
    gInstalledLongPressRow = nil;

    UILabel *anchorLabel = DYYYLiveBoardLongPressFindLabel(sheetVC.view);
    if (!anchorLabel) return; // 菜单没开时本来就找不到，不写诊断（免得冲掉真实记录）。
    UIView *container = DYYYLiveBoardLongPressRowContainerForLabel(anchorLabel);
    if (!container) {
        if (recordDiag) {
            DYYYLiveBoardEntryRecordDiagLine(@"长按行：找不到推荐直播行容器", sheetVC);
            NSLog(@"[DYYY-90] LongPressEntry skip: recommend-live row container not found");
        }
        return;
    }
    UIView *parent = container.superview;
    if (!parent) {
        if (recordDiag) DYYYLiveBoardEntryRecordDiagLine(@"长按行：推荐直播行无父容器", sheetVC);
        return;
    }
    // 父容器是 UITableView 时绝不硬贴：表不会为手动加的子视图重排，
    // 新行会盖住下一行。表格驱动的菜单走 DYYYLongPressPanel.xm 里的模型注入。
    if ([parent isKindOfClass:UITableView.class]) {
        if (recordDiag) {
            DYYYLiveBoardEntryRecordDiagLine(@"长按行：父容器是表格，改走模型注入", sheetVC);
            NSLog(@"[DYYY-90] LongPressEntry skip: parent is UITableView, model injection path owns this sheet");
        }
        return;
    }
    // 同一行只加一次。
    if ([parent viewWithTag:kDYYYLiveBoardLongPressEntryTag]) {
        if (recordDiag) DYYYLiveBoardEntryRecordDiagLine(@"长按行已装上", sheetVC);
        return;
    }

    UIButton *row = DYYYLiveBoardMakeLongPressRow();
    DYYYLiveBoardLongPressEntryTarget *target = [[DYYYLiveBoardLongPressEntryTarget alloc] init];
    target.sheetVC = sheetVC;
    [row addTarget:target action:@selector(openBoard:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(row, @selector(openBoard:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([parent isKindOfClass:UIStackView.class]) {
        UIStackView *stack = (UIStackView *)parent;
        NSInteger index = [stack.arrangedSubviews indexOfObject:container];
        [stack insertArrangedSubview:row atIndex:(index == NSNotFound ? stack.arrangedSubviews.count : index + 1)];
        [NSLayoutConstraint activateConstraints:@[
            [row.heightAnchor constraintEqualToAnchor:container.heightAnchor],
        ]];
    } else {
        [parent addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:container.bottomAnchor],
            [row.heightAnchor constraintEqualToAnchor:container.heightAnchor],
        ]];
    }
    gInstalledLongPressRow = row;
    if (recordDiag) DYYYLiveBoardEntryRecordDiagLine(@"长按行已装上(视图贴行)", sheetVC);
    NSLog(@"[DYYY-90] LongPressEntry added: parent=%@ container h=%.0f",
          NSStringFromClass(parent.class), CGRectGetHeight(container.bounds));
}
