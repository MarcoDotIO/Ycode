// mtlrec: a diagnostic Metal call recorder for Ycode's own simulator
// (visionos.md §10.6.7 item 2, round R2). Unlike mtlwatch it does not wrap
// anything: object identity and classes stay as they are. It reroutes, in
// place, the methods that the Metal protocols declare (MTLDevice, MTLHeap,
// MTLCommandQueue, MTLCommandBuffer, MTLLibrary, MTLSharedEvent, …) on the
// classes that implement them, and logs every call with its arguments,
// result and error. Classes are hooked as objects of them are first seen
// (the device from MTLCreateSystemDefaultDevice, then every object a hooked
// method returns). Completion blocks passed to hooked methods are wrapped so
// that their arguments (command-buffer status and error, NSError objects)
// are logged as well.
//
// Technique (public ObjC runtime only): the original implementation is
// added under a new selector, the method's implementation becomes
// _objc_msgForward, and the class gets a forwardInvocation: that invokes
// the renamed original and logs. Inserted with
// DYLD_INSERT_LIBRARIES=<DEV path>/mtlrec.dylib; output in
// $MTLREC_DIR/mtlrec.<process>.<pid> (default /tmp). MTLREC_LIMIT (default
// 40) is how many calls of one class and selector are logged in full;
// nil results and errors are always logged. Frequent accessors (contents,
// length, gpuAddress, …) are not hooked unless MTLREC_ALL=1. MTLREC_LOOKUPS=1
// also logs class look-ups by name, feature flags, MobileGestalt answers, OS
// variant checks, sysctl names, getenv, C-API preference reads and dispatch
// queue labels (see "Look-ups" below).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static FILE *out;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t hookMu;  // recursive (class set-up may call back into hooked methods)
static uint64_t t0;
static unsigned limit = 40;
static CFMutableDictionaryRef renamed;      // "Class|sel" (CFString) -> renamed SEL (as pointer)
static CFMutableSetRef hookedClasses;       // Class pointers whose protocol methods are hooked
static CFMutableDictionaryRef counts;       // "Class|sel" -> count
static CFMutableDictionaryRef origForward;  // Class -> IMP of its previous forwardInvocation:
static CFMutableDictionaryRef hookedBySel;  // selector name -> CFArray of the classes hooked for it

static void maybeOpenWindow(const char *chain);
static void maybeScan(const char *chain);
/// Set while the main thread is inside the recorder (no TLS: its first use
/// may allocate): the window hooks then do nothing.
static int inHook;
/// Command queues created so far (newCommandQueue…), for MTLREC_FLIP.
static volatile long queueCalls;

static uint64_t nowNs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/// MTLREC_PROCS="backboardd,datamigrator": record only in these processes
/// (unset: every process the library is inserted into).
static int selected(void) {
    const char *list = getenv("MTLREC_PROCS");
    if (!list || !*list) return 1;
    const char *me = getprogname();
    size_t n = strlen(me);
    for (const char *p = list; *p;) {
        const char *e = strchr(p, ',');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == n && strncmp(p, me, n) == 0) return 1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

static void openLog(void) {
    if (out || !selected()) return;
    const char *dir = getenv("MTLREC_DIR");
    char path[1024];
    snprintf(path, sizeof path, "%s/mtlrec.%s.%d", dir && *dir ? dir : "/tmp", getprogname(), getpid());
    out = fopen(path, "w");
    if (out) setvbuf(out, NULL, _IOLBF, 0);
    const char *l = getenv("MTLREC_LIMIT");
    if (l && *l) limit = (unsigned)atoi(l);
}

static void emit(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void emit(const char *fmt, ...) {
    if (!out) return;
    char line[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    double ms = (double)(nowNs() - t0) / 1e6;
    int onMain = pthread_main_np(), saved = inHook;
    if (onMain) inHook = 1;
    pthread_mutex_lock(&mu);
    fprintf(out, "%10.3f t%-6u %s\n", ms, (unsigned)pthread_mach_thread_np(pthread_self()), line);
    pthread_mutex_unlock(&mu);
    if (onMain) inHook = saved;
}

/// MTLREC_STACK=<n>: after each logged call, the caller chain (n frames,
/// frame pointers) as image+offset and the nearest exported symbol.
static int stackDepth = -1;

/// The caller chain as " | image+offset symbol+offset" entries ("" when
/// MTLREC_STACK is unset).
static void buildStack(char *line, size_t cap) {
    line[0] = 0;
    if (stackDepth < 0) {
        const char *v = getenv("MTLREC_STACK");
        stackDepth = v && *v ? atoi(v) : 0;
    }
    if (stackDepth <= 0) return;
    int onMain = pthread_main_np(), saved = inHook;
    if (onMain) inHook = 1;
    void **fp = __builtin_frame_address(0);
    size_t used = 0;
    int skipped = 0;
    for (int i = 0; fp && i < stackDepth + 12 && used < cap - 200; i++) {
        void *ret = fp[1];
        void **next = fp[0];
        if (!ret) break;
        Dl_info info;
        if (dladdr(ret, &info) && info.dli_fname) {
            const char *base = strrchr(info.dli_fname, '/');
            base = base ? base + 1 : info.dli_fname;
            // Skip our own frames and the forwarding machinery.
            if (strstr(base, "mtlrec") || strstr(base, "CoreFoundation") || strstr(base, "libobjc")) { skipped++; goto next; }
            used += (size_t)snprintf(line + used, cap - used, " | %s+0x%lx %s+%ld", base,
                                     (unsigned long)((char *)ret - (char *)info.dli_fbase), info.dli_sname ? info.dli_sname : "?",
                                     info.dli_saddr ? (long)((char *)ret - (char *)info.dli_saddr) : 0L);
        }
    next:
        if (next <= fp) break;
        fp = next;
        if (i - skipped >= stackDepth) break;
    }
    if (onMain) inHook = saved;
}

// MTLREC_SCAN_QUEUES=<prefix> and MTLREC_SCAN_AT=<text>: the dispatch queues
// created with a label that starts with <prefix> are remembered; the first
// time a recorded call's caller chain contains <text>, the main thread's
// stack and the heap blocks it reaches (three levels, blocks of at most
// 64 KiB, malloc_size-checked) are searched for those queue pointers. Each
// path found is logged as "stack+off -> block[+off] -> …". It shows which
// live objects of the running code still refer to the component that owns
// the queues (for example whether a caller holds a pointer to it).
#include <malloc/malloc.h>
static void *scanQueues[16];
static int scanQueueCount;
static int scanDone;  // scans made so far

static void scanRemember(const char *label, void *q) {
    const char *pre = getenv("MTLREC_SCAN_QUEUES");
    if (!pre || !*pre || !label || strncmp(label, pre, strlen(pre)) != 0 || scanQueueCount >= 16) return;
    scanQueues[scanQueueCount++] = q;
}

static int isQueue(uintptr_t v) {
    for (int i = 0; i < scanQueueCount; i++) if ((uintptr_t)scanQueues[i] == v) return i + 1;
    return 0;
}

static size_t heapSize(uintptr_t v) {
    if (v < 0x100000000ull || v > 0x7fffffffffffull || (v & 7)) return 0;
    if (!malloc_zone_from_ptr((void *)v)) return 0;
    return malloc_size((void *)v);
}

static int scanFound;
static uintptr_t scanOwner;  // the first block found holding a remembered queue

/// One word of a dump: the value, and what it points to when it is a heap
/// block (its size) or an image address (the nearest exported name).
static void dumpWords(const char *what, uintptr_t base, size_t size) {
    for (size_t off = 0; off + 8 <= size && off < 4096; off += 8) {
        uintptr_t v = *(uintptr_t *)(base + off);
        char note[400] = "";
        Dl_info info;
        size_t hs = heapSize(v);
        if (isQueue(v)) snprintf(note, sizeof note, "queue %d", isQueue(v));
        else if (hs) {
            // The block's first word, named when it is an image address (a vtable or isa).
            uintptr_t first = *(uintptr_t *)v;
            const char *fname = "", *sname = "";
            long d = 0;
            if (first > 0x100000000ull && first < 0x7fffffffffffull && dladdr((void *)(first & 0x0000000fffffffffull), &info) && info.dli_fname) {
                fname = strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname;
                sname = info.dli_sname ? info.dli_sname : "?";
                d = info.dli_saddr ? (long)((first & 0x0000000fffffffffull) - (uintptr_t)info.dli_saddr) : 0L;
            }
            snprintf(note, sizeof note, "heap block (%zu) first 0x%lx %s %s+%ld", hs, (unsigned long)first, fname, sname, d);
        }
        else if (v > 0x100000000ull && v < 0x7fffffffffffull && dladdr((void *)v, &info) && info.dli_fname) {
            const char *b = strrchr(info.dli_fname, '/');
            snprintf(note, sizeof note, "%s %s+%ld", b ? b + 1 : info.dli_fname, info.dli_sname ? info.dli_sname : "?",
                     info.dli_saddr ? (long)(v - (uintptr_t)info.dli_saddr) : 0L);
        }
        emit("D %s +0x%03zx: 0x%016lx %s", what, off, (unsigned long)v, note);
    }
}

static void scanBlock(uintptr_t base, size_t size, int depth, char *path, size_t plen, uintptr_t *seen, int *nseen) {
    if (scanFound >= 40) return;
    size_t lim = size > 65536 ? 65536 : size;
    for (size_t off = 0; off + 8 <= lim; off += 8) {
        uintptr_t v = *(uintptr_t *)(base + off);
        int q = isQueue(v);
        if (q) {
            emit("S found queue %d at %s -> block 0x%lx(%zu)+0x%zx", q, path, (unsigned long)base, size, off);
            if (scanFound == 0) {
                scanOwner = base;
                char w[64];
                snprintf(w, sizeof w, "owner 0x%lx", (unsigned long)base);
                dumpWords(w, base, size);
                // MTLREC_SCAN_DEEP=1: also the blocks the owner points to (up to 1 KiB each).
                const char *deep = getenv("MTLREC_SCAN_DEEP");
                if (deep && *deep == '1')
                    for (size_t o2 = 0; o2 + 8 <= size; o2 += 8) {
                        uintptr_t c = *(uintptr_t *)(base + o2);
                        size_t cs = isQueue(c) ? 0 : heapSize(c);
                        if (!cs) continue;
                        snprintf(w, sizeof w, "owner+0x%zx 0x%lx", o2, (unsigned long)c);
                        dumpWords(w, c, cs > 1024 ? 1024 : cs);
                    }
            }
            scanFound++;
            continue;
        }
        if (depth >= 3) continue;
        size_t sz = heapSize(v);
        if (!sz) continue;
        int dup = 0;
        for (int i = 0; i < *nseen; i++) if (seen[i] == v) { dup = 1; break; }
        if (dup || *nseen >= 200000) continue;
        seen[(*nseen)++] = v;
        char sub[1024];
        snprintf(sub, sizeof sub, "%s -> 0x%lx(%zu)+0x%zx", path, (unsigned long)base, size, off);
        (void)plen;
        scanBlock(v, sz, depth + 1, sub, strlen(sub), seen, nseen);
    }
}


// MTLREC_CALL=<symbol>@<scan>: after scan number <scan> (1-based), call the
// function named <symbol> (found by name in the symbol tables of the loaded
// images, as dladdr names it) with the owner block as its first argument and
// the word at owner+MTLREC_CALL_ARG_OFF (default 0x10) as its second, after
// writing the bytes MTLREC_POKE="off=value,…" into the owner block. A
// black-box experiment: which state of the owner makes the function do its
// work (its Metal calls and look-ups are recorded as usual).
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
static void *findSymbol(const char *want) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *mh = (const void *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *lc = (const void *)(mh + 1);
        uint64_t leVM = 0, leFile = 0;
        const struct symtab_command *st = NULL;
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, "__LINKEDIT") == 0) {
                leVM = ((const struct segment_command_64 *)lc)->vmaddr;
                leFile = ((const struct segment_command_64 *)lc)->fileoff;
            } else if (lc->cmd == LC_SYMTAB) st = (const void *)lc;
            lc = (const void *)((const char *)lc + lc->cmdsize);
        }
        if (!st || !leVM) continue;
        const struct nlist_64 *nl = (const void *)(uintptr_t)(leVM + slide + (st->symoff - leFile));
        const char *strs = (const char *)(uintptr_t)(leVM + slide + (st->stroff - leFile));
        for (uint32_t k = 0; k < st->nsyms; k++) {
            if ((nl[k].n_type & N_TYPE) != N_SECT || nl[k].n_un.n_strx >= st->strsize) continue;
            if (strcmp(strs + nl[k].n_un.n_strx, want) == 0) return (void *)(uintptr_t)(nl[k].n_value + slide);
        }
    }
    return NULL;
}

static void maybeCall(void) {
    const char *spec = getenv("MTLREC_CALL");
    if (!spec || !*spec || !scanOwner) return;
    const char *at = strrchr(spec, '@');
    if (!at || atoi(at + 1) != scanDone) return;
    char sym[512];
    size_t n = (size_t)(at - spec);
    if (n >= sizeof sym) return;
    memcpy(sym, spec, n); sym[n] = 0;
    void *fn = findSymbol(sym);
    const char *ao = getenv("MTLREC_CALL_ARG_OFF");
    size_t argOff = ao && *ao ? (size_t)strtoul(ao, NULL, 0) : 0x10;
    uintptr_t arg = *(uintptr_t *)(scanOwner + argOff);
    const char *poke = getenv("MTLREC_POKE");
    for (const char *p = poke; p && *p;) {
        char *e;
        unsigned long off = strtoul(p, &e, 0);
        if (*e != '=') break;
        unsigned long val = strtoul(e + 1, &e, 0);
        emit("C poke owner+0x%lx: %u -> %lu", off, *(uint8_t *)(scanOwner + off), val);
        *(uint8_t *)(scanOwner + off) = (uint8_t)val;
        p = *e == ',' ? e + 1 : e;
        if (!*e) break;
    }
    emit("C call %s (%p) owner 0x%lx arg 0x%lx", sym, fn, (unsigned long)scanOwner, (unsigned long)arg);
    if (!fn) return;
    // MTLREC_FLIP=1: before the plain call, flip each byte of the owner and
    // of the argument block whose value is 0 or 1 and whose word is not a
    // pointer, call, note whether a command queue was created, and restore.
    const char *flip = getenv("MTLREC_FLIP");
    if (flip && *flip == '1') {
        uintptr_t blocks[2] = {scanOwner, arg};
        const char *names[2] = {"owner", "arg"};
        for (int b = 0; b < 2; b++) {
            size_t size = heapSize(blocks[b]);
            for (size_t off = 0; off < size && off < 2048; off++) {
                uint8_t *byte = (uint8_t *)(blocks[b] + off);
                if (*byte > 1) continue;
                uintptr_t word = *(uintptr_t *)(blocks[b] + (off & ~(size_t)7));
                Dl_info info;
                if (heapSize(word) || (word > 0x100000000ull && word < 0x7fffffffffffull && dladdr((void *)word, &info))) continue;
                if (b == 0 && off >= 0x10 && off < 0x18) continue;  // the argument itself
                uint8_t was = *byte;
                long before = queueCalls;
                *byte = was ^ 1;
                int saved2 = inHook;
                inHook = 0;
                ((void (*)(uintptr_t, uintptr_t))fn)(scanOwner, arg);
                inHook = saved2;
                if (queueCalls != before) emit("C FLIP %s+0x%zx %u->%u: command queue created", names[b], off, was, was ^ 1);
                *byte = was;
            }
            emit("C flips of %s done (%zu bytes)", names[b], size);
        }
    }
    int saved = inHook;
    inHook = 0;
    ((void (*)(uintptr_t, uintptr_t))fn)(scanOwner, arg);
    inHook = saved;
    emit("C call returned");
    dumpWords("owner after call", scanOwner, 448);
}

// MTLREC_CONFIG=1: at each scan, find a heap block on the stack whose first
// word names re::Shareable<re::EngineConfiguration> (the engine
// configuration object) and log the values its public getters return
// (REEngineConfigurationGet…, found with dlsym; the raw x0 of each).
static void configApplyAndDump(uintptr_t v, const char *where) {
    static const char *names[] = {
        "REEngineConfigurationGetAllowOutOfProcessImageDecode",
        "REEngineConfigurationGetAssetRuntimeSizeLimitForResourceShareClient",
        "REEngineConfigurationGetAssetRuntimeUpdateTimeout",
        "REEngineConfigurationGetAutoCalculateNonSharedAssetDataSize",
        "REEngineConfigurationGetCALayerServiceFlags",
        "REEngineConfigurationGetCALayerServiceType",
        "REEngineConfigurationGetClockMode",
        "REEngineConfigurationGetDefaultSceneRoles",
        "REEngineConfigurationGetDevice",
        "REEngineConfigurationGetDisableRenderGraphCaching",
        "REEngineConfigurationGetEnableCommitSynchronously",
        "REEngineConfigurationGetEnableInteractions",
        "REEngineConfigurationGetEnablePreloadEngineAssets",
        "REEngineConfigurationGetEnablePreloadMXIAssets",
        "REEngineConfigurationGetEnablePreloadMXIAssetsForBackgroundRender",
        "REEngineConfigurationGetEnableVideoSupport",
        "REEngineConfigurationGetEngineQueue",
        "REEngineConfigurationGetForExportOnly",
        "REEngineConfigurationGetIsHostingSharedAudioSimulation",
        "REEngineConfigurationGetLiteHUDTabs",
        "REEngineConfigurationGetRealityFusionSessionNeeded",
        "REEngineConfigurationGetRenderFlags",
        "REEngineConfigurationGetRenderFrameOverlap",
        "REEngineConfigurationGetRenderSkippingEnabled",
        "REEngineConfigurationGetRenderThreadPriority",
        "REEngineConfigurationGetServicesToCreate",
        "REEngineConfigurationGetServicesToUpdate",
        "REEngineConfigurationGetShareAssetStates",
        "REEngineConfigurationGetStartupOptions",
        "REEngineConfigurationGetSuppressAssetRegistrationQueueAssertion",
        "REEngineConfigurationGetUseMetal",
        "REEngineConfigurationGetUsePhysicsSceneSystem",
        "REEngineConfigurationGetUserData",
        "REEngineConfigurationGetUseRealityIO",
        "REEngineConfigurationIsSolariumLeanModeEnabled",
        NULL};
    Dl_info info;
    uintptr_t first = *(uintptr_t *)v & 0x0000000fffffffffull;
    emit("E engine configuration 0x%lx (%s) %s", (unsigned long)v, first && dladdr((void *)first, &info) && info.dli_sname ? info.dli_sname : "?", where);
    // MTLREC_CONFIG_SET="<Name>=<value>,…": call REEngineConfigurationSet<Name>(config, value) first.
    const char *set = getenv("MTLREC_CONFIG_SET");
    for (const char *q = set; q && *q;) {
        const char *eq = strchr(q, '=');
        if (!eq) break;
        char fname[160];
        snprintf(fname, sizeof fname, "REEngineConfigurationSet%.*s", (int)(eq - q), q);
        char *e;
        unsigned long long val = strtoull(eq + 1, &e, 0);
        void *fn = dlsym(RTLD_DEFAULT, fname);
        emit("E set %s(0x%llx)%s", fname, val, fn ? "" : ": not found");
        if (fn) ((void (*)(uintptr_t, unsigned long long))fn)(v, val);
        q = *e == ',' ? e + 1 : NULL;
    }
    for (int i = 0; names[i]; i++) {
        void *fn = dlsym(RTLD_DEFAULT, names[i]);
        if (!fn) { emit("E %s: not found", names[i]); continue; }
        uint64_t r = ((uint64_t (*)(uintptr_t))fn)(v);
        emit("E %s -> 0x%llx", names[i], (unsigned long long)r);
    }
}

static void dumpEngineConfiguration(void) {
    const char *c = getenv("MTLREC_CONFIG");
    if (!c || *c != '1') return;
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    for (uintptr_t a = (uintptr_t)__builtin_frame_address(0); a + 8 <= top; a += 8) {
        uintptr_t v = *(uintptr_t *)a;
        if (!heapSize(v)) continue;
        uintptr_t first = *(uintptr_t *)v & 0x0000000fffffffffull;
        Dl_info info;
        if (!first || !dladdr((void *)first, &info) || !info.dli_sname || !strstr(info.dli_sname, "EngineConfiguration")) continue;
        configApplyAndDump(v, "(on the stack)");
        return;
    }
    emit("E no engine configuration on the stack");
}

// REEngineInitWithConfiguration (exported by CoreRE; resolved at load time):
// with MTLREC_CONFIG=1 the configuration argument is dumped (and changed by
// MTLREC_CONFIG_SET) before the engine reads it.
extern uint64_t REEngineInitWithConfiguration(uintptr_t, uintptr_t, uintptr_t, uintptr_t) __attribute__((weak_import));
static uint64_t rec_REEngineInitWithConfiguration(uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d) {
    const char *cfg = getenv("MTLREC_CONFIG");
    if (out && cfg && *cfg == '1' && REEngineInitWithConfiguration) {
        uintptr_t args[2] = {a, b};
        for (int i = 0; i < 2; i++) {
            Dl_info info;
            uintptr_t first = heapSize(args[i]) ? *(uintptr_t *)args[i] & 0x0000000fffffffffull : 0;
            if (first && dladdr((void *)first, &info) && info.dli_sname && strstr(info.dli_sname, "EngineConfiguration"))
                configApplyAndDump(args[i], "(at REEngineInitWithConfiguration)");
        }
    }
    return REEngineInitWithConfiguration(a, b, c, d);
}

static void maybeScan(const char *chain) {
    const char *at = getenv("MTLREC_SCAN_AT");
    if (!at || !*at || !pthread_main_np()) return;
    // MTLREC_SCAN_AT=a,b: one scan at the first chain containing a, another at b.
    char want[256];
    {
        const char *p = at;
        for (int i = 0; i < scanDone && p; i++) { p = strchr(p, ','); if (p) p++; }
        if (!p || !*p) return;
        const char *e = strchr(p, ',');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n >= sizeof want) n = sizeof want - 1;
        memcpy(want, p, n); want[n] = 0;
    }
    if (!strstr(chain, want)) return;
    scanDone++;
    scanFound = 0;
    at = want;
    int saved = inHook;
    inHook = 1;
    emit("S scan at %s: %d queues remembered", at, scanQueueCount);
    // Frames of the chain with their frame addresses, to place stack hits.
    void **fp = __builtin_frame_address(0);
    for (int i = 0; fp && i < 40; i++) {
        Dl_info info;
        void *ret = fp[1];
        if (ret && dladdr(ret, &info) && info.dli_sname)
            emit("S frame %d fp=0x%lx ret %s+%ld", i, (unsigned long)fp, info.dli_sname,
                 info.dli_saddr ? (long)((char *)ret - (char *)info.dli_saddr) : 0L);
        void **next = fp[0];
        // MTLREC_SCAN_FRAME=<symbol>: dump the frame of the function that
        // this record returns into (from the callee's record to its own).
        const char *fr = getenv("MTLREC_SCAN_FRAME");
        if (fr && *fr && ret && dladdr(ret, &info) && info.dli_sname && strstr(info.dli_sname, fr) && next > fp) {
            uintptr_t lo = (uintptr_t)fp + 16, hi = (uintptr_t)next + 16;
            dumpWords("frame", lo, (size_t)(hi - lo));
            // MTLREC_SCAN_ARGS=<n>: the first <n> bytes above that frame's
            // record (the caller's outgoing stack arguments).
            const char *sa = getenv("MTLREC_SCAN_ARGS");
            if (sa && atoi(sa) > 0) dumpWords("args", hi, (size_t)atoi(sa));
            // MTLREC_SCAN_DEREF=<off>:<len>[,…]: also dump <len> bytes at the
            // address stored at frame+<off> (a pointer into another frame).
            const char *dr = getenv("MTLREC_SCAN_DEREF");
            for (const char *q = dr; q && *q;) {
                char *e;
                unsigned long off = strtoul(q, &e, 0), len = 0;
                if (*e == ':') len = strtoul(e + 1, &e, 0);
                if (off + 8 <= hi - lo && len) {
                    uintptr_t target = *(uintptr_t *)(lo + off);
                    char w[64];
                    snprintf(w, sizeof w, "*frame+0x%lx 0x%lx", off, (unsigned long)target);
                    if (target >= lo && target < (uintptr_t)pthread_get_stackaddr_np(pthread_self())) dumpWords(w, target, len);
                    else if (heapSize(target)) dumpWords(w, target, len < heapSize(target) ? len : heapSize(target));
                }
                q = *e == ',' ? e + 1 : NULL;
            }
            // MTLREC_SCAN_BLOCK_SIZE=<n>: also dump the heap blocks of n bytes the frame refers to.
            const char *bs = getenv("MTLREC_SCAN_BLOCK_SIZE");
            size_t want = bs && *bs ? (size_t)atol(bs) : 0;
            // (searched from this function's own frame up to the top of that
            // frame: callee-saved registers of the frame live in the frames below it)
            uintptr_t seenBlocks[64];
            int nb = 0;
            for (uintptr_t a = (uintptr_t)__builtin_frame_address(0); want && a + 8 <= hi && nb < 64; a += 8) {
                uintptr_t v = *(uintptr_t *)a;
                if (heapSize(v) != want) continue;
                int dup = 0;
                for (int k = 0; k < nb; k++) if (seenBlocks[k] == v) dup = 1;
                if (dup) continue;
                seenBlocks[nb++] = v;
                char w[64];
                snprintf(w, sizeof w, "block 0x%lx", (unsigned long)v);
                dumpWords(w, v, want);
                // MTLREC_SCAN_CHILDREN=1: also dump the heap blocks this block
                // points to whose first word names a vtable (up to 1 KiB each).
                const char *sc = getenv("MTLREC_SCAN_CHILDREN");
                if (sc && *sc == '1')
                    for (size_t o2 = 0; o2 + 8 <= want; o2 += 8) {
                        uintptr_t c = *(uintptr_t *)(v + o2);
                        size_t cs = heapSize(c);
                        if (!cs) continue;
                        uintptr_t first = *(uintptr_t *)c & 0x0000000fffffffffull;
                        Dl_info ci;
                        if (!first || !dladdr((void *)first, &ci) || !ci.dli_sname || strncmp(ci.dli_sname, "_ZTV", 4) != 0) continue;
                        snprintf(w, sizeof w, "child+0x%zx %s", o2, ci.dli_sname);
                        dumpWords(w, c, cs > 1024 ? 1024 : cs);
                    }
                // MTLREC_BLOCK_POKE="<scan>:<off>=<byte>,…": write bytes into
                // the dumped blocks at scan number <scan> (an experiment).
                const char *bp = getenv("MTLREC_BLOCK_POKE");
                // MTLREC_BLOCK_MATCH=<off>=<word>: only blocks with that word at that offset.
                const char *bm = getenv("MTLREC_BLOCK_MATCH");
                int blockOK = 1;
                if (bm && strchr(bm, '=')) {
                    unsigned long mo = strtoul(bm, NULL, 0);
                    unsigned long long mv = strtoull(strchr(bm, '=') + 1, NULL, 0);
                    blockOK = mo + 8 <= want && *(unsigned long long *)(v + mo) == mv;
                }
                if (blockOK && bp && atoi(bp) == scanDone && strchr(bp, ':')) {
                    for (const char *q = strchr(bp, ':') + 1; q && *q;) {
                        char *e;
                        unsigned long off = strtoul(q, &e, 0);
                        if (*e != '=' || off >= want) break;
                        unsigned long val = strtoul(e + 1, &e, 0);
                        emit("C block poke 0x%lx+0x%lx: %u -> %lu", (unsigned long)v, off, *(uint8_t *)(v + off), val);
                        *(uint8_t *)(v + off) = (uint8_t)val;
                        q = *e == ',' ? e + 1 : NULL;
                    }
                }
                // MTLREC_BLOCK_CALL="<scan>:<symbol>": then call <symbol>(fresh
                // zeroed 4 KiB, block) — a constructor taking the block by
                // reference — and log the block's bytes that it changed.
                const char *bc = getenv("MTLREC_BLOCK_CALL");
                if (bc && atoi(bc) == scanDone && strchr(bc, ':')) {
                    void *fn = findSymbol(strchr(bc, ':') + 1);
                    uint8_t before[2048];
                    memcpy(before, (void *)v, want < sizeof before ? want : sizeof before);
                    void *fresh = calloc(1, 4096);
                    emit("C block call %s (%p) on 0x%lx", strchr(bc, ':') + 1, fn, (unsigned long)v);
                    if (fn) {
                        int saved3 = inHook;
                        inHook = 0;
                        ((void (*)(void *, uintptr_t))fn)(fresh, v);
                        inHook = saved3;
                        for (size_t o = 0; o < want && o < sizeof before; o++)
                            if (before[o] != *(uint8_t *)(v + o)) emit("C block changed +0x%zx: %u -> %u", o, before[o], *(uint8_t *)(v + o));
                        emit("C block call returned");
                        dumpWords("constructed", (uintptr_t)fresh, 256);
                    }
                }
            }
        }
        if (next <= fp) break;
        fp = next;
    }
    uintptr_t sp = (uintptr_t)__builtin_frame_address(0);
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    uintptr_t *seen = malloc(200000 * sizeof(uintptr_t));
    int nseen = 0;
    for (uintptr_t a = sp; a + 8 <= top && scanFound < 40; a += 8) {
        uintptr_t v = *(uintptr_t *)a;
        if (isQueue(v)) { emit("S found queue %d on the stack at 0x%lx", isQueue(v), (unsigned long)a); scanFound++; continue; }
        size_t sz = heapSize(v);
        if (!sz) continue;
        int dup = 0;
        for (int i = 0; i < nseen; i++) if (seen[i] == v) { dup = 1; break; }
        if (dup) continue;
        seen[nseen++] = v;
        char path[1024];
        snprintf(path, sizeof path, "stack 0x%lx", (unsigned long)a);
        scanBlock(v, sz, 1, path, strlen(path), seen, &nseen);
    }
    // MTLREC_SCAN_PATTERN=<u64>,<u64>: places on the stack and in the heap
    // blocks visited where these two words follow each other; 256 bytes
    // before and after each place are dumped.
    const char *pat = getenv("MTLREC_SCAN_PATTERN");
    if (pat && strchr(pat, ',')) {
        unsigned long long p1 = strtoull(pat, NULL, 0), p2 = strtoull(strchr(pat, ',') + 1, NULL, 0);
        int found = 0;
        for (uintptr_t a = sp; a + 16 <= top && found < 6; a += 8)
            if (*(unsigned long long *)a == p1 && *(unsigned long long *)(a + 8) == p2) {
                char w[64];
                snprintf(w, sizeof w, "pattern on the stack at 0x%lx", (unsigned long)a);
                uintptr_t from = a - 256 > sp ? a - 256 : sp;
                dumpWords(w, from, (a + 256 < top ? a + 256 : top) - from);
                found++;
            }
        for (int i = 0; i < nseen && found < 6; i++) {
            size_t sz = heapSize(seen[i]);
            for (size_t o = 0; o + 16 <= sz && sz <= 65536; o += 8)
                if (*(unsigned long long *)(seen[i] + o) == p1 && *(unsigned long long *)(seen[i] + o + 8) == p2) {
                    char w[64];
                    snprintf(w, sizeof w, "pattern in block 0x%lx(%zu)+0x%zx", (unsigned long)seen[i], sz, o);
                    dumpWords(w, seen[i], sz < 4096 ? sz : 4096);
                    found++;
                    break;
                }
        }
        emit("S pattern places: %d", found);
    }
    // MTLREC_VPOKE="<scan>:<vtable text>:<off>=<byte>,…": at that scan,
    // write bytes into each heap block found from the stack (three levels,
    // as above) whose first word names a vtable containing <vtable text>.
    const char *vp = getenv("MTLREC_VPOKE");
    if (vp && atoi(vp) == scanDone && strchr(vp, ':') && strchr(strchr(vp, ':') + 1, ':')) {
        const char *t0 = strchr(vp, ':') + 1, *t1 = strchr(t0, ':');
        char vt[160];
        snprintf(vt, sizeof vt, "%.*s", (int)(t1 - t0), t0);
        for (int i = 0; i < nseen; i++) {
            uintptr_t b = seen[i];
            size_t bsz = heapSize(b);
            uintptr_t first = bsz ? *(uintptr_t *)b & 0x0000000fffffffffull : 0;
            Dl_info vi;
            if (!first || !dladdr((void *)first, &vi) || !vi.dli_sname || strncmp(vi.dli_sname, "_ZTV", 4) || !strstr(vi.dli_sname, vt)) continue;
            for (const char *q = t1 + 1; q && *q;) {
                char *e;
                unsigned long off = strtoul(q, &e, 0);
                if (*e != '=' || off >= bsz) break;
                unsigned long val = strtoul(e + 1, &e, 0);
                emit("C vpoke %s 0x%lx+0x%lx: %u -> %lu", vi.dli_sname, (unsigned long)b, off, *(uint8_t *)(b + off), val);
                *(uint8_t *)(b + off) = (uint8_t)val;
                q = *e == ',' ? e + 1 : NULL;
            }
        }
    }
    emit("S scan done: %d hits, %d blocks visited", scanFound, nseen);
    free(seen);
    dumpEngineConfiguration();
    inHook = saved;
    maybeCall();
}

static void emitStack(void) {
    char line[4096];
    buildStack(line, sizeof line);
    if (!line[0]) return;
    emit("    stack%s", line);
    maybeOpenWindow(line);
    maybeScan(line);
}

// MTLREC_WINDOW_AFTER=<text>: once a recorded call's caller chain contains
// <text> (a symbol name), the allocation and lock calls of the main thread
// are recorded with their caller chains (MTLREC_WINDOW_MAX lines, default
// 3000): a trace of what runs when no Metal call and no system call does.
static volatile int windowOpen;
static volatile int windowLines;
static int windowMax = -1;

static void maybeOpenWindow(const char *chain) {
    const char *after = getenv("MTLREC_WINDOW_AFTER");
    if (!windowOpen && after && *after && strstr(chain, after)) {
        windowOpen = 1;
        emit("window opened (%s)", after);
    }
}

static NSString *brief(id o) {
    if (!o) return @"nil";
    Class c = object_getClass(o);
    if ([o isKindOfClass:[NSString class]] || [o isKindOfClass:[NSNumber class]] || [o isKindOfClass:[NSURL class]]) {
        NSString *d = [o description];
        if (d.length > 300) d = [d substringToIndex:300];
        return [NSString stringWithFormat:@"%s\"%@\"", class_getName(c), d];
    }
    if ([o isKindOfClass:[NSError class]]) {
        NSError *e = o;
        NSString *d = [e.localizedDescription stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        return [NSString stringWithFormat:@"NSError(%@ %ld: %@)", e.domain, (long)e.code, d];
    }
    if ([o isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"%s[%lu]", class_getName(c), (unsigned long)[o count]];
    if ([o isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"%s{%lu}", class_getName(c), (unsigned long)[o count]];
    const char *name = class_getName(c);
    if (strstr(name, "Descriptor") || strstr(name, "Handle")) {
        NSString *d = [[o description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        while ([d containsString:@"  "]) d = [d stringByReplacingOccurrencesOfString:@"  " withString:@" "];
        if (d.length > 700) d = [d substringToIndex:700];
        return [NSString stringWithFormat:@"%s<%@>", name, d];
    }
    return [NSString stringWithFormat:@"%s@%p", name, (__bridge void *)o];
}

static void hookObjectClass(id o);

// MARK: Blocks

struct BlockLayout {
    void *isa;
    int flags;
    int reserved;
    void (*invoke)(void *, ...);
    struct {
        unsigned long reserved, size;
        void *rest[2];
    } * descriptor;
};

static const char *blockSignature(id block) {
    struct BlockLayout *b = (__bridge void *)block;
    if (!b || !(b->flags & (1 << 30))) return NULL;
    void **p = b->descriptor->rest;
    if (b->flags & (1 << 25)) p += 2;  // copy and dispose helpers
    return (const char *)p[0];
}

/// A wrapper for a completion block whose arguments are all objects (up to
/// three), or nil when its signature is not of that form.
static id wrapBlock(id block, NSString *where) {
    const char *sig = blockSignature(block);
    if (!sig) return nil;
    NSMethodSignature *ms = nil;
    @try { ms = [NSMethodSignature signatureWithObjCTypes:sig]; } @catch (id e) { return nil; }
    if (!ms || ms.methodReturnType[0] != 'v') return nil;
    NSUInteger n = ms.numberOfArguments - 1;  // argument 0 is the block
    if (n == 0 || n > 3) return nil;
    for (NSUInteger i = 1; i <= n; i++) if ([ms getArgumentTypeAtIndex:i][0] != '@') return nil;
    NSString *w = [where copy];
    void (^logArgs)(id, id, id) = ^(id a, id b, id c) {
        NSMutableString *s = [NSMutableString string];
        id args[3] = {a, b, c};
        for (NSUInteger i = 0; i < n; i++) {
            id x = args[i];
            [s appendFormat:@" %@", brief(x)];
            if (x && [x conformsToProtocol:@protocol(MTLCommandBuffer)]) {
                id<MTLCommandBuffer> cb = x;
                [s appendFormat:@"(status=%lu error=%@ gpu=%.3f-%.3f)", (unsigned long)cb.status, brief(cb.error),
                                cb.GPUStartTime, cb.GPUEndTime];
            }
        }
        emit("  block %s ->%s", w.UTF8String, s.UTF8String);
        if (n >= 1) hookObjectClass(a);
    };
    switch (n) {
    case 1: {
        void (^orig)(id) = block;
        return ^(id a) { logArgs(a, nil, nil); orig(a); };
    }
    case 2: {
        void (^orig)(id, id) = block;
        return ^(id a, id b) { logArgs(a, b, nil); orig(a, b); };
    }
    default: {
        void (^orig)(id, id, id) = block;
        return ^(id a, id b, id c) { logArgs(a, b, c); orig(a, b, c); };
    }
    }
}

// MARK: Values

static NSString *describeValue(NSInvocation *inv, const char *type, NSInteger index, NSUInteger size) {
    // index -1: the return value
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' || *type == 'R' || *type == 'V') type++;
    unsigned char buf[256] = {0};
    if (size > sizeof buf) return [NSString stringWithFormat:@"(%s)", type];
    if (index < 0) [inv getReturnValue:buf]; else [inv getArgument:buf atIndex:index];
    switch (type[0]) {
    case '@': {
        if (type[1] == '?') return @"block";
        __unsafe_unretained id o = *(__unsafe_unretained id *)(void *)buf;
        return brief(o);
    }
    case 'B': case 'c': case 'C': return [NSString stringWithFormat:@"%d", buf[0]];
    case 's': case 'S': return [NSString stringWithFormat:@"%u", *(uint16_t *)(void *)buf];
    case 'i': case 'I': case 'l': case 'L': return [NSString stringWithFormat:@"%u", *(uint32_t *)(void *)buf];
    case 'q': case 'Q': return [NSString stringWithFormat:@"%llu", *(unsigned long long *)(void *)buf];
    case 'f': return [NSString stringWithFormat:@"%g", *(float *)(void *)buf];
    case 'd': return [NSString stringWithFormat:@"%g", *(double *)(void *)buf];
    case ':': return [NSString stringWithFormat:@"@selector(%s)", sel_getName(*(SEL *)(void *)buf)];
    case '*': return @"char*";
    case '^': {
        void *p = *(void **)(void *)buf;
        if (type[1] == '@' && p && index >= 0) return @"&out";
        return p ? [NSString stringWithFormat:@"%p", p] : @"NULL";
    }
    case '{': {
        NSMutableString *s = [NSMutableString stringWithString:@"{"];
        for (NSUInteger i = 0; i + 8 <= size && i < 64; i += 8) [s appendFormat:@"%s%llu", i ? "," : "", *(unsigned long long *)(void *)(buf + i)];
        [s appendString:@"}"];
        return s;
    }
    default: return [NSString stringWithFormat:@"(%s)", type];
    }
}

// MARK: Forwarding

static SEL renamedSelector(Class cls, SEL sel) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("%s|%s"), class_getName(c), sel_getName(sel));
        pthread_mutex_lock(&hookMu);
        const void *v = CFDictionaryGetValue(renamed, key);
        pthread_mutex_unlock(&hookMu);
        CFRelease(key);
        if (v) return (SEL)v;
    }
    return NULL;
}

static unsigned bump(Class cls, SEL sel) {
    CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("%s|%s"), class_getName(cls), sel_getName(sel));
    pthread_mutex_lock(&hookMu);
    long n = 0;
    CFNumberRef v = CFDictionaryGetValue(counts, key);
    if (v) CFNumberGetValue(v, kCFNumberLongType, &n);
    n++;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberLongType, &n);
    CFDictionarySetValue(counts, key, nv);
    CFRelease(nv);
    pthread_mutex_unlock(&hookMu);
    CFRelease(key);
    return (unsigned)n;
}

static void recForwardInvocation(id self, SEL _cmd, NSInvocation *inv) {
    SEL sel = inv.selector;
    Class cls = object_getClass(self);
    SEL orig = renamedSelector(cls, sel);
    if (!orig) {
        // Not one of ours: the previous forwardInvocation: of the first class that had one recorded.
        for (Class c = cls; c; c = class_getSuperclass(c)) {
            pthread_mutex_lock(&hookMu);
            IMP prev = (IMP)CFDictionaryGetValue(origForward, (__bridge const void *)c);
            pthread_mutex_unlock(&hookMu);
            if (prev) {
                ((void (*)(id, SEL, NSInvocation *))prev)(self, _cmd, inv);
                return;
            }
        }
        [self doesNotRecognizeSelector:sel];
        return;
    }
    NSMethodSignature *ms = inv.methodSignature;
    NSUInteger n = ms.numberOfArguments;
    const char *name = sel_getName(sel);
    // Wrap completion blocks (status and errors of what they report).
    NSMutableArray *keep = nil;
    for (NSUInteger i = 2; i < n; i++) {
        const char *t = [ms getArgumentTypeAtIndex:i];
        if (t[0] == '@' && t[1] == '?') {
            __unsafe_unretained id b = nil;
            [inv getArgument:&b atIndex:(NSInteger)i];
            if (!b) continue;
            id w = wrapBlock(b, [NSString stringWithFormat:@"%s %s", class_getName(cls), name]);
            if (w) {
                if (!keep) keep = [NSMutableArray array];
                [keep addObject:w];
                __unsafe_unretained id wu = w;
                [inv setArgument:&wu atIndex:(NSInteger)i];
            }
        }
    }
    if (keep) [inv retainArguments];
    // NSError ** out-parameters: give the callee our own slot so it can be read afterwards.
    // MTLREC_PRECALL=<text>: log calls whose selector contains <text> before
    // they run too, with their arguments (for calls that do not return).
    const char *pre = getenv("MTLREC_PRECALL");
    if (pre && *pre && strstr(name, pre)) {
        NSMutableString *args = [NSMutableString string];
        for (NSUInteger i = 2; i < n && i < 8; i++) {
            const char *t = [ms getArgumentTypeAtIndex:i];
            NSUInteger sz = 0;
            NSGetSizeAndAlignment(t, &sz, NULL);
            [args appendFormat:@" %@", describeValue(inv, t, (NSInteger)i, sz)];
        }
        emit("> %s@%p %s%s", class_getName(cls), (__bridge void *)self, name, args.UTF8String);
        emitStack();
    }
    uint64_t start = nowNs();
    inv.selector = orig;
    [inv invoke];
    inv.selector = sel;
    double callMs = (double)(nowNs() - start) / 1e6;

    const char *rt = ms.methodReturnType;
    while (*rt == 'r' || *rt == 'V' || *rt == 'n' || *rt == 'N' || *rt == 'o' || *rt == 'O' || *rt == 'R') rt++;
    BOOL interesting = NO;
    __unsafe_unretained id robj = nil;
    if (rt[0] == '@' && rt[1] != '?') {
        [inv getReturnValue:&robj];
        if (!robj && strncmp(name, "new", 3) == 0) interesting = YES;
    }
    NSMutableString *errs = [NSMutableString string];
    for (NSUInteger i = 2; i < n; i++) {
        const char *t = [ms getArgumentTypeAtIndex:i];
        if (t[0] == '^' && t[1] == '@') {
            void *pp = NULL;
            [inv getArgument:&pp atIndex:(NSInteger)i];
            if (pp) {
                __unsafe_unretained id e = *(__unsafe_unretained id *)pp;
                if (e) {
                    [errs appendFormat:@" error=%@", brief(e)];
                    interesting = YES;
                }
            }
        }
    }
    if (strncmp(name, "newCommandQueue", 15) == 0) queueCalls++;
    unsigned count = bump(cls, sel);
    if (count <= limit || interesting || (count & (count - 1)) == 0) {
        NSMutableString *args = [NSMutableString string];
        for (NSUInteger i = 2; i < n && i < 8; i++) {
            const char *t = [ms getArgumentTypeAtIndex:i];
            NSUInteger sz = 0;
            NSGetSizeAndAlignment(t, &sz, NULL);
            [args appendFormat:@" %@", describeValue(inv, t, (NSInteger)i, sz)];
        }
        NSString *result = @"";
        if (rt[0] != 'v') result = describeValue(inv, rt, -1, ms.methodReturnLength);
        emit("%s%s@%p %s%s -> %s%s [#%u %.2f ms]", interesting ? "!! " : "", class_getName(cls), (__bridge void *)self, name,
             args.UTF8String, result.UTF8String, errs.UTF8String, count, callMs);
        emitStack();
    }
    // Status after a wait on a command buffer.
    if (strcmp(name, "waitUntilCompleted") == 0 || strcmp(name, "waitUntilScheduled") == 0) {
        id<MTLCommandBuffer> cb = self;
        emit("  %s returned: status=%lu error=%s", name, (unsigned long)cb.status, brief(cb.error).UTF8String);
    }
    if (robj) hookObjectClass(robj);
}

static const char *protocolNames[] = {
    "MTLDevice", "MTLHeap", "MTLCommandQueue", "MTLCommandBuffer", "MTLLibrary", "MTLFunction", "MTLComputePipelineState",
    "MTLRenderPipelineState", "MTLEvent", "MTLSharedEvent", "MTLFence", "MTLTexture", "MTLBuffer", "MTLResource",
    "MTLBlitCommandEncoder", "MTLComputeCommandEncoder", "MTLCommandEncoder", "MTLArgumentEncoder", "MTLBinaryArchive",
    "MTLIOCommandQueue", "MTLIOCommandBuffer", "MTLIOFileHandle", "MTLSamplerState", "MTLDepthStencilState",
    "MTLResidencySet", "MTLAllocation", "MTLDynamicLibrary", "MTLCounterSampleBuffer", "MTLLogState", NULL,
};

/// Skipped: hot or re-entrant accessors whose calls tell nothing.
static BOOL skipSelector(const char *s) {
    // MTLREC_ALL=1: hook the accessors too (contents, length, gpuAddress, …).
    static int all = -1;
    if (all < 0) all = getenv("MTLREC_ALL") && *getenv("MTLREC_ALL") == '1';
    if (all && strcmp(s, "status") && strcmp(s, "error")) return NO;
    static const char *skip[] = {"device", "label", "setLabel:", "retainedReferences", "contents", "length", "gpuAddress",
                                 "allocatedSize", "storageMode", "cpuCacheMode", "hazardTrackingMode", "resourceOptions",
                                 "pixelFormat", "width", "height", "depth", "textureType", "usage", "status", "error",
                                 "GPUStartTime", "GPUEndTime", "kernelStartTime", "kernelEndTime", "gpuResourceID",
                                 "commandQueue", "heap", "heapOffset", "isAliasable", "name", NULL};
    for (int i = 0; skip[i]; i++) if (strcmp(s, skip[i]) == 0) return YES;
    // Encoder argument setters are frequent; the counts limit keeps a sample, but skip the busiest outright.
    if (strncmp(s, "setVertex", 9) == 0 || strncmp(s, "setFragment", 11) == 0) return YES;
    return NO;
}

static Class definingClass(Class cls, SEL sel) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned n = 0;
        Method *ms = class_copyMethodList(c, &n);
        BOOL found = NO;
        for (unsigned i = 0; i < n && !found; i++) if (method_getName(ms[i]) == sel) found = YES;
        free(ms);
        if (found) return c;
    }
    return Nil;
}

static void hookSelector(Class cls, SEL sel) {
    Class def = definingClass(cls, sel);
    if (!def || def == [NSObject class] || class_getSuperclass(def) == Nil) return;
    CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("%s|%s"), class_getName(def), sel_getName(sel));
    if (CFDictionaryContainsKey(renamed, key)) {
        CFRelease(key);
        return;
    }
    Method m = class_getInstanceMethod(def, sel);
    const char *types = method_getTypeEncoding(m);
    IMP imp = method_getImplementation(m);
    if (!types || imp == (IMP)_objc_msgForward) {
        CFRelease(key);
        return;
    }
    NSMethodSignature *sig = nil;
    @try { sig = [NSMethodSignature signatureWithObjCTypes:types]; } @catch (id e) { sig = nil; }
    if (!sig || strchr(types, '(') || strchr(types, '[')) {
        CFRelease(key);
        return;
    }
    // One hooked class per selector in any superclass chain: a hooked
    // subclass whose original calls super into a hooked superclass would
    // forward back to the subclass and loop.
    CFStringRef selKey = CFStringCreateWithCString(NULL, sel_getName(sel), kCFStringEncodingUTF8);
    CFMutableArrayRef list = (CFMutableArrayRef)CFDictionaryGetValue(hookedBySel, selKey);
    if (list) {
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            Class other = (__bridge Class)CFArrayGetValueAtIndex(list, i);
            for (Class c = def; c; c = class_getSuperclass(c)) if (c == other) goto clash;
            for (Class c = other; c; c = class_getSuperclass(c)) if (c == def) goto clash;
        }
    } else {
        list = CFArrayCreateMutable(NULL, 0, NULL);
        CFDictionarySetValue(hookedBySel, selKey, list);
        CFRelease(list);
    }
    CFArrayAppendValue(list, (__bridge const void *)def);
    CFRelease(selKey);
    goto hook;
clash:
    CFRelease(selKey);
    CFRelease(key);
    return;
hook:;
    char newName[512];
    snprintf(newName, sizeof newName, "mtlrec_%s_%s", class_getName(def), sel_getName(sel));
    SEL renamedSel = sel_registerName(newName);
    if (!class_addMethod(def, renamedSel, imp, types)) {
        CFRelease(key);
        return;
    }
    // forwardInvocation: of this class once.
    if (!CFDictionaryContainsKey(origForward, (__bridge const void *)def)) {
        IMP prev = class_getMethodImplementation(def, @selector(forwardInvocation:));
        CFDictionarySetValue(origForward, (__bridge const void *)def, (const void *)prev);
        class_replaceMethod(def, @selector(forwardInvocation:), (IMP)recForwardInvocation, "v@:@");
    }
    CFDictionarySetValue(renamed, key, (const void *)renamedSel);
    CFRelease(key);
    method_setImplementation(m, (IMP)_objc_msgForward);
}

static void hookClass(Class cls) {
    if (!cls) return;
    pthread_mutex_lock(&hookMu);
    if (CFSetContainsValue(hookedClasses, (__bridge const void *)cls)) {
        pthread_mutex_unlock(&hookMu);
        return;
    }
    CFSetAddValue(hookedClasses, (__bridge const void *)cls);
    int hooked = 0;
    NSMutableString *protos = [NSMutableString string];
    for (int i = 0; protocolNames[i]; i++) {
        Protocol *p = objc_getProtocol(protocolNames[i]);
        if (!p || !class_conformsToProtocol(cls, p)) {
            BOOL conforms = NO;
            for (Class c = cls; c && p && !conforms; c = class_getSuperclass(c)) conforms = class_conformsToProtocol(c, p);
            if (!conforms) continue;
        }
        [protos appendFormat:@" %s", protocolNames[i]];
        for (int req = 0; req < 2; req++) {
            unsigned n = 0;
            struct objc_method_description *d = protocol_copyMethodDescriptionList(p, req == 0, YES, &n);
            for (unsigned j = 0; j < n; j++) {
                if (skipSelector(sel_getName(d[j].name))) continue;
                if (!class_respondsToSelector(cls, d[j].name)) continue;
                hookSelector(cls, d[j].name);
                hooked++;
            }
            free(d);
        }
    }
    // MTLREC_ALL_METHODS="ClassA,ClassB": for these classes (and their
    // superclasses up to NSObject) also every instance method the class
    // itself defines, SPI included, apart from memory management, runtime
    // and forwarding methods and accessors skipped as above.
    const char *allm = getenv("MTLREC_ALL_METHODS");
    if (allm && *allm) {
        for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            const char *cn = class_getName(c);
            const char *hit = strstr(allm, cn);
            size_t cl = strlen(cn);
            if (!hit || (hit != allm && hit[-1] != ',') || (hit[cl] && hit[cl] != ',')) continue;
            unsigned n = 0;
            Method *ms = class_copyMethodList(c, &n);
            for (unsigned j = 0; j < n; j++) {
                const char *sn = sel_getName(method_getName(ms[j]));
                if (sn[0] == '.' || sn[0] == '_' || skipSelector(sn) || strstr(sn, "retain") || strstr(sn, "release") ||
                    strstr(sn, "dealloc") || strstr(sn, "autorelease") || strstr(sn, "forward") || strstr(sn, "methodSignature") ||
                    strstr(sn, "respondsTo") || strstr(sn, "isKindOf") || strstr(sn, "conformsTo") || strstr(sn, "description") ||
                    strcmp(sn, "class") == 0 || strcmp(sn, "hash") == 0 || strncmp(sn, "isEqual", 7) == 0 || strncmp(sn, "init", 4) == 0 ||
                    strncmp(sn, "mtlrec_", 7) == 0)
                    continue;
                hookSelector(c, method_getName(ms[j]));
                hooked++;
            }
            free(ms);
            [protos appendFormat:@" all(%s)", cn];
        }
    }
    pthread_mutex_unlock(&hookMu);
    if (hooked) emit("hooked class %s (%d selectors):%s", class_getName(cls), hooked, protos.UTF8String);
}

static void hookObjectClass(id o) {
    if (!o) return;
    Class c = object_getClass(o);
    if (class_isMetaClass(c)) return;
    pthread_mutex_lock(&hookMu);
    BOOL done = CFSetContainsValue(hookedClasses, (__bridge const void *)c);
    pthread_mutex_unlock(&hookMu);
    if (done) return;
    for (int i = 0; protocolNames[i]; i++) {
        Protocol *p = objc_getProtocol(protocolNames[i]);
        if (p && [o conformsToProtocol:p]) {
            hookClass(c);
            return;
        }
    }
}

// MARK: Entry points

static id<MTLDevice> rec_MTLCreateSystemDefaultDevice(void) NS_RETURNS_RETAINED;
static id<MTLDevice> rec_MTLCreateSystemDefaultDevice(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!out) return d;
    emit("MTLCreateSystemDefaultDevice -> %s", brief(d).UTF8String);
    emitStack();
    // MTLREC_NO_METAL=<process>,…: in these processes record look-ups only;
    // the Metal classes stay as they are.
    const char *nm = getenv("MTLREC_NO_METAL");
    const char *me = getprogname();
    const char *hit = nm ? strstr(nm, me) : NULL;
    size_t ml = strlen(me);
    if (!(hit && (hit == nm || hit[-1] == ',') && (hit[ml] == 0 || hit[ml] == ','))) hookObjectClass(d);
    return d;
}

static NSArray<id<MTLDevice>> *rec_MTLCopyAllDevices(void) NS_RETURNS_RETAINED;
static NSArray<id<MTLDevice>> *rec_MTLCopyAllDevices(void) {
    NSArray *all = MTLCopyAllDevices();
    if (!out) return all;
    emit("MTLCopyAllDevices -> %lu devices", (unsigned long)all.count);
    for (id d in all) hookObjectClass(d);
    return all;
}

// dlopen/dlsym (MTLREC_DL=1): which images and symbols a process looks up,
// with the result and the caller chain (a failed lookup can change a path).
static int dlLog = -1;
static int wantDL(void) {
    if (dlLog < 0) dlLog = out && getenv("MTLREC_DL") && *getenv("MTLREC_DL") == '1';
    return dlLog;
}

static void *rec_dlopen(const char *path, int mode) {
    void *h = dlopen(path, mode);
    if (wantDL()) {
        emit("dlopen(%s, 0x%x) -> %p%s%s", path ? path : "NULL", mode, h, h ? "" : " error ", h ? "" : dlerror());
        emitStack();
    }
    return h;
}

static void *rec_dlsym(void *handle, const char *name) {
    void *p = dlsym(handle, name);
    if (wantDL()) {
        emit("dlsym(%p, %s) -> %p", handle, name ? name : "NULL", p);
        emitStack();
    }
    return p;
}

static void windowNote(const char *what, unsigned long size) {
    if (!windowOpen || !pthread_main_np() || inHook) return;
    if (windowMax < 0) {
        const char *v = getenv("MTLREC_WINDOW_MAX");
        windowMax = v && *v ? atoi(v) : 3000;
    }
    if (windowLines >= windowMax) return;
    inHook = 1;
    char line[4096];
    buildStack(line, sizeof line);
    // MTLREC_WINDOW_MATCH=<text>: only chains that contain <text>.
    const char *match = getenv("MTLREC_WINDOW_MATCH");
    if (!match || !*match || strstr(line, match)) {
        windowLines++;
        emit("%s %lu", what, size);
        emit("    stack%s", line);
    }
    maybeScan(line);
    inHook = 0;
}

#include <malloc/malloc.h>
#include <os/lock.h>
static void *rec_malloc(size_t n) { windowNote("malloc", n); return malloc(n); }
static void *rec_calloc(size_t a, size_t b) { windowNote("calloc", a * b); return calloc(a, b); }
static void rec_os_unfair_lock_lock(os_unfair_lock_t l) { windowNote("os_unfair_lock_lock", 0); os_unfair_lock_lock(l); }
static int rec_pthread_mutex_lock(pthread_mutex_t *m) { windowNote("pthread_mutex_lock", 0); return pthread_mutex_lock(m); }
extern void *malloc_type_malloc(size_t, unsigned long long);
extern void *malloc_type_aligned_alloc(size_t, size_t, unsigned long long);
extern void *malloc_type_calloc(size_t, size_t, unsigned long long);
static void *rec_malloc_type_malloc(size_t n, unsigned long long t) { windowNote("malloc_type_malloc", n); return malloc_type_malloc(n, t); }
static void *rec_malloc_type_aligned_alloc(size_t a, size_t n, unsigned long long t) {
    windowNote("malloc_type_aligned_alloc", n);
    return malloc_type_aligned_alloc(a, n, t);
}
static void *rec_malloc_type_calloc(size_t a, size_t b, unsigned long long t) { windowNote("malloc_type_calloc", a * b); return malloc_type_calloc(a, b, t); }
extern void *_Znwm(unsigned long);
static void *rec_Znwm(unsigned long n) { windowNote("operator new", n); return _Znwm(n); }

// MARK: Look-ups (MTLREC_LOOKUPS=1)
//
// What a process consults before it decides whether a component exists:
// class look-ups by name, feature flags, MobileGestalt answers, OS variant
// checks, sysctl names, environment variables, preference reads made through
// the C API, and dispatch queues created (by label). Each distinct
// (function, key) is logged MTLREC_LOOKUP_LIMIT times (default 2) with its
// result and, with MTLREC_STACK, its caller chain. MTLREC_LOOKUP_MATCH=<text>
// keeps only look-ups whose chain contains <text>.

#include <errno.h>
#include <sys/sysctl.h>
#include <stdbool.h>

static int lookups = -1;
static unsigned lookupLimit = 2;
static pthread_mutex_t lkMu = PTHREAD_MUTEX_INITIALIZER;
static uint32_t lkKeys[8192];
static uint8_t lkCounts[8192];

static int wantLookups(void) {
    if (!out) return 0;
    if (lookups < 0) {
        // "1": in every recorded process; otherwise a list of process names.
        const char *lv = getenv("MTLREC_LOOKUPS");
        const char *me = getprogname();
        const char *hit = lv ? strstr(lv, me) : NULL;
        size_t ml = strlen(me);
        lookups = lv && ((lv[0] == '1' && lv[1] == 0) ||
                         (hit && (hit == lv || hit[-1] == ',') && (hit[ml] == 0 || hit[ml] == ',')));
        const char *l = getenv("MTLREC_LOOKUP_LIMIT");
        if (l && *l) lookupLimit = (unsigned)atoi(l);
    }
    return lookups && !(pthread_main_np() && inHook);
}

/// Whether this (function, key) is still under its limit.
static int lookupFresh(const char *fn, const char *key) {
    uint32_t h = 2166136261u;
    for (const char *p = fn; *p; p++) h = (h ^ (uint8_t)*p) * 16777619u;
    h = (h ^ '|') * 16777619u;
    for (const char *p = key ? key : "(null)"; *p; p++) h = (h ^ (uint8_t)*p) * 16777619u;
    if (h == 0) h = 1;
    int fresh = 0;
    pthread_mutex_lock(&lkMu);
    for (uint32_t i = 0; i < 8192; i++) {
        uint32_t s = (h + i) & 8191;
        if (lkKeys[s] == 0) { lkKeys[s] = h; lkCounts[s] = 1; fresh = 1; break; }
        if (lkKeys[s] == h) { if (lkCounts[s] < lookupLimit) { lkCounts[s]++; fresh = 1; } break; }
    }
    pthread_mutex_unlock(&lkMu);
    return fresh;
}

static void lookupNote(const char *fn, const char *key, const char *result) {
    int onMain = pthread_main_np(), saved = inHook;
    if (onMain) inHook = 1;
    char chain[4096];
    buildStack(chain, sizeof chain);
    const char *match = getenv("MTLREC_LOOKUP_MATCH");
    if ((!match || !*match || strstr(chain, match)) && lookupFresh(fn, key)) {
        emit("L %s(%s) -> %s", fn, key ? key : "(null)", result);
        if (chain[0]) emit("    stack%s", chain);
    }
    if (chain[0]) maybeScan(chain);
    if (onMain) inHook = saved;
}

static const char *cfKey(CFStringRef s, char *buf, size_t cap) {
    if (!s) return "(null)";
    if (CFGetTypeID(s) != CFStringGetTypeID()) return "(not a string)";
    if (!CFStringGetCString(s, buf, (CFIndex)cap, kCFStringEncodingUTF8)) return "(unconvertible)";
    return buf;
}

static void cfDescribe(CFTypeRef v, char *buf, size_t cap) {
    if (!v) { snprintf(buf, cap, "NULL"); return; }
    CFStringRef d = CFCopyDescription(v);
    if (!d || !CFStringGetCString(d, buf, (CFIndex)cap, kCFStringEncodingUTF8)) snprintf(buf, cap, "(type %lu)", (unsigned long)CFGetTypeID(v));
    if (d) CFRelease(d);
    for (char *p = buf; *p; p++) if (*p == '\n') *p = ' ';
}

extern bool _os_feature_enabled_impl(const char *domain, const char *feature);
extern bool _os_feature_enabled_simple_impl(const char *domain, const char *feature, bool enabledDefault);
extern bool os_variant_has_internal_content(const char *subsystem);
extern bool os_variant_has_internal_diagnostics(const char *subsystem);
extern bool os_variant_has_internal_ui(const char *subsystem);
extern bool os_variant_allows_internal_security_policies(const char *subsystem);
extern bool os_variant_is_darwinos(const char *subsystem);
extern bool os_variant_uses_ephemeral_storage(const char *subsystem);
extern bool MGGetBoolAnswer(CFStringRef question);
extern CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options);
extern CFTypeRef MGCopyAnswerWithError(CFStringRef question, CFDictionaryRef options, int *error);
extern int32_t MGGetSInt32Answer(CFStringRef question, int32_t fallback);
extern int64_t MGGetSInt64Answer(CFStringRef question, int64_t fallback);
extern float MGGetFloat32Answer(CFStringRef question, float fallback);
extern uint32_t MGGetProductType(void);

static bool rec_feature(const char *d, const char *f) {
    bool r = _os_feature_enabled_impl(d, f);
    if (wantLookups()) { char k[512]; snprintf(k, sizeof k, "%s/%s", d ? d : "?", f ? f : "?"); lookupNote("_os_feature_enabled_impl", k, r ? "YES" : "NO"); }
    return r;
}
static bool rec_feature_simple(const char *d, const char *f, bool def) {
    bool r = _os_feature_enabled_simple_impl(d, f, def);
    if (wantLookups()) { char k[512]; snprintf(k, sizeof k, "%s/%s default %d", d ? d : "?", f ? f : "?", def); lookupNote("_os_feature_enabled_simple_impl", k, r ? "YES" : "NO"); }
    return r;
}
#define VARIANT(name) \
    static bool rec_##name(const char *s) { bool r = name(s); if (wantLookups()) lookupNote(#name, s, r ? "YES" : "NO"); return r; }
VARIANT(os_variant_has_internal_content)
VARIANT(os_variant_has_internal_diagnostics)
VARIANT(os_variant_has_internal_ui)
VARIANT(os_variant_allows_internal_security_policies)
VARIANT(os_variant_is_darwinos)
VARIANT(os_variant_uses_ephemeral_storage)

static bool rec_MGGetBoolAnswer(CFStringRef q) {
    bool r = MGGetBoolAnswer(q);
    if (wantLookups()) { char k[256]; lookupNote("MGGetBoolAnswer", cfKey(q, k, sizeof k), r ? "YES" : "NO"); }
    return r;
}
static CFTypeRef rec_MGCopyAnswer(CFStringRef q, CFDictionaryRef o) {
    CFTypeRef r = MGCopyAnswer(q, o);
    if (wantLookups()) { char k[256], v[512]; cfDescribe(r, v, sizeof v); lookupNote("MGCopyAnswer", cfKey(q, k, sizeof k), v); }
    return r;
}
static CFTypeRef rec_MGCopyAnswerWithError(CFStringRef q, CFDictionaryRef o, int *e) {
    CFTypeRef r = MGCopyAnswerWithError(q, o, e);
    if (wantLookups()) { char k[256], v[600]; cfDescribe(r, v, 500); if (e) snprintf(v + strlen(v), 100, " err %d", *e); lookupNote("MGCopyAnswerWithError", cfKey(q, k, sizeof k), v); }
    return r;
}
static int32_t rec_MGGetSInt32Answer(CFStringRef q, int32_t d) {
    int32_t r = MGGetSInt32Answer(q, d);
    if (wantLookups()) { char k[256], v[64]; snprintf(v, sizeof v, "%d (fallback %d)", r, d); lookupNote("MGGetSInt32Answer", cfKey(q, k, sizeof k), v); }
    return r;
}
static int64_t rec_MGGetSInt64Answer(CFStringRef q, int64_t d) {
    int64_t r = MGGetSInt64Answer(q, d);
    if (wantLookups()) { char k[256], v[64]; snprintf(v, sizeof v, "%lld (fallback %lld)", (long long)r, (long long)d); lookupNote("MGGetSInt64Answer", cfKey(q, k, sizeof k), v); }
    return r;
}
static float rec_MGGetFloat32Answer(CFStringRef q, float d) {
    float r = MGGetFloat32Answer(q, d);
    if (wantLookups()) { char k[256], v[64]; snprintf(v, sizeof v, "%g (fallback %g)", r, d); lookupNote("MGGetFloat32Answer", cfKey(q, k, sizeof k), v); }
    return r;
}
static uint32_t rec_MGGetProductType(void) {
    uint32_t r = MGGetProductType();
    if (wantLookups()) { char v[32]; snprintf(v, sizeof v, "0x%x", r); lookupNote("MGGetProductType", "", v); }
    return r;
}
static int rec_sysctlbyname(const char *n, void *o, size_t *ol, void *nw, size_t nl) {
    int r = sysctlbyname(n, o, ol, nw, nl);
    if (wantLookups()) {
        char v[128];
        if (r != 0) snprintf(v, sizeof v, "%d errno %d", r, errno);
        else if (o && ol && *ol == 4) snprintf(v, sizeof v, "0 value %d", *(int32_t *)o);
        else if (o && ol && *ol == 8) snprintf(v, sizeof v, "0 value %lld", *(long long *)o);
        else snprintf(v, sizeof v, "0 len %zu", ol ? *ol : 0);
        lookupNote("sysctlbyname", n, v);
    }
    return r;
}
static int rec_sysctl(int *mib, unsigned n, void *o, size_t *ol, void *nw, size_t nl) {
    int r = sysctl(mib, n, o, ol, nw, nl);
    if (wantLookups()) {
        char k[96] = "", v[128];
        size_t used = 0;
        for (unsigned i = 0; i < n && i < 8 && used < sizeof k - 12; i++) used += (size_t)snprintf(k + used, sizeof k - used, "%s%d", i ? "." : "", mib[i]);
        if (r != 0) snprintf(v, sizeof v, "%d errno %d", r, errno);
        else if (o && ol && *ol == 4) snprintf(v, sizeof v, "0 value %d", *(int32_t *)o);
        else if (o && ol && *ol == 8) snprintf(v, sizeof v, "0 value %lld", *(long long *)o);
        else snprintf(v, sizeof v, "0 len %zu", ol ? *ol : 0);
        lookupNote("sysctl", k, v);
    }
    return r;
}
static int rec_sysctlnametomib(const char *name, int *mib, size_t *len) {
    int r = sysctlnametomib(name, mib, len);
    if (wantLookups()) {
        char v[96];
        if (r != 0) snprintf(v, sizeof v, "%d errno %d", r, errno);
        else snprintf(v, sizeof v, "0 mib %d.%d (len %zu)", len && *len > 0 ? mib[0] : -1, len && *len > 1 ? mib[1] : -1, len ? *len : 0);
        lookupNote("sysctlnametomib", name, v);
    }
    return r;
}
#import <IOSurface/IOSurfaceRef.h>
extern IOSurfaceRef IOSurfaceLookupFromXPCObject(xpc_object_t xobj);
extern xpc_object_t IOSurfaceCreateXPCObject(IOSurfaceRef aSurface);
static void surfaceNote(const char *fn, IOSurfaceRef s, const char *extra) {
    char v[160];
    if (s) snprintf(v, sizeof v, "surface id %u %zux%zu%s", IOSurfaceGetID(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), extra);
    else snprintf(v, sizeof v, "NULL%s", extra);
    lookupNote(fn, "", v);
}
extern IOSurfaceRef raw_IOSurfaceLookupFromXPCObject(void *x) __asm__("_IOSurfaceLookupFromXPCObject");
static IOSurfaceRef rec_IOSurfaceLookupFromXPCObject(void *x) {
    IOSurfaceRef r = raw_IOSurfaceLookupFromXPCObject(x);
    if (wantLookups()) surfaceNote("IOSurfaceLookupFromXPCObject", r, "");
    return r;
}
static IOSurfaceRef rec_IOSurfaceLookupFromMachPort(mach_port_t p) {
    IOSurfaceRef r = IOSurfaceLookupFromMachPort(p);
    if (wantLookups()) { char e[32]; snprintf(e, sizeof e, " (port 0x%x)", p); surfaceNote("IOSurfaceLookupFromMachPort", r, e); }
    return r;
}
static IOSurfaceRef rec_IOSurfaceLookup(IOSurfaceID i) {
    IOSurfaceRef r = IOSurfaceLookup(i);
    if (wantLookups()) { char e[32]; snprintf(e, sizeof e, " (id %u)", i); surfaceNote("IOSurfaceLookup", r, e); }
    return r;
}
static mach_port_t rec_IOSurfaceCreateMachPort(IOSurfaceRef s) {
    mach_port_t p = IOSurfaceCreateMachPort(s);
    if (wantLookups()) { char e[32]; snprintf(e, sizeof e, " -> port 0x%x", p); surfaceNote("IOSurfaceCreateMachPort", s, e); }
    return p;
}
static CFTypeRef rec_IOSurfaceCopyValue(IOSurfaceRef s, CFStringRef key) {
    CFTypeRef v = IOSurfaceCopyValue(s, key);
    if (wantLookups()) {
        char k[200], d[300];
        cfDescribe(v, d, sizeof d);
        lookupNote("IOSurfaceCopyValue", cfKey(key, k, sizeof k), d);
    }
    return v;
}
static void rec_IOSurfaceSetValue(IOSurfaceRef s, CFStringRef key, CFTypeRef value) {
    IOSurfaceSetValue(s, key, value);
    if (wantLookups()) {
        char k[200], d[300];
        cfDescribe(value, d, sizeof d);
        lookupNote("IOSurfaceSetValue", cfKey(key, k, sizeof k), d);
    }
}
extern void *raw_IOSurfaceCreateXPCObject(IOSurfaceRef s) __asm__("_IOSurfaceCreateXPCObject");
static void *rec_IOSurfaceCreateXPCObject(IOSurfaceRef s) {
    void *x = raw_IOSurfaceCreateXPCObject(s);
    if (wantLookups()) surfaceNote("IOSurfaceCreateXPCObject", s, x ? " -> object" : " -> NULL");
    return x;
}
// XPC dictionary reads (MTLREC_LOOKUPS=1; use MTLREC_LOOKUP_MATCH to keep
// only those under one caller): which keys a reply is read for.
extern void *raw_xpc_dictionary_get_value(void *d, const char *k) __asm__("_xpc_dictionary_get_value");
static void *rec_xpc_dictionary_get_value(void *d, const char *k) {
    void *v = raw_xpc_dictionary_get_value(d, k);
    if (wantLookups()) {
        char t[96] = "NULL";
        if (v) snprintf(t, sizeof t, "%s", xpc_type_get_name(xpc_get_type((__bridge xpc_object_t)v)));
        lookupNote("xpc_dictionary_get_value", k, t);
    }
    return v;
}
extern uint64_t raw_xpc_dictionary_get_uint64(void *d, const char *k) __asm__("_xpc_dictionary_get_uint64");
static uint64_t rec_xpc_dictionary_get_uint64(void *d, const char *k) {
    uint64_t v = raw_xpc_dictionary_get_uint64(d, k);
    if (wantLookups()) { char t[32]; snprintf(t, sizeof t, "%llu", (unsigned long long)v); lookupNote("xpc_dictionary_get_uint64", k, t); }
    return v;
}
extern int64_t raw_xpc_dictionary_get_int64(void *d, const char *k) __asm__("_xpc_dictionary_get_int64");
static int64_t rec_xpc_dictionary_get_int64(void *d, const char *k) {
    int64_t v = raw_xpc_dictionary_get_int64(d, k);
    if (wantLookups()) { char t[32]; snprintf(t, sizeof t, "%lld", (long long)v); lookupNote("xpc_dictionary_get_int64", k, t); }
    return v;
}
extern const void *raw_xpc_dictionary_get_data(void *d, const char *k, size_t *len) __asm__("_xpc_dictionary_get_data");
static const void *rec_xpc_dictionary_get_data(void *d, const char *k, size_t *len) {
    size_t l = 0;
    const void *v = raw_xpc_dictionary_get_data(d, k, &l);
    if (len) *len = l;
    if (wantLookups()) {
        char t[200];
        int n = snprintf(t, sizeof t, v ? "%zu bytes:" : "NULL", l);
        for (size_t i = 0; v && i < l && i < 32 && n < (int)sizeof t - 3; i++) n += snprintf(t + n, sizeof t - (size_t)n, "%02x", ((const uint8_t *)v)[i]);
        lookupNote("xpc_dictionary_get_data", k, t);
    }
    return v;
}
extern mach_port_t raw_xpc_dictionary_copy_mach_send(void *d, const char *k) __asm__("_xpc_dictionary_copy_mach_send");
static mach_port_t rec_xpc_dictionary_copy_mach_send(void *d, const char *k) {
    mach_port_t p = raw_xpc_dictionary_copy_mach_send(d, k);
    if (wantLookups()) { char t[32]; snprintf(t, sizeof t, "port 0x%x", p); lookupNote("xpc_dictionary_copy_mach_send", k, t); }
    return p;
}
static char *rec_getenv(const char *n) {
    char *r = getenv(n);
    if (wantLookups()) lookupNote("getenv", n, r ? r : "NULL");
    return r;
}
static Class rec_objc_getClass(const char *n) {
    Class r = objc_getClass(n);
    if (wantLookups()) lookupNote("objc_getClass", n, r ? "found" : "nil");
    return r;
}
static Class rec_objc_lookUpClass(const char *n) {
    Class r = objc_lookUpClass(n);
    if (wantLookups()) lookupNote("objc_lookUpClass", n, r ? "found" : "nil");
    return r;
}
static Class rec_NSClassFromString(NSString *n) {
    Class r = NSClassFromString(n);
    if (wantLookups()) lookupNote("NSClassFromString", n ? n.UTF8String : NULL, r ? "found" : "nil");
    return r;
}
static CFPropertyListRef rec_CFPreferencesCopyAppValue(CFStringRef k, CFStringRef a) {
    CFPropertyListRef r = CFPreferencesCopyAppValue(k, a);
    if (wantLookups()) {
        char kb[256], ab[256], key[600], v[300];
        snprintf(key, sizeof key, "%s in %s", cfKey(k, kb, sizeof kb), cfKey(a, ab, sizeof ab));
        cfDescribe(r, v, sizeof v);
        lookupNote("CFPreferencesCopyAppValue", key, v);
    }
    return r;
}
static Boolean rec_CFPreferencesGetAppBooleanValue(CFStringRef k, CFStringRef a, Boolean *valid) {
    Boolean ok = false;
    Boolean r = CFPreferencesGetAppBooleanValue(k, a, &ok);
    if (valid) *valid = ok;
    if (wantLookups()) {
        char kb[256], ab[256], key[600];
        snprintf(key, sizeof key, "%s in %s", cfKey(k, kb, sizeof kb), cfKey(a, ab, sizeof ab));
        lookupNote("CFPreferencesGetAppBooleanValue", key, ok ? (r ? "YES" : "NO") : "unset");
    }
    return r;
}
static CFIndex rec_CFPreferencesGetAppIntegerValue(CFStringRef k, CFStringRef a, Boolean *valid) {
    Boolean ok = false;
    CFIndex r = CFPreferencesGetAppIntegerValue(k, a, &ok);
    if (valid) *valid = ok;
    if (wantLookups()) {
        char kb[256], ab[256], key[600], v[64];
        snprintf(key, sizeof key, "%s in %s", cfKey(k, kb, sizeof kb), cfKey(a, ab, sizeof ab));
        if (ok) snprintf(v, sizeof v, "%ld", (long)r); else snprintf(v, sizeof v, "unset");
        lookupNote("CFPreferencesGetAppIntegerValue", key, v);
    }
    return r;
}
// Declared without ARC types: libdispatch creates queues before libobjc is
// initialized, and ARC's retain/release of the result would run then.
extern void *raw_dispatch_queue_create(const char *label, void *attr) __asm__("_dispatch_queue_create");
static void *rec_dispatch_queue_create(const char *label, void *attr) {
    void *q = raw_dispatch_queue_create(label, attr);
    if (out) scanRemember(label, q);
    if (wantLookups()) lookupNote("dispatch_queue_create", label, "queue");
    return q;
}

// MTLREC_QUEUE_MATCH=<text>: work submitted to dispatch queues whose label
// contains <text> (dispatch_async, dispatch_sync, their _f forms, barrier
// async): the submission with its caller chain, and the start and end of
// the work with the name of the function or block that runs.
// Raw (non-ARC) declarations: these run in every process, also before
// libobjc is initialized, so the pass-through path must not retain anything.
extern void raw_dispatch_async(void *q, void *b) __asm__("_dispatch_async");
extern void raw_dispatch_barrier_async(void *q, void *b) __asm__("_dispatch_barrier_async");
extern void raw_dispatch_sync(void *q, void *b) __asm__("_dispatch_sync");
extern void raw_dispatch_async_f(void *q, void *ctx, void (*f)(void *)) __asm__("_dispatch_async_f");
extern void raw_dispatch_sync_f(void *q, void *ctx, void (*f)(void *)) __asm__("_dispatch_sync_f");
extern const char *raw_dispatch_queue_get_label(void *q) __asm__("_dispatch_queue_get_label");

static const char *queueMatch(void *q) {
    if (!out || !q) return NULL;
    const char *m = getenv("MTLREC_QUEUE_MATCH");
    if (!m || !*m) return NULL;
    const char *label = raw_dispatch_queue_get_label(q);
    return label && strstr(label, m) ? label : NULL;
}

static const char *symbolOf(const void *pc, char *buf, size_t cap) {
    Dl_info info;
    if (pc && dladdr(pc, &info) && info.dli_fname) {
        const char *base = strrchr(info.dli_fname, '/');
        snprintf(buf, cap, "%s+0x%lx %s", base ? base + 1 : info.dli_fname, (unsigned long)((const char *)pc - (const char *)info.dli_fbase),
                 info.dli_sname ? info.dli_sname : "?");
    } else snprintf(buf, cap, "%p", pc);
    return buf;
}

static void queueNote(const char *how, const char *label, const void *work) {
    char sym[512];
    emit("Q %s(%s) %s", how, label, symbolOf(work, sym, sizeof sym));
    emitStack();
}

static const void *blockInvoke(void *b) { return b ? (const void *)((struct BlockLayout *)b)->invoke : NULL; }

static void rec_dispatch_async(void *q, void *b) {
    const char *label = queueMatch(q);
    if (!label) { raw_dispatch_async(q, b); return; }
    const void *fn = blockInvoke(b);
    queueNote("dispatch_async", label, fn);
    char *l = strdup(label);
    dispatch_block_t copy = [(__bridge dispatch_block_t)b copy];
    dispatch_block_t wrapper = ^{
        char sym[512];
        emit("Q start %s %s", l, symbolOf(fn, sym, sizeof sym));
        copy();
        emit("Q end %s %s", l, symbolOf(fn, sym, sizeof sym));
        free(l);
    };
    raw_dispatch_async(q, (__bridge void *)wrapper);
}
static void rec_dispatch_barrier_async(void *q, void *b) {
    const char *label = queueMatch(q);
    if (label) queueNote("dispatch_barrier_async", label, blockInvoke(b));
    raw_dispatch_barrier_async(q, b);
}
static void rec_dispatch_sync(void *q, void *b) {
    const char *label = queueMatch(q);
    if (label) queueNote("dispatch_sync", label, blockInvoke(b));
    raw_dispatch_sync(q, b);
    if (label) emit("Q sync returned (%s)", label);
}
static void rec_dispatch_async_f(void *q, void *ctx, void (*f)(void *)) {
    const char *label = queueMatch(q);
    if (label) queueNote("dispatch_async_f", label, (const void *)f);
    raw_dispatch_async_f(q, ctx, f);
}
static void rec_dispatch_sync_f(void *q, void *ctx, void (*f)(void *)) {
    const char *label = queueMatch(q);
    if (label) queueNote("dispatch_sync_f", label, (const void *)f);
    raw_dispatch_sync_f(q, ctx, f);
    if (label) emit("Q sync_f returned (%s)", label);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } lookupInterposers[] = {
    {(const void *)rec_feature, (const void *)_os_feature_enabled_impl},
    {(const void *)rec_feature_simple, (const void *)_os_feature_enabled_simple_impl},
    {(const void *)rec_os_variant_has_internal_content, (const void *)os_variant_has_internal_content},
    {(const void *)rec_os_variant_has_internal_diagnostics, (const void *)os_variant_has_internal_diagnostics},
    {(const void *)rec_os_variant_has_internal_ui, (const void *)os_variant_has_internal_ui},
    {(const void *)rec_os_variant_allows_internal_security_policies, (const void *)os_variant_allows_internal_security_policies},
    {(const void *)rec_os_variant_is_darwinos, (const void *)os_variant_is_darwinos},
    {(const void *)rec_os_variant_uses_ephemeral_storage, (const void *)os_variant_uses_ephemeral_storage},
    {(const void *)rec_MGGetBoolAnswer, (const void *)MGGetBoolAnswer},
    {(const void *)rec_MGCopyAnswer, (const void *)MGCopyAnswer},
    {(const void *)rec_MGCopyAnswerWithError, (const void *)MGCopyAnswerWithError},
    {(const void *)rec_MGGetSInt32Answer, (const void *)MGGetSInt32Answer},
    {(const void *)rec_MGGetSInt64Answer, (const void *)MGGetSInt64Answer},
    {(const void *)rec_MGGetFloat32Answer, (const void *)MGGetFloat32Answer},
    {(const void *)rec_MGGetProductType, (const void *)MGGetProductType},
    {(const void *)rec_sysctlbyname, (const void *)sysctlbyname},
    {(const void *)rec_sysctl, (const void *)sysctl},
    {(const void *)rec_sysctlnametomib, (const void *)sysctlnametomib},
    {(const void *)rec_getenv, (const void *)getenv},
    {(const void *)rec_xpc_dictionary_get_value, (const void *)raw_xpc_dictionary_get_value},
    {(const void *)rec_xpc_dictionary_get_uint64, (const void *)raw_xpc_dictionary_get_uint64},
    {(const void *)rec_xpc_dictionary_get_int64, (const void *)raw_xpc_dictionary_get_int64},
    {(const void *)rec_xpc_dictionary_get_data, (const void *)raw_xpc_dictionary_get_data},
    {(const void *)rec_xpc_dictionary_copy_mach_send, (const void *)raw_xpc_dictionary_copy_mach_send},
    {(const void *)rec_IOSurfaceLookupFromXPCObject, (const void *)raw_IOSurfaceLookupFromXPCObject},
    {(const void *)rec_IOSurfaceLookupFromMachPort, (const void *)IOSurfaceLookupFromMachPort},
    {(const void *)rec_IOSurfaceLookup, (const void *)IOSurfaceLookup},
    {(const void *)rec_IOSurfaceCopyValue, (const void *)IOSurfaceCopyValue},
    {(const void *)rec_IOSurfaceSetValue, (const void *)IOSurfaceSetValue},
    {(const void *)rec_IOSurfaceCreateMachPort, (const void *)IOSurfaceCreateMachPort},
    {(const void *)rec_IOSurfaceCreateXPCObject, (const void *)raw_IOSurfaceCreateXPCObject},
    {(const void *)rec_objc_getClass, (const void *)objc_getClass},
    {(const void *)rec_objc_lookUpClass, (const void *)objc_lookUpClass},
    {(const void *)rec_NSClassFromString, (const void *)NSClassFromString},
    {(const void *)rec_CFPreferencesCopyAppValue, (const void *)CFPreferencesCopyAppValue},
    {(const void *)rec_CFPreferencesGetAppBooleanValue, (const void *)CFPreferencesGetAppBooleanValue},
    {(const void *)rec_CFPreferencesGetAppIntegerValue, (const void *)CFPreferencesGetAppIntegerValue},
    {(const void *)rec_dispatch_queue_create, (const void *)raw_dispatch_queue_create},
    {(const void *)rec_REEngineInitWithConfiguration, (const void *)REEngineInitWithConfiguration},
    {(const void *)rec_dispatch_async, (const void *)raw_dispatch_async},
    {(const void *)rec_dispatch_barrier_async, (const void *)raw_dispatch_barrier_async},
    {(const void *)rec_dispatch_sync, (const void *)raw_dispatch_sync},
    {(const void *)rec_dispatch_async_f, (const void *)raw_dispatch_async_f},
    {(const void *)rec_dispatch_sync_f, (const void *)raw_dispatch_sync_f},
};

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } interposers[] = {
    {(const void *)rec_malloc, (const void *)malloc},
    {(const void *)rec_calloc, (const void *)calloc},
    {(const void *)rec_os_unfair_lock_lock, (const void *)os_unfair_lock_lock},
    {(const void *)rec_pthread_mutex_lock, (const void *)pthread_mutex_lock},
    {(const void *)rec_malloc_type_malloc, (const void *)malloc_type_malloc},
    {(const void *)rec_malloc_type_aligned_alloc, (const void *)malloc_type_aligned_alloc},
    {(const void *)rec_malloc_type_calloc, (const void *)malloc_type_calloc},
    {(const void *)rec_Znwm, (const void *)_Znwm},
    {(const void *)rec_MTLCreateSystemDefaultDevice, (const void *)MTLCreateSystemDefaultDevice},
    {(const void *)rec_MTLCopyAllDevices, (const void *)MTLCopyAllDevices},
    {(const void *)rec_dlopen, (const void *)dlopen},
    {(const void *)rec_dlsym, (const void *)dlsym},
};

__attribute__((constructor)) static void mtlrecInit(void) {
    t0 = nowNs();
    pthread_mutexattr_t a;
    pthread_mutexattr_init(&a);
    pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&hookMu, &a);
    hookedBySel = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    renamed = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
    counts = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    hookedClasses = CFSetCreateMutable(NULL, 0, NULL);
    origForward = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    openLog();
    emit("mtlrec loaded in %s pid %d", getprogname(), getpid());
}
