// DYYYLiveBoardAudienceEntry.h — 在线观众面板标题栏的“人气榜”快捷入口（2.2-9-85）。
// 用户嫌直播间悬浮人气榜面板挡画面：悬浮榜改默认关，入口改放到“在线观众”
// 面板标题栏左侧的空白处，点一下打开榜单页。
// 安装点在 DYYYLiveBoardOverlayHooks.xm（IESLiveAudienceViewController 的
// 生命周期 + presentViewController 完成回调，2.2-9-86 起另有 UIViewController
// 的 viewDidAppear/presentViewController 两钩——面板真正出现时才触发，
// 2.2-9-88 起进房间后另有 1 秒轮询 watcher——面板无论何时出现/重建都能装上），
// 逻辑全在这里，不另起 .xm。
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
// 2.2-9-87：每次安装尝试都把结果写进 NSUserDefaults（DYYYLiveBoardEntryDiag），
// 榜单设置页第 0 组页脚现读现显——用户不用找日志，截设置页图就能定位。
// 2.2-9-93：入口诊断已关闭（用户要求），这段只留作历史，见 .m。
// 2.2-9-90：供长按菜单入口复用：从 from 出发走到最上层已呈现的控制器，
// 再 present 榜单页（全屏导航 + “关闭”按钮）。打开榜单的 target 用关联
// 对象挂在 boardVC 上保活（UIBarButtonItem 不 retain target）。
void DYYYLiveBoardPresentBoardFromViewController(UIViewController *from);

// 2.2-9-93：胶囊点开的紧凑榜单（compactListOnly，只含主播列表）。
// 其他入口继续走上面的完整页。
void DYYYLiveBoardPresentCompactBoardFromViewController(UIViewController *from);

// 2.2-9-93：入口诊断已关闭——RecordDiagLine 保留（调用点不动），
// 但不再写任何诊断（见 .m 的 DYYYLiveBoardEntryRecordDiag）。
void DYYYLiveBoardEntryRecordDiagLine(NSString *outcome, UIViewController *vc);

void DYYYLiveBoardAudienceEntryInstall(UIViewController *audienceVC);

// 2.2-9-89：判断一个 VC 是不是我们自家页面或设置宿主（榜单页/设置页，
// 类名以 DYYY 开头，或类名含 "Setting"——抖音设置宿主
// AWESettingBaseViewController 在 -88 漏网）。观众面板永远不在这类页面
// 里，Install 与诊断都必须跳过这类触发 VC——-88 的诊断就是被用户打开
// 设置读诊断时 AWESettingBaseViewController 的触发覆盖掉的。
BOOL DYYYLiveBoardAudienceEntryIsOwnViewController(UIViewController *vc);

// 2.2-9-88：进房间后每秒重试安装的 watcher。进房间（viewDidAppear /
// didEnterRoom）时启动，出房间（didCloseRoom / dealloc）时停止；每跳只
// 调 Install，Install 自身幂等、按钮已在窗口里可见时快路返回，所以每跳
// 很便宜。面板无论何时出现/重建都能被装上，不依赖呈现方式。
void DYYYLiveBoardAudienceEntryStartWatcher(UIViewController *roomVC);
void DYYYLiveBoardAudienceEntryStopWatcher(void);

// 2.2-9-93：入口诊断已关闭——本函数保留作死代码（不再被设置页调用），
// 不再写新诊断、不再读心跳；字面量“入口诊断”只剩在这里。
NSString *DYYYLiveBoardAudienceEntryDiagText(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
