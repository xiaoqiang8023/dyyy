// DYYYLiveBoardOverlayHooks.xm — 直播间内悬浮人气榜的挂载钩子（2.2-9-72）。
// 钩点与 -7 开播时长胶囊（DYYY.xm）完全一致：AWELiveAudienceContainerController
// 的 init/setAudienceVC/setRoomModel/updateWithRoomModel 等 + AWELiveAudienceViewController，
// 不另找没验证过的类。安装/拆除逻辑在 DYYYLiveBoardOverlay.m 里，这里只转发。
// 安装是幂等的（root 上已有悬浮榜就不再新建），进出直播间多次也不会重复挂。
#import "DYYYLiveBoardOverlay.h"
#import "DYYYLiveBoardAudienceEntry.h"
#import "DYYYLiveBoardLongPressEntry.h"
#import "AwemeHeaders.h" // IESLiveAudienceViewController 的完整声明（view/isViewLoaded）

%hook AWELiveAudienceContainerController

- (id)initWithRoomModel:(id)roomModel {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DYYYLiveBoardOverlayInstallFromContainer(weakResult);
    });
    return result;
}

- (id)initWithRoomModel:(id)roomModel config:(id)config {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DYYYLiveBoardOverlayInstallFromContainer(weakResult);
    });
    return result;
}

- (id)initWithRoomModel:(id)roomModel context:(id)context {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DYYYLiveBoardOverlayInstallFromContainer(weakResult);
    });
    return result;
}

- (id)initWithRoomModel:(id)roomModel context:(id)context player:(id)player {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DYYYLiveBoardOverlayInstallFromContainer(weakResult);
    });
    return result;
}

- (void)setAudienceVC:(UIViewController *)audienceVC {
    %orig;
    DYYYLiveBoardOverlayInstallFromContainer(self);
}

- (void)setRoomModel:(id)roomModel {
    %orig;
    DYYYLiveBoardOverlayInstallFromContainer(self);
}

- (void)createAudienceViewController:(id)arg beginTime:(double)beginTime {
    %orig;
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DYYYLiveBoardOverlayInstallFromContainer(weakSelf);
    });
}

- (id)audienceControllerWithRoom:(id)room beginTime:(double)beginTime {
    id result = %orig;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        DYYYLiveBoardOverlayInstallFromContainer(weakSelf);
    });
    return result;
}

- (void)updateWithRoomModel:(id)roomModel config:(id)config {
    %orig;
    DYYYLiveBoardOverlayInstallFromContainer(self);
}

- (void)updateWithRoomModel:(id)roomModel context:(id)context {
    %orig;
    DYYYLiveBoardOverlayInstallFromContainer(self);
}

- (void)updateWithRoomModel:(id)roomModel context:(id)context player:(id)player {
    %orig;
    DYYYLiveBoardOverlayInstallFromContainer(self);
}

- (void)clearAudience {
    DYYYLiveBoardOverlayRemoveFromContainer(self);
    %orig;
}

- (void)prepareForReuse {
    DYYYLiveBoardOverlayRemoveFromContainer(self);
    %orig;
}

- (void)dealloc {
    DYYYLiveBoardOverlayRemoveFromContainer(self);
    %orig;
}

%end

%hook AWELiveAudienceViewController

- (id)initWithRoomModel:(id)roomModel {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DYYYLiveBoardOverlayInstallFromAudienceWrapper(weakResult);
    });
    return result;
}

- (void)setRoomModel:(id)roomModel {
    %orig;
    DYYYLiveBoardOverlayInstallFromAudienceWrapper(self);
}

- (void)setAudienceViewController:(UIViewController *)audienceViewController {
    %orig;
    DYYYLiveBoardOverlayInstallFromAudienceWrapper(self);
}

- (void)attachAudienceViewControllerDelegate:(id)delegate {
    %orig;
    DYYYLiveBoardOverlayInstallFromAudienceWrapper(self);
}

- (void)exitLiveRoomWithType:(unsigned long long)type {
    DYYYLiveBoardOverlayRemoveFromAudienceWrapper(self);
    %orig;
}

- (void)dealloc {
    DYYYLiveBoardOverlayRemoveFromAudienceWrapper(self);
    %orig;
}

%end

// 2.2-9-73：直播广场/推荐页上下滑切换的房间（inner feed cell）+
// 观众页控制器自身的生命周期——开播时长胶囊有这两条安装路，悬浮榜
// -72 只有容器和 wrapper 两条，所以滑着进的房间不显示。
// viewDidLayoutSubviews 故意不钩（安装会改 frame，不在布局回调里动帧）。
%hook IESLiveInnerFeedLiveRoomCell

- (void)setItemModel:(id)itemModel {
    %orig;
    DYYYLiveBoardOverlayInstallFromInnerFeedCell(self);
}

- (void)setRoomAisle:(id)roomAisle {
    %orig;
    DYYYLiveBoardOverlayInstallFromInnerFeedCell(self);
}

- (void)setAudienceVC:(UIViewController *)audienceVC {
    %orig;
    DYYYLiveBoardOverlayInstallFromInnerFeedCell(self);
}

- (void)updateWithItemModel:(id)itemModel {
    %orig;
    DYYYLiveBoardOverlayInstallFromInnerFeedCell(self);
}

- (void)prepareForReuse {
    DYYYLiveBoardOverlayRemoveFromInnerFeedCell(self);
    %orig;
}

%end

%hook IESLiveAudienceViewController

- (void)viewDidLoad {
    %orig;
    DYYYLiveBoardOverlayInstallOnView(self.view);
    DYYYLiveBoardAudienceEntryInstall(self);
    __weak id weakSelf = self;
    // 房间自己的 view 陆续加上来可能盖住悬浮榜，0.35 秒后再装一次置顶。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf) DYYYLiveBoardOverlayInstallOnView([weakSelf view]);
    });
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    DYYYLiveBoardOverlayInstallOnView(self.view);
    DYYYLiveBoardAudienceEntryInstall(self);
}

// 2.2-9-85：在线观众面板的“人气榜”入口。面板可能在进房间时已预建好
// （viewDidAppear 时直接装上），也可能在用户点人数后才现出来——
// presentViewController 完成回调里再试一次（面板是单独呈现的 sheet 时
// 它不在 room VC 子树里，Install 会再扫 keyWindow）；1 秒后还有一次
// 延迟重试，盖住房间 view 陆续加进来的情况。Install 自身幂等，多调无害。
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    DYYYLiveBoardAudienceEntryInstall(self);
    DYYYLiveBoardAudienceEntryStartWatcher(self);
    __weak IESLiveAudienceViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IESLiveAudienceViewController *strongSelf = weakSelf;
        if (strongSelf) DYYYLiveBoardAudienceEntryInstall(strongSelf);
    });
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    __weak IESLiveAudienceViewController *weakSelf = self;
    void (^wrappedCompletion)(void) = ^{
        if (completion) completion();
        IESLiveAudienceViewController *strongSelf = weakSelf;
        if (strongSelf) DYYYLiveBoardAudienceEntryInstall(strongSelf);
    };
    %orig(viewControllerToPresent, flag, wrappedCompletion);
}

- (void)didEnterRoom:(id)room {
    %orig;
    DYYYLiveBoardOverlayInstallOnView(self.view);
    DYYYLiveBoardAudienceEntryInstall(self);
    DYYYLiveBoardAudienceEntryStartWatcher(self);
}

- (void)didPreloadRoom:(id)room {
    %orig;
    DYYYLiveBoardOverlayInstallOnView(self.view);
    DYYYLiveBoardAudienceEntryInstall(self);
}

- (void)didCloseRoom:(id)room closeType:(unsigned long long)type {
    DYYYLiveBoardAudienceEntryStopWatcher();
    DYYYLiveBoardOverlayRemoveFromView(self.view);
    %orig;
}

- (void)dealloc {
    DYYYLiveBoardAudienceEntryStopWatcher();
    if (self.isViewLoaded) {
        DYYYLiveBoardOverlayRemoveFromView(self.view);
    }
    %orig;
}

%end

// 2.2-9-86：修 -85 真机入口没出现。-85 的 Install 只挂在
// IESLiveAudienceViewController 的生命周期上，而它是在播房间的 VC
// 本身、不是“在线观众”那张 sheet；面板若由别的 VC 呈现、或挂在
// sheet 管理器下，面板真正出现时没有任何 -85 触发点会跑。
// 补两条在面板真正出现时才跑的触发点（只做这一件，其他不动）：
// ① 任何被呈现出来的 VC 在 viewDidAppear 时试一次（presentingViewController
// 非空才算 sheet，Feed 里正常 push 的页面不扫）；② 任何 present 完成
// 后，对被呈现的 VC 和自己各试一次。先 %orig 再装，不改原生 frame，
// 不碰 layoutSubviews，不订阅通知。Install 自身幂等，多调无害。
// 2.2-9-88：① 进房间后另有 1 秒轮询 watcher（见 IESLiveAudienceViewController
// 的 viewDidAppear/didEnterRoom 启动、didCloseRoom/dealloc 停止），面板
// 无论何时出现/重建都能装上；② 下面两钩都跳过自家 DYYY 页面触发，诊断
// 不再被榜单页自己覆盖；③ Install 的快路只认可见的已装按钮。
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 2.2-9-88：自家榜单/设置页出现时跳过——-87 的诊断就是被自家榜单页
    // 的 viewDidAppear 触发覆盖掉的（诊断里触发 VC 是 DYYYLiveBoardViewController）。
    if (!DYYYLiveBoardAudienceEntryIsOwnViewController(self) && self.presentingViewController) {
        DYYYLiveBoardAudienceEntryInstall(self);
        // 2.2-9-90：长按菜单入口同款触发——菜单出现时也装一次。
        DYYYLiveBoardLongPressEntryInstall(self);
    }
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    __weak UIViewController *weakSelf = self;
    __weak UIViewController *weakPresented = viewControllerToPresent;
    void (^wrappedCompletion)(void) = ^{
        if (completion) completion();
        UIViewController *strongSelf = weakSelf;
        UIViewController *strongPresented = weakPresented;
        // 2.2-9-88：任一端是我们自家页面（比如设置页弹出榜单页）时都跳过，
        // 观众面板不可能在那次呈现里，装了只会拿榜单页自己的标题覆盖诊断。
        if (strongPresented && !DYYYLiveBoardAudienceEntryIsOwnViewController(strongPresented)) { DYYYLiveBoardAudienceEntryInstall(strongPresented); DYYYLiveBoardLongPressEntryInstall(strongPresented); }
        if (strongSelf && !DYYYLiveBoardAudienceEntryIsOwnViewController(strongSelf)) { DYYYLiveBoardAudienceEntryInstall(strongSelf); DYYYLiveBoardLongPressEntryInstall(strongSelf); }
    };
    %orig(viewControllerToPresent, flag, wrappedCompletion);
}

%end
