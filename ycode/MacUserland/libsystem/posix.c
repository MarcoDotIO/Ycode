// posix.c - paths, sysctl, user and host identity, temporary files, file
// copies and the other POSIX and Darwin libc functions the Swift runtime,
// libc++ and Foundation need (specs/macos/libsystem.md §12). Clean-room
// Ycode code from POSIX and Apple's public man pages; struct layouts and
// constants are the public SDK headers' (interoperability facts).
#include "ycl.h"

int fcntl(int, int, ...);
int fstat(int, void *);
int stat(const char *, void *);
int lstat(const char *, void *);
ssize_t readlink(const char *, char *, size_t);
int statfs(const char *, void *);
int fstatfs(int, void *);
int mkdir(const char *, mode_t);
pid_t wait4(pid_t, int *, int, void *);
uint32_t getuid(void);
uint32_t geteuid(void);
char *getenv(const char *);
uint32_t arc4random_uniform(uint32_t);
size_t strlcat(char *, const char *, size_t);

enum { F_GETPATH = 50, PATH_MAX = 1024, CTL_MAXNAME = 12 };

// --- paths ---

YCL_EXPORT char *getcwd(char *buf, size_t size) {
    char path[PATH_MAX];
    int fd = open(".", YCL_O_RDONLY | YCL_O_CLOEXEC);
    if (fd < 0) return 0;
    int r = fcntl(fd, F_GETPATH, path);
    close(fd);
    if (r < 0) return 0;
    size_t need = strlen(path) + 1;
    if (!buf) {
        buf = malloc(size > need ? size : need);
        if (!buf) {
            ycl_errno = YCL_ENOMEM;
            return 0;
        }
    } else if (size == 0) {
        ycl_errno = YCL_EINVAL;
        return 0;
    } else if (size < need) {
        ycl_errno = YCL_ERANGE;
        return 0;
    }
    memcpy(buf, path, need);
    return buf;
}

YCL_EXPORT char *getwd(char *buf) { return getcwd(buf, PATH_MAX); }

// realpath(3): resolves ".", ".." and symbolic links component by
// component (at most 32 links); every component must exist.
static char *resolve(const char *path, char *out) {
    char work[PATH_MAX * 2];
    char result[PATH_MAX];
    int links = 0;
    if (!path || !*path) {
        ycl_errno = YCL_ENOENT;
        return 0;
    }
    if (path[0] == '/') {
        strlcpy(work, path, sizeof work);
        result[0] = 0;
    } else {
        if (!getcwd(result, sizeof result)) return 0;
        if (!strcmp(result, "/")) result[0] = 0;
        strlcpy(work, path, sizeof work);
    }
    char *rest = work;
    for (;;) {
        while (*rest == '/') rest++;
        if (!*rest) break;
        char *slash = strchr(rest, '/');
        size_t len = slash ? (size_t)(slash - rest) : strlen(rest);
        char name[256];
        if (len >= sizeof name) {
            ycl_errno = YCL_ENAMETOOLONG;
            return 0;
        }
        memcpy(name, rest, len);
        name[len] = 0;
        rest += len;
        if (!strcmp(name, ".")) continue;
        if (!strcmp(name, "..")) {
            char *last = strrchr(result, '/');
            if (last) *last = 0;
            continue;
        }
        size_t base = strlen(result);
        if (base + 1 + len >= sizeof result) {
            ycl_errno = YCL_ENAMETOOLONG;
            return 0;
        }
        result[base] = '/';
        memcpy(result + base + 1, name, len + 1);
        char target[PATH_MAX];
        ssize_t n = readlink(result, target, sizeof target - 1);
        if (n < 0) {
            if (ycl_errno == YCL_EINVAL) continue;  // exists and is not a link
            return 0;
        }
        if (++links > 32) {
            ycl_errno = 62;  // ELOOP
            return 0;
        }
        target[n] = 0;
        char joined[PATH_MAX * 2];
        strlcpy(joined, target, sizeof joined);
        strlcat(joined, rest, sizeof joined);
        strlcpy(work, joined, sizeof work);
        rest = work;
        if (target[0] == '/') result[0] = 0;
        else result[base] = 0;
    }
    if (!result[0]) strlcpy(result, "/", sizeof result);
    char *dst = out ? out : malloc(strlen(result) + 1);
    if (!dst) {
        ycl_errno = YCL_ENOMEM;
        return 0;
    }
    memcpy(dst, result, strlen(result) + 1);
    return dst;
}

YCL_EXPORT char *realpath(const char *path, char *out) { return resolve(path, out); }
char *ycl_realpath_extsn(const char *path, char *out) __asm__("_realpath$DARWIN_EXTSN");
YCL_EXPORT char *ycl_realpath_extsn(const char *path, char *out) { return resolve(path, out); }

// --- sysctl ---

int __sysctl(int *, unsigned, void *, size_t *, void *, size_t);

YCL_EXPORT int sysctl(int *name, unsigned namelen, void *old, size_t *oldlenp, void *new, size_t newlen) {
    return __sysctl(name, namelen, old, oldlenp, new, newlen);
}

YCL_EXPORT int sysctlnametomib(const char *name, int *mib, size_t *sizep) {
    int query[2] = {0, 3};  // the name-to-OID request
    size_t bytes = *sizep * sizeof(int);
    if (__sysctl(query, 2, mib, &bytes, (void *)name, strlen(name)) != 0) return -1;
    *sizep = bytes / sizeof(int);
    return 0;
}

YCL_EXPORT int sysctlbyname(const char *name, void *old, size_t *oldlenp, void *new, size_t newlen) {
    int mib[CTL_MAXNAME];
    size_t n = CTL_MAXNAME;
    if (sysctlnametomib(name, mib, &n) != 0) return -1;
    return __sysctl(mib, (unsigned)n, old, oldlenp, new, newlen);
}

static void sysctl_string(const char *name, char *out, size_t size, const char *fallback) {
    size_t len = size;
    if (sysctlbyname(name, out, &len, 0, 0) != 0 || len == 0) strlcpy(out, fallback, size);
    else out[len < size ? len : size - 1] = 0;
}

YCL_EXPORT int gethostname(char *name, size_t size) {
    char buf[256];
    sysctl_string("kern.hostname", buf, sizeof buf, "localhost");
    if (strlen(buf) >= size) {
        ycl_errno = YCL_ENAMETOOLONG;
        return -1;
    }
    strlcpy(name, buf, size);
    return 0;
}

struct ycl_utsname {
    char sysname[256], nodename[256], release[256], version[256], machine[256];
};

YCL_EXPORT int uname(struct ycl_utsname *u) {
    sysctl_string("kern.ostype", u->sysname, sizeof u->sysname, "Darwin");
    sysctl_string("kern.hostname", u->nodename, sizeof u->nodename, "localhost");
    sysctl_string("kern.osrelease", u->release, sizeof u->release, "25.0.0");
    sysctl_string("kern.version", u->version, sizeof u->version, "Darwin Kernel Version (Ycode)");
    sysctl_string("hw.machine", u->machine, sizeof u->machine, "arm64");
    return 0;
}

// --- memory ---

YCL_EXPORT int memset_s(void *s, size_t smax, int c, size_t n) {
    if (!s) return YCL_EINVAL;
    size_t count = n < smax ? n : smax;
    volatile unsigned char *p = s;
    for (size_t i = 0; i < count; i++) p[i] = (unsigned char)c;
    return n > smax ? YCL_EOVERFLOW : 0;
}

// --- users: Ycode's macOS processes run as one user, described by the
//     environment (USER, HOME, SHELL); uid and gid come from the kernel ---

struct ycl_passwd {
    char *pw_name, *pw_passwd;
    uint32_t pw_uid, pw_gid;
    long pw_change;
    char *pw_class, *pw_gecos, *pw_dir, *pw_shell;
    long pw_expire;
};

static int fill_passwd(uint32_t uid, const char *want_name, struct ycl_passwd *pw, char *buf, size_t size,
                       struct ycl_passwd **result) {
    *result = 0;
    const char *user = uid == 0 ? "root" : getenv("USER");
    if (!user || !*user) user = "user";
    const char *home = uid == 0 ? "/var/root" : getenv("HOME");
    if (!home || !*home) home = "/tmp";
    const char *shell = getenv("SHELL");
    if (!shell || !*shell) shell = "/bin/sh";
    if (want_name && strcmp(want_name, user) != 0) return 0;  // no such user
    size_t need = strlen(user) + strlen(home) + strlen(shell) + 8;
    if (size < need) return YCL_ERANGE;
    char *at = buf;
#define PLACE(field, value)                 \
    do {                                    \
        size_t l = strlen(value) + 1;       \
        memcpy(at, value, l);               \
        pw->field = at;                     \
        at += l;                            \
    } while (0)
    PLACE(pw_name, user);
    PLACE(pw_dir, home);
    PLACE(pw_shell, shell);
    PLACE(pw_passwd, "*");
    pw->pw_class = at - 1;  // ""
    pw->pw_gecos = pw->pw_name;
#undef PLACE
    pw->pw_uid = uid;
    pw->pw_gid = uid == 0 ? 0 : 20;  // staff
    pw->pw_change = pw->pw_expire = 0;
    *result = pw;
    return 0;
}

YCL_EXPORT int getpwuid_r(uint32_t uid, struct ycl_passwd *pw, char *buf, size_t size, struct ycl_passwd **result) {
    return fill_passwd(uid, 0, pw, buf, size, result);
}

YCL_EXPORT int getpwnam_r(const char *name, struct ycl_passwd *pw, char *buf, size_t size,
                          struct ycl_passwd **result) {
    if (!strcmp(name, "root")) return fill_passwd(0, 0, pw, buf, size, result);
    return fill_passwd(getuid(), name, pw, buf, size, result);
}

static struct ycl_passwd shared_pw;
static char shared_pw_buf[2048];

YCL_EXPORT struct ycl_passwd *getpwuid(uint32_t uid) {
    struct ycl_passwd *r;
    return getpwuid_r(uid, &shared_pw, shared_pw_buf, sizeof shared_pw_buf, &r) == 0 ? r : 0;
}

YCL_EXPORT struct ycl_passwd *getpwnam(const char *name) {
    struct ycl_passwd *r;
    return getpwnam_r(name, &shared_pw, shared_pw_buf, sizeof shared_pw_buf, &r) == 0 ? r : 0;
}

YCL_EXPORT char *getlogin(void) {
    struct ycl_passwd *pw = getpwuid(getuid());
    return pw ? pw->pw_name : 0;
}

YCL_EXPORT int getlogin_r(char *buf, size_t size) {
    char *name = getlogin();
    if (!name) return YCL_ENOENT;
    if (strlen(name) >= size) return YCL_ERANGE;
    strlcpy(buf, name, size);
    return 0;
}

// --- temporary files ---

static int fill_template(char *path, size_t suffix) {
    static const char chars[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    size_t len = strlen(path);
    if (len < suffix + 6) {
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    char *x = path + len - suffix;
    size_t count = 0;
    while (x > path && x[-1] == 'X') x--, count++;
    if (count < 1) {
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    for (size_t i = 0; i < count; i++) x[i] = chars[arc4random_uniform(sizeof chars - 1)];
    return 0;
}

YCL_EXPORT int mkstemps(char *path, int suffix) {
    char saved[PATH_MAX];
    strlcpy(saved, path, sizeof saved);
    for (int attempt = 0; attempt < 100; attempt++) {
        strlcpy(path, saved, PATH_MAX);
        if (fill_template(path, (size_t)suffix)) return -1;
        int fd = open(path, YCL_O_RDWR | YCL_O_CREAT | YCL_O_EXCL | YCL_O_CLOEXEC, 0600);
        if (fd >= 0 || ycl_errno != YCL_EEXIST) return fd;
    }
    return -1;
}

YCL_EXPORT int mkstemp(char *path) { return mkstemps(path, 0); }

YCL_EXPORT char *mkdtemp(char *path) {
    char saved[PATH_MAX];
    strlcpy(saved, path, sizeof saved);
    for (int attempt = 0; attempt < 100; attempt++) {
        strlcpy(path, saved, PATH_MAX);
        if (fill_template(path, 0)) return 0;
        if (mkdir(path, 0700) == 0) return path;
        if (ycl_errno != YCL_EEXIST) return 0;
    }
    return 0;
}

YCL_EXPORT char *mktemp(char *path) {
    if (fill_template(path, 0)) return 0;
    return path;
}

// --- processes ---

YCL_EXPORT pid_t waitpid(pid_t pid, int *status, int options) { return wait4(pid, status, options, 0); }
YCL_EXPORT pid_t wait(int *status) { return wait4(-1, status, 0, 0); }

// --- file systems ---

struct ycl_statfs {
    uint32_t f_bsize;
    int32_t f_iosize;
    uint64_t f_blocks, f_bfree, f_bavail, f_files, f_ffree;
    int32_t f_fsid[2];
    uint32_t f_owner, f_type, f_flags, f_fssubtype;
    char f_fstypename[16];
    char f_mntonname[1024];
    char f_mntfromname[1024];
    uint32_t f_flags_ext;
    uint32_t f_reserved[7];
};

struct ycl_statvfs {
    unsigned long f_bsize, f_frsize;
    uint32_t f_blocks, f_bfree, f_bavail, f_files, f_ffree, f_favail;
    unsigned long f_fsid, f_flag, f_namemax;
};

static void to_statvfs(const struct ycl_statfs *s, struct ycl_statvfs *v) {
    v->f_bsize = (unsigned long)s->f_iosize;
    v->f_frsize = s->f_bsize;
    // fsblkcnt_t and fsfilcnt_t are 32-bit (unsigned int) in the public header.
    v->f_blocks = (uint32_t)s->f_blocks;
    v->f_bfree = (uint32_t)s->f_bfree;
    v->f_bavail = (uint32_t)s->f_bavail;
    v->f_files = (uint32_t)s->f_files;
    v->f_ffree = (uint32_t)s->f_ffree;
    v->f_favail = (uint32_t)s->f_ffree;
    v->f_fsid = (unsigned long)(uint32_t)s->f_fsid[0];
    v->f_flag = (s->f_flags & 1 /* MNT_RDONLY */ ? 1 : 0) | (s->f_flags & 8 /* MNT_NOSUID */ ? 2 : 0);
    v->f_namemax = 255;
}

YCL_EXPORT int statvfs(const char *path, struct ycl_statvfs *v) {
    struct ycl_statfs s;
    if (statfs(path, &s) != 0) return -1;
    to_statvfs(&s, v);
    return 0;
}

YCL_EXPORT int fstatvfs(int fd, struct ycl_statvfs *v) {
    struct ycl_statfs s;
    if (fstatfs(fd, &s) != 0) return -1;
    to_statvfs(&s, v);
    return 0;
}

// --- copyfile(3): data and permission bits; ACLs and extended attributes
//     are not kept (Ycode's file system has none) ---

enum { COPYFILE_STAT = 1 << 1, COPYFILE_DATA = 1 << 3 };

struct ycl_copyfile_state {
    int unused;
};

YCL_EXPORT struct ycl_copyfile_state *copyfile_state_alloc(void) { return calloc(1, sizeof(struct ycl_copyfile_state)); }
YCL_EXPORT int copyfile_state_free(struct ycl_copyfile_state *s) {
    free(s);
    return 0;
}
YCL_EXPORT int copyfile_state_get(struct ycl_copyfile_state *s, uint32_t flag, void *result) {
    (void)s;
    (void)flag;
    (void)result;
    ycl_errno = YCL_EINVAL;
    return -1;
}
YCL_EXPORT int copyfile_state_set(struct ycl_copyfile_state *s, uint32_t flag, const void *value) {
    (void)s;
    (void)flag;
    (void)value;
    return 0;
}

int fchmod(int, mode_t);

YCL_EXPORT int fcopyfile(int from, int to, struct ycl_copyfile_state *state, uint32_t flags) {
    (void)state;
    if (flags & COPYFILE_DATA) {
        char buf[65536];
        for (;;) {
            ssize_t n = read(from, buf, sizeof buf);
            if (n < 0) {
                if (ycl_errno == YCL_EINTR) continue;
                return -1;
            }
            if (n == 0) break;
            for (ssize_t done = 0; done < n;) {
                ssize_t w = write(to, buf + done, (size_t)(n - done));
                if (w < 0) {
                    if (ycl_errno == YCL_EINTR) continue;
                    return -1;
                }
                done += w;
            }
        }
    }
    if (flags & COPYFILE_STAT) {
        uint8_t st[144];
        if (fstat(from, st) == 0) {
            mode_t mode = *(uint16_t *)(st + 4);  // st_mode (struct stat, 64-bit inode layout)
            fchmod(to, mode & 07777);
        }
    }
    return 0;
}

YCL_EXPORT int copyfile(const char *from, const char *to, struct ycl_copyfile_state *state, uint32_t flags) {
    int in = open(from, YCL_O_RDONLY | YCL_O_CLOEXEC);
    if (in < 0) return -1;
    int out = open(to, YCL_O_WRONLY | YCL_O_CREAT | YCL_O_TRUNC | YCL_O_CLOEXEC, 0644);
    if (out < 0) {
        close(in);
        return -1;
    }
    int r = fcopyfile(in, out, state, flags);
    close(in);
    close(out);
    return r;
}

// --- message catalogs: Ycode's libSystem has none; catgets returns the
//     default text ---

YCL_EXPORT void *catopen(const char *name, int flag) {
    (void)name;
    (void)flag;
    ycl_errno = YCL_ENOENT;
    return (void *)-1;
}
YCL_EXPORT char *catgets(void *catalog, int set, int number, const char *text) {
    (void)catalog;
    (void)set;
    (void)number;
    return (char *)text;
}
YCL_EXPORT int catclose(void *catalog) {
    (void)catalog;
    return 0;
}

// --- remaining locale-taking ctype entry points (C locale) ---

int ___tolower(int);
int ___toupper(int);
int __maskrune(int, unsigned long);
YCL_EXPORT int ___tolower_l(int c, void *locale) {
    (void)locale;
    return ___tolower(c);
}
YCL_EXPORT int ___toupper_l(int c, void *locale) {
    (void)locale;
    return ___toupper(c);
}
YCL_EXPORT int __maskrune_l(int c, unsigned long mask, void *locale) {
    (void)locale;
    return __maskrune(c, mask);
}
YCL_EXPORT unsigned long ___runetype_l(int c, void *locale) {
    (void)locale;
    return (unsigned long)__maskrune(c, ~0ul);
}

// --- groups: "wheel" (0) and the user's "staff" (20) ---

struct ycl_group {
    char *gr_name, *gr_passwd;
    uint32_t gr_gid;
    char **gr_mem;
};

static int fill_group(uint32_t gid, const char *want, struct ycl_group *g, char *buf, size_t size,
                      struct ycl_group **result) {
    *result = 0;
    const char *name = gid == 0 ? "wheel" : gid == 20 ? "staff" : 0;
    if (want) {
        if (!strcmp(want, "wheel")) gid = 0, name = "wheel";
        else if (!strcmp(want, "staff")) gid = 20, name = "staff";
        else return 0;
    }
    if (!name) return 0;
    size_t len = strlen(name) + 1;
    size_t need = (len + 2 + 7) / 8 * 8 + sizeof(char *);
    if (size < need) return YCL_ERANGE;
    memcpy(buf, name, len);
    buf[len] = '*';
    buf[len + 1] = 0;
    char **members = (char **)(buf + (len + 2 + 7) / 8 * 8);
    members[0] = 0;
    g->gr_name = buf;
    g->gr_passwd = buf + len;
    g->gr_gid = gid;
    g->gr_mem = members;
    *result = g;
    return 0;
}

YCL_EXPORT int getgrgid_r(uint32_t gid, struct ycl_group *g, char *buf, size_t size, struct ycl_group **result) {
    return fill_group(gid, 0, g, buf, size, result);
}
YCL_EXPORT int getgrnam_r(const char *name, struct ycl_group *g, char *buf, size_t size, struct ycl_group **result) {
    return fill_group(0, name, g, buf, size, result);
}
static struct ycl_group shared_group;
static char shared_group_buf[64];
YCL_EXPORT struct ycl_group *getgrgid(uint32_t gid) {
    struct ycl_group *r;
    return getgrgid_r(gid, &shared_group, shared_group_buf, sizeof shared_group_buf, &r) == 0 ? r : 0;
}
YCL_EXPORT struct ycl_group *getgrnam(const char *name) {
    struct ycl_group *r;
    return getgrnam_r(name, &shared_group, shared_group_buf, sizeof shared_group_buf, &r) == 0 ? r : 0;
}

// --- confstr(3): the search path and the per-user directories (Ycode
//     keeps them under TMPDIR, default /tmp) ---

enum { CS_PATH = 1, CS_DARWIN_USER_DIR = 65536, CS_DARWIN_USER_TEMP_DIR = 65537, CS_DARWIN_USER_CACHE_DIR = 65538 };

YCL_EXPORT size_t confstr(int name, char *buf, size_t len) {
    char value[PATH_MAX];
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp/";
    switch (name) {
    case CS_PATH: strlcpy(value, "/usr/bin:/bin:/usr/sbin:/sbin", sizeof value); break;
    case CS_DARWIN_USER_DIR:
    case CS_DARWIN_USER_TEMP_DIR:
    case CS_DARWIN_USER_CACHE_DIR:
        strlcpy(value, tmp, sizeof value);
        if (value[strlen(value) - 1] != '/') strlcat(value, "/", sizeof value);
        if (name == CS_DARWIN_USER_CACHE_DIR) strlcat(value, "Caches/", sizeof value);
        break;
    default: ycl_errno = YCL_EINVAL; return 0;
    }
    size_t need = strlen(value) + 1;
    if (buf && len) strlcpy(buf, value, len);
    return need;
}

// The notification name <libkern/OSThermalNotification.h> exports.
YCL_EXPORT const char *const kOSThermalNotificationPressureLevelName = "com.apple.system.thermalpressurelevel";
