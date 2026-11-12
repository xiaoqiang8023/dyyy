// DYYYLiveBoardStore.m — 见 DYYYLiveBoardStore.h。
// 存储做法照抄 DYYYRadarStore.m（按账号 JSON、损坏文件备份、字段校验），
// 但只存主播列表，没有档案/基线/历史；写盘立即落盘（文件很小，<=20 人）。
#import "DYYYLiveBoardStore.h"
#import "DYYYLiveBoardModel.h"
#import "DYYYRadarModel.h"

@interface DYYYLiveBoardStore ()
@property(nonatomic, copy) NSString *accountID;
@property(nonatomic, copy) NSString *storageError;
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *people;
@end

static BOOL DYYYLiveBoardValidAnchor(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    if (!DYYYRadarIdentifier(value[@"uid"]) || [value[@"uid"] isEqualToString:@"0"]) return NO;
    for (NSString *key in @[@"secUID", @"handle", @"name", @"avatar"]) {
        id field = value[key];
        if (field && (![field isKindOfClass:NSString.class] || [field length] > 256)) return NO;
    }
    // 2.2-9-72：自定义名字（remark），字符串、最长 120 字（与特别关注同限）。
    id remark = value[@"remark"];
    if (remark && (![remark isKindOfClass:NSString.class] || [remark length] > 120)) return NO;
    if (value[@"addedAt"] && ![value[@"addedAt"] isKindOfClass:NSNumber.class]) return NO;
    return YES;
}

@implementation DYYYLiveBoardStore
+ (instancetype)shared {
    static DYYYLiveBoardStore *store; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        store = [[self alloc] initWithDirectory:[base URLByAppendingPathComponent:@"DYYYLiveBoard" isDirectory:YES]];
    });
    return store;
}
- (instancetype)initWithDirectory:(NSURL *)directory {
    if ((self = [super init])) {
        _directory = directory; _accountID = @""; _storageError = @"";
        _people = [NSMutableArray array];
    }
    return self;
}
- (NSURL *)fileURL {
    return [self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"account-%@.json", self.accountID]];
}
- (void)activateAccount:(NSString *)accountID {
    NSAssert(NSThread.isMainThread, @"Store is confined to the main thread");
    if ([self.accountID isEqual:accountID]) return;
    if (accountID.length && !DYYYRadarIdentifier(accountID)) accountID = @"";
    [self flush];
    self.accountID = accountID; self.storageError = @"";
    self.people = [NSMutableArray array];
    if (!accountID.length) return;
    NSURL *file = self.fileURL;
    NSData *data = [NSData dataWithContentsOfURL:file];
    if (!data) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *anchors = [json isKindOfClass:NSDictionary.class] ? json[@"anchors"] : nil;
    if (![anchors isKindOfClass:NSArray.class]) {
        // 损坏文件先备份再清空，不丢现场。
        NSURL *backup = [self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"account-%@.corrupt-%lld.json", accountID, (long long)NSDate.date.timeIntervalSince1970]];
        [NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager moveItemAtURL:file toURL:backup error:nil];
        self.storageError = @"主播列表文件已损坏，已备份后清空。";
        return;
    }
    for (id item in anchors) if (DYYYLiveBoardValidAnchor(item)) [self.people addObject:[item mutableCopy]];
}
- (NSDictionary *)options {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return @{@"enabled": @([defaults objectForKey:DYYYLiveBoardEnabledKey] ? [defaults boolForKey:DYYYLiveBoardEnabledKey] : NO),
             @"interval": @([self interval]),
             @"overlay": @([self overlayEnabled]),
             @"opacity": @([self overlayOpacity]),
             @"sheetBackgroundOpacity": @([self sheetBackgroundOpacity]),
             @"capsuleBackgroundOpacity": @([self capsuleBackgroundOpacity]),
             @"capsuleFontSize": @([self capsuleFontSize])};
}
- (BOOL)enabled { return [NSUserDefaults.standardUserDefaults boolForKey:DYYYLiveBoardEnabledKey]; }
- (BOOL)overlayEnabled {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // 2.2-9-85：未写过视为 NO（默认关）——用户嫌直播间悬浮面板挡画面；
    // 总开关关着时悬浮也不显示，由调用方再门控。以前亲手拨过开关的，
    // 键已写死，改默认值对他不生效，要自己在设置里拨回来。
    if (![defaults objectForKey:DYYYLiveBoardOverlayKey]) return NO;
    return [defaults boolForKey:DYYYLiveBoardOverlayKey];
}
// 2.2-9-75：悬浮榜透明度，未写过视为 0.64（与 -72 面板黑底一致），钳制 0.2–1.0。
- (double)overlayOpacity {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:DYYYLiveBoardOverlayOpacityKey]) return 0.64;
    return fmin(1.0, fmax(0.2, [defaults doubleForKey:DYYYLiveBoardOverlayOpacityKey]));
}
// 2.2-9-94：底页背景不透明度，未写过视为 0.85，钳制 0.3–1.0。
- (double)sheetBackgroundOpacity {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:DYYYLiveBoardSheetBackgroundOpacityKey]) return 0.85;
    return fmin(1.0, fmax(0.3, [defaults doubleForKey:DYYYLiveBoardSheetBackgroundOpacityKey]));
}
// 2.2-9-98：胶囊背景不透明度，未写过视为 0.42（-97 的样子），钳制 0.1–1.0。
- (double)capsuleBackgroundOpacity {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:DYYYLiveBoardCapsuleBackgroundOpacityKey]) return 0.42;
    return fmin(1.0, fmax(0.1, [defaults doubleForKey:DYYYLiveBoardCapsuleBackgroundOpacityKey]));
}
// 2.2-9-98：胶囊字号，未写过视为 13pt（-97 的样子），钳制 11–18pt。
- (double)capsuleFontSize {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:DYYYLiveBoardCapsuleFontSizeKey]) return 13.0;
    return fmin(18.0, fmax(11.0, [defaults doubleForKey:DYYYLiveBoardCapsuleFontSizeKey]));
}
- (NSTimeInterval)interval {
    double value = [NSUserDefaults.standardUserDefaults doubleForKey:DYYYLiveBoardIntervalKey];
    if (value <= 0) return 30;
    return fmin(300, fmax(10, value));
}
- (void)setOption:(NSString *)key value:(id)value {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([key isEqualToString:@"enabled"]) [defaults setBool:[value boolValue] forKey:DYYYLiveBoardEnabledKey];
    else if ([key isEqualToString:@"interval"]) [defaults setDouble:fmin(300, fmax(10, [value doubleValue])) forKey:DYYYLiveBoardIntervalKey];
    else if ([key isEqualToString:@"overlay"]) [defaults setBool:[value boolValue] forKey:DYYYLiveBoardOverlayKey];
    else if ([key isEqualToString:@"opacity"]) [defaults setDouble:fmin(1.0, fmax(0.2, [value doubleValue])) forKey:DYYYLiveBoardOverlayOpacityKey];
    else if ([key isEqualToString:@"sheetBackgroundOpacity"]) [defaults setDouble:fmin(1.0, fmax(0.3, [value doubleValue])) forKey:DYYYLiveBoardSheetBackgroundOpacityKey];
    else if ([key isEqualToString:@"capsuleBackgroundOpacity"]) [defaults setDouble:fmin(1.0, fmax(0.1, [value doubleValue])) forKey:DYYYLiveBoardCapsuleBackgroundOpacityKey];
    else if ([key isEqualToString:@"capsuleFontSize"]) [defaults setDouble:fmin(18.0, fmax(11.0, [value doubleValue])) forKey:DYYYLiveBoardCapsuleFontSizeKey];
    [defaults synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:DYYYLiveBoardStoreChanged object:self];
}
- (NSArray<NSDictionary *> *)anchors { return [self.people copy]; }
- (NSDictionary *)anchor:(NSString *)uid {
    for (NSDictionary *person in self.people) if ([person[@"uid"] isEqual:uid]) return person;
    return nil;
}
- (BOOL)addAnchor:(NSDictionary *)profile error:(NSError **)error {
    if (!DYYYLiveBoardValidAnchor(profile)) {
        if (error) *error = DYYYRadarError(400, @"主播资料不完整，请重新添加。");
        return NO;
    }
    if ([self anchor:profile[@"uid"]]) {
        if (error) *error = DYYYRadarError(409, @"这位主播已经在榜单里了。");
        return NO;
    }
    if (self.people.count >= DYYYLiveBoardMaxAnchors) {
        if (error) *error = DYYYRadarError(400, @"榜单最多 20 位主播，先删掉一位再添加。");
        return NO;
    }
    // 2.2-9-73：secUID 从四个键里取第一个非空的（星牌 person 用 secUID 键，
    // 资料接口用 sec_uid，别只认一个）；丢了 secUID 就没法走 reflow 兜底。
    NSString *secUID = @"";
    for (NSString *key in @[@"secUID", @"sec_uid", @"sec_user_id", @"secUserID"]) {
        secUID = DYYYRadarString(profile[key]);
        if (secUID.length) break;
    }
    NSMutableDictionary *anchor = [@{@"uid": DYYYRadarString(profile[@"uid"]),
        @"secUID": secUID,
        @"handle": DYYYRadarString(profile[@"handle"]),
        @"name": DYYYRadarString(profile[@"name"]),
        @"avatar": DYYYRadarString(profile[@"avatar"]),
        @"addedAt": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
    // 2.2-9-72：带过来的自定义名字（remark）一并存下。
    NSString *remark = DYYYRadarString(profile[@"remark"]);
    if (remark.length) anchor[@"remark"] = remark;
    [self.people addObject:anchor];
    [self save];
    [NSNotificationCenter.defaultCenter postNotificationName:DYYYLiveBoardStoreChanged object:self];
    return YES;
}
// 2.2-9-73：只补写 secUID 字段（给 -72 加人时丢了 secUID 的已存主播补回用），
// 不动名字、自定义名字、头像；写回失败或主播不在了返回 NO。
- (BOOL)updateSecUID:(NSString *)secUID forUID:(NSString *)uid {
    NSAssert(NSThread.isMainThread, @"Store is confined to the main thread");
    NSMutableDictionary *anchor = nil;
    for (NSMutableDictionary *person in self.people) {
        if ([person[@"uid"] isEqual:uid]) { anchor = person; break; }
    }
    if (!anchor) return NO;
    NSString *clean = DYYYRadarString(secUID);
    if (!clean.length) return NO;
    if ([anchor[@"secUID"] isEqual:clean]) return YES; // 已经有了，不重复写盘
    anchor[@"secUID"] = clean;
    [self save];
    [NSNotificationCenter.defaultCenter postNotificationName:DYYYLiveBoardStoreChanged object:self];
    return YES;
}
- (BOOL)setCustomName:(NSString *)name forUID:(NSString *)uid {
    NSAssert(NSThread.isMainThread, @"Store is confined to the main thread");
    NSMutableDictionary *anchor = nil;
    for (NSMutableDictionary *person in self.people) {
        if ([person[@"uid"] isEqual:uid]) { anchor = person; break; }
    }
    if (!anchor) return NO;
    NSString *clean = [name ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length > 30) clean = [clean substringToIndex:30];
    if (clean.length) anchor[@"remark"] = clean;
    else [anchor removeObjectForKey:@"remark"];
    [self save];
    [NSNotificationCenter.defaultCenter postNotificationName:DYYYLiveBoardStoreChanged object:self];
    return YES;
}
- (void)removeAnchor:(NSString *)uid {
    NSUInteger index = [self.people indexOfObjectPassingTest:^BOOL(NSDictionary *person, NSUInteger idx, BOOL *stop) { return [person[@"uid"] isEqual:uid]; }];
    if (index == NSNotFound) return;
    [self.people removeObjectAtIndex:index];
    [self save];
    [NSNotificationCenter.defaultCenter postNotificationName:DYYYLiveBoardStoreChanged object:self];
}
- (void)save {
    if (!self.accountID.length) return;
    [NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"anchors": self.people} options:0 error:nil];
    if (data) [data writeToURL:self.fileURL atomically:YES];
}
- (void)flush { [self save]; }
- (NSUInteger)storageBytes {
    if (!self.accountID.length) return 0;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.fileURL.path error:nil];
    return [attributes[NSFileSize] unsignedIntegerValue];
}
@end
