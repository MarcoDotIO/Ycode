//! Exceptions (objc-runtime.md §13): wave 1 reports and aborts. The entry
//! points exist so that programs built with exception handling load.

use crate::abi::*;
use crate::class;
use crate::util::{fatal, Msg};
use core::ffi::c_void;

static mut UNCAUGHT: Option<extern "C" fn(Id)> = None;

#[no_mangle]
pub extern "C" fn objc_exception_throw(exc: Id) -> ! {
    if let Some(h) = unsafe { core::ptr::addr_of!(UNCAUGHT).read() } {
        h(exc);
    }
    let mut m = Msg::new();
    m.s("objc: terminating with uncaught exception of class ")
        .cstr(class::name_of(class::object_class(exc)))
        .s(" (")
        .hex(exc as usize)
        .s("); Ycode's runtime does not unwind yet");
    fatal(&mut m)
}

#[no_mangle]
pub extern "C" fn objc_exception_rethrow() -> ! {
    crate::util::fatal_str("objc_exception_rethrow: no exception unwinding yet")
}

#[no_mangle]
pub extern "C" fn objc_begin_catch(exc: *mut c_void) -> Id {
    exc as Id
}

#[no_mangle]
pub extern "C" fn objc_end_catch() {}

#[no_mangle]
pub extern "C" fn objc_terminate() -> ! {
    crate::util::fatal_str("objc_terminate")
}

/// `objc_setUncaughtExceptionHandler`; returns the previous handler.
#[no_mangle]
pub extern "C" fn objc_setUncaughtExceptionHandler(h: Option<extern "C" fn(Id)>) -> Option<extern "C" fn(Id)> {
    unsafe {
        let old = core::ptr::addr_of!(UNCAUGHT).read();
        core::ptr::addr_of_mut!(UNCAUGHT).write(h);
        old
    }
}

/// The personality routine named by landing pads in Objective-C code.
/// Nothing unwinds through Objective-C frames yet, so it never catches
/// (`_URC_CONTINUE_UNWIND` = 8).
#[no_mangle]
pub extern "C" fn __objc_personality_v0(_version: i32, _actions: i32, _class: u64, _exc: *mut c_void, _ctx: *mut c_void) -> i32 {
    8
}
