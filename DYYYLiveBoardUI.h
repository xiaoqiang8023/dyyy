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
// 2.2-9-108：房内主播提示——从直播间里打开榜单时，由打开方在呈现前
// 一次性填入 @{@"uid": 主播 uid, @"start": 开播起点秒时间戳}；
// 从设置页打开（不在直播间里）时为 nil，行为跟原来一样。
// uid 对上的那一行即使轮询还是“未开播”，也显示在播 + 已播时长
//（人数/场观仍只走轮询数据，没有就不显示，不编数字）。
@property(nonatomic, strong, nullable) NSDictionary *roomHint;
@end

// 统一安装入口（DYYYPortsInstall.m 的 constructor 里调）：
// 只启动前台轮询 Monitor，开关默认关闭，运行时由 DYYYLiveBoardEnabled 门控。
// 不订阅全局 NSUserDefaultsDidChangeNotification，不做任何 Hook。
void DYYYInstallLiveBoard(void);

NS_ASSUME_NONNULL_END
