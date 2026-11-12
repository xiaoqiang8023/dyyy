// DYYYChatInputScope.h
// 聊天输入区范围判定与布局登记（DYKiller DKChatInput.h/.m 移植，2.2-9-99）。
// 只移植消息页精简用到的部分：宿主判定、ivar 读取、组件查找、输入行布局登记与刷新。
// 未移植：玻璃相关（DKChatInputGlassWanted / DKChatInputSync / DKChatInputRestore
// 与 DKChatInputRefresh 里的浮动层 / 表情页签 / 小火人 / 顶栏玻璃 fan-out）。
// .xm 文件按 ObjC++ 编译、本文件按 ObjC(.m) 编译，C 函数用 extern "C" 包裹。
#ifndef DYYYChatInputScope_h
#define DYYYChatInputScope_h

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 对象是否属于某个抖音类（类不存在或对象为 nil 时为假）。
BOOL DYYYChatInputIsKind(id object, NSString *className);

/// 读取对象上某个对象类型 ivar（对象为 nil、ivar 不存在或非对象类型时返回 nil）。
id DYYYChatInputObjectIvar(id object, const char *name);

/// 组件所属的普通聊天输入控制器；公司会话、POI 会话、作品详情、图文详情内返回 nil。
UIViewController *DYYYChatInputController(id component);

/// 聊天页内任意视图（浮动容器、消息列表等输入页之外的兄弟层）所属的普通聊天输入控制器，规则同上。
UIViewController *DYYYChatInputControllerForPageView(UIView *view);

/// 同一组件管理器内的语义组件（按类名），找不到返回 nil。
id DYYYChatInputComponent(id component, NSString *className);

/// 输入行布局对象：布局回调里登记、按输入页内视图或输入控制器反查、取全部在场对象。
void DYYYChatInputRegisterLayout(id layout);
id DYYYChatInputLayoutForView(UIView *view);
id DYYYChatInputLayoutForController(UIViewController *input);
NSArray *DYYYChatInputLayouts(void);

/// 输入行重排（主线程）：只对已登记的布局调 refreshLayout，不碰玻璃与浮动层。
void DYYYChatInputRefresh(void);

/// 表情提示条的即时刷新（设置变化时调用；定义在 DYYYMessageCleanChatInput.xm）。
void DYYYChatInputCleanRefresh(void);

#ifdef __cplusplus
}
#endif

#endif /* DYYYChatInputScope_h */
