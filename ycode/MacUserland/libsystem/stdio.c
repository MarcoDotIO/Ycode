// stdio.c - buffered streams of Ycode's libSystem (specs/macos/libsystem.md
// §4). Clean-room Ycode code from the C standard and POSIX descriptions.
// FILE keeps the public Darwin layout for the fields the SDK's inline
// macros read (see ycl.h).
#include "ycl.h"

enum { BUFSIZE = 4096 };
enum { IOFBF = 0, IOLBF = 1, IONBF = 2 };
#define EOF (-1)

YCL_EXPORT FILE __sF[3];
YCL_EXPORT FILE *__stdinp = &__sF[0];
YCL_EXPORT FILE *__stdoutp = &__sF[1];
YCL_EXPORT FILE *__stderrp = &__sF[2];

static os_unfair_lock list_lock;
static FILE *open_files;

static void lock_file(FILE *f) { os_unfair_lock_lock(&f->lock); }
static void unlock_file(FILE *f) { os_unfair_lock_unlock(&f->lock); }

static int is_terminal(int fd) {
    char termios[72];
    return ioctl(fd, 0x40487413ul /* TIOCGETA */, termios) == 0;
}

static void setup(FILE *f, int fd, int flags) {
    memset(f, 0, sizeof *f);
    f->_file = (short)fd;
    f->flags2 = flags | YCL_F_USED;
    f->ungot = -1;
    f->mode = IOFBF;
}

void ycl_stdio_init(void) {
    setup(&__sF[0], 0, YCL_F_READ | YCL_F_STATIC);
    setup(&__sF[1], 1, YCL_F_WRITE | YCL_F_STATIC);
    setup(&__sF[2], 2, YCL_F_WRITE | YCL_F_STATIC);
    __sF[2].mode = IONBF;
    if (is_terminal(1)) __sF[1].mode = IOLBF;
    if (is_terminal(0)) __sF[0].mode = IOLBF;
}

static int ensure_buffer(FILE *f) {
    if (f->buf) return 0;
    if (f->mode == IONBF) {
        f->buf = f->small;
        f->size = 1;
        return 0;
    }
    f->buf = malloc(BUFSIZE);
    if (!f->buf) {
        f->buf = f->small;
        f->size = 1;
        f->mode = IONBF;
        return 0;
    }
    f->size = BUFSIZE;
    f->flags2 |= YCL_F_OWNBUF;
    return 0;
}

static int write_all(FILE *f, const unsigned char *p, size_t n) {
    while (n) {
        ssize_t w = write(f->_file, p, n);
        if (w < 0) {
            if (ycl_errno == YCL_EINTR) continue;
            f->_flags |= YCL_SERR;
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int flush_locked(FILE *f) {
    f->_w = 0;
    if (f->lastop == 2 && f->len) {
        uint32_t n = f->len;
        f->len = 0;
        if (write_all(f, f->buf, n)) return EOF;
    } else if (f->lastop == 1) {
        // Drop read-ahead: move the descriptor back to the logical position.
        off_t back = (off_t)(f->len - f->pos) + (f->ungot >= 0 ? 1 : 0);
        if (back) lseek(f->_file, -back, YCL_SEEK_CUR);
        f->len = f->pos = 0;
        f->ungot = -1;
    }
    f->lastop = 0;
    return 0;
}

static size_t write_locked(FILE *f, const unsigned char *p, size_t n) {
    if (!(f->flags2 & YCL_F_WRITE)) {
        f->_flags |= YCL_SERR;
        ycl_errno = YCL_EBADF;
        return 0;
    }
    if (f->lastop == 1) flush_locked(f);
    f->lastop = 2;
    ensure_buffer(f);
    if (f->mode == IONBF) {
        if (write_all(f, p, n)) return 0;
        return n;
    }
    size_t done = 0;
    while (done < n) {
        if (f->len == f->size && flush_locked(f)) return done;
        f->lastop = 2;
        size_t room = f->size - f->len, k = n - done < room ? n - done : room;
        memcpy(f->buf + f->len, p + done, k);
        f->len += (uint32_t)k;
        done += k;
    }
    if (f->mode == IOLBF) {
        for (size_t i = 0; i < n; i++)
            if (p[i] == '\n') {
                if (flush_locked(f)) return n;
                break;
            }
    }
    return n;
}

static int fill_locked(FILE *f) {
    if (f->lastop == 2) flush_locked(f);
    f->lastop = 1;
    ensure_buffer(f);
    // Reading a line-buffered or unbuffered stream flushes stdout first.
    if (f == &__sF[0] && __sF[1].lastop == 2 && f != &__sF[1]) {
        lock_file(&__sF[1]);
        flush_locked(&__sF[1]);
        unlock_file(&__sF[1]);
    }
    for (;;) {
        ssize_t r = read(f->_file, f->buf, f->size);
        if (r < 0 && ycl_errno == YCL_EINTR) continue;
        if (r < 0) {
            f->_flags |= YCL_SERR;
            return EOF;
        }
        if (r == 0) {
            f->_flags |= YCL_SEOF;
            return EOF;
        }
        f->len = (uint32_t)r;
        f->pos = 0;
        return 0;
    }
}

static int getc_locked(FILE *f) {
    if (!(f->flags2 & YCL_F_READ)) {
        f->_flags |= YCL_SERR;
        return EOF;
    }
    if (f->ungot >= 0) {
        int c = f->ungot;
        f->ungot = -1;
        return c;
    }
    if (f->lastop != 1 || f->pos >= f->len) {
        if (fill_locked(f)) return EOF;
    }
    return f->buf[f->pos++];
}

// --- the slow paths of the SDK's inline macros ---

YCL_EXPORT int __srget(FILE *f) {
    f->_r = 0;
    return getc_locked(f);
}

YCL_EXPORT int __swbuf(int c, FILE *f) {
    f->_w = 0;
    unsigned char b = (unsigned char)c;
    return write_locked(f, &b, 1) == 1 ? b : EOF;
}

// --- public functions ---

YCL_EXPORT int fflush(FILE *f) {
    if (!f) {
        ycl_stdio_flush_all();
        return 0;
    }
    lock_file(f);
    int r = flush_locked(f);
    unlock_file(f);
    return r;
}

void ycl_stdio_flush_all(void) {
    for (int i = 0; i < 3; i++) fflush(&__sF[i]);
    os_unfair_lock_lock(&list_lock);
    for (FILE *f = open_files; f; f = f->next) {
        lock_file(f);
        flush_locked(f);
        unlock_file(f);
    }
    os_unfair_lock_unlock(&list_lock);
}

static int parse_mode(const char *mode, int *oflags, int *fflags) {
    int plus = 0;
    for (const char *m = mode + 1; *m; m++)
        if (*m == '+') plus = 1;
    switch (mode[0]) {
    case 'r':
        *oflags = plus ? YCL_O_RDWR : YCL_O_RDONLY;
        *fflags = YCL_F_READ | (plus ? YCL_F_WRITE : 0);
        break;
    case 'w':
        *oflags = (plus ? YCL_O_RDWR : YCL_O_WRONLY) | YCL_O_CREAT | YCL_O_TRUNC;
        *fflags = YCL_F_WRITE | (plus ? YCL_F_READ : 0);
        break;
    case 'a':
        *oflags = (plus ? YCL_O_RDWR : YCL_O_WRONLY) | YCL_O_CREAT | YCL_O_APPEND;
        *fflags = YCL_F_WRITE | YCL_F_APPEND | (plus ? YCL_F_READ : 0);
        break;
    default:
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    for (const char *m = mode + 1; *m; m++) {
        if (*m == 'x') *oflags |= YCL_O_EXCL;
        if (*m == 'e') *oflags |= YCL_O_CLOEXEC;
    }
    return 0;
}

static FILE *new_file(int fd, int fflags) {
    FILE *f = malloc(sizeof *f);
    if (!f) {
        ycl_errno = YCL_ENOMEM;
        return 0;
    }
    setup(f, fd, fflags);
    os_unfair_lock_lock(&list_lock);
    f->next = open_files;
    open_files = f;
    os_unfair_lock_unlock(&list_lock);
    return f;
}

YCL_EXPORT FILE *fopen(const char *path, const char *mode) {
    int oflags, fflags;
    if (parse_mode(mode, &oflags, &fflags)) return 0;
    int fd = open(path, oflags, 0666);
    if (fd < 0) return 0;
    FILE *f = new_file(fd, fflags);
    if (!f) close(fd);
    return f;
}

YCL_EXPORT FILE *fdopen(int fd, const char *mode) {
    int oflags, fflags;
    if (parse_mode(mode, &oflags, &fflags)) return 0;
    return new_file(fd, fflags);
}

YCL_EXPORT int fclose(FILE *f) {
    lock_file(f);
    int r = flush_locked(f);
    if (close(f->_file) != 0) r = EOF;
    if (f->flags2 & YCL_F_OWNBUF) free(f->buf);
    f->buf = 0;
    unlock_file(f);
    if (f->flags2 & YCL_F_STATIC) {
        f->flags2 = YCL_F_STATIC;
        return r;
    }
    os_unfair_lock_lock(&list_lock);
    for (FILE **p = &open_files; *p; p = &(*p)->next)
        if (*p == f) {
            *p = f->next;
            break;
        }
    os_unfair_lock_unlock(&list_lock);
    free(f);
    return r;
}

YCL_EXPORT size_t fwrite(const void *p, size_t size, size_t count, FILE *f) {
    if (!size || !count) return 0;
    lock_file(f);
    size_t n = write_locked(f, p, size * count);
    unlock_file(f);
    return n / size;
}

YCL_EXPORT size_t fread(void *p, size_t size, size_t count, FILE *f) {
    size_t want = size * count, got = 0;
    if (!want) return 0;
    unsigned char *out = p;
    lock_file(f);
    while (got < want) {
        if (f->ungot >= 0) {
            out[got++] = (unsigned char)f->ungot;
            f->ungot = -1;
            continue;
        }
        if (f->lastop != 1 || f->pos >= f->len) {
            if (!(f->flags2 & YCL_F_READ) || fill_locked(f)) break;
        }
        size_t k = f->len - f->pos < want - got ? f->len - f->pos : want - got;
        memcpy(out + got, f->buf + f->pos, k);
        f->pos += (uint32_t)k;
        got += k;
    }
    unlock_file(f);
    return got / size;
}

YCL_EXPORT int fgetc(FILE *f) {
    lock_file(f);
    int c = getc_locked(f);
    unlock_file(f);
    return c;
}
YCL_EXPORT int getc(FILE *f) { return fgetc(f); }
YCL_EXPORT int getchar(void) { return fgetc(__stdinp); }
YCL_EXPORT int getc_unlocked(FILE *f) { return getc_locked(f); }
YCL_EXPORT int getchar_unlocked(void) { return getc_locked(__stdinp); }

YCL_EXPORT int ungetc(int c, FILE *f) {
    if (c == EOF) return EOF;
    lock_file(f);
    f->ungot = (unsigned char)c;
    f->_flags &= ~YCL_SEOF;
    unlock_file(f);
    return (unsigned char)c;
}

YCL_EXPORT char *fgets(char *s, int n, FILE *f) {
    if (n <= 0) return 0;
    int i = 0;
    lock_file(f);
    while (i < n - 1) {
        int c = getc_locked(f);
        if (c == EOF) break;
        s[i++] = (char)c;
        if (c == '\n') break;
    }
    unlock_file(f);
    if (i == 0) return 0;
    s[i] = 0;
    return s;
}

YCL_EXPORT ssize_t getdelim(char **line, size_t *cap, int delim, FILE *f) {
    if (!line || !cap) {
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    size_t n = 0;
    lock_file(f);
    for (;;) {
        int c = getc_locked(f);
        if (c == EOF) break;
        if (n + 2 > *cap || !*line) {
            size_t want = *cap ? *cap * 2 : 128;
            char *grown = realloc(*line, want);
            if (!grown) {
                unlock_file(f);
                return -1;
            }
            *line = grown;
            *cap = want;
        }
        (*line)[n++] = (char)c;
        if (c == delim) break;
    }
    unlock_file(f);
    if (n == 0) return -1;
    (*line)[n] = 0;
    return (ssize_t)n;
}
YCL_EXPORT ssize_t getline(char **line, size_t *cap, FILE *f) { return getdelim(line, cap, '\n', f); }

YCL_EXPORT int fputc(int c, FILE *f) {
    unsigned char b = (unsigned char)c;
    lock_file(f);
    size_t n = write_locked(f, &b, 1);
    unlock_file(f);
    return n == 1 ? b : EOF;
}
YCL_EXPORT int putc(int c, FILE *f) { return fputc(c, f); }
YCL_EXPORT int putchar(int c) { return fputc(c, __stdoutp); }
YCL_EXPORT int putc_unlocked(int c, FILE *f) {
    unsigned char b = (unsigned char)c;
    return write_locked(f, &b, 1) == 1 ? b : EOF;
}
YCL_EXPORT int putchar_unlocked(int c) { return putc_unlocked(c, __stdoutp); }

YCL_EXPORT int fputs(const char *s, FILE *f) {
    size_t n = strlen(s);
    lock_file(f);
    size_t w = write_locked(f, (const unsigned char *)s, n);
    unlock_file(f);
    return w == n ? 0 : EOF;
}

YCL_EXPORT int puts(const char *s) {
    FILE *f = __stdoutp;
    size_t n = strlen(s);
    lock_file(f);
    size_t w = write_locked(f, (const unsigned char *)s, n);
    size_t nl = write_locked(f, (const unsigned char *)"\n", 1);
    unlock_file(f);
    return w == n && nl == 1 ? 0 : EOF;
}

YCL_EXPORT int feof(FILE *f) { return (f->_flags & YCL_SEOF) != 0; }
YCL_EXPORT int ferror(FILE *f) { return (f->_flags & YCL_SERR) != 0; }
YCL_EXPORT void clearerr(FILE *f) { f->_flags &= ~(YCL_SEOF | YCL_SERR); }
YCL_EXPORT int fileno(FILE *f) { return f->_file; }
YCL_EXPORT void flockfile(FILE *f) { lock_file(f); }
YCL_EXPORT void funlockfile(FILE *f) { unlock_file(f); }

YCL_EXPORT int setvbuf(FILE *f, char *buf, int mode, size_t size) {
    lock_file(f);
    flush_locked(f);
    if (f->flags2 & YCL_F_OWNBUF) free(f->buf);
    f->flags2 &= ~YCL_F_OWNBUF;
    f->buf = 0;
    f->mode = mode;
    if (mode != IONBF && buf && size) {
        f->buf = (unsigned char *)buf;
        f->size = (uint32_t)size;
    }
    unlock_file(f);
    return 0;
}
YCL_EXPORT void setbuf(FILE *f, char *buf) { setvbuf(f, buf, buf ? IOFBF : IONBF, BUFSIZE); }
YCL_EXPORT void setlinebuf(FILE *f) { setvbuf(f, 0, IOLBF, 0); }

YCL_EXPORT int fseeko(FILE *f, off_t offset, int whence) {
    lock_file(f);
    if (whence == YCL_SEEK_CUR && f->lastop == 1) offset -= (off_t)(f->len - f->pos) + (f->ungot >= 0 ? 1 : 0);
    f->ungot = -1;
    if (f->lastop == 1) f->len = f->pos = 0, f->lastop = 0;
    flush_locked(f);
    off_t r = lseek(f->_file, offset, whence);
    if (r >= 0) f->_flags &= ~YCL_SEOF;
    unlock_file(f);
    return r < 0 ? -1 : 0;
}
YCL_EXPORT int fseek(FILE *f, long offset, int whence) { return fseeko(f, offset, whence); }
YCL_EXPORT off_t ftello(FILE *f) {
    lock_file(f);
    off_t r = lseek(f->_file, 0, YCL_SEEK_CUR);
    if (r >= 0 && f->lastop == 1) r -= (off_t)(f->len - f->pos) + (f->ungot >= 0 ? 1 : 0);
    if (r >= 0 && f->lastop == 2) r += f->len;
    unlock_file(f);
    return r;
}
YCL_EXPORT long ftell(FILE *f) { return (long)ftello(f); }
YCL_EXPORT void rewind(FILE *f) {
    fseeko(f, 0, YCL_SEEK_SET);
    clearerr(f);
}

// --- formatted output ---

static void file_sink(void *context, const char *bytes, size_t n) { write_locked(context, (const unsigned char *)bytes, n); }

YCL_EXPORT int vfprintf(FILE *f, const char *fmt, va_list args) {
    lock_file(f);
    int n = ycl_vformat(file_sink, f, fmt, args);
    int bad = f->_flags & YCL_SERR;
    unlock_file(f);
    return bad ? -1 : n;
}
YCL_EXPORT int fprintf(FILE *f, const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    int n = vfprintf(f, fmt, a);
    va_end(a);
    return n;
}
YCL_EXPORT int vprintf(const char *fmt, va_list args) { return vfprintf(__stdoutp, fmt, args); }
YCL_EXPORT int printf(const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    int n = vfprintf(__stdoutp, fmt, a);
    va_end(a);
    return n;
}

struct buffer_sink {
    char *p;
    size_t cap, len;
};
static void buffer_put(void *context, const char *bytes, size_t n) {
    struct buffer_sink *b = context;
    for (size_t i = 0; i < n; i++, b->len++)
        if (b->len + 1 < b->cap) b->p[b->len] = bytes[i];
}

YCL_EXPORT int vsnprintf(char *s, size_t n, const char *fmt, va_list args) {
    struct buffer_sink b = {s, n, 0};
    int r = ycl_vformat(buffer_put, &b, fmt, args);
    if (n) s[b.len < n ? b.len : n - 1] = 0;
    return r;
}
YCL_EXPORT int snprintf(char *s, size_t n, const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    int r = vsnprintf(s, n, fmt, a);
    va_end(a);
    return r;
}
YCL_EXPORT int vsprintf(char *s, const char *fmt, va_list args) { return vsnprintf(s, (size_t)-1 >> 1, fmt, args); }
YCL_EXPORT int sprintf(char *s, const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    int r = vsprintf(s, fmt, a);
    va_end(a);
    return r;
}

struct grow_sink {
    char *p;
    size_t cap, len;
    int failed;
};
static void grow_put(void *context, const char *bytes, size_t n) {
    struct grow_sink *g = context;
    if (g->failed) return;
    if (g->len + n + 1 > g->cap) {
        size_t want = (g->len + n + 1) * 2;
        char *p = realloc(g->p, want);
        if (!p) {
            g->failed = 1;
            return;
        }
        g->p = p;
        g->cap = want;
    }
    memcpy(g->p + g->len, bytes, n);
    g->len += n;
}
YCL_EXPORT int vasprintf(char **out, const char *fmt, va_list args) {
    struct grow_sink g = {0, 0, 0, 0};
    int n = ycl_vformat(grow_put, &g, fmt, args);
    if (!g.failed && !g.p) g.p = malloc(1);
    if (g.failed || !g.p) {
        free(g.p);
        *out = 0;
        return -1;
    }
    g.p[g.len] = 0;
    *out = g.p;
    return n;
}
YCL_EXPORT int asprintf(char **out, const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    int n = vasprintf(out, fmt, a);
    va_end(a);
    return n;
}

struct fd_sink {
    int fd;
};
static void fd_put(void *context, const char *bytes, size_t n) {
    struct fd_sink *s = context;
    while (n) {
        ssize_t w = write(s->fd, bytes, n);
        if (w <= 0) return;
        bytes += w;
        n -= (size_t)w;
    }
}
YCL_EXPORT int vdprintf(int fd, const char *fmt, va_list args) {
    struct fd_sink s = {fd};
    return ycl_vformat(fd_put, &s, fmt, args);
}
YCL_EXPORT int dprintf(int fd, const char *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    int n = vdprintf(fd, fmt, a);
    va_end(a);
    return n;
}

YCL_EXPORT void perror(const char *s) {
    int e = ycl_errno;
    if (s && *s) fprintf(__stderrp, "%s: %s\n", s, strerror(e));
    else fprintf(__stderrp, "%s\n", strerror(e));
}

YCL_EXPORT int remove(const char *path) { return unlink(path); }

// Fortified variants (the SDK's _FORTIFY_SOURCE forms).
YCL_EXPORT int __sprintf_chk(char *s, int flags, size_t size, const char *fmt, ...) {
    (void)flags;
    va_list a;
    va_start(a, fmt);
    int r = vsnprintf(s, size, fmt, a);
    va_end(a);
    if ((size_t)r >= size) abort();
    return r;
}
YCL_EXPORT int __snprintf_chk(char *s, size_t n, int flags, size_t size, const char *fmt, ...) {
    (void)flags;
    if (n > size) abort();
    va_list a;
    va_start(a, fmt);
    int r = vsnprintf(s, n, fmt, a);
    va_end(a);
    return r;
}
YCL_EXPORT int __vsnprintf_chk(char *s, size_t n, int flags, size_t size, const char *fmt, va_list args) {
    (void)flags;
    if (n > size) abort();
    return vsnprintf(s, n, fmt, args);
}
YCL_EXPORT int __vsprintf_chk(char *s, int flags, size_t size, const char *fmt, va_list args) {
    (void)flags;
    int r = vsnprintf(s, size, fmt, args);
    if ((size_t)r >= size) abort();
    return r;
}
