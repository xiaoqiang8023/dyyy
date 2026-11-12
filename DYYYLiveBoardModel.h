// DYYYLiveBoardModel.h — 直播间人气榜（2.2-9-71）：纯工具层。
// 设置键、通知名、人数/时长格式化、在播判定解析、HTSLiveRoomAPI 取数、AWERouter 跳转。
// 取数与解析逻辑复用 DYYYLivePreview.xm（-56/-60）已验证的那套：
//   人数解析键 onlineCountByIM/userCount/user_count；开播时间键
//   startTime/start_time/liveStartTime/createTime/create_time；
//   万规则 >=10000 除以 10000、2 位小数去末尾 0、>=1亿用亿。
// .xm 的 static 函数无法跨文件链接，这里按原逻辑复制并改名前缀，行为不变。
// .xm（DYYYSettings.xm）会调这里的 C 函数，故声明包在 extern "C" 里（-69 教训）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// NSUserDefaults 键（开关未写过时一律视为 NO，即默认关闭）。
extern NSString *const DYYYLiveBoardEnabledKey;  // BOOL，默认 NO
extern NSString *const DYYYLiveBoardIntervalKey; // NSNumber 秒，默认 30，钳制 10–300
// 2.2-9-72：直播间内悬浮榜开关（BOOL，未写过视为 YES，即默认开；
// 但总开关 DYYYLiveBoardEnabled 关着时悬浮也不显示，没加主播时也不显示）。
extern NSString *const DYYYLiveBoardOverlayKey;
// 2.2-9-75：悬浮榜透明度（NSNumber double，0.2–1.0，默认 0.64；
// 只改面板黑底的 alpha，文字保持全不透明）。
extern NSString *const DYYYLiveBoardOverlayOpacityKey;
// 2.2-9-94：胶囊点开的三分之二底页背景不透明度（NSNumber double，
// 0.3–1.0，默认 0.85；只改底页底色的 alpha，文字保持全不透明）。
extern NSString *const DYYYLiveBoardSheetBackgroundOpacityKey;
// 2.2-9-98：胶囊背景不透明度（NSNumber double，0.1–1.0，默认 0.42；
// 只改胶囊黑底的 alpha，文字保持全不透明）与胶囊字号（NSNumber double，
// 11–18pt，默认 13；胶囊高度 = 字号 + 13，圆角 = 高度 / 2）。
extern NSString *const DYYYLiveBoardCapsuleBackgroundOpacityKey;
extern NSString *const DYYYLiveBoardCapsuleFontSizeKey;
// 悬浮榜收起状态（BOOL，默认 NO）与拖动位置（中心百分比，横竖屏分别记，
// 与 -7 开播时长胶囊同款做法：竖屏用旧键，横屏用 Landscape 键）。
extern NSString *const DYYYLiveBoardOverlayCollapsedKey;
extern NSString *const DYYYLiveBoardOverlayCenterXPercentKey;
extern NSString *const DYYYLiveBoardOverlayCenterYPercentKey;
extern NSString *const DYYYLiveBoardOverlayLandscapeCenterXPercentKey;
extern NSString *const DYYYLiveBoardOverlayLandscapeCenterYPercentKey;
extern NSUInteger const DYYYLiveBoardMaxAnchors; // 20

// 榜单状态变化通知（Monitor 每次写完一位主播的状态后发，主线程）。
extern NSNotificationName const DYYYLiveBoardChanged;
// 主播列表/选项变化通知（Store 写完后发，主线程）。
extern NSNotificationName const DYYYLiveBoardStoreChanged;

// DYYY 万规则（与直播间/预览一致）：>=10000 除以 10000、2 位小数去末尾 0；
// >=1亿用亿；<10000 原样。
NSString *DYYYLiveBoardFormatCountCompact(long long count);
// 开播时间戳 → 已播时长 "HH:MM:SS"，时间戳无效返回 nil。
NSString * _Nullable DYYYLiveBoardElapsedDigits(double start);
// profile/other 响应体（data 层或 user 层）里找 room_data：
// 返回 @{@"present": @YES/@NO, @"live": @YES/@NO, @"roomID": NSString?, @"totalViewers": NSNumber?}。
// present=NO 表示响应里根本没有 room_data 字段（走 reflow 兜底）；
// live 只认 status==2（抖音资料接口的在播标记，见 record-live 的说明）。
// 2.2-9-81：room_data 里如果带 total_user 也顺手读出来（有就用，没有也不强求）。
NSDictionary *DYYYLiveBoardParseRoomData(id _Nullable payload);
// fetchRoomInfoWithRoomID 响应里按 roomID 严格匹配取人数/开播时间/场观（先走这套）。
NSNumber * _Nullable DYYYLiveBoardViewerCount(id _Nullable object, NSString * _Nullable roomID);
double DYYYLiveBoardRoomStart(id _Nullable object, NSString * _Nullable roomID);
// 2.2-9-81：场观（累计进场人数）——与在线人数同款嵌套遍历、同款键表，
// 键 total_user/totalUser/total_user_count/totalUserCount/total_user_str/totalUserStr；
// 字符串型先转数字（“12.5万”按万规则转回数字再统一格式化，不直接拼原文），>0 才用。
NSNumber * _Nullable DYYYLiveBoardTotalViewers(id _Nullable object, NSString * _Nullable roomID);
// 严格匹配取不到时用的放宽版：不按 roomID 对号，只取响应里第一个带人数/
// 开播时间/场观的房间（fetchRoomInfo 只会返回本次请求的那间房）。
NSNumber * _Nullable DYYYLiveBoardViewerCountRelaxed(id _Nullable object);
double DYYYLiveBoardRoomStartRelaxed(id _Nullable object);
NSNumber * _Nullable DYYYLiveBoardTotalViewersRelaxed(id _Nullable object);
// HTSLiveRoomAPI 可用性（initWithRoomID:/fetchRoomInfoWithRoomID:completion: 签名校验）。
BOOL DYYYLiveBoardRoomAPIAvailable(void);
// 调 HTSLiveRoomAPI fetchRoomInfoWithRoomID，completion 原样回传 (first, second)。
// API 不可用或 roomNumber 无效时直接调 completion(nil, nil)。
void DYYYLiveBoardFetchRoomInfo(NSNumber *roomNumber, void (^completion)(id _Nullable first, id _Nullable second));
// profile/other 的完整 URL（照抄 DYYYRadarApi 的取域名逻辑：NetworkProviderDomain
// apiDomain/apiHost → likeRequestURL → https://aweme.snssdk.com）。
NSString *DYYYLiveBoardProfileOtherURL(void);

// 跳转：按顺序试 AWERouter.transferToURLString:，返回 YES 即路由接手。
// 进直播间：aweme://webcast_room?id= → aweme://live?room_id=&user_id= →
//          snssdk1128://live?room_id=&user_id=（后两者是公开的抖音 scheme 写法）。
// 进主页（直播间进不去时的回退）：aweme://user/profile/<uid> → snssdk1128://user/profile/<uid>。
BOOL DYYYLiveBoardOpenLiveRoom(NSString *roomID, NSString * _Nullable uid);
BOOL DYYYLiveBoardOpenProfile(NSString *uid);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
