//
//  DYYYClassDump.h
//  DYYY
//
//  把 ObjC 运行时元数据生成类头文件文本（移植自 DYKiller 0.7.1 DKClassDump，仅改前缀）。
//  内置安全内省检查。
//

#ifndef DYYYClassDump_h
#define DYYYClassDump_h

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 该类是否可安全内省（不安全类集合 + 根类检查）。
BOOL DYYYClassIsSafe(Class cls);

/// 该类名是否为运行时生成的子类噪声（NSKVONotifying_ / _hmd_subfix_ / _AWEPERF_ / _block_invoke / %）。
BOOL DYYYClassNameIsRuntimeGenerated(NSString *name);

/// 生成单个类的头文件文本。
/// 内含安全内省检查 + @try 兜底；不安全 / nil 一律返回 nil。
NSString *DYYYClassDumpHeaderForClass(Class cls);

#ifdef __cplusplus
}
#endif

#endif /* DYYYClassDump_h */
