// icprobe: our own probe of MobileInstallation's installed-content gathering
// (Ycode stage 9, agent J): runs MILaunchServicesDatabaseGatherer by name and
// prints what the enumerator receives for bundles whose id matches argv[1].
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <malloc/malloc.h>
static id obj(void *p) { return p && ((uintptr_t)p & 0x8000000000000000ULL ? 1 : malloc_zone_from_ptr(p) != NULL) ? (__bridge id)p : nil; }
int main(int argc, char **argv) {
  @autoreleasepool {
    const char *filter = argc > 1 ? argv[1] : "AAUIViewService";
    unsigned long long opts = argc > 2 ? strtoull(argv[2], 0, 0) : 0;
    if (!dlopen("/System/Library/PrivateFrameworks/MobileSystemServices.framework/MobileSystemServices", RTLD_NOW)) { printf("dlopen: %s\n", dlerror()); return 1; }
    Class c = objc_getClass("MILaunchServicesDatabaseGatherer");
    __block int n = 0;
    id block = ^(void *pa, void *pb, void *pc) {
      n++;
      id a = obj(pa), b2 = obj(pb), c2 = obj(pc);
      NSString *d = [a description] ?: @"(nil)";
      if (n <= 3 && c2) printf("err: %s\n", [[c2 description] UTF8String]);
      if (n <= 2) printf("[%d] args %p %s | %p %s | %p %s\n", n, pa, a ? object_getClassName(a) : "-", pb, b2 ? object_getClassName(b2) : "-", pc, c2 ? object_getClassName(c2) : "-");
      if (strstr(d.UTF8String, filter)) {
        printf("[%d] %s\n%s\n", n, object_getClassName(a), d.UTF8String);
        for (NSString *sel in @[@"isPlaceholder", @"legacyRecordDictionary"]) {
          SEL s = NSSelectorFromString(sel);
          if (![a respondsToSelector:s]) continue;
          Method m = class_getInstanceMethod(object_getClass(a), s);
          char rt[8]; method_getReturnType(m, rt, 8);
          if (rt[0] == 'B') printf("  %s = %d\n", sel.UTF8String, ((BOOL (*)(id, SEL))objc_msgSend)(a, s));
          else printf("  %s = %s\n", sel.UTF8String, [[((id (*)(id, SEL))objc_msgSend)(a, s) description] UTF8String]);
        }
        { fflush(stdout); exit(0); }
      }
    };
    id g = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)([c alloc], sel_registerName("initWithOptions:enumerator:"), opts, block);
    NSError *err = nil;
    BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(g, sel_registerName("performGatherWithError:"), &err);
    printf("gather ok=%d records=%d err=%s\n", ok, n, err ? err.description.UTF8String : "nil");
  }
  return 0;
}
