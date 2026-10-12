/*
 * simframebuffer.c - Ycode's headless SimFramebuffer library for the iOS
 * simulator guest (stage7-contract.md §5; specs/simulator/simframebuffer.md).
 *
 * Clean-room Ycode code, written from specs/simulator/simframebuffer.md
 * (the interface, values and minimal behavior of its §3 to §7), the
 * CoreFoundation open-source CFRuntime.h declarations (level 1), and public
 * C/Blocks ABI rules. It is loaded by the runtime's SimFramebufferClient
 * from the path in SIMULATOR_FRAMEBUFFER_FRAMEWORK.
 *
 * Behavior (spec §7): one built-in display (id 1, type 0, "LCD"/"primary")
 * whose size, scale and dot pitch come from the SIMULATOR_MAINSCREEN_*
 * variables; connect succeeds without contacting anything; one swapchain
 * per display; swaps succeed and every submitted swap's completion block is
 * called once, asynchronously, on the library's serial queue, with
 * (NULL, swapchain, target time, now, context). Nothing is presented:
 * frames are dropped. Handlers are kept and never called.
 *
 * Built without SDK headers, like the host libraries: every type and
 * imported function is declared here, and the build links against .tbd
 * stubs of libSystem and CoreFoundation (build.sh).
 */

typedef __SIZE_TYPE__ size_t;
typedef __UINT8_TYPE__ uint8_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __UINT64_TYPE__ uint64_t;
typedef __INT64_TYPE__ int64_t;
typedef __UINTPTR_TYPE__ uintptr_t;
typedef __INTPTR_TYPE__ intptr_t;

#define EXPORT __attribute__((visibility("default")))
#define NULL ((void *)0)

/* ---- CoreFoundation (public CF API; CFRuntime.h from CF open source) ---- */

typedef const void *CFTypeRef;
typedef const void *CFAllocatorRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFArray *CFArrayRef;
typedef const struct __CFDictionary *CFDictionaryRef;
typedef struct __CFError *CFErrorRef;
typedef long CFIndex;
typedef unsigned long CFTypeID;
typedef unsigned long CFHashCode;
typedef unsigned char Boolean;
typedef uint32_t CFStringEncoding;
#define kCFStringEncodingUTF8 0x08000100u

typedef struct {
    CFIndex version;
    const void *(*retain)(CFAllocatorRef, const void *);
    void (*release)(CFAllocatorRef, const void *);
    CFStringRef (*copyDescription)(const void *);
    Boolean (*equal)(const void *, const void *);
} CFArrayCallBacks;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef cf);
    CFTypeRef (*copy)(CFAllocatorRef allocator, CFTypeRef cf);
    void (*finalize)(CFTypeRef cf);
    Boolean (*equal)(CFTypeRef cf1, CFTypeRef cf2);
    CFHashCode (*hash)(CFTypeRef cf);
    CFStringRef (*copyFormattingDesc)(CFTypeRef cf, CFDictionaryRef formatOptions);
    CFStringRef (*copyDebugDesc)(CFTypeRef cf);
} CFRuntimeClass;

/* The CFRuntimeBase header of every CF instance (64-bit: isa, info, rc). */
typedef struct {
    uintptr_t cfisa;
    uint8_t cfinfo[4];
    uint32_t rc;
} CFRuntimeBase;

extern CFTypeRef CFRetain(CFTypeRef);
extern void CFRelease(CFTypeRef);
extern Boolean CFEqual(CFTypeRef, CFTypeRef);
extern CFArrayRef CFArrayCreate(CFAllocatorRef, const void **values, CFIndex count, const CFArrayCallBacks *callBacks);
extern const CFArrayCallBacks kCFTypeArrayCallBacks;
extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, CFStringEncoding);
extern CFErrorRef CFErrorCreate(CFAllocatorRef, CFStringRef domain, CFIndex code, CFDictionaryRef userInfo);
extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes,
                                          unsigned char *category);

/* ---- libSystem (public API) ---- */

typedef void *dispatch_queue_t;
typedef long dispatch_once_t;
typedef void (*dispatch_function_t)(void *);
typedef struct { uint32_t opaque; } os_unfair_lock;

extern void *calloc(size_t, size_t);
extern void free(void *);
extern char *getenv(const char *);
extern uint64_t mach_absolute_time(void);
extern dispatch_queue_t dispatch_queue_create(const char *label, void *attr);
extern void dispatch_async_f(dispatch_queue_t queue, void *context, dispatch_function_t work);
extern void dispatch_once_f(dispatch_once_t *predicate, void *context, dispatch_function_t function);
extern void *_Block_copy(const void *);
extern void _Block_release(const void *);
extern void os_unfair_lock_lock(os_unfair_lock *);
extern void os_unfair_lock_unlock(os_unfair_lock *);
extern int open(const char *path, int flags, ...);
extern long pwrite(int fd, const void *buf, size_t n, int64_t offset);
extern uint32_t IOSurfaceGetID(const void *surface);
#define O_WRONLY 0x0001
#define O_CREAT 0x0200
#define O_CLOEXEC 0x01000000

/* ---- Types of the interface (spec §3) ---- */

typedef struct { double width, height; } CGSize;
typedef struct { double x, y, width, height; } CGRect;

typedef void (^SFBDisplayHandler)(const void *display, uint64_t value);
typedef void (^SFBSwapCompletion)(CFErrorRef error, const void *swapchain, uint64_t target, uint64_t done, void *context);

struct SFBConnection {
    CFRuntimeBase base;
    CFStringRef name;
    void *handlers[3];  /* connected, updated, disconnected (copied blocks; never called) */
};

struct SFBDisplay {
    CFRuntimeBase base;
    uint32_t width, height, scale, pitch;
    CFStringRef name, deviceName, uid;
    const void *swapchain; /* weak: the display's one swapchain */
    os_unfair_lock lock;
};

struct SFBSwapchain {
    CFRuntimeBase base;
    struct SFBDisplay *display;
    uint64_t id;
    uint64_t presentationMode;
    os_unfair_lock lock;
    uint64_t target;          /* SwapBegin's target time */
    SFBSwapCompletion block;  /* SwapSetCallback's block (copied) */
    void *context;
    dispatch_queue_t queue;
    /* The frame being built (SwapBegin … SwapSubmit): the last surface added. */
    uint32_t pendingSurface;
    CGRect pendingRect;
    uint64_t presented;  /* frames submitted */
};

/* ---- Small helpers (no C library string functions) ---- */

static char *put_text(char *p, char *end, const char *s) {
    while (*s && p < end) *p++ = *s++;
    return p;
}

static char *put_hex(char *p, char *end, uintptr_t v) {
    char digits[17];
    int n = 0;
    do {
        digits[n++] = "0123456789abcdef"[v & 0xF];
        v >>= 4;
    } while (v && n < 16);
    while (n && p < end) *p++ = digits[--n];
    return p;
}

static CFStringRef make_string(const char *s) {
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

/* The integer part of a decimal environment value, or `fallback`. */
static uint32_t env_number(const char *name, uint32_t fallback) {
    const char *s = getenv(name);
    if (!s || *s < '0' || *s > '9') return fallback;
    uint32_t v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (uint32_t)(*s++ - '0');
    return v ? v : fallback;
}

/* ---- CF classes ---- */

static CFTypeID connectionTypeID, displayTypeID, swapchainTypeID;
static dispatch_once_t classesOnce;

static CFStringRef describe(CFTypeRef cf, const char *className) {
    char buf[64];
    char *p = buf, *end = buf + sizeof buf - 1;
    p = put_text(p, end, "<");
    p = put_text(p, end, className);
    p = put_text(p, end, " 0x");
    p = put_hex(p, end, (uintptr_t)cf);
    p = put_text(p, end, ">");
    *p = 0;
    return make_string(buf);
}

static CFStringRef connection_describe(CFTypeRef cf) { return describe(cf, "SFBConnection"); }
static CFStringRef display_describe(CFTypeRef cf) { return describe(cf, "SFBDisplay"); }
static CFStringRef swapchain_describe(CFTypeRef cf) { return describe(cf, "SFBSwapchain"); }
static CFStringRef connection_format(CFTypeRef cf, CFDictionaryRef o) { (void)o; return connection_describe(cf); }
static CFStringRef display_format(CFTypeRef cf, CFDictionaryRef o) { (void)o; return display_describe(cf); }
static CFStringRef swapchain_format(CFTypeRef cf, CFDictionaryRef o) { (void)o; return swapchain_describe(cf); }

static void connection_finalize(CFTypeRef cf) {
    struct SFBConnection *c = (struct SFBConnection *)cf;
    if (c->name) CFRelease(c->name);
    for (int i = 0; i < 3; i++)
        if (c->handlers[i]) _Block_release(c->handlers[i]);
}

static void display_finalize(CFTypeRef cf) {
    struct SFBDisplay *d = (struct SFBDisplay *)cf;
    if (d->name) CFRelease(d->name);
    if (d->deviceName) CFRelease(d->deviceName);
    if (d->uid) CFRelease(d->uid);
}

static void swapchain_finalize(CFTypeRef cf) {
    struct SFBSwapchain *s = (struct SFBSwapchain *)cf;
    os_unfair_lock_lock(&s->display->lock);
    if (s->display->swapchain == s) s->display->swapchain = NULL;
    os_unfair_lock_unlock(&s->display->lock);
    if (s->block) _Block_release(s->block);
    CFRelease(s->display);
    /* The serial queue is left alive: completions may still be queued. */
}

static const CFRuntimeClass connectionClass = {0, "SFBConnection", NULL, NULL, connection_finalize, NULL, NULL,
                                               connection_format, connection_describe};
static const CFRuntimeClass displayClass = {0, "SFBDisplay", NULL, NULL, display_finalize, NULL, NULL,
                                            display_format, display_describe};
static const CFRuntimeClass swapchainClass = {0, "SFBSwapchain", NULL, NULL, swapchain_finalize, NULL, NULL,
                                              swapchain_format, swapchain_describe};

static void register_classes(void *unused) {
    (void)unused;
    connectionTypeID = _CFRuntimeRegisterClass(&connectionClass);
    displayTypeID = _CFRuntimeRegisterClass(&displayClass);
    swapchainTypeID = _CFRuntimeRegisterClass(&swapchainClass);
}

static void classes(void) { dispatch_once_f(&classesOnce, NULL, register_classes); }

static void *create(CFTypeID type, size_t size) {
    return (void *)_CFRuntimeCreateInstance(NULL, type, (CFIndex)(size - sizeof(CFRuntimeBase)), NULL);
}

/* ---- The one display (spec §7 item 4) ---- */

static struct SFBDisplay *theDisplay;
static dispatch_once_t displayOnce;

static void make_display(void *unused) {
    (void)unused;
    classes();
    struct SFBDisplay *d = create(displayTypeID, sizeof(struct SFBDisplay));
    if (!d) return;
    d->width = env_number("SIMULATOR_MAINSCREEN_WIDTH", 1206);
    d->height = env_number("SIMULATOR_MAINSCREEN_HEIGHT", 2622);
    d->scale = env_number("SIMULATOR_MAINSCREEN_SCALE", 3);
    d->pitch = env_number("SIMULATOR_MAINSCREEN_PITCH", 460);
    d->name = make_string("LCD");
    d->deviceName = make_string("primary");
    d->uid = make_string("59434F44-4500-4000-8000-000000000001");
    theDisplay = d;  /* held for the life of the process */
}

static struct SFBDisplay *display(void) {
    dispatch_once_f(&displayOnce, NULL, make_display);
    return theDisplay;
}

static void set_error(CFErrorRef *error, CFIndex code) {
    if (!error) return;
    CFStringRef domain = make_string("SimFramebufferClientErrorDomain");
    *error = CFErrorCreate(NULL, domain, code, NULL);
    CFRelease(domain);
}

/* ---- Connection (spec §3.3) ---- */

EXPORT const char *simFramebufferGetStructName(void) { return ""; }

EXPORT CFTypeID SFBConnectionGetTypeID(void) {
    classes();
    return connectionTypeID;
}

EXPORT const void *SFBConnectionCreate(CFAllocatorRef allocator, CFStringRef name) {
    (void)allocator;
    classes();
    struct SFBConnection *c = create(connectionTypeID, sizeof(struct SFBConnection));
    if (c && name) c->name = CFRetain(name);
    return c;
}

EXPORT Boolean SFBConnectionConnect(const void *connection, CFErrorRef *error) {
    (void)connection;
    (void)error;
    return 1;
}

EXPORT uint64_t SFBConnectionGetID(const void *connection) {
    (void)connection;
    return 1;
}

static void set_handler(const void *connection, int which, void *queue, void *block) {
    (void)queue;
    struct SFBConnection *c = (struct SFBConnection *)connection;
    if (!c) return;
    void *copy = block ? _Block_copy(block) : NULL;
    void *old = c->handlers[which];
    c->handlers[which] = copy;
    if (old) _Block_release(old);
}

EXPORT void SFBConnectionSetDisplayConnectedHandler(const void *c, void *queue, void *block) { set_handler(c, 0, queue, block); }
EXPORT void SFBConnectionSetDisplayUpdatedHandler(const void *c, void *queue, void *block) { set_handler(c, 1, queue, block); }
EXPORT void SFBConnectionSetDisplayDisconnectedHandler(const void *c, void *queue, void *block) { set_handler(c, 2, queue, block); }

EXPORT CFArrayRef SFBConnectionCopyDisplays(const void *connection, CFErrorRef *error) {
    (void)connection;
    struct SFBDisplay *d = display();
    if (!d) {
        set_error(error, 1);
        return NULL;
    }
    const void *values[1] = {d};
    return CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
}

EXPORT const void *SFBConnectionCopyDisplay(const void *connection, uint64_t id, CFErrorRef *error) {
    (void)connection;
    (void)error;
    struct SFBDisplay *d = display();
    return (d && id == 1) ? CFRetain(d) : NULL;
}

EXPORT const void *SFBConnectionCopyDisplayByUID(const void *connection, CFStringRef uid) {
    (void)connection;
    struct SFBDisplay *d = display();
    if (!d || !uid) return NULL;
    return (CFEqual(uid, d->uid) || CFEqual(uid, d->deviceName)) ? CFRetain(d) : NULL;
}

/* Not called by the runtime (spec §7 item 8): they fail. */
EXPORT const void *SFBConnectionCreateDisplay(const void *c, const void *a, CFErrorRef *error) {
    (void)c;
    (void)a;
    set_error(error, 2);
    return NULL;
}
EXPORT Boolean SFBConnectionUpdateDisplay(const void *c, const void *d, const void *a, CFErrorRef *error) {
    (void)c;
    (void)d;
    (void)a;
    set_error(error, 2);
    return 0;
}
EXPORT Boolean SFBConnectionRemoveDisplay(const void *c, const void *d, CFErrorRef *error) {
    (void)c;
    (void)d;
    set_error(error, 2);
    return 0;
}

/* ---- Display (spec §3.4, §3.5) ---- */

#define DISPLAY ((const struct SFBDisplay *)d)

EXPORT CFTypeID SFBDisplayGetTypeID(void) {
    classes();
    return displayTypeID;
}
EXPORT CFStringRef SFBDisplayGetName(const void *d) { return DISPLAY->name; }
EXPORT CFStringRef SFBDisplayGetDisplayUID(const void *d) { return DISPLAY->uid; }
EXPORT CFStringRef SFBDisplayGetDeviceName(const void *d) { return DISPLAY->deviceName; }
EXPORT uint64_t SFBDisplayGetConnectionID(const void *d) { (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetID(const void *d) { (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetType(const void *d) { (void)d; return 0; }
EXPORT uint64_t SFBDisplayGetPowerState(const void *d) { (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetFlags(const void *d) { (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetModeCount(const void *d) { (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetCanvasSizeCount(const void *d) { (void)d; return 0; }
EXPORT uint64_t SFBDisplayGetDotPitch(const void *d) { return DISPLAY->pitch; }
EXPORT uint64_t SFBDisplayGetMaxLayerCount(const void *d) { (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetMaxSwapchainCount(const void *d) { (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetSupportedPresentationModes(const void *d) { (void)d; return 3; }
EXPORT uint64_t SFBDisplayGetSupportedSurfaceFlags(const void *d) { (void)d; return 0x38; }
EXPORT CFStringRef SFBDisplayGetMaskPath(const void *d) { (void)d; return NULL; }

/* The 35-byte mode record (spec §3.5; values of display 1 of §4 except
 * the size and scale). */
static void write_mode(const struct SFBDisplay *d, uint8_t *out) {
    uint32_t words[8] = {1, d->width, d->height, d->scale, 1, 0x42475241u /* 'BGRA' */, 2, 6000};
    for (int i = 0; i < 8; i++)
        for (int b = 0; b < 4; b++) out[4 * i + b] = (uint8_t)(words[i] >> (8 * b));
    out[32] = 1;
    out[33] = 1;
    out[34] = 1;
}

EXPORT Boolean SFBDisplayGetMode(const void *d, uint64_t index, void *out) {
    if (index != 0 || !out) return 0;
    write_mode(DISPLAY, out);
    return 1;
}
EXPORT const void *SFBDisplayGetPreferredMode(const void *d, void *out) {
    if (out) write_mode(DISPLAY, out);
    return d;
}
EXPORT const void *SFBDisplayGetCurrentMode(const void *d, void *out) {
    if (out) write_mode(DISPLAY, out);
    return d;
}
EXPORT Boolean SFBDisplaySetCurrentMode(const void *d, const void *mode, CFErrorRef *error) {
    (void)d;
    (void)mode;
    (void)error;
    return 1;
}

EXPORT CGSize SFBDisplayGetDeviceSize(const void *d) {
    CGSize s = {DISPLAY->width, DISPLAY->height};
    return s;
}
EXPORT CGSize SFBDisplayGetCurrentCanvasSize(const void *d) { return SFBDisplayGetDeviceSize(d); }
EXPORT CGSize SFBDisplayGetCanvasSize(const void *d, uint64_t index) {
    (void)index;
    return SFBDisplayGetDeviceSize(d);
}
EXPORT Boolean SFBDisplaySetCanvasSize(const void *d, CGSize size, CFErrorRef *error) {
    (void)d;
    (void)size;
    (void)error;
    return 1;
}

EXPORT Boolean SFBDisplayGetExtendedProperties(const void *d, void *out) {
    (void)d;
    (void)out;
    return 0;
}
EXPORT CFArrayRef SFBDisplayCopyExtendedPropertyProtocols(const void *d) {
    (void)d;
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}
EXPORT Boolean SFBDisplaySetCurrentUIOrientation(const void *d, uint64_t orientation, CFErrorRef *error) {
    (void)d;
    (void)orientation;
    (void)error;
    return 1;
}
EXPORT Boolean SFBDisplaySetBacklightState(const void *d, uint64_t state, CFErrorRef *error) {
    (void)d;
    (void)state;
    (void)error;
    return 1;
}
EXPORT Boolean SFBDisplaySetBrightnessFactor(const void *d, double factor, CFErrorRef *error) {
    (void)d;
    (void)factor;
    (void)error;
    return 1;
}

/* ---- Swapchain (spec §3.6, §7 items 6 and 7) ---- */

static uint64_t nextSwapchainID = 1;
static os_unfair_lock idLock;

EXPORT const void *SFBDisplayCreateSwapchain(const void *d, uint64_t presentationMode, CFDictionaryRef options,
                                             CFErrorRef *error) {
    (void)options;
    struct SFBDisplay *disp = (struct SFBDisplay *)d;
    classes();
    os_unfair_lock_lock(&disp->lock);
    if (disp->swapchain) {
        os_unfair_lock_unlock(&disp->lock);
        set_error(error, 2); /* "swapchain_exists" */
        return NULL;
    }
    struct SFBSwapchain *s = create(swapchainTypeID, sizeof(struct SFBSwapchain));
    if (!s) {
        os_unfair_lock_unlock(&disp->lock);
        set_error(error, 1);
        return NULL;
    }
    disp->swapchain = s;
    os_unfair_lock_unlock(&disp->lock);
    s->display = (struct SFBDisplay *)CFRetain(disp);
    os_unfair_lock_lock(&idLock);
    s->id = nextSwapchainID++;
    os_unfair_lock_unlock(&idLock);
    s->presentationMode = presentationMode;
    s->queue = dispatch_queue_create("dev.ycode.SimFramebuffer.swaps", NULL);
    return s;
}

#define SWAPCHAIN ((struct SFBSwapchain *)sc)

EXPORT CFTypeID SFBSwapchainGetTypeID(void) {
    classes();
    return swapchainTypeID;
}
EXPORT uint64_t SFBSwapchainGetID(const void *sc) { return SWAPCHAIN->id; }
EXPORT uint64_t SFBSwapchainGetDisplayID(const void *sc) { (void)sc; return 1; }
EXPORT uint64_t SFBSwapchainGetConnectionID(const void *sc) { (void)sc; return 1; }
EXPORT CGSize SFBSwapchainGetFramebufferSize(const void *sc) { return SFBDisplayGetDeviceSize(SWAPCHAIN->display); }
EXPORT uint64_t SFBSwapchainGetPixelFormat(const void *sc) { (void)sc; return 0x42475241u; }
EXPORT uint64_t SFBSwapchainGetColorspace(const void *sc) { (void)sc; return 1; }
EXPORT uint64_t SFBSwapchainGetHDRMode(const void *sc) { (void)sc; return 1; }
EXPORT uint64_t SFBSwapchainGetPresentationMode(const void *sc) { return SWAPCHAIN->presentationMode; }
EXPORT uint64_t SFBSwapchainGetMaxSurfacesPerOperation(const void *sc) { (void)sc; return 32; }

EXPORT const void *SFBSwapchainAcquireSurfaceFence(const void *sc, CFErrorRef *error) {
    (void)sc;
    set_error(error, 2);
    return NULL;
}

EXPORT Boolean SFBSwapchainSwapBegin(const void *sc, uint64_t targetTime, CFErrorRef *error) {
    (void)error;
    os_unfair_lock_lock(&SWAPCHAIN->lock);
    SWAPCHAIN->target = targetTime;
    SWAPCHAIN->pendingSurface = 0;
    os_unfair_lock_unlock(&SWAPCHAIN->lock);
    return 1;
}

EXPORT Boolean SFBSwapchainSwapAddSurface(const void *sc, const void *surface, CGRect source, CGRect destination,
                                          uint64_t a, uint64_t b) {
    (void)source;
    (void)a;
    (void)b;
    /* Headless: nothing is shown; the host learns which IOSurface was
     * presented (the frame record, below) and can read it for a screenshot. */
    uint32_t id = surface ? IOSurfaceGetID(surface) : 0;
    /* A frame may add several surfaces (layers): keep the largest. */
    os_unfair_lock_lock(&SWAPCHAIN->lock);
    CGRect *r = &SWAPCHAIN->pendingRect;
    if (!SWAPCHAIN->pendingSurface || destination.width * destination.height >= r->width * r->height) {
        SWAPCHAIN->pendingSurface = id;
        *r = destination;
    }
    os_unfair_lock_unlock(&SWAPCHAIN->lock);
    return 1;
}

/* ---- The frame record for the host (Ycode) ----
 * Each submitted frame rewrites one 96-byte text record at offset 0 of the
 * file named by YCODE_FRAMEBUFFER_STATE:
 *   "ycode-framebuffer 1 display <id> surface <IOSurface id> rect <x> <y> <w> <h> frame <n>\n"
 * padded with spaces. The VMM reads it to find the presented surface. */
static int stateFD = -2;
static os_unfair_lock stateLock;

static char *put_decimal(char *p, char *end, uint64_t v) {
    char digits[21];
    int n = 0;
    do {
        digits[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v && n < 20);
    while (n && p < end) *p++ = digits[--n];
    return p;
}

static void write_frame_record(uint64_t display, uint32_t surface, CGRect r, uint64_t frame) {
    os_unfair_lock_lock(&stateLock);
    if (stateFD == -2) {
        const char *path = getenv("YCODE_FRAMEBUFFER_STATE");
        stateFD = path && *path ? open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644) : -1;
    }
    if (stateFD >= 0) {
        char buf[96];
        char *p = buf, *end = buf + sizeof buf - 1;
        p = put_text(p, end, "ycode-framebuffer 1 display ");
        p = put_decimal(p, end, display);
        p = put_text(p, end, " surface ");
        p = put_decimal(p, end, surface);
        p = put_text(p, end, " rect ");
        p = put_decimal(p, end, (uint64_t)r.x);
        p = put_text(p, end, " ");
        p = put_decimal(p, end, (uint64_t)r.y);
        p = put_text(p, end, " ");
        p = put_decimal(p, end, (uint64_t)r.width);
        p = put_text(p, end, " ");
        p = put_decimal(p, end, (uint64_t)r.height);
        p = put_text(p, end, " frame ");
        p = put_decimal(p, end, frame);
        while (p < end) *p++ = ' ';
        *p = '\n';
        (void)pwrite(stateFD, buf, sizeof buf, 0);
    }
    os_unfair_lock_unlock(&stateLock);
}

EXPORT void SFBSwapchainSwapSetCallback(const void *sc, void *context, uintptr_t value, void *block) {
    (void)value;
    void *copy = block ? _Block_copy(block) : NULL;
    os_unfair_lock_lock(&SWAPCHAIN->lock);
    void *old = SWAPCHAIN->block;
    SWAPCHAIN->block = copy;
    SWAPCHAIN->context = context;
    os_unfair_lock_unlock(&SWAPCHAIN->lock);
    if (old) _Block_release(old);
}

struct completion {
    struct SFBSwapchain *swapchain;
    SFBSwapCompletion block;
    void *context;
    uint64_t target;
};

static void complete(void *argument) {
    struct completion *c = argument;
    c->block(NULL, c->swapchain, c->target, mach_absolute_time(), c->context);
    _Block_release(c->block);
    CFRelease(c->swapchain);
    free(c);
}

EXPORT Boolean SFBSwapchainSwapSubmit(const void *sc, CFErrorRef *error) {
    (void)error;
    struct SFBSwapchain *s = SWAPCHAIN;
    os_unfair_lock_lock(&s->lock);
    SFBSwapCompletion block = s->block ? _Block_copy(s->block) : NULL;
    void *context = s->context;
    uint64_t target = s->target;
    uint32_t surface = s->pendingSurface;
    CGRect rect = s->pendingRect;
    uint64_t frame = ++s->presented;
    os_unfair_lock_unlock(&s->lock);
    if (surface) write_frame_record(1, surface, rect, frame);
    if (!block) return 1;
    struct completion *c = calloc(1, sizeof *c);
    if (!c) {
        _Block_release(block);
        return 1;
    }
    c->swapchain = (struct SFBSwapchain *)CFRetain(s);
    c->block = block;
    c->context = context;
    c->target = target;
    dispatch_async_f(s->queue, c, complete);
    return 1;
}

EXPORT Boolean SFBSwapchainSwapCancel(const void *sc, CFErrorRef *error) {
    (void)sc;
    (void)error;
    return 1;
}
