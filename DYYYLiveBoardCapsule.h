// DYYYLiveBoardCapsule.h — 直播间左上角“人气榜”小胶囊按钮（2.2-9-92）。
// 做法照抄 -7 开播时长胶囊：挂在 audienceVC.view 上；样式与时长胶囊一致
// （黑半透明底、白字、圆角 7、0.5 白边）；只认总开关 DYYYLiveBoardEnabled
// （不认悬浮显示开关、不要求加了主播、不新增设置开关——不喜欢就关总开关）；
// 点一下走 DYYYLiveBoardPresentBoardFromViewController 打开榜单页；
// 拖动换位置（横竖屏分别记）；清屏跟藏（DYYY 一键清屏按 identifier，
// 抖音原生清屏按每秒 tick 的可见标签启发式，-80 同款）。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// 从直播间容器装/拆小胶囊（.xm 里调，幂等）。
void DYYYLiveBoardCapsuleInstallFromContainer(id container);
void DYYYLiveBoardCapsuleInstallFromAudienceWrapper(id wrapper);
void DYYYLiveBoardCapsuleRemoveFromContainer(id container);
void DYYYLiveBoardCapsuleRemoveFromAudienceWrapper(id wrapper);
// 2.2-9-73 同款：直接装在某个 view 上（IESLiveAudienceViewController 的
// 生命周期里调，幂等）；inner feed cell 的房间（直播广场/推荐页上下滑切换）
// 走 InstallFromInnerFeedCell。
void DYYYLiveBoardCapsuleInstallOnView(UIView *root);
void DYYYLiveBoardCapsuleRemoveFromView(UIView *root);
void DYYYLiveBoardCapsuleInstallFromInnerFeedCell(id cell);
void DYYYLiveBoardCapsuleRemoveFromInnerFeedCell(id cell);
// 2.2-9-92：房间里改了总开关后，给正在开着的房间补装
// （监听自家 DYYYLiveBoardStoreChanged，不是全局 defaults 通知）。
void DYYYLiveBoardCapsuleStartWatcher(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
