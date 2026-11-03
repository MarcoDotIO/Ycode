// rrmpeek (our own code, OBS-VISION-RRM 2026-11-01, dirty room): does any guest process use Metal rasterization
// rate maps, and what decides it? Inserted into a boot with SIMCTL_CHILD_DYLD_INSERT_LIBRARIES (every job).
// In every process (or only those named in RP_PROCS, comma list of program names) it logs, to $RP_DIR/rp.<prog>.<pid>
// (the file is opened on the first line, so processes that never touch these calls leave no file):
//  - MTLSimDevice supportsRasterizationRateMapWithLayerCount: (answer, layer count, the image of the caller),
//    newRasterizationRateMapWithDescriptor: (screen size, layers, zone counts, result), and the device's
//    maxRasterizationRateLayerCount / supportsVariableRateRasterization when it defines them;
//  - setRasterizationRateMap: on the render pass descriptor class (non-nil maps, caller image);
//  - every instance method whose name mentions foveation, VRR or rasterization rate in classes of the compositor,
//    RealityKit, CoreComposite, SpatialConnect and Metal-driver images (and the main executable), when its signature is a one-word getter or a
//    one-word setter: the value read or set (first calls per method, then every 1000th).
// RP_EARLY_SCAN=<comma list of programs>: also scan in the constructor (before main). RP_SEEN_ALL=1: see g_seenAll.
// The device is hooked when MTLSimDriver is loaded (add-image callback), with polling as a fallback.
// Diagnostic only, never a host input: RP_FORCE_RRM=1 makes supportsRasterizationRateMapWithLayerCount: answer YES.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static FILE *g_out; static double g_t0; static char g_dir[512];
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static int g_force;
static double wall(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }
static void rp(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void rp(const char *fmt, ...) {
    char line[4096]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    double w = wall(); pthread_mutex_lock(&g_mx);
    if (!g_out) { char p[1024]; snprintf(p, sizeof p, "%s/rp.%s.%d", g_dir, getprogname(), getpid()); g_out = fopen(p, "w"); }
    if (g_out) { fprintf(g_out, "%.3f +%.3f %s\n", w, w - g_t0, line); fflush(g_out); }
    pthread_mutex_unlock(&g_mx);
}
static const char *imgOf(const void *addr) {
    Dl_info i; if (dladdr(addr, &i) && i.dli_fname) { const char *s = strrchr(i.dli_fname, '/'); return s ? s + 1 : i.dli_fname; }
    return "?";
}
#define CALLER imgOf(__builtin_return_address(0))

// ------------------------------------------------------------ device
static IMP o_srrm, o_new, o_max, o_svr;
static int g_srrmN;
static BOOL h_srrm(id self, SEL c, NSUInteger n) {
    BOOL r = ((BOOL(*)(id, SEL, NSUInteger))o_srrm)(self, c, n);
    int k = __atomic_add_fetch(&g_srrmN, 1, __ATOMIC_RELAXED);
    if (k <= 12 || k % 1000 == 0) rp("supportsRasterizationRateMapWithLayerCount:%lu -> %d%s (call #%d, caller %s)", (unsigned long)n, r, g_force ? " forced YES" : "", k, CALLER);
    return g_force ? YES : r;
}
static id h_new(id self, SEL c, MTLRasterizationRateMapDescriptor *d) {
    const char *who = CALLER;
    char b[1024]; size_t o = 0;
    o += snprintf(b + o, sizeof b - o, "screen %lux%lu layers %lu label \"%s\"", (unsigned long)d.screenSize.width, (unsigned long)d.screenSize.height,
                  (unsigned long)d.layerCount, d.label ? d.label.UTF8String : "");
    for (NSUInteger l = 0; l < d.layerCount && l < 4; l++) {
        MTLRasterizationRateLayerDescriptor *ld = [d layerAtIndex:l]; if (!ld) continue;
        MTLSize s = ld.sampleCount;
        o += snprintf(b + o, sizeof b - o, " | layer %lu zones %lux%lu h", (unsigned long)l, (unsigned long)s.width, (unsigned long)s.height);
        for (NSUInteger i = 0; i < s.width && i < 16 && o < sizeof b - 32; i++) o += snprintf(b + o, sizeof b - o, " %.3g", ld.horizontalSampleStorage[i]);
        o += snprintf(b + o, sizeof b - o, " v");
        for (NSUInteger i = 0; i < s.height && i < 16 && o < sizeof b - 32; i++) o += snprintf(b + o, sizeof b - o, " %.3g", ld.verticalSampleStorage[i]);
    }
    id m = ((id(*)(id, SEL, id))o_new)(self, c, d);
    rp("newRasterizationRateMapWithDescriptor: %s -> %s (caller %s)", b, m ? object_getClassName(m) : "nil", who);
    if (m) { MTLSize p = [(id<MTLRasterizationRateMap>)m physicalSizeForLayer:0]; rp("   map physical size layer 0 %lux%lu", (unsigned long)p.width, (unsigned long)p.height); }
    return m;
}
static NSUInteger h_max(id self, SEL c) { NSUInteger r = ((NSUInteger(*)(id, SEL))o_max)(self, c); static int n; if (n++ < 6) rp("maxRasterizationRateLayerCount -> %lu (caller %s)", (unsigned long)r, CALLER); return r; }
static BOOL h_svr(id self, SEL c) { BOOL r = ((BOOL(*)(id, SEL))o_svr)(self, c); static int n; if (n++ < 6) rp("supportsVariableRateRasterization -> %d (caller %s, its caller %s)", r, CALLER, imgOf(__builtin_return_address(1))); return r; }

static IMP o_setmap; static int g_setmapN;
static void h_setmap(id self, SEL c, id map) {
    int k = __atomic_add_fetch(&g_setmapN, 1, __ATOMIC_RELAXED);
    if (map && (k <= 12 || k % 1000 == 0)) rp("renderPass setRasterizationRateMap: %s (#%d, caller %s)", object_getClassName(map), k, CALLER);
    ((void(*)(id, SEL, id))o_setmap)(self, c, map);
}
static BOOL hookDefined(Class c, SEL s, IMP imp, IMP *orig) {
    unsigned n = 0; Method *ms = class_copyMethodList(c, &n); Method m = NULL;
    for (unsigned i = 0; i < n; i++) if (method_getName(ms[i]) == s) { m = ms[i]; break; }
    free(ms);
    if (!m) { rp("%s does not define %s (inherited: %s)", class_getName(c), sel_getName(s), class_getInstanceMethod(c, s) ? "yes" : "no"); return NO; }
    *orig = method_setImplementation(m, imp); rp("hooked %s %s (impl in %s)", class_getName(c), sel_getName(s), imgOf((const void *)*orig)); return YES;
}
static void hookAny(Class c, SEL s, IMP imp, IMP *orig) {   // defined here or inherited: hook the method found
    Method m = class_getInstanceMethod(c, s);
    if (!m) { rp("no %s on %s", sel_getName(s), class_getName(c)); return; }
    *orig = method_setImplementation(m, imp); rp("hooked %s %s (impl in %s)", class_getName(c), sel_getName(s), imgOf((const void *)*orig));
}

// ------------------------------------------------------------ generic foveation/VRR methods
typedef struct { Class cls; SEL sel; IMP orig; char kind; char t; int count; } entry_t;
static entry_t g_e[768]; static int g_ne;
static entry_t *find(id self, SEL s) {
    for (Class k = object_getClass(self); k; k = class_getSuperclass(k))
        for (int i = 0; i < g_ne; i++) if (g_e[i].cls == k && g_e[i].sel == s) return &g_e[i];
    return NULL;
}
static void val(char t, uintptr_t v, char *b, size_t n) {
    if (t == '@') snprintf(b, n, "%s %p", v ? object_getClassName((__bridge id)(void *)v) : "nil", (void *)v);
    else if (t == 'B' || t == 'c' || t == 'C') snprintf(b, n, "%u", (unsigned)(v & 0xff));
    else if (t == 'i' || t == 'I') snprintf(b, n, "%d", (int)(uint32_t)v);
    else snprintf(b, n, "%ld", (long)v);
}
static uintptr_t gen_get(id self, SEL s) {
    entry_t *e = find(self, s); if (!e) return 0;
    uintptr_t r = ((uintptr_t(*)(id, SEL))e->orig)(self, s);
    int k = __atomic_add_fetch(&e->count, 1, __ATOMIC_RELAXED);
    if (k <= 4 || k % 1000 == 0) { char b[256]; val(e->t, r, b, sizeof b); rp("get -[%s %s] -> %s (#%d, caller %s)", class_getName(e->cls), sel_getName(s), b, k, CALLER); }
    return r;
}
static void gen_set(id self, SEL s, uintptr_t a) {
    entry_t *e = find(self, s); if (!e) return;
    int k = __atomic_add_fetch(&e->count, 1, __ATOMIC_RELAXED);
    if (k <= 6 || k % 1000 == 0) { char b[256]; val(e->t, a, b, sizeof b); rp("set -[%s %s] %s (#%d, caller %s)", class_getName(e->cls), sel_getName(s), b, k, CALLER); }
    ((void(*)(id, SEL, uintptr_t))e->orig)(self, s, a);
}
static int interesting(const char *n) {
    return strcasestr(n, "foveat") || strstr(n, "VRR") || strstr(n, "Vrr") || strstr(n, "vrr") || strcasestr(n, "rasterizationRate") || strcasestr(n, "eyeTrack");
}
static int wantedImage(const char *img) {
    if (!img) return 0;
    const char *keys[] = {"wakeboard", "Compositor", "CoreRE", "RealityKit", "RealitySimulation", "RealityFoundation", "MTLSimDriver", "BackBoard", "backboardd", "RealitySystemSupport", "CoreComposite", "SpatialConnect", NULL};
    for (int i = 0; keys[i]; i++) if (strstr(img, keys[i])) return 1;
    const char *base = strrchr(img, '/'); return base && !strcmp(base + 1, getprogname());   // the main executable
}
static int g_seenAll;   // RP_SEEN_ALL=1: in the 30 s scan also list (without hooking) matching methods of every other image

static int hooked(Class c, SEL s) { for (int i = 0; i < g_ne; i++) if (g_e[i].cls == c && g_e[i].sel == s) return 1; return 0; }
static int superDefines(Class c, SEL s) {   // only the top-most definer is hooked (avoids recursion through super calls)
    for (Class k = class_getSuperclass(c); k; k = class_getSuperclass(k)) {
        unsigned n = 0; Method *ms = class_copyMethodList(k, &n); int has = 0;
        for (unsigned i = 0; i < n; i++) if (method_getName(ms[i]) == s) { has = 1; break; }
        free(ms); if (has) return 1;
    }
    return 0;
}
static void scan(const char *when) {
    unsigned nc = 0; Class *cs = objc_copyClassList(&nc); int added = 0, skipped = 0;
    for (unsigned i = 0; i < nc && g_ne < (int)(sizeof g_e / sizeof *g_e); i++) {
        Class c = cs[i]; const char *img = class_getImageName(c);
        if (!wantedImage(img)) {
            if (g_seenAll && !strcmp(when, "at 30 s") && img) {
                unsigned nm = 0; Method *ms = class_copyMethodList(c, &nm);
                for (unsigned j = 0; j < nm; j++) { const char *n = sel_getName(method_getName(ms[j]));
                    if (interesting(n)) rp("seen elsewhere -[%s %s] type %s in %s", class_getName(c), n, method_getTypeEncoding(ms[j]) ?: "?", strrchr(img, '/') ? strrchr(img, '/') + 1 : img); }
                free(ms);
            }
            continue;
        }
        unsigned nm = 0; Method *ms = class_copyMethodList(c, &nm);
        for (unsigned j = 0; j < nm; j++) {
            SEL s = method_getName(ms[j]); const char *n = sel_getName(s);
            if (!interesting(n) || hooked(c, s)) continue;
            const char *ty = method_getTypeEncoding(ms[j]); if (!ty) continue;
            char rt = ty[0]; int nargs = (int)method_getNumberOfArguments(ms[j]);
            char at[32] = {0}; if (nargs == 3) method_getArgumentType(ms[j], 2, at, sizeof at);
            const char *ok = "@BcCqQiIlL";
            if (superDefines(c, s)) { skipped++; continue; }
            entry_t *e = &g_e[g_ne];
            if (nargs == 2 && rt && strchr(ok, rt)) { e->kind = 'g'; e->t = rt; }
            else if (nargs == 3 && rt == 'v' && at[0] && strchr(ok, at[0]) && at[1] == 0) { e->kind = 's'; e->t = at[0]; }
            else { rp("seen (not hooked, type %s) -[%s %s] in %s", ty, class_getName(c), n, strrchr(img, '/') ? strrchr(img, '/') + 1 : img); continue; }
            e->cls = c; e->sel = s; e->count = 0;
            e->orig = method_setImplementation(ms[j], e->kind == 'g' ? (IMP)gen_get : (IMP)gen_set);
            g_ne++; added++;
            rp("hooked -[%s %s] (%s, type %s) in %s", class_getName(c), n, e->kind == 'g' ? "getter" : "setter", ty, strrchr(img, '/') ? strrchr(img, '/') + 1 : img);
        }
        free(ms);
    }
    free(cs);
    rp("scan %s: %u classes, %d methods hooked (%d total), %d overrides skipped", when, nc, added, g_ne, skipped);
}

static int g_dev, g_later;
static void hookDevice(const char *how) {
    Class d = objc_getClass("MTLSimDevice");
    if (!d || __atomic_exchange_n(&g_dev, 1, __ATOMIC_SEQ_CST)) return;
    rp("MTLSimDevice hooked %s (image %s)", how, imgOf((const void *)class_getMethodImplementation(d, @selector(name))));
    if (!hookDefined(d, @selector(supportsRasterizationRateMapWithLayerCount:), (IMP)h_srrm, &o_srrm))
        hookAny(d, @selector(supportsRasterizationRateMapWithLayerCount:), (IMP)h_srrm, &o_srrm);
    hookAny(d, @selector(newRasterizationRateMapWithDescriptor:), (IMP)h_new, &o_new);
    SEL mx = sel_registerName("maxRasterizationRateLayerCount"), sv = sel_registerName("supportsVariableRateRasterization");
    if (class_getInstanceMethod(d, mx)) hookAny(d, mx, (IMP)h_max, &o_max);
    if (class_getInstanceMethod(d, sv)) hookAny(d, sv, (IMP)h_svr, &o_svr);
    g_later = 1;   // render-pass hook and scan run on our thread, not inside the image-load callback
}
static void addImage(const struct mach_header *mh, intptr_t slide) {   // hook as soon as the Metal driver is loaded
    (void)slide; Dl_info i;
    if (!g_dev && dladdr(mh, &i) && i.dli_fname && strstr(i.dli_fname, "MTLSimDriver")) hookDevice("at image load");
}
static void *hooker(void *arg) {
    (void)arg;
    for (int i = 0; i < 12000; i++) {
        if (!g_dev) { char how[64]; snprintf(how, sizeof how, "after %d polls", i); hookDevice(how); }
        if (g_later == 1) {
            g_later = 2;
            Class rpc = object_getClass([MTLRenderPassDescriptor renderPassDescriptor]);
            hookAny(rpc, @selector(setRasterizationRateMap:), (IMP)h_setmap, &o_setmap);
            scan("after Metal driver");
        }
        if (i == 1000) scan("at 5 s");
        if (i == 6000) { scan("at 30 s"); }
        if (g_dev && i > 6000) return NULL;
        usleep(5000);
    }
    return NULL;
}

__attribute__((constructor)) static void rp_init(void) {
    const char *me = getprogname(), *only = getenv("RP_PROCS");
    if (only && *only) { char buf[1024]; snprintf(buf, sizeof buf, ",%s,", only); char k[256]; snprintf(k, sizeof k, ",%s,", me); if (!strstr(buf, k)) return; }
    const char *d = getenv("RP_DIR"); if (!d || !*d) return;
    snprintf(g_dir, sizeof g_dir, "%s", d); g_t0 = wall(); g_force = getenv("RP_FORCE_RRM") != NULL;
    const char *early = getenv("RP_EARLY_SCAN");   // comma list of programs scanned already in the constructor
    if (early && *early) { char buf[1024]; snprintf(buf, sizeof buf, ",%s,", early); char k[256]; snprintf(k, sizeof k, ",%s,", me); if (strstr(buf, k)) scan("in constructor"); }
    g_seenAll = getenv("RP_SEEN_ALL") != NULL;
    _dyld_register_func_for_add_image(addImage);
    pthread_t th; pthread_create(&th, NULL, hooker, NULL); pthread_detach(th);
}
