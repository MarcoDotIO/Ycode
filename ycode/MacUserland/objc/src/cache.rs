//! The per-class method cache probed by `objc_msgSend` (objc-runtime.md §5).
//! Writers hold the runtime lock; readers take no lock.

use crate::abi::{Class, Imp, Sel};
use crate::sys;
use crate::util::Global;
use alloc::vec::Vec;
use core::ffi::c_void;
use core::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};

#[repr(C)]
pub struct Bucket {
    pub sel: AtomicUsize,
    pub imp: AtomicUsize,
}

#[repr(C)]
pub struct Cache {
    /// Bucket count − 1.
    pub mask: u64,
    pub occupied: u32,
    pub reserved: u32,
    pub buckets: [Bucket; 1],
}

/// `_objc_empty_cache`: mask 0, one empty bucket. Every unrealized or
/// flushed class points here, so the probe ends in the slow path.
#[export_name = "_objc_empty_cache"]
pub static mut OBJC_EMPTY_CACHE: Cache = Cache {
    mask: 0,
    occupied: 0,
    reserved: 0,
    buckets: [Bucket { sel: AtomicUsize::new(0), imp: AtomicUsize::new(0) }],
};

#[inline(always)]
pub fn empty() -> *mut Cache {
    core::ptr::addr_of_mut!(OBJC_EMPTY_CACHE)
}

const MAX_BUCKETS: usize = 1 << 16;
const FIRST_BUCKETS: usize = 8;

/// Replaced caches, kept because a reader may still probe them (§5.3).
static GARBAGE: Global<Vec<*mut Cache>> = Global::new(Vec::new());
static GARBAGE_BYTES: AtomicUsize = AtomicUsize::new(0);

#[inline(always)]
pub fn index(sel: Sel, mask: u64) -> usize {
    let s = sel as u64;
    ((s ^ (s >> 7)) & mask) as usize
}

fn alloc_cache(n: usize) -> *mut Cache {
    let bytes = 16 + n * 16;
    let c = unsafe { sys::calloc(1, bytes) } as *mut Cache;
    if c.is_null() {
        crate::util::fatal_str("out of memory for a method cache");
    }
    unsafe { (*c).mask = (n - 1) as u64 };
    c
}

#[inline(always)]
unsafe fn bucket(c: *mut Cache, i: usize) -> *mut Bucket {
    (core::ptr::addr_of_mut!((*c).buckets) as *mut Bucket).add(i)
}

fn retire(c: *mut Cache) {
    if c == empty() {
        return;
    }
    unsafe {
        GARBAGE_BYTES.fetch_add(16 + ((*c).mask as usize + 1) * 16, Ordering::Relaxed);
        GARBAGE.get().push(c);
    }
}

#[inline(always)]
fn cache_slot(cls: Class) -> &'static AtomicPtr<Cache> {
    unsafe { &*(core::ptr::addr_of_mut!((*cls).cache) as *const AtomicPtr<Cache>) }
}

/// Inserts `sel` → `imp` into `cls`'s cache. Runtime lock held.
pub fn fill(cls: Class, sel: Sel, imp: Imp) {
    let slot = cache_slot(cls);
    let c = slot.load(Ordering::Relaxed);
    unsafe {
        if c == empty() {
            let nc = alloc_cache(FIRST_BUCKETS);
            insert(nc, sel, imp);
            slot.store(nc, Ordering::Release);
            return;
        }
        // One probe: present (another thread filled it) or the free bucket.
        let mask = (*c).mask as usize;
        let mut i = index(sel, mask as u64);
        let free = loop {
            let b = bucket(c, i);
            let s = (*b).sel.load(Ordering::Relaxed);
            if s == sel as usize {
                return;
            }
            if s == 0 {
                break b;
            }
            i = (i + 1) & mask;
        };
        let cap = mask + 1;
        if ((*c).occupied as usize + 1) * 4 <= cap * 3 {
            (*free).imp.store(imp as usize, Ordering::Relaxed);
            (*free).sel.store(sel as usize, Ordering::Release);
            (*c).occupied += 1;
            return;
        }
        // Grow into a new cache and publish it (filled buckets never change).
        let n = if cap >= MAX_BUCKETS { cap } else { cap * 2 };
        let nc = alloc_cache(n);
        if cap < MAX_BUCKETS {
            for j in 0..cap {
                let b = bucket(c, j);
                let s = (*b).sel.load(Ordering::Relaxed);
                if s != 0 {
                    insert(nc, s as Sel, (*b).imp.load(Ordering::Relaxed) as Imp);
                }
            }
        }
        insert(nc, sel, imp);
        slot.store(nc, Ordering::Release);
        retire(c);
    }
}

/// Fills an empty bucket: IMP first, then the SEL with release ordering.
unsafe fn insert(c: *mut Cache, sel: Sel, imp: Imp) {
    let mask = (*c).mask;
    let mut i = index(sel, mask);
    loop {
        let b = bucket(c, i);
        let s = (*b).sel.load(Ordering::Relaxed);
        if s == 0 {
            (*b).imp.store(imp as usize, Ordering::Relaxed);
            (*b).sel.store(sel as usize, Ordering::Release);
            (*c).occupied += 1;
            return;
        }
        if s == sel as usize {
            return;
        }
        i = (i + 1) & mask as usize;
    }
}

/// Points `cls` back at the empty cache. Runtime lock held.
pub fn flush(cls: Class) {
    let slot = cache_slot(cls);
    let c = slot.load(Ordering::Relaxed);
    if c != empty() {
        slot.store(empty(), Ordering::Release);
        retire(c);
    }
}

/// A cached IMP, or null (used by lock-free lookups in the runtime itself).
pub fn probe(cls: Class, sel: Sel) -> Imp {
    let c = cache_slot(cls).load(Ordering::Acquire);
    unsafe {
        let mask = (*c).mask;
        let mut i = index(sel, mask);
        loop {
            let b = bucket(c, i);
            let s = (*b).sel.load(Ordering::Acquire);
            if s == sel as usize {
                return (*b).imp.load(Ordering::Relaxed) as Imp;
            }
            if s == 0 {
                return core::ptr::null();
            }
            i = (i + 1) & mask as usize;
        }
    }
}

/// Bytes held by replaced caches (for diagnostics).
pub fn garbage_bytes() -> usize {
    GARBAGE_BYTES.load(Ordering::Relaxed)
}

#[allow(dead_code)]
pub fn free_cache(c: *mut Cache) {
    unsafe { sys::free(c as *mut c_void) }
}
