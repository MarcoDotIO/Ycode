// webprobe: our own probe app, public API only. Loads a data: URL in a
// WKWebView, logs the navigation result, then asks the system to open the
// same data: URL (which app, if any, handles it).
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

static NSString *const kPage = @"data:text/html,<html><body style='background:%23ffd400;margin:0'><h1 style='font-size:64px'>YCODE QA data URL</h1></body></html>";

@interface ProbeVC : UIViewController <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@end
@implementation ProbeVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:[WKWebViewConfiguration new]];
    self.web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.web.navigationDelegate = self;
    [self.view addSubview:self.web];
    NSLog(@"webprobe: loading %@", kPage);
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kPage]]];
}
- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)n {
    [w evaluateJavaScript:@"document.body.innerText" completionHandler:^(id r, NSError *e) {
        NSLog(@"webprobe: didFinish text=%@ err=%@", r, e);
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--open"]) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:kPage] options:@{} completionHandler:^(BOOL ok) {
                NSLog(@"webprobe: openURL(data:) -> %d", ok);
            }];
        }
    }];
}
- (void)webView:(WKWebView *)w didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e { NSLog(@"webprobe: didFailProvisional %@", e); }
- (void)webView:(WKWebView *)w didFailNavigation:(WKNavigation *)n withError:(NSError *)e { NSLog(@"webprobe: didFail %@", e); }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)w { NSLog(@"webprobe: content process terminated"); }
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ProbeVC new];
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = [SceneDelegate class];
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
