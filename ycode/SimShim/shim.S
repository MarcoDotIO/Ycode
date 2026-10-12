/*
 * Ycode EL1 shim (stage 2, with the stage-3a additions).
 *
 * Contract: specs/simulator/vm-shim-protocol.md (sections 4 and 5) and
 * specs/simulator/stage3-contract.md section 7 (resumeFlags, CNTKCTL_EL1).
 * This is original Ycode code. It is written from that contract and from
 * the public Arm Architecture Reference Manual.
 *
 * The image is loaded at GPA 0x4000_0000 and its entry point is the first
 * byte. The code uses only PC-relative addressing (adr), so it does not
 * depend on the load address. It runs with the MMU off until step 7, and
 * after that through an identity map (VA = GPA).
 *
 * Register use outside the boot path:
 *   TPIDR_EL1 = address of the boot info block. The vector code reads the
 *               trap frame address (boot info +56) and the doorbell address
 *               (boot info +64) through it.
 *   SP_EL1    = the EL1 stack. A vector entry pushes the guest's x0 and x1
 *               (16 bytes) so that it has two scratch registers, then pops
 *               them before it saves them to the frame. SP_EL1 is the same
 *               at eret as it was at exception entry.
 */

/* Boot info offsets (contract section 4). */
#define BI_MAGIC        0
#define BI_TTBR0        8
#define BI_TCR          16
#define BI_MAIR         24
#define BI_SCTLR        32
#define BI_EL0_PC       40
#define BI_EL0_SP       48
#define BI_FRAME        56
#define BI_DOORBELL     64
#define BI_TPIDRRO      72
#define BI_TPIDR        80
#define BI_X0           88      /* x0..x7: 88..151 */
#define BI_STACK_TOP    152

/* Trap frame offsets (contract section 5). */
#define TF_X0           0       /* x0..x30: 0..247 */
#define TF_SP_EL0       248
#define TF_ELR          256
#define TF_SPSR         264
#define TF_ESR          272
#define TF_FAR          280
#define TF_TPIDRRO      288
#define TF_TPIDR        296
#define TF_KIND         304
#define TF_RESUME_FLAGS 312     /* stage 3a: bit 0 = flush the TLB on resume */

/* Frame kinds (contract section 5). */
#define KIND_CLASSIFY   0       /* internal: decide 1 or 2 from ESR_EL1.EC */
#define KIND_SVC        1
#define KIND_SYNC       2
#define KIND_ASYNC      3
#define KIND_EL1_SYNC   4
#define FATAL           0x100   /* internal: spin after the doorbell */
#define FATAL_BIT       8

#define EC_SVC64        0x15
#define SPSR_EL0T_DAIF  0x3C0
#define CPACR_FPEN_ALL  (3 << 20)
/* CNTKCTL_EL1: EL0VCTEN (bit 1) = 1, EL0PCTEN (bit 0) = 0, all else 0. */
#define CNTKCTL_EL0VCT  (1 << 1)
#define RESUME_FLUSH_TLB_BIT 0

/* "YCDBOOT1" read as a little-endian u64. */
#define BOOT_MAGIC_0    0x4359
#define BOOT_MAGIC_1    0x4244
#define BOOT_MAGIC_2    0x4F4F
#define BOOT_MAGIC_3    0x3154

/* ------------------------------------------------------------------ */
/* Entry point: the first byte of shim.bin.                            */
/* In: x0 = boot info address. EL1h, MMU off, DAIF masked.             */
/* ------------------------------------------------------------------ */

        .section .text.start, "ax"
        .globl  _start
_start:
        /* Step 1: validate the magic. */
        movz    x1, #BOOT_MAGIC_0
        movk    x1, #BOOT_MAGIC_1, lsl #16
        movk    x1, #BOOT_MAGIC_2, lsl #32
        movk    x1, #BOOT_MAGIC_3, lsl #48
        ldr     x2, [x0, #BI_MAGIC]
        cmp     x2, x1
        b.ne    .Lbad_magic

        /* Step 2: SP_EL1 (SPSel is 1 at EL1h). */
        ldr     x2, [x0, #BI_STACK_TOP]
        mov     sp, x2

        /* Step 3: translation registers. */
        ldr     x2, [x0, #BI_MAIR]
        msr     mair_el1, x2
        ldr     x2, [x0, #BI_TCR]
        msr     tcr_el1, x2
        ldr     x2, [x0, #BI_TTBR0]
        msr     ttbr0_el1, x2

        /* Step 4. */
        isb

        /* Step 5: FP/SIMD at EL0 and EL1 without traps. */
        mov     x2, #CPACR_FPEN_ALL
        msr     cpacr_el1, x2

        /* Stage 3a: EL0 may read CNTVCT_EL0 (not the physical counter). */
        mov     x2, #CNTKCTL_EL0VCT
        msr     cntkctl_el1, x2

        /* Step 6: drop stale TLB entries (and stale I-cache lines). */
        tlbi    vmalle1
        ic      iallu
        dsb     sy
        isb

        /* Step 7: enable the MMU and caches. */
        ldr     x2, [x0, #BI_SCTLR]
        msr     sctlr_el1, x2
        isb

        /* Step 8: vector table. */
        adr     x2, vectors
        msr     vbar_el1, x2

        /* Shim-private: the vectors find the frame and doorbell through this. */
        msr     tpidr_el1, x0
        isb

        /* Step 9: thread registers. */
        ldr     x2, [x0, #BI_TPIDRRO]
        msr     tpidrro_el0, x2
        ldr     x2, [x0, #BI_TPIDR]
        msr     tpidr_el0, x2

        /* Step 10: EL0 stack, entry and PSTATE. */
        ldr     x2, [x0, #BI_EL0_SP]
        msr     sp_el0, x2
        ldr     x2, [x0, #BI_EL0_PC]
        msr     elr_el1, x2
        mov     x2, #SPSR_EL0T_DAIF
        msr     spsr_el1, x2

        /* Step 11: x0..x7 from boot info, every other GPR zero. */
        mov     x8, x0
        ldp     x0, x1, [x8, #BI_X0 + 0]
        ldp     x2, x3, [x8, #BI_X0 + 16]
        ldp     x4, x5, [x8, #BI_X0 + 32]
        ldp     x6, x7, [x8, #BI_X0 + 48]
        mov     x8, xzr
        mov     x9, xzr
        mov     x10, xzr
        mov     x11, xzr
        mov     x12, xzr
        mov     x13, xzr
        mov     x14, xzr
        mov     x15, xzr
        mov     x16, xzr
        mov     x17, xzr
        mov     x18, xzr
        mov     x19, xzr
        mov     x20, xzr
        mov     x21, xzr
        mov     x22, xzr
        mov     x23, xzr
        mov     x24, xzr
        mov     x25, xzr
        mov     x26, xzr
        mov     x27, xzr
        mov     x28, xzr
        mov     x29, xzr
        mov     x30, xzr
        isb
        eret

.Lbad_magic:
        wfi
        b       .Lbad_magic

/* ------------------------------------------------------------------ */
/* Vector table: 16 entries of 0x80 bytes, 2 KiB aligned.               */
/* Each entry pushes the guest's x0/x1, puts a kind code in x1 and      */
/* branches to the common save path.                                    */
/* ------------------------------------------------------------------ */

        .text

.macro VENTRY code
        .balign 0x80
        stp     x0, x1, [sp, #-16]!
        mov     x1, #(\code)
        b       trap_common
.endm

        .balign 2048
        .globl  vectors
vectors:
        /* 0x000-0x180: current EL with SP_EL0. The shim never runs on SP_EL0. */
        VENTRY  KIND_EL1_SYNC | FATAL           /* 0x000 synchronous */
        VENTRY  KIND_ASYNC | FATAL              /* 0x080 IRQ */
        VENTRY  KIND_ASYNC | FATAL              /* 0x100 FIQ */
        VENTRY  KIND_ASYNC | FATAL              /* 0x180 SError */
        /* 0x200-0x380: current EL with SP_ELx. */
        VENTRY  KIND_EL1_SYNC | FATAL           /* 0x200 synchronous */
        VENTRY  KIND_ASYNC | FATAL              /* 0x280 IRQ */
        VENTRY  KIND_ASYNC | FATAL              /* 0x300 FIQ */
        VENTRY  KIND_ASYNC | FATAL              /* 0x380 SError */
        /* 0x400-0x580: lower EL, AArch64. */
        VENTRY  KIND_CLASSIFY                   /* 0x400 synchronous */
        VENTRY  KIND_ASYNC                      /* 0x480 IRQ */
        VENTRY  KIND_ASYNC                      /* 0x500 FIQ */
        VENTRY  KIND_ASYNC                      /* 0x580 SError */
        /* 0x600-0x780: lower EL, AArch32. Unused (EL0 is AArch64 only). */
        VENTRY  KIND_CLASSIFY                   /* 0x600 synchronous */
        VENTRY  KIND_ASYNC                      /* 0x680 IRQ */
        VENTRY  KIND_ASYNC                      /* 0x700 FIQ */
        VENTRY  KIND_ASYNC                      /* 0x780 SError */
        .balign 0x80                            /* table ends at vectors + 0x800 */

/* ------------------------------------------------------------------ */
/* Common path.                                                         */
/* In: [sp] = guest x0, [sp+8] = guest x1, x1 = kind code.              */
/* Every other GPR still holds its guest value.                         */
/* ------------------------------------------------------------------ */

        .globl  trap_common
trap_common:
        mrs     x0, tpidr_el1
        ldr     x0, [x0, #BI_FRAME]             /* x0 = frame */

        /* x2..x30 first, while they still hold guest values. */
        stp     x2, x3, [x0, #TF_X0 + 16]
        stp     x4, x5, [x0, #TF_X0 + 32]
        stp     x6, x7, [x0, #TF_X0 + 48]
        stp     x8, x9, [x0, #TF_X0 + 64]
        stp     x10, x11, [x0, #TF_X0 + 80]
        stp     x12, x13, [x0, #TF_X0 + 96]
        stp     x14, x15, [x0, #TF_X0 + 112]
        stp     x16, x17, [x0, #TF_X0 + 128]
        stp     x18, x19, [x0, #TF_X0 + 144]
        stp     x20, x21, [x0, #TF_X0 + 160]
        stp     x22, x23, [x0, #TF_X0 + 176]
        stp     x24, x25, [x0, #TF_X0 + 192]
        stp     x26, x27, [x0, #TF_X0 + 208]
        stp     x28, x29, [x0, #TF_X0 + 224]
        str     x30, [x0, #TF_X0 + 240]

        /* Guest x0/x1 from the stack. SP_EL1 is back to its entry value. */
        ldp     x2, x3, [sp], #16
        stp     x2, x3, [x0, #TF_X0 + 0]

        /* System registers. */
        mrs     x2, sp_el0
        mrs     x3, elr_el1
        stp     x2, x3, [x0, #TF_SP_EL0]        /* 248, 256 */
        mrs     x2, spsr_el1
        mrs     x3, esr_el1
        stp     x2, x3, [x0, #TF_SPSR]          /* 264, 272 */
        mrs     x2, far_el1
        mrs     x4, tpidrro_el0
        stp     x2, x4, [x0, #TF_FAR]           /* 280, 288 */
        mrs     x2, tpidr_el0
        str     x2, [x0, #TF_TPIDR]             /* 296 */

        /* Kind: classify a lower-EL synchronous exception by ESR_EL1.EC. */
        and     x2, x1, #0xff
        cbnz    x2, 1f
        ubfx    x4, x3, #26, #6                 /* x3 = ESR_EL1 */
        mov     x2, #KIND_SYNC
        mov     x5, #KIND_SVC
        cmp     x4, #EC_SVC64
        csel    x2, x5, x2, eq
1:
        stp     x2, xzr, [x0, #TF_KIND]         /* 304 kind, 312 resumeFlags = 0 */

        /* Doorbell: make the frame visible, then store its address. */
        mrs     x2, tpidr_el1
        ldr     x2, [x2, #BI_DOORBELL]
        dsb     sy
        str     x0, [x2]                        /* KVM_EXIT_MMIO, 8-byte write */
        dsb     sy

        tbnz    x1, #FATAL_BIT, .Lfatal

        /*
         * Stage 3a: resumeFlags bit 0 = the VMM changed the page tables while
         * it handled this trap. Flush the EL1&0 TLB (and the I-cache, because
         * a reused page may now hold new code), then clear the flag.
         */
        ldr     x2, [x0, #TF_RESUME_FLAGS]
        tbz     x2, #RESUME_FLUSH_TLB_BIT, 2f
        tlbi    vmalle1
        ic      iallu
        dsb     ish
        isb
        bic     x2, x2, #(1 << RESUME_FLUSH_TLB_BIT)
        str     x2, [x0, #TF_RESUME_FLAGS]
2:
        /* Resume: reload everything from the frame (the VMM may have edited it). */
        ldp     x2, x3, [x0, #TF_SP_EL0]
        msr     sp_el0, x2
        msr     elr_el1, x3
        ldr     x2, [x0, #TF_SPSR]
        msr     spsr_el1, x2
        ldp     x2, x3, [x0, #TF_TPIDRRO]       /* 288, 296 */
        msr     tpidrro_el0, x2
        msr     tpidr_el0, x3

        ldp     x2, x3, [x0, #TF_X0 + 16]
        ldp     x4, x5, [x0, #TF_X0 + 32]
        ldp     x6, x7, [x0, #TF_X0 + 48]
        ldp     x8, x9, [x0, #TF_X0 + 64]
        ldp     x10, x11, [x0, #TF_X0 + 80]
        ldp     x12, x13, [x0, #TF_X0 + 96]
        ldp     x14, x15, [x0, #TF_X0 + 112]
        ldp     x16, x17, [x0, #TF_X0 + 128]
        ldp     x18, x19, [x0, #TF_X0 + 144]
        ldp     x20, x21, [x0, #TF_X0 + 160]
        ldp     x22, x23, [x0, #TF_X0 + 176]
        ldp     x24, x25, [x0, #TF_X0 + 192]
        ldp     x26, x27, [x0, #TF_X0 + 208]
        ldp     x28, x29, [x0, #TF_X0 + 224]
        ldr     x30, [x0, #TF_X0 + 240]
        ldp     x0, x1, [x0, #TF_X0 + 0]        /* base last; no writeback, so allowed */
        isb
        eret

.Lfatal:
        wfi
        b       .Lfatal
