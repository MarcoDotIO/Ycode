/*
 * hidprobe: Ycode research probe (original Ycode code, no Apple code).
 * Loads the simulator HID client bundle named by argv[1] (default:
 * $SIMULATOR_HID_SYSTEM_MANAGER) as a bundle, reports its principal class and
 * whether it conforms to the manager protocol, then (in a forked child, with a
 * timeout) calls -initUsingHIDService:error: with a NULL event system and
 * prints the result and error. Run with dlsymtrace.dylib inserted to see the
 * Mach services the bundle contacts.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *p = argc > 1 ? argv[1] : getenv("SIMULATOR_HID_SYSTEM_MANAGER");
        if (!p) { printf("no path\n"); return 1; }
        NSBundle *b = [NSBundle bundleWithPath:@(p)];
        NSError *e = nil;
        BOOL ok = [b loadAndReturnError:&e];
        printf("bundle %s load=%d err=%s\n", p, ok, e ? e.description.UTF8String : "-");
        Class pc = b.principalClass;
        printf("principal class %s\n", pc ? class_getName(pc) : "(none)");
        Protocol *proto = objc_getProtocol("SimulatorClientHIDSystemManager");
        printf("conforms to SimulatorClientHIDSystemManager: %d\n", pc && proto ? class_conformsToProtocol(pc, proto) : -1);
        if (!pc) return 0;
        fflush(stdout);
        pid_t c = fork();
        if (c == 0) {
            alarm(5);
            NSError *err = nil;
            id obj = ((id (*)(id, SEL, void *, NSError **))objc_msgSend)([pc alloc],
                        sel_getUid("initUsingHIDService:error:"), NULL, &err);
            printf("initUsingHIDService:NULL -> %s err=%s\n", obj ? [[obj description] UTF8String] : "nil",
                   err ? err.description.UTF8String : "-");
            fflush(stdout);
            _exit(0);
        }
        int st = 0;
        waitpid(c, &st, 0);
        if (!WIFEXITED(st)) printf("child died, signal %d\n", WIFSIGNALED(st) ? WTERMSIG(st) : -1);
    }
    return 0;
}
