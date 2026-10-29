// exports: lists the exported symbol names (export trie) and the symbol
// table names (LC_SYMTAB, the names dladdr reports) of a loaded image that
// contain a given text (visionos.md §10.9, round R2b). Binary metadata only (names
// from the image's export trie, evidence level 4); nothing is disassembled.
//   exports <image path> <text> [<output file>]
// The image is loaded with dlopen; its export trie (LC_DYLD_EXPORTS_TRIE, or
// the export range of LC_DYLD_INFO_ONLY) is walked in memory.

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *out;
static const char *want;
static const uint8_t *trieStart, *trieEnd;

static uint64_t uleb(const uint8_t **p) {
    uint64_t v = 0;
    int shift = 0;
    while (*p < trieEnd) {
        uint8_t b = *(*p)++;
        v |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) break;
        shift += 7;
    }
    return v;
}

static void walk(const uint8_t *node, char *name, size_t len, int depth) {
    if (node < trieStart || node >= trieEnd || depth > 4096 || len > 4000) return;
    const uint8_t *p = node;
    uint64_t termSize = uleb(&p);
    if (termSize && strstr(name, want)) fprintf(out, "%s\n", name);
    p += termSize;
    if (p >= trieEnd) return;
    uint8_t children = *p++;
    for (uint8_t i = 0; i < children && p < trieEnd; i++) {
        const char *edge = (const char *)p;
        size_t el = strnlen(edge, (size_t)(trieEnd - p));
        p += el + 1;
        uint64_t off = uleb(&p);
        memcpy(name + len, edge, el);
        name[len + el] = 0;
        walk(trieStart + off, name, len + el, depth + 1);
        name[len] = 0;
    }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "exports <image> <text> [out]\n"); return 64; }
    want = argv[2];
    out = argc > 3 ? fopen(argv[3], "w") : stdout;
    if (!out) return 73;
    if (!dlopen(argv[1], RTLD_LAZY)) { fprintf(out, "dlopen failed: %s\n", dlerror()); return 1; }
    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (strstr(_dyld_get_image_name(i), argv[1])) { mh = (const void *)_dyld_get_image_header(i); slide = _dyld_get_image_vmaddr_slide(i); }
    if (!mh) { fprintf(out, "image not found among loaded images\n"); return 1; }
    const struct load_command *lc = (const void *)(mh + 1);
    uint64_t linkeditVM = 0, linkeditFile = 0, trieOff = 0, trieSize = 0;
    const struct symtab_command *st = NULL;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const void *)lc;
            if (strcmp(sc->segname, "__LINKEDIT") == 0) { linkeditVM = sc->vmaddr; linkeditFile = sc->fileoff; }
        } else if (lc->cmd == LC_SYMTAB) {
            st = (const void *)lc;
        } else if (lc->cmd == LC_DYLD_EXPORTS_TRIE) {
            const struct linkedit_data_command *ld = (const void *)lc;
            trieOff = ld->dataoff; trieSize = ld->datasize;
        } else if (lc->cmd == LC_DYLD_INFO_ONLY || lc->cmd == LC_DYLD_INFO) {
            const struct dyld_info_command *di = (const void *)lc;
            if (!trieSize) { trieOff = di->export_off; trieSize = di->export_size; }
        }
        lc = (const void *)((const char *)lc + lc->cmdsize);
    }
    if (!trieSize || !linkeditVM) { fprintf(out, "no export trie\n"); return 1; }
    trieStart = (const uint8_t *)(uintptr_t)(linkeditVM + slide + (trieOff - linkeditFile));
    trieEnd = trieStart + trieSize;
    char *name = calloc(1, 8192);
    fprintf(out, "# export trie\n");
    walk(trieStart, name, 0, 0);
    if (st) {
        fprintf(out, "# symbol table (defined symbols)\n");
        const struct nlist_64 *nl = (const void *)(uintptr_t)(linkeditVM + slide + (st->symoff - linkeditFile));
        const char *strs = (const char *)(uintptr_t)(linkeditVM + slide + (st->stroff - linkeditFile));
        for (uint32_t i = 0; i < st->nsyms; i++) {
            if ((nl[i].n_type & N_TYPE) != N_SECT || nl[i].n_un.n_strx >= st->strsize) continue;
            const char *n = strs + nl[i].n_un.n_strx;
            if (strstr(n, want)) fprintf(out, "%s%s\n", n, (nl[i].n_type & N_EXT) ? "" : " (local)");
        }
    }
    fclose(out);
    return 0;
}
