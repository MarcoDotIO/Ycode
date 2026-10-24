/*
 * hidsend: Ycode research probe (original Ycode code, no Apple code).
 * Runs on the Mac. Black-box driver of the reference simulator's input path,
 * following the approach documented by Meta's idb (MIT): build a message with
 * SimulatorKit's exported IndigoHIDMessageFor* functions, optionally hex-dump
 * it, and hand it to SimulatorKit's legacy HID client for a device.
 *
 *   hidsend <udid> tap <x> <y>            ratio coordinates 0..1
 *   hidsend <udid> drag <x0> <y0> <x1> <y1> <steps>
 *   hidsend <udid> key <hidUsage>         down then up
 *   hidsend <udid> button <source>        down then up, target 0x33
 *   hidsend <udid> hid <page> <usage>     arbitrary usage, target 0x32
 *   hidsend <udid> dump ...               same verbs, print bytes only
 *   hidsend <udid> orient <n>            GSEvent orientation via PurpleWorkspacePort
 *   HID_EDGE=<n> selects the builder edge argument (0 none, 1 top, 2 left, 3 bottom, 4 right)
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <malloc/malloc.h>

typedef void *(*MouseFn)(CGPoint *, CGPoint *, uint32_t, unsigned long, CGSize, uint32_t);
typedef void *(*KeyFn)(int32_t, int32_t);
typedef void *(*ButtonFn)(int32_t, int32_t, int32_t);
typedef void *(*ArbFn)(int32_t, uint32_t, uint32_t, int32_t);

static MouseFn mouseFn; static KeyFn keyFn; static ButtonFn buttonFn; static ArbFn arbFn;
static id client; static BOOL dumpOnly;
static dispatch_queue_t q;
static id device;

static void hexdump(const char *label, void *m)
{
    size_t n = malloc_size(m);
    const uint8_t *b = m;
    printf("%s (%zu bytes)\n", label, n);
    for (size_t i = 0; i < n; i += 16) {
        printf("  %04zx:", i);
        for (size_t j = i; j < i + 16 && j < n; j++) printf(" %02x", b[j]);
        printf("\n");
    }
}

static void send(const char *label, void *m)
{
    hexdump(label, m);
    if (dumpOnly) { free(m); return; }
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    void (^done)(NSError *) = ^(NSError *e) { if (e) printf("  error %s\n", e.description.UTF8String); dispatch_semaphore_signal(s); };
    ((void (*)(id, SEL, void *, BOOL, dispatch_queue_t, id))objc_msgSend)(client,
        NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:"), m, YES, q, done);
    dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

static void touch(CGPoint p, unsigned long type, const char *label)
{
    uint32_t edge = getenv("HID_EDGE") ? (uint32_t)atoi(getenv("HID_EDGE")) : 0;
    void *m = mouseFn(&p, NULL, 0x32, type, CGSizeMake(1, 1), edge);
    send(label, m);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 3) return 2;
        int a = 1;
        NSString *udid = @(argv[a++]);
        if (!strcmp(argv[a], "dump")) { dumpOnly = YES; a++; }
        const char *verb = argv[a++];
        dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
        void *sk = dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW);
        if (!sk) { printf("no SimulatorKit: %s\n", dlerror()); return 1; }
        mouseFn = dlsym(sk, "IndigoHIDMessageForMouseNSEvent");
        keyFn = dlsym(sk, "IndigoHIDMessageForKeyboardArbitrary");
        buttonFn = dlsym(sk, "IndigoHIDMessageForButton");
        arbFn = dlsym(sk, "IndigoHIDMessageForHIDArbitrary");
        q = dispatch_queue_create("hidsend", DISPATCH_QUEUE_SERIAL);
        if (!dumpOnly) {
            NSError *e = nil;
            id ctx = ((id (*)(id, SEL, NSString *, NSError **))objc_msgSend)(NSClassFromString(@"SimServiceContext"),
                NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), @"/Applications/Xcode.app/Contents/Developer", &e);
            id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(ctx, NSSelectorFromString(@"defaultDeviceSetWithError:"), &e);
            NSDictionary *byUDID = ((id (*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(@"devicesByUDID"));
            id dev = byUDID[[[NSUUID alloc] initWithUUIDString:udid]];
            if (!dev) { printf("no device %s\n", udid.UTF8String); return 1; }
            device = dev;
            Class cls = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
            client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithDevice:error:"), dev, &e);
            if (!client) { printf("no client: %s\n", e.description.UTF8String); return 1; }
        }
        if (!strcmp(verb, "orient")) {
            /* The 108-byte orientation message to PurpleWorkspacePort, laid out as idb documents it. */
            NSError *e = nil;
            mach_port_t port = ((mach_port_t (*)(id, SEL, NSString *, NSError **))objc_msgSend)(device,
                NSSelectorFromString(@"lookup:error:"), @"PurpleWorkspacePort", &e);
            uint32_t buf[27] = {0};
            buf[0] = 0x13; buf[1] = 108; buf[2] = port; buf[5] = 0x7B;
            buf[6] = 50 | 0x20000; buf[0x48 / 4] = 4; buf[0x4C / 4] = (uint32_t)atoi(argv[a]);
            kern_return_t kr = mach_msg((mach_msg_header_t *)buf, MACH_SEND_MSG | MACH_SEND_TIMEOUT, 108, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
            printf("orient port=0x%x kr=0x%x\n", port, kr);
            return 0;
        }
        if (!strcmp(verb, "tap")) {
            CGPoint p = CGPointMake(atof(argv[a]), atof(argv[a + 1]));
            touch(p, 1, "touch down");
            usleep(80000);
            touch(p, 2, "touch up");
        } else if (!strcmp(verb, "drag")) {
            double x0 = atof(argv[a]), y0 = atof(argv[a + 1]), x1 = atof(argv[a + 2]), y1 = atof(argv[a + 3]);
            int steps = atoi(argv[a + 4]);
            touch(CGPointMake(x0, y0), 1, "drag down");
            for (int i = 1; i <= steps; i++) {
                double t = (double)i / steps;
                usleep(16000);
                touch(CGPointMake(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t), 6, "drag move (dragged type)");
            }
            usleep(16000);
            touch(CGPointMake(x1, y1), 2, "drag up");
        } else if (!strcmp(verb, "key")) {
            int u = (int)strtol(argv[a], NULL, 0);
            send("key down", keyFn(u, 1));
            usleep(50000);
            send("key up", keyFn(u, 2));
        } else if (!strcmp(verb, "button")) {
            int s = (int)strtol(argv[a], NULL, 0);
            send("button down", buttonFn(s, 1, 0x33));
            usleep(100000);
            send("button up", buttonFn(s, 2, 0x33));
        } else if (!strcmp(verb, "hid")) {
            uint32_t pg = (uint32_t)strtol(argv[a], NULL, 0), u = (uint32_t)strtol(argv[a + 1], NULL, 0);
            send("hid down", arbFn(0x32, pg, u, 1));
            usleep(100000);
            send("hid up", arbFn(0x32, pg, u, 2));
        }
        usleep(200000);
        return 0;
    }
}
