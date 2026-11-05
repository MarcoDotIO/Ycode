//! `@synchronized` (objc-runtime.md §9): a recursive lock per object.

use crate::abi::Id;
use crate::sys;
use crate::util::{Global, Lock};
use alloc::boxed::Box;
use alloc::vec::Vec;
use core::sync::atomic::{AtomicUsize, Ordering};

struct SyncData {
    obj: usize,
    owner: AtomicUsize,
    depth: usize,
    users: usize,
    lock: Lock,
}

struct Stripe {
    lock: Lock,
    list: Global<Vec<*mut SyncData>>,
}
const N: usize = 64;
static STRIPES: [Stripe; N] = [const { Stripe { lock: Lock::new(), list: Global::new(Vec::new()) } }; N];

pub const OBJC_SYNC_SUCCESS: i32 = 0;
pub const OBJC_SYNC_NOT_OWNING_THREAD_ERROR: i32 = -1;

fn stripe(obj: Id) -> &'static Stripe {
    let a = obj as usize;
    &STRIPES[((a >> 4) ^ (a >> 10)) % N]
}

/// The record for `obj`, created or reused; counts the caller as a user.
fn acquire(obj: Id) -> *mut SyncData {
    let s = stripe(obj);
    let _g = s.lock.lock();
    let list = unsafe { s.list.get() };
    let mut free: *mut SyncData = core::ptr::null_mut();
    for &d in list.iter() {
        unsafe {
            if (*d).obj == obj as usize {
                (*d).users += 1;
                return d;
            }
            if (*d).users == 0 && free.is_null() {
                free = d;
            }
        }
    }
    let d = if free.is_null() {
        let d = Box::into_raw(Box::new(SyncData {
            obj: 0,
            owner: AtomicUsize::new(0),
            depth: 0,
            users: 0,
            lock: Lock::new(),
        }));
        list.push(d);
        d
    } else {
        free
    };
    unsafe {
        (*d).obj = obj as usize;
        (*d).users = 1;
    }
    d
}

fn find(obj: Id) -> *mut SyncData {
    let s = stripe(obj);
    let _g = s.lock.lock();
    for &d in unsafe { s.list.get() }.iter() {
        if unsafe { (*d).obj } == obj as usize {
            return d;
        }
    }
    core::ptr::null_mut()
}

fn unuse(obj: Id, d: *mut SyncData) {
    let s = stripe(obj);
    let _g = s.lock.lock();
    unsafe {
        (*d).users -= 1;
        if (*d).users == 0 {
            (*d).obj = 0;
        }
    }
}

#[no_mangle]
pub extern "C" fn objc_sync_enter(obj: Id) -> i32 {
    if obj.is_null() {
        return OBJC_SYNC_SUCCESS;
    }
    let me = unsafe { sys::pthread_self() } as usize;
    let d = acquire(obj);
    unsafe {
        if (*d).owner.load(Ordering::Relaxed) == me {
            (*d).depth += 1;
            unuse(obj, d);
            return OBJC_SYNC_SUCCESS;
        }
        (*d).lock.raw_lock();
        (*d).owner.store(me, Ordering::Relaxed);
        (*d).depth = 1;
    }
    OBJC_SYNC_SUCCESS
}

#[no_mangle]
pub extern "C" fn objc_sync_exit(obj: Id) -> i32 {
    if obj.is_null() {
        return OBJC_SYNC_SUCCESS;
    }
    let me = unsafe { sys::pthread_self() } as usize;
    let d = find(obj);
    if d.is_null() {
        return OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
    }
    unsafe {
        if (*d).owner.load(Ordering::Relaxed) != me {
            return OBJC_SYNC_NOT_OWNING_THREAD_ERROR;
        }
        (*d).depth -= 1;
        if (*d).depth > 0 {
            return OBJC_SYNC_SUCCESS;
        }
        (*d).owner.store(0, Ordering::Relaxed);
        (*d).lock.raw_unlock();
    }
    unuse(obj, d);
    OBJC_SYNC_SUCCESS
}
