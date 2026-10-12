/*
 * libproc.c - the libproc functions of libsystem_kernel that are thin
 * library code over BSD 336 (__proc_info) and BSD 545
 * (__proc_info_extended_id).
 *
 * Clean-room Ycode code. Contract: specs/simulator/processes.md section
 * 2.11 (call numbers, LISTPIDS types and results, PIDINFO flavors and
 * sizes, PATHINFO bounds, proc_name, DIRTYCONTROL flavors, TERMINATE,
 * PIDRUSAGE) and section 4.5 (audit-token words: val[5] = pid,
 * val[7] = pid version). Public C signatures: the SDK <libproc.h>.
 *
 * The kernel wrappers (generated, syscalls.S) return -1 with errno set on
 * failure. libproc's own conventions differ per function and are noted
 * on each one.
 */
#include "yc_kernel.h"

#define YC_EOVERFLOW 84

/* proc_info call numbers. */
#define YC_PROC_INFO_CALL_LISTPIDS 1
#define YC_PROC_INFO_CALL_PIDINFO 2
#define YC_PROC_INFO_CALL_PIDFDINFO 3
#define YC_PROC_INFO_CALL_TERMINATE 7
#define YC_PROC_INFO_CALL_DIRTYCONTROL 8
#define YC_PROC_INFO_CALL_PIDRUSAGE 9

/* LISTPIDS types. */
#define YC_PROC_ALL_PIDS 1
#define YC_PROC_PGRP_ONLY 2
#define YC_PROC_PPID_ONLY 6
#define YC_PROC_KDBG_ONLY 7

/* PIDINFO flavors. */
#define YC_PROC_PIDTBSDINFO 3
#define YC_PROC_PIDPATHINFO 11

/* DIRTYCONTROL flavors. */
#define YC_PROC_DIRTYCONTROL_TRACK 1
#define YC_PROC_DIRTYCONTROL_SET 2
#define YC_PROC_DIRTYCONTROL_GET 3
#define YC_PROC_DIRTYCONTROL_CLEAR 4

/* proc_info_extended_id flag: compare the pid version. */
#define YC_PIF_COMPARE_IDVERSION 0x1u

#define YC_PROC_PIDPATHINFO_SIZE 1024    /* MAXPATHLEN */
#define YC_PROC_PIDPATHINFO_MAXSIZE 4096 /* 4 * MAXPATHLEN */

/* struct proc_bsdinfo (136 bytes); only the name fields are read. */
struct yc_proc_bsdinfo {
    yc_u32 head[12]; /* pbi_flags .. reserved, offsets 0..47 */
    char comm[16];   /* 48 */
    char name[32];   /* 64 */
    yc_u32 tail[10]; /* pbi_nfiles .. pbi_start_tvusec, 96..135 */
};
_Static_assert(sizeof(struct yc_proc_bsdinfo) == 136, "proc_bsdinfo is 136 bytes");

/* audit_token_t: eight u32 words. */
struct yc_audit_token {
    yc_u32 val[8];
};

/* Generated wrappers (syscalls.S); fakes in the host tests. */
int YC_KFN(__proc_info)(int callnum, int pid, yc_u32 flavor, yc_u64 arg, void *buffer, int buffersize);
int YC_KFN(__proc_info_extended_id)(int callnum, int pid, yc_u32 flavor, yc_u32 flags, yc_u64 ext_id, yc_u64 arg,
                                    void *buffer, int buffersize);

static int last_errno(void)
{
    return *YC_KFN(__error)();
}

static int c_strlen(const char *s, int max)
{
    int n = 0;
    while (n < max && s[n] != '\0')
        n++;
    return n;
}

/* ------------------------------------------------------------ lists */

/* int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer,
 *     int buffersize): the byte count the kernel reports (a size hint
 * when buffer is NULL); 0 on error with errno set. */
YC_EXPORT int YC_FN(proc_listpids)(yc_u32 type, yc_u32 typeinfo, void *buffer, int buffersize)
{
    if (type < YC_PROC_ALL_PIDS || type > YC_PROC_KDBG_ONLY) {
        __ycode_set_errno(YC_EINVAL);
        return 0;
    }
    int r = YC_KFN(__proc_info)(YC_PROC_INFO_CALL_LISTPIDS, (int)type, typeinfo, 0, buffer, buffersize);
    return r < 0 ? 0 : r;
}

/* The count forms return bytes / sizeof(pid_t). */
YC_EXPORT int YC_FN(proc_listallpids)(void *buffer, int buffersize)
{
    return YC_FN(proc_listpids)(YC_PROC_ALL_PIDS, 0, buffer, buffersize) / 4;
}

YC_EXPORT int YC_FN(proc_listpgrppids)(int pgrpid, void *buffer, int buffersize)
{
    return YC_FN(proc_listpids)(YC_PROC_PGRP_ONLY, (yc_u32)pgrpid, buffer, buffersize) / 4;
}

YC_EXPORT int YC_FN(proc_listchildpids)(int ppid, void *buffer, int buffersize)
{
    return YC_FN(proc_listpids)(YC_PROC_PPID_ONLY, (yc_u32)ppid, buffer, buffersize) / 4;
}

/* ----------------------------------------------------------- pidinfo */

/* int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer,
 *     int buffersize): bytes written, or 0 with errno set. */
YC_EXPORT int YC_FN(proc_pidinfo)(int pid, int flavor, yc_u64 arg, void *buffer, int buffersize)
{
    int r = YC_KFN(__proc_info)(YC_PROC_INFO_CALL_PIDINFO, pid, (yc_u32)flavor, arg, buffer, buffersize);
    return r < 0 ? 0 : r;
}

/* int proc_pidfdinfo(int pid, int fd, int flavor, void *buffer,
 *     int buffersize): bytes written, or 0 with errno set. */
YC_EXPORT int YC_FN(proc_pidfdinfo)(int pid, int fd, int flavor, void *buffer, int buffersize)
{
    int r = YC_KFN(__proc_info)(YC_PROC_INFO_CALL_PIDFDINFO, pid, (yc_u32)flavor, (yc_u64)(yc_i64)fd, buffer, buffersize);
    return r < 0 ? 0 : r;
}

/* int proc_name(int pid, void *buffer, uint32_t buffersize): pbi_name if
 * it is not empty, else pbi_comm; returns its length. A buffer under 32
 * bytes: errno ENOMEM, result 0. Failure: 0. */
YC_EXPORT int YC_FN(proc_name)(int pid, void *buffer, yc_u32 buffersize)
{
    struct yc_proc_bsdinfo info;
    if (buffersize < sizeof info.name || buffer == YC_NULL) {
        __ycode_set_errno(YC_ENOMEM);
        return 0;
    }
    if (YC_FN(proc_pidinfo)(pid, YC_PROC_PIDTBSDINFO, 0, &info, (int)sizeof info) == 0)
        return 0;
    const char *src = info.name[0] != '\0' ? info.name : info.comm;
    int max = info.name[0] != '\0' ? (int)sizeof info.name - 1 : (int)sizeof info.comm - 1;
    int n = c_strlen(src, max);
    char *dst = buffer;
    for (int i = 0; i < n; i++)
        dst[i] = src[i];
    dst[n] = '\0';
    return n;
}

/* Common bounds of the path calls: 1024 <= size <= 4096. */
static int path_buffer_ok(void *buffer, yc_u32 buffersize)
{
    if (buffer == YC_NULL || buffersize < YC_PROC_PIDPATHINFO_SIZE) {
        __ycode_set_errno(YC_ENOMEM);
        return 0;
    }
    if (buffersize > YC_PROC_PIDPATHINFO_MAXSIZE) {
        __ycode_set_errno(YC_EOVERFLOW);
        return 0;
    }
    return 1;
}

/* int proc_pidpath(int pid, void *buffer, uint32_t buffersize): the
 * executable's path; returns its length, 0 on failure (errno set). */
YC_EXPORT int YC_FN(proc_pidpath)(int pid, void *buffer, yc_u32 buffersize)
{
    if (!path_buffer_ok(buffer, buffersize))
        return 0;
    if (YC_KFN(__proc_info)(YC_PROC_INFO_CALL_PIDINFO, pid, YC_PROC_PIDPATHINFO, 0, buffer, (int)buffersize) < 0)
        return 0;
    return c_strlen(buffer, (int)buffersize);
}

/* int proc_pidpath_audittoken(audit_token_t *token, void *buffer,
 *     uint32_t buffersize): as proc_pidpath for pid val[5], failing with
 * ESRCH when the process's pid version is no longer val[7]. */
YC_EXPORT int YC_FN(proc_pidpath_audittoken)(const struct yc_audit_token *token, void *buffer, yc_u32 buffersize)
{
    if (token == YC_NULL) {
        __ycode_set_errno(YC_EINVAL);
        return 0;
    }
    if (!path_buffer_ok(buffer, buffersize))
        return 0;
    if (YC_KFN(__proc_info_extended_id)(YC_PROC_INFO_CALL_PIDINFO, (int)token->val[5], YC_PROC_PIDPATHINFO,
                                YC_PIF_COMPARE_IDVERSION, token->val[7], 0, buffer, (int)buffersize) < 0)
        return 0;
    return c_strlen(buffer, (int)buffersize);
}

/* int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer): 0, or
 * -1 with errno set. The kernel writes the flavor's struct to buffer. */
YC_EXPORT int YC_FN(proc_pid_rusage)(int pid, int flavor, void *buffer)
{
    return YC_KFN(__proc_info)(YC_PROC_INFO_CALL_PIDRUSAGE, pid, (yc_u32)flavor, 0, buffer, 0) < 0 ? -1 : 0;
}

/* --------------------------------------------- dirty tracking, terminate */

/* These return 0 or the error number (errno is also set by the wrapper). */
static int dirtycontrol(int pid, yc_u32 flavor, yc_u64 arg, int *result)
{
    int r = YC_KFN(__proc_info)(YC_PROC_INFO_CALL_DIRTYCONTROL, pid, flavor, arg, YC_NULL, 0);
    if (r < 0)
        return last_errno();
    if (result != YC_NULL)
        *result = r;
    return 0;
}

/* int proc_track_dirty(pid_t pid, uint32_t flags) */
YC_EXPORT int YC_FN(proc_track_dirty)(int pid, yc_u32 flags)
{
    return dirtycontrol(pid, YC_PROC_DIRTYCONTROL_TRACK, flags, YC_NULL);
}

/* int proc_set_dirty(pid_t pid, bool dirty) */
YC_EXPORT int YC_FN(proc_set_dirty)(int pid, yc_bool dirty)
{
    return dirtycontrol(pid, YC_PROC_DIRTYCONTROL_SET, dirty ? 1 : 0, YC_NULL);
}

/* int proc_get_dirty(pid_t pid, uint32_t *flags) */
YC_EXPORT int YC_FN(proc_get_dirty)(int pid, yc_u32 *flags)
{
    if (flags == YC_NULL)
        return YC_EINVAL;
    int bits = 0;
    int err = dirtycontrol(pid, YC_PROC_DIRTYCONTROL_GET, 0, &bits);
    if (err == 0)
        *flags = (yc_u32)bits;
    return err;
}

/* int proc_clear_dirty(pid_t pid, uint32_t flags) */
YC_EXPORT int YC_FN(proc_clear_dirty)(int pid, yc_u32 flags)
{
    return dirtycontrol(pid, YC_PROC_DIRTYCONTROL_CLEAR, flags, YC_NULL);
}

/* int proc_terminate(pid_t pid, int *sig): the signal the kernel used
 * (SIGKILL for a clean dirty-tracked process, else SIGTERM). */
YC_EXPORT int YC_FN(proc_terminate)(int pid, int *sig)
{
    if (sig == YC_NULL)
        return YC_EINVAL;
    int r = YC_KFN(__proc_info)(YC_PROC_INFO_CALL_TERMINATE, pid, 0, 0, YC_NULL, 0);
    if (r < 0)
        return last_errno();
    *sig = r;
    return 0;
}
