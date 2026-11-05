//! The structures clang emits for Objective-C (objc-runtime.md §2) and the
//! public types of `objc/objc.h` and `objc/runtime.h`.

#![allow(dead_code)]

use core::ffi::{c_char, c_void};

pub type Id = *mut Object;
pub type Sel = *const c_char;
pub type Imp = *const c_void;
pub type Class = *mut ClassT;

#[repr(C)]
pub struct Object {
    pub isa: usize,
}

/// The 5-word class object (§2.2). Words 2-4 belong to the runtime after
/// realization.
#[repr(C)]
pub struct ClassT {
    pub isa: Class,
    pub superclass: Class,
    pub cache: *mut crate::cache::Cache,
    pub fast: usize,
    pub bits: usize,
}

/// `class_ro` (§2.3).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ClassRO {
    pub flags: u32,
    pub instance_start: u32,
    pub instance_size: u32,
    pub reserved: u32,
    pub ivar_layout: *const u8,
    pub name: *const c_char,
    pub base_methods: *const MethodListHeader,
    pub base_protocols: *const ProtocolList,
    pub ivars: *const IvarList,
    pub weak_ivar_layout: *const u8,
    pub base_properties: *const PropertyList,
}

pub const RO_META: u32 = 1 << 0;
pub const RO_ROOT: u32 = 1 << 1;
pub const RO_HAS_CXX_STRUCTORS: u32 = 1 << 2;

#[repr(C)]
pub struct MethodListHeader {
    pub entsize_flags: u32,
    pub count: u32,
}
pub const METHOD_LIST_RELATIVE: u32 = 0x8000_0000;
pub const METHOD_LIST_ENTSIZE_MASK: u32 = 0x0000_FFFC;

/// A classic method-list entry.
#[repr(C)]
pub struct MethodBig {
    pub name: Sel,
    pub types: *const c_char,
    pub imp: Imp,
}

/// A relative method-list entry (offsets from each field's own address).
#[repr(C)]
pub struct MethodSmall {
    pub name: i32,
    pub types: i32,
    pub imp: i32,
}

/// One decoded method from either list format.
#[derive(Clone, Copy)]
pub struct RawMethod {
    pub name: *const c_char,
    pub types: *const c_char,
    pub imp: Imp,
    /// `name` already is a unique SEL read from a selector reference.
    pub name_is_selref: bool,
}

impl MethodListHeader {
    pub fn count(&self) -> usize {
        self.count as usize
    }
    /// Decodes entry `i`.
    ///
    /// # Safety
    /// `self` is a valid method list and `i < count`.
    pub unsafe fn get(&self, i: usize) -> RawMethod {
        let base = (self as *const Self as *const u8).add(8);
        let entsize = (self.entsize_flags & METHOD_LIST_ENTSIZE_MASK) as usize;
        if self.entsize_flags & METHOD_LIST_RELATIVE != 0 {
            let e = base.add(i * entsize) as *const MethodSmall;
            let f = |field: *const i32| -> *const u8 { (field as *const u8).offset(*field as isize) };
            let selref = f(&(*e).name) as *const Sel;
            let imp_off = (*e).imp;
            RawMethod {
                name: *selref,
                types: f(&(*e).types) as *const c_char,
                imp: if imp_off == 0 { core::ptr::null() } else { f(&(*e).imp) as Imp },
                name_is_selref: true,
            }
        } else {
            let e = base.add(i * entsize) as *const MethodBig;
            RawMethod { name: (*e).name, types: (*e).types, imp: (*e).imp, name_is_selref: false }
        }
    }
}

#[repr(C)]
pub struct IvarList {
    pub entsize: u32,
    pub count: u32,
}
#[repr(C)]
pub struct IvarT {
    pub offset: *mut u32,
    pub name: *const c_char,
    pub types: *const c_char,
    pub alignment_log2: u32,
    pub size: u32,
}
impl IvarList {
    /// # Safety
    /// `i < count`.
    pub unsafe fn get(&self, i: usize) -> *mut IvarT {
        (self as *const Self as *mut u8).add(8 + i * self.entsize as usize) as *mut IvarT
    }
}

#[repr(C)]
pub struct PropertyList {
    pub entsize: u32,
    pub count: u32,
}
#[repr(C)]
pub struct PropertyT {
    pub name: *const c_char,
    pub attributes: *const c_char,
}
impl PropertyList {
    /// # Safety
    /// `i < count`.
    pub unsafe fn get(&self, i: usize) -> *mut PropertyT {
        (self as *const Self as *mut u8).add(8 + i * self.entsize as usize) as *mut PropertyT
    }
}

#[repr(C)]
pub struct ProtocolList {
    pub count: usize,
    // followed by `count` protocol pointers
}
impl ProtocolList {
    /// # Safety
    /// `i < count`.
    pub unsafe fn get(&self, i: usize) -> *mut ProtocolT {
        *((self as *const Self as *const *mut ProtocolT).add(1 + i))
    }
}

#[repr(C)]
pub struct ProtocolT {
    pub isa: usize,
    pub name: *const c_char,
    pub protocols: *const ProtocolList,
    pub instance_methods: *const MethodListHeader,
    pub class_methods: *const MethodListHeader,
    pub optional_instance_methods: *const MethodListHeader,
    pub optional_class_methods: *const MethodListHeader,
    pub instance_properties: *const PropertyList,
    pub size: u32,
    pub flags: u32,
    pub extended_method_types: *const *const c_char,
    pub demangled_name: *const c_char,
    pub class_properties: *const PropertyList,
}

#[repr(C)]
pub struct CategoryT {
    pub name: *const c_char,
    pub cls: Class,
    pub instance_methods: *const MethodListHeader,
    pub class_methods: *const MethodListHeader,
    pub protocols: *const ProtocolList,
    pub instance_properties: *const PropertyList,
    /// Valid only when the image info has `IMAGE_INFO_CLASS_PROPERTIES`.
    pub class_properties: *const PropertyList,
}

#[repr(C)]
pub struct ImageInfo {
    pub version: u32,
    pub flags: u32,
}
pub const IMAGE_INFO_CLASS_PROPERTIES: u32 = 1 << 6;

/// `struct objc_super` (`objc/message.h`).
#[repr(C)]
pub struct ObjcSuper {
    pub receiver: Id,
    pub super_class: Class,
}

/// `objc_property_attribute_t` (`objc/runtime.h`).
#[repr(C)]
pub struct PropertyAttribute {
    pub name: *const c_char,
    pub value: *const c_char,
}

/// `struct objc_method_description` (`objc/runtime.h`).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct MethodDescription {
    pub name: Sel,
    pub types: *mut c_char,
}

pub const NIL: Id = core::ptr::null_mut();
pub const NO_CLASS: Class = core::ptr::null_mut();

/// Opaque for `void *` returns.
pub type Ptr = *mut c_void;
