// camrec (our own code, OBS-VISION-FOV 2026-11-01, dirty room): per-frame picture timing for the
// visionOS reference simulator. Inserted into a boot with SIMCTL_CHILD_DYLD_INSERT_LIBRARIES.
// backboardd: logs every PalomaPose event (vendor 0xFF00 / 0x72) at dispatch: mach time now, the
//   event's timestamp, translation and quaternion (fields as in visionos.md §5.5.10).
//   (pose timestamps are changed on the host side: vhid TS_OFFSET_MS.)
// wakeboardd: at every SFBSwapchainSwapAddSurface records mach time and the surface; while the file
//   $CR_DIR/on exists it samples the surface given at the previous swap (complete by then): rows
//   y = H/2, H/4, 3H/4, every 2nd pixel, as 8-bit luma, appended to $CR_DIR/frames.<pid>.bin as
//   (the file is closed when "on" goes away and reopened, appending, when it returns), as
//   records {u64 swap time of that surface, u32 surface id, u32 width, u32 rows, u32 samples, u8[rows*samples]}.
// Output: $CR_DIR/cr.<process>.<pid> (text log).
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static FILE *g_log, *g_bin; static int g_proc; static char g_dir[512];
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static void cr(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void cr(const char *fmt, ...) {
    if (!g_log) return; char line[2048]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    pthread_mutex_lock(&g_mx); fprintf(g_log, "%llu %s\n", mach_absolute_time(), line); fflush(g_log); pthread_mutex_unlock(&g_mx);
}

// ---------------------------------------------------------------- backboardd: pose events
typedef void *IOHIDServiceRef; typedef void *IOHIDEventRef;
extern void _IOHIDServiceDispatchEvent(IOHIDServiceRef, IOHIDEventRef) __attribute__((weak_import));
extern uint32_t IOHIDEventGetType(IOHIDEventRef) __attribute__((weak_import));
extern CFArrayRef IOHIDEventGetChildren(IOHIDEventRef) __attribute__((weak_import));
extern double IOHIDEventGetFloatValue(IOHIDEventRef, uint32_t) __attribute__((weak_import));
extern CFIndex IOHIDEventGetIntegerValue(IOHIDEventRef, uint32_t) __attribute__((weak_import));
extern uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef) __attribute__((weak_import));
extern uint32_t IOHIDEventGetEventFlags(IOHIDEventRef) __attribute__((weak_import));
extern void IOHIDEventSetEventFlags(IOHIDEventRef, uint32_t) __attribute__((weak_import));
// CR_PFLAGS / CR_TFLAGS / CR_OFLAGS (hex): before dispatch, set the event flags of a pose event's parent,
// Translation child and Orientation child (experiments on whether a flag changes the guest's camera smoothing).
static long envhex(const char *n) { const char *v = getenv(n); return v ? strtol(v, NULL, 16) : -1; }
static unsigned long g_other;
static void cr_dispatch(IOHIDServiceRef s, IOHIDEventRef e) {
    if (g_proc == 1 && e && IOHIDEventGetType(e) == 1 && IOHIDEventGetIntegerValue(e, (1 << 16) | 0) == 0xFF00) {
        CFIndex u = IOHIDEventGetIntegerValue(e, (1 << 16) | 1);
        if (u == 0x72) {
            double t[3] = {0}, q[4] = {0}; CFArrayRef c = IOHIDEventGetChildren(e);
            if (c) for (CFIndex k = 0; k < CFArrayGetCount(c); k++) { IOHIDEventRef ch = (IOHIDEventRef)CFArrayGetValueAtIndex(c, k); uint32_t ty = IOHIDEventGetType(ch);
                if (ty == 4) for (int i = 0; i < 3; i++) t[i] = IOHIDEventGetFloatValue(ch, (4 << 16) | i);
                if (ty == 10) for (int i = 0; i < 4; i++) q[i] = IOHIDEventGetFloatValue(ch, (10 << 16) | (8 + i)); }
            long pf = envhex("CR_PFLAGS"), tf = envhex("CR_TFLAGS"), of = envhex("CR_OFLAGS");
            if (pf >= 0) IOHIDEventSetEventFlags(e, (uint32_t)pf);
            if (c) for (CFIndex k = 0; k < CFArrayGetCount(c); k++) { IOHIDEventRef ch = (IOHIDEventRef)CFArrayGetValueAtIndex(c, k); uint32_t ty = IOHIDEventGetType(ch);
                if (ty == 4 && tf >= 0) IOHIDEventSetEventFlags(ch, (uint32_t)tf);
                if (ty == 10 && of >= 0) IOHIDEventSetEventFlags(ch, (uint32_t)of); }
            cr("POSE flags 0x%x ts %llu t %.4f %.4f %.4f q %.5f %.5f %.5f %.5f", IOHIDEventGetEventFlags(e), IOHIDEventGetTimeStamp(e), t[0], t[1], t[2], q[0], q[1], q[2], q[3]);
        } else if (__atomic_add_fetch(&g_other, 1, __ATOMIC_RELAXED) < 20) cr("VENDOR usage 0x%lx ts %llu", (long)u, IOHIDEventGetTimeStamp(e));
    }
    _IOHIDServiceDispatchEvent(s, e);
}

// ---------------------------------------------------------------- wakeboardd: swaps and samples
typedef struct { double x, y, w, h; } crrect_t;
extern bool SFBSwapchainSwapAddSurface(void *sc, void *surf, crrect_t src, crrect_t dst, long a, long b) __attribute__((weak_import));
static IOSurfaceRef g_prev; static uint64_t g_prevT; static unsigned long g_n; static char g_on[600];
static void sample(IOSurfaceRef s, uint64_t t) {
    struct stat st; if (stat(g_on, &st) != 0) { if (g_bin) { fclose(g_bin); g_bin = NULL; } return; }
    if (!g_bin) { char p[700]; snprintf(p, sizeof p, "%s/frames.%d.bin", g_dir, getpid()); g_bin = fopen(p, "ab"); if (!g_bin) return; }
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
    if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != 0) return;
    const uint8_t *b = IOSurfaceGetBaseAddress(s);
    uint32_t rows = 3, n = (uint32_t)(w / 2); static uint8_t buf[3 * 4096];
    size_t ys[3] = {h / 2, h / 4, 3 * h / 4};
    for (uint32_t r = 0; r < rows; r++) { const uint8_t *row = b + ys[r] * bpr;
        for (uint32_t i = 0; i < n && i < 4096; i++) { const uint8_t *px = row + (size_t)i * 2 * 4; buf[r * n + i] = (uint8_t)((px[0] * 29 + px[1] * 150 + px[2] * 77) >> 8); } }
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    uint32_t hdr[4] = {IOSurfaceGetID(s), (uint32_t)w, rows, n};
    fwrite(&t, 8, 1, g_bin); fwrite(hdr, 4, 4, g_bin); fwrite(buf, 1, rows * n, g_bin); fflush(g_bin);
}
static bool cr_add(void *sc, void *surf, crrect_t src, crrect_t dst, long a, long b) {
    uint64_t now = mach_absolute_time();
    bool r = SFBSwapchainSwapAddSurface(sc, surf, src, dst, a, b);
    if (g_proc == 2 && surf) {
        unsigned long n = ++g_n;
        if (n <= 3) cr("SWAP #%lu surf %u %zux%zu fmt 0x%x bpr %zu", n, IOSurfaceGetID(surf), IOSurfaceGetWidth(surf), IOSurfaceGetHeight(surf),
                        (unsigned)IOSurfaceGetPixelFormat(surf), IOSurfaceGetBytesPerRow(surf));
        if (g_prev) { sample(g_prev, g_prevT); CFRelease(g_prev); }
        g_prev = (IOSurfaceRef)CFRetain(surf); g_prevT = now;
    }
    return r;
}
__attribute__((used)) static struct { const void *r; const void *o; } cr_ip[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)cr_add, (const void *)SFBSwapchainSwapAddSurface},
    {(const void *)cr_dispatch, (const void *)_IOHIDServiceDispatchEvent},
};

__attribute__((constructor)) static void cr_init(void) {
    const char *me = getprogname();
    if (strcmp(me, "backboardd") == 0) g_proc = 1; else if (strcmp(me, "wakeboardd") == 0) g_proc = 2; else return;
    const char *d = getenv("CR_DIR"); snprintf(g_dir, sizeof g_dir, "%s", d && *d ? d : "/tmp");
    snprintf(g_on, sizeof g_on, "%s/on", g_dir);
    char path[700]; snprintf(path, sizeof path, "%s/cr.%s.%d", g_dir, me, getpid());
    g_log = fopen(path, "w");
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    cr("loaded in %s pid %d timebase %u/%u", me, getpid(), tb.numer, tb.denom);
}
