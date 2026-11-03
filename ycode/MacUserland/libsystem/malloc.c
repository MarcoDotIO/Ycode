// malloc.c - Ycode libSystem's allocator (specs/macos/libsystem.md §5).
// Clean-room Ycode code: size-class free lists over 1 MB anonymous
// mappings, one lock, a 16-byte header per block.
#include "ycl.h"

enum {
    HEADER = 16,
    SMALL_LIMIT = 1024,            // classes 1..64: 16-byte steps
    SMALL_CLASSES = SMALL_LIMIT / 16,
    MEDIUM_LIMIT = 65536,          // classes 65..70: 2 KB .. 64 KB
    NCLASSES = SMALL_CLASSES + 7,
    ARENA = 1 << 20,
    PAGE = 16384,
};
#define BIG_CLASS 0xFFFFu
#define ALIGNED_MARK 0xA11Eu

// The header in front of every block: the class, and for a big block its
// mapping size; for an aligned block, the distance back to the real one.
struct header {
    uint32_t klass;
    uint32_t mark;
    uint64_t extra;
};

struct free_block {
    struct free_block *next;
};

static os_unfair_lock heap_lock;
static struct free_block *free_lists[NCLASSES + 1];
static uint8_t *arena_next, *arena_end;

static size_t class_size(uint32_t k) {
    return k <= SMALL_CLASSES ? (size_t)k * 16 : (size_t)2048 << (k - SMALL_CLASSES - 1);
}

static uint32_t class_for(size_t n) {
    if (n == 0) n = 1;
    if (n <= SMALL_LIMIT) return (uint32_t)((n + 15) / 16);
    uint32_t k = SMALL_CLASSES + 1;
    while (class_size(k) < n) k++;
    return k;
}

static void *map_pages(size_t n) {
    void *p = mmap(0, n, YCL_PROT_READ | YCL_PROT_WRITE, YCL_MAP_PRIVATE | YCL_MAP_ANON, -1, 0);
    return p == YCL_MAP_FAILED ? 0 : p;
}

void ycl_malloc_init(void) {}

static void *allocate(size_t n) {
    if (n > MEDIUM_LIMIT) {
        if (n > ((size_t)1 << 46)) {
            ycl_errno = YCL_ENOMEM;
            return 0;
        }
        size_t total = (n + HEADER + PAGE - 1) & ~(size_t)(PAGE - 1);
        struct header *h = map_pages(total);
        if (!h) {
            ycl_errno = YCL_ENOMEM;
            return 0;
        }
        h->klass = BIG_CLASS;
        h->mark = 0;
        h->extra = total;
        return (uint8_t *)h + HEADER;
    }
    uint32_t k = class_for(n);
    size_t need = class_size(k) + HEADER;
    os_unfair_lock_lock(&heap_lock);
    struct free_block *f = free_lists[k];
    if (f) {
        free_lists[k] = f->next;
        os_unfair_lock_unlock(&heap_lock);
        return f;
    }
    if (!arena_next || (size_t)(arena_end - arena_next) < need) {
        uint8_t *a = map_pages(ARENA);
        if (!a) {
            os_unfair_lock_unlock(&heap_lock);
            ycl_errno = YCL_ENOMEM;
            return 0;
        }
        arena_next = a;
        arena_end = a + ARENA;
    }
    struct header *h = (struct header *)arena_next;
    arena_next += need;
    os_unfair_lock_unlock(&heap_lock);
    h->klass = k;
    h->mark = 0;
    h->extra = 0;
    return (uint8_t *)h + HEADER;
}

static struct header *header_of(void *p) { return (struct header *)((uint8_t *)p - HEADER); }

// The block a pointer belongs to (undoing posix_memalign's offset).
static void *real_block(void *p) {
    struct header *h = header_of(p);
    if (h->mark == ALIGNED_MARK) return (uint8_t *)p - h->extra;
    return p;
}

YCL_EXPORT void *malloc(size_t n) { return allocate(n); }

YCL_EXPORT void free(void *p) {
    if (!p) return;
    p = real_block(p);
    struct header *h = header_of(p);
    if (h->klass == BIG_CLASS) {
        munmap(h, (size_t)h->extra);
        return;
    }
    if (h->klass == 0 || h->klass > NCLASSES) abort();  // not one of ours
    os_unfair_lock_lock(&heap_lock);
    struct free_block *f = p;
    f->next = free_lists[h->klass];
    free_lists[h->klass] = f;
    os_unfair_lock_unlock(&heap_lock);
}

YCL_EXPORT size_t malloc_size(const void *p) {
    if (!p) return 0;
    void *block = real_block((void *)p);
    struct header *h = header_of(block);
    size_t usable = h->klass == BIG_CLASS ? (size_t)h->extra - HEADER : class_size(h->klass);
    return usable - (size_t)((const uint8_t *)p - (const uint8_t *)block);
}

YCL_EXPORT size_t malloc_good_size(size_t n) { return n > MEDIUM_LIMIT ? (n + PAGE - 1) & ~(size_t)(PAGE - 1) : class_size(class_for(n)); }

YCL_EXPORT void *calloc(size_t count, size_t size) {
    size_t n;
    if (__builtin_mul_overflow(count, size, &n)) {
        ycl_errno = YCL_ENOMEM;
        return 0;
    }
    void *p = allocate(n);
    if (p && header_of(p)->klass != BIG_CLASS) memset(p, 0, n);  // fresh mappings are already zero
    return p;
}

YCL_EXPORT void *realloc(void *p, size_t n) {
    if (!p) return allocate(n);
    if (n == 0) n = 1;
    size_t have = malloc_size(p);
    if (n <= have && real_block(p) == p) return p;
    void *q = allocate(n);
    if (!q) return 0;
    memcpy(q, p, have < n ? have : n);
    free(p);
    return q;
}

YCL_EXPORT void *reallocf(void *p, size_t n) {
    void *q = realloc(p, n);
    if (!q) free(p);
    return q;
}

YCL_EXPORT int posix_memalign(void **out, size_t alignment, size_t n) {
    if (alignment < sizeof(void *) || (alignment & (alignment - 1))) return YCL_EINVAL;
    if (alignment <= 16) {
        void *p = allocate(n);
        if (!p) return YCL_ENOMEM;
        *out = p;
        return 0;
    }
    uint8_t *block = allocate(n + alignment + HEADER);
    if (!block) return YCL_ENOMEM;
    uintptr_t aligned = ((uintptr_t)block + HEADER + alignment - 1) & ~(uintptr_t)(alignment - 1);
    struct header *h = header_of((void *)aligned);
    h->klass = 0;
    h->mark = ALIGNED_MARK;
    h->extra = aligned - (uintptr_t)block;
    *out = (void *)aligned;
    return 0;
}

YCL_EXPORT void *aligned_alloc(size_t alignment, size_t n) {
    void *p = 0;
    int r = posix_memalign(&p, alignment < sizeof(void *) ? sizeof(void *) : alignment, n);
    if (r) {
        ycl_errno = r;
        return 0;
    }
    return p;
}

YCL_EXPORT void *valloc(size_t n) { return aligned_alloc(PAGE, n); }
