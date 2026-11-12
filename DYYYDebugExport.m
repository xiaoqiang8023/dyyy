//
//  DYYYDebugExport.m
//  DYYY
//
//  只处理不可变采集结果的序列化、类元数据导出与 ZIP 打包。
//  移植自 DYKiller 0.7.1 DKDebugExport，仅保留页面模式（音频分支已删）。
//
//  两条硬规矩：
//  · 收集到的文件数有上限，超了就截断并在 manifest 标记，不把失败留给打包那一步。
//  · 打包失败时保留工作目录并把路径回传，错误信息里带上 underlying —— 唯一能
//    解释失败原因的东西不能跟着失败一起消失。
//

#import "DYYYDebugExport.h"
#import "DYYYClassDump.h"
#import "DYYYConstants.h"
#import "DYYYZipWriter.h"

NSString *const DYYYDebugExportWorkingDirectoryKey = @"DYYYDebugExportWorkingDirectory";

static NSString *const DYYYExportErrorDomain = @"com.dyyy.debug-export";

// 单个导出包的文件数上限。页面导出约 200 个，
// 这道闸门只用来防止将来某处再写出失控的循环。
static const NSUInteger kDYYYMaxExportFiles = 8000;

@implementation DYYYDebugExportResult
@end

#pragma mark - 写入汇集器

// 把「文件清单 + 错误清单 + 关键失败标记 + 截断计数」收在一起，
// 免得每个写入函数都拖着四个 out 参数。
@interface DYYYExportSink : NSObject
@property (nonatomic, copy) NSString *rootDir;
@property (nonatomic, strong) NSMutableArray<NSString *> *files;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *errors;
@property (nonatomic, assign) BOOL criticalFailed;
@property (nonatomic, assign) NSUInteger droppedFiles;
@end

@implementation DYYYExportSink

- (instancetype)initWithRootDir:(NSString *)rootDir {
    if ((self = [super init])) {
        _rootDir = [rootDir copy];
        _files = [NSMutableArray array];
        _errors = [NSMutableArray array];
    }
    return self;
}

@end

#pragma mark - 文件工具

static NSError *DYYYMakeExportError(NSInteger code, NSString *message, NSError *underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message ?: @"导出失败"
                                                                   forKey:NSLocalizedDescriptionKey];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:DYYYExportErrorDomain code:code userInfo:info];
}

static NSString *DYYYSafeFileName(NSString *name) {
    if (!name.length) return @"Unknown";
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:"];
    NSString *safe = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    return safe.length ? safe : @"Unknown";
}

static NSString *DYYYUniqueFileStem(NSString *name) {
    NSString *safe = DYYYSafeFileName(name);
    if (safe.length > 160) {
        NSRange range = [safe rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 160)];
        safe = [safe substringWithRange:range];
    }
    NSData *utf8 = [(name ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t *bytes = utf8.bytes;
    for (NSUInteger i = 0; i < utf8.length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%@-%08llx", safe, (unsigned long long)(hash & 0xffffffffULL)];
}

static void DYYYRecordError(DYYYExportSink *sink,
                            NSString *relativePath,
                            NSString *stage,
                            NSError *error,
                            BOOL critical) {
    [sink.errors addObject:@{
        @"path": relativePath ?: @"",
        @"stage": stage ?: @"write",
        @"critical": @(critical),
        @"domain": error.domain ?: @"",
        @"code": @(error.code),
        @"message": error.localizedDescription ?: @"unknown error",
    }];
}

static BOOL DYYYWriteData(DYYYExportSink *sink, NSString *relativePath, NSData *data, BOOL critical) {
    if (sink.files.count >= kDYYYMaxExportFiles) {
        sink.droppedFiles++;
        return NO;
    }

    NSString *path = [sink.rootDir stringByAppendingPathComponent:relativePath];
    NSError *writeError = nil;
    NSString *directory = path.stringByDeletingLastPathComponent;
    BOOL ok = data && [NSFileManager.defaultManager createDirectoryAtPath:directory
                                              withIntermediateDirectories:YES
                                                               attributes:nil
                                                                    error:&writeError];
    if (ok) ok = [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
    if (ok) {
        [sink.files addObject:path];
        return YES;
    }
    if (!writeError) writeError = DYYYMakeExportError(10, @"没有可写入的数据", nil);
    DYYYRecordError(sink, relativePath, @"write", writeError, critical);
    if (critical) sink.criticalFailed = YES;
    return NO;
}

static BOOL DYYYWriteString(DYYYExportSink *sink, NSString *relativePath, NSString *string, BOOL critical) {
    return DYYYWriteData(sink, relativePath, [(string ?: @"") dataUsingEncoding:NSUTF8StringEncoding], critical);
}

static BOOL DYYYWriteJSON(DYYYExportSink *sink, NSString *relativePath, id object, BOOL critical) {
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{}
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (!data) {
        DYYYRecordError(sink, relativePath, @"json",
                        jsonError ?: DYYYMakeExportError(11, @"JSON 序列化失败", nil), critical);
        if (critical) sink.criticalFailed = YES;
        return NO;
    }
    return DYYYWriteData(sink, relativePath, data, critical);
}

static NSString *DYYYModeName(DYYYDebugExportMode mode) {
    return @"page";
}

#pragma mark - README

static NSString *DYYYReadme(DYYYDebugExportContext *context, DYYYDebugExportMode mode) {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"DYYY Debug Export\n"];
    [text appendFormat:@"Generated: %@\n", context.metadata[@"generatedAt"] ?: @""];
    [text appendFormat:@"DYYY: %@\n", DYYY_VERSION];
    [text appendFormat:@"Bundle: %@\n", context.metadata[@"bundleIdentifier"] ?: @""];
    [text appendFormat:@"App: %@ %@ (%@)\n",
     context.metadata[@"bundleName"] ?: @"", context.metadata[@"appVersion"] ?: @"",
     context.metadata[@"buildVersion"] ?: @""];
    [text appendFormat:@"System: %@ %@\n", context.metadata[@"systemName"] ?: @"",
     context.metadata[@"systemVersion"] ?: @""];
    [text appendFormat:@"Mode: %@\n\n", DYYYModeName(mode)];

    [text appendString:@"Contents:\n- page/: UI 主线程快照与本页类\n"];
    [text appendString:@"- probe/windows.txt: 前台窗口一览（窗口类 / 层级 / 是否 key 窗口 / 顶层 VC）\n- ui/: 目标窗口截图\n"];
    return text;
}

#pragma mark - 页面内容

static void DYYYWritePageClasses(DYYYExportSink *sink, NSArray<NSString *> *classNames) {
    for (NSString *name in [classNames sortedArrayUsingSelector:@selector(compare:)]) {
        @autoreleasepool {
            @try {
                Class cls = NSClassFromString(name);
                NSString *header = cls ? DYYYClassDumpHeaderForClass(cls) : nil;
                if (!header.length) continue;
                NSString *relative = [@"page/classes" stringByAppendingPathComponent:
                                      [DYYYUniqueFileStem(name) stringByAppendingString:@".h"]];
                DYYYWriteString(sink, relative, header, NO);
            } @catch (NSException *exception) {
                DYYYRecordError(sink, name, @"page-class",
                                DYYYMakeExportError(20, exception.reason ?: @"类头文件导出异常", nil), NO);
            }
        }
    }
}

static void DYYYWritePageFiles(DYYYExportSink *sink,
                               DYYYDebugExportContext *context,
                               void (^progress)(NSString *text)) {
    if (progress) progress(@"写入页面结构...");
    DYYYWriteJSON(sink, @"page/windows.json", context.windowsJSON ?: @[], NO);
    DYYYWriteString(sink, @"page/view-tree.txt", context.viewTreeText, NO);
    DYYYWriteJSON(sink, @"page/view-tree.json", context.viewTreeJSON ?: @[], NO);
    DYYYWriteJSON(sink, @"page/selected-view.json", context.selectedViewJSON ?: @{}, NO);
    DYYYWriteString(sink, @"page/view-controllers.txt", context.viewControllersText, NO);
    DYYYWriteJSON(sink, @"page/layers.json", context.layersJSON ?: @[], NO);
    if (progress) progress(@"导出本页类头文件...");
    DYYYWritePageClasses(sink, context.pageClassNames ?: @[]);
}

#pragma mark - 导出入口

DYYYDebugExportResult *DYYYDebugCreateExport(DYYYDebugExportContext *context,
                                             DYYYDebugExportMode mode,
                                             void (^progress)(NSString *text),
                                             NSError **error) {
    if (!context) {
        if (error) *error = DYYYMakeExportError(1, @"导出上下文不完整", nil);
        return nil;
    }

    NSString *rootName = [NSString stringWithFormat:@"DYYY-Debug-%@-%@-%lld",
                          DYYYModeName(mode), NSBundle.mainBundle.bundleIdentifier ?: @"Aweme",
                          (long long)NSDate.date.timeIntervalSince1970];
    NSString *temporary = NSTemporaryDirectory();
    NSString *rootDir = [temporary stringByAppendingPathComponent:rootName];
    NSString *zipPath = [temporary stringByAppendingPathComponent:[rootName stringByAppendingString:@".zip"]];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:rootDir error:nil];
    [fm removeItemAtPath:zipPath error:nil];

    NSError *directoryError = nil;
    if (![fm createDirectoryAtPath:rootDir withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        if (error) *error = DYYYMakeExportError(2, @"无法创建导出目录", directoryError);
        return nil;
    }

    DYYYExportSink *sink = [[DYYYExportSink alloc] initWithRootDir:rootDir];
    DYYYWriteString(sink, @"README.txt", DYYYReadme(context, mode), NO);
    DYYYWriteData(sink, @"ui/screenshot.png", context.screenshotPNG, NO);
    // 上游这里写的是 DKTabBarProbe 的底栏诊断（probe/tabbar.txt），DYYY 不移植
    // DKTabBarProbe；改成主线程生成的通用前台窗口一览，仍放在 probe/ 下，
    // 找“面板在哪个窗口里”时直接看它。
    DYYYWriteString(sink, @"probe/windows.txt", context.probeText, NO);

    DYYYWritePageFiles(sink, context, progress);

    NSDictionary *manifest = @{
        @"schemaVersion": @"dyyy.debug.v2",
        @"mode": DYYYModeName(mode),
        @"dyyyVersion": DYYY_VERSION,
        @"device": context.metadata ?: @{},
        @"integrity": @{
            @"complete": @(!sink.criticalFailed && sink.droppedFiles == 0),
            @"status": sink.criticalFailed ? @"critical-failure"
                     : (sink.droppedFiles ? @"truncated"
                     : (sink.errors.count ? @"complete-with-recoverable-errors" : @"complete")),
            @"fileCount": @(sink.files.count),
            @"fileLimit": @(kDYYYMaxExportFiles),
            @"truncated": @(sink.droppedFiles > 0),
            @"droppedFiles": @(sink.droppedFiles),
            @"errorCount": @(sink.errors.count),
            @"errors": sink.errors,
        },
    };
    DYYYWriteJSON(sink, @"manifest.json", manifest, NO);

    if (sink.criticalFailed) {
        if (error) {
            *error = [NSError errorWithDomain:DYYYExportErrorDomain code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"关键文件写入失败，工作目录已保留",
                DYYYDebugExportWorkingDirectoryKey: rootDir,
            }];
        }
        return nil;
    }

    if (progress) progress(@"压缩 zip...");
    NSError *zipError = nil;
    BOOL zipped = sink.files.count > 0 && [DYYYZipWriter createZipAtPath:zipPath
                                                                 rootDir:rootDir
                                                                   files:sink.files
                                                                progress:nil
                                                                   error:&zipError];
    NSError *attributeError = nil;
    NSDictionary *attributes = zipped ? [fm attributesOfItemAtPath:zipPath error:&attributeError] : nil;
    NSNumber *zipSize = attributes[NSFileSize];
    if (!zipped || zipError || attributeError || zipSize.unsignedLongLongValue <= 22) {
        NSError *underlying = zipError ?: attributeError;
        NSString *message = underlying
            ? [NSString stringWithFormat:@"ZIP 生成失败（%lu 个待打包文件）：%@",
               (unsigned long)sink.files.count, underlying.localizedDescription]
            : [NSString stringWithFormat:@"ZIP 未生成或内容为空（%lu 个待打包文件）",
               (unsigned long)sink.files.count];
        [fm removeItemAtPath:zipPath error:nil];
        // 工作目录留着：它是唯一能解释这次失败的现场。
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:@{
            NSLocalizedDescriptionKey: message,
            DYYYDebugExportWorkingDirectoryKey: rootDir,
        }];
        if (underlying) info[NSUnderlyingErrorKey] = underlying;
        if (error) *error = [NSError errorWithDomain:DYYYExportErrorDomain code:4 userInfo:info];
        return nil;
    }

    DYYYDebugExportResult *result = [DYYYDebugExportResult new];
    result.zipURL = [NSURL fileURLWithPath:zipPath];
    result.workingDirectoryURL = [NSURL fileURLWithPath:rootDir isDirectory:YES];
    return result;
}

void DYYYDebugCleanupExport(DYYYDebugExportResult *result) {
    if (!result) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (result.workingDirectoryURL.isFileURL) [fm removeItemAtURL:result.workingDirectoryURL error:nil];
    if (result.zipURL.isFileURL) [fm removeItemAtURL:result.zipURL error:nil];
}
