// ydl_format_test.c - host unit tests for the format layer of Ycode's
// dynamic linker (specs/macos/dyld.md §11). The inputs are built by hand
// from the public format facts of dyld.md §2. Run by `sh build.sh test`.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ydl_format.h"

static int failures, checks;

#define CHECK(cond)                                                            \
    do {                                                                       \
        checks++;                                                              \
        if (!(cond)) {                                                         \
            failures++;                                                        \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                      \
    } while (0)

static void put32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}
static void put16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}
static void put64(uint8_t *p, uint64_t v) {
    put32(p, (uint32_t)v);
    put32(p + 4, (uint32_t)(v >> 32));
}

static void test_leb(void) {
    const uint8_t u[] = {0xE5, 0x8E, 0x26};
    const uint8_t *p = u;
    int bad = 0;
    CHECK(ydl_uleb(&p, u + 3, &bad) == 624485 && !bad && p == u + 3);
    const uint8_t s1[] = {0x7F}, s2[] = {0x80, 0x7F}, s3[] = {0x78};
    p = s1;
    CHECK(ydl_sleb(&p, s1 + 1, &bad) == -1 && !bad);
    p = s2;
    CHECK(ydl_sleb(&p, s2 + 2, &bad) == -128 && !bad);
    p = s3;
    CHECK(ydl_sleb(&p, s3 + 1, &bad) == -8 && !bad);
    const uint8_t cut[] = {0x80, 0x80};
    p = cut;
    bad = 0;
    ydl_uleb(&p, cut + 2, &bad);
    CHECK(bad);
}

// root: edges "_a" -> A (regular, value 0x1000) and "_b" -> B (re-export
// of "_c" from dependency 1).
static const uint8_t trie[] = {
    0x00, 0x02, '_', 'a', 0, 10, '_', 'b', 0, 15,     // root (0)
    0x03, 0x00, 0x80, 0x20, 0x00,                    // A (10)
    0x05, 0x08, 0x01, '_', 'c', 0, 0x00,             // B (15)
};

static void test_trie(void) {
    struct ydl_export e;
    CHECK(ydl_trie_find(trie, sizeof trie, "_a", &e) == 1 && e.flags == 0 && e.value == 0x1000);
    CHECK(ydl_trie_find(trie, sizeof trie, "_b", &e) == 1 && (e.flags & YC_EXPORT_REEXPORT) &&
          e.reexport_ordinal == 1 && strcmp(e.import_name, "_c") == 0);
    CHECK(ydl_trie_find(trie, sizeof trie, "_x", &e) == 0);
    CHECK(ydl_trie_find(trie, sizeof trie, "_", &e) == 0);
    CHECK(ydl_trie_find(trie, sizeof trie, "_ab", &e) == 0);
    CHECK(ydl_trie_find(trie, 12, "_b", &e) == -1);  // the child offset is past the end
}

// A chained-fixups blob: two segments, the second with one 16 KB page whose
// chain is a rebase at +0 and a bind of import 1 (+4) at +8.
static size_t make_chained(uint8_t *b, uint16_t pointer_format) {
    memset(b, 0, 128);
    put32(b + 0, 0);     // version
    put32(b + 4, 32);    // starts
    put32(b + 8, 68);    // imports
    put32(b + 12, 76);   // symbols
    put32(b + 16, 2);    // import count
    put32(b + 20, YC_CHAINED_IMPORT);
    put32(b + 24, 0);
    put32(b + 32, 2);    // segment count
    put32(b + 36, 0);
    put32(b + 40, 12);   // -> 44
    put32(b + 44, 24);
    put16(b + 48, 0x4000);
    put16(b + 50, pointer_format);
    put64(b + 52, 0x4000);
    put32(b + 60, 0);
    put16(b + 64, 1);
    put16(b + 66, 0);    // the chain starts at the page's first byte
    put32(b + 68, 1u | 0u << 8 | 1u << 9);      // ordinal 1, "_foo"
    put32(b + 72, 0xFEu | 1u << 8 | 6u << 9);   // flat lookup, weak, "_bar"
    memcpy(b + 76, "\0_foo\0_bar\0", 11);
    return 87;
}

static void test_chained(void) {
    uint8_t blob[128];
    size_t size = make_chained(blob, YC_CHAINED_PTR_64_OFFSET);
    CHECK(ydl_chained_import_count(blob, size) == 2);
    struct ydl_import imp;
    CHECK(ydl_chained_import(blob, size, 0, &imp) == 0 && imp.ordinal == 1 && !imp.weak && strcmp(imp.name, "_foo") == 0);
    CHECK(ydl_chained_import(blob, size, 1, &imp) == 0 && imp.ordinal == -2 && imp.weak && strcmp(imp.name, "_bar") == 0);
    CHECK(ydl_chained_import(blob, size, 2, &imp) == -1);

    uint8_t *image = aligned_alloc(16384, 0x8000);
    memset(image, 0, 0x8000);
    uint64_t targets[2] = {0x1111, 0x2222};
    const char *why = 0;
    put64(image + 0x4000, 2ull << 51 | 0x100);
    put64(image + 0x4008, 1ull << 63 | 4ull << 24 | 1);
    CHECK(ydl_chained_apply(blob, size, image, 0, targets, 2, &why) == 2);
    uint64_t v0, v1;
    memcpy(&v0, image + 0x4000, 8);
    memcpy(&v1, image + 0x4008, 8);
    CHECK(v0 == (uint64_t)(uintptr_t)image + 0x100);
    CHECK(v1 == 0x2222 + 4);

    // DYLD_CHAINED_PTR_64: an unslid target, with a high byte.
    size = make_chained(blob, YC_CHAINED_PTR_64);
    put64(image + 0x4000, 0x5Aull << 36 | 0x100000100ull);
    CHECK(ydl_chained_apply(blob, size, image, 0x100000000ull, targets, 1, &why) == 1);
    memcpy(&v0, image + 0x4000, 8);
    CHECK(v0 == (((uint64_t)(uintptr_t)image + 0x100) | 0x5Aull << 56));

    // A bind past the import table and an unsupported format are errors.
    put64(image + 0x4000, 1ull << 63 | 7);
    CHECK(ydl_chained_apply(blob, size, image, 0x100000000ull, targets, 2, &why) == -1);
    make_chained(blob, 1 /* arm64e */);
    CHECK(ydl_chained_apply(blob, size, image, 0, targets, 2, &why) == -1);
    free(image);
}

struct seen {
    int n;
    struct ydl_classic_bind b[4];
};
static int record(void *context, const struct ydl_classic_bind *b) {
    struct seen *s = context;
    if (s->n < 4) s->b[s->n++] = *b;
    *b->location = 0xB0B0;
    return 0;
}

static void test_classic(void) {
    uint64_t seg0[2] = {0, 0}, seg1[4] = {0x100, 0x200, 0x300, 0x400};
    uint64_t addresses[2] = {(uint64_t)(uintptr_t)seg0, (uint64_t)(uintptr_t)seg1}, sizes[2] = {16, 32};
    const char *why = 0;
    const uint8_t rebase[] = {0x11, 0x21, 8, 0x52, 0x00};
    CHECK(ydl_rebase_apply(rebase, sizeof rebase, addresses, sizes, 2, 0x1000, &why) == 2);
    CHECK(seg1[0] == 0x100 && seg1[1] == 0x1200 && seg1[2] == 0x1300 && seg1[3] == 0x400);
    const uint8_t skipping[] = {0x11, 0x21, 0, 0x80, 2, 8, 0x00};
    CHECK(ydl_rebase_apply(skipping, sizeof skipping, addresses, sizes, 2, 1, &why) == 2);
    CHECK(seg1[0] == 0x101 && seg1[2] == 0x1301 && seg1[1] == 0x1200);
    const uint8_t outside[] = {0x11, 0x21, 32, 0x51, 0x00};
    CHECK(ydl_rebase_apply(outside, sizeof outside, addresses, sizes, 2, 1, &why) == -1);

    const uint8_t bind[] = {0x11, 0x40, '_', 'f', 'o', 'o', 0, 0x51, 0x71, 16, 0x90,
                            0x3E, 0x41, '_', 'b', 'a', 'r', 0, 0x60, 0x78, 0x90, 0x00};
    struct seen s = {0};
    CHECK(ydl_bind_walk(bind, sizeof bind, addresses, sizes, 2, 0, record, &s, &why) == 2);
    CHECK(s.n == 2);
    CHECK(s.b[0].ordinal == 1 && strcmp(s.b[0].name, "_foo") == 0 && !s.b[0].weak && s.b[0].location == &seg1[2]);
    CHECK(s.b[1].ordinal == -2 && strcmp(s.b[1].name, "_bar") == 0 && s.b[1].weak && s.b[1].addend == -8 &&
          s.b[1].location == &seg1[3]);
    CHECK(seg1[2] == 0xB0B0 && seg1[3] == 0xB0B0);
    const uint8_t threaded[] = {0xD0, 0x00};
    CHECK(ydl_bind_walk(threaded, sizeof threaded, addresses, sizes, 2, 0, record, &s, &why) == -1);
}

int main(void) {
    test_leb();
    test_trie();
    test_chained();
    test_classic();
    if (failures) {
        fprintf(stderr, "ydl_format_test: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("ydl_format_test: %d checks passed\n", checks);
    return 0;
}
