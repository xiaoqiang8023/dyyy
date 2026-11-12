// DYYYDisguise.h — 2.2-9-69：本机伪装别人主页（仅本机视觉替换）。
// 只在本机把“我”页显示成目标的样子：头像、昵称、抖音号、简介、
// 获赞/关注/粉丝数换成缓存的目标资料，作品左下角播放量按顺序换成
// 目标作品的播放量。绝不改服务器、不改登录 UID、不冒充发视频/回私信。
// 别人手机上看到的还是你。数字是伪装时刻的缓存快照，会漂移。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 伪装状态开关（NSUserDefaults，默认 NO）。缓存文件只存一份，
// 按当前登录账号分文件，换号不串。
extern NSString * const DYYYDisguiseActiveKey;

// .xm 按 ObjC++ 编译：C 函数声明必须包在 extern "C" 里，否则调用方
// 会按 C++ 修饰名链接、找不到 .m 里的 C 符号（-69 链接失败的根因，
// DYYYUtils.h 同款做法）。
#ifdef __cplusplus
extern "C" {
#endif

// 当前登录账号 UID（AWEUserService），未登录返回 @""
NSString *DYYYDisguiseMyUID(void);
// 伪装是否开着（开关 + 缓存都在才算开）
BOOL DYYYDisguiseIsActive(void);
// 缓存的目标资料（DYYYFansPerson 格式：uid/secUID/name/handle/
// avatarURL/signature/followers/following/likes/works），未伪装返回 nil
NSDictionary *_Nullable DYYYDisguiseTarget(void);
// 目标的某项计数（@"praise" 获赞 / @"fans" 粉丝 / @"follow" 关注），
// 未伪装或该项没有缓存时返回 nil（互关数没有缓存，不替换）
NSNumber *_Nullable DYYYDisguiseTargetCountForField(NSString *field);
// 诊断用（设置页“伪装主页”组显示）：目标昵称 / 缓存文件在不在 /
// 最近一次伪装保存时间（0 表示没有保存过）
NSString *_Nullable DYYYDisguiseTargetName(void);
BOOL DYYYDisguiseCacheExists(void);
NSTimeInterval DYYYDisguiseSavedAt(void);
// 重刷已记录的主页显示对象（计数区、作品格、导航按钮、水印），
// 伪装开/关后调；只重刷，不重新取数
void DYYYDisguiseRefreshDisplays(void);
// 我的某条作品（itemID）在伪装里对应的目标播放量，未命中返回 nil
NSNumber *_Nullable DYYYDisguisePlayCountForMyAwemeID(NSString *itemID);
// 按缓存目标资料造一个 AWEUserModel（头像/昵称/抖音号/简介/计数），
// uid 保持我自己的（主页“是自己还是别人”的判断不能翻），造不出返回 nil
id _Nullable DYYYDisguiseSyntheticUserModel(void);
// 同上，但 secUID 从传入的真 model（换之前的那个）上读——
// -106：-105 只补了 uid，没补 secUID；41.1.0 里多个组件用 secUID
// 判“是不是我自己”。original 为 nil 时不设 secUID，不编来源。
id _Nullable DYYYDisguiseSyntheticUserModelForOriginal(id _Nullable original);
// 按原 statistics 复制一份，只把播放量换成目标的；复制失败返回 nil
id _Nullable DYYYDisguiseFakeStatistics(id original, NSNumber *playCount);
// 启动时恢复：开关开着且本机缓存还在，就恢复成伪装状态
void DYYYDisguiseRestoreIfNeeded(void);
// 从别人主页点“伪装此人”后调：取目标资料 + 前 20 条作品播放量 +
// 我自己的前 20 条作品 ID（用来按顺序对播放量），取完写缓存并开启
void DYYYDisguiseStartWithPerson(NSDictionary *person);
// 一键取消：清开关、删缓存、让已打开的“我”页重载恢复
void DYYYDisguiseCancel(void);
// 让已记录的个人主页组件重载一次（伪装开/关后刷新“我”页用）
void DYYYDisguiseReloadOwnProfile(void);
// 记录一个活着的 AWEProfileNavigationBaseComponent（弱引用，供重载用）
void DYYYDisguiseNoteProfileOwner(id owner);
// 刷新某主页组件对应的水印（只在“我的页 + 伪装开着”时显示）
void DYYYDisguiseUpdateWatermarkForOwner(id owner);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
