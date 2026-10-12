// syscall_special.S - libsystem_kernel system-call wrappers that are not a
// plain "number, svc, carry -> cerror" sequence (see gen_syscalls.py,
// HANDWRITTEN).
//
// Clean-room Ycode code. Facts used:
//   - darwin-arm64-abi.md, stage3-contract.md section 10: svc #0x80,
//     x16 = BSD number (low 16 bits) or -Mach number, carry = error with the
//     errno in x0; BSD 0 is the indirect call (number in x0, arguments in
//     x1...).
//   - darwin-trap-tables.md section 4: the platform call (x16 = 0x8000_0000,
//     x3 = 2 sets the TSD base from x0).
//   - host-library-init.md section 4: cerror / cerror_nocancel, ULF_NO_ERRNO.
//   - Apple's published arm64 calling convention: every variadic argument
//     takes its own 8-byte stack slot starting at the caller's sp; named
//     arguments use x0-x7. Arguments beyond x7 are packed on the stack at
//     their natural size and alignment.
//   - Public <fcntl.h>/<sys/select.h> values: O_CREAT = 0x200,
//     FD_SETSIZE = 1024, EINVAL = 22, EFAULT = 14.

    .section __TEXT,__text,regular,pure_instructions

    .macro BSD number
    mov x16, #\number
    svc #0x80
    .endm

    .p2align 2
Lsp_cerror:
    b _cerror
Lsp_cerror_nocancel:
    b _cerror_nocancel
Lsp_einval:
    mov w0, #22
    b _cerror_nocancel
Lsp_efault:
    mov w0, #14
    b _cerror_nocancel

// ---------------------------------------------------------------------------
// int pipe(int fds[2]): BSD 42 returns the read end in x0 and the write end
// in x1.
    .globl _pipe
    .p2align 2
_pipe:
    str x0, [sp, #-16]!
    BSD 42
    ldr x2, [sp], #16          // ldr and the add do not change the flags
    b.cs Lsp_cerror_nocancel
    stp w0, w1, [x2]
    mov w0, #0
    ret

// pid_t __fork(void): BSD 2 returns x0 = the other process's pid and
// x1 = 0 in the parent, 1 in the child. The child returns 0.
    .globl ___fork
    .p2align 2
___fork:
    BSD 2
    b.cs Lsp_cerror_nocancel
    cbz w1, 1f
    mov w0, #0
1:  ret

// int kill(pid_t, int): BSD 37 takes a third "POSIX semantics" flag; the
// LP64 library is always the conforming variant (__unix_conforming = 1).
    .globl _kill
    .p2align 2
_kill:
    mov w2, #1
    BSD 37
    b.cs Lsp_cerror_nocancel
    ret

// int reboot(int howto): BSD 55 also takes a message pointer.
    .globl _reboot
    .p2align 2
_reboot:
    mov x1, #0
    BSD 55
    b.cs Lsp_cerror_nocancel
    ret

// int sigsuspend(const sigset_t *): BSD 111 / 410 take the mask by value.
    .globl _sigsuspend
    .p2align 2
_sigsuspend:
    cbz x0, Lsp_efault
    ldr w0, [x0]
    BSD 111
    b.cs Lsp_cerror
    ret

    .globl "_sigsuspend$NOCANCEL"
    .p2align 2
"_sigsuspend$NOCANCEL":
    cbz x0, Lsp_efault
    ldr w0, [x0]
    BSD 410
    b.cs Lsp_cerror_nocancel
    ret

// select / pselect without $DARWIN_EXTSN: nfds above FD_SETSIZE (or below
// 0) fails with EINVAL (select(2)); the $DARWIN_EXTSN variants are plain.
    .globl _select
    .p2align 2
_select:
    cmp w0, #1024
    b.hi Lsp_einval
    BSD 93
    b.cs Lsp_cerror
    ret

    .globl "_select$NOCANCEL"
    .p2align 2
"_select$NOCANCEL":
    cmp w0, #1024
    b.hi Lsp_einval
    BSD 407
    b.cs Lsp_cerror_nocancel
    ret

    .globl _pselect
    .p2align 2
_pselect:
    cmp w0, #1024
    b.hi Lsp_einval
    BSD 394
    b.cs Lsp_cerror
    ret

    .globl "_pselect$NOCANCEL"
    .p2align 2
"_pselect$NOCANCEL":
    cmp w0, #1024
    b.hi Lsp_einval
    BSD 395
    b.cs Lsp_cerror_nocancel
    ret

// ---------------------------------------------------------------------------
// ulock (BSD 515 wait, 544 wait2, 516 wake). With ULF_NO_ERRNO
// (bit 24 of the operation) an error is returned as -errno and errno is
// untouched. The kernel already does this; the wrapper also handles a
// carry-set error so that the rule holds either way.
    .macro ULOCK name, number
    .globl \name
    .p2align 2
\name:
    str x0, [sp, #-16]!
    mov x16, #\number
    svc #0x80
    ldr x9, [sp], #16
    b.cs 1f
    ret
1:  tbz w9, #24, Lsp_cerror_nocancel
    neg w0, w0
    ret
    .endm

    ULOCK ___ulock_wait, 515
    ULOCK ___ulock_wait2, 544
    ULOCK ___ulock_wake, 516

// ---------------------------------------------------------------------------
// Variadic calls: the optional trailing argument is the caller's first
// stack slot.

// int open(const char *, int, ...) -> BSD 5 (path, flags, mode)
    .macro VARIADIC1 name, number, reg, err
    .globl \name
    .p2align 2
\name:
    ldr \reg, [sp]
    mov x16, #\number
    svc #0x80
    b.cs \err
    ret
    .endm

    VARIADIC1 _open, 5, x2, Lsp_cerror
    VARIADIC1 "_open$NOCANCEL", 398, x2, Lsp_cerror_nocancel
    // int openat(int, const char *, int, ...) -> BSD 463 (fd, path, flags, mode)
    VARIADIC1 _openat, 463, x3, Lsp_cerror
    VARIADIC1 "_openat$NOCANCEL", 464, x3, Lsp_cerror_nocancel
    // int fcntl(int, int, ...) -> BSD 92 (fd, cmd, long arg)
    VARIADIC1 _fcntl, 92, x2, Lsp_cerror
    VARIADIC1 "_fcntl$NOCANCEL", 406, x2, Lsp_cerror_nocancel
    // int ioctl(int, unsigned long, ...) -> BSD 54 (fd, request, data)
    VARIADIC1 _ioctl, 54, x2, Lsp_cerror_nocancel
    // int shm_open(const char *, int, ...) -> BSD 266 (name, oflag, mode)
    VARIADIC1 _shm_open, 266, x2, Lsp_cerror_nocancel
    // int semctl(int, int, int, ...) -> BSD 254 (semid, semnum, cmd, arg)
    VARIADIC1 _semctl, 254, x3, Lsp_cerror_nocancel
    // int open_dprotected_np(const char *, int, int, int, ...)
    //   -> BSD 216 (path, flags, class, dpflags, mode)
    VARIADIC1 _open_dprotected_np, 216, x4, Lsp_cerror_nocancel
    // int guarded_open_np(const char *, const guardid_t *, u_int, int, ...)
    //   -> BSD 441 (path, guard, guardflags, flags, mode)
    VARIADIC1 _guarded_open_np, 441, x4, Lsp_cerror_nocancel
    // int guarded_open_dprotected_np(const char *, const guardid_t *, u_int,
    //   int, int dpclass, int dpflags, ...) -> BSD 484 (..., mode)
    VARIADIC1 _guarded_open_dprotected_np, 484, x6, Lsp_cerror_nocancel

// sem_t *sem_open(const char *, int, ...) -> BSD 268 (name, oflag, mode,
// value): two optional arguments, used only with O_CREAT. Returns
// SEM_FAILED (-1) on error.
    .globl _sem_open
    .p2align 2
_sem_open:
    ldp x2, x3, [sp]
    BSD 268
    b.cs Lsp_cerror_nocancel
    ret

// int syscall(int number, ...) and quad_t __syscall(quad_t number, ...):
// the indirect call. The number stays in x0; up to eight arguments are
// copied from the caller's stack slots into x1-x8.
    .globl _syscall
    .globl ___syscall
    .p2align 2
_syscall:
___syscall:
    ldp x1, x2, [sp]
    ldp x3, x4, [sp, #16]
    ldp x5, x6, [sp, #32]
    ldp x7, x8, [sp, #48]
    mov x16, #0
    svc #0x80
    b.cs Lsp_cerror
    ret

// ---------------------------------------------------------------------------
// void _thread_set_tsd_base(void *): the platform call, sub-selector 2.
// x0 is returned unchanged by the kernel.
    .globl __thread_set_tsd_base
    .p2align 2
__thread_set_tsd_base:
    mov x3, #2
    mov x16, #0x80000000
    svc #0x80
    ret

// ---------------------------------------------------------------------------
// Mach VM mapping through Mach trap -15 (_kernelrpc_mach_vm_map_trap:
// target, &address, size, mask, flags, cur_protection). The trap covers
// anonymous memory only, so a request with a memory object, an offset or a
// copy flag is reported as unimplemented.
//
// kern_return_t mach_vm_map(vm_map_t target, mach_vm_address_t *address,
//     mach_vm_size_t size, mach_vm_offset_t mask, int flags,
//     mem_entry_name_port_t object, memory_object_offset_t offset,
//     boolean_t copy, vm_prot_t cur, vm_prot_t max, vm_inherit_t inherit)
// x0-x7 = target ... copy; cur, max, inherit are packed 4-byte stack
// arguments at [sp], [sp+4], [sp+8]. vm_map has the same layout on LP64.
    .globl _mach_vm_map
    .globl _vm_map
    .p2align 2
_mach_vm_map:
_vm_map:
    cbnz w5, 1f                // object
    cbnz x6, 1f                // offset
    ldr w5, [sp]               // cur_protection
    mov x16, #-15
    svc #0x80
    ret
1:  adrp x0, Lsp_name_vm_map@PAGE
    add x0, x0, Lsp_name_vm_map@PAGEOFF
    movz x16, #0x0F00
    movk x16, #0x7963, lsl #16
    svc #0x80
    mov w0, #46                // KERN_NOT_SUPPORTED
    ret

    .section __TEXT,__cstring,cstring_literals
Lsp_name_vm_map:
    .asciz "mach_vm_map (memory object)"
