// ydl_main.c - Ycode's dynamic linker for macOS processes
// (specs/macos/dyld.md). The kernel maps the main executable and this
// image, builds the Darwin argument block and starts at __ydl_start; this
// code loads the dependent dylibs, applies their fixups, runs their
// initializers (libSystem's first), calls main and then libSystem's exit.
//
// Clean-room Ycode code. It is written from the Mach-O format facts in
// specs/macos/dyld.md §2 (public <mach-o/*.h> definitions) and the process
// contract of specs/simulator/darwin-process-start.md; it contains no
// Apple code. It links no library: every system call is a raw trap
// (ydl_syscall, ydl_start.S), and it has no data pointers to rebase, so the
// kernel may map it at any address (the build checks this).
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include "yc_dyld_api.h"
#include "yc_macho.h"
#include "ydl_format.h"

long ydl_syscall(long number, long a0, long a1, long a2, long a3, long a4, long a5);
void ydl_main(uint64_t *kernel_sp) __attribute__((noreturn, used));

enum {
    SYS_exit = 1, SYS_read = 3, SYS_write = 4, SYS_open = 5, SYS_close = 6, SYS_getpid = 20, SYS_munmap = 73,
    SYS_mprotect = 74, SYS_pread = 153, SYS_mmap = 197, SYS_abort_with_payload = 521,
};
enum { O_RDONLY = 0, PROT_NONE = 0, MAP_PRIVATE = 0x2, MAP_FIXED = 0x10, MAP_ANON = 0x1000 };
enum { GUEST_PAGE = 16384, OS_REASON_DYLD = 6 };

#define MAX_IMAGES 256
#define MAX_DEPS 64
#define MAX_SEGS 16
#define MAX_INIT_SECTIONS 8
#define MAX_RPATHS 8
#define MAX_CALLBACKS 16

enum { DEP_NORMAL = 0, DEP_WEAK = 1, DEP_REEXPORT = 2, DEP_UPWARD = 4 };
enum { ST_MAPPED, ST_FIXED, ST_INITIALIZING, ST_INITIALIZED };

struct image {
    uint8_t *mh;
    uint64_t slide;
    uint64_t preferred;          // unslid address of the Mach-O header
    const char *path;            // the path it was loaded from
    const char *install_name;    // LC_ID_DYLIB, or NULL
    uint64_t start, end;         // loaded range
    uint32_t nsegs;
    uint64_t seg_addr[MAX_SEGS], seg_size[MAX_SEGS];
    uint32_t seg_flags[MAX_SEGS];
    int32_t seg_initprot[MAX_SEGS];
    const uint8_t *linkedit;     // file offset 0 of __LINKEDIT's data, as loaded
    uint32_t exports_off, exports_size, chained_off, chained_size;
    struct yc_dyld_info_command info;
    int has_info;
    uint32_t symoff, nsyms, stroff, strsize;
    uint32_t ndeps;
    const char *dep_name[MAX_DEPS];
    uint8_t dep_kind[MAX_DEPS];
    int16_t dep[MAX_DEPS];       // image index, or -1 (a missing weak dylib)
    uint32_t ninits;
    uint64_t init_addr[MAX_INIT_SECTIONS], init_size[MAX_INIT_SECTIONS];
    uint8_t init_offsets[MAX_INIT_SECTIONS];
    uint32_t nrpaths;
    const char *rpath[MAX_RPATHS];
    uint64_t entryoff;
    int has_main;
    int state;
};

struct program_vars {
    const void *mh;
    int *NXArgcPtr;
    char ***NXArgvPtr;
    char ***environPtr;
    const char **prognamePtr;
};

static struct image images[MAX_IMAGES];
static uint32_t nimages;
static int main_index = -1, libsystem_index = -1;
static int print_libraries;
static int print_segments;  // DYLD_PRINT_SEGMENTS: each image's load address
static const char *library_path;
static const char *executable_path;  // set at start (no data pointers to rebase)
static int NXArgc;
static char **NXArgv, **environ_storage, **apple_strings;
static const char *progname;
static struct program_vars vars;
static struct yc_dyld_api api;
static char last_error[512];
static int error_pending;
static void (*add_callbacks[MAX_CALLBACKS])(const void *, intptr_t);
static uint32_t ncallbacks;
static volatile int big_lock;

// --- small libc ----------------------------------------------------------------

void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = dst;
    const uint8_t *s = src;
    while (n--) *d++ = *s++;
    return dst;
}
void *memset(void *dst, int c, size_t n) {
    uint8_t *d = dst;
    while (n--) *d++ = (uint8_t)c;
    return dst;
}

static int starts_with(const char *s, const char *prefix) {
    while (*prefix)
        if (*s++ != *prefix++) return 0;
    return 1;
}

static long sys_write(int fd, const void *p, size_t n) { return ydl_syscall(SYS_write, fd, (long)p, (long)n, 0, 0, 0); }

static void *ydl_alloc(size_t size) {
    static uint8_t *chunk;
    static size_t left;
    size = (size + 15) & ~(size_t)15;
    if (size > left) {
        size_t want = size > 262144 ? (size + GUEST_PAGE - 1) & ~(size_t)(GUEST_PAGE - 1) : 262144;
        long p = ydl_syscall(SYS_mmap, 0, (long)want, 3, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p < 0 && p > -4096) return 0;
        chunk = (uint8_t *)p;
        left = want;
    }
    void *r = chunk;
    chunk += size;
    left -= size;
    return r;
}

// A message buffer: the fatal and dlerror paths build text without printf.
struct text {
    char *buf;
    size_t cap, len;
};
static void put(struct text *t, const char *s) {
    while (s && *s && t->len + 1 < t->cap) t->buf[t->len++] = *s++;
    t->buf[t->len] = 0;
}
static void put_dec(struct text *t, uint64_t v) {
    char d[24];
    int n = 0;
    do d[n++] = (char)('0' + v % 10); while ((v /= 10) && n < 23);
    char r[24];
    for (int i = 0; i < n; i++) r[i] = d[n - 1 - i];
    r[n] = 0;
    put(t, r);
}
static void say(const char *a, const char *b, const char *c) {
    char buf[1024];
    struct text t = {buf, sizeof buf, 0};
    put(&t, "dyld[");
    put_dec(&t, (uint64_t)ydl_syscall(SYS_getpid, 0, 0, 0, 0, 0, 0));
    put(&t, "]: ");
    put(&t, a);
    put(&t, b);
    put(&t, c);
    put(&t, "\n");
    sys_write(2, buf, t.len);
}

// "dyld[pid]: <path> at 0x<header address>" (DYLD_PRINT_SEGMENTS).
static void say_address(const char *path, const void *address) {
    char hex[19] = "0x";
    uint64_t v = (uint64_t)(uintptr_t)address;
    for (int i = 0; i < 16; i++) hex[2 + i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 15];
    hex[18] = 0;
    say(path, " at ", hex);
}

__attribute__((noreturn)) static void fatal(const char *a, const char *b, const char *c) {
    char buf[1024];
    struct text t = {buf, sizeof buf, 0};
    put(&t, a);
    put(&t, b);
    put(&t, c);
    say(buf, "", "");
    // As the system dyld does: the process ends with a dyld termination reason.
    ydl_syscall(SYS_abort_with_payload, OS_REASON_DYLD, 1, 0, 0, (long)buf, 0);
    ydl_syscall(SYS_exit, 134, 0, 0, 0, 0, 0);
    for (;;) {
    }
}

static void set_error(const char *a, const char *b, const char *c) {
    struct text t = {last_error, sizeof last_error, 0};
    put(&t, a);
    put(&t, b);
    put(&t, c);
    error_pending = 1;
}

static void lock(void) {
    while (__atomic_exchange_n(&big_lock, 1, __ATOMIC_ACQUIRE)) {
        while (__atomic_load_n(&big_lock, __ATOMIC_RELAXED)) __asm__ volatile("yield");
    }
}
static void unlock(void) { __atomic_store_n(&big_lock, 0, __ATOMIC_RELEASE); }

static const char *getenv_in(char **list, const char *key) {
    size_t n = ydl_strlen(key);
    for (char **e = list; e && *e; e++) {
        if (starts_with(*e, key) && (*e)[n] == '=') return *e + n + 1;
    }
    return 0;
}

static char *join(const char *dir, size_t dirlen, const char *rest) {
    size_t n = ydl_strlen(rest);
    char *p = ydl_alloc(dirlen + n + 2);
    if (!p) return 0;
    memcpy(p, dir, dirlen);
    size_t at = dirlen;
    if (at > 0 && p[at - 1] != '/' && rest[0] != '/') p[at++] = '/';
    memcpy(p + at, rest, n + 1);
    return p;
}

static size_t dirname_length(const char *path) {
    size_t n = ydl_strlen(path), slash = 0;
    int found = 0;
    for (size_t i = 0; i < n; i++)
        if (path[i] == '/') slash = i, found = 1;
    return found ? (slash == 0 ? 1 : slash) : 0;
}

// --- images ----------------------------------------------------------------------

static uint8_t *image_data(const struct image *im, uint32_t off) { return (uint8_t *)im->linkedit + off; }

// Parses the load commands of an image already mapped at `mh`.
static const char *parse_image(struct image *im) {
    const struct yc_mach_header_64 *h = (const void *)im->mh;
    const uint8_t *lc = im->mh + sizeof *h, *end = lc + h->sizeofcmds;
    uint64_t linkedit_vm = 0, linkedit_file = 0;
    int have_text = 0, have_linkedit = 0;
    im->start = ~(uint64_t)0;
    im->end = 0;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct yc_load_command *c = (const void *)lc;
        if (lc + 8 > end || c->cmdsize < 8 || lc + c->cmdsize > end) return "malformed load commands";
        switch (c->cmd) {
        case YC_LC_SEGMENT_64: {
            const struct yc_segment_command_64 *s = (const void *)lc;
            if (im->nsegs >= MAX_SEGS) return "too many segments";
            if (!have_text && s->fileoff == 0 && s->filesize > 0) {
                im->preferred = s->vmaddr;
                have_text = 1;
            }
            uint32_t k = im->nsegs++;
            im->seg_addr[k] = s->vmaddr;  // unslid until the slide is known
            im->seg_size[k] = s->vmsize;
            im->seg_flags[k] = s->flags;
            im->seg_initprot[k] = s->initprot;
            if (s->segname[0] == '_' && ydl_strcmp(s->segname, "__LINKEDIT") == 0) {
                linkedit_vm = s->vmaddr;
                linkedit_file = s->fileoff;
                have_linkedit = 1;
            }
            const struct yc_section_64 *sect = (const void *)(s + 1);
            for (uint32_t j = 0; j < s->nsects; j++) {
                uint32_t type = sect[j].flags & YC_SECTION_TYPE;
                if ((type == YC_S_MOD_INIT_FUNC_POINTERS || type == YC_S_INIT_FUNC_OFFSETS) && sect[j].size) {
                    if (im->ninits >= MAX_INIT_SECTIONS) return "too many initializer sections";
                    im->init_addr[im->ninits] = sect[j].addr;
                    im->init_size[im->ninits] = sect[j].size;
                    im->init_offsets[im->ninits++] = type == YC_S_INIT_FUNC_OFFSETS;
                }
            }
            break;
        }
        case YC_LC_LOAD_DYLIB:
        case YC_LC_LOAD_WEAK_DYLIB:
        case YC_LC_REEXPORT_DYLIB:
        case YC_LC_LOAD_UPWARD_DYLIB: {
            const struct yc_dylib_command *d = (const void *)lc;
            if (im->ndeps >= MAX_DEPS) return "too many dependent libraries";
            if (d->name_offset >= c->cmdsize) return "bad dylib name offset";
            im->dep_name[im->ndeps] = (const char *)lc + d->name_offset;
            im->dep_kind[im->ndeps] = c->cmd == YC_LC_LOAD_WEAK_DYLIB ? DEP_WEAK
                                    : c->cmd == YC_LC_REEXPORT_DYLIB ? DEP_REEXPORT
                                    : c->cmd == YC_LC_LOAD_UPWARD_DYLIB ? DEP_UPWARD : DEP_NORMAL;
            im->dep[im->ndeps++] = -1;
            break;
        }
        case YC_LC_ID_DYLIB: {
            const struct yc_dylib_command *d = (const void *)lc;
            if (d->name_offset < c->cmdsize) im->install_name = (const char *)lc + d->name_offset;
            break;
        }
        case YC_LC_RPATH: {
            const struct yc_rpath_command *r = (const void *)lc;
            if (im->nrpaths < MAX_RPATHS && r->path_offset < c->cmdsize) im->rpath[im->nrpaths++] = (const char *)lc + r->path_offset;
            break;
        }
        case YC_LC_DYLD_INFO:
        case YC_LC_DYLD_INFO_ONLY:
            memcpy(&im->info, lc, sizeof im->info);
            im->has_info = 1;
            break;
        case YC_LC_DYLD_EXPORTS_TRIE: {
            const struct yc_linkedit_data_command *l = (const void *)lc;
            im->exports_off = l->dataoff;
            im->exports_size = l->datasize;
            break;
        }
        case YC_LC_DYLD_CHAINED_FIXUPS: {
            const struct yc_linkedit_data_command *l = (const void *)lc;
            im->chained_off = l->dataoff;
            im->chained_size = l->datasize;
            break;
        }
        case YC_LC_SYMTAB: {
            const uint32_t *w = (const void *)lc;
            im->symoff = w[2];
            im->nsyms = w[3];
            im->stroff = w[4];
            im->strsize = w[5];
            break;
        }
        case YC_LC_MAIN: {
            const struct yc_entry_point_command *e = (const void *)lc;
            im->entryoff = e->entryoff;
            im->has_main = 1;
            break;
        }
        default:
            break;
        }
        lc += c->cmdsize;
    }
    if (!have_text) return "no segment maps the Mach-O header";
    im->slide = (uint64_t)(uintptr_t)im->mh - im->preferred;
    for (uint32_t k = 0; k < im->nsegs; k++) {
        im->seg_addr[k] += im->slide;
        if (im->seg_size[k] == 0 || (im->seg_initprot[k] == 0 && im->seg_addr[k] - im->slide == 0)) continue;  // __PAGEZERO
        if (im->seg_addr[k] < im->start) im->start = im->seg_addr[k];
        if (im->seg_addr[k] + im->seg_size[k] > im->end) im->end = im->seg_addr[k] + im->seg_size[k];
    }
    for (uint32_t k = 0; k < im->ninits; k++) im->init_addr[k] += im->slide;
    if (have_linkedit) im->linkedit = (const uint8_t *)(uintptr_t)(linkedit_vm + im->slide - linkedit_file);
    if (!im->exports_size && im->has_info && im->info.export_size) {
        im->exports_off = im->info.export_off;
        im->exports_size = im->info.export_size;
    }
    if ((im->exports_size || im->chained_size || im->has_info || im->nsyms) && !have_linkedit) return "no __LINKEDIT segment";
    return 0;
}

static int find_loaded(const char *path) {
    for (uint32_t i = 0; i < nimages; i++) {
        if (ydl_strcmp(images[i].path, path) == 0) return (int)i;
        if (images[i].install_name && ydl_strcmp(images[i].install_name, path) == 0) return (int)i;
    }
    return -1;
}

static int read_fully(int fd, void *buf, size_t n, uint64_t off) {
    long r = ydl_syscall(SYS_pread, fd, (long)buf, (long)n, (long)off, 0, 0);
    return r == (long)n ? 0 : -1;
}

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

// Maps the Mach-O at `path` (opened as `fd`) and returns its image index,
// or -1 with the error set.
static int map_image(int fd, const char *path) {
    uint8_t probe[4096];
    long got = ydl_syscall(SYS_pread, fd, (long)probe, sizeof probe, 0, 0, 0);
    if (got < 32) {
        set_error("cannot read ", path, "");
        return -1;
    }
    uint64_t slice = 0;
    uint32_t magic_be = be32(probe);
    if (magic_be == YC_FAT_MAGIC || magic_be == YC_FAT_MAGIC_64) {
        uint32_t n = be32(probe + 4);
        int found = 0;
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *a = probe + 8 + (magic_be == YC_FAT_MAGIC ? 20 : 32) * i;
            if (a + 20 > probe + got) break;
            if (be32(a) == YC_CPU_TYPE_ARM64 && (be32(a + 4) & 0x00FFFFFF) == 0) {
                slice = magic_be == YC_FAT_MAGIC ? be32(a + 8) : ((uint64_t)be32(a + 8) << 32 | be32(a + 12));
                found = 1;
                break;
            }
        }
        if (!found) {
            set_error("no arm64 slice in ", path, "");
            return -1;
        }
        if (read_fully(fd, probe, 32, slice)) {
            set_error("cannot read ", path, "");
            return -1;
        }
    }
    struct yc_mach_header_64 h;
    memcpy(&h, probe, sizeof h);
    if (h.magic != YC_MH_MAGIC_64 || h.cputype != YC_CPU_TYPE_ARM64) {
        set_error("not an arm64 Mach-O image: ", path, "");
        return -1;
    }
    if (h.filetype != YC_MH_DYLIB && h.filetype != YC_MH_BUNDLE) {
        set_error("not a dylib or bundle: ", path, "");
        return -1;
    }
    uint8_t *cmds = ydl_alloc(sizeof h + h.sizeofcmds);
    if (!cmds || read_fully(fd, cmds, sizeof h + h.sizeofcmds, slice)) {
        set_error("cannot read the load commands of ", path, "");
        return -1;
    }
    // The span of the segments (not __PAGEZERO), in unslid addresses.
    uint64_t low = ~(uint64_t)0, high = 0, header_vm = 0;
    const uint8_t *lc = cmds + sizeof h;
    for (uint32_t i = 0; i < h.ncmds; i++) {
        const struct yc_load_command *c = (const void *)lc;
        if (c->cmdsize < 8 || lc + c->cmdsize > cmds + sizeof h + h.sizeofcmds) {
            set_error("malformed load commands in ", path, "");
            return -1;
        }
        if (c->cmd == YC_LC_SEGMENT_64) {
            const struct yc_segment_command_64 *s = (const void *)lc;
            if (s->vmsize && !(s->vmaddr == 0 && s->initprot == 0 && s->filesize == 0)) {
                if (s->vmaddr < low) low = s->vmaddr;
                if (s->vmaddr + s->vmsize > high) high = s->vmaddr + s->vmsize;
                if (s->fileoff == 0 && s->filesize) header_vm = s->vmaddr;
            }
        }
        lc += c->cmdsize;
    }
    if (high <= low) {
        set_error("no segments in ", path, "");
        return -1;
    }
    uint64_t span = (high - low + GUEST_PAGE - 1) & ~(uint64_t)(GUEST_PAGE - 1);
    long base = ydl_syscall(SYS_mmap, 0, (long)span, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base < 0 && base > -4096) {
        set_error("cannot reserve address space for ", path, "");
        return -1;
    }
    lc = cmds + sizeof h;
    for (uint32_t i = 0; i < h.ncmds; i++) {
        const struct yc_load_command *c = (const void *)lc;
        if (c->cmd == YC_LC_SEGMENT_64) {
            const struct yc_segment_command_64 *s = (const void *)lc;
            if (s->vmsize && !(s->vmaddr == 0 && s->initprot == 0 && s->filesize == 0)) {
                uint64_t at = (uint64_t)base + (s->vmaddr - low);
                uint64_t filespan = (s->filesize + GUEST_PAGE - 1) & ~(uint64_t)(GUEST_PAGE - 1);
                uint64_t vmspan = (s->vmsize + GUEST_PAGE - 1) & ~(uint64_t)(GUEST_PAGE - 1);
                if (s->filesize) {
                    // A zero-fill tail in the last file page needs that page
                    // writable for a moment (zero-fill sections follow the
                    // file bytes; the page holds whatever the file has next).
                    int tail = s->vmsize > s->filesize && filespan > s->filesize;
                    int prot = s->initprot | (tail ? YC_VM_PROT_WRITE : 0);
                    long r = ydl_syscall(SYS_mmap, (long)at, (long)filespan, prot, MAP_PRIVATE | MAP_FIXED, fd,
                                         (long)(slice + s->fileoff));
                    if (r < 0 && r > -4096) {
                        set_error("cannot map a segment of ", path, "");
                        return -1;
                    }
                    if (tail) {
                        memset((void *)(uintptr_t)(at + s->filesize), 0, filespan - s->filesize);
                        if (prot != s->initprot) ydl_syscall(SYS_mprotect, (long)at, (long)filespan, s->initprot, 0, 0, 0);
                    }
                }
                if (vmspan > filespan) ydl_syscall(SYS_mprotect, (long)(at + filespan), (long)(vmspan - filespan), s->initprot, 0, 0, 0);
            }
        }
        lc += c->cmdsize;
    }
    if (nimages >= MAX_IMAGES) {
        set_error("too many images loading ", path, "");
        return -1;
    }
    int index = (int)nimages++;
    struct image *im = &images[index];
    memset(im, 0, sizeof *im);
    im->mh = (uint8_t *)(uintptr_t)(base + (header_vm - low));
    size_t n = ydl_strlen(path);
    char *copy = ydl_alloc(n + 1);
    memcpy(copy, path, n + 1);
    im->path = copy;
    const char *why = parse_image(im);
    if (why) {
        nimages--;
        set_error(why, " in ", path);
        return -1;
    }
    if (print_libraries) say(path, "", "");
    if (print_segments) say_address(path, im->mh);
    return index;
}

static int try_open(const char *path) {
    long fd = ydl_syscall(SYS_open, (long)path, O_RDONLY, 0, 0, 0, 0);
    return fd < 0 ? -1 : (int)fd;
}

// Opens `name` as loaded by image `loader` (install-name expansion,
// DYLD_LIBRARY_PATH). Sets *resolved to the path that opened.
static int open_dependency(const char *name, int loader, const char **resolved) {
    if (library_path) {
        const char *leaf = name + dirname_length(name);
        if (*leaf == '/') leaf++;
        const char *d = library_path;
        while (*d) {
            const char *e = d;
            while (*e && *e != ':') e++;
            if (e > d) {
                char *p = join(d, (size_t)(e - d), leaf);
                int fd = p ? try_open(p) : -1;
                if (fd >= 0) {
                    *resolved = p;
                    return fd;
                }
            }
            d = *e ? e + 1 : e;
        }
    }
    if (starts_with(name, "@executable_path/")) {
        char *p = join(executable_path, dirname_length(executable_path), name + 17);
        *resolved = p;
        return p ? try_open(p) : -1;
    }
    if (starts_with(name, "@loader_path/")) {
        const char *lp = images[loader].path;
        char *p = join(lp, dirname_length(lp), name + 13);
        *resolved = p;
        return p ? try_open(p) : -1;
    }
    if (starts_with(name, "@rpath/")) {
        int owners[2] = {loader, main_index};
        for (int o = 0; o < 2; o++) {
            if (owners[o] < 0 || (o == 1 && owners[1] == owners[0])) continue;
            const struct image *im = &images[owners[o]];
            for (uint32_t r = 0; r < im->nrpaths; r++) {
                const char *rp = im->rpath[r];
                char *dir;
                if (starts_with(rp, "@executable_path"))
                    dir = join(executable_path, dirname_length(executable_path), rp + 16 + (rp[16] == '/'));
                else if (starts_with(rp, "@loader_path"))
                    dir = join(im->path, dirname_length(im->path), rp + 12 + (rp[12] == '/'));
                else
                    dir = join(rp, ydl_strlen(rp), "");
                char *p = dir ? join(dir, ydl_strlen(dir), name + 7) : 0;
                int fd = p ? try_open(p) : -1;
                if (fd >= 0) {
                    *resolved = p;
                    return fd;
                }
            }
        }
        return -1;
    }
    *resolved = name;
    return try_open(name);
}

// Loads the dependencies of image `index` (not recursively; the caller
// walks the image list). Returns 0, or -1 with the error set.
static int load_dependencies(int index) {
    for (uint32_t d = 0; d < images[index].ndeps; d++) {
        const char *name = images[index].dep_name[d];
        int found = find_loaded(name);
        if (found < 0) {
            const char *resolved = name;
            int fd = open_dependency(name, index, &resolved);
            if (fd >= 0) {
                found = find_loaded(resolved);
                if (found < 0) found = map_image(fd, resolved);
                ydl_syscall(SYS_close, fd, 0, 0, 0, 0, 0);
                if (found < 0) return -1;
            } else if (images[index].dep_kind[d] & DEP_WEAK) {
                continue;
            } else {
                set_error("Library not loaded: ", name, "");
                char buf[512];
                struct text t = {buf, sizeof buf, 0};
                put(&t, last_error);
                put(&t, "\n  Referenced from: ");
                put(&t, images[index].path);
                struct text e = {last_error, sizeof last_error, 0};
                put(&e, buf);
                return -1;
            }
        }
        images[index].dep[d] = (int16_t)found;
        if (ydl_strcmp(images[found].install_name ? images[found].install_name : "", "/usr/lib/libSystem.B.dylib") == 0)
            libsystem_index = found;
    }
    return 0;
}

// --- symbols ----------------------------------------------------------------------

static int find_export(int index, const char *name, uint64_t *address, int depth) {
    if (index < 0 || depth > 32) return 0;
    struct image *im = &images[index];
    if (im->exports_size) {
        struct ydl_export e;
        int r = ydl_trie_find(image_data(im, im->exports_off), im->exports_size, name, &e);
        if (r == 1) {
            if (e.flags & YC_EXPORT_REEXPORT) {
                if (e.reexport_ordinal == 0 || e.reexport_ordinal > im->ndeps) return 0;
                return find_export(im->dep[e.reexport_ordinal - 1], *e.import_name ? e.import_name : name, address,
                                   depth + 1);
            }
            if ((e.flags & YC_EXPORT_KIND_MASK) == YC_EXPORT_KIND_ABSOLUTE) {
                *address = e.value;
            } else if (e.flags & YC_EXPORT_STUB_AND_RESOLVER) {
                uint64_t (*resolver)(void) = (uint64_t (*)(void))(uintptr_t)((uint64_t)(uintptr_t)im->mh + e.resolver);
                *address = resolver();
            } else {
                *address = (uint64_t)(uintptr_t)im->mh + e.value;
            }
            return 1;
        }
    }
    for (uint32_t d = 0; d < im->ndeps; d++) {
        if ((im->dep_kind[d] & DEP_REEXPORT) && find_export(im->dep[d], name, address, depth + 1)) return 1;
    }
    return 0;
}

static int flat_lookup(const char *name, uint64_t *address) {
    for (uint32_t i = 0; i < nimages; i++)
        if (find_export((int)i, name, address, 0)) return 1;
    return 0;
}

// Resolves one bind of image `index`. Returns 0, or -1 with the error set.
static int resolve(int index, int32_t ordinal, const char *name, int weak, uint64_t *address) {
    struct image *im = &images[index];
    int found = 0, target = -1;
    if (ordinal > 0) {
        if ((uint32_t)ordinal > im->ndeps) {
            set_error("bad library ordinal in ", im->path, "");
            return -1;
        }
        target = im->dep[ordinal - 1];
        found = target >= 0 && find_export(target, name, address, 0);
    } else if (ordinal == YC_BIND_SELF) {
        target = index;
        found = find_export(index, name, address, 0);
    } else if (ordinal == YC_BIND_MAIN_EXECUTABLE) {
        target = main_index;
        found = find_export(main_index, name, address, 0);
    } else if (ordinal == YC_BIND_FLAT_LOOKUP || ordinal == YC_BIND_WEAK_LOOKUP) {
        found = flat_lookup(name, address);
        if (!found && ordinal == YC_BIND_WEAK_LOOKUP) found = find_export(index, name, address, 0);
    } else {
        set_error("unsupported library ordinal in ", im->path, "");
        return -1;
    }
    if (found) return 0;
    if (weak) {
        *address = 0;
        return 0;
    }
    char buf[512];
    struct text t = {buf, sizeof buf, 0};
    put(&t, "Symbol not found: ");
    put(&t, name);
    put(&t, "\n  Referenced from: ");
    put(&t, im->path);
    put(&t, "\n  Expected in:     ");
    put(&t, target >= 0 ? images[target].path : "(flat namespace)");
    set_error(buf, "", "");
    return -1;
}

struct bind_context {
    int index;
};

static int classic_bind(void *context, const struct ydl_classic_bind *b) {
    int index = ((struct bind_context *)context)->index;
    uint64_t address;
    if (resolve(index, b->ordinal, b->name, b->weak, &address)) return -1;
    *b->location = address ? address + (uint64_t)b->addend : 0;
    return 0;
}

static int fix_image(int index) {
    struct image *im = &images[index];
    const char *why = 0;
    // Make every writable-at-runtime segment writable while fixing it up.
    for (uint32_t k = 0; k < im->nsegs; k++)
        if ((im->seg_flags[k] & YC_SG_READ_ONLY) && im->seg_size[k])
            ydl_syscall(SYS_mprotect, (long)im->seg_addr[k], (long)((im->seg_size[k] + GUEST_PAGE - 1) & ~(uint64_t)(GUEST_PAGE - 1)),
                        YC_VM_PROT_READ | YC_VM_PROT_WRITE, 0, 0, 0);
    if (im->chained_size) {
        const uint8_t *blob = image_data(im, im->chained_off);
        int64_t n = ydl_chained_import_count(blob, im->chained_size);
        if (n < 0) {
            set_error("malformed chained fixups in ", im->path, "");
            return -1;
        }
        uint64_t *targets = n ? ydl_alloc((size_t)n * 8) : 0;
        if (n && !targets) {
            set_error("out of memory fixing up ", im->path, "");
            return -1;
        }
        for (uint32_t i = 0; i < (uint32_t)n; i++) {
            struct ydl_import imp;
            if (ydl_chained_import(blob, im->chained_size, i, &imp)) {
                set_error("malformed chained import in ", im->path, "");
                return -1;
            }
            uint64_t address;
            if (resolve(index, imp.ordinal, imp.name, imp.weak, &address)) return -1;
            targets[i] = address ? address + (uint64_t)imp.addend : 0;
        }
        if (ydl_chained_apply(blob, im->chained_size, im->mh, im->preferred, targets, (uint32_t)n, &why) < 0) {
            set_error(why, " in ", im->path);
            return -1;
        }
    } else if (im->has_info) {
        if (im->info.rebase_size &&
            ydl_rebase_apply(image_data(im, im->info.rebase_off), im->info.rebase_size, im->seg_addr, im->seg_size,
                             im->nsegs, im->slide, &why) < 0) {
            set_error(why, " in ", im->path);
            return -1;
        }
        struct bind_context bc = {index};
        if (im->info.bind_size &&
            ydl_bind_walk(image_data(im, im->info.bind_off), im->info.bind_size, im->seg_addr, im->seg_size, im->nsegs,
                          0, classic_bind, &bc, &why) < 0) {
            if (!error_pending) set_error(why, " in ", im->path);
            return -1;
        }
        // Lazy pointers are bound now (no stub binder runs).
        if (im->info.lazy_bind_size &&
            ydl_bind_walk(image_data(im, im->info.lazy_bind_off), im->info.lazy_bind_size, im->seg_addr, im->seg_size,
                          im->nsegs, 1, classic_bind, &bc, &why) < 0) {
            if (!error_pending) set_error(why, " in ", im->path);
            return -1;
        }
    }
    for (uint32_t k = 0; k < im->nsegs; k++)
        if ((im->seg_flags[k] & YC_SG_READ_ONLY) && im->seg_size[k])
            ydl_syscall(SYS_mprotect, (long)im->seg_addr[k], (long)((im->seg_size[k] + GUEST_PAGE - 1) & ~(uint64_t)(GUEST_PAGE - 1)),
                        YC_VM_PROT_READ, 0, 0, 0);
    im->state = ST_FIXED;
    return 0;
}

// --- initializers -----------------------------------------------------------------

typedef void (*initializer_fn)(int, char **, char **, char **, const struct program_vars *);

static void run_initializers(int index) {
    struct image *im = &images[index];
    if (im->state >= ST_INITIALIZING) return;
    im->state = ST_INITIALIZING;
    for (uint32_t d = 0; d < im->ndeps; d++)
        if (!(im->dep_kind[d] & DEP_UPWARD) && im->dep[d] >= 0) run_initializers(im->dep[d]);
    for (uint32_t s = 0; s < im->ninits; s++) {
        if (im->init_offsets[s]) {
            const uint32_t *offsets = (const uint32_t *)(uintptr_t)im->init_addr[s];
            for (uint64_t k = 0; k < im->init_size[s] / 4; k++)
                ((initializer_fn)(uintptr_t)((uint64_t)(uintptr_t)im->mh + offsets[k]))(NXArgc, NXArgv, environ_storage,
                                                                                         apple_strings, &vars);
        } else {
            const uint64_t *pointers = (const uint64_t *)(uintptr_t)im->init_addr[s];
            for (uint64_t k = 0; k < im->init_size[s] / 8; k++)
                ((initializer_fn)(uintptr_t)pointers[k])(NXArgc, NXArgv, environ_storage, apple_strings, &vars);
        }
    }
    im->state = ST_INITIALIZED;
}

// --- the API for libSystem -----------------------------------------------------------

static uint32_t api_image_count(void) { return nimages; }
static const void *api_image_header(uint32_t i) { return i < nimages ? images[i].mh : 0; }
static const char *api_image_name(uint32_t i) { return i < nimages ? images[i].path : 0; }
static intptr_t api_image_slide(uint32_t i) { return i < nimages ? (intptr_t)images[i].slide : 0; }

static int handle_index(void *handle) {
    for (uint32_t i = 0; i < nimages; i++)
        if (handle == (void *)&images[i]) return (int)i;
    return -1;
}

static void *api_dlopen(const char *path, int mode) {
    (void)mode;
    if (!path) return &images[main_index];
    lock();
    error_pending = 0;
    uint32_t first = nimages;
    int index = find_loaded(path);
    if (index < 0) {
        const char *resolved = path;
        int fd = open_dependency(path, main_index, &resolved);
        if (fd < 0) {
            set_error("image not found: ", path, "");
            unlock();
            return 0;
        }
        index = find_loaded(resolved);
        if (index < 0) index = map_image(fd, resolved);
        ydl_syscall(SYS_close, fd, 0, 0, 0, 0, 0);
    }
    for (uint32_t i = first; index >= 0 && i < nimages; i++)
        if (load_dependencies((int)i)) index = -1;
    for (uint32_t i = first; index >= 0 && i < nimages; i++)
        if (fix_image((int)i)) index = -1;
    if (index < 0) {
        nimages = first;  // the mappings stay (no unloading), the records go
        unlock();
        return 0;
    }
    uint32_t last = nimages;
    unlock();
    for (uint32_t i = first; i < last; i++)
        for (uint32_t c = 0; c < ncallbacks; c++) add_callbacks[c](images[i].mh, (intptr_t)images[i].slide);
    run_initializers(index);
    return &images[index];
}

static void *api_dlsym(void *handle, const char *symbol) {
    char name[512];
    size_t n = ydl_strlen(symbol);
    if (n + 2 > sizeof name) return 0;
    name[0] = '_';
    memcpy(name + 1, symbol, n + 1);
    uint64_t address = 0;
    int found;
    intptr_t h = (intptr_t)handle;
    if (h == -2 || h == -1 || h == -3) found = flat_lookup(name, &address);   // RTLD_DEFAULT, RTLD_NEXT, RTLD_SELF
    else if (h == -5) found = find_export(main_index, name, &address, 0);   // RTLD_MAIN_ONLY
    else {
        int index = handle_index(handle);
        if (index < 0) {
            set_error("invalid handle passed to dlsym", "", "");
            return 0;
        }
        found = find_export(index, name, &address, 0);
    }
    if (!found) {
        set_error("symbol not found: ", symbol, "");
        return 0;
    }
    return (void *)(uintptr_t)address;
}

static int api_dlclose(void *handle) { return handle_index(handle) < 0 ? -1 : 0; }

static const char *api_dlerror(void) {
    if (!error_pending) return 0;
    error_pending = 0;
    return last_error;
}

static int api_dladdr(const void *address, struct yc_dl_info *info) {
    uint64_t a = (uint64_t)(uintptr_t)address;
    for (uint32_t i = 0; i < nimages; i++) {
        struct image *im = &images[i];
        if (a < im->start || a >= im->end) continue;
        info->dli_fname = im->path;
        info->dli_fbase = im->mh;
        info->dli_sname = 0;
        info->dli_saddr = 0;
        if (im->nsyms && im->linkedit) {
            const uint8_t *sym = image_data(im, im->symoff);
            const char *strings = (const char *)image_data(im, im->stroff);
            uint64_t best = 0;
            for (uint32_t s = 0; s < im->nsyms; s++, sym += 16) {
                uint8_t type = sym[4];
                if ((type & 0xE0) || (type & 0x0E) != 0x0E) continue;  // not a stab; defined in a section
                uint64_t value;
                uint32_t strx;
                memcpy(&value, sym + 8, 8);
                memcpy(&strx, sym, 4);
                value += im->slide;
                if (value <= a && value >= best && strx < im->strsize) {
                    best = value;
                    info->dli_sname = strings + strx + (strings[strx] == '_');
                    info->dli_saddr = (void *)(uintptr_t)value;
                }
            }
        }
        return 1;
    }
    return 0;
}

static void api_add_image_callback(void (*callback)(const void *, intptr_t)) {
    if (ncallbacks < MAX_CALLBACKS) add_callbacks[ncallbacks++] = callback;
    for (uint32_t i = 0; i < nimages; i++) callback(images[i].mh, (intptr_t)images[i].slide);
}

// --- start -------------------------------------------------------------------------

void ydl_main(uint64_t *sp) {
    uint8_t *main_mh = (uint8_t *)(uintptr_t)sp[0];
    NXArgc = (int)sp[1];
    NXArgv = (char **)&sp[2];
    environ_storage = NXArgv + NXArgc + 1;
    char **e = environ_storage;
    while (*e) e++;
    apple_strings = e + 1;
    const char *exec = getenv_in(apple_strings, "executable_path");
    executable_path = exec ? exec : NXArgc > 0 && NXArgv[0] ? NXArgv[0] : "";
    progname = NXArgc > 0 && NXArgv[0] ? NXArgv[0] + dirname_length(NXArgv[0]) : "";
    if (*progname == '/') progname++;
    const char *p = getenv_in(environ_storage, "DYLD_PRINT_LIBRARIES");
    print_libraries = p && *p && *p != '0';
    p = getenv_in(environ_storage, "DYLD_PRINT_SEGMENTS");
    print_segments = p && *p && *p != '0';
    library_path = getenv_in(environ_storage, "DYLD_LIBRARY_PATH");
    if (library_path && !*library_path) library_path = 0;

    struct image *m = &images[0];
    nimages = 1;
    main_index = 0;
    m->mh = main_mh;
    m->path = executable_path;
    const struct yc_mach_header_64 *h = (const void *)main_mh;
    if (h->magic != YC_MH_MAGIC_64 || h->filetype != YC_MH_EXECUTE) fatal("the main executable is not an MH_EXECUTE image", "", "");
    const char *why = parse_image(m);
    if (why) fatal(why, " in ", executable_path);
    if (!m->has_main) fatal("no LC_MAIN in ", executable_path, " (LC_UNIXTHREAD executables are not supported)");
    if (print_libraries) say(executable_path, "", "");

    for (uint32_t i = 0; i < nimages; i++)
        if (load_dependencies((int)i)) fatal(last_error, "", "");
    for (uint32_t i = 0; i < nimages; i++)
        if (fix_image((int)i)) fatal(last_error, "", "");

    vars.mh = main_mh;
    vars.NXArgcPtr = &NXArgc;
    vars.NXArgvPtr = &NXArgv;
    vars.environPtr = &environ_storage;
    vars.prognamePtr = &progname;
    api.version = YC_DYLD_API_VERSION;
    api.image_count = api_image_count;
    api.image_header = api_image_header;
    api.image_name = api_image_name;
    api.image_slide = api_image_slide;
    api.dlopen = api_dlopen;
    api.dlsym = api_dlsym;
    api.dlclose = api_dlclose;
    api.dlerror = api_dlerror;
    api.dladdr = api_dladdr;
    api.add_image_callback = api_add_image_callback;
    api.executable_path = executable_path;

    uint64_t exit_address = 0;
    if (libsystem_index >= 0) {
        uint64_t slot;
        if (find_export(libsystem_index, "_ycode_dyld_api", &slot, 0)) *(struct yc_dyld_api **)(uintptr_t)slot = &api;
        find_export(libsystem_index, "_exit", &exit_address, 0);
        run_initializers(libsystem_index);
    }
    run_initializers(main_index);

    typedef int (*main_fn)(int, char **, char **, char **);
    int status = ((main_fn)(uintptr_t)((uint64_t)(uintptr_t)main_mh + m->entryoff))(NXArgc, NXArgv, environ_storage,
                                                                                   apple_strings);
    if (exit_address) ((void (*)(int))(uintptr_t)exit_address)(status);
    ydl_syscall(SYS_exit, status, 0, 0, 0, 0, 0);
    for (;;) {
    }
}
