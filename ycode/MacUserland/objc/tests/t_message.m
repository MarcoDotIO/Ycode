// t_message.m - messaging conformance (specs/macos/objc-runtime.md §4, §5).
// Ycode's own test program: classes, super, class methods, +load,
// +initialize, categories, resolveInstanceMethod:, many and floating-point
// arguments through the slow path, struct returns, nil receivers,
// swizzling, runtime-added methods. Prints one line per check.
#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdio.h>
#include <string.h>

static int order = 0;

@interface Base : NSObject {
@public
    int value;
}
+ (int)classValue;
- (int)value;
- (int)twice;
- (double)scale:(double)f by:(float)g;
- (long)sum:(long)a :(long)b :(long)c :(long)d :(long)e :(long)f :(long)g :(long)h :(long)i :(long)j;
- (const char *)who;
@end

@implementation Base
+ (void)load { printf("load Base (%d)\n", ++order); }
+ (void)initialize { printf("initialize %s (self %s)\n", class_getName(self), class_getName(self)); }
+ (int)classValue { return 7; }
- (int)value { return value; }
- (int)twice { return [self value] * 2; }
- (double)scale:(double)f by:(float)g { return f * g + value; }
- (long)sum:(long)a :(long)b :(long)c :(long)d :(long)e :(long)f :(long)g :(long)h :(long)i :(long)j {
    return a + b + c + d + e + f + g + h + i + j;
}
- (const char *)who { return "Base"; }
@end

@interface Sub : Base
@end
@implementation Sub
+ (void)load { printf("load Sub (%d)\n", ++order); }
+ (int)classValue { return [super classValue] + 1; }
- (int)value { return [super value] + 100; }
- (const char *)who { return "Sub"; }
@end

@interface SubSub : Sub
@end
@implementation SubSub
- (const char *)who { return "SubSub"; }
@end

@interface Base (Extra)
- (const char *)extra;
- (const char *)who;
@end
@implementation Base (Extra)
+ (void)load { printf("load Base(Extra) (%d)\n", ++order); }
- (const char *)extra { return "extra"; }
@end

typedef struct { double x, y, z, w; } Vec4;   // returned in registers (HFA)
typedef struct { long a, b, c, d, e; } Big;   // returned through x8

@interface Shapes : NSObject
- (Vec4)vec:(double)s;
- (Big)big:(long)s;
@end
@implementation Shapes
- (Vec4)vec:(double)s { Vec4 v = { s, s * 2, s * 3, s * 4 }; return v; }
- (Big)big:(long)s { Big b = { s, s + 1, s + 2, s + 3, s + 4 }; return b; }
@end

static int dynamicIMP(id self, SEL _cmd, int x) { return x * 3; }

@interface Dynamic : NSObject
- (int)triple:(int)x;
@end
@implementation Dynamic
+ (BOOL)resolveInstanceMethod:(SEL)sel {
    if (sel == @selector(triple:)) {
        printf("resolveInstanceMethod: %s\n", sel_getName(sel));
        class_addMethod(self, sel, (IMP)dynamicIMP, "i20@0:8i16");
        return YES;
    }
    return [super resolveInstanceMethod:sel];
}
@end

@interface Swizzle : NSObject
- (int)a;
- (int)b;
@end
@implementation Swizzle
- (int)a { return 1; }
- (int)b { return 2; }
@end

int main(void) {
    printf("main\n");
    Sub *s = [[Sub alloc] init];
    s->value = 5;
    printf("value %d twice %d\n", [s value], [s twice]);
    printf("classValue Base %d Sub %d\n", [Base classValue], [Sub classValue]);
    SubSub *ss = [SubSub new];
    printf("who %s %s %s\n", [[Base new] who], [s who], [ss who]);
    printf("extra %s\n", [ss extra]);
    printf("scale %.2f\n", [s scale:1.5 by:2.0f]);
    printf("sum %ld\n", [s sum:1 :2 :3 :4 :5 :6 :7 :8 :9 :10]);
    for (int i = 0; i < 3; i++)   // cached path after the first
        printf("cached twice %d\n", [s twice]);

    Shapes *sh = [Shapes new];
    Vec4 v = [sh vec:1.25];
    Big b = [sh big:10];
    printf("vec %.2f %.2f %.2f %.2f big %ld %ld %ld %ld %ld\n", v.x, v.y, v.z, v.w, b.a, b.b, b.c, b.d, b.e);

    id nothing = nil;
    printf("nil int %d nil double %.1f nil ptr %p\n", [nothing twice], [nothing scale:2 by:3], (void *)[nothing who]);

    printf("isKindOfClass %d %d %d\n", [ss isKindOfClass:[Base class]], [s isKindOfClass:[SubSub class]], [Sub isKindOfClass:[NSObject class]]);
    printf("isMemberOfClass %d %d\n", [ss isMemberOfClass:[SubSub class]], [ss isMemberOfClass:[Sub class]]);
    printf("respondsToSelector %d %d %d\n", [s respondsToSelector:@selector(extra)], [s respondsToSelector:@selector(nope)],
           [Sub respondsToSelector:@selector(classValue)]);
    printf("instancesRespondToSelector %d\n", [Sub instancesRespondToSelector:@selector(twice)]);
    printf("class %s superclass %s meta %d\n", class_getName([ss class]), class_getName([ss superclass]),
           class_isMetaClass(object_getClass([SubSub class])));
    printf("performSelector %s\n", (const char *)(void *)[ss performSelector:@selector(who)]);

    Dynamic *d = [Dynamic new];
    printf("triple %d\n", [d triple:14]);
    printf("triple again %d\n", [d triple:2]);

    Swizzle *w = [Swizzle new];
    printf("before swizzle a %d b %d\n", [w a], [w b]);
    method_exchangeImplementations(class_getInstanceMethod([Swizzle class], @selector(a)),
                                   class_getInstanceMethod([Swizzle class], @selector(b)));
    printf("after swizzle a %d b %d\n", [w a], [w b]);
    IMP old = method_setImplementation(class_getInstanceMethod([Swizzle class], @selector(a)), (IMP)dynamicIMP);
    printf("setImplementation old==b-imp %d now %d\n", old == class_getMethodImplementation([Swizzle class], @selector(b)) ? 0 : 1,
           ((int (*)(id, SEL, int))objc_msgSend)(w, @selector(a), 5));

    struct objc_super sup = { s, [Base class] };
    printf("msgSendSuper value %d\n", ((int (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(value)));

    [s release];
    [ss release];
    [sh release];
    [d release];
    [w release];
    printf("done\n");
    return 0;
}
