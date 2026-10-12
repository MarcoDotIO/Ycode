/*
 * entry.S - the two thread entry points that Ycode's libsystem_pthread
 * registers with the kernel (bsdthread_register, host-library-init.md
 * section 6.1).
 *
 * Clean-room Ycode code, from threads-and-events.md sections 1.1 and 2.6
 * and host-library-init.md sections 6.2-6.3:
 *
 *   thread_start    entered by a thread made with bsdthread_create:
 *                   x0 = pthread, x1 = port, x2 = func, x3 = arg,
 *                   x4 = stack, x5 = flags, sp = stack.
 *   start_wqthread  entered by a workqueue thread for every piece of work:
 *                   x0 = self, x1 = port, x2 = stack bottom, x3 = event
 *                   list or 0, x4 = upcall flags, x5 = event count or -1.
 *
 * Both push a zero frame record (the end of the frame chain for
 * backtracers), call the C routine with x0-x5 unchanged, and never return:
 * the C routines leave through the kernel. A return would hit the brk.
 */
    .section __TEXT,__text,regular,pure_instructions

    .globl _thread_start
    .p2align 2
_thread_start:
    stp     xzr, xzr, [sp, #-16]!
    mov     x29, sp
    bl      __pthread_start
    brk     #1

    .globl _start_wqthread
    .p2align 2
_start_wqthread:
    stp     xzr, xzr, [sp, #-16]!
    mov     x29, sp
    bl      __pthread_wqthread
    brk     #1
