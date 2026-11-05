//! Locks, a global cell type, stderr output and fatal errors.

use crate::sys;
use core::cell::UnsafeCell;
use core::ffi::{c_char, c_void};

/// A static whose synchronization the runtime does itself (under one of
/// its locks, or written once at start-up before other threads exist).
pub struct Global<T>(UnsafeCell<T>);
unsafe impl<T> Sync for Global<T> {}
impl<T> Global<T> {
    pub const fn new(v: T) -> Self {
        Global(UnsafeCell::new(v))
    }
    #[inline(always)]
    pub fn ptr(&self) -> *mut T {
        self.0.get()
    }
    /// # Safety
    /// The caller holds the lock that guards this value.
    #[inline(always)]
    #[allow(clippy::mut_from_ref)]
    pub unsafe fn get(&self) -> &mut T {
        &mut *self.0.get()
    }
}

/// An `os_unfair_lock`.
pub struct Lock(UnsafeCell<sys::os_unfair_lock>);
unsafe impl Sync for Lock {}
impl Lock {
    pub const fn new() -> Self {
        Lock(UnsafeCell::new(sys::os_unfair_lock { v: 0 }))
    }
    #[inline(always)]
    pub fn lock(&self) -> LockGuard<'_> {
        unsafe { sys::os_unfair_lock_lock(self.0.get()) };
        LockGuard(self)
    }
    #[inline(always)]
    pub fn raw_lock(&self) {
        unsafe { sys::os_unfair_lock_lock(self.0.get()) };
    }
    #[inline(always)]
    pub fn raw_unlock(&self) {
        unsafe { sys::os_unfair_lock_unlock(self.0.get()) };
    }
}
pub struct LockGuard<'a>(&'a Lock);
impl Drop for LockGuard<'_> {
    #[inline(always)]
    fn drop(&mut self) {
        unsafe { sys::os_unfair_lock_unlock((self.0).0.get()) };
    }
}

extern "C" {
    fn __ulock_wait(op: u32, addr: *mut c_void, value: u64, timeout_us: u32) -> i32;
    fn __ulock_wake(op: u32, addr: *mut c_void, wake_value: u64) -> i32;
}
/// `UL_COMPARE_AND_WAIT` (xnu's public `sys/ulock.h`).
const UL_COMPARE_AND_WAIT: u32 = 1;

/// A lock whose uncontended path is inline: 0 free, 1 held, 2 held with
/// waiters; waiters sleep in the kernel's compare-and-wait (objc-runtime.md
/// §10.3). Used for the short side-table critical sections.
pub struct FastLock(core::sync::atomic::AtomicU32);
unsafe impl Sync for FastLock {}
impl FastLock {
    pub const fn new() -> Self {
        FastLock(core::sync::atomic::AtomicU32::new(0))
    }
    #[inline(always)]
    pub fn raw_lock(&self) {
        use core::sync::atomic::Ordering::*;
        if self.0.compare_exchange_weak(0, 1, Acquire, Relaxed).is_err() {
            self.lock_slow();
        }
    }
    #[cold]
    fn lock_slow(&self) {
        use core::sync::atomic::Ordering::*;
        for _ in 0..64 {
            if self.0.load(Relaxed) == 0 && self.0.compare_exchange_weak(0, 1, Acquire, Relaxed).is_ok() {
                return;
            }
            core::hint::spin_loop();
        }
        while self.0.swap(2, Acquire) != 0 {
            unsafe { __ulock_wait(UL_COMPARE_AND_WAIT, self.0.as_ptr() as *mut c_void, 2, 0) };
        }
    }
    #[inline(always)]
    pub fn raw_unlock(&self) {
        if self.0.swap(0, core::sync::atomic::Ordering::Release) == 2 {
            self.wake();
        }
    }
    #[cold]
    fn wake(&self) {
        unsafe { __ulock_wake(UL_COMPARE_AND_WAIT, self.0.as_ptr() as *mut c_void, 0) };
    }
    #[inline(always)]
    pub fn lock(&self) -> FastGuard<'_> {
        self.raw_lock();
        FastGuard(self)
    }
}
pub struct FastGuard<'a>(&'a FastLock);
impl Drop for FastGuard<'_> {
    #[inline(always)]
    fn drop(&mut self) {
        self.0.raw_unlock();
    }
}

/// A small stack buffer for diagnostics (no allocation on error paths).
pub struct Msg {
    buf: [u8; 512],
    len: usize,
}
impl Msg {
    pub fn new() -> Self {
        Msg { buf: [0; 512], len: 0 }
    }
    pub fn s(&mut self, s: &str) -> &mut Self {
        self.bytes(s.as_bytes())
    }
    pub fn bytes(&mut self, b: &[u8]) -> &mut Self {
        for &c in b {
            if self.len < self.buf.len() {
                self.buf[self.len] = c;
                self.len += 1;
            }
        }
        self
    }
    pub fn cstr(&mut self, p: *const c_char) -> &mut Self {
        if p.is_null() {
            return self.s("(null)");
        }
        let n = unsafe { sys::strlen(p) };
        self.bytes(unsafe { core::slice::from_raw_parts(p as *const u8, n) })
    }
    pub fn hex(&mut self, v: usize) -> &mut Self {
        self.s("0x");
        let mut started = false;
        for i in (0..16).rev() {
            let d = (v >> (i * 4)) & 0xF;
            if d != 0 || started || i == 0 {
                started = true;
                self.bytes(&[b"0123456789abcdef"[d]]);
            }
        }
        self
    }
    pub fn dec(&mut self, mut v: usize) -> &mut Self {
        let mut tmp = [0u8; 20];
        let mut i = tmp.len();
        loop {
            i -= 1;
            tmp[i] = b'0' + (v % 10) as u8;
            v /= 10;
            if v == 0 {
                break;
            }
        }
        let t = tmp;
        self.bytes(&t[i..])
    }
    pub fn print(&self) {
        unsafe { sys::write(2, self.buf.as_ptr() as *const c_void, self.len) };
    }
}

/// Prints `objc[<pid>]: <message>` style diagnostics and aborts.
pub fn fatal(m: &mut Msg) -> ! {
    m.s("\n");
    m.print();
    unsafe { sys::abort() }
}

pub fn fatal_str(s: &str) -> ! {
    let mut m = Msg::new();
    m.s("objc: ").s(s);
    fatal(&mut m)
}

/// Length of a C string.
#[inline]
pub fn cstrlen(p: *const c_char) -> usize {
    unsafe { sys::strlen(p) }
}

/// Compares two C strings for equality.
#[inline]
pub fn cstreq(a: *const c_char, b: *const c_char) -> bool {
    a == b || unsafe { sys::strcmp(a, b) == 0 }
}

/// A heap copy of a C string (never freed: names live as long as the process).
pub fn cstrdup(p: *const c_char) -> *const c_char {
    let n = cstrlen(p);
    unsafe {
        let d = sys::malloc(n + 1) as *mut c_char;
        sys::memcpy(d as *mut c_void, p as *const c_void, n + 1);
        d
    }
}

/// 64-bit FNV-1a of a C string.
#[inline]
pub fn hash_cstr(p: *const c_char) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut q = p as *const u8;
    unsafe {
        while *q != 0 {
            h ^= *q as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01B3);
            q = q.add(1);
        }
    }
    h
}

/// Mixes a pointer-sized key for hash tables.
#[inline(always)]
pub fn hash_ptr(p: usize) -> u64 {
    let mut x = p as u64;
    x ^= x >> 33;
    x = x.wrapping_mul(0xff51_afd7_ed55_8ccd);
    x ^= x >> 33;
    x
}
