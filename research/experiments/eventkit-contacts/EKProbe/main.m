// EKProbe: our own black-box probe of EventKit / EventKitUI in the iOS simulator.
// Written for Ycode's clean-room specs (specs/frameworks/eventkit/). Uses only
// public API and made-up data. Output: one line per observation on stderr,
// prefixed "EKPROBE", ending with "phase <p> DONE".
//
//   -phase basic     no access needed: status, enum values, rule descriptions,
//                    exceptions, errors before authorization
//   -phase reqfull   requestFullAccessToEvents (system prompt)
//   -phase reqwo     requestWriteOnlyAccessToEvents (system prompt)
//   -phase reqrem    requestFullAccessToReminders (system prompt)
//   -phase reqlegacy requestAccessToEntityType: (deprecated; events then reminders)
//   -phase status    statuses only
//   -phase events    (full access) sources, calendars, CRUD, recurrence
//                    expansion, exceptions, time zones, alarms, notifications,
//                    errors
//   -phase reminders (reminder access) lists, CRUD, predicates, recurrence
//   -phase wo        (write-only access) what a write-only client sees
//   -phase count     count the probe's items (persistence check)
//   -phase wipe      delete the probe's calendars
//   -phase uiedit    present EKEventEditViewController (no access needed)
//   -phase uiview    present EKEventViewController for a probe event
//   -phase uichooser present EKCalendarChooser
#import <UIKit/UIKit.h>
#import <EventKit/EventKit.h>
#import <EventKitUI/EventKitUI.h>
#import <CoreLocation/CoreLocation.h>
#import <QuartzCore/QuartzCore.h>

static CFTimeInterval gStart;
static EKEventStore *gStore;
static UIViewController *gRoot;
static int gChanges;
static NSString *const kCal = @"Ycode Probe";
static NSString *const kList = @"Ycode Probe List";

static void P(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void P(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    fprintf(stderr, "EKPROBE t=%.3f %s\n", CACurrentMediaTime() - gStart, s.UTF8String);
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

static void Wait(NSString *what, double secs, void (^body)(dispatch_block_t done)) {
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    body(^{ dispatch_semaphore_signal(s); });
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC))))
        P(@"%@ TIMEOUT after %.0fs (no callback)", what, secs);
}

static void Sleep(double s) { [NSThread sleepForTimeInterval:s]; }

static NSString *U(NSDate *d) { // UTC ISO 8601
    if (!d) return @"nil";
    static NSISO8601DateFormatter *f;
    if (!f) { f = [NSISO8601DateFormatter new]; f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; }
    return [f stringFromDate:d];
}
static NSString *Z(NSDate *d, NSTimeZone *tz) { // wall time in a zone
    if (!d) return @"nil";
    if (!tz) return U(d);
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = tz;
    f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ EEE";
    return [f stringFromDate:d];
}
static NSDate *At(NSString *tzName, int y, int mo, int d, int h, int mi) {
    NSCalendar *c = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    c.timeZone = tzName ? [NSTimeZone timeZoneWithName:tzName] : [NSTimeZone defaultTimeZone];
    NSDateComponents *k = [NSDateComponents new];
    k.year = y; k.month = mo; k.day = d; k.hour = h; k.minute = mi;
    return [c dateFromComponents:k];
}
static NSString *DC(NSDateComponents *c) {
    if (!c) return @"nil";
    NSMutableString *s = [NSMutableString string];
    if (c.calendar) [s appendFormat:@"cal=%@ ", c.calendar.calendarIdentifier];
    if (c.timeZone) [s appendFormat:@"tz=%@ ", c.timeZone.name];
    [s appendFormat:@"%ld-%ld-%ld", (long)c.year, (long)c.month, (long)c.day];
    if (c.hour != NSDateComponentUndefined) [s appendFormat:@" %ld:%02ld", (long)c.hour, (long)c.minute];
    if (c.second != NSDateComponentUndefined) [s appendFormat:@":%02ld", (long)c.second];
    return s;
}
static NSString *Strip(NSString *d) { // remove pointers from -description
    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+" options:0 error:nil];
    return [r stringByReplacingMatchesInString:d options:0 range:NSMakeRange(0, d.length) withTemplate:@"0x…"];
}
static NSString *Rule(EKRecurrenceRule *r) { return r ? Strip(r.description) : @"nil"; }
static NSString *ColorS(CGColorRef c) {
    if (!c) return @"nil";
    const CGFloat *v = CGColorGetComponents(c);
    size_t n = CGColorGetNumberOfComponents(c);
    NSMutableArray *a = [NSMutableArray array];
    for (size_t i = 0; i < n; i++) [a addObject:[NSString stringWithFormat:@"%.4f", v[i]]];
    CGColorSpaceRef sp = CGColorGetColorSpace(c);
    NSString *spn = sp ? (__bridge_transfer NSString *)CGColorSpaceCopyName(sp) : @"?";
    return [NSString stringWithFormat:@"%@(%@)", spn, [a componentsJoinedByString:@","]];
}

static void Status(NSString *tag) {
    P(@"%@ status events=%ld reminders=%ld", tag, (long)[EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent],
      (long)[EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder]);
}

static void Sources(NSString *tag) {
    P(@"%@ eventStoreIdentifier=%@", tag, gStore.eventStoreIdentifier);
    NSArray *src = [gStore.sources sortedArrayUsingComparator:^NSComparisonResult(EKSource *a, EKSource *b) { return [a.title compare:b.title]; }];
    P(@"%@ sources n=%lu delegateSources n=%lu", tag, (unsigned long)src.count, (unsigned long)gStore.delegateSources.count);
    for (EKSource *s in src)
        P(@"%@ source title=\"%@\" type=%ld id=%@ isDelegate=%d calendars(events)=%lu calendars(reminders)=%lu", tag, s.title, (long)s.sourceType,
          s.sourceIdentifier, s.isDelegate, (unsigned long)[s calendarsForEntityType:EKEntityTypeEvent].count,
          (unsigned long)[s calendarsForEntityType:EKEntityTypeReminder].count);
    for (NSNumber *et in @[ @(EKEntityTypeEvent), @(EKEntityTypeReminder) ]) {
        NSArray *cals = [[gStore calendarsForEntityType:et.integerValue] sortedArrayUsingComparator:^NSComparisonResult(EKCalendar *a, EKCalendar *b) { return [a.title compare:b.title]; }];
        P(@"%@ calendarsForEntityType(%@) n=%lu", tag, et, (unsigned long)cals.count);
        for (EKCalendar *c in cals)
            P(@"%@ calendar entity=%@ title=\"%@\" type=%ld source=\"%@\" id=%@ allowsMod=%d subscribed=%d immutable=%d avail=%lu entities=%lu color=%@",
              tag, et, c.title, (long)c.type, c.source.title, c.calendarIdentifier, c.allowsContentModifications, c.isSubscribed,
              c.isImmutable, (unsigned long)c.supportedEventAvailabilities, (unsigned long)c.allowedEntityTypes, ColorS(c.CGColor));
    }
    EKCalendar *de = gStore.defaultCalendarForNewEvents, *dr = gStore.defaultCalendarForNewReminders;
    P(@"%@ defaultCalendarForNewEvents=\"%@\" id=%@ type=%ld", tag, de.title, de.calendarIdentifier, (long)de.type);
    P(@"%@ defaultCalendarForNewReminders=\"%@\" id=%@ type=%ld", tag, dr.title, dr.calendarIdentifier, (long)dr.type);
}

static EKSource *LocalSource(void) {
    for (EKSource *s in gStore.sources) if (s.sourceType == EKSourceTypeLocal) return s;
    return gStore.defaultCalendarForNewEvents.source;
}

static EKCalendar *ProbeCalendar(EKEntityType et, NSString *title, BOOL create) {
    for (EKCalendar *c in [gStore calendarsForEntityType:et]) if ([c.title isEqualToString:title]) return c;
    if (!create) return nil;
    EKCalendar *c = [EKCalendar calendarForEntityType:et eventStore:gStore];
    c.title = title;
    EKSource *src = (et == EKEntityTypeReminder) ? gStore.defaultCalendarForNewReminders.source : LocalSource();
    c.source = src;
    NSError *e = nil;
    BOOL ok = [gStore saveCalendar:c commit:YES error:&e];
    P(@"create calendar entity=%ld title=\"%@\" source=\"%@\"(type %ld) ok=%d err=%@ id=%@ color=%@", (long)et, title, src.title,
      (long)src.sourceType, ok, E(e), c.calendarIdentifier, ColorS(c.CGColor));
    return ok ? c : nil;
}

static NSString *EvDesc(EKEvent *e) {
    return [NSString stringWithFormat:@"\"%@\" start=%@ end=%@ allDay=%d tz=%@ startZ=%@ endZ=%@ occ=%@ detached=%d rules=%lu",
            e.title, U(e.startDate), U(e.endDate), e.allDay, e.timeZone.name ?: @"nil(floating)", Z(e.startDate, e.timeZone),
            Z(e.endDate, e.timeZone), U(e.occurrenceDate), e.isDetached, (unsigned long)e.recurrenceRules.count];
}

static NSArray<EKEvent *> *Fetch(NSString *tag, NSDate *s, NSDate *e, NSArray *cals, NSString *titlePrefix) {
    NSPredicate *p = [gStore predicateForEventsWithStartDate:s endDate:e calendars:cals];
    NSArray *ev = [gStore eventsMatchingPredicate:p];
    NSMutableArray *out = [NSMutableArray array];
    for (EKEvent *x in ev) if (!titlePrefix || [x.title hasPrefix:titlePrefix]) [out addObject:x];
    [out sortUsingComparator:^NSComparisonResult(EKEvent *a, EKEvent *b) {
        NSComparisonResult r = [a.startDate compare:b.startDate];
        return r != NSOrderedSame ? r : [a.title compare:b.title];
    }];
    P(@"%@ fetch [%@, %@) prefix=%@ n=%lu (unfiltered %lu)", tag, U(s), U(e), titlePrefix ?: @"*", (unsigned long)out.count, (unsigned long)ev.count);
    return out;
}

static void Expand(NSString *tag, EKCalendar *cal, NSString *title, NSDate *s, NSDate *e) {
    NSArray *ev = Fetch(tag, s, e, @[ cal ], title);
    int i = 0;
    for (EKEvent *x in ev) {
        if (![x.title isEqualToString:title]) continue;
        P(@"%@ #%d %@ startZ=%@", tag, ++i, U(x.startDate), Z(x.startDate, x.timeZone));
    }
}

static BOOL SaveEv(NSString *tag, EKEvent *ev, EKSpan span) {
    NSError *e = nil;
    BOOL ok = [gStore saveEvent:ev span:span commit:YES error:&e];
    P(@"%@ save span=%ld ok=%d err=%@ id=%@ calItemId=%@ extId=%@", tag, (long)span, ok, E(e), ev.eventIdentifier, ev.calendarItemIdentifier,
      ev.calendarItemExternalIdentifier);
    return ok;
}

static EKEvent *NewEv(EKCalendar *cal, NSString *title, NSDate *s, NSDate *e, NSString *tz) {
    EKEvent *ev = [EKEvent eventWithEventStore:gStore];
    ev.calendar = cal; ev.title = title; ev.startDate = s; ev.endDate = e;
    if (tz) ev.timeZone = [NSTimeZone timeZoneWithName:tz];
    return ev;
}

static EKRecurrenceRule *RR(EKRecurrenceFrequency f, NSInteger iv, NSArray *dow, NSArray *dom, NSArray *moy, NSArray *woy, NSArray *doy, NSArray *pos,
                            EKRecurrenceEnd *end) {
    return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:f interval:iv daysOfTheWeek:dow daysOfTheMonth:dom monthsOfTheYear:moy
                                                 weeksOfTheYear:woy daysOfTheYear:doy setPositions:pos end:end];
}
static EKRecurrenceDayOfWeek *DOW(EKWeekday d, NSInteger wk) { return [EKRecurrenceDayOfWeek dayOfWeek:d weekNumber:wk]; }

#pragma mark - basic

static void TryRule(NSString *tag, EKRecurrenceRule * (^make)(void)) {
    @try {
        EKRecurrenceRule *r = make();
        P(@"rule %@ -> %@ freq=%ld interval=%ld firstDay=%ld end=%@", tag, Rule(r), (long)r.frequency, (long)r.interval, (long)r.firstDayOfTheWeek,
          r.recurrenceEnd ? [NSString stringWithFormat:@"{date=%@ count=%lu}", U(r.recurrenceEnd.endDate), (unsigned long)r.recurrenceEnd.occurrenceCount] : @"nil");
    } @catch (NSException *ex) { P(@"rule %@ EXCEPTION %@: %@", tag, ex.name, ex.reason); }
}

static void PhaseBasic(void) {
    Status(@"basic");
    P(@"EKErrorDomain=%@ EKEventStoreChangedNotification=%@", EKErrorDomain, EKEventStoreChangedNotification);
    Sources(@"basic-noaccess");
    // Errors before access.
    EKEvent *ev = [EKEvent eventWithEventStore:gStore];
    ev.title = @"Probe unauthorized"; ev.startDate = At(@"UTC", 2026, 10, 5, 9, 0); ev.endDate = At(@"UTC", 2026, 10, 5, 10, 0);
    ev.calendar = gStore.defaultCalendarForNewEvents;
    P(@"noaccess new event calendar=%@ timeZone=%@ allDay=%d availability=%ld status=%ld isNew=%d hasChanges=%d", ev.calendar.title, ev.timeZone.name,
      ev.allDay, (long)ev.availability, (long)ev.status, ev.isNew, ev.hasChanges);
    SaveEv(@"noaccess", ev, EKSpanThisEvent);
    NSArray *f = [gStore eventsMatchingPredicate:[gStore predicateForEventsWithStartDate:At(@"UTC", 2020, 1, 1, 0, 0) endDate:At(@"UTC", 2024, 1, 1, 0, 0) calendars:nil]];
    P(@"noaccess events fetch n=%lu", (unsigned long)f.count);
    Wait(@"noaccess reminders fetch", 20, ^(dispatch_block_t done) {
        [gStore fetchRemindersMatchingPredicate:[gStore predicateForRemindersInCalendars:nil] completion:^(NSArray *r) {
            P(@"noaccess reminders fetch n=%@ %@", r ? @(r.count) : @"nil", Thr()); done();
        }];
    });
    EKCalendar *c = [EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:gStore];
    c.title = @"Probe unauthorized";
    NSError *e = nil;
    BOOL ok = [gStore saveCalendar:c commit:YES error:&e];
    P(@"noaccess saveCalendar ok=%d err=%@", ok, E(e));
    P(@"new calendar defaults: type=%ld source=%@ allowsMod=%d color=%@ entities=%lu id=%@", (long)c.type, c.source.title, c.allowsContentModifications,
      ColorS(c.CGColor), (unsigned long)c.allowedEntityTypes, c.calendarIdentifier);

    // Recurrence rule descriptions (no store needed).
    NSDate *until = At(@"UTC", 2026, 12, 31, 23, 59);
    TryRule(@"daily", ^{ return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1 end:nil]; });
    TryRule(@"daily/2 count 5", ^{ return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:2
                                                                                        end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:5]]; });
    TryRule(@"weekly until", ^{ return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyWeekly interval:1
                                                                                     end:[EKRecurrenceEnd recurrenceEndWithEndDate:until]]; });
    TryRule(@"weekly MO,WE,FR", ^{ return RR(EKRecurrenceFrequencyWeekly, 1, @[ DOW(EKWeekdayMonday, 0), DOW(EKWeekdayWednesday, 0), DOW(EKWeekdayFriday, 0) ], nil, nil, nil, nil, nil, nil); });
    TryRule(@"monthly 1,15,-1", ^{ return RR(EKRecurrenceFrequencyMonthly, 1, nil, @[ @1, @15, @-1 ], nil, nil, nil, nil, nil); });
    TryRule(@"monthly -1FR", ^{ return RR(EKRecurrenceFrequencyMonthly, 1, @[ DOW(EKWeekdayFriday, -1) ], nil, nil, nil, nil, nil, nil); });
    TryRule(@"monthly 2TU", ^{ return RR(EKRecurrenceFrequencyMonthly, 1, @[ DOW(EKWeekdayTuesday, 2) ], nil, nil, nil, nil, nil, nil); });
    TryRule(@"monthly weekdays setpos -2", ^{ return RR(EKRecurrenceFrequencyMonthly, 1, @[ DOW(2, 0), DOW(3, 0), DOW(4, 0), DOW(5, 0), DOW(6, 0) ], nil, nil, nil, nil, @[ @-2 ], nil); });
    TryRule(@"yearly months 3,9", ^{ return RR(EKRecurrenceFrequencyYearly, 1, nil, nil, @[ @3, @9 ], nil, nil, nil, nil); });
    TryRule(@"yearly weekno 20 MO", ^{ return RR(EKRecurrenceFrequencyYearly, 1, @[ DOW(EKWeekdayMonday, 0) ], nil, nil, @[ @20 ], nil, nil, nil); });
    TryRule(@"yearly yearday 100,-1", ^{ return RR(EKRecurrenceFrequencyYearly, 1, nil, nil, nil, nil, @[ @100, @-1 ], nil, nil); });
    TryRule(@"yearly 4th TH Nov", ^{ return RR(EKRecurrenceFrequencyYearly, 1, @[ DOW(EKWeekdayThursday, 4) ], nil, @[ @11 ], nil, nil, nil, nil); });
    TryRule(@"interval 0", ^{ return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:0 end:nil]; });
    TryRule(@"interval -1", ^{ return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:-1 end:nil]; });
    TryRule(@"count 0", ^{ return [[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1
                                                                                  end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:0]]; });
    TryRule(@"daily with BYDAY", ^{ return RR(EKRecurrenceFrequencyDaily, 1, @[ DOW(EKWeekdayMonday, 0) ], nil, nil, nil, nil, nil, nil); });
    TryRule(@"weekly with BYMONTHDAY", ^{ return RR(EKRecurrenceFrequencyWeekly, 1, nil, @[ @3 ], nil, nil, nil, nil, nil); });
    TryRule(@"monthly with BYWEEKNO", ^{ return RR(EKRecurrenceFrequencyMonthly, 1, nil, nil, nil, @[ @3 ], nil, nil, nil); });
    TryRule(@"monthly day 32", ^{ return RR(EKRecurrenceFrequencyMonthly, 1, nil, @[ @32 ], nil, nil, nil, nil, nil); });
    TryRule(@"yearly month 13", ^{ return RR(EKRecurrenceFrequencyYearly, 1, nil, nil, @[ @13 ], nil, nil, nil, nil); });
    TryRule(@"weekday 9", ^{ return RR(EKRecurrenceFrequencyWeekly, 1, @[ [EKRecurrenceDayOfWeek dayOfWeek:9] ], nil, nil, nil, nil, nil, nil); });
    TryRule(@"weekly 2MO (weeknumber in weekly)", ^{ return RR(EKRecurrenceFrequencyWeekly, 1, @[ DOW(EKWeekdayMonday, 2) ], nil, nil, nil, nil, nil, nil); });
    TryRule(@"setpos 0", ^{ return RR(EKRecurrenceFrequencyMonthly, 1, @[ DOW(2, 0) ], nil, nil, nil, nil, @[ @0 ], nil); });
    @try {
        EKRecurrenceDayOfWeek *d = [EKRecurrenceDayOfWeek dayOfWeek:EKWeekdaySunday weekNumber:-1];
        P(@"dayOfWeek desc=%@ day=%ld wk=%ld", Strip(d.description), (long)d.dayOfTheWeek, (long)d.weekNumber);
        EKRecurrenceDayOfWeek *d2 = [EKRecurrenceDayOfWeek dayOfWeek:EKWeekdaySunday weekNumber:60];
        P(@"dayOfWeek wk=60 desc=%@", Strip(d2.description));
    } @catch (NSException *ex) { P(@"dayOfWeek EXCEPTION %@: %@", ex.name, ex.reason); }
    @try {
        EKRecurrenceEnd *re = [EKRecurrenceEnd recurrenceEndWithEndDate:until];
        P(@"recurrenceEnd date desc=%@ count=%lu", Strip(re.description), (unsigned long)re.occurrenceCount);
    } @catch (NSException *ex) { P(@"recurrenceEnd EXCEPTION %@: %@", ex.name, ex.reason); }
    // Alarm descriptions.
    EKAlarm *a1 = [EKAlarm alarmWithRelativeOffset:-900];
    EKAlarm *a2 = [EKAlarm alarmWithAbsoluteDate:At(@"UTC", 2026, 10, 5, 8, 0)];
    P(@"alarm relative offset=%.0f abs=%@ proximity=%ld", a1.relativeOffset, U(a1.absoluteDate), (long)a1.proximity);
    P(@"alarm absolute offset=%.0f abs=%@", a2.relativeOffset, U(a2.absoluteDate));
    a1.absoluteDate = At(@"UTC", 2026, 10, 5, 7, 0);
    P(@"alarm relative after setting absoluteDate: offset=%.0f abs=%@", a1.relativeOffset, U(a1.absoluteDate));
    a2.relativeOffset = -60;
    P(@"alarm absolute after setting relativeOffset: offset=%.0f abs=%@", a2.relativeOffset, U(a2.absoluteDate));
    EKStructuredLocation *loc = [EKStructuredLocation locationWithTitle:@"Probe Park"];
    loc.geoLocation = [[CLLocation alloc] initWithLatitude:40.0 longitude:-75.0];
    loc.radius = 150;
    P(@"structuredLocation title=%@ lat=%.4f lon=%.4f radius=%.0f", loc.title, loc.geoLocation.coordinate.latitude, loc.geoLocation.coordinate.longitude, loc.radius);
    // Event model defaults.
    EKEvent *e2 = [EKEvent eventWithEventStore:gStore];
    P(@"fresh event: title=%@ start=%@ end=%@ tz=%@ allDay=%d calendar=%@ uuid-nonnil=%d calItemId-nonnil=%d eventId=%@", e2.title, U(e2.startDate),
      U(e2.endDate), e2.timeZone.name, e2.allDay, e2.calendar.title, e2.UUID != nil, e2.calendarItemIdentifier != nil, e2.eventIdentifier);
    EKReminder *r = [EKReminder reminderWithEventStore:gStore];
    P(@"fresh reminder: title=%@ due=%@ start=%@ completed=%d priority=%lu tz=%@ calendar=%@", r.title, DC(r.dueDateComponents),
      DC(r.startDateComponents), r.completed, (unsigned long)r.priority, r.timeZone.name, r.calendar.title);
    r.completed = YES;
    P(@"reminder completed=YES -> completionDate set=%d", r.completionDate != nil);
    r.completionDate = nil;
    P(@"reminder completionDate=nil -> completed=%d", r.completed);
    @try { r.priority = 10; P(@"reminder priority 10 accepted (value %lu)", (unsigned long)r.priority); }
    @catch (NSException *ex) { P(@"reminder priority 10 EXCEPTION %@: %@", ex.name, ex.reason); }
    // Predicates.
    NSPredicate *p = [gStore predicateForEventsWithStartDate:At(@"UTC", 2026, 1, 1, 0, 0) endDate:At(@"UTC", 2036, 1, 1, 0, 0) calendars:nil];
    P(@"event predicate (10y) desc=%@", Strip(p.description));
    P(@"reminder predicates: %@ | %@ | %@", Strip([gStore predicateForRemindersInCalendars:nil].description),
      Strip([gStore predicateForIncompleteRemindersWithDueDateStarting:nil ending:nil calendars:nil].description),
      Strip([gStore predicateForCompletedRemindersWithCompletionDateStarting:nil ending:nil calendars:nil].description));
}

#pragma mark - requests

static void Request(NSString *kind) {
    Status([@"before " stringByAppendingString:kind]);
    __block CFTimeInterval t0 = CACurrentMediaTime();
    void (^h)(BOOL, NSError *) = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    h = ^(BOOL granted, NSError *e) {
        P(@"%@ completion granted=%d err=%@ after %.1fs %@", kind, granted, E(e), CACurrentMediaTime() - t0, Thr());
        dispatch_semaphore_signal(s);
    };
    @try {
        if ([kind isEqualToString:@"reqfull"]) [gStore requestFullAccessToEventsWithCompletion:h];
        else if ([kind isEqualToString:@"reqwo"]) [gStore requestWriteOnlyAccessToEventsWithCompletion:h];
        else if ([kind isEqualToString:@"reqrem"]) [gStore requestFullAccessToRemindersWithCompletion:h];
        else if ([kind isEqualToString:@"reqlegacy"]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [gStore requestAccessToEntityType:EKEntityTypeEvent completion:h];
            dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_SEC));
            Status(@"legacy after events");
            t0 = CACurrentMediaTime();
            [gStore requestAccessToEntityType:EKEntityTypeReminder completion:h];
#pragma clang diagnostic pop
        }
    } @catch (NSException *ex) { P(@"%@ EXCEPTION %@: %@", kind, ex.name, ex.reason); return; }
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_SEC))) P(@"%@ TIMEOUT", kind);
    Status([@"after " stringByAppendingString:kind]);
}

#pragma mark - events

static void Wipe(void) {
    for (NSNumber *et in @[ @(EKEntityTypeEvent), @(EKEntityTypeReminder) ])
        for (EKCalendar *c in [gStore calendarsForEntityType:et.integerValue])
            if ([c.title hasPrefix:@"Ycode Probe"]) {
                NSError *e = nil;
                BOOL ok = [gStore removeCalendar:c commit:YES error:&e];
                P(@"wipe calendar \"%@\" ok=%d err=%@", c.title, ok, E(e));
            }
}

static void Errors(EKCalendar *cal) {
    NSDate *s = At(@"America/New_York", 2026, 10, 6, 9, 0), *e = At(@"America/New_York", 2026, 10, 6, 10, 0);
    EKEvent *x = NewEv(nil, @"Probe err nocal", s, e, @"America/New_York");
    SaveEv(@"err no-calendar", x, EKSpanThisEvent);
    x = NewEv(cal, @"Probe err nostart", nil, e, nil); SaveEv(@"err no-start", x, EKSpanThisEvent);
    x = NewEv(cal, @"Probe err noend", s, nil, nil); SaveEv(@"err no-end", x, EKSpanThisEvent);
    x = NewEv(cal, @"Probe err inverted", e, s, nil); SaveEv(@"err inverted", x, EKSpanThisEvent);
    x = NewEv(cal, @"Probe err equal", s, s, nil); SaveEv(@"err zero-duration", x, EKSpanThisEvent);
    if (x.eventIdentifier) [gStore removeEvent:x span:EKSpanThisEvent commit:YES error:nil];
    x = NewEv(cal, @"Probe err dur>rec", s, [s dateByAddingTimeInterval:25 * 3600], nil);
    [x addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3]]];
    SaveEv(@"err duration>recurrence", x, EKSpanThisEvent);
    x = NewEv(cal, @"Probe err alarm>rec", s, e, nil);
    [x addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3]]];
    [x addAlarm:[EKAlarm alarmWithRelativeOffset:-3 * 86400]];
    SaveEv(@"err alarm>recurrence", x, EKSpanThisEvent);
    if (x.eventIdentifier) [gStore removeEvent:x span:EKSpanFutureEvents commit:YES error:nil];
    x = NewEv(cal, @"Probe err far-future", At(@"UTC", 4100, 1, 1, 9, 0), At(@"UTC", 4100, 1, 1, 10, 0), @"UTC");
    SaveEv(@"err year-4100", x, EKSpanThisEvent);
    if (x.eventIdentifier) [gStore removeEvent:x span:EKSpanThisEvent commit:YES error:nil];
    x = NewEv(cal, @"Probe err past", At(@"UTC", 1800, 1, 1, 9, 0), At(@"UTC", 1800, 1, 1, 10, 0), @"UTC");
    SaveEv(@"err year-1800", x, EKSpanThisEvent);
    if (x.eventIdentifier) [gStore removeEvent:x span:EKSpanThisEvent commit:YES error:nil];
    x = NewEv(cal, @"Probe err span", s, e, nil);
    SaveEv(@"err invalid-span(7)", x, (EKSpan)7);
    if (x.eventIdentifier) [gStore removeEvent:x span:EKSpanThisEvent commit:YES error:nil];
    EKEventStore *other = [EKEventStore new];
    EKCalendar *otherCal = [other calendarWithIdentifier:cal.calendarIdentifier];
    x = [EKEvent eventWithEventStore:other]; x.calendar = otherCal; x.title = @"Probe err otherstore"; x.startDate = s; x.endDate = e;
    SaveEv(@"err other-store", x, EKSpanThisEvent);
    EKCalendar *rcal = gStore.defaultCalendarForNewReminders;
    if (rcal) {
        x = NewEv(rcal, @"Probe err remcal", s, e, nil);
        SaveEv(@"err event-in-reminder-list", x, EKSpanThisEvent);
    }
    for (EKCalendar *c in [gStore calendarsForEntityType:EKEntityTypeEvent]) {
        if (c.type == EKCalendarTypeBirthday || c.isImmutable || !c.allowsContentModifications) {
            x = NewEv(c, @"Probe err readonly", s, e, nil);
            SaveEv([NSString stringWithFormat:@"err readonly-calendar(%@ type %ld)", c.title, (long)c.type], x, EKSpanThisEvent);
            NSError *er = nil;
            BOOL ok = [gStore removeCalendar:c commit:NO error:&er];
            P(@"err remove readonly calendar \"%@\" ok=%d err=%@", c.title, ok, E(er));
        }
    }
    EKCalendar *nc = [EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:gStore];
    nc.title = @"Ycode Probe nosource";
    NSError *er = nil;
    BOOL ok = [gStore saveCalendar:nc commit:YES error:&er];
    P(@"err calendar-no-source ok=%d err=%@", ok, E(er));
    // Exceptions on misuse.
    @try { [gStore predicateForEventsWithStartDate:nil endDate:e calendars:nil]; P(@"predicate nil start accepted"); }
    @catch (NSException *ex) { P(@"predicate nil start EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { [gStore eventWithIdentifier:@"bogus"] ? P(@"bogus id -> object") : P(@"bogus eventWithIdentifier -> nil"); }
    @catch (NSException *ex) { P(@"bogus id EXCEPTION %@: %@", ex.name, ex.reason); }
    @try { P(@"calendarWithIdentifier bogus -> %@", [gStore calendarWithIdentifier:@"bogus"]); } @catch (NSException *ex) { P(@"bogus cal EXCEPTION %@", ex.name); }
    @try { P(@"calendarItemWithIdentifier bogus -> %@", [gStore calendarItemWithIdentifier:@"bogus"]); } @catch (NSException *ex) { P(@"bogus item EXCEPTION %@", ex.name); }
}

static void PhaseEvents(void) {
    Status(@"events");
    Sources(@"events");
    Wipe();
    __block int changes = 0;
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:EKEventStoreChangedNotification object:gStore queue:nil usingBlock:^(NSNotification *n) {
        changes++; gChanges++;
        NSMutableArray *k = [NSMutableArray array];
        for (id key in n.userInfo) [k addObject:[key description]];
        P(@"NOTIFY EKEventStoreChanged #%d object=%@ userInfoKeys=[%@] %@", changes, n.object == gStore ? @"store" : n.object, [k componentsJoinedByString:@","], Thr());
    }];
    EKCalendar *cal = ProbeCalendar(EKEntityTypeEvent, kCal, YES);
    if (!cal) return;
    Sleep(2);
    P(@"notifications after calendar create: %d", changes);
    NSString *NY = @"America/New_York";

    // E1 simple timed event with fields.
    EKEvent *e1 = NewEv(cal, @"Probe E1 standup", At(NY, 2026, 10, 5, 9, 0), At(NY, 2026, 10, 5, 10, 0), NY);
    e1.location = @"Room 1 (made up)"; e1.notes = @"Made-up notes"; e1.URL = [NSURL URLWithString:@"https://example.invalid/e1"];
    e1.availability = EKEventAvailabilityFree;
    P(@"E1 before save isNew=%d hasChanges=%d id=%@ calItemId=%@", e1.isNew, e1.hasChanges, e1.eventIdentifier, e1.calendarItemIdentifier);
    SaveEv(@"E1", e1, EKSpanThisEvent);
    P(@"E1 after save isNew=%d hasChanges=%d created=%@ modified=%@ status=%ld organizer=%@ hasAttendees=%d", e1.isNew, e1.hasChanges,
      e1.creationDate ? @"set" : @"nil", e1.lastModifiedDate ? @"set" : @"nil", (long)e1.status, e1.organizer, e1.hasAttendees);
    Sleep(2);
    P(@"notifications after E1: %d", changes);
    EKEvent *e1b = [gStore eventWithIdentifier:e1.eventIdentifier];
    P(@"E1 refetch %@ location=%@ notes=%@ URL=%@ availability=%ld same-object=%d", EvDesc(e1b), e1b.location, e1b.notes, e1b.URL, (long)e1b.availability, e1b == e1);
    EKCalendarItem *ci = [gStore calendarItemWithIdentifier:e1.calendarItemIdentifier];
    P(@"E1 calendarItemWithIdentifier class=%@", NSStringFromClass([ci class]));
    NSArray *byExt = [gStore calendarItemsWithExternalIdentifier:e1.calendarItemExternalIdentifier];
    P(@"E1 calendarItemsWithExternalIdentifier n=%lu", (unsigned long)byExt.count);

    // E2 all-day single, E3 all-day multi-day.
    EKEvent *e2 = NewEv(cal, @"Probe E2 allday", At(nil, 2026, 10, 7, 0, 0), At(nil, 2026, 10, 7, 0, 0), nil);
    e2.allDay = YES;
    P(@"E2 before save tz=%@", e2.timeZone.name ?: @"nil");
    SaveEv(@"E2", e2, EKSpanThisEvent);
    P(@"E2 %@", EvDesc([gStore eventWithIdentifier:e2.eventIdentifier]));
    EKEvent *e3 = NewEv(cal, @"Probe E3 allday3", At(nil, 2026, 10, 10, 0, 0), At(nil, 2026, 10, 12, 0, 0), nil);
    e3.allDay = YES;
    SaveEv(@"E3", e3, EKSpanThisEvent);
    P(@"E3 %@", EvDesc([gStore eventWithIdentifier:e3.eventIdentifier]));
    EKEvent *e3b = NewEv(cal, @"Probe E3b allday-timed-input", At(NY, 2026, 10, 13, 15, 30), At(NY, 2026, 10, 13, 16, 30), NY);
    e3b.allDay = YES;
    SaveEv(@"E3b", e3b, EKSpanThisEvent);
    P(@"E3b %@", EvDesc([gStore eventWithIdentifier:e3b.eventIdentifier]));

    // E4 floating (no time zone).
    EKEvent *e4 = NewEv(cal, @"Probe E4 floating", At(nil, 2026, 10, 8, 14, 0), At(nil, 2026, 10, 8, 15, 0), nil);
    e4.timeZone = nil;
    SaveEv(@"E4", e4, EKSpanThisEvent);
    P(@"E4 default tz=%@ %@", [NSTimeZone defaultTimeZone].name, EvDesc([gStore eventWithIdentifier:e4.eventIdentifier]));
    // E4b timed in Tokyo.
    EKEvent *e4b = NewEv(cal, @"Probe E4b tokyo", At(@"Asia/Tokyo", 2026, 10, 8, 14, 0), At(@"Asia/Tokyo", 2026, 10, 8, 15, 0), @"Asia/Tokyo");
    SaveEv(@"E4b", e4b, EKSpanThisEvent);
    P(@"E4b %@", EvDesc([gStore eventWithIdentifier:e4b.eventIdentifier]));
    // Floating behaviour under another default time zone in this process.
    NSString *e4id = e4.eventIdentifier, *e2id = e2.eventIdentifier, *e4bid = e4b.eventIdentifier;
    NSTimeZone *saved = [NSTimeZone defaultTimeZone];
    for (NSString *tzn in @[ @"Asia/Tokyo", @"Europe/Berlin", @"UTC" ]) {
        [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:tzn]];
        EKEventStore *s2 = [EKEventStore new];
        P(@"floating under default=%@: E4 %@", tzn, EvDesc([s2 eventWithIdentifier:e4id]));
        P(@"floating under default=%@: E2 %@", tzn, EvDesc([s2 eventWithIdentifier:e2id]));
        P(@"floating under default=%@: E4b %@", tzn, EvDesc([s2 eventWithIdentifier:e4bid]));
        NSArray *f = Fetch([@"floating-fetch " stringByAppendingString:tzn], At(tzn, 2026, 10, 8, 0, 0), At(tzn, 2026, 10, 9, 0, 0),
                           @[ [s2 calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe E4");
        for (EKEvent *x in f) P(@"floating-fetch %@ %@", tzn, EvDesc(x));
        [NSTimeZone resetSystemTimeZone];
    }
    [NSTimeZone setDefaultTimeZone:saved];
    // Changing the zone of a saved event.
    EKEvent *e4c = NewEv(cal, @"Probe E4c retz", At(NY, 2026, 10, 9, 9, 0), At(NY, 2026, 10, 9, 10, 0), NY);
    SaveEv(@"E4c", e4c, EKSpanThisEvent);
    e4c.timeZone = [NSTimeZone timeZoneWithName:@"Europe/Berlin"];
    P(@"E4c after setting tz Berlin (unsaved) %@", EvDesc(e4c));
    SaveEv(@"E4c retz", e4c, EKSpanThisEvent);
    P(@"E4c refetch %@", EvDesc([gStore eventWithIdentifier:e4c.eventIdentifier]));

    // Recurrence: golden expansions.
    NSDate *W0 = At(@"UTC", 2026, 10, 1, 0, 0), *W1 = At(@"UTC", 2027, 10, 1, 0, 0);
    struct { const char *title; } dummy; (void)dummy;
    // R1 weekly MO,WE,FR count 10 across the US DST change (2026-11-01).
    EKEvent *r1 = NewEv(cal, @"Probe R1 mwf", At(NY, 2026, 10, 26, 8, 30), At(NY, 2026, 10, 26, 9, 0), NY);
    [r1 addRecurrenceRule:RR(EKRecurrenceFrequencyWeekly, 1, @[ DOW(EKWeekdayMonday, 0), DOW(EKWeekdayWednesday, 0), DOW(EKWeekdayFriday, 0) ], nil, nil, nil, nil, nil,
                             [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:10])];
    SaveEv(@"R1", r1, EKSpanThisEvent);
    P(@"R1 rule after save %@", Rule(r1.recurrenceRules.firstObject));
    Expand(@"R1", cal, @"Probe R1 mwf", W0, W1);
    // R2 daily every 2 days until 2026-10-20 (date in NY 23:59).
    EKEvent *r2 = NewEv(cal, @"Probe R2 daily2", At(NY, 2026, 10, 10, 7, 0), At(NY, 2026, 10, 10, 7, 15), NY);
    [r2 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:2
                                                                           end:[EKRecurrenceEnd recurrenceEndWithEndDate:At(NY, 2026, 10, 20, 7, 0)]]];
    SaveEv(@"R2", r2, EKSpanThisEvent);
    P(@"R2 rule %@", Rule(r2.recurrenceRules.firstObject));
    Expand(@"R2", cal, @"Probe R2 daily2", W0, W1);
    // R3 monthly on the 31st, count 6 (months without a 31st).
    EKEvent *r3 = NewEv(cal, @"Probe R3 m31", At(NY, 2026, 10, 31, 12, 0), At(NY, 2026, 10, 31, 13, 0), NY);
    [r3 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyMonthly interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:6]]];
    SaveEv(@"R3", r3, EKSpanThisEvent);
    P(@"R3 rule %@", Rule(r3.recurrenceRules.firstObject));
    Expand(@"R3", cal, @"Probe R3 m31", W0, W1);
    // R3b monthly BYMONTHDAY=31 explicitly.
    EKEvent *r3b = NewEv(cal, @"Probe R3b bymd31", At(NY, 2026, 10, 31, 12, 0), At(NY, 2026, 10, 31, 13, 0), NY);
    [r3b addRecurrenceRule:RR(EKRecurrenceFrequencyMonthly, 1, nil, @[ @31 ], nil, nil, nil, nil, [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:6])];
    SaveEv(@"R3b", r3b, EKSpanThisEvent);
    P(@"R3b rule %@", Rule(r3b.recurrenceRules.firstObject));
    Expand(@"R3b", cal, @"Probe R3b bymd31", W0, W1);
    // R4 monthly last Friday, count 5.
    EKEvent *r4 = NewEv(cal, @"Probe R4 lastfri", At(NY, 2026, 10, 30, 17, 0), At(NY, 2026, 10, 30, 18, 0), NY);
    [r4 addRecurrenceRule:RR(EKRecurrenceFrequencyMonthly, 1, @[ DOW(EKWeekdayFriday, -1) ], nil, nil, nil, nil, nil, [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:5])];
    SaveEv(@"R4", r4, EKSpanThisEvent);
    Expand(@"R4", cal, @"Probe R4 lastfri", W0, W1);
    // R5 monthly second-to-last weekday (setpos -2), count 4.
    EKEvent *r5 = NewEv(cal, @"Probe R5 setpos", At(NY, 2026, 10, 29, 10, 0), At(NY, 2026, 10, 29, 10, 30), NY);
    [r5 addRecurrenceRule:RR(EKRecurrenceFrequencyMonthly, 1, @[ DOW(2, 0), DOW(3, 0), DOW(4, 0), DOW(5, 0), DOW(6, 0) ], nil, nil, nil, nil, @[ @-2 ],
                             [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:4])];
    SaveEv(@"R5", r5, EKSpanThisEvent);
    P(@"R5 rule %@", Rule(r5.recurrenceRules.firstObject));
    Expand(@"R5", cal, @"Probe R5 setpos", W0, W1);
    // R6 yearly on Feb 29 from 2028, count 3 (four-year window: fetch in pieces).
    EKEvent *r6 = NewEv(cal, @"Probe R6 feb29", At(NY, 2028, 2, 29, 9, 0), At(NY, 2028, 2, 29, 10, 0), NY);
    [r6 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyYearly interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3]]];
    SaveEv(@"R6", r6, EKSpanThisEvent);
    P(@"R6 rule %@", Rule(r6.recurrenceRules.firstObject));
    Expand(@"R6 2028-2031", cal, @"Probe R6 feb29", At(@"UTC", 2028, 1, 1, 0, 0), At(@"UTC", 2031, 12, 31, 0, 0));
    Expand(@"R6 2031-2035", cal, @"Probe R6 feb29", At(@"UTC", 2031, 12, 31, 0, 0), At(@"UTC", 2035, 12, 30, 0, 0));
    Expand(@"R6 2035-2039", cal, @"Probe R6 feb29", At(@"UTC", 2035, 12, 30, 0, 0), At(@"UTC", 2039, 12, 29, 0, 0));
    // R7 yearly 4th Thursday of November, count 3.
    EKEvent *r7 = NewEv(cal, @"Probe R7 thanks", At(NY, 2026, 11, 26, 15, 0), At(NY, 2026, 11, 26, 18, 0), NY);
    [r7 addRecurrenceRule:RR(EKRecurrenceFrequencyYearly, 1, @[ DOW(EKWeekdayThursday, 4) ], nil, @[ @11 ], nil, nil, nil, [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3])];
    SaveEv(@"R7", r7, EKSpanThisEvent);
    Expand(@"R7", cal, @"Probe R7 thanks", W0, At(@"UTC", 2029, 9, 30, 0, 0));
    // R8 every 2 weeks TU,TH starting on a Thursday, count 6.
    EKEvent *r8 = NewEv(cal, @"Probe R8 biweekly", At(NY, 2026, 10, 1, 11, 0), At(NY, 2026, 10, 1, 11, 30), NY);
    [r8 addRecurrenceRule:RR(EKRecurrenceFrequencyWeekly, 2, @[ DOW(EKWeekdayTuesday, 0), DOW(EKWeekdayThursday, 0) ], nil, nil, nil, nil, nil, [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:6])];
    SaveEv(@"R8", r8, EKSpanThisEvent);
    P(@"R8 rule %@", Rule(r8.recurrenceRules.firstObject));
    Expand(@"R8", cal, @"Probe R8 biweekly", W0, W1);
    // R9 yearly week number 20 Monday, count 3; R10 yearly day 100 count 3.
    EKEvent *r9 = NewEv(cal, @"Probe R9 weekno", At(NY, 2027, 5, 17, 9, 0), At(NY, 2027, 5, 17, 10, 0), NY);
    [r9 addRecurrenceRule:RR(EKRecurrenceFrequencyYearly, 1, @[ DOW(EKWeekdayMonday, 0) ], nil, nil, @[ @20 ], nil, nil, [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3])];
    SaveEv(@"R9", r9, EKSpanThisEvent);
    P(@"R9 rule %@", Rule(r9.recurrenceRules.firstObject));
    Expand(@"R9", cal, @"Probe R9 weekno", W0, At(@"UTC", 2030, 9, 1, 0, 0));
    EKEvent *r10 = NewEv(cal, @"Probe R10 yday", At(NY, 2027, 4, 10, 9, 0), At(NY, 2027, 4, 10, 10, 0), NY);
    [r10 addRecurrenceRule:RR(EKRecurrenceFrequencyYearly, 1, nil, nil, nil, nil, @[ @100 ], nil, [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3])];
    SaveEv(@"R10", r10, EKSpanThisEvent);
    Expand(@"R10", cal, @"Probe R10 yday", W0, At(@"UTC", 2030, 9, 1, 0, 0));
    // R11 floating daily count 3 (no zone).
    EKEvent *r11 = NewEv(cal, @"Probe R11 floatdaily", At(nil, 2026, 10, 31, 22, 0), At(nil, 2026, 10, 31, 23, 0), nil);
    r11.timeZone = nil;
    [r11 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3]]];
    SaveEv(@"R11", r11, EKSpanThisEvent);
    Expand(@"R11", cal, @"Probe R11 floatdaily", W0, W1);
    // R12 all-day yearly (birthday-like), count 3.
    EKEvent *r12 = NewEv(cal, @"Probe R12 allday-yearly", At(nil, 2026, 12, 25, 0, 0), At(nil, 2026, 12, 25, 0, 0), nil);
    r12.allDay = YES;
    [r12 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyYearly interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3]]];
    SaveEv(@"R12", r12, EKSpanThisEvent);
    Expand(@"R12", cal, @"Probe R12 allday-yearly", W0, At(@"UTC", 2029, 9, 1, 0, 0));
    // R13 two rules on one event.
    EKEvent *r13 = NewEv(cal, @"Probe R13 tworules", At(NY, 2026, 11, 2, 9, 0), At(NY, 2026, 11, 2, 9, 30), NY);
    [r13 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyWeekly interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:2]]];
    [r13 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:2]]];
    P(@"R13 rules before save n=%lu", (unsigned long)r13.recurrenceRules.count);
    SaveEv(@"R13", r13, EKSpanThisEvent);
    P(@"R13 rules after refetch n=%lu %@", (unsigned long)[gStore eventWithIdentifier:r13.eventIdentifier].recurrenceRules.count,
      Rule([gStore eventWithIdentifier:r13.eventIdentifier].recurrenceRules.firstObject));
    Expand(@"R13", cal, @"Probe R13 tworules", W0, W1);
    // R14 start not matching rule (weekly WE, start on Monday) count 3.
    EKEvent *r14 = NewEv(cal, @"Probe R14 offstart", At(NY, 2026, 11, 2, 12, 0), At(NY, 2026, 11, 2, 12, 30), NY);
    [r14 addRecurrenceRule:RR(EKRecurrenceFrequencyWeekly, 1, @[ DOW(EKWeekdayWednesday, 0) ], nil, nil, nil, nil, nil, [EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3])];
    SaveEv(@"R14", r14, EKSpanThisEvent);
    Expand(@"R14", cal, @"Probe R14 offstart", W0, W1);
    // R15 hourly-like: daily ending with an end date earlier than start.
    EKEvent *r15 = NewEv(cal, @"Probe R15 endbefore", At(NY, 2026, 11, 3, 12, 0), At(NY, 2026, 11, 3, 12, 30), NY);
    [r15 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1 end:[EKRecurrenceEnd recurrenceEndWithEndDate:At(NY, 2026, 11, 1, 0, 0)]]];
    SaveEv(@"R15", r15, EKSpanThisEvent);
    Expand(@"R15", cal, @"Probe R15 endbefore", W0, W1);

    // Exceptions on R1: detach the 3rd occurrence, delete the 4th, split at the 7th.
    NSArray *occ = Fetch(@"R1-occ", W0, W1, @[ cal ], @"Probe R1 mwf");
    if (occ.count >= 8) {
        EKEvent *o3 = occ[2];
        P(@"R1 o3 before: %@ eventId=%@ hasRules=%d", EvDesc(o3), o3.eventIdentifier, o3.hasRecurrenceRules);
        o3.title = @"Probe R1 mwf (moved)";
        o3.startDate = [o3.startDate dateByAddingTimeInterval:5400];
        o3.endDate = [o3.endDate dateByAddingTimeInterval:5400];
        SaveEv(@"R1 detach o3", o3, EKSpanThisEvent);
        P(@"R1 o3 after: %@ eventId=%@ hasRules=%d", EvDesc(o3), o3.eventIdentifier, o3.hasRecurrenceRules);
        EKEvent *o4 = occ[3];
        NSError *e = nil;
        BOOL ok = [gStore removeEvent:o4 span:EKSpanThisEvent commit:YES error:&e];
        P(@"R1 delete o4 (%@) ok=%d err=%@", U(o4.startDate), ok, E(e));
        NSArray *after = Fetch(@"R1-after-exceptions", W0, W1, @[ cal ], @"Probe R1");
        int i = 0;
        for (EKEvent *x in after) P(@"R1x #%d %@ id=%@", ++i, EvDesc(x), x.eventIdentifier);
        // Collide: move o5 onto o6's date.
        after = Fetch(@"R1-occ2", W0, W1, @[ cal ], @"Probe R1 mwf");
        EKEvent *o5 = nil, *o6 = nil;
        for (EKEvent *x in after) if (!x.isDetached && [x.title isEqualToString:@"Probe R1 mwf"]) { if (!o5) o5 = x; else if (!o6) { o6 = x; break; } }
        if (o5 && o6) {
            o5.startDate = [o6.startDate dateByAddingTimeInterval:0];
            o5.endDate = [o6.endDate dateByAddingTimeInterval:0];
            SaveEv(@"R1 collide (move o onto next occurrence)", o5, EKSpanThisEvent);
        }
        after = Fetch(@"R1-occ3", W0, W1, @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe R1 mwf");
        EKEvent *o7 = after.count >= 6 ? after[5] : nil;
        if (o7) {
            P(@"R1 split at %@", U(o7.startDate));
            o7.title = @"Probe R1 mwf (future)";
            SaveEv(@"R1 split future", o7, EKSpanFutureEvents);
            NSArray *fin = Fetch(@"R1-after-split", W0, W1, @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe R1");
            i = 0;
            NSMutableSet *ids = [NSMutableSet set];
            for (EKEvent *x in fin) {
                P(@"R1s #%d %@ id=%@ rule=%@", ++i, EvDesc(x), x.eventIdentifier, Rule(x.recurrenceRules.firstObject));
                if (x.eventIdentifier) [ids addObject:x.eventIdentifier];
            }
            P(@"R1 distinct eventIdentifiers after split: %lu", (unsigned long)ids.count);
        }
    } else P(@"R1 occurrences too few: %lu", (unsigned long)occ.count);
    // Remove the rule from R8 (all future) and see what remains.
    EKEvent *r8m = [gStore eventWithIdentifier:r8.eventIdentifier];
    P(@"R8 master via eventWithIdentifier: %@", EvDesc(r8m));
    [r8m removeRecurrenceRule:r8m.recurrenceRules.firstObject];
    SaveEv(@"R8 remove rule", r8m, EKSpanFutureEvents);
    Expand(@"R8 after rule removal", [gStore calendarWithIdentifier:cal.calendarIdentifier], @"Probe R8 biweekly", W0, W1);
    // Delete a whole series from its second occurrence with future span.
    NSArray *r2o = Fetch(@"R2-occ", W0, W1, @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe R2 daily2");
    if (r2o.count >= 3) {
        NSError *e = nil;
        BOOL ok = [gStore removeEvent:r2o[2] span:EKSpanFutureEvents commit:YES error:&e];
        P(@"R2 remove from #3 future ok=%d err=%@", ok, E(e));
        Expand(@"R2 after future-delete", [gStore calendarWithIdentifier:cal.calendarIdentifier], @"Probe R2 daily2", W0, W1);
        P(@"R2 rule now %@", Rule([gStore eventWithIdentifier:r2.eventIdentifier].recurrenceRules.firstObject));
    }

    // Alarms.
    EKEvent *a = NewEv([gStore calendarWithIdentifier:cal.calendarIdentifier], @"Probe A1 alarms", At(NY, 2026, 10, 14, 9, 0), At(NY, 2026, 10, 14, 10, 0), NY);
    [a addAlarm:[EKAlarm alarmWithRelativeOffset:-900]];
    [a addAlarm:[EKAlarm alarmWithAbsoluteDate:At(NY, 2026, 10, 13, 20, 0)]];
    EKAlarm *geo = [EKAlarm alarmWithRelativeOffset:0];
    EKStructuredLocation *loc = [EKStructuredLocation locationWithTitle:@"Probe Park"];
    loc.geoLocation = [[CLLocation alloc] initWithLatitude:40.0 longitude:-75.0]; loc.radius = 150;
    geo.structuredLocation = loc; geo.proximity = EKAlarmProximityEnter;
    [a addAlarm:geo];
    [a addAlarm:[EKAlarm alarmWithRelativeOffset:-900]]; // duplicate
    a.structuredLocation = loc;
    SaveEv(@"A1", a, EKSpanThisEvent);
    EKEvent *ar = [[EKEventStore new] eventWithIdentifier:a.eventIdentifier];
    P(@"A1 refetch in a new store: %@", ar ? EvDesc(ar) : @"nil");
    ar = [gStore eventWithIdentifier:a.eventIdentifier];
    P(@"A1 refetch alarms n=%lu location=%@ structured=%@ r=%.0f", (unsigned long)ar.alarms.count, ar.location, ar.structuredLocation.title, ar.structuredLocation.radius);
    for (EKAlarm *x in ar.alarms)
        P(@"A1 alarm offset=%.0f abs=%@ proximity=%ld loc=%@", x.relativeOffset, U(x.absoluteDate), (long)x.proximity, x.structuredLocation.title);
    EKEvent *ad = NewEv([gStore calendarWithIdentifier:cal.calendarIdentifier], @"Probe A2 allday-alarm", At(nil, 2026, 10, 15, 0, 0), At(nil, 2026, 10, 15, 0, 0), nil);
    ad.allDay = YES;
    SaveEv(@"A2", ad, EKSpanThisEvent);
    P(@"A2 default alarms on all-day event n=%lu; A1-like new timed event default alarms checked below", (unsigned long)[gStore eventWithIdentifier:ad.eventIdentifier].alarms.count);
    P(@"E1 default alarms n=%lu", (unsigned long)[gStore eventWithIdentifier:e1.eventIdentifier].alarms.count);

    // Batch commit and notifications.
    int before = changes;
    for (int i = 0; i < 3; i++) {
        EKEvent *b = NewEv([gStore calendarWithIdentifier:cal.calendarIdentifier], [NSString stringWithFormat:@"Probe B%d batch", i], At(NY, 2026, 10, 16, 9 + i, 0), At(NY, 2026, 10, 16, 9 + i, 30), NY);
        NSError *e = nil;
        BOOL ok = [gStore saveEvent:b span:EKSpanThisEvent commit:NO error:&e];
        P(@"batch save %d commit:NO ok=%d id=%@", i, ok, b.eventIdentifier);
    }
    P(@"batch fetched before commit (same store) n=%lu", (unsigned long)Fetch(@"batch-precommit", At(NY, 2026, 10, 16, 0, 0), At(NY, 2026, 10, 17, 0, 0), @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe B").count);
    NSError *ce = nil;
    BOOL cok = [gStore commit:&ce];
    P(@"batch commit ok=%d err=%@", cok, E(ce));
    Sleep(3);
    P(@"notifications for batch of 3: %d", changes - before);
    P(@"batch fetched after commit n=%lu", (unsigned long)Fetch(@"batch-postcommit", At(NY, 2026, 10, 16, 0, 0), At(NY, 2026, 10, 17, 0, 0), @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe B").count);
    // Rollback/reset.
    EKEvent *rb = [gStore eventWithIdentifier:e1.eventIdentifier];
    rb.title = @"Probe E1 changed";
    P(@"E1 hasChanges after edit=%d", rb.hasChanges);
    [rb rollback];
    P(@"E1 after rollback title=%@ hasChanges=%d", rb.title, rb.hasChanges);
    // Notification from another store instance.
    before = changes;
    EKEventStore *s2 = [EKEventStore new];
    EKEvent *o = [EKEvent eventWithEventStore:s2];
    o.calendar = [s2 calendarWithIdentifier:cal.calendarIdentifier]; o.title = @"Probe O1 otherstore";
    o.startDate = At(NY, 2026, 10, 17, 9, 0); o.endDate = At(NY, 2026, 10, 17, 10, 0);
    NSError *oe = nil;
    BOOL ook = [s2 saveEvent:o span:EKSpanThisEvent commit:YES error:&oe];
    P(@"other store save ok=%d err=%@", ook, E(oe));
    Sleep(3);
    P(@"notifications on first store after other-store save: %d", changes - before);
    P(@"stale object e1 refresh=%d", [e1 refresh]);
    // Predicate span limit.
    NSArray *big = Fetch(@"span10y", At(@"UTC", 2026, 1, 1, 0, 0), At(@"UTC", 2036, 1, 1, 0, 0), @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe R6");
    for (EKEvent *x in big) P(@"span10y R6 %@", U(x.startDate));
    // Enumerate API.
    __block int en = 0;
    [gStore enumerateEventsMatchingPredicate:[gStore predicateForEventsWithStartDate:W0 endDate:W1 calendars:@[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ]]
                                  usingBlock:^(EKEvent *ev, BOOL *stop) { en++; }];
    P(@"enumerateEvents count=%d", en);
    // Spanning event: started before the window.
    NSArray *span = Fetch(@"overlap", At(NY, 2026, 10, 11, 12, 0), At(NY, 2026, 10, 11, 13, 0), @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe");
    for (EKEvent *x in span) P(@"overlap %@", EvDesc(x));
    NSArray *edge = Fetch(@"edge-end==start", At(NY, 2026, 10, 5, 10, 0), At(NY, 2026, 10, 5, 11, 0), @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe E1");
    NSArray *edge2 = Fetch(@"edge-start==end", At(NY, 2026, 10, 5, 8, 0), At(NY, 2026, 10, 5, 9, 0), @[ [gStore calendarWithIdentifier:cal.calendarIdentifier] ], @"Probe E1");
    P(@"edges: window starting at E1 end n=%lu; window ending at E1 start n=%lu", (unsigned long)edge.count, (unsigned long)edge2.count);

    Errors([gStore calendarWithIdentifier:cal.calendarIdentifier]);
    // Calendar edits.
    EKCalendar *c2 = [gStore calendarWithIdentifier:cal.calendarIdentifier];
    c2.title = @"Ycode Probe renamed";
    NSError *e = nil;
    BOOL ok = [gStore saveCalendar:c2 commit:YES error:&e];
    P(@"rename calendar ok=%d err=%@", ok, E(e));
    c2.title = kCal;
    [gStore saveCalendar:c2 commit:YES error:nil];
    Sleep(2);
    // reset invalidates objects fetched earlier.
    EKEvent *pre = [gStore eventWithIdentifier:e1.eventIdentifier];
    [gStore reset];
    P(@"after reset: old object id=%@ title=%@; refetch=%@", pre.eventIdentifier, pre.title, EvDesc([gStore eventWithIdentifier:e1.eventIdentifier]));
    Sleep(2);
    P(@"total notifications this phase: %d", changes);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
}

#pragma mark - reminders

static NSArray *FetchR(NSString *tag, NSPredicate *p) {
    __block NSArray *out = nil;
    Wait(tag, 30, ^(dispatch_block_t done) {
        [gStore fetchRemindersMatchingPredicate:p completion:^(NSArray *r) { out = r; P(@"%@ completion %@", tag, Thr()); done(); }];
    });
    NSMutableArray *m = [NSMutableArray array];
    for (EKReminder *r in out) if ([r.title hasPrefix:@"Probe"]) [m addObject:r];
    [m sortUsingComparator:^NSComparisonResult(EKReminder *a, EKReminder *b) { return [a.title compare:b.title]; }];
    P(@"%@ n=%lu (unfiltered %lu)", tag, (unsigned long)m.count, (unsigned long)out.count);
    for (EKReminder *r in m)
        P(@"%@ - \"%@\" due=%@ start=%@ completed=%d completionDate=%@ priority=%lu tz=%@ rules=%@ alarms=%lu", tag, r.title, DC(r.dueDateComponents),
          DC(r.startDateComponents), r.completed, r.completionDate ? @"set" : @"nil", (unsigned long)r.priority, r.timeZone.name ?: @"nil",
          Rule(r.recurrenceRules.firstObject), (unsigned long)r.alarms.count);
    return m;
}

static BOOL SaveR(NSString *tag, EKReminder *r) {
    NSError *e = nil;
    BOOL ok = [gStore saveReminder:r commit:YES error:&e];
    P(@"%@ saveReminder ok=%d err=%@ calItemId=%@ extId=%@", tag, ok, E(e), r.calendarItemIdentifier, r.calendarItemExternalIdentifier);
    return ok;
}

static NSDateComponents *Comp(int y, int mo, int d, int h, int mi, NSString *tz) {
    NSDateComponents *c = [NSDateComponents new];
    c.year = y; c.month = mo; c.day = d;
    if (h >= 0) { c.hour = h; c.minute = mi; }
    if (tz) c.timeZone = [NSTimeZone timeZoneWithName:tz];
    return c;
}

static void PhaseReminders(void) {
    Status(@"reminders");
    Sources(@"reminders");
    for (EKCalendar *c in [gStore calendarsForEntityType:EKEntityTypeReminder])
        if ([c.title hasPrefix:@"Ycode Probe"]) [gStore removeCalendar:c commit:YES error:nil];
    __block int changes = 0;
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:EKEventStoreChangedNotification object:gStore queue:nil usingBlock:^(NSNotification *n) {
        changes++;
    }];
    EKCalendar *list = ProbeCalendar(EKEntityTypeReminder, kList, YES);
    if (!list) list = gStore.defaultCalendarForNewReminders;
    EKReminder *r1 = [EKReminder reminderWithEventStore:gStore];
    r1.calendar = list; r1.title = @"Probe R1 dateonly"; r1.dueDateComponents = Comp(2026, 10, 20, -1, 0, nil);
    SaveR(@"R1", r1);
    EKReminder *r2 = [EKReminder reminderWithEventStore:gStore];
    r2.calendar = list; r2.title = @"Probe R2 timed"; r2.dueDateComponents = Comp(2026, 10, 21, 9, 30, @"America/New_York");
    r2.startDateComponents = Comp(2026, 10, 21, 8, 0, @"America/New_York");
    [r2 addAlarm:[EKAlarm alarmWithRelativeOffset:-600]];
    SaveR(@"R2", r2);
    EKReminder *r3 = [EKReminder reminderWithEventStore:gStore];
    r3.calendar = list; r3.title = @"Probe R3 done"; r3.dueDateComponents = Comp(2026, 10, 2, 12, 0, nil);
    r3.completionDate = At(@"UTC", 2026, 10, 3, 12, 0);
    SaveR(@"R3", r3);
    EKReminder *r4 = [EKReminder reminderWithEventStore:gStore];
    r4.calendar = list; r4.title = @"Probe R4 high"; r4.priority = EKReminderPriorityHigh; r4.notes = @"made up";
    SaveR(@"R4", r4);
    EKReminder *r5 = [EKReminder reminderWithEventStore:gStore];
    r5.calendar = list; r5.title = @"Probe R5 daily"; r5.dueDateComponents = Comp(2026, 10, 22, 7, 0, @"America/New_York");
    [r5 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1 end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:3]]];
    SaveR(@"R5", r5);
    EKReminder *r6 = [EKReminder reminderWithEventStore:gStore];
    r6.calendar = list; r6.title = @"Probe R6 rec-nodue";
    [r6 addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyDaily interval:1 end:nil]];
    SaveR(@"err R6 recurring-without-due", r6);
    EKReminder *r7 = [EKReminder reminderWithEventStore:gStore];
    r7.calendar = list; r7.title = @"Probe R7 prio";
    @try { r7.priority = 12; SaveR(@"err R7 priority 12", r7); } @catch (NSException *ex) { P(@"R7 EXCEPTION %@: %@", ex.name, ex.reason); }
    EKReminder *r8 = [EKReminder reminderWithEventStore:gStore];
    r8.calendar = list; r8.title = @"Probe R8 floating"; r8.dueDateComponents = Comp(2026, 10, 23, 18, 0, nil);
    SaveR(@"R8", r8);
    EKReminder *r9 = [EKReminder reminderWithEventStore:gStore];
    r9.calendar = list; r9.title = @"Probe R9 geo";
    EKAlarm *geo = [EKAlarm alarmWithRelativeOffset:0];
    EKStructuredLocation *loc = [EKStructuredLocation locationWithTitle:@"Probe Park"];
    loc.geoLocation = [[CLLocation alloc] initWithLatitude:40.0 longitude:-75.0]; loc.radius = 100;
    geo.structuredLocation = loc; geo.proximity = EKAlarmProximityLeave;
    [r9 addAlarm:geo];
    SaveR(@"R9", r9);
    EKReminder *r10 = [EKReminder reminderWithEventStore:gStore];
    r10.title = @"Probe R10 nocal";
    SaveR(@"err R10 no-list", r10);
    EKCalendar *evcal = gStore.defaultCalendarForNewEvents;
    if (evcal) {
        EKReminder *r11 = [EKReminder reminderWithEventStore:gStore];
        r11.calendar = evcal; r11.title = @"Probe R11 eventcal";
        SaveR(@"err R11 reminder-in-event-calendar", r11);
    }
    Sleep(2);
    P(@"notifications after reminder saves: %d", changes);
    FetchR(@"all", [gStore predicateForRemindersInCalendars:@[ list ]]);
    FetchR(@"incomplete 10-20..10-22", [gStore predicateForIncompleteRemindersWithDueDateStarting:At(@"America/New_York", 2026, 10, 20, 0, 0)
                                                                                         ending:At(@"America/New_York", 2026, 10, 22, 0, 0) calendars:@[ list ]]);
    FetchR(@"incomplete nil..nil", [gStore predicateForIncompleteRemindersWithDueDateStarting:nil ending:nil calendars:@[ list ]]);
    FetchR(@"completed nil..nil", [gStore predicateForCompletedRemindersWithCompletionDateStarting:nil ending:nil calendars:@[ list ]]);
    FetchR(@"completed 10-03 window", [gStore predicateForCompletedRemindersWithCompletionDateStarting:At(@"UTC", 2026, 10, 3, 0, 0)
                                                                                                ending:At(@"UTC", 2026, 10, 4, 0, 0) calendars:@[ list ]]);
    // Complete the recurring reminder.
    r5.completed = YES;
    SaveR(@"R5 complete", r5);
    FetchR(@"after completing R5", [gStore predicateForRemindersInCalendars:@[ list ]]);
    r5 = (EKReminder *)[gStore calendarItemWithIdentifier:r5.calendarItemIdentifier];
    P(@"R5 same identifier now: due=%@ completed=%d", DC(r5.dueDateComponents), r5.completed);
    // Cancel a fetch.
    id fid = [gStore fetchRemindersMatchingPredicate:[gStore predicateForRemindersInCalendars:nil] completion:^(NSArray *r) { P(@"cancelled fetch completion called n=%lu", (unsigned long)r.count); }];
    [gStore cancelFetchRequest:fid];
    Sleep(2);
    // Delete.
    NSError *e = nil;
    BOOL ok = [gStore removeReminder:r4 commit:YES error:&e];
    P(@"remove R4 ok=%d err=%@", ok, E(e));
    ok = [gStore removeReminder:r4 commit:YES error:&e];
    P(@"remove R4 again ok=%d err=%@", ok, E(e));
    P(@"total reminder notifications: %d", changes);
    [[NSNotificationCenter defaultCenter] removeObserver:obs];
}

#pragma mark - write-only

static void PhaseWO(void) {
    Status(@"wo");
    Sources(@"wo");
    EKCalendar *dc = gStore.defaultCalendarForNewEvents;
    EKEvent *ev = NewEv(dc, @"Probe W1 writeonly", At(@"America/New_York", 2026, 10, 19, 9, 0), At(@"America/New_York", 2026, 10, 19, 10, 0), @"America/New_York");
    SaveEv(@"W1", ev, EKSpanThisEvent);
    P(@"W1 eventWithIdentifier -> %@", [gStore eventWithIdentifier:ev.eventIdentifier] ? @"object" : @"nil");
    P(@"W1 calendarItemWithIdentifier -> %@", [gStore calendarItemWithIdentifier:ev.calendarItemIdentifier] ? @"object" : @"nil");
    NSArray *f = [gStore eventsMatchingPredicate:[gStore predicateForEventsWithStartDate:At(@"UTC", 2026, 10, 1, 0, 0) endDate:At(@"UTC", 2026, 11, 1, 0, 0) calendars:nil]];
    P(@"wo fetch n=%lu", (unsigned long)f.count);
    ev.title = @"Probe W1 writeonly edited";
    SaveEv(@"W1 edit", ev, EKSpanThisEvent);
    NSError *e = nil;
    BOOL ok = [gStore removeEvent:ev span:EKSpanThisEvent commit:YES error:&e];
    P(@"W1 remove ok=%d err=%@", ok, E(e));
    EKCalendar *c = [EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:gStore];
    c.title = @"Ycode Probe WO"; c.source = dc.source;
    ok = [gStore saveCalendar:c commit:YES error:&e];
    P(@"wo saveCalendar ok=%d err=%@", ok, E(e));
    EKEvent *ev2 = NewEv(nil, @"Probe W2 nocal", At(@"UTC", 2026, 10, 19, 9, 0), At(@"UTC", 2026, 10, 19, 10, 0), @"UTC");
    SaveEv(@"W2 no calendar", ev2, EKSpanThisEvent);
}

static void PhaseCount(void) {
    Status(@"count");
    EKCalendar *cal = ProbeCalendar(EKEntityTypeEvent, kCal, NO);
    P(@"count calendar present=%d", cal != nil);
    if (cal) {
        NSArray *f = Fetch(@"count", At(@"UTC", 2026, 9, 1, 0, 0), At(@"UTC", 2027, 9, 1, 0, 0), @[ cal ], @"Probe");
        P(@"count events(occurrences, 1 year)=%lu", (unsigned long)f.count);
    }
    EKCalendar *list = ProbeCalendar(EKEntityTypeReminder, kList, NO);
    P(@"count list present=%d", list != nil);
    if (list) FetchR(@"count reminders", [gStore predicateForRemindersInCalendars:@[ list ]]);
}

#pragma mark - UI

@interface UIDel : NSObject <EKEventEditViewDelegate, EKEventViewDelegate, EKCalendarChooserDelegate>
@end
@implementation UIDel
- (void)eventEditViewController:(EKEventEditViewController *)c didCompleteWithAction:(EKEventEditViewAction)a {
    P(@"UI edit didComplete action=%ld event=%@ eventId=%@ %@", (long)a, c.event.title, c.event.eventIdentifier, Thr());
    [c dismissViewControllerAnimated:YES completion:nil];
}
- (EKCalendar *)eventEditViewControllerDefaultCalendarForNewEvents:(EKEventEditViewController *)c {
    P(@"UI edit asked default calendar");
    return nil;
}
- (void)eventViewController:(EKEventViewController *)c didCompleteWithAction:(EKEventViewAction)a {
    P(@"UI view didComplete action=%ld", (long)a);
    [c dismissViewControllerAnimated:YES completion:nil];
}
- (void)calendarChooserSelectionDidChange:(EKCalendarChooser *)c { P(@"UI chooser selection n=%lu", (unsigned long)c.selectedCalendars.count); }
- (void)calendarChooserDidFinish:(EKCalendarChooser *)c { P(@"UI chooser finish n=%lu", (unsigned long)c.selectedCalendars.count); [c dismissViewControllerAnimated:YES completion:nil]; }
- (void)calendarChooserDidCancel:(EKCalendarChooser *)c { P(@"UI chooser cancel"); [c dismissViewControllerAnimated:YES completion:nil]; }
@end
static UIDel *gDel;

static void PhaseUI(NSString *phase) {
    Status(phase);
    gDel = [UIDel new];
    __block NSString *eid = nil;
    if ([phase isEqualToString:@"uiview"]) {
        EKCalendar *cal = ProbeCalendar(EKEntityTypeEvent, kCal, NO);
        NSArray *f = cal ? Fetch(@"uiview", At(@"UTC", 2026, 10, 5, 0, 0), At(@"UTC", 2026, 10, 6, 0, 0), @[ cal ], @"Probe E1") : @[];
        eid = [f.firstObject eventIdentifier];
        P(@"uiview event id=%@", eid);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *vc = nil;
            if ([phase isEqualToString:@"uiedit"]) {
                EKEventEditViewController *ed = [EKEventEditViewController new];
                ed.eventStore = gStore;
                EKEvent *ev = [EKEvent eventWithEventStore:gStore];
                ev.title = @"Probe UI prefilled"; ev.location = @"Room 2 (made up)";
                ev.startDate = At(@"America/New_York", 2026, 10, 27, 13, 0); ev.endDate = At(@"America/New_York", 2026, 10, 27, 14, 0);
                ed.event = ev;
                ed.editViewDelegate = gDel;
                P(@"UI edit class=%@ viewControllers=%lu", NSStringFromClass([ed class]), (unsigned long)ed.viewControllers.count);
                vc = ed;
            } else if ([phase isEqualToString:@"uiview"]) {
                EKEventViewController *v = [EKEventViewController new];
                v.event = eid ? [gStore eventWithIdentifier:eid] : nil;
                v.allowsEditing = YES; v.delegate = gDel;
                vc = [[UINavigationController alloc] initWithRootViewController:v];
            } else {
                EKCalendarChooser *ch = [[EKCalendarChooser alloc] initWithSelectionStyle:EKCalendarChooserSelectionStyleMultiple displayStyle:EKCalendarChooserDisplayAllCalendars
                                                                              entityType:EKEntityTypeEvent eventStore:gStore];
                ch.showsDoneButton = YES; ch.showsCancelButton = YES; ch.delegate = gDel;
                vc = [[UINavigationController alloc] initWithRootViewController:ch];
            }
            [gRoot presentViewController:vc animated:YES completion:^{ P(@"UI presented %@", NSStringFromClass([vc class])); }];
        } @catch (NSException *ex) { P(@"UI EXCEPTION %@: %@", ex.name, ex.reason); }
    });
    Sleep(8);
    P(@"UI presentedViewController=%@", NSStringFromClass([gRoot.presentedViewController class]));
}

#pragma mark - App

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor systemOrangeColor];
    UILabel *l = [UILabel new]; l.text = @"EKProbe"; l.frame = CGRectMake(40, 120, 300, 40); [vc.view addSubview:l];
    self.window.rootViewController = vc;
    gRoot = vc;
    [self.window makeKeyAndVisible];
    P(@"scene connected");
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    NSString *phase = [[NSUserDefaults standardUserDefaults] stringForKey:@"phase"] ?: @"basic";
    P(@"launch phase=%@ bundle=%@ tz=%@ locale=%@", phase, [NSBundle mainBundle].bundleIdentifier, [NSTimeZone systemTimeZone].name,
      [NSLocale currentLocale].localeIdentifier);
    dispatch_queue_t q = dispatch_queue_create("dev.ycode.ekprobe.runner", DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), q, ^{
        @try {
            gStore = [EKEventStore new];
            if ([phase isEqualToString:@"basic"]) PhaseBasic();
            else if ([phase hasPrefix:@"req"]) Request(phase);
            else if ([phase isEqualToString:@"status"]) { Status(@"status"); Sources(@"status"); }
            else if ([phase isEqualToString:@"events"]) PhaseEvents();
            else if ([phase isEqualToString:@"reminders"]) PhaseReminders();
            else if ([phase isEqualToString:@"wo"]) PhaseWO();
            else if ([phase isEqualToString:@"count"]) PhaseCount();
            else if ([phase isEqualToString:@"wipe"]) Wipe();
            else if ([phase hasPrefix:@"ui"]) PhaseUI(phase);
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
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
