/*
 * spawn.c - posix_spawn, the posix_spawnattr_* and posix_spawn_file_actions_*
 * families of libsystem_kernel.
 *
 * Clean-room Ycode code. Contract: specs/simulator/processes.md section 0
 * and section 1 (1.1 return convention, 1.2 the 144-byte argument
 * descriptor, 1.4 the 248-byte attribute block and its defaults, 1.5 flags,
 * 1.6 value sets, 1.7 file actions, 1.8 port actions, 1.14 library rules);
 * stage4b-contract.md section 8. Public C signatures: the SDK <spawn.h>
 * and the private SPI names listed in specs/simulator/data/
 * host-lib-surface-kernel.json. Constants from public headers:
 * OPEN_MAX 10240, MAXPATHLEN 1024, CPU_SUBTYPE_ANY -1,
 * IOPOL_MATERIALIZE_DATALESS_FILES_ORIG 4.
 *
 * posix_spawnattr_t and posix_spawn_file_actions_t are pointers to heap
 * blocks with the layouts of section 1.4 / 1.7. The heap is libsystem_c's
 * malloc from the _libkernel_functions table (host-library-init.md 2.1),
 * or anonymous mmap memory when that table was never installed.
 */
#include "yc_kernel.h"

typedef __INT16_TYPE__ yc_i16;

#define YC_EBADF 9
#define YC_ENAMETOOLONG 63

#define YC_OPEN_MAX 10240
#define YC_MAXPATHLEN 1024
#define YC_CPU_SUBTYPE_ANY ((yc_i32)-1)
#define YC_IOPOL_DATALESS_ORIG 4
#define YC_PSA_OPTION_DATALESS_IOPOLICY 0x4u
#define YC_QOS_CLAMP_LAST 4u /* clamps 0..3 are valid (section 1.6) */
#define YC_IMPORTANCE_PORTS_MAX 128
#define YC_REGISTERED_PORTS_MAX 3

#define YC_BSD_POSIX_SPAWN 244

/* ------------------------------------------------------------- layouts */

/* Section 1.4: struct _posix_spawnattr, 248 bytes. */
struct yc_spawnattr {
    yc_i16 flags;                 /* 0 */
    yc_i16 pad0;                  /* 2 */
    yc_u32 sigdefault;            /* 4 */
    yc_u32 sigmask;               /* 8 */
    yc_i32 pgroup;                /* 12 */
    yc_i32 binprefs[4];           /* 16 */
    yc_i32 pcontrol;              /* 32 */
    yc_i32 apptype;               /* 36 */
    yc_u64 cpumonitor_percent;    /* 40 */
    yc_u64 cpumonitor_interval;   /* 48 */
    yc_u64 reserved;              /* 56, default 1 */
    yc_i16 jetsam_flags;          /* 64 */
    yc_i16 pad1;                  /* 66 */
    yc_i32 priority;              /* 68, default -1 */
    yc_i32 memlimit_active;       /* 72, default -1 */
    yc_i32 memlimit_inactive;     /* 76, default -1 */
    yc_u64 qos_clamp;             /* 80 */
    yc_u32 darwin_role;           /* 88 */
    yc_i32 thread_limit;          /* 92 */
    yc_u64 max_addr;              /* 96 */
    yc_u8 no_smt;                 /* 104 */
    yc_u8 force_4k;               /* 105 */
    yc_u8 tecs;                   /* 106 */
    yc_u8 pad2;                   /* 107 */
    yc_i32 platform;              /* 108 */
    yc_i32 subcpuprefs[4];        /* 112, default CPU_SUBTYPE_ANY */
    yc_u32 options;               /* 128 */
    yc_u32 port_soft_limit;       /* 132 */
    yc_u32 port_hard_limit;       /* 136 */
    yc_u32 filedesc_soft_limit;   /* 140 */
    yc_u32 filedesc_hard_limit;   /* 144 */
    yc_u32 crash_behavior;        /* 148 */
    yc_i32 dataless_iopolicy;     /* 152 */
    yc_u32 pad3;                  /* 156 */
    yc_u64 crash_behavior_deadline; /* 160 */
    yc_u8 launch_type;            /* 168 */
    yc_u8 pad4;                   /* 169 */
    yc_u16 sec_flags;             /* 170 */
    yc_u32 crash_count;           /* 172 */
    yc_u32 throttle_timeout;      /* 176 */
    yc_u32 kqworkloop_soft_limit; /* 180 */
    yc_u32 kqworkloop_hard_limit; /* 184 */
    yc_u32 conclave_mem_limit;    /* 188 */
    struct yc_port_actions *ports; /* 192 */
    void *mac_extensions;         /* 200 */
    void *coalition_info;         /* 208 */
    void *persona_info;           /* 216 */
    void *posix_cred_info;        /* 224 */
    char *subsystem_root_path;    /* 232, a MAXPATHLEN buffer */
    char *conclave_id;            /* 240 */
};
_Static_assert(sizeof(struct yc_spawnattr) == 248, "attribute block is 248 bytes");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, jetsam_flags) == 64, "psa_jetsam_flags");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, qos_clamp) == 80, "psa_qos_clamp");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, platform) == 108, "psa_platform");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, subcpuprefs) == 112, "psa_subcpuprefs");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, dataless_iopolicy) == 152, "psa_dataless_iopolicy");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, crash_behavior_deadline) == 160, "deadline");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, sec_flags) == 170, "psa_sec_flags");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, ports) == 192, "psa_ports");
_Static_assert(__builtin_offsetof(struct yc_spawnattr, subsystem_root_path) == 232, "subsystem root");

/* Section 1.8: port actions, 24 bytes each after an 8-byte header. */
enum {
    YC_PSPA_SPECIAL = 0,
    YC_PSPA_EXCEPTION = 1,
    YC_PSPA_AU_SESSION = 2,
    YC_PSPA_IMP_WATCHPORTS = 3,
    YC_PSPA_REGISTERED_PORTS = 4,
};
struct yc_port_action {
    yc_u32 port_type;
    yc_u32 mask;
    yc_u32 new_port;
    yc_u32 behavior;
    yc_u32 flavor;
    yc_u32 which;
};
struct yc_port_actions {
    yc_i32 alloc;
    yc_i32 count;
    struct yc_port_action actions[];
};
_Static_assert(sizeof(struct yc_port_action) == 24, "port action is 24 bytes");
_Static_assert(sizeof(struct yc_port_actions) == 8, "port-action header is 8 bytes");

/* Section 1.7: file actions, 1040 bytes each after an 8-byte header. */
enum {
    YC_PSFA_OPEN = 0,
    YC_PSFA_CLOSE = 1,
    YC_PSFA_DUP2 = 2,
    YC_PSFA_INHERIT = 3,
    YC_PSFA_FILEPORT_DUP2 = 4,
    YC_PSFA_CHDIR = 5,
    YC_PSFA_FCHDIR = 6,
};
struct yc_file_action {
    yc_i32 type;
    yc_i32 filedes; /* or the fileport name for FILEPORT_DUP2 */
    union {
        struct {
            yc_i32 oflag;
            yc_u16 mode;
            char path[YC_MAXPATHLEN];
        } open;
        yc_i32 newfiledes;
        char path[YC_MAXPATHLEN];
    } u;
};
struct yc_file_actions {
    yc_i32 alloc;
    yc_i32 count;
    struct yc_file_action actions[];
};
_Static_assert(sizeof(struct yc_file_action) == 1040, "file action is 1040 bytes");
_Static_assert(__builtin_offsetof(struct yc_file_action, u.open.mode) == 12, "open mode");
_Static_assert(__builtin_offsetof(struct yc_file_action, u.open.path) == 14, "open path");
_Static_assert(sizeof(struct yc_file_actions) == 8, "file-action header is 8 bytes");

/* Section 1.2: struct _posix_spawn_args_desc, nine (size, pointer) pairs. */
struct yc_spawn_pair {
    yc_u64 size;
    const void *ptr;
};
struct yc_spawn_desc {
    struct yc_spawn_pair attr;
    struct yc_spawn_pair file_actions;
    struct yc_spawn_pair port_actions;
    struct yc_spawn_pair mac_extensions;
    struct yc_spawn_pair coal_info;
    struct yc_spawn_pair persona_info;
    struct yc_spawn_pair posix_cred_info;
    struct yc_spawn_pair subsystem_root_path;
    struct yc_spawn_pair conclave_id;
};
_Static_assert(sizeof(struct yc_spawn_desc) == 144, "descriptor is 144 bytes");

typedef struct yc_spawnattr *yc_spawnattr_t;
typedef struct yc_file_actions *yc_file_actions_t;

/* ------------------------------------------------------------ helpers */

static void zero_bytes(void *p, yc_size_t n)
{
    volatile yc_u8 *b = p; /* volatile: keep the compiler from emitting memset */
    for (yc_size_t i = 0; i < n; i++)
        b[i] = 0;
}

static void copy_bytes(void *dst, const void *src, yc_size_t n)
{
    volatile yc_u8 *d = dst;
    const yc_u8 *s = src;
    for (yc_size_t i = 0; i < n; i++)
        d[i] = s[i];
}

static yc_size_t string_length(const char *s)
{
    yc_size_t n = 0;
    while (s[n] != '\0')
        n++;
    return n;
}

/* Copy a C string into a MAXPATHLEN buffer; ENAMETOOLONG if it does not
 * fit with its terminator. */
static int copy_path(char *dst, const char *src)
{
    yc_size_t n = string_length(src);
    if (n >= YC_MAXPATHLEN)
        return YC_ENAMETOOLONG;
    copy_bytes(dst, src, n + 1);
    return 0;
}

/* Heap blocks carry a 16-byte header that says where they came from. */
struct yc_block {
    yc_u64 size; /* payload size */
    yc_u64 source;
};
#define YC_BLOCK_MALLOC 1u
#define YC_BLOCK_MMAP 2u


static yc_size_t mmap_length(yc_size_t payload)
{
    return (payload + sizeof(struct yc_block) + YC_PAGE_SIZE - 1) & ~(YC_PAGE_SIZE - 1);
}

/* Zero-filled memory, or NULL. */
static void *spawn_alloc(yc_size_t size)
{
    const struct yc_libkernel_functions *f = yc_libkernel_fns;
    struct yc_block *b;
    yc_u64 source;
    if (f != YC_NULL && f->version >= 1 && f->malloc != YC_NULL && f->free != YC_NULL) {
        b = f->malloc(size + sizeof(struct yc_block));
        if (b == YC_NULL)
            return YC_NULL;
        source = YC_BLOCK_MALLOC;
    } else {
        void *m = YC_KFN(mmap)(YC_NULL, mmap_length(size), YC_PROT_READ | YC_PROT_WRITE,
                               YC_MAP_PRIVATE | YC_MAP_ANON, -1, 0);
        if (m == YC_MAP_FAILED)
            return YC_NULL;
        b = m;
        source = YC_BLOCK_MMAP;
    }
    b->size = size;
    b->source = source;
    zero_bytes(b + 1, size);
    return b + 1;
}

static void spawn_free(void *p)
{
    if (p == YC_NULL)
        return;
    struct yc_block *b = (struct yc_block *)p - 1;
    if (b->source == YC_BLOCK_MMAP) {
        (void)YC_KFN(munmap)(b, mmap_length(b->size));
    } else {
        const struct yc_libkernel_functions *f = yc_libkernel_fns;
        if (f != YC_NULL && f->free != YC_NULL)
            f->free(b);
    }
}

/* A new zero-filled block of `size` bytes holding the first `keep` bytes
 * of `old` (which is freed). NULL on failure, `old` untouched. */
static void *spawn_grow(void *old, yc_size_t keep, yc_size_t size)
{
    void *p = spawn_alloc(size);
    if (p == YC_NULL)
        return YC_NULL;
    if (old != YC_NULL) {
        copy_bytes(p, old, keep);
        spawn_free(old);
    }
    return p;
}

/* The attribute block behind a posix_spawnattr_t *, or NULL. */
static struct yc_spawnattr *attr_of(const yc_spawnattr_t *attr)
{
    return (attr == YC_NULL) ? YC_NULL : *attr;
}

/* ------------------------------------------------------- posix_spawn */

#ifdef YC_HOST_TEST
/* The host tests record the call instead. */
int yc_testk_posix_spawn_trap(int *pid, const char *path, const void *desc, char *const argv[], char *const envp[]);
#define posix_spawn_trap yc_testk_posix_spawn_trap
#else
/* BSD 244 issued directly: the error number comes back as the result and
 * errno is not touched (section 1.1). */
static int posix_spawn_trap(int *pid, const char *path, const struct yc_spawn_desc *desc, char *const argv[],
                            char *const envp[])
{
    register yc_uintptr_t x0 __asm__("x0") = (yc_uintptr_t)pid;
    register yc_uintptr_t x1 __asm__("x1") = (yc_uintptr_t)path;
    register yc_uintptr_t x2 __asm__("x2") = (yc_uintptr_t)desc;
    register yc_uintptr_t x3 __asm__("x3") = (yc_uintptr_t)argv;
    register yc_uintptr_t x4 __asm__("x4") = (yc_uintptr_t)envp;
    register long x16 __asm__("x16") = YC_BSD_POSIX_SPAWN;
    yc_uintptr_t failed;
    __asm__ volatile("svc #0x80\n\tcset %2, cs"
                     : "+r"(x0), "+r"(x1), "=&r"(failed)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory", "cc");
    return failed ? (int)x0 : 0;
}
#endif

/* int posix_spawn(pid_t *pid, const char *path,
 *     const posix_spawn_file_actions_t *file_actions,
 *     const posix_spawnattr_t *attrp, char *const argv[], char *const envp[])
 * Returns 0 or an error number. With POSIX_SPAWN_SETEXEC a successful call
 * does not return. The descriptor is passed only when there are
 * attributes or at least one file action (section 1.1). */
YC_EXPORT int YC_FN(posix_spawn)(int *pid, const char *path, const yc_file_actions_t *file_actions,
                          const yc_spawnattr_t *attrp, char *const argv[], char *const envp[])
{
    struct yc_spawn_desc desc;
    int have_desc = 0;
    zero_bytes(&desc, sizeof desc);

    struct yc_spawnattr *a = attr_of(attrp);
    if (a != YC_NULL) {
        have_desc = 1;
        desc.attr.size = sizeof(struct yc_spawnattr);
        desc.attr.ptr = a;
        if (a->ports != YC_NULL && a->ports->count > 0) {
            desc.port_actions.size =
                sizeof(struct yc_port_actions) + (yc_u64)a->ports->count * sizeof(struct yc_port_action);
            desc.port_actions.ptr = a->ports;
        }
        if (a->subsystem_root_path != YC_NULL) {
            desc.subsystem_root_path.size = YC_MAXPATHLEN;
            desc.subsystem_root_path.ptr = a->subsystem_root_path;
        }
    }
    struct yc_file_actions *fa = (file_actions == YC_NULL) ? YC_NULL : *file_actions;
    if (fa != YC_NULL && fa->count > 0) {
        have_desc = 1;
        desc.file_actions.size = sizeof(struct yc_file_actions) + (yc_u64)fa->count * sizeof(struct yc_file_action);
        desc.file_actions.ptr = fa;
    }
    return posix_spawn_trap(pid, path, have_desc ? &desc : YC_NULL, argv, envp);
}

/* ------------------------------------------------------ attribute block */

YC_EXPORT int YC_FN(posix_spawnattr_init)(yc_spawnattr_t *attr)
{
    if (attr == YC_NULL)
        return YC_EINVAL;
    struct yc_spawnattr *a = spawn_alloc(sizeof *a);
    if (a == YC_NULL)
        return YC_ENOMEM;
    /* Everything else is 0 (section 1.4). */
    a->reserved = 1;
    a->priority = -1;
    a->memlimit_active = -1;
    a->memlimit_inactive = -1;
    for (int i = 0; i < 4; i++)
        a->subcpuprefs[i] = YC_CPU_SUBTYPE_ANY;
    *attr = a;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_destroy)(yc_spawnattr_t *attr)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    spawn_free(a->ports);
    spawn_free(a->subsystem_root_path);
    spawn_free(a);
    *attr = YC_NULL;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_setflags)(yc_spawnattr_t *attr, short flags)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    a->flags = flags;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_getflags)(const yc_spawnattr_t *attr, short *flags)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || flags == YC_NULL)
        return YC_EINVAL;
    *flags = a->flags;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_setpgroup)(yc_spawnattr_t *attr, int pgroup)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    a->pgroup = pgroup;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_getpgroup)(const yc_spawnattr_t *attr, int *pgroup)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || pgroup == YC_NULL)
        return YC_EINVAL;
    *pgroup = a->pgroup;
    return 0;
}

/* sigset_t is a u32 on Darwin. */
YC_EXPORT int YC_FN(posix_spawnattr_setsigdefault)(yc_spawnattr_t *attr, const yc_u32 *sigdefault)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || sigdefault == YC_NULL)
        return YC_EINVAL;
    a->sigdefault = *sigdefault;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_getsigdefault)(const yc_spawnattr_t *attr, yc_u32 *sigdefault)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || sigdefault == YC_NULL)
        return YC_EINVAL;
    *sigdefault = a->sigdefault;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_setsigmask)(yc_spawnattr_t *attr, const yc_u32 *sigmask)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || sigmask == YC_NULL)
        return YC_EINVAL;
    a->sigmask = *sigmask;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_getsigmask)(const yc_spawnattr_t *attr, yc_u32 *sigmask)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || sigmask == YC_NULL)
        return YC_EINVAL;
    *sigmask = a->sigmask;
    return 0;
}

/* Architecture preferences (sections 1.6 and 1.14): copy up to four
 * entries, fill the rest with 0 / CPU_SUBTYPE_ANY, report the number
 * copied. */
static int set_prefs(yc_spawnattr_t *attr, yc_size_t count, const yc_i32 *types, const yc_i32 *subtypes,
                     yc_size_t *ocount)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || (count > 0 && types == YC_NULL))
        return YC_EINVAL;
    yc_size_t n = count < 4 ? count : 4;
    for (yc_size_t i = 0; i < 4; i++) {
        a->binprefs[i] = i < n ? types[i] : 0;
        a->subcpuprefs[i] = (i < n && subtypes != YC_NULL) ? subtypes[i] : YC_CPU_SUBTYPE_ANY;
    }
    if (ocount != YC_NULL)
        *ocount = n;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_setbinpref_np)(yc_spawnattr_t *attr, yc_size_t count, yc_i32 *pref, yc_size_t *ocount)
{
    return set_prefs(attr, count, pref, YC_NULL, ocount);
}

YC_EXPORT int YC_FN(posix_spawnattr_setarchpref_np)(yc_spawnattr_t *attr, yc_size_t count, yc_i32 *pref, yc_i32 *subpref,
                                             yc_size_t *ocount)
{
    return set_prefs(attr, count, pref, subpref, ocount);
}

/* Read back up to `count` slots, stopping at the first empty one. */
static int get_prefs(const yc_spawnattr_t *attr, yc_size_t count, yc_i32 *types, yc_i32 *subtypes,
                     yc_size_t *ocount)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || (count > 0 && types == YC_NULL))
        return YC_EINVAL;
    yc_size_t n = 0;
    while (n < count && n < 4 && a->binprefs[n] != 0) {
        types[n] = a->binprefs[n];
        if (subtypes != YC_NULL)
            subtypes[n] = a->subcpuprefs[n];
        n++;
    }
    if (ocount != YC_NULL)
        *ocount = n;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_getbinpref_np)(const yc_spawnattr_t *attr, yc_size_t count, yc_i32 *pref,
                                            yc_size_t *ocount)
{
    return get_prefs(attr, count, pref, YC_NULL, ocount);
}

YC_EXPORT int YC_FN(posix_spawnattr_getarchpref_np)(const yc_spawnattr_t *attr, yc_size_t count, yc_i32 *pref,
                                             yc_i32 *subpref, yc_size_t *ocount)
{
    return get_prefs(attr, count, pref, subpref, ocount);
}

/* int posix_spawnattr_setprocesstype_np(posix_spawnattr_t *, const int) */
YC_EXPORT int YC_FN(posix_spawnattr_setprocesstype_np)(yc_spawnattr_t *attr, const int type)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    a->apptype = type;
    return 0;
}

/* int posix_spawnattr_setcpumonitor(posix_spawnattr_t *, uint64_t percent,
 *     uint64_t interval) */
YC_EXPORT int YC_FN(posix_spawnattr_setcpumonitor)(yc_spawnattr_t *attr, yc_u64 percent, yc_u64 interval)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    a->cpumonitor_percent = percent;
    a->cpumonitor_interval = interval;
    return 0;
}

/* int posix_spawnattr_set_qos_clamp_np(const posix_spawnattr_t *, uint64_t) */
YC_EXPORT int YC_FN(posix_spawnattr_set_qos_clamp_np)(const yc_spawnattr_t *attr, yc_u64 clamp)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || clamp >= YC_QOS_CLAMP_LAST)
        return YC_EINVAL;
    a->qos_clamp = clamp;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_get_qos_clamp_np)(const yc_spawnattr_t *attr, yc_u64 *clamp)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || clamp == YC_NULL)
        return YC_EINVAL;
    *clamp = a->qos_clamp;
    return 0;
}

/* int posix_spawnattr_set_darwin_role_np(const posix_spawnattr_t *, uint64_t) */
YC_EXPORT int YC_FN(posix_spawnattr_set_darwin_role_np)(const yc_spawnattr_t *attr, yc_u64 role)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    a->darwin_role = (yc_u32)role;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawnattr_get_darwin_role_np)(const yc_spawnattr_t *attr, yc_u64 *role)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || role == YC_NULL)
        return YC_EINVAL;
    *role = a->darwin_role;
    return 0;
}

/* int posix_spawnattr_setdataless_iopolicy_np(posix_spawnattr_t *,
 *     const int policy): option 0x4 plus `policy | ORIG` (section 1.14). */
YC_EXPORT int YC_FN(posix_spawnattr_setdataless_iopolicy_np)(yc_spawnattr_t *attr, const int policy)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    a->options |= YC_PSA_OPTION_DATALESS_IOPOLICY;
    a->dataless_iopolicy = policy | YC_IOPOL_DATALESS_ORIG;
    return 0;
}

/* int posix_spawnattr_set_use_sec_transition_shims_np(posix_spawnattr_t *,
 *     uint32_t flags): records the flags in psa_sec_flags (section 1.14);
 * Ycode's kernel ignores the field. */
YC_EXPORT int YC_FN(posix_spawnattr_set_use_sec_transition_shims_np)(yc_spawnattr_t *attr, yc_u32 flags)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    a->sec_flags |= (yc_u16)flags;
    return 0;
}

/* posix_spawnattr_set_use_sanitizers_np: its effect is not specified
 * (processes.md open question 6): succeed and store nothing. */
YC_EXPORT int YC_FN(posix_spawnattr_set_use_sanitizers_np)(yc_spawnattr_t *attr, yc_u32 flags)
{
    (void)flags;
    if (attr_of(attr) == YC_NULL)
        return YC_EINVAL;
    return 0;
}

/* int posix_spawnattr_set_subsystem_root_path_np(posix_spawnattr_t *,
 *     char *path): a MAXPATHLEN copy; NULL clears it (section 1.14). */
YC_EXPORT int YC_FN(posix_spawnattr_set_subsystem_root_path_np)(yc_spawnattr_t *attr, char *path)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    if (path == YC_NULL) {
        spawn_free(a->subsystem_root_path);
        a->subsystem_root_path = YC_NULL;
        return 0;
    }
    if (string_length(path) >= YC_MAXPATHLEN)
        return YC_ENAMETOOLONG;
    if (a->subsystem_root_path == YC_NULL) {
        a->subsystem_root_path = spawn_alloc(YC_MAXPATHLEN);
        if (a->subsystem_root_path == YC_NULL)
            return YC_ENOMEM;
    }
    zero_bytes(a->subsystem_root_path, YC_MAXPATHLEN);
    return copy_path(a->subsystem_root_path, path);
}

/* ------------------------------------------------------- port actions */

/* Append one 24-byte action (initial room for 2, doubling). */
static int add_port_action(struct yc_spawnattr *a, const struct yc_port_action *action)
{
    struct yc_port_actions *p = a->ports;
    if (p == YC_NULL || p->count == p->alloc) {
        yc_i32 alloc = (p == YC_NULL) ? 2 : p->alloc * 2;
        yc_size_t keep = (p == YC_NULL) ? 0 : sizeof *p + (yc_size_t)p->count * sizeof(struct yc_port_action);
        struct yc_port_actions *q =
            spawn_grow(p, keep, sizeof *q + (yc_size_t)alloc * sizeof(struct yc_port_action));
        if (q == YC_NULL)
            return YC_ENOMEM;
        q->alloc = alloc;
        a->ports = p = q;
    }
    p->actions[p->count++] = *action;
    return 0;
}

static int add_port_action_of(yc_spawnattr_t *attr, yc_u32 type, yc_u32 port, yc_u32 which, yc_u32 mask,
                              yc_u32 behavior, yc_u32 flavor)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL)
        return YC_EINVAL;
    struct yc_port_action action = {type, mask, port, behavior, flavor, which};
    return add_port_action(a, &action);
}

/* int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t,
 *     int which) */
YC_EXPORT int YC_FN(posix_spawnattr_setspecialport_np)(yc_spawnattr_t *attr, yc_port_t port, int which)
{
    return add_port_action_of(attr, YC_PSPA_SPECIAL, port, (yc_u32)which, 0, 0, 0);
}

/* int posix_spawnattr_setexceptionports_np(posix_spawnattr_t *,
 *     exception_mask_t, mach_port_t, exception_behavior_t,
 *     thread_state_flavor_t) */
YC_EXPORT int YC_FN(posix_spawnattr_setexceptionports_np)(yc_spawnattr_t *attr, yc_u32 mask, yc_port_t port,
                                                   int behavior, int flavor)
{
    return add_port_action_of(attr, YC_PSPA_EXCEPTION, port, 0, mask, (yc_u32)behavior, (yc_u32)flavor);
}

/* int posix_spawnattr_setauditsessionport_np(posix_spawnattr_t *, mach_port_t) */
YC_EXPORT int YC_FN(posix_spawnattr_setauditsessionport_np)(yc_spawnattr_t *attr, yc_port_t port)
{
    return add_port_action_of(attr, YC_PSPA_AU_SESSION, port, 0, 0, 0, 0);
}

/* Append `count` actions of one type, one per port, in array order; on
 * failure the attribute is left as it was. */
static int add_port_list(yc_spawnattr_t *attr, yc_u32 type, const yc_port_t *ports, yc_u32 count, yc_u32 max)
{
    struct yc_spawnattr *a = attr_of(attr);
    if (a == YC_NULL || count > max || (count > 0 && ports == YC_NULL))
        return YC_EINVAL;
    yc_i32 before = a->ports ? a->ports->count : 0;
    for (yc_u32 i = 0; i < count; i++) {
        struct yc_port_action action = {type, 0, ports[i], 0, 0, 0};
        int err = add_port_action(a, &action);
        if (err != 0) {
            if (a->ports)
                a->ports->count = before;
            return err;
        }
    }
    return 0;
}

/* int posix_spawnattr_set_importancewatch_port_np(posix_spawnattr_t *,
 *     int count, mach_port_t ports[]) */
YC_EXPORT int YC_FN(posix_spawnattr_set_importancewatch_port_np)(yc_spawnattr_t *attr, int count, yc_port_t *ports)
{
    if (count < 0)
        return YC_EINVAL;
    return add_port_list(attr, YC_PSPA_IMP_WATCHPORTS, ports, (yc_u32)count, YC_IMPORTANCE_PORTS_MAX);
}

/* int posix_spawnattr_set_registered_ports_np(posix_spawnattr_t *,
 *     mach_port_t ports[], uint32_t count): count <= 3. */
YC_EXPORT int YC_FN(posix_spawnattr_set_registered_ports_np)(yc_spawnattr_t *attr, yc_port_t *ports, yc_u32 count)
{
    return add_port_list(attr, YC_PSPA_REGISTERED_PORTS, ports, count, YC_REGISTERED_PORTS_MAX);
}

/* ------------------------------------------------------- file actions */

YC_EXPORT int YC_FN(posix_spawn_file_actions_init)(yc_file_actions_t *file_actions)
{
    if (file_actions == YC_NULL)
        return YC_EINVAL;
    struct yc_file_actions *fa = spawn_alloc(sizeof *fa + 2 * sizeof(struct yc_file_action));
    if (fa == YC_NULL)
        return YC_ENOMEM;
    fa->alloc = 2;
    fa->count = 0;
    *file_actions = fa;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_destroy)(yc_file_actions_t *file_actions)
{
    if (file_actions == YC_NULL || *file_actions == YC_NULL)
        return YC_EINVAL;
    spawn_free(*file_actions);
    *file_actions = YC_NULL;
    return 0;
}

static int fd_ok(int fd)
{
    return fd >= 0 && fd < YC_OPEN_MAX;
}

/* A new zeroed action at the end of the list (growing it), or NULL with
 * *err set. */
static struct yc_file_action *new_file_action(yc_file_actions_t *file_actions, yc_i32 type, int *err)
{
    struct yc_file_actions *fa = *file_actions;
    if (fa->count == fa->alloc) {
        yc_i32 alloc = fa->alloc > 0 ? fa->alloc * 2 : 2;
        struct yc_file_actions *q = spawn_grow(fa, sizeof *fa + (yc_size_t)fa->count * sizeof(struct yc_file_action),
                                               sizeof *q + (yc_size_t)alloc * sizeof(struct yc_file_action));
        if (q == YC_NULL) {
            *err = YC_ENOMEM;
            return YC_NULL;
        }
        q->alloc = alloc;
        *file_actions = fa = q;
    }
    struct yc_file_action *act = &fa->actions[fa->count];
    zero_bytes(act, sizeof *act);
    act->type = type;
    return act;
}

/* Validates, then appends; the count grows only after the action is
 * complete. */
static int file_action_common(yc_file_actions_t *file_actions)
{
    return (file_actions == YC_NULL || *file_actions == YC_NULL) ? YC_EINVAL : 0;
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_addopen)(yc_file_actions_t *file_actions, int fd, const char *path, int oflag,
                                               yc_u16 mode)
{
    int err = file_action_common(file_actions);
    if (err != 0)
        return err;
    if (!fd_ok(fd))
        return YC_EBADF;
    if (path == YC_NULL)
        return YC_EINVAL;
    if (string_length(path) >= YC_MAXPATHLEN)
        return YC_ENAMETOOLONG;
    struct yc_file_action *act = new_file_action(file_actions, YC_PSFA_OPEN, &err);
    if (act == YC_NULL)
        return err;
    act->filedes = fd;
    act->u.open.oflag = oflag;
    act->u.open.mode = mode;
    (void)copy_path(act->u.open.path, path);
    (*file_actions)->count++;
    return 0;
}

static int add_fd_action(yc_file_actions_t *file_actions, yc_i32 type, int fd, int newfd)
{
    int err = file_action_common(file_actions);
    if (err != 0)
        return err;
    if (!fd_ok(fd) || (type == YC_PSFA_DUP2 && !fd_ok(newfd)))
        return YC_EBADF;
    struct yc_file_action *act = new_file_action(file_actions, type, &err);
    if (act == YC_NULL)
        return err;
    act->filedes = fd;
    if (type == YC_PSFA_DUP2)
        act->u.newfiledes = newfd;
    (*file_actions)->count++;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_addclose)(yc_file_actions_t *file_actions, int fd)
{
    return add_fd_action(file_actions, YC_PSFA_CLOSE, fd, 0);
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_adddup2)(yc_file_actions_t *file_actions, int fd, int newfd)
{
    return add_fd_action(file_actions, YC_PSFA_DUP2, fd, newfd);
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_addinherit_np)(yc_file_actions_t *file_actions, int fd)
{
    return add_fd_action(file_actions, YC_PSFA_INHERIT, fd, 0);
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_addfchdir)(yc_file_actions_t *file_actions, int fd)
{
    return add_fd_action(file_actions, YC_PSFA_FCHDIR, fd, 0);
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_addfchdir_np)(yc_file_actions_t *file_actions, int fd)
{
    return add_fd_action(file_actions, YC_PSFA_FCHDIR, fd, 0);
}

/* int posix_spawn_file_actions_add_fileportdup2_np(
 *     posix_spawn_file_actions_t *, mach_port_t fileport, int newfd) */
YC_EXPORT int YC_FN(posix_spawn_file_actions_add_fileportdup2_np)(yc_file_actions_t *file_actions, yc_port_t fileport,
                                                           int newfd)
{
    int err = file_action_common(file_actions);
    if (err != 0)
        return err;
    if (fileport == YC_MACH_PORT_NULL || fileport == YC_MACH_PORT_DEAD || !fd_ok(newfd))
        return YC_EBADF;
    struct yc_file_action *act = new_file_action(file_actions, YC_PSFA_FILEPORT_DUP2, &err);
    if (act == YC_NULL)
        return err;
    act->filedes = (yc_i32)fileport;
    act->u.newfiledes = newfd;
    (*file_actions)->count++;
    return 0;
}

static int add_chdir(yc_file_actions_t *file_actions, const char *path)
{
    int err = file_action_common(file_actions);
    if (err != 0)
        return err;
    if (path == YC_NULL)
        return YC_EINVAL;
    if (string_length(path) >= YC_MAXPATHLEN)
        return YC_ENAMETOOLONG;
    struct yc_file_action *act = new_file_action(file_actions, YC_PSFA_CHDIR, &err);
    if (act == YC_NULL)
        return err;
    (void)copy_path(act->u.path, path);
    (*file_actions)->count++;
    return 0;
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_addchdir)(yc_file_actions_t *file_actions, const char *path)
{
    return add_chdir(file_actions, path);
}

YC_EXPORT int YC_FN(posix_spawn_file_actions_addchdir_np)(yc_file_actions_t *file_actions, const char *path)
{
    return add_chdir(file_actions, path);
}
