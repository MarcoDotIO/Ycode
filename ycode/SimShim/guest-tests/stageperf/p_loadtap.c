/* Ycode performance probe, built as a dylib (libp_loadtap.dylib): inserted
 * into a real program with DYLD_INSERT_LIBRARIES, its initializer runs
 * after the loader has loaded and bound the program's whole closure and
 * before the program's own code. It prints one line to stderr and ends the
 * process, so the program itself never runs:
 *   "loadtap images=N since_start_s=S cpu_s=C thread_cpu_s=T"
 * With P_LOADTAP_LIST=1 it also prints every image path.
 * Original Ycode code (specs/simulator/boot-profile.md §6). */
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

__attribute__((constructor)) static void tap(void)
{
    struct timeval now;
    gettimeofday(&now, NULL);
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    struct timespec tc;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &tc);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    memset(&kp, 0, sizeof kp);
    double since = -1;
    if (sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && len >= sizeof kp && kp.kp_proc.p_un.__p_starttime.tv_sec)
        since = (double)(now.tv_sec - kp.kp_proc.p_un.__p_starttime.tv_sec) +
                (double)(now.tv_usec - kp.kp_proc.p_un.__p_starttime.tv_usec) / 1e6;
    double cpu = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1e6 + (double)ru.ru_stime.tv_sec +
                 (double)ru.ru_stime.tv_usec / 1e6;
    fprintf(stderr, "loadtap images=%u since_start_s=%.3f cpu_s=%.3f thread_cpu_s=%.3f\n", _dyld_image_count(), since,
            cpu, (double)tc.tv_sec + (double)tc.tv_nsec / 1e9);
    const char *list = getenv("P_LOADTAP_LIST");
    if (list && *list == '1')
        for (uint32_t i = 0; i < _dyld_image_count(); i++)
            fprintf(stderr, "loadtap image %s\n", _dyld_get_image_name(i));
    fflush(stderr);
    _exit(0);
}
