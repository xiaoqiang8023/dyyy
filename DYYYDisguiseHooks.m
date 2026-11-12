// DYYYDisguiseHooks.m — 2.2-9-69：本机伪装别人主页的装钩。
// 装钩点全部是已验证的：
//   1. AWEProfileNavigationBaseComponent 生命周期（星牌按钮同款注入点，
//      方法签名逐个校验，不存在就跳过）：挂“伪装此人 / 取消伪装”按钮、
//      刷新水印。
//   2. 同类的 userModel getter：伪装开着且读到的是我自己的 model 时，
//      返回按缓存造的假 AWEUserModel；别人的主页一律返回原 model。
//   3. AWEAwemeModel -statistics（DY778 显示数字同款 hook 点）：
//      只换我自己作品的播放量数字（按 itemID 对位），封面和视频不动。
//   4. AWEProfileNavigationContainerView hitTest：让两个新按钮能点到，
//      其余一律走原实现（星牌的 hitTest 链在下面，不动它）。
// 不订阅任何通知，不在任何 layout 方法里改抖音视图的帧。
#import "DYYYDisguise.h"
#import "AwemeHeaders.h"
#import "DYYYFansRuntime.h"
#import "DYYYFansModel.h"
#import <objc/runtime.h>

static BOOL DYYYDisguiseMatch(Method method, const char *returns, const char *arguments) {
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.methodReturnType[0] != returns[0] || signature.numberOfArguments != strlen(arguments) + 2) return NO;
    for (NSUInteger i = 0; arguments[i]; i++) {
        if ([signature getArgumentTypeAtIndex:i + 2][0] != arguments[i]) return NO;
    }
    return YES;
}

#pragma mark - 两个按钮

@interface DYYYDisguiseProfileButton : UIButton
@property(nonatomic, weak) id owner;
@end
@implementation DYYYDisguiseProfileButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setImage:[UIImage systemImageNamed:@"person.fill.badge.plus"] forState:UIControlStateNormal];
        [self setTitle:@" 伪装此人" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        self.tintColor = UIColor.whiteColor;
        self.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.28];
        self.layer.cornerRadius = 18;
        self.accessibilityLabel = @"伪装成此用户，仅本机可见";
        [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -4), point);
}
- (void)open {
    NSDictionary *person = DYYYFansPerson(DYYYFansCall(self.owner, @"userModel", @[]));
    if (!person) return;
    DYYYDisguiseStartWithPerson(person);
}
@end

@interface DYYYDisguiseCancelProfileButton : UIButton
@property(nonatomic, weak) id owner;
@end
@implementation DYYYDisguiseCancelProfileButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setImage:[UIImage systemImageNamed:@"xmark.circle"] forState:UIControlStateNormal];
        [self setTitle:@" 取消伪装" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        self.tintColor = UIColor.whiteColor;
        self.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.55];
        self.layer.cornerRadius = 18;
        self.accessibilityLabel = @"取消伪装，恢复成自己的主页";
        [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -4), point);
}
- (void)open {
    DYYYDisguiseCancel();
}
@end

static char DYYYDisguiseButtonKeyStorage;
static const void *DYYYDisguiseButtonKey = &DYYYDisguiseButtonKeyStorage;
static char DYYYDisguiseCancelButtonKeyStorage;
static const void *DYYYDisguiseCancelButtonKey = &DYYYDisguiseCancelButtonKeyStorage;
static char DYYYDisguiseFakeStatsKeyStorage;
static const void *DYYYDisguiseFakeStatsKey = &DYYYDisguiseFakeStatsKeyStorage;
static char DYYYDisguiseFakeStatsPlayKeyStorage;
static const void *DYYYDisguiseFakeStatsPlayKey = &DYYYDisguiseFakeStatsPlayKeyStorage;

#pragma mark - 主页更新

static void DYYYDisguiseUpdateProfile(id owner) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYDisguiseUpdateProfile(owner); });
        return;
    }
    DYYYDisguiseNoteProfileOwner(owner);
    UIView *container = DYYYFansRead(owner, @"navigationContainerView");
    DYYYDisguiseProfileButton *disguiseButton = objc_getAssociatedObject(container, DYYYDisguiseButtonKey);
    DYYYDisguiseCancelProfileButton *cancelButton = objc_getAssociatedObject(container, DYYYDisguiseCancelButtonKey);
    // -70：isMine 必须按原始 model 判断，不能走被换过的 userModel getter。
    // -69 的假 model 没设 uid，DYYYFansPerson(假 model) 直接返回 nil，
    // isMine 恒为 NO，“我”页的“取消伪装”按钮永远出不来。先读 _userModel
    // 这个 ivar（绕开 getter 拿原始 model），读不到再走 getter。
    id originalModel = nil;
    @try { originalModel = [owner valueForKey:@"_userModel"]; } @catch (__unused NSException *e) {}
    if (!originalModel) originalModel = DYYYFansCall(owner, @"userModel", @[]);
    NSDictionary *person = DYYYFansPerson(originalModel);
    NSString *myUID = DYYYDisguiseMyUID();
    BOOL isMine = person && myUID.length && [DYYYFansString(person[@"uid"]) isEqual:myUID];
    BOOL active = DYYYDisguiseIsActive();
    if (![container isKindOfClass:UIView.class] || !person || container.bounds.size.width < 120) {
        disguiseButton.hidden = YES;
        cancelButton.hidden = YES;
        DYYYDisguiseUpdateWatermarkForOwner(owner);
        return;
    }
    // 按钮位：复用星牌同款算法，先算左右已有视图夹出来的空隙，
    // 我的按钮放空隙最右端；放不下（会盖住星牌）就隐藏，宁可不显示也不挡。
    CGFloat left = 12, right = container.bounds.size.width - 12, centerY = container.bounds.size.height / 2;
    id leftViews = DYYYFansCall(owner, @"currentLeftShowViews", @[]);
    id rightViews = DYYYFansCall(owner, @"currentRightShowViews", @[]);
    if ([leftViews isKindOfClass:NSArray.class] && [rightViews isKindOfClass:NSArray.class]) {
        for (id views in @[leftViews, rightViews]) {
            for (UIView *view in views) {
                if (![view isKindOfClass:UIView.class] || view.hidden || view.alpha < 0.05 || ![view isDescendantOfView:container]) continue;
                CGRect frame = [view convertRect:view.bounds toView:container];
                if (views == leftViews) { left = MAX(left, CGRectGetMaxX(frame) + 8); centerY = CGRectGetMidY(frame); }
                else right = MIN(right, CGRectGetMinX(frame) - 8);
            }
        }
    }
    BOOL wantDisguise = !isMine;
    BOOL wantCancel = isMine && active;
    // 先取或创建目标按钮（第一次是 nil，必须在这里创建，不能等它非空）
    UIButton *targetButton = nil;
    if (wantDisguise) {
        if (!disguiseButton) {
            disguiseButton = [DYYYDisguiseProfileButton new];
            [container addSubview:disguiseButton];
            objc_setAssociatedObject(container, DYYYDisguiseButtonKey, disguiseButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        disguiseButton.owner = owner;
        targetButton = disguiseButton;
    } else if (wantCancel) {
        if (!cancelButton) {
            cancelButton = [DYYYDisguiseCancelProfileButton new];
            [container addSubview:cancelButton];
            objc_setAssociatedObject(container, DYYYDisguiseCancelButtonKey, cancelButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        cancelButton.owner = owner;
        targetButton = cancelButton;
    }
    disguiseButton.hidden = YES;
    cancelButton.hidden = YES;
    if (targetButton) {
        // 星牌按钮如果可见，我的按钮必须排在它右边 8pt 之后，否则隐藏
        CGFloat minX = right - 96;
        BOOL blocked = NO;
        for (UIView *view in container.subviews) {
            if (![view isKindOfClass:UIButton.class] || view == targetButton || view.hidden || view.alpha < 0.05) continue;
            NSString *title = [(UIButton *)view titleForState:UIControlStateNormal] ?: @"";
            if ([title containsString:@"星牌"]) {
                if (minX < CGRectGetMaxX(view.frame) + 8) blocked = YES;
            }
        }
        BOOL fits = (right - left) >= 96 && container.bounds.size.height >= 36 && !blocked;
        targetButton.hidden = !fits;
        if (fits) {
            targetButton.frame = CGRectMake(minX, MAX(0, MIN(container.bounds.size.height - 36, centerY - 18)), 96, 36);
            [container bringSubviewToFront:targetButton];
        }
    }
    DYYYDisguiseUpdateWatermarkForOwner(owner);
}

#pragma mark - 装钩

static void DYYYDisguiseInstallProfile(void) {
    static BOOL installed[4];
    NSArray *selectors = @[@"viewDidLayoutSubviews", @"viewDidAppear", @"reloadData", @"viewDidDisappear"];
    Class cls = NSClassFromString(@"AWEProfileNavigationBaseComponent");
    if (!cls) return;
    for (NSUInteger i = 0; i < selectors.count; i++) {
        if (installed[i]) continue;
        SEL sel = NSSelectorFromString(selectors[i]);
        Method method = class_getInstanceMethod(cls, sel);
        if (!DYYYDisguiseMatch(method, "v", "")) continue;
        IMP original = method_getImplementation(method);
        BOOL hiding = i == 3;
        IMP replacement = imp_implementationWithBlock(^(id owner) {
            ((void (*)(id, SEL))original)(owner, sel);
            if (hiding) {
                UIView *view = DYYYFansRead(owner, @"navigationContainerView");
                UIView *a = objc_getAssociatedObject(view, DYYYDisguiseButtonKey);
                UIView *b = objc_getAssociatedObject(view, DYYYDisguiseCancelButtonKey);
                a.hidden = YES; b.hidden = YES;
            } else {
                DYYYDisguiseUpdateProfile(owner);
            }
        });
        class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
        installed[i] = YES;
    }
    // userModel getter：只在“我自己的页 + 伪装开着”时返回假 model
    static BOOL userModelInstalled;
    if (!userModelInstalled) {
        SEL sel = @selector(userModel);
        Method method = class_getInstanceMethod(cls, sel);
        if (DYYYDisguiseMatch(method, "@", "")) {
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^id(id owner) {
                id originalModel = ((id (*)(id, SEL))original)(owner, sel);
                if (!DYYYDisguiseIsActive() || !originalModel) return originalModel;
                NSDictionary *person = DYYYFansPerson(originalModel);
                if (!person || ![DYYYFansString(person[@"uid"]) isEqual:DYYYDisguiseMyUID()]) return originalModel;
                id synthetic = DYYYDisguiseSyntheticUserModelForOriginal(originalModel);
                return synthetic ?: originalModel;
            });
            class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
            userModelInstalled = YES;
        }
    }
}

static void DYYYDisguiseInstallStatistics(void) {
    static BOOL installed;
    if (installed) return;
    Class cls = NSClassFromString(@"AWEAwemeModel");
    if (!cls) return;
    SEL sel = @selector(statistics);
    Method method = class_getInstanceMethod(cls, sel);
    if (!DYYYDisguiseMatch(method, "@", "")) return;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^id(id self) {
        id origStats = ((id (*)(id, SEL))original)(self, sel);
        if (!DYYYDisguiseIsActive()) return origStats;
        NSString *itemID = nil;
        @try {
            id value = [self valueForKey:@"itemID"];
            if ([value isKindOfClass:NSString.class]) itemID = value;
            else if ([value respondsToSelector:@selector(stringValue)]) itemID = [value stringValue];
        } @catch (__unused NSException *e) {}
        NSNumber *play = itemID ? DYYYDisguisePlayCountForMyAwemeID(itemID) : nil;
        if (!play) return origStats;
        // 假 statistics 按 model 缓存；目标换了（播放量变了）就重建
        id fake = objc_getAssociatedObject(self, DYYYDisguiseFakeStatsKey);
        NSNumber *cachedPlay = objc_getAssociatedObject(self, DYYYDisguiseFakeStatsPlayKey);
        if (!fake || ![cachedPlay isEqual:play]) {
            fake = DYYYDisguiseFakeStatistics(origStats, play);
            if (!fake) return origStats;
            objc_setAssociatedObject(self, DYYYDisguiseFakeStatsKey, fake, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, DYYYDisguiseFakeStatsPlayKey, play, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return fake;
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    installed = YES;
}

static void DYYYDisguiseInstallHitTest(void) {
    static BOOL installed;
    if (installed) return;
    Class container = NSClassFromString(@"AWEProfileNavigationContainerView");
    if (!container) return;
    SEL sel = @selector(hitTest:withEvent:);
    Method method = class_getInstanceMethod(container, sel);
    if (!method) return;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != 4 || signature.methodReturnType[0] != '@' ||
        strcmp([signature getArgumentTypeAtIndex:2], @encode(CGPoint)) != 0 ||
        [signature getArgumentTypeAtIndex:3][0] != '@') return;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^UIView *(UIView *owner, CGPoint point, UIEvent *event) {
        if (owner.userInteractionEnabled && !owner.hidden && owner.alpha > 0.05) {
            const void *keys[] = {DYYYDisguiseButtonKey, DYYYDisguiseCancelButtonKey};
            for (int k = 0; k < 2; k++) {
                UIButton *button = objc_getAssociatedObject(owner, keys[k]);
                if (button && !button.hidden && button.alpha > 0.05) {
                    CGPoint local = [button convertPoint:point fromView:owner];
                    if ([button pointInside:local withEvent:event]) return button;
                }
            }
        }
        return ((UIView *(*)(id, SEL, CGPoint, id))original)(owner, sel, point, event);
    });
    class_replaceMethod(container, sel, replacement, method_getTypeEncoding(method));
    installed = YES;
}

#pragma mark - 主页计数区、基础头部与作品格（2.2-9-70）
// -69 的根因（已定罪）：主页头部根本不走 AWEProfileNavigationBaseComponent
// 的 userModel getter——获赞/关注/粉丝数由
// AWEProfileHeaderSocialStatisticSectionControllerV2（新版）和
// AWEProfileSocialStatisticView（旧版）各自从自己的 context 读数渲染，
// 头像/昵称/简介由 AWEProfileBaseHeaderSectionController 配 cell，
// 作品格左下角由 AWEUserWorkCellContext 配内容。-69 只钩了导航组件的
// getter，所以提示成功了，“我”页却纹丝不动。
// 以下钩点全部照抄 DY778 1.0-3 主页数字自定义（DY778DisplayStats.m）的
// 同款类名/方法名/签名判定，只在“当前登录账号自己的主页”才替换，
// 方法不存在或签名对不上就跳过，不编假实现。
static NSHashTable *sDisguiseSections;
static NSHashTable *sDisguiseLegacyViews;
static NSHashTable *sDisguiseBaseHeaders;
static NSHashTable *sDisguiseWorkContexts;
static NSHashTable *sDisguiseWorkCells; // -105：41.1.0 作品格 cell（弱引用）
static NSHashTable *sDisguiseNameAreaCells; // -106：名字区 cell（弱引用）
static NSHashTable *sDisguiseSignatureCells; // -106：简介区 cell（弱引用）
static NSHashTable *sDisguiseHeaderSections; // -106：已包 configCell 的头部 section controller（弱引用）
static NSMutableSet *sDisguiseWrappedSectionClasses; // -106：已装过 configCell 包装的 section 类

// 返回接回的表（ARC 不允许把全局变量地址传给 __autoreleasing 出参，
// -66 修 RecallMediaView 时同款报错，改法一样：返回值再赋回去）。
static NSHashTable *DYYYDisguiseTrackDisplay(id obj, NSHashTable *slot) {
    if (!obj || !NSThread.isMainThread) return slot;
    if (!slot) slot = [NSHashTable weakObjectsHashTable];
    [slot addObject:obj];
    return slot;
}

// 组件 context 的归属判定（DY778 同款）：isCurrentUser 且 userID 是我
static NSString *DYYYDisguiseContextOwner(id context) {
    if (![DYYYFansRead(context, @"isCurrentUser") boolValue]) return nil;
    NSString *owner = DYYYFansString(DYYYFansRead(DYYYFansRead(context, @"userModel"), @"userID"));
    if (!owner.length) owner = DYYYFansString(DYYYFansRead(context, @"userId"));
    return owner;
}

static BOOL DYYYDisguiseIsOwnContext(id context) {
    NSString *owner = DYYYDisguiseContextOwner(context);
    NSString *myUID = DYYYDisguiseMyUID();
    return owner.length && myUID.length && [owner isEqual:myUID];
}

// 计数组件类名 -> 字段（DY778 同款；互关数没有缓存，不替换）
static NSString *DYYYDisguiseProfileField(id component, id item) {
    NSString *name = NSStringFromClass([component class]);
    if ([name isEqualToString:@"AWEProfileSocialStatisticPraiseComponent"]) return @"praise";
    if ([name isEqualToString:@"AWEProfileSocialStatisticFansComponent"]) return @"fans";
    if ([name isEqualToString:@"AWEProfileSocialStatisticFollowComponent"]) return @"follow";
    if ([name isEqualToString:@"AWEProfileSocialStatisticMutualComponent"]) return @"mutual";
    if ([name isEqualToString:@"AWEProfileSocialStatisticFriendComponent"]) {
        for (NSString *key in @[@"title", @"name", @"text"])
            if ([DYYYFansRead(item, key) isEqual:@"互关"]) return @"mutual";
    }
    return nil;
}

static id DYYYDisguiseSectionComponent(id section, id item) {
    id identifier = DYYYFansRead(item, @"modelID");
    id components = DYYYFansRead(section, @"components");
    return ([identifier isKindOfClass:NSNumber.class] && [components isKindOfClass:NSDictionary.class]) ? components[identifier] : nil;
}

static id (*DYYYDisguiseOrigProfileCount)(id, SEL, id);
static void (*DYYYDisguiseOrigProfileApply)(id, SEL, id, long long, id, id);
static void (*DYYYDisguiseOrigProfileConfig)(id, SEL, id, long long, id);

static void DYYYDisguiseInstallProfileCounts(void) {
    Class cls = NSClassFromString(@"AWEProfileHeaderSocialStatisticSectionControllerV2");
    if (!cls) return;
    static BOOL countInstalled, applyInstalled, configInstalled;
    if (!countInstalled) {
        SEL sel = NSSelectorFromString(@"p_displayCountForItem:");
        Method method = class_getInstanceMethod(cls, sel);
        if (DYYYDisguiseMatch(method, "@", "@")) {
            DYYYDisguiseOrigProfileCount = (id (*)(id, SEL, id))method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^id(id self, id item) {
                id raw = DYYYDisguiseOrigProfileCount(self, sel, item);
                sDisguiseSections = DYYYDisguiseTrackDisplay(self, sDisguiseSections);
                if (!DYYYDisguiseIsActive()) return raw;
                id component = DYYYDisguiseSectionComponent(self, item);
                NSString *field = DYYYDisguiseProfileField(component, item);
                NSNumber *number = nil;
                if (field && DYYYDisguiseIsOwnContext(DYYYFansRead(component, @"context")))
                    number = DYYYDisguiseTargetCountForField(field);
                return number ?: raw;
            });
            class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
            countInstalled = YES;
        }
    }
    if (!applyInstalled) {
        SEL sel = NSSelectorFromString(@"p_applyDisplayText:itemId:cell:component:");
        Method method = class_getInstanceMethod(cls, sel);
        if (DYYYDisguiseMatch(method, "v", "@q@@")) {
            DYYYDisguiseOrigProfileApply = (void (*)(id, SEL, id, long long, id, id))method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^(id self, id text, long long itemID, id cell, id component) {
                sDisguiseSections = DYYYDisguiseTrackDisplay(self, sDisguiseSections);
                NSString *showText = text;
                if (DYYYDisguiseIsActive()) {
                    id item = nil;
                    SEL itemSel = NSSelectorFromString(@"p_itemForItemId:");
                    Method itemMethod = class_getInstanceMethod([self class], itemSel);
                    if (DYYYDisguiseMatch(itemMethod, "@", "q"))
                        item = ((id (*)(id, SEL, long long))objc_msgSend)(self, itemSel, itemID);
                    NSString *field = DYYYDisguiseProfileField(component, item);
                    NSNumber *number = nil;
                    if (field && DYYYDisguiseIsOwnContext(DYYYFansRead(component, @"context")))
                        number = DYYYDisguiseTargetCountForField(field);
                    if (number) showText = number.stringValue;
                }
                DYYYDisguiseOrigProfileApply(self, sel, showText, itemID, cell, component);
            });
            class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
            applyInstalled = YES;
        }
    }
    if (!configInstalled) {
        SEL sel = NSSelectorFromString(@"configCell:index:model:");
        Method method = class_getInstanceMethod(cls, sel);
        if (DYYYDisguiseMatch(method, "v", "@q@")) {
            DYYYDisguiseOrigProfileConfig = (void (*)(id, SEL, id, long long, id))method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^(id self, id cell, long long index, id model) {
                DYYYDisguiseOrigProfileConfig(self, sel, cell, index, model);
                sDisguiseSections = DYYYDisguiseTrackDisplay(self, sDisguiseSections);
            });
            class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
            configInstalled = YES;
        }
    }
}

// 旧版计数（BOOL 参数在有些版本编成 'c'，这里两个都认，DY778 同款宽容判定）
static BOOL DYYYDisguiseMatchBoolArg(Method method, const char *returns, const char *arguments) {
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.methodReturnType[0] != returns[0] || signature.numberOfArguments != strlen(arguments) + 2) return NO;
    for (NSUInteger i = 0; arguments[i]; i++) {
        char actual = [signature getArgumentTypeAtIndex:i + 2][0];
        if (actual != arguments[i] && !(arguments[i] == 'B' && actual == 'c')) return NO;
    }
    return YES;
}

typedef struct {
    const char *selector;
    const char *field;
    const char *property;
    IMP original;
} DYYYDisguiseLegacyHook;

static DYYYDisguiseLegacyHook DYYYDisguiseLegacyHooks[] = {
    {"updatePraiseLabel:isLoaded:", "praise", "praiseCount", NULL},
    {"updateFollowLabel:isLoaded:", "follow", "followingCount", NULL},
    {"updateFansLabel:isLoaded:", "fans", "fansCount", NULL},
    {"updateFriendsLabel:isLoaded:", "mutual", "friendCount", NULL},
};

static void DYYYDisguiseLegacyLabel(id self, SEL selector, id count, BOOL loaded) {
    for (NSUInteger i = 0; i < sizeof(DYYYDisguiseLegacyHooks) / sizeof(DYYYDisguiseLegacyHooks[0]); i++) {
        DYYYDisguiseLegacyHook *hook = &DYYYDisguiseLegacyHooks[i];
        if (!hook->original || selector != sel_registerName(hook->selector)) continue;
        sDisguiseLegacyViews = DYYYDisguiseTrackDisplay(self, sDisguiseLegacyViews);
        NSString *field = @(hook->field);
        if ([field isEqualToString:@"mutual"] && ![DYYYFansRead(DYYYFansRead(self, @"config"), @"friendPrefixTitle") isEqual:@"互关"]) field = nil;
        NSNumber *number = nil;
        if (field) {
            id config = DYYYFansRead(self, @"config");
            NSString *owner = nil;
            if ([DYYYFansRead(config, @"isCurrentUser") boolValue]) {
                owner = DYYYDisguiseContextOwner(DYYYFansRead(config, @"context"));
                if (!owner.length) owner = DYYYFansString(DYYYFansRead(DYYYFansRead(config, @"currentUser"), @"userID"));
            }
            NSString *myUID = DYYYDisguiseMyUID();
            if (owner.length && myUID.length && [owner isEqual:myUID]) number = DYYYDisguiseTargetCountForField(field);
        }
        @try { ((void (*)(id, SEL, id, BOOL))hook->original)(self, selector, number ?: count, number ? YES : loaded); }
        @finally { if (number) DYYYFansSet(self, @(hook->property), count); }
        return;
    }
}

static void DYYYDisguiseInstallLegacyCounts(void) {
    Class cls = NSClassFromString(@"AWEProfileSocialStatisticView");
    if (!cls) return;
    for (NSUInteger i = 0; i < sizeof(DYYYDisguiseLegacyHooks) / sizeof(DYYYDisguiseLegacyHooks[0]); i++) {
        DYYYDisguiseLegacyHook *hook = &DYYYDisguiseLegacyHooks[i];
        if (hook->original) continue;
        SEL sel = sel_registerName(hook->selector);
        Method method = class_getInstanceMethod(cls, sel);
        if (!DYYYDisguiseMatchBoolArg(method, "v", "@B")) continue;
        hook->original = method_getImplementation(method);
        class_replaceMethod(cls, sel, (IMP)DYYYDisguiseLegacyLabel, method_getTypeEncoding(method));
    }
}

static void (*DYYYDisguiseOrigBaseHeaderConfig)(id, SEL, id, long long, id);

static void DYYYDisguiseInstallBaseHeader(void) {
    Class cls = NSClassFromString(@"AWEProfileBaseHeaderSectionController");
    if (!cls) return;
    static BOOL installed;
    if (installed) return;
    SEL sel = NSSelectorFromString(@"configCell:index:model:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!DYYYDisguiseMatch(method, "v", "@q@")) return;
    DYYYDisguiseOrigBaseHeaderConfig = (void (*)(id, SEL, id, long long, id))method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id self, id cell, long long index, id model) {
        sDisguiseBaseHeaders = DYYYDisguiseTrackDisplay(self, sDisguiseBaseHeaders);
        id showModel = model;
        // 只在 model 本来就是我自己的 AWEUserModel 时才换成假 model：
        // 类型守卫保证不会把别的类型误换，没伪装或不是我自己的页时原样通过。
        // 假 model 的头像/昵称/抖音号/简介/计数来自缓存目标，uid 仍是我自己的。
        if (DYYYDisguiseIsActive() && [model isKindOfClass:NSClassFromString(@"AWEUserModel")]) {
            NSString *uid = DYYYFansString(DYYYFansRead(model, @"uid"));
            if (!uid.length) uid = DYYYFansString(DYYYFansRead(model, @"userID"));
            if (uid.length && [uid isEqual:DYYYDisguiseMyUID()]) {
                id synthetic = DYYYDisguiseSyntheticUserModelForOriginal(model);
                if (synthetic) showModel = synthetic;
            }
        }
        DYYYDisguiseOrigBaseHeaderConfig(self, sel, cell, index, showModel);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    installed = YES;
}

static void (*DYYYDisguiseOrigWorkContent)(id, SEL, id);

static void DYYYDisguiseInstallWorkContexts(void) {
    Class cls = NSClassFromString(@"AWEUserWorkCellContext");
    if (!cls) return;
    static BOOL installed;
    if (installed) return;
    SEL sel = NSSelectorFromString(@"__updateAccessibilityLabelAndLeftBottomContent:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!DYYYDisguiseMatch(method, "v", "@")) return;
    DYYYDisguiseOrigWorkContent = (void (*)(id, SEL, id))method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id self, id model) {
        sDisguiseWorkContexts = DYYYDisguiseTrackDisplay(self, sDisguiseWorkContexts);
        DYYYDisguiseOrigWorkContent(self, sel, model);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    installed = YES;
}

#pragma mark - 41.1.0 头部：名字区 / 简介区 / section 动态发现（2.2-9-106）
// 根因（debug-1794460435/ANALYSIS.md）：-105 在头部 VC 的
// configWithContext:user:useCache: 里把整个 context.userModel 换成
// 裸假 model（缺 secUID 与 shortID/displayID 字段），结果：
// ① 计数区 cell 建 items 时看到裸假 model，items 建不出来（subview 0 个）；
// ② 名字区“抖音号：”值标签建不出来；③ 页面在“是不是我自己”上混乱，
// “编辑资料”与“添加朋友”并排出现。-106 拆掉整页换，改成只在配 cell
// 的那一刻临时换：名字区 cell config、简介区 cell config、各头部
// section 的 configCell:index:model:（动态发现类名，见下），调完原
// 方法立刻把真 model 写回；计数区（SocialStatistic）绝不包——它的
// items 必须用真 model 建出来，再由 -70 的钩子改数字。
// 头像 cell（AWEProfileAvatarCollectionViewCellV2）自己没有任何
// config 方法、也没有 context 属性，只能走它所属 section 的
// configCell；section 类名在调试包里没有（只导出 view），所以用
// MyProfile VC 的 dataSourceDidCreateSectionController: 现抓。
static void (*DYYYDisguiseOrigWorkCellConfig)(id, SEL, id);
static void (*DYYYDisguiseOrigNameAreaConfig)(id, SEL, id, id, double);
static void (*DYYYDisguiseOrigSignatureConfig)(id, SEL, id);
static char DYYYDisguiseSectionOrigKeyStorage;
static const void *DYYYDisguiseSectionOrigKey = &DYYYDisguiseSectionOrigKeyStorage;
// -107：上一次传给某 section 的 configCell 的 model（刷新 5a 重调用；
// 没记过的 section 不重调，避免把 userModel 硬塞给要 view model 的 section）。
static char DYYYDisguiseSectionLastModelKeyStorage;
static const void *DYYYDisguiseSectionLastModelKey = &DYYYDisguiseSectionLastModelKeyStorage;
// -107：已装过的 section configCell 包装 IMP 集合。子类继承父类包装时，
// class_getInstanceMethod(子类) 拿到的是父类的包装 IMP——命中集合就跳过，
// 不再给子类包一层（否则包装里取到的“原实现”就是包装自己，无限递归）。
static NSMutableSet *sDisguiseSectionWrapperIMPs;

// 临时换 context.userModel：只在调原方法期间换成假 model，调完写回
// 调用前的值（不是“真 model”）——外层钩子与内层钩子嵌套时也安全。
static void DYYYDisguiseSwapContextUserModel(id context, id synthetic, void (^body)(void)) {
    if (!context || !synthetic) { if (body) body(); return; }
    id previous = DYYYFansRead(context, @"userModel");
    if (!previous || previous == synthetic) { if (body) body(); return; }
    DYYYFansSet(context, @"userModel", synthetic);
    @try { if (body) body(); } @finally { DYYYFansSet(context, @"userModel", previous); }
}

static void DYYYDisguiseInstallNameAreaCell(void) {
    Class cls = NSClassFromString(@"AWEProfileHeaderNameAreaSectionCell_New");
    if (!cls) return;
    static BOOL installed;
    if (installed) return;
    SEL sel = NSSelectorFromString(@"configWithContext:componentTree:contentRenderWidth:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!DYYYDisguiseMatch(method, "v", "@@d")) return;
    DYYYDisguiseOrigNameAreaConfig = (void (*)(id, SEL, id, id, double))method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id self, id context, id tree, double width) {
        sDisguiseNameAreaCells = DYYYDisguiseTrackDisplay(self, sDisguiseNameAreaCells);
        if (DYYYDisguiseIsActive() && DYYYDisguiseIsOwnContext(context)) {
            id synthetic = DYYYDisguiseSyntheticUserModelForOriginal(DYYYFansRead(context, @"userModel"));
            if (synthetic) {
                DYYYDisguiseSwapContextUserModel(context, synthetic, ^{
                    DYYYDisguiseOrigNameAreaConfig(self, sel, context, tree, width);
                });
                return;
            }
        }
        DYYYDisguiseOrigNameAreaConfig(self, sel, context, tree, width);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    installed = YES;
    NSLog(@"[DYYY-106] NameArea cell hook installed");
}

static void DYYYDisguiseInstallSignatureCell(void) {
    Class cls = NSClassFromString(@"AWEProfileHeaderSignatureCollectionViewCell");
    if (!cls) return;
    static BOOL installed;
    if (installed) return;
    SEL sel = NSSelectorFromString(@"configWithHeaderContext:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!DYYYDisguiseMatch(method, "v", "@")) return;
    DYYYDisguiseOrigSignatureConfig = (void (*)(id, SEL, id))method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id self, id context) {
        sDisguiseSignatureCells = DYYYDisguiseTrackDisplay(self, sDisguiseSignatureCells);
        if (DYYYDisguiseIsActive() && DYYYDisguiseIsOwnContext(context)) {
            id synthetic = DYYYDisguiseSyntheticUserModelForOriginal(DYYYFansRead(context, @"userModel"));
            if (synthetic) {
                DYYYDisguiseSwapContextUserModel(context, synthetic, ^{
                    DYYYDisguiseOrigSignatureConfig(self, sel, context);
                });
                return;
            }
        }
        DYYYDisguiseOrigSignatureConfig(self, sel, context);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    installed = YES;
    NSLog(@"[DYYY-106] Signature cell hook installed");
}

static void DYYYDisguiseInstallHeaderSectionDiscovery(void) {
    Class cls = NSClassFromString(@"AWEProfileHeaderMyProfileViewController");
    if (!cls) return;
    static BOOL installed;
    if (installed) return;
    SEL sel = NSSelectorFromString(@"dataSourceDidCreateSectionController:forSectionViewModel:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!DYYYDisguiseMatch(method, "v", "@@")) return;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id self, id section, id viewModel) {
        ((void (*)(id, SEL, id, id))original)(self, sel, section, viewModel);
        // 动态发现：section controller 建好、配 cell 之前，立刻给它的
        // configCell:index:model: 包一层临时换。计数区绝不包（见上）。
        NSString *className = NSStringFromClass([section class]);
        if ([className containsString:@"SocialStatistic"]) return;
        if ([section respondsToSelector:@selector(p_displayCountForItem:)]) return;
        if (!DYYYFansRead(section, @"context")) return;
        Class sectionClass = [section class];
        if (!sDisguiseWrappedSectionClasses) sDisguiseWrappedSectionClasses = [NSMutableSet set];
        if ([sDisguiseWrappedSectionClasses containsObject:sectionClass]) return;
        SEL configSel = NSSelectorFromString(@"configCell:index:model:");
        Method configMethod = class_getInstanceMethod(sectionClass, configSel);
        if (!DYYYDisguiseMatch(configMethod, "v", "@q@")) return;
        // 原实现按类分别记（多个 section 类共用一个全局会被后装的覆盖）。
        // -107：拿到的 IMP 若已是我们自己的包装（子类继承了父类已包的
        // configCell），直接跳过——再包一层会让包装调到包装自己，无限递归。
        void (*origConfig)(id, SEL, id, long long, id) = (void (*)(id, SEL, id, long long, id))method_getImplementation(configMethod);
        if (!sDisguiseSectionWrapperIMPs) sDisguiseSectionWrapperIMPs = [NSMutableSet set];
        if ([sDisguiseSectionWrapperIMPs containsObject:[NSValue valueWithPointer:origConfig]]) return;
        objc_setAssociatedObject(sectionClass, DYYYDisguiseSectionOrigKey, [NSValue valueWithPointer:origConfig], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // -107：包装自己的 IMP（防御守卫用：取到的原实现若等于它，绝不调用）。
        __block IMP configReplacementIMP = NULL;
        IMP configReplacement = imp_implementationWithBlock(^(id controller, id cell, long long index, id model) {
            sDisguiseHeaderSections = DYYYDisguiseTrackDisplay(controller, sDisguiseHeaderSections);
            // -107：记下这次传进来的 model，供刷新 5a 重调时原样传回。
            if (model) objc_setAssociatedObject(controller, DYYYDisguiseSectionLastModelKey, model, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id context = DYYYFansRead(controller, @"context");
            id showModel = model;
            id synthetic = nil;
            if (DYYYDisguiseIsActive() && DYYYDisguiseIsOwnContext(context)) {
                synthetic = DYYYDisguiseSyntheticUserModelForOriginal(DYYYFansRead(context, @"userModel"));
                // model 参数若本来就是我自己的 user model，也换成假的；
                // 若是别的 view model 则原样通过，只换 context.userModel。
                if (synthetic && [model isKindOfClass:NSClassFromString(@"AWEUserModel")]) {
                    NSString *uid = DYYYFansString(DYYYFansRead(model, @"uid"));
                    if (!uid.length) uid = DYYYFansString(DYYYFansRead(model, @"userID"));
                    if (uid.length && [uid isEqual:DYYYDisguiseMyUID()]) showModel = synthetic;
                }
            }
            // -107：原实现按安装时捕获的 sectionClass 取，绝不按
            // [controller class] 现取——子类的实例调父类包装时，
            // [controller class] 是子类，取到的会是包装自己的 IMP。
            NSValue *origValue = objc_getAssociatedObject(sectionClass, DYYYDisguiseSectionOrigKey);
            void (*orig)(id, SEL, id, long long, id) = origValue ? [origValue pointerValue] : NULL;
            // -107：原实现为空或等于包装自己时直接返回，绝不调用（防递归）。
            if (!orig || orig == (void (*)(id, SEL, id, long long, id))configReplacementIMP) return;
            if (synthetic) {
                DYYYDisguiseSwapContextUserModel(context, synthetic, ^{
                    orig(controller, configSel, cell, index, showModel);
                });
            } else {
                orig(controller, configSel, cell, index, showModel);
            }
        });
        configReplacementIMP = configReplacement;
        class_replaceMethod(sectionClass, configSel, configReplacement, method_getTypeEncoding(configMethod));
        [sDisguiseSectionWrapperIMPs addObject:[NSValue valueWithPointer:configReplacement]];
        [sDisguiseWrappedSectionClasses addObject:sectionClass];
        NSLog(@"[DYYY-107] Wrapped header section configCell: %@", className);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    installed = YES;
    NSLog(@"[DYYY-106] Header section discovery installed");
}

static void DYYYDisguiseInstallWorkCells(void) {
    Class cls = NSClassFromString(@"AWEUserWorkCollectionViewComponentCell");
    if (!cls) return;
    static BOOL installed;
    if (installed) return;
    SEL sel = NSSelectorFromString(@"configWithViewModel:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!DYYYDisguiseMatch(method, "v", "@")) return;
    DYYYDisguiseOrigWorkCellConfig = (void (*)(id, SEL, id))method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id self, id viewModel) {
        sDisguiseWorkCells = DYYYDisguiseTrackDisplay(self, sDisguiseWorkCells);
        DYYYDisguiseOrigWorkCellConfig(self, sel, viewModel);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    installed = YES;
}

static void DYYYDisguiseInstallHeaderHooks(void) {
    DYYYDisguiseInstallProfileCounts();
    DYYYDisguiseInstallLegacyCounts();
    DYYYDisguiseInstallBaseHeader();
    DYYYDisguiseInstallWorkContexts();
    DYYYDisguiseInstallNameAreaCell();
    DYYYDisguiseInstallSignatureCell();
    DYYYDisguiseInstallHeaderSectionDiscovery();
    DYYYDisguiseInstallWorkCells();
}

void DYYYDisguiseRefreshDisplays(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ DYYYDisguiseRefreshDisplays(); }); return; }
    // 1. 计数区（新版）：按 DY778 刷新套路，用原始方法读原数，再走已钩的
    //    apply 方法重写一遍（钩里会按需换成目标数；没伪装就原样写回）。
    for (id section in sDisguiseSections.allObjects) {
        @try {
            if (!DYYYDisguiseOrigProfileCount || !DYYYDisguiseOrigProfileApply) break;
            id cell = DYYYFansRead(section, @"currentCell");
            id components = DYYYFansRead(section, @"components");
            SEL itemSel = NSSelectorFromString(@"p_itemForItemId:");
            Method itemMethod = class_getInstanceMethod([section class], itemSel);
            if (!cell || ![components isKindOfClass:NSDictionary.class] || !DYYYDisguiseMatch(itemMethod, "@", "q")) continue;
            for (id identifier in [components allKeys]) {
                if (![identifier isKindOfClass:NSNumber.class]) continue;
                id component = components[identifier];
                id item = ((id (*)(id, SEL, long long))objc_msgSend)(section, itemSel, [identifier longLongValue]);
                if (!item || !DYYYDisguiseProfileField(component, item)) continue;
                id raw = DYYYDisguiseOrigProfileCount(section, NSSelectorFromString(@"p_displayCountForItem:"), item);
                if (![raw respondsToSelector:@selector(stringValue)]) continue;
                ((void (*)(id, SEL, id, long long, id, id))objc_msgSend)(section, NSSelectorFromString(@"p_applyDisplayText:itemId:cell:component:"), [raw stringValue], [identifier longLongValue], cell, component);
            }
        } @catch (__unused NSException *e) {}
    }
    // 2. 计数区（旧版）：重调一次内容更新，内部会再走 update*Label 钩。
    for (id view in sDisguiseLegacyViews.allObjects) {
        @try {
            SEL sel = NSSelectorFromString(@"p_updateSocialStatisticContent:");
            Method method = class_getInstanceMethod([view class], sel);
            if (!DYYYDisguiseMatchBoolArg(method, "v", "B")) continue;
            ((void (*)(id, SEL, BOOL))objc_msgSend)(view, sel, NO);
        } @catch (__unused NSException *e) {}
    }
    // 3. 基础头部：重配一次当前 cell（读得到的才调；读不到就跳过，不硬调）。
    //    走已钩的 configCell，钩里会按需把 model 换成假 model。
    for (id controller in sDisguiseBaseHeaders.allObjects) {
        @try {
            if (!DYYYDisguiseOrigBaseHeaderConfig) break;
            id cell = DYYYFansRead(controller, @"currentCell");
            id model = DYYYFansRead(DYYYFansRead(controller, @"context"), @"userModel");
            if (!cell || !model) continue;
            ((void (*)(id, SEL, id, long long, id))objc_msgSend)(controller, NSSelectorFromString(@"configCell:index:model:"), cell, 0, model);
        } @catch (__unused NSException *e) {}
    }
    // 4. 作品格：重调一次内容更新，内部会再读 statistics（-69 的钩按 itemID 换播放量）。
    for (id context in sDisguiseWorkContexts.allObjects) {
        @try {
            if (!DYYYDisguiseOrigWorkContent) break;
            id model = DYYYFansRead(context, @"data");
            if (!model) continue;
            ((void (*)(id, SEL, id))objc_msgSend)(context, NSSelectorFromString(@"__updateAccessibilityLabelAndLeftBottomContent:"), model);
        } @catch (__unused NSException *e) {}
    }
    // 5. 41.1.0 头部（-106）：-105 的整页换已拆掉，改成重调各 cell 的
    //    config，让 -106 的钩子在配 cell 的那一刻按当前伪装状态临时换
    //    model。计数区不在此列（它看的是真 model，-70 钩子改数）。
    //    5a. 已包 configCell 的头部 section（头像区等）：重调 configCell，
    //    走包装里的临时换；调 selector（进包装），不直接调原实现。
    //    -107：传包装里记下的上一次 model（有的是 view model 不是 user
    //    model，硬传 context.userModel 会在抖音自己的代码里崩）；没记过
    //    的 section 跳过不重调。
    for (id controller in sDisguiseHeaderSections.allObjects) {
        @try {
            id cell = DYYYFansRead(controller, @"currentCell");
            id model = objc_getAssociatedObject(controller, DYYYDisguiseSectionLastModelKey);
            if (!cell || !model) continue;
            ((void (*)(id, SEL, id, long long, id))objc_msgSend)(controller, NSSelectorFromString(@"configCell:index:model:"), cell, 0, model);
        } @catch (__unused NSException *e) {}
    }
    //    5b. 名字区 cell：重调 configWithContext:componentTree:contentRenderWidth:，
    //    走 cell 钩子里的临时换。componentTree 是 weak 的，释放了就跳过
    //    （靠 5a 的 section 重调兜底），别拿 nil 树硬调。
    for (id cell in sDisguiseNameAreaCells.allObjects) {
        @try {
            if (!DYYYDisguiseOrigNameAreaConfig) break;
            id context = DYYYFansRead(cell, @"context");
            id tree = DYYYFansRead(cell, @"componentTree");
            NSNumber *width = DYYYFansRead(cell, @"contentRenderWidth");
            if (!context || !tree || !width) continue;
            ((void (*)(id, SEL, id, id, double))objc_msgSend)(cell, NSSelectorFromString(@"configWithContext:componentTree:contentRenderWidth:"), context, tree, [width doubleValue]);
        } @catch (__unused NSException *e) {}
    }
    //    5c. 简介区 cell：重调 configWithHeaderContext:，走 cell 钩子里的临时换。
    for (id cell in sDisguiseSignatureCells.allObjects) {
        @try {
            if (!DYYYDisguiseOrigSignatureConfig) break;
            id context = DYYYFansRead(cell, @"context");
            if (!context) continue;
            ((void (*)(id, SEL, id))objc_msgSend)(cell, NSSelectorFromString(@"configWithHeaderContext:"), context);
        } @catch (__unused NSException *e) {}
    }
    // 6. 41.1.0 作品格 cell（-105）：重调一次 configWithViewModel:，
    //    让 cell 在配置时重读 statistics（-69 的钩按 itemID 换播放量）。
    //    AWEUserWorkCellContext 在 41.1.0 上已不存在，-70 的第 4 步刷不到。
    for (id cell in sDisguiseWorkCells.allObjects) {
        @try {
            if (!DYYYDisguiseOrigWorkCellConfig) break;
            id viewModel = DYYYFansRead(cell, @"viewModel");
            if (!viewModel) continue;
            ((void (*)(id, SEL, id))objc_msgSend)(cell, NSSelectorFromString(@"configWithViewModel:"), viewModel);
        } @catch (__unused NSException *e) {}
    }
    // -106：viewModel 可能在创建时就缓存了播放量文本，只重调 config
    // 换不掉；再对作品列表调一次 reloadData，逼它按当前 map 重建
    // viewModel（statistics 钩子在重建时按 itemID 换播放量）。只对
    // 已记录的作品格 cell 所在的那一个列表调一次，找不到就跳过；
    // 伪装开/关才走到这里（RefreshDisplays 只在 ReloadOwnProfile 里
    // 调），不会每进一次主页就闪。
    id firstWorkCell = sDisguiseWorkCells.allObjects.firstObject;
    if (firstWorkCell) {
        @try {
            UIView *view = firstWorkCell;
            while (view && ![view isKindOfClass:UICollectionView.class]) view = view.superview;
            if ([view isKindOfClass:UICollectionView.class]) [(UICollectionView *)view reloadData];
        } @catch (__unused NSException *e) {}
    }
    // 5. 导航按钮 + 水印由调用方（ReloadOwnProfile）对已记录的导航组件
    //    调 reloadData 时一并重算，这里不再重复。
}

void DYYYInstallDisguiseHooks(void) {
    DYYYDisguiseRestoreIfNeeded();
    DYYYDisguiseInstallProfile();
    DYYYDisguiseInstallStatistics();
    DYYYDisguiseInstallHitTest();
    DYYYDisguiseInstallHeaderHooks();
}

// .m 不能用 Logos 的 %ctor，故用等价的 __attribute__((constructor))，与星牌同款。
// 本文件排在 Makefile DYYY_FILES 末尾，constructor 在星牌之后跑，
// 同名方法的替换链能正确包住星牌的替换。
__attribute__((constructor)) static void DYYYDisguiseStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ DYYYInstallDisguiseHooks(); });
}
