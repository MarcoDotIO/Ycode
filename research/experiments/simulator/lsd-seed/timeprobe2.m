// timeprobe2: our probe (stage 7, agent I4). Calls each public wall-clock
// interface 1000 times, so a Ycode trace shows which ones enter the kernel.
#import <Foundation/Foundation.h>
#include <time.h>
#include <sys/time.h>
int main(int argc, char **argv) {
    const char *which = argc > 1 ? argv[1] : "all";
    double sink = 0;
    if (!strcmp(which, "clock") || !strcmp(which, "all"))
        for (int i = 0; i < 1000; i++) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); sink += ts.tv_nsec; }
    if (!strcmp(which, "cf") || !strcmp(which, "all"))
        for (int i = 0; i < 1000; i++) sink += CFAbsoluteTimeGetCurrent();
    if (!strcmp(which, "nsdate") || !strcmp(which, "all"))
        for (int i = 0; i < 1000; i++) @autoreleasepool { sink += [NSDate date].timeIntervalSinceReferenceDate; }
    if (!strcmp(which, "time") || !strcmp(which, "all"))
        for (int i = 0; i < 1000; i++) sink += time(NULL);
    printf("done %s %f\n", which, sink > 0 ? 1.0 : 0.0);
    return 0;
}
