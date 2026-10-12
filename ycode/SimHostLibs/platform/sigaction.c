/*
 * sigaction.c - __platform_sigaction and the signal trampoline of Ycode's
 * libsystem_platform.
 *
 * Clean-room Ycode code. Contract: specs/simulator/threads-and-events.md
 * section 5.1 (BSD 46 takes a 24-byte struct __sigaction {handler @0,
 * sa_tramp @8, sa_mask u32 @16, sa_flags i32 @20} and returns the old
 * action as the 16-byte struct sigaction {handler @0, sa_mask @8,
 * sa_flags @12}), section 5.3 (registers at the trampoline: x0 handler,
 * x1 infostyle, x2 signo, x3 siginfo, x4 ucontext, x5 token, sp = frame)
 * and section 5.4 (BSD 184 sigreturn(uctx, infostyle, token)).
 *
 * int __platform_sigaction(int sig, const struct sigaction *nsv,
 *     struct sigaction *osv) is what libsystem_c's sigaction() and
 * signal() call (the platform surface lists libsystem_c as its importer).
 * It fills the kernel structure with the caller's handler, mask and flags
 * plus this library's trampoline, and calls libsystem_kernel's
 * __sigaction. Errors come back as -1 with errno set by that wrapper.
 * SA_VALIDATE_SIGRETURN_FROM_SIGTRAMP is not requested, so the kernel
 * does not check the sigreturn token (section 5.1).
 */
#include "yc_platform.h"

struct yc_user_sigaction { /* struct sigaction, 16 bytes */
    void *handler;
    yc_u32 mask;
    int flags;
};
_Static_assert(sizeof(struct yc_user_sigaction) == 16, "struct sigaction is 16 bytes");

struct yc_kernel_sigaction { /* struct __sigaction, 24 bytes */
    void *handler;
    void *tramp;
    yc_u32 mask;
    int flags;
};
_Static_assert(sizeof(struct yc_kernel_sigaction) == 24, "struct __sigaction is 24 bytes");

#if defined(YC_HOST_TEST) || !defined(__aarch64__)
/* The host tests only check that the address is passed through. */
YC_HIDDEN void yc_sigtramp(void)
{
}
#else
/* Calls handler(signo, siginfo, ucontext), then sigreturn(ucontext,
 * infostyle, token). Every register is restored by sigreturn from the
 * frame, so the trampoline may use callee-saved registers freely. If
 * sigreturn ever returns, the process traps (brk). */
YC_HIDDEN void yc_sigtramp(void);
__asm__(".section __TEXT,__text,regular,pure_instructions\n"
        ".private_extern _yc_sigtramp\n"
        ".p2align 2\n"
        "_yc_sigtramp:\n"
        "    mov x19, x4\n"   /* ucontext */
        "    mov x20, x1\n"   /* infostyle */
        "    mov x21, x5\n"   /* token */
        "    mov x16, x0\n"   /* handler */
        "    mov w0, w2\n"    /* signo */
        "    mov x1, x3\n"    /* siginfo */
        "    mov x2, x4\n"    /* ucontext */
        "    blr x16\n"
        "    mov x0, x19\n"
        "    mov w1, w20\n"
        "    mov x2, x21\n"
        "    mov x16, #184\n" /* sigreturn */
        "    svc #0x80\n"
        "    brk #0x7965\n");
#endif

YC_EXPORT int YC_FN(__platform_sigaction)(int sig, const struct yc_user_sigaction *nsv,
                                          struct yc_user_sigaction *osv)
{
    struct yc_kernel_sigaction ksa;
    struct yc_kernel_sigaction *kp = YC_NULL;
    if (nsv != YC_NULL) {
        ksa.handler = nsv->handler;
        ksa.tramp = (void *)yc_sigtramp;
        ksa.mask = nsv->mask;
        ksa.flags = nsv->flags;
        kp = &ksa;
    }
    return YC_KFN(__sigaction)(sig, kp, osv);
}
