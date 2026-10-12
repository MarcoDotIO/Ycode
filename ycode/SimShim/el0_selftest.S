/*
 * Ycode stage-2 EL0 self-test.
 *
 * Contract: specs/simulator/vm-shim-protocol.md section 7. Darwin trap
 * convention: specs/simulator/darwin-arm64-abi.md (number in x16,
 * svc #0x80, BSD errors signalled by carry set).
 * This is original Ycode code.
 *
 * Linked at VA 0x1_0000_0000. The text page (first 16 KiB) is EL0 RX; the
 * data section starts at 0x1_0000_4000 (EL0 RW) with the magic first.
 *
 * In: x0 = expected TPIDRRO_EL0 value, x1 = expected PID.
 * The test does not use the stack.
 */

#define SYS_EXIT        1
#define SYS_WRITE       4
#define SYS_GETPID      20
#define SYS_UNKNOWN     9999
#define ENOSYS          78

/* 0x5943_4F44_4531_3645 */
#define MAGIC_0         0x3645
#define MAGIC_1         0x4531
#define MAGIC_2         0x4F44
#define MAGIC_3         0x5943

        .section .text.start, "ax"
        .globl  _start
_start:
        mov     x19, x0                         /* expected tpidrro */
        mov     x20, x1                         /* expected pid */

        /* 1. TPIDRRO_EL0 was set by the shim. */
        mrs     x2, tpidrro_el0
        cmp     x2, x19
        b.ne    fail_10

        /* 2. getpid: carry clear, x0 == expected pid. */
        mov     x16, #SYS_GETPID
        svc     #0x80
        b.cs    fail_11
        cmp     x0, x20
        b.ne    fail_12

        /* 3. mach_absolute_time (-3) twice: both nonzero, second >= first. */
        mov     x16, #-3
        svc     #0x80
        mov     x21, x0
        mov     x16, #-3
        svc     #0x80
        mov     x22, x0
        cbz     x21, fail_13
        cbz     x22, fail_13
        cmp     x22, x21
        b.lo    fail_13                         /* unsigned: second < first */

        /* 4. Unknown BSD call: carry set, x0 == ENOSYS. */
        mov     x16, #SYS_UNKNOWN
        svc     #0x80
        b.cc    fail_14
        cmp     x0, #ENOSYS
        b.ne    fail_14

        /* 5. write(1, hello, len): carry clear, x0 == len. */
        mov     x0, #1
        adr     x1, hello
        mov     x2, #(hello_end - hello)
        mov     x16, #SYS_WRITE
        svc     #0x80
        b.cs    fail_15
        cmp     x0, #(hello_end - hello)
        b.ne    fail_15

        /* 6. The magic at the start of the data page. */
        adr     x1, data_magic
        ldr     x2, [x1]
        movz    x3, #MAGIC_0
        movk    x3, #MAGIC_1, lsl #16
        movk    x3, #MAGIC_2, lsl #32
        movk    x3, #MAGIC_3, lsl #48
        cmp     x2, x3
        b.ne    fail_16

        /* 7. exit(0). */
        mov     x0, #0
        b       do_exit

fail_10: mov    x0, #10
        b       do_exit
fail_11: mov    x0, #11
        b       do_exit
fail_12: mov    x0, #12
        b       do_exit
fail_13: mov    x0, #13
        b       do_exit
fail_14: mov    x0, #14
        b       do_exit
fail_15: mov    x0, #15
        b       do_exit
fail_16: mov    x0, #16

do_exit:
        mov     x16, #SYS_EXIT
        svc     #0x80
        /* exit does not return. If it does, fault so the VMM sees a kind-2 trap. */
        brk     #0xdead
        b       .

        .section .rodata, "a"
hello:
        .ascii  "hello from EL0 (Darwin ABI on KVM)\n"
hello_end:

        .data
        .balign 16384
        .globl  data_magic
data_magic:
        .quad   0x59434F4445313645
