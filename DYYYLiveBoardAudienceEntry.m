// DYYYLiveBoardAudienceEntry.m — 见 DYYYLiveBoardAudienceEntry.h。
// 只做两件事：① 在“在线观众”标题栏左侧加“人气榜”入口按钮；
// ② 点按钮打开榜单页（包一层导航控制器 modal 全屏呈现，带“关闭”按钮）。
// 硬约束：不改任何原生 view 的 frame，不在 layoutSubviews 里做任何事，
// 不订阅任何通知；按钮只用自己的 Auto Layout 约束定位；找不到标题栏时
// 静默返回，不弹提示；2.2-9-87 起每次尝试都把结果写进诊断 defaults
//（DYYYLiveBoardEntryDiag 单条 + 2.2-9-89 起最近 3 条环
// DYYYLiveBoardEntryDiagRing），供榜单设置页页脚现读现显——
// 2.2-9-93：入口诊断已关闭（用户要求），这段只留作历史。
// 2.2-9-88：① 进房间后 1 秒轮询 watcher（StartWatcher/StopWatcher）；
// ② 自家榜单/设置页（类名 DYYY 开头）触发时跳过安装与诊断，不再覆盖
// 真实诊断；③ 快路只认“可见”的已装按钮，藏在预建面板里的旧按钮不再
// 挡住重装；④ 找不到标题时诊断另记窗口顶层视图类名与标签总数。
// 2.2-9-89：① 诊断改成最近 3 条环（设置页页脚全显，读诊断的动作本身
// 再也盖不掉面板打开那一刻的记录）；② 排除类名含 "Setting" 的触发 VC
//（抖音设置宿主 AWESettingBaseViewController 在 -88 漏网）；③ watcher
// 每跳写心跳（上一跳时间 + 跳数），页脚可验证 watcher 是不是真在跑；
// ④ 找不到“在线观众”标题时，改用面板 tab 标签“贡献榜/高等级”作第二
// 锚点定位面板、把按钮放到标题行左端。
#import "DYYYLiveBoardAudienceEntry.h"
#import "DYYYLiveBoardLongPressEntry.h"
#import "DYYYLiveBoardModel.h"
#import "DYYYLiveBoardSheet.h"
#import "DYYYLiveBoardStore.h"
#import "DYYYLiveBoardUI.h"
#import <objc/runtime.h>

// 2.2-9-94：底页 transitioningDelegate 的关联对象键（UIKit 只弱持有
// transitioningDelegate，不挂关联对象的话呈现过程中 delegate 可能被释放）。
static const char kDYYYLiveBoardSheetDelegateKey;

// 前向声明（2.2-9-90：定义在文件后半部分，供 AudienceEntryTarget.openBoard
// 与长按菜单入口共用）。
void DYYYLiveBoardPresentBoardFromViewController(UIViewController *from);

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
// 2.2-9-89：再排除类名含 "Setting" 的触发 VC——抖音设置宿主
// AWESettingBaseViewController 不以 DYYY 开头，-88 的守卫漏了它；用户
// 一打开设置读诊断，AWESettingBaseViewController 的出现/呈现就触发一次
// 安装，面板关着当然找不到标题，又把真实诊断覆盖掉（观察者效应）。
// 观众面板的 VC 类名里不会有 "Setting"，排除它是安全的。
BOOL DYYYLiveBoardAudienceEntryIsOwnViewController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass(vc.class);
    if ([name hasPrefix:@"DYYY"]) return YES;
    if ([name rangeOfString:@"Setting"].location != NSNotFound) return YES;
    return NO;
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

// 2.2-9-89：watcher 心跳。每次 tick 写一条 "HH:mm:ss 第N跳" 到 defaults
//（另记一条时间戳供页脚判断新鲜度），榜单设置页页脚现读现显——没有心跳，
// 就证明 watcher 根本没在跑；心跳停在进房间之前，说明 watcher 启动过
// 但后来停了。心跳键定义在这里是因为 StartWatcher 在诊断键定义之前。
// 2.2-9-93：心跳不再写（入口诊断已关闭），键只剩 DiagText 死代码在读。
static NSString *const kDYYYLiveBoardEntryWatcherBeatKey = @"DYYYLiveBoardEntryWatcherBeat";
static NSString *const kDYYYLiveBoardEntryWatcherBeatAtKey = @"DYYYLiveBoardEntryWatcherBeatAt";
static NSUInteger gDYYYLiveBoardEntryWatcherTickCount = 0;

void DYYYLiveBoardAudienceEntryStartWatcher(UIViewController *roomVC) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardAudienceEntryStartWatcher(roomVC); });
        return;
    }
    if (!roomVC) return;
    [gDYYYLiveBoardEntryWatcherTimer invalidate];
    gDYYYLiveBoardEntryWatcherTimer = nil;
    gDYYYLiveBoardEntryWatcherRoomVC = roomVC;
    gDYYYLiveBoardEntryWatcherTickCount = 0;
    __weak UIViewController *weakRoom = roomVC;
    gDYYYLiveBoardEntryWatcherTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        UIViewController *room = weakRoom;
        if (!room) {
            DYYYLiveBoardAudienceEntryStopWatcher();
            return;
        }
        // 后台不刷（直播间只在前台看得到）。
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        // 2.2-9-93：心跳不再写 defaults（入口诊断已关闭，没人再读它）；
        // 跳数只在内存里计着，watcher 本身每跳照常调 Install。
        gDYYYLiveBoardEntryWatcherTickCount++;
        // watcher 每跳不写“找不到标题”的诊断：面板没打开时本来就找不到，
        // 写了会把面板打开那一刻的真实诊断冲掉；只有找到标题（面板在场）
        // 或已装上时才记，见 InstallWithDiag 的 recordDiag 分支。
        DYYYLiveBoardAudienceEntryInstallWithDiag(room, NO);
        // 2.2-9-90：长按菜单入口同款 backstop——菜单无论何时出现/重建都
        // 能装上（recordDiag=NO，找不到锚点时不写诊断）。
        DYYYLiveBoardLongPressEntryInstallWithDiag(room, NO);
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
    // 2.2-9-90：打开榜单的逻辑抽到共用函数里，长按菜单入口也走同一条路。
    DYYYLiveBoardPresentBoardFromViewController(self.audienceVC);
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

// 2.2-9-89：第二锚点。面板的 tab 标签（截图里看得见的“贡献榜 (99+)",
// “高等级 (66)”、"千钻贡献"、"星守护"）是面板在场的铁证；如果“在线观众”
// 标题根本不是 UILabel（比如 Lynx 渲染），标题路找不到，tab 标签仍能
// 定位面板。只认前缀（后面跟的 "(99+)" 人数会变），attributedText 也认。
static UILabel *DYYYLiveBoardFindTabLabel(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *text = label.text.length ? label.text : label.attributedText.string;
        if ([text hasPrefix:@"贡献榜"] || [text hasPrefix:@"高等级"]) return label;
    }
    for (UIView *sub in view.subviews) {
        UILabel *found = DYYYLiveBoardFindTabLabel(sub);
        if (found) return found;
    }
    return nil;
}

// 两段式查找：先在 room VC 的 view 子树里找（面板是房间 view 里的子视图
// 时），找不到再扫各 window（面板是单独呈现的 sheet 时）。finder 是
// 上面两个查找函数之一。
typedef UILabel *(*DYYYLiveBoardLabelFinder)(UIView *view);
static UILabel *DYYYLiveBoardFindLabel(UIView *rootView, DYYYLiveBoardLabelFinder finder) {
    UILabel *found = finder(rootView);
    if (found) return found;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        found = finder(window);
        if (found) return found;
    }
    return nil;
}

// 2.2-9-89：tab 锚点的容器。往上最多走 5 层，宽 ≥200、高 30–200
//（tab 行的容器可能比标题栏高，30–120 不够；整屏高的房间根视图仍被
// 高度 guard 挡在外面）。tab 行容器常是横向滚动视图（clipsToBounds=YES）：
// 按钮要往上 44pt 放到标题行，会被它裁掉，所以优先找不裁剪的祖先；
// 5 层里找不到不裁剪的，才退回第一个合尺寸的容器。
static UIView *DYYYLiveBoardEntryContainerForTabLabel(UILabel *tabLabel) {
    UIView *firstFit = nil;
    UIView *candidate = tabLabel.superview;
    for (NSInteger level = 0; level < 5 && candidate; level++) {
        CGFloat containerWidth = CGRectGetWidth(candidate.bounds);
        CGFloat containerHeight = CGRectGetHeight(candidate.bounds);
        if (containerWidth >= 200.0 && containerHeight >= 30.0 && containerHeight <= 200.0) {
            if (!firstFit) firstFit = candidate;
            if (!candidate.clipsToBounds && ![candidate isKindOfClass:UIScrollView.class]) return candidate;
        }
        candidate = candidate.superview;
    }
    return firstFit;
}

// 标题行与 tab 行的中心距（用户截图实测约 55–60pt，取 44pt 保守值：
// 按钮中心落在标题行偏下处，仍在标题行空白区内，不会盖住标题文字）。
static const CGFloat kDYYYLiveBoardEntryTitleRowOffset = 44.0;
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
// 2.2-9-89：诊断环。单条会被读诊断的动作本身覆盖（-87：榜单页触发；
// -88：设置宿主 AWESettingBaseViewController 触发），改成最近 3 条环，
// 最新一条在最前；设置页读诊断最多只能追加最新一条，面板打开那一刻的
// 记录仍留在环里看得见。
static NSString *const kDYYYLiveBoardEntryDiagRingKey = @"DYYYLiveBoardEntryDiagRing";

// 2.2-9-93：入口诊断已关闭。函数与调用点保留（编译不受影响），
// 但不再写任何 defaults 键、不再返回诊断文案；旧键留在 defaults
// 里看不见、无害，不做迁移/清理。
static NSString *DYYYLiveBoardEntryRecordDiag(NSString *outcome, UIViewController *audienceVC) {
    (void)outcome; (void)audienceVC;
    return @"";
}

// 2.2-9-90：从 from 出发走到最上层已呈现的控制器，再 present 榜单页
//（全屏导航 + “关闭”按钮；榜单页自己没有关闭按钮，这里补一个，不改榜单页
// 本身）。target 用关联对象挂在 boardVC 上保活——UIBarButtonItem 不
// retain target，不挂关联对象的话点“关闭”时 target 可能已经释放。
// from 为 nil 时什么都不做；from 是 sheet/面板时，从最上层 present 一定
// 在最前面，不会被面板盖住。
void DYYYLiveBoardPresentBoardFromViewController(UIViewController *from) {
    if (!from) return;
    UIViewController *top = from;
    while (top.presentedViewController) top = top.presentedViewController;
    DYYYLiveBoardAudienceEntryTarget *target = [[DYYYLiveBoardAudienceEntryTarget alloc] init];
    target.audienceVC = from;
    DYYYLiveBoardViewController *boardVC = [[DYYYLiveBoardViewController alloc] init];
    // 2.2-9-108：从直播间里打开时，取当前房间的主播 uid + 开播起点
    //（只取一次）；从设置页以外的地方打开、或取不到时为 nil，行为不变。
    boardVC.roomHint = DYYYLiveBoardRoomHintForViewController(from);
    boardVC.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:target action:@selector(closeBoard:)];
    objc_setAssociatedObject(boardVC, @selector(openBoard:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:boardVC];
    // 全屏呈现：榜单是表格页（加人/长按菜单/改名字），半屏卡片下不好操作；
    // 与星牌 modal 全屏的做法一致。
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:nav animated:YES completion:nil];
}

// 2.2-9-93：胶囊点开的紧凑榜单——只含主播列表（compactListOnly），
// 标题“人气榜”、无设置组、无添加组、无页脚；其他入口（在线观众按钮、
// 长按菜单、推荐页长按）继续走上面的完整页。
// 2.2-9-94：改成下三分之二底页（自定义呈现控制器）——上三分之一留着
// 直播间（无遮罩），点外面 / 下滑 / “关闭”收回；内容仍是 -93 的紧凑列表。
void DYYYLiveBoardPresentCompactBoardFromViewController(UIViewController *from) {
    if (!from) return;
    UIViewController *top = from;
    while (top.presentedViewController) top = top.presentedViewController;
    DYYYLiveBoardAudienceEntryTarget *target = [[DYYYLiveBoardAudienceEntryTarget alloc] init];
    target.audienceVC = from;
    DYYYLiveBoardViewController *boardVC = [[DYYYLiveBoardViewController alloc] init];
    boardVC.compactListOnly = YES;
    // 2.2-9-108：同上，胶囊点开时取房内主播提示（只取一次）。
    boardVC.roomHint = DYYYLiveBoardRoomHintForViewController(from);
    boardVC.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:target action:@selector(closeBoard:)];
    objc_setAssociatedObject(boardVC, @selector(openBoard:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:boardVC];
    DYYYLiveBoardSheetTransitioningDelegate *sheetDelegate = [[DYYYLiveBoardSheetTransitioningDelegate alloc] init];
    nav.modalPresentationStyle = UIModalPresentationCustom;
    nav.transitioningDelegate = sheetDelegate;
    objc_setAssociatedObject(nav, &kDYYYLiveBoardSheetDelegateKey, sheetDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[DYYY-94] opening compact board as 2/3 sheet");
    [top presentViewController:nav animated:YES completion:nil];
}

// 2.2-9-90：给长按入口写诊断（进 -89 的最近 3 条环），并打 [DYYY-90] 日志。
void DYYYLiveBoardEntryRecordDiagLine(NSString *outcome, UIViewController *vc) {
    NSString *diag = DYYYLiveBoardEntryRecordDiag(outcome, vc);
    NSLog(@"[DYYY-90] %@", diag);
}

// 2.2-9-89：读最近 3 条诊断（最新在前）+ watcher 心跳行，供榜单设置页
// 页脚现读现显。心跳 10 秒内算活跃，否则只写上一跳时间与跳数；
// 从来没有心跳，写“无心跳（未进直播间或 watcher 未启动）”。
NSString *DYYYLiveBoardAudienceEntryDiagText(void) {
    NSArray *ring = [NSUserDefaults.standardUserDefaults arrayForKey:kDYYYLiveBoardEntryDiagRingKey];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (id item in ring ?: @[]) {
        if ([item isKindOfClass:NSString.class]) [lines addObject:item];
    }
    if (!lines.count) {
        NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kDYYYLiveBoardEntryDiagKey];
        if (stored.length) [lines addObject:stored];
    }
    NSString *beat = [NSUserDefaults.standardUserDefaults stringForKey:kDYYYLiveBoardEntryWatcherBeatKey];
    NSTimeInterval beatAt = [NSUserDefaults.standardUserDefaults doubleForKey:kDYYYLiveBoardEntryWatcherBeatAtKey];
    NSString *beatLine;
    if (beat.length) {
        NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - beatAt;
        if (beatAt > 0 && age < 10.0) beatLine = [NSString stringWithFormat:@"watcher：活跃，上一跳 %@", beat];
        else beatLine = [NSString stringWithFormat:@"watcher：上一跳 %@（已停止/不在直播间）", beat];
    } else {
        beatLine = @"watcher：无心跳（未进直播间或 watcher 未启动）";
    }
    if (!lines.count) {
        return [NSString stringWithFormat:@"入口诊断：暂无记录，请先打开一次在线观众面板再回来\n%@", beatLine];
    }
    return [NSString stringWithFormat:@"入口诊断：\n%@\n%@", [lines componentsJoinedByString:@"\n"], beatLine];
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
    // 2.2-9-108：改动态色——浅色底白 0.94 / 字白 0.15（与原来一致），
    // 深色底白 0.16 / 字白 0.92（深色观众面板里不刺眼）。
    button.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
        CGFloat w = trait.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.16 : 0.94;
        return [UIColor colorWithWhite:w alpha:1.0];
    }];
    [button setTitle:@"人气榜" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
        CGFloat w = trait.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.92 : 0.15;
        return [UIColor colorWithWhite:w alpha:1.0];
    }] forState:UIControlStateNormal];
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
        NSLog(@"[DYYY-89] AudienceEntry skip: board disabled — %@", diag);
        return;
    }
    // 快路：上次装的按钮还在窗口里且真的可见，就不用再扫整棵树。
    // 2.2-9-88：只认可见——藏在预建面板容器里的旧按钮不算装上，清掉重装。
    if (DYYYLiveBoardEntryButtonIsVisible(gInstalledEntryButton)) {
        if (recordDiag) {
            NSString *diag = DYYYLiveBoardEntryRecordDiag(@"已装上", audienceVC);
            NSLog(@"[DYYY-89] AudienceEntry already installed — %@", diag);
        }
        return;
    }
    gInstalledEntryButton = nil;

    // ① 标题路（首选）：在 room VC 子树、再不行各 window 里找“在线观众”。
    UILabel *titleLabel = DYYYLiveBoardFindLabel(audienceVC.view, DYYYLiveBoardFindAudienceTitleLabel);
    // ② 标题找不到时走 tab 锚点（2.2-9-89）：找“贡献榜/高等级”标签定位面板。
    UILabel *tabLabel = nil;
    UILabel *anchorLabel = titleLabel;
    BOOL useTabAnchor = NO;
    if (!titleLabel) {
        tabLabel = DYYYLiveBoardFindLabel(audienceVC.view, DYYYLiveBoardFindTabLabel);
        if (tabLabel) {
            anchorLabel = tabLabel;
            useTabAnchor = YES;
        }
    }
    if (!anchorLabel) {
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
        NSLog(@"[DYYY-89] AudienceEntry skip: title label not found — %@", diag);
        return;
    }

    UIButton *button = DYYYLiveBoardMakeEntryButton();
    CGFloat buttonWidth = button.intrinsicContentSize.width;
    UIView *container = nil;
    if (useTabAnchor) {
        // tab 锚点：用 tab 行的容器作面板锚点，按钮放标题行左端。
        container = DYYYLiveBoardEntryContainerForTabLabel(tabLabel);
        if (!container) {
            NSString *outcome = @"找不到容器(贡献榜锚点，需宽≥200/高30–200)";
            NSString *diag = DYYYLiveBoardEntryRecordDiag(outcome, audienceVC);
            NSLog(@"[DYYY-89] AudienceEntry skip: tab container not found — %@", diag);
            return;
        }
    } else {
        container = DYYYLiveBoardEntryContainerForTitleLabel(titleLabel, buttonWidth);
        if (!container) {
            CGFloat need = kDYYYLiveBoardAudienceEntryLeading + buttonWidth + kDYYYLiveBoardAudienceEntryGapToTitle;
            NSString *outcome = [NSString stringWithFormat:@"找不到容器(最后候选 %.0f-%.0f-%.0f，需 %.0f)",
                                 gDYYYLiveBoardEntryLastCandidateWidth, gDYYYLiveBoardEntryLastCandidateHeight,
                                 gDYYYLiveBoardEntryLastCandidateLeftSpace, need];
            NSString *diag = DYYYLiveBoardEntryRecordDiag(outcome, audienceVC);
            NSLog(@"[DYYY-89] AudienceEntry skip: container not found — %@", diag);
            return;
        }
    }
    // 同一标题栏只加一次（面板重建时会换新容器，旧按钮随旧容器一起走）。
    if ([container viewWithTag:kDYYYLiveBoardAudienceEntryTag]) {
        NSString *diag = DYYYLiveBoardEntryRecordDiag(@"已装上", audienceVC);
        NSLog(@"[DYYY-89] AudienceEntry already installed — %@", diag);
        return;
    }

    DYYYLiveBoardAudienceEntryTarget *target = [[DYYYLiveBoardAudienceEntryTarget alloc] init];
    target.audienceVC = audienceVC;
    [button addTarget:target action:@selector(openBoard:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, @selector(openBoard:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [container addSubview:button];
    // 只给按钮自己加约束：左贴标题栏、定高 26；纵向：标题路与标题对齐，
    // tab 路取 tab 中心往上一个标题行高（2.2-9-89，kDYYYLiveBoardEntryTitleRowOffset）。
    // 不改标题、不改标题栏、不碰任何原生 view 的 frame 或约束。
    if (useTabAnchor) {
        [NSLayoutConstraint activateConstraints:@[
            [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:kDYYYLiveBoardAudienceEntryLeading],
            [button.centerYAnchor constraintEqualToAnchor:tabLabel.centerYAnchor constant:-kDYYYLiveBoardEntryTitleRowOffset],
            [button.heightAnchor constraintEqualToConstant:kDYYYLiveBoardAudienceEntryHeight],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:kDYYYLiveBoardAudienceEntryLeading],
            [button.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
            [button.heightAnchor constraintEqualToConstant:kDYYYLiveBoardAudienceEntryHeight],
        ]];
    }
    gInstalledEntryButton = button;
    NSString *outcome = [NSString stringWithFormat:@"已装上(%@ 容器 %.0f×%.0f)",
                         useTabAnchor ? @"贡献榜锚点" : @"标题",
                         CGRectGetWidth(container.bounds), CGRectGetHeight(container.bounds)];
    NSString *diag = DYYYLiveBoardEntryRecordDiag(outcome, audienceVC);
    NSLog(@"[DYYY-89] AudienceEntry added: container w=%.0f h=%.0f buttonW=%.0f — %@",
          CGRectGetWidth(container.bounds), CGRectGetHeight(container.bounds), buttonWidth, diag);
}
