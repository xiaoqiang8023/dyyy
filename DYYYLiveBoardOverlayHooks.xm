// DYYYLiveBoardOverlayHooks.xm — 直播间内悬浮人气榜的挂载钩子（2.2-9-72）。
// 钩点与 -7 开播时长胶囊（DYYY.xm）完全一致：AWELiveAudienceContainerController
// 的 init/setAudienceVC/setRoomModel/updateWithRoomModel 等 + AWELiveAudienceViewController，
// 不另找没验证过的类。安装/拆除逻辑在 DYYYLiveBoardOverlay.m 里，这里只转发。
// 安装是幂等的（root 上已有悬浮榜就不再新建），进出直播间多次也不会重复挂。
#import "DYYYLiveBoardOverlay.h"
#import "DYYYLiveBoardAudienceEntry.h"
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
}

- (void)didPreloadRoom:(id)room {
    %orig;
    DYYYLiveBoardOverlayInstallOnView(self.view);
    DYYYLiveBoardAudienceEntryInstall(self);
}

- (void)didCloseRoom:(id)room closeType:(unsigned long long)type {
    DYYYLiveBoardOverlayRemoveFromView(self.view);
    %orig;
}

- (void)dealloc {
    if (self.isViewLoaded) {
        DYYYLiveBoardOverlayRemoveFromView(self.view);
    }
    %orig;
}

%end
