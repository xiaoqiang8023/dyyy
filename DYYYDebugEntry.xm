//
//  DYYYDebugEntry.xm
//  DYYY
//
//  调试工具入口（2.2-9-99，移植自 DYKiller 0.7.1 DKDebugEntry.xm）：
//  %ctor 只装调试浮层；前台窗口变化时同步浮层显隐。
//
//  与上游不同的三点：
//  · 音频探针安装（DKAudioProbeInstallIfEnabled）已删——DYYY 不移植音频探针；
//  · 设置开关不在这里注册：DYKiller 的 DKSettingsRegister / DKMakeSwitch 是
//    DYKiller 自己的设置基建，DYYY 没有；开关行由 DYYYSettings.xm 用
//    AWESettingItemModel（cellType 37）直接加，开关拨动后调
//    DYYYDebugInspectorRefreshOverlay()（见集成说明）；
//  · 因此本文件不依赖任何 DYYY 设置页代码，只依赖 DYYYDebugInspector。
//

#import "DYYYDebugInspector.h"

static BOOL DYYYEntryIsDebugWindow(UIWindow *window) {
    return [NSStringFromClass(window.class) hasPrefix:@"DYYYDebug"];
}

%hook UIWindow

- (void)becomeKeyWindow {
    %orig;
    if (!DYYYEntryIsDebugWindow(self)) DYYYDebugInspectorRefreshOverlay();
}

- (void)makeKeyAndVisible {
    %orig;
    if (!DYYYEntryIsDebugWindow(self)) DYYYDebugInspectorRefreshOverlay();
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);
    if (!hidden && !DYYYEntryIsDebugWindow(self)) DYYYDebugInspectorRefreshOverlay();
}

%end

%ctor {
    NSLog(@"[DYYY-99] debug inspector installed");
    DYYYDebugInspectorInstall();
}
