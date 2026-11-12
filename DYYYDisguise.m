// DYYYDisguise.m — 2.2-9-69：本机伪装别人主页。
// 实现只分三层，全部可回退：
//   1. 取数：复用 DYYYRadarNetwork（AWENetworkService 签名请求，特别关注
//      在用的同一条路）调 /aweme/v1/user/profile/other/ 取目标资料，
//      调 /aweme/v1/aweme/post/ 取目标和自己的前 20 条作品。
//   2. 缓存：目标资料 + 作品播放量 + 我的作品 ID 顺序，写本机 JSON，
//      只按当前登录账号分文件；数字是伪装时刻的快照，会漂移。
//   3. 显示：个人主页组件的 userModel 读到“我自己”时返回按缓存造的
//      假 AWEUserModel（头像/昵称/抖音号/简介/计数，uid 保持我自己的，
//      主页“自己/别人”的判断不能翻）；作品播放量在 AWEAwemeModel
//      的 statistics 上按 itemID 对位替换（只换数字，不换封面和视频）。
// 不订阅任何 NSUserDefaults 通知，不在 layoutSubviews 里改帧，
// 所有 UI 写操作回主线程；取数失败就停在那一步并提示，不编假数据。
#import "DYYYDisguise.h"
#import "AwemeHeaders.h"
#import "DYYYFansRuntime.h"
#import "DYYYFansModel.h"
#import "DYYYRadarNetwork.h"
#import "DYYYUtils.h"
#import "DYYYToast.h"
#import <objc/runtime.h>

NSString * const DYYYDisguiseActiveKey = @"DYYYDisguiseActive";

static NSDictionary *sTarget;
static NSArray *sTargetWorks;
static NSDictionary *sPlayMap; // 我的 aweme_id -> 目标播放量 NSNumber
static id sSyntheticModel;
static NSUInteger sGeneration;
static NSUInteger sSyntheticGeneration;
static NSUInteger sFetchGeneration;
static NSHashTable *sOwners;
static NSTimeInterval sSavedAt; // 最近一次伪装保存时间（缓存 JSON 里的 savedAt）

#pragma mark - 小工具

static NSString *DYYYDisguiseAPIOrigin(void) {
    Class provider = NSClassFromString(@"NetworkProviderDomain");
    for (NSString *selector in @[@"apiDomain", @"apiHost"]) {
        id raw = DYYYFansCall(provider, selector, @[]);
        NSString *text = [raw isKindOfClass:NSURL.class] ? [raw absoluteString] : DYYYFansString(raw);
        if (!text.length) continue;
        if (![text containsString:@"://"]) text = [@"https://" stringByAppendingString:text];
        NSURLComponents *parts = [NSURLComponents componentsWithString:text];
        if (![parts.scheme.lowercaseString isEqual:@"https"] || !parts.host.length || parts.user.length || parts.password.length) continue;
        parts.path = @""; parts.query = nil; parts.fragment = nil;
        return parts.string;
    }
    return @"https://aweme.snssdk.com";
}

static void DYYYDisguiseSetValueIfSupported(id obj, NSString *key, id value) {
    if (!obj || !key.length || !value) return;
    BOOL supported = NO;
    for (Class c = [obj class]; c && c != Nil; c = class_getSuperclass(c)) {
        if (class_getProperty(c, key.UTF8String)) { supported = YES; break; }
    }
    if (!supported) {
        NSString *setter = [NSString stringWithFormat:@"set%@%@:",
            [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]];
        supported = [obj respondsToSelector:NSSelectorFromString(setter)];
    }
    if (!supported) return;
    @try { [obj setValue:value forKey:key]; } @catch (__unused NSException *e) {}
}

static NSString *DYYYDisguiseFirstURL(id obj) {
    if ([obj isKindOfClass:NSString.class]) {
        NSURL *url = [NSURL URLWithString:obj];
        return ([url.scheme.lowercaseString isEqual:@"https"] && url.host.length) ? obj : @"";
    }
    if ([obj isKindOfClass:NSArray.class]) {
        for (id item in obj) { NSString *u = DYYYDisguiseFirstURL(item); if (u.length) return u; }
        return @"";
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (NSString *k in @[@"url_list", @"urlList", @"originURLList", @"URLList"]) {
            NSString *u = DYYYDisguiseFirstURL(obj[k]); if (u.length) return u;
        }
    }
    return @"";
}

static NSString *DYYYDisguiseCachePath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = [[dirs.firstObject ?: NSTemporaryDirectory() stringByAppendingPathComponent:@"DYYYDisguise"] copy];
    [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    return [base stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", DYYYDisguiseMyUID().length ? DYYYDisguiseMyUID() : @"anonymous"]];
}

static NSDictionary *DYYYDisguiseBuildPlayMap(NSArray *myWorkIDs, NSArray *targetWorks) {
    if (!myWorkIDs.count || !targetWorks.count) return @{};
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSUInteger n = MIN(myWorkIDs.count, targetWorks.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSString *mine = myWorkIDs[i];
        NSNumber *play = targetWorks[i][@"playCount"];
        if ([mine isKindOfClass:NSString.class] && mine.length && [play isKindOfClass:NSNumber.class]) map[mine] = play;
    }
    return [map copy];
}

#pragma mark - 进度条（自己的小浮层，不挡触摸）

static UIView *sHUDView;
static UILabel *sHUDLabel;

static void DYYYDisguiseShowHUD(NSString *text) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ DYYYDisguiseShowHUD(text); }); return; }
    UIWindow *window = [DYYYUtils getActiveWindow] ?: UIApplication.sharedApplication.keyWindow;
    if (!window) return;
    if (!sHUDView) {
        sHUDView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 260, 44)];
        sHUDView.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.8];
        sHUDView.layer.cornerRadius = 22;
        sHUDView.userInteractionEnabled = NO;
        sHUDLabel = [[UILabel alloc] initWithFrame:sHUDView.bounds];
        sHUDLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        sHUDLabel.textColor = UIColor.whiteColor;
        sHUDLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        sHUDLabel.textAlignment = NSTextAlignmentCenter;
        [sHUDView addSubview:sHUDLabel];
        [window addSubview:sHUDView];
    }
    sHUDView.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds) - 120);
    sHUDLabel.text = text;
    [window bringSubviewToFront:sHUDView];
}

static void DYYYDisguiseDismissHUD(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ DYYYDisguiseDismissHUD(); }); return; }
    [sHUDView removeFromSuperview];
    sHUDView = nil; sHUDLabel = nil;
}

#pragma mark - 水印（自己的 view，只画字，不改任何抖音视图的帧）

@interface DYYYDisguiseWatermarkView : UIView
@property(nonatomic, copy) NSString *watermarkText;
@end
@implementation DYYYDisguiseWatermarkView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    NSString *text = self.watermarkText;
    if (!text.length) return;
    NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:13],
        NSForegroundColorAttributeName: [[UIColor blackColor] colorWithAlphaComponent:0.10]};
    CGSize size = [text sizeWithAttributes:attrs];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGContextRotateCTM(ctx, -0.5);
    CGFloat diag = hypot(rect.size.width, rect.size.height);
    CGFloat stepX = size.width + 60, stepY = 90;
    for (CGFloat y = -diag; y < diag; y += stepY) {
        for (CGFloat x = -diag; x < diag; x += stepX) {
            [text drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
        }
    }
    CGContextRestoreGState(ctx);
}
@end

static char DYYYDisguiseWatermarkKeyStorage;
static const void *DYYYDisguiseWatermarkKey = &DYYYDisguiseWatermarkKeyStorage;

void DYYYDisguiseUpdateWatermarkForOwner(id owner) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ DYYYDisguiseUpdateWatermarkForOwner(owner); }); return; }
    UIView *container = DYYYFansRead(owner, @"navigationContainerView");
    if (![container isKindOfClass:UIView.class]) return;
    UIViewController *vc = nil;
    for (UIResponder *r = container; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) { vc = (UIViewController *)r; break; }
    }
    UIView *host = vc.view;
    if (!host) return;
    DYYYDisguiseWatermarkView *mark = objc_getAssociatedObject(host, DYYYDisguiseWatermarkKey);
    BOOL show = DYYYDisguiseIsActive();
    NSString *text = nil;
    if (show) {
        // 拿原始 model（直接读 ivar，绕开被换过的 userModel getter）
        id original = nil;
        @try { original = [owner valueForKey:@"_userModel"]; } @catch (__unused NSException *e) {}
        if (!original) original = DYYYFansCall(owner, @"userModel", @[]);
        NSDictionary *person = DYYYFansPerson(original);
        NSString *myUID = DYYYDisguiseMyUID();
        show = person && myUID.length && [DYYYFansString(person[@"uid"]) isEqual:myUID];
        if (show) {
            NSString *name = DYYYFansString(person[@"name"]);
            text = name.length
                ? [NSString stringWithFormat:@"仅本地伪装 %@ UID %@ 请勿用于违法行为", name, myUID]
                : [NSString stringWithFormat:@"仅本地伪装 UID %@ 请勿用于违法行为", myUID];
        }
    }
    if (!show) { [mark removeFromSuperview]; return; }
    if (!mark) {
        mark = [[DYYYDisguiseWatermarkView alloc] initWithFrame:host.bounds];
        mark.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, DYYYDisguiseWatermarkKey, mark, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    mark.watermarkText = text;
    if (!CGRectEqualToRect(mark.frame, host.bounds)) mark.frame = host.bounds;
    if (mark.superview != host) [host addSubview:mark];
    [host bringSubviewToFront:mark];
    [mark setNeedsDisplay];
}

#pragma mark - 状态与缓存

NSString *DYYYDisguiseMyUID(void) {
    return DYYYFansAccount() ?: @"";
}

BOOL DYYYDisguiseIsActive(void) {
    return DYYYGetBool(DYYYDisguiseActiveKey) && sTarget != nil;
}

NSDictionary *DYYYDisguiseTarget(void) {
    return sTarget;
}

NSNumber *DYYYDisguisePlayCountForMyAwemeID(NSString *itemID) {
    if (!itemID.length || !DYYYDisguiseIsActive()) return nil;
    id value = sPlayMap[itemID];
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

void DYYYDisguiseNoteProfileOwner(id owner) {
    if (!owner) return;
    if (!sOwners) sOwners = [NSHashTable weakObjectsHashTable];
    [sOwners addObject:owner];
}

void DYYYDisguiseReloadOwnProfile(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ DYYYDisguiseReloadOwnProfile(); }); return; }
    for (id owner in sOwners.allObjects) {
        @try {
            if ([owner respondsToSelector:@selector(reloadData)]) [owner reloadData];
        } @catch (__unused NSException *e) {}
    }
    // -70：只调导航组件的 reloadData 不够——计数区、作品格、基础头部
    // 都不经过它重读，-69 在这里就停了，所以“我”页纹丝不动。
    // 再把已记录的计数区/作品格/基础头部重刷一遍（实现在 Hooks 文件里）。
    DYYYDisguiseRefreshDisplays();
}

NSNumber *DYYYDisguiseTargetCountForField(NSString *field) {
    if (!DYYYDisguiseIsActive() || !field.length) return nil;
    NSString *key = nil;
    if ([field isEqualToString:@"praise"]) key = @"likes";
    else if ([field isEqualToString:@"fans"]) key = @"followers";
    else if ([field isEqualToString:@"follow"]) key = @"following";
    if (!key) return nil;
    id value = sTarget[key];
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

NSString *DYYYDisguiseTargetName(void) {
    if (!DYYYDisguiseIsActive()) return nil;
    NSString *name = DYYYFansString(sTarget[@"name"]);
    return name.length ? name : nil;
}

BOOL DYYYDisguiseCacheExists(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:DYYYDisguiseCachePath()];
}

NSTimeInterval DYYYDisguiseSavedAt(void) {
    return sSavedAt;
}

static void DYYYDisguiseSaveCache(NSDictionary *target, NSArray *targetWorks, NSArray *myWorkIDs) {
    sSavedAt = NSDate.date.timeIntervalSince1970;
    NSDictionary *cache = @{@"account": DYYYDisguiseMyUID(),
        @"target": target ?: @{},
        @"targetWorks": targetWorks ?: @[],
        @"myWorkIDs": myWorkIDs ?: @[],
        @"savedAt": @(sSavedAt)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:cache options:0 error:nil];
    if (data) [data writeToFile:DYYYDisguiseCachePath() atomically:YES];
}

static void DYYYDisguiseLoadCache(void) {
    if (!DYYYGetBool(DYYYDisguiseActiveKey)) return;
    NSData *data = [NSData dataWithContentsOfFile:DYYYDisguiseCachePath()];
    if (!data.length) return;
    NSDictionary *cache = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![cache isKindOfClass:NSDictionary.class]) return;
    if (![DYYYFansString(cache[@"account"]) isEqual:DYYYDisguiseMyUID()]) return;
    NSDictionary *target = cache[@"target"];
    if (![target isKindOfClass:NSDictionary.class] || !DYYYFansString(target[@"uid"]).length) return;
    sTarget = target;
    sTargetWorks = [cache[@"targetWorks"] isKindOfClass:NSArray.class] ? cache[@"targetWorks"] : @[];
    NSArray *myWorkIDs = [cache[@"myWorkIDs"] isKindOfClass:NSArray.class] ? cache[@"myWorkIDs"] : @[];
    sPlayMap = DYYYDisguiseBuildPlayMap(myWorkIDs, sTargetWorks);
    sSavedAt = [cache[@"savedAt"] doubleValue];
    sGeneration++;
    sSyntheticModel = nil;
}

void DYYYDisguiseRestoreIfNeeded(void) {
    DYYYDisguiseLoadCache();
}

#pragma mark - 假 model / 假 statistics

id DYYYDisguiseSyntheticUserModel(void) {
    return DYYYDisguiseSyntheticUserModelForOriginal(nil);
}

id DYYYDisguiseSyntheticUserModelForOriginal(id original) {
    if (!DYYYDisguiseIsActive()) return nil;
    if (sSyntheticModel && sSyntheticGeneration == sGeneration) return sSyntheticModel;
    NSDictionary *t = sTarget;
    Class cls = NSClassFromString(@"AWEUserModel");
    if (!cls || !t) return nil;
    id model = [cls new];
    if (!model) return nil;
    // 昵称 / 简介 / 抖音号（uniqueID 才是主页显示的“抖音号：xxx”）
    DYYYDisguiseSetValueIfSupported(model, @"nickname", DYYYFansString(t[@"name"]));
    DYYYDisguiseSetValueIfSupported(model, @"signature", DYYYFansString(t[@"signature"]));
    // 地区/IP（缓存里有就设上，标签区按它显示；性别/年龄缓存里没有，换不了）
    NSString *ipLocation = DYYYFansString(t[@"ipLocation"]);
    if (ipLocation.length) DYYYDisguiseSetValueIfSupported(model, @"ipLocation", ipLocation);
    DYYYDisguiseSetValueIfSupported(model, @"uniqueID", DYYYFansString(t[@"handle"]));
    DYYYDisguiseSetValueIfSupported(model, @"uniqueIDForShow", DYYYFansString(t[@"handle"]));
    // 头像：AWEURLModel 只认 originURLList
    NSString *avatar = DYYYFansString(t[@"avatarURL"]);
    if (avatar.length) {
        Class urlCls = NSClassFromString(@"AWEURLModel");
        id urlModel = urlCls ? [urlCls new] : nil;
        if (urlModel) {
            DYYYDisguiseSetValueIfSupported(urlModel, @"originURLList", @[avatar]);
            DYYYDisguiseSetValueIfSupported(model, @"avatarMedium", urlModel);
            DYYYDisguiseSetValueIfSupported(model, @"avatarThumb", urlModel);
            DYYYDisguiseSetValueIfSupported(model, @"avatarLarger", urlModel);
        }
    }
    // 计数：属性名按抖音 AWEUserModel 的真实命名，存在才设，不存在就跳过
    DYYYDisguiseSetValueIfSupported(model, @"followerCount", t[@"followers"]);
    DYYYDisguiseSetValueIfSupported(model, @"followingCount", t[@"following"]);
    DYYYDisguiseSetValueIfSupported(model, @"totalFavorited", t[@"likes"]);
    DYYYDisguiseSetValueIfSupported(model, @"awemeCount", t[@"works"]);
    // 注意：uid 故意不换成目标的，保持我自己的，主页“自己/别人”
    // 的判断（编辑主页还是关注按钮）不能翻。
    // -70 根因之一：-69 只写了这句注释，实际一行 uid 也没设——
    // 假 model 的 uid/secUID 全空，DYYYFansPerson(假 model) 直接
    // 返回 nil，“我”页的取消按钮和水印全被 early-return 藏掉。
    // 这里把 uid 设成我自己的 uid（不是目标的），判断就对了。
    NSString *myUID = DYYYDisguiseMyUID();
    DYYYDisguiseSetValueIfSupported(model, @"uid", myUID);
    DYYYDisguiseSetValueIfSupported(model, @"userID", myUID);
    // -106：secUID 也补成我自己的（-105 只补了 uid，没补 secUID；
    // 41.1.0 里多个组件用 secUID 判“是不是我自己”，缺了它名字区
    // 的抖音号值标签建不出来、计数区 items 建不出来、“添加朋友”
    // 按钮会误现）。来源：换之前的真 model（调用方传进来），不编。
    NSString *mySecUID = DYYYFansString(DYYYFansFirst(original, @[@"secUID", @"sec_uid", @"secUserID", @"secUid"]));
    if (mySecUID.length) DYYYDisguiseSetValueIfSupported(model, @"secUID", mySecUID);
    // -106：抖音号值可能读的不是 uniqueID，而是 shortID/displayID/
    // customID（或缓存里的 handle 本来就是空的，两种可能都要堵）——
    // 几个 ID 字段都用 handle 填一遍，属性存在才设。
    NSString *handle = DYYYFansString(t[@"handle"]);
    if (handle.length) {
        DYYYDisguiseSetValueIfSupported(model, @"shortID", handle);
        DYYYDisguiseSetValueIfSupported(model, @"shortId", handle);
        DYYYDisguiseSetValueIfSupported(model, @"displayID", handle);
        DYYYDisguiseSetValueIfSupported(model, @"customID", handle);
    }
    sSyntheticModel = model;
    sSyntheticGeneration = sGeneration;
    return model;
}

id DYYYDisguiseFakeStatistics(id original, NSNumber *playCount) {
    if (!original || !playCount) return nil;
    @try {
        Class cls = [original class];
        id fake = [cls new];
        if (!fake) return nil;
        for (Class c = cls; c && c != Nil && c != NSObject.class; c = class_getSuperclass(c)) {
            unsigned int count = 0;
            objc_property_t *props = class_copyPropertyList(c, &count);
            for (unsigned int i = 0; i < count; i++) {
                NSString *key = [NSString stringWithUTF8String:property_getName(props[i])];
                @try {
                    id value = [original valueForKey:key];
                    if (value) [fake setValue:value forKey:key];
                } @catch (__unused NSException *e) {}
            }
            free(props);
        }
        DYYYDisguiseSetValueIfSupported(fake, @"playCount", playCount);
        id check = nil;
        @try { check = [fake valueForKey:@"playCount"]; } @catch (__unused NSException *e) {}
        if (![check isKindOfClass:NSNumber.class]) {
            DYYYDisguiseSetValueIfSupported(fake, @"play_count", playCount);
        }
        return fake;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

#pragma mark - 取数

static NSArray *DYYYDisguiseParseWorks(id value) {
    id data = value;
    if ([data isKindOfClass:NSDictionary.class]) {
        id inner = data[@"data"];
        if ([inner isKindOfClass:NSDictionary.class]) data = inner;
    }
    NSArray *list = nil;
    if ([data isKindOfClass:NSDictionary.class]) {
        for (NSString *k in @[@"aweme_list", @"awemeList"]) {
            id v = data[k];
            if ([v isKindOfClass:NSArray.class]) { list = v; break; }
        }
    }
    if (!list) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in list) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *awemeID = DYYYFansString(DYYYFansFirst(item, @[@"aweme_id", @"awemeId"]));
        if (!awemeID.length) continue;
        id stats = DYYYFansFirst(item, @[@"statistics"]);
        NSNumber *play = DYYYFansInteger(DYYYFansFirst(stats, @[@"play_count", @"playCount"]));
        id video = DYYYFansFirst(item, @[@"video"]);
        id coverObj = DYYYFansFirst(video, @[@"cover", @"origin_cover", @"originCover"]);
        NSString *cover = DYYYDisguiseFirstURL(coverObj);
        NSString *desc = DYYYFansString(DYYYFansFirst(item, @[@"desc", @"description"]));
        // -106：play 取不到时别写 @0——@0 进了 BuildPlayMap 会被当成
        // 有效数，statistics 钩子会把播放量强制写成 0（▷ 0 的嫌疑之
        // 一）。取不到就不写这个键，映射跳过它，钩子走原始播放量；
        // 目标作品真的是 0 播放时解析出来就是 @0，不受影响。
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"aweme_id"] = awemeID;
        if (play) entry[@"playCount"] = play;
        entry[@"coverURL"] = cover ?: @"";
        entry[@"desc"] = desc ?: @"";
        [out addObject:[entry copy]];
        if (out.count >= 20) break;
    }
    return [out copy];
}

static void DYYYDisguiseFetchWorks(NSString *uid, void (^completion)(NSArray *works, NSError *error)) {
    NSString *url = [DYYYDisguiseAPIOrigin() stringByAppendingString:@"/aweme/v1/aweme/post/"];
    NSDictionary *params = @{@"user_id": uid, @"count": @20, @"max_cursor": @0};
    [[DYYYRadarNetwork shared] get:url parameters:params owner:@"DYYYDisguise" completion:^(id value, NSError *error) {
        if (error) { completion(nil, error); return; }
        completion(DYYYDisguiseParseWorks(value), nil);
    }];
}

// 逐条确认播放量：真在一条一条读，每读一条就让主线程刷一次进度
// （不是定时器假涨；20 条很快，数字一闪而过是正常的）。
static void DYYYDisguiseConfirmWorksProgressively(NSArray *works, NSUInteger index, NSMutableArray *into, NSUInteger gen, void (^done)(NSArray *confirmed)) {
    if (index >= works.count) { done([into copy]); return; }
    [into addObject:works[index]];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gen != sFetchGeneration) return;
        DYYYDisguiseShowHUD([NSString stringWithFormat:@"正在读取作品播放量 %lu/%lu",
            (unsigned long)(index + 1), (unsigned long)MAX(works.count, 1)]);
        DYYYDisguiseConfirmWorksProgressively(works, index + 1, into, gen, done);
    });
}

void DYYYDisguiseStartWithPerson(NSDictionary *person) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ DYYYDisguiseStartWithPerson(person); }); return; }
    NSString *myUID = DYYYDisguiseMyUID();
    NSString *uid = DYYYFansString(person[@"uid"]);
    if (!myUID.length) { DYYYFansToast(@"请先登录账号"); return; }
    if (!uid.length || [uid isEqual:myUID]) { DYYYFansToast(@"不能伪装成自己"); return; }
    sFetchGeneration++;
    NSUInteger gen = sFetchGeneration;
    DYYYDisguiseShowHUD(@"正在读取资料…");
    NSString *secUID = DYYYFansString(person[@"secUID"]);
    NSMutableDictionary *params = [@{@"user_id": uid, @"source": @"other_profile"} mutableCopy];
    if (secUID.length) params[@"sec_user_id"] = secUID;
    NSString *url = [DYYYDisguiseAPIOrigin() stringByAppendingString:@"/aweme/v1/user/profile/other/"];
    [[DYYYRadarNetwork shared] get:url parameters:params owner:@"DYYYDisguise" completion:^(id value, NSError *error) {
        if (gen != sFetchGeneration) return;
        NSDictionary *raw = nil;
        if ([value isKindOfClass:NSDictionary.class]) {
            id inner = value[@"data"];
            raw = [inner isKindOfClass:NSDictionary.class] ? inner : value;
        }
        id user = raw ? (DYYYFansFirst(raw, @[@"user"]) ?: raw) : nil;
        NSDictionary *target = DYYYFansPerson(user);
        if (error || !target || ![DYYYFansString(target[@"uid"]) isEqual:uid]) {
            DYYYDisguiseDismissHUD();
            DYYYFansToast(@"目标资料没取到，伪装失败，请稍后重试");
            return;
        }
        DYYYDisguiseShowHUD(@"正在读取作品列表…");
        DYYYDisguiseFetchWorks(uid, ^(NSArray *targetWorks, NSError *werr) {
            if (gen != sFetchGeneration) return;
            BOOL worksFailed = (werr != nil);
            NSArray *list = targetWorks ?: @[];
            DYYYDisguiseConfirmWorksProgressively(list, 0, [NSMutableArray array], gen, ^(NSArray *confirmed) {
                if (gen != sFetchGeneration) return;
                DYYYDisguiseShowHUD(@"正在读取我的作品…");
                DYYYDisguiseFetchWorks(myUID, ^(NSArray *myWorks, NSError *merr) {
                    if (gen != sFetchGeneration) return;
                    NSMutableArray *myIDs = [NSMutableArray array];
                    for (NSDictionary *w in myWorks ?: @[]) {
                        NSString *awemeID = DYYYFansString(w[@"aweme_id"]);
                        if (awemeID.length) [myIDs addObject:awemeID];
                    }
                    sTarget = target;
                    sTargetWorks = confirmed;
                    sPlayMap = DYYYDisguiseBuildPlayMap(myIDs, confirmed);
                    sGeneration++;
                    sSyntheticModel = nil;
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DYYYDisguiseActiveKey];
                    DYYYDisguiseSaveCache(target, confirmed, myIDs);
                    DYYYDisguiseDismissHUD();
                    DYYYDisguiseReloadOwnProfile();
                    NSString *name = DYYYFansString(target[@"name"]);
                    // -70：完成提示里写清已刷新 + 兜底（重启抖音），别让用户
                    // 以为“提示成功 = 一定已显示”。
                    if (worksFailed || merr) {
                        [DYYYToast showSuccessToastWithMessage:@"伪装完成（头像资料已伪装，作品播放量未取到）。已刷新，仍看不到请重启抖音"];
                    } else if (confirmed.count) {
                        [DYYYToast showSuccessToastWithMessage:[NSString stringWithFormat:@"伪装完成，仅本机可见：你的主页现在显示成%@，别人看到的还是你。已刷新，仍看不到请重启抖音", name.length ? name : @"对方"]];
                    } else {
                        [DYYYToast showSuccessToastWithMessage:@"伪装完成，仅本机可见：对方暂无公开作品，只伪装了头像资料。已刷新，仍看不到请重启抖音"];
                    }
                });
            });
        });
    }];
}

void DYYYDisguiseCancel(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ DYYYDisguiseCancel(); }); return; }
    sFetchGeneration++;
    sTarget = nil;
    sTargetWorks = nil;
    sPlayMap = nil;
    sSyntheticModel = nil;
    sGeneration++;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DYYYDisguiseActiveKey];
    [[NSFileManager defaultManager] removeItemAtPath:DYYYDisguiseCachePath() error:nil];
    DYYYDisguiseDismissHUD();
    DYYYDisguiseReloadOwnProfile();
    DYYYFansToast(@"已取消伪装，恢复成你自己的主页");
}
