//! The property accessor helpers clang calls (`objc_getProperty`,
//! `objc_setProperty*`, `objc_copyStruct`, `objc_copyCppObjectAtomic`).

use crate::abi::*;
use crate::msgsend::send1;
use crate::rr;
use crate::sys;
use crate::util::Lock;
use core::ffi::c_void;

const N: usize = 64;
static LOCKS: [Lock; N] = [const { Lock::new() }; N];

fn lock_for(p: *const c_void) -> &'static Lock {
    let a = p as usize;
    &LOCKS[((a >> 4) ^ (a >> 9)) % N]
}

/// `objc_getProperty`, entered through an assembly shim that passes the
/// return address, so an atomic getter's result can be handed to a
/// claiming caller (objc-runtime.md §8.3).
#[no_mangle]
pub extern "C" fn _ycobjc_getProperty(this: Id, _cmd: Sel, offset: isize, atomic: bool, ra: usize) -> Id {
    if this.is_null() {
        return this;
    }
    let slot = unsafe { (this as *mut u8).offset(offset) } as *mut Id;
    if !atomic {
        return unsafe { *slot };
    }
    let v = {
        let _g = lock_for(slot as *const c_void).lock();
        rr::objc_retain(unsafe { *slot })
    };
    crate::arp::_ycobjc_autoreleaseReturnValue(v, ra)
}

fn set(this: Id, offset: isize, new: Id, atomic: bool, copy: bool, mutable_copy: bool) {
    if this.is_null() {
        return;
    }
    if offset == 0 {
        crate::api::object_setClass(this, new as Class);
        return;
    }
    let value = if new.is_null() {
        new
    } else if copy {
        send1(new, crate::sel::register(c"copyWithZone:".as_ptr(), false), 0) as Id
    } else if mutable_copy {
        send1(new, crate::sel::register(c"mutableCopyWithZone:".as_ptr(), false), 0) as Id
    } else {
        rr::objc_retain(new)
    };
    let slot = unsafe { (this as *mut u8).offset(offset) } as *mut Id;
    let old = if atomic {
        let _g = lock_for(slot as *const c_void).lock();
        let o = unsafe { *slot };
        unsafe { *slot = value };
        o
    } else {
        let o = unsafe { *slot };
        unsafe { *slot = value };
        o
    };
    rr::objc_release(old);
}

/// `shouldCopy`: 0 retain, 1 copy, 2 mutable copy.
#[no_mangle]
pub extern "C" fn objc_setProperty(this: Id, _cmd: Sel, offset: isize, new: Id, atomic: bool, should_copy: i8) {
    set(this, offset, new, atomic, should_copy != 0 && should_copy != 2, should_copy == 2);
}
#[no_mangle]
pub extern "C" fn objc_setProperty_atomic(this: Id, _cmd: Sel, new: Id, offset: isize) {
    set(this, offset, new, true, false, false);
}
#[no_mangle]
pub extern "C" fn objc_setProperty_nonatomic(this: Id, _cmd: Sel, new: Id, offset: isize) {
    set(this, offset, new, false, false, false);
}
#[no_mangle]
pub extern "C" fn objc_setProperty_atomic_copy(this: Id, _cmd: Sel, new: Id, offset: isize) {
    set(this, offset, new, true, true, false);
}
#[no_mangle]
pub extern "C" fn objc_setProperty_nonatomic_copy(this: Id, _cmd: Sel, new: Id, offset: isize) {
    set(this, offset, new, false, true, false);
}

#[no_mangle]
pub extern "C" fn objc_copyStruct(dest: *mut c_void, src: *const c_void, size: isize, atomic: bool, _has_strong: bool) {
    if atomic {
        let a = lock_for(src);
        let b = lock_for(dest as *const c_void);
        let same = core::ptr::eq(a, b);
        a.raw_lock();
        if !same {
            b.raw_lock();
        }
        unsafe { sys::memmove(dest, src, size as usize) };
        if !same {
            b.raw_unlock();
        }
        a.raw_unlock();
    } else {
        unsafe { sys::memmove(dest, src, size as usize) };
    }
}

#[no_mangle]
pub extern "C" fn objc_copyCppObjectAtomic(
    dest: *mut c_void,
    src: *const c_void,
    helper: extern "C" fn(*mut c_void, *const c_void),
) {
    let a = lock_for(src);
    let b = lock_for(dest as *const c_void);
    let same = core::ptr::eq(a, b);
    a.raw_lock();
    if !same {
        b.raw_lock();
    }
    helper(dest, src);
    if !same {
        b.raw_unlock();
    }
    a.raw_unlock();
}
