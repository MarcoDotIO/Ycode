/*
 * Default errno hook, linked into every host library that does not define
 * __ycode_set_errno itself (see ../../README.md, "Fallbacks").
 *
 * Clean-room Ycode code. The thread-local errno ABI is pending
 * (host-libraries.md section 8); routing every store through __error()
 * means that only libsystem_kernel's __error has to change when it lands.
 */
#include "yc_kernel_api.h"

YC_HIDDEN void __ycode_set_errno(int value)
{
    *YC_KFN(__error)() = value;
}

/* Tail of every BSD-style unimplemented stub: errno = ENOSYS, return -1. */
YC_HIDDEN long __ycode_stub_enosys(void)
{
    __ycode_set_errno(YC_ENOSYS);
    return -1;
}
