// ydl_format.c - export tries, chained fixups and classic rebase/bind
// opcodes (specs/macos/dyld.md §2, §4). Clean-room Ycode code written from
// the public Mach-O format headers' definitions; host-testable (no system
// calls, no global state).
#include "ydl_format.h"

int ydl_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (unsigned char)*a - (unsigned char)*b;
}

size_t ydl_strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32; }

uint64_t ydl_uleb(const uint8_t **p, const uint8_t *end, int *bad) {
    uint64_t result = 0;
    unsigned shift = 0;
    const uint8_t *q = *p;
    for (;;) {
        if (q >= end) {
            *bad = 1;
            break;
        }
        uint8_t byte = *q++;
        if (shift < 64) result |= (uint64_t)(byte & 0x7F) << shift;
        shift += 7;
        if (!(byte & 0x80)) break;
        if (shift > 70) {
            *bad = 1;
            break;
        }
    }
    *p = q;
    return result;
}

int64_t ydl_sleb(const uint8_t **p, const uint8_t *end, int *bad) {
    int64_t result = 0;
    unsigned shift = 0;
    uint8_t byte = 0;
    const uint8_t *q = *p;
    do {
        if (q >= end) {
            *bad = 1;
            *p = q;
            return 0;
        }
        byte = *q++;
        if (shift < 64) result |= (int64_t)((uint64_t)(byte & 0x7F) << shift);
        shift += 7;
    } while ((byte & 0x80) && shift <= 70);
    if ((byte & 0x40) && shift < 64) result |= (int64_t)(~(uint64_t)0 << shift);
    *p = q;
    return result;
}

int ydl_trie_find(const uint8_t *trie, size_t size, const char *name, struct ydl_export *out) {
    const uint8_t *end = trie + size;
    const char *rest = name;
    uint64_t node = 0;
    int bad = 0;
    for (unsigned depth = 0; depth < 4096; depth++) {
        if (node >= size) return -1;
        const uint8_t *p = trie + node;
        uint64_t terminal = ydl_uleb(&p, end, &bad);
        if (bad || terminal > (uint64_t)(end - p)) return -1;
        if (*rest == 0) {
            if (terminal == 0) return 0;
            const uint8_t *t = p, *tend = p + terminal;
            out->flags = ydl_uleb(&t, tend, &bad);
            out->value = out->resolver = out->reexport_ordinal = 0;
            out->import_name = "";
            if (out->flags & YC_EXPORT_REEXPORT) {
                out->reexport_ordinal = ydl_uleb(&t, tend, &bad);
                const uint8_t *s = t;
                while (s < tend && *s) s++;
                if (s >= tend) return -1;
                out->import_name = (const char *)t;
            } else if (out->flags & YC_EXPORT_STUB_AND_RESOLVER) {
                out->value = ydl_uleb(&t, tend, &bad);
                out->resolver = ydl_uleb(&t, tend, &bad);
            } else {
                out->value = ydl_uleb(&t, tend, &bad);
            }
            return bad ? -1 : 1;
        }
        const uint8_t *c = p + terminal;
        if (c >= end) return -1;
        unsigned count = *c++;
        int matched = 0;
        for (unsigned i = 0; i < count; i++) {
            const uint8_t *edge = c;
            const char *r = rest;
            int same = 1;
            while (c < end && *c) {
                if (same && (unsigned char)*r == *c) {
                    r++;
                } else {
                    same = 0;
                }
                c++;
            }
            if (c >= end || c == edge) return -1;
            c++;  // the edge's NUL
            uint64_t child = ydl_uleb(&c, end, &bad);
            if (bad) return -1;
            if (same) {
                rest = r;
                node = child;
                matched = 1;
                break;
            }
        }
        if (!matched) return 0;
    }
    return -1;
}

// --- chained fixups ---------------------------------------------------------

int64_t ydl_chained_import_count(const uint8_t *blob, size_t size) {
    if (size < 28) return -1;
    uint32_t version = rd32(blob), starts = rd32(blob + 4), imports = rd32(blob + 8), symbols = rd32(blob + 12);
    uint32_t count = rd32(blob + 16), format = rd32(blob + 20), symformat = rd32(blob + 24);
    if (version != 0 || symformat != 0 || starts >= size || imports > size || symbols > size) return -1;
    uint64_t width = format == YC_CHAINED_IMPORT ? 4 : format == YC_CHAINED_IMPORT_ADDEND ? 8
                   : format == YC_CHAINED_IMPORT_ADDEND64 ? 16 : 0;
    if (width == 0 || imports + width * count > size) return -1;
    return count;
}

int ydl_chained_import(const uint8_t *blob, size_t size, uint32_t index, struct ydl_import *out) {
    int64_t count = ydl_chained_import_count(blob, size);
    if (count < 0 || index >= (uint64_t)count) return -1;
    uint32_t imports = rd32(blob + 8), symbols = rd32(blob + 12), format = rd32(blob + 20);
    uint64_t name_offset;
    if (format == YC_CHAINED_IMPORT_ADDEND64) {
        const uint8_t *r = blob + imports + 16 * (uint64_t)index;
        uint64_t w = rd64(r);
        uint16_t ordinal = (uint16_t)(w & 0xFFFF);
        out->ordinal = ordinal >= 0xFFF0 ? (int32_t)(int16_t)ordinal : ordinal;
        out->weak = (int)((w >> 16) & 1);
        name_offset = w >> 32;
        out->addend = (int64_t)rd64(r + 8);
    } else {
        const uint8_t *r = blob + imports + (format == YC_CHAINED_IMPORT ? 4 : 8) * (uint64_t)index;
        uint32_t w = rd32(r);
        uint8_t ordinal = (uint8_t)(w & 0xFF);
        out->ordinal = ordinal >= 0xF0 ? (int32_t)(int8_t)ordinal : ordinal;
        out->weak = (int)((w >> 8) & 1);
        name_offset = w >> 9;
        out->addend = format == YC_CHAINED_IMPORT_ADDEND ? (int64_t)(int32_t)rd32(r + 4) : 0;
    }
    if (symbols + name_offset >= size) return -1;
    const uint8_t *s = blob + symbols + name_offset;
    while (s < blob + size && *s) s++;
    if (s >= blob + size) return -1;
    out->name = (const char *)(blob + symbols + name_offset);
    return 0;
}

int64_t ydl_chained_apply(const uint8_t *blob, size_t size, uint8_t *load_address, uint64_t preferred_base,
                          const uint64_t *targets, uint32_t ntargets, const char **why) {
    if (ydl_chained_import_count(blob, size) < 0) {
        *why = "malformed chained-fixups header";
        return -1;
    }
    uint32_t starts = rd32(blob + 4);
    if (starts + 4 > size) {
        *why = "chained starts out of range";
        return -1;
    }
    const uint8_t *image_starts = blob + starts;
    uint32_t segments = rd32(image_starts);
    if (starts + 4 + 4 * (uint64_t)segments > size) {
        *why = "chained segment table out of range";
        return -1;
    }
    uint64_t slide = (uint64_t)(uintptr_t)load_address - preferred_base;
    int64_t applied = 0;
    for (uint32_t i = 0; i < segments; i++) {
        uint32_t offset = rd32(image_starts + 4 + 4 * i);
        if (offset == 0) continue;
        if (starts + (uint64_t)offset + 22 > size) {
            *why = "chained segment starts out of range";
            return -1;
        }
        const uint8_t *seg = image_starts + offset;
        uint16_t page_size = rd16(seg + 4), format = rd16(seg + 6), page_count = rd16(seg + 20);
        uint64_t segment_offset = rd64(seg + 8);
        if (starts + (uint64_t)offset + 22 + 2 * (uint64_t)page_count > size || page_size == 0) {
            *why = "chained page table out of range";
            return -1;
        }
        if (format != YC_CHAINED_PTR_64 && format != YC_CHAINED_PTR_64_OFFSET) {
            *why = "unsupported chained pointer format (arm64e and 32-bit formats are not supported)";
            return -1;
        }
        for (uint32_t page = 0; page < page_count; page++) {
            uint16_t start = rd16(seg + 22 + 2 * page);
            if (start == YC_CHAINED_PTR_START_NONE) continue;
            if (start & YC_CHAINED_PTR_START_MULTI) {
                *why = "multi-start pages are not used by 64-bit formats";
                return -1;
            }
            uint8_t *page_base = load_address + segment_offset + (uint64_t)page * page_size;
            uint8_t *loc = page_base + start;
            for (;;) {
                if (loc + 8 > page_base + page_size) {
                    *why = "a fixup chain leaves its page";
                    return -1;
                }
                uint64_t v = *(uint64_t *)loc, value;
                uint64_t next = (v >> 51) & 0xFFF;
                if (v >> 63) {
                    uint32_t ordinal = (uint32_t)(v & 0xFFFFFF);
                    uint64_t addend = (v >> 24) & 0xFF;
                    if (ordinal >= ntargets) {
                        *why = "a bind names an import past the import table";
                        return -1;
                    }
                    value = targets[ordinal] + addend;
                } else {
                    uint64_t target = v & 0xFFFFFFFFFull, high8 = (v >> 36) & 0xFF;
                    value = format == YC_CHAINED_PTR_64 ? target + slide : (uint64_t)(uintptr_t)load_address + target;
                    value |= high8 << 56;
                }
                *(uint64_t *)loc = value;
                applied++;
                if (next == 0) break;
                loc += next * 4;
            }
        }
    }
    return applied;
}

// --- classic opcodes ---------------------------------------------------------

static uint64_t *slot(const uint64_t *addresses, const uint64_t *sizes, uint32_t n, uint32_t seg, uint64_t offset) {
    if (seg >= n || offset + 8 > sizes[seg] || offset + 8 < offset) return 0;
    return (uint64_t *)(uintptr_t)(addresses[seg] + offset);
}

int64_t ydl_rebase_apply(const uint8_t *p, size_t size, const uint64_t *addresses, const uint64_t *sizes,
                         uint32_t n, uint64_t slide, const char **why) {
    const uint8_t *end = p + size;
    uint32_t seg = 0;
    uint64_t offset = 0, count = 0, times, skip;
    int bad = 0, type = 0;
    while (p < end) {
        uint8_t byte = *p++, op = byte & YC_REBASE_OPCODE_MASK, imm = byte & YC_REBASE_IMMEDIATE_MASK;
        switch (op) {
        case YC_REBASE_OPCODE_DONE:
            return (int64_t)count;
        case YC_REBASE_OPCODE_SET_TYPE_IMM:
            type = imm;
            break;
        case YC_REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
            seg = imm;
            offset = ydl_uleb(&p, end, &bad);
            break;
        case YC_REBASE_OPCODE_ADD_ADDR_ULEB:
            offset += ydl_uleb(&p, end, &bad);
            break;
        case YC_REBASE_OPCODE_ADD_ADDR_IMM_SCALED:
            offset += (uint64_t)imm * 8;
            break;
        case YC_REBASE_OPCODE_DO_REBASE_IMM_TIMES:
        case YC_REBASE_OPCODE_DO_REBASE_ULEB_TIMES:
        case YC_REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB:
        case YC_REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB:
            times = op == YC_REBASE_OPCODE_DO_REBASE_IMM_TIMES ? imm
                  : op == YC_REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB ? 1 : ydl_uleb(&p, end, &bad);
            skip = op == YC_REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB || op == YC_REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB
                 ? ydl_uleb(&p, end, &bad) : 0;
            if (bad) break;
            for (uint64_t i = 0; i < times; i++) {
                uint64_t *s = slot(addresses, sizes, n, seg, offset);
                if (!s || type != YC_REBASE_TYPE_POINTER) {
                    *why = s ? "unsupported rebase type" : "a rebase leaves its segment";
                    return -1;
                }
                *s += slide;
                count++;
                offset += skip + 8;
            }
            break;
        default:
            *why = "unknown rebase opcode";
            return -1;
        }
        if (bad) {
            *why = "truncated rebase opcodes";
            return -1;
        }
    }
    return (int64_t)count;
}

int64_t ydl_bind_walk(const uint8_t *p, size_t size, const uint64_t *addresses, const uint64_t *sizes, uint32_t n,
                      int lazy, ydl_bind_fn fn, void *context, const char **why) {
    const uint8_t *end = p + size;
    struct ydl_classic_bind b = {0, 0, 0, 0, 0};
    uint32_t seg = 0;
    uint64_t offset = 0, count = 0, times, skip;
    int bad = 0;
    while (p < end) {
        uint8_t byte = *p++, op = byte & YC_BIND_OPCODE_MASK, imm = byte & YC_BIND_IMMEDIATE_MASK;
        switch (op) {
        case YC_BIND_OPCODE_DONE:
            if (!lazy) return (int64_t)count;
            break;
        case YC_BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
            b.ordinal = imm;
            break;
        case YC_BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
            b.ordinal = (int32_t)ydl_uleb(&p, end, &bad);
            break;
        case YC_BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
            b.ordinal = imm == 0 ? 0 : (int32_t)(int8_t)(YC_BIND_OPCODE_MASK | imm);
            break;
        case YC_BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
            b.name = (const char *)p;
            b.weak = imm & YC_BIND_SYMBOL_FLAGS_WEAK_IMPORT;
            while (p < end && *p) p++;
            if (p >= end) bad = 1;
            else p++;
            break;
        case YC_BIND_OPCODE_SET_TYPE_IMM:
            if (imm != YC_BIND_TYPE_POINTER) {
                *why = "unsupported bind type";
                return -1;
            }
            break;
        case YC_BIND_OPCODE_SET_ADDEND_SLEB:
            b.addend = ydl_sleb(&p, end, &bad);
            break;
        case YC_BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
            seg = imm;
            offset = ydl_uleb(&p, end, &bad);
            break;
        case YC_BIND_OPCODE_ADD_ADDR_ULEB:
            offset += ydl_uleb(&p, end, &bad);
            break;
        case YC_BIND_OPCODE_DO_BIND:
        case YC_BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
        case YC_BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
        case YC_BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
            times = op == YC_BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB ? ydl_uleb(&p, end, &bad) : 1;
            skip = op == YC_BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB ? ydl_uleb(&p, end, &bad)
                 : op == YC_BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED ? (uint64_t)imm * 8
                 : op == YC_BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB ? ydl_uleb(&p, end, &bad) : 0;
            if (bad) break;
            if (!b.name) {
                *why = "a bind without a symbol";
                return -1;
            }
            for (uint64_t i = 0; i < times; i++) {
                b.location = slot(addresses, sizes, n, seg, offset);
                if (!b.location) {
                    *why = "a bind leaves its segment";
                    return -1;
                }
                if (fn(context, &b) != 0) {
                    *why = "a symbol could not be bound";
                    return -1;
                }
                count++;
                offset += skip + 8;
            }
            break;
        default:
            *why = op == YC_BIND_OPCODE_THREADED ? "threaded binds (arm64e) are not supported" : "unknown bind opcode";
            return -1;
        }
        if (bad) {
            *why = "truncated bind opcodes";
            return -1;
        }
    }
    return (int64_t)count;
}
