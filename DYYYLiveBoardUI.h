// DYYYLiveBoardUI.h — 直播间人气榜页面（2.2-9-71）。
// 榜单页：每行头像 + 名字 + 在播/未开播状态，在播的显示在线人数（DYYY 万规则）
// 和开播时长，按人数从高到低排，未开播的沉底；点一行进直播间，
// 进不去就打开该主播主页。页内可添加/删除主播（上限 20）、改刷新间隔、
// 开关总榜单。样式跟 -67/-68 一致：InsetGrouped 圆角白卡片、深青图标。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYLiveBoardViewController : UITableViewController
// 2.2-9-93：紧凑模式——胶囊点开时只显示主播列表（1 组，无设置组、
// 无添加组、无页脚）；设置页榜单管理页用完整模式（默认 NO）。
@property(nonatomic, assign) BOOL compactListOnly;
@end

// 统一安装入口（DYYYPortsInstall.m 的 constructor 里调）：
// 只启动前台轮询 Monitor，开关默认关闭，运行时由 DYYYLiveBoardEnabled 门控。
// 不订阅全局 NSUserDefaultsDidChangeNotification，不做任何 Hook。
void DYYYInstallLiveBoard(void);

NS_ASSUME_NONNULL_END
