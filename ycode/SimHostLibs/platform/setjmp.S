/*
 * setjmp.S - setjmp, longjmp, _setjmp, _longjmp, sigsetjmp, siglongjmp of
 * Ycode's libsystem_platform (arm64).
 *
 * Clean-room Ycode code, from the C standard / POSIX semantics, the AAPCS64
 * callee-saved register set, and the public Darwin arm64 buffer sizes
 * (jmp_buf = 48 ints = 192 bytes, sigjmp_buf = 49 ints = 196 bytes).
 *
 * Buffer layout (Ycode's):
 *   0x00 x19 x20   0x10 x21 x22   0x20 x23 x24   0x30 x25 x26
 *   0x40 x27 x28   0x50 x29 (fp) x30 (lr)        0x60 sp   0x68 0
 *   0x70 d8 d9     0x80 d10 d11   0x90 d12 d13   0xa0 d14 d15
 *   0xb0 saved signal mask (sigset_t, 4 bytes)
 *   0xc0 sigjmp_buf only: the savemask flag of sigsetjmp (int)
 *
 * setjmp/longjmp save and restore the signal mask through libsystem_kernel's
 * sigprocmask; _setjmp/_longjmp do not touch it. sigsetjmp(env, savemask)
 * records savemask and behaves like setjmp (savemask != 0) or _setjmp;
 * siglongjmp follows the recorded choice. longjmp(env, 0) returns 1.
 */

#if defined(YC_HOST_TEST)
#  if defined(__APPLE__)
#    define SYM(n) _yc_test_##n
#    define KSYM(n) _yc_testk_##n
#  else
#    define SYM(n) yc_test_##n
#    define KSYM(n) yc_testk_##n
#  endif
#else
#  define SYM(n) _##n
#  define KSYM(n) _##n
#endif

#if defined(__APPLE__) || !defined(YC_HOST_TEST)
#  define TEXT .section __TEXT,__text,regular,pure_instructions
#  define FUNC(n) .globl SYM(n) %% .p2align 2 %% SYM(n):
#else
#  define TEXT .text
#  define FUNC(n) .globl SYM(n) ; .type SYM(n), %function ; .p2align 2 ; SYM(n):
#endif

#define JB_MASK 0xb0
#define JB_SAVEMASK 0xc0
#define SIG_BLOCK 1
#define SIG_SETMASK 3

        TEXT

/* int _setjmp(jmp_buf env) */
FUNC(_setjmp)
        stp     x19, x20, [x0, #0x00]
        stp     x21, x22, [x0, #0x10]
        stp     x23, x24, [x0, #0x20]
        stp     x25, x26, [x0, #0x30]
        stp     x27, x28, [x0, #0x40]
        stp     x29, x30, [x0, #0x50]
        mov     x1, sp
        stp     x1, xzr, [x0, #0x60]
        stp     d8, d9, [x0, #0x70]
        stp     d10, d11, [x0, #0x80]
        stp     d12, d13, [x0, #0x90]
        stp     d14, d15, [x0, #0xa0]
        mov     w0, #0
        ret

/* void _longjmp(jmp_buf env, int val) */
FUNC(_longjmp)
        ldp     x19, x20, [x0, #0x00]
        ldp     x21, x22, [x0, #0x10]
        ldp     x23, x24, [x0, #0x20]
        ldp     x25, x26, [x0, #0x30]
        ldp     x27, x28, [x0, #0x40]
        ldp     x29, x30, [x0, #0x50]
        ldr     x2, [x0, #0x60]
        mov     sp, x2
        ldp     d8, d9, [x0, #0x70]
        ldp     d10, d11, [x0, #0x80]
        ldp     d12, d13, [x0, #0x90]
        ldp     d14, d15, [x0, #0xa0]
        cmp     w1, #0
        csinc   w0, w1, wzr, ne
        ret

/* int setjmp(jmp_buf env) */
FUNC(setjmp)
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x0, [sp, #16]
        add     x2, x0, #JB_MASK                /* oset = &env->mask */
        mov     x1, #0                          /* set = NULL */
        mov     w0, #SIG_BLOCK
        bl      KSYM(sigprocmask)
        ldr     x0, [sp, #16]
        ldp     x29, x30, [sp], #32
        b       SYM(_setjmp)                    /* records the caller's x30 and sp */

/* void longjmp(jmp_buf env, int val) */
FUNC(longjmp)
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x0, x1, [sp, #16]
        add     x1, x0, #JB_MASK                /* set = &env->mask */
        mov     x2, #0                          /* oset = NULL */
        mov     w0, #SIG_SETMASK
        bl      KSYM(sigprocmask)
        ldp     x0, x1, [sp, #16]
        add     sp, sp, #32
        b       SYM(_longjmp)

/* int sigsetjmp(sigjmp_buf env, int savemask) */
FUNC(sigsetjmp)
        str     w1, [x0, #JB_SAVEMASK]
        cbz     w1, 1f
        b       SYM(setjmp)
1:      b       SYM(_setjmp)

/* void siglongjmp(sigjmp_buf env, int val) */
FUNC(siglongjmp)
        ldr     w2, [x0, #JB_SAVEMASK]
        cbz     w2, 1f
        b       SYM(longjmp)
1:      b       SYM(_longjmp)
