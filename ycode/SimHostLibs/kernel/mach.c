/*
 * mach.c - Mach routines of libsystem_kernel that map onto Mach traps or
 * are answered inside the library.
 *
 * Clean-room Ycode code. Facts used:
 *  - trap numbers and argument orders: specs/simulator/data/mach-traps.json;
 *  - fast time traps -3/-4 and mach_timebase_info (-89):
 *    darwin-process-start.md section 4;
 *  - host_info(HOST_PRIORITY_INFO): host-libraries.md section 7.5 and
 *    host-library-init.md section 9.2;
 *  - TSD slots 2 and 8 (MIG reply ports): host-library-init.md section 3.3;
 *  - the public Mach C API (the mach headers): routine signatures and constants
 *    such as MACH_SEND_MSG, MACH_RCV_MSG, MACH_SEND_INTERRUPT(ED),
 *    MACH_RCV_INTERRUPT(ED), MACH_PORT_RIGHT_RECEIVE, the mach_msg_header_t
 *    layout and mach_timespec_t.
 * No function here has more than eight register arguments: the objects use
 * the platform-neutral AAPCS64, which agrees with Apple's arm64 convention
 * only for register arguments (see mach_vm_map in syscall_special.S).
 */
#include "yc_kernel.h"

/* ---------------------------------------------------------------- time */

YC_EXPORT yc_u64 mach_absolute_time(void)
{
    return YC_MACH0(YC_TRAP_ABSOLUTE_TIME);
}

YC_EXPORT yc_u64 mach_continuous_time(void)
{
    return YC_MACH0(YC_TRAP_CONTINUOUS_TIME);
}

/* The approximate clocks may return any value no newer than the precise
 * ones; the precise values satisfy that. */
YC_EXPORT yc_u64 mach_approximate_time(void)
{
    return mach_absolute_time();
}

YC_EXPORT yc_u64 mach_continuous_approximate_time(void)
{
    return mach_continuous_time();
}

static struct yc_mach_timebase_info yc_timebase_cache;

YC_EXPORT int mach_timebase_info(struct yc_mach_timebase_info *info)
{
    if (yc_timebase_cache.denom == 0) {
        struct yc_mach_timebase_info tb = {0, 0};
        int kr = (int)YC_MACH1(YC_TRAP_TIMEBASE_INFO, &tb);
        if (kr != YC_KERN_SUCCESS)
            return kr;
        if (tb.denom == 0)
            return YC_KERN_FAILURE;
        yc_timebase_cache = tb;
    }
    if (info == YC_NULL)
        return YC_KERN_INVALID_ARGUMENT;
    *info = yc_timebase_cache;
    return YC_KERN_SUCCESS;
}

/* uint64_t mach_boottime_usec(void): commpage BOOTTIME_USEC. */
YC_EXPORT yc_u64 mach_boottime_usec(void)
{
    return yc_commpage_u64(YC_COMM_BOOTTIME_USEC);
}

/* --------------------------------------------------------- self ports */

YC_EXPORT yc_port_t mach_task_self(void)
{
    return mach_task_self_;
}

YC_EXPORT yc_port_t mach_host_self(void)
{
    return (yc_port_t)YC_MACH0(YC_TRAP_HOST_SELF);
}

YC_EXPORT yc_port_t mach_thread_self(void)
{
    return (yc_port_t)YC_MACH0(YC_TRAP_THREAD_SELF);
}

/* boolean_t mach_task_is_self(task_name_t task) */
YC_EXPORT int mach_task_is_self(yc_port_t task)
{
    return task == mach_task_self_;
}

/* ------------------------------------------------- port traps (-16..-77) */

YC_EXPORT int mach_port_allocate(yc_port_t task, yc_u32 right, yc_port_t *name)
{
    return (int)YC_MACH3(YC_TRAP_PORT_ALLOCATE, task, right, name);
}

YC_EXPORT int mach_port_deallocate(yc_port_t task, yc_port_t name)
{
    return (int)YC_MACH2(YC_TRAP_PORT_DEALLOCATE, task, name);
}

YC_EXPORT int mach_port_mod_refs(yc_port_t task, yc_port_t name, yc_u32 right, int delta)
{
    return (int)YC_MACH4(YC_TRAP_PORT_MOD_REFS, task, name, right, (yc_intptr_t)delta);
}

YC_EXPORT int mach_port_move_member(yc_port_t task, yc_port_t member, yc_port_t after)
{
    return (int)YC_MACH3(YC_TRAP_PORT_MOVE_MEMBER, task, member, after);
}

YC_EXPORT int mach_port_insert_right(yc_port_t task, yc_port_t name, yc_port_t poly, yc_u32 poly_poly)
{
    return (int)YC_MACH4(YC_TRAP_PORT_INSERT_RIGHT, task, name, poly, poly_poly);
}

YC_EXPORT int mach_port_insert_member(yc_port_t task, yc_port_t name, yc_port_t pset)
{
    return (int)YC_MACH3(YC_TRAP_PORT_INSERT_MEMBER, task, name, pset);
}

YC_EXPORT int mach_port_extract_member(yc_port_t task, yc_port_t name, yc_port_t pset)
{
    return (int)YC_MACH3(YC_TRAP_PORT_EXTRACT_MEMBER, task, name, pset);
}

/* kern_return_t mach_port_construct(ipc_space_t task,
 *     mach_port_options_ptr_t options, mach_port_context_t context,
 *     mach_port_name_t *name) */
YC_EXPORT int mach_port_construct(yc_port_t task, void *options, yc_u64 context, yc_port_t *name)
{
    return (int)YC_MACH4(YC_TRAP_PORT_CONSTRUCT, task, options, context, name);
}

/* kern_return_t mach_port_destruct(ipc_space_t task, mach_port_name_t name,
 *     mach_port_delta_t srdelta, mach_port_context_t guard) */
YC_EXPORT int mach_port_destruct(yc_port_t task, yc_port_t name, int srdelta, yc_u64 guard)
{
    return (int)YC_MACH4(YC_TRAP_PORT_DESTRUCT, task, name, (yc_intptr_t)srdelta, guard);
}

YC_EXPORT int mach_port_get_attributes(yc_port_t task, yc_port_t name, int flavor, void *info, yc_u32 *count)
{
    return (int)YC_MACH5(YC_TRAP_PORT_GET_ATTRIBUTES, task, name, (yc_intptr_t)flavor, info, count);
}

YC_EXPORT int mach_port_guard(yc_port_t task, yc_port_t name, yc_u64 guard, int strict)
{
    return (int)YC_MACH4(YC_TRAP_PORT_GUARD, task, name, guard, (yc_intptr_t)strict);
}

YC_EXPORT int mach_port_unguard(yc_port_t task, yc_port_t name, yc_u64 guard)
{
    return (int)YC_MACH3(YC_TRAP_PORT_UNGUARD, task, name, guard);
}

YC_EXPORT int mach_port_type(yc_port_t task, yc_port_t name, yc_u32 *ptype)
{
    return (int)YC_MACH3(YC_TRAP_PORT_TYPE, task, name, ptype);
}

/* kern_return_t mach_port_request_notification(ipc_space_t task,
 *     mach_port_name_t name, mach_msg_id_t msgid, mach_port_mscount_t sync,
 *     mach_port_t notify, mach_msg_type_name_t notifyPoly,
 *     mach_port_t *previous) */
YC_EXPORT int mach_port_request_notification(yc_port_t task, yc_port_t name, int msgid, yc_u32 sync,
                                             yc_port_t notify, yc_u32 notify_poly, yc_port_t *previous)
{
    return (int)yc_mach_trap(YC_TRAP_PORT_REQUEST_NOTIFICATION, task, name, (yc_uintptr_t)(yc_intptr_t)msgid, sync,
                             notify, notify_poly, (yc_uintptr_t)previous);
}

/* ------------------------------------------------- VM traps (-10..-15) */

YC_EXPORT int mach_vm_allocate(yc_port_t task, yc_u64 *address, yc_u64 size, int flags)
{
    return (int)YC_MACH4(YC_TRAP_VM_ALLOCATE, task, address, size, (yc_intptr_t)flags);
}

YC_EXPORT int mach_vm_deallocate(yc_port_t task, yc_u64 address, yc_u64 size)
{
    return (int)YC_MACH3(YC_TRAP_VM_DEALLOCATE, task, address, size);
}

YC_EXPORT int mach_vm_protect(yc_port_t task, yc_u64 address, yc_u64 size, int set_maximum, int new_protection)
{
    return (int)YC_MACH5(YC_TRAP_VM_PROTECT, task, address, size, (yc_intptr_t)set_maximum,
                         (yc_intptr_t)new_protection);
}

YC_EXPORT int mach_vm_purgable_control(yc_port_t task, yc_u64 address, int control, int *state)
{
    return (int)YC_MACH4(YC_TRAP_VM_PURGABLE_CONTROL, task, address, (yc_intptr_t)control, state);
}

/* The vm_* names take vm_address_t / vm_size_t, which are 64-bit on LP64,
 * so they are the same calls. */
YC_EXPORT int vm_allocate(yc_port_t task, yc_uintptr_t *address, yc_uintptr_t size, int flags)
{
    return mach_vm_allocate(task, (yc_u64 *)address, size, flags);
}

YC_EXPORT int vm_deallocate(yc_port_t task, yc_uintptr_t address, yc_uintptr_t size)
{
    return mach_vm_deallocate(task, address, size);
}

YC_EXPORT int vm_protect(yc_port_t task, yc_uintptr_t address, yc_uintptr_t size, int set_maximum,
                         int new_protection)
{
    return mach_vm_protect(task, address, size, set_maximum, new_protection);
}

YC_EXPORT int vm_purgable_control(yc_port_t task, yc_uintptr_t address, int control, int *state)
{
    return mach_vm_purgable_control(task, address, control, state);
}

/* --------------------------------------------- semaphores (-33..-39) */

typedef struct {
    yc_u32 tv_sec;
    int tv_nsec;
} yc_mach_timespec_t;

YC_EXPORT int semaphore_signal(yc_port_t semaphore)
{
    return (int)YC_MACH1(YC_TRAP_SEMAPHORE_SIGNAL, semaphore);
}

YC_EXPORT int semaphore_signal_all(yc_port_t semaphore)
{
    return (int)YC_MACH1(YC_TRAP_SEMAPHORE_SIGNAL_ALL, semaphore);
}

YC_EXPORT int semaphore_signal_thread(yc_port_t semaphore, yc_port_t thread)
{
    return (int)YC_MACH2(YC_TRAP_SEMAPHORE_SIGNAL_THREAD, semaphore, thread);
}

YC_EXPORT int semaphore_wait(yc_port_t semaphore)
{
    return (int)YC_MACH1(YC_TRAP_SEMAPHORE_WAIT, semaphore);
}

YC_EXPORT int semaphore_wait_signal(yc_port_t wait_semaphore, yc_port_t signal_semaphore)
{
    return (int)YC_MACH2(YC_TRAP_SEMAPHORE_WAIT_SIGNAL, wait_semaphore, signal_semaphore);
}

YC_EXPORT int semaphore_timedwait(yc_port_t semaphore, yc_mach_timespec_t wait_time)
{
    return (int)YC_MACH3(YC_TRAP_SEMAPHORE_TIMEDWAIT, semaphore, wait_time.tv_sec,
                         (yc_intptr_t)wait_time.tv_nsec);
}

YC_EXPORT int semaphore_timedwait_signal(yc_port_t wait_semaphore, yc_port_t signal_semaphore,
                                         yc_mach_timespec_t wait_time)
{
    return (int)YC_MACH4(YC_TRAP_SEMAPHORE_TIMEDWAIT_SIGNAL, wait_semaphore, signal_semaphore, wait_time.tv_sec,
                         (yc_intptr_t)wait_time.tv_nsec);
}

/* -------------------------------------------------------------- mach_msg */

#define YC_MACH_SEND_MSG 0x00000001u
#define YC_MACH_RCV_MSG 0x00000002u
#define YC_MACH_SEND_INTERRUPT 0x00000040u
#define YC_MACH_RCV_INTERRUPT 0x00000400u
#define YC_MACH_SEND_INTERRUPTED 0x10000007
#define YC_MACH_RCV_INTERRUPTED 0x10004005

struct yc_mach_msg_header {
    yc_u32 msgh_bits;
    yc_u32 msgh_size;
    yc_port_t msgh_remote_port;
    yc_port_t msgh_local_port;
    yc_port_t msgh_voucher_port;
    int msgh_id;
};

/* mach_msg_return_t mach_msg(mach_msg_header_t *msg, mach_msg_option_t
 *     option, mach_msg_size_t send_size, mach_msg_size_t rcv_size,
 *     mach_port_name_t rcv_name, mach_msg_timeout_t timeout,
 *     mach_port_name_t notify)
 * An interrupted send or receive is restarted unless the caller asked to
 * see interruptions; after a completed send only the receive is redone. */
YC_EXPORT int mach_msg(struct yc_mach_msg_header *msg, yc_u32 option, yc_u32 send_size, yc_u32 rcv_size,
                       yc_port_t rcv_name, yc_u32 timeout, yc_port_t notify)
{
    for (;;) {
        int mr = (int)yc_mach_trap(YC_TRAP_MACH_MSG, (yc_uintptr_t)msg, option, send_size, rcv_size, rcv_name,
                                   timeout, notify);
        if (mr == YC_MACH_SEND_INTERRUPTED && !(option & YC_MACH_SEND_INTERRUPT))
            continue;
        if (mr == YC_MACH_RCV_INTERRUPTED && !(option & YC_MACH_RCV_INTERRUPT)) {
            option &= ~YC_MACH_SEND_MSG;
            continue;
        }
        return mr;
    }
}

/* mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout,
 *     notify, rcv_msg, rcv_limit): the ninth argument (rcv_limit) is not
 * passed to the trap, so it is not read here. */
YC_EXPORT int mach_msg_overwrite(struct yc_mach_msg_header *msg, yc_u32 option, yc_u32 send_size, yc_u32 rcv_size,
                                 yc_port_t rcv_name, yc_u32 timeout, yc_port_t notify,
                                 struct yc_mach_msg_header *rcv_msg)
{
    register yc_uintptr_t x7 __asm__("x7") = (yc_uintptr_t)rcv_msg;
    for (;;) {
        register yc_uintptr_t x0 __asm__("x0") = (yc_uintptr_t)msg;
        register yc_uintptr_t x1 __asm__("x1") = option;
        register yc_uintptr_t x2 __asm__("x2") = send_size;
        register yc_uintptr_t x3 __asm__("x3") = rcv_size;
        register yc_uintptr_t x4 __asm__("x4") = rcv_name;
        register yc_uintptr_t x5 __asm__("x5") = timeout;
        register yc_uintptr_t x6 __asm__("x6") = notify;
        register long x16 __asm__("x16") = YC_TRAP_MACH_MSG_OVERWRITE;
        __asm__ volatile("svc #0x80"
                         : "+r"(x0), "+r"(x1)
                         : "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x6), "r"(x7), "r"(x16)
                         : "memory", "cc");
        int mr = (int)x0;
        if (mr == YC_MACH_SEND_INTERRUPTED && !(option & YC_MACH_SEND_INTERRUPT))
            continue;
        if (mr == YC_MACH_RCV_INTERRUPTED && !(option & YC_MACH_RCV_INTERRUPT)) {
            option &= ~YC_MACH_SEND_MSG;
            continue;
        }
        return mr;
    }
}

YC_EXPORT int mach_msg_send(struct yc_mach_msg_header *msg)
{
    return mach_msg(msg, YC_MACH_SEND_MSG, msg->msgh_size, 0, YC_MACH_PORT_NULL, 0, YC_MACH_PORT_NULL);
}

YC_EXPORT int mach_msg_receive(struct yc_mach_msg_header *msg)
{
    return mach_msg(msg, YC_MACH_RCV_MSG, 0, msg->msgh_size, msg->msgh_local_port, 0, YC_MACH_PORT_NULL);
}

/* ------------------------------------------------------ MIG reply ports */

#define YC_MACH_PORT_RIGHT_RECEIVE 1u

/* Used while no TSD base is set (single-threaded early start). */
static yc_port_t yc_reply_port_no_tsd;
static yc_port_t yc_special_reply_port_no_tsd;

/* The port cached in TSD slot `slot` (or in *fallback without a TSD),
 * created with the given port-returning trap when there is none. */
static yc_port_t cached_port_get(int slot, yc_port_t *fallback, long trap)
{
    yc_uintptr_t *tsd = yc_tsd_base();
    yc_port_t port = tsd ? (yc_port_t)tsd[slot] : *fallback;
    if (port == YC_MACH_PORT_NULL) {
        port = (yc_port_t)YC_MACH0(trap);
        if (tsd)
            tsd[slot] = port;
        else
            *fallback = port;
    }
    return port;
}

/* Forget the cached port and drop its receive right. */
static void cached_port_dealloc(int slot, yc_port_t *fallback, yc_port_t given)
{
    yc_uintptr_t *tsd = yc_tsd_base();
    yc_port_t port = tsd ? (yc_port_t)tsd[slot] : *fallback;
    if (tsd)
        tsd[slot] = 0;
    else
        *fallback = YC_MACH_PORT_NULL;
    if (port == YC_MACH_PORT_NULL)
        port = given;
    if (port != YC_MACH_PORT_NULL)
        (void)mach_port_mod_refs(mach_task_self_, port, YC_MACH_PORT_RIGHT_RECEIVE, -1);
}

/* mach_port_t mig_get_reply_port(void): TSD slot 2, from Mach trap -26
 * (mach_reply_port) on first use. */
YC_EXPORT yc_port_t mig_get_reply_port(void)
{
    return cached_port_get(YC_TSD_MIG_REPLY, &yc_reply_port_no_tsd, YC_TRAP_REPLY_PORT);
}

YC_EXPORT void mig_dealloc_reply_port(yc_port_t reply_port)
{
    cached_port_dealloc(YC_TSD_MIG_REPLY, &yc_reply_port_no_tsd, reply_port);
}

/* void mig_put_reply_port(mach_port_t reply_port): nothing to do. */
YC_EXPORT void mig_put_reply_port(yc_port_t reply_port)
{
    (void)reply_port;
}

/* mach_port_t mig_get_special_reply_port(void): TSD slot 8, from Mach trap
 * -50 (thread_get_special_reply_port) on first use. */
YC_EXPORT yc_port_t mig_get_special_reply_port(void)
{
    return cached_port_get(YC_TSD_MACH_SPECIAL_REPLY, &yc_special_reply_port_no_tsd, YC_TRAP_SPECIAL_REPLY_PORT);
}

YC_EXPORT void mig_dealloc_special_reply_port(yc_port_t migport)
{
    cached_port_dealloc(YC_TSD_MACH_SPECIAL_REPLY, &yc_special_reply_port_no_tsd, migport);
}

/* void mig_deallocate(vm_address_t addr, vm_size_t size) */
YC_EXPORT void mig_deallocate(yc_uintptr_t addr, yc_uintptr_t size)
{
    (void)vm_deallocate(mach_task_self_, addr, size);
}

/* int mig_strncpy(char *dest, const char *src, int len): copies at most
 * len - 1 characters, always terminates dest when len > 0, and returns the
 * number of bytes written including the terminator. The _zerofill form
 * also clears the rest of dest. */
static int mig_copy(char *dest, const char *src, int len, int zerofill)
{
    int i = 0;
    if (dest == YC_NULL || len <= 0)
        return 0;
    if (src != YC_NULL)
        while (i < len - 1 && src[i] != '\0') {
            dest[i] = src[i];
            i++;
        }
    dest[i++] = '\0';
    if (zerofill)
        for (int j = i; j < len; j++)
            dest[j] = '\0';
    return i;
}

YC_EXPORT int mig_strncpy(char *dest, const char *src, int len)
{
    return mig_copy(dest, src, len, 0);
}

YC_EXPORT int mig_strncpy_zerofill(char *dest, const char *src, int len)
{
    return mig_copy(dest, src, len, 1);
}

/* ------------------------------------------------------------- host_info */

#define YC_HOST_PRIORITY_INFO 5
#define YC_HOST_PRIORITY_INFO_COUNT 8u

/* kern_return_t host_info(host_t host, host_flavor_t flavor,
 *     host_info_t info, mach_msg_type_number_t *count)
 * HOST_PRIORITY_INFO is answered here (contract section 7.5): kernel 80,
 * system 80, server 64, user 31, depress 0, idle 0, minimum 0,
 * maximum 79. Other flavors are not implemented yet. */
YC_EXPORT int host_info(yc_port_t host, int flavor, int *info, yc_u32 *count)
{
    (void)host;
    if (flavor == YC_HOST_PRIORITY_INFO) {
        static const int prio[YC_HOST_PRIORITY_INFO_COUNT] = {80, 80, 64, 31, 0, 0, 0, 79};
        if (info == YC_NULL || count == YC_NULL || *count < YC_HOST_PRIORITY_INFO_COUNT)
            return YC_KERN_FAILURE;
        for (unsigned i = 0; i < YC_HOST_PRIORITY_INFO_COUNT; i++)
            info[i] = prio[i];
        *count = YC_HOST_PRIORITY_INFO_COUNT;
        return YC_KERN_SUCCESS;
    }
    yc_unimplemented("host_info (flavor other than HOST_PRIORITY_INFO)");
    return YC_KERN_NOT_SUPPORTED;
}

/* kern_return_t host_page_size(host_t host, vm_size_t *size) */
YC_EXPORT int host_page_size(yc_port_t host, yc_uintptr_t *size)
{
    (void)host;
    if (size == YC_NULL)
        return YC_KERN_INVALID_ARGUMENT;
    *size = vm_kernel_page_size;
    return YC_KERN_SUCCESS;
}

/* ------------------------------------------------ voucher message hooks */

/* Forwarded to libdispatch's table (host-library-init.md section 2.3);
 * without it: set -> FALSE, adopt -> VOUCHER_MACH_MSG_STATE_UNCHANGED,
 * the others do nothing. */
#define YC_VOUCHER_MACH_MSG_STATE_UNCHANGED ((void *)~(yc_uintptr_t)0)

YC_EXPORT int voucher_mach_msg_set(void *msg)
{
    const struct yc_libkernel_voucher_functions *v = yc_libkernel_voucher_fns;
    if (v != YC_NULL && v->voucher_mach_msg_set != YC_NULL)
        return v->voucher_mach_msg_set(msg);
    return 0;
}

YC_EXPORT void voucher_mach_msg_clear(void *msg)
{
    const struct yc_libkernel_voucher_functions *v = yc_libkernel_voucher_fns;
    if (v != YC_NULL && v->voucher_mach_msg_clear != YC_NULL)
        v->voucher_mach_msg_clear(msg);
}

YC_EXPORT void *voucher_mach_msg_adopt(void *msg)
{
    const struct yc_libkernel_voucher_functions *v = yc_libkernel_voucher_fns;
    if (v != YC_NULL && v->voucher_mach_msg_adopt != YC_NULL)
        return v->voucher_mach_msg_adopt(msg);
    return YC_VOUCHER_MACH_MSG_STATE_UNCHANGED;
}

YC_EXPORT void voucher_mach_msg_revert(void *state)
{
    const struct yc_libkernel_voucher_functions *v = yc_libkernel_voucher_fns;
    if (v != YC_NULL && v->voucher_mach_msg_revert != YC_NULL)
        v->voucher_mach_msg_revert(state);
}
