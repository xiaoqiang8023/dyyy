//
//  DYYYDebugCapture.m
//  DYYY
//
//  只读地遍历 UIKit/CoreAnimation 安全字段 + 收集本页类，产出 DYYYDebugExportContext。
//  不递归读任意对象的 ivar 值。
//  移植自 DYKiller 0.7.1 DKDebugCapture，仅改前缀；音频专项的轻量路径
//  （DKDebugCaptureMetadataContext）已删——DYYY 只有整页导出一种模式。
//  注意：整棵 view tree 的遍历发生在主线程（导出点按时），大页面会短暂卡一下。
//

#import "DYYYDebugCapture.h"
#import "DYYYConstants.h"
#import "DYYYClassDump.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@implementation DYYYDebugExportContext
@end

#pragma mark - 小型格式化工具

static NSString *DYYYStringFromPointer(const void *pointer) {
    return [NSString stringWithFormat:@"%p", pointer];
}

static NSString *DYYYClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"";
}

static NSString *DYYYObjectDesc(id object) {
    if (!object) return @"";
    @try {
        return [object description] ?: @"";
    } @catch (__unused NSException *exception) {
        return @"<description threw>";
    }
}

static NSNumber *DYYYNum(double value) {
    return @(isfinite(value) ? value : 0);
}

static NSString *DYYYStringFromColor(UIColor *color) {
    if (!color) return @"";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"rgba(%.4f, %.4f, %.4f, %.4f)", r, g, b, a];
    }
    return DYYYObjectDesc(color);
}

static NSDictionary *DYYYRectDict(CGRect rect) {
    return @{
        @"x": DYYYNum(rect.origin.x),
        @"y": DYYYNum(rect.origin.y),
        @"width": DYYYNum(rect.size.width),
        @"height": DYYYNum(rect.size.height),
        @"string": NSStringFromCGRect(rect)
    };
}

static NSDictionary *DYYYPointDict(CGPoint point) {
    return @{ @"x": DYYYNum(point.x), @"y": DYYYNum(point.y), @"string": NSStringFromCGPoint(point) };
}

static NSDictionary *DYYYSizeDict(CGSize size) {
    return @{ @"width": DYYYNum(size.width), @"height": DYYYNum(size.height), @"string": NSStringFromCGSize(size) };
}

static NSDictionary *DYYYAffineDict(CGAffineTransform t) {
    return @{
        @"a": DYYYNum(t.a), @"b": DYYYNum(t.b), @"c": DYYYNum(t.c),
        @"d": DYYYNum(t.d), @"tx": DYYYNum(t.tx), @"ty": DYYYNum(t.ty)
    };
}

static NSDictionary *DYYYTransform3DDict(CATransform3D t) {
    return @{
        @"m11": DYYYNum(t.m11), @"m12": DYYYNum(t.m12), @"m13": DYYYNum(t.m13), @"m14": DYYYNum(t.m14),
        @"m21": DYYYNum(t.m21), @"m22": DYYYNum(t.m22), @"m23": DYYYNum(t.m23), @"m24": DYYYNum(t.m24),
        @"m31": DYYYNum(t.m31), @"m32": DYYYNum(t.m32), @"m33": DYYYNum(t.m33), @"m34": DYYYNum(t.m34),
        @"m41": DYYYNum(t.m41), @"m42": DYYYNum(t.m42), @"m43": DYYYNum(t.m43), @"m44": DYYYNum(t.m44)
    };
}

#pragma mark - 窗口与控制器工具

static BOOL DYYYIsDebugWindow(UIWindow *window) {
    NSString *cls = DYYYClassName(window);
    return [cls hasPrefix:@"DYYYDebug"];
}

NSArray<UIWindow *> *DYYYDebugActiveWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window || DYYYIsDebugWindow(window)) continue;
                if (window.hidden || window.alpha <= 0.01) continue;
                [windows addObject:window];
            }
        }
    }
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (!window || DYYYIsDebugWindow(window)) continue;
            if (window.hidden || window.alpha <= 0.01) continue;
            [windows addObject:window];
        }
#pragma clang diagnostic pop
    }
    return windows;
}

UIWindow *DYYYDebugTargetWindow(void) {
    NSArray<UIWindow *> *windows = DYYYDebugActiveWindows();
    for (UIWindow *window in windows) if (window.isKeyWindow) return window;
    return windows.firstObject;
}

static UIViewController *DYYYViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    for (NSUInteger i = 0; responder && i < 80; i++) {
        responder = responder.nextResponder;
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
    }
    return nil;
}

static UIViewController *DYYYTopViewControllerFrom(UIViewController *vc) {
    for (NSUInteger i = 0; vc && i < 80; i++) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = ((UINavigationController *)vc).visibleViewController;
            if (!visible || visible == vc) break;
            vc = visible;
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = ((UITabBarController *)vc).selectedViewController;
            if (!selected || selected == vc) break;
            vc = selected;
        } else {
            break;
        }
    }
    return vc;
}

UIViewController *DYYYDebugTopPresenter(UIWindow *window) {
    return DYYYTopViewControllerFrom(window.rootViewController);
}

#pragma mark - 页面快照

static NSDictionary *DYYYLayerInfo(CALayer *layer) {
    if (!layer) return @{};
    return @{
        @"class": DYYYClassName(layer),
        @"address": DYYYStringFromPointer((__bridge const void *)layer),
        @"bounds": DYYYRectDict(layer.bounds),
        @"position": DYYYPointDict(layer.position),
        @"anchorPoint": DYYYPointDict(layer.anchorPoint),
        @"zPosition": DYYYNum(layer.zPosition),
        @"opacity": DYYYNum(layer.opacity),
        @"hidden": @(layer.hidden),
        @"masksToBounds": @(layer.masksToBounds),
        @"cornerRadius": DYYYNum(layer.cornerRadius),
        @"sublayerCount": @(layer.sublayers.count),
        @"transform": DYYYTransform3DDict(layer.transform),
        @"mask": layer.mask ? @{
            @"class": DYYYClassName(layer.mask),
            @"address": DYYYStringFromPointer((__bridge const void *)layer.mask),
            @"bounds": DYYYRectDict(layer.mask.bounds)
        } : @{}
    };
}

static NSMutableDictionary *DYYYBaseViewInfo(UIView *view, NSUInteger depth) {
    UIViewController *nearestVC = DYYYViewControllerForView(view);
    NSMutableDictionary *info = [@{
        @"class": DYYYClassName(view),
        @"address": DYYYStringFromPointer((__bridge const void *)view),
        @"depth": @(depth),
        @"frame": DYYYRectDict(view.frame),
        @"bounds": DYYYRectDict(view.bounds),
        @"center": DYYYPointDict(view.center),
        @"alpha": DYYYNum(view.alpha),
        @"hidden": @(view.hidden),
        @"opaque": @(view.opaque),
        @"clipsToBounds": @(view.clipsToBounds),
        @"userInteractionEnabled": @(view.userInteractionEnabled),
        @"multipleTouchEnabled": @(view.multipleTouchEnabled),
        @"contentMode": @(view.contentMode),
        @"tag": @(view.tag),
        @"autoresizingMask": @(view.autoresizingMask),
        @"autoresizesSubviews": @(view.autoresizesSubviews),
        @"transform": DYYYAffineDict(view.transform),
        @"backgroundColor": DYYYStringFromColor(view.backgroundColor),
        @"tintColor": DYYYStringFromColor(view.tintColor),
        @"accessibilityIdentifier": view.accessibilityIdentifier ?: @"",
        @"accessibilityLabel": view.accessibilityLabel ?: @"",
        @"nearestViewController": nearestVC ? @{
            @"class": DYYYClassName(nearestVC),
            @"address": DYYYStringFromPointer((__bridge const void *)nearestVC)
        } : @{},
        @"layer": DYYYLayerInfo(view.layer),
        @"subviewCount": @(view.subviews.count)
    } mutableCopy];

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        info[@"label"] = @{
            @"text": label.text ?: @"",
            @"attributedText": label.attributedText.string ?: @"",
            @"font": DYYYObjectDesc(label.font),
            @"textColor": DYYYStringFromColor(label.textColor),
            @"numberOfLines": @(label.numberOfLines),
            @"textAlignment": @(label.textAlignment)
        };
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        info[@"button"] = @{
            @"currentTitle": [button titleForState:UIControlStateNormal] ?: (button.currentTitle ?: @""),
            @"currentAttributedTitle": button.currentAttributedTitle.string ?: @"",
            @"enabled": @(button.enabled),
            @"selected": @(button.selected),
            @"highlighted": @(button.highlighted)
        };
    }
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)view;
        info[@"imageView"] = @{
            @"imageSize": imageView.image ? DYYYSizeDict(imageView.image.size) : @{},
            @"highlighted": @(imageView.highlighted)
        };
    }
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        info[@"control"] = @{
            @"enabled": @(control.enabled),
            @"selected": @(control.selected),
            @"highlighted": @(control.highlighted),
            @"state": @(control.state)
        };
    }
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)view;
        info[@"scrollView"] = @{
            @"contentOffset": DYYYPointDict(scroll.contentOffset),
            @"contentSize": DYYYSizeDict(scroll.contentSize),
            @"contentInset": NSStringFromUIEdgeInsets(scroll.contentInset),
            @"adjustedContentInset": NSStringFromUIEdgeInsets(scroll.adjustedContentInset),
            @"zoomScale": DYYYNum(scroll.zoomScale),
            @"minimumZoomScale": DYYYNum(scroll.minimumZoomScale),
            @"maximumZoomScale": DYYYNum(scroll.maximumZoomScale),
            @"pagingEnabled": @(scroll.pagingEnabled),
            @"scrollEnabled": @(scroll.scrollEnabled),
            @"dragging": @(scroll.dragging),
            @"tracking": @(scroll.tracking),
            @"decelerating": @(scroll.decelerating)
        };
    }
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        info[@"visualEffectView"] = @{ @"effect": DYYYObjectDesc(((UIVisualEffectView *)view).effect) };
    }
    return info;
}

static NSDictionary *DYYYViewTreeJSON(UIView *view, NSUInteger depth, NSMutableArray *layers) {
    NSMutableDictionary *info = DYYYBaseViewInfo(view, depth);
    [layers addObject:@{
        @"viewClass": info[@"class"],
        @"viewAddress": info[@"address"],
        @"nearestViewController": info[@"nearestViewController"],
        @"layer": info[@"layer"]
    }];

    NSMutableArray *children = [NSMutableArray arrayWithCapacity:view.subviews.count];
    for (UIView *subview in view.subviews) {
        [children addObject:DYYYViewTreeJSON(subview, depth + 1, layers)];
    }
    info[@"children"] = children;
    return info;
}

static void DYYYAppendViewTreeText(UIView *view, NSUInteger depth, NSMutableString *out) {
    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    UIViewController *vc = DYYYViewControllerForView(view);
    [out appendFormat:@"%@%@ %@ frame=%@ bounds=%@ vc=%@ %@ hidden=%d alpha=%.3f clips=%d user=%d layer=%@\n",
     indent,
     DYYYClassName(view),
     DYYYStringFromPointer((__bridge const void *)view),
     NSStringFromCGRect(view.frame),
     NSStringFromCGRect(view.bounds),
     vc ? DYYYClassName(vc) : @"",
     vc ? DYYYStringFromPointer((__bridge const void *)vc) : @"",
     view.hidden,
     view.alpha,
     view.clipsToBounds,
     view.userInteractionEnabled,
     DYYYClassName(view.layer)];
    for (UIView *subview in view.subviews) DYYYAppendViewTreeText(subview, depth + 1, out);
}

static NSDictionary *DYYYWindowJSON(UIWindow *window) {
    return @{
        @"class": DYYYClassName(window),
        @"address": DYYYStringFromPointer((__bridge const void *)window),
        @"frame": DYYYRectDict(window.frame),
        @"bounds": DYYYRectDict(window.bounds),
        @"windowLevel": DYYYNum(window.windowLevel),
        @"hidden": @(window.hidden),
        @"alpha": DYYYNum(window.alpha),
        @"keyWindow": @(window.isKeyWindow),
        @"rootViewController": window.rootViewController ? @{
            @"class": DYYYClassName(window.rootViewController),
            @"address": DYYYStringFromPointer((__bridge const void *)window.rootViewController)
        } : @{}
    };
}

static NSArray *DYYYAncestorChain(UIView *view) {
    NSMutableArray *chain = [NSMutableArray array];
    UIView *v = view;
    for (NSUInteger depth = 0; v && depth < 120; depth++, v = v.superview) {
        [chain addObject:DYYYBaseViewInfo(v, depth)];
    }
    return chain;
}

static void DYYYAppendVCText(UIViewController *vc, NSUInteger depth, NSMutableString *out, NSHashTable *seen) {
    if (!vc || [seen containsObject:vc]) return;
    [seen addObject:vc];
    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    BOOL loaded = vc.isViewLoaded;
    UIView *view = loaded ? vc.view : nil;
    [out appendFormat:@"%@%@ %@ viewLoaded=%@ view=%@ %@ frame=%@\n",
     indent,
     DYYYClassName(vc),
     DYYYStringFromPointer((__bridge const void *)vc),
     loaded ? @"YES" : @"NO",
     DYYYClassName(view),
     view ? DYYYStringFromPointer((__bridge const void *)view) : @"",
     view ? NSStringFromCGRect(view.frame) : @"null"];

    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        [out appendFormat:@"%@  nav.top=%@ nav.visible=%@\n", indent, DYYYClassName(nav.topViewController), DYYYClassName(nav.visibleViewController)];
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        [out appendFormat:@"%@  tab.selected=%@\n", indent, DYYYClassName(tab.selectedViewController)];
    }
    for (UIViewController *child in vc.childViewControllers) DYYYAppendVCText(child, depth + 1, out, seen);
    if (vc.presentedViewController) {
        [out appendFormat:@"%@  presented:\n", indent];
        DYYYAppendVCText(vc.presentedViewController, depth + 1, out, seen);
    }
}

// 按 windowLevel 从低到高逐个画，截图才等于用户真正看到的画面。
// 只画 key 窗口会漏掉浮层：抖音的内嵌画中画 AWEDPlayerPiPWindow 在 windowLevel 2000，
// 它铺满全屏时导出截图却一切正常，排查会整整绕一轮。
static NSData *DYYYScreenshotPNG(UIWindow *targetWindow) {
    if (!targetWindow) return NSData.data;

    NSArray<UIWindow *> *windows =
        [DYYYDebugActiveWindows() sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
            if (a.windowLevel == b.windowLevel) return NSOrderedSame;
            return a.windowLevel < b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
        }];
    if (windows.count == 0) windows = @[ targetWindow ];

    UIGraphicsBeginImageContextWithOptions(targetWindow.bounds.size, NO, 0);
    for (UIWindow *window in windows) {
        BOOL drew = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
        if (!drew) [window.layer renderInContext:UIGraphicsGetCurrentContext()];
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image ? UIImagePNGRepresentation(image) : NSData.data;
}

#pragma mark - 页面类收集

// 收集一个类及其整条继承链的类名：跳过运行时生成子类噪声，但继续上溯 → 自动收到真实基类。
static void DYYYCollectClassAndSupers(Class cls, NSMutableSet<NSString *> *names) {
    for (int i = 0; cls && i < 50; i++) {
        if (!DYYYClassIsSafe(cls)) break;
        NSString *name = NSStringFromClass(cls);
        if (name.length && !DYYYClassNameIsRuntimeGenerated(name)) [names addObject:name];
        cls = class_getSuperclass(cls);
    }
}

// 递归收集视图子树里每个 view 及其 layer 的类（含继承链）。
static void DYYYCollectPageClassesFromView(UIView *view, NSMutableSet<NSString *> *names) {
    if (!view) return;
    DYYYCollectClassAndSupers(object_getClass(view), names);
    DYYYCollectClassAndSupers(object_getClass(view.layer), names);
    for (UIView *sub in view.subviews) DYYYCollectPageClassesFromView(sub, names);
}

// 递归收集 VC 树（child + presented）里每个 VC 及其已加载 view 的类（含继承链）。
static void DYYYCollectPageClassesFromVC(UIViewController *vc, NSMutableSet<NSString *> *names, NSHashTable *seen) {
    if (!vc || [seen containsObject:vc]) return;
    [seen addObject:vc];
    DYYYCollectClassAndSupers(object_getClass(vc), names);
    if (vc.isViewLoaded) DYYYCollectClassAndSupers(object_getClass(vc.view), names);
    for (UIViewController *child in vc.childViewControllers) DYYYCollectPageClassesFromVC(child, names, seen);
    if (vc.presentedViewController) DYYYCollectPageClassesFromVC(vc.presentedViewController, names, seen);
}

static NSDictionary *DYYYDebugMetadata(UIWindow *targetWindow, CGPoint point) {
    return @{
        @"generatedAt": DYYYObjectDesc(NSDate.date),
        @"dyyyVersion": DYYY_VERSION,
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"bundleName": NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"",
        @"appVersion": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
        @"buildVersion": NSBundle.mainBundle.infoDictionary[(NSString *)kCFBundleVersionKey] ?: @"",
        @"systemName": UIDevice.currentDevice.systemName ?: @"",
        @"systemVersion": UIDevice.currentDevice.systemVersion ?: @"",
        @"deviceModel": UIDevice.currentDevice.model ?: @"",
        @"screenBounds": DYYYRectDict(UIScreen.mainScreen.bounds),
        @"tapPointInTargetWindow": DYYYPointDict(point),
        @"targetWindow": targetWindow ? DYYYWindowJSON(targetWindow) : @{}
    };
}

DYYYDebugExportContext *DYYYDebugCaptureContext(UIWindow *targetWindow, CGPoint point, UIView *selectedView) {
    DYYYDebugExportContext *context = [DYYYDebugExportContext new];
    NSArray<UIWindow *> *windows = DYYYDebugActiveWindows();
    NSMutableArray *windowsJSON = [NSMutableArray array];
    NSMutableArray *treeJSON = [NSMutableArray array];
    NSMutableArray *layersJSON = [NSMutableArray array];
    NSMutableString *treeText = [NSMutableString string];
    NSMutableString *vcText = [NSMutableString string];
    NSHashTable *seenVCs = [NSHashTable weakObjectsHashTable];
    NSMutableSet<NSString *> *pageClasses = [NSMutableSet set];
    NSHashTable *seenClassVCs = [NSHashTable weakObjectsHashTable];

    for (UIWindow *window in windows) {
        [windowsJSON addObject:DYYYWindowJSON(window)];
        [treeJSON addObject:DYYYViewTreeJSON(window, 0, layersJSON)];
        DYYYAppendViewTreeText(window, 0, treeText);
        DYYYCollectPageClassesFromView(window, pageClasses);
        DYYYCollectPageClassesFromVC(window.rootViewController, pageClasses, seenClassVCs);
        if (window.rootViewController) {
            [vcText appendFormat:@"Window %@ %@\n", DYYYClassName(window), DYYYStringFromPointer((__bridge const void *)window)];
            DYYYAppendVCText(window.rootViewController, 1, vcText, seenVCs);
        }
    }

    UIViewController *nearestVC = DYYYViewControllerForView(selectedView);
    NSDictionary *selected = @{
        @"tapPointInWindow": DYYYPointDict(point),
        @"hitView": DYYYBaseViewInfo(selectedView ?: targetWindow, 0),
        @"nearestViewController": nearestVC ? @{
            @"class": DYYYClassName(nearestVC),
            @"address": DYYYStringFromPointer((__bridge const void *)nearestVC)
        } : @{},
        @"ancestorChain": selectedView ? DYYYAncestorChain(selectedView) : @[]
    };

    NSString *summary = [NSString stringWithFormat:
                         @"Hit: %@ %@\nFrame: %@\nBounds: %@\nNearest VC: %@ %@\nWindows: %lu\nSubviews: %lu",
                         DYYYClassName(selectedView),
                         DYYYStringFromPointer((__bridge const void *)selectedView),
                         selectedView ? NSStringFromCGRect(selectedView.frame) : @"",
                         selectedView ? NSStringFromCGRect(selectedView.bounds) : @"",
                         nearestVC ? DYYYClassName(nearestVC) : @"",
                         nearestVC ? DYYYStringFromPointer((__bridge const void *)nearestVC) : @"",
                         (unsigned long)windows.count,
                         (unsigned long)selectedView.subviews.count];

    context.metadata = DYYYDebugMetadata(targetWindow, point);
    context.windowsJSON = windowsJSON;
    context.viewTreeJSON = treeJSON;
    context.viewTreeText = treeText;
    context.selectedViewJSON = selected;
    context.viewControllersText = vcText;
    context.layersJSON = layersJSON;
    context.screenshotPNG = DYYYScreenshotPNG(targetWindow);
    context.summary = summary;
    context.pageClassNames = pageClasses.allObjects;
    context.sourceView = targetWindow;
    context.presenter = DYYYDebugTopPresenter(targetWindow);
    return context;
}
