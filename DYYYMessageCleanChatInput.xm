// DYYYMessageCleanChatInput.xm
// 聊天页输入区精简：表情快捷提示条、输入框左侧的玩法入口，以及加号面板上方的最近照片条。
// 移植自 DYKiller DKChatInputClean.xm（40.8.0），仅改名前缀与键名；逻辑未改，
// 但去掉了玻璃 fan-out：布局回调里不再调 DKChatInputSync（玻璃同步），
// 设置变化的刷新只做输入行重排 + 提示条显隐（见 DYYYChatInputCleanRefresh）。
//
// 未验证（40.9.0）：#8 表情提示针对 40.8.0 行为——提示条经浮动容器分发展示，
// 4 个方法（p_layoutActionBarShowAnimated: / p_shouldShowActionBarAfterTypeResolved /
// p_shouldShowInputActionBarWithInputType: / canShowBarWhenInputTypeChangedTo:）与
// AWEIMInputActionBarMaker_NormalGroupOrPrivate 配置类名均照抄 40.8.0，未在 40.9.0 上核对。
// 若 40.9.0 里提示条改了分发路径，#8 可能不生效或只部分生效；其余两项不受影响。
// 类不存在时 Logos %hook 是安全 no-op。见父级报告的未验证清单。
// 其余未验证：IESIMInputLeftComponentPolicy / IESIMInputRightComponentPolicy /
// leftButtonsForShow / rightButtonsForShow，IESIMInputLayoutComponent /
// p_layoutInputViewsAfterAdjustButtons / pp_layoutSubviewsWithAnimated:context: / refreshLayout，
// IESIMInputPlayEntryComponent / _playEntryBtn ivar，
// AWEIMQuickSelectPhotoInteractor / canShowBarWhenInputTypeChangedTo:，
// AWEIMInputActionBarInteractor / p_layoutActionBarDismissAnimated: /
// hideActionBarIfNeeded / showActionBarIfPossible / barMaker。

#import "AwemeHeaders.h"
#import "DYYYChatInputScope.h"
#import "DYYYMessageClean.h"
#import <objc/runtime.h>

static NSHashTable<AWEIMInputActionBarInteractor *> *gDYYYChatActionBars;
static char kDYYYChatPlayDisabledKey;

static UIView *DYYYChatPlayButton(id component) {
    id play = DYYYChatInputComponent(component, @"IESIMInputPlayEntryComponent");
    return DYYYChatInputObjectIvar(play, "_playEntryBtn");
}

// 玩法入口的开关：打开即「移除」，输入框向左补满。
static BOOL DYYYChatPlayRemoved(void) {
    return DYYYGetBool(DYYYKeyChatPlayEntryMode);
}

// 只过滤返回的副本，不改原生可变数组。
static NSArray *DYYYChatFilterPlayButton(id policy, NSArray *buttons) {
    if (!DYYYChatPlayRemoved() || !DYYYChatInputController(policy)) return buttons;
    UIView *play = DYYYChatPlayButton(policy);
    if (!play || ![buttons containsObject:play]) return buttons;
    NSMutableArray *filtered = [buttons mutableCopy];
    [filtered removeObjectIdenticalTo:play];
    return [filtered copy];
}

// 按钮退出布局后补一层命中关闭，避免过渡帧里还能点到它。
static void DYYYChatPlayApply(id layout) {
    UIView *play = DYYYChatPlayButton(layout);
    if (!play) return;
    if (DYYYChatInputController(layout) && DYYYChatPlayRemoved()) {
        if (!play.userInteractionEnabled) return;
        objc_setAssociatedObject(play, &kDYYYChatPlayDisabledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        play.userInteractionEnabled = NO;
    } else if (objc_getAssociatedObject(play, &kDYYYChatPlayDisabledKey)) {
        play.userInteractionEnabled = YES;
        objc_setAssociatedObject(play, &kDYYYChatPlayDisabledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// 提示条只接管普通单聊群聊那一套配置，最近照片等浮动业务不受影响。
static BOOL DYYYChatSuggestionsSupported(AWEIMInputActionBarInteractor *bar) {
    return DYYYChatInputController(bar)
        && DYYYChatInputIsKind(bar.barMaker, @"AWEIMInputActionBarMaker_NormalGroupOrPrivate");
}

void DYYYChatInputCleanRefresh(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYChatInputCleanRefresh(); });
        return;
    }
    for (AWEIMInputActionBarInteractor *bar in gDYYYChatActionBars.allObjects) {
        if (!DYYYChatSuggestionsSupported(bar)) continue;
        if (DYYYGetBool(DYYYKeyChatRemoveEmojiSuggestions)) [bar hideActionBarIfNeeded];
        else [bar showActionBarIfPossible];
    }
}

%group DYYYMessageCleanChatInputHooks
%hook IESIMInputLeftComponentPolicy
- (NSArray *)leftButtonsForShow {
    return DYYYChatFilterPlayButton(self, %orig);
}
%end
%hook IESIMInputRightComponentPolicy
- (NSArray *)rightButtonsForShow {
    return DYYYChatFilterPlayButton(self, %orig);
}
%end
%hook IESIMInputLayoutComponent
- (void)p_layoutInputViewsAfterAdjustButtons {
    %orig;
    DYYYChatInputRegisterLayout(self);
    DYYYChatPlayApply(self);
}
- (void)pp_layoutSubviewsWithAnimated:(BOOL)animated context:(id)context {
    %orig;
    DYYYChatInputRegisterLayout(self);
    DYYYChatPlayApply(self);
}
%end
// 最近照片条只在切到加号面板时经分发询问展示，开关打开时答“不展示”，浮动容器按原生收起。
%hook AWEIMQuickSelectPhotoInteractor
- (BOOL)canShowBarWhenInputTypeChangedTo:(long long)type {
    if (DYYYGetBool(DYYYKeyChatRemovePlusPhotos) && DYYYChatInputController(self)) return NO;
    return %orig;
}
%end
%hook AWEIMInputActionBarInteractor
// 首次展示判定先于 barMaker 赋值；提交浮动布局时配置已确定，由原生收起路径同步回收高度与展示状态。
- (void)p_layoutActionBarShowAnimated:(BOOL)animated {
    if (DYYYChatSuggestionsSupported(self)) {
        [gDYYYChatActionBars addObject:self];
        if (DYYYGetBool(DYYYKeyChatRemoveEmojiSuggestions)) {
            [self p_layoutActionBarDismissAnimated:NO];
            return;
        }
    }
    %orig;
}
- (BOOL)p_shouldShowActionBarAfterTypeResolved {
    if (DYYYChatSuggestionsSupported(self)) {
        [gDYYYChatActionBars addObject:self];
        if (DYYYGetBool(DYYYKeyChatRemoveEmojiSuggestions)) return NO;
    }
    return %orig;
}
// 输入类型变化会重新判断提示条，与首次配置解析共用同一功能判据。
- (BOOL)p_shouldShowInputActionBarWithInputType:(NSInteger)type {
    if (DYYYChatSuggestionsSupported(self)) {
        [gDYYYChatActionBars addObject:self];
        if (DYYYGetBool(DYYYKeyChatRemoveEmojiSuggestions)) return NO;
    }
    return %orig;
}
// 40.8.0 起提示条经浮动容器分发展示，分发方只按这一询问决定是否显示。
- (BOOL)canShowBarWhenInputTypeChangedTo:(long long)type {
    if (DYYYChatSuggestionsSupported(self)) {
        [gDYYYChatActionBars addObject:self];
        if (DYYYGetBool(DYYYKeyChatRemoveEmojiSuggestions)) return NO;
    }
    return %orig;
}
%end
%end

%ctor {
    gDYYYChatActionBars = [NSHashTable weakObjectsHashTable];
    %init(DYYYMessageCleanChatInputHooks);
}
