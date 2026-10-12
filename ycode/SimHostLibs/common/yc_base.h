/*
 * yc_base.h - freestanding base definitions shared by Ycode's host libraries
 * (libsystem_kernel, libsystem_platform, libsystem_pthread).
 *
 * Clean-room Ycode code. Contract: specs/simulator/host-libraries.md.
 * No SDK headers are used: every type the libraries need is declared here
 * with Ycode-private names (yc_*), so these files also compile on a Linux or
 * macOS host for the unit tests (YC_HOST_TEST).
 */
#ifndef YC_BASE_H
#define YC_BASE_H

typedef __SIZE_TYPE__ yc_size_t;
typedef __PTRDIFF_TYPE__ yc_ssize_t;
typedef __UINTPTR_TYPE__ yc_uintptr_t;
typedef __INTPTR_TYPE__ yc_intptr_t;
typedef __UINT8_TYPE__ yc_u8;
typedef __UINT16_TYPE__ yc_u16;
typedef __UINT32_TYPE__ yc_u32;
typedef __UINT64_TYPE__ yc_u64;
typedef __INT32_TYPE__ yc_i32;
typedef __INT64_TYPE__ yc_i64;
typedef _Bool yc_bool;

#define YC_NULL ((void *)0)

/* Visibility. Everything is hidden by default (-fvisibility=hidden);
 * surface symbols are marked YC_EXPORT. */
#define YC_EXPORT __attribute__((visibility("default")))
#define YC_HIDDEN __attribute__((visibility("hidden")))
#define YC_NOINLINE __attribute__((noinline))
#define YC_NORETURN __attribute__((noreturn))
#define YC_LIKELY(x) __builtin_expect(!!(x), 1)
#define YC_UNLIKELY(x) __builtin_expect(!!(x), 0)

/*
 * YC_FN(name) names an exported function. In the guest build it is the C
 * name itself (the Mach-O symbol gets the usual leading underscore). In the
 * host unit tests it gets a yc_test_ prefix, so the code under test never
 * collides with the host C library (memmove, setjmp, ffs, ...).
 */
#ifdef YC_HOST_TEST
#define YC_FN(name) yc_test_##name
#else
#define YC_FN(name) name
#endif

/* Darwin errno values (public <sys/errno.h> numbering). */
#define YC_EPERM 1
#define YC_ENOENT 2
#define YC_EINTR 4
#define YC_ENOMEM 12
#define YC_EFAULT 14
#define YC_EBUSY 16
#define YC_EINVAL 22
#define YC_ERANGE 34
#define YC_EAGAIN 35
#define YC_ENOTSUP 45
#define YC_ETIMEDOUT 60
#define YC_ENOSYS 78
#define YC_EOWNERDEAD 105

/* Mach return codes. */
#define YC_KERN_SUCCESS 0
#define YC_KERN_NOT_SUPPORTED 46

/* The Ycode-private "unimplemented library function" trap
 * (host-libraries.md section 4): svc #0x80 with x16 = 0x7963_0F00 and
 * x0 = the function's name. */
#define YC_TRAP_UNIMPLEMENTED 0x79630F00u

/* Darwin arm64 uses 16 KiB pages. */
#define YC_PAGE_SIZE 16384ul

/*
 * Errno hook. Every library contains one hidden copy (from
 * common/fallback/all/yc_errno_hook.c unless the library supplies its own).
 * The default stores through __error(), which libsystem_kernel exports.
 */
YC_HIDDEN void __ycode_set_errno(int value);
YC_HIDDEN long __ycode_stub_enosys(void);

/* Crash on a broken invariant (an API misuse the real library also
 * treats as fatal). brk #0x7964: distinct from the unimplemented trap. */
#if defined(__aarch64__) && !defined(YC_HOST_TEST)
#define YC_CRASH() do { __asm__ volatile("brk #0x7964"); __builtin_unreachable(); } while (0)
#else
#define YC_CRASH() __builtin_trap()
#endif

#endif /* YC_BASE_H */
