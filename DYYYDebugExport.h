//
//  DYYYDebugExport.h
//  DYYY
//
//  把主线程采集完成的调试上下文序列化并打包。
//  移植自 DYKiller 0.7.1 DKDebugExport，仅保留页面模式：音频专项分支
//  （DKDebugExportModeAudio 与全部 audio/ 内容）已删，DYYY 只有整页导出。
//

#ifndef DYYYDebugExport_h
#define DYYYDebugExport_h

#import <Foundation/Foundation.h>
#import "DYYYDebugCapture.h"

typedef NS_ENUM(NSUInteger, DYYYDebugExportMode) {
    DYYYDebugExportModePage,
};

/// ZIP 生成失败时，工作目录会被保留，路径放在 error.userInfo 的这个键上。
extern NSString *const DYYYDebugExportWorkingDirectoryKey;

@interface DYYYDebugExportResult : NSObject
@property (nonatomic, strong) NSURL *zipURL;
@property (nonatomic, strong) NSURL *workingDirectoryURL;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// 在后台线程生成导出包。失败时返回 nil，并通过 error 返回真实原因。
DYYYDebugExportResult *DYYYDebugCreateExport(DYYYDebugExportContext *context,
                                             DYYYDebugExportMode mode,
                                             void (^progress)(NSString *text),
                                             NSError **error);

/// 分享完成或取消后删除工作目录和 zip。
void DYYYDebugCleanupExport(DYYYDebugExportResult *result);

#ifdef __cplusplus
}
#endif

#endif /* DYYYDebugExport_h */
