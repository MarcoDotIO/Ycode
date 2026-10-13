// miprobe: our own probe of how MobileInstallation's bundle model sees an app
// bundle (Ycode stage 9, agent J). Classes and selectors by name at run time.
//   miprobe <bundle path> [getter ...]   -> MIExecutableBundle -initWithBundleURL:error:, then getters
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static void show(id obj, const char *name) {
  SEL s = sel_registerName(name);
  Method m = class_getInstanceMethod(object_getClass(obj), s);
  if (!m) { printf("%-32s (no method)\n", name); return; }
  char rt[64]; method_getReturnType(m, rt, sizeof rt);
  unsigned nargs = method_getNumberOfArguments(m);
  if (nargs == 3) { // one NSError ** argument
    NSError *err = nil;
    if (rt[0] == '@') { id v = ((id (*)(id, SEL, NSError **))objc_msgSend)(obj, s, &err); printf("%-32s %s err=%s\n", name, [[v description] UTF8String], err ? [[err description] UTF8String] : "nil"); }
    else if (rt[0] == 'B') { BOOL v = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(obj, s, &err); printf("%-32s %d err=%s\n", name, v, err ? [[err description] UTF8String] : "nil"); }
    return;
  }
  if (nargs != 2) { printf("%-32s (takes arguments)\n", name); return; }
  switch (rt[0]) {
  case '@': { id v = ((id (*)(id, SEL))objc_msgSend)(obj, s); printf("%-32s %s\n", name, [[v description] UTF8String]); break; }
  case 'B': case 'c': { BOOL v = ((BOOL (*)(id, SEL))objc_msgSend)(obj, s); printf("%-32s %d\n", name, v); break; }
  case 'I': case 'i': { unsigned v = ((unsigned (*)(id, SEL))objc_msgSend)(obj, s); printf("%-32s %u (0x%x)\n", name, v, v); break; }
  case 'Q': case 'q': { unsigned long long v = ((unsigned long long (*)(id, SEL))objc_msgSend)(obj, s); printf("%-32s %llu (0x%llx)\n", name, v, v); break; }
  default: printf("%-32s (return type %s)\n", name, rt);
  }
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) return 64;
    if (!dlopen("/System/Library/PrivateFrameworks/MobileSystemServices.framework/MobileSystemServices", RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 1; }
    Class c = objc_getClass("MIExecutableBundle");
    NSError *err = nil;
    id b = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([c alloc], sel_registerName("initWithBundleURL:error:"), [NSURL fileURLWithPath:@(argv[1])], &err);
    printf("bundle %s err=%s\n", [[b description] UTF8String], err ? [[err description] UTF8String] : "nil");
    if (!b) return 2;
    static const char *defaults[] = { "isPlaceholder", "isPlaceholderStatusValid", "hasExecutable", "mayHaveExecutableProgram", "executableURL",
      "relativeExecutablePath", "maxLinkedSDKVersion", "sdkBuildVersion", "platformHint", "isAppTypeBundle", "bundleInfoPlistSupportedPlatforms",
      "executableImageSlicesWithError:", "executablePlatformsWithError:", "checkExecutableExistsIfRequiredWithError:", "identifier", "bundleType", 0 };
    if (argc > 2) for (int i = 2; i < argc; i++) show(b, argv[i]);
    else for (int i = 0; defaults[i]; i++) show(b, defaults[i]);
  }
  return 0;
}
