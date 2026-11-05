// scanf.c - formatted input from strings and streams for Ycode's libSystem
// (specs/macos/libsystem.md §12). Clean-room Ycode code from the C
// standard's description of fscanf: directives, conversions
// d i u o x X c s [ ] n p and the floating-point ones, the * suppression,
// field widths and the length modifiers hh h l ll L q j z t.
#include "ycl.h"

double strtod(const char *, char **);
int fgetc(FILE *);
int ungetc(int, FILE *);

// An input source: a string or a stream, one byte of look-ahead.
struct input {
    const char *s;  // string source
    FILE *f;        // stream source
    long consumed;
    int eof;
};

static int peek(struct input *in) {
    if (in->s) return *in->s ? (unsigned char)*in->s : -1;
    int c = fgetc(in->f);
    if (c < 0) {
        in->eof = 1;
        return -1;
    }
    ungetc(c, in->f);
    return c;
}

static int next(struct input *in) {
    int c;
    if (in->s) {
        c = *in->s ? (unsigned char)*in->s++ : -1;
    } else {
        c = fgetc(in->f);
    }
    if (c < 0) in->eof = 1;
    else in->consumed++;
    return c;
}

static int is_space(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

static int digit_value(int c, int base) {
    int v = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'z' ? c - 'a' + 10 : c >= 'A' && c <= 'Z' ? c - 'A' + 10 : 99;
    return v < base ? v : -1;
}

enum { LEN_NONE, LEN_HH, LEN_H, LEN_L, LEN_LL, LEN_BIG_L, LEN_J, LEN_Z, LEN_T };

static void store_integer(void *p, int len, unsigned long long v) {
    switch (len) {
    case LEN_HH: *(char *)p = (char)v; break;
    case LEN_H: *(short *)p = (short)v; break;
    case LEN_L:
    case LEN_J:
    case LEN_Z:
    case LEN_T: *(long *)p = (long)v; break;
    case LEN_LL:
    case LEN_BIG_L: *(long long *)p = (long long)v; break;
    default: *(int *)p = (int)v; break;
    }
}

// Reads an integer of `base` (0: by prefix); returns 0 if no digits.
static int scan_integer(struct input *in, int base, long width, unsigned long long *out) {
    char buf[96];
    int n = 0;
    int c = peek(in);
    if ((c == '+' || c == '-') && width) {
        buf[n++] = (char)next(in);
        width--;
        c = peek(in);
    }
    if ((base == 0 || base == 16) && c == '0' && width) {
        buf[n++] = (char)next(in);
        width--;
        c = peek(in);
        if ((c == 'x' || c == 'X') && width) {
            buf[n++] = (char)next(in);
            width--;
            base = 16;
        } else if (base == 0) {
            base = 8;
        }
    }
    if (base == 0) base = 10;
    int digits = n > 0 && buf[n - 1] == '0';
    while (width && n < (int)sizeof buf - 1 && digit_value(peek(in), base) >= 0) {
        buf[n++] = (char)next(in);
        width--;
        digits = 1;
    }
    if (!digits) return 0;
    buf[n] = 0;
    const char *p = buf;
    int negative = 0;
    if (*p == '+' || *p == '-') negative = *p++ == '-';
    if (base == 16 && p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    unsigned long long v = 0;
    for (; *p; p++) {
        int d = digit_value(*p, base);
        if (d < 0) break;
        v = v * (unsigned)base + (unsigned)d;
    }
    *out = negative ? 0 - v : v;
    return 1;
}

static int scan_float(struct input *in, long width, double *out) {
    char buf[512];
    int n = 0;
    // Take the longest prefix that can belong to a floating-point number
    // (sign, digits, point, exponent, hex prefix, inf/nan letters), then
    // let strtod decide how much of it is the number.
    while (width && n < (int)sizeof buf - 1) {
        int c = peek(in);
        int ok = (c >= '0' && c <= '9') || c == '.' || ((c == '+' || c == '-') && (n == 0 || buf[n - 1] == 'e' || buf[n - 1] == 'E' || buf[n - 1] == 'p' || buf[n - 1] == 'P')) ||
                 (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        if (!ok) break;
        buf[n++] = (char)next(in);
        width--;
    }
    buf[n] = 0;
    char *end;
    double v = strtod(buf, &end);
    if (end == buf) return 0;
    // Give back what strtod did not use (string sources only can rewind).
    if (in->s) {
        long extra = (long)(buf + n - end);
        in->s -= extra;
        in->consumed -= extra;
    } else {
        for (char *p = buf + n; p > end;) ungetc((unsigned char)*--p, in->f), in->consumed--;
    }
    *out = v;
    return 1;
}

static int vscan(struct input *in, const char *fmt, va_list args) {
    int assigned = 0, any_conversion = 0;
    while (*fmt) {
        unsigned char f = (unsigned char)*fmt;
        if (is_space(f)) {
            while (is_space(peek(in))) next(in);
            fmt++;
            continue;
        }
        if (f != '%' || fmt[1] == '%') {
            if (f == '%') fmt++;
            while (is_space(peek(in)) && *fmt == '%') next(in);
            if (peek(in) != (unsigned char)*fmt) goto done;
            next(in);
            fmt++;
            continue;
        }
        fmt++;
        int suppress = 0;
        if (*fmt == '*') suppress = 1, fmt++;
        long width = 0;
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        int len = LEN_NONE;
        switch (*fmt) {
        case 'h': len = fmt[1] == 'h' ? (fmt++, LEN_HH) : LEN_H; fmt++; break;
        case 'l': len = fmt[1] == 'l' ? (fmt++, LEN_LL) : LEN_L; fmt++; break;
        case 'q': len = LEN_LL; fmt++; break;
        case 'L': len = LEN_BIG_L; fmt++; break;
        case 'j': len = LEN_J; fmt++; break;
        case 'z': len = LEN_Z; fmt++; break;
        case 't': len = LEN_T; fmt++; break;
        default: break;
        }
        char conv = *fmt++;
        if (!conv) break;
        if (conv != 'c' && conv != '[' && conv != 'n')
            while (is_space(peek(in))) next(in);
        if (!width) width = conv == 'c' ? 1 : -1;
        switch (conv) {
        case 'n':
            if (!suppress) store_integer(va_arg(args, void *), len, (unsigned long long)in->consumed);
            continue;
        case 'd':
        case 'i':
        case 'u':
        case 'o':
        case 'x':
        case 'X':
        case 'p': {
            int base = conv == 'd' || conv == 'u' ? 10 : conv == 'i' ? 0 : conv == 'o' ? 8 : 16;
            unsigned long long v;
            if (peek(in) < 0) goto input_failure;
            if (!scan_integer(in, base, width, &v)) goto done;
            any_conversion = 1;
            if (!suppress) {
                if (conv == 'p') *va_arg(args, void **) = (void *)(uintptr_t)v;
                else store_integer(va_arg(args, void *), len, v);
                assigned++;
            }
            break;
        }
        case 'a':
        case 'A':
        case 'e':
        case 'E':
        case 'f':
        case 'F':
        case 'g':
        case 'G': {
            double v;
            if (peek(in) < 0) goto input_failure;
            if (!scan_float(in, width, &v)) goto done;
            any_conversion = 1;
            if (!suppress) {
                if (len == LEN_L || len == LEN_BIG_L) *va_arg(args, double *) = v;
                else *va_arg(args, float *) = (float)v;
                assigned++;
            }
            break;
        }
        case 'c': {
            char *out = suppress ? 0 : va_arg(args, char *);
            if (peek(in) < 0) goto input_failure;
            for (long i = 0; i < width; i++) {
                int c = next(in);
                if (c < 0) goto done;
                if (out) out[i] = (char)c;
            }
            any_conversion = 1;
            if (out) assigned++;
            break;
        }
        case 's':
        case '[': {
            unsigned char set[256];
            int negate = 0;
            if (conv == '[') {
                memset(set, 0, sizeof set);
                if (*fmt == '^') negate = 1, fmt++;
                if (*fmt == ']') set[']'] = 1, fmt++;
                while (*fmt && *fmt != ']') {
                    if (fmt[1] == '-' && fmt[2] && fmt[2] != ']') {
                        for (int c = (unsigned char)fmt[0]; c <= (unsigned char)fmt[2]; c++) set[c] = 1;
                        fmt += 3;
                    } else {
                        set[(unsigned char)*fmt++] = 1;
                    }
                }
                if (*fmt == ']') fmt++;
            }
            char *out = suppress ? 0 : va_arg(args, char *);
            long n = 0;
            if (peek(in) < 0) goto input_failure;
            while (width < 0 || n < width) {
                int c = peek(in);
                if (c < 0) break;
                int accept = conv == 's' ? !is_space(c) : (set[c] != negate);
                if (!accept) break;
                next(in);
                if (out) out[n] = (char)c;
                n++;
            }
            if (!n) goto done;
            any_conversion = 1;
            if (out) {
                out[n] = 0;
                assigned++;
            }
            break;
        }
        default: goto done;
        }
    }
done:
    return assigned;
input_failure:
    return any_conversion || assigned ? assigned : -1;
}

YCL_EXPORT int vsscanf(const char *s, const char *fmt, va_list args) {
    struct input in = {s, 0, 0, 0};
    if (!*s) {
        // EOF before the first conversion.
        const char *f = fmt;
        while (is_space((unsigned char)*f)) f++;
        if (*f) return -1;
    }
    return vscan(&in, fmt, args);
}

YCL_EXPORT int sscanf(const char *s, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int r = vsscanf(s, fmt, args);
    va_end(args);
    return r;
}

YCL_EXPORT int vfscanf(FILE *f, const char *fmt, va_list args) {
    struct input in = {0, f, 0, 0};
    return vscan(&in, fmt, args);
}

YCL_EXPORT int fscanf(FILE *f, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int r = vfscanf(f, fmt, args);
    va_end(args);
    return r;
}

YCL_EXPORT int scanf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int r = vfscanf(__stdinp, fmt, args);
    va_end(args);
    return r;
}

YCL_EXPORT int vscanf(const char *fmt, va_list args) { return vfscanf(__stdinp, fmt, args); }

// The _l forms: the C locale is the only one (locale.c).
YCL_EXPORT int sscanf_l(const char *s, void *locale, const char *fmt, ...) {
    (void)locale;
    va_list args;
    va_start(args, fmt);
    int r = vsscanf(s, fmt, args);
    va_end(args);
    return r;
}
YCL_EXPORT int vsscanf_l(const char *s, void *locale, const char *fmt, va_list args) {
    (void)locale;
    return vsscanf(s, fmt, args);
}
