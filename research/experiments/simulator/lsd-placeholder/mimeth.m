// mimeth: lists methods of classes after dlopen-ing frameworks (names only).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
int main(int argc, char **argv) {
  @autoreleasepool {
    int i = 1;
    for (; i < argc && argv[i][0] == '/'; i++) if (!dlopen(argv[i], RTLD_NOW)) printf("dlopen %s: %s\n", argv[i], dlerror());
    for (; i < argc; i++) {
      if (argv[i][0] == '~') { // list classes with prefix
        unsigned n = 0; Class *cs = objc_copyClassList(&n);
        for (unsigned k = 0; k < n; k++) if (!strncmp(class_getName(cs[k]), argv[i] + 1, strlen(argv[i] + 1))) printf("class %s\n", class_getName(cs[k]));
        continue;
      }
      Class c = objc_getClass(argv[i]);
      if (!c) { printf("%s: no class\n", argv[i]); continue; }
      printf("%s : %s\n", argv[i], class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "-");
      for (int meta = 1; meta >= 0; meta--) {
        unsigned n = 0; Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
        for (unsigned k = 0; k < n; k++) printf("  %c%s %s\n", meta ? '+' : '-', sel_getName(method_getName(m[k])), method_getTypeEncoding(m[k]));
        free(m);
      }
    }
  }
  return 0;
}
