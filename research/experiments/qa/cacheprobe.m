// cacheprobe: our own probe, public API only. Reports how framework
// executables that exist only in the dyld shared cache look to a simulator
// process: stat/lstat/access/open per path spelling, the public dyld query,
// CFBundle/NSBundle answers, and loaded image names.
// Build: xcrun -sdk iphonesimulator clang -fobjc-arc -framework Foundation \
//        -mios-simulator-version-min=27.0 cacheprobe.m -o cacheprobe
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;


static void probePath(const char *label, const char *p) {
    struct stat st; int r, e;
    printf("== %s: %s\n", label, p);
    errno = 0; r = stat(p, &st); e = errno;
    if (r == 0) printf("  stat ok mode=%06o size=%lld dev=%d ino=%llu uid=%u nlink=%u\n",
                       st.st_mode, (long long)st.st_size, st.st_dev, (unsigned long long)st.st_ino, st.st_uid, st.st_nlink);
    else printf("  stat -1 errno=%d (%s)\n", e, strerror(e));
    errno = 0; r = lstat(p, &st); e = errno;
    if (r == 0) printf("  lstat ok mode=%06o size=%lld dev=%d\n", st.st_mode, (long long)st.st_size, st.st_dev);
    else printf("  lstat -1 errno=%d (%s)\n", e, strerror(e));
    errno = 0; r = access(p, F_OK); e = errno; printf("  access F_OK %d errno=%d\n", r, r ? e : 0);
    errno = 0; r = access(p, X_OK); e = errno; printf("  access X_OK %d errno=%d\n", r, r ? e : 0);
    errno = 0; int fd = open(p, O_RDONLY); e = errno;
    if (fd >= 0) { printf("  open ok\n"); close(fd); } else printf("  open -1 errno=%d (%s)\n", e, strerror(e));
    char buf[1024]; ssize_t n = readlink(p, buf, sizeof buf - 1);
    if (n >= 0) { buf[n] = 0; printf("  readlink -> %s\n", buf); }
    char rp[PATH_MAX]; if (realpath(p, rp)) printf("  realpath -> %s\n", rp);
    printf("  _dyld_shared_cache_contains_path = %d\n", _dyld_shared_cache_contains_path(p));
}

int main(int argc, char **argv, char **envp, char **apple) {
    @autoreleasepool {
        if (argc == 1) for (char **e = envp; *e; e++) if (!strncmp(*e, "DYLD_", 5) || !strncmp(*e, "SIMULATOR_", 10) || !strncmp(*e, "IPHONE_", 7)) printf("env %s\n", *e);
        if (argc == 1) for (char **a = apple; *a; a++) printf("apple %s\n", *a);
        if (argc > 2 && !strcmp(argv[1], "--respawn-env")) {  // re-run self with VAR=VALUE replaced or added
            const char *assign = argv[2]; size_t klen = strchr(assign, '=') - assign + 1;
            int n = 0; for (char **e = environ; *e; e++) n++;
            char **env = calloc(n + 2, sizeof *env); int k = 0;
            for (char **e = environ; *e; e++) if (strncmp(*e, assign, klen)) env[k++] = *e;
            env[k++] = (char *)assign; env[k] = NULL;
            pid_t pid; int st = 0;
            const char *self = apple[0] && !strncmp(apple[0], "executable_path=", 16) ? apple[0] + 16 : argv[0];
            int r = posix_spawn(&pid, self, NULL, NULL, argv + 2, env);  // child argv[0] is the assignment; argv[1...] the rest
            if (r) { printf("posix_spawn failed %d\n", r); return 1; }
            waitpid(pid, &st, 0); printf("child status %d\n", st); return 0;
        }
        if (argc > 1 && strcmp(argv[1], "--full")) {  // query mode: report the public dyld answer for each argument
            printf("env DYLD_ROOT_PATH=%s\n", getenv("DYLD_ROOT_PATH") ?: "(unset)");
            for (int i = 1; i < argc; i++) printf("contains(%s) = %d\n", argv[i], _dyld_shared_cache_contains_path(argv[i]));
            return 0;
        }
        const char *rr = getenv("IPHONE_SIMULATOR_ROOT");
        if (!rr) rr = getenv("SIMULATOR_ROOT");
        printf("IPHONE_SIMULATOR_ROOT=%s\n", rr ? rr : "(unset)");
        printf("SIMULATOR_RUNTIME_VERSION=%s\n", getenv("SIMULATOR_RUNTIME_VERSION") ?: "(unset)");
        if (!rr) rr = "";
        const char *fws[] = {"WebKit", "JavaScriptCore", "UIKit", "Foundation", NULL};
        char p[2048];
        for (int i = 0; fws[i]; i++) {
            snprintf(p, sizeof p, "/System/Library/Frameworks/%s.framework/%s", fws[i], fws[i]); probePath("plain", p);
            snprintf(p, sizeof p, "%s/System/Library/Frameworks/%s.framework/%s", rr, fws[i], fws[i]); probePath("rooted", p);
            snprintf(p, sizeof p, "/System/Cryptexes/OS/System/Library/Frameworks/%s.framework/%s", fws[i], fws[i]); probePath("cryptex", p);
            snprintf(p, sizeof p, "%s/System/Cryptexes/OS/System/Library/Frameworks/%s.framework/%s", rr, fws[i], fws[i]); probePath("rooted-cryptex", p);
        }
        snprintf(p, sizeof p, "%s/System/Library/Frameworks/WebKit.framework", rr); probePath("rooted-bundle-dir", p);
        snprintf(p, sizeof p, "%s/System/Library/Frameworks/WebKit.framework/MacOS/WebKit", rr); probePath("rooted-macos-variant", p);
        snprintf(p, sizeof p, "%s/System/Library", rr); probePath("rooted-System-Library", p);
        snprintf(p, sizeof p, "%s", rr); probePath("runtime-root", p);
        snprintf(p, sizeof p, "%s/usr/lib/libSystem.B.dylib", rr); probePath("rooted-libSystem", p);

        void *h = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW);
        printf("dlopen plain WebKit -> %p %s\n", h, h ? "" : dlerror());

        CFBundleRef b = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.WebKit"));
        printf("CFBundleGetBundleWithIdentifier(com.apple.WebKit) -> %p\n", b);
        if (b) {
            CFURLRef bu = CFBundleCopyBundleURL(b);
            NSLog(@"  bundle URL: %@", (__bridge NSURL *)bu);
            CFURLRef eu = CFBundleCopyExecutableURL(b);
            NSLog(@"  CFBundleCopyExecutableURL: %@", (__bridge NSURL *)eu);
            void *fp = CFBundleGetFunctionPointerForName(b, CFSTR("WebContentServiceInitializer"));
            printf("  CFBundleGetFunctionPointerForName(WebContentServiceInitializer) -> %s\n", fp ? "non-NULL" : "NULL");
            fp = CFBundleGetFunctionPointerForName(b, CFSTR("NetworkServiceInitializer"));
            printf("  CFBundleGetFunctionPointerForName(NetworkServiceInitializer) -> %s\n", fp ? "non-NULL" : "NULL");
            printf("  CFBundleIsExecutableLoaded -> %d\n", CFBundleIsExecutableLoaded(b));
        }
        NSBundle *nb = [NSBundle bundleWithIdentifier:@"com.apple.WebKit"];
        NSLog(@"NSBundle(com.apple.WebKit) path=%@ executablePath=%@", nb.bundlePath, nb.executablePath);
        snprintf(p, sizeof p, "%s/System/Library/Frameworks/WebKit.framework", rr);
        CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)p, strlen(p), true);
        CFBundleRef b2 = CFBundleCreate(NULL, u);
        if (b2) { CFURLRef eu2 = CFBundleCopyExecutableURL(b2); NSLog(@"CFBundleCreate(rooted WebKit) exec URL: %@", (__bridge NSURL *)eu2); }
        NSBundle *jb = [NSBundle bundleWithIdentifier:@"com.apple.JavaScriptCore"];
        NSLog(@"NSBundle(com.apple.JavaScriptCore) path=%@ executablePath=%@", jb.bundlePath, jb.executablePath);
        NSBundle *ub = [NSBundle bundleWithIdentifier:@"com.apple.UIKit"];
        NSLog(@"NSBundle(com.apple.UIKit) path=%@ executablePath=%@", ub.bundlePath, ub.executablePath);

        uint32_t n = _dyld_image_count();
        printf("image count %u\n", n);
        for (uint32_t i = 0; i < n; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (i < 6 || strstr(nm, "WebKit") || strstr(nm, "JavaScriptCore") || strstr(nm, "UIKitCore") || strstr(nm, "libSystem.B") || strstr(nm, "CoreFoundation") || strstr(nm, "cacheprobe"))
                printf("  image[%u] %s\n", i, nm);
        }
        Dl_info di; if (h && dladdr(dlsym(h, "WebContentServiceInitializer") ?: (void*)CFBundleGetBundleWithIdentifier, &di)) printf("dladdr fname=%s\n", di.dli_fname);
    }
    return 0;
}
