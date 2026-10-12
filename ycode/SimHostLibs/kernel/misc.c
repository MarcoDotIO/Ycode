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
 * Public API (setiopolicy_np(3)) over __iopolicysys(cmd, param) (BSD 322;
 * xnu sys/resource.h: IOPOL_CMD_SET 0, IOPOL_CMD_GET 1, struct
 * _iopol_param_t {scope, iotype, policy}). The kernel keeps what is set,
 * per process, thread or darwin-background scope; get returns the policy. */
int __iopolicysys(int cmd, void *param);

struct yc_iopol_param {
    int scope;
    int iotype;
    int policy;
};

YC_EXPORT int setiopolicy_np(int iotype, int scope, int policy)
{
    struct yc_iopol_param p = {scope, iotype, policy};
    return __iopolicysys(0, &p);
}

YC_EXPORT int getiopolicy_np(int iotype, int scope)
{
    struct yc_iopol_param p = {scope, iotype, 0};
    if (__iopolicysys(1, &p) != 0)
        return -1;
    return p.policy;
}

/* posix_madvise: on Darwin the same call as madvise(2), with the POSIX_
 * advice names for the same values, and -1 and errno on failure (the
 * madvise(2) manual page; level 1). */
int madvise(void *addr, yc_size_t len, int advice);
YC_EXPORT int posix_madvise(void *addr, yc_size_t len, int advice)
{
    return madvise(addr, len, advice);
}

/* csr_check / csr_get_active_config: wrappers of csrctl(2) (xnu
 * libsyscall/wrappers/csr.c: op 0 = check, op 1 = active config; the
 * argument is a pointer to a u32 and its size). */
int __csrctl(yc_u32 op, void *buffer, yc_size_t size);
YC_EXPORT int csr_check(yc_u32 mask)
{
    return __csrctl(0, &mask, sizeof(mask));
}

YC_EXPORT int csr_get_active_config(yc_u32 *config)
{
    return __csrctl(1, config, sizeof(*config));
}

/* kpersona_*: wrappers of __persona(op, flags, info, id, idlen, path)
 * (xnu libsyscall/wrappers/persona.c, sys/persona.h op numbers 1-9). */
int __persona(yc_u32 op, yc_u32 flags, void *info, yc_u32 *id, yc_size_t *idlen, char *path);

struct yc_kpersona_info { /* sys/persona.h, packed, 348 bytes */
    yc_u32 version;
    yc_u32 id;
    int type;
    yc_u32 gid;
    yc_u32 ngroups;
    yc_u32 groups[16];
    yc_u32 gmuid;
    char name[255 + 1]; /* MAXLOGNAME + 1: the struct is 348 bytes */
    yc_u32 uid;
} __attribute__((packed));
_Static_assert(sizeof(struct yc_kpersona_info) == 348, "struct kpersona_info is 348 bytes");

YC_EXPORT int kpersona_alloc(void *info, yc_u32 *id)
{
    yc_size_t idlen = 1;
    return __persona(1, 0, info, id, &idlen, YC_NULL);
}

YC_EXPORT int kpersona_palloc(void *info, yc_u32 *id, char *path)
{
    yc_size_t idlen = 1;
    return __persona(2, 0, info, id, &idlen, path);
}

YC_EXPORT int kpersona_dealloc(yc_u32 id)
{
    yc_size_t idlen = 1;
    return __persona(3, 0, YC_NULL, &id, &idlen, YC_NULL);
}

YC_EXPORT int kpersona_get(yc_u32 *id)
{
    yc_size_t idlen = 1;
    return __persona(4, 0, YC_NULL, id, &idlen, YC_NULL);
}

YC_EXPORT int kpersona_info(yc_u32 id, void *info)
{
    yc_size_t idlen = 1;
    return __persona(5, 0, info, &id, &idlen, YC_NULL);
}

YC_EXPORT int kpersona_pidinfo(int pid, void *info)
{
    yc_size_t idlen = 1;
    yc_u32 id = (yc_u32)pid;
    return __persona(6, 0, info, &id, &idlen, YC_NULL);
}

YC_EXPORT int kpersona_getpath(yc_u32 id, char *path)
{
    yc_size_t idlen = 1;
    return __persona(8, 0, YC_NULL, &id, &idlen, path);
}

static int yc_persona_find(yc_u32 op, const char *name, yc_u32 uid, int type, yc_u32 *id, yc_size_t *idlen)
{
    struct yc_kpersona_info k;
    char *p = (char *)&k;
    for (yc_size_t i = 0; i < sizeof(k); i++)
        p[i] = 0;
    k.version = 1;
    k.id = uid;
    k.type = type;
    if (name != YC_NULL) {
        yc_size_t i = 0;
        for (; name[i] != 0 && i < sizeof(k.name) - 1; i++)
            k.name[i] = name[i];
    }
    int ret = __persona(op, 0, &k, id, idlen, YC_NULL);
    if (ret < 0)
        return ret;
    return (int)*idlen;
}

YC_EXPORT int kpersona_find(const char *name, yc_u32 uid, yc_u32 *id, yc_size_t *idlen)
{
    return yc_persona_find(7, name, uid, 0, id, idlen);
}

YC_EXPORT int kpersona_find_by_type(int persona_type, yc_u32 *id, yc_size_t *idlen)
{
    return yc_persona_find(9, YC_NULL, (yc_u32)-1, persona_type, id, idlen);
}

/* char *mach_error_string(mach_error_t error_value): the (os/kern) strings
 * of xnu's error table (libsyscall/mach/err_kern.sub, level 1); any other
 * code is reported as "unknown error code" (Ycode keeps no other tables). */
static const char *const yc_kern_errors[] = {
    "(os/kern) successful", "(os/kern) invalid address", "(os/kern) protection failure",
    "(os/kern) no space available", "(os/kern) invalid argument", "(os/kern) failure",
    "(os/kern) resource shortage", "(os/kern) not receiver", "(os/kern) no access", "(os/kern) memory failure",
    "(os/kern) memory error", "(os/kern) already in set", "(os/kern) not in set", "(os/kern) name exists",
    "(os/kern) aborted", "(os/kern) invalid name", "(os/kern) invalid task", "(os/kern) invalid right",
    "(os/kern) invalid value", "(os/kern) urefs overflow", "(os/kern) invalid capability",
    "(os/kern) right exists", "(os/kern) invalid host", "(os/kern) memory present",
    "(os/kern) memory data moved", "(os/kern) memory restart copy", "(os/kern) invalid processor set",
    "(os/kern) policy limit", "(os/kern) invalid policy", "(os/kern) invalid object",
    "(os/kern) already waiting", "(os/kern) default set", "(os/kern) exception protected",
    "(os/kern) invalid ledger", "(os/kern) invalid memory control", "(os/kern) invalid security",
    "(os/kern) not depressed", "(os/kern) object terminated", "(os/kern) lock set destroyed",
    "(os/kern) lock unstable", "(os/kern) lock owned by another", "(os/kern) lock owned by self",
    "(os/kern) semaphore destroyed", "(os/kern) RPC terminated", "(os/kern) terminate orphan",
    "(os/kern) let orphan continue", "(os/kern) service not supported", "(os/kern) remote node down",
    "(os/kern) thread not waiting", "(os/kern) operation timed out", "(os/kern) code signing error",
    "(os/kern) policy is static", "(os/kern) insufficient input buffer size",
    "(os/kern) denied by security policy", "(os/kern) missing kernel collection",
    "(os/kern) invalid kernel collection", "(os/kern) result not found",
};

YC_EXPORT const char *mach_error_string(int error_value)
{
    unsigned code = (unsigned)error_value;
    if (code < sizeof(yc_kern_errors) / sizeof(yc_kern_errors[0]))
        return yc_kern_errors[code];
    return "unknown error code";
}
