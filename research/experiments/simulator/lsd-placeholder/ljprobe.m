// ljprobe: our own probe (Ycode stage 9, agent J): asks launchd about pids
// through AppServerSupport's OSLaunchdJob (class and selectors by name):
// +copyJobWithPid:, -getCurrentJobInfo. Also by process name.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
static void ask(int pid) {
  Class c = objc_getClass("OSLaunchdJob");
  id job = ((id (*)(id, SEL, int))objc_msgSend)(c, sel_registerName("copyJobWithPid:"), pid);
  id info = job ? ((id (*)(id, SEL))objc_msgSend)(job, sel_registerName("getCurrentJobInfo")) : nil;
  printf("pid %d job %s\n  info %s\n", pid, [[job description] UTF8String], [[[info description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]);
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (!dlopen("/System/Library/PrivateFrameworks/AppServerSupport.framework/AppServerSupport", RTLD_NOW)) { printf("dlopen %s\n", dlerror()); return 1; }
    for (int i = 1; i < argc; i++) {
      if (argv[i][0] >= '0' && argv[i][0] <= '9') { ask(atoi(argv[i])); continue; }
      int pids[4096]; int n = proc_listallpids(pids, sizeof pids);
      for (int k = 0; k < n; k++) { char name[256] = ""; proc_name(pids[k], name, sizeof name); if (!strcmp(name, argv[i])) { ask(pids[k]); break; } }
    }
  }
  return 0;
}
