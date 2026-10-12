/*
 * init.c - libsystem_kernel's initialization entry points.
 *
 * Clean-room Ycode code. Contract: host-libraries.md section 7 and
 * host-library-init.md sections 1.3, 1.4, 2 and 9.2:
 *  - every entry point stores what it is given, NULL-checks every table
 *    member it uses, and is safe to skip or to call twice;
 *  - the exported data already hold correct static values at load time
 *    (common/data-symbols.txt), so nothing depends on these running.
 */
#include "yc_kernel.h"

YC_HIDDEN const struct yc_libkernel_functions *yc_libkernel_fns;
YC_HIDDEN const struct yc_libkernel_string_functions *yc_libkernel_string_fns;
YC_HIDDEN const struct yc_libkernel_voucher_functions *yc_libkernel_voucher_fns;

/* Kept for parity with the published init behavior (dlsym of the v1+
 * table); nothing in Ycode reads it yet. */
static void *(*yc_dlsym)(void *, const char *);

/* The task's reply port from mach_init (Mach trap -26). */
static yc_port_t yc_task_reply_port;
static int yc_mach_init_done;

/* Recompute one page-size triple from a commpage shift byte. Values
 * outside 12..16 (4 KiB..64 KiB) are ignored, which keeps the static
 * 16 KiB values if the commpage is missing or not filled. */
static void set_page_triple(yc_u8 shift, int *shift_var, yc_uintptr_t *size_var, yc_uintptr_t *mask_var)
{
    if (shift < 12 || shift > 16)
        return;
    *shift_var = shift;
    *size_var = (yc_uintptr_t)1 << shift;
    *mask_var = *size_var - 1;
}

/* Mach-level process initialization, run once (host-library-init.md
 * section 1.3, step 2). Exported as the mach_init SPI. */
YC_EXPORT int mach_init(void)
{
    if (yc_mach_init_done)
        return 0;
    yc_mach_init_done = 1;

    yc_port_t task = (yc_port_t)YC_MACH0(YC_TRAP_TASK_SELF);
    if (task != YC_MACH_PORT_NULL)
        mach_task_self_ = task;
    yc_task_reply_port = (yc_port_t)YC_MACH0(YC_TRAP_REPLY_PORT);

    set_page_triple(yc_commpage_u8(YC_COMM_KERNEL_PAGE_SHIFT), &vm_kernel_page_shift, &vm_kernel_page_size,
                    &vm_kernel_page_mask);
    set_page_triple(yc_commpage_u8(YC_COMM_USER_PAGE_SHIFT_64), &vm_page_shift, &vm_page_size, &vm_page_mask);
    /* CPU-capability setup and _pthread_set_self(NULL) do nothing on arm64. */
    return 0;
}

/* void __libkernel_init(_libkernel_functions_t fns, const char *envp[],
 *     const char *apple[], const struct ProgramVars *vars) */
YC_EXPORT void __libkernel_init(const struct yc_libkernel_functions *fns, const char **envp, const char **apple,
                                const void *vars)
{
    (void)envp;
    (void)apple; /* the "pfz" key is optional and skipped (section 1.3) */
    (void)vars;
    if (fns != YC_NULL) {
        yc_libkernel_fns = fns;
        if (fns->version >= 1 && fns->dlsym != YC_NULL)
            yc_dlsym = fns->dlsym;
    }
    mach_init();
}

/* int __libkernel_platform_init(_libkernel_string_functions_t fns) */
YC_EXPORT int __libkernel_platform_init(const struct yc_libkernel_string_functions *fns)
{
    if (fns != YC_NULL)
        yc_libkernel_string_fns = fns;
    return 0;
}

/* kern_return_t __libkernel_voucher_init(_libkernel_voucher_functions_t fns) */
YC_EXPORT int __libkernel_voucher_init(const struct yc_libkernel_voucher_functions *fns)
{
    if (fns != YC_NULL)
        yc_libkernel_voucher_fns = fns;
    return YC_KERN_SUCCESS;
}

/* void __libkernel_init_late(_libkernel_late_init_config_t config):
 * version-compatibility shims and spawn filtering are not used. */
YC_EXPORT void __libkernel_init_late(const void *config)
{
    (void)config;
}

/* void __libkernel_init_after_boot_tasks(config): launchd only. */
YC_EXPORT void __libkernel_init_after_boot_tasks(const void *config)
{
    (void)config;
}

/* void _init_cpu_capabilities(void): nothing to do on arm64. */
YC_EXPORT void _init_cpu_capabilities(void)
{
}

/* uint64_t _get_cpu_capabilities(void): the commpage capability word. */
YC_EXPORT yc_u64 _get_cpu_capabilities(void)
{
    return yc_commpage_u64(YC_COMM_CPU_CAPABILITIES64);
}

/* Accessors for the other kernel sources. */
YC_HIDDEN void *yc_kernel_dlsym(void *handle, const char *name)
{
    return yc_dlsym ? yc_dlsym(handle, name) : YC_NULL;
}

YC_HIDDEN yc_port_t yc_kernel_task_reply_port(void)
{
    return yc_task_reply_port;
}
