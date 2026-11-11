// DYYYLiveBoardAudienceEntry.m — 见 DYYYLiveBoardAudienceEntry.h。
// 只做两件事：① 在“在线观众”标题栏左侧加“人气榜”入口按钮；
// ② 点按钮打开榜单页（包一层导航控制器 modal 全屏呈现，带“关闭”按钮）。
// 硬约束：不改任何原生 view 的 frame，不在 layoutSubviews 里做任何事，
// 不订阅任何通知；按钮只用自己的 Auto Layout 约束定位；找不到标题栏时
// 静默返回，不弹提示；2.2-9-87 起每次尝试都把结果写进一条诊断 defaults
//（DYYYLiveBoardEntryDiag），供榜单设置页页脚现读现显。
// 2.2-9-88：① 进房间后 1 秒轮询 watcher（StartWatcher/StopWatcher）；
// ② 自家榜单/设置页（类名 DYYY 开头）触发时跳过安装与诊断，不再覆盖
// 真实诊断；③ 快路只认“可见”的已装按钮，藏在预建面板里的旧按钮不再
// 挡住重装；④ 找不到标题时诊断另记窗口顶层视图类名与标签总数。
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

// 2.2-9-88：自家页面判定。榜单页/设置页的类名都以 DYYY 开头，抖音
// 自己的 VC 没有这个前缀；观众面板永远不在自家页面里。
BOOL DYYYLiveBoardAudienceEntryIsOwnViewController(UIViewController *vc) {
    if (!vc) return NO;
    return [NSStringFromClass(vc.class) hasPrefix:@"DYYY"];
}

// 2.2-9-88：已装按钮是不是真的可见。只看 window 不够：按钮可能装进了
// 预建好藏着的面板容器（在窗口里、但祖先 hidden），那时快路会永远挡住
// 重装，面板打开后仍是旧容器里的旧按钮。可见才算装上，否则清掉弱引用
// 让本次安装重新扫、重新装。
static BOOL DYYYLiveBoardEntryButtonIsVisible(UIButton *button) {
    if (!button || !button.window || button.hidden || button.alpha <= 0.01) return NO;
    for (UIView *v = button.superview; v; v = v.superview) {
        if (v.hidden || v.alpha <= 0.01) return NO;
    }
    return YES;
}

// 前向声明（定义在文件后半部分；watcher 每跳调它，recordDiag=NO）。
static void DYYYLiveBoardAudienceEntryInstallWithDiag(UIViewController *audienceVC, BOOL recordDiag);

// 2.2-9-88：进房间后每秒重试安装的 watcher（照抄悬浮榜 tickTimer 的
// 做法：1 秒 NSTimer、主 RunLoop、common modes）。房间 VC 只弱引用，
// 房间没了 tick 自己停；显式 Stop 也清掉。定时器只调 Install，不另起
// 任何轮询、不订阅通知。
static NSTimer *gDYYYLiveBoardEntryWatcherTimer = nil;
static __weak UIViewController *gDYYYLiveBoardEntryWatcherRoomVC = nil;

void DYYYLiveBoardAudienceEntryStartWatcher(UIViewController *roomVC) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardAudienceEntryStartWatcher(roomVC); });
        return;
    }
    if (!roomVC) return;
    [gDYYYLiveBoardEntryWatcherTimer invalidate];
    gDYYYLiveBoardEntryWatcherTimer = nil;
    gDYYYLiveBoardEntryWatcherRoomVC = roomVC;
    __weak UIViewController *weakRoom = roomVC;
    gDYYYLiveBoardEntryWatcherTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        UIViewController *room = weakRoom;
        if (!room) {
            DYYYLiveBoardAudienceEntryStopWatcher();
            return;
        }
        // 后台不刷（直播间只在前台看得到）。
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        // watcher 每跳不写“找不到标题”的诊断：面板没打开时本来就找不到，
        // 写了会把面板打开那一刻的真实诊断冲掉；只有找到标题（面板在场）
        // 或已装上时才记，见 InstallWithDiag 的 recordDiag 分支。
        DYYYLiveBoardAudienceEntryInstallWithDiag(room, NO);
    }];
    [NSRunLoop.mainRunLoop addTimer:gDYYYLiveBoardEntryWatcherTimer forMode:NSRunLoopCommonModes];
}

void DYYYLiveBoardAudienceEntryStopWatcher(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardAudienceEntryStopWatcher(); });
        return;
    }
    [gDYYYLiveBoardEntryWatcherTimer invalidate];
    gDYYYLiveBoardEntryWatcherTimer = nil;
    gDYYYLiveBoardEntryWatcherRoomVC = nil;
}

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
// 2.2-9-86：标题也可能只写在 attributedText 里（label.text 为空时
// 读 attributedText.string 兜底）。
static UILabel *DYYYLiveBoardFindAudienceTitleLabel(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if ([label.text isEqualToString:@"在线观众"]) return label;
        if (label.text.length == 0 && [label.attributedText.string isEqualToString:@"在线观众"]) return label;
    }
    for (UIView *sub in view.subviews) {
        UILabel *found = DYYYLiveBoardFindAudienceTitleLabel(sub);
        if (found) return found;
    }
    return nil;
}

// 从标题 label 往上找标题栏：第一层足够宽、且标题左缘留得出入口位置的祖先。
// 标题在面板里居中，左侧空白 = 标题左缘在容器里的 x；要放得下左边距 +
// 按钮宽 + 与标题的间距。2.2-9-86：最多往上走 5 层（-85 的 3 层在真机面板
// 上不够，标题栏可能隔了更多中间容器）；高度也卡一道（30–120pt），
// 防止一路走到房间根视图（整屏高）上——按钮不能挂在房间根视图上，
// 否则面板关了它还留在屏幕上。
// 找不到合适的容器返回 nil（调用方静默跳过，不强行贴上去盖住标题）。
// 诊断用：记下最后一个合宽高但左缘不够的候选容器，供 [DYYY-88] 日志与诊断用。
static CGFloat gDYYYLiveBoardEntryLastCandidateWidth = 0;
static CGFloat gDYYYLiveBoardEntryLastCandidateHeight = 0;
static CGFloat gDYYYLiveBoardEntryLastCandidateLeftSpace = 0;
static UIView *DYYYLiveBoardEntryContainerForTitleLabel(UILabel *titleLabel, CGFloat buttonWidth) {
    gDYYYLiveBoardEntryLastCandidateWidth = 0;
    gDYYYLiveBoardEntryLastCandidateHeight = 0;
    gDYYYLiveBoardEntryLastCandidateLeftSpace = 0;
    UIView *candidate = titleLabel.superview;
    for (NSInteger level = 0; level < 5 && candidate; level++) {
        CGFloat containerWidth = CGRectGetWidth(candidate.bounds);
        CGFloat containerHeight = CGRectGetHeight(candidate.bounds);
        if (containerWidth >= 200.0 && containerHeight >= 30.0 && containerHeight <= 120.0) {
            CGRect titleFrameInContainer = [titleLabel convertRect:titleLabel.bounds toView:candidate];
            CGFloat leftSpace = CGRectGetMinX(titleFrameInContainer);
            if (leftSpace >= kDYYYLiveBoardAudienceEntryLeading + buttonWidth + kDYYYLiveBoardAudienceEntryGapToTitle) {
                return candidate;
            }
            gDYYYLiveBoardEntryLastCandidateWidth = containerWidth;
            gDYYYLiveBoardEntryLastCandidateHeight = containerHeight;
            gDYYYLiveBoardEntryLastCandidateLeftSpace = leftSpace;
        }
        candidate = candidate.superview;
    }
    return nil;
}

// 2.2-9-87：安装诊断。每次 Install 尝试都把结果写进 NSUserDefaults
//（单条短字符串，每次覆盖），榜单设置页第 0 组页脚现读现显——
// 用户不用找日志，截设置页图就能定位。只写这一条 defaults 键，
// 不订阅任何通知、不弹任何提示。
static NSString *const kDYYYLiveBoardEntryDiagKey = @"DYYYLiveBoardEntryDiag";

// 把一条诊断写进 defaults（并返回带前缀的完整文案，供日志复用）。
// 格式：HH:mm:ss <触发 VC 类名> <结果>；结果是 总开关关 / 找不到标题 /
// 找不到容器(最后候选宽-高-左缘，需左缘) / 已装上 之一。
static NSString *DYYYLiveBoardEntryRecordDiag(NSString *outcome, UIViewController *audienceVC) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *time = [formatter stringFromDate:[NSDate date]];
    NSString *vcName = audienceVC ? NSStringFromClass(audienceVC.class) : @"(nil)";
    NSString *diag = [NSString stringWithFormat:@"%@ %@ %@", time, vcName, outcome];
    [NSUserDefaults.standardUserDefaults setObject:diag forKey:kDYYYLiveBoardEntryDiagKey];
    return [NSString stringWithFormat:@"入口诊断：%@", diag];
}

NSString *DYYYLiveBoardAudienceEntryDiagText(void) {
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kDYYYLiveBoardEntryDiagKey];
    if (!stored.length) return @"入口诊断：暂无记录，请先打开一次在线观众面板再回来";
    return [NSString stringWithFormat:@"入口诊断：%@", stored];
}

// 找不到标题时用：扫一棵子树，收集实际见到的 UILabel 文字（去重、
// 去空白、每条截 12 字、最多 cap 条），供诊断判断标题是拼写不同
//（多了空格/换了词）还是根本不是 UILabel。
static void DYYYLiveBoardCollectLabelTexts(UIView *view, NSMutableArray<NSString *> *out, NSUInteger cap) {
    if (!view || out.count >= cap) return;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *text = label.text.length ? label.text : label.attributedText.string;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0 && ![trimmed isEqualToString:@"人气榜"] && ![out containsObject:trimmed]) {
            if (trimmed.length > 12) trimmed = [trimmed substringToIndex:12];
            [out addObject:trimmed];
        }
    }
    for (UIView *sub in view.subviews) {
        if (out.count >= cap) break;
        DYYYLiveBoardCollectLabelTexts(sub, out, cap);
    }
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

// 2.2-9-88：数一棵子树里的 UILabel 总数（找不到标题时的诊断用）。
static NSUInteger DYYYLiveBoardCountLabels(UIView *view) {
    if (!view) return 0;
    NSUInteger count = [view isKindOfClass:UILabel.class] ? 1 : 0;
    for (UIView *sub in view.subviews) count += DYYYLiveBoardCountLabels(sub);
    return count;
}

void DYYYLiveBoardAudienceEntryInstall(UIViewController *audienceVC) {
    DYYYLiveBoardAudienceEntryInstallWithDiag(audienceVC, YES);
}

// recordDiag=YES：生命周期/present 触发的尝试，失败也记诊断（面板很可能
// 在场，失败本身就是定位信息）。recordDiag=NO：watcher 每跳，找不到标题
// 时不记（面板没开时本来就找不到）；找到标题或已装上时照常记。
static void DYYYLiveBoardAudienceEntryInstallWithDiag(UIViewController *audienceVC, BOOL recordDiag) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardAudienceEntryInstallWithDiag(audienceVC, recordDiag); });
        return;
    }
    // 2.2-9-88：自家页面触发时直接跳过，不安装也不写诊断——-87 的诊断
    // 就是被自家榜单页 viewDidAppear 时的尝试覆盖掉的。
    if (DYYYLiveBoardAudienceEntryIsOwnViewController(audienceVC)) return;
    if (!audienceVC) return;
    // 门控：人气榜总开关关着时不显示入口（榜单页本身也没数据）。
    if (![DYYYLiveBoardStore.shared enabled]) {
        if (!recordDiag) return;
        NSString *diag = DYYYLiveBoardEntryRecordDiag(@"总开关关", audienceVC);
        NSLog(@"[DYYY-88] AudienceEntry skip: board disabled — %@", diag);
        return;
    }
    // 快路：上次装的按钮还在窗口里且真的可见，就不用再扫整棵树。
    // 2.2-9-88：只认可见——藏在预建面板容器里的旧按钮不算装上，清掉重装。
    if (DYYYLiveBoardEntryButtonIsVisible(gInstalledEntryButton)) {
        if (recordDiag) {
            NSString *diag = DYYYLiveBoardEntryRecordDiag(@"已装上", audienceVC);
            NSLog(@"[DYYY-88] AudienceEntry already installed — %@", diag);
        }
        return;
    }
    gInstalledEntryButton = nil;

    UILabel *titleLabel = DYYYLiveBoardFindAudienceTitleLabel(audienceVC.view);
    if (!titleLabel) {
        // 面板可能是单独呈现的 sheet，不在 room VC 子树里；再扫各 window。
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            titleLabel = DYYYLiveBoardFindAudienceTitleLabel(window);
            if (titleLabel) break;
        }
    }
    if (!titleLabel) {
        // watcher 每跳：面板没开时本来就找不到，不记诊断（见 StartWatcher）。
        if (!recordDiag) return;
        // 2.2-9-87：标题没找到时，把实际见到的标题文字也记进诊断——
        // 能分清是标题拼写不同、还是根本不是 UILabel、还是面板压根没被扫到。
        NSMutableArray<NSString *> *seen = [NSMutableArray array];
        DYYYLiveBoardCollectLabelTexts(audienceVC.view, seen, 12);
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (seen.count >= 12) break;
            DYYYLiveBoardCollectLabelTexts(window, seen, 12);
        }
        // 2.2-9-88：再记两样，判面板标题是不是根本不是 UILabel：各 window
        // 顶层子视图的类名（前 10，去重）与扫到的 UILabel 总数。顶层出现
        // UILynxView/LynxView 之类，就说明面板是 Lynx 渲染的、标题不在
        // UILabel 树里；标签总数为 0，则被扫的 window 里根本没有文字视图。
        NSMutableArray<NSString *> *topClasses = [NSMutableArray array];
        NSUInteger labelCount = DYYYLiveBoardCountLabels(audienceVC.view);
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            labelCount += DYYYLiveBoardCountLabels(window);
            for (UIView *sub in window.subviews) {
                NSString *name = NSStringFromClass(sub.class);
                if (topClasses.count < 10 && ![topClasses containsObject:name]) [topClasses addObject:name];
            }
        }
        NSString *topJoined = [topClasses componentsJoinedByString:@","];
        NSString *outcome;
        if (seen.count) {
            outcome = [NSString stringWithFormat:@"找不到标题 | 标签%lu个 | 顶层:%@ | 已见标题:%@",
                       (unsigned long)labelCount, topJoined,
                       [[seen subarrayWithRange:NSMakeRange(0, MIN(8, (NSInteger)seen.count))] componentsJoinedByString:@","]];
        } else {
            outcome = [NSString stringWithFormat:@"找不到标题 | 标签%lu个 | 顶层:%@ | 未见任何标题文字",
                       (unsigned long)labelCount, topJoined];
        }
        NSString *diag = DYYYLiveBoardEntryRecordDiag(outcome, audienceVC);
        NSLog(@"[DYYY-88] AudienceEntry skip: title label not found — %@", diag);
        return;
    }

    UIButton *button = DYYYLiveBoardMakeEntryButton();
    CGFloat buttonWidth = button.intrinsicContentSize.width;
    UIView *container = DYYYLiveBoardEntryContainerForTitleLabel(titleLabel, buttonWidth);
    if (!container) {
        CGFloat need = kDYYYLiveBoardAudienceEntryLeading + buttonWidth + kDYYYLiveBoardAudienceEntryGapToTitle;
        NSString *outcome = [NSString stringWithFormat:@"找不到容器(最后候选 %.0f-%.0f-%.0f，需 %.0f)",
                             gDYYYLiveBoardEntryLastCandidateWidth, gDYYYLiveBoardEntryLastCandidateHeight,
                             gDYYYLiveBoardEntryLastCandidateLeftSpace, need];
        NSString *diag = DYYYLiveBoardEntryRecordDiag(outcome, audienceVC);
        NSLog(@"[DYYY-88] AudienceEntry skip: container not found — %@", diag);
        return;
    }
    // 同一标题栏只加一次（面板重建时会换新容器，旧按钮随旧容器一起走）。
    if ([container viewWithTag:kDYYYLiveBoardAudienceEntryTag]) {
        NSString *diag = DYYYLiveBoardEntryRecordDiag(@"已装上", audienceVC);
        NSLog(@"[DYYY-88] AudienceEntry already installed — %@", diag);
        return;
    }

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
    NSString *outcome = [NSString stringWithFormat:@"已装上(容器 %.0f×%.0f)",
                         CGRectGetWidth(container.bounds), CGRectGetHeight(container.bounds)];
    NSString *diag = DYYYLiveBoardEntryRecordDiag(outcome, audienceVC);
    NSLog(@"[DYYY-88] AudienceEntry added: container w=%.0f h=%.0f buttonW=%.0f — %@",
          CGRectGetWidth(container.bounds), CGRectGetHeight(container.bounds), buttonWidth, diag);
}
