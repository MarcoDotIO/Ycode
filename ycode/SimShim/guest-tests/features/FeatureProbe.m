// FeatureProbe.app (dev.ycode.FeatureProbe): the guest probe of the settings
// features (specs/simulator/simulator-features.md "Ycode implementation",
// verification). A UIKit app that shows and prints, with milliseconds since
// launch on every line ("probe: <ms> …"):
//   - its trait collection (style, content size, contrast, legibility
//     weight) at launch and at every change;
//   - UIAccessibility's switches at launch, at every status notification,
//     and every 5 s (with the VoiceOver state);
//   - UIContentSizeCategoryDidChange;
//   - location: authorization, every update (coordinate, accuracy, speed,
//     course), every error;
//   - audio: the session's output volume and route, every 5 s and on route
//     changes.
// The screen: a large title, a system button with a text title (Show
// Borders underlines it), a glass/blur panel, and coloured bars (a colour
// filter changes them in a screenshot).

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <AVFoundation/AVFoundation.h>
#import <Accessibility/Accessibility.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static CFAbsoluteTime gStart;

static void say(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // Milliseconds since launch, then the wall clock (Unix ms; the guest's
    // calendar time is the host's) to line events up with host commands.
    fprintf(stdout, "probe: %lld %s [wall %lld]\n", (long long)((CFAbsoluteTimeGetCurrent() - gStart) * 1000), s.UTF8String,
            (long long)((CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970) * 1000));
    fflush(stdout);
}

static NSString *styleName(UIUserInterfaceStyle s) {
    return s == UIUserInterfaceStyleDark ? @"dark" : s == UIUserInterfaceStyleLight ? @"light" : @"unspecified";
}

static NSString *traitsLine(UITraitCollection *t) {
    return [NSString stringWithFormat:@"style=%@ size=%@ contrast=%@ weight=%@", styleName(t.userInterfaceStyle),
            t.preferredContentSizeCategory,
            t.accessibilityContrast == UIAccessibilityContrastHigh ? @"high" : t.accessibilityContrast == UIAccessibilityContrastNormal ? @"normal" : @"unspecified",
            t.legibilityWeight == UILegibilityWeightBold ? @"bold" : @"regular"];
}

static NSString *axLine(void) {
    return [NSString stringWithFormat:@"reduceMotion=%d reduceTransparency=%d darkerColors=%d buttonShapes=%d grayscale=%d "
            "boldText=%d onOffLabels=%d invert=%d differentiate=%d voiceOver=%d",
            UIAccessibilityIsReduceMotionEnabled(), UIAccessibilityIsReduceTransparencyEnabled(),
            UIAccessibilityDarkerSystemColorsEnabled(), AXShowBordersEnabled(),
            UIAccessibilityIsGrayscaleEnabled(), UIAccessibilityIsBoldTextEnabled(),
            UIAccessibilityIsOnOffSwitchLabelsEnabled(), UIAccessibilityIsInvertColorsEnabled(),
            UIAccessibilityShouldDifferentiateWithoutColor(), UIAccessibilityIsVoiceOverRunning()];
}

@interface ProbeView : UIView
@property (nonatomic, strong) UILabel *label;
@end

@implementation ProbeView
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    say(@"traits %@", traitsLine(self.traitCollection));
    self.label.text = traitsLine(self.traitCollection);
}
@end

@interface ProbeController : UIViewController <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *location;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *where;
@end

@implementation ProbeController

- (void)loadView {
    ProbeView *v = [ProbeView new];
    v.backgroundColor = UIColor.systemBackgroundColor;
    self.view = v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
    ]];
    UILabel *title = [UILabel new];
    title.text = @"Feature Probe";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    title.adjustsFontForContentSizeCategory = YES;
    [stack addArrangedSubview:title];
    UILabel *body = [UILabel new];
    body.numberOfLines = 0;
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    body.adjustsFontForContentSizeCategory = YES;
    ((ProbeView *)self.view).label = body;
    body.text = traitsLine(self.traitCollection);
    [stack addArrangedSubview:body];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"A Text Button" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [stack addArrangedSubview:button];
    // Coloured bars: red, green, blue, yellow.
    UIStackView *bars = [UIStackView new];
    bars.distribution = UIStackViewDistributionFillEqually;
    for (UIColor *c in @[UIColor.systemRedColor, UIColor.systemGreenColor, UIColor.systemBlueColor, UIColor.systemYellowColor]) {
        UIView *bar = [UIView new];
        bar.backgroundColor = c;
        [bars addArrangedSubview:bar];
    }
    [bars.heightAnchor constraintEqualToConstant:80].active = YES;
    [stack addArrangedSubview:bars];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    [blur.heightAnchor constraintEqualToConstant:60].active = YES;
    UILabel *blurLabel = [UILabel new];
    blurLabel.text = @"Material";
    blurLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [blur.contentView addSubview:blurLabel];
    [blurLabel.centerXAnchor constraintEqualToAnchor:blur.contentView.centerXAnchor].active = YES;
    [blurLabel.centerYAnchor constraintEqualToAnchor:blur.contentView.centerYAnchor].active = YES;
    [stack addArrangedSubview:blur];
    self.where = [UILabel new];
    self.where.numberOfLines = 0;
    self.where.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.where.adjustsFontForContentSizeCategory = YES;
    self.where.text = @"Location: waiting";
    [stack addArrangedSubview:self.where];
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.status.adjustsFontForContentSizeCategory = YES;
    [stack addArrangedSubview:self.status];

    say(@"launch traits %@", traitsLine(self.traitCollection));
    say(@"launch ax %@", axLine());
    for (NSString *name in @[UIAccessibilityReduceMotionStatusDidChangeNotification, UIAccessibilityReduceTransparencyStatusDidChangeNotification,
                             UIAccessibilityDarkerSystemColorsStatusDidChangeNotification, AXShowBordersEnabledStatusDidChangeNotification,
                             UIAccessibilityGrayscaleStatusDidChangeNotification, UIAccessibilityVoiceOverStatusDidChangeNotification,
                             UIAccessibilityBoldTextStatusDidChangeNotification, UIAccessibilityInvertColorsStatusDidChangeNotification,
                             UIAccessibilityShouldDifferentiateWithoutColorDidChangeNotification, UIAccessibilityOnOffSwitchLabelsDidChangeNotification,
                             UIContentSizeCategoryDidChangeNotification, AVAudioSessionRouteChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            say(@"notification %@ ax %@ size %@", n.name, axLine(), UIApplication.sharedApplication.preferredContentSizeCategory);
        }];
    }
    self.location = [CLLocationManager new];
    self.location.delegate = self;
    self.location.desiredAccuracy = kCLLocationAccuracyBest;
    [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [self tick];
    }];
    [self tick];
}

- (void)tick {
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSMutableArray *outs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) [outs addObject:[NSString stringWithFormat:@"%@(%@)", p.portName, p.portType]];
    NSString *audio = [NSString stringWithFormat:@"volume=%.2f outputs=%@", s.outputVolume, [outs componentsJoinedByString:@","]];
    say(@"state traits %@ | ax %@ | audio %@", traitsLine(self.view.traitCollection), axLine(), audio);
    self.status.text = [NSString stringWithFormat:@"%@\n%@", axLine(), audio];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)m {
    say(@"location authorization %d", (int)m.authorizationStatus);
    if (m.authorizationStatus == kCLAuthorizationStatusNotDetermined) [m requestWhenInUseAuthorization];
    if (m.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse || m.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways) {
        [m startUpdatingLocation];
    }
}

- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)m;
    for (CLLocation *l in locations) {
        say(@"location %.6f,%.6f acc=%.0f speed=%.2f course=%.1f alt=%.1f age=%.1f", l.coordinate.latitude, l.coordinate.longitude,
            l.horizontalAccuracy, l.speed, l.course, l.altitude, -l.timestamp.timeIntervalSinceNow);
        self.where.text = [NSString stringWithFormat:@"Location: %.5f, %.5f (±%.0f m, %.1f m/s)", l.coordinate.latitude,
                           l.coordinate.longitude, l.horizontalAccuracy, l.speed];
    }
}

- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)error {
    (void)m;
    say(@"location error %@ %ld", error.domain, (long)error.code);
}
@end

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProbeDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)app;
    (void)options;
    say(@"didFinishLaunching");
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options {
    (void)app;
    (void)options;
    UISceneConfiguration *c = [UISceneConfiguration configurationWithName:@"Default" sessionRole:session.role];
    c.delegateClass = NSClassFromString(@"ProbeSceneDelegate");
    return c;
}
@end

// The scene life cycle (required for apps built with the iOS 27 SDK).
@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session;
    (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ProbeController new];
    [self.window makeKeyAndVisible];
}
@end

int main(int argc, char **argv) {
    gStart = CFAbsoluteTimeGetCurrent();
    @autoreleasepool {
        say(@"start pid %d", getpid());
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class));
    }
}
