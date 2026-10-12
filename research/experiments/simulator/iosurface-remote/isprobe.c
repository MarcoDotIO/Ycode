/*
 * isprobe: an IOSurface client written only against the PUBLIC IOSurface API
 * (IOSurfaceRef.h / IOSurfaceTypes.h). Original Ycode code (R5). It exercises
 * the calls whose wire traffic ismitm/isinterpose record, one step at a time,
 * printing "ISPROBE <step>" markers so captures can be aligned with calls.
 *
 * Usage: isprobe <test>[,<test>...] [args]
 *   basic      create BGRA 64x32, getters, lock/unlock (ro, avoid-sync), write, seeds, release
 *   values     set/copy/copy-all/remove values (string, number, data, dict, array)
 *   use        increment/decrement use count, is-in-use
 *   purge      set purgeable volatile / non-volatile / keep-current
 *   port       create mach port, look it up in the same process
 *   xpc        create XPC object, look it up
 *   formats    create surfaces in several sizes and pixel formats; print layouts
 *   share      create, fill, put a mach port in registered slot 2, spawn a child
 *              ("isprobe child-port") that looks it up, maps it and checks the pattern
 *   global     create with kIOSurfaceIsGlobal, spawn "isprobe child-id <id>"
 *   lookupid   IOSurfaceLookup(<id>) of an id this process did not create (arg)
 *   name       create with kIOSurfaceName "LCD"
 *   big        create the 1398x2034 BGRA surface backboardd uses
 *   wait       sleep 1 s (marker spacing)
 */
#include <IOSurface/IOSurfaceRef.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;
static const char *g_self;

#define MARK(...) do { printf("ISPROBE "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); usleep(30000); } while (0)

static CFNumberRef num(long v) { return CFNumberCreate(NULL, kCFNumberLongType, &v); }

static CFMutableDictionaryRef props(long w, long h, long bpe, uint32_t fmt)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    CFNumberRef a = num(w), b = num(h), c = num(bpe), f = num((long)fmt);
    CFDictionarySetValue(d, kIOSurfaceWidth, a);
    CFDictionarySetValue(d, kIOSurfaceHeight, b);
    if (bpe) CFDictionarySetValue(d, kIOSurfaceBytesPerElement, c);
    CFDictionarySetValue(d, kIOSurfacePixelFormat, f);
    CFRelease(a); CFRelease(b); CFRelease(c); CFRelease(f);
    return d;
}

static void region(const char *what, void *addr)
{
    vm_address_t a = (vm_address_t)(uintptr_t)addr;
    vm_size_t sz = 0;
    natural_t depth = 1;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
    kern_return_t kr = vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt);
    if (kr) { printf("  %s region: kr=0x%x\n", what, kr); return; }
    printf("  %s region: start=0x%llx size=0x%llx (addr offset 0x%llx) prot=%d max=%d share_mode=%d user_tag=%d ref_count=%u obj_id=0x%x\n",
           what, (unsigned long long)a, (unsigned long long)sz,
           (unsigned long long)((uintptr_t)addr - a), info.protection, info.max_protection, info.share_mode,
           info.user_tag, info.ref_count, info.object_id);
}

static void show(const char *tag, IOSurfaceRef s)
{
    if (!s) { printf("  %s: NULL\n", tag); return; }
    printf("  %s: id=%u w=%zu h=%zu bpe=%zu bpr=%zu ew=%zu eh=%zu alloc=%zu fmt=0x%08x '%c%c%c%c' planes=%zu seed=%u base=%p use=%d inuse=%d\n",
           tag, IOSurfaceGetID(s), IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), IOSurfaceGetBytesPerElement(s),
           IOSurfaceGetBytesPerRow(s), IOSurfaceGetElementWidth(s), IOSurfaceGetElementHeight(s),
           IOSurfaceGetAllocSize(s), IOSurfaceGetPixelFormat(s),
           (IOSurfaceGetPixelFormat(s) >> 24) & 0xff, (IOSurfaceGetPixelFormat(s) >> 16) & 0xff,
           (IOSurfaceGetPixelFormat(s) >> 8) & 0xff, IOSurfaceGetPixelFormat(s) & 0xff,
           IOSurfaceGetPlaneCount(s), IOSurfaceGetSeed(s), IOSurfaceGetBaseAddress(s),
           IOSurfaceGetUseCount(s), IOSurfaceIsInUse(s));
    for (size_t p = 0; p < IOSurfaceGetPlaneCount(s); p++)
        printf("    plane %zu: w=%zu h=%zu bpe=%zu bpr=%zu ew=%zu eh=%zu base=%p (offset 0x%lx)\n", p,
               IOSurfaceGetWidthOfPlane(s, p), IOSurfaceGetHeightOfPlane(s, p),
               IOSurfaceGetBytesPerElementOfPlane(s, p), IOSurfaceGetBytesPerRowOfPlane(s, p),
               IOSurfaceGetElementWidthOfPlane(s, p), IOSurfaceGetElementHeightOfPlane(s, p),
               IOSurfaceGetBaseAddressOfPlane(s, p),
               (long)((char *)IOSurfaceGetBaseAddressOfPlane(s, p) - (char *)IOSurfaceGetBaseAddress(s)));
    region("base", IOSurfaceGetBaseAddress(s));
    fflush(stdout);
}

static void fill(IOSurfaceRef s, uint32_t v)
{
    uint32_t *p = IOSurfaceGetBaseAddress(s);
    size_t n = IOSurfaceGetAllocSize(s) / 4;
    for (size_t i = 0; i < n; i++) p[i] = v ^ (uint32_t)i;
}

static int check(IOSurfaceRef s, uint32_t v)
{
    uint32_t *p = IOSurfaceGetBaseAddress(s);
    size_t n = IOSurfaceGetAllocSize(s) / 4, bad = 0;
    for (size_t i = 0; i < n; i++) if (p[i] != (v ^ (uint32_t)i)) bad++;
    return (int)bad;
}

static void t_basic(void)
{
    MARK("basic: create 64x32 BGRA bpe 4");
    CFMutableDictionaryRef d = props(64, 32, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    show("created", s);
    if (!s) return;
    uint32_t seed = 0;
    MARK("basic: lock 0");
    kern_return_t kr = IOSurfaceLock(s, 0, &seed);
    printf("  lock kr=0x%x seed=%u\n", kr, seed);
    fill(s, 0x11223344);
    MARK("basic: unlock 0");
    kr = IOSurfaceUnlock(s, 0, &seed);
    printf("  unlock kr=0x%x seed=%u getseed=%u\n", kr, seed, IOSurfaceGetSeed(s));
    MARK("basic: lock readonly");
    kr = IOSurfaceLock(s, kIOSurfaceLockReadOnly, &seed);
    printf("  lock(ro) kr=0x%x seed=%u bad=%d\n", kr, seed, check(s, 0x11223344));
    MARK("basic: unlock readonly");
    kr = IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, &seed);
    printf("  unlock(ro) kr=0x%x seed=%u\n", kr, seed);
    MARK("basic: lock avoid-sync");
    kr = IOSurfaceLock(s, kIOSurfaceLockAvoidSync, &seed);
    printf("  lock(avoid) kr=0x%x seed=%u\n", kr, seed);
    MARK("basic: unlock avoid-sync");
    kr = IOSurfaceUnlock(s, kIOSurfaceLockAvoidSync, &seed);
    printf("  unlock(avoid) kr=0x%x seed=%u\n", kr, seed);
    MARK("basic: unlock again (not locked)");
    kr = IOSurfaceUnlock(s, 0, &seed);
    printf("  unlock(unlocked) kr=0x%x seed=%u\n", kr, seed);
    MARK("basic: getters");
    show("after", s);
    MARK("basic: release");
    CFRelease(s);
    MARK("basic: done");
}

static void t_values(void)
{
    MARK("values: create");
    CFMutableDictionaryRef d = props(16, 16, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    MARK("values: set string YcodeStr=hello");
    IOSurfaceSetValue(s, CFSTR("YcodeStr"), CFSTR("hello"));
    MARK("values: set number YcodeNum=42");
    CFNumberRef n = num(42);
    IOSurfaceSetValue(s, CFSTR("YcodeNum"), n);
    MARK("values: set data YcodeData=01020304");
    const uint8_t bytes[4] = {1, 2, 3, 4};
    CFDataRef data = CFDataCreate(NULL, bytes, 4);
    IOSurfaceSetValue(s, CFSTR("YcodeData"), data);
    MARK("values: set dict and array");
    const void *k[1] = { CFSTR("inner") }, *v[1] = { n };
    CFDictionaryRef dict = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceSetValue(s, CFSTR("YcodeDict"), dict);
    CFArrayRef arr = CFArrayCreate(NULL, v, 1, &kCFTypeArrayCallBacks);
    IOSurfaceSetValue(s, CFSTR("YcodeArr"), arr);
    MARK("values: copy YcodeStr");
    CFTypeRef got = IOSurfaceCopyValue(s, CFSTR("YcodeStr"));
    CFShow(got ? got : CFSTR("(null)"));
    if (got) CFRelease(got);
    MARK("values: copy missing key");
    got = IOSurfaceCopyValue(s, CFSTR("YcodeMissing"));
    printf("  missing -> %p\n", got);
    MARK("values: copy all");
    CFDictionaryRef all = IOSurfaceCopyAllValues(s);
    CFShow(all ? (CFTypeRef)all : CFSTR("(null)"));
    if (all) CFRelease(all);
    MARK("values: remove YcodeNum");
    IOSurfaceRemoveValue(s, CFSTR("YcodeNum"));
    MARK("values: set values (dict of 2)");
    const void *k2[2] = { CFSTR("YcodeA"), CFSTR("YcodeB") }, *v2[2] = { CFSTR("a"), CFSTR("b") };
    CFDictionaryRef two = CFDictionaryCreate(NULL, k2, v2, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceSetValues(s, two);
    MARK("values: remove all");
    IOSurfaceRemoveAllValues(s);
    MARK("values: copy all after remove");
    all = IOSurfaceCopyAllValues(s);
    CFShow(all ? (CFTypeRef)all : CFSTR("(null)"));
    if (all) CFRelease(all);
    CFRelease(two); CFRelease(arr); CFRelease(dict); CFRelease(data); CFRelease(n);
    MARK("values: release");
    CFRelease(s);
    MARK("values: done");
}

static void t_use(void)
{
    MARK("use: create");
    CFMutableDictionaryRef d = props(16, 16, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    MARK("use: getusecount");
    printf("  use=%d inuse=%d\n", IOSurfaceGetUseCount(s), IOSurfaceIsInUse(s));
    MARK("use: increment");
    IOSurfaceIncrementUseCount(s);
    MARK("use: getusecount");
    printf("  use=%d inuse=%d\n", IOSurfaceGetUseCount(s), IOSurfaceIsInUse(s));
    MARK("use: decrement");
    IOSurfaceDecrementUseCount(s);
    MARK("use: getusecount");
    printf("  use=%d inuse=%d\n", IOSurfaceGetUseCount(s), IOSurfaceIsInUse(s));
    MARK("use: release");
    CFRelease(s);
    MARK("use: done");
}

static void t_purge(void)
{
    MARK("purge: create");
    CFMutableDictionaryRef d = props(16, 16, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    uint32_t old = 99;
    MARK("purge: volatile");
    kern_return_t kr = IOSurfaceSetPurgeable(s, kIOSurfacePurgeableVolatile, &old);
    printf("  kr=0x%x old=%u\n", kr, old);
    MARK("purge: keep-current");
    kr = IOSurfaceSetPurgeable(s, kIOSurfacePurgeableKeepCurrent, &old);
    printf("  kr=0x%x old=%u\n", kr, old);
    MARK("purge: non-volatile");
    kr = IOSurfaceSetPurgeable(s, kIOSurfacePurgeableNonVolatile, &old);
    printf("  kr=0x%x old=%u\n", kr, old);
    MARK("purge: release");
    CFRelease(s);
    MARK("purge: done");
}

static void t_port(void)
{
    MARK("port: create");
    CFMutableDictionaryRef d = props(32, 8, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    show("created", s);
    MARK("port: create mach port");
    mach_port_t p = IOSurfaceCreateMachPort(s);
    mach_port_type_t ty = 0;
    mach_port_type(mach_task_self(), p, &ty);
    printf("  port=0x%x type=0x%x\n", p, ty);
    MARK("port: create mach port again");
    mach_port_t p2 = IOSurfaceCreateMachPort(s);
    printf("  port2=0x%x (same name: %d)\n", p2, p == p2);
    MARK("port: lookup from mach port");
    IOSurfaceRef t = IOSurfaceLookupFromMachPort(p);
    printf("  lookup -> %p (same object: %d)\n", (void *)t, t == s);
    show("looked-up", t);
    MARK("port: release looked-up");
    if (t) CFRelease(t);
    mach_port_deallocate(mach_task_self(), p);
    mach_port_deallocate(mach_task_self(), p2);
    MARK("port: release");
    CFRelease(s);
    MARK("port: done");
}

extern void *IOSurfaceCreateXPCObject(IOSurfaceRef);
extern IOSurfaceRef IOSurfaceLookupFromXPCObject(void *);
static void t_xpc(void)
{
    MARK("xpc: create");
    CFMutableDictionaryRef d = props(8, 8, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    MARK("xpc: create xpc object");
    void *x = IOSurfaceCreateXPCObject(s);
    printf("  xpc=%p\n", x);
    MARK("xpc: lookup from xpc object");
    IOSurfaceRef t = x ? IOSurfaceLookupFromXPCObject(x) : NULL;
    printf("  lookup -> %p same=%d\n", (void *)t, t == s);
    if (t) CFRelease(t);
    MARK("xpc: release");
    CFRelease(s);
    MARK("xpc: done");
}

static void make_one(const char *label, CFMutableDictionaryRef d)
{
    MARK("formats: %s", label);
    IOSurfaceRef s = IOSurfaceCreate(d);
    show(label, s);
    if (s) CFRelease(s);
}

static void t_formats(void)
{
    struct { long w, h, bpe; uint32_t f; } c[] = {
        { 1, 1, 4, 'BGRA' }, { 3, 5, 4, 'BGRA' }, { 100, 100, 4, 'BGRA' }, { 1000, 10, 4, 'BGRA' },
        { 1398, 2034, 4, 'BGRA' }, { 64, 64, 4, 'RGBA' }, { 64, 64, 1, 'L008' }, { 64, 64, 2, 'L016' },
        { 64, 64, 8, 'RGhA' }, { 64, 64, 4, 'l10r' }, { 64, 64, 0, 'BGRA' },
    };
    for (size_t i = 0; i < sizeof c / sizeof c[0]; i++) {
        char lab[64];
        snprintf(lab, sizeof lab, "%ldx%ld bpe%ld %c%c%c%c", c[i].w, c[i].h, c[i].bpe,
                 (c[i].f >> 24) & 0xff, (c[i].f >> 16) & 0xff, (c[i].f >> 8) & 0xff, c[i].f & 0xff);
        CFMutableDictionaryRef d = props(c[i].w, c[i].h, c[i].bpe, c[i].f);
        make_one(lab, d);
        CFRelease(d);
    }
    /* Explicit bytes per row and alloc size. */
    CFMutableDictionaryRef d = props(10, 10, 4, 'BGRA');
    CFNumberRef bpr = num(256), as = num(65536);
    CFDictionarySetValue(d, kIOSurfaceBytesPerRow, bpr);
    make_one("10x10 BGRA bpr 256", d);
    CFDictionarySetValue(d, kIOSurfaceAllocSize, as);
    make_one("10x10 BGRA bpr 256 alloc 65536", d);
    CFRelease(d); CFRelease(bpr); CFRelease(as);
    /* Bi-planar 4:2:0 ('420v') with explicit plane info, as CoreVideo would pass. */
    d = props(64, 48, 0, '420v');
    CFMutableArrayRef planes = CFArrayCreateMutable(NULL, 2, &kCFTypeArrayCallBacks);
    long pw[2] = { 64, 32 }, ph[2] = { 48, 24 }, pb[2] = { 1, 2 }, prow[2] = { 64, 64 }, poff[2] = { 0, 64 * 48 };
    for (int i = 0; i < 2; i++) {
        CFMutableDictionaryRef p = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFNumberRef a = num(pw[i]), b = num(ph[i]), e = num(pb[i]), r = num(prow[i]), o = num(poff[i]), sz = num(prow[i] * ph[i]);
        CFDictionarySetValue(p, kIOSurfacePlaneWidth, a);
        CFDictionarySetValue(p, kIOSurfacePlaneHeight, b);
        CFDictionarySetValue(p, kIOSurfacePlaneBytesPerElement, e);
        CFDictionarySetValue(p, kIOSurfacePlaneBytesPerRow, r);
        CFDictionarySetValue(p, kIOSurfacePlaneOffset, o);
        CFDictionarySetValue(p, kIOSurfacePlaneSize, sz);
        CFArrayAppendValue(planes, p);
        CFRelease(p); CFRelease(a); CFRelease(b); CFRelease(e); CFRelease(r); CFRelease(o); CFRelease(sz);
    }
    CFDictionarySetValue(d, kIOSurfacePlaneInfo, planes);
    CFNumberRef total = num(64 * 48 + 64 * 24);
    CFDictionarySetValue(d, kIOSurfaceAllocSize, total);
    make_one("64x48 420v two planes", d);
    CFRelease(total); CFRelease(planes); CFRelease(d);
    /* Invalid: zero width. */
    d = props(0, 10, 4, 'BGRA');
    make_one("0x10 BGRA (invalid)", d);
    CFRelease(d);
    MARK("formats: done");
}

static pid_t spawn_self(const char *a1, const char *a2)
{
    char *argv[] = { (char *)g_self, (char *)a1, (char *)a2, NULL };
    pid_t pid = 0;
    int e = posix_spawn(&pid, g_self, NULL, NULL, argv, environ);
    if (e) { printf("  spawn failed %d\n", e); return -1; }
    return pid;
}

static void t_share(void)
{
    MARK("share: create 128x64 BGRA");
    CFMutableDictionaryRef d = props(128, 64, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    IOSurfaceLock(s, 0, NULL);
    fill(s, 0xC0DE0000);
    IOSurfaceUnlock(s, 0, NULL);
    show("parent", s);
    MARK("share: create mach port");
    mach_port_t p = IOSurfaceCreateMachPort(s);
    mach_port_t *old = NULL;
    mach_msg_type_number_t n = 0;
    mach_ports_lookup(mach_task_self(), &old, &n);
    mach_port_t slots[3] = { n > 0 ? old[0] : MACH_PORT_NULL, n > 1 ? old[1] : MACH_PORT_NULL, p };
    kern_return_t kr = mach_ports_register(mach_task_self(), slots, 3);
    printf("  registered slot 2 kr=0x%x port=0x%x\n", kr, p);
    MARK("share: spawn child");
    pid_t pid = spawn_self("child-port", NULL);
    int st = 0;
    if (pid > 0) waitpid(pid, &st, 0);
    printf("  child status 0x%x\n", st);
    MARK("share: after child, parent sees");
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    uint32_t first = *(uint32_t *)IOSurfaceGetBaseAddress(s);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    printf("  parent first word after child = 0x%08x (child writes 0xFEEDFACE)\n", first);
    show("parent", s);
    MARK("share: release");
    CFRelease(s);
    MARK("share: done");
}

static void child_port(void)
{
    mach_port_t *ports = NULL;
    mach_msg_type_number_t n = 0;
    mach_ports_lookup(mach_task_self(), &ports, &n);
    mach_port_t p = n > 2 ? ports[2] : MACH_PORT_NULL;
    MARK("child: lookup from mach port 0x%x", p);
    IOSurfaceRef s = IOSurfaceLookupFromMachPort(p);
    show("child", s);
    if (!s) return;
    MARK("child: lock");
    IOSurfaceLock(s, 0, NULL);
    printf("  child pattern mismatches: %d of %zu words\n", check(s, 0xC0DE0000), IOSurfaceGetAllocSize(s) / 4);
    *(uint32_t *)IOSurfaceGetBaseAddress(s) = 0xFEEDFACE;
    MARK("child: unlock");
    IOSurfaceUnlock(s, 0, NULL);
    MARK("child: release");
    CFRelease(s);
    MARK("child: done");
}

static void child_id(const char *arg)
{
    IOSurfaceID id = (IOSurfaceID)strtoul(arg ? arg : "0", NULL, 0);
    MARK("child: lookup id %u", id);
    IOSurfaceRef s = IOSurfaceLookup(id);
    show("child-id", s);
    if (s) {
        printf("  child-id pattern mismatches: %d\n", check(s, 0xC0DE0000));
        MARK("child: release");
        CFRelease(s);
    }
    MARK("child: done");
}

static void t_global(void)
{
    MARK("global: create IsGlobal");
    CFMutableDictionaryRef d = props(32, 32, 4, 'BGRA');
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CFDictionarySetValue(d, kIOSurfaceIsGlobal, kCFBooleanTrue);
#pragma clang diagnostic pop
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    IOSurfaceLock(s, 0, NULL);
    fill(s, 0xC0DE0000);
    IOSurfaceUnlock(s, 0, NULL);
    char id[32];
    snprintf(id, sizeof id, "%u", IOSurfaceGetID(s));
    MARK("global: spawn child for id %s", id);
    pid_t pid = spawn_self("child-id", id);
    int st = 0;
    if (pid > 0) waitpid(pid, &st, 0);
    MARK("global: lookup own id in parent");
    IOSurfaceRef t = IOSurfaceLookup(IOSurfaceGetID(s));
    printf("  parent lookup -> %p same=%d\n", (void *)t, t == s);
    if (t) CFRelease(t);
    MARK("global: release");
    CFRelease(s);
    MARK("global: done");
}

static void t_name(void)
{
    MARK("name: create with name LCD");
    CFMutableDictionaryRef d = props(16, 16, 4, 'BGRA');
    CFDictionarySetValue(d, kIOSurfaceName, CFSTR("LCD"));
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    show("named", s);
    if (s) CFRelease(s);
    MARK("name: done");
}

static void t_big(void)
{
    MARK("big: create 1398x2034 BGRA");
    CFMutableDictionaryRef d = props(1398, 2034, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    show("big", s);
    if (s) { IOSurfaceLock(s, 0, NULL); fill(s, 1); IOSurfaceUnlock(s, 0, NULL); CFRelease(s); }
    MARK("big: done");
}

static void t_limits(void)
{
    struct { const char *n; CFStringRef k; } ks[] = {
        { "Width", kIOSurfaceWidth }, { "Height", kIOSurfaceHeight }, { "BytesPerRow", kIOSurfaceBytesPerRow },
        { "BytesPerElement", kIOSurfaceBytesPerElement }, { "ElementWidth", kIOSurfaceElementWidth },
        { "ElementHeight", kIOSurfaceElementHeight }, { "Offset", kIOSurfaceOffset }, { "AllocSize", kIOSurfaceAllocSize },
        { "PlaneWidth", kIOSurfacePlaneWidth }, { "PlaneHeight", kIOSurfacePlaneHeight },
        { "PlaneBytesPerRow", kIOSurfacePlaneBytesPerRow }, { "PlaneOffset", kIOSurfacePlaneOffset },
        { "PlaneSize", kIOSurfacePlaneSize },
    };
    MARK("limits: property maximum and alignment");
    for (size_t i = 0; i < sizeof ks / sizeof ks[0]; i++)
        printf("  %s max=0x%zx align=0x%zx\n", ks[i].n, IOSurfaceGetPropertyMaximum(ks[i].k), IOSurfaceGetPropertyAlignment(ks[i].k));
    MARK("limits: done");
}

extern Boolean IOSurfaceAllowsPixelSizeCasting(IOSurfaceRef);
static void t_cast(void)
{
    MARK("cast: create with PixelSizeCastingAllowed false");
    CFMutableDictionaryRef d = props(16, 16, 4, 'BGRA');
    CFDictionarySetValue(d, kIOSurfacePixelSizeCastingAllowed, kCFBooleanFalse);
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    printf("  allows casting: %d\n", s ? IOSurfaceAllowsPixelSizeCasting(s) : -1);
    if (s) CFRelease(s);
    MARK("cast: create default");
    d = props(16, 16, 4, 'BGRA');
    s = IOSurfaceCreate(d);
    CFRelease(d);
    printf("  allows casting: %d\n", s ? IOSurfaceAllowsPixelSizeCasting(s) : -1);
    if (s) CFRelease(s);
    MARK("cast: done");
}

/* Create a surface that is NOT global, fill it, and leave without releasing. */
static void t_leak(void)
{
    MARK("leak: create (not global), fill, exit without release");
    CFMutableDictionaryRef d = props(32, 32, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    IOSurfaceLock(s, 0, NULL);
    fill(s, 0xC0DE0000);
    IOSurfaceUnlock(s, 0, NULL);
    printf("LEAKED_ID %u\n", IOSurfaceGetID(s));
    fflush(stdout);
}

/* Non-global surface: a child looks it up by id while the parent still holds it. */
static void t_idshare(void)
{
    MARK("idshare: create (not global)");
    CFMutableDictionaryRef d = props(32, 32, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    IOSurfaceLock(s, 0, NULL);
    fill(s, 0xC0DE0000);
    IOSurfaceUnlock(s, 0, NULL);
    char id[32];
    snprintf(id, sizeof id, "%u", IOSurfaceGetID(s));
    MARK("idshare: spawn child for id %s", id);
    pid_t pid = spawn_self("child-id", id);
    int st = 0;
    if (pid > 0) waitpid(pid, &st, 0);
    MARK("idshare: release");
    CFRelease(s);
    MARK("idshare: done");
}

/* When does IsInUse become true? */
static void t_inuse(void)
{
    MARK("inuse: create");
    CFMutableDictionaryRef d = props(16, 16, 4, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    if (!s) return;
    printf("  fresh: inuse=%d\n", IOSurfaceIsInUse(s));
    MARK("inuse: create mach port");
    mach_port_t p = IOSurfaceCreateMachPort(s);
    printf("  with port: inuse=%d\n", IOSurfaceIsInUse(s));
    MARK("inuse: deallocate port");
    mach_port_deallocate(mach_task_self(), p);
    usleep(300000);
    printf("  port gone: inuse=%d\n", IOSurfaceIsInUse(s));
    MARK("inuse: lookup by id in same process");
    IOSurfaceRef t = IOSurfaceLookup(IOSurfaceGetID(s));
    printf("  second ref: inuse=%d\n", IOSurfaceIsInUse(s));
    if (t) CFRelease(t);
    usleep(100000);
    printf("  second ref released: inuse=%d\n", IOSurfaceIsInUse(s));
    MARK("inuse: release");
    CFRelease(s);
    MARK("inuse: done");
}

int main(int argc, char **argv)
{
    g_self = argv[0];
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: isprobe tests\n"); return 2; }
    if (!strcmp(argv[1], "child-port")) { child_port(); return 0; }
    if (!strcmp(argv[1], "child-id")) { child_id(argc > 2 ? argv[2] : NULL); return 0; }
    char *list = strdup(argv[1]);
    for (char *t = strtok(list, ","); t; t = strtok(NULL, ",")) {
        if (!strcmp(t, "basic")) t_basic();
        else if (!strcmp(t, "values")) t_values();
        else if (!strcmp(t, "use")) t_use();
        else if (!strcmp(t, "purge")) t_purge();
        else if (!strcmp(t, "port")) t_port();
        else if (!strcmp(t, "xpc")) t_xpc();
        else if (!strcmp(t, "formats")) t_formats();
        else if (!strcmp(t, "share")) t_share();
        else if (!strcmp(t, "global")) t_global();
        else if (!strcmp(t, "lookupid")) child_id(argc > 2 ? argv[2] : NULL);
        else if (!strcmp(t, "name")) t_name();
        else if (!strcmp(t, "big")) t_big();
        else if (!strcmp(t, "wait")) sleep(1);
        else if (!strcmp(t, "limits")) t_limits();
        else if (!strcmp(t, "cast")) t_cast();
        else if (!strcmp(t, "inuse")) t_inuse();
        else if (!strcmp(t, "leak")) t_leak();
        else if (!strcmp(t, "idshare")) t_idshare();
        else printf("unknown test %s\n", t);
    }
    MARK("exit");
    return 0;
}
