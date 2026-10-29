/*
 * sysctl.c - libsystem_kernel's __sysctl (BSD 202) and issetugid (BSD 327)
 * with answers given in the library when the kernel allows it
 * (fast-traps.md section 5a, guest-cpu.md section 6).
 *
 * Clean-room Ycode code. Ycode's kernel answers these calls from fixed
 * data (specs/simulator/stage3-contract.md section 8, its sysctl table):
 *  - the name-to-OID query, sysctl({0, 3}, old, oldlenp, name, namelen):
 *    the MIB of a name never changes while the process runs;
 *  - kern.boottime ({1, 21}): fixed for the life of the simulated system;
 *  - issetugid: always 0 (guest credentials never change).
 * With the commpage's YC_FAST_SYSCTL_CACHE bit, the first answer of each
 * name-to-OID query and of kern.boottime comes from the trap and is kept in
 * the library; later identical queries are answered from that copy with the
 * kernel's copy-out rules (a size query when old is NULL, EINVAL without
 * oldlenp, ENOMEM when the buffer is too small). libc's sysctlbyname makes
 * both traps for every call (a boot asked for kern.boottime 105,000 times).
 * With YC_FAST_LOCAL_CALLS, issetugid answers 0 without the trap.
 * Unlike the kernel, a cache hit reads the caller's name and length
 * pointers directly: a bad pointer faults in the caller instead of
 * returning EFAULT.
 */
#include "yc_kernel.h"

static long yc_sysctl_trap(int *name, yc_u32 namelen, void *old, yc_size_t *oldlenp, void *new, yc_size_t newlen,
                           int *error)
{
    register yc_uintptr_t x0 __asm__("x0") = (yc_uintptr_t)name;
    register yc_uintptr_t x1 __asm__("x1") = namelen;
    register yc_uintptr_t x2 __asm__("x2") = (yc_uintptr_t)old;
    register yc_uintptr_t x3 __asm__("x3") = (yc_uintptr_t)oldlenp;
    register yc_uintptr_t x4 __asm__("x4") = (yc_uintptr_t)new;
    register yc_uintptr_t x5 __asm__("x5") = newlen;
    register long x16 __asm__("x16") = 202;
    yc_uintptr_t failed;
    __asm__ volatile("svc #0x80\n\tcset %[f], cs"
                     : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4), "+r"(x5), "+r"(x16), [f] "=r"(failed)
                     :
                     : "memory", "cc");
    *error = failed ? (int)x0 : 0;
    return failed ? -1 : (long)x0;
}

static void yc_copy_bytes(void *to, const void *from, yc_size_t n)
{
    unsigned char *d = to;
    const unsigned char *s = from;
    for (yc_size_t i = 0; i < n; i++)
        d[i] = s[i];
}

/* The kernel's copy-out: 0 or an errno. */
static int yc_copy_out(const void *bytes, yc_size_t len, void *old, yc_size_t *oldlenp)
{
    if (old == YC_NULL) {
        if (oldlenp != YC_NULL)
            *oldlenp = len;
        return 0;
    }
    if (oldlenp == YC_NULL)
        return YC_EINVAL;
    if (*oldlenp < len)
        return YC_ENOMEM;
    yc_copy_bytes(old, bytes, len);
    *oldlenp = len;
    return 0;
}

#define YC_OID_SLOTS 256
#define YC_OID_NAME 96
#define YC_OID_MIB 12
struct yc_oid_slot {
    yc_u32 state; /* 0 empty, 1 being written, 2 ready */
    yc_u32 namelen;
    yc_u32 miblen; /* bytes */
    int mib[YC_OID_MIB];
    char name[YC_OID_NAME];
};
static struct yc_oid_slot yc_oids[YC_OID_SLOTS];
static yc_u32 yc_boottime_state;
static yc_u32 yc_boottime_len;
static unsigned char yc_boottime[32];

static yc_u32 yc_name_hash(const char *s, yc_u32 n)
{
    yc_u32 h = 2166136261u;
    for (yc_u32 i = 0; i < n; i++)
        h = (h ^ (unsigned char)s[i]) * 16777619u;
    return h;
}

static int yc_same(const char *a, const char *b, yc_u32 n)
{
    for (yc_u32 i = 0; i < n; i++)
        if (a[i] != b[i])
            return 0;
    return 1;
}

/* The slot of `name` (ready), or NULL. */
static struct yc_oid_slot *yc_oid_find(const char *name, yc_u32 n)
{
    yc_u32 h = yc_name_hash(name, n);
    for (yc_u32 probe = 0; probe < 8; probe++) {
        struct yc_oid_slot *s = &yc_oids[(h + probe) % YC_OID_SLOTS];
        yc_u32 state = __atomic_load_n(&s->state, __ATOMIC_ACQUIRE);
        if (state == 0)
            return YC_NULL;
        if (state == 2 && s->namelen == n && yc_same(s->name, name, n))
            return s;
    }
    return YC_NULL;
}

static void yc_oid_insert(const char *name, yc_u32 n, const void *mib, yc_u32 miblen)
{
    if (miblen > sizeof(int) * YC_OID_MIB)
        return;
    yc_u32 h = yc_name_hash(name, n);
    for (yc_u32 probe = 0; probe < 8; probe++) {
        struct yc_oid_slot *s = &yc_oids[(h + probe) % YC_OID_SLOTS];
        yc_u32 empty = 0;
        if (!__atomic_compare_exchange_n(&s->state, &empty, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
            if (empty == 2 && s->namelen == n && yc_same(s->name, name, n))
                return; /* another thread kept it */
            continue;
        }
        s->namelen = n;
        s->miblen = miblen;
        yc_copy_bytes(s->name, name, n);
        yc_copy_bytes(s->mib, mib, miblen);
        __atomic_store_n(&s->state, 2, __ATOMIC_RELEASE);
        return;
    }
}

int __sysctl(int *name, yc_u32 namelen, void *old, yc_size_t *oldlenp, void *new, yc_size_t newlen);

YC_EXPORT int __sysctl(int *name, yc_u32 namelen, void *old, yc_size_t *oldlenp, void *new, yc_size_t newlen)
{
    int cache = (yc_commpage_u8(YC_COMM_FAST_FLAGS) & YC_FAST_SYSCTL_CACHE) != 0;
    int oid_query = 0, boottime = 0;
    yc_u32 n = 0;
    if (cache && namelen == 2 && name != YC_NULL) {
        if (name[0] == 0 && name[1] == 3 && new != YC_NULL && newlen > 0 && newlen <= YC_OID_NAME) {
            /* The kernel's key: the name bytes without trailing NULs. */
            n = (yc_u32)newlen;
            while (n > 0 && ((const char *)new)[n - 1] == 0)
                n--;
            oid_query = 1;
            struct yc_oid_slot *s = yc_oid_find(new, n);
            if (s != YC_NULL) {
                int e = yc_copy_out(s->mib, s->miblen, old, oldlenp);
                if (e == 0)
                    return 0;
                __ycode_set_errno(e);
                return -1;
            }
        } else if (name[0] == 1 && name[1] == 21 && (new == YC_NULL || newlen == 0)) {
            boottime = 1;
            if (__atomic_load_n(&yc_boottime_state, __ATOMIC_ACQUIRE) == 2) {
                int e = yc_copy_out(yc_boottime, yc_boottime_len, old, oldlenp);
                if (e == 0)
                    return 0;
                __ycode_set_errno(e);
                return -1;
            }
        }
    }
    int error;
    long r = yc_sysctl_trap(name, namelen, old, oldlenp, new, newlen, &error);
    if (r < 0) {
        __ycode_set_errno(error);
        return -1;
    }
    if (oid_query && old != YC_NULL && oldlenp != YC_NULL)
        yc_oid_insert(new, n, old, (yc_u32)*oldlenp);
    if (boottime && old != YC_NULL && oldlenp != YC_NULL && *oldlenp <= sizeof yc_boottime) {
        yc_u32 empty = 0;
        if (__atomic_compare_exchange_n(&yc_boottime_state, &empty, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
            yc_boottime_len = (yc_u32)*oldlenp;
            yc_copy_bytes(yc_boottime, old, *oldlenp);
            __atomic_store_n(&yc_boottime_state, 2, __ATOMIC_RELEASE);
        }
    }
    return (int)r;
}

/* int issetugid(void): BSD 327, which never fails; Ycode's kernel answers 0. */
YC_EXPORT int issetugid(void)
{
    if (yc_commpage_u8(YC_COMM_FAST_FLAGS) & YC_FAST_LOCAL_CALLS)
        return 0;
    register yc_uintptr_t x0 __asm__("x0");
    register long x16 __asm__("x16") = 327;
    __asm__ volatile("svc #0x80" : "=r"(x0), "+r"(x16) : : "x1", "memory", "cc");
    return (int)x0;
}
