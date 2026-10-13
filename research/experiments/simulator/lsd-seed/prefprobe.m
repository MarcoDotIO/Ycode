// prefprobe: our probe (stage 7, agent I4). Writes one preference through
// CFPreferences (cfprefsd), synchronizes, and reports whether the plist file
// appeared under the home directory's Library/Preferences.
#import <Foundation/Foundation.h>
#include <sys/stat.h>
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    CFPreferencesSetAppValue(CFSTR("probeKey"), CFSTR("probeValue"), CFSTR("dev.ycode.prefprobe"));
    Boolean ok = CFPreferencesAppSynchronize(CFSTR("dev.ycode.prefprobe"));
    printf("synchronize -> %d\n", ok);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/dev.ycode.prefprobe.plist"];
    struct stat st;
    printf("%s exists %d\n", path.UTF8String, stat(path.UTF8String, &st) == 0);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("probeKey"), CFSTR("dev.ycode.prefprobe"));
    printf("read back %s\n", v ? [[(__bridge id)v description] UTF8String] : "(null)");
    return 0;
}
