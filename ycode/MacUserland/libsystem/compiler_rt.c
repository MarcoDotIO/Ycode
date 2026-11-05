// compiler_rt.c - compiler-runtime entry points that macOS programs import
// from libSystem.
//
// Clean-room Ycode code. ___chkstk_darwin: clang calls it in functions
// whose frame exceeds a page (the size in x9; only x9 and the flags may
// change; libsystem.md §4). Ycode's libsystem_pthread has the probe as
// ____chkstk_darwin with the same convention; this entry forwards to it
// (the linker's stub uses only x16 and x17).
#include "ycl.h"

__asm__(".globl ___chkstk_darwin\n"
        ".p2align 2\n"
        "___chkstk_darwin:\n"
        "    b ____chkstk_darwin\n");
