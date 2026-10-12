/*
 * sfbtrace: Ycode research interposer for the simulator framebuffer client
 * library (original Ycode code; contains no Apple code).
 *
 * Built for the iOS simulator platform and named like the real library, it is
 * loaded in its place (SIMULATOR_FRAMEBUFFER_FRAMEWORK points at it). It
 * exports the same function names (generated stubs, tramps.s) and forwards
 * every call to the real library, opened with dlopen. For each call it logs:
 * the caller's image, x0-x7 (with a safe description of each value: ObjC/CF
 * objects via CFCopyDescription, C strings, short hex of other readable
 * memory), d0-d3, and after the call x0/x1/d0-d3 plus any argument memory
 * that changed (out-parameters). Block arguments are replaced by wrapper
 * blocks so that their later invocations are logged too.
 *
 * Log: $SFBTRACE_DIR (default /tmp/sfbtrace-R4)/<process>-<pid>.log
 * Real library: $SFBTRACE_REAL (default: CoreSimulator's copy).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/objc.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

extern const char *const sfbt_names[];
extern const size_t sfbt_count;
extern const char *const sfbt_data_names[];
extern const size_t sfbt_data_count;
extern void *const sfbt_data_vars[];
extern void sfbt_blk_common(void);
extern const char *getprogname(void);

#define DEFAULT_REAL "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/Platforms/iphoneos/Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer"

struct frame {
    uint64_t x[8];
    uint64_t x8, idx;
    double d[8];
    uint64_t pad[2];
    uint64_t rx0, rx1;
    double rd[4];
    uint64_t target, cookie;
};

static void *g_real;
static void **g_fn;
static FILE *g_log;
static pthread_mutex_t g_mu = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static _Atomic uint64_t g_seq;
static __thread int t_depth;
static __thread int t_in_log;

/* ---------------------------------------------------------------- safety */

/* Readable, and never executable: the tool must not read any code bytes. */
static int readable(uint64_t a, void *buf, size_t n)
{
    if (a < 0x100000 || (a >> 47)) return 0;
    vm_address_t ra = (vm_address_t)a;
    vm_size_t rs = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt,
                       &obj) != KERN_SUCCESS)
        return 0;
    if (ra > a || a + n > ra + rs) return 0;
    if (info.protection & VM_PROT_EXECUTE) return 0;
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)a, n, (vm_address_t)buf, &got) == KERN_SUCCESS && got == n;
}

static Class *g_classes;
static unsigned g_nclasses;
static int cmpp(const void *a, const void *b)
{
    uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return x < y ? -1 : x > y;
}
static void refresh_classes(void)
{
    free(g_classes);
    g_classes = objc_copyClassList(&g_nclasses);
    qsort(g_classes, g_nclasses, sizeof(Class), cmpp);
}
static int known_class(uintptr_t c)
{
    for (int pass = 0; pass < 2; pass++) {
        if (g_classes && bsearch(&c, g_classes, g_nclasses, sizeof(Class), cmpp)) return 1;
        if (pass == 0) refresh_classes();
    }
    return 0;
}

/* Returns the class name if v looks like a live ObjC/CF object. */
static const char *object_class_name(uint64_t v)
{
    uint64_t isa;
    if (!readable(v, &isa, 8)) return NULL;
    uintptr_t cls = (uintptr_t)(isa & 0x0000000ffffffff8ULL);
    if (!cls || !known_class(cls)) return NULL;
    return class_getName((Class)cls);
}

static void describe(uint64_t v)
{
    if (v == 0) { fprintf(g_log, "0"); return; }
    fprintf(g_log, "0x%llx", (unsigned long long)v);
    const char *cn = NULL;
    if (v >> 63) {
        /* Possible tagged-pointer object: only strings and numbers are described. */
        Class c = object_getClass((id)v);
        if (c && known_class((uintptr_t)c)) {
            const char *n = class_getName(c);
            if (strstr(n, "TaggedPointerString") || strstr(n, "NSCFNumber")) cn = n;
        }
        if (!cn) return;
    } else {
        cn = object_class_name(v);
    }
    if (cn) {
        CFStringRef d = CFCopyDescription((CFTypeRef)v);
        char buf[1024] = "";
        if (d) { CFStringGetCString(d, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(d); }
        for (char *p = buf; *p; p++) if (*p == '\n') *p = ' ';
        fprintf(g_log, " <%s> {%s}", cn, buf);
        return;
    }
    unsigned char b[48];
    if (readable(v, b, sizeof b)) {
        int n = 0;
        while (n < (int)sizeof b && b[n] >= 32 && b[n] < 127) n++;
        if (n >= 2 && n < (int)sizeof b && b[n] == 0) { fprintf(g_log, " \"%.*s\"", n, b); return; }
        if (n == (int)sizeof b) {
            char s[260]; size_t i = 0;
            if (readable(v, s, sizeof s - 1)) {
                s[sizeof s - 1] = 0;
                for (i = 0; i < sizeof s - 1 && s[i]; i++) if (s[i] < 32 || s[i] > 126) break;
                if (s[i] == 0) { fprintf(g_log, " \"%s\"", s); return; }
            }
        }
        fprintf(g_log, " [");
        for (int i = 0; i < 32; i++) fprintf(g_log, "%02x%s", b[i], (i % 8 == 7 && i < 31) ? " " : "");
        fprintf(g_log, "]");
    }
}

static void header(const char *kind, const char *name, uint64_t seq, uint64_t lr)
{
    struct timeval tv; gettimeofday(&tv, NULL);
    Dl_info di = {0};
    const char *img = "?";
    if (lr && dladdr((void *)lr, &di) && di.dli_fname) {
        img = strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname;
    }
    fprintf(g_log, "%ld.%06d t%llx #%llu %*s%s %s [from %s]", (long)tv.tv_sec, (int)tv.tv_usec,
            (unsigned long long)pthread_mach_thread_np(pthread_self()), (unsigned long long)seq,
            t_depth * 2, "", kind, name, img);
}

/* ---------------------------------------------------------------- blocks */

struct blk_desc { unsigned long reserved, size; const char *sig; };
struct blk {
    void *isa; int32_t flags, reserved; void *invoke; struct blk_desc *desc;
    void *orig; uint64_t id; const char *where;
};
extern void *_NSConcreteGlobalBlock[];
static _Atomic uint64_t g_blk_ids;

static const char *block_signature(void *b)
{
    struct blk *ob = b;
    if (!(ob->flags & (1 << 30))) return NULL;
    char *d = (char *)ob->desc + 2 * sizeof(unsigned long);
    if (ob->flags & (1 << 25)) d += 2 * sizeof(void *);
    return *(const char **)d;
}

static uint64_t wrap_block(uint64_t v, const char *where)
{
    extern void *_Block_copy(const void *);
    void *orig = _Block_copy((void *)v);
    struct blk *w = calloc(1, sizeof *w);
    struct blk_desc *d = calloc(1, sizeof *d);
    const char *sig = block_signature(orig);
    d->size = sizeof *w;
    d->sig = sig;
    w->isa = _NSConcreteGlobalBlock;
    w->flags = (1 << 28) | (sig ? (1 << 30) : 0);
    w->invoke = (void *)sfbt_blk_common;
    w->desc = d;
    w->orig = orig;
    w->id = ++g_blk_ids;
    w->where = where;
    fprintf(g_log, " => block#%llu sig=%s", (unsigned long long)w->id, sig ? sig : "(none)");
    return (uint64_t)w;
}

/* ---------------------------------------------------------------- hooks */

static void log_args(struct frame *f, int first)
{
    for (int i = first; i < 8; i++) {
        fprintf(g_log, "\n      x%d=", i);
        describe(f->x[i]);
        const char *cn = object_class_name(f->x[i]);
        if (cn && strstr(cn, "Block")) f->x[i] = wrap_block(f->x[i], "arg");
    }
    fprintf(g_log, "\n      x8=0x%llx d0..d7= %g %g %g %g %g %g %g %g\n", (unsigned long long)f->x8,
            f->d[0], f->d[1], f->d[2], f->d[3], f->d[4], f->d[5], f->d[6], f->d[7]);
}

/* Out-parameter tracking: snapshot readable non-object argument memory. */
struct snap { uint64_t addr; unsigned char b[64]; int ok; };
static __thread struct snap t_snaps[16][8];

static void take_snaps(struct frame *f)
{
    if (t_depth >= 16) return;
    for (int i = 0; i < 8; i++) {
        struct snap *s = &t_snaps[t_depth][i];
        s->addr = f->x[i];
        s->ok = !object_class_name(f->x[i]) && readable(f->x[i], s->b, sizeof s->b);
    }
}

static void diff_snaps(void)
{
    if (t_depth >= 16) return;
    for (int i = 0; i < 8; i++) {
        struct snap *s = &t_snaps[t_depth][i];
        unsigned char now[64];
        if (!s->ok || !readable(s->addr, now, sizeof now) || !memcmp(now, s->b, sizeof now)) continue;
        fprintf(g_log, "      out x%d @0x%llx:", i, (unsigned long long)s->addr);
        for (int j = 0; j < 64; j++) fprintf(g_log, "%s%02x", (j % 8) ? "" : " ", now[j]);
        uint64_t w0; memcpy(&w0, now, 8);
        fprintf(g_log, "\n        word0=");
        describe(w0);
        fprintf(g_log, "\n");
    }
}

void *sfbt_pre(struct frame *f, uint64_t lr)
{
    uint64_t idx = f->idx;
    f->cookie = 0;
    if (!g_fn[idx]) g_fn[idx] = dlsym(g_real, sfbt_names[idx]);
    if (t_in_log) return g_fn[idx];
    t_in_log = 1;
    pthread_mutex_lock(&g_mu);
    f->cookie = ++g_seq;
    header("CALL", sfbt_names[idx], f->cookie, lr);
    log_args(f, 0);
    take_snaps(f);
    fflush(g_log);
    pthread_mutex_unlock(&g_mu);
    t_depth++;
    t_in_log = 0;
    return g_fn[idx];
}

void sfbt_post(struct frame *f)
{
    if (!f->cookie) return;
    t_in_log = 1;
    t_depth--;
    pthread_mutex_lock(&g_mu);
    header("RET ", sfbt_names[f->idx], f->cookie, 0);
    fprintf(g_log, " x0=");
    describe(f->rx0);
    fprintf(g_log, " x1=0x%llx d0..d3= %g %g %g %g\n", (unsigned long long)f->rx1,
            f->rd[0], f->rd[1], f->rd[2], f->rd[3]);
    diff_snaps();
    fflush(g_log);
    pthread_mutex_unlock(&g_mu);
    t_in_log = 0;
}

void *sfbt_blk_pre(struct frame *f, uint64_t lr)
{
    struct blk *w = (struct blk *)f->x[0];
    struct blk *orig = w->orig;
    f->x[0] = (uint64_t)orig;
    t_in_log = 1;
    pthread_mutex_lock(&g_mu);
    f->cookie = ++g_seq;
    f->idx = w->id;
    char name[64]; snprintf(name, sizeof name, "block#%llu", (unsigned long long)w->id);
    header("BLOCK", name, f->cookie, lr);
    log_args(f, 1);
    take_snaps(f);
    fflush(g_log);
    pthread_mutex_unlock(&g_mu);
    t_depth++;
    t_in_log = 0;
    return orig->invoke;
}

void sfbt_blk_post(struct frame *f)
{
    t_in_log = 1;
    t_depth--;
    pthread_mutex_lock(&g_mu);
    char name[64]; snprintf(name, sizeof name, "block#%llu", (unsigned long long)f->idx);
    header("BRET", name, f->cookie, 0);
    fprintf(g_log, " x0=0x%llx\n", (unsigned long long)f->rx0);
    fflush(g_log);
    pthread_mutex_unlock(&g_mu);
    t_in_log = 0;
}

/* ---------------------------------------------------------------- setup */

__attribute__((constructor)) static void sfbt_init(void)
{
    const char *dir = getenv("SFBTRACE_DIR");
    if (!dir) dir = "/tmp/sfbtrace-R4";
    mkdir(dir, 0777);
    char path[1024];
    snprintf(path, sizeof path, "%s/%s-%d.log", dir, getprogname(), getpid());
    g_log = fopen(path, "a");
    if (!g_log) g_log = stderr;
    const char *real = getenv("SFBTRACE_REAL");
    if (!real) real = DEFAULT_REAL;
    g_real = dlopen(real, RTLD_NOW | RTLD_LOCAL);
    g_fn = calloc(sfbt_count, sizeof *g_fn);
    fprintf(g_log, "== sfbtrace loaded in %s pid %d; real=%s handle=%p err=%s\n", getprogname(), getpid(),
            real, g_real, g_real ? "" : dlerror());
    const char *keys[] = { "SIMULATOR_FRAMEBUFFER_FRAMEWORK", "SIMULATOR_HID_SYSTEM_MANAGER",
                           "SIMULATOR_MAINSCREEN_WIDTH", "SIMULATOR_MAINSCREEN_HEIGHT",
                           "SIMULATOR_MAINSCREEN_SCALE", "SIMULATOR_MAINSCREEN_PITCH",
                           "SIMULATOR_EXTENDED_DISPLAY_PROPERTIES", "SIMULATOR_MODEL_IDENTIFIER" };
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++)
        fprintf(g_log, "   env %s=%s\n", keys[i], getenv(keys[i]) ? getenv(keys[i]) : "(unset)");
    for (size_t i = 0; i < sfbt_data_count && g_real; i++) {
        void *p = dlsym(g_real, sfbt_data_names[i]);
        if (p) memcpy(sfbt_data_vars[i], p, 8);
        fprintf(g_log, "   data %s -> ", sfbt_data_names[i]);
        describe(p ? *(uint64_t *)p : 0);
        fprintf(g_log, "\n");
    }
    /* Who loaded us: image names on the current stack (no symbol names). */
    void *bt[64];
    int n = backtrace(bt, 64);
    fprintf(g_log, "   load stack:");
    for (int i = 0; i < n; i++) {
        Dl_info di = {0};
        const char *img = (dladdr(bt[i], &di) && di.dli_fname) ? di.dli_fname : "?";
        const char *s = strrchr(img, '/');
        fprintf(g_log, " %s", s ? s + 1 : img);
    }
    fprintf(g_log, "\n");
    fflush(g_log);
}
