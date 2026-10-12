/*
 * Host unit tests for libsystem_kernel's library-side spawn and libproc code
 * (kernel/spawn.c, kernel/libproc.c), built with -DYC_HOST_TEST so every
 * exported name is yc_test_<name> and every kernel call it makes is
 * yc_testk_<name>; this file supplies those fakes. Checked against
 * specs/simulator/processes.md sections 1.1, 1.2, 1.4, 1.7, 1.8, 1.14 and
 * 2.11. Original Ycode code. arm64 hosts only (yc_kernel.h uses arm64
 * register names).
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

/* Darwin errno values where they differ from the host's (Linux). The
 * others used here (EPERM, ESRCH, EBADF, ENOMEM, EINVAL) are the same. */
#define D_ENAMETOOLONG 63
#define D_EOVERFLOW 84

static int failures, checks;
#define CHECK(cond) do { checks++; if (!(cond)) { failures++; \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

/* ---- fakes --------------------------------------------------------------- */

static int fake_errno;
int *yc_testk___error(void) { return &fake_errno; }
void __ycode_set_errno(int v) { fake_errno = v; }

void *yc_testk_mmap(void *addr, size_t len, int prot, int flags, int fd, int64_t off)
{
    if (flags != (0x0002 | 0x1000) || prot != 3 || fd != -1 || off != 0)
        abort();
    void *p = mmap(addr, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? (void *)-1 : p;
}
int yc_testk_munmap(void *addr, size_t len) { return munmap(addr, len); }

/* _libkernel_functions v5 (host-library-init.md 2.1): only malloc/free used. */
static long mallocs, frees;
static void *t_malloc(size_t n) { mallocs++; return malloc(n); }
static void t_free(void *p) { frees++; free(p); }
struct libkernel_functions {
    unsigned long version;
    void *dlsym;
    void *(*malloc)(size_t);
    void (*free)(void *);
    void *rest[12];
};
static struct libkernel_functions fns = {5, NULL, t_malloc, t_free, {0}};
const struct libkernel_functions *yc_libkernel_fns;

/* BSD 244: record the descriptor. */
struct pair { uint64_t size; const void *ptr; };
static struct pair last_desc[9];
static int spawn_calls, spawn_had_desc, spawn_result;
int yc_testk_posix_spawn_trap(int *pid, const char *path, const void *desc, char *const argv[], char *const envp[])
{
    (void)path; (void)argv; (void)envp;
    spawn_calls++;
    spawn_had_desc = desc != NULL;
    if (desc)
        memcpy(last_desc, desc, sizeof last_desc);
    if (spawn_result == 0 && pid)
        *pid = 4242;
    return spawn_result;
}

/* BSD 336 / 545: answer from a small table. */
static int pi_call, pi_pid, pi_size, pi_result, pi_errno;
static uint32_t pi_flavor, pi_ext_flags;
static uint64_t pi_arg, pi_ext_id;
static int fill_proc_info(int callnum, int pid, uint32_t flavor, uint64_t arg, void *buf, int size)
{
    pi_call = callnum; pi_pid = pid; pi_flavor = flavor; pi_arg = arg; pi_size = size;
    if (pi_errno) { fake_errno = pi_errno; return -1; }
    if (callnum == 2 && flavor == 3 && buf) { /* TBSDINFO */
        memset(buf, 0, 136);
        memcpy((char *)buf + 48, "shortcomm", 10);
        memcpy((char *)buf + 64, pid == 7 ? "" : "the-long-name", pid == 7 ? 1 : 14);
        return 136;
    }
    if (callnum == 2 && flavor == 11 && buf) { /* PATHINFO */
        memset(buf, 0, (size_t)size);
        strcpy(buf, "/usr/libexec/thing");
        return 0;
    }
    return pi_result;
}
int yc_testk___proc_info(int callnum, int pid, uint32_t flavor, uint64_t arg, void *buf, int size)
{
    pi_ext_flags = 0; pi_ext_id = 0;
    return fill_proc_info(callnum, pid, flavor, arg, buf, size);
}
int yc_testk___proc_info_extended_id(int callnum, int pid, uint32_t flavor, uint32_t flags, uint64_t ext_id,
                                     uint64_t arg, void *buf, int size)
{
    int r = fill_proc_info(callnum, pid, flavor, arg, buf, size);
    pi_ext_flags = flags; pi_ext_id = ext_id;
    return r;
}

/* ---- functions under test ------------------------------------------------ */

typedef void *attr_t;
typedef void *fa_t;
int yc_test_posix_spawn(int *, const char *, const fa_t *, const attr_t *, char *const[], char *const[]);
int yc_test_posix_spawnattr_init(attr_t *);
int yc_test_posix_spawnattr_destroy(attr_t *);
int yc_test_posix_spawnattr_setflags(attr_t *, short);
int yc_test_posix_spawnattr_getflags(const attr_t *, short *);
int yc_test_posix_spawnattr_setsigmask(attr_t *, const uint32_t *);
int yc_test_posix_spawnattr_setbinpref_np(attr_t *, size_t, int32_t *, size_t *);
int yc_test_posix_spawnattr_getbinpref_np(const attr_t *, size_t, int32_t *, size_t *);
int yc_test_posix_spawnattr_setspecialport_np(attr_t *, uint32_t, int);
int yc_test_posix_spawnattr_setexceptionports_np(attr_t *, uint32_t, uint32_t, int, int);
int yc_test_posix_spawnattr_set_registered_ports_np(attr_t *, uint32_t *, uint32_t);
int yc_test_posix_spawnattr_set_qos_clamp_np(const attr_t *, uint64_t);
int yc_test_posix_spawnattr_set_subsystem_root_path_np(attr_t *, char *);
int yc_test_posix_spawnattr_setdataless_iopolicy_np(attr_t *, int);
int yc_test_posix_spawnattr_set_use_sanitizers_np(attr_t *, uint32_t);
int yc_test_posix_spawn_file_actions_init(fa_t *);
int yc_test_posix_spawn_file_actions_destroy(fa_t *);
int yc_test_posix_spawn_file_actions_addopen(fa_t *, int, const char *, int, uint16_t);
int yc_test_posix_spawn_file_actions_addclose(fa_t *, int);
int yc_test_posix_spawn_file_actions_adddup2(fa_t *, int, int);
int yc_test_posix_spawn_file_actions_addinherit_np(fa_t *, int);
int yc_test_posix_spawn_file_actions_addchdir(fa_t *, const char *);
int yc_test_posix_spawn_file_actions_add_fileportdup2_np(fa_t *, uint32_t, int);

int yc_test_proc_listpids(uint32_t, uint32_t, void *, int);
int yc_test_proc_listallpids(void *, int);
int yc_test_proc_listchildpids(int, void *, int);
int yc_test_proc_name(int, void *, uint32_t);
int yc_test_proc_pidpath(int, void *, uint32_t);
int yc_test_proc_pidpath_audittoken(const uint32_t *, void *, uint32_t);
int yc_test_proc_get_dirty(int, uint32_t *);
int yc_test_proc_set_dirty(int, _Bool);
int yc_test_proc_terminate(int, int *);
int yc_test_proc_pid_rusage(int, int, void *);

static uint32_t u32_at(const void *p, size_t off) { uint32_t v; memcpy(&v, (const char *)p + off, 4); return v; }
static uint64_t u64_at(const void *p, size_t off) { uint64_t v; memcpy(&v, (const char *)p + off, 8); return v; }

/* ---- tests --------------------------------------------------------------- */

static void test_attr(void)
{
    attr_t a = NULL;
    CHECK(yc_test_posix_spawnattr_init(NULL) == EINVAL);
    CHECK(yc_test_posix_spawnattr_init(&a) == 0 && a != NULL);
    /* Defaults (section 1.4). */
    CHECK(u64_at(a, 56) == 1);
    CHECK(u32_at(a, 68) == 0xFFFFFFFFu && u32_at(a, 72) == 0xFFFFFFFFu && u32_at(a, 76) == 0xFFFFFFFFu);
    for (int i = 0; i < 4; i++)
        CHECK(u32_at(a, 112 + 4 * i) == 0xFFFFFFFFu);
    CHECK(u32_at(a, 0) == 0 && u32_at(a, 16) == 0 && u64_at(a, 192) == 0 && u64_at(a, 232) == 0);

    short f = 0;
    CHECK(yc_test_posix_spawnattr_setflags(&a, 0x40) == 0);
    CHECK(yc_test_posix_spawnattr_getflags(&a, &f) == 0 && f == 0x40);
    attr_t none = NULL;
    CHECK(yc_test_posix_spawnattr_setflags(&none, 1) == EINVAL);
    uint32_t mask = 0x80001;
    CHECK(yc_test_posix_spawnattr_setsigmask(&a, &mask) == 0 && u32_at(a, 8) == 0x80001);

    int32_t prefs[5] = {0x0100000C, 7, 8, 9, 10};
    size_t oc = 0;
    CHECK(yc_test_posix_spawnattr_setbinpref_np(&a, 5, prefs, &oc) == 0 && oc == 4);
    CHECK(yc_test_posix_spawnattr_setbinpref_np(&a, 1, prefs, &oc) == 0 && oc == 1);
    CHECK(u32_at(a, 16) == 0x0100000C && u32_at(a, 20) == 0 && u32_at(a, 112) == 0xFFFFFFFFu);
    int32_t back[4] = {0};
    CHECK(yc_test_posix_spawnattr_getbinpref_np(&a, 4, back, &oc) == 0 && oc == 1 && back[0] == 0x0100000C);

    CHECK(yc_test_posix_spawnattr_set_qos_clamp_np(&a, 4) == EINVAL);
    CHECK(yc_test_posix_spawnattr_set_qos_clamp_np(&a, 3) == 0 && u64_at(a, 80) == 3);
    CHECK(yc_test_posix_spawnattr_setdataless_iopolicy_np(&a, 2) == 0);
    CHECK((u32_at(a, 128) & 4) && u32_at(a, 152) == (2 | 4));
    CHECK(yc_test_posix_spawnattr_set_use_sanitizers_np(&a, 1) == 0);

    /* Port actions: 24-byte records, growth past 2 and 4. */
    CHECK(yc_test_posix_spawnattr_setspecialport_np(&a, 0x1103, 4) == 0);
    CHECK(yc_test_posix_spawnattr_setexceptionports_np(&a, 0x3FFE, 0x1207, 0x80000001, 6) == 0);
    uint32_t regs[4] = {0x1303, 0x1403, 0x1503, 0x1603};
    CHECK(yc_test_posix_spawnattr_set_registered_ports_np(&a, regs, 4) == EINVAL);
    CHECK(yc_test_posix_spawnattr_set_registered_ports_np(&a, regs, 3) == 0);
    const char *pa = (const char *)(uintptr_t)u64_at(a, 192);
    CHECK(pa != NULL && u32_at(pa, 4) == 5 && (int)u32_at(pa, 0) >= 5);
    CHECK(u32_at(pa, 8 + 0) == 0 && u32_at(pa, 8 + 8) == 0x1103 && u32_at(pa, 8 + 20) == 4);
    CHECK(u32_at(pa, 32 + 0) == 1 && u32_at(pa, 32 + 4) == 0x3FFE && u32_at(pa, 32 + 8) == 0x1207 &&
          u32_at(pa, 32 + 12) == 0x80000001u && u32_at(pa, 32 + 16) == 6);
    for (int i = 0; i < 3; i++)
        CHECK(u32_at(pa, 56 + 24 * i) == 4 && u32_at(pa, 56 + 24 * i + 8) == regs[i]);

    char longpath[1100];
    memset(longpath, 'a', sizeof longpath - 1);
    longpath[sizeof longpath - 1] = 0;
    CHECK(yc_test_posix_spawnattr_set_subsystem_root_path_np(&a, longpath) == D_ENAMETOOLONG);
    CHECK(yc_test_posix_spawnattr_set_subsystem_root_path_np(&a, "/sub/root") == 0);
    CHECK(strcmp((const char *)(uintptr_t)u64_at(a, 232), "/sub/root") == 0);

    /* posix_spawn: descriptor contents. */
    int pid = 0;
    spawn_result = 0;
    CHECK(yc_test_posix_spawn(&pid, "/bin/x", NULL, &a, NULL, NULL) == 0 && pid == 4242 && spawn_had_desc);
    CHECK(last_desc[0].size == 248 && last_desc[0].ptr == a);
    CHECK(last_desc[1].size == 0 && last_desc[1].ptr == NULL);
    CHECK(last_desc[2].size == 8 + 24 * 5 && last_desc[2].ptr == pa);
    CHECK(last_desc[7].size == 1024 && last_desc[7].ptr == (const void *)(uintptr_t)u64_at(a, 232));
    CHECK(last_desc[3].size == 0 && last_desc[4].size == 0 && last_desc[5].size == 0 && last_desc[6].size == 0 &&
          last_desc[8].size == 0);

    /* The error number is the result; errno is untouched. */
    fake_errno = 0;
    spawn_result = 2;
    CHECK(yc_test_posix_spawn(&pid, "/missing", NULL, &a, NULL, NULL) == 2 && fake_errno == 0);
    spawn_result = 0;

    CHECK(yc_test_posix_spawnattr_set_subsystem_root_path_np(&a, NULL) == 0 && u64_at(a, 232) == 0);
    CHECK(yc_test_posix_spawnattr_destroy(&a) == 0 && a == NULL);
    CHECK(yc_test_posix_spawnattr_destroy(&a) == EINVAL);
}

static void test_file_actions(void)
{
    fa_t fa = NULL;
    CHECK(yc_test_posix_spawn_file_actions_init(&fa) == 0 && fa != NULL);

    /* No attributes and no file actions: no descriptor at all. */
    int pid = 0;
    CHECK(yc_test_posix_spawn(&pid, "/bin/x", &fa, NULL, NULL, NULL) == 0 && !spawn_had_desc);
    CHECK(yc_test_posix_spawn(&pid, "/bin/x", NULL, NULL, NULL, NULL) == 0 && !spawn_had_desc);

    CHECK(yc_test_posix_spawn_file_actions_addclose(&fa, -1) == EBADF);
    CHECK(yc_test_posix_spawn_file_actions_addclose(&fa, 10240) == EBADF);
    CHECK(yc_test_posix_spawn_file_actions_adddup2(&fa, 3, 10240) == EBADF);
    CHECK(yc_test_posix_spawn_file_actions_add_fileportdup2_np(&fa, 0, 1) == EBADF);
    char longpath[1100];
    memset(longpath, 'b', sizeof longpath - 1);
    longpath[sizeof longpath - 1] = 0;
    CHECK(yc_test_posix_spawn_file_actions_addchdir(&fa, longpath) == D_ENAMETOOLONG);

    CHECK(yc_test_posix_spawn_file_actions_addopen(&fa, 5, "/tmp/f", 0x601, 0644) == 0);
    CHECK(yc_test_posix_spawn_file_actions_addclose(&fa, 6) == 0);
    CHECK(yc_test_posix_spawn_file_actions_adddup2(&fa, 7, 1) == 0);
    CHECK(yc_test_posix_spawn_file_actions_addinherit_np(&fa, 8) == 0);
    CHECK(yc_test_posix_spawn_file_actions_addchdir(&fa, "/var") == 0);
    CHECK(yc_test_posix_spawn_file_actions_add_fileportdup2_np(&fa, 0x2203, 9) == 0);

    const char *b = fa;
    CHECK(u32_at(b, 4) == 6 && (int)u32_at(b, 0) >= 6);
    const char *a0 = b + 8, *a1 = a0 + 1040, *a2 = a1 + 1040, *a3 = a2 + 1040, *a4 = a3 + 1040, *a5 = a4 + 1040;
    CHECK(u32_at(a0, 0) == 0 && u32_at(a0, 4) == 5 && u32_at(a0, 8) == 0x601);
    CHECK(((const uint16_t *)(a0 + 12))[0] == 0644 && strcmp(a0 + 14, "/tmp/f") == 0);
    CHECK(u32_at(a1, 0) == 1 && u32_at(a1, 4) == 6);
    CHECK(u32_at(a2, 0) == 2 && u32_at(a2, 4) == 7 && u32_at(a2, 8) == 1);
    CHECK(u32_at(a3, 0) == 3 && u32_at(a3, 4) == 8);
    CHECK(u32_at(a4, 0) == 5 && strcmp(a4 + 8, "/var") == 0);
    CHECK(u32_at(a5, 0) == 4 && u32_at(a5, 4) == 0x2203 && u32_at(a5, 8) == 9);

    CHECK(yc_test_posix_spawn(&pid, "/bin/x", &fa, NULL, NULL, NULL) == 0 && spawn_had_desc);
    CHECK(last_desc[0].size == 0 && last_desc[0].ptr == NULL);
    CHECK(last_desc[1].size == 8 + 1040 * 6 && last_desc[1].ptr == fa);

    CHECK(yc_test_posix_spawn_file_actions_destroy(&fa) == 0 && fa == NULL);
}

static void test_libproc(void)
{
    char buf[4096];
    pi_errno = 0;
    pi_result = 40;
    CHECK(yc_test_proc_listpids(1, 0, buf, 400) == 40 && pi_call == 1 && pi_pid == 1 && pi_flavor == 0);
    CHECK(yc_test_proc_listallpids(buf, 400) == 10);
    CHECK(yc_test_proc_listchildpids(100, buf, 400) == 10 && pi_pid == 6 && pi_flavor == 100);
    fake_errno = 0;
    CHECK(yc_test_proc_listpids(99, 0, buf, 400) == 0 && fake_errno == EINVAL);
    pi_errno = ESRCH;
    CHECK(yc_test_proc_listpids(1, 0, buf, 400) == 0);
    pi_errno = 0;

    fake_errno = 0;
    CHECK(yc_test_proc_name(5, buf, 16) == 0 && fake_errno == ENOMEM);
    CHECK(yc_test_proc_name(5, buf, 64) == 13 && strcmp(buf, "the-long-name") == 0 && pi_flavor == 3);
    CHECK(yc_test_proc_name(7, buf, 64) == 9 && strcmp(buf, "shortcomm") == 0);

    CHECK(yc_test_proc_pidpath(5, buf, 512) == 0 && fake_errno == ENOMEM);
    CHECK(yc_test_proc_pidpath(5, buf, 8192) == 0 && fake_errno == D_EOVERFLOW);
    CHECK(yc_test_proc_pidpath(5, buf, 1024) == 18 && strcmp(buf, "/usr/libexec/thing") == 0 && pi_flavor == 11 &&
          pi_size == 1024);
    uint32_t token[8] = {501, 501, 20, 501, 20, 123, 100000, 77};
    CHECK(yc_test_proc_pidpath_audittoken(token, buf, 2048) == 18 && pi_pid == 123 && pi_ext_flags == 1 &&
          pi_ext_id == 77);

    uint32_t flags = 0;
    pi_result = 0x5;
    CHECK(yc_test_proc_get_dirty(9, &flags) == 0 && flags == 5 && pi_call == 8 && pi_flavor == 3);
    CHECK(yc_test_proc_get_dirty(9, NULL) == EINVAL);
    CHECK(yc_test_proc_set_dirty(9, 1) == 0 && pi_flavor == 2 && pi_arg == 1);
    int sig = 0;
    pi_result = 15;
    CHECK(yc_test_proc_terminate(9, &sig) == 0 && sig == 15 && pi_call == 7);
    pi_errno = EPERM;
    CHECK(yc_test_proc_terminate(9, &sig) == EPERM);
    CHECK(yc_test_proc_pid_rusage(9, 4, buf) == -1);
    pi_errno = 0;
    pi_result = 0;
    CHECK(yc_test_proc_pid_rusage(9, 4, buf) == 0 && pi_call == 9 && pi_flavor == 4);
}

int main(void)
{
    yc_libkernel_fns = &fns;
    test_attr();
    test_file_actions();
    test_libproc();
    CHECK(mallocs == frees);
    /* Without the libSystem table the blocks come from mmap. */
    yc_libkernel_fns = NULL;
    attr_t a = NULL;
    CHECK(yc_test_posix_spawnattr_init(&a) == 0 && u64_at(a, 56) == 1);
    CHECK(yc_test_posix_spawnattr_destroy(&a) == 0);
    printf("kernel host tests: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
