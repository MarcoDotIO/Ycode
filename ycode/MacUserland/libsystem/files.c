// files.c - removefile(3), the standard directory search paths
// (sysdir(3)) and UUIDs (uuid(3)) for Ycode's libSystem
// (specs/macos/libsystem.md §12). Clean-room Ycode code from the public
// headers <removefile.h>, <sysdir.h> and <uuid/uuid.h> and their manual
// pages (constants, callback protocol and the documented directory
// layout of a Mac).
#include "ycl.h"

int rmdir(const char *);
int lstat(const char *, void *);
int strncasecmp(const char *, const char *, size_t);
void arc4random_buf(void *, size_t);
size_t strlcat(char *, const char *, size_t);
struct ycl_dirent {
    uint64_t d_ino, d_seekoff;
    uint16_t d_reclen, d_namlen;
    uint8_t d_type;
    char d_name[1024];
};
void *opendir(const char *);
struct ycl_dirent *readdir(void *);
int closedir(void *);

YCL_EXPORT int strncasecmp_l(const char *a, const char *b, size_t n, void *locale) {
    (void)locale;
    return strncasecmp(a, b, n);
}

// --- removefile ---

typedef int (*removefile_callback)(void *state, const char *path, void *context);

struct removefile_state {
    removefile_callback confirm, error, status;
    void *confirm_context, *error_context, *status_context;
    int error_number;
    int cancelled;
    void *ftsent;
};

enum {
    RF_RECURSIVE = 1 << 0, RF_KEEP_PARENT = 1 << 1,
    RF_CONFIRM_CALLBACK = 1, RF_CONFIRM_CONTEXT, RF_ERROR_CALLBACK, RF_ERROR_CONTEXT, RF_ERRNO, RF_STATUS_CALLBACK,
    RF_STATUS_CONTEXT, RF_FTSENT,
    RF_PROCEED = 0, RF_SKIP = 1, RF_STOP = 2,
    PATH_MAX = 1024, IFMT = 0170000, IFDIR = 0040000,
};

YCL_EXPORT struct removefile_state *removefile_state_alloc(void) { return calloc(1, sizeof(struct removefile_state)); }
YCL_EXPORT int removefile_state_free(struct removefile_state *s) {
    free(s);
    return 0;
}

YCL_EXPORT int removefile_state_set(struct removefile_state *s, uint32_t key, const void *value) {
    switch (key) {
    case RF_CONFIRM_CALLBACK: s->confirm = (removefile_callback)value; break;
    case RF_CONFIRM_CONTEXT: s->confirm_context = (void *)value; break;
    case RF_ERROR_CALLBACK: s->error = (removefile_callback)value; break;
    case RF_ERROR_CONTEXT: s->error_context = (void *)value; break;
    case RF_STATUS_CALLBACK: s->status = (removefile_callback)value; break;
    case RF_STATUS_CONTEXT: s->status_context = (void *)value; break;
    default: ycl_errno = YCL_EINVAL; return -1;
    }
    return 0;
}

YCL_EXPORT int removefile_state_get(struct removefile_state *s, uint32_t key, void *dst) {
    switch (key) {
    case RF_CONFIRM_CALLBACK: *(removefile_callback *)dst = s->confirm; break;
    case RF_CONFIRM_CONTEXT: *(void **)dst = s->confirm_context; break;
    case RF_ERROR_CALLBACK: *(removefile_callback *)dst = s->error; break;
    case RF_ERROR_CONTEXT: *(void **)dst = s->error_context; break;
    case RF_ERRNO: *(int *)dst = s->error_number; break;
    case RF_STATUS_CALLBACK: *(removefile_callback *)dst = s->status; break;
    case RF_STATUS_CONTEXT: *(void **)dst = s->status_context; break;
    case RF_FTSENT: *(void **)dst = s->ftsent; break;
    default: ycl_errno = YCL_EINVAL; return -1;
    }
    return 0;
}

YCL_EXPORT int removefile_cancel(struct removefile_state *s) {
    if (!s) {
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    s->cancelled = 1;
    return 0;
}

// Returns 0 to go on, -1 to stop (errno set). `top` is the path the caller
// named (kept with RF_KEEP_PARENT).
static int remove_tree(struct removefile_state *s, char *path, uint32_t flags, int top) {
    if (s->cancelled) {
        ycl_errno = YCL_ECANCELED;
        return -1;
    }
    if (s->confirm) {
        int answer = s->confirm(s, path, s->confirm_context);
        if (answer == RF_SKIP) return 0;
        if (answer == RF_STOP) {
            ycl_errno = YCL_ECANCELED;
            return -1;
        }
    }
    uint8_t st[144];
    if (lstat(path, st) != 0) goto failed;
    int is_dir = (*(uint16_t *)(st + 4) & IFMT) == IFDIR;
    if (is_dir) {
        if (!(flags & RF_RECURSIVE)) {
            if (top && (flags & RF_KEEP_PARENT)) return 0;
            if (rmdir(path) != 0) goto failed;
            goto removed;
        }
        void *d = opendir(path);
        if (!d) goto failed;
        size_t len = strlen(path);
        struct ycl_dirent *e;
        int result = 0;
        while ((e = readdir(d))) {
            if (e->d_name[0] == '.' && (!e->d_name[1] || (e->d_name[1] == '.' && !e->d_name[2]))) continue;
            if (len + 1 + e->d_namlen >= PATH_MAX) {
                ycl_errno = YCL_ENAMETOOLONG;
                result = -1;
                break;
            }
            path[len] = '/';
            memcpy(path + len + 1, e->d_name, (size_t)e->d_namlen + 1);
            result = remove_tree(s, path, flags, 0);
            path[len] = 0;
            if (result) break;
        }
        closedir(d);
        if (result) return -1;
        if (top && (flags & RF_KEEP_PARENT)) return 0;
        if (rmdir(path) != 0) goto failed;
    } else {
        if (unlink(path) != 0) goto failed;
    }
removed:
    if (s->status) s->status(s, path, s->status_context);
    return 0;
failed:
    s->error_number = ycl_errno;
    if (s->error) {
        int saved = ycl_errno;
        int answer = s->error(s, path, s->error_context);
        ycl_errno = saved;
        if (answer == RF_PROCEED || answer == RF_SKIP) return 0;
    }
    return -1;
}

YCL_EXPORT int removefile(const char *path, struct removefile_state *state, uint32_t flags) {
    struct removefile_state local = {0, 0, 0, 0, 0, 0, 0, 0, 0};
    struct removefile_state *s = state ? state : &local;
    char buf[PATH_MAX];
    if (strlen(path) >= sizeof buf) {
        ycl_errno = YCL_ENAMETOOLONG;
        return -1;
    }
    strlcpy(buf, path, sizeof buf);
    s->error_number = 0;
    return remove_tree(s, buf, flags, 1);
}

// --- sysdir: user-domain paths begin with "~" (the caller expands it) ---

enum { DOM_USER = 1, DOM_LOCAL = 2, DOM_NETWORK = 4, DOM_SYSTEM = 8 };

static const struct {
    unsigned char dir, domain;
    const char *path;
} search_paths[] = {
    {1, DOM_USER, "~/Applications"}, {1, DOM_LOCAL, "/Applications"}, {1, DOM_NETWORK, "/Network/Applications"},
    {1, DOM_SYSTEM, "/System/Applications"},
    {2, DOM_USER, "~/Applications/Demos"}, {2, DOM_LOCAL, "/Applications/Demos"},
    {3, DOM_LOCAL, "/Developer/Applications"},
    {4, DOM_USER, "~/Applications/Utilities"}, {4, DOM_LOCAL, "/Applications/Utilities"},
    {4, DOM_SYSTEM, "/System/Applications/Utilities"},
    {5, DOM_USER, "~/Library"}, {5, DOM_LOCAL, "/Library"}, {5, DOM_NETWORK, "/Network/Library"},
    {5, DOM_SYSTEM, "/System/Library"},
    {6, DOM_LOCAL, "/Developer"},
    {7, DOM_LOCAL, "/Users"}, {7, DOM_NETWORK, "/Network/Users"},
    {8, DOM_USER, "~/Library/Documentation"}, {8, DOM_LOCAL, "/Library/Documentation"},
    {8, DOM_SYSTEM, "/System/Library/Documentation"},
    {9, DOM_USER, "~/Documents"},
    {10, DOM_SYSTEM, "/System/Library/CoreServices"},
    {11, DOM_USER, "~/Library/Autosave Information"},
    {12, DOM_USER, "~/Desktop"},
    {13, DOM_USER, "~/Library/Caches"}, {13, DOM_LOCAL, "/Library/Caches"}, {13, DOM_SYSTEM, "/System/Library/Caches"},
    {14, DOM_USER, "~/Library/Application Support"}, {14, DOM_LOCAL, "/Library/Application Support"},
    {14, DOM_NETWORK, "/Network/Library/Application Support"},
    {15, DOM_USER, "~/Downloads"},
    {16, DOM_USER, "~/Library/Input Methods"}, {16, DOM_LOCAL, "/Library/Input Methods"},
    {16, DOM_SYSTEM, "/System/Library/Input Methods"},
    {17, DOM_USER, "~/Movies"},
    {18, DOM_USER, "~/Music"},
    {19, DOM_USER, "~/Pictures"},
    {20, DOM_LOCAL, "/Library/Printers/PPDs"}, {20, DOM_SYSTEM, "/System/Library/Printers/PPDs"},
    {21, DOM_USER, "~/Public"},
    {22, DOM_USER, "~/Library/PreferencePanes"}, {22, DOM_LOCAL, "/Library/PreferencePanes"},
    {22, DOM_SYSTEM, "/System/Library/PreferencePanes"},
};
enum { SEARCH_PATHS = sizeof search_paths / sizeof search_paths[0] };

// The directory sets of the "all" values.
static int matches(unsigned dir, unsigned entry_dir) {
    if (dir == entry_dir) return 1;
    if (dir == 100) return entry_dir == 1 || entry_dir == 2 || entry_dir == 3 || entry_dir == 4;  // all applications
    if (dir == 101) return entry_dir == 5 || entry_dir == 6;                                    // all libraries
    return 0;
}

// The state: directory (bits 0-7), domain mask (8-11), next table index + 1 (12-).
YCL_EXPORT unsigned sysdir_start_search_path_enumeration(unsigned dir, unsigned long mask) {
    return (dir & 0xFF) | (unsigned)((mask & 0xF) << 8) | (1u << 12);
}

YCL_EXPORT unsigned sysdir_get_next_search_path_enumeration(unsigned state, char *path) {
    unsigned dir = state & 0xFF, mask = (state >> 8) & 0xF, index = (state >> 12);
    if (!index) return 0;
    // Domains are reported in order: user, local, network, system.
    for (unsigned domain = DOM_USER; domain <= DOM_SYSTEM; domain <<= 1) {
        if (!(mask & domain)) continue;
        for (unsigned i = 0; i < SEARCH_PATHS; i++) {
            unsigned position = (unsigned)(__builtin_ctz(domain)) * SEARCH_PATHS + i + 1;
            if (position < index) continue;
            if (search_paths[i].domain != domain || !matches(dir, search_paths[i].dir)) continue;
            strlcpy(path, search_paths[i].path, PATH_MAX);
            return (state & 0xFFF) | ((position + 1) << 12);
        }
    }
    return 0;
}

// --- UUIDs ---

YCL_EXPORT void uuid_clear(unsigned char uu[16]) { memset(uu, 0, 16); }
YCL_EXPORT void uuid_copy(unsigned char dst[16], const unsigned char src[16]) { memcpy(dst, src, 16); }
YCL_EXPORT int uuid_compare(const unsigned char a[16], const unsigned char b[16]) { return memcmp(a, b, 16); }
YCL_EXPORT int uuid_is_null(const unsigned char uu[16]) {
    for (int i = 0; i < 16; i++)
        if (uu[i]) return 0;
    return 1;
}

// Random (version 4) UUIDs; the time-based form is random too.
YCL_EXPORT void uuid_generate_random(unsigned char out[16]) {
    arc4random_buf(out, 16);
    out[6] = (unsigned char)((out[6] & 0x0F) | 0x40);
    out[8] = (unsigned char)((out[8] & 0x3F) | 0x80);
}
YCL_EXPORT void uuid_generate(unsigned char out[16]) { uuid_generate_random(out); }
YCL_EXPORT void uuid_generate_time(unsigned char out[16]) { uuid_generate_random(out); }

static void unparse(const unsigned char uu[16], char *out, const char *digits) {
    int n = 0;
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) out[n++] = '-';
        out[n++] = digits[uu[i] >> 4];
        out[n++] = digits[uu[i] & 15];
    }
    out[n] = 0;
}
YCL_EXPORT void uuid_unparse_upper(const unsigned char uu[16], char *out) { unparse(uu, out, "0123456789ABCDEF"); }
YCL_EXPORT void uuid_unparse_lower(const unsigned char uu[16], char *out) { unparse(uu, out, "0123456789abcdef"); }
YCL_EXPORT void uuid_unparse(const unsigned char uu[16], char *out) { uuid_unparse_upper(uu, out); }

YCL_EXPORT int uuid_parse(const char *in, unsigned char uu[16]) {
    int n = 0;
    for (int i = 0; i < 36; i++) {
        char c = in[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') return -1;
            continue;
        }
        int v = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
        if (v < 0) return -1;
        if (n & 1) uu[n / 2] = (unsigned char)(uu[n / 2] | v);
        else uu[n / 2] = (unsigned char)(v << 4);
        n++;
    }
    return in[36] == 0 ? 0 : -1;
}
