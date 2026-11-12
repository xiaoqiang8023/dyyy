// DYYYProfileEntry.xm — 2.2-9-99：DYKiller 个人主页快捷入口移植（DYKiller 0.7.1，DKProfileSettingsEntry.xm）。
//
// 在自己主页（“我”页）头像下方的功能区（观看历史 / 稍后再看 / … / 全部功能）末尾，
// 注入一张与原生卡片长得一样的假卡片（齿轮图标 + 名称），点它直接打开 DYYY 设置主界面。
//
// 实现（照搬 DYKiller，只换键名与打开目标）：
//   - 功能区数据源 AWEProfileEAVajraDataSource 按服务端顺序生成卡片列表，「全部功能」（cardType 120）追加在末尾，
//     再按列表建卡片控制器与卡片视图；视图持有者 AWEProfileEAVajraViewHolder 拿到列表后按标题算宽度与间距，
//     cell 里的卡片视图按下标向数据源取。
//   - 入口只追加在视图持有者的列表末尾，排布由抖音按五张卡片重算。数据源的列表、卡片控制器与视图都不含入口，
//     抖音的曝光、点击上报与长按编辑不经过它：入口的 cell 用原生复用标识与原生卡片视图（cardViewWithCardModel:）自建，
//     willDisplay 不交给抖音，点击直接打开 DYYY 设置；可见下标、曝光、加载与点击回调都跳过入口的下标。
//   - 功能区最多五张：数据源生成列表时，若加上入口会超过五张，从「全部功能」之前的最后一个入口开始去掉，
//     被去掉的卡片不再生成控制器与视图，其余卡片在两份列表里的下标保持一致。
//   - 图标取个人主页 SVG 图标集里的齿轮（ic_gearsimplify_outlined_20），模板渲染，按标题文字色着色；
//     卡片视图按主题重新取图标时改挂齿轮。
//   - 设置改动：对已见的功能区以当前用户模型调用数据源的 refreshUserModel:，走抖音自己的重建与重排。
//
// 与 DYKiller 的不同：
//   - 键改名：DYKillerProfileSettingsEntry → DYYYProfileSettingsEntry，
//     DYKillerProfileSettingsEntryName → DYYYProfileSettingsEntryName；名称默认值 0 → @"DYYY"。
//   - 点开目标改成 DYYY 自己的 showDYYYSettingsVC（DYYYSettings.xm 已有，左栏 DYYY 按钮同款走法），
//     不再推 DYKiller 的设置页。
//   - DYKiller 还有“移除主页功能区”开关，入口要求它关闭才显示；DYYY 没有这个开关，门控只剩“开关开 + 是自己的主页”。
//   - DYKiller 用 DKSettingsRegister 注册设置项；DYYY 的设置行由主代理加进 DYYYSettings.xm 的“插件工具”组，
//     本文件不注册设置项，%ctor 只做可用性检查。
//   - 40.9.0 校验：DYYYProfileEntryAvailable() 在第一次使用前检查全部类与方法，
//     任一缺失时所有钩子只走 %orig（静默不装，不崩）；DYYY 的星牌 / 伪装同款做法。
//
// 约束（-57/-60 冻屏的教训）：不订阅全局 NSUserDefaultsDidChangeNotification，
// 不改 layout，不在后台跑定时器；刷新只靠设置行改动时调 DYYYProfileEntryRefresh()，
// 以及主页重建时钩子重新判断。
#import "AwemeHeaders.h"
#import "DYYYProfileEntry.h"
#import "DYYYSettingsHelper.h"
#import "DYYYUtils.h"
#import <objc/runtime.h>

static const unsigned long long kDYYYProfileEntryCardType = 990001;   // 不与抖音卡片类型重合，只作诊断标识
static const unsigned long long kDYYYProfileEntryFindMoreCardType = 120;
static const NSUInteger kDYYYProfileEntryMaxCards = 5;
static NSString *const kDYYYProfileEntryReuseIdentifier = @"kAWEProfileExtensionAreaCard";
static NSString *const kDYYYProfileEntryIconName = @"ic_gearsimplify_outlined_20";

static char kDYYYProfileEntryModelKey;
static char kDYYYProfileEntryCardViewKey;
// 弱表（自己主页的功能区视图持有者），只在主线程读写。
static NSHashTable *gDYYYProfileEntryHolders;
static NSString *gDYYYProfileEntryLastTrim;

#pragma mark - 40.9.0 可用性校验

static BOOL DYYYProfileEntryCheckMethod(Class cls, SEL sel) {
    return cls && sel && class_getInstanceMethod(cls, sel) != NULL;
}

BOOL DYYYProfileEntryAvailable(void) {
    static BOOL checked = NO;
    static BOOL available = NO;
    if (checked) return available;
    checked = YES;

    Class dataSourceClass = NSClassFromString(@"AWEProfileEAVajraDataSource");
    Class holderClass = NSClassFromString(@"AWEProfileEAVajraViewHolder");
    Class cardModelClass = NSClassFromString(@"AWEProfileExtensionAreaCardModel");
    Class contextClass = NSClassFromString(@"AWEProfileExtensionAreaContext");
    Class headerContextClass = NSClassFromString(@"AWEProfileHeaderContext");
    Class cellClass = NSClassFromString(@"AWEProfileExtensionAreaCell");
    Class cardViewClass = NSClassFromString(@"AWEProfileExtensionAreaVajraStyleCardView");
    if (!dataSourceClass || !holderClass || !cardModelClass || !contextClass ||
        !headerContextClass || !cellClass || !cardViewClass) {
        available = NO;
        return available;
    }

    available =
        // 数据源：钩 setCardList:，调 context / refreshUserModel:
        DYYYProfileEntryCheckMethod(dataSourceClass, @selector(setCardList:)) &&
        DYYYProfileEntryCheckMethod(dataSourceClass, @selector(context)) &&
        DYYYProfileEntryCheckMethod(dataSourceClass, @selector(refreshUserModel:)) &&
        // 视图持有者：钩 setCardList: 与 8 个 collectionView / 卡片回调，调 cardList / cardViewWithCardModel: / context
        DYYYProfileEntryCheckMethod(holderClass, @selector(setCardList:)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(cardList)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(cardViewWithCardModel:)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(context)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(collectionView:cellForItemAtIndexPath:)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(collectionView:willDisplayCell:forItemAtIndexPath:)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(collectionView:didSelectItemAtIndexPath:)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(indexPathsForVisibleItems)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(cardWillDisplayAtIndexPath:)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(cardDidLoadAtIndexPath:)) &&
        DYYYProfileEntryCheckMethod(holderClass, @selector(cardDidClickAtIndexPath:)) &&
        // 卡片模型：建假模型时写 cardType / title，判断时读 cardType / title
        DYYYProfileEntryCheckMethod(cardModelClass, @selector(setCardType:)) &&
        DYYYProfileEntryCheckMethod(cardModelClass, @selector(setTitle:)) &&
        DYYYProfileEntryCheckMethod(cardModelClass, @selector(cardType)) &&
        DYYYProfileEntryCheckMethod(cardModelClass, @selector(title)) &&
        // 上下文与头部上下文：取 userModel / dataSource，判断是不是自己的主页
        DYYYProfileEntryCheckMethod(contextClass, @selector(userModel)) &&
        DYYYProfileEntryCheckMethod(contextClass, @selector(profileHeaderContext)) &&
        DYYYProfileEntryCheckMethod(contextClass, @selector(dataSource)) &&
        DYYYProfileEntryCheckMethod(headerContextClass, @selector(isCurrentUser)) &&
        // cell 与卡片视图：入口 cell 挂卡片视图，卡片视图取图标 / 标题 / 模型
        DYYYProfileEntryCheckMethod(cellClass, @selector(addCardView:)) &&
        DYYYProfileEntryCheckMethod(cardViewClass, @selector(cardModel)) &&
        DYYYProfileEntryCheckMethod(cardViewClass, @selector(configWithCardModel:)) &&
        DYYYProfileEntryCheckMethod(cardViewClass, @selector(imageView)) &&
        DYYYProfileEntryCheckMethod(cardViewClass, @selector(titleLabel)) &&
        DYYYProfileEntryCheckMethod(cardViewClass, @selector(updateImageViewWithLightUrlArray:darkUrlArray:)) &&
        DYYYProfileEntryCheckMethod(cardViewClass, @selector(updateImageViewWithLightUrlArray:darkUrlArray:completion:));
    return available;
}

void DYYYInstallProfileEntry(void) {
    BOOL ok = DYYYProfileEntryAvailable();
    NSLog(@"[DYYY] 个人主页入口：%@（40.9.0 类/方法校验）", ok ? @"可用" : @"不可用，已静默不装");
}

#pragma mark - 门控与假模型

static BOOL DYYYProfileEntryMine(id owner) {
    AWEProfileExtensionAreaContext *context = [owner respondsToSelector:@selector(context)] ? (AWEProfileExtensionAreaContext *)[owner context] : nil;
    AWEProfileHeaderContext *header = [context respondsToSelector:@selector(profileHeaderContext)] ? [context profileHeaderContext] : nil;
    return [header respondsToSelector:@selector(isCurrentUser)] && [header isCurrentUser];
}

static BOOL DYYYProfileEntryWanted(id owner) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:DYYYProfileSettingsEntry] && DYYYProfileEntryMine(owner);
}

NSString *DYYYProfileEntryTitle(void) {
    return [[NSUserDefaults standardUserDefaults] integerForKey:DYYYProfileSettingsEntryName] == 1 ? @"插件设置" : @"DYYY";
}

static BOOL DYYYProfileEntryIsModel(id card) {
    return card && objc_getAssociatedObject(card, &kDYYYProfileEntryModelKey) != nil;
}

static BOOL DYYYProfileEntryIsFindMore(id card) {
    return [card respondsToSelector:@selector(cardType)] && [(AWEProfileExtensionAreaCardModel *)card cardType] == kDYYYProfileEntryFindMoreCardType;
}

static AWEProfileExtensionAreaCardModel *DYYYProfileEntryMakeModel(void) {
    Class cardModelClass = NSClassFromString(@"AWEProfileExtensionAreaCardModel");
    if (!cardModelClass) return nil;
    AWEProfileExtensionAreaCardModel *model = [[cardModelClass alloc] init];
    if (![model respondsToSelector:@selector(setTitle:)] || ![model respondsToSelector:@selector(setCardType:)]) return nil;
    model.cardType = kDYYYProfileEntryCardType;
    model.title = DYYYProfileEntryTitle();
    objc_setAssociatedObject(model, &kDYYYProfileEntryModelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return model;
}

// 数据源列表给入口留一位：总数（含「全部功能」与入口）不超过五张，多出的从「全部功能」之前的最后一个入口去掉。
static NSArray *DYYYProfileEntryTrimSourceCards(NSArray *cards) {
    NSMutableArray *kept = [cards mutableCopy];
    NSMutableArray<NSString *> *dropped = [NSMutableArray array];
    while (kept.count + 1 > kDYYYProfileEntryMaxCards) {
        NSInteger index = (NSInteger)kept.count - 1;
        while (index >= 0 && DYYYProfileEntryIsFindMore(kept[index])) index--;
        if (index < 0) break;
        id card = kept[index];
        [dropped addObject:[card respondsToSelector:@selector(title)] ? ([(AWEProfileExtensionAreaCardModel *)card title] ?: @"?") : @"?"];
        [kept removeObjectAtIndex:index];
    }
    if (NSThread.isMainThread) {
        gDYYYProfileEntryLastTrim = dropped.count ? [NSString stringWithFormat:@"%lu 张，让位去掉 [%@]", (unsigned long)cards.count,
                                            [dropped componentsJoinedByString:@", "]] : nil;
    }
    return dropped.count ? [kept copy] : cards;
}

static NSArray *DYYYProfileEntryAppend(NSArray *cards) {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:cards.count + 1];
    for (id card in cards) {
        if (!DYYYProfileEntryIsModel(card)) [list addObject:card];
    }
    if (!list.count || list.count >= kDYYYProfileEntryMaxCards) return list.count == cards.count ? cards : [list copy];
    AWEProfileExtensionAreaCardModel *model = DYYYProfileEntryMakeModel();
    if (model) [list addObject:model];
    return [list copy];
}

static BOOL DYYYProfileEntryAtIndexPath(AWEProfileEAVajraViewHolder *holder, NSIndexPath *indexPath) {
    NSArray *cards = [holder respondsToSelector:@selector(cardList)] ? [holder cardList] : nil;
    return indexPath.item >= 0 && indexPath.item < (NSInteger)cards.count && DYYYProfileEntryIsModel(cards[indexPath.item]);
}

#pragma mark - 图标

static UIImage *DYYYProfileEntryGearImage(CGSize size) {
    static UIImage *image;
    static CGSize imageSize;
    if (image && CGSizeEqualToSize(size, imageSize)) return image;
    UIImage *gear = nil;
    if ([UIImage respondsToSelector:@selector(svg_userProfileImageWithName:size:color:)]) {
        gear = [UIImage svg_userProfileImageWithName:kDYYYProfileEntryIconName size:size color:UIColor.blackColor];
    }
    if (!gear) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size.height * 0.8
                                                                                              weight:UIImageSymbolWeightRegular];
        gear = [UIImage systemImageNamed:@"gearshape" withConfiguration:config];
    }
    image = [gear imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    imageSize = size;
    return image;
}

static void DYYYProfileEntryApplyIcon(UIView *cardView) {
    UIImageView *imageView = [cardView respondsToSelector:@selector(imageView)] ? [(AWEProfileExtensionAreaVajraStyleCardView *)cardView imageView] : nil;
    if (![imageView isKindOfClass:UIImageView.class]) return;
    CGSize size = imageView.bounds.size;
    if (size.width < 1.0 || size.height < 1.0) size = CGSizeMake(24.0, 24.0);
    UIImage *gear = DYYYProfileEntryGearImage(size);
    if (gear && imageView.image != gear) imageView.image = gear;
    UILabel *label = [cardView respondsToSelector:@selector(titleLabel)] ? [(AWEProfileExtensionAreaVajraStyleCardView *)cardView titleLabel] : nil;
    if ([label isKindOfClass:UILabel.class] && label.textColor) imageView.tintColor = label.textColor;
}

// 卡片视图按主题刷新时，标题色可能在图标之后才写；下一轮主队列再着一次色。
static void DYYYProfileEntryApplyIconNowAndLater(UIView *cardView) {
    DYYYProfileEntryApplyIcon(cardView);
    __weak UIView *weakView = cardView;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = weakView;
        if (view && [view respondsToSelector:@selector(cardModel)] && DYYYProfileEntryIsModel([(id)view cardModel])) DYYYProfileEntryApplyIcon(view);
    });
}

static UIView *DYYYProfileEntryCardView(AWEProfileEAVajraViewHolder *holder, AWEProfileExtensionAreaCardModel *model) {
    UIView *view = objc_getAssociatedObject(holder, &kDYYYProfileEntryCardViewKey);
    if (![view isKindOfClass:UIView.class]) {
        view = [holder respondsToSelector:@selector(cardViewWithCardModel:)] ? [holder cardViewWithCardModel:model] : nil;
        if (![view isKindOfClass:UIView.class]) return nil;
        objc_setAssociatedObject(holder, &kDYYYProfileEntryCardViewKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if ([view respondsToSelector:@selector(cardModel)] && [(id)view cardModel] != model &&
               [view respondsToSelector:@selector(configWithCardModel:)]) {
        [(AWEProfileExtensionAreaVajraStyleCardView *)view configWithCardModel:model];
    }
    DYYYProfileEntryApplyIconNowAndLater(view);
    return view;
}

static UIViewController *DYYYProfileEntryPresenter(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class] && ((UIViewController *)responder).navigationController) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

// 点入口：打开 DYYY 设置主界面（左栏 DYYY 按钮同款走法：showDYYYSettingsVC）。
// 响应链里找不到带导航栈的控制器时，退到当前最上层控制器再找。
static void DYYYProfileEntryOpenSettings(UIView *view) {
    UIViewController *presenter = DYYYProfileEntryPresenter(view);
    if (!presenter) {
        presenter = [DYYYUtils topView];
        while (presenter.presentedViewController) {
            presenter = presenter.presentedViewController;
        }
    }
    if (!presenter) return;
    BOOL hasAgreed = [DYYYSettingsHelper getUserDefaults:@"DYYYUserAgreementAccepted"];
    showDYYYSettingsVC(presenter, hasAgreed);
}

#pragma mark - 刷新与诊断

void DYYYProfileEntryRefresh(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYProfileEntryRefresh(); });
        return;
    }
    if (!DYYYProfileEntryAvailable()) return;
    for (AWEProfileEAVajraViewHolder *holder in gDYYYProfileEntryHolders.allObjects) {
        if (!DYYYProfileEntryMine(holder)) continue;
        AWEProfileExtensionAreaContext *context = [holder respondsToSelector:@selector(context)] ? [holder context] : nil;
        id dataSource = [context respondsToSelector:@selector(dataSource)] ? [context dataSource] : nil;
        id user = [context respondsToSelector:@selector(userModel)] ? [context userModel] : nil;
        if (user && [dataSource respondsToSelector:@selector(refreshUserModel:)]) [dataSource refreshUserModel:user];
    }
}

NSString *DYYYProfileEntryStatus(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"主页入口=%d 名称=%@ 已见功能区=%lu 最近一次让位：%@\n", [[NSUserDefaults standardUserDefaults] boolForKey:DYYYProfileSettingsEntry],
        DYYYProfileEntryTitle(), (unsigned long)gDYYYProfileEntryHolders.allObjects.count,
        gDYYYProfileEntryLastTrim ?: @"无"];
    for (AWEProfileEAVajraViewHolder *holder in gDYYYProfileEntryHolders.allObjects) {
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (id card in [holder cardList]) {
            NSString *title = [card respondsToSelector:@selector(title)] ? [(AWEProfileExtensionAreaCardModel *)card title] : nil;
            [titles addObject:[NSString stringWithFormat:@"%@%@", title ?: @"?", DYYYProfileEntryIsModel(card) ? @"(入口)" : @""]];
        }
        UIView *view = objc_getAssociatedObject(holder, &kDYYYProfileEntryCardViewKey);
        [out appendFormat:@"  卡片=[%@] 入口视图在窗口=%d frame=%@\n", [titles componentsJoinedByString:@", "], view.window != nil,
            view ? NSStringFromCGRect([view convertRect:view.bounds toView:nil]) : @"-"];
    }
    return out;
}

#pragma mark - Hook

%hook AWEProfileEAVajraDataSource

- (void)setCardList:(NSArray *)cardList {
    if (!DYYYProfileEntryAvailable()) {
        %orig;
        return;
    }
    if ([cardList isKindOfClass:NSArray.class] && cardList.count && DYYYProfileEntryWanted(self)) {
        %orig(DYYYProfileEntryTrimSourceCards(cardList));
        return;
    }
    %orig;
}

%end

%hook AWEProfileEAVajraViewHolder

- (void)setCardList:(NSArray *)cardList {
    if (!DYYYProfileEntryAvailable()) {
        %orig;
        return;
    }
    if (NSThread.isMainThread && DYYYProfileEntryMine(self)) {
        if (!gDYYYProfileEntryHolders) gDYYYProfileEntryHolders = [NSHashTable weakObjectsHashTable];
        [gDYYYProfileEntryHolders addObject:self];
    }
    if ([cardList isKindOfClass:NSArray.class] && DYYYProfileEntryWanted(self)) {
        %orig(DYYYProfileEntryAppend(cardList));
        return;
    }
    %orig;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (!DYYYProfileEntryAvailable() || !DYYYProfileEntryAtIndexPath(self, indexPath)) return %orig;
    UICollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kDYYYProfileEntryReuseIdentifier forIndexPath:indexPath];
    UIView *view = DYYYProfileEntryCardView(self, [self cardList][indexPath.item]);
    if (view && [cell respondsToSelector:@selector(addCardView:)]) [(AWEProfileExtensionAreaCell *)cell addCardView:view];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (DYYYProfileEntryAvailable() && DYYYProfileEntryAtIndexPath(self, indexPath)) return;
    %orig;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (!DYYYProfileEntryAvailable() || !DYYYProfileEntryAtIndexPath(self, indexPath)) {
        %orig;
        return;
    }
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    DYYYProfileEntryOpenSettings(collectionView);
}

// 出现时的曝光补报按可见下标逐个走 cardWillDisplayAtIndexPath:，入口不在其中。
- (NSArray *)indexPathsForVisibleItems {
    NSArray *paths = %orig;
    if (!DYYYProfileEntryAvailable() || ![paths isKindOfClass:NSArray.class] || !paths.count) return paths;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:paths.count];
    for (id path in paths) {
        if (!([path isKindOfClass:NSIndexPath.class] && DYYYProfileEntryAtIndexPath(self, path))) [kept addObject:path];
    }
    return kept.count == paths.count ? paths : [kept copy];
}

- (void)cardWillDisplayAtIndexPath:(NSIndexPath *)indexPath {
    if (DYYYProfileEntryAvailable() && DYYYProfileEntryAtIndexPath(self, indexPath)) return;
    %orig;
}

- (void)cardDidLoadAtIndexPath:(NSIndexPath *)indexPath {
    if (DYYYProfileEntryAvailable() && DYYYProfileEntryAtIndexPath(self, indexPath)) return;
    %orig;
}

- (void)cardDidClickAtIndexPath:(NSIndexPath *)indexPath {
    if (DYYYProfileEntryAvailable() && DYYYProfileEntryAtIndexPath(self, indexPath)) return;
    %orig;
}

%end

%hook AWEProfileExtensionAreaVajraStyleCardView

- (void)updateImageViewWithLightUrlArray:(id)lightUrls darkUrlArray:(id)darkUrls {
    %orig;
    if (DYYYProfileEntryAvailable() && DYYYProfileEntryIsModel([self cardModel])) DYYYProfileEntryApplyIconNowAndLater(self);
}

- (void)updateImageViewWithLightUrlArray:(id)lightUrls darkUrlArray:(id)darkUrls completion:(id)completion {
    %orig;
    if (DYYYProfileEntryAvailable() && DYYYProfileEntryIsModel([self cardModel])) DYYYProfileEntryApplyIconNowAndLater(self);
}

%end

#pragma mark - 安装

%ctor {
    // 只做可用性检查并打一行日志；钩子由 Logos 在加载时自装，缺失时各钩子只走 %orig。
    // 设置项不在这里注册，由主代理加进 DYYYSettings.xm 的“插件工具”组。
    NSLog(@"[DYYY-99] profile entry installed");
    DYYYInstallProfileEntry();
}
