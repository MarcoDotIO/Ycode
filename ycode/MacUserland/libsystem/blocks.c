// blocks.c - the Blocks runtime of Ycode's libSystem
// (specs/macos/libsystem.md §4, §7.1). Clean-room Ycode code written from
// clang's public Block ABI specification (the literal, descriptor and
// __block layouts and flag values). No Objective-C: captured objects are
// plain pointers.
#include "ycl.h"

enum {
    REFCOUNT_MASK = 0xFFFE,  // the count, in steps of 2
    NEEDS_FREE = 1 << 24,
    HAS_COPY_DISPOSE = 1 << 25,
    IS_GLOBAL = 1 << 28,
};
enum { FIELD_OBJECT = 3, FIELD_BLOCK = 7, FIELD_BYREF = 8, FIELD_WEAK = 16, BYREF_CALLER = 128 };

struct descriptor {
    unsigned long reserved, size;
    void (*copy)(void *dst, const void *src);  // with HAS_COPY_DISPOSE
    void (*dispose)(const void *);
};

struct block {
    void *isa;
    volatile int flags;
    int reserved;
    void (*invoke)(void *, ...);
    struct descriptor *descriptor;
};

struct byref {
    void *isa;
    struct byref *forwarding;
    volatile int flags;
    int size;
    void (*keep)(struct byref *dst, struct byref *src);  // with HAS_COPY_DISPOSE
    void (*destroy)(struct byref *);
};

// The class words (only their addresses matter without Objective-C).
YCL_EXPORT void *_NSConcreteStackBlock[32];
YCL_EXPORT void *_NSConcreteMallocBlock[32];
YCL_EXPORT void *_NSConcreteGlobalBlock[32];
YCL_EXPORT void *_NSConcreteAutoBlock[32];
YCL_EXPORT void *_NSConcreteFinalizingBlock[32];
YCL_EXPORT void *_NSConcreteWeakBlockVariable[32];

// Adds `delta` (±2) to the count in `flags`; returns the new count.
static int adjust(volatile int *flags, int delta) {
    for (;;) {
        int old = *flags;
        int count = old & REFCOUNT_MASK;
        if (count == REFCOUNT_MASK && delta > 0) return count;  // saturated: lives forever
        int now = (old & ~REFCOUNT_MASK) | ((count + delta) & REFCOUNT_MASK);
        if (__atomic_compare_exchange_n(flags, &old, now, 0, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
            return now & REFCOUNT_MASK;
    }
}

YCL_EXPORT void *_Block_copy(const void *arg) {
    struct block *b = (struct block *)arg;
    if (!b) return 0;
    if (b->flags & IS_GLOBAL) return b;
    if (b->flags & NEEDS_FREE) {
        adjust(&b->flags, 2);
        return b;
    }
    struct block *copy = malloc(b->descriptor->size);
    if (!copy) return 0;
    memmove(copy, b, b->descriptor->size);
    copy->flags = (b->flags & ~REFCOUNT_MASK) | NEEDS_FREE | 2;
    copy->isa = _NSConcreteMallocBlock;
    if (b->flags & HAS_COPY_DISPOSE) b->descriptor->copy(copy, b);
    return copy;
}

YCL_EXPORT void _Block_release(const void *arg) {
    struct block *b = (struct block *)arg;
    if (!b || (b->flags & IS_GLOBAL) || !(b->flags & NEEDS_FREE)) return;
    if (adjust(&b->flags, -2) != 0) return;
    if (b->flags & HAS_COPY_DISPOSE) b->descriptor->dispose(b);
    free(b);
}

// A __block variable moves to the heap the first time a block that uses
// it is copied; both copies' forwarding pointers then name the heap one.
static struct byref *byref_copy(struct byref *src) {
    src = src->forwarding;
    if (src->flags & NEEDS_FREE) {
        adjust(&src->flags, 2);
        return src;
    }
    struct byref *copy = malloc((size_t)src->size);
    if (!copy) abort();
    copy->isa = 0;
    copy->flags = (src->flags & ~REFCOUNT_MASK) | NEEDS_FREE | 4;  // the heap copy and the stack frame
    copy->forwarding = copy;
    copy->size = src->size;
    src->forwarding = copy;
    if (src->flags & HAS_COPY_DISPOSE) {
        copy->keep = src->keep;
        copy->destroy = src->destroy;
        src->keep(copy, src);
    } else {
        size_t header = offsetof(struct byref, keep);
        memmove((char *)copy + header, (char *)src + header, (size_t)src->size - header);
    }
    return copy;
}

static void byref_release(struct byref *b) {
    b = b->forwarding;
    if (!(b->flags & NEEDS_FREE)) return;
    if (adjust(&b->flags, -2) != 0) return;
    if (b->flags & HAS_COPY_DISPOSE) b->destroy(b);
    free(b);
}

YCL_EXPORT void _Block_object_assign(void *dst, const void *object, const int flags) {
    void **slot = dst;
    switch (flags & ~BYREF_CALLER) {
    case FIELD_BYREF:
    case FIELD_BYREF | FIELD_WEAK:
        *slot = byref_copy((struct byref *)object);
        break;
    case FIELD_BLOCK:
        *slot = (flags & BYREF_CALLER) ? (void *)object : _Block_copy(object);
        break;
    default:  // objects (and weak ones): no retain without Objective-C
        *slot = (void *)object;
        break;
    }
}

YCL_EXPORT void _Block_object_dispose(const void *object, const int flags) {
    switch (flags & ~BYREF_CALLER) {
    case FIELD_BYREF:
    case FIELD_BYREF | FIELD_WEAK:
        byref_release((struct byref *)object);
        break;
    case FIELD_BLOCK:
        if (!(flags & BYREF_CALLER)) _Block_release(object);
        break;
    default:
        break;
    }
}

// Calls a block that takes no arguments (dispatch's work items).
void ycl_block_invoke(void *block) { ((void (*)(void *))((struct block *)block)->invoke)(block); }
