// DYYYLiveBoardStore.h — 直播间人气榜存储（2.2-9-71）。
// 照抄 DYYYRadarStore 的做法：选项（总开关/刷新间隔/悬浮开关）存 NSUserDefaults，
// 主播列表按登录账号存 Application Support/DYYYLiveBoard/account-<uid>.json，
// 每账号一份。主播记录只含 uid/secUID/handle/name/avatar/addedAt；
// 2.2-9-72：自定义名字存在 remark 字段（照抄特别关注 remark 的存法，
// DYYYRadarDisplayName 优先读 remark，所以榜单页和悬浮榜自动显示自定义名字）；
// 在播状态不落盘，只在 Monitor 内存里。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYLiveBoardStore : NSObject
@property(nonatomic, readonly, copy) NSString *accountID;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *anchors;
@property(nonatomic, readonly, copy) NSDictionary *options;
@property(nonatomic, readonly, copy) NSString *storageError;
+ (instancetype)shared;
- (instancetype)initWithDirectory:(NSURL *)directory;
- (void)activateAccount:(NSString *)accountID;
// options: @{@"enabled": @BOOL, @"interval": @秒, @"overlay": @BOOL, @"opacity": @0.2–1.0, @"sheetBackgroundOpacity": @0.3–1.0, @"capsuleBackgroundOpacity": @0.1–1.0, @"capsuleFontSize": @11–18}，未写过时默认 NO / 30 / YES / 0.64 / 0.85 / 0.42 / 13。
- (void)setOption:(NSString *)key value:(id)value;
- (BOOL)enabled;
- (NSTimeInterval)interval; // 已钳制 10–300
// 2.2-9-72：直播间内悬浮显示开关，未写过视为 YES（默认开），
// 但总开关关着时悬浮也不显示（见 DYYYLiveBoardOverlayShouldShow）。
- (BOOL)overlayEnabled;
// 2.2-9-75：悬浮榜透明度（0.2–1.0，默认 0.64，未写过视为 0.64；
// 只改面板黑底的 alpha，文字保持全不透明）。
- (double)overlayOpacity;
// 2.2-9-94：胶囊点开的三分之二底页背景不透明度（0.3–1.0，默认 0.85，
// 未写过视为 0.85；只改底页底色的 alpha，文字保持全不透明）。
- (double)sheetBackgroundOpacity;
// 2.2-9-98：胶囊背景不透明度（0.1–1.0，默认 0.42，未写过视为 0.42；
// 只改胶囊黑底的 alpha，文字保持全不透明）与胶囊字号（11–18pt，
// 默认 13，未写过视为 13；胶囊高度 = 字号 + 13，圆角 = 高度 / 2）。
- (double)capsuleBackgroundOpacity;
- (double)capsuleFontSize;
- (BOOL)addAnchor:(NSDictionary *)profile error:(NSError * _Nullable *)error;
// 2.2-9-73：只补写 secUID 字段（给 -72 加人时丢了 secUID 的已存主播补回用），
// 不动名字、自定义名字、头像；写回失败或主播不在了返回 NO。
- (BOOL)updateSecUID:(nullable NSString *)secUID forUID:(NSString *)uid;
// 2.2-9-72：改自定义名字（存在 anchor 的 remark 字段里）；
// name 为空或全空白表示清除自定义名字，恢复显示昵称。找不到该主播返回 NO。
- (BOOL)setCustomName:(nullable NSString *)name forUID:(NSString *)uid;
- (nullable NSDictionary *)anchor:(NSString *)uid;
- (void)removeAnchor:(NSString *)uid;
- (void)save;
- (void)flush;
- (NSUInteger)storageBytes;
@end

NS_ASSUME_NONNULL_END
