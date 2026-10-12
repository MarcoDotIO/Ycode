/*
 * chkstk.S - the stack probe of Ycode's libsystem_pthread
 * (____chkstk_darwin, also exported as thread_chkstk_darwin).
 *
 * Clean-room Ycode code, from host-library-init.md section 5.1:
 *   - the frame size is in x9; x10 and x11 are preserved (saved below SP
 *     without moving SP); only x9 and the flags are clobbered;
 *   - if SP lies within [stackbottom, stackaddr] of the current thread
 *     (TSD base - 40 and - 48) and SP - size falls below stackbottom, it
 *     faults on purpose in the guard page below the stack;
 *   - otherwise it touches every 4 KiB page from SP down to SP - size, in
 *     order, so that the guard page is hit before anything below it.
 * A TSD base of 0 (no thread block) skips the bounds check.
 */
    .section __TEXT,__text,regular,pure_instructions
    .globl ____chkstk_darwin
    .globl _thread_chkstk_darwin
    .p2align 2
____chkstk_darwin:
_thread_chkstk_darwin:
    stp     x10, x11, [sp, #-16]
    mrs     x10, tpidrro_el0
    cbz     x10, Lprobe
    ldr     x11, [x10, #-48]        /* stackaddr (top) */
    ldr     x10, [x10, #-40]        /* stackbottom */
    cmp     sp, x11
    b.hi    Lprobe                  /* SP above this thread's stack */
    cmp     sp, x10
    b.lo    Lprobe                  /* SP below it (another stack) */
    mov     x11, sp
    subs    x11, x11, x9
    b.lo    Loverflow               /* wrapped around */
    cmp     x11, x10
    b.lo    Loverflow
Lprobe:
    mov     x10, sp
    mov     x11, x9
Lloop:
    cmp     x11, #0x1000
    b.lo    Llast
    sub     x10, x10, #0x1000
    ldr     xzr, [x10]
    sub     x11, x11, #0x1000
    b       Lloop
Llast:
    sub     x10, x10, x11
    ldr     xzr, [x10]
    ldp     x10, x11, [sp, #-16]
    ret
Loverflow:
    /* Fault in the guard page directly below stackbottom. */
    sub     x10, x10, #0x1000
    ldr     xzr, [x10]
    brk     #0x7964
