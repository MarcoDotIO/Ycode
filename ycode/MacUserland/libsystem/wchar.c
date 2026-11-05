// wchar.c - wide-character strings and conversions for Ycode's libSystem
// (specs/macos/libsystem.md §12). Clean-room Ycode code from the C
// standard. wchar_t is a 32-bit int on Darwin. Multibyte text is UTF-8 in
// every locale Ycode's libSystem knows (locale.c), so mbrtowc and wcrtomb
// convert UTF-8; numeric conversions narrow the digits to ASCII and use the
// narrow functions.
#include "ycl.h"

typedef int wchar_t_;
typedef struct {
    unsigned char bytes[4];
    unsigned count, need;
    char reserved[120];
} mbstate;  // the public mbstate_t is 128 bytes

YCL_EXPORT size_t wcslen(const wchar_t_ *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

YCL_EXPORT size_t wcsnlen(const wchar_t_ *s, size_t max) {
    size_t n = 0;
    while (n < max && s[n]) n++;
    return n;
}

YCL_EXPORT wchar_t_ *wmemchr(const wchar_t_ *s, wchar_t_ c, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (s[i] == c) return (wchar_t_ *)&s[i];
    return 0;
}

YCL_EXPORT int wmemcmp(const wchar_t_ *a, const wchar_t_ *b, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return 0;
}

YCL_EXPORT wchar_t_ *wmemcpy(wchar_t_ *d, const wchar_t_ *s, size_t n) { return memcpy(d, s, n * sizeof *d); }
YCL_EXPORT wchar_t_ *wmemmove(wchar_t_ *d, const wchar_t_ *s, size_t n) { return memmove(d, s, n * sizeof *d); }
YCL_EXPORT wchar_t_ *wmemset(wchar_t_ *d, wchar_t_ c, size_t n) {
    for (size_t i = 0; i < n; i++) d[i] = c;
    return d;
}

YCL_EXPORT int wcscmp(const wchar_t_ *a, const wchar_t_ *b) {
    while (*a && *a == *b) a++, b++;
    return *a == *b ? 0 : (*a < *b ? -1 : 1);
}

YCL_EXPORT int wcsncmp(const wchar_t_ *a, const wchar_t_ *b, size_t n) {
    for (; n; n--, a++, b++) {
        if (*a != *b) return *a < *b ? -1 : 1;
        if (!*a) return 0;
    }
    return 0;
}

YCL_EXPORT int wcscoll(const wchar_t_ *a, const wchar_t_ *b) { return wcscmp(a, b); }

YCL_EXPORT wchar_t_ *wcschr(const wchar_t_ *s, wchar_t_ c) {
    for (;; s++) {
        if (*s == c) return (wchar_t_ *)s;
        if (!*s) return 0;
    }
}

YCL_EXPORT wchar_t_ *wcsrchr(const wchar_t_ *s, wchar_t_ c) {
    const wchar_t_ *found = 0;
    for (;; s++) {
        if (*s == c) found = s;
        if (!*s) return (wchar_t_ *)found;
    }
}

YCL_EXPORT wchar_t_ *wcscpy(wchar_t_ *d, const wchar_t_ *s) {
    wchar_t_ *r = d;
    while ((*d++ = *s++)) {
    }
    return r;
}

YCL_EXPORT wchar_t_ *wcsncpy(wchar_t_ *d, const wchar_t_ *s, size_t n) {
    size_t i = 0;
    for (; i < n && s[i]; i++) d[i] = s[i];
    for (; i < n; i++) d[i] = 0;
    return d;
}

YCL_EXPORT wchar_t_ *wcscat(wchar_t_ *d, const wchar_t_ *s) {
    wcscpy(d + wcslen(d), s);
    return d;
}

YCL_EXPORT size_t wcsxfrm(wchar_t_ *d, const wchar_t_ *s, size_t n) {
    size_t len = wcslen(s);
    if (n) wcsncpy(d, s, n);
    return len;
}

// --- UTF-8 multibyte conversions ---

YCL_EXPORT size_t mbrtowc(wchar_t_ *pwc, const char *s, size_t n, void *ps) {
    static mbstate internal;
    mbstate *st = ps ? ps : &internal;
    if (!s) {
        st->count = st->need = 0;
        return 0;
    }
    size_t used = 0;
    while (used < n) {
        unsigned char b = (unsigned char)s[used++];
        if (st->need == 0) {
            if (b < 0x80) {
                if (pwc) *pwc = b;
                return b ? used : 0;
            }
            unsigned need = b >= 0xF0 && b < 0xF5 ? 4 : b >= 0xE0 ? 3 : b >= 0xC2 && b < 0xE0 ? 2 : 0;
            if (!need) {
                ycl_errno = 92;  // EILSEQ
                return (size_t)-1;
            }
            st->need = need;
            st->bytes[0] = b;
            st->count = 1;
            continue;
        }
        if ((b & 0xC0) != 0x80) {
            st->count = st->need = 0;
            ycl_errno = 92;
            return (size_t)-1;
        }
        st->bytes[st->count++] = b;
        if (st->count == st->need) {
            unsigned c = st->bytes[0] & (0x7F >> st->need);
            for (unsigned i = 1; i < st->need; i++) c = (c << 6) | (st->bytes[i] & 0x3F);
            st->count = st->need = 0;
            if (pwc) *pwc = (wchar_t_)c;
            return c ? used : 0;
        }
    }
    return (size_t)-2;
}

YCL_EXPORT int mbtowc(wchar_t_ *pwc, const char *s, size_t n) {
    if (!s) return 0;
    mbstate st = {{0}, 0, 0, {0}};
    size_t r = mbrtowc(pwc, s, n, &st);
    return r == (size_t)-1 || r == (size_t)-2 ? -1 : (int)r;
}

YCL_EXPORT size_t mbrlen(const char *s, size_t n, void *ps) { return mbrtowc(0, s, n, ps); }
YCL_EXPORT int mblen(const char *s, size_t n) { return mbtowc(0, s, n); }
YCL_EXPORT int mbsinit(const void *ps) { return !ps || ((const mbstate *)ps)->need == 0; }

YCL_EXPORT size_t wcrtomb(char *s, wchar_t_ wc, void *ps) {
    (void)ps;
    char tmp[4];
    if (!s) s = tmp, wc = 0;
    unsigned c = (unsigned)wc;
    if (c < 0x80) {
        s[0] = (char)c;
        return 1;
    }
    if (c < 0x800) {
        s[0] = (char)(0xC0 | c >> 6);
        s[1] = (char)(0x80 | (c & 0x3F));
        return 2;
    }
    if (c < 0x10000) {
        if (c >= 0xD800 && c < 0xE000) {
            ycl_errno = 92;
            return (size_t)-1;
        }
        s[0] = (char)(0xE0 | c >> 12);
        s[1] = (char)(0x80 | ((c >> 6) & 0x3F));
        s[2] = (char)(0x80 | (c & 0x3F));
        return 3;
    }
    if (c < 0x110000) {
        s[0] = (char)(0xF0 | c >> 18);
        s[1] = (char)(0x80 | ((c >> 12) & 0x3F));
        s[2] = (char)(0x80 | ((c >> 6) & 0x3F));
        s[3] = (char)(0x80 | (c & 0x3F));
        return 4;
    }
    ycl_errno = 92;
    return (size_t)-1;
}

YCL_EXPORT int wctomb(char *s, wchar_t_ wc) {
    if (!s) return 0;
    size_t r = wcrtomb(s, wc, 0);
    return r == (size_t)-1 ? -1 : (int)r;
}

YCL_EXPORT size_t mbsrtowcs(wchar_t_ *dst, const char **src, size_t len, void *ps) {
    const char *s = *src;
    size_t n = 0;
    while (!dst || n < len) {
        wchar_t_ wc;
        size_t r = mbrtowc(&wc, s, 4, ps);
        if (r == (size_t)-1 || r == (size_t)-2) return (size_t)-1;
        if (dst) dst[n] = wc;
        if (r == 0) {
            if (dst) *src = 0;
            return n;
        }
        s += r;
        n++;
    }
    *src = s;
    return n;
}

YCL_EXPORT size_t mbsnrtowcs(wchar_t_ *dst, const char **src, size_t nms, size_t len, void *ps) {
    const char *s = *src, *end = s + nms;
    size_t n = 0;
    while (s < end && (!dst || n < len)) {
        wchar_t_ wc;
        size_t r = mbrtowc(&wc, s, (size_t)(end - s), ps);
        if (r == (size_t)-1) {
            *src = s;
            return r;
        }
        if (r == (size_t)-2) break;
        if (dst) dst[n] = wc;
        if (r == 0) {
            if (dst) *src = 0;
            return n;
        }
        s += r;
        n++;
    }
    if (dst) *src = s;
    return n;
}

YCL_EXPORT size_t mbstowcs(wchar_t_ *dst, const char *src, size_t len) { return mbsrtowcs(dst, &src, len, 0); }

YCL_EXPORT size_t wcsnrtombs(char *dst, const wchar_t_ **src, size_t nwc, size_t len, void *ps) {
    const wchar_t_ *s = *src;
    size_t n = 0;
    for (size_t i = 0; i < nwc; i++) {
        char buf[4];
        size_t r = wcrtomb(buf, s[i], ps);
        if (r == (size_t)-1) {
            if (dst) *src = s + i;
            return r;
        }
        if (dst) {
            if (n + r > len) {
                *src = s + i;
                return n;
            }
            memcpy(dst + n, buf, r);
        }
        if (!s[i]) {
            if (dst) *src = 0;
            return n;
        }
        n += r;
    }
    if (dst) *src = s + nwc;
    return n;
}

YCL_EXPORT size_t wcsrtombs(char *dst, const wchar_t_ **src, size_t len, void *ps) {
    return wcsnrtombs(dst, src, (size_t)-1 / sizeof(wchar_t_), len, ps);
}

YCL_EXPORT size_t wcstombs(char *dst, const wchar_t_ *src, size_t len) { return wcsrtombs(dst, &src, len, 0); }

YCL_EXPORT int wctob(int wc) { return wc >= 0 && wc < 0x80 ? wc : -1; }
YCL_EXPORT int btowc(int c) { return c >= 0 && c < 0x80 ? c : -1; }

YCL_EXPORT int wcwidth(wchar_t_ c) {
    if (c == 0) return 0;
    if (c < 0x20 || (c >= 0x7F && c < 0xA0)) return -1;
    return 1;
}

// --- numbers from wide strings: narrow the leading ASCII, convert, map
//     the end pointer back ---

double strtod(const char *, char **);
float strtof(const char *, char **);
long double strtold(const char *, char **);
long long strtoll(const char *, char **, int);
unsigned long long strtoull(const char *, char **, int);

enum { NARROW_MAX = 512 };

static size_t narrow(const wchar_t_ *s, char *out) {
    size_t n = 0;
    while (n < NARROW_MAX - 1 && s[n] > 0 && s[n] < 0x80) out[n] = (char)s[n], n++;
    out[n] = 0;
    return n;
}

#define WIDE_TO_NUMBER(type, name, call)                       \
    YCL_EXPORT type name(const wchar_t_ *s, wchar_t_ **end) {  \
        char buf[NARROW_MAX];                                  \
        narrow(s, buf);                                        \
        char *e;                                               \
        type v = call;                                         \
        if (end) *end = (wchar_t_ *)(s + (e - buf));           \
        return v;                                              \
    }
WIDE_TO_NUMBER(double, wcstod, strtod(buf, &e))
WIDE_TO_NUMBER(float, wcstof, strtof(buf, &e))
WIDE_TO_NUMBER(long double, wcstold, strtold(buf, &e))

#define WIDE_TO_INTEGER(type, name, call)                                \
    YCL_EXPORT type name(const wchar_t_ *s, wchar_t_ **end, int base) {  \
        char buf[NARROW_MAX];                                            \
        narrow(s, buf);                                                  \
        char *e;                                                         \
        type v = (type)call;                                             \
        if (end) *end = (wchar_t_ *)(s + (e - buf));                     \
        return v;                                                        \
    }
WIDE_TO_INTEGER(long, wcstol, strtoll(buf, &e, base))
WIDE_TO_INTEGER(long long, wcstoll, strtoll(buf, &e, base))
WIDE_TO_INTEGER(unsigned long, wcstoul, strtoull(buf, &e, base))
WIDE_TO_INTEGER(unsigned long long, wcstoull, strtoull(buf, &e, base))

// swprintf: format narrow, then widen (UTF-8 decoded).
int vsnprintf(char *, size_t, const char *, va_list);

YCL_EXPORT int vswprintf(wchar_t_ *out, size_t n, const wchar_t_ *format, va_list args) {
    char fmt[NARROW_MAX];
    size_t flen = 0;
    while (format[flen] && flen < NARROW_MAX - 1) {
        wchar_t_ c = format[flen];
        fmt[flen++] = (char)(c < 0x80 ? c : '?');
    }
    fmt[flen] = 0;
    char buf[1024];
    int len = vsnprintf(buf, sizeof buf, fmt, args);
    if (len < 0) return -1;
    const char *s = buf;
    size_t w = mbsrtowcs(out, &s, n, 0);
    if (w == (size_t)-1 || w >= n || (size_t)len >= sizeof buf) {
        if (n) out[n - 1] = 0;
        ycl_errno = YCL_EOVERFLOW;
        return -1;
    }
    return (int)w;
}

YCL_EXPORT int swprintf(wchar_t_ *out, size_t n, const wchar_t_ *format, ...) {
    va_list args;
    va_start(args, format);
    int r = vswprintf(out, n, format, args);
    va_end(args);
    return r;
}

YCL_EXPORT int wcscoll_l(const wchar_t_ *a, const wchar_t_ *b, void *locale) {
    (void)locale;
    return wcscmp(a, b);
}
YCL_EXPORT size_t wcsxfrm_l(wchar_t_ *d, const wchar_t_ *s, size_t n, void *locale) {
    (void)locale;
    return wcsxfrm(d, s, n);
}

// --- wide characters on byte streams (UTF-8) ---

int fgetc(FILE *);
int fputc(int, FILE *);
int ungetc(int, FILE *);
enum { WEOF_ = -1 };

YCL_EXPORT int fputwc(wchar_t_ wc, FILE *f) {
    char buf[4];
    size_t n = wcrtomb(buf, wc, 0);
    if (n == (size_t)-1) return WEOF_;
    for (size_t i = 0; i < n; i++)
        if (fputc((unsigned char)buf[i], f) < 0) return WEOF_;
    return wc;
}
YCL_EXPORT int putwc(wchar_t_ wc, FILE *f) { return fputwc(wc, f); }
YCL_EXPORT int putwchar(wchar_t_ wc) { return fputwc(wc, __stdoutp); }

YCL_EXPORT int fgetwc(FILE *f) {
    mbstate st = {{0}, 0, 0, {0}};
    for (;;) {
        int c = fgetc(f);
        if (c < 0) return WEOF_;
        char b = (char)c;
        wchar_t_ wc;
        size_t r = mbrtowc(&wc, &b, 1, &st);
        if (r == (size_t)-2) continue;
        if (r == (size_t)-1) return WEOF_;
        return wc;
    }
}
YCL_EXPORT int getwc(FILE *f) { return fgetwc(f); }
YCL_EXPORT int getwchar(void) { return fgetwc(__stdinp); }

// Only one byte can be pushed back on Ycode's streams, so only ASCII wide
// characters can be returned to a stream.
YCL_EXPORT int ungetwc(int wc, FILE *f) {
    if (wc < 0 || wc >= 0x80) return WEOF_;
    return ungetc(wc, f) < 0 ? WEOF_ : wc;
}
