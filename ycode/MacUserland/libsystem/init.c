// init.c - libSystem's initializer, the program globals, exit and abort
// (specs/macos/libsystem.md §3, §6). Clean-room Ycode code; the init
// interfaces of the host libraries come from
// specs/simulator/host-library-init.md §1-§2.
#include "ycl.h"
#include "yc_dyld_api.h"

// Set by Ycode's dyld before any initializer runs (dyld.md §7.2).
YCL_EXPORT const struct yc_dyld_api *ycode_dyld_api;

YCL_EXPORT long __stack_chk_guard = 0x59434C4755415244L;

struct program_vars {
    const void *mh;
    int *argc;
    char ***argv;
    char ***environ;
    const char **progname;
};
static const struct program_vars *vars;
static int fallback_argc;
static char **fallback_argv, **fallback_environ;
static const char *fallback_progname = "";
// The program name as the public variable <stdlib.h> code may read; it is
// the storage _NSGetProgname points at once libSystem is initialized.
YCL_EXPORT const char *__progname = "";

YCL_EXPORT int *_NSGetArgc(void) { return vars ? vars->argc : &fallback_argc; }
YCL_EXPORT char ***_NSGetArgv(void) { return vars ? vars->argv : &fallback_argv; }
YCL_EXPORT char ***_NSGetEnviron(void) { return vars ? vars->environ : &fallback_environ; }
YCL_EXPORT char **_NSGetProgname(void) { return (char **)(vars ? &__progname : &fallback_progname); }
YCL_EXPORT const void *_NSGetMachExecuteHeader(void) { return vars ? vars->mh : 0; }
YCL_EXPORT const char *getprogname(void) { return *_NSGetProgname(); }
YCL_EXPORT void setprogname(const char *name) {
    const char *slash = strrchr(name, '/');
    *_NSGetProgname() = (char *)(slash ? slash + 1 : name);
}

YCL_EXPORT int _NSGetExecutablePath(char *buf, uint32_t *size) {
    const char *path = ycode_dyld_api ? ycode_dyld_api->executable_path : "";
    uint32_t need = (uint32_t)strlen(path) + 1;
    if (*size < need) {
        *size = need;
        return -1;
    }
    memcpy(buf, path, need);
    return 0;
}

// --- the tables handed to the host libraries (host-library-init.md §2) ---

static void no_cancel(int error) { (void)error; }

static void *kernel_dlsym(void *handle, const char *name) {
    return ycode_dyld_api ? ycode_dyld_api->dlsym(handle, name) : 0;
}

static const struct {
    unsigned long version;
    void *(*dlsym)(void *, const char *);
    void *(*malloc)(size_t);
    void (*free)(void *);
    void *(*realloc)(void *, size_t);
    void (*pthread_exit_if_canceled)(int);
    void *reserved[5];
    void *pthread_clear_qos_tsd;
    void *pthread_current_stack_contains_np;
    void *malloc_type_malloc, *malloc_type_free, *malloc_type_realloc;
} kernel_functions = {5, kernel_dlsym, malloc, free, realloc, no_cancel, {0}, 0, 0, 0, 0, 0};

static const struct {
    unsigned long version;
    void (*exit)(int);
    void *(*malloc)(size_t);
    void (*free)(void *);
} pthread_functions = {2, exit, malloc, free};

__attribute__((constructor)) static void libsystem_initializer(int argc, char **argv, char **envp, char **apple,
                                                               const struct program_vars *program_vars) {
    (void)argc;
    (void)argv;
    vars = program_vars;
    if (program_vars && program_vars->progname && *program_vars->progname) __progname = *program_vars->progname;
    __libkernel_init(&kernel_functions, envp, apple, program_vars);
    __libplatform_init(0, envp, apple, program_vars);
    __pthread_init(&pthread_functions, envp, apple, program_vars);
    ycl_malloc_init();
    ycl_ctype_init();
    long guard = 0;
    if (getentropy(&guard, sizeof guard) == 0 && guard != 0) __stack_chk_guard = guard;
    ycl_stdio_init();
    __pthread_late_init(envp, apple, program_vars);
    ycl_dispatch_init();
    ycl_errno = 0;
}

// --- exit and abort ---

enum { MAX_HANDLERS = 64 };
static struct {
    void (*fn)(void *);
    void *arg;
    int plain;
} handlers[MAX_HANDLERS];
static int nhandlers;
static os_unfair_lock handler_lock;

YCL_EXPORT int __cxa_atexit(void (*fn)(void *), void *arg, void *dso) {
    (void)dso;
    os_unfair_lock_lock(&handler_lock);
    int ok = nhandlers < MAX_HANDLERS;
    if (ok) {
        handlers[nhandlers].fn = fn;
        handlers[nhandlers].arg = arg;
        handlers[nhandlers++].plain = 0;
    }
    os_unfair_lock_unlock(&handler_lock);
    return ok ? 0 : -1;
}

YCL_EXPORT int atexit(void (*fn)(void)) {
    os_unfair_lock_lock(&handler_lock);
    int ok = nhandlers < MAX_HANDLERS;
    if (ok) {
        handlers[nhandlers].fn = (void (*)(void *))fn;
        handlers[nhandlers].arg = 0;
        handlers[nhandlers++].plain = 1;
    }
    os_unfair_lock_unlock(&handler_lock);
    return ok ? 0 : -1;
}

YCL_EXPORT void exit(int status) {
    for (;;) {
        os_unfair_lock_lock(&handler_lock);
        if (nhandlers == 0) {
            os_unfair_lock_unlock(&handler_lock);
            break;
        }
        nhandlers--;
        void (*fn)(void *) = handlers[nhandlers].fn;
        void *arg = handlers[nhandlers].arg;
        int plain = handlers[nhandlers].plain;
        os_unfair_lock_unlock(&handler_lock);
        if (plain) ((void (*)(void))fn)();
        else fn(arg);
    }
    ycl_stdio_flush_all();
    _exit(status);
}

YCL_EXPORT void abort(void) {
    kill(getpid(), 6 /* SIGABRT */);
    _exit(134);
}

YCL_EXPORT void __stack_chk_fail(void) {
    static const char message[] = "stack smashing detected\n";
    write(2, message, sizeof message - 1);
    abort();
}
