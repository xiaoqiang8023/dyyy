// DYYYLiveBoardModel.m — 见 DYYYLiveBoardModel.h。
// 取数/解析照抄 DYYYLivePreview.xm（-56/-60）已验证的逻辑，仅改名前缀；
// ApiURL 逻辑照抄 DYYYRadarApi.m 的 DYYYRadarApiURL；
// 路由写法照抄 DYYYRadarUI.m 的 DYYYRadarOpenVideo（AWERouter.transferToURLString:）。
#import "DYYYLiveBoardModel.h"
#import "DYYYRadarModel.h"
#import "DYYYRadarNetwork.h"
#import <objc/runtime.h>
#import <math.h>

NSString *const DYYYLiveBoardEnabledKey = @"DYYYLiveBoardEnabled";
NSString *const DYYYLiveBoardIntervalKey = @"DYYYLiveBoardInterval";
NSString *const DYYYLiveBoardOverlayKey = @"DYYYLiveBoardOverlay";
NSString *const DYYYLiveBoardOverlayOpacityKey = @"DYYYLiveBoardOverlayOpacity";
NSString *const DYYYLiveBoardSheetBackgroundOpacityKey = @"DYYYLiveBoardSheetBackgroundOpacity";
NSString *const DYYYLiveBoardCapsuleBackgroundOpacityKey = @"DYYYLiveBoardCapsuleBackgroundOpacity";
NSString *const DYYYLiveBoardCapsuleFontSizeKey = @"DYYYLiveBoardCapsuleFontSize";
NSString *const DYYYLiveBoardOverlayCollapsedKey = @"DYYYLiveBoardOverlayCollapsed";
NSString *const DYYYLiveBoardOverlayCenterXPercentKey = @"DYYYLiveBoardOverlayCenterXPercent";
NSString *const DYYYLiveBoardOverlayCenterYPercentKey = @"DYYYLiveBoardOverlayCenterYPercent";
NSString *const DYYYLiveBoardOverlayLandscapeCenterXPercentKey = @"DYYYLiveBoardOverlayLandscapeCenterXPercent";
NSString *const DYYYLiveBoardOverlayLandscapeCenterYPercentKey = @"DYYYLiveBoardOverlayLandscapeCenterYPercent";
NSUInteger const DYYYLiveBoardMaxAnchors = 20;
NSNotificationName const DYYYLiveBoardChanged = @"DYYYLiveBoard.Changed";
NSNotificationName const DYYYLiveBoardStoreChanged = @"DYYYLiveBoard.StoreChanged";

@protocol DYYYLiveBoardRoomAPI <NSObject>
- (instancetype)initWithRoomID:(id)roomID;
- (void)fetchRoomInfoWithRoomID:(id)roomID completion:(id)completion;
@end

// ---- 以下 static 帮助照抄 DYYYLivePreview.xm（仅改名前缀）----

static id DYYYLiveBoardValueForKey(id object, NSString *key) {
    if (!object || object == [NSNull null] || key.length == 0) return nil;
    if ([object isKindOfClass:[NSDictionary class]]) {
        id value = [object objectForKey:key];
        return value == [NSNull null] ? nil : value;
    }
    Class objectClass = [object class];
    if (![object respondsToSelector:NSSelectorFromString(key)] &&
        !class_getInstanceVariable(objectClass, key.UTF8String) &&
        !class_getInstanceVariable(objectClass, [@"_" stringByAppendingString:key].UTF8String)) return nil;
    @try {
        id value = [object valueForKey:key];
        return value == [NSNull null] ? nil : value;
    } @catch (__unused NSException *exception) { return nil; }
}

static NSNumber *DYYYLiveBoardOnlineCount(id value) {
    if ([value isKindOfClass:[NSNumber class]]) value = [value stringValue];
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) return nil;
    const char *digits = [value UTF8String];
    if (!digits || strlen(digits) != [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return nil;
    for (const char *cursor = digits; *cursor; ++cursor) if (*cursor < '0' || *cursor > '9') return nil;
    errno = 0; char *end = NULL;
    unsigned long long count = strtoull(digits, &end, 10);
    if (errno == ERANGE || end == digits || *end || count > LLONG_MAX) return nil;
    return @((long long)count);
}

static double DYYYLiveBoardNormalizeTimestamp(double value) {
    if (!isfinite(value) || value <= 0) return 0;
    if (value > 1e17) value /= 1e9;
    else if (value > 1e14) value /= 1e6;
    else if (value > 1e11) value /= 1e3;
    return value >= 1e9 && value < 1e11 ? value : 0;
}

static double DYYYLiveBoardElapsed(double start, double now) {
    start = DYYYLiveBoardNormalizeTimestamp(start);
    if (!start || !isfinite(now) || start > now + 5 || now - start > 366 * 86400) return -1;
    return fmax(0, now - start);
}

NSString *DYYYLiveBoardFormatCountCompact(long long count) {
    if (count < 0) return @"0";
    if (count < 10000) return [NSString stringWithFormat:@"%lld", count];
    double value = (double)count / 10000.0;
    NSString *unit = @"万";
    if (value >= 10000.0) { value /= 10000.0; unit = @"亿"; }
    NSString *number = [NSString stringWithFormat:@"%.2f", value];
    while ([number hasSuffix:@"0"]) number = [number substringToIndex:number.length - 1];
    if ([number hasSuffix:@"."]) number = [number substringToIndex:number.length - 1];
    return [number stringByAppendingString:unit];
}

NSString *DYYYLiveBoardElapsedDigits(double start) {
    double elapsed = DYYYLiveBoardElapsed(start, [[NSDate date] timeIntervalSince1970]);
    if (!isfinite(elapsed) || elapsed < 0 || elapsed > 366 * 86400) return nil;
    unsigned long long seconds = (unsigned long long)elapsed;
    return [NSString stringWithFormat:@"%02llu:%02llu:%02llu", seconds / 3600, (seconds / 60) % 60, seconds % 60];
}

static NSString *DYYYLiveBoardRoomIdentifier(id room) {
    for (NSString *key in @[@"roomID", @"idStr", @"id_str", @"id"]) {
        NSString *value = nil;
        id raw = DYYYLiveBoardValueForKey(room, key);
        if ([raw isKindOfClass:[NSNumber class]]) value = [raw stringValue];
        else if ([raw isKindOfClass:[NSString class]]) value = raw;
        if (value.length && ![value isEqual:@"0"] &&
            [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound) return value;
    }
    return nil;
}

static double DYYYLiveBoardRoomStartGated(id room, NSString *roomID, BOOL gated, NSUInteger depth) {
    if (!room || depth > 5) return 0;
    if ([room isKindOfClass:NSString.class] || [room isKindOfClass:NSData.class]) {
        NSData *data = [room isKindOfClass:NSString.class] ? [room dataUsingEncoding:NSUTF8StringEncoding] : room;
        if (data.length > 1024 * 1024) return 0;
        room = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!room) return 0;
    }
    NSString *identifier = DYYYLiveBoardRoomIdentifier(room);
    if (gated && identifier.length && roomID.length && ![identifier isEqual:roomID]) return 0;
    if (!gated || identifier.length) {
        for (NSString *key in @[@"startTime", @"start_time", @"liveStartTime", @"createTime", @"create_time"]) {
            id value = DYYYLiveBoardValueForKey(room, key);
            double time = [value respondsToSelector:@selector(doubleValue)] ? DYYYLiveBoardNormalizeTimestamp([value doubleValue]) : 0;
            if (DYYYLiveBoardElapsed(time, [[NSDate date] timeIntervalSince1970]) >= 0) return time;
        }
    }
    if ([room isKindOfClass:[NSArray class]]) {
        for (id item in room) {
            double time = DYYYLiveBoardRoomStartGated(item, roomID, gated, depth + 1);
            if (time) return time;
        }
    }
    for (NSString *key in @[@"rawRoom", @"room", @"roomModel", @"rawHTSLiveRoomModel", @"rawDataRoomModel", @"data", @"room_info", @"roomInfo", @"liveRoom", @"rooms"]) {
        id nested = DYYYLiveBoardValueForKey(room, key);
        if (!nested || nested == room) continue;
        double time = DYYYLiveBoardRoomStartGated(nested, roomID, gated, depth + 1);
        if (time) return time;
    }
    return 0;
}

double DYYYLiveBoardRoomStart(id object, NSString *roomID) { return DYYYLiveBoardRoomStartGated(object, roomID, YES, 0); }
double DYYYLiveBoardRoomStartRelaxed(id object) { return DYYYLiveBoardRoomStartGated(object, nil, NO, 0); }

static NSNumber *DYYYLiveBoardViewerCountInRooms(NSArray *rooms) {
    for (id room in rooms) {
        for (NSString *key in @[@"onlineCountByIM", @"userCount", @"user_count"]) {
            NSNumber *count = DYYYLiveBoardOnlineCount(DYYYLiveBoardValueForKey(room, key));
            if (count.longLongValue > 0) return count;
        }
    }
    return nil;
}

static NSNumber *DYYYLiveBoardNetworkViewerCountGated(id object, NSString *roomID, BOOL gated, NSUInteger depth) {
    if (!object || object == [NSNull null] || depth > 5) return nil;
    NSString *responseRoomID = DYYYLiveBoardRoomIdentifier(object);
    if (gated && responseRoomID && roomID.length && ![responseRoomID isEqualToString:roomID]) return nil;
    NSNumber *direct = DYYYLiveBoardViewerCountInRooms(@[object]);
    if (direct) return direct;
    for (NSString *key in @[@"data", @"room", @"roomModel", @"room_info", @"roomInfo", @"liveRoom", @"live_room", @"stats", @"roomViewStats", @"response", @"result", @"data_list", @"rooms"]) {
        id nested = DYYYLiveBoardValueForKey(object, key);
        NSNumber *count = DYYYLiveBoardNetworkViewerCountGated(nested, roomID, gated, depth + 1);
        if (count) return count;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            NSNumber *count = DYYYLiveBoardNetworkViewerCountGated(item, roomID, gated, depth + 1);
            if (count) return count;
        }
    }
    return nil;
}

NSNumber *DYYYLiveBoardViewerCount(id object, NSString *roomID) { return DYYYLiveBoardNetworkViewerCountGated(object, roomID, YES, 0); }
NSNumber *DYYYLiveBoardViewerCountRelaxed(id object) { return DYYYLiveBoardNetworkViewerCountGated(object, nil, NO, 0); }

// ---- 2.2-9-81：场观（累计进场人数）解析，与在线人数同款写法 ----

// 计数串转数字：NSNumber 直接用；纯数字串走 OnlineCount；
// 带“万”/“亿”的格式化串（如 total_user_str 常见的“12.5万”）先按后缀
// 换算回数字再统一格式化，不直接拼原文；其他一律返回 nil。
static NSNumber *DYYYLiveBoardParseCountValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        long long count = [value longLongValue];
        return count > 0 ? @(count) : nil;
    }
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    text = [text stringByReplacingOccurrencesOfString:@"," withString:@""];
    if (!text.length) return nil;
    double multiplier = 1.0;
    if ([text hasSuffix:@"万"]) { multiplier = 10000.0; text = [text substringToIndex:text.length - 1]; }
    else if ([text hasSuffix:@"亿"]) { multiplier = 100000000.0; text = [text substringToIndex:text.length - 1]; }
    if (!text.length) return nil;
    if (multiplier == 1.0) return DYYYLiveBoardOnlineCount(text);
    const char *digits = [text UTF8String];
    if (!digits || strlen(digits) != [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return nil;
    char *end = NULL;
    double number = strtod(digits, &end);
    if (end == digits || *end || !isfinite(number) || number < 0) return nil;
    double count = number * multiplier;
    if (count <= 0 || count > (double)LLONG_MAX) return nil;
    return @((long long)llround(count));
}

static NSNumber *DYYYLiveBoardTotalViewersInRooms(NSArray *rooms) {
    for (id room in rooms) {
        // 数字键优先，再试格式化字符串键（total_user_str 常见“12.5万”）。
        for (NSString *key in @[@"total_user", @"totalUser", @"total_user_count", @"totalUserCount", @"total_user_str", @"totalUserStr"]) {
            NSNumber *count = DYYYLiveBoardParseCountValue(DYYYLiveBoardValueForKey(room, key));
            if (count.longLongValue > 0) return count;
        }
    }
    return nil;
}

static NSNumber *DYYYLiveBoardNetworkTotalViewersGated(id object, NSString *roomID, BOOL gated, NSUInteger depth) {
    if (!object || object == [NSNull null] || depth > 5) return nil;
    NSString *responseRoomID = DYYYLiveBoardRoomIdentifier(object);
    if (gated && responseRoomID && roomID.length && ![responseRoomID isEqualToString:roomID]) return nil;
    NSNumber *direct = DYYYLiveBoardTotalViewersInRooms(@[object]);
    if (direct) return direct;
    for (NSString *key in @[@"data", @"room", @"roomModel", @"room_info", @"roomInfo", @"liveRoom", @"live_room", @"stats", @"roomViewStats", @"response", @"result", @"data_list", @"rooms"]) {
        id nested = DYYYLiveBoardValueForKey(object, key);
        NSNumber *count = DYYYLiveBoardNetworkTotalViewersGated(nested, roomID, gated, depth + 1);
        if (count) return count;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            NSNumber *count = DYYYLiveBoardNetworkTotalViewersGated(item, roomID, gated, depth + 1);
            if (count) return count;
        }
    }
    return nil;
}

NSNumber *DYYYLiveBoardTotalViewers(id object, NSString *roomID) { return DYYYLiveBoardNetworkTotalViewersGated(object, roomID, YES, 0); }
NSNumber *DYYYLiveBoardTotalViewersRelaxed(id object) { return DYYYLiveBoardNetworkTotalViewersGated(object, nil, NO, 0); }

// ---- room_data 解析（profile/other 响应）----

NSDictionary *DYYYLiveBoardParseRoomData(id payload) {
    id data = payload;
    if ([data isKindOfClass:NSDictionary.class] && [data[@"data"] isKindOfClass:NSDictionary.class]) data = data[@"data"];
    id roomData = nil;
    if ([data isKindOfClass:NSDictionary.class]) {
        roomData = DYYYLiveBoardValueForKey(data, @"room_data") ?: DYYYLiveBoardValueForKey(data, @"roomData");
        if (!roomData) {
            id user = DYYYLiveBoardValueForKey(data, @"user") ?: DYYYLiveBoardValueForKey(data, @"user_info") ?: DYYYLiveBoardValueForKey(data, @"userInfo");
            roomData = DYYYLiveBoardValueForKey(user, @"room_data") ?: DYYYLiveBoardValueForKey(user, @"roomData");
        }
    }
    if (![roomData isKindOfClass:NSDictionary.class]) return @{@"present": @NO, @"live": @NO};
    // status==2 是在播（web profile/other 同款字段）；room_id 长号优先，取不到用 web_rid。
    BOOL live = [DYYYLiveBoardOnlineCount(DYYYLiveBoardValueForKey(roomData, @"status")) longLongValue] == 2;
    NSString *roomID = nil;
    for (NSString *key in @[@"room_id", @"roomId", @"id", @"id_str", @"web_rid", @"webRid"]) {
        id raw = DYYYLiveBoardValueForKey(roomData, key);
        NSString *value = [raw isKindOfClass:NSNumber.class] ? [raw stringValue] : DYYYRadarString(raw);
        if (DYYYRadarIdentifier(value) && ![value isEqualToString:@"0"]) { roomID = value; break; }
    }
    NSMutableDictionary *result = [@{@"present": @YES, @"live": @(live)} mutableCopy];
    if (roomID.length) result[@"roomID"] = roomID;
    // 2.2-9-81：room_data 里带 total_user 时顺手读出来（有就用，没有也不强求）。
    NSNumber *total = DYYYLiveBoardTotalViewersInRooms(@[roomData]);
    if (total.longLongValue > 0) result[@"totalViewers"] = total;
    return result;
}

// ---- HTSLiveRoomAPI（照抄 DYYYLivePreview.xm 的签名校验与调用）----

BOOL DYYYLiveBoardRoomAPIAvailable(void) {
    Class cls = NSClassFromString(@"HTSLiveRoomAPI");
    if (!cls) return NO;
    Method initialize = class_getInstanceMethod(cls, @selector(initWithRoomID:));
    Method fetch = class_getInstanceMethod(cls, @selector(fetchRoomInfoWithRoomID:completion:));
    if (!initialize || !fetch) return NO;
    NSMethodSignature *a = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(initialize)];
    NSMethodSignature *b = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(fetch)];
    return a.numberOfArguments == 3 && a.methodReturnType[0] == '@' && [a getArgumentTypeAtIndex:2][0] == '@' &&
           b.numberOfArguments == 4 && b.methodReturnType[0] == 'v' && [b getArgumentTypeAtIndex:2][0] == '@' &&
           !strcmp([b getArgumentTypeAtIndex:3], "@?");
}

void DYYYLiveBoardFetchRoomInfo(NSNumber *roomNumber, void (^completion)(id first, id second)) {
    if (!roomNumber || roomNumber.longLongValue <= 0 || !DYYYLiveBoardRoomAPIAvailable()) { if (completion) completion(nil, nil); return; }
    Class apiClass = NSClassFromString(@"HTSLiveRoomAPI");
    id<DYYYLiveBoardRoomAPI> api = [(id<DYYYLiveBoardRoomAPI>)[apiClass alloc] initWithRoomID:roomNumber];
    if (!api) { if (completion) completion(nil, nil); return; }
    [api fetchRoomInfoWithRoomID:roomNumber completion:completion];
}

// ---- profile/other URL（照抄 DYYYRadarApi.m 的取域名逻辑）----

static NSString *DYYYLiveBoardOrigin(id raw) {
    NSString *value = [raw isKindOfClass:NSURL.class] ? [raw absoluteString] : DYYYRadarString(raw);
    if (!value.length || [value hasPrefix:@"/"]) return nil;
    if (![value containsString:@"://"]) value = [@"https://" stringByAppendingString:value];
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    if (![parts.scheme isEqualToString:@"https"] || !parts.host.length || parts.user || parts.password) return nil;
    parts.path = @""; parts.query = nil; parts.fragment = nil;
    return parts.string;
}

NSString *DYYYLiveBoardProfileOtherURL(void) {
    Class domain = NSClassFromString(@"NetworkProviderDomain");
    NSString *origin = DYYYLiveBoardOrigin(DYYYRadarCall(domain, @"apiDomain", @[])) ?: DYYYLiveBoardOrigin(DYYYRadarCall(domain, @"apiHost", @[]));
    // 2.2-9-74：与星牌 DYYYFansAPIOrigin() 逐字一致（apiDomain/apiHost，
    // 取不到直接 fallback，不再中转收藏接口）——-11001 核对时 URL 必须
    // 与星牌那条通的请求完全一致，差一个字符都可能是错误页而不是 JSON。
    return [(origin ?: @"https://aweme.snssdk.com") stringByAppendingString:@"/aweme/v1/user/profile/other/"];
}

// ---- AWERouter 跳转（照抄 DYYYRadarUI.m 的 DYYYRadarOpenVideo 写法）----

static BOOL DYYYLiveBoardTransfer(NSString *route) {
    Class router = NSClassFromString(@"AWERouter");
    if (!DYYYRadarHasMethod(router, @"transferToURLString:", "B", "@")) return NO;
    @try { return [DYYYRadarCall(router, @"transferToURLString:", @[route]) boolValue]; }
    @catch (__unused NSException *exception) { return NO; }
}

BOOL DYYYLiveBoardOpenLiveRoom(NSString *roomID, NSString *uid) {
    if (!DYYYRadarIdentifier(roomID)) return NO;
    NSString *user = DYYYRadarIdentifier(uid) ? uid : @"";
    NSArray<NSString *> *routes = @[
        [NSString stringWithFormat:@"aweme://webcast_room?id=%@", roomID],
        [NSString stringWithFormat:@"aweme://live?room_id=%@&user_id=%@", roomID, user],
        [NSString stringWithFormat:@"snssdk1128://live?room_id=%@&user_id=%@", roomID, user],
    ];
    for (NSString *route in routes) if (DYYYLiveBoardTransfer(route)) return YES;
    return NO;
}

BOOL DYYYLiveBoardOpenProfile(NSString *uid) {
    if (!DYYYRadarIdentifier(uid)) return NO;
    if (DYYYLiveBoardTransfer([@"aweme://user/profile/" stringByAppendingString:uid])) return YES;
    return DYYYLiveBoardTransfer([@"snssdk1128://user/profile/" stringByAppendingString:uid]);
}
