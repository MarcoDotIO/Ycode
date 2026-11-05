//! Selectors (objc-runtime.md §4.6): a SEL is the address of the first
//! registered copy of its name.

use crate::abi::Sel;
use crate::map::StrMap;
use crate::util::{cstrdup, hash_cstr, Global, Lock};
use core::ffi::c_char;

static SEL_LOCK: Lock = Lock::new();
static SELS: Global<StrMap<()>> = Global::new(StrMap::new());

/// Registers `name`; when `copy` is set and the name is new, the table keeps
/// a heap copy (for names that do not live in an image).
pub fn register(name: *const c_char, copy: bool) -> Sel {
    if name.is_null() {
        return core::ptr::null();
    }
    let h = hash_cstr(name);
    let _g = SEL_LOCK.lock();
    let t = unsafe { SELS.get() };
    if let Some((k, _)) = t.get_key_value(name, h) {
        return k;
    }
    let stored = if copy { cstrdup(name) } else { name };
    t.insert_if_absent(stored, h, ()).0
}

/// Registers every name in a batch under one lock acquisition, rewriting
/// each slot to its SEL (an image's selector references).
///
/// # Safety
/// `refs` points at `count` writable slots holding name pointers.
pub unsafe fn fix_refs(refs: *mut Sel, count: usize) {
    let _g = SEL_LOCK.lock();
    let t = SELS.get();
    for i in 0..count {
        let slot = refs.add(i);
        let name = *slot;
        if name.is_null() {
            continue;
        }
        let h = hash_cstr(name);
        let k = t.insert_if_absent(name, h, ()).0;
        if k != name {
            *slot = k;
        }
    }
}

/// The SEL of `name` if registered.
pub fn lookup(name: *const c_char) -> Option<Sel> {
    if name.is_null() {
        return None;
    }
    let h = hash_cstr(name);
    let _g = SEL_LOCK.lock();
    unsafe { SELS.get() }.get_key_value(name, h).map(|(k, _)| k)
}

/// Selectors the runtime itself uses, registered at start-up.
pub struct Builtins {
    pub alloc: Sel,
    pub alloc_with_zone: Sel,
    pub init: Sel,
    pub new: Sel,
    pub dealloc: Sel,
    pub retain: Sel,
    pub release: Sel,
    pub autorelease: Sel,
    pub retain_count: Sel,
    pub try_retain: Sel,
    pub is_deallocating: Sel,
    pub allows_weak_reference: Sel,
    pub retain_weak_reference: Sel,
    pub initialize: Sel,
    pub load: Sel,
    pub resolve_instance_method: Sel,
    pub resolve_class_method: Sel,
    pub forwarding_target: Sel,
    pub cxx_construct: Sel,
    pub cxx_destruct: Sel,
    pub copy: Sel,
    pub mutable_copy: Sel,
    pub self_: Sel,
    pub class: Sel,
    pub is_kind_of_class: Sel,
    pub responds_to_selector: Sel,
    pub does_not_recognize: Sel,
}

pub static B: Global<Builtins> = Global::new(Builtins {
    alloc: c"alloc".as_ptr(),
    alloc_with_zone: c"allocWithZone:".as_ptr(),
    init: c"init".as_ptr(),
    new: c"new".as_ptr(),
    dealloc: c"dealloc".as_ptr(),
    retain: c"retain".as_ptr(),
    release: c"release".as_ptr(),
    autorelease: c"autorelease".as_ptr(),
    retain_count: c"retainCount".as_ptr(),
    try_retain: c"_tryRetain".as_ptr(),
    is_deallocating: c"_isDeallocating".as_ptr(),
    allows_weak_reference: c"allowsWeakReference".as_ptr(),
    retain_weak_reference: c"retainWeakReference".as_ptr(),
    initialize: c"initialize".as_ptr(),
    load: c"load".as_ptr(),
    resolve_instance_method: c"resolveInstanceMethod:".as_ptr(),
    resolve_class_method: c"resolveClassMethod:".as_ptr(),
    forwarding_target: c"forwardingTargetForSelector:".as_ptr(),
    cxx_construct: c".cxx_construct".as_ptr(),
    cxx_destruct: c".cxx_destruct".as_ptr(),
    copy: c"copy".as_ptr(),
    mutable_copy: c"mutableCopy".as_ptr(),
    self_: c"self".as_ptr(),
    class: c"class".as_ptr(),
    is_kind_of_class: c"isKindOfClass:".as_ptr(),
    responds_to_selector: c"respondsToSelector:".as_ptr(),
    does_not_recognize: c"doesNotRecognizeSelector:".as_ptr(),
});

/// The built-in selectors (valid after `init`).
#[inline(always)]
pub fn b() -> &'static Builtins {
    unsafe { &*B.ptr() }
}

/// Registers the built-in selectors. Their static strings become the SELs,
/// because nothing is registered before this runs.
pub fn init() {
    let b = unsafe { B.get() };
    let fields: [&mut Sel; 27] = [
        &mut b.alloc,
        &mut b.alloc_with_zone,
        &mut b.init,
        &mut b.new,
        &mut b.dealloc,
        &mut b.retain,
        &mut b.release,
        &mut b.autorelease,
        &mut b.retain_count,
        &mut b.try_retain,
        &mut b.is_deallocating,
        &mut b.allows_weak_reference,
        &mut b.retain_weak_reference,
        &mut b.initialize,
        &mut b.load,
        &mut b.resolve_instance_method,
        &mut b.resolve_class_method,
        &mut b.forwarding_target,
        &mut b.cxx_construct,
        &mut b.cxx_destruct,
        &mut b.copy,
        &mut b.mutable_copy,
        &mut b.self_,
        &mut b.class,
        &mut b.is_kind_of_class,
        &mut b.responds_to_selector,
        &mut b.does_not_recognize,
    ];
    for f in fields {
        *f = register(*f, false);
    }
}
