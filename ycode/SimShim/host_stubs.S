/*
 * Ycode host page (stage 3a): the EL0 launch trampoline, the 67 dyld_sim
 * helper stubs, the helpers table, and the reserved read-write data area.
 *
 * Contract: specs/simulator/stage3-contract.md section 5, and
 * specs/simulator/dyld-sim-handoff.md sections 2.3, 3.2 and 7.3.
 * This is original Ycode code, written from those specs and the public
 * Arm architecture and Apple arm64 calling-convention documentation.
 *
 * Linked at VA 0x3_1000_0000 (see build.sh). Layout (offsets from the base):
 *   +0x0000  .text            _ycode_launch, then the helper stubs
 *   +0x0F00  .text            ycode_ret_stub: a single `ret` (fixed offset;
 *                             dyld_all_image_infos.notification points here)
 *   +0x4000  .rodata.helpers  helpers table: version 18, slots 1..67
 *   +0x8000  .data            RW area (errno cell, startGlue cell, launch
 *                             block, dyld_all_image_infos, ...), zero-filled
 *                             through +0xFFFF
 *
 * Every helper stub follows Apple's arm64 calling convention. In particular
 * the variadic third argument of open/fcntl/ioctl is in the first stack slot
 * [sp], not in x2. Stubs use only x0-x17 as scratch, never touch the stack
 * (except the variadic load), and never write the callee-saved registers.
 *
 * Darwin trap convention: `svc #0x80`, number in x16. A BSD failure sets
 * the carry flag with x0 = errno. Mach traps are negative and return a
 * kern_return_t (or a port name / value) in x0 with no carry semantics.
 * Ycode-private traps use x16 = 0x7963_00NN ("yc").
 */

/* ---------------------------------------------------------------- */
/* Fixed offsets (contract section 5).                               */
/* ---------------------------------------------------------------- */

#define HELPERS_VERSION         18

/* Launch block word offsets (12 x u64 at +0x8040). */
#define LB_PREPARE_ENTRY        0
#define LB_ARGC                 8
#define LB_ARGV                 16
#define LB_ENVP                 24
#define LB_APPLE                32
#define LB_MAIN_MH              40
#define LB_SIM_MH               48
#define LB_SIM_SLIDE            56
#define LB_HELPERS              64
#define LB_START_GLUE_ADDR      72
#define LB_STACK_TOP            80
#define LB_RESERVED             88

/* Darwin values used by the pure stubs. */
#define AMFI_OUTPUT_FLAGS       0xFF    /* bits 0-7; bit 1 = honor DYLD_* path vars */
#define KERN_SUCCESS            0
#define KERN_NOT_SUPPORTED      46

/* BSD numbers (low 16 bits of x16; specs/simulator/data/bsd-syscalls.json). */
#define SYS_exit                1
#define SYS_write               4
#define SYS_open                5
#define SYS_close               6
#define SYS_getpid              20
#define SYS_ioctl               54
#define SYS_munmap              73
#define SYS_madvise             75
#define SYS_fcntl               92
#define SYS_pread               153
#define SYS_mmap                197
#define SYS_getattrlist         220
#define SYS_stat64              338
#define SYS_fstat64             339
#define SYS_getfsstat64         347
#define SYS_fsgetpath           427
#define SYS_getattrlistbulk     461
#define SYS_abort_with_payload  521

/* Mach trap numbers (negative; specs/simulator/data/mach-traps.json). */
#define MACH_absolute_time              -3
#define MACH_vm_allocate                -10
#define MACH_vm_deallocate              -12
#define MACH_vm_protect                 -14
#define MACH_port_allocate              -16
#define MACH_port_deallocate            -18
#define MACH_port_insert_right          -21
#define MACH_port_construct             -24
#define MACH_port_destruct              -25
#define MACH_thread_self                -27
#define MACH_task_self                  -28
#define MACH_msg                        -31
#define MACH_thread_switch              -61
#define MACH_timebase_info              -89

/* Ycode-private traps: x16 = 0x7963_0000 | low (contract section 5). */
#define YC_HI                   0x7963
#define YC_vlog                 0x0001
#define YC_realpath             0x0002
#define YC_getcwd               0x0003
#define YC_vm_copy              0x0004
#define YC_proc_regionfilename  0x0005
#define YC_task_info            0x0006
#define YC_thread_info          0x0007
#define YC_mach_msg_destroy     0x0008
#define YC_sysctlbyname         0x0009
#define YC_notify_image_list    0x0010
#define YC_notify_main_called   0x0011
#define YC_notify_before_inits  0x0012

/* ---------------------------------------------------------------- */
/* Stub macros.                                                      */
/* ---------------------------------------------------------------- */

.macro STUB name
        .balign 16
        .globl  \name
        .type   \name, %function
\name:
.endm

/* BSD forwarder, int/ssize_t result: carry -> errno cell, return -1. */
.macro BSD name, num
        STUB    \name
        mov     x16, #\num
        svc     #0x80
        b.cs    bsd_fail_minus1
        ret
.endm

/* BSD forwarder for a variadic helper: third argument from [sp] (64-bit). */
.macro BSD_VA3 name, num
        STUB    \name
        ldr     x2, [sp]
        mov     x16, #\num
        svc     #0x80
        b.cs    bsd_fail_minus1
        ret
.endm

/* Mach forwarder: x0 passes through unchanged. */
.macro MACH name, num
        STUB    \name
        mov     x16, #\num
        svc     #0x80
        ret
.endm

/* Ycode-private trap number into x16. */
.macro YCNUM low
        movz    x16, #\low
        movk    x16, #YC_HI, lsl #16
.endm

/* Private trap, BSD convention, int-like result (-1 on carry). */
.macro YC_INT name, low
        STUB    \name
        YCNUM   \low
        svc     #0x80
        b.cs    bsd_fail_minus1
        ret
.endm

/* Private trap, BSD convention, pointer result (NULL on carry). */
.macro YC_PTR name, low
        STUB    \name
        YCNUM   \low
        svc     #0x80
        b.cs    bsd_fail_null
        ret
.endm

/* Private trap, kern_return_t result: x0 passes through (no carry handling). */
.macro YC_KERN name, low
        STUB    \name
        YCNUM   \low
        svc     #0x80
        ret
.endm

/* Private trap, void result. */
.macro YC_VOID name, low
        STUB    \name
        YCNUM   \low
        svc     #0x80
        ret
.endm

/* Pure stub that returns a small constant. */
.macro RETURN_CONST name, value
        STUB    \name
        mov     x0, #\value
        ret
.endm

/* ================================================================ */
/* Code: +0x0000                                                     */
/* ================================================================ */

        .section .text.start, "ax"

/*
 * _ycode_launch: the EL0 entry (boot-info PC = 0x3_1000_0000).
 * x19 = launch block, x20 = start_sim. Both are callee-saved, so they
 * survive the call into dyld_sim.
 */
        .globl  _ycode_launch
        .type   _ycode_launch, %function
_ycode_launch:
        adr     x19, ycode_launch_block

        /* 1. SP = (stackTop - 16) & ~15: 16-byte aligned and strictly below
         *    the kernel block, so [sp] (the 9th argument) never overlays the
         *    mach_header slot. [sp] = startGlueAddr. */
        ldr     x9, [x19, #LB_STACK_TOP]
        sub     x9, x9, #16
        and     sp, x9, #0xfffffffffffffff0
        mov     x29, xzr                        /* end of the frame chain */
        ldr     x9, [x19, #LB_START_GLUE_ADDR]
        str     x9, [sp]

        /* 2. _dyld_sim_prepare(argc, argv, envp, apple, mainMH, simMH,
         *    simSlide, helpers, &startGlue). */
        ldp     x0, x1, [x19, #LB_ARGC]         /* argc, argv */
        ldp     x2, x3, [x19, #LB_ENVP]         /* envp, apple */
        ldp     x4, x5, [x19, #LB_MAIN_MH]      /* mainMH, simMH */
        ldp     x6, x7, [x19, #LB_SIM_SLIDE]    /* simSlide, helpers */
        ldr     x9, [x19, #LB_PREPARE_ENTRY]
        blr     x9

        /* 3. start_sim(argc, argv, envp, apple). argc is re-read from
         *    argv[-1], because dyld_sim may have rewritten the block. */
        mov     x20, x0
        ldp     x1, x2, [x19, #LB_ARGV]         /* argv, envp */
        ldr     x3, [x19, #LB_APPLE]
        ldr     x0, [x1, #-8]                   /* argc = argv[-1] */
        blr     x20

        /* 4. If start_sim returns: BSD exit(x0). */
        mov     x16, #SYS_exit
        svc     #0x80
        brk     #0x1                            /* exit never returns */

/* ---------------------------------------------------------------- */
/* Shared failure tails for the BSD-convention stubs.                */
/* In: x0 = errno (carry was set).                                   */
/* ---------------------------------------------------------------- */

        .balign 16
bsd_fail_minus1:
        adr     x9, ycode_errno
        str     w0, [x9]
        mov     x0, #-1
        ret

        .balign 16
bsd_fail_null:
        adr     x9, ycode_errno
        str     w0, [x9]
        mov     x0, #0
        ret

/* ---------------------------------------------------------------- */
/* Helper stubs, in slot order (dyld-sim-handoff.md section 3.2).    */
/* ---------------------------------------------------------------- */

/* 1  open(path, oflag, ...mode): the mode (an int) comes from [sp]. */
        STUB    ycode_h_open
        ldr     w2, [sp]
        mov     x16, #SYS_open
        svc     #0x80
        b.cs    bsd_fail_minus1
        ret

        BSD     ycode_h_close,          SYS_close               /* 2 */
        BSD     ycode_h_pread,          SYS_pread               /* 3 */
        BSD     ycode_h_write,          SYS_write               /* 4 */
        BSD     ycode_h_mmap,           SYS_mmap                /* 5: MAP_FAILED (-1) on error */
        BSD     ycode_h_munmap,         SYS_munmap              /* 6 */
        BSD     ycode_h_madvise,        SYS_madvise             /* 7 */
        BSD     ycode_h_stat,           SYS_stat64              /* 8 */
        BSD_VA3 ycode_h_fcntl,          SYS_fcntl               /* 9 */
        BSD_VA3 ycode_h_ioctl,          SYS_ioctl               /* 10 */
        RETURN_CONST ycode_h_issetugid, 0                       /* 11 */
        YC_PTR  ycode_h_getcwd,         YC_getcwd               /* 12 */
        YC_PTR  ycode_h_realpath,       YC_realpath             /* 13 */
        MACH    ycode_h_vm_allocate,    MACH_vm_allocate        /* 14 */
        MACH    ycode_h_vm_deallocate,  MACH_vm_deallocate      /* 15 */
        MACH    ycode_h_vm_protect,     MACH_vm_protect         /* 16 */
        YC_VOID ycode_h_vlog,           YC_vlog                 /* 17 */
        YC_VOID ycode_h_vwarn,          YC_vlog                 /* 18 */
        RETURN_CONST ycode_h_pthread_mutex_lock, 0              /* 19 */
        RETURN_CONST ycode_h_pthread_mutex_unlock, 0            /* 20 */
        MACH    ycode_h_mach_thread_self, MACH_thread_self      /* 21 */
        MACH    ycode_h_mach_port_deallocate, MACH_port_deallocate /* 22 */
        MACH    ycode_h_task_self_trap, MACH_task_self          /* 23 */
        MACH    ycode_h_mach_timebase_info, MACH_timebase_info  /* 24 */

/* 25 OSAtomicCompareAndSwapPtrBarrier(old, new, ptr) -> bool. */
        STUB    ycode_h_cas_ptr_barrier
        dmb     ish
1:      ldaxr   x9, [x2]
        cmp     x9, x0
        b.ne    2f
        stlxr   w10, x1, [x2]
        cbnz    w10, 1b
        dmb     ish
        mov     x0, #1
        ret
2:      clrex
        dmb     ish
        mov     x0, #0
        ret

/* 26 OSMemoryBarrier(). */
        STUB    ycode_h_memory_barrier
        dmb     ish
        ret

/* 27 getProcessInfo() -> &dyld_all_image_infos. */
        STUB    ycode_h_get_process_info
        adr     x0, ycode_all_image_infos
        ret

/* 28 errnoAddress() -> &errno cell. */
        STUB    ycode_h_errno_address
        adr     x0, ycode_errno
        ret

        MACH    ycode_h_mach_absolute_time, MACH_absolute_time  /* 29 */
        MACH    ycode_h_thread_switch,  MACH_thread_switch      /* 30 */
        RETURN_CONST ycode_h_opendir,   0                       /* 31: NULL */
        /* 32 readdir_r, 33 closedir: NULL slots in the table. */
        STUB    ycode_h_coresymbolication_load_notifier         /* 34 */
        ret
        STUB    ycode_h_coresymbolication_unload_notifier       /* 35 */
        ret
        YC_INT  ycode_h_proc_regionfilename, YC_proc_regionfilename /* 36 */
        BSD     ycode_h_getpid,         SYS_getpid              /* 37 */
        MACH    ycode_h_mach_port_insert_right, MACH_port_insert_right /* 38 */
        MACH    ycode_h_mach_port_allocate, MACH_port_allocate  /* 39 */
        MACH    ycode_h_mach_msg,       MACH_msg                /* 40 */
        BSD     ycode_h_abort_with_payload, SYS_abort_with_payload /* 41 */
        RETURN_CONST ycode_h_task_register_dyld_image_infos, KERN_SUCCESS          /* 42 */
        RETURN_CONST ycode_h_task_unregister_dyld_image_infos, KERN_SUCCESS        /* 43 */
        RETURN_CONST ycode_h_task_get_dyld_image_infos, KERN_NOT_SUPPORTED         /* 44 */
        RETURN_CONST ycode_h_task_register_dyld_shared_cache_image_info, KERN_SUCCESS /* 45 */
        RETURN_CONST ycode_h_task_register_dyld_set_dyld_state, KERN_SUCCESS       /* 46 */
        RETURN_CONST ycode_h_task_register_dyld_get_process_state, KERN_NOT_SUPPORTED /* 47 */
        YC_KERN ycode_h_task_info,      YC_task_info            /* 48 */
        YC_KERN ycode_h_thread_info,    YC_thread_info          /* 49 */
        RETURN_CONST ycode_h_kdebug_is_enabled, 0               /* 50 */
        RETURN_CONST ycode_h_kdebug_trace, 0                    /* 51 */
        RETURN_CONST ycode_h_kdebug_trace_string, 0             /* 52 */

/* 53 amfi_check_dyld_policy_self(in_flags, out_flags*) -> 0, *out = 0xFF. */
        STUB    ycode_h_amfi_check_dyld_policy_self
        cbz     x1, 1f
        mov     x9, #AMFI_OUTPUT_FLAGS
        str     x9, [x1]
1:      mov     x0, #0
        ret

        YC_VOID ycode_h_notify_main_called, YC_notify_main_called   /* 54 */
        YC_VOID ycode_h_notify_image_list, YC_notify_image_list     /* 55 */
        YC_VOID ycode_h_mach_msg_destroy, YC_mach_msg_destroy       /* 56 */
        MACH    ycode_h_mach_port_construct, MACH_port_construct    /* 57 */
        MACH    ycode_h_mach_port_destruct, MACH_port_destruct      /* 58 */
        BSD     ycode_h_fstat,          SYS_fstat64             /* 59 */
        YC_KERN ycode_h_vm_copy,        YC_vm_copy              /* 60 */
        RETURN_CONST ycode_h_task_dyld_process_info_notify_get, KERN_NOT_SUPPORTED /* 61 */
        BSD     ycode_h_fsgetpath,      SYS_fsgetpath           /* 62 */
        BSD     ycode_h_getattrlistbulk, SYS_getattrlistbulk    /* 63 */
        BSD     ycode_h_getattrlist,    SYS_getattrlist         /* 64 */
        BSD     ycode_h_getfsstat,      SYS_getfsstat64         /* 65 */
        YC_VOID ycode_h_notify_before_inits, YC_notify_before_inits /* 66 */
        YC_INT  ycode_h_sysctlbyname,   YC_sysctlbyname         /* 67 */

/*
 * The `ret` stub at the fixed offset +0x0F00. dyld_all_image_infos.
 * notification points here. The assembler fails if the code above has
 * grown past this offset.
 */
        .org    0x0F00
        .globl  ycode_ret_stub
        .type   ycode_ret_stub, %function
ycode_ret_stub:
        ret
        .globl  ycode_code_end
ycode_code_end:

/* ================================================================ */
/* Helpers table: +0x4000 (read-only)                                */
/* ================================================================ */

        .section .rodata.helpers, "a"
        .balign 8
        .globl  ycode_helpers
ycode_helpers:
        .quad   HELPERS_VERSION                         /*  0 version  0x000 */
        .quad   ycode_h_open                            /*  1          0x008 */
        .quad   ycode_h_close                           /*  2          0x010 */
        .quad   ycode_h_pread                           /*  3          0x018 */
        .quad   ycode_h_write                           /*  4          0x020 */
        .quad   ycode_h_mmap                            /*  5          0x028 */
        .quad   ycode_h_munmap                          /*  6          0x030 */
        .quad   ycode_h_madvise                         /*  7          0x038 */
        .quad   ycode_h_stat                            /*  8          0x040 */
        .quad   ycode_h_fcntl                           /*  9          0x048 */
        .quad   ycode_h_ioctl                           /* 10          0x050 */
        .quad   ycode_h_issetugid                       /* 11          0x058 */
        .quad   ycode_h_getcwd                          /* 12          0x060 */
        .quad   ycode_h_realpath                        /* 13          0x068 */
        .quad   ycode_h_vm_allocate                     /* 14          0x070 */
        .quad   ycode_h_vm_deallocate                   /* 15          0x078 */
        .quad   ycode_h_vm_protect                      /* 16          0x080 */
        .quad   ycode_h_vlog                            /* 17 vlog     0x088 */
        .quad   ycode_h_vwarn                           /* 18 vwarn    0x090 */
        .quad   ycode_h_pthread_mutex_lock              /* 19          0x098 */
        .quad   ycode_h_pthread_mutex_unlock            /* 20   0x0A0 */
        .quad   ycode_h_mach_thread_self                /* 21          0x0A8 */
        .quad   ycode_h_mach_port_deallocate            /* 22          0x0B0 */
        .quad   ycode_h_task_self_trap                  /* 23          0x0B8 */
        .quad   ycode_h_mach_timebase_info              /* 24          0x0C0 */
        .quad   ycode_h_cas_ptr_barrier                 /* 25          0x0C8 */
        .quad   ycode_h_memory_barrier                  /* 26          0x0D0 */
        .quad   ycode_h_get_process_info                /* 27          0x0D8 */
        .quad   ycode_h_errno_address                   /* 28          0x0E0 */
        .quad   ycode_h_mach_absolute_time              /* 29          0x0E8 */
        .quad   ycode_h_thread_switch                   /* 30          0x0F0 */
        .quad   ycode_h_opendir                         /* 31          0x0F8 */
        .quad   0                                       /* 32 readdir_r 0x100 */
        .quad   0                                       /* 33 closedir 0x108 */
        .quad   ycode_h_coresymbolication_load_notifier /* 34 cs load  0x110 */
        .quad   ycode_h_coresymbolication_unload_notifier /* 35 cs unload 0x118 */
        .quad   ycode_h_proc_regionfilename             /* 36          0x120 */
        .quad   ycode_h_getpid                          /* 37          0x128 */
        .quad   ycode_h_mach_port_insert_right          /* 38          0x130 */
        .quad   ycode_h_mach_port_allocate              /* 39          0x138 */
        .quad   ycode_h_mach_msg                        /* 40          0x140 */
        .quad   ycode_h_abort_with_payload              /* 41          0x148 */
        .quad   ycode_h_task_register_dyld_image_infos  /* 42 register 0x150 */
        .quad   ycode_h_task_unregister_dyld_image_infos /* 43 unregister 0x158 */
        .quad   ycode_h_task_get_dyld_image_infos       /* 44 get infos 0x160 */
        .quad   ycode_h_task_register_dyld_shared_cache_image_info /* 45 reg cache 0x168 */
        .quad   ycode_h_task_register_dyld_set_dyld_state /* 46 set state 0x170 */
        .quad   ycode_h_task_register_dyld_get_process_state /* 47 get state 0x178 */
        .quad   ycode_h_task_info                       /* 48          0x180 */
        .quad   ycode_h_thread_info                     /* 49          0x188 */
        .quad   ycode_h_kdebug_is_enabled               /* 50 kdebug_is_enabled 0x190 */
        .quad   ycode_h_kdebug_trace                    /* 51 kdebug_trace 0x198 */
        .quad   ycode_h_kdebug_trace_string             /* 52 kdebug_trace_string 0x1A0 */
        .quad   ycode_h_amfi_check_dyld_policy_self     /* 53          0x1A8 */
        .quad   ycode_h_notify_main_called              /* 54          0x1B0 */
        .quad   ycode_h_notify_image_list               /* 55          0x1B8 */
        .quad   ycode_h_mach_msg_destroy                /* 56          0x1C0 */
        .quad   ycode_h_mach_port_construct             /* 57          0x1C8 */
        .quad   ycode_h_mach_port_destruct              /* 58          0x1D0 */
        .quad   ycode_h_fstat                           /* 59          0x1D8 */
        .quad   ycode_h_vm_copy                         /* 60          0x1E0 */
        .quad   ycode_h_task_dyld_process_info_notify_get /* 61 notify_get 0x1E8 */
        .quad   ycode_h_fsgetpath                       /* 62          0x1F0 */
        .quad   ycode_h_getattrlistbulk                 /* 63          0x1F8 */
        .quad   ycode_h_getattrlist                     /* 64          0x200 */
        .quad   ycode_h_getfsstat                       /* 65          0x208 */
        .quad   ycode_h_notify_before_inits             /* 66          0x210 */
        .quad   ycode_h_sysctlbyname                    /* 67          0x218 */
        .globl  ycode_helpers_end
ycode_helpers_end:
        .if (ycode_helpers_end - ycode_helpers) != 544
        .error "helpers table is not 544 bytes"
        .endif

/* ================================================================ */
/* Read-write data: +0x8000 .. +0xFFFF (zero-filled; VMM writes it)  */
/* ================================================================ */

        .section .data.host, "aw"
        .balign 8
        .globl  ycode_rw_base
ycode_rw_base:
        .globl  ycode_errno
ycode_errno:                                    /* +0x8000 errno (int, 8-byte slot) */
        .quad   0
        .globl  ycode_start_glue
ycode_start_glue:                               /* +0x8008 startGlue cell */
        .quad   0
        .org    0x40
        .globl  ycode_launch_block
ycode_launch_block:                             /* +0x8040 launch block, 12 x u64 */
        .fill   12, 8, 0
        .org    0x100
        .globl  ycode_all_image_infos
ycode_all_image_infos:                          /* +0x8100 dyld_all_image_infos (368) */
        .fill   368, 1, 0
        .org    0x300
        .globl  ycode_image_storage
ycode_image_storage:                            /* +0x8300 infoArray, uuidArray, paths (2 KiB) */
        .fill   2048, 1, 0
        .org    0x1000
        .globl  ycode_scratch
ycode_scratch:                                  /* +0x9000 sysctlbyname / scratch (4 KiB) */
        .fill   4096, 1, 0
        .org    0x8000                          /* the binary ends at +0x10000 */
        .globl  ycode_host_page_end
ycode_host_page_end:
