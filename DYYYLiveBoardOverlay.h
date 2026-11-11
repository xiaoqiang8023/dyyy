// DYYYLiveBoardOverlay.h — 直播间内悬浮人气榜（2.2-9-72）。
// 挂载点与 -7 开播时长胶囊一致：AWELiveAudienceContainerController /
// AWELiveAudienceViewController 的 audienceVC.view，2.2-9-73 再加
// IESLiveInnerFeedLiveRoomCell（直播广场/推荐页上下滑切换的房间）和
// IESLiveAudienceViewController 自身的生命周期钩子。
// 取数/刷新复用 -71 的 DYYYLiveBoardMonitor，不另起轮询定时器；
// 每秒只刷可见行的“已播时长”文字（显示用 tick，不做网络请求）。
// 拖动只改自己的 frame，不碰别的 view 的 frame；内部布局用 Auto Layout，
// 不在 layoutSubviews 里改帧。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// 从直播间容器装/拆悬浮榜（.xm 里调，幂等）。
void DYYYLiveBoardOverlayInstallFromContainer(id container);
void DYYYLiveBoardOverlayInstallFromAudienceWrapper(id wrapper);
void DYYYLiveBoardOverlayRemoveFromContainer(id container);
void DYYYLiveBoardOverlayRemoveFromAudienceWrapper(id wrapper);
// 2.2-9-73：直接装在某个 view 上（IESLiveAudienceViewController 的
// viewDidLoad/viewWillAppear 里调，幂等）；inner feed cell 的房间
// （直播广场/推荐页上下滑切换）走 InstallFromInnerFeedCell。
void DYYYLiveBoardOverlayInstallOnView(UIView *root);
void DYYYLiveBoardOverlayRemoveFromView(UIView *root);
void DYYYLiveBoardOverlayInstallFromInnerFeedCell(id cell);
void DYYYLiveBoardOverlayRemoveFromInnerFeedCell(id cell);
// 2.2-9-73：房间里加了主播/改了开关后，给正在开着的房间补装
// （监听自家 DYYYLiveBoardStoreChanged，不是全局 defaults 通知）。
void DYYYLiveBoardOverlayStartWatcher(void);
// 当前是否应该显示悬浮榜（总开关 + 悬浮开关 + 至少加了一位主播）。
BOOL DYYYLiveBoardOverlayShouldShow(void);
// 2.2-9-92：给人气榜小胶囊复用（-80 的可见标签启发式，不另写一套）。
BOOL DYYYLiveBoardRootHasVisibleNativeLabel(UIView *view);

#ifdef __cplusplus
}
#endif

@interface DYYYLiveBoardOverlayView : UIView <UITableViewDataSource, UITableViewDelegate>
@end

NS_ASSUME_NONNULL_END
