/*
 * atomic.c - the OSAtomic* family, OSMemoryBarrier and the OSAtomic queues
 * of Ycode's libsystem_platform.
 *
 * Clean-room Ycode code. Behavior from the public OSAtomic(3) man pages:
 * - arithmetic and logical operations return the NEW value, except the
 *   *Orig variants, which return the original value;
 * - the *Barrier variants are full memory barriers, the others are atomic
 *   but impose no ordering;
 * - OSAtomicTestAndSet/Clear(n, addr) operate on bit (0x80 >> (n & 7)) of
 *   byte (addr + (n >> 3)) and return the bit's original value;
 * - OSAtomicEnqueue/Dequeue are a LIFO with the link at a given offset in
 *   each element; OSAtomicFifoEnqueue/Dequeue are a FIFO.
 */
#include "yc_platform.h"

#define RLX __ATOMIC_RELAXED
#define SEQ __ATOMIC_SEQ_CST

#define ARITH(name, type, op, order) \
    YC_EXPORT type YC_FN(name)(type amount, volatile type *value) \
    { return __atomic_##op##_fetch((type *)value, amount, order); }

ARITH(OSAtomicAdd32, yc_i32, add, RLX)
ARITH(OSAtomicAdd32Barrier, yc_i32, add, SEQ)
ARITH(OSAtomicAdd64, yc_i64, add, RLX)
ARITH(OSAtomicAdd64Barrier, yc_i64, add, SEQ)

#define INCDEC(name, type, op, order) \
    YC_EXPORT type YC_FN(name)(volatile type *value) \
    { return __atomic_##op##_fetch((type *)value, 1, order); }

INCDEC(OSAtomicIncrement32, yc_i32, add, RLX)
INCDEC(OSAtomicIncrement32Barrier, yc_i32, add, SEQ)
INCDEC(OSAtomicIncrement64, yc_i64, add, RLX)
INCDEC(OSAtomicIncrement64Barrier, yc_i64, add, SEQ)
INCDEC(OSAtomicDecrement32, yc_i32, sub, RLX)
INCDEC(OSAtomicDecrement32Barrier, yc_i32, sub, SEQ)
INCDEC(OSAtomicDecrement64, yc_i64, sub, RLX)
INCDEC(OSAtomicDecrement64Barrier, yc_i64, sub, SEQ)

#define LOGIC_NEW(name, op, order) \
    YC_EXPORT yc_i32 YC_FN(name)(yc_u32 mask, volatile yc_u32 *value) \
    { return (yc_i32)__atomic_##op##_fetch((yc_u32 *)value, mask, order); }
#define LOGIC_ORIG(name, op, order) \
    YC_EXPORT yc_i32 YC_FN(name)(yc_u32 mask, volatile yc_u32 *value) \
    { return (yc_i32)__atomic_fetch_##op((yc_u32 *)value, mask, order); }

LOGIC_NEW(OSAtomicOr32, or, RLX)
LOGIC_NEW(OSAtomicOr32Barrier, or, SEQ)
LOGIC_ORIG(OSAtomicOr32Orig, or, RLX)
LOGIC_ORIG(OSAtomicOr32OrigBarrier, or, SEQ)
LOGIC_NEW(OSAtomicAnd32, and, RLX)
LOGIC_NEW(OSAtomicAnd32Barrier, and, SEQ)
LOGIC_ORIG(OSAtomicAnd32Orig, and, RLX)
LOGIC_ORIG(OSAtomicAnd32OrigBarrier, and, SEQ)
LOGIC_NEW(OSAtomicXor32, xor, RLX)
LOGIC_NEW(OSAtomicXor32Barrier, xor, SEQ)
LOGIC_ORIG(OSAtomicXor32Orig, xor, RLX)
LOGIC_ORIG(OSAtomicXor32OrigBarrier, xor, SEQ)

#define CAS(name, type, order) \
    YC_EXPORT yc_bool YC_FN(name)(type old_value, type new_value, type volatile *value) \
    { return __atomic_compare_exchange_n((type *)value, &old_value, new_value, 0, order, RLX); }

CAS(OSAtomicCompareAndSwap32, yc_i32, RLX)
CAS(OSAtomicCompareAndSwap32Barrier, yc_i32, SEQ)
CAS(OSAtomicCompareAndSwap64, yc_i64, RLX)
CAS(OSAtomicCompareAndSwap64Barrier, yc_i64, SEQ)
CAS(OSAtomicCompareAndSwapInt, int, RLX)
CAS(OSAtomicCompareAndSwapIntBarrier, int, SEQ)
CAS(OSAtomicCompareAndSwapLong, long, RLX)
CAS(OSAtomicCompareAndSwapLongBarrier, long, SEQ)
CAS(OSAtomicCompareAndSwapPtr, void *, RLX)
CAS(OSAtomicCompareAndSwapPtrBarrier, void *, SEQ)

static yc_bool test_and_op(yc_u32 n, volatile void *address, yc_bool set, int order)
{
    yc_u8 *byte = (yc_u8 *)address + (n >> 3);
    yc_u8 mask = (yc_u8)(0x80u >> (n & 7));
    yc_u8 old = set ? __atomic_fetch_or(byte, mask, order)
                    : __atomic_fetch_and(byte, (yc_u8)~mask, order);
    return (old & mask) != 0;
}

YC_EXPORT yc_bool YC_FN(OSAtomicTestAndSet)(yc_u32 n, volatile void *a) { return test_and_op(n, a, 1, RLX); }
YC_EXPORT yc_bool YC_FN(OSAtomicTestAndSetBarrier)(yc_u32 n, volatile void *a) { return test_and_op(n, a, 1, SEQ); }
YC_EXPORT yc_bool YC_FN(OSAtomicTestAndClear)(yc_u32 n, volatile void *a) { return test_and_op(n, a, 0, RLX); }
YC_EXPORT yc_bool YC_FN(OSAtomicTestAndClearBarrier)(yc_u32 n, volatile void *a) { return test_and_op(n, a, 0, SEQ); }

YC_EXPORT void YC_FN(OSMemoryBarrier)(void)
{
    __atomic_thread_fence(SEQ);
}

/* ---- LIFO queue: OSQueueHead { void *head; long generation; } ---------
 * Lock-free with a 128-bit compare-and-swap of (head, generation); the
 * generation count defeats ABA. */

typedef struct {
    void *head;
    long generation;
} __attribute__((aligned(16))) yc_queue_head;

#define LINK(elem, offset) (*(void **)((char *)(elem) + (offset)))

#if defined(__aarch64__)
static yc_bool cas_pair(yc_queue_head *q, void *old_head, long old_gen, void *new_head, long new_gen)
{
    yc_u64 lo, hi;
    yc_u32 status;
    yc_bool ok;
    for (;;) {
        __asm__ volatile("ldaxp %0, %1, [%2]" : "=&r"(lo), "=&r"(hi) : "r"(q) : "memory");
        if (lo != (yc_u64)old_head || hi != (yc_u64)old_gen) {
            __asm__ volatile("clrex" ::: "memory");
            ok = 0;
            break;
        }
        __asm__ volatile("stlxp %w0, %1, %2, [%3]"
                         : "=&r"(status)
                         : "r"((yc_u64)new_head), "r"((yc_u64)new_gen), "r"(q)
                         : "memory");
        if (status == 0) {
            ok = 1;
            break;
        }
    }
    return ok;
}

static void snapshot(yc_queue_head *q, void **head, long *gen)
{
    yc_u64 lo, hi;
    yc_u32 status;
    /* A single-copy-atomic 128-bit read: ldaxp, then stlxp the same value
     * back to make sure the pair was read atomically. */
    do {
        __asm__ volatile("ldaxp %0, %1, [%2]" : "=&r"(lo), "=&r"(hi) : "r"(q) : "memory");
        __asm__ volatile("stlxp %w0, %1, %2, [%3]" : "=&r"(status) : "r"(lo), "r"(hi), "r"(q) : "memory");
    } while (status != 0);
    *head = (void *)lo;
    *gen = (long)hi;
}

YC_EXPORT void YC_FN(OSAtomicEnqueue)(yc_queue_head *q, void *elem, yc_size_t offset)
{
    void *head;
    long gen;
    do {
        snapshot(q, &head, &gen);
        LINK(elem, offset) = head;
    } while (!cas_pair(q, head, gen, elem, gen + 1));
}

YC_EXPORT void *YC_FN(OSAtomicDequeue)(yc_queue_head *q, yc_size_t offset)
{
    void *head;
    long gen;
    do {
        snapshot(q, &head, &gen);
        if (head == YC_NULL)
            return YC_NULL;
    } while (!cas_pair(q, head, gen, LINK(head, offset), gen + 1));
    return head;
}
#else
/* Host-test fallback for non-arm64 hosts: a global lock. */
static yc_i32 queue_lock;

YC_EXPORT void YC_FN(OSAtomicEnqueue)(yc_queue_head *q, void *elem, yc_size_t offset)
{
    __yc_futex_lock(&queue_lock);
    LINK(elem, offset) = q->head;
    q->head = elem;
    q->generation++;
    __yc_futex_unlock(&queue_lock);
}

YC_EXPORT void *YC_FN(OSAtomicDequeue)(yc_queue_head *q, yc_size_t offset)
{
    __yc_futex_lock(&queue_lock);
    void *head = q->head;
    if (head) {
        q->head = LINK(head, offset);
        q->generation++;
    }
    __yc_futex_unlock(&queue_lock);
    return head;
}
#endif

/* ---- FIFO queue: OSFifoQueueHead { void *head; void *tail; int lock; } -
 * Ycode uses the third word as a lock word for the futex lock. */

typedef struct {
    void *head;
    void *tail;
    yc_i32 lock;
} yc_fifo_head;

YC_EXPORT void YC_FN(OSAtomicFifoEnqueue)(yc_fifo_head *q, void *elem, yc_size_t offset)
{
    LINK(elem, offset) = YC_NULL;
    __yc_futex_lock(&q->lock);
    if (q->tail)
        LINK(q->tail, offset) = elem;
    else
        q->head = elem;
    q->tail = elem;
    __yc_futex_unlock(&q->lock);
}

YC_EXPORT void *YC_FN(OSAtomicFifoDequeue)(yc_fifo_head *q, yc_size_t offset)
{
    __yc_futex_lock(&q->lock);
    void *elem = q->head;
    if (elem) {
        q->head = LINK(elem, offset);
        if (q->head == YC_NULL)
            q->tail = YC_NULL;
    }
    __yc_futex_unlock(&q->lock);
    return elem;
}
