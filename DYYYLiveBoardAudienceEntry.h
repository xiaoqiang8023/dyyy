// DYYYLiveBoardAudienceEntry.h — 在线观众面板标题栏的“人气榜”快捷入口（2.2-9-85）。
// 用户嫌直播间悬浮人气榜面板挡画面：悬浮榜改默认关，入口改放到“在线观众”
// 面板标题栏左侧的空白处，点一下打开榜单页。
// 安装点在 DYYYLiveBoardOverlayHooks.xm（IESLiveAudienceViewController 的
// 生命周期 + presentViewController 完成回调），逻辑全在这里，不另起 .xm。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// 在 audienceVC 的 view 子树（面板是房间 view 里的子视图时）、再不行
// keyWindow 各 window 子树（面板是单独呈现的 sheet 时）里找文字是
// “在线观众”的 UILabel，取它的父容器（标题栏），在标题左侧空白处加一个
// “人气榜”胶囊按钮；找不到、或人气榜总开关关着，就什么都不做。
// 幂等（tag 守卫 + 已装按钮弱引用快路）：面板每次打开都可重调，不会叠加。
void DYYYLiveBoardAudienceEntryInstall(UIViewController *audienceVC);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
