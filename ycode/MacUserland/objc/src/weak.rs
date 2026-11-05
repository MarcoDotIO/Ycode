//! Weak references (objc-runtime.md §9): the referent's side-table entry
//! lists the addresses of the weak variables that point at it.

use crate::abi::*;
use crate::class::ISA_MASK;
use crate::msgsend::send0;
use crate::rr::{self, stripe, stripe_at, stripe_index, Stripe};
use crate::sel;
use core::sync::atomic::Ordering;

#[inline(always)]
fn weakable(o: Id) -> bool {
    (o as isize) > 0
}

/// Locks the stripes of `a` and `b` (either may be unweakable) in index order.
fn lock2(a: Id, b: Id) -> (Option<&'static Stripe>, Option<&'static Stripe>) {
    let ia = if weakable(a) { Some(stripe_index(a)) } else { None };
    let ib = if weakable(b) { Some(stripe_index(b)) } else { None };
    match (ia, ib) {
        (Some(x), Some(y)) if x == y => {
            let s = stripe_at(x);
            s.lock.raw_lock();
            (Some(s), None)
        }
        (Some(x), Some(y)) => {
            let (lo, hi) = if x < y { (x, y) } else { (y, x) };
            stripe_at(lo).lock.raw_lock();
            stripe_at(hi).lock.raw_lock();
            (Some(stripe_at(x)), Some(stripe_at(y)))
        }
        (Some(x), None) => {
            stripe_at(x).lock.raw_lock();
            (Some(stripe_at(x)), None)
        }
        (None, Some(y)) => {
            stripe_at(y).lock.raw_lock();
            (None, Some(stripe_at(y)))
        }
        (None, None) => (None, None),
    }
}
fn unlock2(l: (Option<&'static Stripe>, Option<&'static Stripe>)) {
    if let Some(s) = l.0 {
        s.lock.raw_unlock();
    }
    if let Some(s) = l.1 {
        s.lock.raw_unlock();
    }
}

fn custom_rr(o: Id) -> bool {
    let isa = rr::isa_word(o).load(Ordering::Relaxed);
    let c = (isa & ISA_MASK) as Class;
    !c.is_null() && rr::custom_rr(c)
}

/// Stores `new` into the weak variable `loc`; returns what was stored.
fn store_weak(loc: *mut Id, mut new: Id, has_old: bool) -> Id {
    // Ask a class with its own reference counting before taking locks.
    if weakable(new) && custom_rr(new) {
        let ok = send0(new, sel::b().allows_weak_reference) & 0xFF != 0;
        if !ok {
            new = core::ptr::null_mut();
        }
    }
    loop {
        let old = if has_old { unsafe { *loc } } else { core::ptr::null_mut() };
        let l = lock2(old, new);
        if has_old && unsafe { *loc } != old {
            unlock2(l);
            continue;
        }
        if weakable(old) {
            let s = stripe(old);
            if let Some(e) = s.get(old) {
                if let Some(i) = e.weak.iter().position(|&p| p == loc) {
                    e.weak.swap_remove(i);
                }
            }
        }
        let mut stored = new;
        if weakable(new) {
            let s = stripe(new);
            if rr::deallocating_locked(new, s) {
                stored = core::ptr::null_mut();
            } else {
                s.entry(new).weak.push(loc);
                rr::set_weakly_referenced(new);
            }
        }
        unsafe { *loc = stored };
        unlock2(l);
        return stored;
    }
}

#[no_mangle]
pub extern "C" fn objc_storeWeak(loc: *mut Id, obj: Id) -> Id {
    store_weak(loc, obj, true)
}

#[no_mangle]
pub extern "C" fn objc_storeWeakOrNil(loc: *mut Id, obj: Id) -> Id {
    store_weak(loc, obj, true)
}

#[no_mangle]
pub extern "C" fn objc_initWeak(loc: *mut Id, obj: Id) -> Id {
    if obj.is_null() {
        unsafe { *loc = obj };
        return obj;
    }
    store_weak(loc, obj, false)
}

#[no_mangle]
pub extern "C" fn objc_initWeakOrNil(loc: *mut Id, obj: Id) -> Id {
    objc_initWeak(loc, obj)
}

#[no_mangle]
pub extern "C" fn objc_destroyWeak(loc: *mut Id) {
    store_weak(loc, core::ptr::null_mut(), true);
}

#[no_mangle]
pub extern "C" fn objc_loadWeakRetained(loc: *mut Id) -> Id {
    loop {
        let obj = unsafe { *loc };
        if !weakable(obj) {
            return obj;
        }
        if custom_rr(obj) {
            // Classes with their own counting decide through
            // -retainWeakReference (called without our locks).
            let s = stripe(obj);
            s.lock.raw_lock();
            if unsafe { *loc } != obj {
                s.lock.raw_unlock();
                continue;
            }
            let dying = rr::deallocating_locked(obj, s);
            s.lock.raw_unlock();
            if dying {
                return core::ptr::null_mut();
            }
            if send0(obj, sel::b().retain_weak_reference) & 0xFF == 0 {
                return core::ptr::null_mut();
            }
            return obj;
        }
        let s = stripe(obj);
        s.lock.raw_lock();
        if unsafe { *loc } != obj {
            s.lock.raw_unlock();
            continue;
        }
        let ok = rr::try_retain_locked(obj, s);
        s.lock.raw_unlock();
        return if ok { obj } else { core::ptr::null_mut() };
    }
}

#[no_mangle]
pub extern "C" fn objc_loadWeak(loc: *mut Id) -> Id {
    crate::arp::objc_autorelease(objc_loadWeakRetained(loc))
}

#[no_mangle]
pub extern "C" fn objc_copyWeak(dst: *mut Id, src: *mut Id) {
    let o = objc_loadWeakRetained(src);
    objc_initWeak(dst, o);
    rr::objc_release(o);
}

#[no_mangle]
pub extern "C" fn objc_moveWeak(dst: *mut Id, src: *mut Id) {
    objc_copyWeak(dst, src);
    objc_destroyWeak(src);
    unsafe { *src = core::ptr::null_mut() };
}

/// `-[NSObject allowsWeakReference]`'s default answer.
pub fn default_allows_weak(obj: Id) -> bool {
    !rr::_objc_rootIsDeallocating(obj)
}
