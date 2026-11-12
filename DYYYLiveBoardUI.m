// DYYYLiveBoardUI.m — 见 DYYYLiveBoardUI.h。
// 行用 DYYYRadarPersonCell（46pt 圆头像 + 异步加载，与特别关注同款）；
// 开播时长每秒跳一次，只改可见行的副标题文字，不 reloadData、不动布局
// （不在 layoutSubviews 里改帧，-53/-57 教训）；排序只在状态变化时重排。
#import "DYYYLiveBoardAudienceEntry.h"
#import "DYYYLiveBoardCapsule.h"
#import "DYYYLiveBoardUI.h"
#import "DYYYLiveBoardApi.h"
#import "DYYYLiveBoardModel.h"
#import "DYYYLiveBoardMonitor.h"
#import "DYYYLiveBoardOverlay.h"
#import "DYYYLiveBoardStore.h"
#import "DYYYFansModel.h"
#import "DYYYFansService.h"
#import "DYYYPortsUI.h"
#import "DYYYRadarApi.h"
#import "DYYYRadarModel.h"
#import "DYYYRadarNetwork.h"
#import "DYYYRadarUI.h"

void DYYYInstallLiveBoard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [DYYYLiveBoardMonitor.shared start];
        // 2.2-9-73：房间里加了主播/改了开关后，给正在开着的房间补装悬浮榜。
        DYYYLiveBoardOverlayStartWatcher();
        // 2.2-9-92：同款，给正在开着的房间补装“人气榜”小胶囊。
        DYYYLiveBoardCapsuleStartWatcher();
    });
}

// MARK: - 透明度滑杆行（2.2-9-75；照抄 -68 直播信息页的 DY778SliderCell
// 做法：标题 + 数值一行、滑杆在下，纯 Auto Layout、标准 UISlider）
// 范围 20%–100%，默认 64%；值按 double 存 DYYYLiveBoardOverlayOpacityKey，
// 只改面板黑底的 alpha，文字保持全不透明。
@interface DYYYLiveBoardOpacitySliderCell : UITableViewCell
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
// 2.2-9-94：同一行复用到“弹窗背景”——标题/范围/存的键可配，
// 默认仍是悬浮榜透明度那套（标题“悬浮榜透明度”、0.2–1.0、@"opacity"）。
@property(nonatomic, copy) NSString *titleText;
@property(nonatomic, assign) float minValue;
@property(nonatomic, assign) float maxValue;
@property(nonatomic, copy) NSString *optionKey;
// 2.2-9-98：字号滑杆用——步长（默认 0.01，即原来的两位小数；字号行
// 设 1.0，按整 pt 走）与数值显示方式（默认百分比；字号行显示“13 pt”）。
@property(nonatomic, assign) float stepValue;
@property(nonatomic, assign) BOOL displayAsPoints;
- (void)updateValue;
@end

@implementation DYYYLiveBoardOpacitySliderCell

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _nameLabel = [UILabel new];
        _titleText = @"悬浮榜透明度";
        _nameLabel.text = _titleText;
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _nameLabel.adjustsFontForContentSizeCategory = YES;
        _nameLabel.numberOfLines = 0;
        _nameLabel.textColor = UIColor.labelColor;
        _valueLabel = [UILabel new];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        _valueLabel.textColor = DYYYRadarAccent();
        [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _valueLabel]];
        top.spacing = 12;
        _slider = [UISlider new];
        _minValue = 0.2f;
        _maxValue = 1.0f;
        _optionKey = @"opacity";
        _stepValue = 0.01f;
        _displayAsPoints = NO;
        _slider.minimumValue = _minValue;
        _slider.maximumValue = _maxValue;
        _slider.minimumTrackTintColor = DYYYRadarAccent();
        [_slider addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(dragEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, _slider]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 7;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:15],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
            [_slider.heightAnchor constraintGreaterThanOrEqualToConstant:36]
        ]];
    }
    return self;
}

- (void)setTitleText:(NSString *)titleText { _titleText = [titleText copy]; self.nameLabel.text = _titleText; }
- (void)setMinValue:(float)minValue { _minValue = minValue; self.slider.minimumValue = minValue; }
- (void)setMaxValue:(float)maxValue { _maxValue = maxValue; self.slider.maximumValue = maxValue; }
- (void)setOptionKey:(NSString *)optionKey { _optionKey = [optionKey copy]; }

- (void)updateValue {
    if (self.displayAsPoints) self.valueLabel.text = [NSString stringWithFormat:@"%.0f pt", self.slider.value];
    else self.valueLabel.text = [NSString stringWithFormat:@"%.0f%%", self.slider.value * 100];
    self.slider.accessibilityValue = self.valueLabel.text;
}

- (void)changed:(UISlider *)slider {
    // 按步长取整后实时写 store（发 StoreChanged，面板/胶囊立即改样式）；
    // 步长 0.01 时与原来保留 2 位小数完全一致，字号行步长 1.0 按整 pt 走。
    float step = self.stepValue > 0 ? self.stepValue : 0.01f;
    float value = roundf(slider.value / step) * step;
    slider.value = value;
    [self updateValue];
    [DYYYLiveBoardStore.shared setOption:self.optionKey value:@(value)];
}

- (void)dragEnded:(__unused UISlider *)slider {
    if (self.onDragEnd) self.onDragEnd();
}

@end

@interface DYYYLiveBoardViewController ()
@property(nonatomic, strong) NSArray<NSDictionary *> *sorted;
@property(nonatomic, strong) NSTimer *tickTimer;
// 2.2-9-72：星牌解析服务（resolveInput 期间持有，流程结束即释放）。
@property(nonatomic, strong) DYYYFansService *fansService;
// 2.2-9-95：紧凑模式副标题（在播行的 ● 变绿、其余文字加深），
// cellForRow 与每秒 tick 共用；完整模式不用它。
- (NSAttributedString *)attributedSubtitleForAnchor:(NSDictionary *)anchor;
// 2.2-9-96：“添加主播”按钮（紧凑模式专用，见 viewDidLoad）。
- (void)addAnchorFromSheet:(id)sender;
@end

@implementation DYYYLiveBoardViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.hidesBottomBarWhenPushed = YES;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 2.2-9-93：紧凑模式标题只叫“人气榜”，完整模式仍是“直播间人气榜”。
    self.title = self.compactListOnly ? @"人气榜" : @"直播间人气榜";
    self.view.tintColor = DYYYRadarAccent();
    self.tableView.backgroundColor = DYYYRadarBackground();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70;
    self.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.backButtonTitle = @"返回";
    if (self.compactListOnly) {
        // 2.2-9-96：底页右上角只留“添加主播”一个按钮，且用 plain 样式——
        // 跟左边“关闭”按钮同一套做法，系统渲染成同样的浅色胶囊，不再
        // 是 -95 那个黑底自定义 pill（用户嫌丑）；“悬浮窗”按钮已取消。
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"添加主播" style:UIBarButtonItemStylePlain target:self action:@selector(addAnchorFromSheet:)];
        NSLog(@"[DYYY-96] compact sheet opened");
    }
    [self applySheetBackground];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:DYYYLiveBoardChanged object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:DYYYLiveBoardStoreChanged object:nil];
    // 2.2-9-80：长按主播行 → 菜单（改名字 / 移除），与左滑菜单同一套流程。
    // 长按要按住 0.5 秒不动才触发，滚动/点按不受影响；左滑菜单保留不动。
    UILongPressGestureRecognizer *anchorLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleAnchorLongPress:)];
    [self.tableView addGestureRecognizer:anchorLongPress];
    [self resort];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [DYYYLiveBoardMonitor.shared synchronizeAccount];
    [self resort];
    [self.tableView reloadData];
    [self applySheetBackground];
    if ([DYYYLiveBoardStore.shared enabled]) [DYYYLiveBoardMonitor.shared checkNow];
    [self startTick];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopTick];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stopTick];
}

#pragma mark - 排序与文案

// 在播按人数从高到低，未开播沉底，从未查到过/只有失败的最后。
// 人数没读到的在播按 0 算，排在有数的在播之后、未开播之前。
- (void)resort {
    NSArray<NSDictionary *> *anchors = DYYYLiveBoardStore.shared.anchors;
    self.sorted = [anchors sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
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

// 2.2-9-93：主播行所在组——完整模式是 section 1，紧凑模式只有 1 组、
// 主播行就是 section 0。以下所有按组号分的逻辑都走它，不再写死 1。
- (NSInteger)anchorSection { return self.compactListOnly ? 0 : 1; }

- (NSString *)subtitleForAnchor:(NSDictionary *)anchor {
    NSDictionary *state = [DYYYLiveBoardMonitor.shared stateForUID:anchor[@"uid"]];
    NSString *error = DYYYRadarString(state[@"error"]);
    if ([state[@"live"] boolValue]) {
        if (self.compactListOnly) {
            // 2.2-9-93：紧凑模式副标题分两行写死换行，不让系统在词中换行——
            // 第 1 行“在播 · 在线人数”，第 2 行“场观 · 已播时长”；
            // 没读到的那项不写，不断词、不断行。
            NSMutableString *line1 = [NSMutableString stringWithString:@"● 在播"];
            NSNumber *viewers = state[@"viewers"];
            if (viewers) [line1 appendFormat:@" · %@在线", DYYYLiveBoardFormatCountCompact(viewers.longLongValue)];
            else [line1 appendString:@" · 在线人数暂未读到"];
            NSMutableArray<NSString *> *line2Parts = [NSMutableArray array];
            NSNumber *total = state[@"totalViewers"];
            if (total.longLongValue > 0) [line2Parts addObject:[NSString stringWithFormat:@"场观 %@", DYYYLiveBoardFormatCountCompact(total.longLongValue)]];
            NSString *digits = [state[@"start"] doubleValue] > 0 ? DYYYLiveBoardElapsedDigits([state[@"start"] doubleValue]) : nil;
            if (digits.length) [line2Parts addObject:[NSString stringWithFormat:@"已播 %@", digits]];
            NSString *text = line1;
            if (line2Parts.count) text = [text stringByAppendingFormat:@"\n%@", [line2Parts componentsJoinedByString:@" · "]];
            if (error.length) text = [text stringByAppendingString:@"\n上次刷新失败，显示的是上次数据"];
            return text;
        }
        NSMutableString *text = [NSMutableString stringWithString:@"● 在播"];
        NSNumber *viewers = state[@"viewers"];
        if (viewers) [text appendFormat:@" · %@在线", DYYYLiveBoardFormatCountCompact(viewers.longLongValue)];
        else [text appendString:@" · 在线人数暂未读到"];
        // 2.2-9-81：场观（累计进场人数），在线人数之后、已播时长之前；
        // 没读到时不显示，不显示“场观 0”。
        NSNumber *total = state[@"totalViewers"];
        if (total.longLongValue > 0) [text appendFormat:@" · 场观 %@", DYYYLiveBoardFormatCountCompact(total.longLongValue)];
        NSString *digits = [state[@"start"] doubleValue] > 0 ? DYYYLiveBoardElapsedDigits([state[@"start"] doubleValue]) : nil;
        if (digits.length) [text appendFormat:@" · 已播 %@", digits];
        if (error.length) [text appendString:@"\n上次刷新失败，显示的是上次数据"];
        return text;
    }
    if ([state[@"checkedAt"] doubleValue] > 0 && !error.length) return @"未开播";
    if (error.length) return [NSString stringWithFormat:@"读取失败：%@", error];
    return @"暂未读取";
}

// 2.2-9-95：紧凑模式专用——副标题的富文本版。在播行开头的 ●
// 涂绿（RGB 0.20 / 0.78 / 0.35，与 -90 的行图标同款绿），其余文字
// 涂深灰（white 0.30，见变化 2）；未开播行没有 ●，整行都是深灰。
// 只在紧凑模式调，完整模式继续走 plain secondaryText。
- (NSAttributedString *)attributedSubtitleForAnchor:(NSDictionary *)anchor {
    NSString *subtitle = [self subtitleForAnchor:anchor];
    UIColor *subColor = [UIColor colorWithWhite:0.30 alpha:1.0];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc]
        initWithString:subtitle attributes:@{NSForegroundColorAttributeName: subColor}];
    if ([subtitle hasPrefix:@"●"]) {
        UIColor *green = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        [attr addAttribute:NSForegroundColorAttributeName value:green range:NSMakeRange(0, 1)];
    }
    return attr;
}

// 2.2-9-95：“添加主播”——复用设置页同一套 addAnchorSheet 流程
//（抖音号 / UID / 分享链接，核对后添加，上限 20）。
- (void)addAnchorFromSheet:(id)sender {
    (void)sender;
    NSLog(@"[DYYY-95] add-anchor button: open addAnchorSheet");
    [self addAnchorSheet];
}

// 2.2-9-94：紧凑模式（底页）才调底色不透明度——表底 + 行底 +
// 导航栏底色按“弹窗背景”滑杆值走，文字全不透明；完整模式（设置页）不动。
// StoreChanged 会走到 reload，滑杆拖动时底页实时跟着变。
- (void)applySheetBackground {
    if (!self.compactListOnly) return;
    CGFloat alpha = (CGFloat)[DYYYLiveBoardStore.shared sheetBackgroundOpacity];
    UIColor *bg = [DYYYRadarBackground() colorWithAlphaComponent:alpha];
    self.view.backgroundColor = bg;
    self.tableView.backgroundColor = bg;
    self.navigationController.navigationBar.barTintColor = bg;
    // 2.2-9-95：底页文字加深——导航标题近黑、“关闭”按钮近黑
    //（tintColor 影响 plain 按钮；2.2-9-96 起右上角“添加主播”也是
    // plain，跟“关闭”一样近黑）；文字全不透明，滑杆行为不变。
    UIColor *nearBlack = [UIColor colorWithWhite:0.05 alpha:1.0];
    self.navigationController.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: nearBlack};
    self.navigationController.navigationBar.tintColor = nearBlack;
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        cell.backgroundColor = bg;
        cell.contentView.backgroundColor = UIColor.clearColor;
    }
}

- (void)reload {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self reload]; }); return; }
    // 2.2-9-75：拖透明度滑杆时不重建 cell，否则拖动会被打断
    //（滑杆值已实时写入 store，label 由 cell 自己维护；松手后 onDragEnd 再 reload）。
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell isKindOfClass:DYYYLiveBoardOpacitySliderCell.class]) {
            if (((DYYYLiveBoardOpacitySliderCell *)cell).slider.isTracking) return;
        }
    }
    [self resort];
    [self.tableView reloadData];
    [self applySheetBackground];
}

// 每秒只改可见行副标题里的“已播 HH:MM:SS”，不动布局、不重排。
- (void)startTick {
    [self stopTick];
    __weak typeof(self) weakSelf = self;
    self.tickTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        DYYYLiveBoardViewController *self = weakSelf;
        if (!self || !self.view.window) return;
        for (UITableViewCell *cell in self.tableView.visibleCells) {
            NSIndexPath *path = [self.tableView indexPathForCell:cell];
            if (!path || path.section != [self anchorSection] || path.row >= (NSInteger)self.sorted.count) continue;
            NSDictionary *anchor = self.sorted[(NSUInteger)path.row];
            UIListContentConfiguration *config = [(UIListContentConfiguration *)cell.contentConfiguration copy];
            NSString *subtitle = [self subtitleForAnchor:anchor];
            if ([config.secondaryText isEqualToString:subtitle]) continue;
            config.secondaryText = subtitle;
            if (self.compactListOnly) {
                // 2.2-9-95：先设 plain 文本（上面那行相等判断用它），再盖
                // 富文本——否则下一秒 tick 会把绿点刷回普通灰字。
                config.secondaryAttributedText = [self attributedSubtitleForAnchor:anchor];
            }
            cell.contentConfiguration = config;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:self.tickTimer forMode:NSRunLoopCommonModes];
}
- (void)stopTick { [self.tickTimer invalidate]; self.tickTimer = nil; }

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // 2.2-9-93：紧凑模式只有主播列表 1 组。
    return self.compactListOnly ? 1 : 3;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == [self anchorSection]) return (NSInteger)self.sorted.count;
    if (section == 0) return 8;
    return 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == [self anchorSection]) return [NSString stringWithFormat:@"主播 · %lu / %lu", (unsigned long)self.sorted.count, (unsigned long)DYYYLiveBoardMaxAnchors];
    if (section == 0) return @"设置";
    return @"添加主播";
}
// 2.2-9-95：紧凑模式组头“主播 · N/20”加深（white 0.35）；完整模式
// 与设置页不动（系统默认色）。
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (!self.compactListOnly || section != [self anchorSection]) return;
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        ((UITableViewHeaderFooterView *)view).textLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    }
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    // 2.2-9-93：紧凑模式没有页脚（“上次刷新…”那行不要了）；完整模式
    // 第 0 组页脚也不再带入口诊断（-93 已关掉，见 AudienceEntry.m）。
    if (self.compactListOnly) return nil;
    if (section != 1) {
        if (section == 0) return @"关闭总开关后停止轮询，已加的主播会保留。";
        return @"输入对方主页显示的抖音号、UID 或分享链接，核对后添加；每位主播先查在没在播，\n在播才拉人数和开播时长。榜单里左滑一行可以改名字或移除主播，也可以长按一行改名字或移除主播。";
    }
    NSTimeInterval last = [DYYYLiveBoardMonitor.shared lastCheckAt];
    NSString *source = [DYYYLiveBoardMonitor.shared lastSource];
    NSString *failure = [DYYYLiveBoardMonitor.shared lastFailure];
    // 2.2-9-74：页脚如实写最后实际走通的是哪条；全失败时写三路断在哪一步。
    NSString *sourceText;
    if (failure.length) sourceText = [NSString stringWithFormat:@"失败（%@）", failure];
    else if ([source isEqualToString:@"fans"]) sourceText = @"星牌解析 roomID";
    else if ([source isEqualToString:@"profile"]) sourceText = @"资料接口";
    else if ([source isEqualToString:@"reflow"]) sourceText = @"资料接口（reflow 兜底）";
    else sourceText = @"—";
    NSString *timeText = @"还没刷新过";
    if (last > 0) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
        timeText = [NSString stringWithFormat:@"上次刷新 %@", [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:last]]];
    }
    return [NSString stringWithFormat:@"%@ · 取数：%@\n只在抖音前台轮询，退后台即停；主播较多时一轮要排队，先查最久没查的那位。", timeText, sourceText];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == [self anchorSection]) {
        NSDictionary *anchor = self.sorted[(NSUInteger)path.row];
        UITableViewCell *cell = DYYYRadarPersonCell(anchor, [self subtitleForAnchor:anchor], YES);
        if (self.compactListOnly) {
            // 2.2-9-94：底页行底跟“弹窗背景”滑杆走（行每次重建，这里现设）。
            CGFloat alpha = (CGFloat)[DYYYLiveBoardStore.shared sheetBackgroundOpacity];
            UIColor *bg = [DYYYRadarBackground() colorWithAlphaComponent:alpha];
            cell.backgroundColor = bg;
            cell.contentView.backgroundColor = UIColor.clearColor;
            UIView *selectedBackground = [[UIView alloc] init];
            selectedBackground.backgroundColor = [UIColor colorWithWhite:0.80 alpha:alpha];
            cell.selectedBackgroundView = selectedBackground;
            // 2.2-9-95：底页文字加深——名字近黑（white 0.05）、副标题
            // 深灰（white 0.30，富文本里自带同色），两行副标题不裁剪；
            // 在播行开头的 ● 涂绿（attributedSubtitleForAnchor:）。
            UIListContentConfiguration *config = [(UIListContentConfiguration *)cell.contentConfiguration copy];
            config.textProperties.color = [UIColor colorWithWhite:0.05 alpha:1.0];
            config.secondaryTextProperties.color = [UIColor colorWithWhite:0.30 alpha:1.0];
            config.secondaryTextProperties.numberOfLines = 0;
            config.secondaryAttributedText = [self attributedSubtitleForAnchor:anchor];
            cell.contentConfiguration = config;
        }
        return cell;
    }
    if (path.section == 0) {
        if (path.row == 0) {
            UITableViewCell *cell = DYYYPortsIconCell(@"开启人气榜", [DYYYLiveBoardStore.shared enabled] ? @"正在前台轮询" : @"关闭后停止轮询", @"person.3.sequence.fill", NO);
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = [DYYYLiveBoardStore.shared enabled];
            toggle.tag = 0;
            [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            return cell;
        }
        if (path.row == 1) {
            // 2.2-9-72：直播间内悬浮显示开关（默认开；总开关关着时悬浮也不显示）。
            BOOL overlayOn = [DYYYLiveBoardStore.shared overlayEnabled];
            UITableViewCell *cell = DYYYPortsIconCell(@"直播间内悬浮显示", overlayOn ? @"进直播间后左上角显示主播人气" : @"关闭后直播间里不显示悬浮榜", @"rectangle.stack.fill", NO);
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = overlayOn;
            toggle.tag = 1;
            [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            return cell;
        }
        if (path.row == 2) {
            // 2.2-9-75：悬浮榜透明度滑杆（20%–100%，默认 64%，只改黑底）。
            DYYYLiveBoardOpacitySliderCell *cell = [[DYYYLiveBoardOpacitySliderCell alloc] init];
            cell.slider.value = (float)[DYYYLiveBoardStore.shared overlayOpacity];
            [cell updateValue];
            __weak typeof(self) weakSelf = self;
            cell.onDragEnd = ^{ [weakSelf reload]; };
            return cell;
        }
        if (path.row == 3) {
            // 2.2-9-94：弹窗背景滑杆（30%–100%，默认 85%，只改底页底色）。
            DYYYLiveBoardOpacitySliderCell *cell = [[DYYYLiveBoardOpacitySliderCell alloc] init];
            cell.titleText = @"弹窗背景";
            cell.minValue = 0.3f;
            cell.maxValue = 1.0f;
            cell.optionKey = @"sheetBackgroundOpacity";
            cell.slider.value = (float)[DYYYLiveBoardStore.shared sheetBackgroundOpacity];
            [cell updateValue];
            __weak typeof(self) weakSelf = self;
            cell.onDragEnd = ^{ [weakSelf reload]; };
            return cell;
        }
        if (path.row == 4) {
            // 2.2-9-98：胶囊背景透明滑杆（10%–100%，默认 42%，只改胶囊黑底）。
            DYYYLiveBoardOpacitySliderCell *cell = [[DYYYLiveBoardOpacitySliderCell alloc] init];
            cell.titleText = @"胶囊背景透明";
            cell.minValue = 0.1f;
            cell.maxValue = 1.0f;
            cell.optionKey = @"capsuleBackgroundOpacity";
            cell.slider.value = (float)[DYYYLiveBoardStore.shared capsuleBackgroundOpacity];
            [cell updateValue];
            __weak typeof(self) weakSelf = self;
            cell.onDragEnd = ^{ [weakSelf reload]; };
            return cell;
        }
        if (path.row == 5) {
            // 2.2-9-98：胶囊字体大小滑杆（11–18pt，默认 13pt，胶囊高度 = 字号 + 13）。
            DYYYLiveBoardOpacitySliderCell *cell = [[DYYYLiveBoardOpacitySliderCell alloc] init];
            cell.titleText = @"胶囊字体大小";
            cell.minValue = 11.0f;
            cell.maxValue = 18.0f;
            cell.stepValue = 1.0f;
            cell.displayAsPoints = YES;
            cell.optionKey = @"capsuleFontSize";
            cell.slider.value = (float)[DYYYLiveBoardStore.shared capsuleFontSize];
            [cell updateValue];
            __weak typeof(self) weakSelf = self;
            cell.onDragEnd = ^{ [weakSelf reload]; };
            return cell;
        }
        if (path.row == 6) return DYYYPortsValueCell(@"刷新间隔", [NSString stringWithFormat:@"每 %ld 秒一轮", (long)[DYYYLiveBoardStore.shared interval]], @"timer", YES);
        if (path.row == 7) return DYYYPortsIconCell(@"立即刷新", DYYYLiveBoardMonitor.shared.status, @"arrow.clockwise", NO);
        return DYYYPortsIconCell(@"立即刷新", DYYYLiveBoardMonitor.shared.status, @"arrow.clockwise", NO);
    }
    return DYYYPortsIconCell(@"添加主播", @"输入抖音号、UID 或分享链接，核对后添加", @"person.crop.circle.badge.plus", YES);
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path { return path.section == [self anchorSection]; }
// 2.2-9-72：左滑菜单改名字 + 移除（替换原来的 commitEditingStyle 删除）。
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section != [self anchorSection]) return nil;
    NSDictionary *anchor = self.sorted[(NSUInteger)path.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"改名字" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completion)(BOOL)) {
        [weakSelf renameAnchor:anchor];
        completion(YES);
    }];
    rename.backgroundColor = DYYYRadarAccent();
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"移除" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completion)(BOOL)) {
        NSString *name = DYYYRadarDisplayName(anchor);
        DYYYRadarConfirm(weakSelf, @"移除这位主播？", [NSString stringWithFormat:@"%@ 将不再出现在人气榜里。", name], @"移除", ^{
            [DYYYLiveBoardStore.shared removeAnchor:anchor[@"uid"]];
            [DYYYLiveBoardMonitor.shared invalidateTarget:anchor[@"uid"]];
            [weakSelf reload];
        });
        completion(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove, rename]];
}

// 2.2-9-80：长按主播行 → 菜单（改名字 / 移除），与左滑菜单同一套流程
// （改名字走 renameAnchor:，移除走 DYYYRadarConfirm 确认框 +
// removeAnchor: + invalidateTarget: + reload）。只在 Began 时触发一次；
// 只认 section 1 的主播行，其他组长按不响应。
- (void)handleAnchorLongPress:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[press locationInView:self.tableView]];
    if (!path || path.section != [self anchorSection] || path.row >= (NSInteger)self.sorted.count) return;
    NSDictionary *anchor = self.sorted[(NSUInteger)path.row];
    NSString *name = DYYYRadarDisplayName(anchor);
    __weak typeof(self) weakSelf = self;
    DYYYRadarSheet(self, name, @[@"改名字", @"移除"], ^(NSUInteger index) {
        DYYYLiveBoardViewController *self = weakSelf; if (!self) return;
        if (index == 0) {
            [self renameAnchor:anchor];
            return;
        }
        DYYYRadarConfirm(self, @"移除这位主播？", [NSString stringWithFormat:@"%@ 将不再出现在人气榜里。", name], @"移除", ^{
            [DYYYLiveBoardStore.shared removeAnchor:anchor[@"uid"]];
            [DYYYLiveBoardMonitor.shared invalidateTarget:anchor[@"uid"]];
            [self reload];
        });
    });
}

#pragma mark - 操作

- (void)toggle:(UISwitch *)toggle {
    if (toggle.tag == 1) {
        // 2.2-9-72：直播间内悬浮显示开关。
        [DYYYLiveBoardStore.shared setOption:@"overlay" value:@(toggle.on)];
        [self reload];
        return;
    }
    [DYYYLiveBoardStore.shared setOption:@"enabled" value:@(toggle.on)];
    if (toggle.on) [DYYYLiveBoardMonitor.shared checkNow];
    [self reload];
}
- (void)editInterval {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"刷新间隔" message:@"输入 10–300 秒的整数。一轮按主播依次查，人多时实际周期会比这个长。" preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = DYYYRadarStyle(); alert.view.tintColor = DYYYRadarAccent();
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.text = [NSString stringWithFormat:@"%ld", (long)[DYYYLiveBoardStore.shared interval]];
        field.placeholder = @"默认 30 秒";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSNumber *value = DYYYRadarCount(weakAlert.textFields.firstObject.text);
        if (!value || value.integerValue < 10 || value.integerValue > 300) {
            dispatch_async(dispatch_get_main_queue(), ^{ DYYYRadarMessage(self, @"间隔不合适", @"请输入 10 到 300 之间的整数秒数。原设置已保留。"); });
            return;
        }
        [DYYYLiveBoardStore.shared setOption:@"interval" value:value];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    // 2.2-9-93：主播行先认（紧凑模式它在 section 0，完整模式在 section 1）。
    if (path.section == [self anchorSection]) {
        NSDictionary *anchor = self.sorted[(NSUInteger)path.row];
        NSDictionary *state = [DYYYLiveBoardMonitor.shared stateForUID:anchor[@"uid"]];
        NSString *roomID = DYYYRadarString(state[@"roomID"]);
        if ([state[@"live"] boolValue] && roomID.length) {
            // 在播：先进直播间，进不去再打开主页。
            if (DYYYLiveBoardOpenLiveRoom(roomID, anchor[@"uid"])) return;
            if (DYYYLiveBoardOpenProfile(anchor[@"uid"])) return;
            DYYYRadarToast(self, @"暂时打不开直播间，请稍后再试");
            return;
        }
        if (!DYYYLiveBoardOpenProfile(anchor[@"uid"])) DYYYRadarToast(self, @"暂时打不开主页，请稍后再试");
        return;
    }
    if (self.compactListOnly) return;
    if (path.section == 0) {
        // 2.2-9-98：第 0 组行号变了：0 开关、1 悬浮开关、2 悬浮榜透明度、
        // 3 弹窗背景、4 胶囊背景透明、5 胶囊字体大小、6 刷新间隔、7 立即刷新。
        // 2.2-9-104：西游隐藏功能已彻底去掉，第 0 组回到 8 行。
        if (path.row == 6) { [self editInterval]; return; }
        if (path.row == 7) {
            if (![DYYYLiveBoardStore.shared enabled]) { DYYYRadarMessage(self, @"人气榜未开启", @"先打开上方的总开关，再点立即刷新。"); return; }
            [DYYYLiveBoardMonitor.shared checkNow];
            DYYYRadarToast(self, @"已安排刷新");
            return;
        }
        return;
    }
    if (path.section == 2) { [self addAnchorSheet]; return; }
}

#pragma mark - 添加主播

// 2.2-9-72：加人改走星牌那套 DYYYFansService resolveInput（自动模式：
// UID、抖音号、分享链接都能认，三路兜底），特别关注的路子只作后备。
// 背景：用户加 32556444245 和 MS1407 都报“没核对上”，MS1407 已查实是
// 真实存在的抖音号（木森），说明 -71 的查号路子在当前抖音版上走不通。
- (void)addAnchorSheet {
    [DYYYLiveBoardMonitor.shared synchronizeAccount];
    if (!DYYYLiveBoardStore.shared.accountID.length) { DYYYRadarMessage(self, @"请先登录", @"登录抖音后即可添加主播。"); return; }
    if (DYYYLiveBoardStore.shared.anchors.count >= DYYYLiveBoardMaxAnchors) { DYYYRadarMessage(self, @"已满 20 位", @"榜单最多 20 位主播，先删掉一位再添加。"); return; }
    DYYYRadarSheet(self, @"添加主播", @[@"输入抖音号", @"输入 UID", @"粘贴分享链接"], ^(NSUInteger index) {
        [self addAnchorInput:(NSInteger)index];
    });
}

// kind：0 抖音号，1 UID，2 分享链接。
- (void)addAnchorInput:(NSInteger)kind {
    NSString *title = kind == 1 ? @"输入 UID" : (kind == 2 ? @"粘贴分享链接" : @"输入抖音号");
    NSString *message = kind == 1 ? @"对方主页的数字 UID（不是昵称）。"
        : (kind == 2 ? @"从对方主页点分享、复制链接后粘贴到这里。"
                     : @"对方主页显示的完整抖音号（不是昵称）。");
    NSString *placeholder = kind == 1 ? @"例如 72000020163" : (kind == 2 ? @"粘贴抖音分享链接" : @"例如 MS1407");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = DYYYRadarStyle(); alert.view.tintColor = DYYYRadarAccent();
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = kind == 1 ? UIKeyboardTypeNumberPad : UIKeyboardTypeDefault;
        field.placeholder = placeholder;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"核对" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        DYYYLiveBoardViewController *self = weakSelf; if (!self) return;
        NSString *input = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        if (!input.length) return;
        [self resolveAnchorInput:input kind:kind];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 先走星牌解析；失败再走特别关注的路子（UID 走资料接口、抖音号走搜索）；
// 分享链接没有后备，星牌失败就直接报星牌的原因。
// 具体原因始终显示在“没核对上”弹窗的副标题里。
- (void)resolveAnchorInput:(NSString *)input kind:(NSInteger)kind {
    DYYYFansInputMode mode = kind == 1 ? DYYYFansInputUID : (kind == 0 ? DYYYFansInputHandle : DYYYFansInputAutomatic);
    self.fansService = [DYYYFansService new];
    DYYYRadarToast(self, @"正在核对…");
    __weak typeof(self) weakSelf = self;
    [self.fansService resolveInput:input mode:mode completion:^(id person, NSError *error) {
        DYYYLiveBoardViewController *self = weakSelf; if (!self) return;
        self.fansService = nil;
        NSArray *candidates = error.userInfo[@"DYYYFansCandidates"];
        if ([candidates isKindOfClass:NSArray.class] && candidates.count) {
            [self chooseAnchorCandidate:candidates];
            return;
        }
        if (person && !error) {
            [self confirmAnchor:person error:nil];
            return;
        }
        if (kind == 2) {
            [self confirmAnchor:nil error:error];
            return;
        }
        if (kind == 1) {
            [DYYYRadarApi profile:@{@"uid": input} owner:@"DYYYLiveBoard.Add" completion:^(id profile, NSError *radarError) {
                [self confirmAnchor:profile error:radarError ?: error];
            }];
        } else {
            [DYYYRadarApi resolveHandle:input owner:@"DYYYLiveBoard.Add" completion:^(id profile, NSError *radarError) {
                [self confirmAnchor:profile error:radarError ?: error];
            }];
        }
    }];
}

// 星牌解析返回多个候选时，让用户按名字 + 抖音号挑一个（与星牌查询同款）。
- (void)chooseAnchorCandidate:(NSArray *)candidates {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"核对主播" message:@"请选择正确的账号。" preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.overrideUserInterfaceStyle = DYYYRadarStyle(); sheet.view.tintColor = DYYYRadarAccent();
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *person in candidates) {
        if (![person isKindOfClass:NSDictionary.class]) continue;
        NSString *title = [NSString stringWithFormat:@"%@ · %@", DYYYFansPersonName(person), DYYYFansString(person[@"handle"])];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf confirmAnchor:person error:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmAnchor:(id)profile error:(NSError *)error {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self confirmAnchor:profile error:error]; }); return; }
    if (error || !DYYYRadarProfile(profile)) {
        DYYYRadarMessage(self, @"没核对上", error.localizedDescription ?: @"没有找到这位主播，请检查输入后重试。");
        return;
    }
    NSDictionary *person = DYYYRadarProfile(profile);
    // 2.2-9-73：secUID 别丢——星牌 person 的 secUID 在 secUID 键里，万一上面
    // 的归一化没留住（比如多候选选择后那条路），从四个键里取第一个非空的补回。
    if (!DYYYRadarString(person[@"secUID"]).length) {
        NSString *sec = DYYYRadarString(DYYYRadarFirst(profile, @[@"secUID", @"sec_uid", @"sec_user_id", @"secUserID"]));
        if (sec.length) {
            NSMutableDictionary *merged = [person mutableCopy];
            merged[@"secUID"] = sec;
            person = merged;
        }
    }
    NSString *name = DYYYRadarDisplayName(person);
    NSString *handle = DYYYRadarString(person[@"handle"]);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认添加"
        message:[NSString stringWithFormat:@"%@\n抖音号：%@\nUID：%@", name, handle.length ? handle : @"—", person[@"uid"]]
        preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = DYYYRadarStyle(); alert.view.tintColor = DYYYRadarAccent();
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSError *addError = nil;
        if ([DYYYLiveBoardStore.shared addAnchor:person error:&addError]) {
            [DYYYLiveBoardMonitor.shared checkNow];
            DYYYRadarToast(self, [NSString stringWithFormat:@"已添加 %@", name]);
        } else {
            DYYYRadarMessage(self, @"没加上", addError.localizedDescription ?: @"添加失败。");
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 改名字

// 2.2-9-72：左滑一行 → 改名字。名字存在 anchor 的 remark 字段里，
// 榜单页和悬浮榜都优先显示自定义名字（DYYYRadarDisplayName 的顺序），
// 没设才显示昵称；留空表示清除，恢复显示昵称。
- (void)renameAnchor:(NSDictionary *)anchor {
    NSString *currentRemark = DYYYRadarString(anchor[@"remark"]);
    NSString *displayName = DYYYRadarDisplayName(anchor);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"改名字"
        message:@"给这位主播起个你自己认得的名字，榜单和直播间悬浮榜都显示它。留空恢复显示昵称。"
        preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = DYYYRadarStyle(); alert.view.tintColor = DYYYRadarAccent();
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = currentRemark;
        field.placeholder = displayName;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        DYYYLiveBoardViewController *self = weakSelf; if (!self) return;
        NSString *input = weakAlert.textFields.firstObject.text ?: @"";
        if ([DYYYLiveBoardStore.shared setCustomName:input forUID:anchor[@"uid"]]) {
            NSString *clean = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            DYYYRadarToast(self, clean.length ? [NSString stringWithFormat:@"已改名为 %@", clean] : @"已恢复显示昵称");
            [self reload];
        } else {
            DYYYRadarMessage(self, @"没改上", @"这位主播不在榜单里了。");
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
