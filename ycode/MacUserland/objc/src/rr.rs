//! Reference counting, allocation and deallocation (objc-runtime.md §3,
//! §6, §7).

use crate::abi::*;
use crate::class::{
    self, fast_word, F_CUSTOM_AWZ, F_CUSTOM_CORE, F_CUSTOM_RR, F_HAS_CXX_CTOR, F_HAS_CXX_DTOR, F_INITIALIZED, F_META,
    F_CUSTOM_DEALLOC, F_CUSTOM_INIT, F_PLAIN_ISA, F_REALIZED, ISA_MASK,
};
use crate::map::PtrMap;
use crate::msgsend::send0;
use crate::sel;
use crate::sys;
use crate::util::{FastLock, Global};
use alloc::vec::Vec;
use core::ffi::c_void;
use core::sync::atomic::{AtomicUsize, Ordering};

// The packed isa (§3).
pub const PACKED: usize = 1;
pub const HAS_ASSOC: usize = 1 << 1;
pub const WEAKLY_REFERENCED: usize = 1 << 47;
pub const DEALLOCATING: usize = 1 << 48;
pub const HAS_SIDETABLE_RC: usize = 1 << 49;
pub const RC_SHIFT: u32 = 50;
pub const RC_ONE: usize = 1 << RC_SHIFT;
pub const RC_MAX: usize = (1 << 14) - 1;
pub const RC_HALF: usize = 1 << 13;
const RC_FIELD: usize = RC_MAX << RC_SHIFT;

/// `objc_debug_isa_class_mask`, for code that inspects isa words.
#[no_mangle]
pub static objc_debug_isa_class_mask: usize = ISA_MASK;

// ---------------------------------------------------------------------------
// The side table (§7.2).

pub struct SideEntry {
    pub extra: usize,
    pub deallocating: bool,
    pub weak: Vec<*mut Id>,
}

#[repr(align(64))]
pub struct Stripe {
    pub lock: FastLock,
    pub map: Global<PtrMap<SideEntry>>,
}
const STRIPES: usize = 64;
static TABLE: [Stripe; STRIPES] = [const { Stripe { lock: FastLock::new(), map: Global::new(PtrMap::new()) } }; STRIPES];

#[inline(always)]
pub fn stripe(obj: Id) -> &'static Stripe {
    let a = obj as usize;
    &TABLE[((a >> 4) ^ (a >> 9)) % STRIPES]
}
#[inline(always)]
pub fn stripe_index(obj: Id) -> usize {
    let a = obj as usize;
    ((a >> 4) ^ (a >> 9)) % STRIPES
}
pub fn stripe_at(i: usize) -> &'static Stripe {
    &TABLE[i]
}
impl Stripe {
    /// The entry for `obj`. Stripe lock held.
    pub fn entry(&self, obj: Id) -> &mut SideEntry {
        unsafe { self.map.get() }.entry(obj as usize, || SideEntry { extra: 0, deallocating: false, weak: Vec::new() })
    }
    pub fn get(&self, obj: Id) -> Option<&mut SideEntry> {
        unsafe { self.map.get() }.get_mut(obj as usize)
    }
    pub fn remove(&self, obj: Id) -> Option<SideEntry> {
        unsafe { self.map.get() }.remove(obj as usize)
    }
}

#[inline(always)]
pub fn isa_word(obj: Id) -> &'static AtomicUsize {
    unsafe { &*(obj as *const AtomicUsize) }
}
#[inline(always)]
fn flags_of(cls: Class) -> usize {
    fast_word(cls).load(Ordering::Relaxed)
}

/// Whether `obj` (plain isa) is a class object: its isa is a metaclass.
#[inline]
fn is_class_object(isa: usize) -> bool {
    let c = (isa & ISA_MASK) as Class;
    !c.is_null() && flags_of(c) & F_META != 0
}

// ---------------------------------------------------------------------------
// Retain.

/// `objc_retain` (assembly fast path in msgsend.rs).
pub fn objc_retain(obj: Id) -> Id {
    unsafe { asm_objc_retain(obj) }
}
/// `objc_release` (assembly fast path in msgsend.rs).
pub fn objc_release(obj: Id) {
    unsafe { asm_objc_release(obj) }
}
extern "C" {
    #[link_name = "objc_retain"]
    fn asm_objc_retain(obj: Id) -> Id;
    #[link_name = "objc_release"]
    fn asm_objc_release(obj: Id);
}

/// The retain slow path: every case the assembly does not handle.
#[no_mangle]
pub extern "C" fn _ycobjc_retain_slow(obj: Id) -> Id {
    if (obj as isize) <= 0 {
        return obj;
    }
    let w = isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    loop {
        if old & PACKED == 0 {
            return retain_plain(obj, old, true);
        }
        if flags_of((old & ISA_MASK) as Class) & F_CUSTOM_RR != 0 {
            return send0(obj, sel::b().retain) as Id;
        }
        let (new, carry) = old.overflowing_add(RC_ONE);
        if carry {
            return retain_overflow(obj);
        }
        match w.compare_exchange_weak(old, new, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return obj,
            Err(x) => old = x,
        }
    }
}

/// `_objc_rootRetain`: the default retain (no custom check).
#[no_mangle]
pub extern "C" fn _objc_rootRetain(obj: Id) -> Id {
    if (obj as isize) <= 0 {
        return obj;
    }
    let w = isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    loop {
        if old & PACKED == 0 {
            return retain_plain(obj, old, false);
        }
        let (new, carry) = old.overflowing_add(RC_ONE);
        if carry {
            return retain_overflow(obj);
        }
        match w.compare_exchange_weak(old, new, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return obj,
            Err(x) => old = x,
        }
    }
}

#[cold]
fn retain_plain(obj: Id, isa: usize, check_custom: bool) -> Id {
    if is_class_object(isa) {
        return obj;
    }
    let c = (isa & ISA_MASK) as Class;
    if check_custom && !c.is_null() && flags_of(c) & F_CUSTOM_RR != 0 {
        return send0(obj, sel::b().retain) as Id;
    }
    let s = stripe(obj);
    let _g = s.lock.lock();
    s.entry(obj).extra += 1;
    obj
}

/// The inline count is full: keep half inline, move the rest to the side table.
#[cold]
fn retain_overflow(obj: Id) -> Id {
    let s = stripe(obj);
    let _g = s.lock.lock();
    let w = isa_word(obj);
    loop {
        let old = w.load(Ordering::Relaxed);
        let rc = old >> RC_SHIFT;
        if rc < RC_MAX {
            if w.compare_exchange_weak(old, old + RC_ONE, Ordering::Relaxed, Ordering::Relaxed).is_ok() {
                return obj;
            }
            continue;
        }
        let new = (old & !RC_FIELD) | (RC_HALF << RC_SHIFT) | HAS_SIDETABLE_RC;
        if w.compare_exchange_weak(old, new, Ordering::Relaxed, Ordering::Relaxed).is_ok() {
            s.entry(obj).extra += RC_MAX + 1 - RC_HALF;
            return obj;
        }
    }
}

/// Retains unless the object is deallocating (weak loads). Stripe lock of
/// `obj` held by the caller.
pub fn try_retain_locked(obj: Id, s: &Stripe) -> bool {
    let w = isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    loop {
        if old & PACKED == 0 {
            if is_class_object(old) {
                return true;
            }
            let e = s.entry(obj);
            if e.deallocating {
                return false;
            }
            e.extra += 1;
            return true;
        }
        if old & DEALLOCATING != 0 {
            return false;
        }
        let (new, carry) = old.overflowing_add(RC_ONE);
        if carry {
            let n = (old & !RC_FIELD) | (RC_HALF << RC_SHIFT) | HAS_SIDETABLE_RC;
            if w.compare_exchange_weak(old, n, Ordering::Relaxed, Ordering::Relaxed).is_ok() {
                s.entry(obj).extra += RC_MAX + 1 - RC_HALF;
                return true;
            }
            old = w.load(Ordering::Relaxed);
            continue;
        }
        match w.compare_exchange_weak(old, new, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return true,
            Err(x) => old = x,
        }
    }
}

// ---------------------------------------------------------------------------
// Release.

/// The release slow path.
#[no_mangle]
pub extern "C" fn _ycobjc_release_slow(obj: Id) {
    if (obj as isize) <= 0 {
        return;
    }
    let w = isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    loop {
        if old & PACKED == 0 {
            return release_plain(obj, old, true);
        }
        if flags_of((old & ISA_MASK) as Class) & F_CUSTOM_RR != 0 {
            send0(obj, sel::b().release);
            return;
        }
        if old & RC_FIELD == 0 {
            return release_underflow(obj);
        }
        match w.compare_exchange_weak(old, old - RC_ONE, Ordering::Release, Ordering::Relaxed) {
            Ok(_) => return,
            Err(x) => old = x,
        }
    }
}

/// `_objc_rootRelease`; returns whether the object began deallocating.
#[no_mangle]
pub extern "C" fn _objc_rootRelease(obj: Id) -> bool {
    if (obj as isize) <= 0 {
        return false;
    }
    let w = isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    loop {
        if old & PACKED == 0 {
            release_plain(obj, old, false);
            return false;
        }
        if old & RC_FIELD == 0 {
            release_underflow(obj);
            return true;
        }
        match w.compare_exchange_weak(old, old - RC_ONE, Ordering::Release, Ordering::Relaxed) {
            Ok(_) => return false,
            Err(x) => old = x,
        }
    }
}

#[cold]
fn release_plain(obj: Id, isa: usize, check_custom: bool) {
    if is_class_object(isa) {
        return;
    }
    let c = (isa & ISA_MASK) as Class;
    if check_custom && !c.is_null() && flags_of(c) & F_CUSTOM_RR != 0 {
        send0(obj, sel::b().release);
        return;
    }
    let s = stripe(obj);
    let dealloc = {
        let _g = s.lock.lock();
        let e = s.entry(obj);
        if e.extra > 0 {
            e.extra -= 1;
            false
        } else if e.deallocating {
            false
        } else {
            e.deallocating = true;
            true
        }
    };
    if dealloc {
        core::sync::atomic::fence(Ordering::Acquire);
        send_dealloc(obj, c);
    }
}

/// The inline count is zero: borrow from the side table or deallocate.
#[cold]
fn release_underflow(obj: Id) {
    let w = isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    if old & HAS_SIDETABLE_RC != 0 {
        let s = stripe(obj);
        let _g = s.lock.lock();
        loop {
            old = w.load(Ordering::Relaxed);
            if old & RC_FIELD != 0 {
                if w.compare_exchange_weak(old, old - RC_ONE, Ordering::Release, Ordering::Relaxed).is_ok() {
                    return;
                }
                continue;
            }
            if old & HAS_SIDETABLE_RC == 0 {
                break;
            }
            let e = s.entry(obj);
            if e.extra == 0 {
                if w.compare_exchange_weak(old, old & !HAS_SIDETABLE_RC, Ordering::Relaxed, Ordering::Relaxed).is_ok() {
                    old &= !HAS_SIDETABLE_RC;
                    break;
                }
                continue;
            }
            let take = if e.extra < RC_HALF { e.extra } else { RC_HALF };
            let left = e.extra - take;
            let mut new = (old & !RC_FIELD) | ((take - 1) << RC_SHIFT);
            if left == 0 {
                new &= !HAS_SIDETABLE_RC;
            }
            if w.compare_exchange_weak(old, new, Ordering::Release, Ordering::Relaxed).is_ok() {
                e.extra = left;
                return;
            }
        }
    }
    // Deallocate: set DEALLOCATING once.
    loop {
        if old & DEALLOCATING != 0 {
            return; // over-release; the object is already going away
        }
        if old & RC_FIELD != 0 {
            match w.compare_exchange_weak(old, old - RC_ONE, Ordering::Release, Ordering::Relaxed) {
                Ok(_) => return,
                Err(x) => {
                    old = x;
                    continue;
                }
            }
        }
        match w.compare_exchange_weak(old, old | DEALLOCATING, Ordering::AcqRel, Ordering::Relaxed) {
            Ok(_) => break,
            Err(x) => old = x,
        }
    }
    send_dealloc(obj, (old & ISA_MASK) as Class);
}

/// `[obj dealloc]`, called directly when the class keeps NSObject's.
#[inline]
fn send_dealloc(obj: Id, cls: Class) {
    if !cls.is_null() && flags_of(cls) & (F_REALIZED | F_CUSTOM_DEALLOC) == F_REALIZED {
        _objc_rootDealloc(obj);
    } else {
        send0(obj, sel::b().dealloc);
    }
}

// ---------------------------------------------------------------------------
// Counts and state.

#[no_mangle]
pub extern "C" fn _objc_rootRetainCount(obj: Id) -> usize {
    if (obj as isize) <= 0 {
        return obj as usize;
    }
    let isa = isa_word(obj).load(Ordering::Relaxed);
    if isa & PACKED == 0 {
        if is_class_object(isa) {
            return usize::MAX;
        }
        let s = stripe(obj);
        let _g = s.lock.lock();
        return 1 + s.get(obj).map(|e| e.extra).unwrap_or(0);
    }
    let mut n = 1 + (isa >> RC_SHIFT);
    if isa & HAS_SIDETABLE_RC != 0 {
        let s = stripe(obj);
        let _g = s.lock.lock();
        n += s.get(obj).map(|e| e.extra).unwrap_or(0);
    }
    n
}

#[no_mangle]
pub extern "C" fn _objc_rootIsDeallocating(obj: Id) -> bool {
    if (obj as isize) <= 0 {
        return false;
    }
    let isa = isa_word(obj).load(Ordering::Relaxed);
    if isa & PACKED != 0 {
        return isa & DEALLOCATING != 0;
    }
    let s = stripe(obj);
    let _g = s.lock.lock();
    s.get(obj).map(|e| e.deallocating).unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn _objc_rootTryRetain(obj: Id) -> bool {
    if (obj as isize) <= 0 {
        return true;
    }
    let s = stripe(obj);
    let _g = s.lock.lock();
    try_retain_locked(obj, s)
}

// ---------------------------------------------------------------------------
// Allocation (§6).

/// Allocates an instance of a realized class.
#[inline]
pub fn root_alloc(cls: Class) -> Id {
    let f = flags_of(cls);
    let size = f >> class::F_SIZE_SHIFT;
    let obj = unsafe { sys::calloc(1, size) } as Id;
    if obj.is_null() {
        return obj;
    }
    let isa = if f & F_PLAIN_ISA != 0 { cls as usize } else { cls as usize | PACKED };
    unsafe { (*obj).isa = isa };
    if f & F_HAS_CXX_CTOR != 0 {
        return call_cxx_construct(obj, cls);
    }
    obj
}

#[cold]
fn call_cxx_construct(obj: Id, cls: Class) -> Id {
    let ctors = collect_structors(cls, sel::b().cxx_construct);
    // Superclass first.
    for &imp in ctors.iter().rev() {
        let f: extern "C" fn(Id, Sel) -> Id = unsafe { core::mem::transmute(imp) };
        if f(obj, sel::b().cxx_construct).is_null() {
            // A constructor failed: destroy what was built and return nil.
            object_dispose(obj);
            return core::ptr::null_mut();
        }
    }
    obj
}

/// The own `.cxx_construct`/`.cxx_destruct` IMPs along the chain, subclass first.
fn collect_structors(cls: Class, s: Sel) -> Vec<Imp> {
    let mut v = Vec::new();
    let _g = class::RUNTIME_LOCK.lock();
    let mut c = cls;
    while !c.is_null() {
        let m = class::own_method(c, s);
        if !m.is_null() {
            v.push(unsafe { (*m).imp.load(Ordering::Relaxed) } as Imp);
        }
        c = unsafe { (*c).superclass };
    }
    v
}

#[inline(always)]
fn alloc_ready(f: usize) -> bool {
    f & (F_REALIZED | F_INITIALIZED | F_CUSTOM_AWZ) == F_REALIZED | F_INITIALIZED
}

#[no_mangle]
pub extern "C" fn objc_alloc(cls: Class) -> Id {
    if cls.is_null() {
        return core::ptr::null_mut();
    }
    if alloc_ready(class::fast(cls)) {
        return root_alloc(cls);
    }
    send0(cls as Id, sel::b().alloc) as Id
}

#[no_mangle]
pub extern "C" fn objc_allocWithZone(cls: Class) -> Id {
    if cls.is_null() {
        return core::ptr::null_mut();
    }
    if alloc_ready(class::fast(cls)) {
        return root_alloc(cls);
    }
    crate::msgsend::send1(cls as Id, sel::b().alloc_with_zone, 0) as Id
}

#[no_mangle]
pub extern "C" fn objc_alloc_init(cls: Class) -> Id {
    if cls.is_null() {
        return core::ptr::null_mut();
    }
    let f = class::fast(cls);
    if alloc_ready(f) && f & F_CUSTOM_INIT == 0 {
        return root_alloc(cls);
    }
    let o = objc_alloc(cls);
    if o.is_null() {
        return o;
    }
    send0(o, sel::b().init) as Id
}

#[no_mangle]
pub extern "C" fn objc_opt_new(cls: Class) -> Id {
    if cls.is_null() {
        return core::ptr::null_mut();
    }
    let f = class::fast(cls);
    let meta = unsafe { (*cls).isa };
    if alloc_ready(f) && flags_of(meta) & F_CUSTOM_CORE == 0 {
        let o = root_alloc(cls);
        if o.is_null() || f & F_CUSTOM_INIT == 0 {
            return o;
        }
        return send0(o, sel::b().init) as Id;
    }
    send0(cls as Id, sel::b().new) as Id
}

#[no_mangle]
pub extern "C" fn _objc_rootAlloc(cls: Class) -> Id {
    class::realize(cls);
    root_alloc(cls)
}
#[no_mangle]
pub extern "C" fn _objc_rootAllocWithZone(cls: Class, _zone: *mut c_void) -> Id {
    class::realize(cls);
    root_alloc(cls)
}
#[no_mangle]
pub extern "C" fn _objc_rootInit(obj: Id) -> Id {
    obj
}

#[no_mangle]
pub extern "C" fn class_createInstance(cls: Class, extra: usize) -> Id {
    if cls.is_null() {
        return core::ptr::null_mut();
    }
    class::realize(cls);
    if extra == 0 {
        return root_alloc(cls);
    }
    let f = flags_of(cls);
    let size = (f >> class::F_SIZE_SHIFT) + extra;
    let obj = unsafe { sys::calloc(1, size) } as Id;
    if obj.is_null() {
        return obj;
    }
    unsafe { (*obj).isa = if f & F_PLAIN_ISA != 0 { cls as usize } else { cls as usize | PACKED } };
    if f & F_HAS_CXX_CTOR != 0 {
        return call_cxx_construct(obj, cls);
    }
    obj
}

/// `objc_constructInstance(cls, bytes)`.
#[no_mangle]
pub extern "C" fn objc_constructInstance(cls: Class, bytes: *mut c_void) -> Id {
    if cls.is_null() || bytes.is_null() {
        return core::ptr::null_mut();
    }
    class::realize(cls);
    let obj = bytes as Id;
    let f = flags_of(cls);
    unsafe { (*obj).isa = if f & F_PLAIN_ISA != 0 { cls as usize } else { cls as usize | PACKED } };
    if f & F_HAS_CXX_CTOR != 0 {
        return call_cxx_construct(obj, cls);
    }
    obj
}

// ---------------------------------------------------------------------------
// Deallocation.

#[no_mangle]
pub extern "C" fn _objc_rootDealloc(obj: Id) {
    if (obj as isize) <= 0 {
        return;
    }
    let isa = isa_word(obj).load(Ordering::Relaxed);
    if isa & PACKED != 0
        && isa & (WEAKLY_REFERENCED | HAS_ASSOC | HAS_SIDETABLE_RC) == 0
        && flags_of((isa & ISA_MASK) as Class) & F_HAS_CXX_DTOR == 0
    {
        unsafe { sys::free(obj as *mut c_void) };
        return;
    }
    object_dispose(obj);
}

#[no_mangle]
pub extern "C" fn object_dispose(obj: Id) -> Id {
    if obj.is_null() {
        return obj;
    }
    objc_destructInstance(obj);
    unsafe { sys::free(obj as *mut c_void) };
    core::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn objc_destructInstance(obj: Id) -> *mut c_void {
    if obj.is_null() {
        return obj as *mut c_void;
    }
    let isa = isa_word(obj).load(Ordering::Relaxed);
    let cls = (isa & ISA_MASK) as Class;
    if !cls.is_null() && flags_of(cls) & F_HAS_CXX_DTOR != 0 {
        for imp in collect_structors(cls, sel::b().cxx_destruct) {
            let f: extern "C" fn(Id, Sel) = unsafe { core::mem::transmute(imp) };
            f(obj, sel::b().cxx_destruct);
        }
    }
    let packed = isa & PACKED != 0;
    if !packed || isa & HAS_ASSOC != 0 {
        crate::assoc::remove_all(obj, false);
    }
    if !packed || isa & (WEAKLY_REFERENCED | HAS_SIDETABLE_RC) != 0 {
        clear_side(obj);
    }
    obj as *mut c_void
}

/// Clears weak variables still pointing at `obj` and drops its side entry.
fn clear_side(obj: Id) {
    let s = stripe(obj);
    let _g = s.lock.lock();
    if let Some(e) = s.remove(obj) {
        for &loc in e.weak.iter() {
            unsafe {
                if *loc == obj {
                    *loc = core::ptr::null_mut();
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Strong-reference helpers.

#[no_mangle]
pub extern "C" fn objc_storeStrong(loc: *mut Id, obj: Id) {
    unsafe {
        let prev = *loc;
        if prev == obj {
            return;
        }
        objc_retain(obj);
        *loc = obj;
        objc_release(prev);
    }
}

#[no_mangle]
pub extern "C" fn objc_retainBlock(block: Id) -> Id {
    if block.is_null() {
        return block;
    }
    unsafe { sys::_Block_copy(block as *const c_void) as Id }
}

#[no_mangle]
pub extern "C" fn objc_retainAutorelease(obj: Id) -> Id {
    crate::arp::objc_autorelease(objc_retain(obj))
}

/// Sets the associated-objects bit in a packed isa.
pub fn set_has_assoc(obj: Id) {
    let w = isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    while old & PACKED != 0 && old & HAS_ASSOC == 0 {
        match w.compare_exchange_weak(old, old | HAS_ASSOC, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return,
            Err(x) => old = x,
        }
    }
}

/// Sets the weakly-referenced bit in a packed isa.
pub fn set_weakly_referenced(obj: Id) {
    let w = isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    while old & PACKED != 0 && old & WEAKLY_REFERENCED == 0 {
        match w.compare_exchange_weak(old, old | WEAKLY_REFERENCED, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return,
            Err(x) => old = x,
        }
    }
}

/// Whether `obj` is being deallocated (stripe lock held for plain isa).
pub fn deallocating_locked(obj: Id, s: &Stripe) -> bool {
    let isa = isa_word(obj).load(Ordering::Relaxed);
    if isa & PACKED != 0 {
        return isa & DEALLOCATING != 0;
    }
    s.get(obj).map(|e| e.deallocating).unwrap_or(false)
}

/// Whether instances of `cls` need messages for retain/release.
#[inline(always)]
pub fn custom_rr(cls: Class) -> bool {
    flags_of(cls) & F_CUSTOM_RR != 0
}

pub fn has_custom_core(cls: Class) -> bool {
    flags_of(cls) & F_CUSTOM_CORE != 0
}
