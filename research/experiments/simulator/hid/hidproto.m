/*
 * hidproto: Ycode research prototype (original Ycode code, no Apple code).
 * A replacement for the bundle named by SIMULATOR_HID_SYSTEM_MANAGER, written
 * from specs/simulator/hid-input.md to check that spec on the Mac's reference
 * simulator. backboardd loads it; it publishes three virtual HID services
 * (touch screen, hardware buttons, keyboard) in backboardd's event system and
 * injects events when told to through a Darwin notification:
 *   notify name "com.ycode.hidproto.cmd", state (64 bits) =
 *     cmd << 56 | a << 28 | b      (a, b: 28-bit fields)
 *   cmd 1 tap at (a/10000, b/10000)      cmd 2 key usage a (page 7)
 *   cmd 3 consumer button usage a        cmd 4 vertical drag from (a/10000)
 *   to (b/10000) at x = 0.5, with the bottom-edge swipe bits when a > 9900
 *   cmd 5 tap with displayUUID unset test (same as 1)
 * Function declarations are our own prototypes for exported C functions whose
 * names and roles are documented in Apple's IOHIDFamily/IOKitUser open source.
 */
#import <Foundation/Foundation.h>
#include <notify.h>
#include <mach/mach_time.h>
#include <os/log.h>
#import <objc/message.h>

typedef struct __IOHIDEventSystem *IOHIDEventSystemRef;
typedef struct __IOHIDService *IOHIDServiceRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;
typedef void (*IOHIDServiceEventCallback)(void *target, void *refcon, void *sender, IOHIDEventRef event, uint32_t options);

typedef struct {
    boolean_t (*open)(void *target, void *refcon, uint32_t options);
    void (*close)(void *target, void *refcon, uint32_t options);
    CFTypeRef (*copyProperty)(void *target, void *refcon, CFStringRef key);
    boolean_t (*setProperty)(void *target, void *refcon, CFStringRef key, CFTypeRef value);
    void (*setEventCallback)(void *target, void *refcon, IOHIDServiceEventCallback cb, void *cbTarget, void *cbRefcon);
    void (*schedule)(void *target, void *refcon, dispatch_queue_t queue);
    void (*unschedule)(void *target, void *refcon, dispatch_queue_t queue);
    IOHIDEventRef (*copyEvent)(void *target, void *refcon, uint32_t type, IOHIDEventRef matching, uint32_t options);
    int (*setOutputEvent)(void *target, void *refcon, IOHIDEventRef event);
} VirtualCallbacks;

extern IOHIDServiceRef _IOHIDServiceCreateVirtual(CFAllocatorRef, uint64_t serviceID, const VirtualCallbacks *, void *target, void *refcon);
extern void _IOHIDEventSystemAddService(IOHIDEventSystemRef, IOHIDServiceRef);
extern void _IOHIDServiceDispatchEvent(IOHIDServiceRef, IOHIDEventRef);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, boolean_t, uint32_t);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, long value);

#define FIELD_DIGITIZER_IS_DISPLAY_INTEGRATED 0xB0019 /* digitizer base (11 << 16) + 25 */

@protocol SimulatorClientHIDSystemManager
- (instancetype)initUsingHIDService:(IOHIDEventSystemRef)system error:(NSError **)error;
@end

@interface YcodeHIDService : NSObject {
@public
    IOHIDServiceRef service;
    NSMutableDictionary *properties;
    IOHIDServiceEventCallback callback;
    void *cbTarget, *cbRefcon;
}
@end
@implementation YcodeHIDService
@end

static os_log_t logh;

static boolean_t v_open(void *t, void *r, uint32_t o) { return true; }
static void v_close(void *t, void *r, uint32_t o) {}
static CFTypeRef v_copyProperty(void *t, void *r, CFStringRef key)
{
    YcodeHIDService *s = (__bridge YcodeHIDService *)t;
    id v;
    @synchronized (s) { v = s->properties[(__bridge NSString *)key]; }
    return v ? CFRetain((__bridge CFTypeRef)v) : NULL;
}
static boolean_t v_setProperty(void *t, void *r, CFStringRef key, CFTypeRef value)
{
    YcodeHIDService *s = (__bridge YcodeHIDService *)t;
    @synchronized (s) { s->properties[(__bridge NSString *)key] = (__bridge id)value; }
    return true;
}
static void v_setEventCallback(void *t, void *r, IOHIDServiceEventCallback cb, void *ct, void *cr)
{
    YcodeHIDService *s = (__bridge YcodeHIDService *)t;
    s->callback = cb; s->cbTarget = ct; s->cbRefcon = cr;
    os_log(logh, "ycode-hidproto: setEventCallback on %{public}@", s->properties[@"Product"]);
}
static void v_schedule(void *t, void *r, dispatch_queue_t q) {}
static void v_unschedule(void *t, void *r, dispatch_queue_t q) {}
static IOHIDEventRef v_copyEvent(void *t, void *r, uint32_t type, IOHIDEventRef m, uint32_t o) { return NULL; }
static int v_setOutputEvent(void *t, void *r, IOHIDEventRef e) { return (int)0xe00002c7; /* unsupported */ }
static const VirtualCallbacks callbacks = { v_open, v_close, v_copyProperty, v_setProperty, v_setEventCallback,
                                            v_schedule, v_unschedule, v_copyEvent, v_setOutputEvent };

@interface YcodeHIDProto : NSObject <SimulatorClientHIDSystemManager>
@end

@implementation YcodeHIDProto {
    IOHIDEventSystemRef _system;
    YcodeHIDService *_touch, *_buttons, *_keyboard;
    dispatch_queue_t _queue;
    int _token;
    uint32_t _identity;
}

- (YcodeHIDService *)add:(uint64_t)ident props:(NSDictionary *)props
{
    YcodeHIDService *s = [YcodeHIDService new];
    s->properties = [props mutableCopy];
    s->service = _IOHIDServiceCreateVirtual(kCFAllocatorDefault, ident, &callbacks, (__bridge void *)s, NULL);
    _IOHIDEventSystemAddService(_system, s->service);
    os_log(logh, "ycode-hidproto: added service 0x%llx %{public}@", ident, props[@"Product"]);
    return s;
}

- (void)dispatch:(IOHIDEventRef)e on:(YcodeHIDService *)s
{
    if (getenv("YCODE_HIDPROTO_USE_CALLBACK") && s->callback) s->callback(s->cbTarget, s->cbRefcon, s->service, e, 0);
    else _IOHIDServiceDispatchEvent(s->service, e);
    CFRelease(e);
}

- (void)touchX:(double)x y:(double)y phase:(int)phase edge:(uint32_t)edge identity:(uint32_t)ident
{
    /* phase 0 down, 1 move, 2 up */
    uint64_t ts = mach_absolute_time();
    uint32_t mask = (phase == 1 ? 0x4 : 0x3) | edge;
    boolean_t in = phase != 2;
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, 3 /* hand */, 0, 0, mask, 0,
                                                          x, y, 0, 0, 0, in, in, 0);
    IOHIDEventSetIntegerValue(parent, FIELD_DIGITIZER_IS_DISPLAY_INTEGRATED, 1);
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, 1, ident, mask,
                                                                x, y, 0, in ? 0.5 : 0, 90, in, in, 0);
    IOHIDEventAppendEvent(parent, finger, 0);
    CFRelease(finger);
    [self dispatch:parent on:_touch];
}

- (void)key:(uint32_t)page usage:(uint32_t)usage on:(YcodeHIDService *)s
{
    [self dispatch:IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, 1, 0) on:s];
    usleep(60000);
    [self dispatch:IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, 0, 0) on:s];
}

- (void)command:(uint64_t)st
{
    unsigned cmd = (unsigned)(st >> 56);
    double a = (double)((st >> 28) & 0xfffffff), b = (double)(st & 0xfffffff);
    os_log(logh, "ycode-hidproto: command %u a=%.0f b=%.0f", cmd, a, b);
    if (cmd == 1) {
        uint32_t id = ++_identity;
        [self touchX:a / 10000 y:b / 10000 phase:0 edge:0 identity:id];
        usleep(80000);
        [self touchX:a / 10000 y:b / 10000 phase:2 edge:0 identity:id];
    } else if (cmd == 2) {
        [self key:7 usage:(uint32_t)a on:_keyboard];
    } else if (cmd == 3) {
        [self key:0x0c usage:(uint32_t)a on:_buttons];
    } else if (cmd == 4) {
        uint32_t id = ++_identity;
        uint32_t edge = a > 9900 ? 0x01040000 : 0;
        double y0 = a / 10000, y1 = b / 10000;
        [self touchX:0.5 y:y0 phase:0 edge:edge identity:id];
        for (int i = 1; i <= 12; i++) { usleep(16000); [self touchX:0.5 y:y0 + (y1 - y0) * i / 12 phase:1 edge:edge identity:id]; }
        usleep(16000);
        [self touchX:0.5 y:y1 phase:2 edge:edge identity:id];
    }
}

- (instancetype)initUsingHIDService:(IOHIDEventSystemRef)system error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    logh = os_log_create("com.ycode.hidproto", "default");
    if (!system) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return nil;
    }
    _system = system;
    _queue = dispatch_queue_create("com.ycode.hidproto", DISPATCH_QUEUE_SERIAL);
    NSMutableDictionary *touch = [@{ @"Product": @"Ycode Touch Screen", @"PrimaryUsagePage": @13, @"PrimaryUsage": @4,
        @"DeviceUsagePairs": @[@{ @"DeviceUsagePage": @13, @"DeviceUsage": @4 }],
        @"Built-In": @YES, @"DisplayIntegrated": @YES, @"Authenticated": @YES } mutableCopy];
    BOOL noUUID = getenv("YCODE_HIDPROTO_NO_UUID") != NULL;
    _buttons = [self add:0x5943000000000001ULL props:@{ @"Product": @"Ycode Buttons", @"PrimaryUsagePage": @11, @"PrimaryUsage": @1,
        @"DeviceUsagePairs": @[@{ @"DeviceUsagePage": @11, @"DeviceUsage": @1 }], @"Built-In": @YES, @"Authenticated": @YES }];
    _keyboard = [self add:0x5943000000000002ULL props:@{ @"Product": @"Ycode Keyboard", @"PrimaryUsagePage": @1, @"PrimaryUsage": @6,
        @"DeviceUsagePairs": @[@{ @"DeviceUsagePage": @1, @"DeviceUsage": @6 }] }];
    /* The touch service names its display by the display's unique id (the
     * QuartzCore display list, i.e. the framebuffer library's display UID),
     * which exists only once the window server has the displays: wait for it. */
    __block int tries = 0;
    __block void (^poll)(void);
    poll = ^{
        id main = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"CADisplay"), NSSelectorFromString(@"mainDisplay"));
        NSString *uid = main ? ((id (*)(id, SEL))objc_msgSend)(main, NSSelectorFromString(@"uniqueId")) : nil;
        if ((uid || noUUID) || ++tries > 200) {
            if (uid && !noUUID) touch[@"displayUUID"] = uid;
            os_log(logh, "ycode-hidproto: main display uid %{public}@ after %d polls", uid, tries);
            self->_touch = [self add:0x5943000000000003ULL props:touch];
            poll = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), self->_queue, poll);
    };
    dispatch_async(_queue, poll);
    __weak YcodeHIDProto *weak = self;
    notify_register_dispatch("com.ycode.hidproto.cmd", &_token, _queue, ^(int token) {
        uint64_t st = 0;
        notify_get_state(token, &st);
        [weak command:st];
    });
    return self;
}
@end
