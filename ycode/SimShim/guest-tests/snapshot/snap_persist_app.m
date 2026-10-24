/* Ycode warm-boot persistence probe (specs/simulator/snapshot.md §12): an
 * iOS app that counts its own launches in three places an app's data lives,
 * so a run shows whether the previous runs' data survived. Original Ycode
 * code; public UIKit, Foundation and Security interfaces only.
 *
 * At launch it reads, then writes back incremented:
 *   - NSUserDefaults key "runs" (cfprefsd, the container's Library/Preferences),
 *   - Documents/runs.txt in its data container,
 *   - a generic-password keychain item (service "dev.ycode.snap-persist").
 * One line each on stdout, "snap-persist: <store> before=<n> after=<n+1>",
 * then "snap-persist: home <NSHomeDirectory()>" and "snap-persist: done".
 * A missing value reads as 0; a keychain error prints its OSStatus. */
#import <Security/Security.h>
#import <UIKit/UIKit.h>

static void say(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stdout, "snap-persist: %s\n", s.UTF8String);
    fflush(stdout);
}

static NSInteger countDefaults(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger before = [d integerForKey:@"runs"];
    [d setInteger:before + 1 forKey:@"runs"];
    [d synchronize];
    say(@"defaults before=%ld after=%ld", (long)before, (long)before + 1);
    return before;
}

static NSInteger countFile(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"runs.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    NSInteger before = text.integerValue;
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:NULL];
    BOOL ok = [[NSString stringWithFormat:@"%ld\n", (long)before + 1] writeToFile:path atomically:YES
                                                                      encoding:NSUTF8StringEncoding error:&error];
    say(@"file before=%ld after=%ld%@", (long)before, (long)before + 1,
        ok ? @"" : [NSString stringWithFormat:@" (write failed: %@)", error.localizedDescription]);
    return before;
}

static NSInteger countKeychain(void) {
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: @"dev.ycode.snap-persist",
                            (__bridge id)kSecAttrAccount: @"runs"};
    NSMutableDictionary *read = [query mutableCopy];
    read[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
    NSInteger before = 0;
    if (status == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        before = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].integerValue;
    } else if (status != errSecItemNotFound) {
        say(@"keychain read status=%d", (int)status);
    }
    NSData *value = [[NSString stringWithFormat:@"%ld", (long)before + 1] dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus write;
    if (status == errSecSuccess) {
        write = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: value});
    } else {
        NSMutableDictionary *add = [query mutableCopy];
        add[(__bridge id)kSecValueData] = value;
        write = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    say(@"keychain before=%ld after=%ld write status=%d", (long)before, (long)before + 1, (int)write);
    return before;
}

static NSInteger runsBefore[3];

@interface SnapPersistDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation SnapPersistDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    runsBefore[0] = countDefaults();
    runsBefore[1] = countFile();
    runsBefore[2] = countKeychain();
    say(@"home %@", NSHomeDirectory());
    say(@"done");
    return YES;
}
@end

@interface SnapPersistSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SnapPersistSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.systemTealColor;
    UILabel *label = [[UILabel alloc] initWithFrame:root.view.bounds];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:40];
    label.text = [NSString stringWithFormat:@"runs before\ndefaults %ld\nfile %ld\nkeychain %ld",
                  (long)runsBefore[0], (long)runsBefore[1], (long)runsBefore[2]];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:label];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SnapPersistDelegate class]));
    }
}
