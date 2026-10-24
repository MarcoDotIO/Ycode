/*
 * simhid.c - Ycode's HID bundle for the iOS simulator guest
 * (specs/simulator/hid-input.md). backboardd loads the bundle named by
 * SIMULATOR_HID_SYSTEM_MANAGER and calls -initUsingHIDService:error: on
 * its principal class with its HID event system (spec §3). The bundle
 * publishes three virtual HID services in that event system (buttons,
 * keyboard, touch screen; §4), registers with ycode-simd's host service
 * dev.ycode.simulator.hid (§7), and turns the host's messages into HID
 * events dispatched from those services (§5).
 *
 * Clean-room Ycode code, written from specs/simulator/hid-input.md only,
 * with public C, Mach, CoreFoundation, dispatch, and Objective-C runtime
 * interfaces. Built without SDK headers like the framebuffer library: the
 * types and imported functions are declared here, and build.sh links
 * against .tbd stubs (imports.txt).
 */

typedef __SIZE_TYPE__ size_t;
typedef __UINT8_TYPE__ uint8_t;
typedef __UINT16_TYPE__ uint16_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __UINT64_TYPE__ uint64_t;
typedef __INT32_TYPE__ int32_t;
typedef __INT64_TYPE__ int64_t;
typedef __UINTPTR_TYPE__ uintptr_t;

#define NULL ((void *)0)

/* ---- CoreFoundation (public API) ---- */

typedef const void *CFTypeRef;
typedef const void *CFAllocatorRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFArray *CFArrayRef;
typedef const struct __CFDictionary *CFDictionaryRef;
typedef struct __CFDictionary *CFMutableDictionaryRef;
typedef const struct __CFNumber *CFNumberRef;
typedef const struct __CFBoolean *CFBooleanRef;
typedef struct __CFError *CFErrorRef;
typedef long CFIndex;
typedef unsigned char Boolean;
typedef uint32_t CFStringEncoding;
#define kCFStringEncodingUTF8 0x08000100u
#define kCFNumberSInt64Type 4

typedef struct {
    CFIndex version;
    const void *retain, *release, *copyDescription, *equal;
} CFArrayCallBacks;
typedef struct {
    CFIndex version;
    const void *retain, *release, *copyDescription, *equal, *hash;
} CFDictionaryKeyCallBacks;
typedef struct {
    CFIndex version;
    const void *retain, *release, *copyDescription, *equal;
} CFDictionaryValueCallBacks;

extern CFTypeRef CFRetain(CFTypeRef);
extern void CFRelease(CFTypeRef);
extern CFArrayRef CFArrayCreate(CFAllocatorRef, const void **values, CFIndex count, const CFArrayCallBacks *callBacks);
extern const CFArrayCallBacks kCFTypeArrayCallBacks;
extern CFMutableDictionaryRef CFDictionaryCreateMutable(CFAllocatorRef, CFIndex capacity, const CFDictionaryKeyCallBacks *,
                                                        const CFDictionaryValueCallBacks *);
extern void CFDictionarySetValue(CFMutableDictionaryRef, const void *key, const void *value);
extern const void *CFDictionaryGetValue(CFDictionaryRef, const void *key);
extern const CFDictionaryKeyCallBacks kCFTypeDictionaryKeyCallBacks;
extern const CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;
extern CFNumberRef CFNumberCreate(CFAllocatorRef, CFIndex type, const void *valuePtr);
extern const CFBooleanRef kCFBooleanTrue;
extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, CFStringEncoding);
extern CFErrorRef CFErrorCreate(CFAllocatorRef, CFStringRef domain, CFIndex code, CFDictionaryRef userInfo);

/* ---- libSystem (public API) ---- */

typedef void *dispatch_queue_t;
typedef void *dispatch_source_t;
typedef uint64_t dispatch_time_t;
typedef void (*dispatch_function_t)(void *);
typedef struct { uint32_t opaque; } os_unfair_lock;
struct dispatch_source_type_s;

extern void *calloc(size_t, size_t);
extern void free(void *);
extern char *getenv(const char *);
extern int open(const char *path, int flags, ...);
extern long write(int fd, const void *buf, size_t n);
extern long pwrite(int fd, const void *buf, size_t n, int64_t offset);
extern uint64_t mach_absolute_time(void);
extern dispatch_queue_t dispatch_queue_create(const char *label, void *attr);
extern void dispatch_async_f(dispatch_queue_t queue, void *context, dispatch_function_t work);
extern dispatch_time_t dispatch_time(dispatch_time_t when, int64_t delta);
extern void dispatch_after_f(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work);
extern dispatch_source_t dispatch_source_create(const struct dispatch_source_type_s *type, uintptr_t handle, uintptr_t mask,
                                                dispatch_queue_t queue);
extern void dispatch_source_set_event_handler_f(dispatch_source_t source, dispatch_function_t handler);
extern void dispatch_set_context(void *object, void *context);
extern void dispatch_resume(void *object);
extern const struct dispatch_source_type_s _dispatch_source_type_mach_recv;
extern void os_unfair_lock_lock(os_unfair_lock *);
extern void os_unfair_lock_unlock(os_unfair_lock *);
#define O_WRONLY 0x0001
#define O_APPEND 0x0008
#define O_CREAT 0x0200
#define O_CLOEXEC 0x01000000
#define DISPATCH_TIME_NOW 0ull

/* ---- Mach (public API) ---- */

typedef uint32_t mach_port_t;
typedef int kern_return_t;
typedef struct {
    uint32_t msgh_bits;
    uint32_t msgh_size;
    mach_port_t msgh_remote_port;
    mach_port_t msgh_local_port;
    mach_port_t msgh_voucher_port;
    int32_t msgh_id;
} mach_msg_header_t;
typedef struct {
    mach_port_t name;
    uint32_t pad1;
    uint16_t pad2;
    uint8_t disposition;
    uint8_t type;
} mach_msg_port_descriptor_t;

extern mach_port_t mach_task_self_;
extern mach_port_t bootstrap_port;
extern kern_return_t mach_port_allocate(mach_port_t task, uint32_t right, mach_port_t *name);
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service, mach_port_t *sp);
extern kern_return_t mach_msg(mach_msg_header_t *msg, int option, uint32_t send_size, uint32_t rcv_size, mach_port_t rcv_name,
                              uint32_t timeout, mach_port_t notify);
#define MACH_PORT_RIGHT_RECEIVE 1u
#define MACH_SEND_MSG 0x1
#define MACH_RCV_MSG 0x2
#define MACH_SEND_TIMEOUT 0x10
#define MACH_RCV_TIMEOUT 0x100
#define MACH_MSG_TYPE_COPY_SEND 19u
#define MACH_MSG_TYPE_MAKE_SEND 20u
#define MACH_MSG_PORT_DESCRIPTOR 0u
#define MACH_MSGH_BITS_COMPLEX 0x80000000u

/* ---- Objective-C runtime (public API) ---- */

typedef struct objc_class *Class;
typedef struct objc_object *id;
typedef struct objc_selector *SEL;
typedef struct objc_object Protocol;
typedef void (*IMP)(void);

extern Class objc_getClass(const char *name);
extern Class objc_allocateClassPair(Class superclass, const char *name, size_t extraBytes);
extern void objc_registerClassPair(Class cls);
extern _Bool class_addMethod(Class cls, SEL name, IMP imp, const char *types);
extern _Bool class_addProtocol(Class cls, Protocol *protocol);
extern Protocol *objc_getProtocol(const char *name);
extern Protocol *objc_allocateProtocol(const char *name);
extern void protocol_addMethodDescription(Protocol *proto, SEL name, const char *types, _Bool isRequired, _Bool isInstance);
extern void objc_registerProtocol(Protocol *proto);
extern SEL sel_registerName(const char *name);
extern void objc_msgSend(void);
extern void objc_release(id);

/* ---- IOKit HID (spec §4, §5; names and argument orders from the spec) ---- */

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDService *IOHIDServiceRef;
typedef struct __IOHIDEventSystem *IOHIDEventSystemRef;

typedef struct {
    int (*open)(void *target, void *refcon, uint32_t options);
    void (*close)(void *target, void *refcon, uint32_t options);
    CFTypeRef (*copyProperty)(void *target, void *refcon, CFStringRef key);
    int (*setProperty)(void *target, void *refcon, CFStringRef key, CFTypeRef value);
    void (*setEventCallback)(void *target, void *refcon, void *callback, void *callbackTarget, void *callbackRefcon);
    void (*scheduleWithDispatchQueue)(void *target, void *refcon, dispatch_queue_t queue);
    void (*unscheduleFromDispatchQueue)(void *target, void *refcon, dispatch_queue_t queue);
    IOHIDEventRef (*copyEvent)(void *target, void *refcon, uint32_t type, IOHIDEventRef matching, uint32_t options);
    int (*setOutputEvent)(void *target, void *refcon, IOHIDEventRef event);
} VirtualServiceCallbacks;

extern IOHIDServiceRef _IOHIDServiceCreateVirtual(CFAllocatorRef, uint64_t serviceID, const VirtualServiceCallbacks *callbacks,
                                                  void *target, void *refcon);
extern void _IOHIDEventSystemAddService(IOHIDEventSystemRef system, IOHIDServiceRef service);
extern void _IOHIDEventSystemRemoveService(IOHIDEventSystemRef system, IOHIDServiceRef service);
extern void _IOHIDServiceDispatchEvent(IOHIDServiceRef service, IOHIDEventRef event);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t timeStamp, uint32_t transducerType, uint32_t index,
                                                    uint32_t identity, uint32_t eventMask, uint32_t buttonMask, double x, double y,
                                                    double z, double tipPressure, double barrelPressure, Boolean range,
                                                    Boolean touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t timeStamp, uint32_t index, uint32_t identity,
                                                          uint32_t eventMask, double x, double y, double z, double tipPressure,
                                                          double twist, Boolean range, Boolean touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t timeStamp, uint32_t usagePage, uint32_t usage,
                                                   Boolean down, uint32_t options);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, CFIndex value);

#define TRANSDUCER_HAND 3u
#define FIELD_DIGITIZER_IS_DISPLAY_INTEGRATED 0xB0019u
#define MASK_RANGE 0x1u
#define MASK_TOUCH 0x2u
#define MASK_POSITION 0x4u
#define MASK_CANCEL 0x80u
#define IORETURN_UNSUPPORTED ((int)0xE00002C7)

/* ---- Small helpers (no C library) ---- */

static char *put_text(char *p, char *end, const char *s) {
    while (*s && p < end) *p++ = *s++;
    return p;
}

static char *put_hex(char *p, char *end, uint64_t v) {
    char digits[17];
    int n = 0;
    do {
        digits[n++] = "0123456789abcdef"[v & 0xF];
        v >>= 4;
    } while (v && n < 16);
    p = put_text(p, end, "0x");
    while (n && p < end) *p++ = digits[--n];
    return p;
}

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

static void copy_bytes(void *dst, const void *src, size_t n) {
    uint8_t *d = dst;
    const uint8_t *s = src;
    while (n--) *d++ = *s++;
}

static CFStringRef make_string(const char *s) { return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); }

/* The log (spec §3 item 6): lines appended to $YCODE_SIMHID_LOG when set. */
static int logFD = -2;
static os_unfair_lock logLock;

static void log_line(const char *text, uint64_t a, uint64_t b) {
    os_unfair_lock_lock(&logLock);
    if (logFD == -2) {
        const char *path = getenv("YCODE_SIMHID_LOG");
        logFD = path && *path ? open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644) : -1;
    }
    if (logFD >= 0) {
        char buf[200];
        char *p = buf, *end = buf + sizeof buf - 1;
        p = put_text(p, end, "simhid: ");
        p = put_decimal(p, end, mach_absolute_time() / 24000);
        p = put_text(p, end, " ms: ");
        p = put_text(p, end, text);
        p = put_text(p, end, " ");
        p = put_hex(p, end, a);
        p = put_text(p, end, " ");
        p = put_hex(p, end, b);
        *p++ = '\n';
        (void)write(logFD, buf, (size_t)(p - buf));
    }
    os_unfair_lock_unlock(&logLock);
}

/* ---- Virtual services (spec §4) ---- */

#define SERVICE_ID_BASE 0x59434F4400000000ull

struct service {
    uint64_t id;
    const char *name;
    os_unfair_lock lock;
    CFMutableDictionaryRef properties;
    IOHIDServiceRef ref;
    int added;
};

static int svc_open(void *target, void *refcon, uint32_t options) {
    (void)target, (void)refcon, (void)options;
    return 1;
}

static void svc_close(void *target, void *refcon, uint32_t options) { (void)target, (void)refcon, (void)options; }

static CFTypeRef svc_copy_property(void *target, void *refcon, CFStringRef key) {
    (void)refcon;
    struct service *s = target;
    if (!key) return NULL;
    os_unfair_lock_lock(&s->lock);
    CFTypeRef v = CFDictionaryGetValue(s->properties, key);
    if (v) CFRetain(v);
    os_unfair_lock_unlock(&s->lock);
    return v;
}

static int svc_set_property(void *target, void *refcon, CFStringRef key, CFTypeRef value) {
    (void)refcon;
    struct service *s = target;
    if (!key || !value) return 0;
    os_unfair_lock_lock(&s->lock);
    CFDictionarySetValue(s->properties, key, value);
    os_unfair_lock_unlock(&s->lock);
    return 1;
}

static void svc_set_event_callback(void *target, void *refcon, void *callback, void *callbackTarget, void *callbackRefcon) {
    (void)target, (void)refcon, (void)callback, (void)callbackTarget, (void)callbackRefcon;
}

static void svc_schedule(void *target, void *refcon, dispatch_queue_t queue) { (void)target, (void)refcon, (void)queue; }
static void svc_unschedule(void *target, void *refcon, dispatch_queue_t queue) { (void)target, (void)refcon, (void)queue; }

static IOHIDEventRef svc_copy_event(void *target, void *refcon, uint32_t type, IOHIDEventRef matching, uint32_t options) {
    (void)target, (void)refcon, (void)type, (void)matching, (void)options;
    return NULL;
}

static int svc_set_output_event(void *target, void *refcon, IOHIDEventRef event) {
    (void)target, (void)refcon, (void)event;
    return IORETURN_UNSUPPORTED;
}

static const VirtualServiceCallbacks callbacks = {
    svc_open, svc_close, svc_copy_property, svc_set_property, svc_set_event_callback,
    svc_schedule, svc_unschedule, svc_copy_event, svc_set_output_event,
};

static void set_number(CFMutableDictionaryRef d, const char *key, int64_t value) {
    CFStringRef k = make_string(key);
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
    CFRelease(k);
}

static void set_value(CFMutableDictionaryRef d, const char *key, CFTypeRef value) {
    CFStringRef k = make_string(key);
    CFDictionarySetValue(d, k, value);
    CFRelease(k);
}

static void set_true(CFMutableDictionaryRef d, const char *key) { set_value(d, key, kCFBooleanTrue); }

static void set_string(CFMutableDictionaryRef d, const char *key, const char *value) {
    CFStringRef v = make_string(value);
    set_value(d, key, v);
    CFRelease(v);
}

/* A property dictionary with the primary usage and DeviceUsagePairs (§4.3). */
static CFMutableDictionaryRef usage_properties(int64_t page, int64_t usage) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    set_number(d, "PrimaryUsagePage", page);
    set_number(d, "PrimaryUsage", usage);
    CFMutableDictionaryRef pair = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    set_number(pair, "DeviceUsagePage", page);
    set_number(pair, "DeviceUsage", usage);
    const void *values[1] = {pair};
    CFArrayRef pairs = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    set_value(d, "DeviceUsagePairs", pairs);
    CFRelease(pairs);
    CFRelease(pair);
    return d;
}

static IOHIDEventSystemRef eventSystem;
static dispatch_queue_t queue;
static struct service buttons, keyboard, touchscreen;

static void add_service(struct service *s) {
    if (s->added) return;
    if (!s->ref) s->ref = _IOHIDServiceCreateVirtual(NULL, s->id, &callbacks, s, NULL);
    if (!s->ref) {
        log_line("cannot create service", s->id, 0);
        return;
    }
    _IOHIDEventSystemAddService(eventSystem, s->ref);
    s->added = 1;
    log_line(s->name, s->id, 1);
}

static void remove_service(struct service *s) {
    if (!s->added) return;
    _IOHIDEventSystemRemoveService(eventSystem, s->ref);
    s->added = 0;
    log_line(s->name, s->id, 0);
}

static void make_buttons(void) {
    buttons.id = SERVICE_ID_BASE | 1;
    buttons.name = "buttons service";
    buttons.properties = usage_properties(0x0B, 1);
    set_true(buttons.properties, "Built-In");
    set_true(buttons.properties, "Authenticated");
    set_true(buttons.properties, "PressCountTrackingEnabled");
    int64_t home = 0x000C0040;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &home);
    const void *values[1] = {n};
    CFArrayRef a = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    set_value(buttons.properties, "PressCountUsagePairs", a);
    CFRelease(a);
    CFRelease(n);
}

static void make_keyboard(void) {
    keyboard.id = SERVICE_ID_BASE | 2;
    keyboard.name = "keyboard service";
    keyboard.properties = usage_properties(1, 6);
    set_string(keyboard.properties, "Product", "Ycode Keyboard");
}

static void make_touchscreen(CFStringRef displayUUID) {
    touchscreen.id = SERVICE_ID_BASE | 3;
    touchscreen.name = "touch screen service";
    touchscreen.properties = usage_properties(0x0D, 4);
    set_true(touchscreen.properties, "Built-In");
    set_true(touchscreen.properties, "DisplayIntegrated");
    set_true(touchscreen.properties, "Authenticated");
    set_value(touchscreen.properties, "displayUUID", displayUUID);
    set_string(touchscreen.properties, "Product", "Ycode Touch Screen");
}

/* ---- Display association (§6) ---- */

#define YCODE_DISPLAY_UID "59434F44-4500-4000-8000-000000000001"

/* The main CADisplay's uniqueId (retained), or NULL. */
static CFStringRef copy_display_uid(void) {
    Class cls = objc_getClass("CADisplay");
    if (!cls) return NULL;
    id display = ((id(*)(Class, SEL))objc_msgSend)(cls, sel_registerName("mainDisplay"));
    if (!display) return NULL;
    id uid = ((id(*)(id, SEL))objc_msgSend)(display, sel_registerName("uniqueId"));
    return uid ? (CFStringRef)CFRetain((CFTypeRef)uid) : NULL;
}

static int displayTries;

static void find_display(void *unused) {
    (void)unused;
    CFStringRef uid = copy_display_uid();
    if (!uid && ++displayTries < 200) {
        /* Every 50 ms for up to 10 s. */
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 50000000), queue, NULL, find_display);
        return;
    }
    if (!uid) {
        uid = make_string(YCODE_DISPLAY_UID);
        log_line("display uid not found; using Ycode's constant after tries", (uint64_t)displayTries, 0);
    } else {
        log_line("display uid found after tries", (uint64_t)displayTries, 0);
    }
    make_touchscreen(uid);
    CFRelease(uid);
    add_service(&touchscreen);
}

/* ---- Events (§5) ---- */

#define MAX_CONTACTS 5

static struct {
    int down;
    uint32_t identity;
    uint32_t edgeBits;
} slots[MAX_CONTACTS + 1];
static uint32_t nextIdentity = 1;
static uint64_t lastTimestamp;

static uint64_t timestamp(void) {
    uint64_t t = mach_absolute_time();
    if (t < lastTimestamp) t = lastTimestamp;
    lastTimestamp = t;
    return t;
}

static void dispatch_from(struct service *s, IOHIDEventRef e) {
    if (!e) return;
    if (s->added) _IOHIDServiceDispatchEvent(s->ref, e);
    CFRelease(e);
}

static const uint32_t edgeBitsFor[5] = {
    0,           /* none */
    0x02040000u, /* top: SwipeDown | SwipeLocked */
    0x08040000u, /* left: SwipeRight | SwipeLocked */
    0x01040000u, /* bottom: SwipeUp | SwipeLocked */
    0x04040000u, /* right: SwipeLeft | SwipeLocked */
};

struct touch_record {
    uint32_t index, phase, edge, reserved;
    double x, y;
};

static void touch(const uint8_t *body, uint32_t count) {
    if (!touchscreen.added) return;
    uint64_t ts = timestamp();
    IOHIDEventRef children[MAX_CONTACTS];
    uint32_t parentMask = 0;
    Boolean parentRange = 0, parentTouch = 0;
    double sx = 0, sy = 0, ax = 0, ay = 0;
    uint32_t touching = 0, n = 0;
    for (uint32_t i = 0; i < count; i++) {
        struct touch_record r;
        copy_bytes(&r, body + 32 * i, sizeof r);
        if (r.index < 1 || r.index > MAX_CONTACTS || r.phase < 1 || r.phase > 5) continue;
        double x = r.x < 0 ? 0 : r.x > 1 ? 1 : r.x, y = r.y < 0 ? 0 : r.y > 1 ? 1 : r.y;
        uint32_t mask = 0;
        Boolean range = 1, down = 1;
        double pressure = 0.5;
        if (r.phase == 1) {
            slots[r.index].down = 1;
            slots[r.index].identity = nextIdentity++;
            slots[r.index].edgeBits = r.edge < 5 ? edgeBitsFor[r.edge] : 0;
            mask = MASK_RANGE | MASK_TOUCH;
        } else if (!slots[r.index].down) {
            continue; /* a contact that never began (or a restart): dropped */
        } else if (r.phase == 2) {
            mask = MASK_POSITION;
        } else if (r.phase == 3) {
            mask = 0;
        } else {
            mask = MASK_RANGE | MASK_TOUCH | (r.phase == 5 ? MASK_CANCEL : 0);
            range = 0, down = 0, pressure = 0;
        }
        if (r.phase != 3) mask |= slots[r.index].edgeBits;
        IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(NULL, ts, r.index, slots[r.index].identity, mask, x, y, 0,
                                                                   pressure, 90, range, down, 0);
        if (r.phase >= 4) slots[r.index].down = 0;
        if (!child) continue;
        children[n++] = child;
        parentMask |= mask;
        parentRange |= range;
        parentTouch |= down;
        ax += x, ay += y;
        if (down) sx += x, sy += y, touching++;
    }
    if (!n) return;
    double cx = touching ? sx / touching : ax / n, cy = touching ? sy / touching : ay / n;
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(NULL, ts, TRANSDUCER_HAND, 0, 0, parentMask, 0, cx, cy, 0, 0, 0,
                                                          parentRange, parentTouch, 0);
    if (parent) {
        IOHIDEventSetIntegerValue(parent, FIELD_DIGITIZER_IS_DISPLAY_INTEGRATED, 1);
        for (uint32_t i = 0; i < n; i++) IOHIDEventAppendEvent(parent, children[i], 0);
    }
    for (uint32_t i = 0; i < n; i++) CFRelease(children[i]);
    static uint32_t logged;
    if (logged < 20) {
        logged++;
        log_line(parent ? "touch dispatched (mask, contacts)" : "touch: no parent event (mask, contacts)", parentMask, n);
    }
    dispatch_from(&touchscreen, parent);
}

static void key(struct service *s, uint32_t page, uint32_t usage, uint32_t down) {
    dispatch_from(s, IOHIDEventCreateKeyboardEvent(NULL, timestamp(), page, usage, down ? 1 : 0, 0));
}

/* ---- Host transport (§7) ---- */

#define HID_SERVICE_NAME "dev.ycode.simulator.hid"
#define MSG_REGISTER 0x59480001
#define MSG_EVENT 0x59480002

static mach_port_t receivePort;
static dispatch_source_t receiveSource;

/* ---- Event timing log (diagnostic, display-stream.md §10) ----
 * With YCODE_SIMHID_TIMING set to a path, every event message writes one
 * 32-byte little-endian entry into a ring of 4096 entries in that file
 * (offset (sequence mod 4096) × 32): u64 host sequence number, u64 mach
 * time when the message was taken from the port, u64 mach time after the
 * event was dispatched to the event system, u32 kind, u32 0. */
static int timingFD = -2;

static void write_timing(uint64_t sequence, uint64_t received, uint64_t dispatched, uint32_t kind) {
    if (timingFD == -2) { /* the receive queue is serial: no lock needed */
        const char *path = getenv("YCODE_SIMHID_TIMING");
        timingFD = path && *path ? open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0644) : -1;
    }
    if (timingFD < 0) return;
    uint8_t e[32];
    uint64_t v[4] = {sequence, received, dispatched, kind};
    for (int i = 0; i < 4; i++)
        for (int b = 0; b < 8; b++) e[8 * i + b] = (uint8_t)(v[i] >> (8 * b));
    (void)pwrite(timingFD, e, sizeof e, (int64_t)((sequence % 4096) * 32));
}

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static uint64_t le64(const uint8_t *p) { return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32; }

static void handle_event(const uint8_t *body, uint32_t size) {
    if (size < 16 || le32(body) != 1) {
        log_line("malformed message (size, version)", size, size >= 4 ? le32(body) : 0);
        return;
    }
    uint32_t kind = le32(body + 4);
    const uint8_t *k = body + 16;
    /* The first messages are logged (bring-up and support). */
    static uint32_t logged;
    if (logged < 40) {
        logged++;
        log_line("message (kind, first word)", kind, size >= 20 ? le32(k) : 0);
    }
    switch (kind) {
    case 1: {
        if (size < 24) break;
        uint32_t count = le32(k + 4);
        if (count < 1 || count > MAX_CONTACTS || size < 24 + 32 * count) {
            log_line("malformed touch message (size, count)", size, count);
            return;
        }
        touch(k + 8, count);
        return;
    }
    case 2:
    case 3:
        if (size < 32) break;
        key(kind == 2 ? &keyboard : &buttons, le32(k), le32(k + 4), le32(k + 8));
        return;
    case 4:
        if (size < 24) break;
        if (le32(k)) add_service(&keyboard); else remove_service(&keyboard);
        return;
    case 5:
        log_line("orientation not supported", size >= 24 ? le32(k) : 0, 0);
        return;
    default:
        return; /* unknown kinds are ignored */
    }
    log_line("malformed message (size, kind)", size, kind);
}

static void receive(void *unused) {
    (void)unused;
    for (;;) {
        union {
            mach_msg_header_t header;
            uint8_t bytes[1024];
        } m;
        m.header.msgh_size = 0;
        kern_return_t kr = mach_msg(&m.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, receivePort, 0, 0);
        if (kr != 0) return; /* drained (or an error: nothing more to read now) */
        uint32_t size = m.header.msgh_size;
        if (m.header.msgh_id != MSG_EVENT || (m.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) || size < sizeof(mach_msg_header_t) ||
            size > sizeof m) {
            log_line("unexpected message (id, size)", (uint64_t)(uint32_t)m.header.msgh_id, size);
            continue;
        }
        uint64_t received = mach_absolute_time();
        const uint8_t *body = m.bytes + sizeof(mach_msg_header_t);
        uint32_t bodySize = size - (uint32_t)sizeof(mach_msg_header_t);
        handle_event(body, bodySize);
        if (timingFD != -1 && bodySize >= 16)
            write_timing(le64(body + 8), received, mach_absolute_time(), le32(body + 4));
    }
}

static int registerTries;

static void register_with_host(void *unused) {
    (void)unused;
    mach_port_t server = 0;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, HID_SERVICE_NAME, &server);
    if (kr != 0 || !server) {
        if (++registerTries < 20) {
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 500000000), queue, NULL, register_with_host);
        } else {
            log_line("host service " HID_SERVICE_NAME " not found; no input will arrive (kr)", (uint64_t)(uint32_t)kr, 0);
        }
        return;
    }
    if (!receivePort) {
        if (mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &receivePort) != 0) {
            log_line("cannot allocate a receive right", 0, 0);
            return;
        }
        receiveSource = dispatch_source_create(&_dispatch_source_type_mach_recv, receivePort, 0, queue);
        dispatch_source_set_event_handler_f(receiveSource, receive);
        dispatch_resume(receiveSource);
    }
    struct {
        mach_msg_header_t header;
        uint32_t descriptorCount;
        mach_msg_port_descriptor_t port;
        uint32_t version, flags;
    } msg; /* 48 bytes: every field is 4-byte aligned, no padding */
    _Static_assert(sizeof msg == 48, "registration message layout");
    uint8_t *raw = (uint8_t *)&msg;
    for (size_t i = 0; i < sizeof msg; i++) raw[i] = 0;
    msg.header.msgh_bits = MACH_MSG_TYPE_COPY_SEND | MACH_MSGH_BITS_COMPLEX;
    msg.header.msgh_size = sizeof msg;
    msg.header.msgh_remote_port = server;
    msg.header.msgh_id = MSG_REGISTER;
    msg.descriptorCount = 1;
    msg.port.name = receivePort;
    msg.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
    msg.port.type = MACH_MSG_PORT_DESCRIPTOR;
    msg.version = 1;
    msg.flags = 0;
    kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof msg, 0, 0, 1000, 0);
    log_line(kr == 0 ? "registered with the host (port)" : "registration failed (kr)", kr == 0 ? receivePort : (uint64_t)(uint32_t)kr,
             0);
}

/* ---- The principal class (§3) ---- */

#define CLASS_NAME "YcodeSimHIDSystem"
#define PROTOCOL_NAME "SimulatorClientHIDSystemManager"
#define INIT_TYPES "@32@0:8^{__IOHIDEventSystem=}16^@24"

static id init_using_hid_service(id self, SEL cmd, IOHIDEventSystemRef system, id *error) {
    (void)cmd;
    if (!system) {
        if (error) {
            CFStringRef domain = make_string("dev.ycode.SimHID");
            *error = (id)CFErrorCreate(NULL, domain, 1, NULL);
            CFRelease(domain);
        }
        log_line("no event system", 0, 0);
        objc_release(self);
        return NULL;
    }
    if (eventSystem) {
        log_line("initialized twice; keeping the first event system", (uint64_t)(uintptr_t)eventSystem, 0);
        return self;
    }
    eventSystem = (IOHIDEventSystemRef)CFRetain(system);
    queue = dispatch_queue_create("dev.ycode.SimHID", NULL);
    make_buttons();
    make_keyboard();
    add_service(&buttons);
    add_service(&keyboard);
    dispatch_async_f(queue, NULL, register_with_host);
    dispatch_async_f(queue, NULL, find_display);
    log_line("initialized with event system", (uint64_t)(uintptr_t)system, 0);
    return self;
}

__attribute__((constructor)) static void make_class(void) {
    if (objc_getClass(CLASS_NAME)) return;
    SEL init = sel_registerName("initUsingHIDService:error:");
    Protocol *protocol = objc_getProtocol(PROTOCOL_NAME);
    if (!protocol) {
        protocol = objc_allocateProtocol(PROTOCOL_NAME);
        if (protocol) {
            protocol_addMethodDescription(protocol, init, INIT_TYPES, 1, 1);
            objc_registerProtocol(protocol);
        }
    }
    Class cls = objc_allocateClassPair(objc_getClass("NSObject"), CLASS_NAME, 0);
    if (!cls) return;
    class_addMethod(cls, init, (IMP)init_using_hid_service, INIT_TYPES);
    if (protocol) class_addProtocol(cls, protocol);
    objc_registerClassPair(cls);
}
