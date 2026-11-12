// DYYYMessageCleanChatTop.xm
// 普通聊天顶栏精简，按钮和标题通过原生 provider 退出布局。
// 移植自 DYKiller DKChatTopClean.xm（40.8.0），仅改名前缀与键名；逻辑未改，
// 但刷新入口改成 DYYY-only：上游设置变化调的是玻璃文件的 DKChatTopBarRefresh
//（重排导航栏 + 同步玻璃），本移植不含玻璃（DKChatTopBar.xm 未移植），
// 故 DYYYMessageCleanChatTopRefresh 只做本模块的同步：重算返回 / 未读 /
// 在线圆点 / 群功能栏，并请已见的导航栏组件 setNeedsUpdateNaviBar 重排。
// provider 返回 nil 的那几项（通话 / 菜单 / 在线文字）
// 在下一次原生导航栏重建时生效，进聊天页即有；开关当场切时淡出类立即生效。
//
// 两处与上游的偏差（有意）：
//  - DKChatTopOnlineDotAway（玻璃居中布局把圆点移出头像的判定）在 DYYY 里恒为 NO：
//    DYYY 没有玻璃居中布局，圆点只可能被本模块的“移除在线状态”移走；缺口遮罩只按这一条挂 / 摘。
//  - 群功能栏入口条（Swift 类 AWEIMGroupImpl.GroupZoneEntryBarView）的 layoutSubviews 钩
//    只调同步（改 alpha），不改任何 frame；-61 教训的“不改 layoutSubviews 帧”守住了。
//
// 未验证（40.9.0）：以下类 / 方法名照抄 40.8.0 上游，未在 40.9.0 上核对；
// 类不存在时 Logos %hook 是安全 no-op。见父级报告的未验证清单。
//   AWEIMNavigationUnreadView / updateWithCount: / p_updateUI / backButton / unreadCountView，
//   AWEIMMessageListNaviBarBackAndUnreadCountComponent / naviBarView，
//   AWEIMMessageListOnLineComponent / naviBarTitleCustomView，
//   AWEIMMessageListNaviBarTitleAvatarComponent / p_updateDots / naviBarTitleCustomView /
//   onlineDotView / contentView / notchLayer，
//   AWEIMMessageListNaviVoIPEntryComponent / naviBarView，
//   AWEIMMessageListNaviBarChatDetailComponent / naviBarView，
//   AWEIMMessageListNaviBarGroupZoneToggleComponent / naviBarView，
//   AWEIMGroupZoneConversationComponent / desiredGroupZoneHeight / hostVC_viewDidLoad /
//   isGroupZoneExpanded / toggleGroupZoneExpanded:，
//   AWEIMGroupImpl.GroupZoneEntryBarView（Swift 混编类名），
//   AWEIMMessageListNaviBarComponent / setNeedsUpdateNaviBar / naviBar / naviBarTitleService。

#import "AwemeHeaders.h"
#import "DYYYChatInputScope.h"
#import "DYYYMessageClean.h"
#import "DYYYViewAdjust.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSHashTable *gDYYYChatUnreadViews;
static NSHashTable *gDYYYChatAvatarComponents;
static NSHashTable *gDYYYChatGroupBars;
static NSHashTable *gDYYYChatNaviComponents;
static char kDYYYChatUnreadCountKey;
static char kDYYYChatAvatarNotchKey;

static BOOL DYYYChatTopRemoved(id component, NSString *key) {
    return DYYYGetBool(key) && DYYYChatInputController(component);
}

static void DYYYChatBackSync(AWEIMNavigationUnreadView *view) {
    if (!DYYYChatInputControllerForPageView(view)) return;
    [gDYYYChatUnreadViews addObject:view];
    DYYYAdjustFade(view.backButton, DYYYGetBool(DYYYKeyChatRemoveBack) ? 0.0 : 1.0, CGSizeZero);
}

// 原生缺口只为头像上的圆点留外圈：圆点被移除期间撤掉缺口，回到头像后按原生规则
//（圆点显示才挂）挂回；没撤过时不碰。
// DYYY 没有玻璃居中布局，圆点不可能被居中布局移出头像，故 away 只看本模块的移除开关。
static void DYYYChatAvatarNotchApply(AWEIMMessageListNaviBarTitleAvatarComponent *component) {
    UIView *dot = component.onlineDotView;
    BOOL away = DYYYGetBool(DYYYKeyChatRemoveOnline);
    if (!away && !objc_getAssociatedObject(component, &kDYYYChatAvatarNotchKey)) return;
    objc_setAssociatedObject(component, &kDYYYChatAvatarNotchKey, away ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CALayer *layer = component.contentView.layer;
    CALayer *mask = !away && dot && !dot.hidden ? component.notchLayer : nil;
    if (layer.mask != mask) layer.mask = mask;
}

static void DYYYChatOnlineDotSync(AWEIMMessageListNaviBarTitleAvatarComponent *component) {
    if (!DYYYChatInputController(component)) return;
    [gDYYYChatAvatarComponents addObject:component];
    DYYYAdjustFade(component.onlineDotView, DYYYGetBool(DYYYKeyChatRemoveOnline) ? 0.0 : 1.0, CGSizeZero);
    DYYYChatAvatarNotchApply(component);
}

static void DYYYChatGroupCleanSync(UIView *view) {
    if (!DYYYChatInputControllerForPageView(view)) return;
    [gDYYYChatGroupBars addObject:view];
    DYYYAdjustAlpha(view, DYYYGetBool(DYYYKeyChatRemoveMenu) ? 0.0 : 1.0);
}

// 本模块的同步（上游 DKChatTopCleanRefresh 的等价物）。
static void DYYYChatTopCleanSync(void) {
    for (AWEIMNavigationUnreadView *view in gDYYYChatUnreadViews.allObjects) {
        NSNumber *count = objc_getAssociatedObject(view, &kDYYYChatUnreadCountKey);
        if (count) [view updateWithCount:count.longLongValue];
        DYYYChatBackSync(view);
    }
    for (id component in gDYYYChatAvatarComponents.allObjects) DYYYChatOnlineDotSync(component);
    for (UIView *bar in gDYYYChatGroupBars.allObjects) DYYYChatGroupCleanSync(bar);
}

void DYYYMessageCleanChatTopRefresh(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYMessageCleanChatTopRefresh(); });
        return;
    }
    DYYYChatTopCleanSync();
    // 请已见的导航栏组件重排，让返回 nil 的 provider 项（通话 / 菜单 / 在线文字）落位；
    // setNeedsUpdateNaviBar 本身也被钩住（只记表，不改行为），不会递归。
    for (AWEIMMessageListNaviBarComponent *component in gDYYYChatNaviComponents.allObjects) {
        if (!DYYYChatInputController(component)) continue;
        [component setNeedsUpdateNaviBar];
        if ([component.naviBarTitleService respondsToSelector:@selector(setNeedsUpdateNaviBarTitle)]) {
            // 方法未在头文件声明（服务类未知），走 objc_msgSend 直调，与 DYYY.xm 既有写法一致。
            ((void (*)(id, SEL))objc_msgSend)(component.naviBarTitleService, @selector(setNeedsUpdateNaviBarTitle));
        }
        if ([component.naviBar respondsToSelector:@selector(setNeedsLayout)]) [component.naviBar setNeedsLayout];
        if ([component.naviBar respondsToSelector:@selector(layoutIfNeeded)]) [component.naviBar layoutIfNeeded];
    }
}

%group DYYYMessageCleanChatTopHooks
%hook AWEIMMessageListNaviBarComponent
- (void)setNeedsUpdateNaviBar {
    if (!gDYYYChatNaviComponents) gDYYYChatNaviComponents = [NSHashTable weakObjectsHashTable];
    [gDYYYChatNaviComponents addObject:self];
    %orig;
}
%end
%hook AWEIMNavigationUnreadView
- (void)updateWithCount:(long long)count {
    objc_setAssociatedObject(self, &kDYYYChatUnreadCountKey, @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL remove = DYYYGetBool(DYYYKeyChatRemoveUnread) && DYYYChatInputControllerForPageView(self);
    %orig(remove ? 0 : count);
    DYYYChatBackSync(self);
}
- (void)p_updateUI { %orig; DYYYChatBackSync(self); }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DYYYGetBool(DYYYKeyChatRemoveBack) && DYYYChatInputControllerForPageView(self)
        && CGRectContainsPoint(self.backButton.frame, point)) return nil;
    return %orig;
}
%end
%hook AWEIMMessageListNaviBarBackAndUnreadCountComponent
- (UIView *)naviBarView {
    AWEIMNavigationUnreadView *view = (id)%orig;
    if (!view || !DYYYChatInputController(self)) return view;
    NSNumber *count = objc_getAssociatedObject(view, &kDYYYChatUnreadCountKey);
    if (count) [view updateWithCount:count.longLongValue];
    DYYYChatBackSync(view);
    if (DYYYGetBool(DYYYKeyChatRemoveBack) && (DYYYGetBool(DYYYKeyChatRemoveUnread) || view.unreadCountView.hidden || view.unreadCountView.alpha <= 0.01)) return nil;
    return view;
}
%end
%hook AWEIMMessageListOnLineComponent
- (UIView *)naviBarTitleCustomView {
    UIView *view = %orig;
    return DYYYChatTopRemoved(self, DYYYKeyChatRemoveOnline) ? nil : view;
}
%end
%hook AWEIMMessageListNaviBarTitleAvatarComponent
- (void)p_updateDots { %orig; DYYYChatOnlineDotSync(self); }
- (UIView *)naviBarTitleCustomView {
    UIView *view = %orig;
    DYYYChatOnlineDotSync(self);
    return view;
}
%end
%hook AWEIMMessageListNaviVoIPEntryComponent
- (UIView *)naviBarView {
    UIView *view = %orig;
    return DYYYChatTopRemoved(self, DYYYKeyChatRemoveCall) ? nil : view;
}
%end
%hook AWEIMMessageListNaviBarChatDetailComponent
- (UIView *)naviBarView {
    UIView *view = %orig;
    return DYYYChatTopRemoved(self, DYYYKeyChatRemoveMenu) ? nil : view;
}
%end
%hook AWEIMMessageListNaviBarGroupZoneToggleComponent
- (UIView *)naviBarView {
    UIView *view = %orig;
    return DYYYChatTopRemoved(self, DYYYKeyChatRemoveMenu) ? nil : view;
}
%end
%hook AWEIMGroupZoneConversationComponent
- (double)desiredGroupZoneHeight {
    return DYYYChatTopRemoved(self, DYYYKeyChatRemoveMenu) ? 0.0 : %orig;
}
// 原生只在这里同步算一次是否展开（不带动画），之后才进入转场与首帧；此时收起，首帧即为收起态。
- (void)hostVC_viewDidLoad {
    %orig;
    if (DYYYGetBool(DYYYKeyChatGroupZoneNoAutoExpand) && DYYYChatInputController(self) && self.isGroupZoneExpanded) {
        [self toggleGroupZoneExpanded:NO];
    }
}
%end
%hook DYYYChatCleanGroupEntryBar
// 只做 alpha 同步，不改 frame（-61 教训：layoutSubviews 里不改帧）。
- (void)layoutSubviews { %orig; DYYYChatGroupCleanSync(self); }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DYYYGetBool(DYYYKeyChatRemoveMenu) && DYYYChatInputControllerForPageView(self)) return nil;
    return %orig;
}
%end
%end

%ctor {
    gDYYYChatUnreadViews = [NSHashTable weakObjectsHashTable];
    gDYYYChatAvatarComponents = [NSHashTable weakObjectsHashTable];
    gDYYYChatGroupBars = [NSHashTable weakObjectsHashTable];
    gDYYYChatNaviComponents = [NSHashTable weakObjectsHashTable];
    %init(DYYYMessageCleanChatTopHooks, DYYYChatCleanGroupEntryBar = NSClassFromString(@"AWEIMGroupImpl.GroupZoneEntryBarView"));
}
