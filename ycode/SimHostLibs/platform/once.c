/*
 * once.c - _os_once, __os_once_reset and _os_alloc_once of Ycode's
 * libsystem_platform.
 *
 * Clean-room Ycode code. Interface facts (from the public os_once
 * conventions that clients inline): the predicate is a long that starts at
 * 0 and holds ~0 once the function has run; clients test for ~0 inline and
 * call _os_once only otherwise. _os_alloc_once's slot is { long once;
 * void *ptr; }; it allocates zeroed memory once, stores the pointer, runs
 * the initializer on it, and returns the pointer (the 1600-byte
 * _os_alloc_once_table in libsystem_kernel is 100 such slots;
 * host-library-init.md sections 7.1-7.2).
 *
 * Predicate states: 0 not started, 1 running, 3 running with waiters,
 * ~0 done. Waiters sleep on the low 32 bits with UL_COMPARE_AND_WAIT.
 */
#include "yc_platform.h"

#define ONCE_DONE (~0l)
#define ONCE_RUNNING 1l
#define ONCE_WAITERS 3l

typedef void (*yc_once_fn)(void *);

static YC_NOINLINE void once_slow(long *pred, void *ctx, yc_once_fn fn)
{
    long expected = 0;
    if (__atomic_compare_exchange_n(pred, &expected, ONCE_RUNNING, 0, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)) {
        fn(ctx);
        long old = __atomic_exchange_n(pred, ONCE_DONE, __ATOMIC_RELEASE);
        if (old == ONCE_WAITERS)
            YC_KFN(__ulock_wake)(YC_UL_COMPARE_AND_WAIT | YC_ULF_WAKE_ALL | YC_ULF_NO_ERRNO, pred, 0);
        return;
    }
    for (;;) {
        long cur = __atomic_load_n(pred, __ATOMIC_ACQUIRE);
        if (cur == ONCE_DONE)
            return;
        if (cur == ONCE_RUNNING &&
            !__atomic_compare_exchange_n(pred, &cur, ONCE_WAITERS, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED))
            continue;
        YC_KFN(__ulock_wait)(YC_UL_COMPARE_AND_WAIT | YC_ULF_NO_ERRNO, pred, (yc_u32)ONCE_WAITERS, 0);
    }
}

YC_EXPORT void YC_FN(_os_once)(long *pred, void *ctx, yc_once_fn fn)
{
    if (YC_LIKELY(__atomic_load_n(pred, __ATOMIC_ACQUIRE) == ONCE_DONE))
        return;
    once_slow(pred, ctx, fn);
}

YC_EXPORT void YC_FN(__os_once_reset)(long *pred)
{
    __atomic_store_n(pred, 0, __ATOMIC_RELEASE);
}

/*
 * Private bump heap (host-library-init.md section 7.1): sizes are rounded
 * up to 16 bytes and carved from zero-filled 2-page (32 KiB) blocks; a
 * request larger than a block gets its own mapping. The memory is never
 * freed (os_alloc_once data lives for the whole process).
 */
#define HEAP_BLOCK (2 * YC_PAGE_SIZE)
static yc_u32 heap_lock;
static char *heap_next;
static yc_size_t heap_left;

static void *map_zeroed(yc_size_t len)
{
    void *mem = YC_KFN(mmap)(YC_NULL, len, YC_PROT_READ | YC_PROT_WRITE, YC_MAP_PRIVATE | YC_MAP_ANON, -1, 0);
    if (mem == YC_MAP_FAILED || mem == YC_NULL)
        YC_CRASH(); /* out of memory in a process-lifetime allocation */
    return mem;
}

static void *heap_alloc(yc_size_t size)
{
    size = (size + 15) & ~(yc_size_t)15;
    if (size == 0)
        size = 16;
    if (size > HEAP_BLOCK / 2)
        return map_zeroed((size + YC_PAGE_SIZE - 1) & ~(YC_PAGE_SIZE - 1));
    yc_u32 self = __yc_lock_owner_id();
    __yc_unfair_lock(&heap_lock, self);
    if (heap_left < size) {
        heap_next = map_zeroed(HEAP_BLOCK);
        heap_left = HEAP_BLOCK;
    }
    void *p = heap_next;
    heap_next += size;
    heap_left -= size;
    __yc_unfair_unlock(&heap_lock, self);
    return p;
}

struct alloc_ctx {
    struct yc_alloc_once_slot *slot;
    yc_size_t size;
    yc_once_fn init;
};

static void alloc_once_body(void *p)
{
    struct alloc_ctx *c = p;
    void *mem = heap_alloc(c->size);
    __atomic_store_n(&c->slot->ptr, mem, __ATOMIC_RELEASE);
    if (c->init)
        c->init(mem);
}

YC_EXPORT void *YC_FN(_os_alloc_once)(struct yc_alloc_once_slot *slot, yc_size_t size, yc_once_fn init)
{
    if (YC_LIKELY(__atomic_load_n(&slot->once, __ATOMIC_ACQUIRE) == ONCE_DONE))
        return slot->ptr;
    struct alloc_ctx c = { slot, size, init };
    once_slow(&slot->once, &c, alloc_once_body);
    return __atomic_load_n(&slot->ptr, __ATOMIC_ACQUIRE);
}
