//! Associated objects (objc-runtime.md §9).

use crate::abi::*;
use crate::map::PtrMap;
use crate::rr;
use crate::util::{Global, Lock};
use alloc::vec::Vec;

struct Assoc {
    key: usize,
    policy: usize,
    value: Id,
}

static LOCK: Lock = Lock::new();
static MAP: Global<PtrMap<Vec<Assoc>>> = Global::new(PtrMap::new());

// Policies (objc/runtime.h): the low two bits say assign (0), retain (1)
// or copy (3); bits 8-9 (01400) make the getter retain and autorelease.
const KIND_MASK: usize = 3;
const KIND_RETAIN: usize = 1;
const KIND_COPY: usize = 3;
const ATOMIC: usize = 0o1400;

fn acquire(value: Id, policy: usize) -> Id {
    match policy & KIND_MASK {
        KIND_RETAIN => rr::objc_retain(value),
        KIND_COPY => {
            if value.is_null() {
                value
            } else {
                // -copy is -copyWithZone:nil in practice; send -copy.
                crate::msgsend::send0(value, crate::sel::b().copy) as Id
            }
        }
        _ => value,
    }
}

fn release(value: Id, policy: usize) {
    let k = policy & KIND_MASK;
    if k == KIND_RETAIN || k == KIND_COPY {
        rr::objc_release(value);
    }
}

#[no_mangle]
pub extern "C" fn objc_setAssociatedObject(obj: Id, key: *const core::ffi::c_void, value: Id, policy: usize) {
    if obj.is_null() {
        return;
    }
    let new = acquire(value, policy);
    let mut old: Option<(Id, usize)> = None;
    {
        let _g = LOCK.lock();
        let map = unsafe { MAP.get() };
        if new.is_null() {
            if let Some(list) = map.get_mut(obj as usize) {
                if let Some(i) = list.iter().position(|a| a.key == key as usize) {
                    let a = list.swap_remove(i);
                    old = Some((a.value, a.policy));
                }
            }
        } else {
            let list = map.entry(obj as usize, Vec::new);
            match list.iter_mut().find(|a| a.key == key as usize) {
                Some(a) => {
                    old = Some((a.value, a.policy));
                    a.value = new;
                    a.policy = policy;
                }
                None => list.push(Assoc { key: key as usize, policy, value: new }),
            }
            rr::set_has_assoc(obj);
        }
    }
    if let Some((v, p)) = old {
        release(v, p);
    }
}

#[no_mangle]
pub extern "C" fn objc_getAssociatedObject(obj: Id, key: *const core::ffi::c_void) -> Id {
    if obj.is_null() {
        return obj;
    }
    let (v, p) = {
        let _g = LOCK.lock();
        let map = unsafe { MAP.get() };
        match map.get(obj as usize).and_then(|l| l.iter().find(|a| a.key == key as usize)) {
            Some(a) => {
                if a.policy & ATOMIC != 0 && a.policy & KIND_MASK != 0 {
                    rr::objc_retain(a.value);
                }
                (a.value, a.policy)
            }
            None => return core::ptr::null_mut(),
        }
    };
    if p & ATOMIC != 0 && p & KIND_MASK != 0 {
        return crate::arp::objc_autorelease(v);
    }
    v
}

#[no_mangle]
pub extern "C" fn objc_removeAssociatedObjects(obj: Id) {
    if obj.is_null() {
        return;
    }
    remove_all(obj, false);
}

/// Drops every association of `obj` (releases outside the lock).
pub fn remove_all(obj: Id, _deallocating: bool) {
    let list = {
        let _g = LOCK.lock();
        unsafe { MAP.get() }.remove(obj as usize)
    };
    if let Some(l) = list {
        for a in l {
            release(a.value, a.policy);
        }
    }
}
