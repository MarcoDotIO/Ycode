// Ycode research interposer: shared trampoline bodies (original Ycode code).
//
// Every generated export does "mov x16, #index; b _sfbt_common". The common
// body saves the argument registers (x0-x8, d0-d7) into a frame record, asks
// the C side for the real function (logging the call), re-materialises the
// arguments plus 8 words of caller stack arguments, calls the real function,
// stores x0/x1/d0-d3 into the record, lets the C side log the result, and
// returns those registers to the caller.
//
// Frame record layout (offsets from sp after "sub sp, sp, #256"):
//   0..63 x0-x7 | 64 x8 | 72 x16 (index) | 80..143 d0-d7
//   160 ret x0 | 168 ret x1 | 176..207 ret d0-d3 | 208 target | 216 cookie
// The C side reads the caller's return address from the frame-pointer pair.

.macro COMMON label, pre, post
    .globl \label
    .p2align 2
\label:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     sp, sp, #256
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x16, [sp, #64]
    stp     d0, d1, [sp, #80]
    stp     d2, d3, [sp, #96]
    stp     d4, d5, [sp, #112]
    stp     d6, d7, [sp, #128]
    mov     x0, sp
    ldr     x1, [x29, #8]
    bl      \pre
    str     x0, [sp, #208]
    sub     sp, sp, #64
    add     x9, x29, #16
    ldp     x10, x11, [x9, #0]
    stp     x10, x11, [sp, #0]
    ldp     x10, x11, [x9, #16]
    stp     x10, x11, [sp, #16]
    ldp     x10, x11, [x9, #32]
    stp     x10, x11, [sp, #32]
    ldp     x10, x11, [x9, #48]
    stp     x10, x11, [sp, #48]
    add     x9, sp, #64
    ldr     x17, [x9, #208]
    ldp     x0, x1, [x9, #0]
    ldp     x2, x3, [x9, #16]
    ldp     x4, x5, [x9, #32]
    ldp     x6, x7, [x9, #48]
    ldr     x8, [x9, #64]
    ldp     d0, d1, [x9, #80]
    ldp     d2, d3, [x9, #96]
    ldp     d4, d5, [x9, #112]
    ldp     d6, d7, [x9, #128]
    blr     x17
    add     sp, sp, #64
    stp     x0, x1, [sp, #160]
    stp     d0, d1, [sp, #176]
    stp     d2, d3, [sp, #192]
    mov     x0, sp
    bl      \post
    ldp     x0, x1, [sp, #160]
    ldp     d0, d1, [sp, #176]
    ldp     d2, d3, [sp, #192]
    mov     sp, x29
    ldp     x29, x30, [sp], #16
    ret
.endm

.text
COMMON _sfbt_common, _sfbt_pre, _sfbt_post
COMMON _sfbt_blk_common, _sfbt_blk_pre, _sfbt_blk_post
