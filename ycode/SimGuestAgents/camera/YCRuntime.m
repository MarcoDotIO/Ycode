// Runtime helpers of the guest capture layer, compiled without ARC
// (class_createInstance is not available under ARC). Public Objective-C
// runtime API only (objc/runtime.h, objc/message.h).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#if __has_feature(objc_arc)
#error "YCRuntime.m is compiled without ARC"
#endif

/// A new instance of `cls` without running any initializer: the capture
/// layer's subclasses of AVFoundation classes whose initializers are not
/// public. Returned retained.
id YCCreateInstance(Class cls) NS_RETURNS_RETAINED;
id YCCreateInstance(Class cls) { return class_createInstance(cls, 0); }

static void YCPlainDealloc(id self, SEL _cmd) {
    // NSObject's dealloc: the AVFoundation superclass's own teardown is
    // skipped (none of its state was ever set up).
    struct objc_super sup = {self, [NSObject class]};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
}

/// Makes `cls`'s instances deallocate as plain NSObjects.
void YCUsePlainDealloc(Class cls);
void YCUsePlainDealloc(Class cls) {
    class_addMethod(cls, sel_registerName("dealloc"), (IMP)YCPlainDealloc, "v@:");
}

/// Gives `cls` NSObject's key-value observing, equality and hash methods.
/// The public superclasses may implement these on top of their own private
/// state, which instances made without an initializer do not have; NSObject's
/// versions need none (observers are kept by Foundation, identity is the
/// pointer).
void YCUseNSObjectBasics(Class cls);
void YCUseNSObjectBasics(Class cls) {
    static const char *const names[] = {
        "willChangeValueForKey:", "didChangeValueForKey:",
        "willChange:valuesAtIndexes:forKey:", "didChange:valuesAtIndexes:forKey:",
        "willChangeValueForKey:withSetMutation:usingObjects:", "didChangeValueForKey:withSetMutation:usingObjects:",
        "addObserver:forKeyPath:options:context:", "removeObserver:forKeyPath:", "removeObserver:forKeyPath:context:",
        "observationInfo", "setObservationInfo:", "isEqual:", "hash",
    };
    Class base = [NSObject class];
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        SEL sel = sel_registerName(names[i]);
        Method m = class_getInstanceMethod(base, sel);
        if (m) class_addMethod(cls, sel, method_getImplementation(m), method_getTypeEncoding(m));
    }
}
