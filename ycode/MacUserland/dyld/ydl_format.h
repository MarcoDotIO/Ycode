// ydl_format.h - the pure, host-testable part of Ycode's dynamic linker:
// LEB128, export-trie lookup, chained fixups and the classic rebase/bind
// opcode streams (specs/macos/dyld.md §2, §4). No system calls, no globals,
// so the same file builds into the guest dyld and into the host tests.
#ifndef YDL_FORMAT_H
#define YDL_FORMAT_H

#include <stddef.h>
#include <stdint.h>

#include "yc_macho.h"

/* Reads a ULEB128/SLEB128 at *p (never past end). Sets *bad on overrun. */
uint64_t ydl_uleb(const uint8_t **p, const uint8_t *end, int *bad);
int64_t ydl_sleb(const uint8_t **p, const uint8_t *end, int *bad);

/* One export-trie terminal. */
struct ydl_export {
    uint64_t flags;
    uint64_t value;          /* image offset (regular, thread-local), absolute value, or stub offset */
    uint64_t resolver;       /* STUB_AND_RESOLVER: the resolver's image offset */
    uint64_t reexport_ordinal; /* REEXPORT: 1-based dependency ordinal */
    const char *import_name; /* REEXPORT: the name in that dependency ("" = same name) */
};

/* Finds `name` in an export trie. Returns 1 when found, 0 when absent,
   -1 when the trie is malformed. */
int ydl_trie_find(const uint8_t *trie, size_t size, const char *name, struct ydl_export *out);

/* One chained-fixup import (LC_DYLD_CHAINED_FIXUPS). */
struct ydl_import {
    int32_t ordinal;   /* 1-based dependency, or YC_BIND_* specials */
    int weak;          /* weak import: a missing symbol binds to 0 */
    const char *name;
    int64_t addend;
};

/* Validates a chained-fixups blob and returns its import count (≥ 0), or
   -1 when it is malformed or uses a format Ycode does not support. */
int64_t ydl_chained_import_count(const uint8_t *blob, size_t size);
/* Decodes import `index`. Returns 0, or -1 when malformed. */
int ydl_chained_import(const uint8_t *blob, size_t size, uint32_t index, struct ydl_import *out);

/* Applies every chained fixup of an image loaded at `load_address` (the
   address of its Mach-O header), whose header's unslid address is
   `preferred_base`. `targets[i]` is the resolved address of import i
   plus the import's own addend (the pointer's 8-bit addend is added here). Returns the number of fixups applied, or -1
   (with *why set) on a malformed chain or an unsupported pointer format. */
int64_t ydl_chained_apply(const uint8_t *blob, size_t size, uint8_t *load_address, uint64_t preferred_base,
                          const uint64_t *targets, uint32_t ntargets, const char **why);

/* Classic LC_DYLD_INFO streams. `segment_addresses[i]` is segment i's
   loaded start address and `segment_sizes[i]` its vm size. */
struct ydl_classic_bind {
    int32_t ordinal;
    int weak;
    const char *name;
    int64_t addend;
    uint64_t *location;
};
typedef int (*ydl_bind_fn)(void *context, const struct ydl_classic_bind *bind);

int64_t ydl_rebase_apply(const uint8_t *opcodes, size_t size, const uint64_t *segment_addresses,
                         const uint64_t *segment_sizes, uint32_t nsegments, uint64_t slide, const char **why);
/* Calls `fn` for every bind of the stream (normal or lazy); a non-zero
   return from `fn` stops the walk with -1. Returns the number of binds. */
int64_t ydl_bind_walk(const uint8_t *opcodes, size_t size, const uint64_t *segment_addresses,
                      const uint64_t *segment_sizes, uint32_t nsegments, int lazy, ydl_bind_fn fn, void *context,
                      const char **why);

/* Small freestanding helpers (the guest dyld links no library). */
int ydl_strcmp(const char *a, const char *b);
size_t ydl_strlen(const char *s);

#endif
