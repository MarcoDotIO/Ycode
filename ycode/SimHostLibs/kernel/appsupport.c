/*
 * appsupport.c - libsystem_kernel functions that apps and their frameworks
 * call at start and that had only the unimplemented-function stub
 * (specs/simulator/app-launch.md section 3.4): thread_info,
 * thread_policy_set/get, host_statistics(64), and libproc's CPU and wakeup
 * monitor controls.
 *
 * Clean-room Ycode code. Facts used: the public Mach headers
 * mach/thread_info.h, mach/thread_policy.h, mach/host_info.h and
 * mach/vm_statistics.h (flavor numbers, structure layouts and counts), and
 * libsyscall's libproc_internal.h (the monitor functions' signatures;
 * level 1). The values are Ycode's choices and are noted on each function.
 */
#include "yc_kernel.h"

#define YC_PRIV_ROUTINE(n) ((long)(0x79632000u + (n)))
#define YC_PRIV_THREAD_INFO 0x30

/* kern_return_t thread_info(thread_inspect_t target_act, thread_flavor_t flavor,
 *     thread_info_t thread_info_out, mach_msg_type_number_t *thread_info_outCnt)
 * Private routine 0x30: the VMM answers THREAD_BASIC_INFO,
 * THREAD_IDENTIFIER_INFO, THREAD_EXTENDED_INFO and
 * THREAD_SCHED_TIMESHARE_INFO for a thread of the caller's task. */
YC_EXPORT int thread_info(yc_port_t thread, yc_u32 flavor, int *info, yc_u32 *count)
{
    if (info == YC_NULL || count == YC_NULL)
        return YC_KERN_INVALID_ARGUMENT;
    return (int)yc_mach_trap(YC_PRIV_ROUTINE(YC_PRIV_THREAD_INFO), thread, flavor, (yc_uintptr_t)info,
                             (yc_uintptr_t)count, 0, 0, 0);
}

/* Thread policy flavors (mach/thread_policy.h). */
#define YC_THREAD_EXTENDED_POLICY 1
#define YC_THREAD_TIME_CONSTRAINT_POLICY 2
#define YC_THREAD_PRECEDENCE_POLICY 3
#define YC_THREAD_AFFINITY_POLICY 4
#define YC_THREAD_BACKGROUND_POLICY 5
#define YC_THREAD_LATENCY_QOS_POLICY 7
#define YC_THREAD_THROUGHPUT_QOS_POLICY 8
#define YC_THREAD_TIME_CONSTRAINT_WITH_PRIORITY_POLICY 10

/* The count (32-bit words) of each policy flavor, 0 for an unknown one. */
static yc_u32 yc_policy_count(int flavor)
{
    switch (flavor) {
    case YC_THREAD_EXTENDED_POLICY: return 1;
    case YC_THREAD_TIME_CONSTRAINT_POLICY: return 4;
    case YC_THREAD_PRECEDENCE_POLICY: return 1;
    case YC_THREAD_AFFINITY_POLICY: return 1;
    case YC_THREAD_BACKGROUND_POLICY: return 1;
    case YC_THREAD_LATENCY_QOS_POLICY: return 1;
    case YC_THREAD_THROUGHPUT_QOS_POLICY: return 1;
    case YC_THREAD_TIME_CONSTRAINT_WITH_PRIORITY_POLICY: return 5;
    default: return 0;
    }
}

/* kern_return_t thread_policy_set(thread_act_t thread, thread_policy_flavor_t flavor,
 *     thread_policy_t policy_info, mach_msg_type_number_t policy_infoCnt)
 * Accepted and not applied: Ycode's guest threads are scheduled by the
 * host (scheduling-policy.md); a real-time request (QuartzCore's render
 * thread, Core Audio) succeeds as it does for an unprivileged macOS
 * process. A null thread or an unknown flavor is KERN_INVALID_ARGUMENT;
 * a short count too. */
YC_EXPORT int thread_policy_set(yc_port_t thread, int flavor, const int *info, yc_u32 count)
{
    yc_u32 need = yc_policy_count(flavor);
    if (thread == 0 || need == 0 || info == YC_NULL || count < need)
        return YC_KERN_INVALID_ARGUMENT;
    return YC_KERN_SUCCESS;
}

YC_EXPORT int _kernelrpc_thread_policy_set(yc_port_t thread, int flavor, const int *info, yc_u32 count)
{
    return thread_policy_set(thread, flavor, info, count);
}

/* kern_return_t thread_policy_get(thread_inspect_t thread, thread_policy_flavor_t flavor,
 *     thread_policy_t policy_info, mach_msg_type_number_t *policy_infoCnt,
 *     boolean_t *get_default)
 * Every thread reports the default policy (*get_default = TRUE): extended
 * timeshare = 1; time constraint period 0, computation 5 ms, constraint
 * 10 ms, preemptible 1 (in Mach absolute time units); the others 0. */
YC_EXPORT int thread_policy_get(yc_port_t thread, int flavor, int *info, yc_u32 *count, int *get_default)
{
    yc_u32 need = yc_policy_count(flavor);
    if (thread == 0 || need == 0 || info == YC_NULL || count == YC_NULL || *count < need)
        return YC_KERN_INVALID_ARGUMENT;
    for (yc_u32 i = 0; i < need; i++)
        info[i] = 0;
    if (flavor == YC_THREAD_EXTENDED_POLICY) {
        info[0] = 1;
    } else if (flavor == YC_THREAD_TIME_CONSTRAINT_POLICY || flavor == YC_THREAD_TIME_CONSTRAINT_WITH_PRIORITY_POLICY) {
        struct yc_mach_timebase_info tb = {1, 1};
        YC_KFN(mach_timebase_info)(&tb);
        yc_u64 ms = tb.numer ? (1000000ull * tb.denom) / tb.numer : 1000000ull;
        info[1] = (int)(yc_u32)(5 * ms);
        info[2] = (int)(yc_u32)(10 * ms);
        info[3] = 1;
    }
    *count = need;
    if (get_default != YC_NULL)
        *get_default = 1;
    return YC_KERN_SUCCESS;
}

/* Host statistics flavors (mach/host_info.h). */
#define YC_HOST_LOAD_INFO 1
#define YC_HOST_VM_INFO 2
#define YC_HOST_CPU_LOAD_INFO 3
#define YC_HOST_VM_INFO64 4
#define YC_GUEST_PAGES 65536u /* 1 GiB of 16 KiB pages, as host_info reports */

/* kern_return_t host_statistics(host_t host_priv, host_flavor_t flavor,
 *     host_info_t host_info_out, mach_msg_type_number_t *host_info_outCnt)
 * HOST_LOAD_INFO (6 words): no load. HOST_VM_INFO (15 words) and
 * HOST_VM_INFO64 (38 words): the guest's 1 GiB as half free, a quarter
 * active, an eighth inactive and an eighth wired, no paging activity.
 * HOST_CPU_LOAD_INFO (4 words: user, system, idle, nice ticks at 100 Hz):
 * the time since boot as idle. Other flavors: KERN_INVALID_ARGUMENT. */
static int yc_host_statistics(int flavor, int *info, yc_u32 *count, int wide)
{
    if (info == YC_NULL || count == YC_NULL)
        return YC_KERN_INVALID_ARGUMENT;
    yc_u32 need;
    switch (flavor) {
    case YC_HOST_LOAD_INFO: need = 6; break;
    case YC_HOST_VM_INFO: need = 15; break;
    case YC_HOST_CPU_LOAD_INFO: need = 4; break;
    case YC_HOST_VM_INFO64: need = wide ? 38 : 0; break;
    default: need = 0; break;
    }
    if (need == 0)
        return YC_KERN_INVALID_ARGUMENT;
    if (*count < need)
        return YC_KERN_FAILURE;
    for (yc_u32 i = 0; i < need; i++)
        info[i] = 0;
    if (flavor == YC_HOST_VM_INFO || flavor == YC_HOST_VM_INFO64) {
        info[0] = (int)(YC_GUEST_PAGES / 2); /* free_count */
        info[1] = (int)(YC_GUEST_PAGES / 4); /* active_count */
        info[2] = (int)(YC_GUEST_PAGES / 8); /* inactive_count */
        info[3] = (int)(YC_GUEST_PAGES / 8); /* wire_count */
    } else if (flavor == YC_HOST_CPU_LOAD_INFO) {
        struct yc_mach_timebase_info tb = {1, 1};
        YC_KFN(mach_timebase_info)(&tb);
        yc_u64 ns = YC_KFN(mach_absolute_time)();
        if (tb.denom)
            ns = ns / tb.denom * tb.numer;
        info[2] = (int)(yc_u32)(ns / 10000000ull); /* idle ticks */
    }
    *count = need;
    return YC_KERN_SUCCESS;
}

YC_EXPORT int host_statistics(yc_port_t host, int flavor, int *info, yc_u32 *count)
{
    (void)host;
    return yc_host_statistics(flavor, info, count, 0);
}

YC_EXPORT int host_statistics64(yc_port_t host, int flavor, int *info, yc_u32 *count)
{
    (void)host;
    return yc_host_statistics(flavor, info, count, 1);
}

/* libproc's CPU and wakeup monitors (libproc_internal.h). Ycode has no
 * resource monitors: setting, resuming or disabling one succeeds and has no
 * effect, and a query reports a disabled monitor (0, 0). Daemons and
 * frameworks call these at start (mediaanalysisd, QuartzCore). */
YC_EXPORT int proc_set_cpumon_params(int pid, int percentage, int interval)
{
    (void)pid; (void)percentage; (void)interval;
    return 0;
}

YC_EXPORT int proc_set_cpumon_params_fatal(int pid, int percentage, int interval)
{
    (void)pid; (void)percentage; (void)interval;
    return 0;
}

YC_EXPORT int proc_get_cpumon_params(int pid, int *percentage, int *interval)
{
    (void)pid;
    if (percentage != YC_NULL) *percentage = 0;
    if (interval != YC_NULL) *interval = 0;
    return 0;
}

YC_EXPORT int proc_set_cpumon_defaults(int pid) { (void)pid; return 0; }
YC_EXPORT int proc_resume_cpumon(int pid) { (void)pid; return 0; }
YC_EXPORT int proc_disable_cpumon(int pid) { (void)pid; return 0; }

YC_EXPORT int proc_set_wakemon_params(int pid, int rate_hz, int flags)
{
    (void)pid; (void)rate_hz; (void)flags;
    return 0;
}

YC_EXPORT int proc_get_wakemon_params(int pid, int *rate_hz, int *flags)
{
    (void)pid;
    if (rate_hz != YC_NULL) *rate_hz = 0;
    if (flags != YC_NULL) *flags = 0;
    return 0;
}

YC_EXPORT int proc_set_wakemon_defaults(int pid) { (void)pid; return 0; }
YC_EXPORT int proc_disable_wakemon(int pid) { (void)pid; return 0; }

YC_EXPORT int proc_setcpu_percentage(int pid, int action, int percentage)
{
    (void)pid; (void)action; (void)percentage;
    return 0;
}

YC_EXPORT int proc_clear_cpulimits(int pid) { (void)pid; return 0; }

/* int proc_setthread_cpupercent(uint8_t percentage, uint32_t ms_refill) */
YC_EXPORT int proc_setthread_cpupercent(yc_u8 percentage, yc_u32 ms_refill)
{
    (void)percentage; (void)ms_refill;
    return 0;
}
