// ydl_start.S - the first instructions of a macOS process under Ycode, and
// the dynamic linker's raw system-call helper (specs/macos/dyld.md §3).
// Clean-room Ycode code (Arm ARM; Darwin trap convention from
// specs/simulator/darwin-arm64-abi.md §1-§2).

    .text
    .p2align 2

// Entry (the LC_UNIXTHREAD pc). The kernel leaves SP at the Mach-header
// slot of the argument block (darwin-process-start.md §1.3), not 16-byte
// aligned, with every general register zero.
    .globl __ydl_start
__ydl_start:
    mov     x0, sp              // x0 = &{mach_header, argc, argv..., NULL, envp..., NULL, apple..., NULL}
    and     x1, x0, #~15
    mov     sp, x1
    mov     x29, #0
    mov     x30, #0
    bl      _ydl_main           // never returns
    brk     #1

// long ydl_syscall(long number, long a0, long a1, long a2, long a3, long a4, long a5)
// A BSD system call: the result, or minus the errno when carry is set.
    .globl _ydl_syscall
    .private_extern _ydl_syscall
_ydl_syscall:
    mov     x16, x0
    mov     x0, x1
    mov     x1, x2
    mov     x2, x3
    mov     x3, x4
    mov     x4, x5
    mov     x5, x6
    svc     #0x80
    b.cs    1f
    ret
1:  neg     x0, x0
    ret
