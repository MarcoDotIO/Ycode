//! Autorelease pools and the return-value hand-off (objc-runtime.md §8),
//! and the runtime's thread-specific data (§10.2).

use crate::abi::*;
use crate::class::{self, F_CUSTOM_RR, F_META, ISA_MASK};
use crate::msgsend::send0;
use crate::rr::{self, PACKED};
use crate::sel;
use crate::sys;
use crate::util::{Global, Msg};
use core::ffi::c_void;
use core::sync::atomic::Ordering;

// ---------------------------------------------------------------------------
// Thread-specific data.

struct Tsd {
    pool_key: usize,
    rv_key: usize,
    inline: bool,
}
static TSD: Global<Tsd> = Global::new(Tsd { pool_key: 0, rv_key: 0, inline: false });

#[inline(always)]
fn tsd() -> &'static Tsd {
    unsafe { &*TSD.ptr() }
}

#[inline(always)]
fn tsd_base() -> *mut usize {
    let x: usize;
    unsafe { core::arch::asm!("mrs {}, tpidrro_el0", out(reg) x, options(pure, nomem, nostack, preserves_flags)) };
    (x & !7usize) as *mut usize
}

#[inline(always)]
fn tls_get(key: usize) -> usize {
    if tsd().inline {
        unsafe { *tsd_base().add(key) }
    } else {
        unsafe { sys::pthread_getspecific(key) as usize }
    }
}

#[inline(always)]
fn tls_set_fast(key: usize, v: usize) {
    if tsd().inline {
        unsafe { *tsd_base().add(key) = v }
    } else {
        unsafe { sys::pthread_setspecific(key, v as *const c_void) };
    }
}

pub fn init() {
    let t = unsafe { TSD.get() };
    unsafe {
        let mut k = 0usize;
        if sys::pthread_key_create(&mut k, Some(pool_thread_exit)) != 0 {
            crate::util::fatal_str("pthread_key_create failed");
        }
        t.pool_key = k;
        if sys::pthread_key_create(&mut k, None) != 0 {
            crate::util::fatal_str("pthread_key_create failed");
        }
        t.rv_key = k;
        // Use the inline slot only if it is where pthread keeps the value.
        let probe = 0x5ca1_ab1e_usize;
        sys::pthread_setspecific(t.rv_key, probe as *const c_void);
        t.inline = *tsd_base().add(t.rv_key) == probe;
        sys::pthread_setspecific(t.rv_key, core::ptr::null());
    }
}

// ---------------------------------------------------------------------------
// Pool pages (§8.1).

const PAGE_SIZE: usize = 4096;

#[repr(C)]
struct Page {
    next: *mut Id,
    parent: *mut Page,
    child: *mut Page,
    thread: usize,
    depth: usize,
}
const HEADER: usize = core::mem::size_of::<Page>();

#[inline(always)]
unsafe fn begin(p: *mut Page) -> *mut Id {
    (p as *mut u8).add(HEADER) as *mut Id
}
#[inline(always)]
unsafe fn end(p: *mut Page) -> *mut Id {
    (p as *mut u8).add(PAGE_SIZE) as *mut Id
}

fn new_page(parent: *mut Page) -> *mut Page {
    let mut mem: *mut c_void = core::ptr::null_mut();
    unsafe {
        if sys::posix_memalign(&mut mem, PAGE_SIZE, PAGE_SIZE) != 0 || mem.is_null() {
            crate::util::fatal_str("out of memory for an autorelease pool page");
        }
        let p = mem as *mut Page;
        p.write(Page {
            next: core::ptr::null_mut(),
            parent,
            child: core::ptr::null_mut(),
            thread: sys::pthread_self() as usize,
            depth: if parent.is_null() { 0 } else { (*parent).depth + 1 },
        });
        (*p).next = begin(p);
        if !parent.is_null() {
            (*parent).child = p;
        }
        p
    }
}

#[inline(always)]
fn hot() -> *mut Page {
    tls_get(tsd().pool_key) as *mut Page
}
#[inline(always)]
fn set_hot(p: *mut Page) {
    unsafe { sys::pthread_setspecific(tsd().pool_key, p as *const c_void) };
}

/// The page after `p`, reused if cached.
#[cold]
fn next_page(p: *mut Page) -> *mut Page {
    unsafe {
        let c = (*p).child;
        let n = if !c.is_null() {
            (*c).next = begin(c);
            c
        } else {
            new_page(p)
        };
        set_hot(n);
        n
    }
}

#[cold]
fn first_page() -> *mut Page {
    let p = new_page(core::ptr::null_mut());
    set_hot(p);
    p
}

#[inline(always)]
fn add(v: Id) -> *mut Id {
    let mut p = hot();
    unsafe {
        if p.is_null() {
            p = first_page();
        } else if (*p).next == end(p) {
            p = next_page(p);
        }
        let slot = (*p).next;
        *slot = v;
        (*p).next = slot.add(1);
        slot
    }
}

#[no_mangle]
pub extern "C" fn objc_autoreleasePoolPush() -> *mut c_void {
    add(core::ptr::null_mut()) as *mut c_void
}

#[no_mangle]
pub extern "C" fn _objc_autoreleasePoolPush() -> *mut c_void {
    objc_autoreleasePoolPush()
}

#[no_mangle]
pub extern "C" fn objc_autoreleasePoolPop(token: *mut c_void) {
    let token = token as *mut Id;
    let mut p = hot();
    if p.is_null() {
        return;
    }
    unsafe {
        // Fast path: the token is on the hot page.
        if token >= begin(p) && token < end(p) {
            while (*p).next > token {
                let slot = (*p).next.sub(1);
                (*p).next = slot;
                let o = *slot;
                if !o.is_null() {
                    rr::objc_release(o);
                }
                // A release may have autoreleased more objects.
                let h = hot();
                if h != p {
                    return pop_slow(token);
                }
            }
            trim(p);
            return;
        }
        pop_slow(token);
        p = hot();
        if !p.is_null() {
            trim(p);
        }
    }
}

#[no_mangle]
pub extern "C" fn _objc_autoreleasePoolPop(token: *mut c_void) {
    objc_autoreleasePoolPop(token)
}

/// Pops across pages. A null token pops everything.
#[cold]
fn pop_slow(token: *mut Id) {
    unsafe {
        let page_of = (token as usize & !(PAGE_SIZE - 1)) as *mut Page;
        loop {
            let p = hot();
            if p.is_null() {
                return;
            }
            if !token.is_null() && p == page_of && (*p).next <= token {
                return;
            }
            if (*p).next == begin(p) {
                let parent = (*p).parent;
                if parent.is_null() {
                    return;
                }
                set_hot(parent);
                continue;
            }
            let slot = (*p).next.sub(1);
            (*p).next = slot;
            let o = *slot;
            if !o.is_null() {
                rr::objc_release(o);
            }
        }
    }
}

/// Keeps one empty child page for reuse and frees the rest.
unsafe fn trim(p: *mut Page) {
    let c = (*p).child;
    if c.is_null() {
        return;
    }
    let mut g = (*c).child;
    (*c).child = core::ptr::null_mut();
    while !g.is_null() {
        let n = (*g).child;
        sys::free(g as *mut c_void);
        g = n;
    }
}

/// Thread exit: pop everything, free the pages.
unsafe extern "C" fn pool_thread_exit(v: *mut c_void) {
    let p = v as *mut Page;
    if p.is_null() {
        return;
    }
    set_hot(p);
    pop_slow(core::ptr::null_mut());
    let mut root = hot();
    while !root.is_null() && !(*root).parent.is_null() {
        root = (*root).parent;
    }
    let mut q = root;
    while !q.is_null() {
        let n = (*q).child;
        sys::free(q as *mut c_void);
        q = n;
    }
    set_hot(core::ptr::null_mut());
}

#[no_mangle]
pub extern "C" fn objc_autorelease(obj: Id) -> Id {
    if (obj as isize) <= 0 {
        return obj;
    }
    let isa = rr::isa_word(obj).load(Ordering::Relaxed);
    let cls = (isa & ISA_MASK) as Class;
    let f = class::fast_word(cls).load(Ordering::Relaxed);
    if f & F_CUSTOM_RR != 0 {
        return send0(obj, sel::b().autorelease) as Id;
    }
    if isa & PACKED == 0 && f & F_META != 0 {
        return obj;
    }
    add(obj);
    obj
}

#[no_mangle]
pub extern "C" fn _objc_rootAutorelease(obj: Id) -> Id {
    if (obj as isize) <= 0 {
        return obj;
    }
    add(obj);
    obj
}

#[no_mangle]
pub extern "C" fn _objc_autoreleasePoolPrint() {
    let mut p = hot();
    let mut m = Msg::new();
    m.s("objc: ##############\nobjc: AUTORELEASE POOLS for thread ").hex(unsafe { sys::pthread_self() } as usize).s("\n");
    m.print();
    unsafe {
        while !p.is_null() && !(*p).parent.is_null() {
            p = (*p).parent;
        }
        let mut count = 0usize;
        let mut q = p;
        let h = hot();
        while !q.is_null() {
            let mut s = begin(q);
            while s < (*q).next {
                let mut m = Msg::new();
                m.s("objc: [").hex(s as usize).s("]  ");
                if (*s).is_null() {
                    m.s("################  POOL ").hex(s as usize);
                } else {
                    count += 1;
                    m.hex(*s as usize).s("  ").cstr(class::name_of(class::object_class(*s)));
                }
                m.s("\n").print();
                s = s.add(1);
            }
            if q == h {
                break;
            }
            q = (*q).child;
        }
        let mut m = Msg::new();
        m.s("objc: ").dec(count).s(" releases pending.\nobjc: ##############\n").print();
    }
}

// ---------------------------------------------------------------------------
// Return-value hand-off (§8.3).

const MARKER: u32 = 0xAA1D_03FD; // mov x29, x29

#[inline(always)]
fn take_rv() -> bool {
    let k = tsd().rv_key;
    if tls_get(k) != 0 {
        tls_set_fast(k, 0);
        true
    } else {
        false
    }
}

/// Whether `t` is one of the claiming functions, directly or through a
/// linker stub `adrp x16, slot@PAGE; ldr x16, [x16, slot@PAGEOFF]; br x16`.
unsafe fn is_claim_target(t: usize) -> bool {
    let claims = [
        objc_claimAutoreleasedReturnValue as *const () as usize,
        objc_retainAutoreleasedReturnValue as *const () as usize,
        objc_unsafeClaimAutoreleasedReturnValue as *const () as usize,
    ];
    if claims.contains(&t) {
        return true;
    }
    let i0 = *(t as *const u32);
    let i1 = *((t + 4) as *const u32);
    let i2 = *((t + 8) as *const u32);
    if i0 & 0x9F00_001F != 0x9000_0010 || i1 & 0xFFC0_03FF != 0xF940_0210 || i2 != 0xD61F_0200 {
        return false;
    }
    let imm = ((((i0 >> 5) & 0x7_FFFF) << 2) | ((i0 >> 29) & 3)) as i64;
    let imm = (imm << 43) >> 43; // sign-extend 21 bits
    let page = ((t & !0xFFF) as i64 + (imm << 12)) as usize;
    let slot = page + (((i1 >> 10) & 0xFFF) as usize) * 8;
    claims.contains(&*(slot as *const usize))
}

/// Whether the caller will claim the result (§8.3): the instruction at the
/// return address is the marker, or a `bl` to a claiming function.
#[inline]
fn caller_claims(ra: usize) -> bool {
    // A small direct-mapped memo of return addresses (benign races).
    static MEMO: [core::sync::atomic::AtomicUsize; 256] = [const { core::sync::atomic::AtomicUsize::new(0) }; 256];
    let slot = &MEMO[(ra >> 2) & 255];
    let m = slot.load(Ordering::Relaxed);
    if m & !1 == ra {
        return m & 1 != 0;
    }
    let insn = unsafe { *(ra as *const u32) };
    let yes = if insn == MARKER {
        true
    } else if insn & 0xFC00_0000 == 0x9400_0000 {
        let imm = (((insn & 0x03FF_FFFF) << 6) as i32 >> 6) as isize * 4;
        unsafe { is_claim_target(ra.wrapping_add(imm as usize)) }
    } else {
        false
    };
    slot.store(ra | yes as usize, Ordering::Relaxed);
    yes
}

#[no_mangle]
pub extern "C" fn _ycobjc_autoreleaseReturnValue(obj: Id, ra: usize) -> Id {
    if caller_claims(ra) {
        tls_set_fast(tsd().rv_key, 1);
        return obj;
    }
    objc_autorelease(obj)
}

#[no_mangle]
pub extern "C" fn _ycobjc_retainAutoreleaseReturnValue(obj: Id, ra: usize) -> Id {
    _ycobjc_autoreleaseReturnValue(rr::objc_retain(obj), ra)
}

#[no_mangle]
pub extern "C" fn objc_retainAutoreleasedReturnValue(obj: Id) -> Id {
    if take_rv() {
        return obj;
    }
    rr::objc_retain(obj)
}

#[no_mangle]
pub extern "C" fn objc_claimAutoreleasedReturnValue(obj: Id) -> Id {
    objc_retainAutoreleasedReturnValue(obj)
}

#[no_mangle]
pub extern "C" fn objc_unsafeClaimAutoreleasedReturnValue(obj: Id) -> Id {
    if take_rv() {
        rr::objc_release(obj);
    }
    obj
}
