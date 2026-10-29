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
 * A foldable device type (specs/simulator/foldable.md §8.1 D1) has a second
 * built-in display, described by YCODE_FRAMEBUFFER_SECOND_DISPLAY
 * ("<id> <name> <device name> <width> <height> <scale> <pitch> <uid>",
 * e.g. the iPhone Duo's inner panel "3 LCD-1 primary-1 2007 2853 3 460
 * <uid>"). It is published next to display 1 from the start, always
 * connected and powered, with a swapchain of its own; the guest decides
 * which one it draws to. Backlight and UI-orientation calls are kept per
 * display and reported in that display's frame record (D2). With it the
 * library publishes the reference's whole list of simframebuffer.md §4 —
 * LCD 1, TVOut 2, the second display, Wireless 4, Resizable 5 — so the
 * guest numbers the displays as the reference does (the inner panel is
 * "Unknown.main[3]"; simframebuffer.md §10).
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
typedef uint64_t dispatch_time_t;
extern dispatch_time_t dispatch_time(dispatch_time_t when, int64_t delta);
extern void dispatch_after_f(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work);
extern void *_Block_copy(const void *);
extern void _Block_release(const void *);
extern void os_unfair_lock_lock(os_unfair_lock *);
extern void os_unfair_lock_unlock(os_unfair_lock *);
extern int open(const char *path, int flags, ...);
extern long pwrite(int fd, const void *buf, size_t n, int64_t offset);
extern int getpid(void);
extern uint32_t IOSurfaceGetID(const void *surface);
#define O_WRONLY 0x0001
#define O_CREAT 0x0200
#define O_TRUNC 0x0400
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
    uint32_t id;    /* SFBDisplayGetID (1, or the second display's id) */
    uint32_t slot;  /* its frame record: 0 for display 1, 1 for the second */
    uint32_t type;  /* 0 built-in panel, 1 TV-out (§3.4) */
    uint32_t width, height, scale, pitch;  /* mode (canvas) */
    uint32_t power, flags;                 /* 1, 1 built-in; 0, 0 others */
    uint32_t deviceWidth, deviceHeight;    /* panel pixels; 0 × 0 for TV-out */
    CFStringRef name, deviceName, uid;
    const void *swapchain; /* weak: the display's one swapchain */
    os_unfair_lock lock;
    /* The last presented frame and the last backlight / UI-orientation
     * values set (its frame record; ~0: never set). Under stateLock. */
    uint32_t lastSurface;
    CGRect lastRect;
    uint64_t lastFrame;
    uint64_t backlight, orientation;
};

struct SFBSwapchain {
    CFRuntimeBase base;
    struct SFBDisplay *display;
    uint64_t id;
    uint64_t presentationMode;
    os_unfair_lock lock;
    uint64_t target;          /* SwapBegin's target time */
    uint64_t begun;           /* mach time of SwapBegin (timing log) */
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


/* ---- Call log (diagnostic): with YCODE_FRAMEBUFFER_CALLS set to a path,
 * the first 4096 calls write one line each ("<name> <value>\n", the value a
 * surface id, a mode or 0). Off (no file, no writes) without the variable.
 * It shows which calls a presenter other than backboardd makes (visionos.md
 * §9 Q5). The display setters (SFBDisplaySet*) and SFBDisplayGetMaskPath
 * have a budget of their own (4096 more lines), so getters called once per
 * frame do not hide them (backlight calls at fold swaps, foldable.md §9 Q4). */
static int callsFD = -2;
static int64_t callsAt;
static uint32_t callsCount, callsKeyCount;
static os_unfair_lock callsLock;

static int call_is_key(const char *name) {
    static const char setter[] = "SFBDisplaySet", mask[] = "SFBDisplayGetMaskPath";
    size_t i = 0;
    while (setter[i] && name[i] == setter[i]) i++;
    if (!setter[i]) return 1;
    for (i = 0; mask[i] && name[i] == mask[i]; i++) {}
    return !mask[i] && !name[i];
}

static void call_log(const char *name, uint64_t value) {
    if (__atomic_load_n(&callsFD, __ATOMIC_RELAXED) == -1) return; /* off: no lock taken */
    os_unfair_lock_lock(&callsLock);
    if (callsFD == -2) {
        /* One file per process: "<path>.<pid>". */
        const char *path = getenv("YCODE_FRAMEBUFFER_CALLS");
        callsFD = -1;
        if (path && *path) {
            char full[1024], digits[12];
            char *p = put_text(full, full + sizeof full - 14, path), *d = digits;
            uint32_t pid = (uint32_t)getpid();
            do { *d++ = (char)('0' + pid % 10); pid /= 10; } while (pid);
            *p++ = '.';
            while (d > digits) *p++ = *--d;
            *p = 0;
            callsFD = open(full, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        }
    }
    int key = callsFD >= 0 && callsCount >= 4096 && call_is_key(name) && callsKeyCount < 4096;
    if (callsFD >= 0 && (callsCount < 4096 || key)) {
        char buf[96];
        char *p = buf, *end = buf + sizeof buf - 1;
        p = put_text(p, end, name);
        p = put_text(p, end, " ");
        p = put_hex(p, end, (uintptr_t)value);
        *p++ = '\n';
        (void)pwrite(callsFD, buf, (size_t)(p - buf), callsAt);
        callsAt += p - buf;
        if (key) callsKeyCount++; else callsCount++;
    }
    os_unfair_lock_unlock(&callsLock);
}
#define CALL(name, value) call_log(name, (uint64_t)(value))

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

/* ---- The displays (spec §7 item 4; foldable.md §8.1 D1) ---- */

#define MAX_DISPLAYS 5
static struct SFBDisplay *theDisplays[MAX_DISPLAYS];
static uint32_t displayCount;
static dispatch_once_t displayOnce;

/* The next space-separated word of *s (at most n - 1 bytes) into out. */
static int next_word(const char **s, char *out, int n) {
    const char *p = *s;
    while (*p == ' ') p++;
    int i = 0;
    while (*p && *p != ' ') {
        if (i < n - 1) out[i++] = *p;
        p++;
    }
    out[i] = 0;
    *s = p;
    return i > 0;
}

static uint32_t word_number(const char *w) {
    uint32_t v = 0;
    while (*w >= '0' && *w <= '9') v = v * 10 + (uint32_t)(*w++ - '0');
    return v;
}

static struct SFBDisplay *new_display(uint32_t id, uint32_t slot) {
    struct SFBDisplay *d = create(displayTypeID, sizeof(struct SFBDisplay));
    if (!d) return NULL;
    d->id = id;
    d->slot = slot;
    d->power = 1;
    d->flags = 1;
    d->backlight = ~0ull;
    d->orientation = ~0ull;
    return d;
}

/* YCODE_FRAMEBUFFER_SECOND_DISPLAY: "<id> <name> <device name> <width>
 * <height> <scale> <pitch> <uid>" (all eight words), or nothing. */
static struct SFBDisplay *make_second_display(void) {
    const char *spec = getenv("YCODE_FRAMEBUFFER_SECOND_DISPLAY");
    if (!spec || !*spec) return NULL;
    char w[8][64];
    for (int i = 0; i < 8; i++)
        if (!next_word(&spec, w[i], sizeof w[i])) return NULL;
    uint32_t id = word_number(w[0]);
    if (id < 2) return NULL;
    struct SFBDisplay *d = new_display(id, 1);
    if (!d) return NULL;
    d->name = make_string(w[1]);
    d->deviceName = make_string(w[2]);
    d->width = word_number(w[3]);
    d->height = word_number(w[4]);
    d->scale = word_number(w[5]);
    d->pitch = word_number(w[6]);
    d->uid = make_string(w[7]);
    d->deviceWidth = d->width;
    d->deviceHeight = d->height;
    return d;
}

/* The reference's other displays (simframebuffer.md §4): TV-out (2),
 * wireless (4) and resizable (5); never presented, powered off. */
static struct SFBDisplay *make_other(uint32_t id, uint32_t type, const char *name, const char *deviceName, uint32_t width,
                                     uint32_t height, uint32_t scale, uint32_t pitch, const char *uid) {
    struct SFBDisplay *d = new_display(id, id);
    if (!d) return NULL;
    d->type = type;
    d->width = width;
    d->height = height;
    d->scale = scale;
    d->pitch = pitch;
    d->power = 0;
    d->flags = 0;
    d->name = make_string(name);
    d->deviceName = make_string(deviceName);
    d->uid = make_string(uid);
    return d;
}

static void make_displays(void *unused) {
    (void)unused;
    classes();
    struct SFBDisplay *d = new_display(1, 0);
    if (!d) return;
    d->width = env_number("SIMULATOR_MAINSCREEN_WIDTH", 1398);
    d->height = env_number("SIMULATOR_MAINSCREEN_HEIGHT", 2034);
    d->scale = env_number("SIMULATOR_MAINSCREEN_SCALE", 3);
    d->pitch = env_number("SIMULATOR_MAINSCREEN_PITCH", 460);
    d->name = make_string("LCD");
    d->deviceName = make_string("primary");
    /* A device type may fix its display's unique id (visionos.md §3.3:
     * the Vision Pro's); otherwise Ycode's constant. */
    const char *uid = getenv("YCODE_FRAMEBUFFER_DISPLAY_UID");
    d->uid = make_string(uid && *uid ? uid : "59434F44-4500-4000-8000-000000000001");
    d->deviceWidth = d->width;
    d->deviceHeight = d->height;
    theDisplays[0] = d;  /* held for the life of the process */
    displayCount = 1;
    struct SFBDisplay *second = make_second_display();
    if (second) {
        struct SFBDisplay *more[4] = {
            make_other(2, 1, "TVOut", "external-0", 720, 480, 1, 72, "59434F44-4500-4000-8000-000000000002"),
            second,
            make_other(4, 2, "Wireless", "wireless0", 720, 480, 1, 72, "59434F44-4500-4000-8000-000000000004"),
            make_other(5, 4, "Resizable", "resizable", 7680, 4320, 3, 120, "59434F44-4500-4000-8000-000000000005"),
        };
        for (int i = 0; i < 4; i++)
            if (more[i]) theDisplays[displayCount++] = more[i];
    }
}

/* Display 1 (the main display), or NULL. */
static struct SFBDisplay *display(void) {
    dispatch_once_f(&displayOnce, NULL, make_displays);
    return theDisplays[0];
}

static uint32_t display_count(void) {
    (void)display();
    return displayCount;
}

static void set_error(CFErrorRef *error, CFIndex code) {
    if (!error) return;
    CFStringRef domain = make_string("SimFramebufferClientErrorDomain");
    *error = CFErrorCreate(NULL, domain, code, NULL);
    CFRelease(domain);
}

/* ---- Connection (spec §3.3) ---- */

EXPORT const char *simFramebufferGetStructName(void) { CALL("simFramebufferGetStructName", 0); return ""; }

EXPORT CFTypeID SFBConnectionGetTypeID(void) {
    CALL("SFBConnectionGetTypeID", 0);
    classes();
    return connectionTypeID;
}

EXPORT const void *SFBConnectionCreate(CFAllocatorRef allocator, CFStringRef name) {
    CALL("SFBConnectionCreate", 0);
    (void)allocator;
    classes();
    struct SFBConnection *c = create(connectionTypeID, sizeof(struct SFBConnection));
    if (c && name) c->name = CFRetain(name);
    return c;
}

EXPORT Boolean SFBConnectionConnect(const void *connection, CFErrorRef *error) {
    CALL("SFBConnectionConnect", 0);
    (void)connection;
    (void)error;
    return 1;
}

EXPORT uint64_t SFBConnectionGetID(const void *connection) {
    CALL("SFBConnectionGetID", 0);
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

EXPORT void SFBConnectionSetDisplayConnectedHandler(const void *c, void *queue, void *block) { CALL("SFBConnectionSetDisplayConnectedHandler", 0); set_handler(c, 0, queue, block); }
EXPORT void SFBConnectionSetDisplayUpdatedHandler(const void *c, void *queue, void *block) { CALL("SFBConnectionSetDisplayUpdatedHandler", 0); set_handler(c, 1, queue, block); }
EXPORT void SFBConnectionSetDisplayDisconnectedHandler(const void *c, void *queue, void *block) { CALL("SFBConnectionSetDisplayDisconnectedHandler", 0); set_handler(c, 2, queue, block); }

EXPORT CFArrayRef SFBConnectionCopyDisplays(const void *connection, CFErrorRef *error) {
    CALL("SFBConnectionCopyDisplays", 0);
    (void)connection;
    struct SFBDisplay *d = display();
    if (!d) {
        set_error(error, 1);
        return NULL;
    }
    const void *values[MAX_DISPLAYS];
    uint32_t n = display_count();
    for (uint32_t i = 0; i < n; i++) values[i] = theDisplays[i];
    return CFArrayCreate(NULL, values, (CFIndex)n, &kCFTypeArrayCallBacks);
}

EXPORT const void *SFBConnectionCopyDisplay(const void *connection, uint64_t id, CFErrorRef *error) {
    CALL("SFBConnectionCopyDisplay", id);
    (void)connection;
    (void)error;
    uint32_t n = display_count();
    for (uint32_t i = 0; i < n; i++)
        if (theDisplays[i]->id == id) return CFRetain(theDisplays[i]);
    return NULL;
}

EXPORT const void *SFBConnectionCopyDisplayByUID(const void *connection, CFStringRef uid) {
    CALL("SFBConnectionCopyDisplayByUID", 0);
    (void)connection;
    if (!uid) return NULL;
    uint32_t n = display_count();
    for (uint32_t i = 0; i < n; i++) {
        struct SFBDisplay *d = theDisplays[i];
        if (CFEqual(uid, d->uid) || CFEqual(uid, d->deviceName)) return CFRetain(d);
    }
    return NULL;
}

/* Not called by the runtime (spec §7 item 8): they fail. */
EXPORT const void *SFBConnectionCreateDisplay(const void *c, const void *a, CFErrorRef *error) {
    CALL("SFBConnectionCreateDisplay", 0);
    (void)c;
    (void)a;
    set_error(error, 2);
    return NULL;
}
EXPORT Boolean SFBConnectionUpdateDisplay(const void *c, const void *d, const void *a, CFErrorRef *error) {
    CALL("SFBConnectionUpdateDisplay", 0);
    (void)c;
    (void)d;
    (void)a;
    set_error(error, 2);
    return 0;
}
EXPORT Boolean SFBConnectionRemoveDisplay(const void *c, const void *d, CFErrorRef *error) {
    CALL("SFBConnectionRemoveDisplay", 0);
    (void)c;
    (void)d;
    set_error(error, 2);
    return 0;
}

/* ---- Display (spec §3.4, §3.5) ---- */

#define DISPLAY ((const struct SFBDisplay *)d)

EXPORT CFTypeID SFBDisplayGetTypeID(void) {
    CALL("SFBDisplayGetTypeID", 0);
    classes();
    return displayTypeID;
}
EXPORT CFStringRef SFBDisplayGetName(const void *d) { CALL("SFBDisplayGetName", 0); return DISPLAY->name; }
EXPORT CFStringRef SFBDisplayGetDisplayUID(const void *d) { CALL("SFBDisplayGetDisplayUID", 0); return DISPLAY->uid; }
EXPORT CFStringRef SFBDisplayGetDeviceName(const void *d) { CALL("SFBDisplayGetDeviceName", 0); return DISPLAY->deviceName; }
EXPORT uint64_t SFBDisplayGetConnectionID(const void *d) { CALL("SFBDisplayGetConnectionID", 0); (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetID(const void *d) { CALL("SFBDisplayGetID", 0); return DISPLAY->id; }
EXPORT uint64_t SFBDisplayGetType(const void *d) { CALL("SFBDisplayGetType", 0); return DISPLAY->type; }
EXPORT uint64_t SFBDisplayGetPowerState(const void *d) { CALL("SFBDisplayGetPowerState", 0); return DISPLAY->power; }
EXPORT uint64_t SFBDisplayGetFlags(const void *d) { CALL("SFBDisplayGetFlags", 0); return DISPLAY->flags; }
EXPORT uint64_t SFBDisplayGetModeCount(const void *d) { CALL("SFBDisplayGetModeCount", 0); (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetCanvasSizeCount(const void *d) { CALL("SFBDisplayGetCanvasSizeCount", 0); (void)d; return 0; }
EXPORT uint64_t SFBDisplayGetDotPitch(const void *d) { CALL("SFBDisplayGetDotPitch", 0); return DISPLAY->pitch; }
EXPORT uint64_t SFBDisplayGetMaxLayerCount(const void *d) { CALL("SFBDisplayGetMaxLayerCount", 0); (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetMaxSwapchainCount(const void *d) { CALL("SFBDisplayGetMaxSwapchainCount", 0); (void)d; return 1; }
EXPORT uint64_t SFBDisplayGetSupportedPresentationModes(const void *d) { CALL("SFBDisplayGetSupportedPresentationModes", 0); (void)d; return 3; }
EXPORT uint64_t SFBDisplayGetSupportedSurfaceFlags(const void *d) { CALL("SFBDisplayGetSupportedSurfaceFlags", 0); (void)d; return 0x38; }
EXPORT CFStringRef SFBDisplayGetMaskPath(const void *d) { CALL("SFBDisplayGetMaskPath", 0); (void)d; return NULL; }

/* The 35-byte mode record (spec §3.5; values of display 1 of §4 except
 * the size and scale). The mode id equals the display id; offset 24 is 2
 * for the main panel and 1 for the others (§3.5 table). */
static void write_mode(const struct SFBDisplay *d, uint8_t *out) {
    uint32_t words[8] = {d->id, d->width, d->height, d->scale, 1, 0x42475241u /* 'BGRA' */, d->slot == 0 ? 2 : 1, 6000};
    for (int i = 0; i < 8; i++)
        for (int b = 0; b < 4; b++) out[4 * i + b] = (uint8_t)(words[i] >> (8 * b));
    out[32] = d->type == 0 ? 1 : 0;  /* 1 built-in, 0 others */
    out[33] = 1;
    out[34] = 1;
}

EXPORT Boolean SFBDisplayGetMode(const void *d, uint64_t index, void *out) {
    CALL("SFBDisplayGetMode", index);
    if (index != 0 || !out) return 0;
    write_mode(DISPLAY, out);
    return 1;
}
EXPORT const void *SFBDisplayGetPreferredMode(const void *d, void *out) {
    CALL("SFBDisplayGetPreferredMode", 0);
    if (out) write_mode(DISPLAY, out);
    return d;
}
EXPORT const void *SFBDisplayGetCurrentMode(const void *d, void *out) {
    CALL("SFBDisplayGetCurrentMode", 0);
    if (out) write_mode(DISPLAY, out);
    return d;
}
EXPORT Boolean SFBDisplaySetCurrentMode(const void *d, const void *mode, CFErrorRef *error) {
    CALL("SFBDisplaySetCurrentMode", 0);
    (void)d;
    (void)mode;
    (void)error;
    return 1;
}

EXPORT CGSize SFBDisplayGetDeviceSize(const void *d) {
    CALL("SFBDisplayGetDeviceSize", 0);
    CGSize s = {DISPLAY->deviceWidth, DISPLAY->deviceHeight};
    return s;
}
static CGSize canvas_size(const void *d) {
    CGSize s = {DISPLAY->width, DISPLAY->height};
    return s;
}
EXPORT CGSize SFBDisplayGetCurrentCanvasSize(const void *d) { CALL("SFBDisplayGetCurrentCanvasSize", 0); return canvas_size(d); }
EXPORT CGSize SFBDisplayGetCanvasSize(const void *d, uint64_t index) {
    CALL("SFBDisplayGetCanvasSize", 0);
    (void)index;
    return canvas_size(d);
}
EXPORT Boolean SFBDisplaySetCanvasSize(const void *d, CGSize size, CFErrorRef *error) {
    CALL("SFBDisplaySetCanvasSize", 0);
    (void)d;
    (void)size;
    (void)error;
    return 1;
}

EXPORT Boolean SFBDisplayGetExtendedProperties(const void *d, void *out) {
    CALL("SFBDisplayGetExtendedProperties", 0);
    /* Only the wireless display has them (§3.4): 21 bytes as observed. */
    if (DISPLAY->type != 2 || !out) return 0;
    uint32_t words[5] = {720, 480, 4, 1, 0};
    uint8_t *o = out;
    for (int i = 0; i < 5; i++)
        for (int b = 0; b < 4; b++) o[4 * i + b] = (uint8_t)(words[i] >> (8 * b));
    o[20] = 0x80;
    return 1;
}
EXPORT CFArrayRef SFBDisplayCopyExtendedPropertyProtocols(const void *d) {
    CALL("SFBDisplayCopyExtendedPropertyProtocols", 0);
    (void)d;
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}
static void display_state_changed(struct SFBDisplay *d, uint64_t *field, uint64_t value);

/* The call log's value for these two is (display id << 16) | value. */
EXPORT Boolean SFBDisplaySetCurrentUIOrientation(const void *d, uint64_t orientation, CFErrorRef *error) {
    CALL("SFBDisplaySetCurrentUIOrientation", (uint64_t)DISPLAY->id << 16 | (orientation & 0xFFFF));
    (void)error;
    struct SFBDisplay *disp = (struct SFBDisplay *)d;
    display_state_changed(disp, &disp->orientation, orientation);
    return 1;
}
EXPORT Boolean SFBDisplaySetBacklightState(const void *d, uint64_t state, CFErrorRef *error) {
    CALL("SFBDisplaySetBacklightState", (uint64_t)DISPLAY->id << 16 | (state & 0xFFFF));
    (void)error;
    struct SFBDisplay *disp = (struct SFBDisplay *)d;
    display_state_changed(disp, &disp->backlight, state);
    return 1;
}
EXPORT Boolean SFBDisplaySetBrightnessFactor(const void *d, double factor, CFErrorRef *error) {
    CALL("SFBDisplaySetBrightnessFactor", 0);
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
    CALL("SFBDisplayCreateSwapchain", presentationMode);
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
    CALL("SFBSwapchainGetTypeID", 0);
    classes();
    return swapchainTypeID;
}
EXPORT uint64_t SFBSwapchainGetID(const void *sc) { CALL("SFBSwapchainGetID", 0); return SWAPCHAIN->id; }
EXPORT uint64_t SFBSwapchainGetDisplayID(const void *sc) { CALL("SFBSwapchainGetDisplayID", 0); return SWAPCHAIN->display->id; }
EXPORT uint64_t SFBSwapchainGetConnectionID(const void *sc) { CALL("SFBSwapchainGetConnectionID", 0); (void)sc; return 1; }
EXPORT CGSize SFBSwapchainGetFramebufferSize(const void *sc) { CALL("SFBSwapchainGetFramebufferSize", 0); return canvas_size(SWAPCHAIN->display); }
EXPORT uint64_t SFBSwapchainGetPixelFormat(const void *sc) { CALL("SFBSwapchainGetPixelFormat", 0); (void)sc; return 0x42475241u; }
EXPORT uint64_t SFBSwapchainGetColorspace(const void *sc) { CALL("SFBSwapchainGetColorspace", 0); (void)sc; return 1; }
EXPORT uint64_t SFBSwapchainGetHDRMode(const void *sc) { CALL("SFBSwapchainGetHDRMode", 0); (void)sc; return 1; }
EXPORT uint64_t SFBSwapchainGetPresentationMode(const void *sc) { CALL("SFBSwapchainGetPresentationMode", 0); return SWAPCHAIN->presentationMode; }
EXPORT uint64_t SFBSwapchainGetMaxSurfacesPerOperation(const void *sc) { CALL("SFBSwapchainGetMaxSurfacesPerOperation", 0); (void)sc; return 32; }

EXPORT const void *SFBSwapchainAcquireSurfaceFence(const void *sc, CFErrorRef *error) {
    CALL("SFBSwapchainAcquireSurfaceFence", 0);
    (void)sc;
    set_error(error, 2);
    return NULL;
}

EXPORT Boolean SFBSwapchainSwapBegin(const void *sc, uint64_t targetTime, CFErrorRef *error) {
    CALL("SFBSwapchainSwapBegin", targetTime);
    (void)error;
    os_unfair_lock_lock(&SWAPCHAIN->lock);
    SWAPCHAIN->target = targetTime;
    SWAPCHAIN->begun = mach_absolute_time();
    SWAPCHAIN->pendingSurface = 0;
    os_unfair_lock_unlock(&SWAPCHAIN->lock);
    return 1;
}

EXPORT Boolean SFBSwapchainSwapAddSurface(const void *sc, const void *surface, CGRect source, CGRect destination,
                                          uint64_t a, uint64_t b) {
    CALL("SFBSwapchainSwapAddSurface", surface ? IOSurfaceGetID(surface) : 0);
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
 * Each display has one 96-byte text record in the file named by
 * YCODE_FRAMEBUFFER_STATE, display 1 at offset 0 and the second display
 * at offset 96 (its slot × 96), rewritten on every submitted frame:
 *   "ycode-framebuffer 1 display <id> surface <IOSurface id> rect <x> <y> <w> <h> frame <n>[ bl <b>][ uio <o>]\n"
 * padded with spaces. `bl` and `uio` are the last values given to
 * SFBDisplaySetBacklightState and SFBDisplaySetCurrentUIOrientation (absent
 * until one is set); such a call rewrites the record too (surface 0 before
 * the display's first frame). The VMM reads it to find the presented
 * surface. */
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

/* Writes display d's record; call with stateLock held. */
static void write_record_locked(struct SFBDisplay *d) {
    if (stateFD == -2) {
        const char *path = getenv("YCODE_FRAMEBUFFER_STATE");
        stateFD = path && *path ? open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644) : -1;
    }
    if (stateFD < 0) return;
    char buf[96];
    char *p = buf, *end = buf + sizeof buf - 1;
    CGRect r = d->lastRect;
    p = put_text(p, end, "ycode-framebuffer 1 display ");
    p = put_decimal(p, end, d->id);
    p = put_text(p, end, " surface ");
    p = put_decimal(p, end, d->lastSurface);
    p = put_text(p, end, " rect ");
    p = put_decimal(p, end, (uint64_t)r.x);
    p = put_text(p, end, " ");
    p = put_decimal(p, end, (uint64_t)r.y);
    p = put_text(p, end, " ");
    p = put_decimal(p, end, (uint64_t)r.width);
    p = put_text(p, end, " ");
    p = put_decimal(p, end, (uint64_t)r.height);
    p = put_text(p, end, " frame ");
    p = put_decimal(p, end, d->lastFrame);
    if (d->backlight != ~0ull) {
        p = put_text(p, end, " bl ");
        p = put_decimal(p, end, d->backlight);
    }
    if (d->orientation != ~0ull) {
        p = put_text(p, end, " uio ");
        p = put_decimal(p, end, d->orientation);
    }
    while (p < end) *p++ = ' ';
    *p = '\n';
    (void)pwrite(stateFD, buf, sizeof buf, (int64_t)d->slot * 96);
}

static void write_frame_record(struct SFBDisplay *d, uint32_t surface, CGRect r, uint64_t frame) {
    os_unfair_lock_lock(&stateLock);
    d->lastSurface = surface;
    d->lastRect = r;
    d->lastFrame = frame;
    write_record_locked(d);
    os_unfair_lock_unlock(&stateLock);
}

static void display_state_changed(struct SFBDisplay *d, uint64_t *field, uint64_t value) {
    if (!d) return;
    os_unfair_lock_lock(&stateLock);
    int changed = *field != value;
    *field = value;
    if (changed) write_record_locked(d);
    os_unfair_lock_unlock(&stateLock);
}

/* ---- Swap timing log (diagnostic, display-stream.md §10) ----
 * With YCODE_FRAMEBUFFER_TIMING set to a path, every submitted swap writes
 * one 48-byte little-endian entry into a ring of 8192 entries in that file
 * (offset (frame mod 8192) × 48): u64 frame, u64 target time (SwapBegin's
 * argument), u64 mach time at SwapBegin, u64 mach time at SwapSubmit,
 * u64 mach time when the completion block was called (0 until then),
 * u32 surface id, u32 0. Times are guest mach ticks. Off (no file, no
 * writes) without the variable. */
#define TIMING_RING 8192u
#define TIMING_ENTRY 48u
static int timingFD = -2;
static os_unfair_lock timingLock;

static int timing_fd(void) {
    os_unfair_lock_lock(&timingLock);
    if (timingFD == -2) {
        const char *path = getenv("YCODE_FRAMEBUFFER_TIMING");
        timingFD = path && *path ? open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644) : -1;
    }
    int fd = timingFD;
    os_unfair_lock_unlock(&timingLock);
    return fd;
}

static void put_u64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static void write_timing(uint64_t frame, uint64_t target, uint64_t begun, uint64_t submitted, uint64_t completed,
                         uint32_t surface) {
    int fd = timing_fd();
    if (fd < 0) return;
    uint8_t e[TIMING_ENTRY];
    put_u64(e, frame);
    put_u64(e + 8, target);
    put_u64(e + 16, begun);
    put_u64(e + 24, submitted);
    put_u64(e + 32, completed);
    put_u64(e + 40, surface);
    (void)pwrite(fd, e, sizeof e, (int64_t)((frame % TIMING_RING) * TIMING_ENTRY));
}

EXPORT void SFBSwapchainSwapSetCallback(const void *sc, void *context, uintptr_t value, void *block) {
    CALL("SFBSwapchainSwapSetCallback", value);
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
    /* For the timing log (timing on only). */
    uint64_t frame, begun, submitted;
    uint32_t surface;
    int timed;
};

static void complete(void *argument) {
    struct completion *c = argument;
    uint64_t now = mach_absolute_time();
    if (c->timed) write_timing(c->frame, c->target, c->begun, c->submitted, now, c->surface);
    c->block(NULL, c->swapchain, c->target, now, c->context);
    _Block_release(c->block);
    CFRelease(c->swapchain);
    free(c);
}

/* Diagnostic (display-stream.md §10): YCODE_FRAMEBUFFER_COMPLETION=delay-<ms>
 * calls completion blocks that much later (does the render server wait for
 * them?); delay-<ms>-ab only in odd seconds of mach time (paired A/B).
 * Unset: asynchronously at once, as spec §7 item 7 says. */
static int64_t completionDelayNs = -1;
static int completionAB;

static int64_t completion_delay(void) {
    if (completionDelayNs < 0) {
        const char *v = getenv("YCODE_FRAMEBUFFER_COMPLETION");
        int64_t ns = 0;
        if (v && v[0] == 'd' && v[1] == 'e' && v[2] == 'l' && v[3] == 'a' && v[4] == 'y' && v[5] == '-') {
            const char *d = v + 6;
            int64_t ms = 0;
            while (*d >= '0' && *d <= '9') ms = ms * 10 + (*d++ - '0');
            ns = ms * 1000000;
            completionAB = d[0] == '-' && d[1] == 'a' && d[2] == 'b';
        }
        completionDelayNs = ns;
    }
    return completionDelayNs;
}

EXPORT Boolean SFBSwapchainSwapSubmit(const void *sc, CFErrorRef *error) {
    CALL("SFBSwapchainSwapSubmit", 0);
    (void)error;
    struct SFBSwapchain *s = SWAPCHAIN;
    os_unfair_lock_lock(&s->lock);
    SFBSwapCompletion block = s->block ? _Block_copy(s->block) : NULL;
    void *context = s->context;
    uint64_t target = s->target;
    uint64_t begun = s->begun;
    uint32_t surface = s->pendingSurface;
    CGRect rect = s->pendingRect;
    uint64_t frame = ++s->presented;
    os_unfair_lock_unlock(&s->lock);
    uint64_t submitted = mach_absolute_time();
    if (surface) write_frame_record(s->display, surface, rect, frame);
    /* The timing ring keeps display 1's swaps (frame numbers are per display). */
    int timed = s->display->slot == 0 && timing_fd() >= 0;
    if (timed && !block) write_timing(frame, target, begun, submitted, 0, surface);
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
    c->frame = frame;
    c->begun = begun;
    c->submitted = submitted;
    c->surface = surface;
    c->timed = timed;
    int64_t delay = completion_delay();
    if (completionAB && (mach_absolute_time() / 24000000u) % 2 == 0) delay = 0;
    if (delay > 0)
        dispatch_after_f(dispatch_time(0, delay), s->queue, c, complete);
    else
        dispatch_async_f(s->queue, c, complete);
    return 1;
}

EXPORT Boolean SFBSwapchainSwapCancel(const void *sc, CFErrorRef *error) {
    CALL("SFBSwapchainSwapCancel", 0);
    (void)sc;
    (void)error;
    return 1;
}
