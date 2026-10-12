/*
 * sfbprobe: Ycode research probe (original Ycode code, no Apple code).
 * Runs inside a booted iOS simulator (xcrun simctl spawn). Opens the
 * simulator framebuffer client library with dlopen, calls the functions it
 * exports BY NAME with controlled arguments, and prints what comes back:
 * x0/x1/d0-d3 after each call and which bytes of our marker-filled buffers
 * (0xAA) the call wrote. Risky getters run in a forked child with a timeout.
 *
 * Usage: sfbprobe [library path] [phase...]
 *   phases: info conn displays swap all (default all)
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define DEFAULT_REAL "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/Platforms/iphoneos/Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer"

extern void raw_call(void *fn, const uint64_t x[9], const double d[8], uint64_t out[2], double outd[4]);

static void *g_lib;

/* ------------------------------------------------------------ describing */

static int readable(uint64_t a, void *buf, size_t n)
{
    if (a < 0x100000 || (a >> 47)) return 0;
    vm_address_t ra = (vm_address_t)a;
    vm_size_t rs = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj))
        return 0;
    if (ra > a || a + n > ra + rs || (info.protection & VM_PROT_EXECUTE)) return 0;
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)buf, &got) == KERN_SUCCESS && got == n;
}

static int known_class(uintptr_t c)
{
    static Class *cl; static unsigned n;
    if (!cl) cl = objc_copyClassList(&n);
    for (unsigned i = 0; i < n; i++) if ((uintptr_t)cl[i] == c) return 1;
    return 0;
}

static const char *class_of(uint64_t v)
{
    if (!v) return NULL;
    if (v >> 63) {
        Class c = object_getClass((id)v);
        if (c && known_class((uintptr_t)c)) {
            const char *n = class_getName(c);
            if (strstr(n, "TaggedPointerString") || strstr(n, "NSCFNumber")) return n;
        }
        return NULL;
    }
    uint64_t isa;
    if (!readable(v, &isa, 8)) return NULL;
    uintptr_t c = (uintptr_t)(isa & 0x0000000ffffffff8ULL);
    return (c && known_class(c)) ? class_getName((Class)c) : NULL;
}

static void desc(uint64_t v)
{
    printf("0x%llx", (unsigned long long)v);
    const char *cn = class_of(v);
    if (cn) {
        CFStringRef d = CFCopyDescription((CFTypeRef)v);
        char buf[2048] = "";
        if (d) { CFStringGetCString(d, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(d); }
        for (char *p = buf; *p; p++) if (*p == '\n') *p = ' ';
        printf(" <%s> {%s}", cn, buf);
        return;
    }
    char s[256];
    if (readable(v, s, 64)) {
        int i = 0;
        while (i < 64 && s[i] >= 32 && s[i] < 127) i++;
        if (i >= 2 && i < 64 && s[i] == 0) printf(" \"%s\"", s);
    }
}

/* ------------------------------------------------------------ calling */

struct res { uint64_t x0, x1; double d[4]; };

static void *fn(const char *name)
{
    void *p = dlsym(g_lib, name);
    if (!p) printf("!! no symbol %s\n", name);
    return p;
}

static struct res callx(const char *name, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                        uint64_t a4, uint64_t a5, const double *dv)
{
    uint64_t x[9] = { a0, a1, a2, a3, a4, a5, 0, 0, 0 };
    double d[8] = { 0 };
    if (dv) memcpy(d, dv, sizeof d);
    struct res r = { 0 };
    uint64_t out[2]; double od[4];
    void *f = fn(name);
    if (!f) return r;
    raw_call(f, x, d, out, od);
    r.x0 = out[0]; r.x1 = out[1]; memcpy(r.d, od, sizeof od);
    return r;
}

static void show(const char *label, struct res r)
{
    printf("%s -> x0=", label);
    desc(r.x0);
    printf(" x1=0x%llx d0..d3=%g %g %g %g\n", (unsigned long long)r.x1, r.d[0], r.d[1], r.d[2], r.d[3]);
}

#define BUFN 256
static unsigned char g_buf[4][BUFN];

static void fill_bufs(void) { memset(g_buf, 0xAA, sizeof g_buf); }

static void show_bufs(void)
{
    for (int b = 0; b < 4; b++) {
        int last = -1;
        for (int i = 0; i < BUFN; i++) if (g_buf[b][i] != 0xAA) last = i;
        if (last < 0) continue;
        printf("    buf%d written, last changed byte %d:", b, last);
        for (int i = 0; i <= last; i++) printf("%s%02x", (i % 4) ? "" : " ", g_buf[b][i]);
        printf("\n");
        for (int i = 0; i + 8 <= last + 1; i += 8) {
            uint64_t w; memcpy(&w, &g_buf[b][i], 8);
            if (class_of(w)) { printf("      word@%d = ", i); desc(w); printf("\n"); }
        }
    }
}

/* Run one call in a forked child (timeout 3 s), print result and buffer writes. */
static void battery(const char *name, uint64_t a0, int mode, uint64_t idx)
{
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) {
        alarm(3);
        fill_bufs();
        struct res r;
        if (mode == 0)
            r = callx(name, a0, (uint64_t)g_buf[1], (uint64_t)g_buf[2], (uint64_t)g_buf[3], 0, 0, NULL);
        else
            r = callx(name, a0, idx, (uint64_t)g_buf[2], (uint64_t)g_buf[3], 0, 0, NULL);
        char label[160];
        snprintf(label, sizeof label, "  %s(obj%s)", name, mode ? ", index" : ", &b1, &b2, &b3");
        if (mode) snprintf(label, sizeof label, "  %s(obj, %llu, &b2, &b3)", name, (unsigned long long)idx);
        show(label, r);
        show_bufs();
        fflush(stdout);
        _exit(0);
    }
    int st = 0;
    waitpid(p, &st, 0);
    if (!WIFEXITED(st)) printf("  %s: child died (signal %d)\n", name, WIFSIGNALED(st) ? WTERMSIG(st) : -1);
}

/* ------------------------------------------------------------ handlers */

static void install_handlers(uint64_t conn, dispatch_queue_t q)
{
    void (^connected)(void *, uint64_t, uint64_t) = ^(void *a, uint64_t b, uint64_t c) {
        printf("  [connected handler] a="); desc((uint64_t)a); printf(" b=0x%llx c=0x%llx\n",
               (unsigned long long)b, (unsigned long long)c); fflush(stdout); };
    void (^disconnected)(void *, uint64_t, uint64_t) = ^(void *a, uint64_t b, uint64_t c) {
        printf("  [disconnected handler] a="); desc((uint64_t)a); printf(" b=0x%llx c=0x%llx\n",
               (unsigned long long)b, (unsigned long long)c); fflush(stdout); };
    void (^updated)(void *, uint64_t, uint64_t) = ^(void *a, uint64_t b, uint64_t c) {
        printf("  [updated handler] a="); desc((uint64_t)a); printf(" b=0x%llx c=0x%llx\n",
               (unsigned long long)b, (unsigned long long)c); fflush(stdout); };
    show("SFBConnectionSetDisplayConnectedHandler(conn, q, blk)",
         callx("SFBConnectionSetDisplayConnectedHandler", conn, (uint64_t)q, (uint64_t)connected, 0, 0, 0, NULL));
    show("SFBConnectionSetDisplayDisconnectedHandler(conn, q, blk)",
         callx("SFBConnectionSetDisplayDisconnectedHandler", conn, (uint64_t)q, (uint64_t)disconnected, 0, 0, 0, NULL));
    show("SFBConnectionSetDisplayUpdatedHandler(conn, q, blk)",
         callx("SFBConnectionSetDisplayUpdatedHandler", conn, (uint64_t)q, (uint64_t)updated, 0, 0, 0, NULL));
}

static const char *display_getters[] = {
    "SFBDisplayGetID", "SFBDisplayGetConnectionID", "SFBDisplayGetType", "SFBDisplayGetName",
    "SFBDisplayGetDeviceName", "SFBDisplayGetDisplayUID", "SFBDisplayGetPowerState",
    "SFBDisplayGetFlags", "SFBDisplayGetModeCount", "SFBDisplayGetPreferredMode",
    "SFBDisplayGetCurrentMode", "SFBDisplayGetDeviceSize", "SFBDisplayGetCurrentCanvasSize",
    "SFBDisplayGetCanvasSizeCount", "SFBDisplayGetDotPitch", "SFBDisplayGetMaxLayerCount",
    "SFBDisplayGetMaxSwapchainCount", "SFBDisplayGetSupportedPresentationModes",
    "SFBDisplayGetSupportedSurfaceFlags", "SFBDisplayGetMaskPath", "SFBDisplayGetExtendedProperties",
    "SFBDisplayCopyExtendedPropertyProtocols", NULL
};

static const char *swapchain_getters[] = {
    "SFBSwapchainGetID", "SFBSwapchainGetDisplayID", "SFBSwapchainGetConnectionID",
    "SFBSwapchainGetFramebufferSize", "SFBSwapchainGetPixelFormat", "SFBSwapchainGetColorspace",
    "SFBSwapchainGetPresentationMode", "SFBSwapchainGetHDRMode", "SFBSwapchainGetMaxSurfacesPerOperation", NULL
};

static int want(int argc, char **argv, const char *phase)
{
    if (argc <= 2) return 1;
    for (int i = 2; i < argc; i++) if (!strcmp(argv[i], phase) || !strcmp(argv[i], "all")) return 1;
    return 0;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *path = argc > 1 && argv[1][0] == '/' ? argv[1] : DEFAULT_REAL;
    g_lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    printf("dlopen %s -> %p %s\n", path, g_lib, g_lib ? "" : dlerror());
    if (!g_lib) return 1;

    printf("== info\n");
    struct res pn = callx("simFramebufferServerPortName", 0, 0, 0, 0, 0, 0, NULL);
    show("simFramebufferServerPortName()", pn);
    /* The result is a C string returned to us; print it (bounded). */
    if (pn.x0) printf("  as string: \"%.*s\"\n", 200, (const char *)pn.x0);
    show("_SFBGetServerPort() before", callx("_SFBGetServerPort", 0, 0, 0, 0, 0, 0, NULL));
    show("SFBConnectionGetTypeID()", callx("SFBConnectionGetTypeID", 0, 0, 0, 0, 0, 0, NULL));
    show("SFBDisplayGetTypeID()", callx("SFBDisplayGetTypeID", 0, 0, 0, 0, 0, 0, NULL));
    show("SFBSwapchainGetTypeID()", callx("SFBSwapchainGetTypeID", 0, 0, 0, 0, 0, 0, NULL));
    show("SFBSetGetEmpty()", callx("SFBSetGetEmpty", 0, 0, 0, 0, 0, 0, NULL));
    if (!want(argc, argv, "conn")) return 0;

    printf("== conn\n");
    dispatch_queue_t q = dispatch_queue_create("ycode.r4.handlers", NULL);
    struct res r = callx("SFBConnectionCreate", 0, (uint64_t)CFSTR("YcodeR4Probe"), 0, 0, 0, 0, NULL);
    show("SFBConnectionCreate(NULL, \"YcodeR4Probe\")", r);
    uint64_t conn = r.x0;
    if (!conn) return 1;
    show("SFBConnectionGetID(conn) before connect", callx("SFBConnectionGetID", conn, 0, 0, 0, 0, 0, NULL));
    if (want(argc, argv, "handlers")) install_handlers(conn, q);
    CFErrorRef err = NULL;
    uint64_t t0 = mach_absolute_time();
    r = callx("SFBConnectionConnect", conn, (uint64_t)&err, 0, 0, 0, 0, NULL);
    show("SFBConnectionConnect(conn, &err)", r);
    printf("  connect took %llu ticks; err=", (unsigned long long)(mach_absolute_time() - t0));
    desc((uint64_t)err); printf("\n");
    show("SFBConnectionGetID(conn) after connect", callx("SFBConnectionGetID", conn, 0, 0, 0, 0, 0, NULL));
    show("_SFBGetServerPort() after", callx("_SFBGetServerPort", 0, 0, 0, 0, 0, 0, NULL));
    if (!want(argc, argv, "displays")) return 0;

    printf("== displays\n");
    err = NULL;
    r = callx("SFBConnectionCopyDisplays", conn, (uint64_t)&err, 0, 0, 0, 0, NULL);
    show("SFBConnectionCopyDisplays(conn, &err)", r);
    CFArrayRef displays = (CFArrayRef)r.x0;
    CFIndex n = displays ? CFArrayGetCount(displays) : 0;
    for (CFIndex i = 0; i < n; i++) {
        uint64_t d = (uint64_t)CFArrayGetValueAtIndex(displays, i);
        printf("-- display %ld ", (long)i); desc(d); printf("\n");
        for (int g = 0; display_getters[g]; g++) battery(display_getters[g], d, 0, 0);
        struct res mc = callx("SFBDisplayGetModeCount", d, 0, 0, 0, 0, 0, NULL);
        for (uint64_t m = 0; m < mc.x0 && m < 16; m++) battery("SFBDisplayGetMode", d, 1, m);
        struct res cc = callx("SFBDisplayGetCanvasSizeCount", d, 0, 0, 0, 0, 0, NULL);
        for (uint64_t m = 0; m < cc.x0 && m < 16; m++) battery("SFBDisplayGetCanvasSize", d, 1, m);
        struct res id = callx("SFBDisplayGetID", d, 0, 0, 0, 0, 0, NULL);
        err = NULL;
        show("  SFBConnectionCopyDisplay(conn, GetID(d), &err)",
             callx("SFBConnectionCopyDisplay", conn, id.x0, (uint64_t)&err, 0, 0, 0, NULL));
        struct res uid = callx("SFBDisplayGetDisplayUID", d, 0, 0, 0, 0, 0, NULL);
        show("  SFBConnectionCopyDisplayByUID(conn, GetDisplayUID(d))",
             callx("SFBConnectionCopyDisplayByUID", conn, uid.x0, 0, 0, 0, 0, NULL));
        struct res dn = callx("SFBDisplayGetDeviceName", d, 0, 0, 0, 0, 0, NULL);
        show("  SFBConnectionCopyDisplayByUID(conn, GetDeviceName(d))",
             callx("SFBConnectionCopyDisplayByUID", conn, dn.x0, 0, 0, 0, 0, NULL));
    }
    if (!want(argc, argv, "swap") || n == 0) { sleep(1); return 0; }

    printf("== swap\n");
    CFIndex di = getenv("SFBPROBE_DISPLAY") ? atoi(getenv("SFBPROBE_DISPLAY")) : 0;
    if (di >= n) di = 0;
    printf("swapchain on display index %ld\n", (long)di);
    uint64_t d0 = (uint64_t)CFArrayGetValueAtIndex(displays, di);
    double sizes[8] = { 0 };
    const char *dims = getenv("SFBPROBE_SC_SIZE"); /* "W,H" passed in d0/d1 */
    if (dims) sscanf(dims, "%lf,%lf", &sizes[0], &sizes[1]);
    uint64_t count = getenv("SFBPROBE_SC_COUNT") ? strtoull(getenv("SFBPROBE_SC_COUNT"), 0, 0) : 2;
    CFDictionaryRef opts = NULL;
    if (getenv("SFBPROBE_FENCES")) {
        CFStringRef k = *(CFStringRef *)dlsym(g_lib, "kSFBSwapchainOptionUseFences");
        const void *keys[] = { k }, *vals[] = { kCFBooleanTrue };
        opts = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    err = NULL;
    r = callx("SFBDisplayCreateSwapchain", d0, count, (uint64_t)opts, (uint64_t)&err, 0, 0, sizes);
    printf("(count=%llu opts=%p d0,d1=%g,%g) ", (unsigned long long)count, (void *)opts, sizes[0], sizes[1]);
    show("SFBDisplayCreateSwapchain(display, count, opts, &err)", r);
    printf("  err="); desc((uint64_t)err); printf("\n");
    uint64_t sc = r.x0;
    if (!sc) return 0;
    for (int g = 0; swapchain_getters[g]; g++) battery(swapchain_getters[g], sc, 0, 0);

    struct res fb = callx("SFBSwapchainGetFramebufferSize", sc, 0, 0, 0, 0, 0, NULL);
    int W = (int)fb.d[0], H = (int)fb.d[1];
    if (W <= 0 || H <= 0) { W = 64; H = 64; }
    int fmt = 'BGRA', bpe = 4;
    CFNumberRef nW = CFNumberCreate(NULL, kCFNumberIntType, &W), nH = CFNumberCreate(NULL, kCFNumberIntType, &H);
    CFNumberRef nF = CFNumberCreate(NULL, kCFNumberIntType, &fmt), nB = CFNumberCreate(NULL, kCFNumberIntType, &bpe);
    const void *k2[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfacePixelFormat, kIOSurfaceBytesPerElement, kIOSurfaceName };
    const void *v2[] = { nW, nH, nF, nB, CFSTR("YcodeR4Probe") };
    CFDictionaryRef sprops = CFDictionaryCreate(NULL, k2, v2, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surf = IOSurfaceCreate(sprops);
    printf("  surface %dx%d -> ", W, H); desc((uint64_t)surf); printf("\n");

    int frames = getenv("SFBPROBE_FRAMES") ? atoi(getenv("SFBPROBE_FRAMES")) : 3;
    for (int f = 0; f < frames; f++) {
        uint64_t now = mach_absolute_time();
        err = NULL;
        r = callx("SFBSwapchainSwapBegin", sc, now, (uint64_t)&err, 0, 0, 0, NULL);
        printf("frame %d (begin time 0x%llx) ", f, (unsigned long long)now);
        show("SFBSwapchainSwapBegin(sc, now, &err)", r);
        /* Two CGRects (source, destination) travel in d0-d3 and d4-d7. */
        double rect[8] = { 0, 0, W, H, 0, 0, W, H };
        if (getenv("SFBPROBE_DST")) sscanf(getenv("SFBPROBE_DST"), "%lf,%lf,%lf,%lf", &rect[4], &rect[5], &rect[6], &rect[7]);
        r = callx("SFBSwapchainSwapAddSurface", sc, (uint64_t)surf, 0, 0, 0, 0, rect);
        printf("  (rects %g,%g,%g,%g / %g,%g,%g,%g) ", rect[0], rect[1], rect[2], rect[3], rect[4], rect[5], rect[6], rect[7]);
        show("SFBSwapchainSwapAddSurface(sc, surf, 0, 0; d0-d7 = src, dst)", r);
        void (^cb)(void *, void *, uint64_t, uint64_t, void *) = ^(void *e, void *s, uint64_t a, uint64_t b, void *ctx) {
            printf("  [swap callback] err="); desc((uint64_t)e); printf(" sc="); desc((uint64_t)s);
            printf(" a=0x%llx b=0x%llx ctx=%p now=0x%llx\n", (unsigned long long)a, (unsigned long long)b, ctx,
                   (unsigned long long)mach_absolute_time());
            fflush(stdout);
        };
        r = callx("SFBSwapchainSwapSetCallback", sc, 0x1234500 + f, 0, (uint64_t)cb, 0, 0, NULL);
        show("  SFBSwapchainSwapSetCallback(sc, ctx, 0, blk)", r);
        err = NULL;
        uint64_t t1 = mach_absolute_time();
        r = callx("SFBSwapchainSwapSubmit", sc, (uint64_t)&err, 0, 0, 0, 0, NULL);
        show("  SFBSwapchainSwapSubmit(sc, &err)", r);
        printf("  submit took %llu ticks; err=", (unsigned long long)(mach_absolute_time() - t1));
        desc((uint64_t)err); printf("\n");
        usleep(200000);
    }
    sleep(1);
    printf("== done\n");
    return 0;
}
