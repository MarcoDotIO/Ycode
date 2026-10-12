// raw_call(fn, const uint64_t x[9], const double d[8], uint64_t out[2], double outd[4])
// Calls fn with x0-x8 and d0-d7 taken from the arrays and stores x0, x1 and
// d0-d3 after the call. Original Ycode research code.
.text
.globl _raw_call
.p2align 2
_raw_call:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x3
    mov     x20, x4
    mov     x16, x0
    mov     x9, x1
    ldp     d0, d1, [x2, #0]
    ldp     d2, d3, [x2, #16]
    ldp     d4, d5, [x2, #32]
    ldp     d6, d7, [x2, #48]
    ldp     x0, x1, [x9, #0]
    ldp     x2, x3, [x9, #16]
    ldp     x4, x5, [x9, #32]
    ldp     x6, x7, [x9, #48]
    ldr     x8, [x9, #64]
    blr     x16
    stp     x0, x1, [x19]
    stp     d0, d1, [x20, #0]
    stp     d2, d3, [x20, #16]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
