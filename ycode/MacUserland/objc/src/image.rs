//! Loading the `__objc_*` sections of each image (objc-runtime.md §2.1,
//! §10.1). Called by the dynamic linker for every image, at registration
//! and for each later `dlopen`.

use crate::abi::*;
use crate::class::{self, PendingCat, RUNTIME_LOCK};
use crate::map::PtrMap;
use crate::sel;
use crate::sys;
use crate::util::{Global, Lock};
use alloc::vec::Vec;
use core::ffi::c_void;

const MH_MAGIC_64: u32 = 0xFEED_FACF;
const LC_SEGMENT_64: u32 = 0x19;
const SG_READ_ONLY: u32 = 0x10;

#[repr(C)]
struct MachHeader64 {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
}
#[repr(C)]
struct LoadCommand {
    cmd: u32,
    cmdsize: u32,
}
#[repr(C)]
struct SegmentCommand64 {
    cmd: u32,
    cmdsize: u32,
    segname: [u8; 16],
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: i32,
    initprot: i32,
    nsects: u32,
    flags: u32,
}
#[repr(C)]
struct Section64 {
    sectname: [u8; 16],
    segname: [u8; 16],
    addr: u64,
    size: u64,
    offset: u32,
    align: u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
}

#[derive(Clone, Copy, Default)]
struct Sect {
    addr: usize,
    size: usize,
    /// The containing segment is read-only after fixups.
    read_only: bool,
    seg_addr: usize,
    seg_size: usize,
}
impl Sect {
    fn count(&self) -> usize {
        self.size / 8
    }
    fn ptrs<T>(&self) -> *mut *mut T {
        self.addr as *mut *mut T
    }
}

#[derive(Default)]
struct Sections {
    imageinfo: Option<Sect>,
    classlist: Sect,
    nlclslist: Sect,
    catlist: Sect,
    nlcatlist: Sect,
    protolist: Sect,
    selrefs: Sect,
    protorefs: Sect,
}

fn name_eq(field: &[u8; 16], s: &[u8]) -> bool {
    let n = field.iter().position(|&c| c == 0).unwrap_or(16);
    &field[..n] == s
}

fn objc_suffix(field: &[u8; 16]) -> Option<&[u8]> {
    let n = field.iter().position(|&c| c == 0).unwrap_or(16);
    let f = &field[..n];
    // The Mac benchmark build reads only renamed sections; the Mac's own
    // runtime owns the `__objc_*` ones there (objc-runtime.md §12).
    #[cfg(not(feature = "host-bench"))]
    let prefix = b"__objc_";
    #[cfg(feature = "host-bench")]
    let prefix = b"__ycob_";
    if f.starts_with(prefix) {
        return Some(&f[7..]);
    }
    None
}

unsafe fn scan(header: *const c_void, slide: isize) -> Option<Sections> {
    let h = header as *const MachHeader64;
    if (*h).magic != MH_MAGIC_64 {
        return None;
    }
    let mut s = Sections::default();
    let mut found = false;
    let mut lc = (h as *const u8).add(core::mem::size_of::<MachHeader64>()) as *const LoadCommand;
    for _ in 0..(*h).ncmds {
        if (*lc).cmd == LC_SEGMENT_64 {
            let seg = lc as *const SegmentCommand64;
            let sn = &(*seg).segname;
            if name_eq(sn, b"__DATA") || name_eq(sn, b"__DATA_CONST") || name_eq(sn, b"__DATA_DIRTY")
                || name_eq(sn, b"__AUTH") || name_eq(sn, b"__AUTH_CONST")
            {
                let ro = (*seg).flags & SG_READ_ONLY != 0 || name_eq(sn, b"__DATA_CONST") || name_eq(sn, b"__AUTH_CONST");
                let sects = (seg as *const u8).add(core::mem::size_of::<SegmentCommand64>()) as *const Section64;
                for i in 0..(*seg).nsects as usize {
                    let sec = sects.add(i);
                    let Some(suffix) = objc_suffix(&(*sec).sectname) else { continue };
                    let v = Sect {
                        addr: ((*sec).addr as isize + slide) as usize,
                        size: (*sec).size as usize,
                        read_only: ro,
                        seg_addr: ((*seg).vmaddr as isize + slide) as usize,
                        seg_size: (*seg).vmsize as usize,
                    };
                    found = true;
                    match suffix {
                        b"imageinfo" => s.imageinfo = Some(v),
                        b"classlist" => s.classlist = v,
                        b"nlclslist" => s.nlclslist = v,
                        b"catlist" => s.catlist = v,
                        b"nlcatlist" => s.nlcatlist = v,
                        b"protolist" => s.protolist = v,
                        b"selrefs" => s.selrefs = v,
                        b"protorefs" => s.protorefs = v,
                        _ => {}
                    }
                }
            }
        }
        lc = (lc as *const u8).add((*lc).cmdsize as usize) as *const LoadCommand;
    }
    if found && s.imageinfo.is_some() {
        Some(s)
    } else {
        None
    }
}

/// Runs `f` with the section's segment writable if it is read-only.
unsafe fn writable(sect: &Sect, f: impl FnOnce()) {
    if !sect.read_only || sect.size == 0 {
        f();
        return;
    }
    let page = 16384usize;
    let start = sect.seg_addr & !(page - 1);
    let len = (sect.seg_addr + sect.seg_size + page - 1 - start) & !(page - 1);
    sys::mprotect(start as *mut c_void, len, sys::PROT_READ | sys::PROT_WRITE);
    f();
    sys::mprotect(start as *mut c_void, len, sys::PROT_READ);
}

/// Classes whose +load already ran.
static LOADED: Global<PtrMap<()>> = Global::new(PtrMap::new());
/// Headers already processed.
static SEEN: Global<PtrMap<()>> = Global::new(PtrMap::new());
static SEEN_LOCK: Lock = Lock::new();

struct Image {
    s: Sections,
    class_props: bool,
}

unsafe fn image_at(header: *const c_void, slide: isize) -> Option<Image> {
    let s = scan(header, slide)?;
    let info = s.imageinfo.unwrap().addr as *const ImageInfo;
    let class_props = (*info).flags & IMAGE_INFO_CLASS_PROPERTIES != 0;
    Some(Image { s, class_props })
}

/// Phase 1: selector references.
unsafe fn fix_selrefs(img: &Image) {
    let s = &img.s;
    if s.selrefs.size != 0 {
        writable(&s.selrefs, || sel::fix_refs(s.selrefs.addr as *mut Sel, s.selrefs.count()));
    }
}

/// Phase 2: protocols, protocol references, classes, categories. Runtime lock held.
unsafe fn register_image(img: &Image) {
    let s = &img.s;
    let pl = s.protolist.ptrs::<ProtocolT>();
    for i in 0..s.protolist.count() {
        crate::protocol::register(*pl.add(i));
    }
    if s.protorefs.size != 0 {
        writable(&s.protorefs, || {
            let pr = s.protorefs.ptrs::<ProtocolT>();
            for i in 0..s.protorefs.count() {
                let slot = pr.add(i);
                *slot = crate::protocol::canonical(*slot);
            }
        });
    }
    let cl = s.classlist.ptrs::<ClassT>();
    for i in 0..s.classlist.count() {
        let c = *cl.add(i);
        if !c.is_null() {
            class::register_class(c);
        }
    }
    let cats = s.catlist.ptrs::<CategoryT>();
    for i in 0..s.catlist.count() {
        let c = *cats.add(i);
        if !c.is_null() {
            class::add_category(PendingCat { cat: c, class_props: img.class_props });
        }
    }
}

/// Phase 3: the +load calls of an image, superclasses first, then
/// categories. Runtime lock held.
unsafe fn collect_loads(img: &Image, out: &mut Vec<(Class, Imp)>) {
    let s = &img.s;
    let nl = s.nlclslist.ptrs::<ClassT>();
    for i in 0..s.nlclslist.count() {
        let c = *nl.add(i);
        if !c.is_null() {
            class::realize_locked(c);
            schedule_load(c, out);
        }
    }
    let nlc = s.nlcatlist.ptrs::<CategoryT>();
    for i in 0..s.nlcatlist.count() {
        let cat = *nlc.add(i);
        if cat.is_null() || (*cat).cls.is_null() {
            continue;
        }
        let cls = (*cat).cls;
        class::realize_locked(cls);
        schedule_load(cls, out);
        let l = (*cat).class_methods;
        if !l.is_null() {
            for j in 0..(*l).count() {
                let m = (*l).get(j);
                let name = if m.name_is_selref { m.name } else { sel::register(m.name, false) };
                if name == sel::b().load {
                    out.push((cls, m.imp));
                }
            }
        }
    }
}

fn run_loads(loads: Vec<(Class, Imp)>) {
    let load = sel::b().load;
    for (c, imp) in loads {
        let f: extern "C" fn(Class, Sel) = unsafe { core::mem::transmute(imp) };
        f(c, load);
    }
}

/// Marks `header` seen; false if it already was.
fn first_time(header: *const c_void) -> bool {
    let _g = SEEN_LOCK.lock();
    let seen = unsafe { SEEN.get() };
    if seen.get(header as usize).is_some() {
        return false;
    }
    seen.insert(header as usize, ());
    true
}

/// The image callback (`_dyld_register_func_for_add_image`): images added
/// later by `dlopen`.
pub unsafe extern "C" fn add_image(header: *const c_void, slide: isize) {
    if !first_time(header) {
        return;
    }
    if let Some(img) = image_at(header, slide) {
        fix_selrefs(&img);
        let mut loads = Vec::new();
        {
            let _g = RUNTIME_LOCK.lock();
            register_image(&img);
            collect_loads(&img, &mut loads);
        }
        run_loads(loads);
    }
    crate::swift::image_added(header);
}

/// Queues `cls`'s own +load after its superclasses'. Runtime lock held.
unsafe fn schedule_load(cls: Class, out: &mut Vec<(Class, Imp)>) {
    if cls.is_null() {
        return;
    }
    let loaded = LOADED.get();
    if loaded.get(cls as usize).is_some() {
        return;
    }
    schedule_load((*cls).superclass, out);
    loaded.insert(cls as usize, ());
    let meta = (*cls).isa;
    let base = &class::rw(meta).base;
    for &m in base.iter() {
        if (*m).name == sel::b().load {
            out.push((cls, (*m).imp.load(core::sync::atomic::Ordering::Relaxed) as Imp));
            break;
        }
    }
}

extern "C" {
    fn _dyld_image_count() -> u32;
    fn _dyld_get_image_header(i: u32) -> *const c_void;
    fn _dyld_get_image_vmaddr_slide(i: u32) -> isize;
}

/// Processes the images already loaded in three passes over all of them
/// (selector references first, so realization never sees an unfixed
/// image; +load from the last image, the dependencies, to the first),
/// then registers for later images.
pub fn init() {
    unsafe {
        let n = _dyld_image_count();
        let mut imgs = Vec::new();
        let mut headers = Vec::new();
        for i in 0..n {
            let h = _dyld_get_image_header(i);
            if h.is_null() || !first_time(h) {
                continue;
            }
            headers.push(h);
            if let Some(img) = image_at(h, _dyld_get_image_vmaddr_slide(i)) {
                imgs.push(img);
            }
        }
        for img in imgs.iter() {
            fix_selrefs(img);
        }
        let mut loads = Vec::new();
        {
            let _g = RUNTIME_LOCK.lock();
            for img in imgs.iter() {
                register_image(img);
            }
            for img in imgs.iter().rev() {
                collect_loads(img, &mut loads);
            }
        }
        run_loads(loads);
        for h in headers {
            crate::swift::image_added(h);
        }
        sys::_dyld_register_func_for_add_image(add_image);
    }
}
