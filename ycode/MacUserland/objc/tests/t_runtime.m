// t_runtime.m - objc/runtime.h introspection and class construction
// (specs/macos/objc-runtime.md §4): names, sizes, ivars and offsets,
// property attributes, protocols, method lists and type encodings,
// selectors, runtime-built classes, object_setClass, ivar sliding.
#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@protocol Named <NSObject>
- (const char *)name;
@optional
- (int)optionalThing;
@end
@protocol Greeter <Named>
+ (int)greeting;
@end

@interface Animal : NSObject <Greeter> {
    char flag;
    double weight;
    id owner;
}
@property (nonatomic, assign) int legs;
@property (atomic, strong, readonly) id friendObject;
@property (nonatomic, copy, getter=isLoud) id loud;
- (const char *)name;
- (void)speak:(int)times volume:(float)v;
@end
@implementation Animal
@synthesize friendObject;
+ (int)greeting { return 1; }
- (const char *)name { return "animal"; }
- (void)speak:(int)times volume:(float)v {}
@end

@interface Dog : Animal { long bones; }
@end
@implementation Dog
- (const char *)name { return "dog"; }
@end

static int cmpstr(const void *a, const void *b) { return strcmp(*(const char **)a, *(const char **)b); }

static void printMethods(Class c) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(c, &n);
    const char **names = malloc(sizeof(char *) * (n + 1));
    for (unsigned i = 0; i < n; i++) names[i] = sel_getName(method_getName(ms[i]));
    qsort(names, n, sizeof(char *), cmpstr);
    printf("%s%s methods (%u):", class_isMetaClass(c) ? "+" : "-", class_getName(c), n);
    for (unsigned i = 0; i < n; i++) printf(" %s", names[i]);
    printf("\n");
    free(names);
    free(ms);
}

static int magic(id self, SEL _cmd) { return 42; }

int main(void) {
    Class A = objc_getClass("Animal"), D = objc_getClass("Dog");
    printf("classes %s %s super %s meta-super %s\n", class_getName(A), class_getName(D), class_getName(class_getSuperclass(D)),
           class_getName(class_getSuperclass(object_getClass(D))));
    printf("lookUp missing %p getClass nil-name %s\n", (void *)objc_lookUpClass("NoSuchClass"), class_getName(Nil));
    printf("root meta isa self %d root meta super NSObject %d\n",
           object_getClass(object_getClass([NSObject class])) == object_getClass([NSObject class]),
           class_getSuperclass(object_getClass([NSObject class])) == [NSObject class]);
    printf("sizes NSObject %zu Animal %zu Dog %zu\n", class_getInstanceSize([NSObject class]), class_getInstanceSize(A),
           class_getInstanceSize(D));

    unsigned n = 0;
    Ivar *iv = class_copyIvarList(A, &n);
    for (unsigned i = 0; i < n; i++)
        printf("ivar %s %s @%td\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]), ivar_getOffset(iv[i]));
    free(iv);
    Ivar bones = class_getInstanceVariable(D, "bones");
    printf("Dog.bones @%td inherited weight %s\n", ivar_getOffset(bones), ivar_getName(class_getInstanceVariable(D, "weight")));

    objc_property_t *props = class_copyPropertyList(A, &n);
    const char **pn = malloc(sizeof(char *) * n);
    for (unsigned i = 0; i < n; i++) pn[i] = property_getName(props[i]);
    qsort(pn, n, sizeof(char *), cmpstr);
    for (unsigned i = 0; i < n; i++)
        printf("property %s %s\n", pn[i], property_getAttributes(class_getProperty(A, pn[i])));
    free(pn);
    free(props);
    objc_property_t legs = class_getProperty(D, "legs");
    unsigned na = 0;
    objc_property_attribute_t *attrs = property_copyAttributeList(legs, &na);
    for (unsigned i = 0; i < na; i++) printf("  attr %s=%s\n", attrs[i].name, attrs[i].value);
    free(attrs);
    char *v = property_copyAttributeValue(legs, "V");
    printf("  V=%s\n", v);
    free(v);

    Protocol *g = objc_getProtocol("Greeter"), *nm = objc_getProtocol("Named");
    printf("protocols %s %s conforms A %d D %d NSObject %d proto-proto %d\n", protocol_getName(g), protocol_getName(nm),
           class_conformsToProtocol(A, g), class_conformsToProtocol(D, g), [D conformsToProtocol:nm],
           protocol_conformsToProtocol(g, nm));
    struct objc_method_description d1 = protocol_getMethodDescription(nm, @selector(name), YES, YES);
    struct objc_method_description d2 = protocol_getMethodDescription(nm, @selector(optionalThing), NO, YES);
    struct objc_method_description d3 = protocol_getMethodDescription(g, @selector(greeting), YES, NO);
    printf("descriptions %s %s / %s %s / %s %s\n", sel_getName(d1.name), d1.types, sel_getName(d2.name), d2.types,
           sel_getName(d3.name), d3.types);

    printMethods(A);
    printMethods(object_getClass(A));
    printMethods(D);

    Method sp = class_getInstanceMethod(D, @selector(speak:volume:));
    char rt[32], at[32];
    method_getReturnType(sp, rt, sizeof rt);
    method_getArgumentType(sp, 3, at, sizeof at);
    char *a2 = method_copyArgumentType(sp, 2);
    printf("speak types %s args %u ret %s arg2 %s arg3 %s\n", method_getTypeEncoding(sp), method_getNumberOfArguments(sp), rt, a2, at);
    free(a2);

    SEL s1 = sel_registerName("dynamicSelector:with:");
    SEL s2 = sel_getUid("dynamicSelector:with:");
    printf("selectors equal %d name %s builtin %d\n", s1 == s2, sel_getName(s1), sel_registerName("name") == @selector(name));

    Class K = objc_allocateClassPair(D, "RuntimeDog", 0);
    printf("allocate twice nil %d\n", objc_allocateClassPair(D, "Dog", 0) == Nil);
    class_addIvar(K, "extraA", sizeof(int), 2, "i");
    class_addIvar(K, "extraB", sizeof(id), 3, "@");
    class_addMethod(K, @selector(magic), (IMP)magic, "i16@0:8");
    objc_registerClassPair(K);
    id k = [[K alloc] init];
    printf("runtime class %s size %zu extraB @%td magic %d name %s kind %d\n", object_getClassName(k), class_getInstanceSize(K),
           ivar_getOffset(class_getInstanceVariable(K, "extraB")), ((int (*)(id, SEL))objc_msgSend)(k, @selector(magic)),
           ((const char *(*)(id, SEL))objc_msgSend)(k, @selector(name)), [k isKindOfClass:A]);
    Ivar ib = class_getInstanceVariable(K, "extraB");
    object_setIvar(k, ib, (id)D);
    printf("object ivar roundtrip %d getClass by name %d\n", object_getIvar(k, ib) == (id)D, objc_getClass("RuntimeDog") == K);
    Class old = object_setClass(k, D);
    printf("setClass old %s now %s\n", class_getName(old), object_getClassName(k));
    [k release];

    printf("respondsTo replaced %d\n", class_respondsToSelector(K, @selector(magic)));
    IMP prev = class_replaceMethod(D, @selector(name), (IMP)magic, "i16@0:8");
    printf("replaceMethod prev %d new %d\n", prev != NULL, ((int (*)(id, SEL))objc_msgSend)([D new], @selector(name)));

    int count = objc_getClassList(NULL, 0);
    Class *all = malloc(sizeof(Class) * count);
    objc_getClassList(all, count);
    int seen = 0;
    for (int i = 0; i < count; i++)
        if (all[i] == A || all[i] == D || all[i] == K) seen++;
    printf("class list has ours %d\n", seen);
    free(all);
    printf("done\n");
    return 0;
}
