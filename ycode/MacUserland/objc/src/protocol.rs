//! Protocols (objc-runtime.md §4.7).

use crate::abi::*;
use crate::class::{self, RUNTIME_LOCK};
use crate::map::StrMap;
use crate::util::{cstreq, hash_cstr, Global};
use alloc::vec::Vec;
use core::ffi::c_char;

static PROTOS: Global<StrMap<*mut ProtocolT>> = Global::new(StrMap::new());

fn protos() -> &'static mut StrMap<*mut ProtocolT> {
    unsafe { PROTOS.get() }
}

/// The registered protocol with `p`'s name (runtime lock held).
pub fn canonical(p: *mut ProtocolT) -> *mut ProtocolT {
    if p.is_null() {
        return p;
    }
    protos().get(unsafe { (*p).name }).unwrap_or(p)
}

/// Registers a protocol from an image (runtime lock held). First wins.
pub fn register(p: *mut ProtocolT) {
    unsafe {
        let name = (*p).name;
        let (_, v) = protos().insert_if_absent(name, hash_cstr(name), p);
        if v == p && (*p).isa == 0 {
            (*p).isa = crate::nsobject::protocol_class() as usize;
        }
    }
}

#[no_mangle]
pub extern "C" fn objc_getProtocol(name: *const c_char) -> *mut ProtocolT {
    if name.is_null() {
        return core::ptr::null_mut();
    }
    let _g = RUNTIME_LOCK.lock();
    protos().get(name).unwrap_or(core::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn objc_copyProtocolList(out_count: *mut u32) -> *mut *mut ProtocolT {
    let _g = RUNTIME_LOCK.lock();
    let mut v: Vec<*mut ProtocolT> = Vec::new();
    protos().for_each(|_, p| v.push(p));
    crate::api::to_c_array(v, out_count)
}

#[no_mangle]
pub extern "C" fn protocol_getName(p: *mut ProtocolT) -> *const c_char {
    if p.is_null() {
        return c"nil".as_ptr();
    }
    unsafe { (*p).name }
}

#[no_mangle]
pub extern "C" fn protocol_isEqual(a: *mut ProtocolT, b: *mut ProtocolT) -> bool {
    if a == b {
        return true;
    }
    if a.is_null() || b.is_null() {
        return false;
    }
    cstreq(unsafe { (*a).name }, unsafe { (*b).name })
}

/// Whether `p` is or includes `other`.
pub fn includes(p: *mut ProtocolT, other: *mut ProtocolT, depth: u32) -> bool {
    if p.is_null() || other.is_null() || depth > 64 {
        return false;
    }
    if protocol_isEqual(p, other) {
        return true;
    }
    unsafe {
        let l = (*p).protocols;
        if !l.is_null() {
            for i in 0..(*l).count {
                if includes((*l).get(i), other, depth + 1) {
                    return true;
                }
            }
        }
    }
    false
}

#[no_mangle]
pub extern "C" fn protocol_conformsToProtocol(p: *mut ProtocolT, other: *mut ProtocolT) -> bool {
    if p.is_null() || other.is_null() {
        return false;
    }
    unsafe {
        let l = (*p).protocols;
        if !l.is_null() {
            for i in 0..(*l).count {
                if includes((*l).get(i), other, 0) {
                    return true;
                }
            }
        }
    }
    false
}

#[no_mangle]
pub extern "C" fn class_conformsToProtocol(cls: Class, p: *mut ProtocolT) -> bool {
    if cls.is_null() || p.is_null() {
        return false;
    }
    class::realize(cls);
    let _g = RUNTIME_LOCK.lock();
    class::rw(cls).protocols.iter().any(|&q| includes(q, p, 0))
}

#[no_mangle]
pub extern "C" fn class_copyProtocolList(cls: Class, out_count: *mut u32) -> *mut *mut ProtocolT {
    if cls.is_null() {
        return crate::api::to_c_array(Vec::<*mut ProtocolT>::new(), out_count);
    }
    class::realize(cls);
    let _g = RUNTIME_LOCK.lock();
    crate::api::to_c_array(class::rw(cls).protocols.clone(), out_count)
}

#[no_mangle]
pub extern "C" fn class_addProtocol(cls: Class, p: *mut ProtocolT) -> bool {
    if cls.is_null() || p.is_null() {
        return false;
    }
    if class_conformsToProtocol(cls, p) {
        return false;
    }
    let _g = RUNTIME_LOCK.lock();
    class::rw(cls).protocols.push(p);
    true
}

#[no_mangle]
pub extern "C" fn protocol_copyProtocolList(p: *mut ProtocolT, out_count: *mut u32) -> *mut *mut ProtocolT {
    let mut v = Vec::new();
    if !p.is_null() {
        unsafe {
            let l = (*p).protocols;
            if !l.is_null() {
                for i in 0..(*l).count {
                    v.push((*l).get(i));
                }
            }
        }
    }
    crate::api::to_c_array(v, out_count)
}

fn method_list(p: *mut ProtocolT, required: bool, instance: bool) -> *const MethodListHeader {
    unsafe {
        match (required, instance) {
            (true, true) => (*p).instance_methods,
            (true, false) => (*p).class_methods,
            (false, true) => (*p).optional_instance_methods,
            (false, false) => (*p).optional_class_methods,
        }
    }
}

fn desc_of(m: RawMethod) -> MethodDescription {
    let name = if m.name_is_selref { m.name } else { crate::sel::register(m.name, false) };
    MethodDescription { name, types: m.types as *mut c_char }
}

fn find_desc(p: *mut ProtocolT, s: Sel, required: bool, instance: bool, depth: u32) -> Option<MethodDescription> {
    if p.is_null() || depth > 64 {
        return None;
    }
    let l = method_list(p, required, instance);
    if !l.is_null() {
        unsafe {
            for i in 0..(*l).count() {
                let d = desc_of((*l).get(i));
                if d.name == s {
                    return Some(d);
                }
            }
        }
    }
    unsafe {
        let pl = (*p).protocols;
        if !pl.is_null() {
            for i in 0..(*pl).count {
                if let Some(d) = find_desc((*pl).get(i), s, required, instance, depth + 1) {
                    return Some(d);
                }
            }
        }
    }
    None
}

#[no_mangle]
pub extern "C" fn protocol_getMethodDescription(
    p: *mut ProtocolT,
    s: Sel,
    required: bool,
    instance: bool,
) -> MethodDescription {
    find_desc(p, s, required, instance, 0)
        .unwrap_or(MethodDescription { name: core::ptr::null(), types: core::ptr::null_mut() })
}

#[no_mangle]
pub extern "C" fn protocol_copyMethodDescriptionList(
    p: *mut ProtocolT,
    required: bool,
    instance: bool,
    out_count: *mut u32,
) -> *mut MethodDescription {
    let mut v = Vec::new();
    if !p.is_null() {
        let l = method_list(p, required, instance);
        if !l.is_null() {
            unsafe {
                for i in 0..(*l).count() {
                    v.push(desc_of((*l).get(i)));
                }
            }
        }
    }
    crate::api::to_c_array(v, out_count)
}

#[no_mangle]
pub extern "C" fn protocol_copyPropertyList(p: *mut ProtocolT, out_count: *mut u32) -> *mut *mut PropertyT {
    let mut v = Vec::new();
    if !p.is_null() {
        unsafe {
            let l = (*p).instance_properties;
            if !l.is_null() {
                for i in 0..(*l).count as usize {
                    v.push((*l).get(i));
                }
            }
        }
    }
    crate::api::to_c_array(v, out_count)
}
