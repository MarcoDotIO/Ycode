/*
 * simple.c - the _simple_* async-signal-safe printing helpers of Ycode's
 * libsystem_platform (weak-only surface, host-library-surface.md section 3).
 *
 * Clean-room Ycode code. Interface (Ycode's reading of the routine names;
 * nothing in the simulator runtime calls these except through the
 * libsystem_sim_platform_host interposition slots):
 *   void   _simple_dprintf(int fd, const char *fmt, ...);
 *   void   _simple_vdprintf(int fd, const char *fmt, va_list ap);
 *   _SIMPLE_STRING _simple_salloc(void);           NULL on failure
 *   int    _simple_sprintf(_SIMPLE_STRING b, const char *fmt, ...);   0 / -1
 *   int    _simple_vsprintf(_SIMPLE_STRING b, const char *fmt, va_list ap);
 *   int    _simple_sappend(_SIMPLE_STRING b, const char *str);         0 / -1
 *   void   _simple_sresize(_SIMPLE_STRING b);   re-sync after outside edits
 *   char  *_simple_string(_SIMPLE_STRING b);
 *   void   _simple_put(_SIMPLE_STRING b, int fd);
 *   void   _simple_putline(_SIMPLE_STRING b, int fd);  adds a newline
 *   void   _simple_sfree(_SIMPLE_STRING b);
 *   const char *_simple_getenv(const char *envp[], const char *var);
 *   void   _simple_asl_log(int level, const char *facility, const char *msg);
 *   void   _simple_asl_log_prog(int level, const char *facility,
 *                               const char *msg, const char *progname);
 * The ASL routines write "<progname>: <message>" lines to fd 2
 * (host-library-init.md section 7.4 allows this). The escaping variants
 * and the ASL message objects remain generated stubs.
 *
 * Supported conversions: %d %i %u %x %X %o %p %s %c %%, with the flags
 * '-' and '0', a width and a precision (numbers or '*'), and the length
 * modifiers hh h l ll q z t j. Anything else is copied verbatim.
 */
#include "yc_platform.h"

typedef __builtin_va_list yc_va_list;
#define yc_va_start(ap, last) __builtin_va_start(ap, last)
#define yc_va_end(ap) __builtin_va_end(ap)
#define yc_va_arg(ap, type) __builtin_va_arg(ap, type)

/* ---- output sinks ----------------------------------------------------- */

struct sink {
    void (*put)(struct sink *, const char *, yc_size_t);
    int failed;
};

static void emit(struct sink *s, const char *p, yc_size_t n)
{
    if (n)
        s->put(s, p, n);
}

static void emit_pad(struct sink *s, char c, int count)
{
    char buf[16];
    for (int i = 0; i < 16; i++)
        buf[i] = c;
    while (count > 0) {
        int n = count > 16 ? 16 : count;
        emit(s, buf, (yc_size_t)n);
        count -= n;
    }
}

/* ---- the formatter ---------------------------------------------------- */

static void format_number(struct sink *s, yc_u64 v, int negative, unsigned base, int upper,
                          int width, int precision, int left, int zero, const char *prefix)
{
    char digits[24];
    int nd = 0;
    const char *set = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    do {
        digits[nd++] = set[v % base];
        v /= base;
    } while (v);
    if (precision == 0 && nd == 1 && digits[0] == '0')
        nd = 0;
    int plen = (int)__yc_strlen(prefix) + (negative ? 1 : 0);
    int zeros = precision > nd ? precision - nd : 0;
    int total = plen + zeros + nd;
    if (zero && !left && precision < 0 && width > total) {
        zeros += width - total;
        total = width;
    }
    if (!left)
        emit_pad(s, ' ', width - total);
    if (negative)
        emit(s, "-", 1);
    emit(s, prefix, __yc_strlen(prefix));
    emit_pad(s, '0', zeros);
    while (nd)
        emit(s, &digits[--nd], 1);
    if (left)
        emit_pad(s, ' ', width - total);
}

static void format(struct sink *s, const char *fmt, yc_va_list ap)
{
    while (*fmt) {
        const char *start = fmt;
        while (*fmt && *fmt != '%')
            fmt++;
        emit(s, start, (yc_size_t)(fmt - start));
        if (!*fmt)
            break;
        const char *spec = fmt++;
        int left = 0, zero = 0, width = 0, precision = -1, lng = 0;
        for (;; fmt++) {
            if (*fmt == '-')
                left = 1;
            else if (*fmt == '0')
                zero = 1;
            else
                break;
        }
        if (*fmt == '*') {
            width = yc_va_arg(ap, int);
            if (width < 0) {
                left = 1;
                width = -width;
            }
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9')
                width = width * 10 + (*fmt++ - '0');
        }
        if (*fmt == '.') {
            fmt++;
            precision = 0;
            if (*fmt == '*') {
                precision = yc_va_arg(ap, int);
                fmt++;
            } else {
                while (*fmt >= '0' && *fmt <= '9')
                    precision = precision * 10 + (*fmt++ - '0');
            }
        }
        for (;; fmt++) {
            if (*fmt == 'h')
                lng = lng > 0 ? lng : lng - 1;
            else if (*fmt == 'l')
                lng = lng < 0 ? 1 : lng + 1;
            else if (*fmt == 'q' || *fmt == 'j')
                lng = 2;
            else if (*fmt == 'z' || *fmt == 't')
                lng = 1;
            else
                break;
        }
        char c = *fmt;
        if (c == 0) {
            emit(s, spec, (yc_size_t)(fmt - spec));
            break;
        }
        fmt++;
        switch (c) {
        case 'd':
        case 'i': {
            yc_i64 v = lng >= 2 ? yc_va_arg(ap, long long) : lng == 1 ? yc_va_arg(ap, long) : yc_va_arg(ap, int);
            if (lng == -1)
                v = (short)v;
            else if (lng <= -2)
                v = (signed char)v;
            yc_u64 mag = v < 0 ? (yc_u64)0 - (yc_u64)v : (yc_u64)v;
            format_number(s, mag, v < 0, 10, 0, width, precision, left, zero, "");
            break;
        }
        case 'u':
        case 'x':
        case 'X':
        case 'o': {
            yc_u64 v = lng >= 2 ? yc_va_arg(ap, unsigned long long)
                     : lng == 1 ? yc_va_arg(ap, unsigned long) : yc_va_arg(ap, unsigned int);
            if (lng == -1)
                v = (unsigned short)v;
            else if (lng <= -2)
                v = (unsigned char)v;
            unsigned base = c == 'u' ? 10 : c == 'o' ? 8 : 16;
            format_number(s, v, 0, base, c == 'X', width, precision, left, zero, "");
            break;
        }
        case 'p':
            format_number(s, (yc_u64)(yc_uintptr_t)yc_va_arg(ap, void *), 0, 16, 0, width, precision, left, 0, "0x");
            break;
        case 's': {
            const char *str = yc_va_arg(ap, const char *);
            if (str == YC_NULL)
                str = "(null)";
            yc_size_t n = 0;
            while (str[n] && (precision < 0 || n < (yc_size_t)precision))
                n++;
            if (!left)
                emit_pad(s, ' ', width - (int)n);
            emit(s, str, n);
            if (left)
                emit_pad(s, ' ', width - (int)n);
            break;
        }
        case 'c': {
            char ch = (char)yc_va_arg(ap, int);
            if (!left)
                emit_pad(s, ' ', width - 1);
            emit(s, &ch, 1);
            if (left)
                emit_pad(s, ' ', width - 1);
            break;
        }
        case '%':
            emit(s, "%", 1);
            break;
        default:
            emit(s, spec, (yc_size_t)(fmt - spec));
            break;
        }
    }
}

/* ---- file descriptor output ------------------------------------------ */

struct fd_sink {
    struct sink base;
    int fd;
    yc_size_t used;
    char buf[256];
};

static void fd_flush(struct fd_sink *f)
{
    const char *p = f->buf;
    yc_size_t n = f->used;
    while (n) {
        yc_ssize_t w = YC_KFN(write)(f->fd, p, n);
        if (w <= 0) {
            if (w < 0 && *YC_KFN(__error)() == YC_EINTR)
                continue;
            break;
        }
        p += w;
        n -= (yc_size_t)w;
    }
    f->used = 0;
}

static void fd_put(struct sink *s, const char *p, yc_size_t n)
{
    struct fd_sink *f = (struct fd_sink *)s;
    while (n) {
        yc_size_t room = sizeof f->buf - f->used;
        yc_size_t k = n < room ? n : room;
        for (yc_size_t i = 0; i < k; i++)
            f->buf[f->used + i] = p[i];
        f->used += k;
        p += k;
        n -= k;
        if (f->used == sizeof f->buf)
            fd_flush(f);
    }
}

YC_EXPORT void YC_FN(_simple_vdprintf)(int fd, const char *fmt, yc_va_list ap)
{
    struct fd_sink f;
    f.base.put = fd_put;
    f.base.failed = 0;
    f.fd = fd;
    f.used = 0;
    format(&f.base, fmt, ap);
    fd_flush(&f);
}

YC_EXPORT void YC_FN(_simple_dprintf)(int fd, const char *fmt, ...)
{
    yc_va_list ap;
    yc_va_start(ap, fmt);
    YC_FN(_simple_vdprintf)(fd, fmt, ap);
    yc_va_end(ap);
}

/* ---- growable strings ----------------------------------------------- */

struct yc_simple_string {
    char *buf;     /* NUL-terminated contents */
    yc_size_t len; /* bytes before the NUL */
    yc_size_t cap; /* usable bytes in buf, including the NUL */
    yc_size_t map; /* size of the mapping that holds buf (0: inline) */
    char inline_buf[];
};

#define HEADER_SIZE sizeof(struct yc_simple_string)

static void *map_pages(yc_size_t len)
{
    void *p = YC_KFN(mmap)(YC_NULL, len, YC_PROT_READ | YC_PROT_WRITE, YC_MAP_PRIVATE | YC_MAP_ANON, -1, 0);
    return (p == YC_MAP_FAILED) ? YC_NULL : p;
}

YC_EXPORT struct yc_simple_string *YC_FN(_simple_salloc)(void)
{
    struct yc_simple_string *b = map_pages(YC_PAGE_SIZE);
    if (b == YC_NULL)
        return YC_NULL;
    b->buf = b->inline_buf;
    b->len = 0;
    b->cap = YC_PAGE_SIZE - HEADER_SIZE;
    b->map = 0;
    b->buf[0] = 0;
    return b;
}

static int reserve(struct yc_simple_string *b, yc_size_t extra)
{
    if (b->len + extra + 1 <= b->cap)
        return 0;
    yc_size_t want = b->cap * 2;
    while (want < b->len + extra + 1)
        want *= 2;
    want = (want + YC_PAGE_SIZE - 1) & ~(YC_PAGE_SIZE - 1);
    char *nb = map_pages(want);
    if (nb == YC_NULL)
        return -1;
    for (yc_size_t i = 0; i <= b->len; i++)
        nb[i] = b->buf[i];
    if (b->map)
        YC_KFN(munmap)(b->buf, b->map);
    b->buf = nb;
    b->cap = want;
    b->map = want;
    return 0;
}

struct str_sink {
    struct sink base;
    struct yc_simple_string *b;
};

static void str_put(struct sink *s, const char *p, yc_size_t n)
{
    struct str_sink *ss = (struct str_sink *)s;
    if (ss->base.failed || reserve(ss->b, n) != 0) {
        ss->base.failed = 1;
        return;
    }
    for (yc_size_t i = 0; i < n; i++)
        ss->b->buf[ss->b->len + i] = p[i];
    ss->b->len += n;
    ss->b->buf[ss->b->len] = 0;
}

YC_EXPORT int YC_FN(_simple_vsprintf)(struct yc_simple_string *b, const char *fmt, yc_va_list ap)
{
    struct str_sink s;
    s.base.put = str_put;
    s.base.failed = 0;
    s.b = b;
    format(&s.base, fmt, ap);
    return s.base.failed ? -1 : 0;
}

YC_EXPORT int YC_FN(_simple_sprintf)(struct yc_simple_string *b, const char *fmt, ...)
{
    yc_va_list ap;
    yc_va_start(ap, fmt);
    int r = YC_FN(_simple_vsprintf)(b, fmt, ap);
    yc_va_end(ap);
    return r;
}

YC_EXPORT int YC_FN(_simple_sappend)(struct yc_simple_string *b, const char *str)
{
    struct str_sink s;
    s.base.put = str_put;
    s.base.failed = 0;
    s.b = b;
    str_put(&s.base, str, __yc_strlen(str));
    return s.base.failed ? -1 : 0;
}

YC_EXPORT void YC_FN(_simple_sresize)(struct yc_simple_string *b)
{
    yc_size_t n = 0;
    while (n + 1 < b->cap && b->buf[n])
        n++;
    b->buf[n] = 0;
    b->len = n;
}

YC_EXPORT char *YC_FN(_simple_string)(struct yc_simple_string *b)
{
    return b->buf;
}

static void write_all(int fd, const char *p, yc_size_t n)
{
    struct fd_sink f;
    f.base.put = fd_put;
    f.base.failed = 0;
    f.fd = fd;
    f.used = 0;
    fd_put(&f.base, p, n);
    fd_flush(&f);
}

YC_EXPORT void YC_FN(_simple_put)(struct yc_simple_string *b, int fd)
{
    write_all(fd, b->buf, b->len);
}

YC_EXPORT void YC_FN(_simple_putline)(struct yc_simple_string *b, int fd)
{
    write_all(fd, b->buf, b->len);
    write_all(fd, "\n", 1);
}

YC_EXPORT void YC_FN(_simple_sfree)(struct yc_simple_string *b)
{
    if (b == YC_NULL)
        return;
    if (b->map)
        YC_KFN(munmap)(b->buf, b->map);
    YC_KFN(munmap)(b, YC_PAGE_SIZE);
}

YC_EXPORT const char *YC_FN(_simple_getenv)(const char *envp[], const char *var)
{
    if (envp == YC_NULL || var == YC_NULL)
        return YC_NULL;
    yc_size_t n = __yc_strlen(var);
    for (; *envp; envp++) {
        const char *e = *envp;
        yc_size_t i = 0;
        while (i < n && e[i] == var[i])
            i++;
        if (i == n && e[n] == '=')
            return e + n + 1;
    }
    return YC_NULL;
}

/* ---- simple ASL --------------------------------------------------------
 * The context lives in os_alloc_once slot 21 (LIBSYSTEM_PLATFORM_ASL) and
 * is set up by __libplatform_init (host-library-init.md section 1.3). */

struct asl_context {
    const char *progname;
    int fd;
    int enabled;
};

void *YC_FN(_os_alloc_once)(struct yc_alloc_once_slot *, yc_size_t, void (*)(void *));

static void asl_context_init(void *p)
{
    struct asl_context *c = p;
    c->progname = "unknown";
    c->fd = -1;
    c->enabled = 0;
}

static struct asl_context *asl_context(void)
{
    struct yc_alloc_once_slot *slot = &YC_KFN(_os_alloc_once_table)[YC_OS_ALLOC_ONCE_KEY_LIBSYSTEM_PLATFORM_ASL];
    if (__atomic_load_n(&slot->once, __ATOMIC_ACQUIRE) == ~0l)
        return slot->ptr;
    return YC_FN(_os_alloc_once)(slot, sizeof(struct asl_context), asl_context_init);
}

/* ProgramVars: mh, NXArgcPtr, NXArgvPtr, environPtr, __prognamePtr. */
struct yc_program_vars {
    const void *mh;
    int *argc;
    const char ***argv;
    const char ***environ;
    const char **progname;
};

YC_HIDDEN void __yc_simple_asl_init(const char **envp, const void *vars)
{
    struct asl_context *c = asl_context();
    const char *disable = YC_FN(_simple_getenv)(envp, "ASL_DISABLE");
    if (disable && disable[0] == '1' && disable[1] == 0)
        return;
    c->enabled = 1;
    const struct yc_program_vars *pv = vars;
    if (pv && pv->progname && *pv->progname)
        c->progname = *pv->progname;
}

YC_EXPORT void YC_FN(_simple_asl_log_prog)(int level, const char *facility, const char *message, const char *progname)
{
    (void)level;
    (void)facility;
    if (message == YC_NULL)
        return;
    YC_FN(_simple_dprintf)(2, "%s: %s\n", progname ? progname : "unknown", message);
}

YC_EXPORT void YC_FN(_simple_asl_log)(int level, const char *facility, const char *message)
{
    YC_FN(_simple_asl_log_prog)(level, facility, message, asl_context()->progname);
}
