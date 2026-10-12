/*
 * misc.c - small libsystem_kernel functions built on the generated
 * system-call wrappers or on the commpage.
 *
 * Clean-room Ycode code. Facts used: published Darwin API behavior
 * (<sys/reason.h> abort_with_reason / terminate_with_reason as wrappers of
 * the *_with_payload calls with no payload; clonefile(2) and renamex_np(2)
 * as the *at forms with AT_FDCWD (-2); sem_init(2)/sem_destroy(2) fail with
 * ENOSYS on Darwin; FD_SETSIZE = 1024), the commpage KDEBUG_ENABLE field
 * (darwin-process-start.md section 3.2) and the BSD table.
 */
#include "yc_kernel.h"

#define YC_AT_FDCWD (-2)
#define YC_FD_SETSIZE 1024

/* Generated wrappers (syscalls.S). */
YC_NORETURN void __abort_with_payload(yc_u32 reason_namespace, yc_u64 reason_code, void *payload,
                                      yc_u32 payload_size, const char *reason_string, yc_u64 reason_flags);
int __terminate_with_payload(int pid, yc_u32 reason_namespace, yc_u64 reason_code, void *payload,
                             yc_u32 payload_size, const char *reason_string, yc_u64 reason_flags);
int __kdebug_trace(yc_u32 debugid, yc_u64 arg1, yc_u64 arg2, yc_u64 arg3, yc_u64 arg4);
int clonefileat(int src_dirfd, const char *src, int dst_dirfd, const char *dst, yc_u32 flags);
int renameatx_np(int fromfd, const char *from, int tofd, const char *to, yc_u32 flags);
yc_u64 __memorystatus_available_memory(void);

YC_EXPORT YC_NORETURN void abort_with_reason(yc_u32 reason_namespace, yc_u64 reason_code, const char *reason_string,
                                             yc_u64 reason_flags)
{
    __abort_with_payload(reason_namespace, reason_code, YC_NULL, 0, reason_string, reason_flags);
}

YC_EXPORT int terminate_with_reason(int pid, yc_u32 reason_namespace, yc_u64 reason_code, const char *reason_string,
                                    yc_u64 reason_flags)
{
    return __terminate_with_payload(pid, reason_namespace, reason_code, YC_NULL, 0, reason_string, reason_flags);
}

YC_EXPORT int clonefile(const char *src, const char *dst, yc_u32 flags)
{
    return clonefileat(YC_AT_FDCWD, src, YC_AT_FDCWD, dst, flags);
}

YC_EXPORT int renamex_np(const char *from, const char *to, yc_u32 flags)
{
    return renameatx_np(YC_AT_FDCWD, from, YC_AT_FDCWD, to, flags);
}

/* Unnamed POSIX semaphores are not supported on Darwin. */
YC_EXPORT int sem_init(void *sem, int pshared, unsigned value)
{
    (void)sem;
    (void)pshared;
    (void)value;
    __ycode_set_errno(YC_ENOSYS);
    return -1;
}

YC_EXPORT int sem_destroy(void *sem)
{
    (void)sem;
    __ycode_set_errno(YC_ENOSYS);
    return -1;
}

/* int __darwin_check_fd_set_overflow(int fd, const void *set, int unlimited):
 * non-zero when fd may be used with an fd_set (FD_SET and friends). */
YC_EXPORT int __darwin_check_fd_set_overflow(int fd, const void *set, int unlimited)
{
    (void)set;
    return fd >= 0 && (unlimited || fd < YC_FD_SETSIZE);
}

/* kdebug: nothing is traced while the commpage enable word is 0. */
YC_EXPORT int kdebug_is_enabled(yc_u32 debugid)
{
    (void)debugid;
    return yc_commpage_u32(YC_COMM_KDEBUG_ENABLE) != 0;
}

YC_EXPORT int kdebug_trace(yc_u32 debugid, yc_u64 arg1, yc_u64 arg2, yc_u64 arg3, yc_u64 arg4)
{
    if (yc_commpage_u32(YC_COMM_KDEBUG_ENABLE) == 0)
        return 0;
    return __kdebug_trace(debugid, arg1, arg2, arg3, arg4);
}

/* size_t os_proc_available_memory(void): 0 when it cannot be determined. */
YC_EXPORT yc_size_t os_proc_available_memory(void)
{
    yc_u64 v = __memorystatus_available_memory();
    return v == ~(yc_u64)0 ? 0 : (yc_size_t)v;
}

/* int __commpage_gettimeofday(struct timeval *tp): Ycode keeps no
 * gettimeofday data in the commpage, so this always reports "not
 * available" (non-zero) and callers fall back to BSD 116
 * (host-libraries.md section 10). */
YC_EXPORT int __commpage_gettimeofday(void *tp)
{
    (void)tp;
    return 1;
}

/* int setiopolicy_np(int iotype, int scope, int policy);
 * int getiopolicy_np(int iotype, int scope);
 * Public API (setiopolicy_np(3)): scope is IOPOL_SCOPE_PROCESS (0),
 * IOPOL_SCOPE_THREAD (1), or IOPOL_SCOPE_DARWIN_BG (2); anything else is
 * EINVAL. Ycode has no I/O scheduling classes: a set is accepted and a get
 * reports IOPOL_DEFAULT (0). */
YC_HIDDEN void __ycode_set_errno(int value);

YC_EXPORT int setiopolicy_np(int iotype, int scope, int policy)
{
    (void)policy;
    if (iotype < 0 || scope < 0 || scope > 2) {
        __ycode_set_errno(22);
        return -1;
    }
    return 0;
}

YC_EXPORT int getiopolicy_np(int iotype, int scope)
{
    if (iotype < 0 || scope < 0 || scope > 2) {
        __ycode_set_errno(22);
        return -1;
    }
    return 0;
}
