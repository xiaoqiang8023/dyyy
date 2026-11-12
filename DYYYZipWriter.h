//
//  DYYYZipWriter.h
//  DYYY
//
//  调试导出使用的最小 ZIP 写入器（移植自 DYKiller 0.7.1 DKZipWriter，仅改前缀）。
//  以不压缩方式写入文件，使用 zlib 计算 CRC32，并支持 ZIP64 条目计数。
//  需要链接 -lz（见 Makefile 的 DYYY_LDFLAGS）。
//

#ifndef DYYYZipWriter_h
#define DYYYZipWriter_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DYYYZipProgressBlock)(CGFloat progress);

@interface DYYYZipWriter : NSObject

+ (BOOL)createZipAtPath:(NSString *)zipPath
                rootDir:(NSString *)rootDir
                  files:(NSArray<NSString *> *)files
               progress:(DYYYZipProgressBlock _Nullable)progress
                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* DYYYZipWriter_h */
