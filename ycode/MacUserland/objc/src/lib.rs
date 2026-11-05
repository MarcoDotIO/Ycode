//! Ycode's Objective-C runtime, `/usr/lib/libobjc.A.dylib` of Ycode's macOS
//! userland (specs/macos/objc-runtime.md). Clean-room code written from
//! clang's public Objective-C ABI, the public SDK headers and the Mach-O
//! format; no Objective-C runtime source was read.

#![no_std]
// The exported functions are the C ABI of objc/runtime.h: they take raw
// pointers from C callers by definition. Class records are handed out as
// `&mut` under the runtime lock (class::rw). The table types are internal.
#![allow(
    clippy::missing_safety_doc,
    clippy::not_unsafe_ptr_arg_deref,
    clippy::mut_from_ref,
    clippy::new_without_default,
    clippy::len_without_is_empty
)]

extern crate alloc;

pub mod abi;
pub mod api;
pub mod arp;
pub mod assoc;
pub mod cache;
pub mod class;
pub mod exc;
pub mod image;
pub mod map;
pub mod msgsend;
pub mod nsobject;
pub mod property;
pub mod protocol;
pub mod rr;
pub mod sel;
pub mod sync;
pub mod sys;
pub mod tagged;
pub mod util;
pub mod weak;

use core::ffi::{c_char, c_int, c_void};

struct Malloc;
unsafe impl core::alloc::GlobalAlloc for Malloc {
    unsafe fn alloc(&self, l: core::alloc::Layout) -> *mut u8 {
        if l.align() <= 16 {
            sys::malloc(l.size()) as *mut u8
        } else {
            let mut p: *mut c_void = core::ptr::null_mut();
            if sys::posix_memalign(&mut p, l.align(), l.size()) != 0 {
                return core::ptr::null_mut();
            }
            p as *mut u8
        }
    }
    unsafe fn alloc_zeroed(&self, l: core::alloc::Layout) -> *mut u8 {
        if l.align() <= 16 {
            sys::calloc(1, l.size()) as *mut u8
        } else {
            let p = self.alloc(l);
            if !p.is_null() {
                sys::memset(p as *mut c_void, 0, l.size());
            }
            p
        }
    }
    unsafe fn dealloc(&self, p: *mut u8, _l: core::alloc::Layout) {
        sys::free(p as *mut c_void)
    }
    unsafe fn realloc(&self, p: *mut u8, l: core::alloc::Layout, n: usize) -> *mut u8 {
        if l.align() <= 16 {
            sys::realloc(p as *mut c_void, n) as *mut u8
        } else {
            let q = self.alloc(core::alloc::Layout::from_size_align_unchecked(n, l.align()));
            if !q.is_null() {
                sys::memcpy(q as *mut c_void, p as *const c_void, if n < l.size() { n } else { l.size() });
                sys::free(p as *mut c_void);
            }
            q
        }
    }
}

#[global_allocator]
static ALLOC: Malloc = Malloc;

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    let mut m = util::Msg::new();
    m.s("objc: internal error");
    if let Some(l) = info.location() {
        m.s(" at ").s(l.file()).s(":").dec(l.line() as usize);
    }
    util::fatal(&mut m)
}

/// The library initializer (a `__mod_init_func` entry): runs after
/// libSystem's, before those of the images that link libobjc.
extern "C" fn objc_init(_argc: c_int, _argv: *const *const c_char, _envp: *const *const c_char) {
    sel::init();
    class::init_special_filter();
    msgsend::init();
    arp::init();
    nsobject::init();
    image::init();
}

#[used]
#[link_section = "__DATA,__mod_init_func,mod_init_funcs"]
static INIT: extern "C" fn(c_int, *const *const c_char, *const *const c_char) = objc_init;
