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
 *    such as MACH_PORT_RIGHT_*, MACH_PORT_TYPE_*, MPG_*, mach_timespec_t
 *    and the thread_destruct_special_reply_port rights selector;
 *  - port-routine behavior (mach_port_destroy, guard flags, special reply
 *    ports, vouchers): mach-ipc.md sections 1.7, 4.2 and 4.3;
 *  - Ycode-private Mach-routine traps x16 = 0x7963_2000 + n:
 *    host-libraries.md section 10; n = 7 (host_create_mach_voucher):
 *    stage4a-contract.md section 7; n = 8/9 (mach_ports_register3 /
 *    lookup3): stage4b-contract.md section 3.7, processes.md section 3.4.
 * The message routines (mach_msg, mach_msg2_internal, ...) are in
 * machmsg.c.
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

/* kern_return_t mach_get_times(uint64_t *absolute_time,
 *     uint64_t *continuous_time, struct timespec *tp)
 * absolute = trap -3, continuous = trap -4, tp = the wall clock from BSD
 * 116 (__gettimeofday, which fills a struct timeval) converted to a
 * struct timespec. Every pointer may be NULL. */
struct yc_timeval {
    yc_i64 tv_sec;
    yc_i32 tv_usec;
};
struct yc_timespec {
    yc_i64 tv_sec;
    yc_i64 tv_nsec;
};
int __gettimeofday(struct yc_timeval *tp, void *tzp, yc_u64 *mach_time);

YC_EXPORT int mach_get_times(yc_u64 *absolute_time, yc_u64 *continuous_time, struct yc_timespec *tp)
{
    if (tp != YC_NULL) {
        struct yc_timeval tv = {0, 0};
        if (__gettimeofday(&tv, YC_NULL, YC_NULL) != 0)
            return YC_KERN_FAILURE;
        tp->tv_sec = tv.tv_sec;
        tp->tv_nsec = (yc_i64)tv.tv_usec * 1000;
    }
    if (absolute_time != YC_NULL)
        *absolute_time = mach_absolute_time();
    if (continuous_time != YC_NULL)
        *continuous_time = mach_continuous_time();
    return YC_KERN_SUCCESS;
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

/* kern_return_t mach_port_guard_with_flags(ipc_space_t task,
 *     mach_port_name_t name, mach_port_context_t guard, uint64_t flags)
 * MPG_STRICT (0x01) maps onto the guard trap's strict argument.
 * MPG_IMMOVABLE_RECEIVE (0x02) is accepted; the guard trap cannot record
 * it, so immovability is not enforced (mach-ipc.md section 1.7). */
#define YC_MPG_STRICT 0x01u
#define YC_MPG_IMMOVABLE_RECEIVE 0x02u

YC_EXPORT int mach_port_guard_with_flags(yc_port_t task, yc_port_t name, yc_u64 guard, yc_u64 flags)
{
    if (flags & ~(yc_u64)(YC_MPG_STRICT | YC_MPG_IMMOVABLE_RECEIVE))
        return YC_KERN_INVALID_ARGUMENT;
    return mach_port_guard(task, name, guard, (flags & YC_MPG_STRICT) ? 1 : 0);
}

/* kern_return_t mach_port_destroy(ipc_space_t task, mach_port_name_t name)
 * Removes every right of the name (mach-ipc.md section 1.7), built from
 * the port traps: a port set or send-once right is dropped with mod_refs;
 * a receive right is destroyed (any send rights then become a dead name);
 * the remaining send or dead-name urefs are dropped one at a time until the
 * name is gone. NULL and DEAD succeed with no effect. */
YC_EXPORT int mach_port_destroy(yc_port_t task, yc_port_t name)
{
    if (name == YC_MACH_PORT_NULL || name == YC_MACH_PORT_DEAD)
        return YC_KERN_SUCCESS;
    yc_u32 type = 0;
    int kr = mach_port_type(task, name, &type);
    if (kr != YC_KERN_SUCCESS)
        return kr;
    if (type & YC_MACH_PORT_TYPE_PORT_SET)
        return mach_port_mod_refs(task, name, YC_MACH_PORT_RIGHT_PORT_SET, -1);
    if (type & YC_MACH_PORT_TYPE_SEND_ONCE)
        return mach_port_mod_refs(task, name, YC_MACH_PORT_RIGHT_SEND_ONCE, -1);
    if (type & YC_MACH_PORT_TYPE_RECEIVE) {
        kr = mach_port_mod_refs(task, name, YC_MACH_PORT_RIGHT_RECEIVE, -1);
        if (kr != YC_KERN_SUCCESS)
            return kr;
    }
    /* Send or dead-name urefs are at most 0xFFFF. */
    for (yc_u32 i = 0; i <= 0x10000u; i++) {
        if (mach_port_type(task, name, &type) != YC_KERN_SUCCESS)
            return YC_KERN_SUCCESS; /* the name is gone */
        if (!(type & (YC_MACH_PORT_TYPE_SEND | YC_MACH_PORT_TYPE_DEAD_NAME)))
            return YC_KERN_SUCCESS;
        if (mach_port_deallocate(task, name) != YC_KERN_SUCCESS)
            return YC_KERN_SUCCESS;
    }
    return YC_KERN_SUCCESS;
}

/* The MIG-routine names of the port routines that have a trap
 * (_kernelrpc_mach_port_*; the MIG fallback the library uses when a trap
 * rejects a task other than the caller's). Ycode's kernel serves the
 * caller's own space through the traps, so these use the traps too. Same
 * C signatures as the mach_port_* routines above. */
YC_EXPORT int _kernelrpc_mach_port_allocate(yc_port_t task, yc_u32 right, yc_port_t *name)
{
    return mach_port_allocate(task, right, name);
}

YC_EXPORT int _kernelrpc_mach_port_deallocate(yc_port_t task, yc_port_t name)
{
    return mach_port_deallocate(task, name);
}

YC_EXPORT int _kernelrpc_mach_port_mod_refs(yc_port_t task, yc_port_t name, yc_u32 right, int delta)
{
    return mach_port_mod_refs(task, name, right, delta);
}

YC_EXPORT int _kernelrpc_mach_port_move_member(yc_port_t task, yc_port_t member, yc_port_t after)
{
    return mach_port_move_member(task, member, after);
}

YC_EXPORT int _kernelrpc_mach_port_insert_right(yc_port_t task, yc_port_t name, yc_port_t poly, yc_u32 poly_poly)
{
    return mach_port_insert_right(task, name, poly, poly_poly);
}

YC_EXPORT int _kernelrpc_mach_port_insert_member(yc_port_t task, yc_port_t name, yc_port_t pset)
{
    return mach_port_insert_member(task, name, pset);
}

YC_EXPORT int _kernelrpc_mach_port_extract_member(yc_port_t task, yc_port_t name, yc_port_t pset)
{
    return mach_port_extract_member(task, name, pset);
}

YC_EXPORT int _kernelrpc_mach_port_construct(yc_port_t task, void *options, yc_u64 context, yc_port_t *name)
{
    return mach_port_construct(task, options, context, name);
}

YC_EXPORT int _kernelrpc_mach_port_destruct(yc_port_t task, yc_port_t name, int srdelta, yc_u64 guard)
{
    return mach_port_destruct(task, name, srdelta, guard);
}

YC_EXPORT int _kernelrpc_mach_port_get_attributes(yc_port_t task, yc_port_t name, int flavor, void *info,
                                                  yc_u32 *count)
{
    return mach_port_get_attributes(task, name, flavor, info, count);
}

YC_EXPORT int _kernelrpc_mach_port_guard(yc_port_t task, yc_port_t name, yc_u64 guard, int strict)
{
    return mach_port_guard(task, name, guard, strict);
}

YC_EXPORT int _kernelrpc_mach_port_guard_with_flags(yc_port_t task, yc_port_t name, yc_u64 guard, yc_u64 flags)
{
    return mach_port_guard_with_flags(task, name, guard, flags);
}

YC_EXPORT int _kernelrpc_mach_port_unguard(yc_port_t task, yc_port_t name, yc_u64 guard)
{
    return mach_port_unguard(task, name, guard);
}

YC_EXPORT int _kernelrpc_mach_port_type(yc_port_t task, yc_port_t name, yc_u32 *ptype)
{
    return mach_port_type(task, name, ptype);
}

YC_EXPORT int _kernelrpc_mach_port_request_notification(yc_port_t task, yc_port_t name, int msgid, yc_u32 sync,
                                                        yc_port_t notify, yc_u32 notify_poly, yc_port_t *previous)
{
    return mach_port_request_notification(task, name, msgid, sync, notify, notify_poly, previous);
}

YC_EXPORT int _kernelrpc_mach_port_destroy(yc_port_t task, yc_port_t name)
{
    return mach_port_destroy(task, name);
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

/* ------------------------------------------------------ MIG reply ports */

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

/* Forget the cached port and return its name (or `given` if none was
 * cached). */
static yc_port_t cached_port_forget(int slot, yc_port_t *fallback, yc_port_t given)
{
    yc_uintptr_t *tsd = yc_tsd_base();
    yc_port_t port = tsd ? (yc_port_t)tsd[slot] : *fallback;
    if (tsd)
        tsd[slot] = 0;
    else
        *fallback = YC_MACH_PORT_NULL;
    return port != YC_MACH_PORT_NULL ? port : given;
}

/* Forget the cached port and drop its receive right (the MIG reply port
 * holds a receive right only, mach-ipc.md section 4.1). */
static void cached_port_dealloc(int slot, yc_port_t *fallback, yc_port_t given)
{
    yc_port_t port = cached_port_forget(slot, fallback, given);
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

/* kern_return_t thread_destruct_special_reply_port(mach_port_name_t port,
 *     thread_destruct_special_reply_port_rights_t rights)
 * A special reply port holds a receive right and a send right under one
 * name (mach-ipc.md section 4.2). The rights selector is the public enum
 * THREAD_SPECIAL_REPLY_PORT_ALL (0), _RECEIVE_ONLY (1), _SEND_ONLY (2). */
#define YC_SRP_ALL 0
#define YC_SRP_RECEIVE_ONLY 1
#define YC_SRP_SEND_ONLY 2

YC_EXPORT int thread_destruct_special_reply_port(yc_port_t port, int rights)
{
    switch (rights) {
    case YC_SRP_ALL: {
        /* Receive right plus the one send uref; fall back to the receive
         * right alone if the send right is already gone. */
        int kr = mach_port_destruct(mach_task_self_, port, -1, 0);
        if (kr != YC_KERN_SUCCESS)
            kr = mach_port_mod_refs(mach_task_self_, port, YC_MACH_PORT_RIGHT_RECEIVE, -1);
        return kr;
    }
    case YC_SRP_RECEIVE_ONLY:
        return mach_port_mod_refs(mach_task_self_, port, YC_MACH_PORT_RIGHT_RECEIVE, -1);
    case YC_SRP_SEND_ONLY:
        return mach_port_deallocate(mach_task_self_, port);
    default:
        return YC_KERN_INVALID_ARGUMENT;
    }
}

YC_EXPORT void mig_dealloc_special_reply_port(yc_port_t migport)
{
    yc_port_t port = cached_port_forget(YC_TSD_MACH_SPECIAL_REPLY, &yc_special_reply_port_no_tsd, migport);
    if (port != YC_MACH_PORT_NULL)
        (void)thread_destruct_special_reply_port(port, YC_SRP_ALL);
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

/* host_t host_self(void): the same name as mach_host_self(). */
YC_EXPORT yc_port_t host_self(void)
{
    return mach_host_self();
}

/* The MIG-routine name of host_page_size. */
YC_EXPORT int _host_page_size(yc_port_t host, yc_uintptr_t *size)
{
    return host_page_size(host, size);
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

/* ------------------------------------- Ycode-private Mach routines (§10) */

/* MIG routines that Ycode's VMM answers directly: x16 = 0x7963_2000 + n,
 * the C arguments in x0-x3, a kern_return_t back in x0, no carry. The VMM
 * writes the out-parameters. */
#define YC_PRIV_ROUTINE(n) ((long)(0x79632000u + (n)))
#define YC_PRIV_HOST_GET_CLOCK_SERVICE 1
#define YC_PRIV_CLOCK_GET_TIME 2
#define YC_PRIV_SEMAPHORE_CREATE 3
#define YC_PRIV_SEMAPHORE_DESTROY 4
#define YC_PRIV_TASK_GET_SPECIAL_PORT 5
#define YC_PRIV_TASK_SET_SPECIAL_PORT 6
#define YC_PRIV_HOST_CREATE_MACH_VOUCHER 7
#define YC_PRIV_MACH_PORTS_REGISTER3 8
#define YC_PRIV_MACH_PORTS_LOOKUP3 9
#define YC_PRIV_MAKE_MEMORY_ENTRY 10
#define YC_PRIV_VM_MAP_OBJECT 11

/* kern_return_t mach_make_memory_entry_64(vm_map_t target_task,
 *     memory_object_size_t *size, memory_object_offset_t offset,
 *     vm_prot_t permission, mach_port_t *object_handle,
 *     mem_entry_name_port_t parent_entry)
 * The VMM makes the entry (shared memory) and writes *size and *object_handle. */
YC_EXPORT int mach_make_memory_entry_64(yc_port_t task, yc_u64 *size, yc_u64 offset, int permission,
                                        yc_port_t *object_handle, yc_port_t parent_entry)
{
    return (int)yc_mach_trap(YC_PRIV_ROUTINE(YC_PRIV_MAKE_MEMORY_ENTRY), task, (yc_uintptr_t)size, offset,
                             (yc_uintptr_t)(unsigned)permission, (yc_uintptr_t)object_handle, parent_entry, 0);
}

/* mach_make_memory_entry: vm_size_t and vm_offset_t are 64-bit on LP64. */
YC_EXPORT int mach_make_memory_entry(yc_port_t task, yc_uintptr_t *size, yc_uintptr_t offset, int permission,
                                     yc_port_t *object_handle, yc_port_t parent_entry)
{
    return mach_make_memory_entry_64(task, (yc_u64 *)size, offset, permission, object_handle, parent_entry);
}

/* kern_return_t mach_vm_map(vm_map_t target, mach_vm_address_t *address,
 *     mach_vm_size_t size, mach_vm_offset_t mask, int flags,
 *     mem_entry_name_port_t object, memory_object_offset_t offset,
 *     boolean_t copy, vm_prot_t cur, vm_prot_t max, vm_inherit_t inherit)
 * Anonymous memory (no object, no offset) is Mach trap -15
 * (target, &address, size, mask, flags, cur); a memory object goes to the
 * private routine with the rest in a block. vm_map has the same layout on LP64. */
YC_EXPORT int mach_vm_map(yc_port_t target, yc_u64 *address, yc_u64 size, yc_u64 mask, int flags, yc_port_t object,
                          yc_u64 offset, int copy, int cur, int max, int inherit)
{
    if (object == 0 && offset == 0)
        return (int)yc_mach_trap(-15, target, (yc_uintptr_t)address, size, mask, (yc_uintptr_t)(unsigned)flags,
                                 (yc_uintptr_t)(unsigned)cur, 0);
    yc_u64 block[6] = {object, offset, (yc_u64)(unsigned)copy, (yc_u64)(unsigned)cur, (yc_u64)(unsigned)max,
                       (yc_u64)(unsigned)inherit};
    return (int)yc_mach_trap(YC_PRIV_ROUTINE(YC_PRIV_VM_MAP_OBJECT), target, (yc_uintptr_t)address, size, mask,
                             (yc_uintptr_t)(unsigned)flags, (yc_uintptr_t)block, 0);
}

YC_EXPORT int vm_map(yc_port_t target, yc_uintptr_t *address, yc_uintptr_t size, yc_uintptr_t mask, int flags,
                     yc_port_t object, yc_uintptr_t offset, int copy, int cur, int max, int inherit)
{
    return mach_vm_map(target, (yc_u64 *)address, size, mask, flags, object, offset, copy, cur, max, inherit);
}

/* kern_return_t host_get_clock_service(host_t host, clock_id_t clock_id,
 *     clock_serv_t *clock_serv) */
YC_EXPORT int host_get_clock_service(yc_port_t host, int clock_id, yc_port_t *clock_serv)
{
    return (int)YC_MACH3(YC_PRIV_ROUTINE(YC_PRIV_HOST_GET_CLOCK_SERVICE), host, (yc_intptr_t)clock_id,
                         clock_serv);
}

/* kern_return_t clock_get_time(clock_serv_t clock_serv,
 *     mach_timespec_t *cur_time) */
YC_EXPORT int clock_get_time(yc_port_t clock_serv, yc_mach_timespec_t *cur_time)
{
    return (int)YC_MACH2(YC_PRIV_ROUTINE(YC_PRIV_CLOCK_GET_TIME), clock_serv, cur_time);
}

/* kern_return_t semaphore_create(task_t task, semaphore_t *semaphore,
 *     int policy, int value) */
YC_EXPORT int semaphore_create(yc_port_t task, yc_port_t *semaphore, int policy, int value)
{
    return (int)YC_MACH4(YC_PRIV_ROUTINE(YC_PRIV_SEMAPHORE_CREATE), task, semaphore, (yc_intptr_t)policy,
                         (yc_intptr_t)value);
}

/* kern_return_t semaphore_destroy(task_t task, semaphore_t semaphore) */
YC_EXPORT int semaphore_destroy(yc_port_t task, yc_port_t semaphore)
{
    return (int)YC_MACH2(YC_PRIV_ROUTINE(YC_PRIV_SEMAPHORE_DESTROY), task, semaphore);
}

/* kern_return_t task_get_special_port(task_t task, int which_port,
 *     mach_port_t *special_port) */
YC_EXPORT int task_get_special_port(yc_port_t task, int which_port, yc_port_t *special_port)
{
    return (int)YC_MACH3(YC_PRIV_ROUTINE(YC_PRIV_TASK_GET_SPECIAL_PORT), task, (yc_intptr_t)which_port,
                         special_port);
}

/* kern_return_t task_set_special_port(task_t task, int which_port,
 *     mach_port_t special_port) */
YC_EXPORT int task_set_special_port(yc_port_t task, int which_port, yc_port_t special_port)
{
    return (int)YC_MACH3(YC_PRIV_ROUTINE(YC_PRIV_TASK_SET_SPECIAL_PORT), task, (yc_intptr_t)which_port,
                         special_port);
}

/* ------------------------------------------------------ registered ports */

/* Three slots per task (TASK_PORT_REGISTER_MAX, processes.md section 3.4).
 * The private traps take exactly three ports (stage4b-contract.md
 * section 3.7): n = 8 mach_ports_register3(task, p0, p1, p2) copies each
 * non-null name in as COPY_SEND; n = 9 mach_ports_lookup3(task, &p0, &p1,
 * &p2) writes a new send right (or 0 / MACH_PORT_DEAD) per slot. */
#define YC_TASK_PORT_REGISTER_MAX 3u
#define YC_VM_FLAGS_ANYWHERE 1

/* kern_return_t mach_ports_register(task_t target_task,
 *     mach_port_array_t init_port_set, mach_msg_type_number_t count):
 * count > 3 -> KERN_INVALID_ARGUMENT; the array is padded with NULL. */
YC_EXPORT int mach_ports_register(yc_port_t task, const yc_port_t *ports, yc_u32 count)
{
    yc_port_t p[YC_TASK_PORT_REGISTER_MAX] = {YC_MACH_PORT_NULL, YC_MACH_PORT_NULL, YC_MACH_PORT_NULL};
    if (count > YC_TASK_PORT_REGISTER_MAX || (count > 0 && ports == YC_NULL))
        return YC_KERN_INVALID_ARGUMENT;
    for (yc_u32 i = 0; i < count; i++)
        p[i] = ports[i];
    return (int)YC_MACH4(YC_PRIV_ROUTINE(YC_PRIV_MACH_PORTS_REGISTER3), task, p[0], p[1], p[2]);
}

/* kern_return_t mach_ports_lookup(task_t target_task,
 *     mach_port_array_t *init_port_set, mach_msg_type_number_t *count):
 * the three names go into one page-rounded vm_allocate region, which the
 * caller frees with vm_deallocate; *count = 3. The region is allocated in
 * the calling task (the only space whose memory the caller can read; it
 * is the target in every normal use). On failure it is freed again. */
YC_EXPORT int mach_ports_lookup(yc_port_t task, yc_port_t **ports, yc_u32 *count)
{
    if (ports == YC_NULL || count == YC_NULL)
        return YC_KERN_INVALID_ARGUMENT;
    yc_uintptr_t size = (YC_TASK_PORT_REGISTER_MAX * sizeof(yc_port_t) + vm_page_size - 1) & ~(vm_page_size - 1);
    yc_uintptr_t addr = 0;
    int kr = vm_allocate(mach_task_self_, &addr, size, YC_VM_FLAGS_ANYWHERE);
    if (kr != YC_KERN_SUCCESS)
        return kr;
    yc_port_t *a = (yc_port_t *)addr;
    kr = (int)YC_MACH4(YC_PRIV_ROUTINE(YC_PRIV_MACH_PORTS_LOOKUP3), task, &a[0], &a[1], &a[2]);
    if (kr != YC_KERN_SUCCESS) {
        (void)vm_deallocate(mach_task_self_, addr, size);
        return kr;
    }
    *ports = a;
    *count = YC_TASK_PORT_REGISTER_MAX;
    return YC_KERN_SUCCESS;
}

/* ------------------------------------------------------------- vouchers */

/* kern_return_t host_create_mach_voucher(host_t host,
 *     mach_voucher_attr_raw_recipe_array_t recipes,
 *     mach_msg_type_number_t recipesCnt, ipc_voucher_t *voucher)
 * Private trap 7 (stage4a-contract.md section 7): the VMM returns
 * KERN_SUCCESS and writes *voucher = 0 (mach-ipc.md section 4.3). */
YC_EXPORT int host_create_mach_voucher(yc_port_t host, const void *recipes, yc_u32 recipes_size,
                                       yc_port_t *voucher)
{
    return (int)YC_MACH4(YC_PRIV_ROUTINE(YC_PRIV_HOST_CREATE_MACH_VOUCHER), host, recipes, recipes_size, voucher);
}

/* The MIG-routine name of the same call. */
YC_EXPORT int _kernelrpc_host_create_mach_voucher(yc_port_t host, const void *recipes, yc_u32 recipes_size,
                                                  yc_port_t *voucher)
{
    return host_create_mach_voucher(host, recipes, recipes_size, voucher);
}

/* kern_return_t mach_voucher_extract_attr_recipe(ipc_voucher_t voucher,
 *     mach_voucher_attr_key_t key, mach_voucher_attr_raw_recipe_t recipe,
 *     mach_msg_type_number_t *recipeCnt): Mach trap -72 with the same
 * arguments. Name 0 or a name that is not a voucher gives
 * MACH_SEND_INVALID_DEST (mach-ipc.md section 4.3). */
YC_EXPORT int mach_voucher_extract_attr_recipe(yc_port_t voucher, yc_u32 key, void *recipe, yc_u32 *recipe_size)
{
    return (int)YC_MACH4(YC_TRAP_VOUCHER_EXTRACT_ATTR_RECIPE, voucher, key, recipe, recipe_size);
}

YC_EXPORT int _kernelrpc_mach_voucher_extract_attr_recipe(yc_port_t voucher, yc_u32 key, void *recipe,
                                                          yc_u32 *recipe_size)
{
    return mach_voucher_extract_attr_recipe(voucher, key, recipe, recipe_size);
}

/* kern_return_t mach_voucher_deallocate(mach_voucher_t voucher): a voucher
 * name is a send right, so this drops one uref; name 0 succeeds
 * (mach-ipc.md sections 1.7 and 4.3). */
YC_EXPORT int mach_voucher_deallocate(yc_port_t voucher)
{
    return mach_port_deallocate(mach_task_self_, voucher);
}

/* kern_return_t mach_voucher_attr_command(ipc_voucher_t voucher,
 *     mach_voucher_attr_key_t key, mach_voucher_attr_command_t command,
 *     mach_voucher_attr_content_t in_content,
 *     mach_msg_type_number_t in_contentCnt,
 *     mach_voucher_attr_content_t out_content,
 *     mach_msg_type_number_t *out_contentCnt)
 * A MIG call on the voucher port. Ycode's kernel creates no voucher
 * objects (every voucher name is 0), so there is never a voucher server to
 * reach: the result is MACH_SEND_INVALID_DEST, which libdispatch tolerates
 * (mach-ipc.md section 4.3). */
YC_EXPORT int mach_voucher_attr_command(yc_port_t voucher, yc_u32 key, yc_u32 command, const void *in_content,
                                        yc_u32 in_size, void *out_content, yc_u32 *out_size)
{
    (void)voucher;
    (void)key;
    (void)command;
    (void)in_content;
    (void)in_size;
    (void)out_content;
    (void)out_size;
    return YC_MACH_SEND_INVALID_DEST;
}

/* kern_return_t task_info(task_name_t target_task, task_flavor_t flavor,
 *     task_info_t task_info_out, mach_msg_type_number_t *task_info_outCnt)
 * The VMM's private task_info trap (0x7963_0006): TASK_DYLD_INFO (17) and
 * TASK_AUDIT_TOKEN (15) of the caller's own task; other flavors
 * KERN_INVALID_ARGUMENT. libxpc reads its own audit token at start. */
YC_EXPORT int task_info(yc_port_t task, int flavor, void *task_info_out, yc_u32 *task_info_outCnt)
{
    return (int)YC_MACH4(0x79630006L, task, (yc_uintptr_t)(unsigned)flavor, task_info_out, task_info_outCnt);
}

#define YC_PRIV_VM_REMAP 12
#define YC_PRIV_TASK_THREADS 13

/* kern_return_t mach_vm_remap(vm_map_t target_task, mach_vm_address_t *target_address,
 *     mach_vm_size_t size, mach_vm_offset_t mask, int flags, vm_map_t src_task,
 *     mach_vm_address_t src_address, boolean_t copy, vm_prot_t *cur_protection,
 *     vm_prot_t *max_protection, vm_inherit_t inheritance)
 * The VMM remaps (shares or copies) the source range: private routine 12. */
static int yc_vm_remap(yc_port_t target, yc_u64 *address, yc_u64 size, yc_u64 mask, int flags, yc_port_t src_task,
                       yc_u64 src_address, int copy, int *cur, int *max, int inherit, int is_new)
{
    yc_u64 block[7] = {src_task, src_address, (yc_u64)(unsigned)copy, (yc_u64)(yc_uintptr_t)cur,
                       (yc_u64)(yc_uintptr_t)max, (yc_u64)(unsigned)inherit, (yc_u64)(unsigned)is_new};
    return (int)yc_mach_trap(YC_PRIV_ROUTINE(YC_PRIV_VM_REMAP), target, (yc_uintptr_t)address, size, mask,
                             (yc_uintptr_t)(unsigned)flags, (yc_uintptr_t)block, 0);
}

YC_EXPORT int mach_vm_remap(yc_port_t target, yc_u64 *address, yc_u64 size, yc_u64 mask, int flags,
                            yc_port_t src_task, yc_u64 src_address, int copy, int *cur, int *max, int inherit)
{
    return yc_vm_remap(target, address, size, mask, flags, src_task, src_address, copy, cur, max, inherit, 0);
}

/* mach_vm_remap_new: cur/max are in-out (requested protections). */
YC_EXPORT int mach_vm_remap_new(yc_port_t target, yc_u64 *address, yc_u64 size, yc_u64 mask, int flags,
                                yc_port_t src_task, yc_u64 src_address, int copy, int *cur, int *max, int inherit)
{
    return yc_vm_remap(target, address, size, mask, flags, src_task, src_address, copy, cur, max, inherit, 1);
}

YC_EXPORT int vm_remap(yc_port_t target, yc_uintptr_t *address, yc_uintptr_t size, yc_uintptr_t mask, int flags,
                       yc_port_t src_task, yc_uintptr_t src_address, int copy, int *cur, int *max, int inherit)
{
    return mach_vm_remap(target, (yc_u64 *)address, size, mask, flags, src_task, src_address, copy, cur, max, inherit);
}

YC_EXPORT int vm_remap_new(yc_port_t target, yc_uintptr_t *address, yc_uintptr_t size, yc_uintptr_t mask, int flags,
                           yc_port_t src_task, yc_uintptr_t src_address, int copy, int *cur, int *max, int inherit)
{
    return mach_vm_remap_new(target, (yc_u64 *)address, size, mask, flags, src_task, src_address, copy, cur, max,
                             inherit);
}

/* kern_return_t task_threads(task_inspect_t target_task, thread_act_array_t *act_list,
 *     mach_msg_type_number_t *act_listCnt)
 * The VMM allocates the array in the caller (vm_deallocate it) with a send
 * right per thread: private routine 13. */
YC_EXPORT int task_threads(yc_port_t task, yc_port_t **act_list, yc_u32 *act_list_count)
{
    return (int)YC_MACH3(YC_PRIV_ROUTINE(YC_PRIV_TASK_THREADS), task, act_list, act_list_count);
}

/* kern_return_t mach_port_get_context(ipc_space_t task, mach_port_name_t name,
 *     mach_port_context_t *context)
 * kern_return_t mach_port_set_context(ipc_space_t task, mach_port_name_t name,
 *     mach_port_context_t context)
 * MIG routines on the task port, served by the VMM: private routines 14, 15. */
YC_EXPORT int mach_port_get_context(yc_port_t task, yc_port_t name, yc_u64 *context)
{
    return (int)YC_MACH3(YC_PRIV_ROUTINE(14), task, name, context);
}

YC_EXPORT int mach_port_set_context(yc_port_t task, yc_port_t name, yc_u64 context)
{
    return (int)YC_MACH3(YC_PRIV_ROUTINE(15), task, name, context);
}
