//! Classes: realization, method tables, lookup, `+initialize`, categories
//! (objc-runtime.md §4).

use crate::abi::*;
use crate::cache;
use crate::map::{PtrMap, StrMap};
use crate::sel;
use crate::sys;
use crate::util::{fatal, FastLock, Global, Msg};
use alloc::boxed::Box;
use alloc::vec::Vec;
use core::ffi::{c_char, c_void};
use core::sync::atomic::{AtomicUsize, Ordering};

// Fast flags in class word 3 (§4.1).
pub const F_REALIZED: usize = 1 << 0;
pub const F_INITIALIZED: usize = 1 << 1;
pub const F_INITIALIZING: usize = 1 << 2;
pub const F_META: usize = 1 << 3;
pub const F_CUSTOM_RR: usize = 1 << 4;
pub const F_CUSTOM_AWZ: usize = 1 << 5;
pub const F_CUSTOM_CORE: usize = 1 << 6;
pub const F_HAS_CXX_DTOR: usize = 1 << 7;
pub const F_HAS_CXX_CTOR: usize = 1 << 8;
pub const F_ROOT: usize = 1 << 9;
pub const F_PLAIN_ISA: usize = 1 << 10;
pub const F_CONSTRUCTING: usize = 1 << 11;
/// The class overrides `-init` / `-dealloc` (else the runtime may skip the message).
pub const F_CUSTOM_INIT: usize = 1 << 12;
pub const F_CUSTOM_DEALLOC: usize = 1 << 13;
pub const F_SIZE_SHIFT: u32 = 32;
const F_DERIVED: usize =
    F_CUSTOM_RR | F_CUSTOM_AWZ | F_CUSTOM_CORE | F_HAS_CXX_DTOR | F_HAS_CXX_CTOR | F_CUSTOM_INIT | F_CUSTOM_DEALLOC;

pub const ISA_MASK: usize = 0x0000_7FFF_FFFF_FFF8;

/// The `Method` of the API: one Ycode-owned record per method.
#[repr(C)]
pub struct MethodEntry {
    pub name: Sel,
    pub types: *const c_char,
    pub imp: AtomicUsize,
}

/// A category attached to (or waiting for) a class.
#[derive(Clone, Copy)]
pub struct PendingCat {
    pub cat: *const CategoryT,
    pub class_props: bool,
}

/// Runtime-private class data (word 4 after realization).
pub struct ClassRW {
    pub ro: *mut ClassRO,
    pub cls: Class,
    /// For a metaclass, its class; for a class, itself.
    pub nonmeta: Class,
    pub base: Vec<*mut MethodEntry>,
    /// Lists from categories, in attach order.
    pub cats: CatSlices,
    /// `class_addMethod` methods.
    pub added: Vec<*mut MethodEntry>,
    /// (SEL, method) sorted by SEL, first in priority order wins.
    pub sorted: Vec<(Sel, *mut MethodEntry)>,
    pub protocols: Vec<*mut ProtocolT>,
    pub properties: Vec<*mut PropertyT>,
    pub subclasses: Vec<Class>,
    pub init_thread: usize,
    /// Exact instance size (word 3 holds the allocation size).
    pub instance_size: u32,
    pub version: i32,
}

pub static RUNTIME_LOCK: FastLock = FastLock::new();

pub struct Registry {
    pub by_name: StrMap<Class>,
    pub pending: PtrMap<Vec<PendingCat>>,
    pub realized: Vec<Class>,
    pub nsobject: Class,
    pub nsobject_meta: Class,
    /// NSObject's own IMPs for the selectors whose override makes a class custom.
    pub default_imps: Vec<(Sel, Imp)>,
}

pub static REG: Global<Registry> = Global::new(Registry {
    by_name: StrMap::new(),
    pending: PtrMap::new(),
    realized: Vec::new(),
    nsobject: core::ptr::null_mut(),
    nsobject_meta: core::ptr::null_mut(),
    default_imps: Vec::new(),
});

#[inline(always)]
pub fn reg() -> &'static mut Registry {
    unsafe { REG.get() }
}

#[inline(always)]
pub fn fast_word(cls: Class) -> &'static AtomicUsize {
    unsafe { &*(core::ptr::addr_of_mut!((*cls).fast) as *const AtomicUsize) }
}
#[inline(always)]
pub fn fast(cls: Class) -> usize {
    fast_word(cls).load(Ordering::Acquire)
}
#[inline(always)]
pub fn is_realized(cls: Class) -> bool {
    fast(cls) & F_REALIZED != 0
}
#[inline(always)]
pub fn is_meta(cls: Class) -> bool {
    if is_realized(cls) {
        fast(cls) & F_META != 0
    } else {
        unsafe { (*ro_of_unrealized(cls)).flags & RO_META != 0 }
    }
}
#[inline(always)]
pub fn alloc_size(cls: Class) -> usize {
    fast(cls) >> F_SIZE_SHIFT
}

/// `ClassRW` of a realized class.
#[inline(always)]
pub fn rw(cls: Class) -> &'static mut ClassRW {
    unsafe { &mut *(((*cls).bits & !7usize) as *mut ClassRW) }
}
#[inline(always)]
pub fn ro_of_unrealized(cls: Class) -> *mut ClassRO {
    unsafe { ((*cls).bits & !3usize) as *mut ClassRO }
}
/// The `class_ro` of any class.
pub fn ro(cls: Class) -> *mut ClassRO {
    if is_realized(cls) {
        rw(cls).ro
    } else {
        ro_of_unrealized(cls)
    }
}
pub fn name_of(cls: Class) -> *const c_char {
    if cls.is_null() {
        return c"nil".as_ptr();
    }
    let r = ro(cls);
    let name = unsafe { (*r).name };
    if !name.is_null() {
        return name;
    }
    // A Swift generic class instance: named on first request (swift.rs).
    let lazy = crate::swift::lazy_name(cls, r);
    if lazy.is_null() {
        c"".as_ptr()
    } else {
        lazy
    }
}

#[inline(always)]
pub fn object_class(obj: Id) -> Class {
    if (obj as isize) <= 0 {
        if obj.is_null() {
            return core::ptr::null_mut();
        }
        return crate::tagged::class_of(obj as usize);
    }
    unsafe { ((*obj).isa & ISA_MASK) as Class }
}

/// Allocation size from an exact instance size (word-aligned, at least 16).
pub fn rounded_size(exact: u32) -> usize {
    let s = (exact as usize + 7) & !7;
    if s < 16 {
        16
    } else {
        s
    }
}

// ---------------------------------------------------------------------------
// Method lists.

/// Method records live as long as their classes: a bump arena. Runtime
/// lock held.
struct Arena {
    next: *mut MethodEntry,
    left: usize,
}
static ARENA: Global<Arena> = Global::new(Arena { next: core::ptr::null_mut(), left: 0 });
const ARENA_CHUNK: usize = 256;

fn alloc_entries(n: usize) -> *mut MethodEntry {
    let a = unsafe { ARENA.get() };
    if n > a.left {
        let count = if n > ARENA_CHUNK { n } else { ARENA_CHUNK };
        let p = unsafe { sys::malloc(count * core::mem::size_of::<MethodEntry>()) } as *mut MethodEntry;
        if p.is_null() {
            crate::util::fatal_str("out of memory for method records");
        }
        if n > ARENA_CHUNK {
            return p;
        }
        a.next = p;
        a.left = count;
    }
    let p = a.next;
    a.next = unsafe { p.add(n) };
    a.left -= n;
    p
}

/// A run of method records (one compiler method list).
#[derive(Clone, Copy)]
pub struct MethodSlice {
    pub ptr: *mut MethodEntry,
    pub len: usize,
}
impl MethodSlice {
    pub fn iter(&self) -> impl Iterator<Item = *mut MethodEntry> + '_ {
        (0..self.len).map(move |i| unsafe { self.ptr.add(i) })
    }
}

/// A class's category lists, the first four inline (most classes get few
/// categories, and attaching one then allocates nothing).
pub struct CatSlices {
    inline: [MethodSlice; 4],
    n: usize,
    spill: Vec<MethodSlice>,
}
impl CatSlices {
    pub const fn new() -> Self {
        let e = MethodSlice { ptr: core::ptr::null_mut(), len: 0 };
        CatSlices { inline: [e; 4], n: 0, spill: Vec::new() }
    }
    pub fn len(&self) -> usize {
        self.n
    }
    pub fn get(&self, i: usize) -> MethodSlice {
        if i < 4 {
            self.inline[i]
        } else {
            self.spill[i - 4]
        }
    }
    pub fn push(&mut self, m: MethodSlice) {
        if self.n < 4 {
            self.inline[self.n] = m;
        } else {
            self.spill.push(m);
        }
        self.n += 1;
    }
    /// In attach order (`.rev()` for priority order).
    pub fn iter(&self) -> impl DoubleEndedIterator<Item = MethodSlice> + '_ {
        (0..self.n).map(move |i| self.get(i))
    }
}

/// Converts a compiler method list into Ycode records (SELs uniqued).
/// Runtime lock held.
pub fn build_slice(list: *const MethodListHeader) -> MethodSlice {
    let empty = MethodSlice { ptr: core::ptr::null_mut(), len: 0 };
    if list.is_null() {
        return empty;
    }
    unsafe {
        let n = (*list).count();
        if n == 0 {
            return empty;
        }
        let block = alloc_entries(n);
        for i in 0..n {
            let m = (*list).get(i);
            let name = if m.name_is_selref { m.name } else { sel::register(m.name, false) };
            block.add(i).write(MethodEntry { name, types: m.types, imp: AtomicUsize::new(m.imp as usize) });
        }
        MethodSlice { ptr: block, len: n }
    }
}

/// The records of a compiler method list as pointers (base lists).
pub fn build_entries(list: *const MethodListHeader) -> Vec<*mut MethodEntry> {
    build_slice(list).iter().collect()
}

pub fn rebuild_sorted(r: &mut ClassRW) {
    let total = r.base.len() + r.added.len() + r.cats.iter().map(|c| c.len).sum::<usize>();
    // Headroom for a few categories without reallocating.
    let mut all: Vec<(Sel, *mut MethodEntry)> = Vec::with_capacity(total + total / 2 + 8);
    // Priority: categories newest first, then the base list, then added methods.
    for c in r.cats.iter().rev() {
        for m in c.iter() {
            all.push((unsafe { (*m).name }, m));
        }
    }
    for &m in r.base.iter().chain(r.added.iter()) {
        all.push((unsafe { (*m).name }, m));
    }
    // Stable sort keeps priority order among equal SELs; keep the first.
    all.sort_by_key(|&(s, _)| s as usize);
    all.dedup_by_key(|&mut (s, _)| s as usize);
    r.sorted = all;
}

/// The method `sel` defined by `cls` itself (not inherited). Runtime lock held.
#[inline]
pub fn own_method(cls: Class, sel: Sel) -> *mut MethodEntry {
    let s = &rw(cls).sorted;
    match s.binary_search_by_key(&(sel as usize), |&(k, _)| k as usize) {
        Ok(i) => s[i].1,
        Err(_) => core::ptr::null_mut(),
    }
}

/// Searches `cls` and its superclasses. All must be realized.
pub fn lookup_method(mut cls: Class, sel: Sel) -> *mut MethodEntry {
    while !cls.is_null() {
        let m = own_method(cls, sel);
        if !m.is_null() {
            return m;
        }
        cls = unsafe { (*cls).superclass };
    }
    core::ptr::null_mut()
}

pub fn lookup_imp(cls: Class, sel: Sel) -> Imp {
    let m = lookup_method(cls, sel);
    if m.is_null() {
        core::ptr::null()
    } else {
        unsafe { (*m).imp.load(Ordering::Relaxed) as Imp }
    }
}

// ---------------------------------------------------------------------------
// Realization (§4.2).

/// Realizes `cls` (and its superclasses and metaclass). Takes the lock.
#[inline]
pub fn realize(cls: Class) {
    if cls.is_null() || is_realized(cls) {
        return;
    }
    let _g = RUNTIME_LOCK.lock();
    realize_locked(cls);
}

/// Runtime lock held.
pub fn realize_locked(cls: Class) {
    if cls.is_null() || is_realized(cls) {
        return;
    }
    let ro0 = ro_of_unrealized(cls);
    if unsafe { (*ro0).flags } & RO_META != 0 {
        // A metaclass reached directly: realize its class, found by name.
        let name = unsafe { (*ro0).name };
        if let Some(c) = reg().by_name.get(name) {
            if unsafe { (*c).isa } == cls {
                realize_locked(c);
                if is_realized(cls) {
                    return;
                }
            }
        }
        realize_one(cls, core::ptr::null_mut());
        return;
    }
    realize_one(cls, cls);
    let meta = unsafe { (*cls).isa };
    if !is_realized(meta) {
        realize_one(meta, cls);
    } else if rw(meta).nonmeta.is_null() {
        rw(meta).nonmeta = cls;
    }
    attach_pending(cls);
    compute_flags(cls);
    compute_flags(meta);
}

fn realize_one(cls: Class, nonmeta: Class) {
    unsafe {
        let sup = (*cls).superclass;
        if !sup.is_null() && !is_realized(sup) {
            realize_locked(sup);
            if is_realized(cls) {
                return;
            }
        }
        let swift_bits = (*cls).bits & 3;
        let mut ro = ro_of_unrealized(cls);
        // Slide ivars when the superclass grew (non-fragile ivars).
        if !sup.is_null() {
            let super_size = rw(sup).instance_size;
            if (*ro).instance_start < super_size {
                ro = slide_ivars(ro, super_size);
            }
        }
        let meta = (*ro).flags & RO_META != 0;
        let mut r = Box::new(ClassRW {
            ro,
            cls,
            nonmeta,
            base: build_entries((*ro).base_methods),
            cats: CatSlices::new(),
            added: Vec::new(),
            sorted: Vec::new(),
            protocols: Vec::new(),
            properties: Vec::new(),
            subclasses: Vec::new(),
            init_thread: 0,
            instance_size: (*ro).instance_size,
            version: if meta { 7 } else { 0 },
        });
        let bp = (*ro).base_protocols;
        if !bp.is_null() {
            for i in 0..(*bp).count {
                r.protocols.push(crate::protocol::canonical((*bp).get(i)));
            }
        }
        let props = (*ro).base_properties;
        if !props.is_null() {
            for i in 0..(*props).count as usize {
                r.properties.push((*props).get(i));
            }
        }
        rebuild_sorted(&mut r);
        let mut f = F_REALIZED | (rounded_size(r.instance_size) << F_SIZE_SHIFT);
        if meta {
            f |= F_META;
        }
        if (*ro).flags & RO_ROOT != 0 {
            f |= F_ROOT;
        }
        if (cls as usize) & !ISA_MASK != 0 {
            f |= F_PLAIN_ISA;
        }
        let rp = Box::into_raw(r);
        (*cls).bits = rp as usize | swift_bits;
        if (*cls).cache.is_null() {
            (*cls).cache = cache::empty();
        }
        if !sup.is_null() {
            rw(sup).subclasses.push(cls);
        }
        reg().realized.push(cls);
        fast_word(cls).store(f, Ordering::Release);
    }
}

/// Attaches the categories that arrived before `cls` was realized (both
/// halves). Runtime lock held; `cls` and its metaclass are realized.
fn attach_pending(cls: Class) {
    let Some(pend) = reg().pending.remove(cls as usize) else { return };
    let r = rw(cls);
    let mr = rw(unsafe { (*cls).isa });
    for p in pend.iter() {
        attach_to_rw(r, p, false);
        attach_to_rw(mr, p, true);
    }
    rebuild_sorted(r);
    rebuild_sorted(mr);
}

fn slide_ivars(ro: *mut ClassRO, super_size: u32) -> *mut ClassRO {
    unsafe {
        let copy = Box::into_raw(Box::new(*ro));
        let ivars = (*ro).ivars;
        let mut align: u32 = 1;
        if !ivars.is_null() {
            for i in 0..(*ivars).count as usize {
                let iv = (*ivars).get(i);
                let a = if (*iv).alignment_log2 == u32::MAX { 8 } else { 1u32 << (*iv).alignment_log2 };
                if a > align {
                    align = a;
                }
            }
        }
        let mut diff = super_size - (*ro).instance_start;
        diff = (diff + align - 1) & !(align - 1);
        if !ivars.is_null() {
            for i in 0..(*ivars).count as usize {
                let iv = (*ivars).get(i);
                if !(*iv).offset.is_null() {
                    *(*iv).offset += diff;
                }
            }
        }
        (*copy).instance_start += diff;
        (*copy).instance_size += diff;
        copy
    }
}

/// Adds one category's methods, protocols and properties to `r` (does not
/// rebuild the sorted table).
fn attach_to_rw(r: &mut ClassRW, p: &PendingCat, class_side: bool) {
    unsafe {
        let c = p.cat;
        let list = if class_side { (*c).class_methods } else { (*c).instance_methods };
        let entries = build_slice(list);
        if entries.len != 0 {
            r.cats.push(entries);
        }
    }
    attach_extras(r, p, class_side);
}

/// A category's protocols and properties.
fn attach_extras(r: &mut ClassRW, p: &PendingCat, class_side: bool) {
    unsafe {
        let c = p.cat;
        if !class_side {
            let pl = (*c).protocols;
            if !pl.is_null() {
                for i in 0..(*pl).count {
                    r.protocols.push(crate::protocol::canonical((*pl).get(i)));
                }
            }
        }
        let props = if class_side {
            if p.class_props {
                (*c).class_properties
            } else {
                core::ptr::null()
            }
        } else {
            (*c).instance_properties
        };
        if !props.is_null() {
            for i in 0..(*props).count as usize {
                r.properties.push((*props).get(i));
            }
        }
    }
}

/// Attaches a category from an image. Runtime lock held.
pub fn add_category(p: PendingCat) {
    let cls = unsafe { (*p.cat).cls };
    if cls.is_null() {
        return;
    }
    if !is_realized(cls) {
        reg().pending.entry(cls as usize, Vec::new).push(p);
        return;
    }
    let meta = unsafe { (*cls).isa };
    let (ni, si) = attach_merged(rw(cls), &p, false);
    let (nc, sc) = attach_merged(rw(meta), &p, true);
    if ni.len != 0 {
        if si {
            methods_changed(cls);
        } else {
            flush_holding(cls, ni);
        }
    }
    if nc.len != 0 {
        if sc {
            methods_changed(meta);
            compute_flags(cls);
        } else {
            flush_holding(meta, nc);
        }
    }
}

/// Attaches one half of a category and merges its methods into the
/// sorted table in place (the category wins over existing entries).
/// Returns the new records (empty if none) and whether any of them
/// affects the class flags.
fn attach_merged(r: &mut ClassRW, p: &PendingCat, class_side: bool) -> (MethodSlice, bool) {
    let before = r.cats.len();
    attach_to_rw(r, p, class_side);
    if r.cats.len() == before {
        return (MethodSlice { ptr: core::ptr::null_mut(), len: 0 }, false);
    }
    let added = r.cats.get(before);
    let mut special = false;
    let mut ins: [(Sel, *mut MethodEntry); 32] = [(core::ptr::null(), core::ptr::null_mut()); 32];
    let mut heap: Vec<(Sel, *mut MethodEntry)> = Vec::new();
    let mut n = 0usize;
    for m in added.iter() {
        let s = unsafe { (*m).name };
        special |= is_special(s);
        match r.sorted.binary_search_by_key(&(s as usize), |&(k, _)| k as usize) {
            Ok(i) => r.sorted[i].1 = m,
            Err(_) => {
                // A SEL repeated inside the list: the first entry wins.
                let dup = ins[..n].iter().chain(heap.iter()).any(|&(k, _)| k == s);
                if !dup {
                    if n < ins.len() {
                        ins[n] = (s, m);
                        n += 1;
                    } else {
                        heap.push((s, m));
                    }
                }
            }
        }
    }
    let add: &mut [(Sel, *mut MethodEntry)] = if heap.is_empty() {
        &mut ins[..n]
    } else {
        heap.extend_from_slice(&ins[..n]);
        &mut heap[..]
    };
    add.sort_unstable_by_key(|&(s, _)| s as usize);
    let k = add.len();
    if k > 0 {
        let old = r.sorted.len();
        r.sorted.reserve(k); // doubles when full
        r.sorted.resize(old + k, (core::ptr::null(), core::ptr::null_mut()));
        let (mut i, mut j, mut w) = (old, k, old + k);
        while j > 0 {
            if i > 0 && (r.sorted[i - 1].0 as usize) > (add[j - 1].0 as usize) {
                r.sorted[w - 1] = r.sorted[i - 1];
                i -= 1;
            } else {
                r.sorted[w - 1] = add[j - 1];
                j -= 1;
            }
            w -= 1;
        }
    }
    (added, special)
}

/// Flushes the caches in `cls`'s subtree that hold any of `added`'s
/// selectors (a cache without them cannot return a stale IMP).
fn flush_holding(cls: Class, added: MethodSlice) {
    let holds = |c: Class| added.iter().any(|m| !cache::probe(c, unsafe { (*m).name }).is_null());
    if rw(cls).subclasses.is_empty() {
        if holds(cls) {
            cache::flush(cls);
        }
        return;
    }
    let mut stack: Vec<Class> = alloc::vec![cls];
    while let Some(c) = stack.pop() {
        if added.iter().any(|m| !cache::probe(c, unsafe { (*m).name }).is_null()) {
            cache::flush(c);
        }
        stack.extend_from_slice(&rw(c).subclasses);
    }
}

/// Selectors whose definition changes a class's fast flags.
#[inline]
fn is_special(s: Sel) -> bool {
    // A one-word filter first: most selectors are rejected by one test.
    if SPECIAL_FILTER.load(Ordering::Relaxed) & filter_bit(s) == 0 {
        return false;
    }
    special_list().contains(&s)
}

static SPECIAL_FILTER: AtomicUsize = AtomicUsize::new(0);

#[inline(always)]
fn filter_bit(s: Sel) -> usize {
    1usize << ((s as usize >> 3) & 63)
}

/// Sets up the filter (after the built-in selectors are registered).
pub fn init_special_filter() {
    let mut f = 0;
    for s in special_list() {
        f |= filter_bit(s);
    }
    SPECIAL_FILTER.store(f, Ordering::Relaxed);
}

fn special_list() -> [Sel; 19] {
    let b = sel::b();
    [
        b.retain,
        b.release,
        b.autorelease,
        b.retain_count,
        b.try_retain,
        b.is_deallocating,
        b.allows_weak_reference,
        b.retain_weak_reference,
        b.alloc,
        b.alloc_with_zone,
        b.new,
        b.self_,
        b.class,
        b.is_kind_of_class,
        b.responds_to_selector,
        b.init,
        b.dealloc,
        b.cxx_construct,
        b.cxx_destruct,
    ]
}


/// After a class's methods change: flush its and its subclasses' caches
/// and recompute their flags. Runtime lock held.
pub fn methods_changed(cls: Class) {
    let mut stack: Vec<Class> = alloc::vec![cls];
    while let Some(c) = stack.pop() {
        cache::flush(c);
        compute_flags(c);
        for &s in rw(c).subclasses.iter() {
            stack.push(s);
        }
    }
}

/// Flushes every cache and recomputes every class's flags (an IMP changed
/// somewhere: method_setImplementation and friends). Runtime lock held.
/// The realized list has superclasses before subclasses.
pub fn all_methods_changed() {
    for &c in reg().realized.iter() {
        cache::flush(c);
        compute_flags(c);
    }
}

fn defines_any(cls: Class, sels: &[Sel]) -> bool {
    sels.iter().any(|&s| !own_method(cls, s).is_null())
}

/// The `CUSTOM_*`/`HAS_CXX_*` flags of `cls` (§4.2 step 6). Runtime lock held.
pub fn compute_flags(cls: Class) {
    if !is_realized(cls) {
        return;
    }
    let b = sel::b();
    let reg = reg();
    let meta = fast(cls) & F_META != 0;
    let sup = unsafe { (*cls).superclass };
    let inherited = if sup.is_null() || !is_realized(sup) { 0 } else { fast(sup) & F_DERIVED };
    let mut f = 0usize;
    let is_ns = cls == reg.nsobject || cls == reg.nsobject_meta;
    let rr = [
        b.retain,
        b.release,
        b.autorelease,
        b.retain_count,
        b.try_retain,
        b.is_deallocating,
        b.allows_weak_reference,
        b.retain_weak_reference,
    ];
    let core_i = [b.self_, b.class, b.is_kind_of_class, b.responds_to_selector];
    let core_c = [b.new, b.self_, b.class, b.is_kind_of_class, b.responds_to_selector];
    if meta {
        // Class-side core methods: kept in the metaclass's word.
        if (sup.is_null() || !is_realized(sup) || fast(sup) & F_META == 0) && !is_ns {
            // The root metaclass's superclass is the root class: only its own methods count.
        } else if inherited & F_CUSTOM_CORE != 0 {
            f |= F_CUSTOM_CORE;
        }
        if !is_ns && defines_any(cls, &core_c) {
            f |= F_CUSTOM_CORE;
        }
        f |= inherited & F_CUSTOM_RR;
    } else {
        f |= inherited & (F_CUSTOM_RR | F_CUSTOM_AWZ | F_CUSTOM_CORE | F_CUSTOM_INIT | F_CUSTOM_DEALLOC);
        if !is_ns {
            if !own_method(cls, b.init).is_null() {
                f |= F_CUSTOM_INIT;
            }
            if !own_method(cls, b.dealloc).is_null() {
                f |= F_CUSTOM_DEALLOC;
            }
            if defines_any(cls, &rr) {
                f |= F_CUSTOM_RR;
            }
            if defines_any(cls, &core_i) {
                f |= F_CUSTOM_CORE;
            }
            let m = unsafe { (*cls).isa };
            if is_realized(m) && defines_any(m, &[b.alloc, b.alloc_with_zone]) {
                f |= F_CUSTOM_AWZ;
            }
        }
        f |= inherited & (F_HAS_CXX_CTOR | F_HAS_CXX_DTOR);
        if !own_method(cls, b.cxx_destruct).is_null() {
            f |= F_HAS_CXX_DTOR;
        }
        if !own_method(cls, b.cxx_construct).is_null() {
            f |= F_HAS_CXX_CTOR;
        }
    }
    let w = fast_word(cls);
    let old = w.load(Ordering::Relaxed);
    w.store((old & !F_DERIVED) | f, Ordering::Release);
    // A metaclass's alloc override shows on its class's word.
    if meta {
        let nm = rw(cls).nonmeta;
        if !nm.is_null() && nm != cls && is_realized(nm) && !is_ns {
            let wn = fast_word(nm);
            let o = wn.load(Ordering::Relaxed);
            let sup_n = unsafe { (*nm).superclass };
            let mut awz = 0;
            if !sup_n.is_null() && is_realized(sup_n) {
                awz = fast(sup_n) & F_CUSTOM_AWZ;
            }
            if defines_any(cls, &[b.alloc, b.alloc_with_zone]) {
                awz = F_CUSTOM_AWZ;
            }
            wn.store((o & !F_CUSTOM_AWZ) | awz, Ordering::Release);
        }
    }
}

// ---------------------------------------------------------------------------
// +initialize (§4.5).

static mut INIT_MUTEX: sys::pthread_mutex_t =
    sys::pthread_mutex_t { sig: sys::PTHREAD_MUTEX_SIG_INIT, opaque: [0; 56] };
static mut INIT_COND: sys::pthread_cond_t = sys::pthread_cond_t { sig: sys::PTHREAD_COND_SIG_INIT, opaque: [0; 40] };

#[inline(always)]
pub fn is_initialized(cls: Class) -> bool {
    fast(cls) & F_INITIALIZED != 0
}

fn set_init_bits(cls: Class, set: usize, clear: usize) {
    let w = fast_word(cls);
    let mut o = w.load(Ordering::Relaxed);
    loop {
        match w.compare_exchange_weak(o, (o & !clear) | set, Ordering::AcqRel, Ordering::Relaxed) {
            Ok(_) => return,
            Err(x) => o = x,
        }
    }
}

/// Runs `+initialize` for `cls` (a class, not a metaclass) if needed.
pub fn initialize(cls: Class) {
    if cls.is_null() || is_initialized(cls) {
        return;
    }
    realize(cls);
    let sup = unsafe { (*cls).superclass };
    if !sup.is_null() && !is_initialized(sup) {
        initialize(sup);
    }
    let me = unsafe { sys::pthread_self() } as usize;
    unsafe {
        let m = core::ptr::addr_of_mut!(INIT_MUTEX);
        let c = core::ptr::addr_of_mut!(INIT_COND);
        sys::pthread_mutex_lock(m);
        loop {
            let f = fast(cls);
            if f & F_INITIALIZED != 0 {
                sys::pthread_mutex_unlock(m);
                return;
            }
            if f & F_INITIALIZING != 0 {
                if rw(cls).init_thread == me {
                    sys::pthread_mutex_unlock(m);
                    return;
                }
                sys::pthread_cond_wait(c, m);
                continue;
            }
            rw(cls).init_thread = me;
            set_init_bits(cls, F_INITIALIZING, 0);
            break;
        }
        sys::pthread_mutex_unlock(m);
        crate::msgsend::send0(cls as Id, sel::b().initialize);
        sys::pthread_mutex_lock(m);
        let meta = (*cls).isa;
        set_init_bits(meta, F_INITIALIZED, 0);
        set_init_bits(cls, F_INITIALIZED, F_INITIALIZING);
        sys::pthread_cond_broadcast(c);
        sys::pthread_mutex_unlock(m);
    }
}

/// Whether the current thread may use `cls` (initialized, or being
/// initialized by this thread).
fn usable(cls: Class) -> bool {
    let f = fast(cls);
    f & F_INITIALIZED != 0
        || (f & F_INITIALIZING != 0 && rw(cls).init_thread == unsafe { sys::pthread_self() } as usize)
}

// ---------------------------------------------------------------------------
// The message slow path (§5.2, §5.4).

/// Called by the assembly slow path with the receiver, the selector and
/// the class whose cache missed. Returns the IMP to jump to.
#[no_mangle]
pub extern "C" fn _ycobjc_lookup(obj: Id, sel: Sel, cls: Class) -> Imp {
    lookup_imp_or_forward(obj, sel, cls, true)
}

pub fn lookup_imp_or_forward(obj: Id, sel: Sel, cls: Class, resolve: bool) -> Imp {
    if cls.is_null() {
        return crate::msgsend::nil_imp();
    }
    if !is_realized(cls) {
        if is_meta(cls) && (obj as isize) > 0 {
            realize(obj as Class);
        }
        realize(cls);
    }
    let nonmeta = {
        let n = rw(cls).nonmeta;
        if n.is_null() {
            cls
        } else {
            n
        }
    };
    if !is_initialized(nonmeta) {
        initialize(nonmeta);
    }
    {
        let _g = RUNTIME_LOCK.lock();
        let m = lookup_method(cls, sel);
        if !m.is_null() {
            let imp = unsafe { (*m).imp.load(Ordering::Relaxed) } as Imp;
            if is_initialized(nonmeta) {
                cache::fill(cls, sel, imp);
            }
            return imp;
        }
    }
    if resolve {
        resolve_method(cls, nonmeta, sel);
        return lookup_imp_or_forward(obj, sel, cls, false);
    }
    let fwd = crate::msgsend::forward_imp();
    if usable(nonmeta) && is_initialized(nonmeta) {
        let _g = RUNTIME_LOCK.lock();
        cache::fill(cls, sel, fwd);
    }
    fwd
}

/// `+resolveInstanceMethod:` / `+resolveClassMethod:`.
fn resolve_method(cls: Class, nonmeta: Class, sel: Sel) {
    let b = sel::b();
    if sel == b.resolve_instance_method || sel == b.resolve_class_method {
        return;
    }
    let which = if fast(cls) & F_META != 0 { b.resolve_class_method } else { b.resolve_instance_method };
    // Only when someone implements it (NSObject's returns NO).
    let meta = unsafe { (*nonmeta).isa };
    let has = {
        let _g = RUNTIME_LOCK.lock();
        !lookup_method(meta, which).is_null()
    };
    if has {
        crate::msgsend::send1(nonmeta as Id, which, sel as usize);
    }
}

/// IMP for `sel` on `cls` without forwarding: null when not found
/// (`class_respondsToSelector`, `respondsToSelector:`).
pub fn lookup_imp_nil(cls: Class, sel: Sel) -> Imp {
    if cls.is_null() {
        return core::ptr::null();
    }
    let c = cache::probe(cls, sel);
    if !c.is_null() {
        return if c == crate::msgsend::forward_imp() { core::ptr::null() } else { c };
    }
    let imp = lookup_imp_or_forward(core::ptr::null_mut(), sel, cls, true);
    if imp == crate::msgsend::forward_imp() {
        core::ptr::null()
    } else {
        imp
    }
}

// ---------------------------------------------------------------------------
// Registry.

/// Adds a class from an image to the name map (first wins). Runtime lock held.
pub fn register_class(cls: Class) {
    let name = unsafe { (*ro(cls)).name };
    if name.is_null() {
        // Lazily named Swift classes are found through the get-class hook.
        return;
    }
    let h = crate::util::hash_cstr(name);
    let (_, existing) = reg().by_name.insert_if_absent(name, h, cls);
    if existing != cls {
        let mut m = Msg::new();
        m.s("objc: Class ").cstr(name).s(" is implemented in two images; using the first (").hex(existing as usize).s(")\n");
        m.print();
    }
}

pub fn class_named(name: *const c_char) -> Class {
    if name.is_null() {
        return core::ptr::null_mut();
    }
    let _g = RUNTIME_LOCK.lock();
    reg().by_name.get(name).unwrap_or(core::ptr::null_mut())
}

/// Reports an unrecoverable class problem.
pub fn class_fatal(what: &str, cls: Class) -> ! {
    let mut m = Msg::new();
    m.s("objc: ").s(what).s(" ").cstr(name_of(cls));
    fatal(&mut m)
}

/// Allocates `n` zeroed bytes that live forever.
pub fn leak_zeroed(n: usize) -> *mut c_void {
    unsafe { sys::calloc(1, n) }
}
