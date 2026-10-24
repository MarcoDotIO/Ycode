/*
 * hidmon: Ycode research probe (original Ycode code, no Apple code).
 * Runs inside a simulator device (simctl spawn). Uses the HID event system
 * client API (names from Apple's IOHIDFamily open source, APSL) to
 *   services          list every HID service and a fixed set of properties
 *   monitor <secs>    print every HID event the event system routes, as the
 *                     CF description of the event, for <secs> seconds
 *   kbstate           print GraphicsServices' hardware-keyboard state
 * Declarations below are our own prototypes for exported C functions.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef void (*EventCallback)(void *target, void *refcon, void *sender, IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int type, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern CFTypeRef IOHIDServiceClientGetRegistryID(IOHIDServiceClientRef);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef, EventCallback, void *, void *);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
extern uint64_t IOHIDEventGetSenderID(IOHIDEventRef);
extern uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef);

static void cb(void *t, void *r, void *sender, IOHIDEventRef ev)
{
    CFStringRef d = CFCopyDescription(ev);
    printf("---- event now=%llu ts=%llu sender=0x%llx\n%s\n", mach_absolute_time(),
           IOHIDEventGetTimeStamp(ev), IOHIDEventGetSenderID(ev),
           [(__bridge NSString *)d UTF8String]);
    CFRelease(d);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *cmd = argc > 1 ? argv[1] : "services";
        if (!strcmp(cmd, "kbstate")) {
            void *gs = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_LAZY);
            const char *names[] = {"GSEventIsHardwareKeyboardAttached", "GSEventGetHardwareKeyboardCountry", "GSEventGetHardwareKeyboardType", NULL};
            for (int i = 0; names[i]; i++) {
                void *f = gs ? dlsym(gs, names[i]) : NULL;
                if (f) printf("%s = %d\n", names[i], ((int (*)(void))f)());
                else printf("%s missing\n", names[i]);
            }
            return 0;
        }
        IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, !strcmp(cmd, "monitor") ? 1 : 0, NULL);
        if (!c) { printf("no client\n"); return 1; }
        if (!strcmp(cmd, "services")) {
            NSArray *keys = @[@"Product", @"Transport", @"PrimaryUsagePage", @"PrimaryUsage", @"DeviceUsagePairs",
                              @"Built-In", @"DisplayIntegrated", @"displayUUID", @"PhysicalDeviceUniqueID", @"Placement",
                              @"Authenticated", @"VendorID", @"ProductID", @"LocationID", @"CountryCode", @"KeyboardLanguage",
                              @"StandardType", @"SurfaceDimensions", @"IOClass", @"HIDServiceSupport", @"ReportInterval",
                              @"DeviceUsage", @"DeviceUsagePage", @"GameControllerType", @"PressCountTrackingEnabled",
                              @"PressCountUsagePairs", @"Hidden", @"HIDDigitizerSurfaceWidth", @"HIDDigitizerSurfaceHeight",
                              @"DigitizerSurfaceWidth", @"DigitizerSurfaceHeight", @"ProtectedService", @"HIDVirtualDevice"];
            NSArray *svcs = CFBridgingRelease(IOHIDEventSystemClientCopyServices(c));
            printf("%lu services\n", (unsigned long)svcs.count);
            for (id s in svcs) {
                IOHIDServiceClientRef sc = (__bridge IOHIDServiceClientRef)s;
                id rid = (__bridge id)IOHIDServiceClientGetRegistryID(sc);
                printf("== service %s\n", [[rid description] UTF8String]);
                for (NSString *k in keys) {
                    id v = CFBridgingRelease(IOHIDServiceClientCopyProperty(sc, (__bridge CFStringRef)k));
                    if (v) printf("   %s = %s\n", k.UTF8String, [[[v description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]);
                }
            }
            return 0;
        }
        int secs = argc > 2 ? atoi(argv[2]) : 20;
        IOHIDEventSystemClientRegisterEventCallback(c, cb, NULL, NULL);
        IOHIDEventSystemClientScheduleWithRunLoop(c, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        printf("monitoring %d s\n", secs);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false);
        return 0;
    }
}
