// HealthProbe: black-box probe of HealthKit's public API behaviour on a simulator.
// Our own code for Ycode's clean-room research. It calls only public
// HealthKit/UIKit/CoreLocation API, uses made-up sample values only, and
// prints one "HKPROBE ..." line per observation to stderr.
//
// Launch arguments:
//   -phase basic     no authorization needed: availability, type model,
//                    units, unauthorized behaviour, invalid requests
//   -phase auth      request authorization for the probe's type set (sheet)
//   -phase authb     request a smaller set (used by the second bundle)
//   -phase status    authorization status / request status only
//   -phase data      save, query, statistics, anchors, observer, delete
//   -phase count     count this source's samples (persistence check)
//   -phase cross     cross-source statistics (run from the second bundle)
//   -phase session   HKWorkoutSession / live builder on iPhone
//   -phase clinical  health-records availability and request
//   -phase wipe      delete everything this source wrote
#import <UIKit/UIKit.h>
#import <HealthKit/HealthKit.h>
#import <CoreLocation/CoreLocation.h>
#import <QuartzCore/QuartzCore.h>

static CFTimeInterval gStart;
static HKHealthStore *gStore;
static NSCalendar *gUTC;
static NSDate *gD0; // 2026-10-01T00:00:00Z, the reference day

static void P(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void P(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "HKPROBE t=%.3f %s\n", CACurrentMediaTime() - gStart, s.UTF8String);
    fflush(stderr);
}

static NSString *E(NSError *e) {
    if (!e) return @"nil";
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in e.userInfo) [keys addObject:[k description]];
    [keys sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"{domain=%@ code=%ld keys=[%@] desc=\"%@\"}", e.domain, (long)e.code,
            [keys componentsJoinedByString:@","], e.localizedDescription];
}

static NSString *Thr(void) {
    const char *l = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    return [NSString stringWithFormat:@"main=%d q=%s", [NSThread isMainThread], l ? l : "?"];
}

// Run an asynchronous step and wait (we run on a background serial queue).
static void Wait(NSString *what, double secs, void (^body)(dispatch_block_t done)) {
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    body(^{ dispatch_semaphore_signal(s); });
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC))))
        P(@"%@ TIMEOUT after %.0fs (no callback)", what, secs);
}

static NSDate *At(int day, int h, int m) {
    return [gD0 dateByAddingTimeInterval:day * 86400.0 + h * 3600.0 + m * 60.0];
}
static NSString *D(NSDate *d) {
    if (!d) return @"nil";
    static NSISO8601DateFormatter *f;
    if (!f) { f = [NSISO8601DateFormatter new]; f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; }
    return [f stringFromDate:d];
}

static HKQuantityType *QT(HKQuantityTypeIdentifier i) { return [HKObjectType quantityTypeForIdentifier:i]; }
static HKCategoryType *CT(HKCategoryTypeIdentifier i) { return [HKObjectType categoryTypeForIdentifier:i]; }

static NSString *Q(HKQuantity *q, HKUnit *u) {
    if (!q) return @"nil";
    return [NSString stringWithFormat:@"%.6g %@", [q doubleValueForUnit:u], u.unitString];
}

#pragma mark - Identifier table

typedef struct { const char *kind; const char *sym; __unsafe_unretained NSString *value; } IdEntry;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
static IdEntry *Ids(size_t *n) {
    static IdEntry *t; static size_t c;
    if (!t) {
#define X(k, s) { #k, #s, nil },
        static IdEntry tmp[] = {
#include "ids.inc"
        };
#undef X
        c = sizeof(tmp) / sizeof(tmp[0]);
        size_t i = 0;
#define X(k, s) tmp[i++].value = (NSString *)s;
#include "ids.inc"
#undef X
        t = tmp;
    }
    *n = c;
    return t;
}
#pragma clang diagnostic pop

#pragma mark - Unit helpers

static NSArray<HKUnit *> *BaseUnits(void) {
    static NSArray *a;
    if (!a) {
        NSMutableArray *m = [NSMutableArray array];
        for (NSString *s in @[@"g", @"m", @"s", @"J", @"K", @"count", @"%", @"Pa", @"L", @"S", @"V", @"W",
                              @"dBASPL", @"dBHL", @"IU", @"Hz", @"lx", @"rad", @"D", @"appleEffortScore",
                              @"count/s", @"m/s", @"g/L", @"L/s", @"J/s", @"m^2", @"mL/(kg*min)", @"kcal/(kg*hr)",
                              @"J/kg", @"s/m", @"count/m", @"m/s^2", @"W/kg"]) {
            @try { HKUnit *u = [HKUnit unitFromString:s]; if (u) [m addObject:u]; }
            @catch (NSException *ex) { P(@"base-unit %@ EXCEPTION %@", s, ex.reason); }
        }
        a = m;
    }
    return a;
}

static NSString *Dimension(HKQuantityType *t) {
    NSMutableArray *m = [NSMutableArray array];
    for (HKUnit *u in BaseUnits()) if ([t isCompatibleWithUnit:u]) [m addObject:u.unitString];
    return [m componentsJoinedByString:@"|"];
}

#pragma mark - Type sets

static NSSet *ShareSet(void) {
    return [NSSet setWithArray:@[
        QT(HKQuantityTypeIdentifierStepCount), QT(HKQuantityTypeIdentifierHeartRate),
        QT(HKQuantityTypeIdentifierBodyMass), QT(HKQuantityTypeIdentifierHeight),
        QT(HKQuantityTypeIdentifierActiveEnergyBurned), QT(HKQuantityTypeIdentifierDistanceWalkingRunning),
        QT(HKQuantityTypeIdentifierBloodPressureSystolic), QT(HKQuantityTypeIdentifierBloodPressureDiastolic),
        QT(HKQuantityTypeIdentifierBodyTemperature), QT(HKQuantityTypeIdentifierDietaryEnergyConsumed),
        CT(HKCategoryTypeIdentifierSleepAnalysis), CT(HKCategoryTypeIdentifierMindfulSession),
        [HKObjectType workoutType], [HKSeriesType workoutRouteType]]];
}
static NSSet *ReadSet(void) {
    NSMutableSet *s = [ShareSet() mutableCopy];
    [s addObjectsFromArray:@[
        [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierDateOfBirth],
        [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierBiologicalSex],
        [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierBloodType],
        [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierFitzpatrickSkinType],
        [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierWheelchairUse],
        [HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierActivityMoveMode],
        [HKObjectType activitySummaryType], QT(HKQuantityTypeIdentifierRestingHeartRate)]];
    return s;
}

static void PrintStatus(NSString *tag) {
    NSMutableArray *parts = [NSMutableArray array];
    NSArray *all = [[ReadSet() allObjects] sortedArrayUsingComparator:^NSComparisonResult(HKObjectType *a, HKObjectType *b) {
        return [a.identifier compare:b.identifier]; }];
    for (HKObjectType *t in all) {
        HKAuthorizationStatus st = [gStore authorizationStatusForType:t];
        [parts addObject:[NSString stringWithFormat:@"%@=%ld", t.identifier, (long)st]];
    }
    P(@"[%@] authorizationStatus %@", tag, [parts componentsJoinedByString:@" "]);
    Wait(@"getRequestStatus", 15, ^(dispatch_block_t done) {
        [gStore getRequestStatusForAuthorizationToShareTypes:ShareSet() readTypes:ReadSet()
                                                  completion:^(HKAuthorizationRequestStatus s, NSError *e) {
            P(@"[%@] requestStatus=%ld err=%@ %@", tag, (long)s, E(e), Thr()); done(); }];
    });
}

#pragma mark - Phase: basic

static void PhaseBasic(void) {
    P(@"isHealthDataAvailable=%d", [HKHealthStore isHealthDataAvailable]);
    P(@"supportsHealthRecords=%d", [gStore supportsHealthRecords]);
    P(@"earliestPermittedSampleDate=%@", D([gStore earliestPermittedSampleDate]));
    HKDevice *ld = [HKDevice localDevice];
    P(@"localDevice name=%@ manufacturer=%@ model=%@ hw=%@ fw=%@ sw=%@ localId=%@ udi=%@", ld.name, ld.manufacturer,
      ld.model, ld.hardwareVersion, ld.firmwareVersion, ld.softwareVersion, ld.localIdentifier, ld.UDIDeviceIdentifier);
    HKSource *src = nil;
    @try { src = [HKSource defaultSource]; P(@"defaultSource name=%@ bundle=%@", src.name, src.bundleIdentifier); }
    @catch (NSException *ex) { P(@"defaultSource EXCEPTION %@: %@", ex.name, ex.reason); }

    // Every public identifier constant: its string value, and the object type it yields.
    size_t n; IdEntry *ids = Ids(&n);
    for (size_t i = 0; i < n; i++) {
        NSString *k = @(ids[i].kind), *v = ids[i].value;
        HKObjectType *t = nil;
        @try {
            if ([k isEqualToString:@"HKQuantityTypeIdentifier"]) t = [HKObjectType quantityTypeForIdentifier:v];
            else if ([k isEqualToString:@"HKCategoryTypeIdentifier"]) t = [HKObjectType categoryTypeForIdentifier:v];
            else if ([k isEqualToString:@"HKCharacteristicTypeIdentifier"]) t = [HKObjectType characteristicTypeForIdentifier:v];
            else if ([k isEqualToString:@"HKCorrelationTypeIdentifier"]) t = [HKObjectType correlationTypeForIdentifier:v];
            else if ([k isEqualToString:@"HKDocumentTypeIdentifier"]) t = [HKObjectType documentTypeForIdentifier:v];
            else if ([k isEqualToString:@"HKClinicalTypeIdentifier"]) t = [HKObjectType clinicalTypeForIdentifier:v];
            else if ([k isEqualToString:@"HKScoredAssessmentTypeIdentifier"]) t = [HKObjectType scoredAssessmentTypeForIdentifier:v];
        } @catch (NSException *ex) { P(@"id %s EXCEPTION %@", ids[i].sym, ex.reason); }
        if (![k isEqualToString:@"NSString"] && ![k hasPrefix:@"HKMedication"] && ![k hasPrefix:@"HKFHIR"] &&
            ![k hasPrefix:@"HKVerifiable"] && ![k hasPrefix:@"HKHealthConcept"]) {
            NSMutableString *x = [NSMutableString string];
            if ([t isKindOfClass:[HKSampleType class]]) {
                HKSampleType *st = (HKSampleType *)t;
                [x appendFormat:@" maxDur=%d", st.isMaximumDurationRestricted];
                if (st.isMaximumDurationRestricted) [x appendFormat:@":%.0f", st.maximumAllowedDuration];
                [x appendFormat:@" minDur=%d", st.isMinimumDurationRestricted];
                if (st.isMinimumDurationRestricted) [x appendFormat:@":%.0f", st.minimumAllowedDuration];
                static int once; if (!once++) {
                    @try { (void)st.maximumAllowedDuration; P(@"maximumAllowedDuration on unrestricted type: no exception"); }
                    @catch (NSException *ex) { P(@"maximumAllowedDuration on unrestricted type EXCEPTION %@: %@", ex.name, ex.reason); }
                }
                if (@available(iOS 15.0, *)) [x appendFormat:@" recal=%d", st.allowsRecalibrationForEstimates];
            }
            if ([t isKindOfClass:[HKQuantityType class]]) {
                HKQuantityType *qt = (HKQuantityType *)t;
                [x appendFormat:@" agg=%ld units=%@", (long)qt.aggregationStyle, Dimension(qt)];
            }
            if (t) [x appendFormat:@" perObject=%d", t.requiresPerObjectAuthorization];
            P(@"id %s kind=%@ value=%@ class=%@%@", ids[i].sym, k, v, t ? NSStringFromClass([t class]) : @"nil", x);
        } else {
            P(@"id %s kind=%@ value=%@", ids[i].sym, k, v);
        }
    }
    // Series and singleton types.
    for (NSString *s in @[HKWorkoutRouteTypeIdentifier, HKDataTypeIdentifierHeartbeatSeries, @"NotAType"]) {
        @try { HKSeriesType *t = [HKObjectType seriesTypeForIdentifier:s];
            P(@"seriesType %@ -> %@ %@", s, NSStringFromClass([t class]), t.identifier); }
        @catch (NSException *ex) { P(@"seriesType %@ EXCEPTION %@: %@", s, ex.name, ex.reason); }
    }
    NSArray *singles = @[[HKObjectType workoutType], [HKObjectType activitySummaryType], [HKObjectType audiogramSampleType],
                         [HKObjectType electrocardiogramType], [HKObjectType visionPrescriptionType],
                         [HKObjectType stateOfMindType], [HKObjectType medicationDoseEventType],
                         [HKObjectType userAnnotatedMedicationType]];
    for (HKObjectType *t in singles)
        P(@"singleton %@ id=%@ perObject=%d", NSStringFromClass([t class]), t.identifier, t.requiresPerObjectAuthorization);
    @try { P(@"quantityType(bogus)=%@", [HKObjectType quantityTypeForIdentifier:@"HKQuantityTypeIdentifierBogus"]); }
    @catch (NSException *ex) { P(@"quantityType(bogus) EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { P(@"categoryType(stepCount id)=%@", [HKObjectType categoryTypeForIdentifier:HKQuantityTypeIdentifierStepCount]); }
    @catch (NSException *ex) { P(@"categoryType(stepCount id) EXCEPTION %@: %@", ex.name, ex.reason); }
    HKQuantityType *a1 = QT(HKQuantityTypeIdentifierStepCount), *a2 = QT(HKQuantityTypeIdentifierStepCount);
    P(@"type identity same=%d equal=%d hashEq=%d desc=%@", a1 == a2, [a1 isEqual:a2], a1.hash == a2.hash, a1.description);

    // Unit string grammar.
    NSArray *unitStrings = @[@"count", @"count/min", @"count/s", @"kg", @"g", @"mg", @"mcg", @"ug", @"ng", @"pg", @"dag", @"hg",
        @"lb", @"oz", @"st", @"m", @"km", @"cm", @"mm", @"um", @"nm", @"mi", @"ft", @"in", @"yd", @"L", @"mL", @"dL",
        @"fl_oz_us", @"fl_oz_imp", @"pt_us", @"pt_imp", @"cup_us", @"cup_imp", @"s", @"ms", @"min", @"hr", @"d",
        @"J", @"kJ", @"cal", @"kcal", @"Cal", @"degC", @"degF", @"K", @"%", @"Pa", @"kPa", @"mmHg", @"cmAq", @"atm",
        @"inHg", @"dBASPL", @"dBHL", @"S", @"mcS", @"uS", @"V", @"mV", @"uV", @"W", @"kW", @"Hz", @"lx", @"klx", @"rad",
        @"deg", @"diopter", @"D", @"prismDiopter", @"pD", @"dpt", @"IU", @"appleEffortScore", @"mg/dL", @"mmol<180.15588000005408>/L",
        @"mol<180.1558800000541>", @"kcal/hr", @"kg*m^2", @"m/s^2", @"m^2", @"m^-1", @"1/min", @"count/min*kg",
        @"mL/(kg*min)", @"(kg*m)/s^2", @"kg^2", @"kcal/(kg*hr)", @"s/m", @"g/dL", @"m/s", @"km/hr", @"mi/hr",
        @"", @"foo", @"kg/", @"m^", @"mmol", @"KG", @"Kg", @"kilogram", @"count/", @" kg", @"kg ", @"Mg", @"Gg", @"Tm",
        @"fs", @"cs", @"ds", @"das", @"hs", @"ks", @"Ms", @"Gs", @"Ts", @"Ps", @"ps", @"fJ", @"aJ"];
    for (NSString *s in unitStrings) {
        @try {
            HKUnit *u = [HKUnit unitFromString:s];
            NSMutableString *conv = [NSMutableString string];
            for (HKUnit *b in BaseUnits()) {
                HKQuantity *q = [HKQuantity quantityWithUnit:u doubleValue:1.0];
                if ([q isCompatibleWithUnit:b]) { [conv appendFormat:@" 1=>%.12g %@", [q doubleValueForUnit:b], b.unitString]; break; }
            }
            P(@"unit \"%@\" -> unitString=\"%@\" desc=\"%@\" null=%d%@", s, u.unitString, u.description, u.isNull, conv);
        } @catch (NSException *ex) { P(@"unit \"%@\" EXCEPTION %@: %@", s, ex.name, ex.reason); }
    }
    // Unit algebra.
    @try {
        HKUnit *c = [HKUnit countUnit], *mn = [HKUnit minuteUnit], *kg = [HKUnit gramUnitWithMetricPrefix:HKMetricPrefixKilo];
        HKUnit *m = [HKUnit meterUnit], *s = [HKUnit secondUnit];
        P(@"algebra count/min=%@", [c unitDividedByUnit:mn].unitString);
        P(@"algebra kg*m=%@", [kg unitMultipliedByUnit:m].unitString);
        P(@"algebra (kg*m)/s^2=%@", [[kg unitMultipliedByUnit:m] unitDividedByUnit:[s unitRaisedToPower:2]].unitString);
        P(@"algebra m^3=%@ m^0=%@ m^-2=%@", [m unitRaisedToPower:3].unitString, [m unitRaisedToPower:0].unitString,
          [m unitRaisedToPower:-2].unitString);
        P(@"algebra reciprocal(min)=%@ reciprocal(count/min)=%@", [mn reciprocalUnit].unitString,
          [[c unitDividedByUnit:mn] reciprocalUnit].unitString);
        P(@"algebra m/m=%@ null=%d", [m unitDividedByUnit:m].unitString, [m unitDividedByUnit:m].isNull);
        P(@"algebra count*count=%@ count/count=%@", [c unitMultipliedByUnit:c].unitString, [c unitDividedByUnit:c].unitString);
        P(@"algebra mmol(glucose)=%@", [HKUnit moleUnitWithMetricPrefix:HKMetricPrefixMilli molarMass:HKUnitMolarMassBloodGlucose].unitString);
        P(@"algebra unitString equality kg==kg: %d, same object: %d", [[HKUnit unitFromString:@"kg"] isEqual:kg],
          [HKUnit unitFromString:@"kg"] == kg);
        P(@"algebra kcal==Cal: %d, kcal unitString=%@ largeCal=%@ smallCal=%@ calorieUnit=%@",
          [[HKUnit kilocalorieUnit] isEqual:[HKUnit largeCalorieUnit]], [HKUnit kilocalorieUnit].unitString,
          [HKUnit largeCalorieUnit].unitString, [HKUnit smallCalorieUnit].unitString, [HKUnit calorieUnit].unitString);
    } @catch (NSException *ex) { P(@"algebra EXCEPTION %@", ex.reason); }
    // Conversions with golden values.
    struct { double v; const char *from, *to; } cv[] = {
        {100, "degC", "degF"}, {0, "degC", "K"}, {98.6, "degF", "degC"}, {1, "mi", "m"}, {1, "lb", "kg"}, {1, "st", "lb"},
        {1, "kcal", "kJ"}, {1, "Cal", "cal"}, {1, "atm", "mmHg"}, {1, "inHg", "mmHg"}, {1, "cmAq", "Pa"}, {1, "fl_oz_us", "mL"},
        {1, "fl_oz_imp", "mL"}, {1, "cup_us", "mL"}, {1, "cup_imp", "mL"}, {1, "pt_us", "mL"}, {1, "pt_imp", "mL"},
        {1, "d", "s"}, {100, "mg/dL", "mmol<180.15588000005408>/L"}, {1, "deg", "rad"}, {1, "count/min", "count/s"},
        {60, "count/min", "Hz"}, {10, "km/hr", "m/s"}, {1, "oz", "g"}, {1, "yd", "m"}, {50, "%", "count"}, {1, "dBASPL", "Pa"}};
    for (size_t i = 0; i < sizeof(cv) / sizeof(cv[0]); i++) {
        @try {
            HKUnit *f = [HKUnit unitFromString:@(cv[i].from)], *t = [HKUnit unitFromString:@(cv[i].to)];
            HKQuantity *q = [HKQuantity quantityWithUnit:f doubleValue:cv[i].v];
            if ([q isCompatibleWithUnit:t]) P(@"convert %g %s = %.15g %s", cv[i].v, cv[i].from, [q doubleValueForUnit:t], cv[i].to);
            else P(@"convert %g %s -> %s INCOMPATIBLE", cv[i].v, cv[i].from, cv[i].to);
        } @catch (NSException *ex) { P(@"convert %s->%s EXCEPTION %@", cv[i].from, cv[i].to, ex.reason); }
    }
    @try { HKQuantity *q = [HKQuantity quantityWithUnit:[HKUnit gramUnit] doubleValue:1];
        P(@"convert g->m: %g", [q doubleValueForUnit:[HKUnit meterUnit]]); }
    @catch (NSException *ex) { P(@"convert g->m EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { HKQuantity *a = [HKQuantity quantityWithUnit:[HKUnit gramUnit] doubleValue:1000];
        HKQuantity *b = [HKQuantity quantityWithUnit:[HKUnit gramUnitWithMetricPrefix:HKMetricPrefixKilo] doubleValue:1];
        P(@"quantity compare 1000g vs 1kg = %ld equal=%d desc=%@ / %@", (long)[a compare:b], [a isEqual:b], a.description, b.description);
        P(@"quantity compare g vs m:"); P(@"  -> %ld", (long)[a compare:[HKQuantity quantityWithUnit:[HKUnit meterUnit] doubleValue:1]]); }
    @catch (NSException *ex) { P(@"quantity compare EXCEPTION %@: %@", ex.name, ex.reason); }

    // Characteristic and other values without authorization.
    NSError *e = nil;
    NSDateComponents *dob = [gStore dateOfBirthComponentsWithError:&e];
    P(@"unauth dateOfBirth=%@ err=%@", dob, E(e)); e = nil;
    HKBiologicalSexObject *sex = [gStore biologicalSexWithError:&e];
    P(@"unauth biologicalSex=%ld err=%@", (long)sex.biologicalSex, E(e)); e = nil;
    HKBloodTypeObject *bt = [gStore bloodTypeWithError:&e];
    P(@"unauth bloodType=%ld err=%@", (long)bt.bloodType, E(e));

    PrintStatus(@"basic");

    // Unauthorized save / query / delete.
    HKQuantitySample *smp = [HKQuantitySample quantitySampleWithType:QT(HKQuantityTypeIdentifierStepCount)
        quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:10] startDate:At(0, 1, 0) endDate:At(0, 1, 1)];
    Wait(@"unauth save", 15, ^(dispatch_block_t done) {
        [gStore saveObject:smp withCompletion:^(BOOL ok, NSError *er) { P(@"unauth save ok=%d err=%@ %@", ok, E(er), Thr()); done(); }];
    });
    Wait(@"unauth query", 15, ^(dispatch_block_t done) {
        HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:QT(HKQuantityTypeIdentifierStepCount) predicate:nil limit:0
            sortDescriptors:nil resultsHandler:^(HKSampleQuery *qq, NSArray *r, NSError *er) {
                P(@"unauth sampleQuery results=%@ err=%@ %@", r ? @(r.count) : @"nil", E(er), Thr()); done(); }];
        [gStore executeQuery:q];
    });
    Wait(@"unauth stats", 15, ^(dispatch_block_t done) {
        HKStatisticsQuery *q = [[HKStatisticsQuery alloc] initWithQuantityType:QT(HKQuantityTypeIdentifierStepCount)
            quantitySamplePredicate:nil options:HKStatisticsOptionCumulativeSum completionHandler:^(HKStatisticsQuery *qq, HKStatistics *r, NSError *er) {
                P(@"unauth statistics sum=%@ err=%@", Q(r.sumQuantity, [HKUnit countUnit]), E(er)); done(); }];
        [gStore executeQuery:q];
    });
    Wait(@"unauth delete", 15, ^(dispatch_block_t done) {
        [gStore deleteObjectsOfType:QT(HKQuantityTypeIdentifierStepCount) predicate:(src ? [HKQuery predicateForObjectsFromSource:src] : nil)
                     withCompletion:^(BOOL ok, NSUInteger cnt, NSError *er) { P(@"unauth deleteOfType ok=%d count=%lu err=%@", ok, (unsigned long)cnt, E(er)); done(); }];
    });
    Wait(@"unauth bgdelivery", 15, ^(dispatch_block_t done) {
        [gStore enableBackgroundDeliveryForType:QT(HKQuantityTypeIdentifierStepCount) frequency:HKUpdateFrequencyImmediate
                                 withCompletion:^(BOOL ok, NSError *er) { P(@"unauth enableBackgroundDelivery ok=%d err=%@", ok, E(er)); done(); }];
    });
    Wait(@"unauth preferredUnits", 15, ^(dispatch_block_t done) {
        [gStore preferredUnitsForQuantityTypes:[NSSet setWithObject:QT(HKQuantityTypeIdentifierBodyMass)]
                                    completion:^(NSDictionary *m, NSError *er) { P(@"unauth preferredUnits=%@ err=%@", m, E(er)); done(); }];
    });

    // Invalid requests (expected to be rejected before any sheet appears).
    struct { const char *tag; NSSet *share, *read; } bad[] = {
        {"share-characteristic", [NSSet setWithObject:[HKObjectType characteristicTypeForIdentifier:HKCharacteristicTypeIdentifierDateOfBirth]], nil},
        {"share-correlation", [NSSet setWithObject:[HKObjectType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure]], nil},
        {"read-correlation", nil, [NSSet setWithObject:[HKObjectType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure]]},
        {"share-activitySummary", [NSSet setWithObject:[HKObjectType activitySummaryType]], nil},
        {"share-appleStandHour", [NSSet setWithObject:CT(HKCategoryTypeIdentifierAppleStandHour)], nil},
        {"share-walkingSteadiness", [NSSet setWithObject:QT(HKQuantityTypeIdentifierAppleWalkingSteadiness)], nil},
        {"read-clinical-no-entitlement", nil, [NSSet setWithObject:[HKObjectType clinicalTypeForIdentifier:HKClinicalTypeIdentifierLabResultRecord]]},
        {"read-userAnnotatedMedication", nil, [NSSet setWithObject:[HKObjectType userAnnotatedMedicationType]]},
        {"share-visionPrescription(perObject)", [NSSet setWithObject:[HKObjectType visionPrescriptionType]], nil},
        {"empty-sets", [NSSet set], [NSSet set]},
        {"nil-sets", nil, nil},
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        NSString *tag = @(bad[i].tag); NSSet *bs = bad[i].share, *br = bad[i].read;
        @try {
            Wait([@"bad " stringByAppendingString:tag], 6, ^(dispatch_block_t done) {
                [gStore requestAuthorizationToShareTypes:bs readTypes:br completion:^(BOOL ok, NSError *er) {
                    P(@"bad-request %@ completion ok=%d err=%@ %@", tag, ok, E(er), Thr()); done(); }];
            });
        } @catch (NSException *ex) { P(@"bad-request %@ EXCEPTION %@: %@", tag, ex.name, ex.reason); }
    }
    // Sample construction validation.
    HKQuantityType *steps = QT(HKQuantityTypeIdentifierStepCount);
    @try { [HKQuantitySample quantitySampleWithType:steps quantity:[HKQuantity quantityWithUnit:[HKUnit meterUnit] doubleValue:1]
                                          startDate:At(0, 1, 0) endDate:At(0, 1, 1)]; P(@"construct incompatible-unit: ok"); }
    @catch (NSException *ex) { P(@"construct incompatible-unit EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [HKQuantitySample quantitySampleWithType:steps quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:1]
                                          startDate:At(0, 2, 0) endDate:At(0, 1, 0)]; P(@"construct end-before-start: ok"); }
    @catch (NSException *ex) { P(@"construct end-before-start EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [HKCategorySample categorySampleWithType:CT(HKCategoryTypeIdentifierSleepAnalysis) value:99 startDate:At(0, 1, 0) endDate:At(0, 2, 0)];
        P(@"construct sleep value=99: ok"); }
    @catch (NSException *ex) { P(@"construct sleep value=99 EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [HKCategorySample categorySampleWithType:CT(HKCategoryTypeIdentifierMindfulSession) value:1 startDate:At(0, 1, 0) endDate:At(0, 2, 0)];
        P(@"construct mindful value=1: ok"); }
    @catch (NSException *ex) { P(@"construct mindful value=1 EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [HKQuantitySample quantitySampleWithType:steps quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:-5]
                                          startDate:At(0, 1, 0) endDate:At(0, 1, 1)]; P(@"construct negative-steps: ok"); }
    @catch (NSException *ex) { P(@"construct negative-steps EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [HKQuantitySample quantitySampleWithType:steps quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:1]
                                          startDate:At(0, 1, 0) endDate:At(0, 1, 1) metadata:@{@"bad": [NSObject new]}]; P(@"construct metadata NSObject: ok"); }
    @catch (NSException *ex) { P(@"construct metadata NSObject EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [HKQuantitySample quantitySampleWithType:steps quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:1]
                                          startDate:At(0, 1, 0) endDate:At(0, 1, 1) metadata:@{@"HKBogusKey": @1}]; P(@"construct metadata HK-prefixed unknown key: ok"); }
    @catch (NSException *ex) { P(@"construct metadata HK-prefixed unknown key EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [HKQuantitySample quantitySampleWithType:steps quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:1]
                                          startDate:At(0, 1, 0) endDate:At(0, 1, 1) metadata:@{HKMetadataKeyExternalUUID: @5}]; P(@"construct metadata ExternalUUID=number: ok"); }
    @catch (NSException *ex) { P(@"construct metadata ExternalUUID=number EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [HKQuantitySample quantitySampleWithType:QT(HKQuantityTypeIdentifierBodyMass) quantity:[HKQuantity quantityWithUnit:[HKUnit poundUnit] doubleValue:150]
                                          startDate:At(0, 1, 0) endDate:At(0, 1, 1)]; P(@"construct bodyMass interval (discrete with duration): ok"); }
    @catch (NSException *ex) { P(@"construct bodyMass interval EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { HKCorrelation *c = [HKCorrelation correlationWithType:[HKObjectType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure]
            startDate:At(0, 1, 0) endDate:At(0, 1, 0) objects:[NSSet setWithObject:[HKQuantitySample quantitySampleWithType:steps
            quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:1] startDate:At(0, 1, 0) endDate:At(0, 1, 0)]]];
        P(@"construct BP correlation with steps: ok %@", c); }
    @catch (NSException *ex) { P(@"construct BP correlation with steps EXCEPTION %@: %@", ex.name, ex.reason); }
    // Enum helper functions.
    P(@"sleep asleepValues=%@", [[HKCategoryValueSleepAnalysisAsleepValues() allObjects] sortedArrayUsingSelector:@selector(compare:)]);
    // PHQ-9 / GAD-7 score-range functions are marked unavailable on iOS (compile error), so not probed.
    for (double v = -1.0; v <= 1.0001; v += 0.25)
        P(@"stateOfMind valence %.2f -> classification %ld", v, (long)HKStateOfMindValenceClassificationForValence(v).integerValue);
    for (double pct = 0; pct <= 1.0001; pct += 0.1) {
        NSError *ee = nil; HKAppleWalkingSteadinessClassification c = 0;
        BOOL ok = HKAppleWalkingSteadinessClassificationForQuantity([HKQuantity quantityWithUnit:[HKUnit percentUnit] doubleValue:pct], &c, &ee);
        P(@"walkingSteadiness %.2f -> ok=%d class=%ld err=%@", pct, ok, (long)c, E(ee));
    }
    for (int c = 1; c <= 3; c++) {
        HKQuantity *mn = HKAppleWalkingSteadinessMinimumQuantityForClassification(c), *mx = HKAppleWalkingSteadinessMaximumQuantityForClassification(c);
        P(@"walkingSteadiness class %d range %@ .. %@", c, Q(mn, [HKUnit percentUnit]), Q(mx, [HKUnit percentUnit]));
    }
    for (int c = 0; c <= 1; c++) P(@"breathingDisturbances class %d min %@", c,
        Q(HKAppleSleepingBreathingDisturbancesMinimumQuantityForClassification(c), [HKUnit countUnit]));
    for (double v = 0; v <= 12; v += 2) {
        NSNumber *n = HKAppleSleepingBreathingDisturbancesClassificationForQuantity([HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:v]);
        P(@"breathingDisturbances %.0f -> %@", v, n);
    }
}

#pragma mark - Phase: auth

static void RequestAuth(NSString *tag, NSSet *share, NSSet *read) {
    PrintStatus([tag stringByAppendingString:@"-before"]);
    Wait(tag, 600, ^(dispatch_block_t done) {
        @try {
            [gStore requestAuthorizationToShareTypes:share readTypes:read completion:^(BOOL ok, NSError *er) {
                P(@"[%@] requestAuthorization completion ok=%d err=%@ %@", tag, ok, E(er), Thr()); done(); }];
            P(@"[%@] requestAuthorization returned", tag);
        } @catch (NSException *ex) { P(@"[%@] requestAuthorization EXCEPTION %@: %@", tag, ex.name, ex.reason); done(); }
    });
    PrintStatus([tag stringByAppendingString:@"-after"]);
}

#pragma mark - Phase: data

static HKQuantitySample *QS(HKQuantityTypeIdentifier i, NSString *u, double v, NSDate *s, NSDate *e, NSDictionary *md) {
    return [HKQuantitySample quantitySampleWithType:QT(i) quantity:[HKQuantity quantityWithUnit:[HKUnit unitFromString:u] doubleValue:v]
                                          startDate:s endDate:e metadata:md];
}

static BOOL Save(NSString *tag, NSArray *objs) {
    __block BOOL res = NO;
    Wait(tag, 30, ^(dispatch_block_t done) {
        [gStore saveObjects:objs withCompletion:^(BOOL ok, NSError *er) {
            P(@"save %@ n=%lu ok=%d err=%@ %@", tag, (unsigned long)objs.count, ok, E(er), Thr()); res = ok; done(); }];
    });
    return res;
}

static NSArray *Samples(NSString *tag, HKSampleType *t, NSPredicate *p, NSUInteger limit, NSArray *sort) {
    __block NSArray *res = nil;
    Wait(tag, 30, ^(dispatch_block_t done) {
        HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:t predicate:p limit:limit sortDescriptors:sort
                                                      resultsHandler:^(HKSampleQuery *qq, NSArray *r, NSError *er) {
            if (er) P(@"query %@ err=%@", tag, E(er));
            res = r; done(); }];
        [gStore executeQuery:q];
    });
    return res;
}

static NSString *SampleDesc(HKSample *s) {
    NSMutableString *m = [NSMutableString stringWithFormat:@"%@..%@", D(s.startDate), D(s.endDate)];
    if ([s isKindOfClass:[HKQuantitySample class]]) {
        HKQuantitySample *q = (HKQuantitySample *)s;
        HKUnit *u = [q.quantityType isCompatibleWithUnit:[HKUnit countUnit]] ? [HKUnit countUnit] :
                    [q.quantityType isCompatibleWithUnit:[HKUnit unitFromString:@"count/min"]] ? [HKUnit unitFromString:@"count/min"] :
                    [q.quantityType isCompatibleWithUnit:[HKUnit gramUnit]] ? [HKUnit unitFromString:@"kg"] :
                    [q.quantityType isCompatibleWithUnit:[HKUnit meterUnit]] ? [HKUnit meterUnit] :
                    [q.quantityType isCompatibleWithUnit:[HKUnit kilocalorieUnit]] ? [HKUnit kilocalorieUnit] :
                    [q.quantityType isCompatibleWithUnit:[HKUnit millimeterOfMercuryUnit]] ? [HKUnit millimeterOfMercuryUnit] : [HKUnit degreeCelsiusUnit];
        [m appendFormat:@" %@ cls=%@ count=%ld", Q(q.quantity, u), NSStringFromClass([q class]), (long)q.count];
    } else if ([s isKindOfClass:[HKCategorySample class]]) {
        [m appendFormat:@" value=%ld", (long)((HKCategorySample *)s).value];
    }
    return m;
}

static HKStatistics *Stats(NSString *tag, HKQuantityTypeIdentifier i, NSPredicate *p, HKStatisticsOptions o, NSString *unit) {
    __block HKStatistics *res = nil;
    HKUnit *u = [HKUnit unitFromString:unit];
    Wait(tag, 30, ^(dispatch_block_t done) {
        @try {
            HKStatisticsQuery *q = [[HKStatisticsQuery alloc] initWithQuantityType:QT(i) quantitySamplePredicate:p options:o
                completionHandler:^(HKStatisticsQuery *qq, HKStatistics *r, NSError *er) {
                    NSMutableString *m = [NSMutableString string];
                    if (o & HKStatisticsOptionCumulativeSum) [m appendFormat:@" sum=%@", Q(r.sumQuantity, u)];
                    if (o & HKStatisticsOptionDiscreteAverage) [m appendFormat:@" avg=%@", Q(r.averageQuantity, u)];
                    if (o & HKStatisticsOptionDiscreteMin) [m appendFormat:@" min=%@", Q(r.minimumQuantity, u)];
                    if (o & HKStatisticsOptionDiscreteMax) [m appendFormat:@" max=%@", Q(r.maximumQuantity, u)];
                    if (o & HKStatisticsOptionMostRecent) [m appendFormat:@" mostRecent=%@ at %@..%@", Q(r.mostRecentQuantity, u),
                        D(r.mostRecentQuantityDateInterval.startDate), D(r.mostRecentQuantityDateInterval.endDate)];
                    if (o & HKStatisticsOptionDuration) [m appendFormat:@" duration=%@", Q(r.duration, [HKUnit secondUnit])];
                    if (o & HKStatisticsOptionSeparateBySource) {
                        for (HKSource *src in r.sources) {
                            [m appendFormat:@" [src %@:", src.bundleIdentifier];
                            if (o & HKStatisticsOptionCumulativeSum) [m appendFormat:@" sum=%@", Q([r sumQuantityForSource:src], u)];
                            if (o & HKStatisticsOptionDiscreteAverage) [m appendFormat:@" avg=%@", Q([r averageQuantityForSource:src], u)];
                            if (o & HKStatisticsOptionMostRecent) [m appendFormat:@" mostRecent=%@", Q([r mostRecentQuantityForSource:src], u)];
                            [m appendString:@"]"];
                        }
                    }
                    P(@"stats %@ range=%@..%@%@ err=%@", tag, D(r.startDate), D(r.endDate), m, E(er));
                    res = r; done(); }];
            [gStore executeQuery:q];
        } @catch (NSException *ex) { P(@"stats %@ EXCEPTION %@: %@", tag, ex.name, ex.reason); done(); }
    });
    return res;
}

static void Collection(NSString *tag, HKQuantityTypeIdentifier i, HKStatisticsOptions o, NSDateComponents *iv, NSDate *anchor,
                       NSDate *from, NSDate *to, NSString *unit) {
    HKUnit *u = [HKUnit unitFromString:unit];
    Wait(tag, 30, ^(dispatch_block_t done) {
        @try {
            HKStatisticsCollectionQuery *q = [[HKStatisticsCollectionQuery alloc] initWithQuantityType:QT(i) quantitySamplePredicate:nil
                options:o anchorDate:anchor intervalComponents:iv];
            q.initialResultsHandler = ^(HKStatisticsCollectionQuery *qq, HKStatisticsCollection *c, NSError *er) {
                P(@"collection %@ initial err=%@ statistics=%lu", tag, E(er), (unsigned long)c.statistics.count);
                int shown = 0;
                for (HKStatistics *st in c.statistics) {
                    if (shown++ >= 40) break;
                    P(@"collection %@ (all) %@..%@ sum=%@ avg=%@ min=%@ max=%@", tag, D(st.startDate), D(st.endDate),
                      Q(st.sumQuantity, u), Q(st.averageQuantity, u), Q(st.minimumQuantity, u), Q(st.maximumQuantity, u));
                }
                __block int k = 0;
                [c enumerateStatisticsFromDate:from toDate:to withBlock:^(HKStatistics *st, BOOL *stop) {
                    if (k++ < 60) P(@"collection %@ (enum) %@..%@ sum=%@ avg=%@", tag, D(st.startDate), D(st.endDate),
                                    Q(st.sumQuantity, u), Q(st.averageQuantity, u));
                }];
                P(@"collection %@ enumerated=%d statisticsForDate(D0 12:00)=%@", tag, k,
                  Q([c statisticsForDate:At(0, 12, 0)].sumQuantity ?: [c statisticsForDate:At(0, 12, 0)].averageQuantity, u));
                [gStore stopQuery:qq];
                done();
            };
            [gStore executeQuery:q];
        } @catch (NSException *ex) { P(@"collection %@ EXCEPTION %@: %@", tag, ex.name, ex.reason); done(); }
    });
}

static void Wipe(void) {
    NSPredicate *mine = [HKQuery predicateForObjectsFromSource:[HKSource defaultSource]];
    Wait(@"wipe-bp", 30, ^(dispatch_block_t done) {
        [gStore deleteObjectsOfType:[HKObjectType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure] predicate:mine
                     withCompletion:^(BOOL ok, NSUInteger n, NSError *er) { P(@"wipe bloodPressure ok=%d deleted=%lu err=%@", ok, (unsigned long)n, E(er)); done(); }];
    });
    for (HKSampleType *t in ShareSet()) {
        if ([t isKindOfClass:[HKSeriesType class]]) continue;
        Wait(@"wipe", 30, ^(dispatch_block_t done) {
            [gStore deleteObjectsOfType:t predicate:mine withCompletion:^(BOOL ok, NSUInteger n, NSError *er) {
                P(@"wipe %@ ok=%d deleted=%lu err=%@", t.identifier, ok, (unsigned long)n, E(er)); done(); }];
        });
    }
}

static void CountMine(NSString *tag) {
    NSPredicate *mine = [HKQuery predicateForObjectsFromSource:[HKSource defaultSource]];
    NSArray *types = [[ShareSet() allObjects] sortedArrayUsingComparator:^NSComparisonResult(HKObjectType *a, HKObjectType *b) {
        return [a.identifier compare:b.identifier]; }];
    for (HKSampleType *t in types) {
        NSArray *r = Samples(@"count", t, mine, 0, nil);
        NSArray *all = Samples(@"countAll", t, nil, 0, nil);
        P(@"[%@] count %@ mine=%@ all=%@", tag, t.identifier, r ? @(r.count) : @"nil", all ? @(all.count) : @"nil");
    }
}

static void PhaseData(void) {
    Wipe();
    NSDictionary *md3 = @{HKMetadataKeyExternalUUID: @"ycode-s3", @"YcodeProbe": @"golden", @"YcodeNumber": @42,
                          @"YcodeQuantity": [HKQuantity quantityWithUnit:[HKUnit meterUnit] doubleValue:3], @"YcodeDate": At(0, 0, 0)};
    NSArray *stepSamples = @[
        QS(HKQuantityTypeIdentifierStepCount, @"count", 1000, At(0, 8, 0), At(0, 8, 10), nil),
        QS(HKQuantityTypeIdentifierStepCount, @"count", 500, At(0, 8, 5), At(0, 8, 15), nil),
        QS(HKQuantityTypeIdentifierStepCount, @"count", 3000, At(0, 12, 0), At(0, 12, 30), md3),
        QS(HKQuantityTypeIdentifierStepCount, @"count", 2000, At(1, 9, 0), At(1, 9, 30), nil),
        QS(HKQuantityTypeIdentifierStepCount, @"count", 600, At(0, 23, 50), At(1, 0, 10), nil)];
    Save(@"steps", stepSamples);
    Save(@"heartRate", @[
        QS(HKQuantityTypeIdentifierHeartRate, @"count/min", 60, At(0, 8, 0), At(0, 8, 0), nil),
        QS(HKQuantityTypeIdentifierHeartRate, @"count/min", 70, At(0, 8, 30), At(0, 8, 30), nil),
        QS(HKQuantityTypeIdentifierHeartRate, @"count/min", 90, At(0, 9, 0), At(0, 9, 0), nil),
        QS(HKQuantityTypeIdentifierHeartRate, @"count/min", 80, At(0, 13, 0), At(0, 13, 10), nil)]);
    Save(@"bodyMass", @[
        QS(HKQuantityTypeIdentifierBodyMass, @"kg", 70, At(0, 7, 0), At(0, 7, 0), @{HKMetadataKeyWasUserEntered: @YES}),
        QS(HKQuantityTypeIdentifierBodyMass, @"lb", 155, At(1, 7, 0), At(1, 7, 0), nil)]);
    Save(@"sleep", @[
        [HKCategorySample categorySampleWithType:CT(HKCategoryTypeIdentifierSleepAnalysis) value:HKCategoryValueSleepAnalysisInBed startDate:At(0, 0, 45) endDate:At(0, 6, 0)],
        [HKCategorySample categorySampleWithType:CT(HKCategoryTypeIdentifierSleepAnalysis) value:HKCategoryValueSleepAnalysisAsleepCore startDate:At(0, 1, 0) endDate:At(0, 3, 0)],
        [HKCategorySample categorySampleWithType:CT(HKCategoryTypeIdentifierSleepAnalysis) value:HKCategoryValueSleepAnalysisAwake startDate:At(0, 3, 0) endDate:At(0, 3, 15)],
        [HKCategorySample categorySampleWithType:CT(HKCategoryTypeIdentifierSleepAnalysis) value:HKCategoryValueSleepAnalysisAsleepDeep startDate:At(0, 3, 15) endDate:At(0, 5, 0)]]);
    Save(@"mindful", @[[HKCategorySample categorySampleWithType:CT(HKCategoryTypeIdentifierMindfulSession) value:HKCategoryValueNotApplicable startDate:At(0, 10, 0) endDate:At(0, 10, 10)]]);
    HKQuantitySample *sys = QS(HKQuantityTypeIdentifierBloodPressureSystolic, @"mmHg", 120, At(0, 7, 30), At(0, 7, 30), nil);
    HKQuantitySample *dia = QS(HKQuantityTypeIdentifierBloodPressureDiastolic, @"mmHg", 80, At(0, 7, 30), At(0, 7, 30), nil);
    HKCorrelation *bp = [HKCorrelation correlationWithType:[HKObjectType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure]
                                                 startDate:At(0, 7, 30) endDate:At(0, 7, 30) objects:[NSSet setWithObjects:sys, dia, nil]];
    Save(@"bloodPressure-correlation", @[bp]);
    // Save the same object twice.
    Save(@"resave-same-object", @[stepSamples[0]]);
    // Sample older than earliestPermittedSampleDate and one in the future.
    Save(@"ancient", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 1, [NSDate dateWithTimeIntervalSince1970:-5e9], [NSDate dateWithTimeIntervalSince1970:-5e9 + 60], nil)]);
    Save(@"old-60-days(own)", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 61, At(-60, 12, 0), At(-60, 12, 1), nil)]);
    P(@"own sample 60 days before D0 readable: n=%lu", (unsigned long)Samples(@"old60", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForSamplesWithStartDate:At(-61, 0, 0) endDate:At(-59, 0, 0) options:0], 0, nil).count);
    P(@"ancient own sample readable: n=%lu", (unsigned long)Samples(@"anc", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForSamplesWithStartDate:nil endDate:[NSDate dateWithTimeIntervalSince1970:-4e9] options:0], 0, nil).count);
    @try { Save(@"too-long-steps(8 days)", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 1, At(-10, 0, 0), At(-2, 0, 0), nil)]); }
    @catch (NSException *ex) { P(@"construct too-long-steps(8 days) EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { Save(@"steps exactly 4 days", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 4, At(-10, 0, 0), At(-6, 0, 0), nil)]); }
    @catch (NSException *ex) { P(@"construct steps exactly 4 days EXCEPTION %@: %@", ex.name, ex.reason); }
    Save(@"not-authorized-type(restingHR read-only)", @[QS(HKQuantityTypeIdentifierRestingHeartRate, @"count/min", 50, At(0, 6, 0), At(0, 6, 0), nil)]);
    Save(@"not-requested-type(flights)", @[QS(HKQuantityTypeIdentifierFlightsClimbed, @"count", 3, At(0, 6, 0), At(0, 6, 1), nil)]);

    // Workout via builder, with route.
    HKWorkoutConfiguration *cfg = [HKWorkoutConfiguration new];
    cfg.activityType = HKWorkoutActivityTypeRunning;
    cfg.locationType = HKWorkoutSessionLocationTypeOutdoor;
    HKWorkoutBuilder *wb = [[HKWorkoutBuilder alloc] initWithHealthStore:gStore configuration:cfg device:[HKDevice localDevice]];
    Wait(@"wb begin", 30, ^(dispatch_block_t done) {
        [wb beginCollectionWithStartDate:At(0, 6, 0) completion:^(BOOL ok, NSError *er) { P(@"workoutBuilder begin ok=%d err=%@", ok, E(er)); done(); }]; });
    Wait(@"wb add", 30, ^(dispatch_block_t done) {
        [wb addSamples:@[QS(HKQuantityTypeIdentifierActiveEnergyBurned, @"kcal", 300, At(0, 6, 0), At(0, 6, 30), nil),
                         QS(HKQuantityTypeIdentifierDistanceWalkingRunning, @"m", 5000, At(0, 6, 0), At(0, 6, 30), nil),
                         QS(HKQuantityTypeIdentifierHeartRate, @"count/min", 150, At(0, 6, 15), At(0, 6, 15), nil)]
            completion:^(BOOL ok, NSError *er) { P(@"workoutBuilder addSamples ok=%d err=%@", ok, E(er)); done(); }]; });
    Wait(@"wb events", 30, ^(dispatch_block_t done) {
        [wb addWorkoutEvents:@[[HKWorkoutEvent workoutEventWithType:HKWorkoutEventTypePause dateInterval:[[NSDateInterval alloc] initWithStartDate:At(0, 6, 10) duration:0] metadata:nil],
                               [HKWorkoutEvent workoutEventWithType:HKWorkoutEventTypeResume dateInterval:[[NSDateInterval alloc] initWithStartDate:At(0, 6, 12) duration:0] metadata:nil]]
                  completion:^(BOOL ok, NSError *er) { P(@"workoutBuilder addEvents ok=%d err=%@", ok, E(er)); done(); }]; });
    Wait(@"wb md", 30, ^(dispatch_block_t done) {
        [wb addMetadata:@{HKMetadataKeyIndoorWorkout: @NO, @"YcodeProbe": @"workout"} completion:^(BOOL ok, NSError *er) { P(@"workoutBuilder addMetadata ok=%d err=%@", ok, E(er)); done(); }]; });
    P(@"workoutBuilder elapsedTime(before end)=%.1f", [wb elapsedTimeAtDate:At(0, 6, 20)]);
    Wait(@"wb end", 30, ^(dispatch_block_t done) {
        [wb endCollectionWithEndDate:At(0, 6, 30) completion:^(BOOL ok, NSError *er) { P(@"workoutBuilder end ok=%d err=%@", ok, E(er)); done(); }]; });
    P(@"workoutBuilder elapsedTime(end)=%.1f", [wb elapsedTimeAtDate:At(0, 6, 30)]);
    __block HKWorkout *workout = nil;
    Wait(@"wb finish", 30, ^(dispatch_block_t done) {
        [wb finishWorkoutWithCompletion:^(HKWorkout *w, NSError *er) { workout = w; P(@"workoutBuilder finish workout=%@ err=%@", w ? @"set" : @"nil", E(er)); done(); }]; });
    if (workout) {
        P(@"workout type=%lu duration=%.1f start=%@ end=%@ events=%lu activities=%lu md=%@", (unsigned long)workout.workoutActivityType, workout.duration,
          D(workout.startDate), D(workout.endDate), (unsigned long)workout.workoutEvents.count, (unsigned long)workout.workoutActivities.count, workout.metadata);
        for (HKQuantityType *t in workout.allStatistics) {
            HKStatistics *st = workout.allStatistics[t];
            P(@"workout statistics %@ sum=%@ avg=%@ min=%@ max=%@", t.identifier, st.sumQuantity, st.averageQuantity, st.minimumQuantity, st.maximumQuantity);
        }
        for (HKWorkoutActivity *a in workout.workoutActivities)
            P(@"workout activity cfgType=%lu %@..%@ duration=%.1f", (unsigned long)a.workoutConfiguration.activityType, D(a.startDate), D(a.endDate), a.duration);
        HKWorkoutRouteBuilder *rb = [[HKWorkoutRouteBuilder alloc] initWithHealthStore:gStore device:nil];
        NSMutableArray *locs = [NSMutableArray array];
        for (int k = 0; k < 3; k++)
            [locs addObject:[[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(10.0 + k * 0.001, 20.0) altitude:5 + k
                                               horizontalAccuracy:5 verticalAccuracy:5 course:0 speed:3 timestamp:At(0, 6, 5 * k)]];
        Wait(@"rb insert", 30, ^(dispatch_block_t done) {
            [rb insertRouteData:locs completion:^(BOOL ok, NSError *er) { P(@"routeBuilder insert ok=%d err=%@", ok, E(er)); done(); }]; });
        __block HKWorkoutRoute *route = nil;
        Wait(@"rb finish", 30, ^(dispatch_block_t done) {
            [rb finishRouteWithWorkout:workout metadata:nil completion:^(HKWorkoutRoute *r, NSError *er) {
                route = r; P(@"routeBuilder finish route=%@ count=%ld err=%@", r ? @"set" : @"nil", (long)r.count, E(er)); done(); }]; });
        if (route) {
            Wait(@"route query", 30, ^(dispatch_block_t done) {
                __block int n = 0;
                HKWorkoutRouteQuery *q = [[HKWorkoutRouteQuery alloc] initWithRoute:route dataHandler:^(HKWorkoutRouteQuery *qq, NSArray<CLLocation *> *data, BOOL fin, NSError *er) {
                    n += data.count;
                    for (CLLocation *l in data) P(@"route location %.4f,%.4f alt=%.0f t=%@", l.coordinate.latitude, l.coordinate.longitude, l.altitude, D(l.timestamp));
                    if (fin || er) { P(@"route query done total=%d err=%@", n, E(er)); done(); } }];
                [gStore executeQuery:q];
            });
        }
        NSArray *wsamples = Samples(@"from-workout", QT(HKQuantityTypeIdentifierActiveEnergyBurned), [HKQuery predicateForObjectsFromWorkout:workout], 0, nil);
        P(@"predicateForObjectsFromWorkout(activeEnergy) n=%lu", (unsigned long)wsamples.count);
        NSArray *wq = Samples(@"workouts", [HKObjectType workoutType], [HKQuery predicateForWorkoutsWithWorkoutActivityType:HKWorkoutActivityTypeRunning], 0, nil);
        P(@"workouts(running) n=%lu", (unsigned long)wq.count);
        NSArray *routes = Samples(@"routes", [HKSeriesType workoutRouteType], [HKQuery predicateForObjectsFromWorkout:workout], 0, nil);
        P(@"routes for workout n=%lu", (unsigned long)routes.count);
    }

    // Sample queries.
    NSPredicate *day0 = [HKQuery predicateForSamplesWithStartDate:At(0, 0, 0) endDate:At(1, 0, 0) options:HKQueryOptionNone];
    NSPredicate *day0strict = [HKQuery predicateForSamplesWithStartDate:At(0, 0, 0) endDate:At(1, 0, 0) options:HKQueryOptionStrictStartDate | HKQueryOptionStrictEndDate];
    NSPredicate *twodays = [HKQuery predicateForSamplesWithStartDate:At(0, 0, 0) endDate:At(2, 0, 0) options:HKQueryOptionNone];
    NSSortDescriptor *byStart = [NSSortDescriptor sortDescriptorWithKey:HKSampleSortIdentifierStartDate ascending:YES];
    NSSortDescriptor *byEndDesc = [NSSortDescriptor sortDescriptorWithKey:HKSampleSortIdentifierEndDate ascending:NO];
    for (HKSample *s in Samples(@"steps-all", QT(HKQuantityTypeIdentifierStepCount), twodays, 0, @[byStart]))
        P(@"steps 2days asc: %@ src=%@ ver=%@ product=%@ os=%ld.%ld.%ld device=%@ md=%@", SampleDesc(s), s.sourceRevision.source.bundleIdentifier,
          s.sourceRevision.version, s.sourceRevision.productType, (long)s.sourceRevision.operatingSystemVersion.majorVersion,
          (long)s.sourceRevision.operatingSystemVersion.minorVersion, (long)s.sourceRevision.operatingSystemVersion.patchVersion, s.device.name, s.metadata);
    for (HKSample *s in Samples(@"steps-limit2", QT(HKQuantityTypeIdentifierStepCount), twodays, 2, @[byEndDesc])) P(@"steps limit2 endDesc: %@", SampleDesc(s));
    for (HKSample *s in Samples(@"steps-unsorted", QT(HKQuantityTypeIdentifierStepCount), twodays, 0, nil)) P(@"steps unsorted: %@", SampleDesc(s));
    P(@"steps day0 (none) n=%lu", (unsigned long)Samples(@"d0", QT(HKQuantityTypeIdentifierStepCount), day0, 0, nil).count);
    P(@"steps day0 (strict) n=%lu", (unsigned long)Samples(@"d0s", QT(HKQuantityTypeIdentifierStepCount), day0strict, 0, nil).count);
    P(@"steps day0 (strictStart) n=%lu", (unsigned long)Samples(@"d0ss", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForSamplesWithStartDate:At(0, 0, 0) endDate:At(1, 0, 0) options:HKQueryOptionStrictStartDate], 0, nil).count);
    P(@"steps day0 (strictEnd) n=%lu", (unsigned long)Samples(@"d0se", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForSamplesWithStartDate:At(0, 0, 0) endDate:At(1, 0, 0) options:HKQueryOptionStrictEndDate], 0, nil).count);
    P(@"steps boundary [08:10, 08:10] n=%lu", (unsigned long)Samples(@"bnd", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForSamplesWithStartDate:At(0, 8, 10) endDate:At(0, 8, 10) options:HKQueryOptionNone], 0, nil).count);
    P(@"steps boundary [08:15, 09:00] (touching end) n=%lu", (unsigned long)Samples(@"bnd2", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForSamplesWithStartDate:At(0, 8, 15) endDate:At(0, 9, 0) options:HKQueryOptionNone], 0, nil).count);
    P(@"steps boundary [07:00, 08:00] (touching start) n=%lu", (unsigned long)Samples(@"bnd3", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForSamplesWithStartDate:At(0, 7, 0) endDate:At(0, 8, 0) options:HKQueryOptionNone], 0, nil).count);
    P(@"steps nil-start [.., D0 09:00] n=%lu", (unsigned long)Samples(@"bnd4", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForSamplesWithStartDate:nil endDate:At(0, 9, 0) options:HKQueryOptionNone], 0, nil).count);
    P(@"steps metadata YcodeProbe==golden n=%lu", (unsigned long)Samples(@"md", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForObjectsWithMetadataKey:@"YcodeProbe" allowedValues:@[@"golden"]], 0, nil).count);
    P(@"steps metadata YcodeNumber>40 n=%lu", (unsigned long)Samples(@"md2", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForObjectsWithMetadataKey:@"YcodeNumber" operatorType:NSGreaterThanPredicateOperatorType value:@40], 0, nil).count);
    P(@"steps metadata exists ExternalUUID n=%lu", (unsigned long)Samples(@"md3", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForObjectsWithMetadataKey:HKMetadataKeyExternalUUID], 0, nil).count);
    P(@"steps quantity>=1000 n=%lu", (unsigned long)Samples(@"qp", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForQuantitySamplesWithOperatorType:NSGreaterThanOrEqualToPredicateOperatorType quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:1000]], 0, nil).count);
    P(@"sleep value==asleepCore n=%lu", (unsigned long)Samples(@"cp", CT(HKCategoryTypeIdentifierSleepAnalysis),
        [HKQuery predicateForCategorySamplesWithOperatorType:NSEqualToPredicateOperatorType value:HKCategoryValueSleepAnalysisAsleepCore], 0, nil).count);
    P(@"sleep value in asleepValues n=%lu", (unsigned long)Samples(@"cp2", CT(HKCategoryTypeIdentifierSleepAnalysis),
        [HKQuery predicateForCategorySamplesEqualToValues:HKCategoryValueSleepAnalysisAsleepValues()], 0, nil).count);
    P(@"steps from-source(default) n=%lu", (unsigned long)Samples(@"src", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForObjectsFromSource:[HKSource defaultSource]], 0, nil).count);
    P(@"steps from localDevice n=%lu", (unsigned long)Samples(@"dev", QT(HKQuantityTypeIdentifierStepCount),
        [HKQuery predicateForObjectsFromDevices:[NSSet setWithObject:[HKDevice localDevice]]], 0, nil).count);
    P(@"steps compound(day0 AND >=1000) n=%lu", (unsigned long)Samples(@"cmp", QT(HKQuantityTypeIdentifierStepCount),
        [NSCompoundPredicate andPredicateWithSubpredicates:@[day0, [HKQuery predicateForQuantitySamplesWithOperatorType:NSGreaterThanOrEqualToPredicateOperatorType
        quantity:[HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:1000]]]], 0, nil).count);
    P(@"steps noCorrelation n=%lu", (unsigned long)Samples(@"nc", QT(HKQuantityTypeIdentifierStepCount), [HKQuery predicateForObjectsWithNoCorrelation], 0, nil).count);
    P(@"systolic noCorrelation n=%lu all=%lu", (unsigned long)Samples(@"nc2", QT(HKQuantityTypeIdentifierBloodPressureSystolic), [HKQuery predicateForObjectsWithNoCorrelation], 0, nil).count,
      (unsigned long)Samples(@"nc3", QT(HKQuantityTypeIdentifierBloodPressureSystolic), nil, 0, nil).count);
    @try { NSArray *r = Samples(@"custom-predicate", QT(HKQuantityTypeIdentifierStepCount), [NSPredicate predicateWithFormat:@"startDate > %@", At(0, 0, 0)], 0, nil);
        P(@"steps custom NSPredicate(startDate > D0) n=%@", r ? @(r.count) : @"nil"); }
    @catch (NSException *ex) { P(@"custom NSPredicate EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { NSArray *r = Samples(@"bad-sort", QT(HKQuantityTypeIdentifierStepCount), nil, 0, @[[NSSortDescriptor sortDescriptorWithKey:@"quantity" ascending:YES]]);
        P(@"steps sort by quantity n=%@", r ? @(r.count) : @"nil"); }
    @catch (NSException *ex) { P(@"sort by quantity EXCEPTION %@: %@", ex.name, ex.reason); }
    for (HKSample *s in Samples(@"bp", [HKObjectType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure], nil, 0, nil)) {
        HKCorrelation *c = (HKCorrelation *)s;
        P(@"bp correlation %@ objects=%lu", SampleDesc(c), (unsigned long)c.objects.count);
        for (HKSample *o in c.objects) P(@"  bp member %@ %@", o.sampleType.identifier, SampleDesc(o));
    }
    Wait(@"correlationQuery", 30, ^(dispatch_block_t done) {
        HKCorrelationQuery *q = [[HKCorrelationQuery alloc] initWithType:[HKObjectType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure]
            predicate:nil samplePredicates:@{QT(HKQuantityTypeIdentifierBloodPressureSystolic): [HKQuery predicateForQuantitySamplesWithOperatorType:NSGreaterThanPredicateOperatorType quantity:[HKQuantity quantityWithUnit:[HKUnit millimeterOfMercuryUnit] doubleValue:110]]}
            completion:^(HKCorrelationQuery *qq, NSArray *r, NSError *er) { P(@"correlationQuery systolic>110 n=%lu err=%@", (unsigned long)r.count, E(er)); done(); }];
        [gStore executeQuery:q];
    });
    for (HKSample *s in Samples(@"sleep", CT(HKCategoryTypeIdentifierSleepAnalysis), nil, 0, @[byStart])) P(@"sleep: %@", SampleDesc(s));
    for (HKSample *s in Samples(@"hr", QT(HKQuantityTypeIdentifierHeartRate), nil, 0, @[byStart])) P(@"heartRate: %@", SampleDesc(s));
    for (HKSample *s in Samples(@"bm", QT(HKQuantityTypeIdentifierBodyMass), nil, 0, @[byStart])) P(@"bodyMass: %@", SampleDesc(s));

    // Statistics (golden values).
    HKStatisticsOptions sumSrc = HKStatisticsOptionCumulativeSum | HKStatisticsOptionSeparateBySource;
    Stats(@"steps day0 sum", HKQuantityTypeIdentifierStepCount, day0, sumSrc, @"count");
    Stats(@"steps day0 strict sum", HKQuantityTypeIdentifierStepCount, day0strict, HKStatisticsOptionCumulativeSum, @"count");
    Stats(@"steps day1 sum", HKQuantityTypeIdentifierStepCount, [HKQuery predicateForSamplesWithStartDate:At(1, 0, 0) endDate:At(2, 0, 0) options:0], HKStatisticsOptionCumulativeSum, @"count");
    Stats(@"steps 2days sum", HKQuantityTypeIdentifierStepCount, twodays, HKStatisticsOptionCumulativeSum | HKStatisticsOptionDuration, @"count");
    Stats(@"steps all sum", HKQuantityTypeIdentifierStepCount, nil, HKStatisticsOptionCumulativeSum | HKStatisticsOptionMostRecent, @"count");
    Stats(@"steps [08:00,08:10] sum (overlap window)", HKQuantityTypeIdentifierStepCount,
          [HKQuery predicateForSamplesWithStartDate:At(0, 8, 0) endDate:At(0, 8, 10) options:0], HKStatisticsOptionCumulativeSum, @"count");
    Stats(@"steps [08:05,08:10] sum (partial)", HKQuantityTypeIdentifierStepCount,
          [HKQuery predicateForSamplesWithStartDate:At(0, 8, 5) endDate:At(0, 8, 10) options:0], HKStatisticsOptionCumulativeSum, @"count");
    Stats(@"steps [12:00,12:15] sum (half of 3000)", HKQuantityTypeIdentifierStepCount,
          [HKQuery predicateForSamplesWithStartDate:At(0, 12, 0) endDate:At(0, 12, 15) options:0], HKStatisticsOptionCumulativeSum, @"count");
    Stats(@"steps discreteAverage (invalid for cumulative)", HKQuantityTypeIdentifierStepCount, nil, HKStatisticsOptionDiscreteAverage, @"count");
    Stats(@"hr day0 discrete", HKQuantityTypeIdentifierHeartRate, day0,
          HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax | HKStatisticsOptionMostRecent, @"count/min");
    Stats(@"hr [08:00,09:00] discrete", HKQuantityTypeIdentifierHeartRate, [HKQuery predicateForSamplesWithStartDate:At(0, 8, 0) endDate:At(0, 9, 0) options:0],
          HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax, @"count/min");
    Stats(@"hr day0 sum (invalid for discrete)", HKQuantityTypeIdentifierHeartRate, day0, HKStatisticsOptionCumulativeSum, @"count/min");
    Stats(@"hr none-option", HKQuantityTypeIdentifierHeartRate, day0, HKStatisticsOptionNone, @"count/min");
    Stats(@"bodyMass all", HKQuantityTypeIdentifierBodyMass, nil,
          HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax | HKStatisticsOptionMostRecent | HKStatisticsOptionSeparateBySource, @"kg");
    Stats(@"empty range steps", HKQuantityTypeIdentifierStepCount, [HKQuery predicateForSamplesWithStartDate:At(-30, 0, 0) endDate:At(-29, 0, 0) options:0],
          HKStatisticsOptionCumulativeSum, @"count");
    Stats(@"empty range hr", HKQuantityTypeIdentifierHeartRate, [HKQuery predicateForSamplesWithStartDate:At(-30, 0, 0) endDate:At(-29, 0, 0) options:0],
          HKStatisticsOptionDiscreteAverage, @"count/min");
    Stats(@"activeEnergy all", HKQuantityTypeIdentifierActiveEnergyBurned, nil, HKStatisticsOptionCumulativeSum, @"kcal");
    Stats(@"distance all", HKQuantityTypeIdentifierDistanceWalkingRunning, nil, HKStatisticsOptionCumulativeSum, @"km");

    // Averaging rule for discrete types: body temperature on day 3 (degC).
    Save(@"avg-A two instants 10,20", @[QS(HKQuantityTypeIdentifierBodyTemperature, @"degC", 10, At(3, 1, 0), At(3, 1, 0), nil),
                                        QS(HKQuantityTypeIdentifierBodyTemperature, @"degC", 20, At(3, 1, 30), At(3, 1, 30), nil)]);
    Stats(@"avg-A", HKQuantityTypeIdentifierBodyTemperature, [HKQuery predicateForSamplesWithStartDate:At(3, 0, 0) endDate:At(3, 2, 0) options:0], HKStatisticsOptionDiscreteAverage, @"degC");
    Save(@"avg-B instant 10 + 10-min 20", @[QS(HKQuantityTypeIdentifierBodyTemperature, @"degC", 10, At(3, 3, 0), At(3, 3, 0), nil),
                                            QS(HKQuantityTypeIdentifierBodyTemperature, @"degC", 20, At(3, 3, 30), At(3, 3, 40), nil)]);
    Stats(@"avg-B", HKQuantityTypeIdentifierBodyTemperature, [HKQuery predicateForSamplesWithStartDate:At(3, 2, 30) endDate:At(3, 4, 0) options:0], HKStatisticsOptionDiscreteAverage, @"degC");
    Save(@"avg-C 1-min 10 + 3-min 20", @[QS(HKQuantityTypeIdentifierBodyTemperature, @"degC", 10, At(3, 5, 0), At(3, 5, 1), nil),
                                         QS(HKQuantityTypeIdentifierBodyTemperature, @"degC", 20, At(3, 5, 30), At(3, 5, 33), nil)]);
    Stats(@"avg-C", HKQuantityTypeIdentifierBodyTemperature, [HKQuery predicateForSamplesWithStartDate:At(3, 4, 30) endDate:At(3, 6, 0) options:0], HKStatisticsOptionDiscreteAverage, @"degC");
    Save(@"avg-D overlapping 10 (0-10min) + 20 (5-15min)", @[QS(HKQuantityTypeIdentifierBodyTemperature, @"degC", 10, At(3, 7, 0), At(3, 7, 10), nil),
                                         QS(HKQuantityTypeIdentifierBodyTemperature, @"degC", 20, At(3, 7, 5), At(3, 7, 15), nil)]);
    Stats(@"avg-D", HKQuantityTypeIdentifierBodyTemperature, [HKQuery predicateForSamplesWithStartDate:At(3, 6, 30) endDate:At(3, 8, 0) options:0], HKStatisticsOptionDiscreteAverage, @"degC");
    Stats(@"avg-D window [07:00,07:05]", HKQuantityTypeIdentifierBodyTemperature, [HKQuery predicateForSamplesWithStartDate:At(3, 7, 0) endDate:At(3, 7, 5) options:0],
          HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax, @"degC");
    Stats(@"avg-all day3", HKQuantityTypeIdentifierBodyTemperature, [HKQuery predicateForSamplesWithStartDate:At(3, 0, 0) endDate:At(4, 0, 0) options:0],
          HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax | HKStatisticsOptionMostRecent | HKStatisticsOptionDuration, @"degC");
    Stats(@"hr instants only [08:00,09:01]", HKQuantityTypeIdentifierHeartRate, [HKQuery predicateForSamplesWithStartDate:At(0, 7, 59) endDate:At(0, 9, 1) options:0],
          HKStatisticsOptionDiscreteAverage, @"count/min");
    Stats(@"hr [06:00,09:01] (150,60,70,90)", HKQuantityTypeIdentifierHeartRate, [HKQuery predicateForSamplesWithStartDate:At(0, 6, 0) endDate:At(0, 9, 1) options:0],
          HKStatisticsOptionDiscreteAverage, @"count/min");
    // Temporally weighted averaging: heart rate on day 4 (count/min).
    struct { const char *tag; double v1, s1, e1, v2, s2, e2; } tw[] = {
        {"tw-A two instants 60@0,120@30", 60, 0, 0, 120, 30, 30},
        {"tw-B instants 60@0,120@10", 60, 0, 0, 120, 10, 10},
        {"tw-C instant 60@0 + 120 over 10min@30", 60, 0, 0, 120, 30, 40},
        {"tw-D 60 over 1min@0 + 120 over 3min@30", 60, 0, 1, 120, 30, 33},
        {"tw-E 60 over 10min@0 + 120 over 10min@10 (adjacent)", 60, 0, 10, 120, 10, 20},
        {"tw-F 60 over 10min@0 + 120 instant@60", 60, 0, 10, 120, 60, 60},
    };
    for (int k = 0; k < (int)(sizeof(tw) / sizeof(tw[0])); k++) {
        NSDate *b = At(4, 2 * k, 0);
        Save(@(tw[k].tag), @[QS(HKQuantityTypeIdentifierHeartRate, @"count/min", tw[k].v1, [b dateByAddingTimeInterval:tw[k].s1 * 60], [b dateByAddingTimeInterval:tw[k].e1 * 60], nil),
                             QS(HKQuantityTypeIdentifierHeartRate, @"count/min", tw[k].v2, [b dateByAddingTimeInterval:tw[k].s2 * 60], [b dateByAddingTimeInterval:tw[k].e2 * 60], nil)]);
        Stats(@(tw[k].tag), HKQuantityTypeIdentifierHeartRate, [HKQuery predicateForSamplesWithStartDate:b endDate:[b dateByAddingTimeInterval:7000] options:0],
              HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDuration, @"count/min");
    }
    // Cumulative proration inside a statistics query vs. a collection bucket.
    NSDateComponents *fiveMin = [NSDateComponents new]; fiveMin.minute = 5;
    Collection(@"steps 5-min around 08:00", HKQuantityTypeIdentifierStepCount, HKStatisticsOptionCumulativeSum, fiveMin, At(0, 0, 0), At(0, 8, 0), At(0, 8, 20), @"count");
    // (the collection's "(all)" list for 5-minute buckets is long; it is printed but not needed)
    NSDateComponents *oneDay = [NSDateComponents new]; oneDay.day = 1;
    NSDateComponents *oneHour = [NSDateComponents new]; oneHour.hour = 1;
    NSDateComponents *sixHours = [NSDateComponents new]; sixHours.hour = 6;
    Collection(@"steps daily anchor D0", HKQuantityTypeIdentifierStepCount, HKStatisticsOptionCumulativeSum, oneDay, At(0, 0, 0), At(-1, 0, 0), At(3, 0, 0), @"count");
    Collection(@"steps daily anchor D0+06:00", HKQuantityTypeIdentifierStepCount, HKStatisticsOptionCumulativeSum, oneDay, At(-5, 6, 0), At(-1, 0, 0), At(3, 0, 0), @"count");
    Collection(@"steps 6-hourly", HKQuantityTypeIdentifierStepCount, HKStatisticsOptionCumulativeSum, sixHours, At(0, 0, 0), At(0, 0, 0), At(2, 0, 0), @"count");
    Collection(@"hr hourly avg", HKQuantityTypeIdentifierHeartRate, HKStatisticsOptionDiscreteAverage | HKStatisticsOptionDiscreteMin | HKStatisticsOptionDiscreteMax,
               oneHour, At(0, 0, 0), At(0, 7, 0), At(0, 14, 0), @"count/min");
    // Characteristics, sources, preferred units.
    NSError *e = nil;
    NSDateComponents *dob = [gStore dateOfBirthComponentsWithError:&e];
    P(@"auth dateOfBirth=%@ err=%@", dob, E(e)); e = nil;
    P(@"auth biologicalSex=%ld err=%@", (long)[gStore biologicalSexWithError:&e].biologicalSex, E(e)); e = nil;
    P(@"auth bloodType=%ld err=%@", (long)[gStore bloodTypeWithError:&e].bloodType, E(e)); e = nil;
    P(@"auth skinType=%ld err=%@", (long)[gStore fitzpatrickSkinTypeWithError:&e].skinType, E(e)); e = nil;
    P(@"auth wheelchair=%ld err=%@", (long)[gStore wheelchairUseWithError:&e].wheelchairUse, E(e)); e = nil;
    P(@"auth moveMode=%ld err=%@", (long)[gStore activityMoveModeWithError:&e].activityMoveMode, E(e)); e = nil;
    Wait(@"sources", 30, ^(dispatch_block_t done) {
        HKSourceQuery *q = [[HKSourceQuery alloc] initWithSampleType:QT(HKQuantityTypeIdentifierStepCount) samplePredicate:nil
            completionHandler:^(HKSourceQuery *qq, NSSet<HKSource *> *srcs, NSError *er) {
                for (HKSource *s in srcs) P(@"source %@ name=%@", s.bundleIdentifier, s.name);
                P(@"sourceQuery n=%lu err=%@", (unsigned long)srcs.count, E(er)); done(); }];
        [gStore executeQuery:q];
    });
    Wait(@"preferredUnits", 30, ^(dispatch_block_t done) {
        NSSet *ts = [NSSet setWithArray:@[QT(HKQuantityTypeIdentifierStepCount), QT(HKQuantityTypeIdentifierBodyMass), QT(HKQuantityTypeIdentifierHeight),
                                          QT(HKQuantityTypeIdentifierBodyTemperature), QT(HKQuantityTypeIdentifierDistanceWalkingRunning),
                                          QT(HKQuantityTypeIdentifierActiveEnergyBurned), QT(HKQuantityTypeIdentifierHeartRate),
                                          QT(HKQuantityTypeIdentifierDietaryEnergyConsumed), QT(HKQuantityTypeIdentifierBloodPressureSystolic)]];
        [gStore preferredUnitsForQuantityTypes:ts completion:^(NSDictionary<HKQuantityType *, HKUnit *> *m, NSError *er) {
            for (HKQuantityType *t in m) P(@"preferredUnit %@ = %@", t.identifier, m[t].unitString);
            P(@"preferredUnits n=%lu err=%@", (unsigned long)m.count, E(er)); done(); }];
    });
    @try {
        Wait(@"preferredUnits-unauthorized", 30, ^(dispatch_block_t done) {
            [gStore preferredUnitsForQuantityTypes:[NSSet setWithObject:QT(HKQuantityTypeIdentifierFlightsClimbed)] completion:^(NSDictionary *m, NSError *er) {
                P(@"preferredUnits(unrequested flights) m=%@ err=%@", m, E(er)); done(); }];
        });
    } @catch (NSException *ex) { P(@"preferredUnits(unrequested) EXCEPTION %@: %@", ex.name, ex.reason); }
    Wait(@"earliestAuthorized", 30, ^(dispatch_block_t done) {
        if (@available(iOS 27.0, *)) {
            [gStore getEarliestAuthorizedSampleDateForTypes:[NSSet setWithObject:QT(HKQuantityTypeIdentifierStepCount)] completion:^(NSDictionary *m, NSError *er) {
                P(@"earliestAuthorizedSampleDate=%@ err=%@", m, E(er)); done(); }];
        } else done();
    });

    // Anchored query + observer query + delete.
    __block HKQueryAnchor *anchor = nil;
    Wait(@"anchored-initial", 30, ^(dispatch_block_t done) {
        HKAnchoredObjectQuery *q = [[HKAnchoredObjectQuery alloc] initWithType:QT(HKQuantityTypeIdentifierStepCount) predicate:nil anchor:nil limit:HKObjectQueryNoLimit
            resultsHandler:^(HKAnchoredObjectQuery *qq, NSArray *s, NSArray *d, HKQueryAnchor *a, NSError *er) {
                anchor = a; P(@"anchored initial added=%lu deleted=%lu anchor=%@ err=%@ %@", (unsigned long)s.count, (unsigned long)d.count, a ? @"set" : @"nil", E(er), Thr()); done(); }];
        [gStore executeQuery:q];
    });
    Wait(@"anchored-limit2", 30, ^(dispatch_block_t done) {
        HKAnchoredObjectQuery *q = [[HKAnchoredObjectQuery alloc] initWithType:QT(HKQuantityTypeIdentifierStepCount) predicate:nil anchor:nil limit:2
            resultsHandler:^(HKAnchoredObjectQuery *qq, NSArray *s, NSArray *d, HKQueryAnchor *a, NSError *er) {
                NSMutableArray *v = [NSMutableArray array]; for (HKQuantitySample *x in s) [v addObject:@([x.quantity doubleValueForUnit:[HKUnit countUnit]])];
                P(@"anchored limit2 values(order)=%@", [v componentsJoinedByString:@","]); done(); }];
        [gStore executeQuery:q];
    });
    NSData *ad = [NSKeyedArchiver archivedDataWithRootObject:anchor requiringSecureCoding:YES error:nil];
    P(@"anchor archived bytes=%lu", (unsigned long)ad.length);
    @try { HKQueryAnchor *z = [HKQueryAnchor anchorFromValue:0]; P(@"anchorFromValue(0)=%@", z ? @"set" : @"nil"); } @catch (NSException *ex) { P(@"anchorFromValue EXCEPTION %@", ex.reason); }
    __block int observerCalls = 0;
    HKObserverQuery *obs = [[HKObserverQuery alloc] initWithSampleType:QT(HKQuantityTypeIdentifierStepCount) predicate:nil
        updateHandler:^(HKObserverQuery *q, HKObserverQueryCompletionHandler ch, NSError *er) {
            observerCalls++; P(@"observer call #%d err=%@ %@", observerCalls, E(er), Thr()); if (ch) ch(); }];
    [gStore executeQuery:obs];
    __block int updates = 0;
    HKAnchoredObjectQuery *live = [[HKAnchoredObjectQuery alloc] initWithType:QT(HKQuantityTypeIdentifierStepCount) predicate:nil anchor:anchor limit:HKObjectQueryNoLimit
        resultsHandler:^(HKAnchoredObjectQuery *qq, NSArray *s, NSArray *d, HKQueryAnchor *a, NSError *er) {
            P(@"live-anchored initial(from anchor) added=%lu deleted=%lu err=%@", (unsigned long)s.count, (unsigned long)d.count, E(er)); }];
    live.updateHandler = ^(HKAnchoredObjectQuery *qq, NSArray *s, NSArray *d, HKQueryAnchor *a, NSError *er) {
        updates++; P(@"live-anchored update #%d added=%lu deleted=%lu err=%@", updates, (unsigned long)s.count, (unsigned long)d.count, E(er));
        for (HKDeletedObject *x in d) P(@"  deleted uuid=%@ md=%@", x.UUID.UUIDString, x.metadata);
    };
    [gStore executeQuery:live];
    [NSThread sleepForTimeInterval:2];
    HKQuantitySample *extra = QS(HKQuantityTypeIdentifierStepCount, @"count", 7, At(0, 20, 0), At(0, 20, 1), @{HKMetadataKeySyncIdentifier: @"ycode-sync-1", HKMetadataKeySyncVersion: @1});
    CFTimeInterval t0 = CACurrentMediaTime();
    Save(@"extra(observer)", @[extra]);
    [NSThread sleepForTimeInterval:3];
    P(@"after save: observerCalls=%d liveUpdates=%d (%.2fs)", observerCalls, updates, CACurrentMediaTime() - t0);
    // Sync identifier replacement: same sync id, higher version replaces; lower version is ignored.
    Save(@"sync v2", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 8, At(0, 20, 0), At(0, 20, 1), @{HKMetadataKeySyncIdentifier: @"ycode-sync-1", HKMetadataKeySyncVersion: @2})]);
    Save(@"sync v1 again", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 9, At(0, 20, 0), At(0, 20, 1), @{HKMetadataKeySyncIdentifier: @"ycode-sync-1", HKMetadataKeySyncVersion: @1})]);
    for (HKSample *s in Samples(@"sync", QT(HKQuantityTypeIdentifierStepCount), [HKQuery predicateForObjectsWithMetadataKey:HKMetadataKeySyncIdentifier], 0, nil))
        P(@"sync result: %@ ver=%@", SampleDesc(s), s.metadata[HKMetadataKeySyncVersion]);
    @try { Save(@"sync-id without version", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 1, At(0, 21, 0), At(0, 21, 1), @{HKMetadataKeySyncIdentifier: @"x"})]); }
    @catch (NSException *ex) { P(@"sync-id without version EXCEPTION %@: %@", ex.name, ex.reason); }
    [NSThread sleepForTimeInterval:2];
    P(@"after sync saves: observerCalls=%d liveUpdates=%d", observerCalls, updates);
    NSArray *ex2 = Samples(@"extra", QT(HKQuantityTypeIdentifierStepCount), [HKQuery predicateForObjectsWithMetadataKey:HKMetadataKeySyncIdentifier], 0, nil);
    Wait(@"delete extra", 30, ^(dispatch_block_t done) {
        [gStore deleteObjects:ex2 withCompletion:^(BOOL ok, NSError *er) { P(@"deleteObjects n=%lu ok=%d err=%@", (unsigned long)ex2.count, ok, E(er)); done(); }]; });
    [NSThread sleepForTimeInterval:3];
    P(@"after delete: observerCalls=%d liveUpdates=%d", observerCalls, updates);
    Wait(@"anchored-after", 30, ^(dispatch_block_t done) {
        HKAnchoredObjectQuery *q = [[HKAnchoredObjectQuery alloc] initWithType:QT(HKQuantityTypeIdentifierStepCount) predicate:nil anchor:anchor limit:HKObjectQueryNoLimit
            resultsHandler:^(HKAnchoredObjectQuery *qq, NSArray *s, NSArray *d, HKQueryAnchor *a, NSError *er) {
                P(@"anchored since-initial added=%lu deleted=%lu err=%@", (unsigned long)s.count, (unsigned long)d.count, E(er)); done(); }];
        [gStore executeQuery:q];
    });
    [gStore stopQuery:obs]; [gStore stopQuery:live];
    Save(@"after stopQuery", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 11, At(0, 22, 0), At(0, 22, 1), nil)]);
    [NSThread sleepForTimeInterval:2];
    P(@"after stopQuery: observerCalls=%d liveUpdates=%d", observerCalls, updates);
    @try { [gStore executeQuery:obs]; P(@"re-execute stopped query: no exception"); }
    @catch (NSException *ex) { P(@"re-execute stopped query EXCEPTION %@: %@", ex.name, ex.reason); }
    // Background delivery.
    Wait(@"bg enable", 30, ^(dispatch_block_t done) {
        [gStore enableBackgroundDeliveryForType:QT(HKQuantityTypeIdentifierStepCount) frequency:HKUpdateFrequencyImmediate withCompletion:^(BOOL ok, NSError *er) {
            P(@"enableBackgroundDelivery(steps, immediate) ok=%d err=%@", ok, E(er)); done(); }]; });
    Wait(@"bg enable hourly", 30, ^(dispatch_block_t done) {
        [gStore enableBackgroundDeliveryForType:QT(HKQuantityTypeIdentifierHeartRate) frequency:HKUpdateFrequencyHourly withCompletion:^(BOOL ok, NSError *er) {
            P(@"enableBackgroundDelivery(hr, hourly) ok=%d err=%@", ok, E(er)); done(); }]; });
    Wait(@"bg disable", 30, ^(dispatch_block_t done) {
        [gStore disableBackgroundDeliveryForType:QT(HKQuantityTypeIdentifierHeartRate) withCompletion:^(BOOL ok, NSError *er) {
            P(@"disableBackgroundDelivery(hr) ok=%d err=%@", ok, E(er)); done(); }]; });
    // Delete one object by UUID; delete a non-existent object.
    NSArray *one = Samples(@"one", QT(HKQuantityTypeIdentifierBodyMass), nil, 1, @[byStart]);
    if (one.count) Wait(@"delete one", 30, ^(dispatch_block_t done) {
        [gStore deleteObject:one[0] withCompletion:^(BOOL ok, NSError *er) { P(@"deleteObject(bodyMass first) ok=%d err=%@", ok, E(er)); done(); }]; });
    if (one.count) Wait(@"delete again", 30, ^(dispatch_block_t done) {
        [gStore deleteObject:one[0] withCompletion:^(BOOL ok, NSError *er) { P(@"deleteObject(again) ok=%d err=%@", ok, E(er)); done(); }]; });
    Wait(@"delete unsaved", 30, ^(dispatch_block_t done) {
        [gStore deleteObject:QS(HKQuantityTypeIdentifierBodyMass, @"kg", 1, At(0, 1, 0), At(0, 1, 0), nil) withCompletion:^(BOOL ok, NSError *er) {
            P(@"deleteObject(never saved) ok=%d err=%@", ok, E(er)); done(); }]; });
    Wait(@"delete by predicate none", 30, ^(dispatch_block_t done) {
        [gStore deleteObjectsOfType:QT(HKQuantityTypeIdentifierStepCount) predicate:[HKQuery predicateForSamplesWithStartDate:At(-30, 0, 0) endDate:At(-29, 0, 0) options:0]
                     withCompletion:^(BOOL ok, NSUInteger n, NSError *er) { P(@"deleteObjectsOfType(empty range) ok=%d n=%lu err=%@", ok, (unsigned long)n, E(er)); done(); }]; });
    Wait(@"delete correlation", 30, ^(dispatch_block_t done) {
        [gStore deleteObjectsOfType:[HKObjectType correlationTypeForIdentifier:HKCorrelationTypeIdentifierBloodPressure] predicate:[HKQuery predicateForObjectsFromSource:[HKSource defaultSource]]
                     withCompletion:^(BOOL ok, NSUInteger n, NSError *er) { P(@"deleteObjectsOfType(bp correlation) ok=%d n=%lu err=%@", ok, (unsigned long)n, E(er)); done(); }]; });
    P(@"after correlation delete: systolic n=%lu", (unsigned long)Samples(@"sys", QT(HKQuantityTypeIdentifierBloodPressureSystolic), nil, 0, nil).count);
    CountMine(@"end-of-data");
}

#pragma mark - Phase: cross (second bundle)

static void PhaseCross(void) {
    // Bundle B saves overlapping steps, then reads statistics across both sources.
    NSPredicate *mine = [HKQuery predicateForObjectsFromSource:[HKSource defaultSource]];
    Wait(@"wipeB", 30, ^(dispatch_block_t done) {
        [gStore deleteObjectsOfType:QT(HKQuantityTypeIdentifierStepCount) predicate:mine withCompletion:^(BOOL ok, NSUInteger n, NSError *er) {
            P(@"wipeB ok=%d n=%lu err=%@", ok, (unsigned long)n, E(er)); done(); }]; });
    Save(@"B steps", @[QS(HKQuantityTypeIdentifierStepCount, @"count", 400, At(0, 8, 0), At(0, 8, 10), nil),
                       QS(HKQuantityTypeIdentifierStepCount, @"count", 900, At(0, 15, 0), At(0, 15, 10), nil)]);
    NSPredicate *day0 = [HKQuery predicateForSamplesWithStartDate:At(0, 0, 0) endDate:At(1, 0, 0) options:HKQueryOptionNone];
    Stats(@"cross steps day0 merged+bySource", HKQuantityTypeIdentifierStepCount, day0, HKStatisticsOptionCumulativeSum | HKStatisticsOptionSeparateBySource, @"count");
    Stats(@"cross steps [08:00,08:10]", HKQuantityTypeIdentifierStepCount, [HKQuery predicateForSamplesWithStartDate:At(0, 8, 0) endDate:At(0, 8, 10) options:0],
          HKStatisticsOptionCumulativeSum | HKStatisticsOptionSeparateBySource, @"count");
    Stats(@"cross hr day0 (read A's)", HKQuantityTypeIdentifierHeartRate, day0, HKStatisticsOptionDiscreteAverage | HKStatisticsOptionSeparateBySource, @"count/min");
    for (HKSample *s in Samples(@"cross all steps", QT(HKQuantityTypeIdentifierStepCount), day0, 0, @[[NSSortDescriptor sortDescriptorWithKey:HKSampleSortIdentifierStartDate ascending:YES]]))
        P(@"cross steps: %@ src=%@", SampleDesc(s), s.sourceRevision.source.bundleIdentifier);
    NSDateComponents *oneHour = [NSDateComponents new]; oneHour.hour = 1;
    Collection(@"cross steps hourly", HKQuantityTypeIdentifierStepCount, HKStatisticsOptionCumulativeSum | HKStatisticsOptionSeparateBySource, oneHour, At(0, 0, 0), At(0, 7, 0), At(0, 16, 0), @"count");
    NSArray *other = Samples(@"A's steps", QT(HKQuantityTypeIdentifierStepCount), [NSCompoundPredicate notPredicateWithSubpredicate:mine], 1, nil);
    if (other.count) Wait(@"delete A's", 30, ^(dispatch_block_t done) {
        [gStore deleteObject:other[0] withCompletion:^(BOOL ok, NSError *er) { P(@"B deletes A's sample ok=%d err=%@", ok, E(er)); done(); }]; });
    Wait(@"sources", 30, ^(dispatch_block_t done) {
        HKSourceQuery *q = [[HKSourceQuery alloc] initWithSampleType:QT(HKQuantityTypeIdentifierStepCount) samplePredicate:nil
            completionHandler:^(HKSourceQuery *qq, NSSet<HKSource *> *srcs, NSError *er) {
                for (HKSource *s in srcs) P(@"cross source %@ name=%@", s.bundleIdentifier, s.name); done(); }];
        [gStore executeQuery:q];
    });
}

#pragma mark - Phase: session

@interface SessDel : NSObject <HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate>
@end
@implementation SessDel
- (void)workoutSession:(HKWorkoutSession *)s didChangeToState:(HKWorkoutSessionState)to fromState:(HKWorkoutSessionState)from date:(NSDate *)d {
    P(@"session state %ld -> %ld %@", (long)from, (long)to, Thr());
}
- (void)workoutSession:(HKWorkoutSession *)s didFailWithError:(NSError *)e { P(@"session didFail %@", E(e)); }
- (void)workoutBuilder:(HKLiveWorkoutBuilder *)b didCollectDataOfTypes:(NSSet<HKSampleType *> *)types { P(@"live builder collected %@", types); }
- (void)workoutBuilderDidCollectEvent:(HKLiveWorkoutBuilder *)b { P(@"live builder event"); }
@end

static void PhaseSession(void) {
    if (@available(iOS 26.0, *)) {
        HKWorkoutConfiguration *cfg = [HKWorkoutConfiguration new];
        cfg.activityType = HKWorkoutActivityTypeWalking; cfg.locationType = HKWorkoutSessionLocationTypeIndoor;
        NSError *e = nil;
        HKWorkoutSession *s = [[HKWorkoutSession alloc] initWithHealthStore:gStore configuration:cfg error:&e];
        P(@"workoutSession init=%@ err=%@ state=%ld type=%ld", s ? @"set" : @"nil", E(e), (long)s.state, (long)s.type);
        if (!s) return;
        static SessDel *del; del = [SessDel new];
        s.delegate = del;
        HKLiveWorkoutBuilder *lb = [s associatedWorkoutBuilder];
        lb.delegate = del;
        lb.dataSource = [[HKLiveWorkoutDataSource alloc] initWithHealthStore:gStore workoutConfiguration:cfg];
        P(@"live builder=%@ typesToCollect=%lu", lb ? @"set" : @"nil", (unsigned long)lb.dataSource.typesToCollect.count);
        [s startActivityWithDate:[NSDate date]];
        Wait(@"live begin", 30, ^(dispatch_block_t done) {
            [lb beginCollectionWithStartDate:[NSDate date] completion:^(BOOL ok, NSError *er) { P(@"live begin ok=%d err=%@", ok, E(er)); done(); }]; });
        [NSThread sleepForTimeInterval:5];
        P(@"session after 5s state=%ld elapsed=%.1f", (long)s.state, lb.elapsedTime);
        [s pause]; [NSThread sleepForTimeInterval:1]; [s resume]; [NSThread sleepForTimeInterval:1];
        [s stopActivityWithDate:[NSDate date]]; [NSThread sleepForTimeInterval:1];
        [s end]; [NSThread sleepForTimeInterval:1];
        Wait(@"live end", 30, ^(dispatch_block_t done) {
            [lb endCollectionWithEndDate:[NSDate date] completion:^(BOOL ok, NSError *er) { P(@"live end ok=%d err=%@", ok, E(er)); done(); }]; });
        Wait(@"live finish", 30, ^(dispatch_block_t done) {
            [lb finishWorkoutWithCompletion:^(HKWorkout *w, NSError *er) { P(@"live finish workout=%@ duration=%.1f err=%@", w ? @"set" : @"nil", w.duration, E(er)); done(); }]; });
        Wait(@"recover", 30, ^(dispatch_block_t done) {
            [gStore recoverActiveWorkoutSessionWithCompletion:^(HKWorkoutSession *rs, NSError *er) { P(@"recoverActiveWorkoutSession=%@ err=%@", rs ? @"set" : @"nil", E(er)); done(); }]; });
    }
}

#pragma mark - Phase: clinical

static void PhaseClinical(void) {
    P(@"supportsHealthRecords=%d", [gStore supportsHealthRecords]);
    NSMutableSet *read = [NSMutableSet set];
    for (NSString *i in @[HKClinicalTypeIdentifierAllergyRecord, HKClinicalTypeIdentifierLabResultRecord, HKClinicalTypeIdentifierMedicationRecord])
        [read addObject:[HKObjectType clinicalTypeForIdentifier:i]];
    for (HKObjectType *t in read) P(@"clinical status %@=%ld", t.identifier, (long)[gStore authorizationStatusForType:t]);
    Wait(@"clinical reqstatus", 15, ^(dispatch_block_t done) {
        @try {
            [gStore getRequestStatusForAuthorizationToShareTypes:[NSSet set] readTypes:read completion:^(HKAuthorizationRequestStatus s, NSError *e) {
                P(@"clinical requestStatus=%ld err=%@", (long)s, E(e)); done(); }];
        } @catch (NSException *ex) { P(@"clinical requestStatus EXCEPTION %@: %@", ex.name, ex.reason); done(); }
    });
    Wait(@"clinical query", 15, ^(dispatch_block_t done) {
        HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:[HKObjectType clinicalTypeForIdentifier:HKClinicalTypeIdentifierLabResultRecord] predicate:nil limit:0
            sortDescriptors:nil resultsHandler:^(HKSampleQuery *qq, NSArray *r, NSError *er) { P(@"clinical query n=%@ err=%@", r ? @(r.count) : @"nil", E(er)); done(); }];
        [gStore executeQuery:q];
    });
    Wait(@"medications query", 15, ^(dispatch_block_t done) {
        if (@available(iOS 26.0, *)) {
            HKUserAnnotatedMedicationQuery *q = [[HKUserAnnotatedMedicationQuery alloc] initWithPredicate:nil limit:0
                resultsHandler:^(HKUserAnnotatedMedicationQuery *qq, HKUserAnnotatedMedication *m, BOOL fin, NSError *er) {
                    P(@"medications query item=%@ done=%d err=%@", m ? @"set" : @"nil", fin, E(er)); if (fin || er) done(); }];
            [gStore executeQuery:q];
        } else done();
    });
    Wait(@"verifiable query", 15, ^(dispatch_block_t done) {
        HKVerifiableClinicalRecordQuery *q = [[HKVerifiableClinicalRecordQuery alloc] initWithRecordTypes:@[@"https://smarthealth.cards#immunization"] predicate:nil
            resultsHandler:^(HKVerifiableClinicalRecordQuery *qq, NSArray *r, NSError *er) { P(@"verifiable query n=%@ err=%@", r ? @(r.count) : @"nil", E(er)); done(); }];
        [gStore executeQuery:q];
    });
    RequestAuth(@"clinical", nil, read);
}

#pragma mark - App

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor systemTealColor];
    UILabel *l = [UILabel new]; l.text = @"HealthProbe"; l.frame = CGRectMake(40, 120, 300, 40); [vc.view addSubview:l];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    P(@"scene connected");
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    NSString *phase = [[NSUserDefaults standardUserDefaults] stringForKey:@"phase"] ?: @"basic";
    P(@"launch phase=%@ bundle=%@ entitlementsProbe", phase, [NSBundle mainBundle].bundleIdentifier);
    gStore = [HKHealthStore new];
    dispatch_queue_t q = dispatch_queue_create("dev.ycode.healthprobe.runner", DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), q, ^{
        @try {
            if ([phase isEqualToString:@"basic"]) PhaseBasic();
            else if ([phase isEqualToString:@"auth"]) RequestAuth(@"auth", ShareSet(), ReadSet());
            else if ([phase isEqualToString:@"authb"]) RequestAuth(@"authb", [NSSet setWithObject:QT(HKQuantityTypeIdentifierStepCount)],
                [NSSet setWithObjects:QT(HKQuantityTypeIdentifierStepCount), QT(HKQuantityTypeIdentifierHeartRate), nil]);
            else if ([phase isEqualToString:@"status"]) PrintStatus(@"status");
            else if ([phase isEqualToString:@"data"]) PhaseData();
            else if ([phase isEqualToString:@"count"]) CountMine(@"count");
            else if ([phase isEqualToString:@"cross"]) PhaseCross();
            else if ([phase isEqualToString:@"session"]) PhaseSession();
            else if ([phase isEqualToString:@"clinical"]) PhaseClinical();
            else if ([phase isEqualToString:@"wipe"]) Wipe();
        } @catch (NSException *ex) { P(@"PHASE EXCEPTION %@: %@", ex.name, ex.reason); }
        P(@"phase %@ DONE", phase);
    });
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = [SceneDelegate class];
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gStart = CACurrentMediaTime();
        gUTC = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        gUTC.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        NSDateComponents *c = [NSDateComponents new]; c.year = 2026; c.month = 10; c.day = 1;
        gD0 = [gUTC dateFromComponents:c];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
