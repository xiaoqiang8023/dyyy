// DYYYMessageCleanSettingsViewController.m
// 消息页精简设置页：3 组 16 行，标题与说明照抄 DYKiller 设置页文案。
//  - 顶栏 4 行 / 列表顶部 3 行：三档单选（显示 / 隐藏 / 移除），
//    点行弹出 DYYYOptionsSelectionView 底部选择表，当前值显示在行右侧。
//  - 聊天页 9 行：标准开关行，改值立即刷新对应部位。
// 存储：三档行存整数 0/1/2（显示/隐藏/移除）；开关行存 BOOL。全部默认原生行为。
// 注意：DYYYOptionsSelectionView 只会读写字符串偏好，
// 所以选择表挂在一个临时键（真键 + ".DYYYChoice"）上，
// 回调里把选中的字符串换算成整数再写入真键——这样选择表的已选高亮才不会错位。
// 联动：DYYYKeyChatGroupZoneNoAutoExpand（不自动展开群聊顶部）在
// DYYYKeyChatRemoveMenu（移除菜单按钮）开启时锁定不可改（群功能栏已被移除，无需此项）。
// 2.2-9-101：只改外观，功能/键/默认值一律不动——
//  每行加前置图标（SF Symbol，取 DYKiller 原版图标的最近似：图标名见
//  dykiller-src/src/Settings/DKSettingsLayout.m:199-218 的 ic_* 登记，
//  DYYY 全工程统一用 SF Symbol，故按原图标含义映射，不直接用抖音内部图名）；
//  标题后加 ① 说明按钮（info.circle 14pt，DYKiller DKSettingsCell.xm 同款：
//  贴在标题文字后、28pt 点击区，点一下用 DYYYBottomAlertView 弹出该行说明）；
//  聊天行的长副标题与三组页脚全部收进 ① 里，行恢复单行。
//  DYYY 专属的两条备注没有删：隐藏头像列表的重叠说明进了限时日常/好友大头像
//  两行的 ①；聊天页的作用域说明进了表情提示/玩法按钮/更多面板照片三行的 ①；
//  「不自动展开群聊顶部」的锁定说明在被锁定时才追加进 ① 弹窗。
#import "DYYYMessageCleanSettingsViewController.h"
#import "AwemeHeaders.h"
#import "DYYYBottomAlertView.h"
#import "DYYYChatInputScope.h"
#import "DYYYMessageClean.h"
#import "DYYYOptionsSelectionView.h"
#import "DYYYPortsUI.h"
#import "DYYYSettingsHelper.h"
#import <objc/runtime.h>

static NSString *const kDYYYMessageCleanChoiceOptionsKeySuffix = @".DYYYChoice";
// 2.2-9-101：收进 ① 的两条 DYYY 专属备注（宏展开后是字面量，可与相邻字面量拼接）。
#define DYYY_MSGCLEAN_AVATAR_NOTE @"开启 DYYY 的「隐藏头像列表」时，整行已被压扁，此项没有可见效果；先关掉它再调此项。"
#define DYYY_MSGCLEAN_CHAT_SCOPE_NOTE @"仅对普通私聊和群聊生效；公司会话、POI 会话、作品详情与图文详情内的输入页不受影响。"

static const NSInteger kDYYYMessageCleanInfoButtonTag = 987101;
static const void *kDYYYMessageCleanInfoKey = &kDYYYMessageCleanInfoKey;
static const void *kDYYYMessageCleanInfoTitleKey = &kDYYYMessageCleanInfoTitleKey;
static const void *kDYYYMessageCleanInfoRowKey = &kDYYYMessageCleanInfoRowKey;

@interface DYYYMessageCleanSettingsViewController ()
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@end

@implementation DYYYMessageCleanSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"消息页精简";
    NSLog(@"[DYYY-101] message clean settings restyled (icons + info badges)");
    DYYYPortsConfigureTable(self.tableView);
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"DYYYMessageCleanSettingsCell"];
    self.sections = @[
        // 顶栏
        @[
            @{@"key": DYYYKeyMessageSideBarMode, @"kind": @"choice", @"title": @"左侧栏",
              @"icon": @"line.3.horizontal",
              @"info": @"消息页顶栏左上角的侧边栏入口（≡）。隐藏：图标不显示，原位置仍可点击打开侧边栏；移除：不显示、不可点击，右侧的装扮商店随之左移。"},
            @{@"key": DYYYKeyMessageSlotMode, @"kind": @"choice", @"title": @"装扮商店",
              @"icon": @"bag",
              @"info": @"消息页顶栏左侧的运营入口，当前为装扮商店，内容随活动变化。隐藏：不显示，原位置仍可点击；移除：不显示、不可点击。"},
            @{@"key": DYYYKeyMessageSearchMode, @"kind": @"choice", @"title": @"搜索图标",
              @"icon": @"magnifyingglass",
              @"info": @"消息页顶栏右侧的搜索图标。隐藏：不显示，原位置仍可点击进入搜索；移除：不显示、不可点击。"},
            @{@"key": DYYYKeyMessagePlusMode, @"kind": @"choice", @"title": @"加号",
              @"icon": @"plus.circle",
              @"info": @"消息页顶栏右上角的加号。隐藏：不显示，原位置仍可点击展开；移除：不显示、不可点击，搜索图标移到最右侧。"},
        ],
        // 列表顶部
        @[
            @{@"key": DYYYKeyMessageDailyMode, @"kind": @"choice", @"title": @"限时日常",
              @"icon": @"clock",
              @"info": @"消息列表上方头像行开头的业务入口：限时日常，以及轮换出现的音乐回忆、一起看直播、回忆等。隐藏：不显示，原位置仍可点击；移除：不显示、不可点击，好友头像随之左移。" DYYY_MSGCLEAN_AVATAR_NOTE},
            @{@"key": DYYYKeyMessageFriendAvatarMode, @"kind": @"choice", @"title": @"好友大头像",
              @"icon": @"person.circle",
              @"info": @"消息列表上方头像行里的好友头像。隐藏：不显示，原位置仍可点击；移除：不显示、不可点击。与「限时日常」都移除时整行收起，下方列表上移。" DYYY_MSGCLEAN_AVATAR_NOTE},
            @{@"key": DYYYKeyMessageInteractionMode, @"kind": @"choice", @"title": @"互动消息",
              @"icon": @"message",
              @"info": @"消息列表里的「互动消息」会话。隐藏：不显示，原位置仍可点击进入；移除：从列表移除，下方会话随之上移。"},
        ],
        // 聊天页
        @[
            @{@"key": DYYYKeyChatRemoveEmojiSuggestions, @"kind": @"switch", @"title": @"移除表情提示",
              @"icon": @"face.smiling",
              @"info": @"移除普通私聊和群聊输入框上方的表情快捷提示，并收回布局占位。最近照片等其他浮动内容保持原生。" DYYY_MSGCLEAN_CHAT_SCOPE_NOTE},
            @{@"key": DYYYKeyChatPlayEntryMode, @"kind": @"switch", @"title": @"移除输入框左侧玩法按钮",
              @"icon": @"square.grid.2x2",
              @"info": @"移除输入框左侧的玩法入口，输入框向左延伸补满；关闭时保持原生按钮、位置与点击。" DYYY_MSGCLEAN_CHAT_SCOPE_NOTE},
            @{@"key": DYYYKeyChatRemovePlusPhotos, @"kind": @"switch", @"title": @"点击更多面板不弹出本地照片",
              @"icon": @"photo",
              @"info": @"打开普通私聊和群聊的加号面板时，输入框上方不再显示最近照片；相册入口仍在加号面板里。关闭时保持原生。" DYYY_MSGCLEAN_CHAT_SCOPE_NOTE},
            @{@"key": DYYYKeyChatRemoveBack, @"kind": @"switch", @"title": @"移除返回按钮",
              @"icon": @"arrow.left",
              @"info": @"移除聊天页顶部的返回箭头并关闭箭头区域的点击，未读数字由独立设置控制。"},
            @{@"key": DYYYKeyChatRemoveUnread, @"kind": @"switch", @"title": @"移除未读数字显示",
              @"icon": @"message",
              @"info": @"移除返回箭头旁的未读数字与底板，返回箭头保持原生功能。"},
            @{@"key": DYYYKeyChatRemoveOnline, @"kind": @"switch", @"title": @"移除在线状态显示",
              @"icon": @"person",
              @"info": @"移除聊天页顶部头像上的在线圆点及名称下方的在线状态文字。"},
            @{@"key": DYYYKeyChatRemoveCall, @"kind": @"switch", @"title": @"移除通话按钮",
              @"icon": @"phone",
              @"info": @"移除聊天页顶部的通话入口，并收回布局占位。"},
            @{@"key": DYYYKeyChatRemoveMenu, @"kind": @"switch", @"title": @"移除菜单按钮",
              @"icon": @"line.3.horizontal",
              @"info": @"移除群聊顶部的展开按钮与群功能栏并收回占位；私聊移除右上角聊天详情入口。"},
            @{@"key": DYYYKeyChatGroupZoneNoAutoExpand, @"kind": @"switch", @"title": @"不自动展开群聊顶部",
              @"icon": @"chevron.up",
              @"info": @"进入群聊时，若群功能栏被自动展开（群主、管理员或功能项有新内容时），在页面显示前收起；未展开时不做处理，仍可点右上角按钮手动展开。"},
        ],
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - 表格结构

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"顶栏";
        case 1: return @"列表顶部";
        case 2: return @"聊天页";
        default: return nil;
    }
}

// 2.2-9-101：三组页脚全部去掉，说明都收进了各行的 ① 里，行保持单行。
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return nil;
}

- (NSDictionary *)rowAt:(NSIndexPath *)path {
    return self.sections[path.section][path.row];
}

// 「不自动展开群聊顶部」在「移除菜单按钮」开启时锁定。
- (BOOL)isRowLocked:(NSDictionary *)row {
    return [row[@"key"] isEqualToString:DYYYKeyChatGroupZoneNoAutoExpand]
        && DYYYGetBool(DYYYKeyChatRemoveMenu);
}

#pragma mark - Cell

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = [self rowAt:indexPath];
    NSString *key = row[@"key"];
    NSString *title = row[@"title"];
    NSString *icon = row[@"icon"];

    if ([row[@"kind"] isEqualToString:@"choice"]) {
        NSString *value = DYYYMessageCleanModeText(DYYYMessageCleanModeForKey(key));
        UITableViewCell *cell = DYYYPortsValueCell(title, value, icon, YES);
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    UITableViewCell *cell = DYYYPortsIconCell(title, nil, icon, NO);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [UISwitch new];
    toggle.on = DYYYGetBool(key);
    toggle.enabled = ![self isRowLocked:row];
    toggle.tag = (NSInteger)(indexPath.section * 100 + indexPath.row);
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

#pragma mark - ① 说明按钮（2.2-9-101，DYKiller DKSettingsCell.xm 同款做法）

- (UILabel *)titleLabelInView:(UIView *)view withText:(NSString *)text {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)sub;
            if ([label.text isEqualToString:text]) return label;
        }
        UILabel *found = [self titleLabelInView:sub withText:text];
        if (found) return found;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = [self rowAt:indexPath];
    NSString *info = row[@"info"];
    if (!info.length) return;
    [cell layoutIfNeeded];
    UIButton *button = (UIButton *)[cell.contentView viewWithTag:kDYYYMessageCleanInfoButtonTag];
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = kDYYYMessageCleanInfoButtonTag;
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightRegular];
        [button setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:config]
                forState:UIControlStateNormal];
        button.accessibilityLabel = @"说明";
        [button addTarget:self action:@selector(infoTapped:) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:button];
    } else if (cell.contentView.subviews.lastObject != button) {
        [cell.contentView bringSubviewToFront:button];
    }
    objc_setAssociatedObject(button, kDYYYMessageCleanInfoKey, info, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(button, kDYYYMessageCleanInfoTitleKey, row[@"title"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(button, kDYYYMessageCleanInfoRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILabel *titleLabel = [self titleLabelInView:cell.contentView withText:row[@"title"]];
    if (!titleLabel) {
        button.hidden = YES;
        return;
    }
    button.hidden = NO;
    CGRect titleRect = [titleLabel convertRect:titleLabel.bounds toView:cell.contentView];
    CGSize fit = [titleLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGRectGetHeight(titleRect))];
    CGFloat textWidth = MIN(ceil(fit.width), CGRectGetWidth(titleRect));
    button.tintColor = [titleLabel.textColor colorWithAlphaComponent:0.45];
    button.frame = CGRectMake(CGRectGetMinX(titleRect) + textWidth - 2.0,
                              CGRectGetMidY(titleRect) - 14.0, 28.0, 28.0);
}

- (void)infoTapped:(UIButton *)sender {
    NSString *info = objc_getAssociatedObject(sender, kDYYYMessageCleanInfoKey);
    NSString *title = objc_getAssociatedObject(sender, kDYYYMessageCleanInfoTitleKey);
    NSDictionary *row = objc_getAssociatedObject(sender, kDYYYMessageCleanInfoRowKey);
    if (!info.length) return;
    // 被锁定时追加锁定原因（DYKiller dk_infoTapped 同款：说明 + 原因）。
    if (row && [self isRowLocked:row]) {
        info = [info stringByAppendingString:@"\n已随「移除菜单按钮」关闭：群功能栏已被移除，无需此项。"];
    }
    [DYYYBottomAlertView showAlertWithTitle:title
                                    message:info
                                  avatarURL:nil
                           cancelButtonText:nil
                          confirmButtonText:@"知道了"
                               cancelAction:nil
                                closeAction:nil
                              confirmAction:nil];
}

#pragma mark - 交互

- (void)switchChanged:(UISwitch *)toggle {
    NSInteger section = toggle.tag / 100;
    NSInteger row = toggle.tag % 100;
    if (section < 0 || section >= (NSInteger)self.sections.count) return;
    if (row < 0 || row >= (NSInteger)self.sections[section].count) return;
    NSDictionary *rowDict = self.sections[section][row];
    NSString *key = rowDict[@"key"];
    [DYYYSettingsHelper setUserDefaults:@(toggle.on) forKey:key];

    if ([key isEqualToString:DYYYKeyChatRemoveEmojiSuggestions]) {
        DYYYChatInputCleanRefresh();
        DYYYChatInputRefresh();
    } else if ([key isEqualToString:DYYYKeyChatPlayEntryMode]) {
        DYYYChatInputRefresh();
    } else if ([key isEqualToString:DYYYKeyChatRemovePlusPhotos]) {
        // 闸门在下次打开加号面板时才问，无需即时刷新。
    } else {
        DYYYMessageCleanChatTopRefresh();
    }
    // 「移除菜单按钮」改动会锁定 / 解锁下一行，整表重刷一次。
    if ([key isEqualToString:DYYYKeyChatRemoveMenu]) [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self rowAt:indexPath];
    if (![row[@"kind"] isEqualToString:@"choice"]) return;
    NSString *key = row[@"key"];
    NSString *title = row[@"title"];
    // 选择表挂临时键（见文件头注释），回调里把字符串换算成整数写入真键。
    NSString *tempKey = [key stringByAppendingString:kDYYYMessageCleanChoiceOptionsKeySuffix];
    NSArray<NSString *> *options = @[ @"显示", @"隐藏", @"移除" ];
    // 临时键先同步成当前值，选择表的高亮才对得上。
    [[NSUserDefaults standardUserDefaults] setObject:DYYYMessageCleanModeText(DYYYMessageCleanModeForKey(key)) forKey:tempKey];
    __weak typeof(self) weakSelf = self;
    [DYYYOptionsSelectionView showWithPreferenceKey:tempKey
                                        optionsArray:options
                                          headerText:title
                                      onPresentingVC:self
                                    selectionChanged:^(NSString *selectedValue) {
                                        NSInteger index = [options indexOfObject:selectedValue];
                                        if (index == NSNotFound) index = 0;
                                        [DYYYSettingsHelper setUserDefaults:@(index) forKey:key];
                                        DYYYMessageCleanRefresh();
                                        [weakSelf.tableView reloadData];
                                    }];
}

@end
