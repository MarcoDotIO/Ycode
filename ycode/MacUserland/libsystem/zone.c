// zone.c - the malloc zone interface of <malloc/malloc.h> over Ycode's one
// allocator (specs/macos/libsystem.md §5, §12). Clean-room Ycode code; the
// malloc_zone_t layout is the public header's (version 13 fields). Every
// zone is the default zone: malloc_create_zone returns it too, and
// malloc_zone_from_ptr answers it for any non-NULL pointer.
#include "ycl.h"

typedef struct ycl_zone ycl_zone;
struct ycl_zone {
    void *reserved1, *reserved2;
    size_t (*size)(ycl_zone *, const void *);
    void *(*malloc)(ycl_zone *, size_t);
    void *(*calloc)(ycl_zone *, size_t, size_t);
    void *(*valloc)(ycl_zone *, size_t);
    void (*free)(ycl_zone *, void *);
    void *(*realloc)(ycl_zone *, void *, size_t);
    void (*destroy)(ycl_zone *);
    const char *zone_name;
    unsigned (*batch_malloc)(ycl_zone *, size_t, void **, unsigned);
    void (*batch_free)(ycl_zone *, void **, unsigned);
    void *introspect;
    unsigned version;
    void *(*memalign)(ycl_zone *, size_t, size_t);
    void (*free_definite_size)(ycl_zone *, void *, size_t);
    size_t (*pressure_relief)(ycl_zone *, size_t);
    int (*claimed_address)(ycl_zone *, void *);
    void (*try_free_default)(ycl_zone *, void *);
    void *(*malloc_with_options)(ycl_zone *, size_t, size_t, uint64_t);
    void *malloc_type_malloc, *malloc_type_calloc, *malloc_type_realloc, *malloc_type_memalign,
        *malloc_type_malloc_with_options;
};

size_t malloc_size(const void *);
void *valloc(size_t);
int posix_memalign(void **, size_t, size_t);

static size_t z_size(ycl_zone *z, const void *p) {
    (void)z;
    return malloc_size(p);
}
static void *z_malloc(ycl_zone *z, size_t n) {
    (void)z;
    return malloc(n);
}
static void *z_calloc(ycl_zone *z, size_t c, size_t n) {
    (void)z;
    return calloc(c, n);
}
static void *z_valloc(ycl_zone *z, size_t n) {
    (void)z;
    return valloc(n);
}
static void z_free(ycl_zone *z, void *p) {
    (void)z;
    free(p);
}
static void *z_realloc(ycl_zone *z, void *p, size_t n) {
    (void)z;
    return realloc(p, n);
}
static void z_destroy(ycl_zone *z) { (void)z; }
static unsigned z_batch_malloc(ycl_zone *z, size_t n, void **out, unsigned count) {
    (void)z;
    unsigned i = 0;
    for (; i < count; i++)
        if (!(out[i] = malloc(n))) break;
    return i;
}
static void z_batch_free(ycl_zone *z, void **p, unsigned count) {
    (void)z;
    for (unsigned i = 0; i < count; i++) free(p[i]);
}
static void *z_memalign(ycl_zone *z, size_t alignment, size_t n) {
    (void)z;
    void *p = 0;
    return posix_memalign(&p, alignment < sizeof(void *) ? sizeof(void *) : alignment, n) == 0 ? p : 0;
}
static void z_free_definite_size(ycl_zone *z, void *p, size_t n) {
    (void)z;
    (void)n;
    free(p);
}
static size_t z_pressure_relief(ycl_zone *z, size_t goal) {
    (void)z;
    (void)goal;
    return 0;
}
static int z_claimed_address(ycl_zone *z, void *p) {
    (void)z;
    return p != 0;
}

static ycl_zone default_zone = {
    0, 0, z_size, z_malloc, z_calloc, z_valloc, z_free, z_realloc, z_destroy, "DefaultMallocZone",
    z_batch_malloc, z_batch_free, 0, 10, z_memalign, z_free_definite_size, z_pressure_relief, z_claimed_address,
    0, 0, 0, 0, 0, 0, 0,
};

YCL_EXPORT ycl_zone *malloc_default_zone(void) { return &default_zone; }
YCL_EXPORT ycl_zone *malloc_default_purgeable_zone(void) { return &default_zone; }
YCL_EXPORT ycl_zone *malloc_zone_from_ptr(const void *p) { return p ? &default_zone : 0; }
YCL_EXPORT ycl_zone *malloc_create_zone(size_t start, unsigned flags) {
    (void)start;
    (void)flags;
    return &default_zone;
}
YCL_EXPORT void malloc_destroy_zone(ycl_zone *z) { (void)z; }
YCL_EXPORT void malloc_set_zone_name(ycl_zone *z, const char *name) {
    (void)z;
    (void)name;
}
YCL_EXPORT const char *malloc_get_zone_name(ycl_zone *z) { return z ? z->zone_name : 0; }
YCL_EXPORT void *malloc_zone_malloc(ycl_zone *z, size_t n) { return z->malloc(z, n); }
YCL_EXPORT void *malloc_zone_calloc(ycl_zone *z, size_t c, size_t n) { return z->calloc(z, c, n); }
YCL_EXPORT void *malloc_zone_valloc(ycl_zone *z, size_t n) { return z->valloc(z, n); }
YCL_EXPORT void *malloc_zone_realloc(ycl_zone *z, void *p, size_t n) { return z->realloc(z, p, n); }
YCL_EXPORT void *malloc_zone_memalign(ycl_zone *z, size_t a, size_t n) { return z->memalign(z, a, n); }
YCL_EXPORT void malloc_zone_free(ycl_zone *z, void *p) { z->free(z, p); }
YCL_EXPORT size_t malloc_zone_pressure_relief(ycl_zone *z, size_t goal) {
    (void)z;
    (void)goal;
    return 0;
}

// --- typed allocation (<malloc/_malloc_type.h>): the type identifier is a
//     hint for segregating allocations; Ycode's allocator ignores it ---

typedef unsigned long long ycl_type_id;
void *aligned_alloc(size_t, size_t);
YCL_EXPORT void *malloc_type_malloc(size_t n, ycl_type_id t) {
    (void)t;
    return malloc(n);
}
YCL_EXPORT void *malloc_type_calloc(size_t c, size_t n, ycl_type_id t) {
    (void)t;
    return calloc(c, n);
}
YCL_EXPORT void *malloc_type_realloc(void *p, size_t n, ycl_type_id t) {
    (void)t;
    return realloc(p, n);
}
YCL_EXPORT void malloc_type_free(void *p, ycl_type_id t) {
    (void)t;
    free(p);
}
YCL_EXPORT void *malloc_type_valloc(size_t n, ycl_type_id t) {
    (void)t;
    return valloc(n);
}
YCL_EXPORT void *malloc_type_aligned_alloc(size_t a, size_t n, ycl_type_id t) {
    (void)t;
    return aligned_alloc(a, n);
}
YCL_EXPORT int malloc_type_posix_memalign(void **out, size_t a, size_t n, ycl_type_id t) {
    (void)t;
    return posix_memalign(out, a, n);
}
YCL_EXPORT void *malloc_type_zone_malloc(ycl_zone *z, size_t n, ycl_type_id t) {
    (void)t;
    return z->malloc(z, n);
}
YCL_EXPORT void *malloc_type_zone_calloc(ycl_zone *z, size_t c, size_t n, ycl_type_id t) {
    (void)t;
    return z->calloc(z, c, n);
}
YCL_EXPORT void *malloc_type_zone_realloc(ycl_zone *z, void *p, size_t n, ycl_type_id t) {
    (void)t;
    return z->realloc(z, p, n);
}
YCL_EXPORT void *malloc_type_zone_memalign(ycl_zone *z, size_t a, size_t n, ycl_type_id t) {
    (void)t;
    return z->memalign(z, a, n);
}
