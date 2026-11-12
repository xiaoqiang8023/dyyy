//
//  DYYYDebugCapture.h
//  DYYY
//
//  抓取当前页面的运行时快照（窗口/视图树/VC 树/图层/截图/本页类），产出
//  一个只含“已算好数据”的 DYYYDebugExportContext，交给 DYYYDebugExport 落盘。
//  移植自 DYKiller 0.7.1 DKDebugCapture，仅改前缀；音频专项（DKAudioProbeCapture
//  与 DKDebugCaptureMetadataContext）已随音频探针一并删掉，DYYY 不需要。
//

#ifndef DYYYDebugCapture_h
#define DYYYDebugCapture_h

#import <UIKit/UIKit.h>

/// 一次页面快照的产物（纯数据；序列化由 DYYYDebugExport 负责）。
@interface DYYYDebugExportContext : NSObject
@property (nonatomic, strong) NSDictionary *metadata;
@property (nonatomic, strong) NSArray *windowsJSON;
@property (nonatomic, strong) NSArray *viewTreeJSON;
@property (nonatomic, copy) NSString *viewTreeText;
@property (nonatomic, strong) NSDictionary *selectedViewJSON;
@property (nonatomic, copy) NSString *viewControllersText;
@property (nonatomic, strong) NSArray *layersJSON;
@property (nonatomic, strong) NSData *screenshotPNG;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, strong) NSArray<NSString *> *pageClassNames;
/// 主线程生成的探针文本（probe/windows.txt：前台窗口一览）；后台导出只落盘，不再读 UIKit。
@property (nonatomic, copy) NSString *probeText;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) UIViewController *presenter;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// 前台全部可见窗口（排除调试自身窗口），按系统返回顺序。
/// 探针必须逐个看：浮层窗口（如 AWEDPlayerPiPWindow，windowLevel 2000）盖在主窗口之上，
/// 只看 key 窗口会把它当成不存在。
NSArray<UIWindow *> *DYYYDebugActiveWindows(void);

/// 前台 key 窗口（排除调试自身窗口）。
UIWindow *DYYYDebugTargetWindow(void);

/// 某窗口当前最顶层的 VC（穿透 present/nav/tab）。
UIViewController *DYYYDebugTopPresenter(UIWindow *window);

/// 抓取一次页面快照。
/// 上游没有点选检查：调用方永远传 CGPointZero / nil，即整页快照。
DYYYDebugExportContext *DYYYDebugCaptureContext(UIWindow *targetWindow, CGPoint point, UIView *selectedView);

#ifdef __cplusplus
}
#endif

#endif /* DYYYDebugCapture_h */
