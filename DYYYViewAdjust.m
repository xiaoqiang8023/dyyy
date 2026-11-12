// DYYYViewAdjust.m
// 可复位的视图调整，供消息页精简（顶栏 / 列表顶部 / 聊天页顶栏）共用。
// 用关联对象记下基础值与写入值，只还原本模块改过的对象；宿主在下一轮写入的新值成为下一轮的基础值。
// 移植自 DYKiller DKViewAdjust.m，仅改名前缀，未改逻辑。
#import "DYYYViewAdjust.h"

#import <math.h>
#import <objc/runtime.h>

static char kDYYYAdjustBackgroundKey;
static char kDYYYAdjustBaseAlphaKey;
static char kDYYYAdjustAppliedAlphaKey;
static char kDYYYAdjustBaseTransformKey;
static char kDYYYAdjustAppliedTransformKey;
static char kDYYYAdjustFadeMaskKey;

BOOL DYYYAdjustTransformEqual(CGAffineTransform lhs, CGAffineTransform rhs) {
    return fabs(lhs.a - rhs.a) < 0.0005 && fabs(lhs.b - rhs.b) < 0.0005
        && fabs(lhs.c - rhs.c) < 0.0005 && fabs(lhs.d - rhs.d) < 0.0005
        && fabs(lhs.tx - rhs.tx) < 0.05 && fabs(lhs.ty - rhs.ty) < 0.05;
}

void DYYYAdjustAlpha(UIView *view, CGFloat factor) {
    if (!view) return;
    factor = MIN(1.0, MAX(0.0, factor));

    NSNumber *applied = objc_getAssociatedObject(view, &kDYYYAdjustAppliedAlphaKey);
    NSNumber *base = objc_getAssociatedObject(view, &kDYYYAdjustBaseAlphaKey);
    CGFloat current = view.alpha;
    CGFloat original = current;
    if (applied && base && fabs(current - applied.doubleValue) < 0.005) {
        original = base.doubleValue;
    }

    if (factor >= 0.9999) {
        if (applied && base) view.alpha = original;
        objc_setAssociatedObject(view, &kDYYYAdjustBaseAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kDYYYAdjustAppliedAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGFloat target = original * factor;
    if (fabs(current - target) >= 0.005) view.alpha = target;
    objc_setAssociatedObject(view, &kDYYYAdjustBaseAlphaKey, @(original), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kDYYYAdjustAppliedAlphaKey, @(target), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void DYYYAdjustTransform(UIView *view, CGAffineTransform delta) {
    if (!view) return;

    NSValue *appliedValue = objc_getAssociatedObject(view, &kDYYYAdjustAppliedTransformKey);
    NSValue *baseValue = objc_getAssociatedObject(view, &kDYYYAdjustBaseTransformKey);
    CGAffineTransform current = view.transform;
    CGAffineTransform original = current;
    if (appliedValue && baseValue && DYYYAdjustTransformEqual(current, appliedValue.CGAffineTransformValue)) {
        original = baseValue.CGAffineTransformValue;
    }

    if (DYYYAdjustTransformEqual(delta, CGAffineTransformIdentity)) {
        if (appliedValue && baseValue) view.transform = original;
        objc_setAssociatedObject(view, &kDYYYAdjustBaseTransformKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kDYYYAdjustAppliedTransformKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGAffineTransform target = CGAffineTransformConcat(original, delta);
    if (!DYYYAdjustTransformEqual(current, target)) view.transform = target;
    objc_setAssociatedObject(view, &kDYYYAdjustBaseTransformKey,
                             [NSValue valueWithCGAffineTransform:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kDYYYAdjustAppliedTransformKey,
                             [NSValue valueWithCGAffineTransform:target], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void DYYYAdjustFade(UIView *view, CGFloat factor, CGSize outset) {
    if (!view) return;
    factor = MIN(1.0, MAX(0.0, factor));

    CALayer *mask = objc_getAssociatedObject(view, &kDYYYAdjustFadeMaskKey);
    BOOL owned = mask && view.layer.mask == mask;
    if (factor >= 0.9999) {
        if (owned) view.layer.mask = nil;
        objc_setAssociatedObject(view, &kDYYYAdjustFadeMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (view.layer.mask && !owned) return;

    if (!mask) {
        mask = [CALayer layer];
        objc_setAssociatedObject(view, &kDYYYAdjustFadeMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = CGRectInset(view.bounds, -outset.width, -outset.height);
    mask.backgroundColor = [UIColor colorWithWhite:1.0 alpha:factor].CGColor;
    if (!owned) view.layer.mask = mask;
    [CATransaction commit];
}

CGFloat DYYYAdjustFadeFactor(UIView *view) {
    CALayer *mask = objc_getAssociatedObject(view, &kDYYYAdjustFadeMaskKey);
    if (!mask || view.layer.mask != mask) return 1.0;
    return CGColorGetAlpha(mask.backgroundColor);
}

void DYYYAdjustClearBackground(UIView *view, BOOL clear) {
    if (!view) return;
    id original = objc_getAssociatedObject(view, &kDYYYAdjustBackgroundKey);
    BOOL isClear = [view.backgroundColor isEqual:UIColor.clearColor];
    if (clear) {
        if (!original || !isClear) {
            objc_setAssociatedObject(view, &kDYYYAdjustBackgroundKey,
                view.backgroundColor ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!isClear) view.backgroundColor = UIColor.clearColor;
    } else if (original) {
        if (isClear) view.backgroundColor = original == NSNull.null ? nil : original;
        objc_setAssociatedObject(view, &kDYYYAdjustBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

BOOL DYYYAdjustBackgroundCleared(UIView *view) {
    return objc_getAssociatedObject(view, &kDYYYAdjustBackgroundKey) != nil;
}
