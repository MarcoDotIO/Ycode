//! The introspection and construction functions of `objc/runtime.h`, and
//! the `objc_opt_*` entry points clang emits.

use crate::abi::*;
use crate::cache;
use crate::class::{
    self, fast, fast_word, is_realized, realize, rw, MethodEntry, F_CONSTRUCTING, F_CUSTOM_CORE, F_INITIALIZED,
    F_META, F_REALIZED, F_SIZE_SHIFT, ISA_MASK, RUNTIME_LOCK,
};
use crate::msgsend::{send0, send1};
use crate::rr;
use crate::sel;
use crate::sys;
use crate::util::{cstrdup, cstreq, cstrlen, fatal, Msg};
use alloc::boxed::Box;
use alloc::vec::Vec;
use core::ffi::{c_char, c_void};
use core::sync::atomic::{AtomicUsize, Ordering};

/// Copies `v` into a `malloc`ed array the caller frees (NULL when empty).
pub fn to_c_array<T: Copy>(v: Vec<T>, out_count: *mut u32) -> *mut T {
    if !out_count.is_null() {
        unsafe { *out_count = v.len() as u32 };
    }
    if v.is_empty() {
        return core::ptr::null_mut();
    }
    let bytes = (v.len() + 1) * core::mem::size_of::<T>();
    unsafe {
        let p = sys::calloc(1, bytes) as *mut T;
        core::ptr::copy_nonoverlapping(v.as_ptr(), p, v.len());
        p
    }
}

/// Whether `cls` is `target` or inherits from it.
pub fn is_kind(mut cls: Class, target: Class) -> bool {
    while !cls.is_null() {
        if cls == target {
            return true;
        }
        cls = unsafe { (*cls).superclass };
    }
    false
}

// ---------------------------------------------------------------------------
// Classes by name.

#[no_mangle]
pub extern "C" fn objc_getClass(name: *const c_char) -> Class {
    named_or_hooked(name)
}
#[no_mangle]
pub extern "C" fn objc_lookUpClass(name: *const c_char) -> Class {
    named_or_hooked(name)
}

/// The class registered under `name`, else the one the Swift runtime's
/// get-class hook knows (swift.rs).
fn named_or_hooked(name: *const c_char) -> Class {
    let c = class::class_named(name);
    if c.is_null() {
        crate::swift::class_from_hook(name)
    } else {
        c
    }
}
#[no_mangle]
pub extern "C" fn objc_getRequiredClass(name: *const c_char) -> Class {
    let c = named_or_hooked(name);
    if c.is_null() {
        let mut m = Msg::new();
        m.s("objc: link error: class '").cstr(name).s("' not found.");
        fatal(&mut m);
    }
    c
}
#[no_mangle]
pub extern "C" fn objc_getMetaClass(name: *const c_char) -> Class {
    let c = named_or_hooked(name);
    if c.is_null() {
        return c;
    }
    unsafe { (*c).isa }
}

#[no_mangle]
pub extern "C" fn objc_getClassList(buffer: *mut Class, count: i32) -> i32 {
    let _g = RUNTIME_LOCK.lock();
    let mut n = 0i32;
    class::reg().by_name.for_each(|_, c| {
        if !buffer.is_null() && n < count {
            unsafe { *buffer.add(n as usize) = c };
        }
        n += 1;
    });
    n
}

#[no_mangle]
pub extern "C" fn objc_copyClassList(out_count: *mut u32) -> *mut Class {
    let _g = RUNTIME_LOCK.lock();
    let mut v = Vec::new();
    class::reg().by_name.for_each(|_, c| v.push(c));
    to_c_array(v, out_count)
}

// ---------------------------------------------------------------------------
// Class properties.

#[no_mangle]
pub extern "C" fn class_getName(cls: Class) -> *const c_char {
    if cls.is_null() {
        return c"nil".as_ptr();
    }
    class::name_of(cls)
}
#[no_mangle]
pub extern "C" fn class_getSuperclass(cls: Class) -> Class {
    if cls.is_null() {
        return cls;
    }
    unsafe { (*cls).superclass }
}
#[no_mangle]
pub extern "C" fn class_isMetaClass(cls: Class) -> bool {
    !cls.is_null() && class::is_meta(cls)
}
#[no_mangle]
pub extern "C" fn class_getInstanceSize(cls: Class) -> usize {
    if cls.is_null() {
        return 0;
    }
    realize(cls);
    (rw(cls).instance_size as usize + 7) & !7
}
#[no_mangle]
pub extern "C" fn class_getVersion(cls: Class) -> i32 {
    if cls.is_null() {
        return 0;
    }
    realize(cls);
    rw(cls).version
}
#[no_mangle]
pub extern "C" fn class_setVersion(cls: Class, v: i32) {
    if cls.is_null() {
        return;
    }
    realize(cls);
    rw(cls).version = v;
}
#[no_mangle]
pub extern "C" fn class_getIvarLayout(cls: Class) -> *const u8 {
    if cls.is_null() {
        return core::ptr::null();
    }
    unsafe { (*class::ro(cls)).ivar_layout }
}
#[no_mangle]
pub extern "C" fn class_getWeakIvarLayout(cls: Class) -> *const u8 {
    if cls.is_null() {
        return core::ptr::null();
    }
    unsafe { (*class::ro(cls)).weak_ivar_layout }
}

// ---------------------------------------------------------------------------
// Methods.

#[no_mangle]
pub extern "C" fn class_getInstanceMethod(cls: Class, s: Sel) -> *mut MethodEntry {
    if cls.is_null() || s.is_null() {
        return core::ptr::null_mut();
    }
    realize(cls);
    let _g = RUNTIME_LOCK.lock();
    class::lookup_method(cls, s)
}
#[no_mangle]
pub extern "C" fn class_getClassMethod(cls: Class, s: Sel) -> *mut MethodEntry {
    if cls.is_null() {
        return core::ptr::null_mut();
    }
    realize(cls);
    class_getInstanceMethod(unsafe { (*cls).isa }, s)
}
#[no_mangle]
pub extern "C" fn class_getMethodImplementation(cls: Class, s: Sel) -> Imp {
    if cls.is_null() || s.is_null() {
        return core::ptr::null();
    }
    if is_realized(cls) {
        let c = cache::probe(cls, s);
        if !c.is_null() {
            return c;
        }
    }
    class::lookup_imp_or_forward(core::ptr::null_mut(), s, cls, true)
}
#[no_mangle]
pub extern "C" fn class_getMethodImplementation_stret(cls: Class, s: Sel) -> Imp {
    class_getMethodImplementation(cls, s)
}
#[no_mangle]
pub extern "C" fn class_respondsToSelector(cls: Class, s: Sel) -> bool {
    if cls.is_null() || s.is_null() {
        return false;
    }
    !class::lookup_imp_nil(cls, s).is_null()
}

#[no_mangle]
pub extern "C" fn class_copyMethodList(cls: Class, out_count: *mut u32) -> *mut *mut MethodEntry {
    if cls.is_null() {
        return to_c_array(Vec::<*mut MethodEntry>::new(), out_count);
    }
    realize(cls);
    let _g = RUNTIME_LOCK.lock();
    let r = rw(cls);
    let mut v = Vec::new();
    for c in r.cats.iter().rev() {
        v.extend(c.iter());
    }
    v.extend_from_slice(&r.base);
    v.extend_from_slice(&r.added);
    to_c_array(v, out_count)
}

fn new_entry(s: Sel, imp: Imp, types: *const c_char) -> *mut MethodEntry {
    let types = if types.is_null() { types } else { cstrdup(types) };
    Box::into_raw(Box::new(MethodEntry { name: s, types, imp: AtomicUsize::new(imp as usize) }))
}

#[no_mangle]
pub extern "C" fn class_addMethod(cls: Class, s: Sel, imp: Imp, types: *const c_char) -> bool {
    if cls.is_null() || s.is_null() {
        return false;
    }
    realize(cls);
    let _g = RUNTIME_LOCK.lock();
    if !class::own_method(cls, s).is_null() {
        return false;
    }
    let r = rw(cls);
    r.added.push(new_entry(s, imp, types));
    class::rebuild_sorted(r);
    class::methods_changed(cls);
    true
}

#[no_mangle]
pub extern "C" fn class_replaceMethod(cls: Class, s: Sel, imp: Imp, types: *const c_char) -> Imp {
    if cls.is_null() || s.is_null() {
        return core::ptr::null();
    }
    realize(cls);
    let _g = RUNTIME_LOCK.lock();
    let m = class::own_method(cls, s);
    if !m.is_null() {
        let old = unsafe { (*m).imp.swap(imp as usize, Ordering::AcqRel) } as Imp;
        class::methods_changed(cls);
        return old;
    }
    let r = rw(cls);
    r.added.push(new_entry(s, imp, types));
    class::rebuild_sorted(r);
    class::methods_changed(cls);
    core::ptr::null()
}

#[no_mangle]
pub extern "C" fn method_getName(m: *mut MethodEntry) -> Sel {
    if m.is_null() {
        return core::ptr::null();
    }
    unsafe { (*m).name }
}
#[no_mangle]
pub extern "C" fn method_getImplementation(m: *mut MethodEntry) -> Imp {
    if m.is_null() {
        return core::ptr::null();
    }
    unsafe { (*m).imp.load(Ordering::Acquire) as Imp }
}
#[no_mangle]
pub extern "C" fn method_getTypeEncoding(m: *mut MethodEntry) -> *const c_char {
    if m.is_null() {
        return core::ptr::null();
    }
    unsafe { (*m).types }
}
/// `struct objc_method_description *`: the record starts with the same two fields.
#[no_mangle]
pub extern "C" fn method_getDescription(m: *mut MethodEntry) -> *mut MethodDescription {
    m as *mut MethodDescription
}
#[no_mangle]
pub extern "C" fn method_setImplementation(m: *mut MethodEntry, imp: Imp) -> Imp {
    if m.is_null() || imp.is_null() {
        return core::ptr::null();
    }
    let _g = RUNTIME_LOCK.lock();
    let old = unsafe { (*m).imp.swap(imp as usize, Ordering::AcqRel) } as Imp;
    class::all_methods_changed();
    old
}
#[no_mangle]
pub extern "C" fn method_exchangeImplementations(a: *mut MethodEntry, b: *mut MethodEntry) {
    if a.is_null() || b.is_null() {
        return;
    }
    let _g = RUNTIME_LOCK.lock();
    unsafe {
        let ia = (*a).imp.load(Ordering::Relaxed);
        let ib = (*b).imp.load(Ordering::Relaxed);
        (*a).imp.store(ib, Ordering::Release);
        (*b).imp.store(ia, Ordering::Release);
    }
    class::all_methods_changed();
}

// Type encodings.

/// Skips one type in an encoding (with its qualifiers and the frame
/// offset digits that follow it in a method encoding).
unsafe fn skip_type(mut p: *const u8) -> *const u8 {
    while matches!(*p, b'r' | b'n' | b'N' | b'o' | b'O' | b'R' | b'V' | b'A' | b'j' | b'+' | b'|') {
        p = p.add(1);
    }
    p = skip_one(p);
    while *p == b'-' || (*p).is_ascii_digit() {
        p = p.add(1);
    }
    p
}
unsafe fn skip_one(mut p: *const u8) -> *const u8 {
    let c = *p;
    if c == 0 {
        return p;
    }
    p = p.add(1);
    match c {
        b'{' | b'(' | b'[' => {
            let (open, close) = match c {
                b'{' => (b'{', b'}'),
                b'(' => (b'(', b')'),
                _ => (b'[', b']'),
            };
            let mut depth = 1;
            while *p != 0 && depth > 0 {
                if *p == b'"' {
                    p = p.add(1);
                    while *p != 0 && *p != b'"' {
                        p = p.add(1);
                    }
                } else if *p == open {
                    depth += 1;
                } else if *p == close {
                    depth -= 1;
                }
                if *p != 0 {
                    p = p.add(1);
                }
            }
            p
        }
        b'^' => skip_one(p),
        b'@' => {
            if *p == b'"' {
                p = p.add(1);
                while *p != 0 && *p != b'"' {
                    p = p.add(1);
                }
                if *p == b'"' {
                    p = p.add(1);
                }
            } else if *p == b'?' {
                p = p.add(1);
                if *p == b'<' {
                    let mut depth = 1;
                    p = p.add(1);
                    while *p != 0 && depth > 0 {
                        if *p == b'<' {
                            depth += 1;
                        } else if *p == b'>' {
                            depth -= 1;
                        }
                        p = p.add(1);
                    }
                }
            }
            p
        }
        b'b' => {
            while (*p).is_ascii_digit() {
                p = p.add(1);
            }
            p
        }
        _ => p,
    }
}
/// The bytes of one type without its offset digits.
unsafe fn type_span(p: *const u8) -> (*const u8, usize) {
    let mut q = p;
    while matches!(*q, b'r' | b'n' | b'N' | b'o' | b'O' | b'R' | b'V' | b'A' | b'j' | b'+' | b'|') {
        q = q.add(1);
    }
    let e = skip_one(q);
    (p, e.offset_from(p) as usize)
}

fn arg_types(m: *mut MethodEntry) -> Vec<(*const u8, usize)> {
    let mut v = Vec::new();
    let t = method_getTypeEncoding(m) as *const u8;
    if t.is_null() {
        return v;
    }
    unsafe {
        let mut p = t;
        while *p != 0 {
            v.push(type_span(p));
            p = skip_type(p);
        }
    }
    v
}

#[no_mangle]
pub extern "C" fn method_getNumberOfArguments(m: *mut MethodEntry) -> u32 {
    let n = arg_types(m).len();
    if n == 0 {
        0
    } else {
        (n - 1) as u32
    }
}
fn copy_span(span: Option<(*const u8, usize)>) -> *mut c_char {
    match span {
        None => core::ptr::null_mut(),
        Some((p, n)) => unsafe {
            let d = sys::malloc(n + 1) as *mut u8;
            core::ptr::copy_nonoverlapping(p, d, n);
            *d.add(n) = 0;
            d as *mut c_char
        },
    }
}
fn get_span(span: Option<(*const u8, usize)>, dst: *mut c_char, len: usize) {
    if dst.is_null() || len == 0 {
        return;
    }
    unsafe {
        sys::memset(dst as *mut c_void, 0, len);
        if let Some((p, n)) = span {
            let k = if n < len { n } else { len };
            core::ptr::copy_nonoverlapping(p, dst as *mut u8, k);
        }
    }
}
#[no_mangle]
pub extern "C" fn method_copyReturnType(m: *mut MethodEntry) -> *mut c_char {
    copy_span(arg_types(m).first().copied())
}
#[no_mangle]
pub extern "C" fn method_copyArgumentType(m: *mut MethodEntry, i: u32) -> *mut c_char {
    copy_span(arg_types(m).get(i as usize + 1).copied())
}
#[no_mangle]
pub extern "C" fn method_getReturnType(m: *mut MethodEntry, dst: *mut c_char, len: usize) {
    get_span(arg_types(m).first().copied(), dst, len)
}
#[no_mangle]
pub extern "C" fn method_getArgumentType(m: *mut MethodEntry, i: u32, dst: *mut c_char, len: usize) {
    get_span(arg_types(m).get(i as usize + 1).copied(), dst, len)
}

// ---------------------------------------------------------------------------
// Selectors.

#[no_mangle]
pub extern "C" fn sel_registerName(name: *const c_char) -> Sel {
    sel::register(name, true)
}
#[no_mangle]
pub extern "C" fn sel_getUid(name: *const c_char) -> Sel {
    sel::register(name, true)
}
#[no_mangle]
pub extern "C" fn sel_getName(s: Sel) -> *const c_char {
    if s.is_null() {
        return c"<null selector>".as_ptr();
    }
    s
}
#[no_mangle]
pub extern "C" fn sel_isEqual(a: Sel, b: Sel) -> bool {
    a == b
}
#[no_mangle]
pub extern "C" fn sel_isMapped(s: Sel) -> bool {
    !s.is_null() && sel::lookup(s) == Some(s)
}

// ---------------------------------------------------------------------------
// Objects.

#[no_mangle]
pub extern "C" fn object_getClass(obj: Id) -> Class {
    class::object_class(obj)
}
#[no_mangle]
pub extern "C" fn object_setClass(obj: Id, cls: Class) -> Class {
    if (obj as isize) <= 0 || cls.is_null() {
        return core::ptr::null_mut();
    }
    realize(cls);
    let w = rr::isa_word(obj);
    let mut old = w.load(Ordering::Relaxed);
    loop {
        let new = if old & rr::PACKED != 0 { (old & !ISA_MASK) | cls as usize } else { cls as usize };
        match w.compare_exchange_weak(old, new, Ordering::AcqRel, Ordering::Relaxed) {
            Ok(_) => return (old & ISA_MASK) as Class,
            Err(x) => old = x,
        }
    }
}
#[no_mangle]
pub extern "C" fn object_isClass(obj: Id) -> bool {
    let c = class::object_class(obj);
    !c.is_null() && class::is_meta(c)
}
#[no_mangle]
pub extern "C" fn object_getClassName(obj: Id) -> *const c_char {
    class_getName(class::object_class(obj))
}
#[no_mangle]
pub extern "C" fn object_getIndexedIvars(obj: Id) -> *mut c_void {
    if obj.is_null() {
        return core::ptr::null_mut();
    }
    let c = class::object_class(obj);
    unsafe { (obj as *mut u8).add(class_getInstanceSize(c)) as *mut c_void }
}
#[no_mangle]
pub extern "C" fn object_copy(obj: Id, extra: usize) -> Id {
    if obj.is_null() {
        return obj;
    }
    let c = class::object_class(obj);
    let size = unsafe { sys::malloc_size(obj as *const c_void) };
    let n = rr::class_createInstance(c, extra);
    if n.is_null() {
        return n;
    }
    let base = class_getInstanceSize(c) + extra;
    let copy = if size > base { base } else { size };
    unsafe {
        sys::memcpy((n as *mut u8).add(8) as *mut c_void, (obj as *const u8).add(8) as *const c_void, copy - 8);
    }
    n
}

#[no_mangle]
pub extern "C" fn object_getIvar(obj: Id, iv: *mut IvarT) -> Id {
    if obj.is_null() || iv.is_null() {
        return core::ptr::null_mut();
    }
    unsafe { *((obj as *mut u8).add(*(*iv).offset as usize) as *mut Id) }
}
#[no_mangle]
pub extern "C" fn object_setIvar(obj: Id, iv: *mut IvarT, value: Id) {
    if obj.is_null() || iv.is_null() {
        return;
    }
    unsafe { *((obj as *mut u8).add(*(*iv).offset as usize) as *mut Id) = value };
}
#[no_mangle]
pub extern "C" fn object_setIvarWithStrongDefault(obj: Id, iv: *mut IvarT, value: Id) {
    if obj.is_null() || iv.is_null() {
        return;
    }
    unsafe { rr::objc_storeStrong((obj as *mut u8).add(*(*iv).offset as usize) as *mut Id, value) };
}
#[no_mangle]
pub extern "C" fn object_getInstanceVariable(obj: Id, name: *const c_char, out: *mut *mut c_void) -> *mut IvarT {
    if obj.is_null() || name.is_null() {
        return core::ptr::null_mut();
    }
    let iv = class_getInstanceVariable(class::object_class(obj), name);
    if !iv.is_null() && !out.is_null() {
        unsafe { *out = *((obj as *mut u8).add(*(*iv).offset as usize) as *mut *mut c_void) };
    }
    iv
}
#[no_mangle]
pub extern "C" fn object_setInstanceVariable(obj: Id, name: *const c_char, value: *mut c_void) -> *mut IvarT {
    if obj.is_null() || name.is_null() {
        return core::ptr::null_mut();
    }
    let iv = class_getInstanceVariable(class::object_class(obj), name);
    if !iv.is_null() {
        unsafe { *((obj as *mut u8).add(*(*iv).offset as usize) as *mut *mut c_void) = value };
    }
    iv
}

// ---------------------------------------------------------------------------
// Ivars and properties.

fn ivars_of(cls: Class) -> Vec<*mut IvarT> {
    let mut v = Vec::new();
    let ro = class::ro(cls);
    unsafe {
        let l = (*ro).ivars;
        if !l.is_null() {
            for i in 0..(*l).count as usize {
                v.push((*l).get(i));
            }
        }
    }
    v
}

#[no_mangle]
pub extern "C" fn class_copyIvarList(cls: Class, out_count: *mut u32) -> *mut *mut IvarT {
    if cls.is_null() {
        return to_c_array(Vec::<*mut IvarT>::new(), out_count);
    }
    realize(cls);
    to_c_array(ivars_of(cls), out_count)
}
#[no_mangle]
pub extern "C" fn class_getInstanceVariable(cls: Class, name: *const c_char) -> *mut IvarT {
    let mut c = cls;
    if name.is_null() {
        return core::ptr::null_mut();
    }
    while !c.is_null() {
        realize(c);
        for iv in ivars_of(c) {
            if cstreq(unsafe { (*iv).name }, name) {
                return iv;
            }
        }
        c = unsafe { (*c).superclass };
    }
    core::ptr::null_mut()
}
#[no_mangle]
pub extern "C" fn class_getClassVariable(cls: Class, name: *const c_char) -> *mut IvarT {
    if cls.is_null() {
        return core::ptr::null_mut();
    }
    class_getInstanceVariable(unsafe { (*cls).isa }, name)
}
#[no_mangle]
pub extern "C" fn ivar_getName(iv: *mut IvarT) -> *const c_char {
    if iv.is_null() {
        return core::ptr::null();
    }
    unsafe { (*iv).name }
}
#[no_mangle]
pub extern "C" fn ivar_getTypeEncoding(iv: *mut IvarT) -> *const c_char {
    if iv.is_null() {
        return core::ptr::null();
    }
    unsafe { (*iv).types }
}
#[no_mangle]
pub extern "C" fn ivar_getOffset(iv: *mut IvarT) -> isize {
    if iv.is_null() {
        return 0;
    }
    unsafe { *(*iv).offset as isize }
}

#[no_mangle]
pub extern "C" fn class_addIvar(cls: Class, name: *const c_char, size: usize, align_log2: u8, types: *const c_char) -> bool {
    if cls.is_null() || name.is_null() || fast(cls) & F_CONSTRUCTING == 0 || fast(cls) & F_META != 0 {
        return false;
    }
    if !class_getInstanceVariable(cls, name).is_null() {
        return false;
    }
    let _g = RUNTIME_LOCK.lock();
    let r = rw(cls);
    let align = 1usize << align_log2;
    let offset = (r.instance_size as usize + align - 1) & !(align - 1);
    let mut list = ivars_of(cls);
    let entry = Box::into_raw(Box::new(IvarT {
        offset: Box::into_raw(Box::new(offset as u32)),
        name: cstrdup(name),
        types: if types.is_null() { c"".as_ptr() } else { cstrdup(types) },
        alignment_log2: align_log2 as u32,
        size: size as u32,
    }));
    list.push(entry);
    // A fresh list with copies of the entries.
    let es = core::mem::size_of::<IvarT>();
    unsafe {
        let l = sys::calloc(1, 8 + list.len() * es) as *mut IvarList;
        (*l).entsize = es as u32;
        (*l).count = list.len() as u32;
        for (i, &e) in list.iter().enumerate() {
            core::ptr::copy_nonoverlapping(e, (*l).get(i), 1);
        }
        (*r.ro).ivars = l;
        r.instance_size = (offset + size) as u32;
        (*r.ro).instance_size = r.instance_size;
    }
    let w = fast_word(cls);
    let f = w.load(Ordering::Relaxed);
    w.store(
        (f & ((1usize << F_SIZE_SHIFT) - 1)) | (class::rounded_size(r.instance_size) << F_SIZE_SHIFT),
        Ordering::Release,
    );
    true
}

#[no_mangle]
pub extern "C" fn class_copyPropertyList(cls: Class, out_count: *mut u32) -> *mut *mut PropertyT {
    if cls.is_null() {
        return to_c_array(Vec::<*mut PropertyT>::new(), out_count);
    }
    realize(cls);
    let _g = RUNTIME_LOCK.lock();
    to_c_array(rw(cls).properties.clone(), out_count)
}
#[no_mangle]
pub extern "C" fn class_getProperty(cls: Class, name: *const c_char) -> *mut PropertyT {
    let mut c = cls;
    if name.is_null() {
        return core::ptr::null_mut();
    }
    while !c.is_null() {
        realize(c);
        let _g = RUNTIME_LOCK.lock();
        for &p in rw(c).properties.iter() {
            if cstreq(unsafe { (*p).name }, name) {
                return p;
            }
        }
        c = unsafe { (*c).superclass };
    }
    core::ptr::null_mut()
}
#[no_mangle]
pub extern "C" fn property_getName(p: *mut PropertyT) -> *const c_char {
    if p.is_null() {
        return core::ptr::null();
    }
    unsafe { (*p).name }
}
#[no_mangle]
pub extern "C" fn property_getAttributes(p: *mut PropertyT) -> *const c_char {
    if p.is_null() {
        return core::ptr::null();
    }
    unsafe { (*p).attributes }
}

/// Splits `T@"NSString",C,N,V_x` into (name, value) pairs.
fn parse_attributes(a: *const c_char) -> Vec<(u8, *const u8, usize)> {
    let mut v = Vec::new();
    if a.is_null() {
        return v;
    }
    unsafe {
        let mut p = a as *const u8;
        while *p != 0 {
            let name = *p;
            p = p.add(1);
            let start = p;
            let mut in_quote = false;
            while *p != 0 && (in_quote || *p != b',') {
                if *p == b'"' {
                    in_quote = !in_quote;
                }
                p = p.add(1);
            }
            v.push((name, start, p.offset_from(start) as usize));
            if *p == b',' {
                p = p.add(1);
            }
        }
    }
    v
}

#[no_mangle]
pub extern "C" fn property_copyAttributeList(p: *mut PropertyT, out_count: *mut u32) -> *mut PropertyAttribute {
    let attrs = parse_attributes(property_getAttributes(p));
    if !out_count.is_null() {
        unsafe { *out_count = attrs.len() as u32 };
    }
    if attrs.is_empty() {
        return core::ptr::null_mut();
    }
    let head = (attrs.len() + 1) * core::mem::size_of::<PropertyAttribute>();
    let strings: usize = attrs.iter().map(|&(_, _, n)| 2 + n + 1).sum();
    unsafe {
        let block = sys::calloc(1, head + strings) as *mut u8;
        let list = block as *mut PropertyAttribute;
        let mut s = block.add(head);
        for (i, &(name, vp, n)) in attrs.iter().enumerate() {
            let np = s;
            *s = name;
            *s.add(1) = 0;
            s = s.add(2);
            let valp = s;
            core::ptr::copy_nonoverlapping(vp, s, n);
            *s.add(n) = 0;
            s = s.add(n + 1);
            *list.add(i) = PropertyAttribute { name: np as *const c_char, value: valp as *const c_char };
        }
        list
    }
}

#[no_mangle]
pub extern "C" fn property_copyAttributeValue(p: *mut PropertyT, name: *const c_char) -> *mut c_char {
    if name.is_null() || cstrlen(name) != 1 {
        return core::ptr::null_mut();
    }
    let want = unsafe { *(name as *const u8) };
    for (n, vp, len) in parse_attributes(property_getAttributes(p)) {
        if n == want {
            return copy_span(Some((vp, len)));
        }
    }
    core::ptr::null_mut()
}

// ---------------------------------------------------------------------------
// Class construction.

#[no_mangle]
pub extern "C" fn objc_allocateClassPair(sup: Class, name: *const c_char, extra: usize) -> Class {
    if name.is_null() || !class::class_named(name).is_null() {
        return core::ptr::null_mut();
    }
    if !sup.is_null() {
        realize(sup);
        if fast(sup) & F_CONSTRUCTING != 0 {
            return core::ptr::null_mut();
        }
    }
    let name = cstrdup(name);
    let super_size = if sup.is_null() { 8 } else { rw(sup).instance_size };
    unsafe {
        let cls = sys::calloc(1, core::mem::size_of::<ClassT>() + extra) as Class;
        let meta = sys::calloc(1, core::mem::size_of::<ClassT>() + extra) as Class;
        let root = if sup.is_null() { RO_ROOT } else { 0 };
        let cro = Box::into_raw(Box::new(ClassRO {
            flags: root,
            instance_start: super_size,
            instance_size: super_size,
            reserved: 0,
            ivar_layout: core::ptr::null(),
            name,
            base_methods: core::ptr::null(),
            base_protocols: core::ptr::null(),
            ivars: core::ptr::null(),
            weak_ivar_layout: core::ptr::null(),
            base_properties: core::ptr::null(),
        }));
        let mro = Box::into_raw(Box::new(ClassRO { flags: RO_META | root, instance_start: 40, instance_size: 40, ..*cro }));
        (*meta).isa = if sup.is_null() { meta } else { (*(*sup).isa).isa };
        (*meta).superclass = if sup.is_null() { cls } else { (*sup).isa };
        (*meta).cache = cache::empty();
        (*meta).bits = mro as usize;
        (*cls).isa = meta;
        (*cls).superclass = sup;
        (*cls).cache = cache::empty();
        (*cls).bits = cro as usize;
        let _g = RUNTIME_LOCK.lock();
        class::realize_locked(cls);
        fast_word(cls).fetch_or(F_CONSTRUCTING, Ordering::AcqRel);
        fast_word(meta).fetch_or(F_CONSTRUCTING, Ordering::AcqRel);
        cls
    }
}

#[no_mangle]
pub extern "C" fn objc_registerClassPair(cls: Class) {
    if cls.is_null() || fast(cls) & F_CONSTRUCTING == 0 {
        return;
    }
    let _g = RUNTIME_LOCK.lock();
    class::register_class(cls);
    fast_word(cls).fetch_and(!F_CONSTRUCTING, Ordering::AcqRel);
    fast_word(unsafe { (*cls).isa }).fetch_and(!F_CONSTRUCTING, Ordering::AcqRel);
}

// ---------------------------------------------------------------------------
// objc_opt_* (clang's direct calls for common messages).

#[inline(always)]
fn plain_core(cls: Class) -> bool {
    fast(cls) & (F_REALIZED | F_INITIALIZED | F_CUSTOM_CORE) == F_REALIZED | F_INITIALIZED
}

#[no_mangle]
pub extern "C" fn objc_opt_self(obj: Id) -> Id {
    if (obj as isize) <= 0 {
        return obj;
    }
    let c = class::object_class(obj);
    if plain_core(c) {
        return obj;
    }
    send0(obj, sel::b().self_) as Id
}

#[no_mangle]
pub extern "C" fn objc_opt_class(obj: Id) -> Class {
    if obj.is_null() {
        return core::ptr::null_mut();
    }
    let c = class::object_class(obj);
    if !c.is_null() && plain_core(c) {
        return if fast(c) & F_META != 0 { obj as Class } else { c };
    }
    send0(obj, sel::b().class) as Class
}

#[no_mangle]
pub extern "C" fn objc_opt_isKindOfClass(obj: Id, target: Class) -> bool {
    if obj.is_null() {
        return false;
    }
    let c = class::object_class(obj);
    if !c.is_null() && plain_core(c) {
        return is_kind(c, target);
    }
    send1(obj, sel::b().is_kind_of_class, target as usize) & 0xFF != 0
}

#[no_mangle]
pub extern "C" fn objc_opt_respondsToSelector(obj: Id, s: Sel) -> bool {
    if obj.is_null() {
        return false;
    }
    let c = class::object_class(obj);
    if !c.is_null() && plain_core(c) {
        return class_respondsToSelector(c, s);
    }
    send1(obj, sel::b().responds_to_selector, s as usize) & 0xFF != 0
}

// ---------------------------------------------------------------------------
// Fast enumeration.

static mut MUTATION_HANDLER: Option<extern "C" fn(Id)> = None;

#[no_mangle]
pub extern "C" fn objc_enumerationMutation(obj: Id) {
    match unsafe { core::ptr::addr_of!(MUTATION_HANDLER).read() } {
        Some(h) => h(obj),
        None => {
            let mut m = Msg::new();
            m.s("objc: mutation detected during enumeration of object ").hex(obj as usize);
            fatal(&mut m)
        }
    }
}
#[no_mangle]
pub extern "C" fn objc_setEnumerationMutationHandler(h: Option<extern "C" fn(Id)>) {
    unsafe { core::ptr::addr_of_mut!(MUTATION_HANDLER).write(h) };
}
