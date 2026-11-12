// DYYYPortsInstall.m
// 2.2-9-66：DY778 1.0-3 三项功能移植（特别关注 / 消息留存 / 缓存管理）的统一安装入口。
// 三个功能的 install 函数都是幂等的轻量装钩，具体行为运行时再由各自的 DYYY*Enabled
// 开关控制（默认全部关闭）。安装本身只做一次，不订阅全局 NSUserDefaultsDidChangeNotification，
// 不改 layout，不在后台跑定时器——-57/-60 冻住的教训，不加回任何已摘掉的东西。
#import "DYYYRadarIntegration.h"
#import "DYYYRecall.h"
#import "DYYYRecallNotifications.h"
#import "DYYYMessageUI.h"
#import "DYYYCacheCleaner.h"
#import "DYYYLiveBoardUI.h"
#import "DYYYMessageClean.h"

void DYYYInstallPorts(void) {
    DYYYInstallRadar();
    DYYYInstallRecallHooks();
    DYYYInstallRecallNotifications();
    DYYYInstallMessageUIHooks();
    DYYYInstallCacheCleanerHooks();
    DYYYInstallLiveBoard();
    DYYYInstallMessageClean();
}

// .m 不能用 Logos 的 %ctor，故用等价的 __attribute__((constructor))，与星牌同款。
__attribute__((constructor)) static void DYYYPortsStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ DYYYInstallPorts(); });
}
