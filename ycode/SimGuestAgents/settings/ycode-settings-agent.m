// ycode-settings-agent: Ycode's guest settings agent
// (specs/simulator/simulator-features.md §6 item 1, "Ycode implementation").
//
// A launchd daemon of the simulated device (ycode-simd writes its plist into
// DEV/data/Library/LaunchDaemons). It connects an AF_UNIX stream socket to
// /private/var/run/dev.ycode.settings, which the VMM answers itself (the
// host channel; YcodeSimFeatures/SettingsChannel.swift has the frames and
// requests), and applies what the host asks with the runtime's own public
// interfaces:
//   - preferences through CFPreferences (so cfprefsd sees them; never the
//     files behind its back), then Darwin notifications with notify_post;
//   - location simulation through CoreLocation's simulation manager
//     (CLSimulationManager, reached by name at run time; every selector is
//     checked before use), which talks to locationd's
//     com.apple.locationd.simulation service. The entitlement of that name is
//     linked into __TEXT,__entitlements (the simulator reads entitlements
//     from that section).
// It reports the notifications the host watches as events. When the
// connection ends (the device was restored from a snapshot, ycode-simd
// stopped) it connects again.
//
// Clean-room: written from the spec, the public CoreFoundation, notify and
// CoreLocation headers, and selector names published by open-source
// location tools; no Apple binary was read.

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/message.h>
#import <notify.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <mach/mach.h>
// <servers/bootstrap.h> (macOS SDK; libSystem exports these on iOS too).
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

static const char *kSocketPaths[] = {"/private/var/run/dev.ycode.settings", "/var/run/dev.ycode.settings"};
static const int kVersion = 1;

static int gFD = -1;
static NSLock *gWriteLock;
static dispatch_queue_t gWork;
static NSMutableDictionary<NSString *, NSNumber *> *gWatchTokens;
static id gSimulation;

static void logLine(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "ycode-settings-agent[%d]: %s\n", getpid(), s.UTF8String);
    fflush(stderr);
}

// MARK: - Frames

static BOOL writeAll(int fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return NO;
        p += w;
        n -= (size_t)w;
    }
    return YES;
}

static void sendMessage(NSDictionary *message) {
    NSError *error = nil;
    NSData *body = [NSPropertyListSerialization dataWithPropertyList:message format:NSPropertyListXMLFormat_v1_0
                                                              options:0 error:&error];
    if (!body) {
        logLine(@"cannot encode a message: %@", error);
        return;
    }
    uint32_t n = (uint32_t)body.length;
    uint8_t header[4] = {(uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
    [gWriteLock lock];
    if (gFD >= 0 && (!writeAll(gFD, header, 4) || !writeAll(gFD, body.bytes, body.length))) {
        logLine(@"write failed (errno %d)", errno);
    }
    [gWriteLock unlock];
}

static BOOL readAll(int fd, uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return NO;
        p += r;
        n -= (size_t)r;
    }
    return YES;
}

// MARK: - Preferences and notifications

static void synchronize(NSSet<NSString *> *domains) {
    for (NSString *d in domains) {
        if (!CFPreferencesSynchronize((__bridge CFStringRef)d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) {
            logLine(@"CFPreferencesSynchronize(%@) failed", d);
        }
    }
}

static NSString *applyWrites(NSArray *writes) {
    NSMutableSet<NSString *> *domains = [NSMutableSet set];
    for (NSDictionary *w in writes) {
        NSString *domain = w[@"domain"], *key = w[@"key"];
        if (![domain isKindOfClass:NSString.class] || ![key isKindOfClass:NSString.class]) return @"a write without domain or key";
        id value = w[@"value"];
        CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        [domains addObject:domain];
        logLine(@"set %@ %@ = %@", domain, key, value ?: @"(removed)");
    }
    synchronize(domains);
    return nil;
}

static NSString *postNotifications(NSArray *names) {
    for (NSString *n in names) {
        if (![n isKindOfClass:NSString.class]) return @"a notification name is not a string";
        uint32_t r = notify_post(n.UTF8String);
        if (r != NOTIFY_STATUS_OK) logLine(@"notify_post(%@) = %u", n, r);
    }
    if (names.count) logLine(@"posted %@", [names componentsJoinedByString:@", "]);
    return nil;
}

static id readValue(NSString *domain, NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain,
                                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
}

static BOOL voiceOverRunning(void) {
    synchronize([NSSet setWithObjects:@"com.apple.Accessibility", @"com.apple.VoiceOverTouch", nil]);
    for (NSString *d in @[@"com.apple.Accessibility", @"com.apple.VoiceOverTouch"]) {
        id v = readValue(d, @"VOTIsRunningKey");
        if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) return YES;
    }
    return NO;
}

/// Starts an on-demand launchd job by a message to one of its Mach
/// services: an empty message (id 0, no reply port) that the job's server
/// ignores; launchd starts the job to receive it.
static NSString *startService(NSString *name) {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, name.UTF8String, &port);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"no service %@ (%d)", name, kr];
    mach_msg_header_t m;
    memset(&m, 0, sizeof m);
    m.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    m.msgh_size = sizeof m;
    m.msgh_remote_port = port;
    m.msgh_id = 0;
    kr = mach_msg(&m, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 100, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), port);
    logLine(@"started %@ (send %d)", name, kr);
    return kr == KERN_SUCCESS ? nil : [NSString stringWithFormat:@"cannot message %@ (%d)", name, kr];
}

// MARK: - Location (CLSimulationManager)

static id simulationManager(NSString **error) {
    if (gSimulation) return gSimulation;
    Class c = NSClassFromString(@"CLSimulationManager");
    if (!c) {
        *error = @"CoreLocation has no simulation manager in this runtime";
        return nil;
    }
    gSimulation = [[c alloc] init];
    if (!gSimulation) *error = @"the simulation manager could not be made";
    return gSimulation;
}

static BOOL call0(id target, NSString *name, NSString **error) {
    SEL s = NSSelectorFromString(name);
    if (![target respondsToSelector:s]) {
        *error = [NSString stringWithFormat:@"the simulation manager has no %@", name];
        return NO;
    }
    ((void (*)(id, SEL))objc_msgSend)(target, s);
    return YES;
}

static BOOL callDouble(id target, NSString *name, double v, NSString **error) {
    SEL s = NSSelectorFromString(name);
    if (![target respondsToSelector:s]) {
        *error = [NSString stringWithFormat:@"the simulation manager has no %@", name];
        return NO;
    }
    ((void (*)(id, SEL, double))objc_msgSend)(target, s, v);
    return YES;
}

static BOOL callObject(id target, NSString *name, id arg, NSString **error) {
    SEL s = NSSelectorFromString(name);
    if (![target respondsToSelector:s]) {
        *error = [NSString stringWithFormat:@"the simulation manager has no %@", name];
        return NO;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(target, s, arg);
    return YES;
}

static double number(NSDictionary *d, NSString *key, double fallback) {
    id v = d[key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
}

/// A scenario file (spec §4.10): { Locations: [keyed-archived CLLocation], Options: { LocationRepeatBehavior, LocationDeliveryBehavior } }.
static NSString *writeScenario(NSDictionary *step) {
    NSString *path = step[@"path"];
    NSArray *points = step[@"points"];
    if (![path isKindOfClass:NSString.class] || ![points isKindOfClass:NSArray.class] || points.count == 0) {
        return @"write-scenario needs a path and points";
    }
    NSDate *base = [NSDate date];
    NSMutableArray *locations = [NSMutableArray array];
    for (NSDictionary *p in points) {
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake(number(p, @"latitude", 0), number(p, @"longitude", 0));
        CLLocation *l = [[CLLocation alloc] initWithCoordinate:c altitude:number(p, @"altitude", 0)
                                            horizontalAccuracy:number(p, @"horizontalAccuracy", 5)
                                              verticalAccuracy:number(p, @"verticalAccuracy", -1)
                                                        course:number(p, @"course", -1)
                                                         speed:number(p, @"speed", -1)
                                                     timestamp:[base dateByAddingTimeInterval:number(p, @"time", 0)]];
        NSError *error = nil;
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:l requiringSecureCoding:YES error:&error];
        if (!d) return [NSString stringWithFormat:@"cannot archive a location: %@", error.localizedDescription];
        // The location's type key must be 1 for locationd to play the fix
        // (found on Ycode: with the 0 a new CLLocation archives, the
        // scenario delivers nothing and clients get error 0).
        NSMutableDictionary *archive = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainers
                                                                                  format:NULL error:&error];
        for (id o in archive[@"$objects"]) {
            if ([o isKindOfClass:NSMutableDictionary.class] && o[@"kCLLocationCodingKeyCoordinateLatitude"]) o[@"kCLLocationCodingKeyType"] = @1;
        }
        NSData *typed = archive ? [NSPropertyListSerialization dataWithPropertyList:archive format:NSPropertyListBinaryFormat_v1_0
                                                                            options:0 error:&error] : nil;
        [locations addObject:typed ?: d];
    }
    NSDictionary *scenario = @{
        @"Locations": locations,
        @"Options": @{@"LocationRepeatBehavior": @((double)number(step, @"repeat", 1)), @"LocationDeliveryBehavior": @0.0},
    };
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:scenario format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:&error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        return [NSString stringWithFormat:@"cannot write %@: %@", path, error.localizedDescription];
    }
    logLine(@"wrote the scenario %@ (%lu fixes)", path, (unsigned long)points.count);
    return nil;
}

static NSString *runLocation(NSArray *steps) {
    NSString *error = nil;
    id m = simulationManager(&error);
    if (!m) return error;
    for (NSDictionary *step in steps) {
        NSString *call = step[@"call"];
        BOOL ok = YES;
        if ([call isEqual:@"stop"]) ok = call0(m, @"stopLocationSimulation", &error);
        else if ([call isEqual:@"clear"]) ok = call0(m, @"clearSimulatedLocations", &error);
        else if ([call isEqual:@"start"]) ok = call0(m, @"startLocationSimulation", &error);
        else if ([call isEqual:@"interval"]) ok = callDouble(m, @"setLocationInterval:", number(step, @"value", 1), &error);
        else if ([call isEqual:@"distance"]) ok = callDouble(m, @"setLocationDistance:", number(step, @"value", 10), &error);
        else if ([call isEqual:@"speed"]) ok = callDouble(m, @"setLocationSpeed:", number(step, @"value", 20), &error);
        else if ([call isEqual:@"repeat"]) {
            SEL s = NSSelectorFromString(@"setLocationRepeatBehavior:");
            if ([m respondsToSelector:s]) ((void (*)(id, SEL, unsigned char))objc_msgSend)(m, s, (unsigned char)number(step, @"value", 1));
            else { error = @"the simulation manager has no setLocationRepeatBehavior:"; ok = NO; }
        } else if ([call isEqual:@"append"]) {
            CLLocationCoordinate2D c = CLLocationCoordinate2DMake(number(step, @"latitude", 0), number(step, @"longitude", 0));
            CLLocation *l = [[CLLocation alloc] initWithCoordinate:c altitude:0 horizontalAccuracy:5 verticalAccuracy:-1
                                                            course:-1 speed:-1 timestamp:[NSDate date]];
            ok = callObject(m, @"appendSimulatedLocation:", l, &error);
        } else if ([call isEqual:@"scenario"]) {
            NSString *path = step[@"path"];
            if (![path isKindOfClass:NSString.class]) return @"scenario needs a path";
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return [NSString stringWithFormat:@"no scenario file %@", path];
            ok = callObject(m, @"loadScenarioFromURL:", [NSURL fileURLWithPath:path], &error);
        } else if ([call isEqual:@"write-scenario"]) {
            error = writeScenario(step);
            ok = error == nil;
        } else {
            return [NSString stringWithFormat:@"unknown location call %@", call];
        }
        if (!ok) return error;
        logLine(@"location: %@", call);
    }
    if ([m respondsToSelector:NSSelectorFromString(@"flush")]) call0(m, @"flush", &error);
    return nil;
}

// MARK: - Requests

static void watch(NSArray *names) {
    for (NSString *n in names) {
        if (![n isKindOfClass:NSString.class] || gWatchTokens[n]) continue;
        int token = 0;
        NSString *name = [n copy];
        uint32_t r = notify_register_dispatch(name.UTF8String, &token, gWork, ^(int t) {
            (void)t;
            sendMessage(@{@"event": @"notification", @"name": name});
        });
        if (r == NOTIFY_STATUS_OK) gWatchTokens[name] = @(token);
        else logLine(@"notify_register_dispatch(%@) = %u", name, r);
    }
}

static NSDictionary *handle(NSDictionary *request) {
    NSString *op = request[@"op"];
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    NSString *error = nil;
    if ([op isEqual:@"apply"]) {
        error = applyWrites(request[@"writes"] ?: @[]);
        if (!error) error = postNotifications(request[@"notify"] ?: @[]);
        for (NSString *service in request[@"startServices"] ?: @[]) {
            NSString *e = startService(service);
            if (e) logLine(@"%@", e);
        }
        id wait = request[@"waitVoiceOver"];
        if (!error && wait) {
            BOOL want = [wait boolValue], now = voiceOverRunning();
            for (int i = 0; i < 50 && now != want; i++) {
                usleep(200000);
                now = voiceOverRunning();
            }
            reply[@"voiceOverRunning"] = @(now);
            if (now != want) logLine(@"VoiceOver did not report %@ within 10 s", want ? @"running" : @"stopped");
        }
    } else if ([op isEqual:@"read"]) {
        NSMutableSet *domains = [NSMutableSet set];
        for (NSDictionary *r in request[@"reads"] ?: @[]) if (r[@"domain"]) [domains addObject:r[@"domain"]];
        synchronize(domains);
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSDictionary *r in request[@"reads"] ?: @[]) {
            id v = readValue(r[@"domain"], r[@"key"]);
            if (v) values[[NSString stringWithFormat:@"%@|%@", r[@"domain"], r[@"key"]]] = v;
        }
        reply[@"values"] = values;
    } else if ([op isEqual:@"notify"]) {
        // Optional states: { name: uint64 } set with notify_set_state before the post.
        NSDictionary *states = request[@"states"];
        for (NSString *name in states) {
            int token = 0;
            if (notify_register_check(name.UTF8String, &token) == NOTIFY_STATUS_OK) {
                notify_set_state(token, [states[name] unsignedLongLongValue]);
                notify_cancel(token);
                logLine(@"state of %@ = %@", name, states[name]);
            }
        }
        error = postNotifications(request[@"notify"] ?: @[]);
    } else if ([op isEqual:@"location"]) {
        error = runLocation(request[@"steps"] ?: @[]);
    } else if ([op isEqual:@"watch"]) {
        watch(request[@"notify"] ?: @[]);
    } else if (![op isEqual:@"ping"]) {
        error = [NSString stringWithFormat:@"unknown op %@", op];
    }
    reply[@"ok"] = @(error == nil);
    if (error) {
        reply[@"error"] = error;
        logLine(@"%@: %@", op, error);
    }
    return reply;
}

// MARK: - The connection

static int connectToHost(void) {
    for (size_t i = 0; i < sizeof kSocketPaths / sizeof kSocketPaths[0]; i++) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        struct sockaddr_un a;
        memset(&a, 0, sizeof a);
        a.sun_family = AF_UNIX;
        a.sun_len = sizeof a;
        strlcpy(a.sun_path, kSocketPaths[i], sizeof a.sun_path);
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
            return fd;
        }
        close(fd);
    }
    return -1;
}

static void serve(void) {
    unsigned failures = 0;
    for (;;) {
        int fd = connectToHost();
        if (fd < 0) {
            // No host end (an older ycode-simd, or none yet): try again, slower over time.
            if (failures++ % 30 == 0) logLine(@"no host channel (errno %d); retrying", errno);
            sleep(failures < 30 ? 2 : 20);
            continue;
        }
        failures = 0;
        [gWriteLock lock];
        gFD = fd;
        [gWriteLock unlock];
        logLine(@"connected to the host");
        sendMessage(@{@"event": @"hello", @"pid": @(getpid()), @"version": @(kVersion)});
        for (;;) {
            uint8_t header[4];
            if (!readAll(fd, header, 4)) break;
            uint32_t n = (uint32_t)header[0] << 24 | (uint32_t)header[1] << 16 | (uint32_t)header[2] << 8 | header[3];
            if (n > (1u << 20)) {
                logLine(@"frame of %u bytes refused", n);
                break;
            }
            NSMutableData *body = [NSMutableData dataWithLength:n];
            if (!readAll(fd, body.mutableBytes, n)) break;
            NSDictionary *request = [NSPropertyListSerialization propertyListWithData:body options:0 format:NULL error:NULL];
            if (![request isKindOfClass:NSDictionary.class]) {
                logLine(@"a frame that is not a dictionary");
                break;
            }
            id requestID = request[@"id"] ?: @0;
            dispatch_async(gWork, ^{
                @autoreleasepool {
                    NSMutableDictionary *reply = [handle(request) mutableCopy];
                    reply[@"id"] = requestID;
                    sendMessage(reply);
                }
            });
        }
        [gWriteLock lock];
        gFD = -1;
        [gWriteLock unlock];
        close(fd);
        logLine(@"the host channel closed; reconnecting");
        sleep(1);
    }
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        gWriteLock = [NSLock new];
        gWatchTokens = [NSMutableDictionary dictionary];
        gWork = dispatch_queue_create("dev.ycode.settings-agent", DISPATCH_QUEUE_SERIAL);
        logLine(@"started (version %d)", kVersion);
        [NSThread detachNewThreadWithBlock:^{ serve(); }];
        dispatch_main();
    }
}
