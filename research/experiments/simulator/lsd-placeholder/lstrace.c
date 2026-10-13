// lstrace: our own interposer (Ycode stage 9, agent J). Logs, through os_log
// (subsystem dev.ycode.lstrace), the file calls a process makes on paths that
// contain $LSTRACE_FILTER, and every call on descriptors it opened for them:
// open/openat/stat/lstat/access/getattrlist/getxattr/read/pread/lseek/mmap/
// fcntl/fstat/close/fgetattrlist. Used in the simulator's lsd (DYLD_INSERT_LIBRARIES
// through launchctl setenv) to see what LaunchServices reads during seeding.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/attr.h>
#include <sys/xattr.h>
#include <sys/mount.h>
#include <os/log.h>
#include <errno.h>

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static __thread int busy;
static os_log_t logger;
static char tracked[1024];
static const char *filter(void) { static const char *f; if (!f) { f = getenv("LSTRACE_FILTER"); if (!f) f = "\x01"; } return f; }
static __thread int hot;
static int match(const char *p) { if (p && strstr(p, filter()) != NULL) { hot = 400; return 1; } if (hot > 0) { hot--; return p != NULL; } return 0; }
static void say(const char *fmt, ...) {
    if (busy) return;
    int saved = errno;
    busy = 1;
    if (!logger) logger = os_log_create("dev.ycode.lstrace", "trace");
    char buf[900]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    uint64_t tid = 0; pthread_threadid_np(NULL, &tid);
    os_log(logger, "LST t%llx %{public}s", tid, buf);
    busy = 0;
    errno = saved;
}
static int isTracked(int fd) { return fd >= 0 && fd < 1024 && tracked[fd]; }
static void track(int fd, int on) { if (fd >= 0 && fd < 1024) tracked[fd] = on; }

static int my_open(const char *path, int flags, ...) {
    va_list ap; va_start(ap, flags); int mode = va_arg(ap, int); va_end(ap);
    int r = open(path, flags, mode);
    if (match(path)) { say("open %s flags %#x -> %d", path, flags, r); track(r, 1); }
    return r;
}
INTERPOSE(my_open, open)
static int my_openat(int dfd, const char *path, int flags, ...) {
    va_list ap; va_start(ap, flags); int mode = va_arg(ap, int); va_end(ap);
    int r = openat(dfd, path, flags, mode);
    if (match(path)) { say("openat %d %s flags %#x -> %d", dfd, path, flags, r); track(r, 1); }
    return r;
}
INTERPOSE(my_openat, openat)
static int my_close(int fd) { if (isTracked(fd)) { say("close %d", fd); track(fd, 0); } return close(fd); }
INTERPOSE(my_close, close)
static int my_stat(const char *p, struct stat *st) { int r = stat(p, st); if (match(p)) say("stat %s -> %d size %lld mode %o uid %u", p, r, r ? 0LL : (long long)st->st_size, r ? 0 : st->st_mode, r ? 0 : st->st_uid); return r; }
INTERPOSE(my_stat, stat)
static int my_lstat(const char *p, struct stat *st) { int r = lstat(p, st); if (match(p)) say("lstat %s -> %d", p, r); return r; }
INTERPOSE(my_lstat, lstat)
static int my_fstat(int fd, struct stat *st) { int r = fstat(fd, st); if (isTracked(fd)) say("fstat %d -> %d size %lld", fd, r, (long long)st->st_size); return r; }
INTERPOSE(my_fstat, fstat)
static int my_fstatat(int dfd, const char *p, struct stat *st, int fl) { int r = fstatat(dfd, p, st, fl); if (match(p)) say("fstatat %s fl %#x -> %d", p, fl, r); return r; }
INTERPOSE(my_fstatat, fstatat)
static int my_access(const char *p, int m) { int r = access(p, m); if (match(p)) say("access %s %d -> %d", p, m, r); return r; }
INTERPOSE(my_access, access)
static int my_faccessat(int d, const char *p, int m, int f) { int r = faccessat(d, p, m, f); if (match(p)) say("faccessat %s %d -> %d", p, m, r); return r; }
INTERPOSE(my_faccessat, faccessat)
static ssize_t my_read(int fd, void *b, size_t n) { ssize_t r = read(fd, b, n); if (isTracked(fd)) say("read %d %zu -> %zd", fd, n, r); return r; }
INTERPOSE(my_read, read)
static ssize_t my_pread(int fd, void *b, size_t n, off_t o) { ssize_t r = pread(fd, b, n, o); if (isTracked(fd)) say("pread %d %zu @%lld -> %zd", fd, n, (long long)o, r); return r; }
INTERPOSE(my_pread, pread)
static off_t my_lseek(int fd, off_t o, int w) { off_t r = lseek(fd, o, w); if (isTracked(fd)) say("lseek %d %lld %d -> %lld", fd, (long long)o, w, (long long)r); return r; }
INTERPOSE(my_lseek, lseek)
static void *my_mmap(void *a, size_t n, int prot, int fl, int fd, off_t o) { void *r = mmap(a, n, prot, fl, fd, o); if (isTracked(fd)) say("mmap fd %d len %zu prot %d flags %#x off %lld -> %p", fd, n, prot, fl, (long long)o, r); return r; }
INTERPOSE(my_mmap, mmap)
static int my_fcntl(int fd, int cmd, ...) { va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap); int r = fcntl(fd, cmd, arg); if (isTracked(fd)) say("fcntl %d cmd %d -> %d", fd, cmd, r); return r; }
INTERPOSE(my_fcntl, fcntl)
// LSTRACE_HIDE: colon-separated exact paths that getattrlist reports as ENOENT (experiment).
static int hidden(const char *p) {
    const char *h = getenv("LSTRACE_HIDE"); if (!h || !p) return 0;
    size_t n = strlen(p);
    for (const char *q = h; *q; ) { const char *e = strchr(q, ':'); size_t m = e ? (size_t)(e - q) : strlen(q);
        if (m == n && !strncmp(q, p, n)) return 1; if (!e) break; q = e + 1; }
    return 0;
}
// LSTRACE_CAPSCLEAR=<mask>: clear these VOL_CAP_FMT bits in ATTR_VOL_CAPABILITIES replies (experiment).
static void capsClear(struct attrlist *a, unsigned char *b) {
    const char *cc = getenv("LSTRACE_CAPSCLEAR"); if (!cc || !(a->volattr & ATTR_VOL_CAPABILITIES)) return;
    static const unsigned char csz[32] = {8,4,8,4,4,8,8,8,4,16,16,16,16,16,32,4,4,4,4,4,4,4,8,16,16,8,8,8,16,0,4,20};
    static const unsigned char vsz[17] = {4,4,8,8,8,8,8,4,4,4,4,4,8,8,4,8,8};
    unsigned off = 4;
    if (a->commonattr & ATTR_CMN_RETURNED_ATTRS) off += 20;
    for (int i = 0; i < 31; i++) if ((a->commonattr & (1u << i)) && i != 29) off += csz[i];
    for (int i = 0; i < 17; i++) if (a->volattr & (1u << i)) off += vsz[i];
    uint32_t caps; memcpy(&caps, b + off, 4); uint32_t m = (uint32_t)strtoul(cc, 0, 0); caps &= ~m; memcpy(b + off, &caps, 4);
}
static int my_getattrlist(const char *p, void *al, void *b, size_t n, unsigned int o) {
    if (hidden(p)) { say("getattrlist %s HIDDEN", p); errno = ENOENT; return -1; }
    int r = getattrlist(p, al, b, n, o);
    struct attrlist *a0 = al;
    if (r == 0) capsClear(a0, b);
    const char *pt = getenv("LSTRACE_PATCH");
    size_t pl = strlen(p), fl = strlen(filter());
    if (r == 0 && pt && a0->commonattr == 0xd61f9e0d && a0->fileattr == 1 && pl > fl && !strcmp(p + pl - fl, filter()) && p[pl - fl - 1] == '/') {
        unsigned m = (unsigned)strtoul(pt, 0, 0); unsigned char *q = b;
        if (m & 1) { uint32_t g = 0x724d3506; memcpy(q + 0x7c, &g, 4); }
        if (m & 2) { uint64_t t = 0x6acc2ee7, ns = 0x010f9f4a; memcpy(q + 0x4c, &t, 8); memcpy(q + 0x54, &ns, 8); t = 0x6acd04a0; ns = 0x31b6fc73; memcpy(q + 0x5c, &t, 8); memcpy(q + 0x64, &ns, 8); }
        if (m & 4) { uint64_t id; memcpy(&id, q + 0x84, 8); id += 0x3a00000; memcpy(q + 0x84, &id, 8); memcpy(q + 0xac, &id, 8); memcpy(q + 0xb8, &id, 8); }
        if (m & 8) { uint32_t d = 0x1000011; memcpy(q + 0x20, &d, 4); memcpy(q + 0xb4, &d, 4); }
        say("getattrlist %s PATCHED %#x", p, m);
    }
    if (r == 0 && getenv("LSTRACE_FNDR") && (a0->commonattr & 0x80004000) == 0x80004000) {
        unsigned *u = b; if (!(u[1] & 0x4000)) { u[1] |= 0x4000; if (match(p)) say("getattrlist %s FNDR-RETURNED", p); }
    }
    const char *pq = getenv("LSTRACE_PATCHPARENT");
    if (r == 0 && pq && !strcmp(pq, p) && (a0->commonattr & 0x84000000) == 0x84000000) {
        // PARENTID: after RETURNED_ATTRS..FILEID in bit order; locate it for the two request shapes LS uses.
        unsigned off = 0;
        if (a0->commonattr == 0xd61f9e0d) off = 0x8c;
        if (off) { uint64_t id = 0x7777777; memcpy((unsigned char *)b + off, &id, 8); say("getattrlist %s PARENTPATCHED", p); }
    }
    const char *pp = getenv("LSTRACE_PATCHDIR");
    if (r == 0 && pp && !strcmp(pp, p) && a0->commonattr == 0xd61f9e0d && a0->dirattr == 5) {
        unsigned char *q = b; uint64_t id = 0x7777777; memcpy(q + 0x84, &id, 8); memcpy(q + 0xb0, &id, 8);
        say("getattrlist %s DIRPATCHED", p);
    }
    if (match(p)) { struct attrlist *a = al; say("getattrlist %s [%#x,%#x,%#x,%#x,%#x] opts %#x -> %d", p, a->commonattr, a->volattr, a->dirattr, a->fileattr, a->forkattr, o, r); }
    return r;
}
INTERPOSE(my_getattrlist, getattrlist)
static int my_fgetattrlist(int fd, void *al, void *b, size_t n, unsigned int o) {
    int r = fgetattrlist(fd, al, b, n, o);
    if (r == 0) capsClear(al, b);
    if (isTracked(fd)) { struct attrlist *a = al; say("fgetattrlist %d [%#x,%#x,%#x,%#x,%#x] -> %d", fd, a->commonattr, a->volattr, a->dirattr, a->fileattr, a->forkattr, r); }
    return r;
}
INTERPOSE(my_fgetattrlist, fgetattrlist)
static int my_getattrlistat(int d, const char *p, void *al, void *b, size_t n, unsigned long o) {
    int r = getattrlistat(d, p, al, b, n, o);
    if (match(p)) { struct attrlist *a = al; say("getattrlistat %s [%#x,%#x,%#x,%#x,%#x] -> %d", p, a->commonattr, a->volattr, a->dirattr, a->fileattr, a->forkattr, r); }
    return r;
}
INTERPOSE(my_getattrlistat, getattrlistat)
static ssize_t my_getxattr(const char *p, const char *nm, void *v, size_t n, u_int32_t pos, int o) {
    ssize_t r = getxattr(p, nm, v, n, pos, o); if (match(p)) say("getxattr %s %s -> %zd", p, nm, r); return r;
}
INTERPOSE(my_getxattr, getxattr)

static int my_statfs(const char *p, struct statfs *b) { int r = statfs(p, b); if (match(p)) say("statfs %s -> %d type %s flags %#x mnton %s", p, r, r ? "" : b->f_fstypename, r ? 0 : b->f_flags, r ? "" : b->f_mntonname); return r; }
INTERPOSE(my_statfs, statfs)
static int my_fstatfs(int fd, struct statfs *b) { int r = fstatfs(fd, b); if (isTracked(fd) || hot > 0) say("fstatfs %d -> %d type %s flags %#x", fd, r, r ? "" : b->f_fstypename, r ? 0 : b->f_flags); return r; }
INTERPOSE(my_fstatfs, fstatfs)
static ssize_t my_readlink(const char *p, char *b, size_t n) { ssize_t r = readlink(p, b, n); if (match(p)) say("readlink %s -> %zd", p, r); return r; }
INTERPOSE(my_readlink, readlink)
static int my_getfsstat(struct statfs *b, int n, int f) { int r = getfsstat(b, n, f); if (hot > 0) say("getfsstat %d -> %d", n, r); return r; }
INTERPOSE(my_getfsstat, getfsstat)
