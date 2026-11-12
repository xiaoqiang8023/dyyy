// DYYYMessageCleanSettingsViewController.h
// 消息页精简设置页：独立 UITableViewController（insetGrouped，标题“消息页精简”），
// 无参 [[DYYYMessageCleanSettingsViewController alloc] init] 即可使用。
// 3 组 16 行，文案与上游 DYKiller 设置页同款；三档行用 DYYYOptionsSelectionView，
// 开关行用 DYYYPortsIconCell + UISwitch。全部默认原生行为，不做 registerDefaults。
#import <UIKit/UIKit.h>

@interface DYYYMessageCleanSettingsViewController : UITableViewController
@end
