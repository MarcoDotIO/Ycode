/*
 * errno.c - libsystem_kernel's errno storage, __error(), cerror and
 * cerror_nocancel, and the library's errno hook.
 *
 * Clean-room Ycode code. Contract: host-libraries.md section 8.5 and
 * host-library-init.md section 4:
 *  - __error() returns TSD slot 1 when the TSD base (TPIDRRO_EL0) and the
 *    slot are non-zero, otherwise the exported global errno;
 *  - cerror(err) first lets libpthread act on a pending cancellation
 *    (through the _libkernel_functions table, NULL-checked), then behaves
 *    like cerror_nocancel(err);
 *  - cerror_nocancel(err) stores err in both places and returns -1 in x0
 *    and x1.
 * This file replaces common/fallback/kernel/yc_errno_fallback.c and
 * common/fallback/all/yc_errno_hook.c for libsystem_kernel.
 */
#include "yc_kernel.h"

YC_EXPORT int errno = 0;

static int *tsd_errno(void)
{
    yc_uintptr_t *tsd = yc_tsd_base();
    if (tsd == YC_NULL)
        return YC_NULL;
    return (int *)tsd[YC_TSD_ERRNO];
}

YC_EXPORT int *__error(void)
{
    int *p = tsd_errno();
    return p ? p : &errno;
}

static void store_errno(int value)
{
    int *p = tsd_errno();
    if (p)
        *p = value;
    errno = value;
}

YC_EXPORT __int128 cerror_nocancel(int value)
{
    store_errno(value);
    return -1; /* all ones: x0 = x1 = -1 */
}

YC_EXPORT __int128 cerror(int value)
{
    const struct yc_libkernel_functions *fns = yc_libkernel_fns;
    if (fns != YC_NULL && fns->pthread_exit_if_canceled != YC_NULL)
        fns->pthread_exit_if_canceled(value);
    return cerror_nocancel(value);
}

/* The hook every host library uses to set errno (SimHostLibs/README.md). */
YC_HIDDEN void __ycode_set_errno(int value)
{
    store_errno(value);
}

/* Tail of the generated BSD-style unimplemented stubs. */
YC_HIDDEN long __ycode_stub_enosys(void)
{
    store_errno(YC_ENOSYS);
    return -1;
}
