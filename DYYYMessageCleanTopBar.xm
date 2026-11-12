// DYYYMessageCleanTopBar.xm
// 消息页精简 —— 顶栏四项：左侧栏、装扮商店（左二运营位）、搜索图标、加号。
// 移植自 DYKiller DKMessageCleanTopBar.xm（40.8.0），仅改名前缀与键名；逻辑未改。
//
// 实现：
//  - 导航栏每个槽位是一组候选按钮组件，布局时取第一个 canShowInNaviBar 为真的组件放上去。
//    移除：组件的 canShowInNaviBar 在 %orig 之后返回 NO，重排时不再放它，同侧其余按钮按抖音原生排布收拢。
//    侧边栏组件的 canShowInNaviBar 每次都会新建氛围对象与入口视图，故始终先走 %orig，本模块也不额外调用它。
//  - 右一（加号位）是右侧容器的锚，右二（搜索位）只挂在右一左边。加号移除且右一其余候选都不能显示时，
//    resolve 之后把右二的候选提到右一，搜索落在最右。右一其余候选的 canShowInNaviBar 只做条件判断。
//  - 隐藏：布局向组件取入口视图时记下是哪一项，布局后给入口视图挂全透明 mask，命中不受影响，点击照常。
//  - 设置改动：对记下的导航栏组件 reloadNaviBarButtons（重新 resolve 并重排）。
//
// 未验证（40.9.0）：以下类 / 方法名照抄 40.8.0 上游，未在 40.9.0 上核对；
// 类不存在时 Logos %hook 是安全 no-op。见父级报告的未验证清单。
//   AWEIMMessageTabNaviBarComponent / p_resolveButtonComponent /
//   p_getCustomNaviButtonViewFromProvider: / p_layoutNaviButtons / reloadNaviBarButtons /
//   rightFirstBtnComponents / rightSecondBtnComponents，
//   AWEIMMessageTabSideBarButtonComponent / AWEIMMessageTabNavBarResourceSlotComponent(V2) /
//   AWEIMMessageTabSearchComponent / AWEIMMessageTabPlusButtonComponent 及其 canShowInNaviBar。

#import "AwemeHeaders.h"
#import "DYYYMessageClean.h"
#import "DYYYViewAdjust.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, DYYYMessageNaviItem) {
    DYYYMessageNaviItemNone = 0,
    DYYYMessageNaviItemSideBar,
    DYYYMessageNaviItemSlot,
    DYYYMessageNaviItemSearch,
    DYYYMessageNaviItemPlus,
};

static char kDYYYMessageNaviItemKey;
static NSHashTable<AWEIMMessageTabNaviBarComponent *> *gDYYYMessageNaviBars;
static NSHashTable<UIView *> *gDYYYMessageNaviViews;

static NSString *DYYYMessageNaviKey(DYYYMessageNaviItem item) {
    switch (item) {
        case DYYYMessageNaviItemSideBar: return DYYYKeyMessageSideBarMode;
        case DYYYMessageNaviItemSlot: return DYYYKeyMessageSlotMode;
        case DYYYMessageNaviItemSearch: return DYYYKeyMessageSearchMode;
        case DYYYMessageNaviItemPlus: return DYYYKeyMessagePlusMode;
        default: return nil;
    }
}

static NSString *DYYYMessageNaviName(DYYYMessageNaviItem item) {
    switch (item) {
        case DYYYMessageNaviItemSideBar: return @"左侧栏";
        case DYYYMessageNaviItemSlot: return @"装扮商店";
        case DYYYMessageNaviItemSearch: return @"搜索图标";
        case DYYYMessageNaviItemPlus: return @"加号";
        default: return @"-";
    }
}

static DYYYMessageCleanDisplayMode DYYYMessageNaviMode(DYYYMessageNaviItem item) {
    NSString *key = DYYYMessageNaviKey(item);
    return key ? DYYYMessageCleanModeForKey(key) : DYYYMessageCleanDisplayModeShow;
}

static DYYYMessageNaviItem DYYYMessageNaviItemForProvider(id provider) {
    if ([provider isKindOfClass:%c(AWEIMMessageTabSideBarButtonComponent)]) return DYYYMessageNaviItemSideBar;
    if ([provider isKindOfClass:%c(AWEIMMessageTabNavBarResourceSlotComponentV2)] ||
        [provider isKindOfClass:%c(AWEIMMessageTabNavBarResourceSlotComponent)]) return DYYYMessageNaviItemSlot;
    if ([provider isKindOfClass:%c(AWEIMMessageTabSearchComponent)]) return DYYYMessageNaviItemSearch;
    if ([provider isKindOfClass:%c(AWEIMMessageTabPlusButtonComponent)]) return DYYYMessageNaviItemPlus;
    return DYYYMessageNaviItemNone;
}

static BOOL DYYYMessageNaviRemoved(DYYYMessageNaviItem item) {
    return DYYYMessageNaviMode(item) == DYYYMessageCleanDisplayModeRemove;
}

// 隐藏与移除都不绘制入口；移除时入口本就不在导航栏上，mask 只作兜底。
static void DYYYMessageNaviApplyView(UIView *view) {
    DYYYMessageNaviItem item = (DYYYMessageNaviItem)[objc_getAssociatedObject(view, &kDYYYMessageNaviItemKey) integerValue];
    DYYYAdjustFade(view, DYYYMessageNaviMode(item) == DYYYMessageCleanDisplayModeShow ? 1.0 : 0.0, view.bounds.size);
}

static void DYYYMessageNaviPromoteSearch(AWEIMMessageTabNaviBarComponent *bar) {
    if (!DYYYMessageNaviRemoved(DYYYMessageNaviItemPlus)) return;
    if (![bar respondsToSelector:@selector(rightFirstBtnComponents)] ||
        ![bar respondsToSelector:@selector(setRightFirstBtnComponents:)]) return;
    for (id component in bar.rightFirstBtnComponents) {
        if (DYYYMessageNaviItemForProvider(component) == DYYYMessageNaviItemPlus) continue;
        if ([component respondsToSelector:@selector(canShowInNaviBar)] && [component canShowInNaviBar]) return;
    }
    NSArray *second = bar.rightSecondBtnComponents;
    if (!second.count) return;
    bar.rightFirstBtnComponents = second;
    bar.rightSecondBtnComponents = @[];
}

void DYYYMessageCleanTopBarRefresh(void) {
    for (AWEIMMessageTabNaviBarComponent *bar in gDYYYMessageNaviBars.allObjects) {
        if ([bar respondsToSelector:@selector(reloadNaviBarButtons)]) [bar reloadNaviBarButtons];
    }
    for (UIView *view in gDYYYMessageNaviViews.allObjects) DYYYMessageNaviApplyView(view);
}

static NSString *DYYYMessageNaviSlotText(NSArray *components) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id component in components) [names addObject:NSStringFromClass([component class])];
    return names.count ? [names componentsJoinedByString:@", "] : @"空";
}

NSString *DYYYMessageCleanTopBarStatus(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"已见导航栏组件=%lu\n", (unsigned long)gDYYYMessageNaviBars.allObjects.count];
    for (AWEIMMessageTabNaviBarComponent *bar in gDYYYMessageNaviBars.allObjects) {
        if (![bar respondsToSelector:@selector(rightFirstBtnComponents)]) continue;
        [out appendFormat:@"  右一=[%@]\n  右二=[%@]\n",
            DYYYMessageNaviSlotText(bar.rightFirstBtnComponents), DYYYMessageNaviSlotText(bar.rightSecondBtnComponents)];
    }
    for (UIView *view in gDYYYMessageNaviViews.allObjects) {
        DYYYMessageNaviItem item = (DYYYMessageNaviItem)[objc_getAssociatedObject(view, &kDYYYMessageNaviItemKey) integerValue];
        [out appendFormat:@"  %@ %@ 在窗口=%d frame=%@ 淡出=%.2f\n", DYYYMessageNaviName(item), NSStringFromClass(view.class),
            view.window != nil, NSStringFromCGRect([view convertRect:view.bounds toView:nil]), DYYYAdjustFadeFactor(view)];
    }
    return out;
}

%hook AWEIMMessageTabNaviBarComponent

- (void)p_resolveButtonComponent {
    %orig;
    DYYYMessageNaviPromoteSearch(self);
}

- (id)p_getCustomNaviButtonViewFromProvider:(id)provider {
    id view = %orig;
    DYYYMessageNaviItem item = DYYYMessageNaviItemForProvider(provider);
    if (item != DYYYMessageNaviItemNone && [view isKindOfClass:UIView.class]) {
        objc_setAssociatedObject(view, &kDYYYMessageNaviItemKey, @(item), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gDYYYMessageNaviViews) gDYYYMessageNaviViews = [NSHashTable weakObjectsHashTable];
        [gDYYYMessageNaviViews addObject:view];
    }
    return view;
}

- (void)p_layoutNaviButtons {
    %orig;
    if (!gDYYYMessageNaviBars) gDYYYMessageNaviBars = [NSHashTable weakObjectsHashTable];
    [gDYYYMessageNaviBars addObject:self];
    for (UIView *view in gDYYYMessageNaviViews.allObjects) DYYYMessageNaviApplyView(view);
}

%end

%hook AWEIMMessageTabSideBarButtonComponent

- (BOOL)canShowInNaviBar {
    BOOL show = %orig;
    return show && !DYYYMessageNaviRemoved(DYYYMessageNaviItemSideBar);
}

%end

%hook AWEIMMessageTabNavBarResourceSlotComponentV2

- (BOOL)canShowInNaviBar {
    BOOL show = %orig;
    return show && !DYYYMessageNaviRemoved(DYYYMessageNaviItemSlot);
}

%end

%hook AWEIMMessageTabNavBarResourceSlotComponent

- (BOOL)canShowInNaviBar {
    BOOL show = %orig;
    return show && !DYYYMessageNaviRemoved(DYYYMessageNaviItemSlot);
}

%end

%hook AWEIMMessageTabSearchComponent

- (BOOL)canShowInNaviBar {
    BOOL show = %orig;
    return show && !DYYYMessageNaviRemoved(DYYYMessageNaviItemSearch);
}

%end

%hook AWEIMMessageTabPlusButtonComponent

- (BOOL)canShowInNaviBar {
    BOOL show = %orig;
    return show && !DYYYMessageNaviRemoved(DYYYMessageNaviItemPlus);
}

%end
