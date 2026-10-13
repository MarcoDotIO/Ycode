// timeprobe: our probe (stage 7, agent I4). Prints the wall clock and
// mach_absolute_time over a few seconds, and times 100000 calls of each.
#include <stdio.h>
#include <sys/time.h>
#include <unistd.h>
#include <mach/mach_time.h>
int main(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    for (int i = 0; i < 3; i++) {
        struct timeval tv; gettimeofday(&tv, 0);
        printf("tod %ld.%06d abs %llu\n", (long)tv.tv_sec, (int)tv.tv_usec, (unsigned long long)mach_absolute_time());
        usleep(1200000);
    }
    uint64_t t0 = mach_absolute_time(); struct timeval a, b; gettimeofday(&a, 0);
    for (int i = 0; i < 100000; i++) { struct timeval tv; gettimeofday(&tv, 0); }
    uint64_t t1 = mach_absolute_time(); gettimeofday(&b, 0);
    printf("100000 gettimeofday: %llu ns (wall %ld us)\n", (unsigned long long)((t1 - t0) * tb.numer / tb.denom),
           (long)((b.tv_sec - a.tv_sec) * 1000000 + (b.tv_usec - a.tv_usec)));
    t0 = mach_absolute_time();
    for (int i = 0; i < 100000; i++) (void)mach_absolute_time();
    t1 = mach_absolute_time();
    printf("100000 mach_absolute_time: %llu ns\n", (unsigned long long)((t1 - t0) * tb.numer / tb.denom));
    return 0;
}
