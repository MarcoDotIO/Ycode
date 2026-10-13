// trapbench: our probe (stage 7, agent I4). Times 100000 calls each of a few
// cheap system calls (each one VM exit under Ycode).
#include <stdio.h>
#include <unistd.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <mach/mach.h>
int main(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    uint64_t t0 = mach_absolute_time();
    for (int i = 0; i < 100000; i++) (void)getppid();
    uint64_t t1 = mach_absolute_time();
    for (int i = 0; i < 100000; i++) { struct timeval tv; gettimeofday(&tv, 0); }
    uint64_t t2 = mach_absolute_time();
    for (int i = 0; i < 100000; i++) (void)mach_absolute_time();
    uint64_t t3 = mach_absolute_time();
    printf("getppid %llu ns, gettimeofday %llu ns, mach_absolute_time %llu ns per call\n",
           (unsigned long long)((t1 - t0) * tb.numer / tb.denom / 100000),
           (unsigned long long)((t2 - t1) * tb.numer / tb.denom / 100000),
           (unsigned long long)((t3 - t2) * tb.numer / tb.denom / 100000));
    return 0;
}
