// ycode-health-agent: Ycode's guest health agent
// (specs/simulator/health-simulation.md §8.1, H-1…H-4; "Ycode implementation").
//
// The executable of a small app bundle, `YcodeHealth.app` (bundle id
// dev.ycode.health, display name "Ycode Health"), that ycode-simd stages into
// DEV/data/Library/Ycode/ and runs as a launchd daemon of the device (its
// plist in DEV/data/Library/LaunchDaemons, like the settings agent). Its
// simulated-entitlements section (__TEXT,__entitlements) carries
// application-identifier = dev.ycode.health and com.apple.developer.healthkit,
// so HealthKit gives it its own source (healthd takes the source's bundle id
// from application-identifier; simulator-baseline.md §6).
//
// It connects an AF_UNIX stream socket to /private/var/run/dev.ycode.health,
// which the VMM answers itself (the host channel of simulator-features.md
// §I.2: a 4-byte big-endian length, then an XML property list with a
// dictionary root; YcodeSimFeatures/HealthChannel.swift has the requests),
// and carries out the host's requests with HealthKit's public API only:
//
//   authorize {share:[ids], read:[ids]}   requestAuthorizationToShareTypes:readTypes:
//   write {samples:[…], device?}          HKQuantitySample / HKCategorySample, saveObjects:
//                                         in batches of at most 200
//   workout {activity, start, end, samples:[…], route?:[[lat, lon, t]…], metadata?}
//                                         HKWorkoutBuilder (+ HKWorkoutRouteBuilder)
//   delete {types:[ids]}                  deleteObjectsOfType:predicate: with the
//                                         agent's own source (other sources are never touched)
//   count {types:[ids]}                   HKSampleQuery counts of the agent's own samples
//   status                                availability, source, authorization per type
//   ping
//
// The host validates every sample first (HealthImport.swift), so HealthKit's
// validation exceptions should never happen; the agent still catches them and
// reports the first one. Every sample carries the metadata key
// `YcodeSynthetic` (1): the data is synthetic and was written by Ycode.
//
// `--selftest` (a diagnostic): asks for heart-rate and step-count access,
// saves one heart-rate sample and counts the agent's heart-rate samples,
// logging each result, then serves the host channel as usual.
//
// Clean-room: written from the spec and the public HealthKit, Foundation and
// CoreLocation headers; no Apple binary was read.

#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>
#import <CoreLocation/CoreLocation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>

static const char *kSocketPaths[] = {"/private/var/run/dev.ycode.health", "/var/run/dev.ycode.health"};
static const int kVersion = 1;
static const NSUInteger kBatch = 200;
static const NSTimeInterval kCallTimeout = 120;

static int gFD = -1;
static NSLock *gWriteLock;
static dispatch_queue_t gWork;
static HKHealthStore *gStore;

static void logLine(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "ycode-health-agent[%d]: %s\n", getpid(), s.UTF8String);
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

// MARK: - Helpers

static NSString *errorText(NSError *e) {
    if (!e) return @"failed";
    return [NSString stringWithFormat:@"%@ code %ld: %@", e.domain, (long)e.code, e.localizedDescription];
}

/// Waits for a completion that signals `s` (false: it never came).
static BOOL waitFor(dispatch_semaphore_t s) {
    return dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCallTimeout * NSEC_PER_SEC))) == 0;
}

/// The object type of an identifier: quantity, category, or the workout type.
static HKObjectType *objectType(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    if ([identifier isEqual:@"HKWorkoutTypeIdentifier"]) return [HKObjectType workoutType];
    if ([identifier isEqual:@"HKWorkoutRouteTypeIdentifier"]) return [HKSeriesType workoutRouteType];
    if ([identifier hasPrefix:@"HKQuantityTypeIdentifier"]) return [HKObjectType quantityTypeForIdentifier:identifier];
    if ([identifier hasPrefix:@"HKCategoryTypeIdentifier"]) return [HKObjectType categoryTypeForIdentifier:identifier];
    return nil;
}

static NSSet<HKObjectType *> *typeSet(NSArray *identifiers, NSMutableArray *unknown) {
    NSMutableSet *out = [NSMutableSet set];
    for (NSString *i in [identifiers isKindOfClass:NSArray.class] ? identifiers : @[]) {
        HKObjectType *t = objectType(i);
        if (t) [out addObject:t]; else [unknown addObject:i ?: @"?"];
    }
    return out;
}

static NSDate *dateValue(id v) {
    if ([v isKindOfClass:NSDate.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [NSDate dateWithTimeIntervalSince1970:[v doubleValue]];
    return nil;
}

/// Plist metadata → HealthKit metadata (strings, numbers, dates; `{value, unit}`
/// dictionaries become quantities), plus the synthetic-data mark.
static NSDictionary *metadataValue(id v) {
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithObject:@1 forKey:@"YcodeSynthetic"];
    if (![v isKindOfClass:NSDictionary.class]) return m;
    for (NSString *k in v) {
        id x = v[k];
        if ([x isKindOfClass:NSDictionary.class] && [x[@"unit"] isKindOfClass:NSString.class] && [x[@"value"] isKindOfClass:NSNumber.class]) {
            @try {
                m[k] = [HKQuantity quantityWithUnit:[HKUnit unitFromString:x[@"unit"]] doubleValue:[x[@"value"] doubleValue]];
            } @catch (NSException *e) {
                logLine(@"metadata %@: %@", k, e.reason);
            }
        } else if ([x isKindOfClass:NSString.class] || [x isKindOfClass:NSNumber.class] || [x isKindOfClass:NSDate.class]) {
            m[k] = x;
        }
    }
    return m;
}

static HKDevice *deviceValue(id d) {
    if (![d isKindOfClass:NSDictionary.class]) return [HKDevice localDevice];
    NSString *(^s)(NSString *) = ^NSString *(NSString *k) { return [d[k] isKindOfClass:NSString.class] ? d[k] : nil; };
    HKDevice *local = [HKDevice localDevice];
    return [[HKDevice alloc] initWithName:s(@"name") ?: local.name manufacturer:s(@"manufacturer") ?: local.manufacturer
                                    model:s(@"model") ?: local.model hardwareVersion:s(@"hardware") ?: local.hardwareVersion
                          firmwareVersion:s(@"firmware") ?: local.firmwareVersion
                          softwareVersion:s(@"software") ?: local.softwareVersion
                          localIdentifier:s(@"localIdentifier") UDIDeviceIdentifier:nil];
}

/// One sample of the host's `{type, start, end, value, unit?, metadata?}`, or nil with `*why`.
static HKSample *makeSample(NSDictionary *d, HKDevice *device, NSString **why) {
    if (![d isKindOfClass:NSDictionary.class]) {
        *why = @"a sample that is not a dictionary";
        return nil;
    }
    NSString *identifier = d[@"type"];
    HKObjectType *type = objectType(identifier);
    NSDate *start = dateValue(d[@"start"]), *end = dateValue(d[@"end"]) ?: start;
    if (!type || !start) {
        *why = [NSString stringWithFormat:@"%@: %@", identifier ?: @"?", type ? @"no start date" : @"not a type this runtime knows"];
        return nil;
    }
    @try {
        if ([type isKindOfClass:HKQuantityType.class]) {
            if (![d[@"unit"] isKindOfClass:NSString.class] || ![d[@"value"] isKindOfClass:NSNumber.class]) {
                *why = [NSString stringWithFormat:@"%@: a quantity needs value and unit", identifier];
                return nil;
            }
            HKQuantity *q = [HKQuantity quantityWithUnit:[HKUnit unitFromString:d[@"unit"]] doubleValue:[d[@"value"] doubleValue]];
            return [HKQuantitySample quantitySampleWithType:(HKQuantityType *)type quantity:q startDate:start endDate:end
                                                      device:device metadata:metadataValue(d[@"metadata"])];
        }
        if ([type isKindOfClass:HKCategoryType.class]) {
            if (![d[@"value"] isKindOfClass:NSNumber.class]) {
                *why = [NSString stringWithFormat:@"%@: a category needs an integer value", identifier];
                return nil;
            }
            return [HKCategorySample categorySampleWithType:(HKCategoryType *)type value:[d[@"value"] integerValue]
                                                  startDate:start endDate:end device:device metadata:metadataValue(d[@"metadata"])];
        }
    } @catch (NSException *e) {
        *why = [NSString stringWithFormat:@"%@: %@: %@", identifier, e.name, e.reason];
        return nil;
    }
    *why = [NSString stringWithFormat:@"%@: not a quantity or category type", identifier];
    return nil;
}

/// Saves `objects` in batches. Returns the number saved; `*firstError` the first failure.
static NSUInteger saveAll(NSArray<HKObject *> *objects, NSString **firstError) {
    NSUInteger saved = 0;
    for (NSUInteger i = 0; i < objects.count; i += kBatch) {
        NSArray *batch = [objects subarrayWithRange:NSMakeRange(i, MIN(kBatch, objects.count - i))];
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        __block NSError *err = nil;
        @try {
            [gStore saveObjects:batch withCompletion:^(BOOL success, NSError *error) {
                ok = success;
                err = error;
                dispatch_semaphore_signal(s);
            }];
        } @catch (NSException *e) {
            if (!*firstError) *firstError = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
            continue;
        }
        if (!waitFor(s)) {
            if (!*firstError) *firstError = @"HealthKit did not answer a save in time";
            continue;
        }
        if (ok) saved += batch.count; else if (!*firstError) *firstError = errorText(err);
    }
    return saved;
}

// MARK: - Requests

static NSDictionary *authStatuses(NSArray *identifiers) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *i in identifiers) {
        HKObjectType *t = objectType(i);
        if (t) out[i] = @([gStore authorizationStatusForType:t]);
    }
    return out;
}

static NSDictionary *authorize(NSDictionary *r) {
    NSMutableArray *unknown = [NSMutableArray array];
    NSSet *share = typeSet(r[@"share"], unknown), *read = typeSet(r[@"read"], unknown);
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    __block NSError *err = nil;
    @try {
        [gStore requestAuthorizationToShareTypes:(NSSet<HKSampleType *> *)share readTypes:read completion:^(BOOL success, NSError *error) {
            ok = success;
            err = error;
            dispatch_semaphore_signal(s);
        }];
    } @catch (NSException *e) {
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: %@", e.name, e.reason]};
    }
    BOOL answered = waitFor(s);
    NSMutableDictionary *reply = [@{@"ok": @(answered && ok), @"answered": @(answered),
                                    @"statuses": authStatuses([r[@"share"] isKindOfClass:NSArray.class] ? r[@"share"] : @[]),
                                    @"unknown": unknown} mutableCopy];
    if (!answered) reply[@"error"] = @"the authorization request was not answered (no grant yet: Ycode grants its agent while the device is shut down)";
    else if (!ok) reply[@"error"] = errorText(err);
    return reply;
}

static NSDictionary *writeSamples(NSDictionary *r) {
    NSArray *list = [r[@"samples"] isKindOfClass:NSArray.class] ? r[@"samples"] : @[];
    HKDevice *device = deviceValue(r[@"device"]);
    NSMutableArray *objects = [NSMutableArray arrayWithCapacity:list.count];
    NSString *first = nil;
    NSUInteger refused = 0;
    for (NSDictionary *d in list) {
        NSString *why = nil;
        HKSample *s = makeSample(d, device, &why);
        if (s) [objects addObject:s]; else { refused++; if (!first) first = why; }
    }
    NSString *saveError = nil;
    NSUInteger saved = saveAll(objects, &saveError);
    if (!first) first = saveError;
    NSMutableDictionary *reply = [@{@"ok": @(saved == list.count), @"saved": @(saved), @"refused": @(refused),
                                    @"requested": @(list.count)} mutableCopy];
    if (first) reply[@"error"] = first;
    return reply;
}

static NSDictionary *writeWorkout(NSDictionary *r) {
    NSDate *start = dateValue(r[@"start"]), *end = dateValue(r[@"end"]);
    if (!start || !end) return @{@"ok": @NO, @"error": @"a workout needs start and end"};
    HKWorkoutConfiguration *config = [HKWorkoutConfiguration new];
    config.activityType = (HKWorkoutActivityType)[r[@"activity"] unsignedIntegerValue];
    config.locationType = [r[@"indoor"] boolValue] ? HKWorkoutSessionLocationTypeIndoor : HKWorkoutSessionLocationTypeOutdoor;
    HKDevice *device = deviceValue(r[@"device"]);
    HKWorkoutBuilder *builder = [[HKWorkoutBuilder alloc] initWithHealthStore:gStore configuration:config device:device];
    __block BOOL ok = NO;
    __block NSError *err = nil;
    void (^step)(void (^)(void (^)(BOOL, NSError *))) = ^(void (^call)(void (^)(BOOL, NSError *))) {
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        ok = NO;
        err = nil;
        call(^(BOOL success, NSError *error) {
            ok = success;
            err = error;
            dispatch_semaphore_signal(s);
        });
        if (!waitFor(s)) err = [NSError errorWithDomain:@"dev.ycode.health" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no answer in time"}];
    };
    step(^(void (^done)(BOOL, NSError *)) { [builder beginCollectionWithStartDate:start completion:done]; });
    if (!ok) return @{@"ok": @NO, @"error": [@"beginCollection: " stringByAppendingString:errorText(err)]};
    NSMutableArray *samples = [NSMutableArray array];
    NSString *first = nil;
    for (NSDictionary *d in [r[@"samples"] isKindOfClass:NSArray.class] ? r[@"samples"] : @[]) {
        NSString *why = nil;
        HKSample *s = makeSample(d, device, &why);
        if (s) [samples addObject:s]; else if (!first) first = why;
    }
    NSUInteger added = 0;
    for (NSUInteger i = 0; i < samples.count; i += kBatch) {
        NSArray *batch = [samples subarrayWithRange:NSMakeRange(i, MIN(kBatch, samples.count - i))];
        step(^(void (^done)(BOOL, NSError *)) { [builder addSamples:batch completion:done]; });
        if (ok) added += batch.count; else if (!first) first = [@"addSamples: " stringByAppendingString:errorText(err)];
    }
    step(^(void (^done)(BOOL, NSError *)) { [builder addMetadata:metadataValue(r[@"metadata"]) completion:done]; });
    step(^(void (^done)(BOOL, NSError *)) { [builder endCollectionWithEndDate:end completion:done]; });
    if (!ok) return @{@"ok": @NO, @"error": [@"endCollection: " stringByAppendingString:errorText(err)]};
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block HKWorkout *workout = nil;
    [builder finishWorkoutWithCompletion:^(HKWorkout *w, NSError *error) {
        workout = w;
        err = error;
        dispatch_semaphore_signal(s);
    }];
    if (!waitFor(s) || !workout) return @{@"ok": @NO, @"error": [@"finishWorkout: " stringByAppendingString:errorText(err)]};
    NSUInteger routePoints = 0;
    NSArray *route = [r[@"route"] isKindOfClass:NSArray.class] ? r[@"route"] : @[];
    if (route.count) {
        NSMutableArray<CLLocation *> *locations = [NSMutableArray array];
        for (NSArray *p in route) {
            if (![p isKindOfClass:NSArray.class] || p.count < 3) continue;
            CLLocationCoordinate2D c = CLLocationCoordinate2DMake([p[0] doubleValue], [p[1] doubleValue]);
            [locations addObject:[[CLLocation alloc] initWithCoordinate:c altitude:0 horizontalAccuracy:5 verticalAccuracy:-1
                                                                 course:-1 speed:-1 timestamp:dateValue(p[2]) ?: start]];
        }
        HKWorkoutRouteBuilder *rb = [[HKWorkoutRouteBuilder alloc] initWithHealthStore:gStore device:device];
        step(^(void (^done)(BOOL, NSError *)) { [rb insertRouteData:locations completion:done]; });
        if (ok) {
            dispatch_semaphore_t rs = dispatch_semaphore_create(0);
            __block HKWorkoutRoute *saved = nil;
            [rb finishRouteWithWorkout:workout metadata:metadataValue(nil) completion:^(HKWorkoutRoute *wr, NSError *error) {
                saved = wr;
                err = error;
                dispatch_semaphore_signal(rs);
            }];
            if (waitFor(rs) && saved) routePoints = locations.count;
            else if (!first) first = [@"route: " stringByAppendingString:errorText(err)];
        } else if (!first) {
            first = [@"route: " stringByAppendingString:errorText(err)];
        }
    }
    NSMutableDictionary *reply = [@{@"ok": @(first == nil), @"saved": @(added), @"workout": workout.UUID.UUIDString,
                                    @"routePoints": @(routePoints)} mutableCopy];
    if (first) reply[@"error"] = first;
    return reply;
}

static NSPredicate *ownSamples(void) {
    return [HKQuery predicateForObjectsFromSource:[HKSource defaultSource]];
}

static NSDictionary *deleteSamples(NSDictionary *r) {
    NSUInteger total = 0;
    NSString *first = nil;
    NSMutableDictionary *perType = [NSMutableDictionary dictionary];
    for (NSString *i in [r[@"types"] isKindOfClass:NSArray.class] ? r[@"types"] : @[]) {
        HKObjectType *t = objectType(i);
        if (!t) continue;
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        __block NSUInteger n = 0;
        __block BOOL ok = NO;
        __block NSError *err = nil;
        [gStore deleteObjectsOfType:t predicate:ownSamples() withCompletion:^(BOOL success, NSUInteger count, NSError *error) {
            ok = success;
            n = count;
            err = error;
            dispatch_semaphore_signal(s);
        }];
        if (!waitFor(s)) { if (!first) first = @"no answer in time"; continue; }
        if (ok) { total += n; if (n) perType[i] = @(n); } else if (!first) first = [NSString stringWithFormat:@"%@: %@", i, errorText(err)];
    }
    NSMutableDictionary *reply = [@{@"ok": @(first == nil), @"deleted": @(total), @"perType": perType} mutableCopy];
    if (first) reply[@"error"] = first;
    return reply;
}

static NSDictionary *countSamples(NSDictionary *r) {
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSString *first = nil;
    for (NSString *i in [r[@"types"] isKindOfClass:NSArray.class] ? r[@"types"] : @[]) {
        HKObjectType *t = objectType(i);
        if (![t isKindOfClass:HKSampleType.class]) continue;
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        __block NSUInteger n = 0;
        __block NSError *err = nil;
        HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:(HKSampleType *)t predicate:ownSamples() limit:HKObjectQueryNoLimit
                                                     sortDescriptors:nil resultsHandler:^(HKSampleQuery *query, NSArray *results, NSError *error) {
            (void)query;
            n = results.count;
            err = error;
            dispatch_semaphore_signal(s);
        }];
        [gStore executeQuery:q];
        if (!waitFor(s)) { if (!first) first = @"no answer in time"; continue; }
        if (err) { if (!first) first = [NSString stringWithFormat:@"%@: %@", i, errorText(err)]; continue; }
        if (n) counts[i] = @(n);
    }
    NSMutableDictionary *reply = [@{@"ok": @(first == nil), @"counts": counts} mutableCopy];
    if (first) reply[@"error"] = first;
    return reply;
}

static NSDictionary *status(NSDictionary *r) {
    HKSource *source = [HKSource defaultSource];
    HKDevice *local = [HKDevice localDevice];
    return @{@"ok": @YES, @"available": @([HKHealthStore isHealthDataAvailable]),
             @"source": source.name ?: @"", @"bundleID": source.bundleIdentifier ?: @"",
             @"device": [NSString stringWithFormat:@"%@/%@/%@/%@", local.name, local.model, local.hardwareVersion, local.softwareVersion],
             @"statuses": authStatuses([r[@"types"] isKindOfClass:NSArray.class] ? r[@"types"] : @[]), @"version": @(kVersion)};
}

static NSDictionary *handle(NSDictionary *request) {
    NSString *op = request[@"op"];
    @try {
        if ([op isEqual:@"ping"]) return @{@"ok": @YES};
        if ([op isEqual:@"status"]) return status(request);
        if ([op isEqual:@"authorize"]) return authorize(request);
        if ([op isEqual:@"write"]) return writeSamples(request);
        if ([op isEqual:@"workout"]) return writeWorkout(request);
        if ([op isEqual:@"delete"]) return deleteSamples(request);
        if ([op isEqual:@"count"]) return countSamples(request);
    } @catch (NSException *e) {
        logLine(@"%@: %@: %@", op, e.name, e.reason);
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: %@", e.name, e.reason]};
    }
    return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"unknown request '%@'", op ?: @"?"]};
}

// MARK: - Self-test

static void selftest(void) {
    NSDictionary *st = status(@{@"types": @[HKQuantityTypeIdentifierHeartRate, HKQuantityTypeIdentifierStepCount]});
    logLine(@"selftest: status %@", st);
    NSArray *types = @[HKQuantityTypeIdentifierHeartRate, HKQuantityTypeIdentifierStepCount];
    logLine(@"selftest: authorize %@", authorize(@{@"share": types, @"read": types}));
    NSDate *now = [NSDate date];
    logLine(@"selftest: write %@", writeSamples(@{@"samples": @[@{@"type": HKQuantityTypeIdentifierHeartRate, @"start": now, @"end": now,
                                                                     @"value": @72, @"unit": @"count/min"}]}));
    logLine(@"selftest: count %@", countSamples(@{@"types": types}));
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
        HKSource *source = [HKSource defaultSource];
        logLine(@"connected to the host (source %@, %@)", source.name, source.bundleIdentifier);
        sendMessage(@{@"event": @"hello", @"pid": @(getpid()), @"version": @(kVersion),
                      @"available": @([HKHealthStore isHealthDataAvailable]), @"bundleID": source.bundleIdentifier ?: @"",
                      @"source": source.name ?: @"", @"model": [HKDevice localDevice].model ?: @""});
        for (;;) {
            uint8_t header[4];
            if (!readAll(fd, header, 4)) break;
            uint32_t n = (uint32_t)header[0] << 24 | (uint32_t)header[1] << 16 | (uint32_t)header[2] << 8 | header[3];
            if (n > (16u << 20)) {
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
                    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                    NSMutableDictionary *reply = [handle(request) mutableCopy];
                    reply[@"id"] = requestID;
                    reply[@"ms"] = @((int)((CFAbsoluteTimeGetCurrent() - t0) * 1000));
                    logLine(@"%@: ok %@ in %@ ms%@", request[@"op"], reply[@"ok"], reply[@"ms"],
                            reply[@"error"] ? [@": " stringByAppendingString:reply[@"error"]] : @"");
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
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        gWriteLock = [NSLock new];
        gWork = dispatch_queue_create("dev.ycode.health-agent", DISPATCH_QUEUE_SERIAL);
        gStore = [HKHealthStore new];
        logLine(@"started (version %d, health data %@)", kVersion, [HKHealthStore isHealthDataAvailable] ? @"available" : @"unavailable");
        BOOL test = NO;
        for (int i = 1; i < argc; i++) if (strcmp(argv[i], "--selftest") == 0) test = YES;
        if (test) dispatch_async(gWork, ^{ @autoreleasepool { selftest(); } });
        [NSThread detachNewThreadWithBlock:^{ serve(); }];
        dispatch_main();
    }
}
