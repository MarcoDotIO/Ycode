//! `objc_msgSend` and friends in arm64 assembly (objc-runtime.md §5.2,
//! §5.4), and typed helpers for sending from Rust.

use crate::abi::{Class, Id, Imp, Sel};
use crate::class;
use crate::sel;
use crate::util::Msg;
use core::ffi::c_void;
use core::sync::atomic::{AtomicUsize, Ordering};

// Register use: x0 receiver, x1 SEL, x16 class, x10 cache, x11 mask,
// x12 index, x15 bucket address, x9 bucket SEL, x17 bucket IMP.
// The probe, expanded once per entry point so none takes an extra branch.
macro_rules! cache_lookup {
    ($p:literal) => {
        concat!(
            "    ldr x10, [x16, #16]\n",
            "    ldr x11, [x10]\n",
            "    eor x12, x1, x1, lsr #7\n",
            "    and x12, x12, x11\n",
            "L", $p, "_probe:\n",
            "    add x15, x10, x12, lsl #4\n",
            "    ldp x9, x17, [x15, #16]\n",
            "    cmp x9, x1\n",
            "    b.ne L", $p, "_next\n",
            "    cbz x17, L", $p, "_miss\n",
            "    br x17\n",
            "L", $p, "_next:\n",
            "    cbz x9, L", $p, "_miss\n",
            "    add x12, x12, #1\n",
            "    and x12, x12, x11\n",
            "    b L", $p, "_probe\n",
            // A relocated branch, so the linker sees the reference (each
            // global label starts its own atom under -dead_strip).
            "L", $p, "_miss:\n",
            "    b __objc_msgSend_uncached\n",
        )
    };
}

core::arch::global_asm!(
    ".text",
    ".globl _objc_msgSend",
    ".p2align 6",
    "_objc_msgSend:",
    "    cmp x0, #0",
    "    b.le LYC_nil_or_tagged",
    "    ldr x13, [x0]",
    "    and x16, x13, #0x7ffffffffff8",
    cache_lookup!("YC_send"),
    "LYC_nil_or_tagged:",
    "    b.ne LYC_tagged",
    // Nil: x0 is already 0.
    "    mov x1, #0",
    "    movi d0, #0",
    "    movi d1, #0",
    "    movi d2, #0",
    "    movi d3, #0",
    "    ret",
    "LYC_tagged:",
    "    lsr x10, x0, #60",
    "    and x10, x10, #7",
    "    adrp x11, __ycobjc_tagged_classes@PAGE",
    "    add x11, x11, __ycobjc_tagged_classes@PAGEOFF",
    "    ldr x16, [x11, x10, lsl #3]",
    "    cbz x16, LYC_tagged_nil",
    cache_lookup!("YC_tagged"),
    "LYC_tagged_nil:",
    "    mov x0, #0",
    "    mov x1, #0",
    "    movi d0, #0",
    "    movi d1, #0",
    "    movi d2, #0",
    "    movi d3, #0",
    "    ret",
    "",
    ".globl _objc_msgSendSuper",
    ".p2align 5",
    "_objc_msgSendSuper:",
    "    ldp x0, x16, [x0]",
    cache_lookup!("YC_super"),
    "",
    ".globl _objc_msgSendSuper2",
    ".p2align 5",
    "_objc_msgSendSuper2:",
    "    ldp x0, x16, [x0]",
    "    ldr x16, [x16, #8]",
    cache_lookup!("YC_super2"),
    "",
    // objc_retain / objc_release fast paths (objc-runtime.md §7.1): packed
    // isa, class without custom retain/release, no inline-count carry or
    // borrow. Everything else goes to the Rust slow paths, which recheck.
    ".globl _objc_retain",
    ".p2align 5",
    "_objc_retain:",
    "    cmp x0, #0",
    "    b.le LYC_retain_done",
    "    ldr x1, [x0]",
    "    movz x3, #0x4, lsl #48",
    "LYC_retain_loop:",
    "    tbz x1, #0, LYC_retain_slow",
    "    and x2, x1, #0x7ffffffffff8",
    "    ldr x2, [x2, #24]",
    "    tbnz x2, #4, LYC_retain_slow",
    "    adds x2, x1, x3",
    "    b.cs LYC_retain_slow",
    "    mov x4, x1",
    "    cas x4, x2, [x0]",
    "    cmp x4, x1",
    "    b.ne LYC_retain_again",
    "LYC_retain_done:",
    "    ret",
    "LYC_retain_again:",
    "    mov x1, x4",
    "    b LYC_retain_loop",
    "LYC_retain_slow:",
    "    b __ycobjc_retain_slow",
    "",
    ".globl _objc_release",
    ".p2align 5",
    "_objc_release:",
    "    cmp x0, #0",
    "    b.le LYC_release_done",
    "    ldr x1, [x0]",
    "    movz x3, #0x4, lsl #48",
    "LYC_release_loop:",
    "    tbz x1, #0, LYC_release_slow",
    "    and x2, x1, #0x7ffffffffff8",
    "    ldr x2, [x2, #24]",
    "    tbnz x2, #4, LYC_release_slow",
    "    cmp x1, x3",
    "    b.lo LYC_release_slow",
    "    sub x2, x1, x3",
    "    mov x4, x1",
    "    casl x4, x2, [x0]",
    "    cmp x4, x1",
    "    b.ne LYC_release_again",
    "LYC_release_done:",
    "    ret",
    "LYC_release_again:",
    "    mov x1, x4",
    "    b LYC_release_loop",
    "LYC_release_slow:",
    "    b __ycobjc_release_slow",
    "",
    // The slow path: x16 is the class to search. Saves the argument
    // registers, asks Rust for the IMP, restores, jumps.
    ".globl __objc_msgSend_uncached",
    ".p2align 4",
    "__objc_msgSend_uncached:",
    "    stp x29, x30, [sp, #-16]!",
    "    mov x29, sp",
    "    sub sp, sp, #208",
    "    stp q0, q1, [sp, #0]",
    "    stp q2, q3, [sp, #32]",
    "    stp q4, q5, [sp, #64]",
    "    stp q6, q7, [sp, #96]",
    "    stp x0, x1, [sp, #128]",
    "    stp x2, x3, [sp, #144]",
    "    stp x4, x5, [sp, #160]",
    "    stp x6, x7, [sp, #176]",
    "    str x8, [sp, #192]",
    "    mov x2, x16",
    "    bl __ycobjc_lookup",
    "    mov x17, x0",
    "    ldp q0, q1, [sp, #0]",
    "    ldp q2, q3, [sp, #32]",
    "    ldp q4, q5, [sp, #64]",
    "    ldp q6, q7, [sp, #96]",
    "    ldp x0, x1, [sp, #128]",
    "    ldp x2, x3, [sp, #144]",
    "    ldp x4, x5, [sp, #160]",
    "    ldp x6, x7, [sp, #176]",
    "    ldr x8, [sp, #192]",
    "    mov sp, x29",
    "    ldp x29, x30, [sp], #16",
    "    br x17",
    "",
    // The IMP of a selector nobody implements: try
    // -forwardingTargetForSelector:, then the forward handler.
    ".globl __objc_msgForward",
    ".p2align 4",
    "__objc_msgForward:",
    "    stp x29, x30, [sp, #-16]!",
    "    mov x29, sp",
    "    sub sp, sp, #208",
    "    stp q0, q1, [sp, #0]",
    "    stp q2, q3, [sp, #32]",
    "    stp q4, q5, [sp, #64]",
    "    stp q6, q7, [sp, #96]",
    "    stp x0, x1, [sp, #128]",
    "    stp x2, x3, [sp, #144]",
    "    stp x4, x5, [sp, #160]",
    "    stp x6, x7, [sp, #176]",
    "    str x8, [sp, #192]",
    "    bl __ycobjc_forward_target",
    "    mov x17, x0",
    "    ldp q0, q1, [sp, #0]",
    "    ldp q2, q3, [sp, #32]",
    "    ldp q4, q5, [sp, #64]",
    "    ldp q6, q7, [sp, #96]",
    "    ldp x0, x1, [sp, #128]",
    "    ldp x2, x3, [sp, #144]",
    "    ldp x4, x5, [sp, #160]",
    "    ldp x6, x7, [sp, #176]",
    "    ldr x8, [sp, #192]",
    "    mov sp, x29",
    "    ldp x29, x30, [sp], #16",
    "    cbz x17, LYC_fwd_handler",
    "    mov x0, x17",
    "    b _objc_msgSend",
    "LYC_fwd_handler:",
    "    adrp x17, __ycobjc_forward_handler@PAGE",
    "    ldr x17, [x17, __ycobjc_forward_handler@PAGEOFF]",
    "    br x17",
    "",
    // Return-value hand-off entry points need their return address.
    ".globl _objc_autoreleaseReturnValue",
    ".p2align 4",
    "_objc_autoreleaseReturnValue:",
    "    mov x1, x30",
    "    b __ycobjc_autoreleaseReturnValue",
    "",
    ".globl _objc_getProperty",
    ".p2align 4",
    "_objc_getProperty:",
    "    mov x4, x30",
    "    b __ycobjc_getProperty",
    "",
    ".globl _objc_retainAutoreleaseReturnValue",
    ".p2align 4",
    "_objc_retainAutoreleaseReturnValue:",
    "    mov x1, x30",
    "    b __ycobjc_retainAutoreleaseReturnValue",
);

extern "C" {
    fn objc_msgSend();
    fn _objc_msgForward();
}

/// Classes of tagged pointers by 3-bit tag (§13: none registered yet).
#[no_mangle]
pub static mut _ycobjc_tagged_classes: [usize; 8] = [0; 8];

/// The forward handler (`objc_setForwardHandler`).
#[no_mangle]
pub static mut _ycobjc_forward_handler: usize = 0;
static DEFAULT_HANDLER: AtomicUsize = AtomicUsize::new(0);

pub fn init() {
    let h = default_forward_handler as *const () as usize;
    DEFAULT_HANDLER.store(h, Ordering::Relaxed);
    unsafe { core::ptr::addr_of_mut!(_ycobjc_forward_handler).write(h) };
}

#[inline(always)]
pub fn forward_imp() -> Imp {
    _objc_msgForward as Imp
}
#[inline(always)]
pub fn msgsend_imp() -> Imp {
    objc_msgSend as Imp
}

extern "C" fn nil_returner() -> usize {
    0
}
pub fn nil_imp() -> Imp {
    nil_returner as Imp
}

#[inline(always)]
pub fn send0(obj: Id, s: Sel) -> usize {
    let f: extern "C" fn(Id, Sel) -> usize = unsafe { core::mem::transmute(objc_msgSend as *const c_void) };
    f(obj, s)
}
#[inline(always)]
pub fn send1(obj: Id, s: Sel, a: usize) -> usize {
    let f: extern "C" fn(Id, Sel, usize) -> usize = unsafe { core::mem::transmute(objc_msgSend as *const c_void) };
    f(obj, s, a)
}
#[inline(always)]
pub fn send2(obj: Id, s: Sel, a: usize, b: usize) -> usize {
    let f: extern "C" fn(Id, Sel, usize, usize) -> usize =
        unsafe { core::mem::transmute(objc_msgSend as *const c_void) };
    f(obj, s, a, b)
}

/// `-forwardingTargetForSelector:` while the default handler is installed.
#[no_mangle]
pub extern "C" fn _ycobjc_forward_target(obj: Id, s: Sel) -> Id {
    if obj.is_null() || unsafe { core::ptr::addr_of!(_ycobjc_forward_handler).read() } != DEFAULT_HANDLER.load(Ordering::Relaxed) {
        return core::ptr::null_mut();
    }
    let b = sel::b();
    if s == b.forwarding_target {
        return core::ptr::null_mut();
    }
    let cls = class::object_class(obj);
    let imp = class::lookup_imp_nil(cls, b.forwarding_target);
    if imp.is_null() || imp == crate::nsobject::default_forwarding_target_imp(class::fast(cls) & class::F_META != 0) {
        return core::ptr::null_mut();
    }
    let t = send1(obj, b.forwarding_target, s as usize) as Id;
    if t.is_null() || t == obj {
        core::ptr::null_mut()
    } else {
        t
    }
}

extern "C" {
    fn getpid() -> i32;
}

/// The default forward handler: report and abort (objc-runtime.md §5.4).
extern "C" fn default_forward_handler(obj: Id, s: Sel) -> ! {
    unrecognized(obj, s, true)
}

pub fn unrecognized(obj: Id, s: Sel, no_handler: bool) -> ! {
    let cls = class::object_class(obj);
    let is_class = !cls.is_null() && class::is_realized(cls) && class::fast(cls) & class::F_META != 0;
    let mut m = Msg::new();
    m.s("objc[").dec(unsafe { getpid() } as usize).s("]: ");
    m.s(if is_class { "+[" } else { "-[" });
    let shown: Class = if is_class { obj as Class } else { cls };
    m.cstr(class::name_of(shown)).s(" ").cstr(s).s("]: unrecognized selector sent to ");
    m.s(if is_class { "class " } else { "instance " }).hex(obj as usize);
    if no_handler {
        m.s(" (no message forward handler is installed)");
    }
    crate::util::fatal(&mut m)
}

/// `objc_setForwardHandler` (`objc/message.h`).
#[no_mangle]
pub extern "C" fn objc_setForwardHandler(fwd: *mut c_void, _fwd_stret: *mut c_void) {
    let h = if fwd.is_null() { DEFAULT_HANDLER.load(Ordering::Relaxed) } else { fwd as usize };
    unsafe { core::ptr::addr_of_mut!(_ycobjc_forward_handler).write(h) };
}
