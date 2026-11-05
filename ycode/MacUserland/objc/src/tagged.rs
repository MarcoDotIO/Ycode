//! Tagged pointers: a negative object pointer carries its class in bits
//! 60-62 (objc-runtime.md §13: no classes are registered yet, so tagged
//! receivers behave as nil).

use crate::abi::Class;
use crate::msgsend::_ycobjc_tagged_classes;

#[inline]
pub fn class_of(p: usize) -> Class {
    let tag = (p >> 60) & 7;
    unsafe { core::ptr::addr_of!(_ycobjc_tagged_classes).read()[tag] as Class }
}

#[inline(always)]
pub fn is_tagged(p: usize) -> bool {
    (p as isize) < 0
}
