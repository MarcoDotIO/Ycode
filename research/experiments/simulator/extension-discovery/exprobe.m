// exprobe: our own probe of app-extension discovery in the iOS simulator
// runtime (Ycode stage 7/8 bring-up). Classes and selectors are found by
// name at run time (objc_getClass, respondsToSelector:); nothing is linked
// privately.
//   exprobe methods <Class>...   list class and instance selectors (names, type encodings)
//   exprobe plugins [filter]     LSApplicationWorkspace -installedPlugins: count, identifiers
//   exprobe points [filter]      extension point records known to LaunchServices
//   exprobe appex [filter] [point] app-extension records (all, or of one extension point)
//   exprobe record <bundle id>   one app-extension record
//   exprobe app <bundle id>      one application record (platform, SDK)
//   exprobe macho <path>         slices and LC_BUILD_VERSION through mach-o/utils.h
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/utils.h>
#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>

// dyld's platform SPI as declared in Apple's open-source dyld (include/mach-o/dyld_priv.h).
extern uint32_t dyld_get_active_platform(void);
extern uint32_t dyld_get_base_platform(uint32_t platform);
extern bool dyld_is_simulator_platform(uint32_t platform);
extern uint32_t dyld_get_sdk_version(const struct mach_header *mh);
extern void dyld_get_image_versions(const struct mach_header *mh, void (^callback)(uint32_t platform, uint32_t sdk, uint32_t minos));

// -init… through objc_msgSend under ARC: the receiver is consumed and the
// result is returned retained (as for a direct -init call).
typedef id (*InitWithIDError)(__attribute__((ns_consumed)) id, SEL, id, NSError **) __attribute__((ns_returns_retained));

static void listMethods(const char *name) {
    Class c = objc_getClass(name);
    if (!c) { printf("%s: no such class\n", name); return; }
    for (int meta = 1; meta >= 0; meta--) {
        unsigned n = 0;
        Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
        for (unsigned i = 0; i < n; i++)
            printf("%s %c[%s %s] %s\n", name, meta ? '+' : '-', name, sel_getName(method_getName(m[i])),
                   method_getTypeEncoding(m[i]));
        free(m);
    }
}

static id call0(id target, const char *sel) {
    SEL s = sel_registerName(sel);
    if (![target respondsToSelector:s]) { printf("  (%s does not answer %s)\n", object_getClassName(target), sel); return nil; }
    return ((id (*)(id, SEL))objc_msgSend)(target, s);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: exprobe methods|plugins|points ...\n"); return 64; }
        NSString *mode = @(argv[1]);
        NSString *filter = argc > 2 ? @(argv[2]) : nil;
        if ([mode isEqual:@"methods"]) {
            for (int i = 2; i < argc; i++) listMethods(argv[i]);
            return 0;
        }
        if ([mode isEqual:@"plugins"]) {
            id ws = call0((id)objc_getClass("LSApplicationWorkspace"), "defaultWorkspace");
            NSArray *plugins = call0(ws, "installedPlugins");
            printf("installedPlugins: %lu\n", (unsigned long)plugins.count);
            for (id p in plugins) {
                NSString *ident = call0(p, "pluginIdentifier");
                NSString *point = [p respondsToSelector:sel_registerName("protocol")] ? call0(p, "protocol") : nil;
                if (filter && ![ident containsString:filter] && ![point containsString:filter]) continue;
                printf("  %s  point=%s\n", ident.UTF8String, point.description.UTF8String);
            }
            return 0;
        }
        if ([mode isEqual:@"points"]) {
            id e = call0((id)objc_getClass("LSExtensionPointRecord"), "enumerator");
            unsigned long n = 0;
            for (id r in e) {
                n++;
                NSString *ident = call0(r, "identifier");
                if (filter && ![ident containsString:filter]) continue;
                printf("  point %s platform=%u\n", ident.UTF8String,
                       ((unsigned (*)(id, SEL))objc_msgSend)(r, sel_registerName("platform")));
            }
            printf("extension points: %lu\n", n);
            return 0;
        }
        if ([mode isEqual:@"appex"]) {
            // All app-extension records, or those of one extension point (argv[3]).
            Class rc = objc_getClass("LSApplicationExtensionRecord");
            id e;
            if (argc > 3) {
                NSError *err = nil;
                id point = ((InitWithIDError)objc_msgSend)([objc_getClass("LSExtensionPointRecord") alloc],
                    sel_registerName("initWithIdentifier:error:"), @(argv[3]), &err);
                printf("point %s: %s\n", argv[3], point ? "found" : err.description.UTF8String);
                if (!point) return 1;
                e = ((id (*)(id, SEL, id, unsigned long))objc_msgSend)(rc, sel_registerName("enumeratorWithExtensionPointRecord:options:"), point, 0);
            } else {
                e = ((id (*)(id, SEL, unsigned long))objc_msgSend)(rc, sel_registerName("enumeratorWithOptions:"), 0);
            }
            unsigned long n = 0;
            for (id r in e) {
                n++;
                NSString *ident = call0(r, "bundleIdentifier");
                id point = call0(r, "extensionPointRecord");
                NSString *pid = point ? call0(point, "identifier") : nil;
                if (filter.length && ![ident containsString:filter] && ![pid containsString:filter]) continue;
                unsigned platform = ((unsigned (*)(id, SEL))objc_msgSend)(r, sel_registerName("platform"));
                printf("  appex %s point=%s platform=%u SDK=%s\n", ident.UTF8String, pid.UTF8String, platform,
                       [[call0(r, "SDKVersion") description] UTF8String]);
            }
            printf("app extensions: %lu\n", n);
            return 0;
        }
        if ([mode isEqual:@"macho"]) {
            // Public dyld API (mach-o/utils.h): every slice, then the best one; LC_BUILD_VERSION of each.
            void (^show)(const struct mach_header *, uint64_t, size_t) = ^(const struct mach_header *mh, uint64_t off, size_t size) {
                printf("  slice cputype=0x%x filetype=%u ncmds=%u offset=%llu size=%zu", mh->cputype, mh->filetype, mh->ncmds,
                       (unsigned long long)off, size);
                const uint8_t *p = (const uint8_t *)mh + (mh->magic == MH_MAGIC_64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
                for (uint32_t i = 0; i < mh->ncmds; i++) {
                    const struct load_command *lc = (const struct load_command *)p;
                    if (lc->cmd == LC_BUILD_VERSION) {
                        const struct build_version_command *bv = (const void *)lc;
                        printf(" platform=%u minos=0x%x sdk=0x%x", bv->platform, bv->minos, bv->sdk);
                    }
                    p += lc->cmdsize;
                }
                printf("\n");
            };
            int r1 = macho_for_each_slice(argv[2], ^(const struct mach_header *mh, uint64_t off, size_t size, bool *stop) { show(mh, off, size); });
            printf("macho_for_each_slice: %d\n", r1);
            int r2 = macho_best_slice(argv[2], ^(const struct mach_header *mh, uint64_t off, size_t size) { show(mh, off, size); });
            printf("macho_best_slice: %d\n", r2);
            return 0;
        }
        if ([mode isEqual:@"register"]) {
            // LSApplicationWorkspace -registerApplication: with a bundle URL (argv[2]); then the record again.
            id ws = call0((id)objc_getClass("LSApplicationWorkspace"), "defaultWorkspace");
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("registerApplication:"), [NSURL fileURLWithPath:@(argv[2])]);
            printf("registerApplication: %s\n", ok ? "YES" : "NO");
            return ok ? 0 : 1;
        }
        if ([mode isEqual:@"dyldplat"]) {
            // dyld's view of platforms: this process, and an executable read into memory (argv[2]).
            uint32_t active = dyld_get_active_platform();
            printf("active platform %u base %u simulator %d\n", active, dyld_get_base_platform(active), dyld_is_simulator_platform(active));
            dyld_get_image_versions(_dyld_get_image_header(0), ^(uint32_t p, uint32_t sdk, uint32_t minos) {
                printf("  main image: platform %u sdk 0x%x minos 0x%x\n", p, sdk, minos);
            });
            if (argc > 2) {
                NSData *d = [NSData dataWithContentsOfFile:@(argv[2])];
                if (d.length < 4096) { printf("cannot read %s\n", argv[2]); return 1; }
                const struct mach_header *mh = d.bytes;
                printf("  file sdk via dyld_get_sdk_version: 0x%x\n", dyld_get_sdk_version(mh));
                __block int n = 0;
                dyld_get_image_versions(mh, ^(uint32_t p, uint32_t sdk, uint32_t minos) {
                    n++;
                    printf("  file: platform %u sdk 0x%x minos 0x%x\n", p, sdk, minos);
                });
                printf("  file callbacks: %d\n", n);
            }
            return 0;
        }
        if ([mode isEqual:@"mmapplat"]) {
            // The file mapped as a loader would (read-only, MAP_PRIVATE | MAP_RESILIENT_CODESIGN), then dyld's view of it.
            int fd = open(argv[2], O_RDONLY | O_NOFOLLOW);
            struct stat st;
            if (fd < 0 || fstat(fd, &st) != 0) { printf("open/fstat failed: %d\n", errno); return 1; }
            for (int flags = 0; flags < 2; flags++) {
                int mflags = MAP_PRIVATE | (flags ? MAP_RESILIENT_CODESIGN : 0);
                void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, mflags, fd, 0);
                if (p == MAP_FAILED) { printf("mmap flags 0x%x failed: %d\n", mflags, errno); continue; }
                const struct mach_header_64 *mh = p;
                printf("mmap flags 0x%x: magic 0x%x ncmds %u sizeofcmds %u\n", mflags, mh->magic, mh->ncmds, mh->sizeofcmds);
                dyld_get_image_versions(p, ^(uint32_t pl, uint32_t sdk, uint32_t minos) {
                    printf("  platform %u sdk 0x%x minos 0x%x\n", pl, sdk, minos);
                });
                munmap(p, (size_t)st.st_size);
            }
            close(fd);
            return 0;
        }
        if ([mode isEqual:@"app"]) {
            NSError *err = nil;
            typedef id (*InitAppFn)(__attribute__((ns_consumed)) id, SEL, id, BOOL, NSError **) __attribute__((ns_returns_retained));
            id r = ((InitAppFn)objc_msgSend)([objc_getClass("LSApplicationRecord") alloc],
                sel_registerName("initWithBundleIdentifier:allowPlaceholder:error:"), filter, YES, &err);
            if (!r) { printf("app %s: %s\n", filter.UTF8String, err.description.UTF8String); return 1; }
            printf("app %s: platform=%u SDK=%s exec=%s\n", filter.UTF8String,
                   ((unsigned (*)(id, SEL))objc_msgSend)(r, sel_registerName("platform")),
                   [[call0(r, "SDKVersion") description] UTF8String], [[call0(r, "executableURL") path] UTF8String]);
            #define B(sel) ((BOOL (*)(id, SEL))objc_msgSend)(r, sel_registerName(sel))
            #define Q(sel) ((unsigned long long (*)(id, SEL))objc_msgSend)(r, sel_registerName(sel))
            printf("  isPlaceholder=%d isSystemPlaceholder=%d installType=%llu compatibilityState=%llu placeholderFailureReason=%llu rawBundleFlags=0x%llx\n",
                   B("isPlaceholder"), B("isSystemPlaceholder"), Q("installType"), Q("compatibilityState"),
                   Q("placeholderFailureReason"), Q("_rawBundleFlags"));
            id ents = call0(r, "entitlements");
            SEL allKeys = sel_registerName("allKeys");
            NSUInteger entCount = [ents respondsToSelector:allKeys] ? [((id (*)(id, SEL))objc_msgSend)(ents, allKeys) count] : 0;
            printf("  signerIdentity=%s signerOrganization=%s appleInternal=%d entitlements=%lu teamID=%s\n",
                   [[call0(r, "signerIdentity") description] UTF8String], [[call0(r, "signerOrganization") description] UTF8String],
                   B("isAppleInternal"), (unsigned long)entCount,
                   [r respondsToSelector:sel_registerName("teamIdentifier")] ? [[call0(r, "teamIdentifier") description] UTF8String] : "?");
            printf("  typeForInstallMachinery=%s applicationState=%s\n", [[call0(r, "typeForInstallMachinery") description] UTF8String],
                   [[call0(r, "applicationState") description] UTF8String]);
            return 0;
        }
        if ([mode isEqual:@"record"]) {
            NSError *err = nil;
            id r = ((InitWithIDError)objc_msgSend)([objc_getClass("LSApplicationExtensionRecord") alloc],
                sel_registerName("initWithBundleIdentifier:error:"), filter, &err);
            if (!r) { printf("record %s: %s\n", filter.UTF8String, err.description.UTF8String); return 1; }
            id point = call0(r, "extensionPointRecord");
            NSString *pid = point ? call0(point, "identifier") : @"(none)";
            unsigned platform = ((unsigned (*)(id, SEL))objc_msgSend)(r, sel_registerName("platform"));
            printf("record %s: point=%s platform=%u SDK=%s\n  url=%s\n  exec=%s\n", filter.UTF8String,
                   pid.UTF8String, platform, [[call0(r, "SDKVersion") description] UTF8String],
                   [[call0(r, "URL") description] UTF8String],
                   [[call0(r, "executableURL") description] UTF8String]);
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[call0(r, "URL") URLByAppendingPathComponent:@"Info.plist"]];
            printf("  EXAppExtensionAttributes=%s\n  NSExtension=%s\n", [[info[@"EXAppExtensionAttributes"] description] UTF8String],
                   [[info[@"NSExtension"] description] UTF8String]);
            id stored = call0(r, "infoDictionary");
            SEL ofClass = sel_registerName("objectForKey:ofClass:");
            if (stored && [stored respondsToSelector:ofClass]) {
                id attrs = ((id (*)(id, SEL, id, Class))objc_msgSend)(stored, ofClass, @"EXAppExtensionAttributes", [NSDictionary class]);
                id ns = ((id (*)(id, SEL, id, Class))objc_msgSend)(stored, ofClass, @"NSExtension", [NSDictionary class]);
                printf("  stored EXAppExtensionAttributes=%s\n  stored NSExtension=%s\n", [[attrs description] UTF8String],
                       [[ns description] UTF8String]);
            }
            printf("  pluginFlags=%llu\n", (unsigned long long)((unsigned long long (*)(id, SEL))objc_msgSend)(r, sel_registerName("pluginFlags")));
            if (point) {
                printf("  point platform=%u version=%s\n", ((unsigned (*)(id, SEL))objc_msgSend)(point, sel_registerName("platform")),
                       [[call0(point, "version") description] UTF8String]);
            }
            return 0;
        }
        fprintf(stderr, "unknown mode\n");
        return 64;
    }
}
