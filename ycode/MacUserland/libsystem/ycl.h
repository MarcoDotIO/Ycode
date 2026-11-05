// ycl.h - internal declarations of Ycode's libSystem for macOS programs
// (specs/macos/libsystem.md). Freestanding: no SDK headers. The C types and
// the FILE layout are the public Darwin arm64 ABI (interoperability facts);
// everything else is Ycode's own.
#ifndef YCL_H
#define YCL_H

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define YCL_EXPORT __attribute__((visibility("default")))
#define YCL_NORETURN __attribute__((noreturn))

typedef long ssize_t;
typedef int64_t off_t;
typedef int pid_t;
typedef uint16_t mode_t;
typedef uint32_t os_unfair_lock;

// --- errno values (public <sys/errno.h>) ---
enum {
    YCL_EPERM = 1, YCL_ENOENT = 2, YCL_EINTR = 4, YCL_EIO = 5, YCL_EBADF = 9, YCL_ENOMEM = 12, YCL_EACCES = 13,
    YCL_EFAULT = 14, YCL_EBUSY = 16, YCL_EEXIST = 17, YCL_ENOTDIR = 20, YCL_EISDIR = 21, YCL_EINVAL = 22,
    YCL_ENFILE = 23, YCL_EMFILE = 24, YCL_ENOTTY = 25, YCL_EFBIG = 27, YCL_ENOSPC = 28, YCL_ESPIPE = 29,
    YCL_EROFS = 30, YCL_EPIPE = 32, YCL_EDOM = 33, YCL_ERANGE = 34, YCL_EAGAIN = 35, YCL_ETIMEDOUT = 60,
    YCL_ENAMETOOLONG = 63, YCL_ENOTEMPTY = 66, YCL_ENOSYS = 78, YCL_EOVERFLOW = 84, YCL_ECANCELED = 89,
    YCL_ENOTSUP = 45,
};

// --- open flags and others (public <fcntl.h>, <sys/mman.h>, <unistd.h>) ---
enum {
    YCL_O_RDONLY = 0, YCL_O_WRONLY = 1, YCL_O_RDWR = 2, YCL_O_APPEND = 0x8, YCL_O_CREAT = 0x200, YCL_O_TRUNC = 0x400,
    YCL_O_EXCL = 0x800, YCL_O_CLOEXEC = 0x1000000,
};
enum { YCL_PROT_READ = 1, YCL_PROT_WRITE = 2, YCL_MAP_PRIVATE = 2, YCL_MAP_ANON = 0x1000 };
#define YCL_MAP_FAILED ((void *)-1)
enum { YCL_SEEK_SET = 0, YCL_SEEK_CUR = 1, YCL_SEEK_END = 2 };

struct ycl_timespec {
    long tv_sec;
    long tv_nsec;
};
struct ycl_timeval {
    long tv_sec;
    int tv_usec;
};

// --- the host libraries Ycode's libSystem re-exports (libsystem_kernel,
//     libsystem_platform, libsystem_pthread) ---
int *__error(void);
#define ycl_errno (*__error())
ssize_t read(int, void *, size_t);
ssize_t write(int, const void *, size_t);
int open(const char *, int, ...);
int close(int);
off_t lseek(int, off_t, int);
int ioctl(int, unsigned long, ...);
int unlink(const char *);
void *mmap(void *, size_t, int, int, int, off_t);
int munmap(void *, size_t);
int getpid(void);
int kill(int, int);
void _exit(int) YCL_NORETURN;
int __gettimeofday(struct ycl_timeval *, void *, uint64_t *);
int __sysctl(int *, unsigned, void *, size_t *, void *, size_t);
int getentropy(void *, size_t);
uint64_t mach_absolute_time(void);
int mach_timebase_info(void *);
int __semwait_signal(int, int, int, int, int64_t, int32_t);
int abort_with_payload(uint32_t, uint64_t, void *, uint32_t, const char *, uint64_t);
int __sigaction(int, const void *, void *);
int sigprocmask(int, const void *, void *);
void os_unfair_lock_lock(os_unfair_lock *);
void os_unfair_lock_unlock(os_unfair_lock *);
int os_unfair_lock_trylock(os_unfair_lock *);
void *_platform_memmove(void *, const void *, size_t);
void *_platform_memset(void *, int, size_t);
int _platform_memcmp(const void *, const void *, size_t);
size_t _platform_strlen(const char *);
void __libkernel_init(const void *, char **, char **, const void *);
void __libplatform_init(void *, char **, char **, const void *);
int __pthread_init(const void *, char **, char **, const void *);
void __pthread_late_init(char **, char **, const void *);

typedef struct ycl_pthread_opaque *pthread_t;
typedef struct {
    long sig;
    char opaque[56];
} pthread_mutex_t;
typedef struct {
    long sig;
    char opaque[40];
} pthread_cond_t;
#define YCL_PTHREAD_MUTEX_INITIALIZER {0x32AAABA7, {0}}
#define YCL_PTHREAD_COND_INITIALIZER {0x3CB0B1BB, {0}}
int pthread_create(pthread_t *, const void *, void *(*)(void *), void *);
int pthread_detach(pthread_t);
int pthread_mutex_lock(pthread_mutex_t *);
int pthread_mutex_unlock(pthread_mutex_t *);
int pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *);
int pthread_cond_timedwait_relative_np(pthread_cond_t *, pthread_mutex_t *, const struct ycl_timespec *);
int pthread_cond_signal(pthread_cond_t *);
int pthread_cond_broadcast(pthread_cond_t *);
int sched_yield(void);
int pthread_mutex_init(pthread_mutex_t *, const void *);
int pthread_mutex_destroy(pthread_mutex_t *);
int pthread_cond_init(pthread_cond_t *, const void *);
int pthread_cond_destroy(pthread_cond_t *);
int mach_wait_until(uint64_t deadline);

// --- libSystem internals ---
void *malloc(size_t);
void *calloc(size_t, size_t);
void *realloc(void *, size_t);
void free(void *);
void ycl_malloc_init(void);
void ycl_stdio_flush_all(void);
void ycl_stdio_init(void);
void ycl_dispatch_init(void);
void ycl_ctype_init(void);
void exit(int) YCL_NORETURN;
void abort(void) YCL_NORETURN;
size_t strlen(const char *);
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
void *memset(void *, int, size_t);
int memcmp(const void *, const void *, size_t);
int strcmp(const char *, const char *);
int strncmp(const char *, const char *, size_t);
char *strerror(int);
char *strrchr(const char *, int);
char *strchr(const char *, int);
char ***_NSGetEnviron(void);
size_t strlcpy(char *, const char *, size_t);
int snprintf(char *, size_t, const char *, ...);
uint64_t ycl_now_ns(void);  // monotonic nanoseconds

// The formatting engine (format.c): calls `sink` for each run of output.
typedef void (*ycl_sink)(void *context, const char *bytes, size_t count);
int ycl_vformat(ycl_sink sink, void *context, const char *format, va_list args);

// FILE: the public Darwin layout (152 bytes). Ycode keeps _r and _w at 0 so
// the header's inline getc/putc macros always call __srget/__swbuf; the
// remaining bytes are Ycode's own fields.
typedef struct ycl_file {
    unsigned char *_p;   // 0
    int _r;              // 8
    int _w;              // 12
    short _flags;        // 16: __SEOF 0x20, __SERR 0x40 (read by feof/ferror macros)
    short _file;         // 18: the descriptor (read by fileno macros)
    unsigned char *buf;  // 24
    uint32_t size;       // 32: buffer capacity
    uint32_t len;        // 36: bytes in the buffer (write: pending; read: filled)
    uint32_t pos;        // 40: read position
    int mode;            // 44: _IOFBF 0, _IOLBF 1, _IONBF 2
    int lastop;          // 48: 0 none, 1 read, 2 write
    int ungot;           // 52: a pushed-back byte, or -1
    os_unfair_lock lock; // 56
    int flags2;          // 60: YCL_F_*
    struct ycl_file *next; // 64: the open-file list
    unsigned char small[2]; // 72
    char pad[6];         // 74
    void *owner;         // 80: the thread holding the (recursive) lock
    uint32_t depth;      // 88: its lock count
    char reserved[60];   // 92, to 152
} FILE;
enum { YCL_SEOF = 0x20, YCL_SERR = 0x40 };
enum { YCL_F_READ = 1, YCL_F_WRITE = 2, YCL_F_APPEND = 4, YCL_F_STATIC = 8, YCL_F_OWNBUF = 16, YCL_F_USED = 32 };
extern FILE *__stdinp, *__stdoutp, *__stderrp;

#endif
