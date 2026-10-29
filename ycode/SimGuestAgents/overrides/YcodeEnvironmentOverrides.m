// libYcodeEnvironmentOverrides.dylib: Environment Overrides inside one app
// (specs/simulator/simulator-features.md §7.3; "Ycode implementation" §I.6;
// YcodeSimFeatures/EnvironmentOverrides.swift has the model).
//
// ycode-simd launches an app with DYLD_INSERT_LIBRARIES naming this library
// and YCODE_ENV_OVERRIDES_DIR naming a directory of the device. The library
// reads `<dir>/<bundle id>.plist` at launch and again on the Darwin
// notification `dev.ycode.environment-overrides.changed`, and applies it to
// this process only:
//   - appearance, Dynamic Type, Increase Contrast and Bold Text as trait
//     overrides of every window scene (UIKit's public UITraitOverrides);
//   - the accessibility switches by answering UIKit's public status
//     functions (dyld interposing, a public dyld feature) and posting their
//     public change notifications.
// Keys: appearance "light"|"dark", dynamic-type "<UICTContentSizeCategory…>",
// increase-contrast, reduce-transparency, bold-text, reduce-motion,
// on-off-labels, button-shapes, grayscale, smart-invert,
// differentiate-without-color (booleans). An absent key is "No Override".

#import <UIKit/UIKit.h>
#import <Accessibility/Accessibility.h>
#import <notify.h>

// Button Shapes: the iOS 26.1+ name (Show Borders, AXShowBordersEnabled) and the older UIKit one.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSDictionary *gOverrides;
static NSString *gPath;

static void say(NSString *s) {
    fprintf(stderr, "ycode-overrides: %s\n", s.UTF8String);
    fflush(stderr);
}

/// -1 no override, 0 off, 1 on.
static int overrideOf(NSString *key) {
    NSDictionary *o = gOverrides;
    id v = o[key];
    if (![v respondsToSelector:@selector(boolValue)]) return -1;
    return [v boolValue] ? 1 : 0;
}

// MARK: - The status functions

#define YCODE_INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *r; const void *o; } _interpose_##original \
    __attribute__((section("__DATA,__interpose"))) = {(const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original};

#define YCODE_SWITCH(fn, key) \
    static BOOL ycode_##fn(void) { int v = overrideOf(key); return v < 0 ? fn() : (BOOL)v; } \
    YCODE_INTERPOSE(ycode_##fn, fn)

YCODE_SWITCH(UIAccessibilityIsReduceMotionEnabled, @"reduce-motion")
YCODE_SWITCH(UIAccessibilityIsReduceTransparencyEnabled, @"reduce-transparency")
YCODE_SWITCH(UIAccessibilityIsBoldTextEnabled, @"bold-text")
YCODE_SWITCH(UIAccessibilityIsOnOffSwitchLabelsEnabled, @"on-off-labels")
YCODE_SWITCH(UIAccessibilityButtonShapesEnabled, @"button-shapes")
YCODE_SWITCH(AXShowBordersEnabled, @"button-shapes")
YCODE_SWITCH(UIAccessibilityIsGrayscaleEnabled, @"grayscale")
YCODE_SWITCH(UIAccessibilityIsInvertColorsEnabled, @"smart-invert")
YCODE_SWITCH(UIAccessibilityShouldDifferentiateWithoutColor, @"differentiate-without-color")
YCODE_SWITCH(UIAccessibilityDarkerSystemColorsEnabled, @"increase-contrast")

// MARK: - Trait overrides

static void applyToScene(UIWindowScene *scene) API_AVAILABLE(ios(17.0)) {
    id<UITraitOverrides> t = scene.traitOverrides;
    NSString *appearance = gOverrides[@"appearance"];
    if ([appearance isEqual:@"dark"]) t.userInterfaceStyle = UIUserInterfaceStyleDark;
    else if ([appearance isEqual:@"light"]) t.userInterfaceStyle = UIUserInterfaceStyleLight;
    else if ([t containsTrait:UITraitUserInterfaceStyle.class]) [t removeTrait:UITraitUserInterfaceStyle.class];

    NSString *size = gOverrides[@"dynamic-type"];
    if ([size isKindOfClass:NSString.class]) t.preferredContentSizeCategory = size;
    else if ([t containsTrait:UITraitPreferredContentSizeCategory.class]) [t removeTrait:UITraitPreferredContentSizeCategory.class];

    int contrast = overrideOf(@"increase-contrast");
    if (contrast >= 0) t.accessibilityContrast = contrast ? UIAccessibilityContrastHigh : UIAccessibilityContrastNormal;
    else if ([t containsTrait:UITraitAccessibilityContrast.class]) [t removeTrait:UITraitAccessibilityContrast.class];

    int bold = overrideOf(@"bold-text");
    if (bold >= 0) t.legibilityWeight = bold ? UILegibilityWeightBold : UILegibilityWeightRegular;
    else if ([t containsTrait:UITraitLegibilityWeight.class]) [t removeTrait:UITraitLegibilityWeight.class];
}

static void applyToAllScenes(void) {
    if (@available(iOS 17.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) applyToScene((UIWindowScene *)s);
        }
    }
}

// MARK: - Loading

static NSDictionary *readFile(void) {
    NSDictionary *d = gPath ? [NSDictionary dictionaryWithContentsOfFile:gPath] : nil;
    return d ?: @{};
}

static void reload(BOOL announce) {
    NSDictionary *old = gOverrides ?: @{};
    gOverrides = readFile();
    say([NSString stringWithFormat:@"%@: %@", gPath.lastPathComponent,
         gOverrides.count ? [[gOverrides.description componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
                                componentsJoinedByString:@" "] : @"no overrides"]);
    applyToAllScenes();
    if (!announce) return;
    NSDictionary<NSString *, NSString *> *notes = @{
        @"reduce-motion": UIAccessibilityReduceMotionStatusDidChangeNotification,
        @"reduce-transparency": UIAccessibilityReduceTransparencyStatusDidChangeNotification,
        @"bold-text": UIAccessibilityBoldTextStatusDidChangeNotification,
        @"on-off-labels": UIAccessibilityOnOffSwitchLabelsDidChangeNotification,
        @"button-shapes": UIAccessibilityButtonShapesEnabledStatusDidChangeNotification,
        @"grayscale": UIAccessibilityGrayscaleStatusDidChangeNotification,
        @"smart-invert": UIAccessibilityInvertColorsStatusDidChangeNotification,
        @"differentiate-without-color": UIAccessibilityShouldDifferentiateWithoutColorDidChangeNotification,
        @"increase-contrast": UIAccessibilityDarkerSystemColorsStatusDidChangeNotification,
    };
    for (NSString *key in notes) {
        if (![old[key] isEqual:gOverrides[key]] && !(old[key] == nil && gOverrides[key] == nil)) {
            [NSNotificationCenter.defaultCenter postNotificationName:notes[key] object:nil];
            if ([key isEqual:@"button-shapes"]) {
                [NSNotificationCenter.defaultCenter postNotificationName:AXShowBordersEnabledStatusDidChangeNotification object:nil];
            }
        }
    }
}

__attribute__((constructor)) static void ycodeOverridesInit(void) {
    const char *dir = getenv("YCODE_ENV_OVERRIDES_DIR");
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (!dir || !bundleID) return;
    gPath = [[NSString stringWithUTF8String:dir] stringByAppendingPathComponent:[bundleID stringByAppendingString:@".plist"]];
    gOverrides = readFile();
    // Scenes: on connection and when the app finishes launching.
    for (NSString *name in @[UISceneWillConnectNotification, UIApplicationDidFinishLaunchingNotification,
                             UISceneDidActivateNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) {
            (void)n;
            applyToAllScenes();
        }];
    }
    int token = 0;
    notify_register_dispatch("dev.ycode.environment-overrides.changed", &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        reload(YES);
    });
    say([NSString stringWithFormat:@"loaded for %@ (%lu overrides)", bundleID, (unsigned long)gOverrides.count]);
}
