//! The entry points the Swift runtime uses to make Swift classes
//! Objective-C classes (objc-runtime.md §15). Their names and C signatures
//! are the ones the open-source Swift runtime declares and calls
//! (`stdlib/public/runtime/{Metadata.cpp,SwiftObject.mm,
//! ImageInspectionMachO.cpp,MetadataLookup.cpp}`, Apache-2.0); the
//! behavior here is Ycode's, from how the Swift runtime uses them:
//!
//! - `objc_addLoadImageFunc`: the Swift runtime scans each image's Swift
//!   sections from this callback; it runs for every image already known and
//!   then for each later one, after the runtime has read its classes.
//! - `objc_readClassPair`: registers a class pair the Swift runtime built at
//!   run time (generic class instances), in place.
//! - `_objc_realizeClassFromSwift`: realizes a Swift class whose metadata
//!   the Swift runtime has just initialized; categories that named the
//!   `previously` address (a class stub) are moved to the class.
//! - the hooks: `objc_getClass` asks the get-class hook for names it does
//!   not know (Swift's mangled class names); `class_getName` asks the
//!   lazy-namer hook for a class without a name (generic instances);
//!   `class_getImageName` asks the image-name hook.

use crate::abi::*;
use crate::class::{self, reg, rw, RUNTIME_LOCK};
use crate::util::Global;
use alloc::vec::Vec;
use core::ffi::{c_char, c_void};
use core::sync::atomic::{AtomicUsize, Ordering};

// ---------------------------------------------------------------------------
// Load-image callbacks.

type LoadImageFn = unsafe extern "C" fn(*const c_void);

struct LoadImages {
    funcs: Vec<LoadImageFn>,
    images: Vec<usize>,
}
static LOAD_IMAGES: Global<LoadImages> = Global::new(LoadImages { funcs: Vec::new(), images: Vec::new() });
static LOAD_LOCK: crate::util::FastLock = crate::util::FastLock::new();

/// Called by image.rs once the runtime has read `header` (every image, with
/// or without Objective-C metadata), outside the runtime lock.
pub fn image_added(header: *const c_void) {
    let funcs = {
        let _g = LOAD_LOCK.lock();
        let l = unsafe { LOAD_IMAGES.get() };
        l.images.push(header as usize);
        l.funcs.clone()
    };
    for f in funcs {
        unsafe { f(header) };
    }
}

#[no_mangle]
pub extern "C" fn objc_addLoadImageFunc(func: LoadImageFn) {
    let images = {
        let _g = LOAD_LOCK.lock();
        let l = unsafe { LOAD_IMAGES.get() };
        l.funcs.push(func);
        l.images.clone()
    };
    for h in images {
        unsafe { func(h as *const c_void) };
    }
}

// ---------------------------------------------------------------------------
// Classes the Swift runtime builds or initializes.

#[no_mangle]
pub extern "C" fn objc_readClassPair(cls: Class, _info: *const c_void) -> Class {
    if cls.is_null() {
        return cls;
    }
    let _g = RUNTIME_LOCK.lock();
    if !class::is_realized(cls) {
        class::register_class(cls);
        class::realize_locked(cls);
    }
    cls
}

#[no_mangle]
pub extern "C" fn _objc_realizeClassFromSwift(cls: Class, previously: *mut c_void) -> Class {
    if cls.is_null() {
        return cls;
    }
    let _g = RUNTIME_LOCK.lock();
    if !previously.is_null() && previously as Class != cls {
        if let Some(mut moved) = reg().pending.remove(previously as usize) {
            match reg().pending.get_mut(cls as usize) {
                Some(list) => list.append(&mut moved),
                None => {
                    reg().pending.insert(cls as usize, moved);
                }
            }
        }
    }
    if !class::is_realized(cls) {
        class::register_class(cls);
        class::realize_locked(cls);
    }
    cls
}

/// `class_setSuperclass` (deprecated API; the Swift runtime uses it to
/// re-parent its NSError stand-in class once Foundation is loaded).
#[no_mangle]
pub extern "C" fn class_setSuperclass(cls: Class, new_super: Class) -> Class {
    if cls.is_null() {
        return core::ptr::null_mut();
    }
    let _g = RUNTIME_LOCK.lock();
    class::realize_locked(cls);
    if !new_super.is_null() {
        class::realize_locked(new_super);
    }
    unsafe {
        let old = (*cls).superclass;
        if !old.is_null() {
            rw(old).subclasses.retain(|&c| c != cls);
        }
        (*cls).superclass = new_super;
        let meta = (*cls).isa;
        if !new_super.is_null() && !meta.is_null() {
            let old_meta_super = (*meta).superclass;
            if !old_meta_super.is_null() {
                rw(old_meta_super).subclasses.retain(|&c| c != meta);
            }
            (*meta).superclass = (*new_super).isa;
            rw((*new_super).isa).subclasses.push(meta);
            rw(new_super).subclasses.push(cls);
        }
        class::all_methods_changed();
        old
    }
}

// ---------------------------------------------------------------------------
// Hooks.

pub type GetClassHook = unsafe extern "C" fn(*const c_char, *mut Class) -> bool;
pub type ImageNameHook = unsafe extern "C" fn(Class, *mut *const c_char) -> bool;
pub type LazyNamerHook = unsafe extern "C" fn(Class) -> *const c_char;

unsafe extern "C" fn no_class(_name: *const c_char, out: *mut Class) -> bool {
    if !out.is_null() {
        *out = core::ptr::null_mut();
    }
    false
}

#[repr(C)]
struct DlInfo {
    fname: *const c_char,
    fbase: *mut c_void,
    sname: *const c_char,
    saddr: *mut c_void,
}
extern "C" {
    fn dladdr(addr: *const c_void, info: *mut DlInfo) -> i32;
}

unsafe extern "C" fn image_of_class(cls: Class, out: *mut *const c_char) -> bool {
    let mut info = DlInfo {
        fname: core::ptr::null(),
        fbase: core::ptr::null_mut(),
        sname: core::ptr::null(),
        saddr: core::ptr::null_mut(),
    };
    let found = !cls.is_null() && dladdr(cls as *const c_void, &mut info) != 0 && !info.fname.is_null();
    if !out.is_null() {
        *out = if found { info.fname } else { core::ptr::null() };
    }
    found
}

static GET_CLASS_HOOK: AtomicUsize = AtomicUsize::new(0);
static IMAGE_NAME_HOOK: AtomicUsize = AtomicUsize::new(0);
static LAZY_NAMER_HOOK: AtomicUsize = AtomicUsize::new(0);

fn get_class_hook() -> GetClassHook {
    let h = GET_CLASS_HOOK.load(Ordering::Acquire);
    if h == 0 {
        no_class
    } else {
        unsafe { core::mem::transmute::<usize, GetClassHook>(h) }
    }
}

fn image_name_hook() -> ImageNameHook {
    let h = IMAGE_NAME_HOOK.load(Ordering::Acquire);
    if h == 0 {
        image_of_class
    } else {
        unsafe { core::mem::transmute::<usize, ImageNameHook>(h) }
    }
}

/// Installs `new` and returns the hook it replaces through `old`; the
/// previous value is never null (a default that answers "not found").
fn swap_hook(slot: &AtomicUsize, new: usize, default: usize, old: *mut usize) {
    let _g = RUNTIME_LOCK.lock();
    let prev = slot.swap(new, Ordering::AcqRel);
    if !old.is_null() {
        unsafe { *old = if prev == 0 { default } else { prev } };
    }
}

#[no_mangle]
pub extern "C" fn objc_setHook_getClass(new: GetClassHook, old: *mut GetClassHook) {
    swap_hook(&GET_CLASS_HOOK, new as usize, no_class as *const () as usize, old as *mut usize);
}

#[no_mangle]
pub extern "C" fn objc_setHook_getImageName(new: ImageNameHook, old: *mut ImageNameHook) {
    swap_hook(&IMAGE_NAME_HOOK, new as usize, image_of_class as *const () as usize, old as *mut usize);
}

#[no_mangle]
pub extern "C" fn objc_setHook_lazyClassNamer(new: LazyNamerHook, old: *mut LazyNamerHook) {
    // A namer hook has no "not found" answer; the first one replaces none.
    let _g = RUNTIME_LOCK.lock();
    let prev = LAZY_NAMER_HOOK.swap(new as usize, Ordering::AcqRel);
    if !old.is_null() {
        unsafe { *(old as *mut usize) = prev };
    }
}

/// The class named `name` when the name map does not have it (the get-class
/// hook), registered so the next lookup is direct. No lock held.
pub fn class_from_hook(name: *const c_char) -> Class {
    if name.is_null() || GET_CLASS_HOOK.load(Ordering::Acquire) == 0 {
        return core::ptr::null_mut();
    }
    let mut out: Class = core::ptr::null_mut();
    if unsafe { get_class_hook()(name, &mut out) } && !out.is_null() {
        let _g = RUNTIME_LOCK.lock();
        class::realize_locked(out);
        return out;
    }
    core::ptr::null_mut()
}

/// The name of a class whose `class_ro` has none, from the lazy namer hook
/// (stored in the `class_ro` so it is asked once). No lock held.
pub fn lazy_name(cls: Class, ro: *mut ClassRO) -> *const c_char {
    let h = LAZY_NAMER_HOOK.load(Ordering::Acquire);
    if h == 0 {
        return core::ptr::null();
    }
    let hook = unsafe { core::mem::transmute::<usize, LazyNamerHook>(h) };
    let name = unsafe { hook(cls) };
    if !name.is_null() {
        let slot = unsafe { &*(core::ptr::addr_of_mut!((*ro).name) as *const AtomicUsize) };
        if slot.compare_exchange(0, name as usize, Ordering::AcqRel, Ordering::Acquire).is_err() {
            return slot.load(Ordering::Acquire) as *const c_char;
        }
    }
    name
}

#[no_mangle]
pub extern "C" fn class_getImageName(cls: Class) -> *const c_char {
    let mut name: *const c_char = core::ptr::null();
    unsafe { image_name_hook()(cls, &mut name) };
    name
}
