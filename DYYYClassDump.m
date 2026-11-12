//
//  DYYYClassDump.m
//  DYYY
//
//  基于 ObjC 运行时生成类头文件文本（移植自 DYKiller 0.7.1 DKClassDump，仅改前缀）。
//  DYYYClassIsSafe 用于限制可内省类集合。
//

#import "DYYYClassDump.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *DYYYCString(const char *value) {
    if (!value) return @"";
    NSString *utf8 = [NSString stringWithUTF8String:value];
    if (utf8) return utf8;
    size_t length = strnlen(value, 4096);
    NSString *latin = [[NSString alloc] initWithBytes:value length:length encoding:NSISOLatin1StringEncoding];
    if (latin) return latin;
    NSMutableString *hex = [NSMutableString stringWithString:@"<bytes:"];
    for (size_t i = 0; i < MIN(length, (size_t)64); i++) [hex appendFormat:@"%02x", (unsigned char)value[i]];
    [hex appendString:@">"];
    return hex;
}

#pragma mark - 安全内省检查

// 用 CFSet + NULL 回调按指针身份比较，用于跳过不安全类。
static CFSetRef DYYYUnsafeClassSet;
static Class DYYYcNSObject;
static Class DYYYcNSProxy;

__attribute__((constructor))
static void DYYYClassDumpInit(void) {
    DYYYcNSObject = [NSObject class];
    DYYYcNSProxy = [NSProxy class];

    static const char *const kUnsafeNames[] = {
        "__ARCLite__", "__NSCFCalendar", "__NSCFTimer", "NSCFTimer",
        "__NSGenericDeallocHandler", "NSAutoreleasePool", "NSPlaceholderNumber",
        "NSPlaceholderString", "NSPlaceholderValue", "Object", "VMUArchitecture",
        "JSExport", "__NSAtom", "_NSZombie_", "_CNZombie_", "__NSMessage",
        "__NSMessageBuilder", "FigIrisAutoTrimmerMotionSampleExport", "_UIPointVector",
    };
    NSUInteger n = sizeof(kUnsafeNames) / sizeof(kUnsafeNames[0]);
    const void **classes = malloc(n * sizeof(void *));
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < n; i++) {
        Class c = objc_getClass(kUnsafeNames[i]);
        if (c) classes[count++] = (__bridge const void *)c;
    }
    DYYYUnsafeClassSet = CFSetCreate(kCFAllocatorDefault, classes, count, NULL);
    free(classes);
}

BOOL DYYYClassIsSafe(Class cls) {
    if (!cls) return NO;
    if (DYYYUnsafeClassSet && CFSetContainsValue(DYYYUnsafeClassSet, (__bridge const void *)cls)) return NO;
    // 无父类者只有 NSObject / NSProxy 两个已知根类是安全的
    if (!class_getSuperclass(cls)) {
        return cls == DYYYcNSObject || cls == DYYYcNSProxy;
    }
    return YES;
}

#pragma mark - 过滤

static BOOL DYYYIsLikelySwiftName(NSString *name) {
    if (name.length == 0) return YES;
    if ([name hasPrefix:@"_Tt"]) return YES;
    if ([name hasPrefix:@"Swift."]) return YES;
    if ([name hasPrefix:@"SwiftUI."]) return YES;
    if ([name containsString:@"<"]) return YES;
    if ([name containsString:@"`"]) return YES;
    if ([name containsString:@"."]) return YES;
    return NO;
}

BOOL DYYYClassNameIsRuntimeGenerated(NSString *name) {
    if (name.length == 0) return YES;
    if ([name hasPrefix:@"NSKVONotifying_"]) return YES;   // KVO 运行时子类
    if ([name containsString:@"_hmd_subfix_"]) return YES; // Heimdallr 崩溃修复子类
    if ([name containsString:@"_AWEPERF_"]) return YES;    // 性能监控子类
    if ([name containsString:@"_block_invoke"]) return YES;
    if ([name containsString:@"%"]) return YES;
    return NO;
}

#pragma mark - 类型编码 → 可读类型

static NSString *DYYYTypeFromEncoding(const char *encoding) {
    if (!encoding) return @"id";
    NSString *e = DYYYCString(encoding);
    if (e.length == 0) return @"id";

    if ([e hasPrefix:@"@\""]) {
        NSRange r1 = [e rangeOfString:@"\""];
        NSRange r2 = [e rangeOfString:@"\"" options:NSBackwardsSearch];
        if (r1.location != NSNotFound && r2.location != NSNotFound && r2.location > r1.location) {
            NSString *cls = [e substringWithRange:NSMakeRange(r1.location + 1, r2.location - r1.location - 1)];
            if (cls.length) return [NSString stringWithFormat:@"%@ *", cls];
        }
    }

    switch ([e characterAtIndex:0]) {
        case 'v': return @"void";
        case '@': return @"id";
        case '#': return @"Class";
        case ':': return @"SEL";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return @"unsigned short";
        case 'i': return @"int";
        case 'I': return @"unsigned int";
        case 'l': return @"long";
        case 'L': return @"unsigned long";
        case 'q': return @"long long";
        case 'Q': return @"unsigned long long";
        case 'f': return @"float";
        case 'd': return @"double";
        case 'B': return @"BOOL";
        case '*': return @"char *";
        case '^': return @"void *";
        case '{': return @"struct";
        case '[': return @"void *";
        default:  return @"id";
    }
}

#pragma mark - 属性 / 方法行

static NSString *DYYYPropertyLine(objc_property_t property) {
    const char *n = property_getName(property);
    if (!n) return nil;
    NSString *name = DYYYCString(n);

    NSString *attrs = @"";
    const char *a = property_getAttributes(property);
    if (a) attrs = DYYYCString(a);

    NSString *type = @"id";
    BOOL readonly = [attrs containsString:@",R"];
    BOOL copy = [attrs containsString:@",C"];
    BOOL weak = [attrs containsString:@",W"];
    BOOL nonatomic = [attrs containsString:@",N"];

    if ([attrs hasPrefix:@"T"]) {
        NSString *typePart = [[attrs substringFromIndex:1] componentsSeparatedByString:@","].firstObject ?: @"@";
        type = DYYYTypeFromEncoding(typePart.UTF8String);
    }

    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:(nonatomic ? @"nonatomic" : @"atomic")];
    if (readonly) [parts addObject:@"readonly"];
    if (copy) [parts addObject:@"copy"];
    else if (weak) [parts addObject:@"weak"];
    else if ([type containsString:@"*"] || [type isEqualToString:@"id"]) [parts addObject:@"strong"];
    else [parts addObject:@"assign"];

    return [NSString stringWithFormat:@"@property (%@) %@ %@;", [parts componentsJoinedByString:@", "], type, name];
}

static NSString *DYYYMethodLine(Method m, BOOL isClassMethod) {
    SEL sel = method_getName(m);
    if (!sel) return nil;

    const char *ret = method_copyReturnType(m);
    NSString *retType = DYYYTypeFromEncoding(ret);
    if (ret) free((void *)ret);

    NSString *name = NSStringFromSelector(sel);
    if (name.length == 0) return nil;

    unsigned int argCount = method_getNumberOfArguments(m);
    if (![name containsString:@":"] || argCount <= 2) {
        return [NSString stringWithFormat:@"%c (%@)%@;", isClassMethod ? '+' : '-', retType, name];
    }

    NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
    NSMutableString *line = [NSMutableString stringWithFormat:@"%c (%@)", isClassMethod ? '+' : '-', retType];
    for (NSUInteger i = 0; i < parts.count - 1; i++) {
        NSString *label = parts[i];
        char *argTypeRaw = method_copyArgumentType(m, (unsigned int)i + 2);
        NSString *argType = DYYYTypeFromEncoding(argTypeRaw);
        if (argTypeRaw) free(argTypeRaw);
        if (i == 0) {
            [line appendFormat:@"%@:(%@)arg%lu", label.length ? label : @"method", argType, (unsigned long)i];
        } else {
            [line appendFormat:@" %@:(%@)arg%lu", label.length ? label : @"param", argType, (unsigned long)i];
        }
    }
    [line appendString:@";"];
    return line;
}

#pragma mark - 单类头文件

static NSString *DYYYHeaderForClass(Class cls, NSString *imageName) {
    if (!DYYYClassIsSafe(cls)) return nil;
    @try {
        NSString *className = NSStringFromClass(cls);
        if (className.length == 0) return nil;
        if (DYYYIsLikelySwiftName(className)) {
            return [NSString stringWithFormat:
                    @"// Runtime class: %@\n// Image: %@\n// 该名称不是有效的 Objective-C 标识符，无法生成头文件。\n",
                    className, imageName ?: @"Unknown"];
        }

        Class superCls = class_getSuperclass(cls);
        NSString *superName = superCls ? NSStringFromClass(superCls) : @"NSObject";

        NSMutableString *h = [NSMutableString string];
        [h appendString:@"//\n"];
        [h appendString:@"// Dumped by DYYY DYYYClassDump\n"];
        [h appendFormat:@"// Bundle: %@\n", NSBundle.mainBundle.bundleIdentifier ?: @"Unknown"];
        [h appendFormat:@"// Image: %@\n", imageName ?: @"Unknown"];
        [h appendString:@"//\n\n"];
        [h appendString:@"#import <Foundation/Foundation.h>\n"];
        [h appendString:@"#import <UIKit/UIKit.h>\n\n"];

        unsigned int protocolCount = 0;
        Protocol *__unsafe_unretained *protocols = class_copyProtocolList(cls, &protocolCount);
        NSMutableArray *protocolNames = [NSMutableArray array];
        for (unsigned int i = 0; i < protocolCount; i++) {
            const char *pn = protocol_getName(protocols[i]);
            if (pn) [protocolNames addObject:DYYYCString(pn)];
        }
        if (protocols) free(protocols);

        if (protocolNames.count) {
            [h appendFormat:@"@interface %@ : %@ <%@>\n\n", className, superName, [protocolNames componentsJoinedByString:@", "]];
        } else {
            [h appendFormat:@"@interface %@ : %@\n\n", className, superName];
        }

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        if (ivarCount > 0) [h appendString:@"{\n"];
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *in = ivar_getName(ivars[i]);
            const char *it = ivar_getTypeEncoding(ivars[i]);
            if (in) [h appendFormat:@"    %@ %@;\n", DYYYTypeFromEncoding(it), DYYYCString(in)];
        }
        if (ivarCount > 0) [h appendString:@"}\n\n"];
        if (ivars) free(ivars);

        unsigned int propertyCount = 0;
        objc_property_t *props = class_copyPropertyList(cls, &propertyCount);
        if (propertyCount > 0) [h appendString:@"#pragma mark - Properties\n\n"];
        for (unsigned int i = 0; i < propertyCount; i++) {
            NSString *line = DYYYPropertyLine(props[i]);
            if (line.length) [h appendFormat:@"%@\n", line];
        }
        if (props) free(props);

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        if (methodCount > 0) [h appendString:@"\n#pragma mark - Instance Methods\n\n"];
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *line = DYYYMethodLine(methods[i], NO);
            if (line.length) [h appendFormat:@"%@\n", line];
        }
        if (methods) free(methods);

        Class meta = object_getClass(cls);
        unsigned int classMethodCount = 0;
        Method *classMethods = class_copyMethodList(meta, &classMethodCount);
        if (classMethodCount > 0) [h appendString:@"\n#pragma mark - Class Methods\n\n"];
        for (unsigned int i = 0; i < classMethodCount; i++) {
            NSString *line = DYYYMethodLine(classMethods[i], YES);
            if (line.length) [h appendFormat:@"%@\n", line];
        }
        if (classMethods) free(classMethods);

        [h appendString:@"\n@end\n"];
        return h;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

#pragma mark - 对外 API

NSString *DYYYClassDumpHeaderForClass(Class cls) {
    if (!DYYYClassIsSafe(cls)) return nil;
    NSString *imageName = @"Unknown";
    const char *img = class_getImageName(cls);
    if (img) imageName = [DYYYCString(img) lastPathComponent] ?: @"Unknown";
    return DYYYHeaderForClass(cls, imageName);
}
