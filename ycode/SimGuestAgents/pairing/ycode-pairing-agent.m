// ycode-pairing-agent: Ycode's guest pairing agent
// (specs/simulator/device-pairing.md §3.1, P-4; §8 for Ycode's decisions).
//
// A launchd daemon of the simulated device (ycode-simd writes its plist into
// DEV/data/Library/LaunchDaemons; `user/<uid>` on iOS, `system` on watchOS).
// It connects an AF_UNIX stream socket to /private/var/run/dev.ycode.pairing,
// which the VMM answers itself (YcodeSimFeatures/DevicePairing.swift,
// PairingAgentChannel: the settings channel's frames), says hello, and
// carries out the host's pairing requests in the guest with the runtime's
// own interfaces, as the reference's host-supplied agent does (§3.1):
//
//   connect <peer>      the transport's connect for the peer:
//                       IDSSimulatorLocalPairingTransportConnect(<peer>)
//   disconnect <peer>   IDSSimulatorLocalPairingTransportDisconnect(<peer>)
//   setActive <peer>    NanoRegistry's paired-device registry (§11.1, P-10): the
//                       peer already the active device → no call; in the
//                       registry → switchToSimulator:withQueue:withCompletion:;
//                       absent → pairWithSimulator:withQueue:withCompletion:.
//                       With peerRunning false (an activation while the peer
//                       does not run, P-11) only the switch is made.
//   unpair <peer>       unpairWithSimulator:withQueue:withCompletion:
//   removeUnpaired      the registry's pairing IDs (getPairedDevices, each
//                       device's NRDevicePropertyPairingID) minus the host's
//                       list: unpairWithSimulator:… for each
//   installApp, appState, openApp   diagnostics: an app installed and opened
//                       directly on this device (§10; the watch app of a probe)
//
// The names are the interop names of the spec; they are reached by name at
// run time (dlsym, the Objective-C runtime), and every one is checked before
// use. The argument forms are not in the spec: the agent passes the peer as
// an NSUUID (an NSString when that raises; §8.4 has what Ycode's runs
// showed), and remembers a form whose call ended the process (its state
// file) so that it is not tried again in this boot.
//
// Clean-room: written from the spec and public headers (dlfcn, the
// Objective-C runtime, dispatch); no Apple binary was read.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <malloc/malloc.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>

static const char *kSocketPaths[] = {"/private/var/run/dev.ycode.pairing", "/var/run/dev.ycode.pairing"};
static const int kVersion = 2;

static int gFD = -1;
static NSLock *gWriteLock;
static dispatch_queue_t gWork;
static NSMutableDictionary *gState;
static NSString *gStatePath;

static void logLine(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "ycode-pairing-agent[%d]: %s\n", getpid(), s.UTF8String);
    fflush(stderr);
}

// MARK: - Frames (4-byte big-endian length, XML plist with a dictionary root)

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

static void sendMessage(NSDictionary *message) {
    NSData *body = [NSPropertyListSerialization dataWithPropertyList:message format:NSPropertyListXMLFormat_v1_0
                                                              options:0 error:NULL];
    if (!body) return;
    uint32_t n = (uint32_t)body.length;
    uint8_t header[4] = {(uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
    [gWriteLock lock];
    if (gFD >= 0 && (!writeAll(gFD, header, 4) || !writeAll(gFD, body.bytes, body.length))) {
        logLine(@"write failed (errno %d)", errno);
    }
    [gWriteLock unlock];
}

// MARK: - State across restarts

static void saveState(void) {
    if (!gStatePath) return;
    [gState writeToFile:gStatePath atomically:YES];
}

/// Marks a call as in progress (a crash leaves the mark for the next start).
static void beginAttempt(NSString *key) {
    gState[@"attempt"] = key;
    saveState();
}

static void endAttempt(void) {
    [gState removeObjectForKey:@"attempt"];
    saveState();
}

static BOOL crashedBefore(NSString *key) { return [gState[@"crashed"] containsObject:key]; }

static void loadState(void) {
    NSString *path = NSProcessInfo.processInfo.environment[@"YCODE_PAIRING_AGENT_STATE"];
    gStatePath = path.length ? path : nil;
    NSDictionary *old = gStatePath ? [NSDictionary dictionaryWithContentsOfFile:gStatePath] : nil;
    gState = [NSMutableDictionary dictionary];
    gState[@"crashed"] = [NSMutableArray arrayWithArray:old[@"crashed"] ?: @[]];
    NSString *attempt = old[@"attempt"];
    if (attempt) {
        [gState[@"crashed"] addObject:attempt];
        logLine(@"the call %@ ended the previous agent process; it is not tried again", attempt);
    }
    saveState();
}

// MARK: - Finding the runtime's interfaces

static NSArray<NSString *> *frameworkPaths(NSString *prefix) {
    NSMutableArray *out = [NSMutableArray array];
    [out addObject:[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", prefix, prefix]];
    // Other frameworks of the family, by directory name, under the runtime root.
    NSString *root = NSProcessInfo.processInfo.environment[@"SIMULATOR_ROOT"] ?: @"";
    NSString *dir = [root stringByAppendingPathComponent:@"System/Library/PrivateFrameworks"];
    for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]
                            sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name hasPrefix:prefix] || ![name hasSuffix:@".framework"]) continue;
        NSString *base = [name stringByDeletingPathExtension];
        NSString *p = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@/%@", name, base];
        if (![out containsObject:p]) [out addObject:p];
    }
    return out;
}

/// A function of the runtime by name: already loaded, or in a framework of
/// the family `familyPrefix` once loaded.
static void *findFunction(NSString *name, NSString *familyPrefix) {
    void *p = dlsym(RTLD_DEFAULT, name.UTF8String);
    if (p) return p;
    for (NSString *path in frameworkPaths(familyPrefix)) {
        if (!dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL)) continue;
        p = dlsym(RTLD_DEFAULT, name.UTF8String);
        if (p) {
            logLine(@"%@ found after loading %@", name, path);
            return p;
        }
    }
    return NULL;
}

/// The peer's UDID in the form `kind` ("string": NSString, "uuid": NSUUID).
static id peerArgument(NSString *peer, NSString *kind) {
    if ([kind isEqual:@"uuid"]) return [[NSUUID alloc] initWithUUIDString:peer];
    return peer.uppercaseString;
}

/// A short description of a value a call returned or a completion got: an
/// integer, or an object's class and description when it is one.
static NSString *describeWord(uintptr_t v) {
    if (v < 4096) return [NSString stringWithFormat:@"%lu", (unsigned long)v];
    BOOL tagged = (v >> 63) != 0;
    if (tagged || malloc_zone_from_ptr((const void *)v) != NULL) {
        @try {
            id o = (__bridge id)(void *)v;
            NSString *d = [[o description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (d.length > 400) d = [[d substringToIndex:400] stringByAppendingString:@"…"];
            return [NSString stringWithFormat:@"<%@: %@>", NSStringFromClass(object_getClass(o)), d];
        } @catch (NSException *e) {
            return [NSString stringWithFormat:@"0x%lx", (unsigned long)v];
        }
    }
    return [NSString stringWithFormat:@"0x%lx", (unsigned long)v];
}

typedef uintptr_t (*Function4)(uintptr_t, uintptr_t, uintptr_t, uintptr_t);

/// Calls `name(peer, completion, queue)` and waits up to 60 s for the
/// completion; the peer as an NSUUID first, an NSString when that raises.
///
/// Ycode findings (device-pairing.md §8.4, the guest's own log under Ycode):
/// called with the UDID string alone (the other argument registers 0), the
/// connect returned at once and the process faulted in libdispatch on a NULL
/// queue from a block the function had queued, and ids_simd dropped the
/// request it forwarded because an NSString is not allowed in its place. The
/// runtime's IDS log line for the call names its parameters: the simulator
/// ID (an NSUUID), a completion block, then a dispatch queue. The
/// completion's own parameters are not known; they are taken as words and
/// described.
static NSString *callPeerFunction(NSString *name, NSString *familyPrefix, NSString *peer, NSString *forced,
                                  NSString **detail) {
    void *f = findFunction(name, familyPrefix);
    if (!f) return [NSString stringWithFormat:@"the runtime has no %@", name];
    NSArray *kinds = forced ? @[forced] : @[@"uuid", @"string"];
    NSMutableArray *notes = [NSMutableArray array];
    dispatch_queue_t q = dispatch_queue_create("dev.ycode.pairing-agent.transport", DISPATCH_QUEUE_SERIAL);
    for (NSString *kind in kinds) {
        NSString *key = [NSString stringWithFormat:@"%@(%@)", name, kind];
        if (crashedBefore(key)) {
            [notes addObject:[NSString stringWithFormat:@"%@ skipped (it ended an earlier agent)", key]];
            continue;
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSString *outcome = nil;
        void (^completion)(uintptr_t, uintptr_t, uintptr_t) = ^(uintptr_t a, uintptr_t b, uintptr_t c) {
            outcome = [NSString stringWithFormat:@"completion(%@, %@, %@)", describeWord(a), describeWord(b), describeWord(c)];
            dispatch_semaphore_signal(done);
        };
        id arg = peerArgument(peer, kind);
        NSDate *t0 = [NSDate date];
        // The mark stays until the completion (or the wait's end): a fault in
        // the function's own asynchronous work is charged to this call.
        beginAttempt(key);
        @try {
            ((Function4)f)((uintptr_t)(__bridge void *)arg, (uintptr_t)(__bridge void *)completion,
                           (uintptr_t)(__bridge void *)q, 0);
        } @catch (NSException *e) {
            endAttempt();
            [notes addObject:[NSString stringWithFormat:@"%@ raised %@: %@", key, e.name, e.reason]];
            continue;
        }
        long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
        endAttempt();
        [notes addObject:[NSString stringWithFormat:@"%@: %@ after %.1f s", key,
                          timedOut ? @"no completion" : outcome, -t0.timeIntervalSinceNow]];
        *detail = [notes componentsJoinedByString:@"; "];
        return nil;
    }
    *detail = [notes componentsJoinedByString:@"; "];
    return [NSString stringWithFormat:@"%@ did not take the peer", name];
}

// MARK: - NanoRegistry's paired-device registry

static NSString *const kPairSelector = @"pairWithSimulator:withQueue:withCompletion:";

/// The registry object: an instance of the NanoRegistry class that answers
/// the pairing selector (its shared instance when it has one).
static id registry(NSString **error) {
    static id cached;
    if (cached) return cached;
    for (NSString *path in frameworkPaths(@"NanoRegistry")) dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
    SEL sel = NSSelectorFromString(kPairSelector);
    Class found = Nil;
    unsigned int imageCount = 0;
    const char **images = objc_copyImageNames(&imageCount);
    for (unsigned int i = 0; i < imageCount && !found; i++) {
        if (!strstr(images[i], "/NanoRegistry.framework/")) continue;
        unsigned int n = 0;
        const char **names = objc_copyClassNamesForImage(images[i], &n);
        for (unsigned int j = 0; j < n && !found; j++) {
            Class c = objc_getClass(names[j]);
            if (c && class_getInstanceMethod(c, sel)) found = c;
        }
        free(names);
    }
    free(images);
    if (!found) {
        *error = [NSString stringWithFormat:@"no NanoRegistry class answers %@", kPairSelector];
        return nil;
    }
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if ([found respondsToSelector:shared]) {
        cached = ((id (*)(id, SEL))objc_msgSend)(found, shared);
    }
    if (!cached) cached = [[found alloc] init];
    logLine(@"registry: %@ (%@)", NSStringFromClass(found), cached ? @"ready" : @"not made");
    if (!cached) *error = [NSString stringWithFormat:@"%@ could not be made", NSStringFromClass(found)];
    return cached;
}

/// One of the registry's simulator calls (`selector` takes the peer, a
/// queue and a completion block, §11.1). Waits up to `wait` seconds for the
/// completion; a later completion is reported to the host as a log event.
/// Returns nil on success, else the failure; `*completed` says whether the
/// completion came in time.
static NSString *registryCall(NSString *selectorName, NSString *peer, NSString *forced, double wait, NSString **detail,
                              BOOL *completed) {
    NSString *error = nil;
    id r = registry(&error);
    if (!r) return error;
    SEL sel = NSSelectorFromString(selectorName);
    if (![r respondsToSelector:sel]) return [NSString stringWithFormat:@"the registry does not answer %@", selectorName];
    NSArray *kinds = forced ? @[forced] : @[@"uuid", @"string"];
    NSMutableArray *notes = [NSMutableArray array];
    dispatch_queue_t q = dispatch_queue_create("dev.ycode.pairing-agent.registry", DISPATCH_QUEUE_SERIAL);
    for (NSString *kind in kinds) {
        NSString *key = [NSString stringWithFormat:@"%@(%@)", selectorName, kind];
        if (crashedBefore(key)) {
            [notes addObject:[NSString stringWithFormat:@"%@ skipped (it ended an earlier agent)", key]];
            continue;
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSString *outcome = nil;
        __block BOOL refused = NO;
        // The completion's parameters are not in the spec: words, described.
        // Under Ycode (device-pairing.md §10.5) the first word is 0 on success
        // and an NSError when the registry refuses: such a completion fails
        // the request.
        void (^completion)(uintptr_t, uintptr_t, uintptr_t) = ^(uintptr_t a, uintptr_t b, uintptr_t c) {
            outcome = [NSString stringWithFormat:@"completion(%@, %@, %@)", describeWord(a), describeWord(b), describeWord(c)];
            refused = [describeWord(a) hasPrefix:@"<NSError"];
            dispatch_semaphore_signal(done);
        };
        id arg = peerArgument(peer, kind);
        beginAttempt(key);
        NSDate *t0 = [NSDate date];
        @try {
            ((void (*)(id, SEL, id, dispatch_queue_t, id))objc_msgSend)(r, sel, arg, q, completion);
        } @catch (NSException *e) {
            endAttempt();
            [notes addObject:[NSString stringWithFormat:@"%@ raised %@: %@", key, e.name, e.reason]];
            continue;
        }
        long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)));
        endAttempt();
        if (timedOut) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3600 * NSEC_PER_SEC)) == 0) {
                    NSString *line = [NSString stringWithFormat:@"%@ for %@: %@ after %.1f s", selectorName, peer, outcome,
                                      -t0.timeIntervalSinceNow];
                    logLine(@"%@", line);
                    sendMessage(@{@"event": @"log", @"text": line});
                }
            });
        }
        if (completed) *completed = !timedOut;
        [notes addObject:[NSString stringWithFormat:@"%@: %@ after %.1f s", key,
                          timedOut ? @"called; completion pending" : outcome, -t0.timeIntervalSinceNow]];
        *detail = [notes componentsJoinedByString:@"; "];
        return !timedOut && refused ? [NSString stringWithFormat:@"the registry refused %@", selectorName] : nil;
    }
    *detail = [notes componentsJoinedByString:@"; "];
    return @"the registry did not take the peer";
}

/// A pairing ID value as an upper-case UUID string (NSUUID or NSString), or nil.
static NSString *uuidText(id v) {
    if ([v isKindOfClass:NSUUID.class]) return [[(NSUUID *)v UUIDString] uppercaseString];
    if ([v isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:v]) return [(NSString *)v uppercaseString];
    return nil;
}

/// The value of NRDevicePropertyPairingID (the peer simulator's UDID, §11.1)
/// on one registry device: the property key is the runtime's exported
/// constant; the device is asked with -valueForProperty: (Ycode's choice of
/// accessor, checked with respondsToSelector:), else key-value coding.
static NSString *pairingID(id device) {
    static NSString *key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *p = findFunction(@"NRDevicePropertyPairingID", @"NanoRegistry");
        if (p) key = (__bridge NSString *)(*(void **)p);
        logLine(@"NRDevicePropertyPairingID: %@", key ?: @"not found");
    });
    if (!key || !device) return nil;
    id v = nil;
    @try {
        SEL get = NSSelectorFromString(@"valueForProperty:");
        if ([device respondsToSelector:get]) v = ((id (*)(id, SEL, id))objc_msgSend)(device, get, key);
        if (!v) v = [device valueForKey:key];
    } @catch (NSException *e) {
        v = nil;
    }
    return uuidText(v);
}

/// Calls a registry getter that returns at once in the reference, on a queue
/// of its own, so a registry that is not ready (a first boot) cannot hold
/// the agent for long.
static id registryGet(NSString *selectorName, double wait, NSString **error) {
    id r = registry(error);
    if (!r) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    if (![r respondsToSelector:sel]) {
        *error = [NSString stringWithFormat:@"the registry does not answer %@", selectorName];
        return nil;
    }
    __block id result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            result = ((id (*)(id, SEL))objc_msgSend)(r, sel);
        } @catch (NSException *e) {
            result = nil;
        }
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)))) {
        *error = [NSString stringWithFormat:@"%@ did not return in %.0f s", selectorName, wait];
        return nil;
    }
    return result;
}

/// The guest's pair list (§11.1): the pairing IDs of the registry's paired
/// devices. Nil (and *error) when the registry cannot be read.
static NSArray<NSString *> *guestPairedIDs(NSString **error) {
    id devices = registryGet(@"getPairedDevices", 30, error);
    if (*error) return nil;
    NSMutableArray *out = [NSMutableArray array];
    if ([devices conformsToProtocol:@protocol(NSFastEnumeration)]) {
        for (id d in (id<NSFastEnumeration>)devices) {
            NSString *u = pairingID(d);
            if (u && ![out containsObject:u]) [out addObject:u];
        }
    }
    return out;
}

static NSString *guestActiveID(void) {
    NSString *error = nil;
    return pairingID(registryGet(@"getActivePairedDevice", 30, &error));
}

static NSString *const kSwitchSelector = @"switchToSimulator:withQueue:withCompletion:";
static NSString *const kUnpairSelector = @"unpairWithSimulator:withQueue:withCompletion:";

/// set-active (§11.1, P-10; P-11 for `peerRunning` false). `*switched` is
/// YES when the switch call was made and succeeded.
static NSString *setActive(NSString *peer, BOOL previouslyPaired, BOOL peerRunning, NSString *forced, NSString **detail,
                           BOOL *switched) {
    NSString *readError = nil;
    NSArray *ids = guestPairedIDs(&readError);
    NSString *active = ids ? guestActiveID() : nil;
    NSString *P = peer.uppercaseString;
    NSString *state = ids ? [NSString stringWithFormat:@"registry: paired [%@], active %@", [ids componentsJoinedByString:@", "],
                                                       active ?: @"none"]
                          : [NSString stringWithFormat:@"registry not read (%@)", readError];
    NSString *callDetail = nil, *error = nil;
    if (ids && [active isEqual:P]) {
        // The reference's agent fails with POSIX 37 here and its host ignores it.
        *detail = [NSString stringWithFormat:@"%@; already the active device: no call", state];
        return nil;
    }
    BOOL present = ids ? [ids containsObject:P] : previouslyPaired;
    if (present) {
        BOOL completed = NO;
        error = registryCall(kSwitchSelector, peer, forced, 20, &callDetail, &completed);
        *switched = error == nil;
    } else if (!peerRunning) {
        *detail = [NSString stringWithFormat:@"%@; not in the registry: no call (it pairs when it runs)", state];
        return nil;
    } else {
        BOOL completed = NO;
        // The completion comes when the property exchange is done (24–65 s
        // in the reference): answered after 20 s at most (§8.4).
        error = registryCall(kPairSelector, peer, forced, 20, &callDetail, &completed);
    }
    *detail = [NSString stringWithFormat:@"%@; %@", state, callDetail ?: @""];
    return error;
}

static NSString *unpair(NSString *peer, NSString *forced, NSString **detail) {
    BOOL completed = NO;
    // The reference's completion comes about 2 s after the call (§11.1).
    NSString *error = registryCall(kUnpairSelector, peer, forced, 30, detail, &completed);
    return error;
}

static NSString *removeUnpaired(NSArray *hostPaired, NSString **detail) {
    NSString *readError = nil;
    NSArray *ids = guestPairedIDs(&readError);
    if (!ids) {
        *detail = [NSString stringWithFormat:@"the guest's pair list was not read (%@); nothing removed", readError];
        return nil;
    }
    NSMutableArray *host = [NSMutableArray array];
    for (id h in hostPaired) if ([h isKindOfClass:NSString.class]) [host addObject:[(NSString *)h uppercaseString]];
    NSMutableArray *gone = [NSMutableArray array];
    for (NSString *u in ids) if (![host containsObject:u]) [gone addObject:u];
    NSMutableArray *notes = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"host [%@], guest [%@], unpair [%@]", [host componentsJoinedByString:@", "],
                                   [ids componentsJoinedByString:@", "], [gone componentsJoinedByString:@", "]]];
    NSString *firstError = nil;
    for (NSString *u in gone) {
        NSString *d = nil;
        NSString *e = unpair(u, nil, &d);
        [notes addObject:[NSString stringWithFormat:@"%@: %@", u, e ?: d ?: @"done"]];
        if (e && !firstError) firstError = e;
    }
    *detail = [notes componentsJoinedByString:@"; "];
    return firstError;
}

// MARK: - Apps on this device (diagnostics: installing a watch app directly, P-9)
//
// The interfaces of specs/simulator/app-install-launch.md §4.1, §4.3, §4.4:
// install with IXAppInstallCoordinator +installApplication:consumeSource:
// options:completion: and MIInstallOptions -initWithLegacyOptionsDictionary:
// {PackageType = Developer}; look up with LSApplicationProxy
// +applicationProxyForIdentifier: (-isInstalled); open with
// LSApplicationWorkspace -openApplicationWithBundleID:. Ycode's ylaunch is an
// iOS simulator build, so a watch device installs and opens apps through
// this agent (`pairing agent installApp path=…`, `openApp bundleID=…`).

static Class classNamed(NSString *name, NSArray<NSString *> *families) {
    Class c = NSClassFromString(name);
    if (c) return c;
    for (NSString *family in families) {
        for (NSString *path in frameworkPaths(family)) {
            dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
            if ((c = NSClassFromString(name))) return c;
        }
    }
    return Nil;
}

static NSString *installApp(NSString *path, NSString **detail) {
    Class coordinator = classNamed(@"IXAppInstallCoordinator", @[@"InstallCoordination"]);
    Class optionsClass = classNamed(@"MIInstallOptions", @[@"MobileInstallation", @"InstallCoordination"]);
    if (!coordinator || !optionsClass) return @"IXAppInstallCoordinator or MIInstallOptions is not in this runtime";
    SEL make = NSSelectorFromString(@"initWithLegacyOptionsDictionary:");
    SEL install = NSSelectorFromString(@"installApplication:consumeSource:options:completion:");
    if (![optionsClass instancesRespondToSelector:make] || ![coordinator respondsToSelector:install]) {
        return @"the install interfaces do not answer their selectors";
    }
    id options = ((id (*)(id, SEL, id))objc_msgSend)([optionsClass alloc], make, @{@"PackageType": @"Developer"});
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSString *result = nil;
    NSDate *t0 = [NSDate date];
    void (^completion)(id, NSError *) = ^(id bundleID, NSError *error) {
        result = error ? [NSString stringWithFormat:@"error %@", error] : [NSString stringWithFormat:@"installed %@", bundleID];
        dispatch_semaphore_signal(done);
    };
    ((void (*)(id, SEL, id, BOOL, id, id))objc_msgSend)(coordinator, install, [NSURL fileURLWithPath:path], NO, options,
                                                         completion);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC))) return @"no completion in 300 s";
    *detail = [NSString stringWithFormat:@"%@ after %.1f s", result, -t0.timeIntervalSinceNow];
    return [result hasPrefix:@"error"] ? *detail : nil;
}

static NSString *appState(NSString *bundleID, NSString **detail) {
    Class proxyClass = classNamed(@"LSApplicationProxy", @[@"MobileCoreServices", @"CoreServices"]);
    SEL forID = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:forID]) return @"no LSApplicationProxy";
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, forID, bundleID);
    BOOL installed = [proxy respondsToSelector:NSSelectorFromString(@"isInstalled")]
        && ((BOOL (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"isInstalled"));
    id url = [proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]
        ? ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleURL")) : nil;
    id data = [proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")]
        ? ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"dataContainerURL")) : nil;
    *detail = [NSString stringWithFormat:@"%@ installed %d bundle %@ data %@", bundleID, installed, [url path], [data path]];
    return nil;
}

/// FrontBoard's open-application service (§4.4: works without debug options
/// for a caller with com.apple.frontboard.launchapplications, which the
/// agent's entitlements carry). The completion gets a process handle and an error.
static NSString *openWithFrontBoard(NSString *bundleID, NSString **detail) {
    Class serviceClass = classNamed(@"FBSOpenApplicationService", @[@"FrontBoardServices"]);
    Class optionsClass = classNamed(@"FBSOpenApplicationOptions", @[@"FrontBoardServices"]);
    SEL endpoint = NSSelectorFromString(@"serviceWithDefaultShellEndpoint");
    SEL make = NSSelectorFromString(@"optionsWithDictionary:");
    SEL open = NSSelectorFromString(@"openApplication:withOptions:completion:");
    if (!serviceClass || !optionsClass || ![serviceClass respondsToSelector:endpoint] || ![optionsClass respondsToSelector:make]) {
        return @"no FBSOpenApplicationService";
    }
    id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, endpoint);
    id options = ((id (*)(id, SEL, id))objc_msgSend)(optionsClass, make, @{});
    if (!service || ![service respondsToSelector:open]) return @"the open-application service is not available";
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSString *result = nil;
    __block BOOL ok = NO;
    NSDate *t0 = [NSDate date];
    void (^completion)(id, NSError *) = ^(id process, NSError *error) {
        ok = error == nil;
        id pid = [process respondsToSelector:NSSelectorFromString(@"pid")] ? [process valueForKey:@"pid"] : nil;
        result = error ? [NSString stringWithFormat:@"error %@", error] : [NSString stringWithFormat:@"launched pid %@", pid];
        dispatch_semaphore_signal(done);
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, open, bundleID, options, completion);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC))) return @"FrontBoard: no completion in 60 s";
    *detail = [NSString stringWithFormat:@"FrontBoard open %@: %@ after %.2f s", bundleID, result, -t0.timeIntervalSinceNow];
    return ok ? nil : *detail;
}

static NSString *openApp(NSString *bundleID, NSString **detail) {
    Class workspaceClass = classNamed(@"LSApplicationWorkspace", @[@"MobileCoreServices", @"CoreServices"]);
    SEL shared = NSSelectorFromString(@"defaultWorkspace");
    SEL open = NSSelectorFromString(@"openApplicationWithBundleID:");
    NSString *first = @"no LSApplicationWorkspace";
    if (workspaceClass && [workspaceClass respondsToSelector:shared]) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, shared);
        if ([workspace respondsToSelector:open]) {
            NSDate *t0 = [NSDate date];
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, open, bundleID);
            first = [NSString stringWithFormat:@"open %@: %@ after %.2f s", bundleID, ok ? @"YES" : @"NO", -t0.timeIntervalSinceNow];
            if (ok) {
                *detail = first;
                return nil;
            }
        }
    }
    // The workspace refused (as on watchOS under Ycode, §10.4): FrontBoard.
    NSString *second = nil;
    NSString *error = openWithFrontBoard(bundleID, &second);
    *detail = [NSString stringWithFormat:@"%@; %@", first, second ?: error];
    return error ? *detail : nil;
}

// MARK: - Requests

static NSDictionary *handle(NSDictionary *request) {
    NSString *op = request[@"op"];
    NSString *peer = [request[@"peer"] isKindOfClass:NSString.class] ? request[@"peer"] : nil;
    NSString *forced = [request[@"argKind"] isKindOfClass:NSString.class] ? request[@"argKind"] : nil;
    NSString *error = nil, *detail = nil;
    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    if ([op isEqual:@"connect"] && peer) {
        logLine(@"connect to %@", peer);
        error = callPeerFunction(@"IDSSimulatorLocalPairingTransportConnect", @"IDS", peer, forced, &detail);
    } else if ([op isEqual:@"disconnect"] && peer) {
        logLine(@"disconnect from %@", peer);
        error = callPeerFunction(@"IDSSimulatorLocalPairingTransportDisconnect", @"IDS", peer, forced, &detail);
    } else if ([op isEqual:@"setActive"] && peer) {
        BOOL before = [request[@"previouslyPaired"] boolValue];
        BOOL running = request[@"peerRunning"] ? [request[@"peerRunning"] boolValue] : YES;
        logLine(@"make %@ the active pair (%@)", peer, running ? @"it runs" : @"it does not run: switch only");
        BOOL switched = NO;
        error = setActive(peer, before, running, forced, &detail, &switched);
        if (switched) extra[@"switched"] = @YES;
    } else if ([op isEqual:@"removeUnpaired"]) {
        NSArray *host = [request[@"hostPaired"] isKindOfClass:NSArray.class] ? request[@"hostPaired"] : @[];
        logLine(@"remove pairs the host no longer has (host pairs: %@)", host.count ? [host componentsJoinedByString:@", "] : @"none");
        error = removeUnpaired(host, &detail);
    } else if ([op isEqual:@"unpair"] && peer) {
        logLine(@"unpair from %@", peer);
        error = unpair(peer, forced, &detail);
    } else if ([op isEqual:@"pairs"]) {
        // Diagnostics: the guest's pair list and its active device.
        NSString *e = nil;
        NSArray *ids = guestPairedIDs(&e);
        if (ids) detail = [NSString stringWithFormat:@"paired [%@], active %@", [ids componentsJoinedByString:@", "], guestActiveID() ?: @"none"];
        else error = e;
    } else if ([op isEqual:@"call"]) {
        // Diagnostics: a peer function by name (`pairing agent call <function> <peer> [string|uuid]`).
        NSString *function = request[@"function"];
        if (![function hasPrefix:@"IDSSimulatorLocalPairing"] || !peer) {
            error = @"call: only IDSSimulatorLocalPairing… functions, with a peer";
        } else {
            error = callPeerFunction(function, @"IDS", peer, forced, &detail);
        }
    } else if ([op isEqual:@"installApp"] && [request[@"path"] isKindOfClass:NSString.class]) {
        logLine(@"install %@", request[@"path"]);
        error = installApp(request[@"path"], &detail);
    } else if ([op isEqual:@"appState"] && [request[@"bundleID"] isKindOfClass:NSString.class]) {
        error = appState(request[@"bundleID"], &detail);
    } else if ([op isEqual:@"openApp"] && [request[@"bundleID"] isKindOfClass:NSString.class]) {
        logLine(@"open %@", request[@"bundleID"]);
        error = openApp(request[@"bundleID"], &detail);
    } else if (![op isEqual:@"ping"]) {
        error = [NSString stringWithFormat:@"unknown or incomplete request %@", op];
    }
    if (detail) logLine(@"%@: %@", op, detail);
    if (error) logLine(@"%@: %@", op, error);
    NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithObject:@(error == nil) forKey:@"ok"];
    [reply addEntriesFromDictionary:extra];
    if (error) reply[@"error"] = error;
    if (detail) reply[@"detail"] = detail;
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
        gWork = dispatch_queue_create("dev.ycode.pairing-agent", DISPATCH_QUEUE_SERIAL);
        loadState();
        logLine(@"started (version %d)", kVersion);
        [NSThread detachNewThreadWithBlock:^{ serve(); }];
        dispatch_main();
    }
}
