// DYYYLiveBoardSheet.h — 胶囊点开的三分之二底页（2.2-9-94）。
// 下三分之二、圆角顶边 + 小横条；上三分之一留着直播间（无遮罩层，
// 房间画面原样可见、视频声音照常）；点外面 / 下滑 / “关闭”收回。
// 其他入口（设置页榜单管理页、在线观众按钮、长按菜单）仍走全屏，不走这里。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYLiveBoardSheetPresentationController : UIPresentationController
@end

// transitioningDelegate：presenting 时返回上面的呈现控制器；
// 用关联对象挂在 nav 上保活（UIKit 只弱持有 transitioningDelegate）。
@interface DYYYLiveBoardSheetTransitioningDelegate : NSObject <UIViewControllerTransitioningDelegate>
@end

NS_ASSUME_NONNULL_END
