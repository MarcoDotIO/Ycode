// GaugeDemo: a small UIKit app for Gauge's end-to-end check
// (specs/ide/profiler.md §10). Every 1.5 s the main thread runs one round
// of deliberate work (Work.c: Crunch > Sieve, Matrix, with signposts), which
// also makes a hang; a background queue does a little work of its own.
// Original Ycode sample code.
#import <UIKit/UIKit.h>
#include <stdio.h>
#include "Work.h"

@interface GaugeDemoController : UIViewController
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) int round;
@property (nonatomic) uint64_t checksum;
@end

@implementation GaugeDemoController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.label = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 20, 120)];
    self.label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.label.numberOfLines = 0;
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.font = [UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightMedium];
    self.label.text = @"GaugeDemo\nwaiting for the first round";
    [self.view addSubview:self.label];
    [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)tick:(NSTimer *)timer {
    int round = ++self.round;
    gauge_demo_tick(round);
    uint64_t sum = self.checksum;
    double ms = gauge_demo_round(round, &sum);
    self.checksum = sum;
    printf("GaugeDemo: round %d took %.1f ms on the main thread (checksum %llu)\n", round, ms, (unsigned long long)sum);
    fflush(stdout);
    self.label.text = [NSString stringWithFormat:@"GaugeDemo\nround %d: %.0f ms", round, ms];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint64_t s = gauge_demo_background(round);
        if (s == 42) printf("unlikely\n");
    });
}
@end

@interface GaugeDemoSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation GaugeDemoSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [GaugeDemoController new];
    [self.window makeKeyAndVisible];
    printf("GaugeDemo: launched\n");
    fflush(stdout);
}
@end

@interface GaugeDemoDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation GaugeDemoDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = [GaugeDemoSceneDelegate class];
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([GaugeDemoDelegate class]));
    }
}
