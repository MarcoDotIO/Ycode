// ylaunch: Ycode's guest-side app install/launch helper (stage7-contract.md
// §3.2 item 2; specs/simulator/app-install-launch.md §4, §6). It runs inside
// the guest as a one-shot of launchd_sim's control channel. It links only
// Foundation and reaches the runtime's private classes by name at run time,
// as an interop client; every selector is checked before use, so a missing
// interface is reported instead of crashing.
//
// The `com.apple.frontboard.debugapplications` entitlement (needed for an
// open request with debug options, §4.4) is linked into
// __TEXT,__entitlements by build-stage7.sh; the simulator reads entitlements
// from that section, not from the code signature (§4.5).
//
//   ylaunch install <path.app>     IXAppInstallCoordinator (waits YLAUNCH_INSTALL_SECONDS, default 300)
//                                  +installApplication:consumeSource:options:completion:
//                                  with MIInstallOptions {PackageType = Developer} (§4.1)
//   ylaunch uninstall <bundle id>  IXAppInstallCoordinator +uninstallAppWithBundleID:error: (§4.2)
//   ylaunch lookup <bundle id>     LSApplicationProxy: installed? container URLs (§4.3)
//   ylaunch open <bundle id> [--stdout P] [--stderr P] [--arg A]... [--env K=V]...
//                                  FBSOpenApplicationService
//                                  -openApplication:withOptions:completion: with
//                                  __DebugOptions (§4.4). Retries failures for up to
//                                  YLAUNCH_RETRY_SECONDS (default 120, §6 item 3);
//                                  a completion with no process is a failure (§3.4).
//
// Output: one line per result on stdout, each starting "ylaunch: ":
//   "ylaunch: installed <bundle id>", "ylaunch: uninstalled <bundle id>",
//   "ylaunch: lookup <id> installed=<0|1> bundle=<url> data=<url>",
//   "ylaunch: launched <bundle id> pid <n>", or "ylaunch: error <text>".
// Exit status 0 on success, 1 on failure, 2 when an interface is missing,
// 3 on a timeout, 64 on a usage error.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <malloc/malloc.h>

static void say(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stdout, "ylaunch: %s\n", s.UTF8String);
    fflush(stdout);
}

static void loadFramework(NSString *name) {
    for (NSString *dir in @[@"/System/Library/PrivateFrameworks", @"/System/Library/Frameworks"]) {
        NSString *path = [NSString stringWithFormat:@"%@/%@.framework/%@", dir, name, name];
        if (dlopen(path.fileSystemRepresentation, RTLD_NOW)) return;
    }
}

static BOOL classResponds(Class c, const char *sel) {
    return c && class_respondsToSelector(object_getClass(c), sel_registerName(sel));
}

// A block argument whose type is not declared: dereferenced only when it
// points into a malloc zone (a heap object).
static id heapObject(void *p) {
    return (p && malloc_zone_from_ptr(p)) ? (__bridge id)p : nil;
}

static int install(NSString *path) {
    loadFramework(@"InstallCoordination");
    loadFramework(@"MobileInstallation");
    Class ix = objc_getClass("IXAppInstallCoordinator");
    Class mio = objc_getClass("MIInstallOptions");
    const char *selName = "installApplication:consumeSource:options:completion:";
    if (!classResponds(ix, selName) || !mio) { say(@"error install interface unavailable"); return 2; }
    // The options must be an MIInstallOptions (a plain dictionary is refused).
    id options = ((id (*)(id, SEL, id))objc_msgSend)([mio alloc], sel_registerName("initWithLegacyOptionsDictionary:"),
                                                      @{@"PackageType": @"Developer"});
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int status = 1;
    void (^completion)(void *, void *) = ^(void *first, void *second) {
        id a = heapObject(first), b = heapObject(second);
        if ([a isKindOfClass:[NSString class]] && !b) {
            say(@"installed %@", a);
            status = 0;
        } else {
            say(@"error install completion: %@ %@", a ?: @"nil", b ?: @"nil");
        }
        dispatch_semaphore_signal(done);
    };
    ((void (*)(id, SEL, id, BOOL, id, id))objc_msgSend)(ix, sel_registerName(selName),
                                                        [NSURL fileURLWithPath:path], NO, options, completion);
    // YLAUNCH_INSTALL_SECONDS (default 300): an install on a slow host
    // (the Thor under Ycode) takes several minutes.
    const char *installText = getenv("YLAUNCH_INSTALL_SECONDS");
    long installSeconds = installText ? atol(installText) : 300;
    if (installSeconds <= 0) installSeconds = 300;
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)installSeconds * (int64_t)NSEC_PER_SEC))) {
        say(@"error install: no completion within %ld s", installSeconds);
        return 3;
    }
    return status;
}

static int uninstall(NSString *bundleID) {
    loadFramework(@"InstallCoordination");
    Class ix = objc_getClass("IXAppInstallCoordinator");
    const char *selName = "uninstallAppWithBundleID:error:";
    if (!classResponds(ix, selName)) { say(@"error uninstall interface unavailable"); return 2; }
    NSError *error = nil;
    BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(ix, sel_registerName(selName), bundleID, &error);
    if (ok) say(@"uninstalled %@", bundleID); else say(@"error uninstall %@: %@", bundleID, error);
    return ok ? 0 : 1;
}

static id send0(id target, const char *sel) {
    SEL s = sel_registerName(sel);
    return [target respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(target, s) : nil;
}

static int lookup(NSString *bundleID) {
    loadFramework(@"MobileCoreServices");
    Class proxyClass = objc_getClass("LSApplicationProxy");
    if (!classResponds(proxyClass, "applicationProxyForIdentifier:")) { say(@"error lookup interface unavailable"); return 2; }
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, sel_registerName("applicationProxyForIdentifier:"), bundleID);
    SEL installedSel = sel_registerName("isInstalled");
    BOOL installed = [proxy respondsToSelector:installedSel] && ((BOOL (*)(id, SEL))objc_msgSend)(proxy, installedSel);
    say(@"lookup %@ installed=%d bundle=%@ data=%@", bundleID, installed, send0(proxy, "bundleURL"),
        send0(proxy, "dataContainerURL"));
    return installed ? 0 : 1;
}

// An exported FrontBoardServices string constant, or the literal it is
// documented to hold (app-install-launch.md §4.4).
static NSString *key(const char *symbol, NSString *literal) {
    void *p = dlsym(RTLD_DEFAULT, symbol);
    NSString *value = p ? *(__unsafe_unretained NSString **)p : nil;
    return value ?: literal;
}

static int openOnce(id service, NSString *bundleID, id options, NSString **failure) {
    SEL s = sel_registerName("openApplication:withOptions:completion:");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int pid = 0;
    __block NSString *problem = nil;
    void (^completion)(id, NSError *) = ^(id process, NSError *error) {
        SEL pidSel = sel_registerName("pid");
        if (process && [process respondsToSelector:pidSel]) pid = ((int (*)(id, SEL))objc_msgSend)(process, pidSel);
        if (error) problem = [NSString stringWithFormat:@"%@", error];
        else if (pid <= 0) problem = @"the open request completed with no process";
        dispatch_semaphore_signal(done);
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, s, bundleID, options, completion);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC))) {
        *failure = @"no completion within 60 s";
        return -1;
    }
    *failure = problem;
    return problem ? -1 : pid;
}

static int openApp(NSString *bundleID, NSString *outPath, NSString *errPath, NSArray *arguments, NSDictionary *environment) {
    loadFramework(@"FrontBoardServices");
    Class serviceClass = objc_getClass("FBSOpenApplicationService");
    Class optionsClass = objc_getClass("FBSOpenApplicationOptions");
    if (!classResponds(serviceClass, "serviceWithDefaultShellEndpoint") || !classResponds(optionsClass, "optionsWithDictionary:")) {
        say(@"error open interface unavailable");
        return 2;
    }
    id service = send0(serviceClass, "serviceWithDefaultShellEndpoint");
    if (![service respondsToSelector:sel_registerName("openApplication:withOptions:completion:")]) {
        say(@"error open interface unavailable");
        return 2;
    }
    NSMutableDictionary *debug = [NSMutableDictionary dictionary];
    if (outPath) debug[key("FBSDebugOptionKeyStandardOutPath", @"__StandardOutPath")] = outPath;
    if (errPath) debug[key("FBSDebugOptionKeyStandardErrorPath", @"__StandardErrorPath")] = errPath;
    if (arguments.count) debug[key("FBSDebugOptionKeyArguments", @"__Arguments")] = arguments;
    if (environment.count) debug[key("FBSDebugOptionKeyEnvironment", @"__Environment")] = environment;
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    if (debug.count) dictionary[key("FBSOpenApplicationOptionKeyDebuggingOptions", @"__DebugOptions")] = debug;
    id options = ((id (*)(id, SEL, id))objc_msgSend)(optionsClass, sel_registerName("optionsWithDictionary:"), dictionary);

    const char *retryText = getenv("YLAUNCH_RETRY_SECONDS");
    double retry = retryText ? atof(retryText) : 120;
    NSDate *start = [NSDate date];
    for (int attempt = 1;; attempt++) {
        NSString *failure = nil;
        int pid = openOnce(service, bundleID, options, &failure);
        if (pid > 0) {
            say(@"launched %@ pid %d", bundleID, pid);
            return 0;
        }
        if (-[start timeIntervalSinceNow] + 2 > retry) {
            say(@"error open %@ (attempt %d): %@", bundleID, attempt, failure);
            return 1;
        }
        fprintf(stdout, "ylaunch: retrying open %s (attempt %d): %s\n", bundleID.UTF8String, attempt, failure.UTF8String);
        fflush(stdout);
        [NSThread sleepForTimeInterval:2];
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: ylaunch install <path.app> | uninstall <id> | lookup <id> |\n"
                            "       open <id> [--stdout P] [--stderr P] [--arg A]... [--env K=V]...\n");
            return 64;
        }
        NSString *command = @(argv[1]), *operand = @(argv[2]);
        if ([command isEqual:@"install"]) return install(operand);
        if ([command isEqual:@"uninstall"]) return uninstall(operand);
        if ([command isEqual:@"lookup"]) return lookup(operand);
        if ([command isEqual:@"open"]) {
            NSString *outPath = nil, *errPath = nil;
            NSMutableArray *arguments = [NSMutableArray array];
            NSMutableDictionary *environment = [NSMutableDictionary dictionary];
            for (int i = 3; i < argc; i++) {
                if (!strcmp(argv[i], "--stdout") && i + 1 < argc) outPath = @(argv[++i]);
                else if (!strcmp(argv[i], "--stderr") && i + 1 < argc) errPath = @(argv[++i]);
                else if (!strcmp(argv[i], "--arg") && i + 1 < argc) [arguments addObject:@(argv[++i])];
                else if (!strcmp(argv[i], "--env") && i + 1 < argc) {
                    NSString *pair = @(argv[++i]);
                    NSRange eq = [pair rangeOfString:@"="];
                    if (eq.location == NSNotFound || eq.location == 0) { say(@"error bad --env %@", pair); return 64; }
                    environment[[pair substringToIndex:eq.location]] = [pair substringFromIndex:eq.location + 1];
                } else {
                    say(@"error unknown option %s", argv[i]);
                    return 64;
                }
            }
            return openApp(operand, outPath, errPath, arguments, environment);
        }
        say(@"error unknown command %@", command);
        return 64;
    }
}
