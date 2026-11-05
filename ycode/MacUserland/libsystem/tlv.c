// tlv.c - thread-local variables (`__thread`, C++ `thread_local`) for
// macOS images (specs/macos/libsystem.md §14, dyld.md §9).
//
// Clean-room Ycode code from the public Mach-O facts: an image's
// S_THREAD_LOCAL_VARIABLES section holds one descriptor per variable,
// { thunk, key, offset }; the linker binds each thunk to libSystem's
// `_tlv_bootstrap`; S_THREAD_LOCAL_REGULAR and S_THREAD_LOCAL_ZEROFILL
// sections hold the initial values of the image's thread-local block, and
// `offset` is the variable's place in that block. Compiled code calls
// `thunk(descriptor)` with the descriptor in x0 and gets the variable's
// address in x0; it assumes that x1-x28, the frame pointer and every
// SIMD register survive the call.
//
// Ycode's design: `_tlv_bootstrap` sets up the descriptor's image on first
// use (one pthread key per image; every descriptor of the image gets
// `_ycl_tlv_get_addr` as its thunk and the key), then answers like
// `_ycl_tlv_get_addr`, whose fast path is the key's TSD slot (at
// TPIDRRO_EL0 + 8 * key, as libsystem_pthread lays it out) plus the offset.
// The slow path allocates and fills the thread's block. `_tlv_atexit`
// registers destructors of thread_local objects; they run when the thread
// exits, before its blocks are freed.
#include "ycl.h"
#include "yc_macho.h"

struct tlv_descriptor {
    void *(*thunk)(struct tlv_descriptor *);
    unsigned long key;
    unsigned long offset;
};

struct tlv_image {
    const struct yc_mach_header_64 *mh;
    unsigned long key;
    uintptr_t start;  // address of the block's initial image
    size_t size;      // whole block
    struct tlv_image *next;
};

int pthread_key_create(unsigned long *, void (*)(void *));
void *pthread_getspecific(unsigned long);
int pthread_setspecific(unsigned long, const void *);
const struct yc_mach_header_64 *ycl_image_containing(const void *address);

void *_tlv_bootstrap(struct tlv_descriptor *);
void *_ycl_tlv_get_addr(struct tlv_descriptor *);

static struct tlv_image *images;
static os_unfair_lock tlv_lock;

static intptr_t slide_of(const struct yc_mach_header_64 *mh) {
    const uint8_t *at = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct yc_load_command *lc = (const void *)at;
        if (lc->cmd == YC_LC_SEGMENT_64) {
            const struct yc_segment_command_64 *seg = (const void *)at;
            if (seg->fileoff == 0 && seg->filesize != 0) return (intptr_t)mh - (intptr_t)seg->vmaddr;
        }
        at += lc->cmdsize;
    }
    return 0;
}

// Calls `visit(section, slide, context)` for each section of `mh`.
static void each_section(const struct yc_mach_header_64 *mh,
                         void (*visit)(const struct yc_section_64 *, intptr_t, void *), void *context) {
    intptr_t slide = slide_of(mh);
    const uint8_t *at = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct yc_load_command *lc = (const void *)at;
        if (lc->cmd == YC_LC_SEGMENT_64) {
            const struct yc_segment_command_64 *seg = (const void *)at;
            const struct yc_section_64 *sect = (const void *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++) visit(&sect[j], slide, context);
        }
        at += lc->cmdsize;
    }
}

static void measure(const struct yc_section_64 *sect, intptr_t slide, void *context) {
    struct tlv_image *image = context;
    uint32_t type = sect->flags & YC_SECTION_TYPE;
    if (type != YC_S_THREAD_LOCAL_REGULAR && type != YC_S_THREAD_LOCAL_ZEROFILL) return;
    uintptr_t start = (uintptr_t)(sect->addr + slide), end = start + sect->size;
    uintptr_t lo = image->size ? image->start : start, hi = image->size ? image->start + image->size : end;
    if (start < lo) lo = start;
    if (end > hi) hi = end;
    image->start = lo;
    image->size = hi - lo;
}

static void patch(const struct yc_section_64 *sect, intptr_t slide, void *context) {
    struct tlv_image *image = context;
    if ((sect->flags & YC_SECTION_TYPE) != YC_S_THREAD_LOCAL_VARIABLES) return;
    struct tlv_descriptor *d = (struct tlv_descriptor *)(sect->addr + slide);
    for (size_t n = sect->size / sizeof *d, i = 0; i < n; i++) {
        d[i].key = image->key;
        __atomic_store_n(&d[i].thunk, _ycl_tlv_get_addr, __ATOMIC_RELEASE);
    }
}

struct fill_context {
    struct tlv_image *image;
    uint8_t *block;
};

static void fill(const struct yc_section_64 *sect, intptr_t slide, void *context) {
    struct fill_context *f = context;
    if ((sect->flags & YC_SECTION_TYPE) != YC_S_THREAD_LOCAL_REGULAR) return;
    uintptr_t start = (uintptr_t)(sect->addr + slide);
    memcpy(f->block + (start - f->image->start), (const void *)start, sect->size);
}

static void free_block(void *block) { free(block); }

static struct tlv_image *image_for(struct tlv_descriptor *d) {
    os_unfair_lock_lock(&tlv_lock);
    struct tlv_image *image = images;
    while (image && image->key != d->key) image = image->next;
    if (!image || __atomic_load_n(&d->thunk, __ATOMIC_ACQUIRE) == _tlv_bootstrap) {
        const struct yc_mach_header_64 *mh = ycl_image_containing(d);
        for (image = images; image && image->mh != mh; image = image->next) {
        }
        if (!image) {
            image = calloc(1, sizeof *image);
            if (!image || !mh || pthread_key_create(&image->key, free_block) != 0) {
                static const char message[] = "libSystem: cannot set up thread-local variables\n";
                write(2, message, sizeof message - 1);
                abort();
            }
            image->mh = mh;
            each_section(mh, measure, image);
            image->next = images;
            images = image;
            each_section(mh, patch, image);
        }
    }
    os_unfair_lock_unlock(&tlv_lock);
    return image;
}

// The slow path of both thunks, called with every register saved.
void *ycl_tlv_slow(struct tlv_descriptor *d) {
    struct tlv_image *image = image_for(d);
    uint8_t *block = pthread_getspecific(image->key);
    if (!block) {
        block = calloc(1, image->size ? image->size : 1);
        if (!block) abort();
        struct fill_context f = {image, block};
        each_section(image->mh, fill, &f);
        pthread_setspecific(image->key, block);
    }
    return block + d->offset;
}

// Both thunks. The slow path keeps x1-x15 and q0-q31 (x16 and x17 are the
// linker's scratch registers; x18 is reserved; x19-x28 are callee-saved).
__asm__(".globl __ycl_tlv_get_addr\n"
        ".private_extern __ycl_tlv_get_addr\n"
        ".p2align 2\n"
        "__ycl_tlv_get_addr:\n"
        "    ldr x16, [x0, #8]\n"
        "    cbz x16, Ltlv_slow\n"
        "    mrs x17, tpidrro_el0\n"
        "    ldr x16, [x17, x16, lsl #3]\n"
        "    cbz x16, Ltlv_slow\n"
        "    ldr x17, [x0, #16]\n"
        "    add x0, x16, x17\n"
        "    ret\n"
        ".globl __tlv_bootstrap\n"
        ".p2align 2\n"
        "__tlv_bootstrap:\n"
        "Ltlv_slow:\n"
        "    stp x29, x30, [sp, #-16]!\n"
        "    mov x29, sp\n"
        "    sub sp, sp, #640\n"
        "    stp x1, x2, [sp, #0]\n"
        "    stp x3, x4, [sp, #16]\n"
        "    stp x5, x6, [sp, #32]\n"
        "    stp x7, x8, [sp, #48]\n"
        "    stp x9, x10, [sp, #64]\n"
        "    stp x11, x12, [sp, #80]\n"
        "    stp x13, x14, [sp, #96]\n"
        "    str x15, [sp, #112]\n"
        "    stp q0, q1, [sp, #128]\n"
        "    stp q2, q3, [sp, #160]\n"
        "    stp q4, q5, [sp, #192]\n"
        "    stp q6, q7, [sp, #224]\n"
        "    stp q8, q9, [sp, #256]\n"
        "    stp q10, q11, [sp, #288]\n"
        "    stp q12, q13, [sp, #320]\n"
        "    stp q14, q15, [sp, #352]\n"
        "    stp q16, q17, [sp, #384]\n"
        "    stp q18, q19, [sp, #416]\n"
        "    stp q20, q21, [sp, #448]\n"
        "    stp q22, q23, [sp, #480]\n"
        "    stp q24, q25, [sp, #512]\n"
        "    stp q26, q27, [sp, #544]\n"
        "    stp q28, q29, [sp, #576]\n"
        "    stp q30, q31, [sp, #608]\n"
        "    bl _ycl_tlv_slow\n"
        "    ldp x1, x2, [sp, #0]\n"
        "    ldp x3, x4, [sp, #16]\n"
        "    ldp x5, x6, [sp, #32]\n"
        "    ldp x7, x8, [sp, #48]\n"
        "    ldp x9, x10, [sp, #64]\n"
        "    ldp x11, x12, [sp, #80]\n"
        "    ldp x13, x14, [sp, #96]\n"
        "    ldr x15, [sp, #112]\n"
        "    ldp q0, q1, [sp, #128]\n"
        "    ldp q2, q3, [sp, #160]\n"
        "    ldp q4, q5, [sp, #192]\n"
        "    ldp q6, q7, [sp, #224]\n"
        "    ldp q8, q9, [sp, #256]\n"
        "    ldp q10, q11, [sp, #288]\n"
        "    ldp q12, q13, [sp, #320]\n"
        "    ldp q14, q15, [sp, #352]\n"
        "    ldp q16, q17, [sp, #384]\n"
        "    ldp q18, q19, [sp, #416]\n"
        "    ldp q20, q21, [sp, #448]\n"
        "    ldp q22, q23, [sp, #480]\n"
        "    ldp q24, q25, [sp, #512]\n"
        "    ldp q26, q27, [sp, #544]\n"
        "    ldp q28, q29, [sp, #576]\n"
        "    ldp q30, q31, [sp, #608]\n"
        "    add sp, sp, #640\n"
        "    ldp x29, x30, [sp], #16\n"
        "    ret\n");

// --- destructors of thread_local objects ---

struct tlv_dtor {
    void (*fn)(void *);
    void *object;
};
struct tlv_dtor_list {
    size_t count, capacity;
    struct tlv_dtor *items;
};

static unsigned long dtor_key;
static int dtor_key_ready;
static os_unfair_lock dtor_lock;

static void run_dtors(void *value) {
    struct tlv_dtor_list *list = value;
    // Destructors may register more; run until the list stays empty.
    while (list->count) {
        struct tlv_dtor d = list->items[--list->count];
        d.fn(d.object);
    }
    free(list->items);
    free(list);
}

YCL_EXPORT void _tlv_atexit(void (*fn)(void *), void *object) {
    os_unfair_lock_lock(&dtor_lock);
    if (!dtor_key_ready) {
        if (pthread_key_create(&dtor_key, run_dtors) != 0) abort();
        dtor_key_ready = 1;
    }
    os_unfair_lock_unlock(&dtor_lock);
    struct tlv_dtor_list *list = pthread_getspecific(dtor_key);
    if (!list) {
        list = calloc(1, sizeof *list);
        if (!list) abort();
        pthread_setspecific(dtor_key, list);
    }
    if (list->count == list->capacity) {
        size_t capacity = list->capacity ? list->capacity * 2 : 8;
        struct tlv_dtor *items = realloc(list->items, capacity * sizeof *items);
        if (!items) abort();
        list->items = items;
        list->capacity = capacity;
    }
    list->items[list->count].fn = fn;
    list->items[list->count++].object = object;
}
