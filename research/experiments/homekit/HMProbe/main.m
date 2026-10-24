// HMProbe: black-box probe of HomeKit's public API behaviour on a simulator.
// Our own code. It calls only public HomeKit/UIKit API and prints one
// "HMPROBE ..." line per observation to stderr.
//
// Launch arguments:
//   -mode auth      create a home manager, log status and callbacks only
//   -mode model     full object-model walk: homes, rooms, zones, groups,
//                   action sets, triggers, events, errors, notifications
//   -mode list      dump every home the manager reports (persistence check)
//   -mode cleanup   remove every home
//   -mode browse    run HMAccessoryBrowser for 10 s, log counts only
//   -mode setup     start the system accessory-setup flow and log the result
//   -mode legacy    start the deprecated addAndSetupAccessories flow
//   -mode objects   events, predicates, ranges, setup payloads: no home needed
//   -mode consts    print every public string constant (names from headers)
#import <UIKit/UIKit.h>
#import <HomeKit/HomeKit.h>
#import <CoreLocation/CoreLocation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

static CFTimeInterval gStart;

static void P(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void P(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "HMPROBE t=%.3f %s\n", CACurrentMediaTime() - gStart, s.UTF8String);
    fflush(stderr);
}

static NSString *Th(void) {
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    return [NSString stringWithFormat:@"main=%d q=%s", [NSThread isMainThread], label ? label : "?"];
}

static NSString *E(NSError *e) {
    if (!e) return @"nil";
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in e.userInfo) [keys addObject:[k description]];
    [keys sortUsingSelector:@selector(compare:)];
    NSError *under = e.userInfo[NSUnderlyingErrorKey];
    return [NSString stringWithFormat:@"domain=%@ code=%ld keys=[%@] desc=\"%@\" reason=\"%@\" under=%@",
            e.domain, (long)e.code, [keys componentsJoinedByString:@","], e.localizedDescription,
            e.localizedFailureReason ?: @"", under ? [NSString stringWithFormat:@"%@/%ld", under.domain, (long)under.code] : @"-"];
}

static NSString *U(NSUUID *u) { return u ? u.UUIDString : @"nil"; }

static NSString *Names(NSArray *objs) {
    NSMutableArray *a = [NSMutableArray array];
    for (id o in objs) [a addObject:[o valueForKey:@"name"] ?: @"?"];
    return [NSString stringWithFormat:@"[%@]", [a componentsJoinedByString:@"|"]];
}

#pragma mark - Delegate logger (one per manager, tags callbacks)

@interface Obs : NSObject <HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate, HMAccessoryBrowserDelegate>
@property (nonatomic, copy) NSString *tag;
@property (nonatomic, copy) void (^onHomes)(void);
@end

@implementation Obs
- (void)homeManager:(HMHomeManager *)m didUpdateAuthorizationStatus:(HMHomeManagerAuthorizationStatus)s {
    P(@"[%@] cb didUpdateAuthorizationStatus=%lu %@", self.tag, (unsigned long)s, Th());
}
- (void)homeManagerDidUpdateHomes:(HMHomeManager *)m {
    P(@"[%@] cb homeManagerDidUpdateHomes homes=%lu status=%lu %@", self.tag, (unsigned long)m.homes.count,
      (unsigned long)m.authorizationStatus, Th());
    if (self.onHomes) { void (^b)(void) = self.onHomes; self.onHomes = nil; b(); }
}
- (void)homeManagerDidUpdatePrimaryHome:(HMHomeManager *)m { P(@"[%@] cb homeManagerDidUpdatePrimaryHome", self.tag); }
- (void)homeManager:(HMHomeManager *)m didAddHome:(HMHome *)h { P(@"[%@] cb didAddHome %@", self.tag, h.name); }
- (void)homeManager:(HMHomeManager *)m didRemoveHome:(HMHome *)h { P(@"[%@] cb didRemoveHome %@", self.tag, h.name); }
- (void)homeDidUpdateName:(HMHome *)h { P(@"[%@] cb homeDidUpdateName %@", self.tag, h.name); }
- (void)homeDidUpdateAccessControlForCurrentUser:(HMHome *)h { P(@"[%@] cb homeDidUpdateAccessControlForCurrentUser", self.tag); }
- (void)home:(HMHome *)h didAddAccessory:(HMAccessory *)a { P(@"[%@] cb didAddAccessory", self.tag); }
- (void)home:(HMHome *)h didRemoveAccessory:(HMAccessory *)a { P(@"[%@] cb didRemoveAccessory", self.tag); }
- (void)home:(HMHome *)h didAddUser:(HMUser *)u { P(@"[%@] cb didAddUser", self.tag); }
- (void)home:(HMHome *)h didRemoveUser:(HMUser *)u { P(@"[%@] cb didRemoveUser", self.tag); }
- (void)home:(HMHome *)h didAddRoom:(HMRoom *)r { P(@"[%@] cb didAddRoom %@", self.tag, r.name); }
- (void)home:(HMHome *)h didRemoveRoom:(HMRoom *)r { P(@"[%@] cb didRemoveRoom %@", self.tag, r.name); }
- (void)home:(HMHome *)h didUpdateNameForRoom:(HMRoom *)r { P(@"[%@] cb didUpdateNameForRoom %@", self.tag, r.name); }
- (void)home:(HMHome *)h didAddZone:(HMZone *)z { P(@"[%@] cb didAddZone %@", self.tag, z.name); }
- (void)home:(HMHome *)h didRemoveZone:(HMZone *)z { P(@"[%@] cb didRemoveZone %@", self.tag, z.name); }
- (void)home:(HMHome *)h didUpdateNameForZone:(HMZone *)z { P(@"[%@] cb didUpdateNameForZone %@", self.tag, z.name); }
- (void)home:(HMHome *)h didAddRoom:(HMRoom *)r toZone:(HMZone *)z { P(@"[%@] cb didAddRoom %@ toZone %@", self.tag, r.name, z.name); }
- (void)home:(HMHome *)h didRemoveRoom:(HMRoom *)r fromZone:(HMZone *)z { P(@"[%@] cb didRemoveRoom %@ fromZone %@", self.tag, r.name, z.name); }
- (void)home:(HMHome *)h didAddServiceGroup:(HMServiceGroup *)g { P(@"[%@] cb didAddServiceGroup %@", self.tag, g.name); }
- (void)home:(HMHome *)h didRemoveServiceGroup:(HMServiceGroup *)g { P(@"[%@] cb didRemoveServiceGroup %@", self.tag, g.name); }
- (void)home:(HMHome *)h didUpdateNameForServiceGroup:(HMServiceGroup *)g { P(@"[%@] cb didUpdateNameForServiceGroup", self.tag); }
- (void)home:(HMHome *)h didAddActionSet:(HMActionSet *)s { P(@"[%@] cb didAddActionSet %@", self.tag, s.name); }
- (void)home:(HMHome *)h didRemoveActionSet:(HMActionSet *)s { P(@"[%@] cb didRemoveActionSet %@", self.tag, s.name); }
- (void)home:(HMHome *)h didUpdateNameForActionSet:(HMActionSet *)s { P(@"[%@] cb didUpdateNameForActionSet %@", self.tag, s.name); }
- (void)home:(HMHome *)h didUpdateActionsForActionSet:(HMActionSet *)s { P(@"[%@] cb didUpdateActionsForActionSet %@", self.tag, s.name); }
- (void)home:(HMHome *)h didAddTrigger:(HMTrigger *)t { P(@"[%@] cb didAddTrigger %@", self.tag, t.name); }
- (void)home:(HMHome *)h didRemoveTrigger:(HMTrigger *)t { P(@"[%@] cb didRemoveTrigger %@", self.tag, t.name); }
- (void)home:(HMHome *)h didUpdateNameForTrigger:(HMTrigger *)t { P(@"[%@] cb didUpdateNameForTrigger %@", self.tag, t.name); }
- (void)home:(HMHome *)h didUpdateTrigger:(HMTrigger *)t { P(@"[%@] cb didUpdateTrigger %@ enabled=%d", self.tag, t.name, t.enabled); }
- (void)home:(HMHome *)h didUpdateHomeHubState:(HMHomeHubState)s { P(@"[%@] cb didUpdateHomeHubState %lu", self.tag, (unsigned long)s); }
- (void)homeDidUpdateSupportedFeatures:(HMHome *)h { P(@"[%@] cb homeDidUpdateSupportedFeatures", self.tag); }
- (void)home:(HMHome *)h didEncounterError:(NSError *)e forAccessory:(HMAccessory *)a { P(@"[%@] cb didEncounterError %@", self.tag, E(e)); }
- (void)accessoryBrowser:(HMAccessoryBrowser *)b didFindNewAccessory:(HMAccessory *)a {
    // Counts and categories only: never names of devices on the network.
    P(@"[%@] cb browser didFindNewAccessory category=%@ total=%lu", self.tag, a.category.categoryType, (unsigned long)b.discoveredAccessories.count);
}
- (void)accessoryBrowser:(HMAccessoryBrowser *)b didRemoveNewAccessory:(HMAccessory *)a {
    P(@"[%@] cb browser didRemoveNewAccessory total=%lu", self.tag, (unsigned long)b.discoveredAccessories.count);
}
@end

#pragma mark - Step runner (sequential async steps with timeouts)

typedef void (^Done)(void);
typedef void (^Step)(Done done);

@interface Runner : NSObject
@property (nonatomic, strong) NSMutableArray<NSArray *> *steps; // [name, Step]
@property (nonatomic) NSUInteger index;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL abortRest;
- (void)add:(NSString *)name step:(Step)s;
- (void)run;
@end

@implementation Runner
- (instancetype)init { if ((self = [super init])) _steps = [NSMutableArray array]; return self; }
- (void)add:(NSString *)name step:(Step)s { [self.steps addObject:@[name, [s copy]]]; }
- (void)run {
    if (self.abortRest) { P(@"END aborted: remaining %lu steps need a home", (unsigned long)(self.steps.count - self.index)); return; }
    if (self.index >= self.steps.count) { P(@"END all steps done"); return; }
    NSArray *e = self.steps[self.index];
    NSString *name = e[0];
    Step s = e[1];
    NSUInteger gen = ++self.generation;
    __block BOOL finished = NO;
    P(@"STEP %@", name);
    Done done = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished || gen != self.generation) return;
            finished = YES;
            self.index++;
            [self run];
        });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (finished || gen != self.generation) return;
        P(@"TIMEOUT step %@ (no completion within 12 s)", name);
        finished = YES;
        self.index++;
        [self run];
    });
    s(done);
}
@end

#pragma mark - Dumps

static void DumpCharacteristic(HMCharacteristic *c, NSString *ind) {
    HMCharacteristicMetadata *m = c.metadata;
    P(@"%@char type=%@ desc=\"%@\" props=%@ value=%@ notif=%d meta(fmt=%@ units=%@ min=%@ max=%@ step=%@ maxLen=%@ valid=%@)",
      ind, c.characteristicType, c.localizedDescription, [c.properties componentsJoinedByString:@","], c.value,
      c.notificationEnabled, m.format, m.units, m.minimumValue, m.maximumValue, m.stepValue, m.maxLength,
      m.validValues);
}

static void DumpHome(HMHome *h) {
    P(@"home name=\"%@\" uuid=%@ primary=%d hub=%lu", h.name, U(h.uniqueIdentifier), h.primary, (unsigned long)h.homeHubState);
    HMUser *cu = h.currentUser;
    HMHomeAccessControl *ac = cu ? [h homeAccessControlForUser:cu] : nil;
    P(@"  currentUser name=\"%@\" uuid=%@ admin=%d", cu.name, U(cu.uniqueIdentifier), ac.administrator);
    HMRoom *er = [h roomForEntireHome];
    P(@"  roomForEntireHome name=\"%@\" uuid=%@ accessories=%lu sameObjTwice=%d", er.name, U(er.uniqueIdentifier),
      (unsigned long)er.accessories.count, er == [h roomForEntireHome]);
    P(@"  rooms=%@ zones=%@ groups=%@", Names(h.rooms), Names(h.zones), Names(h.serviceGroups));
    for (HMZone *z in h.zones) P(@"  zone \"%@\" rooms=%@", z.name, Names(z.rooms));
    for (HMActionSet *s in h.actionSets)
        P(@"  actionSet name=\"%@\" type=%@ actions=%lu executing=%d last=%@ uuid=%@", s.name, s.actionSetType,
          (unsigned long)s.actions.count, s.executing, s.lastExecutionDate, U(s.uniqueIdentifier));
    for (HMTrigger *t in h.triggers) {
        NSString *extra = @"";
        if ([t isKindOfClass:[HMEventTrigger class]]) {
            HMEventTrigger *et = (HMEventTrigger *)t;
            extra = [NSString stringWithFormat:@"events=%lu end=%lu activation=%lu once=%d pred=%@", (unsigned long)et.events.count,
                     (unsigned long)et.endEvents.count, (unsigned long)et.triggerActivationState, et.executeOnce, et.predicate];
        } else if ([t isKindOfClass:[HMTimerTrigger class]]) {
            HMTimerTrigger *tt = (HMTimerTrigger *)t;
            extra = [NSString stringWithFormat:@"fire=%@ recurrence=%@", tt.fireDate, tt.recurrence];
        }
        P(@"  trigger class=%@ name=\"%@\" enabled=%d actionSets=%@ %@", NSStringFromClass([t class]), t.name, t.enabled,
          Names(t.actionSets), extra);
    }
    P(@"  accessories=%lu users(deprecated)=? supportsAddingNetworkRouter=%d matterControllerID=%@",
      (unsigned long)h.accessories.count, h.supportsAddingNetworkRouter, h.matterControllerID);
    for (HMAccessory *a in h.accessories) {
        P(@"  accessory name=\"%@\" cat=%@ reachable=%d bridged=%d blocked=%d room=\"%@\" model=%@ mfr=%@ fw=%@ identify=%d services=%lu",
          a.name, a.category.categoryType, a.reachable, a.bridged, a.blocked, a.room.name, a.model, a.manufacturer,
          a.firmwareVersion, a.supportsIdentify, (unsigned long)a.services.count);
        for (HMService *s in a.services) {
            P(@"    service type=%@ name=\"%@\" primary=%d interactive=%d chars=%lu", s.serviceType, s.name, s.primaryService,
              s.userInteractive, (unsigned long)s.characteristics.count);
            for (HMCharacteristic *c in s.characteristics) DumpCharacteristic(c, @"      ");
        }
    }
}

#pragma mark - App

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) HMHomeManager *mgrA;
@property (nonatomic, strong) HMHomeManager *mgrB;
@property (nonatomic, strong) Obs *obsA;
@property (nonatomic, strong) Obs *obsB;
@property (nonatomic, strong) Obs *obsHomeA;
@property (nonatomic, strong) Obs *obsHomeB;
@property (nonatomic, strong) Runner *runner;
@property (nonatomic, strong) HMAccessoryBrowser *browser;
@property (nonatomic, strong) HMAccessorySetupManager *setupMgr;
@end

@implementation AppDelegate

- (NSString *)arg:(NSString *)name {
    NSArray *a = [NSProcessInfo processInfo].arguments;
    NSUInteger i = [a indexOfObject:name];
    return (i != NSNotFound && i + 1 < a.count) ? a[i + 1] : nil;
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    NSString *mode = [self arg:@"-mode"] ?: @"model";
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    P(@"START mode=%@ bundle=%@ usageString=%d os=%@", mode, NSBundle.mainBundle.bundleIdentifier,
      info[@"NSHomeKitUsageDescription"] != nil, UIDevice.currentDevice.systemVersion);
    // HomeKit work starts from didFinishLaunching (before any scene exists),
    // as many apps do; the scene only shows a label.
    if ([mode isEqualToString:@"consts"]) { [self consts]; return YES; }
    if ([mode isEqualToString:@"auth"]) { [self authOnly]; return YES; }
    if ([mode isEqualToString:@"list"]) { [self listOnly]; return YES; }
    if ([mode isEqualToString:@"cleanup"]) { [self cleanup]; return YES; }
    if ([mode isEqualToString:@"browse"]) { [self browse]; return YES; }
    if ([mode isEqualToString:@"setup"]) { [self setupFlow:NO]; return YES; }
    if ([mode isEqualToString:@"legacy"]) { [self setupFlow:YES]; return YES; }
    if ([mode isEqualToString:@"objects"]) { [self objects]; return YES; }
    [self model];
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = NSClassFromString(@"SceneDelegate");
    return c;
}

- (HMHomeManager *)makeManager:(NSString *)tag obs:(Obs **)outObs {
    Obs *o = [Obs new];
    o.tag = tag;
    CFTimeInterval t0 = CACurrentMediaTime();
    HMHomeManager *m = [HMHomeManager new];
    P(@"[%@] created manager in %.1f ms; status=%lu homes=%lu", tag, (CACurrentMediaTime() - t0) * 1000,
      (unsigned long)m.authorizationStatus, (unsigned long)m.homes.count);
    m.delegate = o;
    *outObs = o;
    return m;
}

- (void)authOnly {
    Obs *o;
    self.mgrA = [self makeManager:@"A" obs:&o];
    self.obsA = o;
    for (int i = 1; i <= 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            P(@"[A] poll %ds status=%lu homes=%lu", i * 5, (unsigned long)self.mgrA.authorizationStatus,
              (unsigned long)self.mgrA.homes.count);
        });
    }
}

- (void)listOnly {
    Obs *o;
    self.mgrA = [self makeManager:@"A" obs:&o];
    self.obsA = o;
    __weak typeof(self) ws = self;
    o.onHomes = ^{
        P(@"list homes=%lu", (unsigned long)ws.mgrA.homes.count);
        for (HMHome *h in ws.mgrA.homes) DumpHome(h);
        P(@"END list");
    };
}

- (void)cleanup {
    Obs *o;
    self.mgrA = [self makeManager:@"A" obs:&o];
    self.obsA = o;
    __weak typeof(self) ws = self;
    o.onHomes = ^{
        NSArray *homes = ws.mgrA.homes;
        P(@"cleanup removing %lu homes", (unsigned long)homes.count);
        __block NSUInteger left = homes.count;
        if (!left) P(@"END cleanup");
        for (HMHome *h in homes) {
            [ws.mgrA removeHome:h completionHandler:^(NSError *e) {
                P(@"removeHome -> %@", E(e));
                if (--left == 0) P(@"END cleanup homes=%lu", (unsigned long)ws.mgrA.homes.count);
            }];
        }
    };
}

- (void)browse {
    P(@"HMAccessorySetupManager.isSupported=%d", HMAccessorySetupManager.isSupported);
    Obs *o = [Obs new];
    o.tag = @"BR";
    self.obsA = o;
    self.browser = [HMAccessoryBrowser new];
    self.browser.delegate = o;
    P(@"browser created discovered=%lu", (unsigned long)self.browser.discoveredAccessories.count);
    [self.browser startSearchingForNewAccessories];
    P(@"browser started");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        P(@"browser after 10s discovered=%lu", (unsigned long)self.browser.discoveredAccessories.count);
        [self.browser stopSearchingForNewAccessories];
        P(@"END browse");
    });
}

- (void)setupFlow:(BOOL)legacy {
    P(@"HMAccessorySetupManager.isSupported=%d", HMAccessorySetupManager.isSupported);
    Obs *o;
    self.mgrA = [self makeManager:@"A" obs:&o];
    self.obsA = o;
    __weak typeof(self) ws = self;
    o.onHomes = ^{
        HMHome *h = ws.mgrA.homes.firstObject;
        P(@"setup: home=%@", h.name);
        if (legacy) {
            if (!h) { P(@"END legacy: no home"); return; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [h addAndSetupAccessoriesWithCompletionHandler:^(NSError *e) {
                P(@"addAndSetupAccessories -> %@ %@", E(e), Th());
            }];
#pragma clang diagnostic pop
            P(@"legacy flow started");
            return;
        }
        ws.setupMgr = [HMAccessorySetupManager new];
        HMAccessorySetupRequest *r = [HMAccessorySetupRequest new];
        r.homeUniqueIdentifier = h.uniqueIdentifier;
        r.suggestedAccessoryName = @"Probe Accessory";
        P(@"request copy equal=%d payload=%@", [[r copy] isEqual:r], r.payload);
        [ws.setupMgr performAccessorySetupUsingRequest:r completionHandler:^(HMAccessorySetupResult *res, NSError *e) {
            P(@"performAccessorySetup -> result=%@ home=%@ accs=%lu err=%@ %@", res, U(res.homeUniqueIdentifier),
              (unsigned long)res.accessoryUniqueIdentifiers.count, E(e), Th());
        }];
        P(@"setup flow started");
    };
}

- (void)consts {
    NSString *path = [NSBundle.mainBundle pathForResource:@"constnames" ofType:@"txt"];
    NSString *all = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSUInteger n = 0, missing = 0;
    for (NSString *name in [all componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!name.length) continue;
        NSString *__unsafe_unretained *p = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, name.UTF8String);
        if (!p) { P(@"CONST %@ = <missing>", name); missing++; continue; }
        P(@"CONST %@ = %@", name, *p);
        n++;
    }
    // Localized descriptions are only reachable through objects; the type
    // names are what HomeKit reports on HMService/HMCharacteristic.
    P(@"END consts found=%lu missing=%lu", (unsigned long)n, (unsigned long)missing);
}


#pragma mark - objects that need no home

- (void)objects {
    NSDateComponents *c = [NSDateComponents new];
    c.hour = 7; c.minute = 30;
    HMCalendarEvent *ce = [[HMCalendarEvent alloc] initWithFireDateComponents:c];
    HMSignificantTimeEvent *se = [[HMSignificantTimeEvent alloc] initWithSignificantEvent:HMSignificantEventSunset offset:nil];
    HMPresenceEvent *pe = [[HMPresenceEvent alloc] initWithPresenceEventType:HMPresenceEventTypeFirstEntry presenceUserType:HMPresenceEventUserTypeHomeUsers];
    HMDurationEvent *de = [[HMDurationEvent alloc] initWithDuration:300];
    CLCircularRegion *reg = [[CLCircularRegion alloc] initWithCenter:CLLocationCoordinate2DMake(37.33, -122.01) radius:100 identifier:@"probe"];
    HMLocationEvent *le = [[HMLocationEvent alloc] initWithRegion:reg];
    for (HMEvent *ev in @[ce, se, pe, de, le]) {
        id cp = [ev copy], mcp = [(id)ev mutableCopy];
        P(@"event %@ uuid=%@ copyClass=%@ copySame=%d copyEqual=%d copyUUIDEqual=%d mutableCopyClass=%@ isSupportedForHome(nil)=%d hash=%lu",
          NSStringFromClass([ev class]), U(ev.uniqueIdentifier), NSStringFromClass([cp class]), cp == ev, [cp isEqual:ev],
          [[cp uniqueIdentifier] isEqual:ev.uniqueIdentifier], NSStringFromClass([mcp class]), [[ev class] isSupportedForHome:(HMHome *)nil],
          (unsigned long)[ev hash]);
    }
    P(@"calendar fire=%@ | significant event=%@ offset=%@ | presence type=%lu user=%lu | duration=%.0f | region=%@",
      ce.fireDateComponents, se.significantEvent, se.offset, (unsigned long)pe.presenceEventType, (unsigned long)pe.presenceUserType,
      de.duration, le.region.identifier);
    HMSignificantTimeEvent *se2 = [[HMSignificantTimeEvent alloc] initWithSignificantEvent:HMSignificantEventSunset offset:nil];
    P(@"two equal sunset events isEqual=%d", [se isEqual:se2]);
    HMNumberRange *r1 = [HMNumberRange numberRangeWithMinValue:@1 maxValue:@5];
    HMNumberRange *r2 = [HMNumberRange numberRangeWithMinValue:@3];
    HMNumberRange *r3 = [HMNumberRange numberRangeWithMaxValue:@9];
    P(@"ranges r1=[%@,%@] r2=[%@,%@] r3=[%@,%@] equal(r1,r1')=%d", r1.minValue, r1.maxValue, r2.minValue, r2.maxValue,
      r3.minValue, r3.maxValue, [r1 isEqual:[HMNumberRange numberRangeWithMinValue:@1 maxValue:@5]]);
    @try {
        HMNumberRange *bad = [HMNumberRange numberRangeWithMinValue:@5 maxValue:@1];
        P(@"range min>max -> %@ [%@,%@]", bad, bad.minValue, bad.maxValue);
    } @catch (NSException *ex) { P(@"range min>max EXCEPTION %@: %@", ex.name, ex.reason); }
    NSDateComponents *d = [NSDateComponents new]; d.hour = 22;
    P(@"pred before 22h: %@", [HMEventTrigger predicateForEvaluatingTriggerOccurringBeforeDateWithComponents:d]);
    P(@"pred on 22h: %@", [HMEventTrigger predicateForEvaluatingTriggerOccurringOnDateWithComponents:d]);
    P(@"pred after sunrise: %@", [HMEventTrigger predicateForEvaluatingTriggerOccurringAfterSignificantEvent:
        [[HMSignificantTimeEvent alloc] initWithSignificantEvent:HMSignificantEventSunrise offset:nil]]);
    NSDateComponents *off = [NSDateComponents new]; off.minute = -30;
    P(@"pred before sunset-30m: %@", [HMEventTrigger predicateForEvaluatingTriggerOccurringBeforeSignificantEvent:
        [[HMSignificantTimeEvent alloc] initWithSignificantEvent:HMSignificantEventSunset offset:off]]);
    P(@"pred presence: %@", [HMEventTrigger predicateForEvaluatingTriggerWithPresence:pe]);
    HMEventTrigger *t = [[HMEventTrigger alloc] initWithName:@"Standalone" events:@[ce] predicate:nil];
    P(@"standalone event trigger name=%@ enabled=%d activation=%lu events=%lu end=%lu once=%d uuid=%@ actionSets=%lu",
      t.name, t.enabled, (unsigned long)t.triggerActivationState, (unsigned long)t.events.count, (unsigned long)t.endEvents.count,
      t.executeOnce, U(t.uniqueIdentifier), (unsigned long)t.actionSets.count);
    HMEventTrigger *t2 = [[HMEventTrigger alloc] initWithName:@"Standalone2" events:@[ce] endEvents:@[de] recurrences:nil predicate:nil];
    P(@"standalone event trigger with endEvents end=%lu", (unsigned long)t2.endEvents.count);
    HMTimerTrigger *tt = [[HMTimerTrigger alloc] initWithName:@"T" fireDate:[NSDate dateWithTimeIntervalSince1970:2000000000] recurrence:nil];
    P(@"standalone timer trigger fire=%@ enabled=%d tz=%@", tt.fireDate, tt.enabled, tt.timeZone);
    for (NSString *u in @[@"X-HM://0023ISYWY1234", @"X-HM://", @"https://example.com", @"MT:Y.K9042C00KA0648G00"]) {
        HMAccessorySetupPayload *pl = [[HMAccessorySetupPayload alloc] initWithURL:[NSURL URLWithString:u]];
        P(@"setupPayload initWithURL %@ -> %@", u, pl ? @"object" : @"nil");
    }
    HMAccessorySetupPayload *pn = [[HMAccessorySetupPayload alloc] initWithURL:nil];
    P(@"setupPayload initWithURL nil -> %@", pn ? @"object" : @"nil");
    HMAccessoryOwnershipToken *tok = [[HMAccessoryOwnershipToken alloc] initWithData:[NSData dataWithBytes:"abc" length:3]];
    P(@"ownershipToken initWithData(3 bytes) -> %@", tok ? @"object" : @"nil");
    HMAccessorySetupRequest *rq = [HMAccessorySetupRequest new];
    HMAccessorySetupRequest *rq2 = [rq copy];
    P(@"setupRequest defaults payload=%@ home=%@ room=%@ name=%@ matter=%@ copyEqual=%d", rq.payload, rq.homeUniqueIdentifier,
      rq.suggestedRoomUniqueIdentifier, rq.suggestedAccessoryName, rq.matterPayload, [rq isEqual:rq2]);
    P(@"HMAccessorySetupManager.isSupported=%d", HMAccessorySetupManager.isSupported);
    P(@"HMErrorDomain=%@", HMErrorDomain);
    P(@"END objects");
}

#pragma mark - model walk

- (void)model {
    Obs *oa, *ob;
    self.mgrA = [self makeManager:@"A" obs:&oa];
    self.obsA = oa;
    self.mgrB = [self makeManager:@"B" obs:&ob];
    self.obsB = ob;
    self.runner = [Runner new];
    Runner *R = self.runner;
    __weak typeof(self) ws = self;
    __block HMHome *home = nil, *home2 = nil;
    __block HMRoom *kitchen = nil, *living = nil;
    __block HMZone *zone = nil;
    __block HMServiceGroup *group = nil;
    __block HMActionSet *scene = nil;
    __block HMTimerTrigger *timer = nil;
    __block HMEventTrigger *evt = nil;

    [R add:@"wait-initial-homes" step:^(Done done) {
        if (ws.mgrA.homes.count || ws.mgrA.authorizationStatus & HMHomeManagerAuthorizationStatusDetermined) {
            // Still wait for the first callback; it tells us the data is loaded.
        }
        ws.obsA.onHomes = ^{ done(); };
    }];
    [R add:@"initial-state" step:^(Done done) {
        P(@"A status=%lu homes=%lu; B status=%lu homes=%lu", (unsigned long)ws.mgrA.authorizationStatus,
          (unsigned long)ws.mgrA.homes.count, (unsigned long)ws.mgrB.authorizationStatus, (unsigned long)ws.mgrB.homes.count);
        for (HMHome *h in ws.mgrA.homes) DumpHome(h);
        done();
    }];
    [R add:@"addHome" step:^(Done done) {
        CFTimeInterval t0 = CACurrentMediaTime();
        [ws.mgrA addHomeWithName:@"Probe Home" completionHandler:^(HMHome *h, NSError *e) {
            P(@"addHome -> home=%@ err=%@ %.0f ms %@ mgrA.homes=%lu", h.name, E(e), (CACurrentMediaTime() - t0) * 1000, Th(),
              (unsigned long)ws.mgrA.homes.count);
            home = h;
            if (h) {
                ws.obsHomeA = [Obs new]; ws.obsHomeA.tag = @"A.home"; h.delegate = ws.obsHomeA;
                DumpHome(h);
            }
            done();
        }];
    }];
    [R add:@"B-sees-home" step:^(Done done) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HMHome *hb = nil;
            for (HMHome *h in ws.mgrB.homes) if ([h.uniqueIdentifier isEqual:home.uniqueIdentifier]) hb = h;
            P(@"B homes=%lu sameUUID=%d sameObject=%d", (unsigned long)ws.mgrB.homes.count, hb != nil, hb == home);
            if (hb) { ws.obsHomeB = [Obs new]; ws.obsHomeB.tag = @"B.home"; hb.delegate = ws.obsHomeB; }
            done();
        });
    }];
    [R add:@"addHome-duplicate" step:^(Done done) {
        [ws.mgrA addHomeWithName:@"Probe Home" completionHandler:^(HMHome *h, NSError *e) {
            P(@"addHome dup -> home=%@ err=%@", h.name, E(e)); home2 = h; done();
        }];
    }];
    [R add:@"addHome-casefold" step:^(Done done) {
        [ws.mgrA addHomeWithName:@"probe home" completionHandler:^(HMHome *h, NSError *e) {
            P(@"addHome case -> home=%@ err=%@", h.name, E(e)); if (h) home2 = h; done();
        }];
    }];
    [R add:@"addHome-empty" step:^(Done done) {
        [ws.mgrA addHomeWithName:@"" completionHandler:^(HMHome *h, NSError *e) {
            P(@"addHome empty -> home=%@ err=%@", h.name, E(e)); done();
        }];
    }];
    [R add:@"addHome-badchars" step:^(Done done) {
        [ws.mgrA addHomeWithName:@"#Bad!" completionHandler:^(HMHome *h, NSError *e) {
            P(@"addHome '#Bad!' -> home=%@ err=%@", h.name, E(e)); if (h) home2 = h; done();
        }];
    }];
    [R add:@"addHome-second" step:^(Done done) {
        if (home2) { P(@"second home already exists: %@", home2.name); done(); return; }
        [ws.mgrA addHomeWithName:@"Probe Cabin" completionHandler:^(HMHome *h, NSError *e) {
            P(@"addHome second -> home=%@ primary=%d err=%@", h.name, h.primary, E(e)); home2 = h; done();
        }];
    }];
    [R add:@"gate-home" step:^(Done done) {
        if (!home) { P(@"no home could be created; the steps below need one"); R.abortRest = YES; }
        done();
    }];
    [R add:@"builtin-actionsets" step:^(Done done) {
        for (NSString *t in @[HMActionSetTypeWakeUp, HMActionSetTypeSleep, HMActionSetTypeHomeDeparture,
                               HMActionSetTypeHomeArrival, HMActionSetTypeUserDefined, HMActionSetTypeTriggerOwned]) {
            HMActionSet *s = [home builtinActionSetOfType:t];
            P(@"builtinActionSetOfType %@ -> %@ (%@)", t, s.name, s.actionSetType);
        }
        done();
    }];
    [R add:@"addRoom" step:^(Done done) {
        [home addRoomWithName:@"Kitchen" completionHandler:^(HMRoom *r, NSError *e) {
            P(@"addRoom Kitchen -> %@ err=%@ %@ rooms=%@", r.name, E(e), Th(), Names(home.rooms)); kitchen = r; done();
        }];
    }];
    [R add:@"addRoom-2" step:^(Done done) {
        [home addRoomWithName:@"Living Room" completionHandler:^(HMRoom *r, NSError *e) {
            P(@"addRoom Living Room -> %@ err=%@", r.name, E(e)); living = r; done();
        }];
    }];
    [R add:@"addRoom-dup" step:^(Done done) {
        [home addRoomWithName:@"Kitchen" completionHandler:^(HMRoom *r, NSError *e) {
            P(@"addRoom dup -> %@ err=%@", r.name, E(e)); done();
        }];
    }];
    [R add:@"addRoom-same-as-home" step:^(Done done) {
        [home addRoomWithName:@"Probe Home" completionHandler:^(HMRoom *r, NSError *e) {
            P(@"addRoom named like home -> %@ err=%@", r.name, E(e)); done();
        }];
    }];
    [R add:@"renameRoom" step:^(Done done) {
        [living updateName:@"Lounge" completionHandler:^(NSError *e) {
            P(@"room updateName Lounge -> %@ name=%@", E(e), living.name); done();
        }];
    }];
    [R add:@"renameEntireHomeRoom" step:^(Done done) {
        [[home roomForEntireHome] updateName:@"Everywhere" completionHandler:^(NSError *e) {
            P(@"roomForEntireHome updateName -> %@ name=%@", E(e), [home roomForEntireHome].name); done();
        }];
    }];
    [R add:@"addZone" step:^(Done done) {
        [home addZoneWithName:@"Downstairs" completionHandler:^(HMZone *z, NSError *e) {
            P(@"addZone -> %@ err=%@", z.name, E(e)); zone = z; done();
        }];
    }];
    [R add:@"zone-addRoom" step:^(Done done) {
        [zone addRoom:kitchen completionHandler:^(NSError *e) {
            P(@"zone addRoom Kitchen -> %@ zone.rooms=%@", E(e), Names(zone.rooms)); done();
        }];
    }];
    [R add:@"zone-addRoom-again" step:^(Done done) {
        [zone addRoom:kitchen completionHandler:^(NSError *e) {
            P(@"zone addRoom Kitchen again -> %@", E(e)); done();
        }];
    }];
    [R add:@"zone-addEntireHomeRoom" step:^(Done done) {
        [zone addRoom:[home roomForEntireHome] completionHandler:^(NSError *e) {
            P(@"zone addRoom roomForEntireHome -> %@", E(e)); done();
        }];
    }];
    [R add:@"addServiceGroup" step:^(Done done) {
        [home addServiceGroupWithName:@"Probe Group" completionHandler:^(HMServiceGroup *g, NSError *e) {
            P(@"addServiceGroup -> %@ err=%@ services=%lu", g.name, E(e), (unsigned long)g.services.count); group = g; done();
        }];
    }];
    [R add:@"addActionSet" step:^(Done done) {
        [home addActionSetWithName:@"Probe Scene" completionHandler:^(HMActionSet *s, NSError *e) {
            P(@"addActionSet -> %@ type=%@ err=%@", s.name, s.actionSetType, E(e)); scene = s; done();
        }];
    }];
    [R add:@"addActionSet-dup" step:^(Done done) {
        [home addActionSetWithName:@"Probe Scene" completionHandler:^(HMActionSet *s, NSError *e) {
            P(@"addActionSet dup -> %@ err=%@", s.name, E(e)); done();
        }];
    }];
    [R add:@"executeActionSet-empty" step:^(Done done) {
        [home executeActionSet:scene completionHandler:^(NSError *e) {
            P(@"executeActionSet empty -> %@ %@", E(e), Th()); done();
        }];
    }];
    [R add:@"executeBuiltin" step:^(Done done) {
        HMActionSet *s = [home builtinActionSetOfType:HMActionSetTypeWakeUp];
        if (!s) { P(@"no builtin wakeup"); done(); return; }
        [home executeActionSet:s completionHandler:^(NSError *e) { P(@"executeActionSet builtin -> %@", E(e)); done(); }];
    }];
    [R add:@"removeBuiltin" step:^(Done done) {
        HMActionSet *s = [home builtinActionSetOfType:HMActionSetTypeSleep];
        if (!s) { P(@"no builtin sleep"); done(); return; }
        [home removeActionSet:s completionHandler:^(NSError *e) { P(@"removeActionSet builtin -> %@", E(e)); done(); }];
    }];
    [R add:@"timerTrigger-past" step:^(Done done) {
        HMTimerTrigger *t = [[HMTimerTrigger alloc] initWithName:@"Past" fireDate:[NSDate dateWithTimeIntervalSinceNow:-3600] recurrence:nil];
        [home addTrigger:t completionHandler:^(NSError *e) { P(@"addTrigger past -> %@", E(e)); done(); }];
    }];
    [R add:@"timerTrigger-oddseconds" step:^(Done done) {
        NSDate *d = [NSDate dateWithTimeIntervalSinceNow:7200 + 17];
        HMTimerTrigger *t = [[HMTimerTrigger alloc] initWithName:@"Odd" fireDate:d recurrence:nil];
        [home addTrigger:t completionHandler:^(NSError *e) { P(@"addTrigger odd-seconds -> %@ fire=%@", E(e), t.fireDate); done(); }];
    }];
    [R add:@"timerTrigger" step:^(Done done) {
        NSCalendar *cal = NSCalendar.currentCalendar;
        NSDate *d = [cal dateBySettingUnit:NSCalendarUnitSecond value:0 ofDate:[NSDate dateWithTimeIntervalSinceNow:3 * 3600] options:0];
        NSDateComponents *rec = [NSDateComponents new];
        rec.day = 1;
        timer = [[HMTimerTrigger alloc] initWithName:@"Probe Timer" fireDate:d recurrence:rec];
        P(@"timer before add: enabled=%d fire=%@ actionSets=%lu", timer.enabled, timer.fireDate, (unsigned long)timer.actionSets.count);
        [home addTrigger:timer completionHandler:^(NSError *e) {
            P(@"addTrigger timer -> %@ triggers=%lu", E(e), (unsigned long)home.triggers.count); done();
        }];
    }];
    [R add:@"timer-addActionSet" step:^(Done done) {
        [timer addActionSet:scene completionHandler:^(NSError *e) { P(@"timer addActionSet -> %@", E(e)); done(); }];
    }];
    [R add:@"timer-enable" step:^(Done done) {
        [timer enable:YES completionHandler:^(NSError *e) { P(@"timer enable -> %@ enabled=%d", E(e), timer.enabled); done(); }];
    }];
    [R add:@"eventTrigger-calendar" step:^(Done done) {
        NSDateComponents *c = [NSDateComponents new];
        c.hour = 7; c.minute = 30;
        HMCalendarEvent *ce = [[HMCalendarEvent alloc] initWithFireDateComponents:c];
        HMSignificantTimeEvent *se = [[HMSignificantTimeEvent alloc] initWithSignificantEvent:HMSignificantEventSunset offset:nil];
        HMPresenceEvent *pe = [[HMPresenceEvent alloc] initWithPresenceEventType:HMPresenceEventTypeFirstEntry presenceUserType:HMPresenceEventUserTypeHomeUsers];
        HMDurationEvent *de = [[HMDurationEvent alloc] initWithDuration:300];
        CLCircularRegion *reg = [[CLCircularRegion alloc] initWithCenter:CLLocationCoordinate2DMake(37.33, -122.01) radius:100 identifier:@"probe"];
        HMLocationEvent *le = [[HMLocationEvent alloc] initWithRegion:reg];
        for (HMEvent *ev in @[ce, se, pe, de, le])
            P(@"event %@ isSupportedForHome=%d copyClass=%@ mutableCopyClass=%@ uuid=%@", NSStringFromClass([ev class]),
              [[ev class] isSupportedForHome:home], NSStringFromClass([[ev copy] class]),
              NSStringFromClass([[(id)ev mutableCopy] class]), U(ev.uniqueIdentifier));
        evt = [[HMEventTrigger alloc] initWithName:@"Probe Morning" events:@[ce] predicate:nil];
        P(@"eventTrigger before add: activation=%lu enabled=%d", (unsigned long)evt.triggerActivationState, evt.enabled);
        [home addTrigger:evt completionHandler:^(NSError *e) {
            P(@"addTrigger event(calendar) -> %@ activation=%lu", E(e), (unsigned long)evt.triggerActivationState); done();
        }];
    }];
    [R add:@"eventTrigger-sunset" step:^(Done done) {
        HMSignificantTimeEvent *se = [[HMSignificantTimeEvent alloc] initWithSignificantEvent:HMSignificantEventSunset offset:nil];
        HMEventTrigger *t = [[HMEventTrigger alloc] initWithName:@"Probe Sunset" events:@[se] predicate:nil];
        [home addTrigger:t completionHandler:^(NSError *e) { P(@"addTrigger event(sunset) -> %@ activation=%lu", E(e), (unsigned long)t.triggerActivationState); done(); }];
    }];
    [R add:@"eventTrigger-presence" step:^(Done done) {
        HMPresenceEvent *pe = [[HMPresenceEvent alloc] initWithPresenceEventType:HMPresenceEventTypeFirstEntry presenceUserType:HMPresenceEventUserTypeHomeUsers];
        HMEventTrigger *t = [[HMEventTrigger alloc] initWithName:@"Probe Arrive" events:@[pe] predicate:nil];
        [home addTrigger:t completionHandler:^(NSError *e) { P(@"addTrigger event(presence) -> %@ activation=%lu", E(e), (unsigned long)t.triggerActivationState); done(); }];
    }];
    [R add:@"eventTrigger-addActionSet" step:^(Done done) {
        [evt addActionSet:scene completionHandler:^(NSError *e) { P(@"event addActionSet -> %@", E(e)); done(); }];
    }];
    [R add:@"eventTrigger-enable" step:^(Done done) {
        [evt enable:YES completionHandler:^(NSError *e) {
            P(@"event enable -> %@ enabled=%d activation=%lu", E(e), evt.enabled, (unsigned long)evt.triggerActivationState); done();
        }];
    }];
    [R add:@"predicates" step:^(Done done) {
        NSDateComponents *c = [NSDateComponents new]; c.hour = 22;
        HMSignificantTimeEvent *se = [[HMSignificantTimeEvent alloc] initWithSignificantEvent:HMSignificantEventSunrise offset:nil];
        P(@"pred before 22h: %@", [HMEventTrigger predicateForEvaluatingTriggerOccurringBeforeDateWithComponents:c]);
        P(@"pred after sunrise: %@", [HMEventTrigger predicateForEvaluatingTriggerOccurringAfterSignificantEvent:se]);
        HMPresenceEvent *pe = [[HMPresenceEvent alloc] initWithPresenceEventType:HMPresenceEventTypeAtHome presenceUserType:HMPresenceEventUserTypeCurrentUser];
        P(@"pred presence: %@", [HMEventTrigger predicateForEvaluatingTriggerWithPresence:pe]);
        done();
    }];
    [R add:@"dump-after-build" step:^(Done done) { DumpHome(home); done(); }];
    [R add:@"B-view" step:^(Done done) {
        for (HMHome *h in ws.mgrB.homes) if ([h.uniqueIdentifier isEqual:home.uniqueIdentifier]) {
            P(@"B view: rooms=%@ zones=%@ actionSets=%lu triggers=%lu", Names(h.rooms), Names(h.zones),
              (unsigned long)h.actionSets.count, (unsigned long)h.triggers.count);
        }
        done();
    }];
    [R add:@"renameHome" step:^(Done done) {
        [home updateName:@"Probe House" completionHandler:^(NSError *e) { P(@"home updateName -> %@ name=%@", E(e), home.name); done(); }];
    }];
    [R add:@"renameHome-to-other" step:^(Done done) {
        [home updateName:home2.name ?: @"Probe Cabin" completionHandler:^(NSError *e) { P(@"home rename to other home's name -> %@", E(e)); done(); }];
    }];
    [R add:@"primary" step:^(Done done) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        P(@"primaryHome=%@", ws.mgrA.primaryHome.name);
        [ws.mgrA updatePrimaryHome:home2 completionHandler:^(NSError *e) {
            P(@"updatePrimaryHome -> %@ primary now=%@", E(e), ws.mgrA.primaryHome.name); done();
        }];
#pragma clang diagnostic pop
    }];
    [R add:@"manageUsers" step:^(Done done) {
        // Presents system UI on a device; record what the simulator does.
        [home manageUsersWithCompletionHandler:^(NSError *e) { P(@"manageUsers -> %@", E(e)); done(); }];
    }];
    [R add:@"removeTrigger" step:^(Done done) {
        [home removeTrigger:timer completionHandler:^(NSError *e) { P(@"removeTrigger -> %@ triggers=%lu", E(e), (unsigned long)home.triggers.count); done(); }];
    }];
    [R add:@"zone-removeRoom" step:^(Done done) {
        [zone removeRoom:kitchen completionHandler:^(NSError *e) { P(@"zone removeRoom -> %@", E(e)); done(); }];
    }];
    [R add:@"removeRoom" step:^(Done done) {
        [home removeRoom:kitchen completionHandler:^(NSError *e) { P(@"removeRoom -> %@ rooms=%@", E(e), Names(home.rooms)); done(); }];
    }];
    [R add:@"removeRoom-again" step:^(Done done) {
        [home removeRoom:kitchen completionHandler:^(NSError *e) { P(@"removeRoom again -> %@", E(e)); done(); }];
    }];
    [R add:@"removeEntireHomeRoom" step:^(Done done) {
        [home removeRoom:[home roomForEntireHome] completionHandler:^(NSError *e) { P(@"removeRoom roomForEntireHome -> %@", E(e)); done(); }];
    }];
    [R add:@"removeGroup" step:^(Done done) {
        [home removeServiceGroup:group completionHandler:^(NSError *e) { P(@"removeServiceGroup -> %@", E(e)); done(); }];
    }];
    [R add:@"removeHome-second" step:^(Done done) {
        if (!home2) { done(); return; }
        [ws.mgrA removeHome:home2 completionHandler:^(NSError *e) { P(@"removeHome second -> %@ homes=%lu", E(e), (unsigned long)ws.mgrA.homes.count); done(); }];
    }];
    [R add:@"settle" step:^(Done done) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            P(@"final A homes=%lu B homes=%lu", (unsigned long)ws.mgrA.homes.count, (unsigned long)ws.mgrB.homes.count);
            done();
        });
    }];
    [R run];
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 20, 160)];
    l.numberOfLines = 0;
    l.text = @"HMProbe";
    [vc.view addSubview:l];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    P(@"scene connected");
}
- (void)sceneDidBecomeActive:(UIScene *)scene { P(@"scene active"); }
- (void)sceneWillResignActive:(UIScene *)scene { P(@"scene resign active"); }
@end

int main(int argc, char *argv[]) {
    gStart = CACurrentMediaTime();
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
