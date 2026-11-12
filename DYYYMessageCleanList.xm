// DYYYMessageCleanList.xm
// 消息页精简 —— 列表顶部三项：头像行开头的业务入口（限时日常等）、头像行里的好友头像、互动消息会话。
// 移植自 DYKiller DKMessageCleanList.xm（40.8.0），仅改名前缀与键名；逻辑未改。
//
// 实现：
//  - 头像行（AWEIMSkylightViewComponent）的全量结果、分区替换、删除刷新都经 applySnapshot:animatingDifferences:completion:
//    交给差异数据源。移除在 %orig 前从快照删掉对应条目，之后各路径都基于删过的快照，其余头像按原生排布左移。
//    条目判定：AWEIMSkylightBizViewModel 及其子类为业务入口；vmType 1 为好友（4 为状态设置，不处理）。
//  - 两项都移除时 AWEIMSkylightDataComponent shouldHidden 返回 YES，列表视图经代理写 hidden 并重排表头，整行收起。
//  - 互动消息（AWEIMOfficialChatModel，type 1003）：官方会话数据源的闸门 p_canShowOfficialChat: 返回 NO，
//    upsert 里已在列表的会话随之转为删除，下方会话按原生排布上移。闸门可能在后台线程调用，记录加锁。
//  - 隐藏：头像格子与会话行渲染后按条目类型给 contentView 挂全透明 mask，命中不受影响；复用时按新条目重挂或摘掉。
//  - 设置改动：快照重新 apply 一次、请求刷新（恢复时由抖音重建全量结果）、按设置收起或展开整行；
//    互动消息会话再 upsert 一次，由闸门决定加回或删除。
//
// 与 DYYY 现有功能的交互（勿动对方）：
//  DYYY.xm 的 DYYYHideAvatarList（AWEIMSkylightListView setFrame:）把整行高度压到最小。
//  它开着时整行已被压扁，本文件的 #5/#6（好友大头像 / 限时日常）没有可见效果；
//  关掉它之后 #5/#6 才看得到。设置页页脚里写了这句。
//
// 未验证（40.9.0）：以下类 / 方法名照抄 40.8.0 上游，未在 40.9.0 上核对；
// 类不存在时 Logos %hook 是安全 no-op。见父级报告的未验证清单。
//   AWEIMSkylightViewComponent / applySnapshot:animatingDifferences:completion: / dataSource，
//   AWEIMSkylightDataComponent / shouldHidden，AWEIMSkylightListView / viewWillAppear /
//   performShouldHiddenDelegate / refreshWithIgnoreFrequency: / skylightInterface，
//   AWEIMSkylightCommonCell / renderWithViewModel:，AWEIMSkylightCellViewModel / model，
//   AWEIMOnlineContactAvatarViewModel / vmType，AWEIMSkylightBizViewModel，
//   AWEIMChatListCommonCell / renderWithHolder: / cellViewModel，AWEIMChatCellViewModel / chat，
//   AWEIMChatModel / type，IESIMOfficialChatDataSource / p_canShowOfficialChat: /
//   p_updateChatListWithUpsert:remove: / chatWithSession:，
//   RxDiffableDataSourceSnapshot / RxCollectionViewDiffableDataSource。

#import "AwemeHeaders.h"
#import "DYYYMessageClean.h"
#import "DYYYViewAdjust.h"
#import <objc/runtime.h>
#import <os/lock.h>

typedef NS_ENUM(NSInteger, DYYYMessageListItem) {
    DYYYMessageListItemNone = 0,
    DYYYMessageListItemDaily,
    DYYYMessageListItemFriend,
    DYYYMessageListItemInteraction,
};

static const NSUInteger kDYYYSkylightFriendType = 1;
static const NSInteger kDYYYInteractionChatType = 1003;
static NSString *const kDYYYInteractionSessionID = @"-1003";

static char kDYYYMessageListItemKey;
// 弱表（头像行列表视图、渲染过的格子与会话行），只在主线程读写。
static NSHashTable *gDYYYSkylightLists;
static NSHashTable *gDYYYMessageListCells;

static os_unfair_lock gDYYYInteractionLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<IESIMOfficialChatDataSource *> *gDYYYOfficialSources;
static __weak AWEIMChatModel *gDYYYInteractionChat;

static NSString *DYYYMessageListKey(DYYYMessageListItem item) {
    switch (item) {
        case DYYYMessageListItemDaily: return DYYYKeyMessageDailyMode;
        case DYYYMessageListItemFriend: return DYYYKeyMessageFriendAvatarMode;
        case DYYYMessageListItemInteraction: return DYYYKeyMessageInteractionMode;
        default: return nil;
    }
}

static NSString *DYYYMessageListName(DYYYMessageListItem item) {
    switch (item) {
        case DYYYMessageListItemDaily: return @"限时日常";
        case DYYYMessageListItemFriend: return @"好友大头像";
        case DYYYMessageListItemInteraction: return @"互动消息";
        default: return @"-";
    }
}

static DYYYMessageCleanDisplayMode DYYYMessageListMode(DYYYMessageListItem item) {
    NSString *key = DYYYMessageListKey(item);
    return key ? DYYYMessageCleanModeForKey(key) : DYYYMessageCleanDisplayModeShow;
}

static BOOL DYYYMessageListRemoved(DYYYMessageListItem item) {
    return DYYYMessageListMode(item) == DYYYMessageCleanDisplayModeRemove;
}

static BOOL DYYYMessageSkylightRowRemoved(void) {
    return DYYYMessageListRemoved(DYYYMessageListItemDaily) && DYYYMessageListRemoved(DYYYMessageListItemFriend);
}

static DYYYMessageListItem DYYYMessageSkylightItem(id model) {
    if ([model isKindOfClass:%c(AWEIMSkylightBizViewModel)]) return DYYYMessageListItemDaily;
    if ([model isKindOfClass:%c(AWEIMOnlineContactAvatarViewModel)] && [model respondsToSelector:@selector(vmType)] &&
        [(AWEIMOnlineContactAvatarViewModel *)model vmType] == kDYYYSkylightFriendType) return DYYYMessageListItemFriend;
    return DYYYMessageListItemNone;
}

static BOOL DYYYMessageChatIsInteraction(id chat) {
    return [chat isKindOfClass:%c(AWEIMChatModel)] && [chat respondsToSelector:@selector(type)] &&
        [(AWEIMChatModel *)chat type] == kDYYYInteractionChatType;
}

static void DYYYMessageTrack(NSHashTable * __strong *table, id object) {
    if (!object) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYMessageTrack(table, object); });
        return;
    }
    if (!*table) *table = [NSHashTable weakObjectsHashTable];
    [*table addObject:object];
}

#pragma mark - 隐藏

static UIView *DYYYMessageCellContent(UIView *cell) {
    UIView *content = [cell respondsToSelector:@selector(contentView)] ? [(UITableViewCell *)cell contentView] : nil;
    return content ?: cell;
}

// 隐藏与移除都不绘制；移除时条目本就不在列表里，mask 只作兜底。
static void DYYYMessageListApplyCell(UIView *cell) {
    DYYYMessageListItem item = (DYYYMessageListItem)[objc_getAssociatedObject(cell, &kDYYYMessageListItemKey) integerValue];
    UIView *content = DYYYMessageCellContent(cell);
    DYYYAdjustFade(content, DYYYMessageListMode(item) == DYYYMessageCleanDisplayModeShow ? 1.0 : 0.0, content.bounds.size);
}

static void DYYYMessageListMarkCell(UIView *cell, DYYYMessageListItem item) {
    objc_setAssociatedObject(cell, &kDYYYMessageListItemKey, item ? @(item) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (item != DYYYMessageListItemNone) DYYYMessageTrack(&gDYYYMessageListCells, cell);
    DYYYMessageListApplyCell(cell);
}

#pragma mark - 头像行

static void DYYYMessageSkylightFilter(RxDiffableDataSourceSnapshot *snapshot) {
    BOOL dropDaily = DYYYMessageListRemoved(DYYYMessageListItemDaily);
    BOOL dropFriend = DYYYMessageListRemoved(DYYYMessageListItemFriend);
    if (!dropDaily && !dropFriend) return;
    if (![snapshot respondsToSelector:@selector(itemIdentifiers)] ||
        ![snapshot respondsToSelector:@selector(deleteItemsWithIdentifiers:)]) return;

    NSMutableArray *drop = [NSMutableArray array];
    for (id model in [snapshot itemIdentifiers]) {
        DYYYMessageListItem item = DYYYMessageSkylightItem(model);
        if ((item == DYYYMessageListItemDaily && dropDaily) || (item == DYYYMessageListItemFriend && dropFriend)) [drop addObject:model];
    }
    if (drop.count) [snapshot deleteItemsWithIdentifiers:drop];
}

static void DYYYMessageSkylightRefresh(AWEIMSkylightListView *list) {
    AWEIMSkylightViewComponent *view = [list respondsToSelector:@selector(skylightInterface)] ? list.skylightInterface : nil;
    if ([view isKindOfClass:%c(AWEIMSkylightViewComponent)] && [view respondsToSelector:@selector(dataSource)]) {
        RxDiffableDataSourceSnapshot *snapshot = [view.dataSource snapshot];
        if (snapshot) [view applySnapshot:snapshot animatingDifferences:NO completion:^{}];
    }
    if ([list respondsToSelector:@selector(refreshWithIgnoreFrequency:)]) [list refreshWithIgnoreFrequency:YES];
    if ([list respondsToSelector:@selector(performShouldHiddenDelegate)]) [list performShouldHiddenDelegate];
}

#pragma mark - 互动消息

static void DYYYMessageRecordInteraction(IESIMOfficialChatDataSource *source, AWEIMChatModel *chat) {
    os_unfair_lock_lock(&gDYYYInteractionLock);
    if (!gDYYYOfficialSources) gDYYYOfficialSources = [NSHashTable weakObjectsHashTable];
    [gDYYYOfficialSources addObject:source];
    gDYYYInteractionChat = chat;
    os_unfair_lock_unlock(&gDYYYInteractionLock);
}

static void DYYYMessageInteractionRefresh(void) {
    os_unfair_lock_lock(&gDYYYInteractionLock);
    NSArray<IESIMOfficialChatDataSource *> *sources = gDYYYOfficialSources.allObjects;
    AWEIMChatModel *chat = gDYYYInteractionChat;
    os_unfair_lock_unlock(&gDYYYInteractionLock);
    if (!chat) return;
    for (IESIMOfficialChatDataSource *source in sources) {
        if ([source respondsToSelector:@selector(p_updateChatListWithUpsert:remove:)]) {
            [source p_updateChatListWithUpsert:@[ chat ] remove:@[]];
        }
    }
}

#pragma mark - 刷新与诊断

void DYYYMessageCleanListRefresh(void) {
    for (AWEIMSkylightListView *list in gDYYYSkylightLists.allObjects) DYYYMessageSkylightRefresh(list);
    DYYYMessageInteractionRefresh();
    for (UIView *cell in gDYYYMessageListCells.allObjects) DYYYMessageListApplyCell(cell);
}

NSString *DYYYMessageCleanListStatus(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"已见头像行=%lu 整行移除=%d\n", (unsigned long)gDYYYSkylightLists.allObjects.count, DYYYMessageSkylightRowRemoved()];
    for (AWEIMSkylightListView *list in gDYYYSkylightLists.allObjects) {
        [out appendFormat:@"  头像行 在窗口=%d hidden=%d frame=%@\n", list.window != nil, list.isHidden,
            NSStringFromCGRect([list convertRect:list.bounds toView:nil])];
        AWEIMSkylightViewComponent *view = [list respondsToSelector:@selector(skylightInterface)] ? list.skylightInterface : nil;
        RxDiffableDataSourceSnapshot *snapshot = [view respondsToSelector:@selector(dataSource)] ? [view.dataSource snapshot] : nil;
        if (![snapshot respondsToSelector:@selector(sectionIdentifiers)]) continue;
        for (id section in [snapshot sectionIdentifiers]) {
            NSUInteger daily = 0, friends = 0, others = 0;
            for (id model in [snapshot itemIdentifiersInSectionWithIdentifier:section]) {
                DYYYMessageListItem item = DYYYMessageSkylightItem(model);
                if (item == DYYYMessageListItemDaily) daily++;
                else if (item == DYYYMessageListItemFriend) friends++;
                else others++;
            }
            [out appendFormat:@"    分区 %@：业务入口=%lu 好友=%lu 其他=%lu\n", section,
                (unsigned long)daily, (unsigned long)friends, (unsigned long)others];
        }
    }

    os_unfair_lock_lock(&gDYYYInteractionLock);
    NSArray<IESIMOfficialChatDataSource *> *sources = gDYYYOfficialSources.allObjects;
    AWEIMChatModel *chat = gDYYYInteractionChat;
    os_unfair_lock_unlock(&gDYYYInteractionLock);
    [out appendFormat:@"官方会话数据源=%lu 已见互动消息会话=%d\n", (unsigned long)sources.count, chat != nil];
    for (IESIMOfficialChatDataSource *source in sources) {
        BOOL listed = [source respondsToSelector:@selector(chatWithSession:)] && [source chatWithSession:kDYYYInteractionSessionID] != nil;
        [out appendFormat:@"  %@ 列表含互动消息=%d\n", NSStringFromClass(source.class), listed];
    }

    for (UIView *cell in gDYYYMessageListCells.allObjects) {
        if (!cell.window) continue;
        DYYYMessageListItem item = (DYYYMessageListItem)[objc_getAssociatedObject(cell, &kDYYYMessageListItemKey) integerValue];
        if (item == DYYYMessageListItemNone) continue;
        [out appendFormat:@"  %@ %@ frame=%@ 淡出=%.2f\n", DYYYMessageListName(item), NSStringFromClass(cell.class),
            NSStringFromCGRect([cell convertRect:cell.bounds toView:nil]), DYYYAdjustFadeFactor(DYYYMessageCellContent(cell))];
    }
    return out;
}

#pragma mark - Hook

%hook AWEIMSkylightViewComponent

- (void)applySnapshot:(RxDiffableDataSourceSnapshot *)snapshot animatingDifferences:(BOOL)animating completion:(id)completion {
    DYYYMessageSkylightFilter(snapshot);
    %orig;
}

%end

%hook AWEIMSkylightDataComponent

- (BOOL)shouldHidden {
    BOOL hidden = %orig;
    return hidden || DYYYMessageSkylightRowRemoved();
}

%end

%hook AWEIMSkylightListView

- (void)viewWillAppear {
    %orig;
    DYYYMessageTrack(&gDYYYSkylightLists, self);
}

- (void)performShouldHiddenDelegate {
    DYYYMessageTrack(&gDYYYSkylightLists, self);
    %orig;
}

%end

%hook AWEIMSkylightCommonCell

- (void)renderWithViewModel:(AWEIMSkylightCellViewModel *)viewModel {
    %orig;
    id model = [viewModel respondsToSelector:@selector(model)] ? viewModel.model : nil;
    DYYYMessageListMarkCell(self, DYYYMessageSkylightItem(model));
}

%end

%hook AWEIMChatListCommonCell

- (void)renderWithHolder:(id)holder {
    %orig;
    AWEIMChatCellViewModel *viewModel = [holder isKindOfClass:%c(AWEIMChatCellViewModel)] ? holder
        : ([self respondsToSelector:@selector(cellViewModel)] ? self.cellViewModel : nil);
    id chat = [viewModel respondsToSelector:@selector(chat)] ? viewModel.chat : nil;
    DYYYMessageListMarkCell(self, DYYYMessageChatIsInteraction(chat) ? DYYYMessageListItemInteraction : DYYYMessageListItemNone);
}

%end

%hook IESIMOfficialChatDataSource

- (BOOL)p_canShowOfficialChat:(AWEIMChatModel *)chat {
    BOOL show = %orig;
    if (!DYYYMessageChatIsInteraction(chat)) return show;
    DYYYMessageRecordInteraction(self, chat);
    return show && !DYYYMessageListRemoved(DYYYMessageListItemInteraction);
}

%end
