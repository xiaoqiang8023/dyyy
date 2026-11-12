// DYYYProfileEntry.h — 2.2-9-99：DYKiller 个人主页快捷入口移植（DYKiller 0.7.1，DKProfileSettingsEntry.xm）。
//
// 在自己主页（“我”页）头像下方的功能区（观看历史 / 稍后再看 / … / 全部功能）末尾，
// 注入一张与原生卡片长得一样的假卡片（齿轮图标 + 名称），点它直接打开 DYYY 设置主界面。
// 不是悬浮按钮，不改任何原生卡片的布局，只在视图持有者的列表末尾追加。
//
// 40.9.0 可靠性：未验证。DYKiller 只在抖音 40.8.0 上实测过；DYYY 的 AwemeHeaders.h
// 里原来一个 AWEProfileEAVajra / AWEProfileExtensionArea 声明都没有。
// 因此本入口带运行时可用性校验：类或方法对不上就静默不装（只走 %orig），
// 左栏原有的 DYYY 按钮（DYYYSettings.xm，tag 232323）保留作兜底，不动它。
//
// 设置键（NSUserDefaults；都不用 registerDefaults，未写过即默认值）：
//   DYYYProfileSettingsEntry     —— 开关，BOOL，默认 NO（关）。
//   DYYYProfileSettingsEntryName —— 名称，整数，默认 0 → @"DYYY"，1 → @"插件设置"。
//   两档固定名称是照搬 DYKiller 的做法（DKMakeChoice），不支持自由改名；
//   自由改名要接 DYYY 的文本输入弹窗，另做，不在这里搭。
//
// 注意：DYYY 没有 DYKiller 那个“移除主页功能区”开关（grep 无此功能），
// 所以门控只有“开关开 + 是自己的主页”，不判断功能区是否被移除。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 开关：个人主页添加 DYYY 入口（默认关）
static NSString *const DYYYProfileSettingsEntry = @"DYYYProfileSettingsEntry";
// 名称：0 → @"DYYY"（默认），1 → @"插件设置"
static NSString *const DYYYProfileSettingsEntryName = @"DYYYProfileSettingsEntryName";

#ifdef __cplusplus
extern "C" {
#endif

// 入口当前显示的文字（@"DYYY" 或 @"插件设置"）
NSString *DYYYProfileEntryTitle(void);

// 40.9.0 运行时可用性：7 个抖音类 + 全部钩点/调用的方法都在才返回 YES；
// 任一缺失返回 NO，此时所有钩子只走 %orig，不注入、不改名、不崩。
BOOL DYYYProfileEntryAvailable(void);

// 安装入口：只做一次可用性检查（%ctor 已自装；DYYYPortsInstall.m 里再调一次也行，幂等）。
// .xm 按 ObjC++ 编译：C 函数声明必须包在 extern "C" 里，否则调用方
// 会按 C++ 修饰名链接、找不到 .xm 里的 C 符号（-69 链接失败的根因）。
void DYYYInstallProfileEntry(void);

// 刷新已见的自己主页功能区（开关 / 名称改动后调；任意线程可调，内部回主线程）。
// 走抖音自己的 refreshUserModel: 重建与重排。
void DYYYProfileEntryRefresh(void);

// 诊断：开关 / 名称 / 已见功能区数 / 最近一次让位 / 各功能区卡片标题。
NSString *DYYYProfileEntryStatus(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
