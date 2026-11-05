//! The libSystem functions the runtime calls (public C declarations from
//! the macOS SDK headers; Ycode's libSystem and the Mac's both export them).

#![allow(non_camel_case_types, dead_code)]

use core::ffi::{c_char, c_int, c_void};

pub type size_t = usize;
pub type pthread_key_t = usize;
pub type pthread_t = *mut c_void;

/// `os_unfair_lock` (`<os/lock.h>`): one 32-bit word, 0 = unlocked.
#[repr(C)]
pub struct os_unfair_lock {
    pub v: u32,
}

/// `pthread_mutex_t` / `pthread_cond_t` (64 / 48 bytes, `<sys/_pthread/*.h>`).
#[repr(C, align(8))]
pub struct pthread_mutex_t {
    pub sig: i64,
    pub opaque: [u8; 56],
}
#[repr(C, align(8))]
pub struct pthread_cond_t {
    pub sig: i64,
    pub opaque: [u8; 40],
}
/// Static initializer signatures (`PTHREAD_MUTEX_INITIALIZER`, `PTHREAD_COND_INITIALIZER`).
pub const PTHREAD_MUTEX_SIG_INIT: i64 = 0x32AAABA7;
pub const PTHREAD_COND_SIG_INIT: i64 = 0x3CB0B1BB;

extern "C" {
    pub fn malloc(size: size_t) -> *mut c_void;
    pub fn calloc(n: size_t, size: size_t) -> *mut c_void;
    pub fn realloc(p: *mut c_void, size: size_t) -> *mut c_void;
    pub fn free(p: *mut c_void);
    pub fn posix_memalign(out: *mut *mut c_void, align: size_t, size: size_t) -> c_int;
    pub fn malloc_size(p: *const c_void) -> size_t;

    pub fn memcpy(d: *mut c_void, s: *const c_void, n: size_t) -> *mut c_void;
    pub fn memmove(d: *mut c_void, s: *const c_void, n: size_t) -> *mut c_void;
    pub fn memset(d: *mut c_void, c: c_int, n: size_t) -> *mut c_void;
    pub fn memcmp(a: *const c_void, b: *const c_void, n: size_t) -> c_int;
    pub fn strlen(s: *const c_char) -> size_t;
    pub fn strcmp(a: *const c_char, b: *const c_char) -> c_int;
    pub fn strncmp(a: *const c_char, b: *const c_char, n: size_t) -> c_int;

    pub fn write(fd: c_int, buf: *const c_void, n: size_t) -> isize;
    pub fn abort() -> !;
    pub fn getenv(name: *const c_char) -> *const c_char;
    pub fn mprotect(addr: *mut c_void, len: size_t, prot: c_int) -> c_int;

    pub fn os_unfair_lock_lock(l: *mut os_unfair_lock);
    pub fn os_unfair_lock_unlock(l: *mut os_unfair_lock);
    pub fn os_unfair_lock_trylock(l: *mut os_unfair_lock) -> bool;

    pub fn pthread_self() -> pthread_t;
    pub fn pthread_key_create(key: *mut pthread_key_t, dtor: Option<unsafe extern "C" fn(*mut c_void)>) -> c_int;
    pub fn pthread_getspecific(key: pthread_key_t) -> *mut c_void;
    pub fn pthread_setspecific(key: pthread_key_t, value: *const c_void) -> c_int;
    pub fn pthread_mutex_lock(m: *mut pthread_mutex_t) -> c_int;
    pub fn pthread_mutex_unlock(m: *mut pthread_mutex_t) -> c_int;
    pub fn pthread_cond_wait(c: *mut pthread_cond_t, m: *mut pthread_mutex_t) -> c_int;
    pub fn pthread_cond_broadcast(c: *mut pthread_cond_t) -> c_int;

    pub fn _dyld_register_func_for_add_image(cb: unsafe extern "C" fn(*const c_void, isize));
    pub fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;

    pub fn _Block_copy(block: *const c_void) -> *mut c_void;
    pub fn _Block_release(block: *const c_void);
}

/// `RTLD_DEFAULT` (`<dlfcn.h>`).
pub const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;
/// `PROT_*` (`<sys/mman.h>`).
pub const PROT_READ: c_int = 1;
pub const PROT_WRITE: c_int = 2;
