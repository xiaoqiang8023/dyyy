// DYYYMessageClean.h
// 消息页精简（DYKiller 消息页精简移植，2.2-9-99）：16 项，3 组。
//   顶栏 4 项（显示 / 隐藏 / 移除）：左侧栏、装扮商店、搜索图标、加号。
//   列表顶部 3 项（显示 / 隐藏 / 移除）：限时日常、好友大头像、互动消息。
//   聊天页 9 项（开关）：表情提示、玩法按钮、加号面板照片、返回、未读数字、
//   在线状态、通话、菜单、不自动展开群聊顶部。
// 全部默认原生行为：三档默认“显示”，9 个开关默认关。本文件不做 registerDefaults。
// .xm 文件按 ObjC++ 编译、C 函数用 extern "C" 包裹（DYYYUtils.h 同款）。
#ifndef DYYYMessageClean_h
#define DYYYMessageClean_h

#import <Foundation/Foundation.h>

/// 「显示 / 隐藏 / 移除」三档单选的取值。
typedef NS_ENUM(NSInteger, DYYYMessageCleanDisplayMode) {
    DYYYMessageCleanDisplayModeShow = 0,    // 抖音原样
    DYYYMessageCleanDisplayModeHide = 1,    // 不显示，位置与点击保留
    DYYYMessageCleanDisplayModeRemove = 2,  // 不显示、不可点击，按抖音原生排布收拢
};

// 设置键（DYYY* 前缀；绝不用 DYKiller* 键）。
static NSString *const DYYYKeyMessageSideBarMode = @"DYYYMessageSideBarMode";
static NSString *const DYYYKeyMessageSlotMode = @"DYYYMessageSlotMode";
static NSString *const DYYYKeyMessageSearchMode = @"DYYYMessageSearchMode";
static NSString *const DYYYKeyMessagePlusMode = @"DYYYMessagePlusMode";
static NSString *const DYYYKeyMessageDailyMode = @"DYYYMessageDailyMode";
static NSString *const DYYYKeyMessageFriendAvatarMode = @"DYYYMessageFriendAvatarMode";
static NSString *const DYYYKeyMessageInteractionMode = @"DYYYMessageInteractionMode";
static NSString *const DYYYKeyChatRemoveEmojiSuggestions = @"DYYYChatRemoveEmojiSuggestions";
static NSString *const DYYYKeyChatPlayEntryMode = @"DYYYChatPlayEntryMode";
static NSString *const DYYYKeyChatRemovePlusPhotos = @"DYYYChatRemovePlusPhotos";
static NSString *const DYYYKeyChatRemoveBack = @"DYYYChatRemoveBack";
static NSString *const DYYYKeyChatRemoveUnread = @"DYYYChatRemoveUnread";
static NSString *const DYYYKeyChatRemoveOnline = @"DYYYChatRemoveOnline";
static NSString *const DYYYKeyChatRemoveCall = @"DYYYChatRemoveCall";
static NSString *const DYYYKeyChatRemoveMenu = @"DYYYChatRemoveMenu";
static NSString *const DYYYKeyChatGroupZoneNoAutoExpand = @"DYYYChatGroupZoneNoAutoExpand";

#ifdef __cplusplus
extern "C" {
#endif

/// 读取「显示 / 隐藏 / 移除」三档单选；未设置或越界按显示。
/// 兼容两种存储：整数 0/1/2，以及 DYYYOptionsSelectionView 写下的字符串
/// “显示”/“隐藏”/“移除”（设置页回调会把字符串再写回整数，见设置页注释）。
DYYYMessageCleanDisplayMode DYYYMessageCleanModeForKey(NSString *key);

/// 三档取值的中文名（显示 / 隐藏 / 移除），供设置页行副标题用。
NSString *DYYYMessageCleanModeText(DYYYMessageCleanDisplayMode mode);

/// 安装入口：幂等、主线程；顶栏 / 列表顶部是顶层 %hook（随文件链接即生效，
/// 行为按每次调用读开关），聊天页两组用 %group + %ctor %init（见两个 .xm）。
/// 由 DYYYPortsInstall.m 的 DYYYInstallPorts() 调用。不订阅任何通知。
void DYYYInstallMessageClean(void);

/// 设置改变后立即刷新消息页（主线程执行）：顶栏 + 列表顶部。
void DYYYMessageCleanRefresh(void);

/// 输出各项档位、顶栏槽位与列表顶部的当前状态，供调试探针使用。
NSString *DYYYMessageCleanStatus(void);

/// 顶栏部分的刷新与诊断（DYYYMessageCleanTopBar.xm）。
void DYYYMessageCleanTopBarRefresh(void);
NSString *DYYYMessageCleanTopBarStatus(void);

/// 列表顶部的刷新与诊断（DYYYMessageCleanList.xm）。
void DYYYMessageCleanListRefresh(void);
NSString *DYYYMessageCleanListStatus(void);

/// 聊天页顶栏的 DYYY-only 刷新（DYYYMessageCleanChatTop.xm）：
/// 重算返回 / 未读 / 在线圆点 / 群功能栏，并请导航栏组件重排。
/// 上游这里调的是玻璃文件的 DKChatTopBarRefresh，本移植不含玻璃，故只做本模块的同步。
void DYYYMessageCleanChatTopRefresh(void);

#ifdef __cplusplus
}
#endif

#endif /* DYYYMessageClean_h */
