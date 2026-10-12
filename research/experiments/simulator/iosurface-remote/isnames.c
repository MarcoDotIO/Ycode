/*
 * isnames: list the exported symbol NAMES of a loaded image (original Ycode
 * code, R5). It dlopens each argument, finds the image's mach header, and
 * walks the image's export trie (LC_DYLD_EXPORTS_TRIE or LC_DYLD_INFO[_ONLY])
 * in the mapped __LINKEDIT. Only names and export flags are printed; no code
 * is read. Works for images inside the simulator's shared cache.
 * Usage: isnames <image path> [<image path> ...]
 *        isnames -sym <image path> <name> ...   (dlsym check only)
 */
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t uleb(const uint8_t **p, const uint8_t *end)
{
    uint64_t v = 0;
    int s = 0;
    while (*p < end) {
        uint8_t b = *(*p)++;
        v |= (uint64_t)(b & 0x7f) << s;
        s += 7;
        if (!(b & 0x80)) break;
    }
    return v;
}

static void walk(const uint8_t *start, const uint8_t *end, const uint8_t *node, char *buf, size_t len)
{
    if (node < start || node >= end) return;
    const uint8_t *p = node;
    uint64_t tsize = uleb(&p, end);
    if (tsize) {
        const uint8_t *q = p;
        uint64_t flags = uleb(&q, end);
        printf("%s  flags=0x%llx\n", buf, (unsigned long long)flags);
    }
    p += tsize;
    if (p >= end) return;
    uint8_t n = *p++;
    for (uint8_t i = 0; i < n && p < end; i++) {
        size_t l = strnlen((const char *)p, (size_t)(end - p));
        if (len + l + 1 > 4096) return;
        memcpy(buf + len, p, l + 1);
        p += l + 1;
        uint64_t off = uleb(&p, end);
        walk(start, end, start + off, buf, len + l);
        buf[len] = 0;
    }
}

static void list(const char *path)
{
    void *h = dlopen(path, RTLD_NOW);
    if (!h) { printf("== %s: %s\n", path, dlerror()); return; }
    const char *base = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *nm = _dyld_get_image_name(i);
        const char *b = strrchr(nm, '/') ? strrchr(nm, '/') + 1 : nm;
        if (strcmp(b, base)) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        printf("== image %s\n", nm);
        const uint8_t *lc = (const uint8_t *)(mh + 1);
        uint64_t le_vm = 0, le_off = 0;
        uint32_t trie_off = 0, trie_size = 0;
        for (uint32_t k = 0; k < mh->ncmds; k++) {
            const struct load_command *c = (const struct load_command *)lc;
            if (c->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *s = (const void *)c;
                if (!strcmp(s->segname, "__LINKEDIT")) { le_vm = s->vmaddr; le_off = s->fileoff; }
            } else if (c->cmd == LC_DYLD_EXPORTS_TRIE) {
                const struct linkedit_data_command *d = (const void *)c;
                trie_off = d->dataoff; trie_size = d->datasize;
            } else if (c->cmd == LC_DYLD_INFO || c->cmd == LC_DYLD_INFO_ONLY) {
                const struct dyld_info_command *d = (const void *)c;
                if (!trie_off) { trie_off = d->export_off; trie_size = d->export_size; }
            } else if (c->cmd == LC_LOAD_DYLIB || c->cmd == LC_LOAD_WEAK_DYLIB || c->cmd == LC_REEXPORT_DYLIB) {
                const struct dylib_command *d = (const void *)c;
                printf("  links %s\n", (const char *)c + d->dylib.name.offset);
            }
            lc += c->cmdsize;
        }
        if (!trie_size) { printf("  no export trie\n"); return; }
        const uint8_t *t = (const uint8_t *)(uintptr_t)(le_vm + slide + (trie_off - le_off));
        char buf[4097] = {0};
        walk(t, t + trie_size, t, buf, 0);
        return;
    }
    printf("== %s: loaded but image not found\n", path);
}

int main(int argc, char **argv)
{
    if (argc > 2 && !strcmp(argv[1], "-sym")) {
        void *h = dlopen(argv[2], RTLD_NOW);
        for (int i = 3; i < argc; i++) printf("%s %s\n", argv[i], h && dlsym(h, argv[i]) ? "present" : "absent");
        return 0;
    }
    for (int i = 1; i < argc; i++) list(argv[i]);
    return 0;
}
