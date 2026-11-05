//! The root classes the runtime provides: `NSObject` (the methods
//! `objc/NSObject.h` declares), `Protocol`, and the block classes
//! (objc-runtime.md §7.3). They are Rust statics in the compiler's class
//! layout (§2.2), so the runtime realizes them like any image's classes.

#![allow(non_upper_case_globals)]

use crate::abi::*;
use crate::api;
use crate::arp;
use crate::cache::Cache;
use crate::class::{self, RUNTIME_LOCK};
use crate::msgsend::{self, send0, send1, send2};
use crate::rr;
use crate::sel;
use core::ffi::{c_char, c_void};
use core::ptr::{addr_of, addr_of_mut, null, null_mut};

/// A static that holds raw pointers.
#[repr(transparent)]
pub struct S<T>(pub T);
unsafe impl<T> Sync for S<T> {}

/// A class object as a static (same layout as `ClassT`, pointer `bits`).
#[repr(C)]
pub struct StaticClass {
    pub isa: *mut StaticClass,
    pub superclass: *mut StaticClass,
    pub cache: *mut Cache,
    pub fast: usize,
    pub bits: *const ClassRO,
}

#[repr(C)]
pub struct MList<const N: usize> {
    pub entsize_flags: u32,
    pub count: u32,
    pub m: [MethodBig; N],
}

macro_rules! m {
    ($name:literal, $types:literal, $f:expr) => {
        MethodBig { name: $name.as_ptr(), types: $types.as_ptr(), imp: $f as *const c_void }
    };
}
macro_rules! mlist {
    ($($e:expr),* $(,)?) => {{
        const N: usize = [$(stringify!($e)),*].len();
        MList::<N> { entsize_flags: 24, count: N as u32, m: [$($e),*] }
    }};
}

const fn ro(flags: u32, start: u32, size: u32, name: &'static core::ffi::CStr, methods: *const MethodListHeader,
    protocols: *const ProtocolList, ivars: *const IvarList) -> ClassRO {
    ClassRO {
        flags,
        instance_start: start,
        instance_size: size,
        reserved: 0,
        ivar_layout: null(),
        name: name.as_ptr(),
        base_methods: methods,
        base_protocols: protocols,
        ivars,
        weak_ivar_layout: null(),
        base_properties: null(),
    }
}

fn empty_cache() -> *mut Cache {
    crate::cache::empty()
}

// ---------------------------------------------------------------------------
// NSObject instance methods.

extern "C" fn i_init(this: Id, _: Sel) -> Id {
    this
}
extern "C" fn i_dealloc(this: Id, _: Sel) {
    rr::_objc_rootDealloc(this)
}
extern "C" fn i_retain(this: Id, _: Sel) -> Id {
    rr::_objc_rootRetain(this)
}
extern "C" fn i_release(this: Id, _: Sel) {
    rr::_objc_rootRelease(this);
}
extern "C" fn i_autorelease(this: Id, _: Sel) -> Id {
    arp::_objc_rootAutorelease(this)
}
extern "C" fn i_retain_count(this: Id, _: Sel) -> usize {
    rr::_objc_rootRetainCount(this)
}
extern "C" fn i_try_retain(this: Id, _: Sel) -> bool {
    rr::_objc_rootTryRetain(this)
}
extern "C" fn i_is_deallocating(this: Id, _: Sel) -> bool {
    rr::_objc_rootIsDeallocating(this)
}
extern "C" fn i_allows_weak(this: Id, _: Sel) -> bool {
    crate::weak::default_allows_weak(this)
}
extern "C" fn i_retain_weak(this: Id, _: Sel) -> bool {
    rr::_objc_rootTryRetain(this)
}
extern "C" fn i_class(this: Id, _: Sel) -> Class {
    class::object_class(this)
}
extern "C" fn i_superclass(this: Id, _: Sel) -> Class {
    api::class_getSuperclass(class::object_class(this))
}
extern "C" fn i_self(this: Id, _: Sel) -> Id {
    this
}
extern "C" fn i_is_equal(this: Id, _: Sel, other: Id) -> bool {
    this == other
}
extern "C" fn i_hash(this: Id, _: Sel) -> usize {
    this as usize
}
extern "C" fn i_is_kind(this: Id, _: Sel, cls: Class) -> bool {
    api::is_kind(class::object_class(this), cls)
}
extern "C" fn i_is_member(this: Id, _: Sel, cls: Class) -> bool {
    class::object_class(this) == cls
}
extern "C" fn i_responds(this: Id, _: Sel, s: Sel) -> bool {
    !s.is_null() && api::class_respondsToSelector(class::object_class(this), s)
}
extern "C" fn i_conforms(this: Id, _: Sel, p: *mut ProtocolT) -> bool {
    conforms_chain(class::object_class(this), p)
}
extern "C" fn i_method_for(this: Id, _: Sel, s: Sel) -> Imp {
    api::class_getMethodImplementation(class::object_class(this), s)
}
extern "C" fn i_does_not_recognize(this: Id, _: Sel, s: Sel) {
    msgsend::unrecognized(this, s, false)
}
extern "C" fn i_forwarding_target(_: Id, _: Sel, _s: Sel) -> Id {
    null_mut()
}
extern "C" fn i_forward_invocation(this: Id, _: Sel, _inv: Id) {
    msgsend::unrecognized(this, c"forwardInvocation:".as_ptr(), false)
}
extern "C" fn i_method_signature(_: Id, _: Sel, _s: Sel) -> Id {
    null_mut()
}
extern "C" fn i_perform0(this: Id, _: Sel, s: Sel) -> Id {
    if s.is_null() {
        msgsend::unrecognized(this, c"performSelector:".as_ptr(), false)
    }
    send0(this, s) as Id
}
extern "C" fn i_perform1(this: Id, _: Sel, s: Sel, a: Id) -> Id {
    send1(this, s, a as usize) as Id
}
extern "C" fn i_perform2(this: Id, _: Sel, s: Sel, a: Id, b: Id) -> Id {
    send2(this, s, a as usize, b as usize) as Id
}
extern "C" fn i_no(_: Id, _: Sel) -> bool {
    false
}
extern "C" fn i_null(_: Id, _: Sel) -> Id {
    null_mut()
}
extern "C" fn i_copy(this: Id, _: Sel) -> Id {
    send1(this, sel::register(c"copyWithZone:".as_ptr(), false), 0) as Id
}
extern "C" fn i_mutable_copy(this: Id, _: Sel) -> Id {
    send1(this, sel::register(c"mutableCopyWithZone:".as_ptr(), false), 0) as Id
}
extern "C" fn i_debug_description(this: Id, _: Sel) -> Id {
    send0(this, sel::register(c"description".as_ptr(), false)) as Id
}

// NSObject class methods.

extern "C" fn c_noop(_: Id, _: Sel) {}
extern "C" fn c_new(this: Id, _: Sel) -> Id {
    let o = send0(this, sel::b().alloc) as Id;
    send0(o, sel::b().init) as Id
}
extern "C" fn c_alloc(this: Id, _: Sel) -> Id {
    rr::_objc_rootAlloc(this as Class)
}
extern "C" fn c_alloc_zone(this: Id, _: Sel, _z: *mut c_void) -> Id {
    rr::_objc_rootAlloc(this as Class)
}
extern "C" fn c_self(this: Id, _: Sel) -> Id {
    this
}
extern "C" fn c_superclass(this: Id, _: Sel) -> Class {
    api::class_getSuperclass(this as Class)
}
extern "C" fn c_is_subclass(this: Id, _: Sel, cls: Class) -> bool {
    api::is_kind(this as Class, cls)
}
extern "C" fn c_instances_respond(this: Id, _: Sel, s: Sel) -> bool {
    !s.is_null() && api::class_respondsToSelector(this as Class, s)
}
extern "C" fn c_conforms(this: Id, _: Sel, p: *mut ProtocolT) -> bool {
    conforms_chain(this as Class, p)
}
extern "C" fn c_instance_method_for(this: Id, _: Sel, s: Sel) -> Imp {
    api::class_getMethodImplementation(this as Class, s)
}
extern "C" fn c_retain(this: Id, _: Sel) -> Id {
    this
}
extern "C" fn c_retain_count(_: Id, _: Sel) -> usize {
    usize::MAX
}
extern "C" fn c_yes(_: Id, _: Sel) -> bool {
    true
}
extern "C" fn c_resolve(_: Id, _: Sel, _s: Sel) -> bool {
    false
}
extern "C" fn c_copy_zone(this: Id, _: Sel, _z: *mut c_void) -> Id {
    this
}

fn conforms_chain(mut cls: Class, p: *mut ProtocolT) -> bool {
    if p.is_null() {
        return false;
    }
    while !cls.is_null() {
        if crate::protocol::class_conformsToProtocol(cls, p) {
            return true;
        }
        cls = unsafe { (*cls).superclass };
    }
    false
}

static NSOBJECT_IMETHODS: S<MList<35>> = S(mlist![
    m!(c"init", c"@16@0:8", i_init),
    m!(c"dealloc", c"v16@0:8", i_dealloc),
    m!(c"retain", c"@16@0:8", i_retain),
    m!(c"release", c"Vv16@0:8", i_release),
    m!(c"autorelease", c"@16@0:8", i_autorelease),
    m!(c"retainCount", c"Q16@0:8", i_retain_count),
    m!(c"_tryRetain", c"B16@0:8", i_try_retain),
    m!(c"_isDeallocating", c"B16@0:8", i_is_deallocating),
    m!(c"allowsWeakReference", c"B16@0:8", i_allows_weak),
    m!(c"retainWeakReference", c"B16@0:8", i_retain_weak),
    m!(c"class", c"#16@0:8", i_class),
    m!(c"superclass", c"#16@0:8", i_superclass),
    m!(c"self", c"@16@0:8", i_self),
    m!(c"isEqual:", c"B24@0:8@16", i_is_equal),
    m!(c"hash", c"Q16@0:8", i_hash),
    m!(c"isKindOfClass:", c"B24@0:8#16", i_is_kind),
    m!(c"isMemberOfClass:", c"B24@0:8#16", i_is_member),
    m!(c"respondsToSelector:", c"B24@0:8:16", i_responds),
    m!(c"conformsToProtocol:", c"B24@0:8@16", i_conforms),
    m!(c"methodForSelector:", c"^?24@0:8:16", i_method_for),
    m!(c"doesNotRecognizeSelector:", c"v24@0:8:16", i_does_not_recognize),
    m!(c"forwardingTargetForSelector:", c"@24@0:8:16", i_forwarding_target),
    m!(c"forwardInvocation:", c"v24@0:8@16", i_forward_invocation),
    m!(c"methodSignatureForSelector:", c"@24@0:8:16", i_method_signature),
    m!(c"performSelector:", c"@24@0:8:16", i_perform0),
    m!(c"performSelector:withObject:", c"@32@0:8:16@24", i_perform1),
    m!(c"performSelector:withObject:withObject:", c"@40@0:8:16@24@32", i_perform2),
    m!(c"isProxy", c"B16@0:8", i_no),
    m!(c"isFault", c"B16@0:8", i_no),
    m!(c"zone", c"^{_NSZone=}16@0:8", i_null),
    m!(c"copy", c"@16@0:8", i_copy),
    m!(c"mutableCopy", c"@16@0:8", i_mutable_copy),
    m!(c"description", c"@16@0:8", i_null),
    m!(c"debugDescription", c"@16@0:8", i_debug_description),
    m!(c"finalize", c"v16@0:8", c_noop),
]);

static NSOBJECT_CMETHODS: S<MList<43>> = S(mlist![
    m!(c"load", c"v16@0:8", c_noop),
    m!(c"initialize", c"v16@0:8", c_noop),
    m!(c"new", c"@16@0:8", c_new),
    m!(c"alloc", c"@16@0:8", c_alloc),
    m!(c"allocWithZone:", c"@24@0:8^{_NSZone=}16", c_alloc_zone),
    m!(c"class", c"#16@0:8", c_self),
    m!(c"superclass", c"#16@0:8", c_superclass),
    m!(c"self", c"@16@0:8", c_self),
    m!(c"isSubclassOfClass:", c"B24@0:8#16", c_is_subclass),
    m!(c"instancesRespondToSelector:", c"B24@0:8:16", c_instances_respond),
    m!(c"conformsToProtocol:", c"B24@0:8@16", c_conforms),
    m!(c"instanceMethodForSelector:", c"^?24@0:8:16", c_instance_method_for),
    m!(c"methodForSelector:", c"^?24@0:8:16", i_method_for),
    m!(c"respondsToSelector:", c"B24@0:8:16", i_responds),
    m!(c"isKindOfClass:", c"B24@0:8#16", i_is_kind),
    m!(c"isMemberOfClass:", c"B24@0:8#16", i_is_member),
    m!(c"isEqual:", c"B24@0:8@16", i_is_equal),
    m!(c"hash", c"Q16@0:8", i_hash),
    m!(c"retain", c"@16@0:8", c_retain),
    m!(c"release", c"Vv16@0:8", c_noop),
    m!(c"autorelease", c"@16@0:8", c_retain),
    m!(c"retainCount", c"Q16@0:8", c_retain_count),
    m!(c"_tryRetain", c"B16@0:8", c_yes),
    m!(c"_isDeallocating", c"B16@0:8", i_no),
    m!(c"allowsWeakReference", c"B16@0:8", c_yes),
    m!(c"retainWeakReference", c"B16@0:8", c_yes),
    m!(c"resolveClassMethod:", c"B24@0:8:16", c_resolve),
    m!(c"resolveInstanceMethod:", c"B24@0:8:16", c_resolve),
    m!(c"copy", c"@16@0:8", c_retain),
    m!(c"mutableCopy", c"@16@0:8", c_retain),
    m!(c"copyWithZone:", c"@24@0:8^{_NSZone=}16", c_copy_zone),
    m!(c"mutableCopyWithZone:", c"@24@0:8^{_NSZone=}16", c_copy_zone),
    m!(c"zone", c"^{_NSZone=}16@0:8", i_null),
    m!(c"isProxy", c"B16@0:8", i_no),
    m!(c"description", c"@16@0:8", i_null),
    m!(c"debugDescription", c"@16@0:8", i_null),
    m!(c"performSelector:", c"@24@0:8:16", i_perform0),
    m!(c"performSelector:withObject:", c"@32@0:8:16@24", i_perform1),
    m!(c"performSelector:withObject:withObject:", c"@40@0:8:16@24@32", i_perform2),
    m!(c"doesNotRecognizeSelector:", c"v24@0:8:16", i_does_not_recognize),
    m!(c"forwardingTargetForSelector:", c"@24@0:8:16", i_forwarding_target),
    m!(c"instanceMethodSignatureForSelector:", c"@24@0:8:16", i_method_signature),
    m!(c"methodSignatureForSelector:", c"@24@0:8:16", i_method_signature),
]);

/// The `NSObject` protocol the class adopts.
static mut PROTO_NSOBJECT: ProtocolT = ProtocolT {
    isa: 0,
    name: c"NSObject".as_ptr(),
    protocols: null(),
    instance_methods: null(),
    class_methods: null(),
    optional_instance_methods: null(),
    optional_class_methods: null(),
    instance_properties: null(),
    size: core::mem::size_of::<ProtocolT>() as u32,
    flags: 0,
    extended_method_types: null(),
    demangled_name: null(),
    class_properties: null(),
};
#[repr(C)]
struct PList1 {
    count: usize,
    p: [*const ProtocolT; 1],
}
static NSOBJECT_PROTOCOLS: S<PList1> = S(PList1 { count: 1, p: [addr_of_mut!(PROTO_NSOBJECT) as *const ProtocolT] });

static mut NSOBJECT_ISA_OFFSET: u32 = 0;
#[repr(C)]
struct IList1 {
    entsize: u32,
    count: u32,
    i: [IvarT; 1],
}
static NSOBJECT_IVARS: S<IList1> = S(IList1 {
    entsize: core::mem::size_of::<IvarT>() as u32,
    count: 1,
    i: [IvarT {
        offset: addr_of_mut!(NSOBJECT_ISA_OFFSET),
        name: c"isa".as_ptr(),
        types: c"#".as_ptr(),
        alignment_log2: 3,
        size: 8,
    }],
});

static NSOBJECT_RO: S<ClassRO> = S(ro(
    RO_ROOT,
    0,
    8,
    c"NSObject",
    addr_of!(NSOBJECT_IMETHODS) as *const MethodListHeader,
    addr_of!(NSOBJECT_PROTOCOLS) as *const ProtocolList,
    addr_of!(NSOBJECT_IVARS) as *const IvarList,
));
static NSOBJECT_META_RO: S<ClassRO> = S(ro(
    RO_ROOT | RO_META,
    40,
    40,
    c"NSObject",
    addr_of!(NSOBJECT_CMETHODS) as *const MethodListHeader,
    addr_of!(NSOBJECT_PROTOCOLS) as *const ProtocolList,
    null(),
));

#[export_name = "OBJC_CLASS_$_NSObject"]
pub static mut NSOBJECT: StaticClass = StaticClass {
    isa: addr_of_mut!(NSOBJECT_META),
    superclass: null_mut(),
    cache: null_mut(),
    fast: 0,
    bits: addr_of!(NSOBJECT_RO) as *const ClassRO,
};
#[export_name = "OBJC_METACLASS_$_NSObject"]
pub static mut NSOBJECT_META: StaticClass = StaticClass {
    isa: addr_of_mut!(NSOBJECT_META),
    superclass: addr_of_mut!(NSOBJECT),
    cache: null_mut(),
    fast: 0,
    bits: addr_of!(NSOBJECT_META_RO) as *const ClassRO,
};

// ---------------------------------------------------------------------------
// Protocol.

extern "C" fn p_name(this: Id, _: Sel) -> *const c_char {
    crate::protocol::protocol_getName(this as *mut ProtocolT)
}
extern "C" fn p_conforms_to(this: Id, _: Sel, other: *mut ProtocolT) -> bool {
    crate::protocol::includes(this as *mut ProtocolT, other, 0)
}
extern "C" fn p_is_equal(this: Id, _: Sel, other: Id) -> bool {
    crate::protocol::protocol_isEqual(this as *mut ProtocolT, other as *mut ProtocolT)
}
extern "C" fn p_hash(this: Id, _: Sel) -> usize {
    crate::util::hash_cstr(crate::protocol::protocol_getName(this as *mut ProtocolT)) as usize
}

static PROTOCOL_IMETHODS: S<MList<9>> = S(mlist![
    m!(c"retain", c"@16@0:8", c_retain),
    m!(c"release", c"Vv16@0:8", c_noop),
    m!(c"autorelease", c"@16@0:8", c_retain),
    m!(c"retainCount", c"Q16@0:8", c_retain_count),
    m!(c"name", c"r*16@0:8", p_name),
    m!(c"conformsTo:", c"B24@0:8@16", p_conforms_to),
    m!(c"isEqual:", c"B24@0:8@16", p_is_equal),
    m!(c"hash", c"Q16@0:8", p_hash),
    m!(c"copy", c"@16@0:8", c_retain),
]);
static PROTOCOL_RO: S<ClassRO> = S(ro(0, 8, 8, c"Protocol", addr_of!(PROTOCOL_IMETHODS) as *const MethodListHeader, null(), null()));
static PROTOCOL_META_RO: S<ClassRO> = S(ro(RO_META, 40, 40, c"Protocol", null(), null(), null()));

#[export_name = "OBJC_CLASS_$_Protocol"]
pub static mut PROTOCOL: StaticClass = StaticClass {
    isa: addr_of_mut!(PROTOCOL_META),
    superclass: addr_of_mut!(NSOBJECT),
    cache: null_mut(),
    fast: 0,
    bits: addr_of!(PROTOCOL_RO) as *const ClassRO,
};
#[export_name = "OBJC_METACLASS_$_Protocol"]
pub static mut PROTOCOL_META: StaticClass = StaticClass {
    isa: addr_of_mut!(NSOBJECT_META),
    superclass: addr_of_mut!(NSOBJECT_META),
    cache: null_mut(),
    fast: 0,
    bits: addr_of!(PROTOCOL_META_RO) as *const ClassRO,
};

pub fn nsobject() -> Class {
    addr_of_mut!(NSOBJECT) as Class
}
pub fn protocol_class() -> Class {
    addr_of_mut!(PROTOCOL) as Class
}

/// NSObject's own `forwardingTargetForSelector:` IMP (instance or class side).
pub fn default_forwarding_target_imp(_class_side: bool) -> Imp {
    i_forwarding_target as Imp
}

// ---------------------------------------------------------------------------
// Block classes (§7.3).

#[cfg(not(feature = "host-bench"))]
mod blocks {
    use super::*;

    extern "C" fn b_copy(this: Id, _: Sel) -> Id {
        unsafe { crate::sys::_Block_copy(this as *const c_void) as Id }
    }
    extern "C" fn b_copy_zone(this: Id, _: Sel, _z: *mut c_void) -> Id {
        unsafe { crate::sys::_Block_copy(this as *const c_void) as Id }
    }
    extern "C" fn b_release(this: Id, _: Sel) {
        unsafe { crate::sys::_Block_release(this as *const c_void) }
    }
    extern "C" fn b_self(this: Id, _: Sel) -> Id {
        this
    }
    extern "C" fn b_count(_: Id, _: Sel) -> usize {
        1
    }

    // Malloc blocks count through _Block_copy/_Block_release.
    pub static MALLOC_METHODS: S<MList<6>> = S(mlist![
        m!(c"retain", c"@16@0:8", b_copy),
        m!(c"release", c"Vv16@0:8", b_release),
        m!(c"copy", c"@16@0:8", b_copy),
        m!(c"copyWithZone:", c"@24@0:8^{_NSZone=}16", b_copy_zone),
        m!(c"retainCount", c"Q16@0:8", b_count),
        m!(c"dealloc", c"v16@0:8", c_noop),
    ]);
    // Stack and global blocks are not counted; copying a stack block moves it to the heap.
    pub static STACK_METHODS: S<MList<6>> = S(mlist![
        m!(c"retain", c"@16@0:8", b_self),
        m!(c"release", c"Vv16@0:8", c_noop),
        m!(c"copy", c"@16@0:8", b_copy),
        m!(c"copyWithZone:", c"@24@0:8^{_NSZone=}16", b_copy_zone),
        m!(c"retainCount", c"Q16@0:8", b_count),
        m!(c"dealloc", c"v16@0:8", c_noop),
    ]);
    pub static GLOBAL_METHODS: S<MList<7>> = S(mlist![
        m!(c"retain", c"@16@0:8", b_self),
        m!(c"release", c"Vv16@0:8", c_noop),
        m!(c"autorelease", c"@16@0:8", b_self),
        m!(c"copy", c"@16@0:8", b_self),
        m!(c"copyWithZone:", c"@24@0:8^{_NSZone=}16", b_self_zone),
        m!(c"retainCount", c"Q16@0:8", b_count),
        m!(c"dealloc", c"v16@0:8", c_noop),
    ]);
    extern "C" fn b_self_zone(this: Id, _: Sel, _z: *mut c_void) -> Id {
        this
    }

    /// Turns libSystem's block class arrays into classes.
    pub fn install() {
        let defs: [(&core::ffi::CStr, &core::ffi::CStr, *const MethodListHeader); 3] = [
            (c"_NSConcreteStackBlock", c"__NSStackBlock__", addr_of!(STACK_METHODS) as *const MethodListHeader),
            (c"_NSConcreteMallocBlock", c"__NSMallocBlock__", addr_of!(MALLOC_METHODS) as *const MethodListHeader),
            (c"_NSConcreteGlobalBlock", c"__NSGlobalBlock__", addr_of!(GLOBAL_METHODS) as *const MethodListHeader),
        ];
        for (sym, name, methods) in defs {
            let p = unsafe { crate::sys::dlsym(crate::sys::RTLD_DEFAULT, sym.as_ptr()) } as *mut StaticClass;
            if p.is_null() {
                continue;
            }
            unsafe {
                let cro = alloc::boxed::Box::into_raw(alloc::boxed::Box::new(ro(0, 8, 8, name, methods, null(), null())));
                let mro = alloc::boxed::Box::into_raw(alloc::boxed::Box::new(ro(RO_META, 40, 40, name, null(), null(), null())));
                let meta = alloc::boxed::Box::into_raw(alloc::boxed::Box::new(StaticClass {
                    isa: addr_of_mut!(NSOBJECT_META),
                    superclass: addr_of_mut!(NSOBJECT_META),
                    cache: empty_cache(),
                    fast: 0,
                    bits: mro,
                }));
                p.write(StaticClass { isa: meta, superclass: addr_of_mut!(NSOBJECT), cache: empty_cache(), fast: 0, bits: cro });
                let _g = RUNTIME_LOCK.lock();
                class::register_class(p as Class);
                class::realize_locked(p as Class);
            }
        }
    }
}

/// Realizes the built-in classes and registers their names (start-up).
pub fn init() {
    let r = class::reg();
    unsafe {
        let ns = addr_of_mut!(NSOBJECT);
        let nsm = addr_of_mut!(NSOBJECT_META);
        (*ns).cache = empty_cache();
        (*nsm).cache = empty_cache();
        (*addr_of_mut!(PROTOCOL)).cache = empty_cache();
        (*addr_of_mut!(PROTOCOL_META)).cache = empty_cache();
        r.nsobject = ns as Class;
        r.nsobject_meta = nsm as Class;
        let _g = RUNTIME_LOCK.lock();
        crate::protocol::register(addr_of_mut!(PROTO_NSOBJECT));
        class::register_class(ns as Class);
        class::register_class(addr_of_mut!(PROTOCOL) as Class);
        class::realize_locked(ns as Class);
        class::realize_locked(addr_of_mut!(PROTOCOL) as Class);
    }
    // NSObject and Protocol need no +initialize work.
    class::initialize(nsobject());
    class::initialize(protocol_class());
    #[cfg(not(feature = "host-bench"))]
    blocks::install();
}
