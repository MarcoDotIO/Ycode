// ylaunch: Ycode guest-side app install/launch helper (research probe, our own code).
//
// Runs inside the iOS simulator guest (xcrun simctl spawn <dev> /tmp/.../ylaunch ...).
// Links only Foundation and Security. Private interfaces are reached by name at
// run time (objc_getClass / dlsym), as an interop client. Calls are guarded with
// respondsToSelector: so a missing interface is reported, not crashed on.
// build.sh links ylaunch.entitlements into __TEXT,__entitlements; open-fbs needs it.
//
// Subcommands:
//   avail                          report which candidate classes/selectors/symbols exist
//   methods <Class> [filter]       list selector names and ObjC type encodings of a class (metadata only)
//   entcheck <entitlement>         SecTaskCopyValueForEntitlement on this process, by audit token
//   implementors <selector>        list classes whose instances implement a selector (metadata only)
//   symbol <framework> <name>      dlsym a string constant and print its value
//   install <path.app> [bundleid]  LSApplicationWorkspace installApplication:withOptions:error:
//   uninstall <bundleid>           LSApplicationWorkspace uninstallApplication:withOptions:
//   install-ix <path.app>          IXAppInstallCoordinator +installApplication:consumeSource:options:completion:
//                                  (options: MIInstallOptions from {PackageType=Developer};
//                                   YLAUNCH_PACKAGE_TYPE overrides the package type)
//   uninstall-ix <bundleid>        IXAppInstallCoordinator +uninstallAppWithBundleID:error:
//   lookup <bundleid>              LSApplicationProxy: installed? bundle + data container URLs
//   open-ls <bundleid>             LSApplicationWorkspace openApplicationWithBundleID:
//   open-fbs <bundleid> [--out P] [--err P] [--env K=V]... [--arg A]... [--wait]
//                                  FBSOpenApplicationService openApplication:withOptions:completion:
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <malloc/malloc.h>
#import <bsm/audit.h>
#import <mach/mach.h>

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void out(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stdout, "%s\n", s.UTF8String); fflush(stdout);
}

static void *openFramework(NSString *name) {
    NSArray *dirs = @[@"/System/Library/PrivateFrameworks", @"/System/Library/Frameworks"];
    for (NSString *d in dirs) {
        NSString *p = [NSString stringWithFormat:@"%@/%@.framework/%@", d, name, name];
        void *h = dlopen(p.fileSystemRepresentation, RTLD_NOW);
        if (h) return h;
    }
    return NULL;
}

static void loadAll(void) {
    for (NSString *f in @[@"MobileCoreServices", @"CoreServices", @"FrontBoardServices",
                          @"BaseBoard", @"MobileInstallation", @"InstallCoordination",
                          @"SpringBoardServices", @"RunningBoardServices"]) {
        void *h = openFramework(f);
        out(@"dlopen %@ -> %s", f, h ? "ok" : dlerror());
    }
}

static id call0(id target, const char *sel) {
    SEL s = sel_registerName(sel);
    if (![target respondsToSelector:s]) { out(@"  %s: not available on %@", sel, target); return nil; }
    return ((id (*)(id, SEL))objc_msgSend)(target, s);
}

static void avail(void) {
    struct { const char *cls; const char *sels[12]; } cands[] = {
        {"LSApplicationWorkspace", {"+defaultWorkspace", "installApplication:withOptions:error:",
            "installApplication:withOptions:error:usingBlock:", "uninstallApplication:withOptions:",
            "openApplicationWithBundleID:", "openURL:", "openSensitiveURL:withOptions:",
            "registerApplicationDictionary:", "registerBundleWithInfo:options:type:progress:", NULL}},
        {"LSApplicationProxy", {"+applicationProxyForIdentifier:", "bundleURL", "dataContainerURL",
            "isInstalled", NULL}},
        {"FBSOpenApplicationService", {"+serviceWithDefaultShellEndpoint", "+new",
            "openApplication:withOptions:completion:", "canOpenApplication:reason:", NULL}},
        {"FBSOpenApplicationOptions", {"+optionsWithDictionary:", "dictionary", NULL}},
        {"FBSSystemService", {"+sharedService", "openApplication:options:withResult:",
            "openApplication:options:clientPort:withResult:", "createClientPort", NULL}},
        {"IXAppInstallCoordinator", {NULL}},
    };
    for (size_t i = 0; i < sizeof cands / sizeof cands[0]; i++) {
        Class c = objc_getClass(cands[i].cls);
        out(@"class %s: %s", cands[i].cls, c ? "present" : "absent");
        if (!c) continue;
        for (int j = 0; cands[i].sels[j]; j++) {
            const char *n = cands[i].sels[j];
            BOOL meta = n[0] == '+';
            SEL s = sel_registerName(meta ? n + 1 : n);
            BOOL r = meta ? class_respondsToSelector(object_getClass(c), s)
                          : class_respondsToSelector(c, s);
            out(@"  %s %s", r ? "yes" : "no ", n);
        }
    }
    const char *syms[] = {"MobileInstallationInstall", "MobileInstallationInstallForLaunchServices",
        "MobileInstallationLookup", "MobileInstallationUninstall", NULL};
    for (int i = 0; syms[i]; i++)
        out(@"symbol %s: %s", syms[i], dlsym(RTLD_DEFAULT, syms[i]) ? "present" : "absent");
}

static void methods(const char *cls, const char *filter) {
    Class c = objc_getClass(cls);
    if (!c) { out(@"no class %s", cls); return; }
    for (int meta = 0; meta < 2; meta++) {
        unsigned n = 0;
        Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *name = sel_getName(method_getName(m[i]));
            if (!filter || strcasestr(name, filter)) out(@"%c%s  %s", meta ? '+' : '-', name, method_getTypeEncoding(m[i]));
        }
        free(m);
    }
}

static void implementors(const char *selName) {
    SEL sel = sel_registerName(selName);
    unsigned n = 0;
    Class *all = objc_copyClassList(&n);
    for (unsigned i = 0; i < n; i++) {
        unsigned mc = 0;
        Method *m = class_copyMethodList(all[i], &mc);   // own methods only, no +initialize
        for (unsigned j = 0; j < mc; j++)
            if (method_getName(m[j]) == sel) { out(@"%s (%s)", class_getName(all[i]), class_getImageName(all[i])); break; }
        free(m);
    }
    free(all);
}

// macOS public SecTask prototypes (the iOS SDK exports these but has no header).
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateWithAuditToken(CFAllocatorRef, audit_token_t);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef, CFStringRef, CFErrorRef *);

static int entcheck(const char *ent) {
    audit_token_t tok; mach_msg_type_number_t cnt = TASK_AUDIT_TOKEN_COUNT;
    if (task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&tok, &cnt)) { out(@"task_info failed"); return 2; }
    SecTaskRef t = SecTaskCreateWithAuditToken(NULL, tok);
    CFErrorRef e = NULL;
    CFTypeRef v = SecTaskCopyValueForEntitlement(t, (__bridge CFStringRef)@(ent), &e);
    out(@"entitlement %s = %@ error=%@", ent, (__bridge id)v, (__bridge id)e);
    return v ? 0 : 1;
}

static void symbol(const char *fw, const char *name) {
    openFramework([NSString stringWithUTF8String:fw]);
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p) { out(@"%s: absent", name); return; }
    id v = *(__unsafe_unretained id *)p;
    out(@"%s = %@", name, v);
}

static id workspace(void) {
    Class ws = objc_getClass("LSApplicationWorkspace");
    return ws ? call0(ws, "defaultWorkspace") : nil;
}

static int install(NSString *path, NSString *bid) {
    id ws = workspace();
    SEL s = sel_registerName("installApplication:withOptions:error:");
    if (![ws respondsToSelector:s]) { out(@"install: selector unavailable"); return 2; }
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (bid) opts[@"CFBundleIdentifier"] = bid;
    const char *pt = getenv("YLAUNCH_PACKAGE_TYPE");
    if (pt) opts[@"PackageType"] = [NSString stringWithUTF8String:pt];
    NSError *err = nil;
    NSDate *t0 = [NSDate date];
    BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(
        ws, s, [NSURL fileURLWithPath:path], opts, &err);
    out(@"install %@ options=%@ -> %d (%.3f s) error=%@", path, opts, ok,
        -[t0 timeIntervalSinceNow], err);
    return ok ? 0 : 1;
}

// Describe a block argument whose type we do not know: only dereference values
// that point into a malloc zone (heap objects); print everything else raw.
static NSString *describeArg(void *p) {
    if (!p) return @"nil";
    if (malloc_zone_from_ptr(p)) {
        id o = (__bridge id)p;
        return [NSString stringWithFormat:@"<%s> %@", object_getClassName(o), o];
    }
    return [NSString stringWithFormat:@"raw %p", p];
}

static int installIX(NSString *path) {
    Class ix = objc_getClass("IXAppInstallCoordinator");
    SEL s = sel_registerName("installApplication:consumeSource:options:completion:");
    if (!ix || !class_respondsToSelector(object_getClass(ix), s)) { out(@"install-ix: unavailable"); return 2; }
    const char *pt = getenv("YLAUNCH_PACKAGE_TYPE");
    // The options argument is an MIInstallOptions object (passing a plain dictionary
    // raises "unrecognized selector installTargetType"). Built from the legacy
    // options dictionary, the same keys the host bridge logs.
    NSDictionary *legacy = @{@"PackageType": pt ? @(pt) : @"Developer"};
    Class mio = objc_getClass("MIInstallOptions");
    id opts = ((id (*)(id, SEL, id))objc_msgSend)([mio alloc],
        sel_registerName("initWithLegacyOptionsDictionary:"), legacy);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block int rc = 1;
    NSDate *t0 = [NSDate date];
    void (^done)(void *, void *, void *) = ^(void *a, void *b, void *c) {
        out(@"completion after %.3f s: arg0=%@ arg1=%@", -[t0 timeIntervalSinceNow],
            describeArg(a), describeArg(b));
        rc = (a && malloc_zone_from_ptr(a) && [(__bridge id)a isKindOfClass:[NSError class]]) ? 1 : 0;
        dispatch_semaphore_signal(sem);
    };
    out(@"install-ix %@ options=%@", path, opts);
    ((void (*)(id, SEL, id, BOOL, id, id))objc_msgSend)(ix, s, [NSURL fileURLWithPath:path], NO, opts, done);
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC))) {
        out(@"install-ix: no completion within 120 s"); return 3;
    }
    return rc;
}

static int uninstallIX(NSString *bid) {
    Class ix = objc_getClass("IXAppInstallCoordinator");
    SEL s = sel_registerName("uninstallAppWithBundleID:error:");
    if (!ix || !class_respondsToSelector(object_getClass(ix), s)) { out(@"uninstall-ix: unavailable"); return 2; }
    NSError *err = nil;
    NSDate *t0 = [NSDate date];
    BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(ix, s, bid, &err);
    out(@"uninstall-ix %@ -> %d (%.3f s) error=%@", bid, ok, -[t0 timeIntervalSinceNow], err);
    return ok ? 0 : 1;
}

static int uninstall(NSString *bid) {
    id ws = workspace();
    SEL s = sel_registerName("uninstallApplication:withOptions:");
    if (![ws respondsToSelector:s]) { out(@"uninstall: selector unavailable"); return 2; }
    BOOL ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, s, bid, nil);
    out(@"uninstall %@ -> %d", bid, ok);
    return ok ? 0 : 1;
}

static int lookup(NSString *bid) {
    Class p = objc_getClass("LSApplicationProxy");
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(p, sel_registerName("applicationProxyForIdentifier:"), bid);
    out(@"proxy %@", proxy);
    if (!proxy) return 1;
    BOOL inst = ((BOOL (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("isInstalled"));
    out(@"  isInstalled=%d", inst);
    out(@"  bundleURL=%@", call0(proxy, "bundleURL"));
    out(@"  dataContainerURL=%@", call0(proxy, "dataContainerURL"));
    return inst ? 0 : 1;
}

static int openLS(NSString *bid) {
    id ws = workspace();
    SEL s = sel_registerName("openApplicationWithBundleID:");
    if (![ws respondsToSelector:s]) { out(@"open-ls: selector unavailable"); return 2; }
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, bid);
    out(@"openApplicationWithBundleID:%@ -> %d", bid, ok);
    return ok ? 0 : 1;
}

static NSString *strConst(const char *name, NSString *fallback) {
    void *p = dlsym(RTLD_DEFAULT, name);
    NSString *v = p ? *(__unsafe_unretained NSString **)p : nil;
    out(@"  key %s = %@%@", name, v ?: fallback, v ? @"" : @" (symbol absent; literal fallback)");
    return v ?: fallback;
}

static int openFBS(NSString *bid, NSString *outPath, NSString *errPath,
                   NSDictionary *env, NSArray *args, BOOL wait) {
    Class svcC = objc_getClass("FBSOpenApplicationService");
    Class optC = objc_getClass("FBSOpenApplicationOptions");
    if (!svcC || !optC) { out(@"open-fbs: classes absent"); return 2; }
    id svc = nil;
    if (class_respondsToSelector(object_getClass(svcC), sel_registerName("serviceWithDefaultShellEndpoint")))
        svc = call0(svcC, "serviceWithDefaultShellEndpoint");
    else
        svc = call0(svcC, "new");
    out(@"service %@", svc);

    NSMutableDictionary *dbg = [NSMutableDictionary dictionary];
    if (outPath) dbg[strConst("FBSDebugOptionKeyStandardOutPath", @"__StandardOutPath")] = outPath;
    if (errPath) dbg[strConst("FBSDebugOptionKeyStandardErrorPath", @"__StandardErrorPath")] = errPath;
    if (env.count) dbg[strConst("FBSDebugOptionKeyEnvironment", @"__Environment")] = env;
    if (args.count) dbg[strConst("FBSDebugOptionKeyArguments", @"__Arguments")] = args;
    if (wait) dbg[strConst("FBSDebugOptionKeyWaitForDebugger", @"__WaitForDebugger")] = @YES;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (dbg.count) d[strConst("FBSOpenApplicationOptionKeyDebuggingOptions", @"__DebugOptions")] = dbg;
    if (!getenv("YLAUNCH_NO_UNLOCK"))
        d[strConst("FBSOpenApplicationOptionKeyUnlockDevice", @"__UnlockDevice")] = @YES;
    if (getenv("YLAUNCH_SUSPENDED"))
        d[strConst("FBSOpenApplicationOptionKeyActivateSuspended", @"__ActivateSuspended")] = @YES;
    id opts = ((id (*)(id, SEL, id))objc_msgSend)(optC, sel_registerName("optionsWithDictionary:"), d);
    out(@"options %@", d);

    SEL s = sel_registerName("openApplication:withOptions:completion:");
    if (![svc respondsToSelector:s]) { out(@"open-fbs: selector unavailable"); return 2; }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block int rc = 1;
    NSDate *t0 = [NSDate date];
    void (^done)(id, NSError *) = ^(id process, NSError *error) {
        out(@"completion after %.3f s: process=%@ error=%@", -[t0 timeIntervalSinceNow], process, error);
        if (process && [process respondsToSelector:sel_registerName("pid")])
            out(@"  pid=%d", ((int (*)(id, SEL))objc_msgSend)(process, sel_registerName("pid")));
        rc = error ? 1 : 0;
        dispatch_semaphore_signal(sem);
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(svc, s, bid, opts, done);
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC))) {
        out(@"open-fbs: no completion within 60 s"); return 3;
    }
    return rc;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: see source header\n"); return 64; }
        loadAll();
        NSString *cmd = @(argv[1]);
        NSString *a2 = argc > 2 ? @(argv[2]) : nil;
        if ([cmd isEqual:@"avail"]) { avail(); return 0; }
        if ([cmd isEqual:@"methods"] && argc > 2) { methods(argv[2], argc > 3 ? argv[3] : NULL); return 0; }
        if ([cmd isEqual:@"entcheck"] && argc > 2) return entcheck(argv[2]);
        if ([cmd isEqual:@"implementors"] && argc > 2) { implementors(argv[2]); return 0; }
        if ([cmd isEqual:@"symbol"] && argc > 3) { symbol(argv[2], argv[3]); return 0; }
        if ([cmd isEqual:@"install"] && a2) return install(a2, argc > 3 ? @(argv[3]) : nil);
        if ([cmd isEqual:@"uninstall"] && a2) return uninstall(a2);
        if ([cmd isEqual:@"install-ix"] && a2) return installIX(a2);
        if ([cmd isEqual:@"uninstall-ix"] && a2) return uninstallIX(a2);
        if ([cmd isEqual:@"lookup"] && a2) return lookup(a2);
        if ([cmd isEqual:@"open-ls"] && a2) return openLS(a2);
        if ([cmd isEqual:@"open-fbs"] && a2) {
            NSString *o = nil, *e = nil; BOOL w = NO;
            NSMutableDictionary *env = [NSMutableDictionary dictionary];
            NSMutableArray *args = [NSMutableArray array];
            for (int i = 3; i < argc; i++) {
                if (!strcmp(argv[i], "--out") && i + 1 < argc) o = @(argv[++i]);
                else if (!strcmp(argv[i], "--err") && i + 1 < argc) e = @(argv[++i]);
                else if (!strcmp(argv[i], "--arg") && i + 1 < argc) [args addObject:@(argv[++i])];
                else if (!strcmp(argv[i], "--wait")) w = YES;
                else if (!strcmp(argv[i], "--env") && i + 1 < argc) {
                    NSString *kv = @(argv[++i]); NSRange r = [kv rangeOfString:@"="];
                    if (r.location != NSNotFound)
                        env[[kv substringToIndex:r.location]] = [kv substringFromIndex:r.location + 1];
                }
            }
            return openFBS(a2, o, e, env, args, w);
        }
        fprintf(stderr, "unknown command\n");
        return 64;
    }
}
