// HealthSim probe core: Ycode research probe (original Ycode code, no Apple
// code), written from Apple's public HealthKit documentation and SDK headers.
// One source, built for the iOS simulator and the watchOS simulator.
// Every value it writes is made up (synthetic); no real health data.
//
// Log lines: "HS <side> <unix time> <event> key=value ..." to stderr (NSLog)
// and to <data container>/Documents/hs.log.
//
// Launch arguments: a list of phases, run in order on a worker thread:
//   info                       availability, local device, request status
//   status                     authorization status of every type
//   auth all|small|read        request authorization (all types; a small
//                              set for sync tests; read-only request)
//   write                      save one synthetic sample of every type
//   workout <secs> [run|walk|cycle|hiit] live workout session + builder,
//                              logging every collected statistic and every
//                              raw sample of the collected types
//   observe <secs> [bg]        observer + anchored queries on a small set;
//                              bg: enable background delivery first
//   burst <n> <every-secs> <tag>  write n marked samples (steps, HR, SpO2,
//                              sleep) with metadata hs.t (writer time)
//   count                      per-type sample counts and sources
//   dump <identifier> [n]      list the newest n samples of one type
//   wait <secs>                sleep
#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>
#import <CoreLocation/CoreLocation.h>
#include <TargetConditionals.h>
#if TARGET_OS_WATCH
#import <WatchKit/WatchKit.h>
#else
#import <UIKit/UIKit.h>
#endif

static NSString *gSide = @"?";
static HKHealthStore *gStore;
static NSFileHandle *gLog;
static double gStarted;

typedef struct { __unsafe_unretained NSString *ident; __unsafe_unretained NSString *unit; __unsafe_unretained NSString *agg; BOOL cat; } HSType;
static HSType kTypes[256];
static int kNTypes;
static NSMutableArray *kKeep;
static void initTypes(void)
{
    kKeep = [NSMutableArray array];
#define Q(i, u, a) { NSString *x = i; if (x) { [kKeep addObject:x]; kTypes[kNTypes++] = (HSType){ x, u, a, NO }; } }
#define C(i, e) { NSString *x = i; if (x) { [kKeep addObject:x]; kTypes[kNTypes++] = (HSType){ x, e, @"", YES }; } }
#include "types.inc"
#undef Q
#undef C
}

static NSString *appState(void)
{
    __block long s = -1;
    void (^b)(void) = ^{
#if TARGET_OS_WATCH
        s = (long)[[WKApplication sharedApplication] applicationState];
#else
        s = (long)[[UIApplication sharedApplication] applicationState];
#endif
    };
    if ([NSThread isMainThread]) b(); else dispatch_sync(dispatch_get_main_queue(), b);
    return [NSString stringWithFormat:@"%ld", s];
}

void HSLog(NSString *ev, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
void HSLog(NSString *ev, NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *rest = fmt ? [[NSString alloc] initWithFormat:fmt arguments:ap] : @"";
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"HS %@ %.3f %@ %@", gSide, [[NSDate date] timeIntervalSince1970], ev, rest];
    NSLog(@"%@", line);
    @synchronized (gSide) {
        [gLog writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [gLog synchronizeFile];
    }
}

static NSString *errStr(NSError *e)
{
    if (!e) return @"nil";
    return [NSString stringWithFormat:@"%@/%ld \"%@\"", e.domain, (long)e.code, e.localizedDescription];
}

static HKSampleType *typeFor(HSType t)
{
    return t.cat ? [HKObjectType categoryTypeForIdentifier:t.ident] : [HKObjectType quantityTypeForIdentifier:t.ident];
}

static NSString *unitFor(HKSampleType *st)
{
    for (int i = 0; i < kNTypes; i++)
        if (!kTypes[i].cat && [kTypes[i].ident isEqualToString:st.identifier]) return kTypes[i].unit;
    return nil;
}

static NSArray<HKSampleType *> *otherTypes(void)
{
    NSMutableArray *a = [NSMutableArray array];
    [a addObject:[HKObjectType workoutType]];
    [a addObject:[HKSeriesType workoutRouteType]];
    [a addObject:[HKSeriesType heartbeatSeriesType]];
    [a addObject:[HKObjectType electrocardiogramType]];
    [a addObject:[HKObjectType audiogramSampleType]];
    [a addObject:[HKObjectType stateOfMindType]];
    return a;
}

static NSArray<HKSampleType *> *allSampleTypes(void)
{
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < kNTypes; i++) { HKSampleType *t = typeFor(kTypes[i]); if (t) [a addObject:t]; }
    [a addObjectsFromArray:otherTypes()];
    return a;
}

static NSArray<HKSampleType *> *smallTypes(void)
{
    return @[ [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount],
              [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate],
              [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierOxygenSaturation],
              [HKObjectType categoryTypeForIdentifier:HKCategoryTypeIdentifierSleepAnalysis],
              [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierActiveEnergyBurned],
              [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning],
              [HKObjectType workoutType] ];
}

static NSString *ids(id<NSFastEnumeration> set)
{
    NSMutableArray *a = [NSMutableArray array];
    for (HKObjectType *t in set) [a addObject:t.identifier];
    [a sortUsingSelector:@selector(compare:)];
    return [a componentsJoinedByString:@","];
}

static void waitSem(dispatch_semaphore_t s, double secs)
{
    dispatch_semaphore_wait(s, secs < 0 ? DISPATCH_TIME_FOREVER : dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)));
}

// ---------------------------------------------------------------- info, status

static void phaseInfo(void)
{
    HKDevice *d = [HKDevice localDevice];
    HSLog(@"info", @"available=%d device.name=%@ model=%@ hw=%@ sw=%@ appState=%@", [HKHealthStore isHealthDataAvailable],
          d.name, d.model, d.hardwareVersion, d.softwareVersion, appState());
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    NSSet *all = [NSSet setWithArray:smallTypes()];
    [gStore getRequestStatusForAuthorizationToShareTypes:all readTypes:all completion:^(HKAuthorizationRequestStatus st, NSError *e) {
        HSLog(@"requestStatus", @"small=%ld error=%@", (long)st, errStr(e));
        dispatch_semaphore_signal(s);
    }];
    waitSem(s, 60);
}

static void phaseReqStat(void)
{
    for (HKSampleType *t in smallTypes()) {
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        NSSet *one = [NSSet setWithObject:t];
        [gStore getRequestStatusForAuthorizationToShareTypes:one readTypes:one completion:^(HKAuthorizationRequestStatus st, NSError *e) {
            HSLog(@"reqStatus", @"type=%@ shareRead=%ld status=%ld error=%@", t.identifier, (long)st, (long)[gStore authorizationStatusForType:t], errStr(e));
            dispatch_semaphore_signal(s);
        }];
        waitSem(s, 60);
        s = dispatch_semaphore_create(0);
        [gStore getRequestStatusForAuthorizationToShareTypes:[NSSet set] readTypes:one completion:^(HKAuthorizationRequestStatus st, NSError *e) {
            HSLog(@"reqStatus", @"type=%@ readOnly=%ld error=%@", t.identifier, (long)st, errStr(e));
            dispatch_semaphore_signal(s);
        }];
        waitSem(s, 60);
    }
}

static void phaseAuthOne(NSString *ident)
{
    HKSampleType *t = nil;
    for (HKSampleType *x in allSampleTypes()) if ([x.identifier isEqualToString:ident]) t = x;
    if (!t) { HSLog(@"authOne", @"unknown=%@", ident); return; }
    [gStore requestAuthorizationToShareTypes:nil readTypes:[NSSet setWithObject:t] completion:^(BOOL ok, NSError *e) {
        HSLog(@"authOneDone", @"type=%@ success=%d error=%@", ident, ok, errStr(e)); }];
    HSLog(@"authOne", @"type=%@ requested", ident);
    [NSThread sleepForTimeInterval:5];
}

static void phaseStatus(void)
{
    NSMutableDictionary<NSNumber *, NSMutableArray *> *by = [NSMutableDictionary dictionary];
    for (HKSampleType *t in allSampleTypes()) {
        NSNumber *k = @([gStore authorizationStatusForType:t]);
        if (!by[k]) by[k] = [NSMutableArray array];
        [by[k] addObject:t.identifier];
    }
    for (NSNumber *k in [by.allKeys sortedArrayUsingSelector:@selector(compare:)])
        HSLog(@"status", @"value=%@ n=%lu types=%@", k, (unsigned long)by[k].count, [by[k] componentsJoinedByString:@","]);
}

// ---------------------------------------------------------------- auth

static NSSet *parseIds(NSString *reason)
{
    NSMutableSet *s = [NSMutableSet set];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"HK[A-Za-z0-9]+Identifier[A-Za-z0-9]+|HKWorkoutTypeIdentifier|HKWorkoutRouteTypeIdentifier|HKDataTypeIdentifier[A-Za-z0-9]+|HKElectrocardiogramType|HKAudiogramSampleType|HKStateOfMindTypeIdentifier|HKActivitySummaryTypeIdentifier"
                                                                        options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:reason options:0 range:NSMakeRange(0, reason.length)])
        [s addObject:[reason substringWithRange:m.range]];
    return s;
}

static void phaseAuth(NSString *mode)
{
    NSMutableSet *share = [NSMutableSet set], *read = [NSMutableSet set];
    if ([mode isEqualToString:@"small"]) { [share addObjectsFromArray:smallTypes()]; [read addObjectsFromArray:smallTypes()]; }
    else {
        [read addObjectsFromArray:allSampleTypes()];
        [read addObject:[HKObjectType activitySummaryType]];
        if (![mode isEqualToString:@"read"]) { [share addObjectsFromArray:allSampleTypes()]; [share addObject:[HKObjectType activitySummaryType]]; }
    }
    NSMutableSet *noShare = [NSMutableSet set], *noRead = [NSMutableSet set];
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    for (int round = 0; round < 30; round++) {
        NSString *reason = nil; NSString *name = nil;
        @try {
            [gStore requestAuthorizationToShareTypes:share readTypes:read completion:^(BOOL ok, NSError *e) {
                HSLog(@"authDone", @"success=%d error=%@ appState=%@", ok, errStr(e), appState());
                dispatch_semaphore_signal(s);
            }];
        } @catch (NSException *x) { reason = x.reason; name = x.name; }
        if (!reason) {
            HSLog(@"authRequested", @"share=%lu read=%lu round=%d", (unsigned long)share.count, (unsigned long)read.count, round);
            break;
        }
        HSLog(@"authException", @"name=%@ reason=%@", name, reason);
        NSSet *bad = parseIds(reason);
        BOOL isShare = [reason rangeOfString:@"to share"].location != NSNotFound;
        NSMutableSet *target = isShare ? share : read;
        NSUInteger before = target.count;
        for (HKObjectType *t in [target copy]) if ([bad containsObject:t.identifier]) { [target removeObject:t]; [(isShare ? noShare : noRead) addObject:t.identifier]; }
        if (target.count == before) { HSLog(@"authGiveUp", @"%@", @"no identifiers parsed"); return; }
    }
    HSLog(@"authDisallowedShare", @"n=%lu types=%@", (unsigned long)noShare.count, [[noShare.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]);
    HSLog(@"authDisallowedRead", @"n=%lu types=%@", (unsigned long)noRead.count, [[noRead.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]);
    waitSem(s, -1);
}

// ---------------------------------------------------------------- write

static double synthValue(NSString *ident, NSString *unit)
{
    NSDictionary *special = @{ HKQuantityTypeIdentifierOxygenSaturation: @0.97, HKQuantityTypeIdentifierAtrialFibrillationBurden: @0.02,
                               HKQuantityTypeIdentifierAppleWalkingSteadiness: @0.8, HKQuantityTypeIdentifierBodyFatPercentage: @0.2,
                               HKQuantityTypeIdentifierPeripheralPerfusionIndex: @0.05, HKQuantityTypeIdentifierStepCount: @1000,
                               HKQuantityTypeIdentifierBloodPressureDiastolic: @80, HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances: @5,
                               HKQuantityTypeIdentifierAppleSleepingWristTemperature: @35.9, HKQuantityTypeIdentifierBloodAlcoholContent: @0.0,
                               HKQuantityTypeIdentifierRespiratoryRate: @15 };
    if (special[ident]) return [special[ident] doubleValue];
    NSDictionary *byUnit = @{ @"count/min": @72, @"ms": @45, @"%": @0.1, @"count": @3, @"m": @1200, @"kcal": @50, @"degC": @36.6,
                              @"dBASPL": @70, @"min": @10, @"ml/(kg*min)": @42, @"W": @200, @"m/s": @1.3, @"kg": @70, @"cm": @175,
                              @"L": @4, @"L/min": @300, @"mmHg": @120, @"g": @10, @"mg/dL": @100, @"mL": @250, @"IU": @5, @"S": @0.000002,
                              @"count/s": @1.2, @"kcal/(kg*hr)": @3, @"appleEffortScore": @5 };
    return byUnit[unit] ? [byUnit[unit] doubleValue] : 1;
}

static NSDictionary *mark(NSString *tag)
{
    return @{ @"hs.t": @([[NSDate date] timeIntervalSince1970]), @"hs.tag": tag ?: @"", @"hs.side": gSide };
}

static void saveOne(NSString *label, HKObject *(^make)(void))
{
    HKObject *o = nil;
    @try { o = make(); } @catch (NSException *x) {
        HSLog(@"writeMakeException", @"type=%@ name=%@ reason=%@", label, x.name, x.reason);
        return;
    }
    if (!o) { HSLog(@"writeMakeNil", @"type=%@", label); return; }
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    double t0 = [[NSDate date] timeIntervalSince1970];
    @try {
        [gStore saveObject:o withCompletion:^(BOOL ok, NSError *e) {
            HSLog(@"write", @"type=%@ success=%d ms=%.0f error=%@", label, ok, ([[NSDate date] timeIntervalSince1970] - t0) * 1000, errStr(e));
            dispatch_semaphore_signal(s);
        }];
    } @catch (NSException *x) {
        HSLog(@"writeSaveException", @"type=%@ name=%@ reason=%@", label, x.name, x.reason);
        return;
    }
    waitSem(s, 60);
}

static NSDate *todayAt(double hours)
{
    NSDate *mid = [[NSCalendar currentCalendar] startOfDayForDate:[NSDate date]];
    return [mid dateByAddingTimeInterval:hours * 3600];
}

static void phaseWrite(void)
{
    NSDate *a = todayAt(-3), *b = [a dateByAddingTimeInterval:300];   // 21:00 yesterday local, 5 minutes
    for (int i = 0; i < kNTypes; i++) {
        HSType t = kTypes[i];
        HKSampleType *st = typeFor(t);
        if (!st) { HSLog(@"writeNoType", @"type=%@", t.ident); continue; }
        if (t.cat) {
            NSInteger v = [t.ident isEqualToString:HKCategoryTypeIdentifierSleepAnalysis] ? HKCategoryValueSleepAnalysisAsleepCore : 0;
            NSMutableDictionary *md = [mark(@"write") mutableCopy];
            if ([t.ident isEqualToString:HKCategoryTypeIdentifierHighHeartRateEvent] || [t.ident isEqualToString:HKCategoryTypeIdentifierLowHeartRateEvent])
                md[HKMetadataKeyHeartRateEventThreshold] = [HKQuantity quantityWithUnit:[HKUnit unitFromString:@"count/min"] doubleValue:120];
            if ([t.ident isEqualToString:HKCategoryTypeIdentifierLowCardioFitnessEvent]) {
                v = HKCategoryValueLowCardioFitnessEventLowFitness;
                md[HKMetadataKeyVO2MaxValue] = [HKQuantity quantityWithUnit:[HKUnit unitFromString:@"ml/(kg*min)"] doubleValue:20];
                md[HKMetadataKeyLowCardioFitnessEventThreshold] = [HKQuantity quantityWithUnit:[HKUnit unitFromString:@"ml/(kg*min)"] doubleValue:25];
            }
            if ([t.ident isEqualToString:HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent]) {
                v = HKCategoryValueEnvironmentalAudioExposureEventMomentaryLimit;
                md[HKMetadataKeyAudioExposureLevel] = [HKQuantity quantityWithUnit:[HKUnit unitFromString:@"dBASPL"] doubleValue:95];
            }
            if ([t.ident isEqualToString:HKCategoryTypeIdentifierHeadphoneAudioExposureEvent]) v = HKCategoryValueHeadphoneAudioExposureEventSevenDayLimit;
            if ([t.ident isEqualToString:HKCategoryTypeIdentifierAppleWalkingSteadinessEvent]) v = HKCategoryValueAppleWalkingSteadinessEventInitialLow;
            if ([t.ident isEqualToString:HKCategoryTypeIdentifierMenstrualFlow]) md[HKMetadataKeyMenstrualCycleStart] = @YES;
            if ([t.ident isEqualToString:HKCategoryTypeIdentifierSexualActivity]) md[HKMetadataKeySexualActivityProtectionUsed] = @NO;
            __block NSInteger vv = v; NSDate *aa = a, *bb = [t.ident isEqualToString:HKCategoryTypeIdentifierAppleStandHour] ? [a dateByAddingTimeInterval:3600] : [a dateByAddingTimeInterval:300];
            saveOne(t.ident, ^HKObject *{ return [HKCategorySample categorySampleWithType:(HKCategoryType *)st value:vv startDate:aa endDate:bb metadata:md]; });
        } else {
            double v = synthValue(t.ident, t.unit);
            HKUnit *u = [HKUnit unitFromString:t.unit];
            BOOL cumulative = [t.agg hasPrefix:@"Cumulative"];
            NSDate *aa = a, *bb = cumulative ? b : a;
            saveOne(t.ident, ^HKObject *{ return [HKQuantitySample quantitySampleWithType:(HKQuantityType *)st quantity:[HKQuantity quantityWithUnit:u doubleValue:v]
                                                                                 startDate:aa endDate:bb metadata:mark(@"write")]; });
        }
    }
    // Workout, then a route attached to it.
    __block HKWorkout *w = nil;
    saveOne(HKWorkoutTypeIdentifier, ^HKObject *{
        w = [HKWorkout workoutWithActivityType:HKWorkoutActivityTypeWalking startDate:todayAt(-2) endDate:[todayAt(-2) dateByAddingTimeInterval:1200]
                                      duration:1200 totalEnergyBurned:[HKQuantity quantityWithUnit:[HKUnit kilocalorieUnit] doubleValue:80]
                                 totalDistance:[HKQuantity quantityWithUnit:[HKUnit meterUnit] doubleValue:1500] metadata:mark(@"write")];
        return w; });
    if (w) {
        HKWorkoutRouteBuilder *rb = [[HKWorkoutRouteBuilder alloc] initWithHealthStore:gStore device:nil];
        NSMutableArray *locs = [NSMutableArray array];
        for (int k = 0; k < 5; k++)
            [locs addObject:[[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(37.0 + k * 0.0005, -122.0) altitude:10 horizontalAccuracy:5 verticalAccuracy:5
                                                         timestamp:[todayAt(-2) dateByAddingTimeInterval:k * 60]]];
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        [rb insertRouteData:locs completion:^(BOOL ok, NSError *e) {
            HSLog(@"routeInsert", @"success=%d error=%@", ok, errStr(e));
            [rb finishRouteWithWorkout:w metadata:nil completion:^(HKWorkoutRoute *r, NSError *e2) {
                HSLog(@"write", @"type=%@ success=%d error=%@", HKWorkoutRouteTypeIdentifier, r != nil, errStr(e2));
                dispatch_semaphore_signal(s);
            }];
        }];
        waitSem(s, 60);
    }
    // Heartbeat series.
    {
        HKHeartbeatSeriesBuilder *hb = [[HKHeartbeatSeriesBuilder alloc] initWithHealthStore:gStore device:nil startDate:todayAt(-1)];
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        __block int added = 0;
        for (int k = 0; k < 10; k++)
            [hb addHeartbeatWithTimeIntervalSinceSeriesStartDate:k * 0.85 precededByGap:NO completion:^(BOOL ok, NSError *e) { if (ok) added++; }];
        [hb finishSeriesWithCompletion:^(HKHeartbeatSeriesSample *sm, NSError *e) {
            HSLog(@"write", @"type=%@ success=%d beats=%d error=%@", HKDataTypeIdentifierHeartbeatSeries, sm != nil, added, errStr(e));
            dispatch_semaphore_signal(s);
        }];
        waitSem(s, 60);
    }
    // Audiogram.
    saveOne(@"HKAudiogramSampleType", ^HKObject *{
        NSMutableArray *pts = [NSMutableArray array];
        for (NSNumber *f in @[ @500, @1000, @2000, @4000 ]) {
            NSError *e = nil;
            HKAudiogramSensitivityPoint *p = [HKAudiogramSensitivityPoint sensitivityPointWithFrequency:[HKQuantity quantityWithUnit:[HKUnit hertzUnit] doubleValue:f.doubleValue]
                                                                                    leftEarSensitivity:[HKQuantity quantityWithUnit:[HKUnit decibelHearingLevelUnit] doubleValue:15]
                                                                                   rightEarSensitivity:[HKQuantity quantityWithUnit:[HKUnit decibelHearingLevelUnit] doubleValue:20] error:&e];
            if (p) [pts addObject:p];
        }
        return [HKAudiogramSample audiogramSampleWithSensitivityPoints:pts startDate:todayAt(-1) endDate:[todayAt(-1) dateByAddingTimeInterval:600] metadata:nil]; });
    // State of mind.
    saveOne(@"HKStateOfMindTypeIdentifier", ^HKObject *{
        return [HKStateOfMind stateOfMindWithDate:todayAt(-1) kind:HKStateOfMindKindMomentaryEmotion valence:0.4 labels:@[ @(HKStateOfMindLabelCalm) ] associations:@[ @(HKStateOfMindAssociationFitness) ]]; });
    HSLog(@"write", @"type=HKElectrocardiogramType success=0 error=%@", @"no public initializer for HKElectrocardiogram (cannot be constructed by an app)");
    HSLog(@"writeDone", @"%@", @"");
}

// ---------------------------------------------------------------- workout

@interface HSWorkout : NSObject <HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate>
@property (strong) HKWorkoutSession *session;
@property (strong) HKLiveWorkoutBuilder *builder;
@property (strong) NSDate *start;
@end

@implementation HSWorkout
- (void)workoutSession:(HKWorkoutSession *)s didChangeToState:(HKWorkoutSessionState)to fromState:(HKWorkoutSessionState)from date:(NSDate *)date
{
    HSLog(@"sessionState", @"from=%ld to=%ld at=%.3f appState=%@", (long)from, (long)to, date.timeIntervalSince1970, appState());
}
- (void)workoutSession:(HKWorkoutSession *)s didFailWithError:(NSError *)e { HSLog(@"sessionFailed", @"error=%@", errStr(e)); }
- (void)workoutSession:(HKWorkoutSession *)s didGenerateEvent:(HKWorkoutEvent *)ev { HSLog(@"sessionEvent", @"type=%ld", (long)ev.type); }
- (void)workoutBuilderDidCollectEvent:(HKLiveWorkoutBuilder *)b { HSLog(@"builderEvent", @"type=%ld n=%lu", (long)b.workoutEvents.lastObject.type, (unsigned long)b.workoutEvents.count); }
- (void)workoutBuilder:(HKLiveWorkoutBuilder *)b didCollectDataOfTypes:(NSSet<HKSampleType *> *)types
{
    for (HKSampleType *t in types) {
        if (![t isKindOfClass:[HKQuantityType class]]) { HSLog(@"collected", @"type=%@ (not quantity) elapsed=%.1f", t.identifier, b.elapsedTime); continue; }
        HKStatistics *st = [b statisticsForType:(HKQuantityType *)t];
        NSString *us = unitFor(t);
        HKUnit *u = us ? [HKUnit unitFromString:us] : nil;
        HSLog(@"collected", @"type=%@ elapsed=%.1f unit=%@ mostRecent=%@ sum=%@ avg=%@ min=%@ max=%@ statStart=%.3f statEnd=%.3f mrInterval=%@", t.identifier, b.elapsedTime, us,
              st.mostRecentQuantity && u ? @([st.mostRecentQuantity doubleValueForUnit:u]) : @"-",
              st.sumQuantity && u ? @([st.sumQuantity doubleValueForUnit:u]) : @"-",
              st.averageQuantity && u ? @([st.averageQuantity doubleValueForUnit:u]) : @"-",
              st.minimumQuantity && u ? @([st.minimumQuantity doubleValueForUnit:u]) : @"-",
              st.maximumQuantity && u ? @([st.maximumQuantity doubleValueForUnit:u]) : @"-",
              st.startDate.timeIntervalSince1970, st.endDate.timeIntervalSince1970,
              st.mostRecentQuantityDateInterval ? [NSString stringWithFormat:@"%.3f+%.1f", st.mostRecentQuantityDateInterval.startDate.timeIntervalSince1970, st.mostRecentQuantityDateInterval.duration] : @"-");
    }
}
@end

static NSString *describeSample(HKSample *s)
{
    NSString *v = @"";
    if ([s isKindOfClass:[HKQuantitySample class]]) {
        HKQuantitySample *q = (HKQuantitySample *)s; NSString *us = unitFor(q.quantityType);
        v = us ? [NSString stringWithFormat:@"%g %@ count=%ld", [q.quantity doubleValueForUnit:[HKUnit unitFromString:us]], us, (long)q.count] : q.quantity.description;
    } else if ([s isKindOfClass:[HKCategorySample class]]) v = [NSString stringWithFormat:@"cat=%ld", (long)((HKCategorySample *)s).value];
    else if ([s isKindOfClass:[HKElectrocardiogram class]]) {
        HKElectrocardiogram *e = (HKElectrocardiogram *)s;
        v = [NSString stringWithFormat:@"ecg class=%ld symptoms=%ld avgHR=%@ n=%ld freq=%@", (long)e.classification, (long)e.symptomsStatus, e.averageHeartRate, (long)e.numberOfVoltageMeasurements, e.samplingFrequency];
    }
    else if ([s isKindOfClass:[HKWorkout class]]) v = [NSString stringWithFormat:@"workout act=%lu dur=%.1f", (unsigned long)((HKWorkout *)s).workoutActivityType, ((HKWorkout *)s).duration];
    HKSourceRevision *r = s.sourceRevision;
    return [NSString stringWithFormat:@"type=%@ value=%@ start=%.3f end=%.3f dur=%.2f src=%@ srcName=\"%@\" product=%@ dev=\"%@\" devModel=%@ meta=%@ uuid=%@", s.sampleType.identifier, v,
            s.startDate.timeIntervalSince1970, s.endDate.timeIntervalSince1970, [s.endDate timeIntervalSinceDate:s.startDate],
            r.source.bundleIdentifier, r.source.name, r.productType, s.device.name, s.device.model,
            [[s.metadata.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"|"], s.UUID.UUIDString];
}

static HKAnchoredObjectQuery *liveAnchored(HKSampleType *t, NSPredicate *p, NSString *ev)
{
    void (^h)(HKAnchoredObjectQuery *, NSArray<__kindof HKSample *> *, NSArray<HKDeletedObject *> *, HKQueryAnchor *, NSError *) =
        ^(HKAnchoredObjectQuery *q, NSArray *add, NSArray *del, HKQueryAnchor *an, NSError *e) {
            double now = [[NSDate date] timeIntervalSince1970];
            if (e) HSLog(ev, @"type=%@ error=%@", t.identifier, errStr(e));
            HSLog([ev stringByAppendingString:@"Batch"], @"type=%@ added=%lu deleted=%lu appState=%@", t.identifier, (unsigned long)add.count, (unsigned long)del.count, appState());
            for (HKSample *s in add) {
                NSNumber *wt = s.metadata[@"hs.t"];
                HSLog(ev, @"%@ lagMs=%@ tag=%@", describeSample(s), wt ? @((long)((now - wt.doubleValue) * 1000)) : @"-", s.metadata[@"hs.tag"] ?: @"-");
            }
        };
    HKAnchoredObjectQuery *q = [[HKAnchoredObjectQuery alloc] initWithType:t predicate:p anchor:nil limit:HKObjectQueryNoLimit resultsHandler:h];
    q.updateHandler = h;
    return q;
}

static void phaseWorkout(double secs, NSString *kind)
{
    HKWorkoutConfiguration *c = [HKWorkoutConfiguration new];
    c.activityType = [kind isEqualToString:@"walk"] ? HKWorkoutActivityTypeWalking : [kind isEqualToString:@"cycle"] ? HKWorkoutActivityTypeCycling
                   : [kind isEqualToString:@"hiit"] ? HKWorkoutActivityTypeHighIntensityIntervalTraining : HKWorkoutActivityTypeRunning;
    c.locationType = HKWorkoutSessionLocationTypeOutdoor;
    NSError *e = nil;
    HSWorkout *w = [HSWorkout new];
    w.session = [[HKWorkoutSession alloc] initWithHealthStore:gStore configuration:c error:&e];
    if (!w.session) { HSLog(@"sessionInitFailed", @"error=%@", errStr(e)); return; }
    w.session.delegate = w;
    w.builder = [w.session associatedWorkoutBuilder];
    w.builder.delegate = w;
    HKLiveWorkoutDataSource *ds = [[HKLiveWorkoutDataSource alloc] initWithHealthStore:gStore workoutConfiguration:c];
    w.builder.dataSource = ds;
    HSLog(@"dataSource", @"activity=%lu typesToCollect=%@", (unsigned long)c.activityType, ids(ds.typesToCollect));
    NSDate *start = [NSDate date];
    w.start = start;
    NSPredicate *p = [HKQuery predicateForSamplesWithStartDate:[start dateByAddingTimeInterval:-5] endDate:nil options:HKQueryOptionNone];
    NSMutableArray *qs = [NSMutableArray array];
    NSMutableSet *watchTypes = [ds.typesToCollect mutableCopy];
    [watchTypes addObjectsFromArray:@[ [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate],
                                       [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount],
                                       [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierBasalEnergyBurned],
                                       [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierRunningSpeed],
                                       [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierRunningPower],
                                       [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierOxygenSaturation],
                                       [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierRespiratoryRate],
                                       [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierAppleExerciseTime],
                                       [HKObjectType workoutType] ]];
    for (HKSampleType *t in watchTypes) { HKAnchoredObjectQuery *q = liveAnchored(t, p, @"rawSample"); [qs addObject:q]; [gStore executeQuery:q]; }
    [w.session startActivityWithDate:start];
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [w.builder beginCollectionWithStartDate:start completion:^(BOOL ok, NSError *e2) {
        HSLog(@"beginCollection", @"success=%d error=%@", ok, errStr(e2)); dispatch_semaphore_signal(s); }];
    waitSem(s, 60);
    for (double t = 0; t < secs; t += 10) {
        [NSThread sleepForTimeInterval:10];
        HSLog(@"tick", @"elapsed=%.1f state=%ld", w.builder.elapsedTime, (long)w.session.state);
    }
    [w.session end];
    [w.builder endCollectionWithEndDate:[NSDate date] completion:^(BOOL ok, NSError *e2) {
        HSLog(@"endCollection", @"success=%d error=%@", ok, errStr(e2));
        [w.builder finishWorkoutWithCompletion:^(HKWorkout *wk, NSError *e3) {
            HSLog(@"finished", @"workout=%@ error=%@", wk ? describeSample(wk) : @"nil", errStr(e3));
            for (HKQuantityType *qt in wk.allStatistics) {
                HKStatistics *st = wk.allStatistics[qt]; NSString *us = unitFor(qt); HKUnit *u = us ? [HKUnit unitFromString:us] : nil;
                HSLog(@"workoutStat", @"type=%@ sum=%@ avg=%@ min=%@ max=%@", qt.identifier,
                      st.sumQuantity && u ? @([st.sumQuantity doubleValueForUnit:u]) : @"-", st.averageQuantity && u ? @([st.averageQuantity doubleValueForUnit:u]) : @"-",
                      st.minimumQuantity && u ? @([st.minimumQuantity doubleValueForUnit:u]) : @"-", st.maximumQuantity && u ? @([st.maximumQuantity doubleValueForUnit:u]) : @"-");
            }
            dispatch_semaphore_signal(s);
        }];
    }];
    waitSem(s, 120);
    [NSThread sleepForTimeInterval:5];
    for (HKQuery *q in qs) [gStore stopQuery:q];
}

// ---------------------------------------------------------------- observe, burst

static void phaseObserve(double secs, BOOL bg)
{
    NSMutableArray *qs = [NSMutableArray array];
    for (HKSampleType *t in smallTypes()) {
        if (bg) {
            dispatch_semaphore_t s = dispatch_semaphore_create(0);
            [gStore enableBackgroundDeliveryForType:t frequency:HKUpdateFrequencyImmediate withCompletion:^(BOOL ok, NSError *e) {
                HSLog(@"bgDelivery", @"type=%@ success=%d error=%@", t.identifier, ok, errStr(e)); dispatch_semaphore_signal(s); }];
            waitSem(s, 30);
        }
        HKObserverQuery *oq = [[HKObserverQuery alloc] initWithSampleType:t predicate:nil updateHandler:^(HKObserverQuery *q, HKObserverQueryCompletionHandler done, NSError *e) {
            HSLog(@"observer", @"type=%@ error=%@ appState=%@", t.identifier, errStr(e), appState());
            if (done) done();
        }];
        [qs addObject:oq]; [gStore executeQuery:oq];
        NSPredicate *p = [HKQuery predicateForSamplesWithStartDate:[NSDate dateWithTimeIntervalSinceNow:-6 * 3600] endDate:nil options:HKQueryOptionNone];
        HKAnchoredObjectQuery *aq = liveAnchored(t, p, @"anchored");
        [qs addObject:aq]; [gStore executeQuery:aq];
    }
    for (double t = 0; t < secs; t += 15) { [NSThread sleepForTimeInterval:15]; HSLog(@"tick", @"appState=%@", appState()); }
    for (HKQuery *q in qs) [gStore stopQuery:q];
}

static void phaseBurst(int n, double every, NSString *tag)
{
    for (int i = 0; i < n; i++) {
        NSDate *now = [NSDate date];
        NSString *tg = [NSString stringWithFormat:@"%@-%d", tag, i];
        saveOne(@"burst.steps", ^HKObject *{ return [HKQuantitySample quantitySampleWithType:[HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount]
            quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:100 + i] startDate:[now dateByAddingTimeInterval:-60] endDate:now metadata:mark(tg)]; });
        saveOne(@"burst.hr", ^HKObject *{ return [HKQuantitySample quantitySampleWithType:[HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRate]
            quantity:[HKQuantity quantityWithUnit:[HKUnit unitFromString:@"count/min"] doubleValue:70 + i] startDate:now endDate:now metadata:mark(tg)]; });
        saveOne(@"burst.spo2", ^HKObject *{ return [HKQuantitySample quantitySampleWithType:[HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierOxygenSaturation]
            quantity:[HKQuantity quantityWithUnit:[HKUnit percentUnit] doubleValue:0.95] startDate:now endDate:now metadata:mark(tg)]; });
        saveOne(@"burst.sleep", ^HKObject *{ return [HKCategorySample categorySampleWithType:[HKObjectType categoryTypeForIdentifier:HKCategoryTypeIdentifierSleepAnalysis]
            value:HKCategoryValueSleepAnalysisAsleepREM startDate:[now dateByAddingTimeInterval:-600] endDate:now metadata:mark(tg)]; });
        if (i + 1 < n) [NSThread sleepForTimeInterval:every];
    }
}

// ---------------------------------------------------------------- count, dump

static void phaseCount(void)
{
    for (HKSampleType *t in allSampleTypes()) {
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:t predicate:nil limit:HKObjectQueryNoLimit sortDescriptors:nil resultsHandler:^(HKSampleQuery *qq, NSArray *res, NSError *e) {
            if (res.count || e) {
                NSCountedSet *src = [NSCountedSet set];
                for (HKSample *x in res) [src addObject:[NSString stringWithFormat:@"%@@%@", x.sourceRevision.source.bundleIdentifier, x.device.model ?: @"-"]];
                NSMutableArray *parts = [NSMutableArray array];
                for (NSString *k in src) [parts addObject:[NSString stringWithFormat:@"%@x%lu", k, (unsigned long)[src countForObject:k]]];
                HSLog(@"count", @"type=%@ n=%lu sources=%@ error=%@", t.identifier, (unsigned long)res.count, [parts componentsJoinedByString:@","], e ? errStr(e) : @"nil");
            }
            dispatch_semaphore_signal(s);
        }];
        [gStore executeQuery:q];
        waitSem(s, 60);
    }
    HSLog(@"countDone", @"%@", @"");
}

static HKSampleType *typeNamed(NSString *ident)
{
    for (HKSampleType *t in allSampleTypes()) if ([t.identifier isEqualToString:ident]) return t;
    return nil;
}

static void phaseDump(NSString *ident, NSUInteger n)
{
    HKSampleType *t = typeNamed(ident);
    if (!t) { HSLog(@"dump", @"unknown=%@", ident); return; }
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:t predicate:nil limit:n
                                                 sortDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:HKSampleSortIdentifierEndDate ascending:NO] ]
                                                  resultsHandler:^(HKSampleQuery *qq, NSArray *res, NSError *e) {
        HSLog(@"dumpHead", @"type=%@ n=%lu error=%@", ident, (unsigned long)res.count, errStr(e));
        for (HKSample *x in res) HSLog(@"dump", @"%@", describeSample(x));
        dispatch_semaphore_signal(s);
    }];
    [gStore executeQuery:q];
    waitSem(s, 60);
}

// ---------------------------------------------------------------- entry

void HSStart(NSArray<NSString *> *args, NSString *side)
{
    gSide = side;
    initTypes();
    gStarted = [[NSDate date] timeIntervalSince1970];
    NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *path = [docs.path stringByAppendingPathComponent:@"hs.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    gLog = [NSFileHandle fileHandleForWritingAtPath:path];
    [gLog seekToEndOfFile];
    gStore = [HKHealthStore new];
    NSArray *a = args.count > 1 ? [args subarrayWithRange:NSMakeRange(1, args.count - 1)] : @[];
    HSLog(@"launch", @"args=%@ bundle=%@ types=%d", [a componentsJoinedByString:@","], [NSBundle mainBundle].bundleIdentifier, kNTypes);
    [[[NSThread alloc] initWithBlock:^{
        __block NSUInteger i = 0;
        while (i < a.count) {
            NSString *p = a[i++];
            NSString *(^next)(NSString *) = ^NSString *(NSString *def) {
                if (i < a.count && ![@[ @"info", @"status", @"reqstat", @"authone", @"auth", @"write", @"workout", @"observe", @"burst", @"count", @"dump", @"wait" ] containsObject:a[i]]) return a[i++];
                return def; };
            HSLog(@"phase", @"name=%@", p);
            if ([p isEqualToString:@"info"]) phaseInfo();
            else if ([p isEqualToString:@"status"]) phaseStatus();
            else if ([p isEqualToString:@"reqstat"]) phaseReqStat();
            else if ([p isEqualToString:@"authone"]) phaseAuthOne(next(@""));
            else if ([p isEqualToString:@"auth"]) phaseAuth(next(@"all"));
            else if ([p isEqualToString:@"write"]) phaseWrite();
            else if ([p isEqualToString:@"workout"]) { double s = next(@"60").doubleValue; phaseWorkout(s, next(@"run")); }
            else if ([p isEqualToString:@"observe"]) { double s = next(@"120").doubleValue; phaseObserve(s, [next(@"") isEqualToString:@"bg"]); }
            else if ([p isEqualToString:@"burst"]) { int n = next(@"3").intValue; double ev = next(@"5").doubleValue; phaseBurst(n, ev, next(@"b")); }
            else if ([p isEqualToString:@"count"]) phaseCount();
            else if ([p isEqualToString:@"dump"]) { NSString *id_ = next(HKQuantityTypeIdentifierHeartRate); phaseDump(id_, next(@"30").integerValue); }
            else if ([p isEqualToString:@"wait"]) [NSThread sleepForTimeInterval:next(@"10").doubleValue];
        }
        HSLog(@"DONE", @"%@", @"");
    }] start];
}
