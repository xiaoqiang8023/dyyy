// DYYYMessageClean.m
// 消息页精简的刷新入口、诊断与安装：汇总顶栏与列表顶部两部分。
// 移植自 DYKiller DKMessageClean.m，仅改名前缀与键名；逻辑未改。
#import "DYYYMessageClean.h"
#import "AwemeHeaders.h"

DYYYMessageCleanDisplayMode DYYYMessageCleanModeForKey(NSString *key) {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if ([raw isKindOfClass:NSString.class]) {
        if ([raw isEqualToString:@"隐藏"]) return DYYYMessageCleanDisplayModeHide;
        if ([raw isEqualToString:@"移除"]) return DYYYMessageCleanDisplayModeRemove;
        return DYYYMessageCleanDisplayModeShow;
    }
    if ([raw respondsToSelector:@selector(integerValue)]) {
        NSInteger value = [raw integerValue];
        if (value == DYYYMessageCleanDisplayModeHide || value == DYYYMessageCleanDisplayModeRemove) {
            return (DYYYMessageCleanDisplayMode)value;
        }
    }
    return DYYYMessageCleanDisplayModeShow;
}

NSString *DYYYMessageCleanModeText(DYYYMessageCleanDisplayMode mode) {
    switch (mode) {
        case DYYYMessageCleanDisplayModeHide: return @"隐藏";
        case DYYYMessageCleanDisplayModeRemove: return @"移除";
        default: return @"显示";
    }
}

void DYYYInstallMessageClean(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYInstallMessageClean(); });
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[DYYY-99] message clean installed");
        // 顶栏 / 列表顶部是顶层 %hook，随文件链接即生效；聊天页两组在各自
        // .xm 的 %ctor 里 %init；这里只做一次即时刷新，不订阅任何通知。
        DYYYMessageCleanRefresh();
    });
}

void DYYYMessageCleanRefresh(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYMessageCleanRefresh(); });
        return;
    }
    DYYYMessageCleanTopBarRefresh();
    DYYYMessageCleanListRefresh();
}

NSString *DYYYMessageCleanStatus(void) {
    NSArray<NSArray<NSString *> *> *items = @[
        @[ DYYYKeyMessageSideBarMode, @"左侧栏" ],
        @[ DYYYKeyMessageSlotMode, @"装扮商店" ],
        @[ DYYYKeyMessageSearchMode, @"搜索图标" ],
        @[ DYYYKeyMessagePlusMode, @"加号" ],
        @[ DYYYKeyMessageDailyMode, @"限时日常" ],
        @[ DYYYKeyMessageFriendAvatarMode, @"好友大头像" ],
        @[ DYYYKeyMessageInteractionMode, @"互动消息" ],
    ];
    NSMutableArray<NSString *> *modes = [NSMutableArray array];
    for (NSArray<NSString *> *item in items) {
        [modes addObject:[NSString stringWithFormat:@"%@=%@", item[1], DYYYMessageCleanModeText(DYYYMessageCleanModeForKey(item[0]))]];
    }
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"档位：%@\n", [modes componentsJoinedByString:@" "]];
    [out appendString:DYYYMessageCleanTopBarStatus()];
    [out appendString:DYYYMessageCleanListStatus()];
    return out;
}
