// DYYYLiveBoardOverlay.m — 见 DYYYLiveBoardOverlay.h。
// 挂载与位置做法照抄 -7 开播时长胶囊（DYYY.xm）：
//   挂在 audienceVC.view 上，associated object 挂在 root 上；
//   位置按中心百分比存 NSUserDefaults，横竖屏分别记；
//   默认位置在时长胶囊下方（按 accessibilityIdentifier 找时长视图，
//   找不到就用安全区顶部 + 120 / 横屏 + 46）。
// 样式与时长胶囊一致：黑半透明底（默认 0.64，2.2-9-75 起由
// DYYYLiveBoardOverlayOpacity 滑杆调 20%–100%，只改黑底 alpha，
// 文字保持全不透明）、白字、圆角 7、0.5 白边。
// 2.2-9-75：面板主体右滑隐藏，只在左边缘留竖排“人气榜”小标签，
// 点小标签滑回来；隐藏状态只在当前房间内有效（不落盘，
// 进新房间是新的 view 实例，重新显示）。
// 2.2-9-77：显示改成左滑——小标签上加左滑手势 + 左边缘 20pt 隐形条，
// 从任一处起手左滑都把面板滑回来；点小标签/点隐形条保留作备用。
// 小标签触摸区加宽到 40pt（视觉 pill 仍 26pt 宽、左贴边，多出的
// 14pt 透明只接手势），左滑行程才够。
// 2.2-9-79：修直播间右滑不能隐藏——右滑手势从 tableView 移到面板
// 容器自身（标题栏/主播行/空白处起手都行），设 delegate 允许与 pan
// 并行识别（标题栏拖动 pan、表格滚动 pan、直播间容器 pan 不再顶掉
// 它），收起状态下右滑同样能藏；隐藏后标题栏 pan 直接 return，
// 不再把面板拉回来。
// 内部布局用 Auto Layout，不在 layoutSubviews 里改帧（-53/-57 教训）；
// 面板自身的 frame 只在拖动结束/内容变化时直接赋值。
// 2.2-9-73 注意：不要再建与本文件同名的 .xm（Theos 有 %.m: %.xm 规则，
// .xm 一新就会把本文件覆盖成 logos 输出——本次事故的根因；钩子文件
// 已改名 DYYYLiveBoardOverlayHooks.xm）。
// 2.2-9-80：清屏跟藏——视频证据断定是抖音原生清屏（不是 DYYY
// 圆形按钮）：DYYY 按钮只在推荐页可见（dyyyInteractionViewVisible
// 只在 AWEPlayInteractionViewController 里置 YES），直播间里根本按
// 不到它，且 DYYY 的 targetClassNames 全是推荐页的类，清不掉直播
// 间的顶栏/评论/底栏；视频里整个房间 UI 全清、且清屏帧里没有任何
// “退出清屏”按钮，是原生点按切换清屏，根本不走
// DYYYRefreshViewsAfterClearToggle。所以面板在每秒 tick 里跟住房间
// UI 的实际可见状态：房间子树里一个有效可见的原生 UILabel 都没有
// 了，就是原生清屏，面板跟着藏、UI 回来跟着恢复（只认 UILabel，
// 不用猜类名；只扫当前房间这一个子树，不全量遍历 window）。
#import "DYYYLiveBoardOverlay.h"
#import "DYYYFloatClearButton.h"
#import "DYYYLiveBoardModel.h"
#import "DYYYLiveBoardMonitor.h"
#import "DYYYLiveBoardStore.h"
#import "DYYYRadarModel.h"
#import <objc/message.h>
#import <objc/runtime.h>

static const void *kDYYYLiveBoardOverlayViewKey = &kDYYYLiveBoardOverlayViewKey;
// 2.2-9-82：面板从 200 加宽到 280——截图那行“12.38万 · 场观 47.6万 ·
// 00:24:04”详情串 11pt 约 174pt，加上名字（2 字约 24pt、5 字约 60pt、
// 6 字约 72pt）与圆点+边距约 38pt，整行要 236–280pt；200 的面板里
// 名字先被压到 0 宽（所以名字不见了），详情还被截成“00:2…”。
// 280 能放下截图那行与 5–6 字名字，仍远小于屏幕宽（竖屏 393pt）。
static const CGFloat kDYYYLiveBoardOverlayWidth = 280.0;
static const CGFloat kDYYYLiveBoardOverlayHeaderHeight = 30.0;
static const CGFloat kDYYYLiveBoardOverlayRowHeight = 24.0;
static const NSInteger kDYYYLiveBoardOverlayMaxVisibleRows = 8;

#pragma mark - 排序（与榜单页 DYYYLiveBoardUI resort 同规则）

// 在播按人数从高到低，未开播沉底，从未查到过/只有失败的最后。
// 人数没读到的在播按 0 算，排在有数的在播之后、未开播之前。
static NSArray<NSDictionary *> *DYYYLiveBoardOverlaySortedAnchors(NSArray<NSDictionary *> *anchors) {
    return [anchors sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDictionary *sa = [DYYYLiveBoardMonitor.shared stateForUID:a[@"uid"]];
        NSDictionary *sb = [DYYYLiveBoardMonitor.shared stateForUID:b[@"uid"]];
        BOOL la = [sa[@"live"] boolValue], lb = [sb[@"live"] boolValue];
        if (la != lb) return la ? NSOrderedAscending : NSOrderedDescending;
        if (la) {
            long long va = [sa[@"viewers"] longLongValue], vb = [sb[@"viewers"] longLongValue];
            if (va != vb) return va > vb ? NSOrderedAscending : NSOrderedDescending;
        } else {
            BOOL ka = [sa[@"checkedAt"] doubleValue] > 0, kb = [sb[@"checkedAt"] doubleValue] > 0;
            if (ka != kb) return ka ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame; // 同档保持添加顺序（sortedArray 稳定）。
    }];
}

#pragma mark - 行 cell

@interface DYYYLiveBoardOverlayCell : UITableViewCell
@property(nonatomic, strong) UIView *dotView;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@end

@implementation DYYYLiveBoardOverlayCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _dotView = [UIView new];
        _dotView.layer.cornerRadius = 4.0;
        _dotView.backgroundColor = [UIColor lightGrayColor];
        _dotView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_dotView];
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        _nameLabel.textColor = UIColor.whiteColor;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_nameLabel];
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
        _detailLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.85];
        _detailLabel.textAlignment = NSTextAlignmentRight;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_detailLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_dotView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10.0],
            [_dotView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_dotView.widthAnchor constraintEqualToConstant:8.0],
            [_dotView.heightAnchor constraintEqualToConstant:8.0],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_dotView.trailingAnchor constant:6.0],
            [_nameLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor constant:6.0],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8.0],
            [_detailLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
        // 名字优先，右侧详情不被挤掉。
        [_nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [_detailLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_detailLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    }
    return self;
}

@end

// 在 root 的子视图里找时长胶囊（identifier 由时长视图自身设置）。
static UIView *DYYYLiveBoardOverlayFindDurationView(UIView *root) {
    for (UIView *view in root.subviews) {
        if ([view.accessibilityIdentifier isEqualToString:@"dyyy_live_duration_view"]) return view;
    }
    for (UIView *view in root.subviews) {
        for (UIView *child in view.subviews) {
            if ([child.accessibilityIdentifier isEqualToString:@"dyyy_live_duration_view"]) return child;
        }
    }
    return nil;
}

// 2.2-9-80：在 root 子树里找第一个“有效可见”的原生 UILabel（带非空
// 文字、frame 非空、从它到 root 的祖先链都不 hidden、alpha 都 > 0.01）。
// 找到一个就说明房间 UI 还在；一个都没有就是原生清屏。
// 跳过 DYYY 自己的整棵子树（面板自身、时长胶囊、小标签、隐形条——
// 时长胶囊就算开关重新打开，它的“已开播”标签也不能算房间 UI）。
// 只扫当前房间这一个子树、找到就提前返回，不全量遍历 window；
// 祖先链不用单独再查——hidden/alpha<=0.01 的容器在递归入口就被
// 整棵剪掉，能走到标签那一层，祖先就都是可见的。
static BOOL DYYYLiveBoardOverlayRootHasVisibleNativeLabel(UIView *view) {
    if (!view || view.hidden || view.alpha <= 0.01) return NO;
    NSString *ident = view.accessibilityIdentifier;
    if ([ident isEqualToString:@"dyyy_live_board_overlay_view"] ||
        [ident isEqualToString:@"dyyy_live_duration_view"] ||
        [ident isEqualToString:@"dyyy_live_board_overlay_tab"] ||
        [ident isEqualToString:@"dyyy_live_board_overlay_edge"] ||
        // 2.2-9-92：小胶囊自己的“人气榜”标签也不能算房间 UI。
        [ident isEqualToString:@"dyyy_live_board_capsule"]) {
        return NO;
    }
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (label.text.length > 0 && !CGRectIsEmpty(label.bounds)) return YES;
    }
    for (UIView *sub in view.subviews) {
        if (DYYYLiveBoardOverlayRootHasVisibleNativeLabel(sub)) return YES;
    }
    return NO;
}

// 2.2-9-92：给人气榜小胶囊复用（同一条可见标签启发式，不另写一套）。
BOOL DYYYLiveBoardRootHasVisibleNativeLabel(UIView *view) {
    return DYYYLiveBoardOverlayRootHasVisibleNativeLabel(view);
}

#pragma mark - 悬浮面板

@interface DYYYLiveBoardOverlayView () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView *headerView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *totalLabel;
@property(nonatomic, strong) UILabel *chevronLabel;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSArray<NSDictionary *> *sorted;
@property(nonatomic, strong) NSTimer *tickTimer;
@property(nonatomic, assign, getter=isCollapsed) BOOL collapsed;
@property(nonatomic, assign, getter=isDragging) BOOL dragging;
// 2.2-9-75：右滑隐藏状态（只在当前房间内有效，不落盘）+ 藏起前的位置
// + 小标签（左边缘竖排“人气榜”pill，点一下面板滑回来）。
// 2.2-9-77：pillVisual 是小标签里真正看得见的 26pt 宽黑底；
// pillButton 本身是 40pt 宽的透明触摸区（视觉不变、手势区加宽）；
// edgeStrip 是左边缘 20pt 宽的隐形条，左滑/点按都能把面板滑回来。
@property(nonatomic, strong, nullable) UIButton *pillButton;
@property(nonatomic, strong, nullable) UIView *pillVisual;
@property(nonatomic, strong, nullable) UIView *edgeStrip;
@property(nonatomic, assign, getter=isHiddenBySwipe) BOOL hiddenBySwipe;
@property(nonatomic, assign) CGPoint preHideCenter;
@property(nonatomic, assign) CGFloat pillCenterYPercent;
// 2.2-9-80：原生清屏跟随状态（只在当前房间内有效，不落盘）。
// hiddenByNativeClear 是当前是否因原生清屏藏着；
// nativeClearGraceTicks 是装上后头几跳的宽限（进房间时 UI 还没
// 铺好、第一跳可能暂时没标签，宽限内不藏，宽限过后第一跳没标签
// 就藏——清屏在视频里只持续约 2.5 秒，不能等两跳）。
@property(nonatomic, assign, getter=isHiddenByNativeClear) BOOL hiddenByNativeClear;
@property(nonatomic, assign) NSInteger nativeClearGraceTicks;
@end

@implementation DYYYLiveBoardOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // 2.2-9-75：黑底透明度走滑杆设置（默认 0.64），只改背景 alpha，文字不动。
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:[DYYYLiveBoardStore.shared overlayOpacity]];
        self.layer.cornerRadius = 7.0;
        self.layer.masksToBounds = YES;
        self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.layer.borderWidth = 0.5;
        self.accessibilityIdentifier = @"dyyy_live_board_overlay_view";
        self.userInteractionEnabled = YES;
        _collapsed = [NSUserDefaults.standardUserDefaults boolForKey:DYYYLiveBoardOverlayCollapsedKey];
        _sorted = @[];
        // 2.2-9-80：刚装上给 1 跳宽限（进房间时 UI 还没铺好，第一跳
        // 可能暂时没标签，宽限内不藏；宽限过后第一跳没标签就藏）。
        _nativeClearGraceTicks = 1;

        _headerView = [UIView new];
        _headerView.backgroundColor = UIColor.clearColor;
        _headerView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_headerView];

        _titleLabel = [UILabel new];
        _titleLabel.text = @"人气榜";
        _titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_headerView addSubview:_titleLabel];

        _totalLabel = [UILabel new];
        _totalLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
        _totalLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.85];
        _totalLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_headerView addSubview:_totalLabel];

        _chevronLabel = [UILabel new];
        _chevronLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        _chevronLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.85];
        _chevronLabel.textAlignment = NSTextAlignmentCenter;
        _chevronLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_headerView addSubview:_chevronLabel];

        _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _tableView.backgroundColor = UIColor.clearColor;
        _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        _tableView.rowHeight = kDYYYLiveBoardOverlayRowHeight;
        _tableView.estimatedRowHeight = kDYYYLiveBoardOverlayRowHeight;
        _tableView.showsVerticalScrollIndicator = NO;
        _tableView.bounces = NO;
        _tableView.dataSource = self;
        _tableView.delegate = self;
        [_tableView registerClass:DYYYLiveBoardOverlayCell.class forCellReuseIdentifier:@"DYYYLiveBoardOverlayCell"];
        _tableView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_tableView];

        [NSLayoutConstraint activateConstraints:@[
            [_headerView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_headerView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_headerView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_headerView.heightAnchor constraintEqualToConstant:kDYYYLiveBoardOverlayHeaderHeight],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_headerView.leadingAnchor constant:10.0],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:_headerView.centerYAnchor],
            [_totalLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:6.0],
            [_totalLabel.centerYAnchor constraintEqualToAnchor:_headerView.centerYAnchor],
            [_chevronLabel.trailingAnchor constraintEqualToAnchor:_headerView.trailingAnchor constant:-8.0],
            [_chevronLabel.centerYAnchor constraintEqualToAnchor:_headerView.centerYAnchor],
            [_chevronLabel.widthAnchor constraintEqualToConstant:14.0],
            [_tableView.topAnchor constraintEqualToAnchor:_headerView.bottomAnchor],
            [_tableView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_tableView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_tableView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleHeaderTap:)];
        [_headerView addGestureRecognizer:tap];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleHeaderPan:)];
        [_headerView addGestureRecognizer:pan];
        // 2.2-9-79：右滑隐藏的手势挂在面板容器自身上（原来只挂在
        // tableView 上，划标题栏时根本没有手势、只会拖动；划主播行时
        // 又常被表格/直播间容器的 pan 抢走，所以真机上右滑藏不了）。
        // 面板上任何位置起手的右滑都能隐藏。设 delegate 允许与 pan
        // 并行识别，行点按是 tap，与右滑不冲突。
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeRight:)];
        swipe.direction = UISwipeGestureRecognizerDirectionRight;
        swipe.delegate = self;
        [self addGestureRecognizer:swipe];

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:DYYYLiveBoardChanged object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:DYYYLiveBoardStoreChanged object:nil];
        [self refresh];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.tickTimer invalidate];
    self.tickTimer = nil;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self startTick];
    else [self stopTick];
}

#pragma mark - 数据与尺寸

// 行详情：在播显示“人数 · 已播 HH:MM:SS”；
// 2.2-9-73：失败必须显示“读取失败”，不能算成“未开播”——之前只要
// checkedAt>0 就返回“未开播”，读失败也被算成确认下播（安顺当时正在播，
// 三行却全显示“未开播”）。只有 reflow 明确没有房间号、或 room_data
// 明确 status 不是在播，才显示“未开播”——那两种情况 state 里没有 error。
// 文案与榜单页 subtitleForAnchor 一致（在播显示数、失败显示“读取失败”）。
- (NSString *)detailForAnchor:(NSDictionary *)anchor {
    NSDictionary *state = [DYYYLiveBoardMonitor.shared stateForUID:anchor[@"uid"]];
    if ([state[@"live"] boolValue]) {
        NSMutableString *text = [NSMutableString string];
        NSNumber *viewers = state[@"viewers"];
        if (viewers) [text appendString:DYYYLiveBoardFormatCountCompact(viewers.longLongValue)];
        else [text appendString:@"人数未读到"];
        // 2.2-9-81：场观（累计进场人数），在线数之后、已播时长之前；
        // 没读到时不显示；详情 label 抗压缩是 required，名字先截断，时长留得住。
        NSNumber *total = state[@"totalViewers"];
        if (total.longLongValue > 0) [text appendFormat:@" · 场观 %@", DYYYLiveBoardFormatCountCompact(total.longLongValue)];
        NSString *digits = [state[@"start"] doubleValue] > 0 ? DYYYLiveBoardElapsedDigits([state[@"start"] doubleValue]) : nil;
        if (digits.length) [text appendFormat:@" · %@", digits];
        return text;
    }
    if (DYYYRadarString(state[@"error"]).length) return @"读取失败";
    if ([state[@"checkedAt"] doubleValue] > 0) return @"未开播";
    return @"暂未读取";
}

- (void)refresh {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
        return;
    }
    if (!DYYYLiveBoardOverlayShouldShow()) {
        [self removeFromSuperview];
        return;
    }
    self.sorted = DYYYLiveBoardOverlaySortedAnchors(DYYYLiveBoardStore.shared.anchors);
    // 标题行总数：在播人数 + 总在线人数。
    NSUInteger liveCount = 0;
    long long totalViewers = 0;
    for (NSDictionary *anchor in self.sorted) {
        NSDictionary *state = [DYYYLiveBoardMonitor.shared stateForUID:anchor[@"uid"]];
        if ([state[@"live"] boolValue]) {
            liveCount++;
            totalViewers += [state[@"viewers"] longLongValue];
        }
    }
    self.totalLabel.text = [NSString stringWithFormat:@"%lu人在播 · %@", (unsigned long)liveCount, DYYYLiveBoardFormatCountCompact(totalViewers)];
    self.chevronLabel.text = self.isCollapsed ? @"›" : @"⌄";
    self.tableView.hidden = self.isCollapsed;
    [self.tableView reloadData];
    [self applyOpacity];
    // 2.2-9-75：右滑藏起来后不置顶、不改 frame（否则会被拉回屏内），
    // 只保持小标签的位置；内容照常刷新。
    if (self.isHiddenBySwipe) {
        [self updatePillPosition];
        return;
    }
    // 2.2-9-73：每次刷新都重新置顶——进直播间后房间自己的 view 陆续加上来
    // 可能盖住悬浮榜，光安装时置顶一次不够。
    if (self.superview) [self.superview bringSubviewToFront:self];
    [self applySize];
}

// 2.2-9-75：透明度只改黑底的 alpha，文字保持全不透明；小标签同款黑底。
// refresh 在 StoreChanged 时调，所以滑杆一动面板立即改，不用等下次进房间。
// 2.2-9-77：黑底在 pillVisual 上（pillButton 本身是透明触摸区）。
- (void)applyOpacity {
    CGFloat opacity = [DYYYLiveBoardStore.shared overlayOpacity];
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:opacity];
    self.pillVisual.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:opacity];
}

// 面板被拆除时小标签和隐形条一起走，不留在房间里。
- (void)removeFromSuperview {
    [self.pillButton removeFromSuperview];
    self.pillButton = nil;
    self.pillVisual = nil;
    [self.edgeStrip removeFromSuperview];
    self.edgeStrip = nil;
    [super removeFromSuperview];
}

// 面板尺寸只由行数和收起状态决定；改 frame 时保持中心不动，
// 不在 layoutSubviews 里改帧。
- (void)applySize {
    UIView *root = self.superview;
    if (!root) return;
    CGFloat width = fmin(kDYYYLiveBoardOverlayWidth, fmax(120.0, CGRectGetWidth(root.bounds) - 16.0));
    CGFloat height = kDYYYLiveBoardOverlayHeaderHeight;
    if (!self.isCollapsed) {
        NSInteger rows = (NSInteger)MIN(self.sorted.count, kDYYYLiveBoardOverlayMaxVisibleRows);
        height += rows * kDYYYLiveBoardOverlayRowHeight;
    }
    CGPoint center = self.center;
    self.frame = CGRectIntegral(CGRectMake(center.x - width / 2.0, center.y - height / 2.0, width, height));
    // 尺寸变了也别出界。
    self.center = [self clampedCenter:self.center inRoot:root];
}

#pragma mark - 位置（与时长胶囊同款：中心百分比，横竖屏分别记）

- (BOOL)isLandscapeRoot:(UIView *)root {
    return CGRectGetWidth(root.bounds) > CGRectGetHeight(root.bounds);
}

- (NSString *)centerXKeyForRoot:(UIView *)root {
    return [self isLandscapeRoot:root] ? DYYYLiveBoardOverlayLandscapeCenterXPercentKey : DYYYLiveBoardOverlayCenterXPercentKey;
}

- (NSString *)centerYKeyForRoot:(UIView *)root {
    return [self isLandscapeRoot:root] ? DYYYLiveBoardOverlayLandscapeCenterYPercentKey : DYYYLiveBoardOverlayCenterYPercentKey;
}

- (CGPoint)clampedCenter:(CGPoint)center inRoot:(UIView *)root {
    if (!root) return center;
    UIEdgeInsets safeInsets = [root respondsToSelector:@selector(safeAreaInsets)] ? root.safeAreaInsets : UIEdgeInsetsZero;
    CGFloat halfWidth = CGRectGetWidth(self.bounds) / 2.0;
    CGFloat halfHeight = CGRectGetHeight(self.bounds) / 2.0;
    CGFloat minX = safeInsets.left + halfWidth + 4.0;
    CGFloat maxX = fmax(minX, CGRectGetWidth(root.bounds) - safeInsets.right - halfWidth - 4.0);
    CGFloat minY = safeInsets.top + halfHeight + 4.0;
    CGFloat maxY = fmax(minY, CGRectGetHeight(root.bounds) - safeInsets.bottom - halfHeight - 4.0);
    return CGPointMake(fmin(fmax(center.x, minX), maxX), fmin(fmax(center.y, minY), maxY));
}

- (void)saveCenter {
    UIView *root = self.superview;
    if (!root || CGRectGetWidth(root.bounds) <= 0.0 || CGRectGetHeight(root.bounds) <= 0.0) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.center.x / CGRectGetWidth(root.bounds) forKey:[self centerXKeyForRoot:root]];
    [defaults setDouble:self.center.y / CGRectGetHeight(root.bounds) forKey:[self centerYKeyForRoot:root]];
}

// 有存过的位置就恢复；没存过就放在时长胶囊下方（用户截图红框处）。
- (void)restorePositionInRoot:(UIView *)root {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *xKey = [self centerXKeyForRoot:root];
    NSString *yKey = [self centerYKeyForRoot:root];
    if ([defaults objectForKey:xKey] && [defaults objectForKey:yKey]) {
        CGFloat rootWidth = CGRectGetWidth(root.bounds);
        CGFloat rootHeight = CGRectGetHeight(root.bounds);
        if (rootWidth > 0.0 && rootHeight > 0.0) {
            CGFloat centerX = fmin(fmax([defaults doubleForKey:xKey], 0.0), 1.0) * rootWidth;
            CGFloat centerY = fmin(fmax([defaults doubleForKey:yKey], 0.0), 1.0) * rootHeight;
            self.center = [self clampedCenter:CGPointMake(centerX, centerY) inRoot:root];
            return;
        }
    }
    // 默认位置：时长胶囊下方 8pt；找不到时长胶囊时按安全区顶部估算。
    UIEdgeInsets safeInsets = [root respondsToSelector:@selector(safeAreaInsets)] ? root.safeAreaInsets : UIEdgeInsetsZero;
    CGFloat width = fmin(kDYYYLiveBoardOverlayWidth, fmax(120.0, CGRectGetWidth(root.bounds) - 16.0));
    CGFloat top = safeInsets.top + ([self isLandscapeRoot:root] ? 46.0 : 120.0);
    UIView *durationView = DYYYLiveBoardOverlayFindDurationView(root);
    if (durationView) top = CGRectGetMaxY(durationView.frame) + 8.0;
    CGFloat height = CGRectGetHeight(self.bounds) > 0 ? CGRectGetHeight(self.bounds) : kDYYYLiveBoardOverlayHeaderHeight;
    self.frame = CGRectIntegral(CGRectMake(safeInsets.left + 12.0, top, width, height));
    self.center = [self clampedCenter:self.center inRoot:root];
}

#pragma mark - 手势

- (void)handleHeaderTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    self.collapsed = !self.isCollapsed;
    [NSUserDefaults.standardUserDefaults setBool:self.isCollapsed forKey:DYYYLiveBoardOverlayCollapsedKey];
    [self refresh];
}

- (void)handleHeaderPan:(UIPanGestureRecognizer *)pan {
    UIView *root = self.superview;
    if (!root) return;
    // 2.2-9-79：右滑藏起来后，标题栏的 pan 不再把面板拉回来
    //（也不保存藏起时的位置）；同时把拖动残留的半透明状态清掉，
    // 免得滑回来时面板还是 0.85。
    if (self.isHiddenBySwipe) {
        self.dragging = NO;
        self.alpha = 1.0;
        return;
    }
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        self.alpha = 0.85;
    }
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [pan translationInView:root];
        CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        self.center = [self clampedCenter:newCenter inRoot:root];
        [pan setTranslation:CGPointZero inView:root];
    }
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
        self.dragging = NO;
        self.alpha = 1.0;
        [self saveCenter];
    }
}

#pragma mark - 右滑隐藏 / 左滑显示（2.2-9-75 右滑藏，2.2-9-77 左滑回）

// 小标签：外层是 40pt 宽的透明触摸区（按钮本身），里层是左贴边、
// 26pt 宽的视觉 pill（半透明黑底白字，跟面板同一透明度）。
// 触摸区比视觉宽 14pt，左滑手指行程才够；点按和左滑都把面板滑回来。
- (UIButton *)makePillButton {
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.backgroundColor = UIColor.clearColor;
    pill.accessibilityIdentifier = @"dyyy_live_board_overlay_tab";
    [pill addTarget:self action:@selector(handlePillTap:) forControlEvents:UIControlEventTouchUpInside];
    // 2.2-9-77：小标签上左滑 → 面板滑回来。
    UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillSwipeLeft:)];
    swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
    [pill addGestureRecognizer:swipeLeft];
    // 视觉 pill：26×68，左贴边。
    UIView *visual = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26.0, 68.0)];
    visual.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:[DYYYLiveBoardStore.shared overlayOpacity]];
    visual.layer.cornerRadius = 13.0;
    visual.layer.masksToBounds = YES;
    visual.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
    visual.layer.borderWidth = 0.5;
    visual.userInteractionEnabled = NO;
    UILabel *label = [[UILabel alloc] initWithFrame:visual.bounds];
    label.numberOfLines = 3;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = @"人\n气\n榜";
    label.textColor = UIColor.whiteColor;
    label.userInteractionEnabled = NO;
    [visual addSubview:label];
    [pill addSubview:visual];
    self.pillVisual = visual;
    return pill;
}

// 2.2-9-77：左边缘隐形条（20pt 宽、跟小标签同一高度），只在面板
// 藏着时存在。从它上面起手左滑也能把面板滑回来；它盖住了小标签
// 的左半边，所以点按同样恢复，免得点小标签左半边没反应。
// 面板显示时不装，不挡直播间其他手势。
- (UIView *)makeEdgeStrip {
    UIView *strip = [[UIView alloc] init];
    strip.backgroundColor = UIColor.clearColor;
    strip.accessibilityIdentifier = @"dyyy_live_board_overlay_edge";
    strip.userInteractionEnabled = YES;
    UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillSwipeLeft:)];
    swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
    [strip addGestureRecognizer:swipeLeft];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePillTap:)];
    [strip addGestureRecognizer:tap];
    return strip;
}

// 2.2-9-79：右滑手势与 pan 并行识别——标题栏的拖动 pan、表格的
// 滚动 pan、直播间容器的 pan 都不能再把右滑顶掉；只放行并行，
// 不改任何一个 pan 本身的行为。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return [otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]];
}

- (void)handleSwipeRight:(UISwipeGestureRecognizer *)swipe {
    if (swipe.state != UIGestureRecognizerStateRecognized) return;
    // 2.2-9-79：收起状态下右滑同样能藏（原来 isCollapsed 时直接
    // return，收起的面板右滑没反应；手势已移到面板容器上，
    // 标题栏起手也能触发）。
    if (self.isHiddenBySwipe) return;
    UIView *root = self.superview;
    if (!root || CGRectGetHeight(root.bounds) <= 0.0) return;
    self.hiddenBySwipe = YES;
    self.preHideCenter = self.center;
    self.pillCenterYPercent = self.center.y / CGRectGetHeight(root.bounds);
    UIButton *pill = [self makePillButton];
    self.pillButton = pill;
    CGFloat pillWidth = 40.0, pillHeight = 68.0;
    pill.frame = CGRectMake(0, self.center.y - pillHeight / 2.0, pillWidth, pillHeight);
    [root addSubview:pill];
    // 2.2-9-77：隐形条跟小标签同一高度、左贴边。
    UIView *strip = [self makeEdgeStrip];
    self.edgeStrip = strip;
    strip.frame = CGRectMake(0, self.center.y - pillHeight / 2.0, 20.0, pillHeight);
    [root addSubview:strip];
    [self updatePillPosition];
    CGRect targetFrame = self.frame;
    targetFrame.origin.x = -CGRectGetWidth(targetFrame) - 8.0;
    [UIView animateWithDuration:0.25 animations:^{
        self.frame = targetFrame;
    }];
}

// 点小标签（或隐形条）→ 面板滑回来，作左滑之外的备用。
- (void)handlePillTap:(__unused id)sender {
    [self restorePanel];
}

// 2.2-9-77：小标签 / 隐形条上左滑 → 面板滑回来。
- (void)handlePillSwipeLeft:(UISwipeGestureRecognizer *)swipe {
    if (swipe.state != UIGestureRecognizerStateRecognized) return;
    [self restorePanel];
}

// 恢复的唯一出口：小标签、隐形条和点按都走这里。
- (void)restorePanel {
    if (!self.isHiddenBySwipe) return;
    UIView *root = self.superview;
    if (!root) return;
    [self.pillButton removeFromSuperview];
    self.pillButton = nil;
    self.pillVisual = nil;
    [self.edgeStrip removeFromSuperview];
    self.edgeStrip = nil;
    self.hiddenBySwipe = NO;
    CGPoint target = [self clampedCenter:self.preHideCenter inRoot:root];
    [UIView animateWithDuration:0.25 animations:^{
        self.center = target;
    } completion:^(__unused BOOL finished) {
        [self refresh];
    }];
}

// 小标签跟面板当时同一高度；根视图尺寸变了（横竖屏）按百分比重算。
// 隐形条跟小标签同一高度、左贴边，一起重算。
- (void)updatePillPosition {
    UIView *root = self.superview;
    if (!root || !self.pillButton) return;
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    CGFloat centerY = rootHeight > 0 ? self.pillCenterYPercent * rootHeight : self.pillButton.center.y;
    UIEdgeInsets safeInsets = [root respondsToSelector:@selector(safeAreaInsets)] ? root.safeAreaInsets : UIEdgeInsetsZero;
    CGFloat halfHeight = CGRectGetHeight(self.pillButton.bounds) / 2.0;
    CGFloat minY = safeInsets.top + halfHeight + 4.0;
    CGFloat maxY = fmax(minY, rootHeight - safeInsets.bottom - halfHeight - 4.0);
    centerY = fmin(fmax(centerY, minY), maxY);
    self.pillButton.center = CGPointMake(CGRectGetWidth(self.pillButton.bounds) / 2.0, centerY);
    if (self.pillButton.superview) [self.pillButton.superview bringSubviewToFront:self.pillButton];
    if (self.edgeStrip) {
        self.edgeStrip.center = CGPointMake(CGRectGetWidth(self.edgeStrip.bounds) / 2.0, centerY);
        if (self.edgeStrip.superview) [self.edgeStrip.superview bringSubviewToFront:self.edgeStrip];
    }
}

#pragma mark - 每秒刷新（只改可见行的时长文字，不做网络请求）

// 2.2-9-80：原生清屏跟随——每秒跟住房间 UI 的实际可见状态。
// DYYY 清屏激活时直接让位（hidden 归 DYYYRefreshViewsAfterClearToggle
// 那条路管，本方法不记录也不改状态，DYYY 清屏退出后下一跳重新算）。
// 收起/拖动时也要跑（收起的面板只剩标题行，清屏时同样要藏）。
- (void)updateNativeClearState {
    if (DYYYClearButtonIsHiding()) return;
    UIView *root = self.superview;
    if (!root) return;
    BOOL hasLabel = DYYYLiveBoardOverlayRootHasVisibleNativeLabel(root);
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
    self.pillButton.hidden = cleared;
    self.edgeStrip.hidden = cleared;
}

- (void)startTick {
    [self stopTick];
    __weak typeof(self) weakSelf = self;
    self.tickTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        DYYYLiveBoardOverlayView *self = weakSelf;
        if (!self || !self.window) return;
        // 后台不刷（直播间只在前台看得到，退后台进程也会被挂起）。
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        // 2.2-9-80：原生清屏跟随在收起/拖动时也要跑，放在 early return 之前。
        [self updateNativeClearState];
        if (self.isCollapsed || self.isDragging) return;
        for (DYYYLiveBoardOverlayCell *cell in self.tableView.visibleCells) {
            NSIndexPath *path = [self.tableView indexPathForCell:cell];
            if (!path || path.row >= (NSInteger)self.sorted.count) continue;
            NSDictionary *anchor = self.sorted[(NSUInteger)path.row];
            NSString *detail = [self detailForAnchor:anchor];
            if ([cell.detailLabel.text isEqualToString:detail]) continue;
            cell.detailLabel.text = detail;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:self.tickTimer forMode:NSRunLoopCommonModes];
}

- (void)stopTick {
    [self.tickTimer invalidate];
    self.tickTimer = nil;
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.sorted.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DYYYLiveBoardOverlayCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DYYYLiveBoardOverlayCell" forIndexPath:indexPath];
    NSDictionary *anchor = self.sorted[(NSUInteger)indexPath.row];
    NSDictionary *state = [DYYYLiveBoardMonitor.shared stateForUID:anchor[@"uid"]];
    BOOL live = [state[@"live"] boolValue];
    // 自定义名字优先（remark），没设才显示昵称（DYYYRadarDisplayName 同款顺序）。
    cell.nameLabel.text = DYYYRadarDisplayName(anchor);
    cell.detailLabel.text = [self detailForAnchor:anchor];
    cell.dotView.backgroundColor = live ? [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0] : [UIColor lightGrayColor];
    cell.detailLabel.textColor = live ? [UIColor.whiteColor colorWithAlphaComponent:0.9] : [UIColor.whiteColor colorWithAlphaComponent:0.55];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.sorted.count) return;
    NSDictionary *anchor = self.sorted[(NSUInteger)indexPath.row];
    NSDictionary *state = [DYYYLiveBoardMonitor.shared stateForUID:anchor[@"uid"]];
    NSString *roomID = DYYYRadarString(state[@"roomID"]);
    if ([state[@"live"] boolValue] && roomID.length) {
        if (DYYYLiveBoardOpenLiveRoom(roomID, anchor[@"uid"])) return;
        if (DYYYLiveBoardOpenProfile(anchor[@"uid"])) return;
        return;
    }
    DYYYLiveBoardOpenProfile(anchor[@"uid"]);
}

@end

#pragma mark - 安装 / 拆除

// 2.2-9-73：最后一次见到的房间 root（弱引用）。进房间时主播还没加完
// （ShouldShow 为假、没装上），之后在设置页加了主播、人在房间里没退出
// 重进，StoreChanged 的 watcher 用这个 root 补装。
static __weak UIView *sDYYYLiveBoardOverlayLastRoot;
static id sDYYYLiveBoardOverlayWatcherToken;

// 房间里加了主播/改了开关后，给正在开着的房间补装悬浮榜（StoreChanged 时调）。
// 只在 lastRoot 还在窗口里时装；安装本身幂等，已装上时只刷新 + 置顶。
void DYYYLiveBoardOverlayStartWatcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDYYYLiveBoardOverlayWatcherToken = [NSNotificationCenter.defaultCenter addObserverForName:DYYYLiveBoardStoreChanged object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            UIView *root = sDYYYLiveBoardOverlayLastRoot;
            if (!root || !root.window) return;
            DYYYLiveBoardOverlayInstallOnView(root);
        }];
    });
}

BOOL DYYYLiveBoardOverlayShouldShow(void) {
    return [DYYYLiveBoardStore.shared enabled] && [DYYYLiveBoardStore.shared overlayEnabled] &&
        DYYYLiveBoardStore.shared.anchors.count > 0;
}

static UIViewController *DYYYLiveBoardOverlayAudienceVC(id container) {
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

void DYYYLiveBoardOverlayInstallOnView(UIView *root) {
    if (!root) return;
    // 记住最后一次见到的房间 root（弱引用），StoreChanged 的 watcher 补装用。
    sDYYYLiveBoardOverlayLastRoot = root;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardOverlayInstallOnView(root); });
        return;
    }
    [DYYYLiveBoardMonitor.shared synchronizeAccount];
    DYYYLiveBoardOverlayView *overlay = objc_getAssociatedObject(root, kDYYYLiveBoardOverlayViewKey);
    if (!DYYYLiveBoardOverlayShouldShow()) {
        [overlay removeFromSuperview];
        if (overlay) objc_setAssociatedObject(root, kDYYYLiveBoardOverlayViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    if (!overlay || overlay.superview != root) {
        overlay = [[DYYYLiveBoardOverlayView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(root, kDYYYLiveBoardOverlayViewKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [root addSubview:overlay];
        [overlay restorePositionInRoot:root];
    }
    [root bringSubviewToFront:overlay];
    [overlay refresh];
    // 2.2-9-80：DYYY 清屏已激活时才装上的面板也要跟着藏（比如推荐页
    // 点了 DYYY 清屏按钮后进直播间，isElementsHidden 会一直保持到再
    // 点一次）；原生清屏那头由面板 tick 里的 updateNativeClearState 跟随。
    if (DYYYClearButtonIsHiding()) overlay.hidden = YES;
    if ([DYYYLiveBoardStore.shared enabled]) [DYYYLiveBoardMonitor.shared checkNow];
}

void DYYYLiveBoardOverlayRemoveFromView(UIView *root) {
    if (!root) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYLiveBoardOverlayRemoveFromView(root); });
        return;
    }
    DYYYLiveBoardOverlayView *overlay = objc_getAssociatedObject(root, kDYYYLiveBoardOverlayViewKey);
    [overlay removeFromSuperview];
    objc_setAssociatedObject(root, kDYYYLiveBoardOverlayViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

void DYYYLiveBoardOverlayInstallFromContainer(id container) {
    UIViewController *viewController = DYYYLiveBoardOverlayAudienceVC(container);
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardOverlayInstallOnView(viewController.view);
}

void DYYYLiveBoardOverlayInstallFromAudienceWrapper(id wrapper) {
    UIViewController *viewController = nil;
    @try {
        viewController = [wrapper valueForKey:@"audienceViewController"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardOverlayInstallOnView(viewController.view);
}

// 2.2-9-73：直播广场/推荐页上下滑切换的房间（inner feed cell），
// 开播时长胶囊有这条安装路（DYYY.xm 的 IESLiveInnerFeedLiveRoomCell），
// 悬浮榜 -72 只有容器和 wrapper 两条，所以滑着进的房间不显示。
// 挂载点与时长胶囊一致：cell 的 audienceVC.view。
void DYYYLiveBoardOverlayInstallFromInnerFeedCell(id cell) {
    UIViewController *viewController = nil;
    @try {
        viewController = [cell valueForKey:@"audienceVC"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardOverlayInstallOnView(viewController.view);
}

void DYYYLiveBoardOverlayRemoveFromInnerFeedCell(id cell) {
    UIViewController *viewController = nil;
    @try {
        viewController = [cell valueForKey:@"audienceVC"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardOverlayRemoveFromView(viewController.view);
}

void DYYYLiveBoardOverlayRemoveFromContainer(id container) {
    UIViewController *viewController = DYYYLiveBoardOverlayAudienceVC(container);
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardOverlayRemoveFromView(viewController.view);
}

void DYYYLiveBoardOverlayRemoveFromAudienceWrapper(id wrapper) {
    UIViewController *viewController = nil;
    @try {
        viewController = [wrapper valueForKey:@"audienceViewController"];
    } @catch (__unused NSException *exception) {
        viewController = nil;
    }
    if ([viewController isKindOfClass:UIViewController.class]) DYYYLiveBoardOverlayRemoveFromView(viewController.view);
}
