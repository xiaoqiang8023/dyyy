// DYYYChatInputScope.m
// 聊天输入区的基础设施：宿主判定、ivar 读取、组件查找、布局对象登记与刷新。
// 移植自 DYKiller DKChatInput.m，仅改名前缀、去掉玻璃相关函数；逻辑未改。
#import "DYYYChatInputScope.h"
#import "AwemeHeaders.h"
#import <objc/runtime.h>

static NSHashTable *gDYYYChatLayouts;
static char kDYYYChatLayoutKey;

// 输入控制器上挂布局对象的弱引用容器，避免控制器反向持有布局组件。
@interface DYYYChatLayoutReference : NSObject
@property (nonatomic, weak) id layout;
@end
@implementation DYYYChatLayoutReference
@end

BOOL DYYYChatInputIsKind(id object, NSString *className) {
    Class cls = NSClassFromString(className);
    return cls && [object isKindOfClass:cls];
}

id DYYYChatInputObjectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(object, ivar) : nil;
}

// 聊天页下的普通聊天输入控制器；专用会话与详情页内的输入页不算。
static UIViewController *DYYYChatNormalInput(UIViewController *host) {
    if (!DYYYChatInputIsKind(host, @"AWEIMMessageBaseViewController")) return nil;
    for (UIViewController *child in host.childViewControllers) {
        if (!DYYYChatInputIsKind(child, @"IESIMInputViewController")) continue;
        IESIMInputViewController *input = (id)child;
        if (input.isCompanyChat || input.isShowingInPOIIMConversationViewController
            || input.isShowingInFeedDetailViewController || input.isShowingInImageVideoDisplayViewController) return nil;
        return input;
    }
    return nil;
}

UIViewController *DYYYChatInputController(id component) {
    return DYYYChatNormalInput(((AWEIMComponentBase *)component).context.hostViewController);
}

UIViewController *DYYYChatInputControllerForPageView(UIView *view) {
    for (UIResponder *node = view; node; node = node.nextResponder) {
        if (DYYYChatInputIsKind(node, @"AWEIMMessageBaseViewController")) return DYYYChatNormalInput((id)node);
    }
    return nil;
}

id DYYYChatInputComponent(id component, NSString *className) {
    for (id sibling in ((AWEIMComponentBase *)component).belongingManager.components) {
        if (DYYYChatInputIsKind(sibling, className)) return sibling;
    }
    return nil;
}

void DYYYChatInputRegisterLayout(id layout) {
    UIViewController *input = DYYYChatInputController(layout);
    if (!input) return;
    if (!gDYYYChatLayouts) gDYYYChatLayouts = [NSHashTable weakObjectsHashTable];
    [gDYYYChatLayouts addObject:layout];
    DYYYChatLayoutReference *reference = objc_getAssociatedObject(input, &kDYYYChatLayoutKey);
    if (!reference) {
        reference = [DYYYChatLayoutReference new];
        objc_setAssociatedObject(input, &kDYYYChatLayoutKey, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    reference.layout = layout;
}

id DYYYChatInputLayoutForController(UIViewController *input) {
    DYYYChatLayoutReference *reference = input ? objc_getAssociatedObject(input, &kDYYYChatLayoutKey) : nil;
    return reference.layout;
}

id DYYYChatInputLayoutForView(UIView *view) {
    for (UIResponder *node = view; node; node = node.nextResponder) {
        if (DYYYChatInputIsKind(node, @"IESIMInputViewController")) return DYYYChatInputLayoutForController((id)node);
    }
    return nil;
}

NSArray *DYYYChatInputLayouts(void) {
    return gDYYYChatLayouts.allObjects ?: @[];
}

void DYYYChatInputRefresh(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ DYYYChatInputRefresh(); });
        return;
    }
    for (id layout in DYYYChatInputLayouts()) [layout refreshLayout];
}
