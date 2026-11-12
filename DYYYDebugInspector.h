//
//  DYYYDebugInspector.h
//  DYYY
//
//  全局扳手入口：独立高层级 window 承载调试按钮，点扳手导出整页快照。
//  移植自 DYKiller 0.7.1 DKDebugInspector，仅改前缀；音频探针与底栏探针已删。
//

#ifndef DYYYDebugInspector_h
#define DYYYDebugInspector_h

#import <UIKit/UIKit.h>

/// 调试工具总开关的 NSUserDefaults 键，默认 OFF（未写过即关）。
extern NSString *const DYYYDebugInspectorEnabledKey;

#ifdef __cplusplus
extern "C" {
#endif

void DYYYDebugInspectorInstall(void);
void DYYYDebugInspectorRefreshOverlay(void);

#ifdef __cplusplus
}
#endif

#endif /* DYYYDebugInspector_h */
