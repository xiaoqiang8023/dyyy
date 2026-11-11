// DYYYLiveBoardLongPressEntry.h — 直播间长按底部菜单里的“人气榜”行（2.2-9-90）。
// 用户 2026-11-11 23:05 改提的新方案：-85..-89 在“在线观众”面板里一直加不
// 上入口，改在长按弹出的底部菜单里加一行（菜单里有识别商品/不感兴趣/
// 小窗播放/投屏、转发到日常、推荐直播、分享联系人）。
// 注意：这张菜单是 UITableView（AWEModernLongPressPanelTableViewController），
// 行是 dataArray 里的 view model——主路是 DYYYLongPressPanel.xm 里模型注入
//（见该文件 -90 段），这里只做兜底：菜单若不是表格驱动（普通容器/stack），
// 在“推荐直播”行下面贴一行原生样式的行。父容器是 UITableView 时绝不硬贴
//（表不会为手动加的子视图重排，会盖住下一行），直接返回、改走模型注入。
// 逻辑全在这里，不另起 .xm；触发点复用 -86 的通用钩与 -88 的 1 秒 watcher。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// 在 sheetVC 的 view 子树、再不行 keyWindow 各 window 子树里找文字是
// “推荐直播”的 UILabel，取它的行容器，在下面贴一行“人气榜”行（图标+标题+
// 副标题+箭头，点进榜单页）；找不到、或人气榜总开关关着、或父容器是
// UITableView，就什么都不做（表格走模型注入）。幂等（tag 守卫 + 已装行
// 弱引用快路）：菜单每次打开都可重调，不会叠加。每次尝试都写进 -89 的
// 诊断环（DYYYLiveBoardEntryDiagRing），供榜单设置页页脚现读现显。
void DYYYLiveBoardLongPressEntryInstall(UIViewController *sheetVC);

// recordDiag=NO：1 秒 watcher 每跳用，找不到锚点/开关关时不写诊断（菜单没开
// 时本来就找不到），只在真正装上时记；与在线观众入口同款规矩。
void DYYYLiveBoardLongPressEntryInstallWithDiag(UIViewController *sheetVC, BOOL recordDiag);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
