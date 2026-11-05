// dirent.c - directory streams for Ycode's libSystem
// (specs/macos/libsystem.md §12). Clean-room Ycode code from POSIX
// opendir(3)/readdir(3) and the public Darwin layouts of DIR and struct
// dirent (<dirent.h>, <sys/dirent.h>: 64-bit inode numbers, d_reclen,
// d_namlen, d_type, 1024-byte d_name). Entries come from the kernel's
// getdirentries64 (libsystem_kernel's __getdirentries64), which returns
// records in that same layout.
#include "ycl.h"

struct ycl_dirent {
    uint64_t d_ino;
    uint64_t d_seekoff;
    uint16_t d_reclen;
    uint16_t d_namlen;
    uint8_t d_type;
    char d_name[1024];
};

typedef struct {
    int fd;              // __dd_fd (the SDK's dirfd macro reads it)
    size_t loc;          // offset of the next record in buf
    size_t size;         // bytes in buf
    char *buf;
    int len;             // buf capacity
    long seek;           // the kernel's position cookie after this buffer
    long padding;        // entries returned so far (telldir)
    int flags;
    pthread_mutex_t lock;
    void *td;
} DIR;

enum { DIR_BUFFER = 8192, O_DIRECTORY = 0x100000 };

ssize_t __getdirentries64(int, void *, size_t, off_t *);
int fstat(int, void *);
int fcntl(int, int, ...);

YCL_EXPORT DIR *fdopendir(int fd) {
    DIR *d = calloc(1, sizeof *d);
    char *buf = malloc(DIR_BUFFER);
    if (!d || !buf) {
        free(d);
        free(buf);
        ycl_errno = YCL_ENOMEM;
        return 0;
    }
    d->fd = fd;
    d->buf = buf;
    d->len = DIR_BUFFER;
    pthread_mutex_init(&d->lock, 0);
    fcntl(fd, 2 /* F_SETFD */, 1 /* FD_CLOEXEC */);
    return d;
}

YCL_EXPORT DIR *opendir(const char *path) {
    int fd = open(path, YCL_O_RDONLY | O_DIRECTORY | YCL_O_CLOEXEC);
    if (fd < 0) return 0;
    DIR *d = fdopendir(fd);
    if (!d) close(fd);
    return d;
}

YCL_EXPORT int closedir(DIR *d) {
    if (!d) {
        ycl_errno = YCL_EBADF;
        return -1;
    }
    int r = close(d->fd);
    pthread_mutex_destroy(&d->lock);
    free(d->buf);
    free(d);
    return r;
}

// The next record, or 0 at the end (errno unchanged) or on error.
static struct ycl_dirent *next_locked(DIR *d) {
    for (;;) {
        if (d->loc >= d->size) {
            off_t base = 0;
            ssize_t n = __getdirentries64(d->fd, d->buf, (size_t)d->len, &base);
            if (n <= 0) return 0;
            d->size = (size_t)n;
            d->loc = 0;
            d->seek = (long)base;
        }
        struct ycl_dirent *e = (struct ycl_dirent *)(d->buf + d->loc);
        if (e->d_reclen == 0 || d->loc + e->d_reclen > d->size) {
            d->size = 0;  // a malformed buffer: read more
            continue;
        }
        d->loc += e->d_reclen;
        if (e->d_ino == 0) continue;  // a deleted entry
        return e;
    }
}

YCL_EXPORT struct ycl_dirent *readdir(DIR *d) {
    pthread_mutex_lock(&d->lock);
    struct ycl_dirent *e = next_locked(d);
    if (e) d->padding++;
    pthread_mutex_unlock(&d->lock);
    return e;
}

YCL_EXPORT int readdir_r(DIR *d, struct ycl_dirent *entry, struct ycl_dirent **result) {
    int saved = ycl_errno;
    ycl_errno = 0;
    pthread_mutex_lock(&d->lock);
    struct ycl_dirent *e = next_locked(d);
    if (e) d->padding++;
    if (e) memcpy(entry, e, e->d_reclen < sizeof *entry ? e->d_reclen : sizeof *entry);
    pthread_mutex_unlock(&d->lock);
    int error = ycl_errno;
    ycl_errno = saved;
    *result = e ? entry : 0;
    return e ? 0 : error;
}

YCL_EXPORT void rewinddir(DIR *d) {
    pthread_mutex_lock(&d->lock);
    lseek(d->fd, 0, YCL_SEEK_SET);
    d->loc = d->size = 0;
    d->seek = 0;
    d->padding = 0;
    pthread_mutex_unlock(&d->lock);
}

// A position is the number of entries returned since the stream was
// opened or rewound (kept in the padding word); seekdir re-reads from the
// start and skips that many, which is exact for a directory that does not
// change meanwhile.
YCL_EXPORT long telldir(DIR *d) {
    pthread_mutex_lock(&d->lock);
    long r = d->padding;
    pthread_mutex_unlock(&d->lock);
    return r;
}

YCL_EXPORT void seekdir(DIR *d, long position) {
    pthread_mutex_lock(&d->lock);
    lseek(d->fd, 0, YCL_SEEK_SET);
    d->loc = d->size = 0;
    d->padding = 0;
    while (d->padding < position && next_locked(d)) d->padding++;
    pthread_mutex_unlock(&d->lock);
}

YCL_EXPORT int dirfd(DIR *d) { return d->fd; }

YCL_EXPORT int alphasort(const struct ycl_dirent **a, const struct ycl_dirent **b) {
    return strcmp((*a)->d_name, (*b)->d_name);
}

void qsort(void *, size_t, size_t, int (*)(const void *, const void *));

YCL_EXPORT int scandir(const char *path, struct ycl_dirent ***out, int (*select)(const struct ycl_dirent *),
                       int (*compare)(const struct ycl_dirent **, const struct ycl_dirent **)) {
    DIR *d = opendir(path);
    if (!d) return -1;
    struct ycl_dirent **list = 0;
    size_t n = 0, cap = 0;
    struct ycl_dirent *e;
    while ((e = readdir(d))) {
        if (select && !select(e)) continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 16;
            struct ycl_dirent **grown = realloc(list, cap * sizeof *grown);
            if (!grown) goto fail;
            list = grown;
        }
        size_t size = e->d_reclen < sizeof *e ? e->d_reclen : sizeof *e;
        struct ycl_dirent *copy = malloc(sizeof *copy);
        if (!copy) goto fail;
        memcpy(copy, e, size);
        list[n++] = copy;
    }
    closedir(d);
    if (compare && n > 1) qsort(list, n, sizeof *list, (int (*)(const void *, const void *))compare);
    *out = list;
    return (int)n;
fail:
    for (size_t i = 0; i < n; i++) free(list[i]);
    free(list);
    closedir(d);
    ycl_errno = YCL_ENOMEM;
    return -1;
}
