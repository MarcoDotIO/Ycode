// format.c - the printf formatting engine of Ycode's libSystem
// (specs/macos/libsystem.md §4). Clean-room Ycode code from the C standard's
// description of the conversions.
#include "ycl.h"

struct spec {
    int left, plus, space, alt, zero;
    int width, precision;  // precision -1 = none
    int length;            // 0 int, 'H' char, 'h' short, 'l' long, 'L' long long / long double, 'z', 'j', 't'
};

struct out {
    ycl_sink sink;
    void *context;
    int count;
};

static void emit(struct out *o, const char *s, size_t n) {
    if (n) o->sink(o->context, s, n);
    o->count += (int)n;
}

static void pad(struct out *o, char c, int n) {
    char block[32];
    for (int i = 0; i < 32; i++) block[i] = c;
    while (n > 0) {
        int k = n > 32 ? 32 : n;
        emit(o, block, (size_t)k);
        n -= k;
    }
}

// Emits a field: prefix (sign, 0x), zero padding to `zeros`, then digits.
static void field(struct out *o, const struct spec *s, const char *prefix, const char *body, int bodylen, int zeros) {
    int plen = (int)strlen(prefix);
    int total = plen + zeros + bodylen;
    if (!s->left && !(s->zero && s->precision < 0) && s->width > total) pad(o, ' ', s->width - total);
    emit(o, prefix, (size_t)plen);
    if (!s->left && s->zero && s->precision < 0 && s->width > total) pad(o, '0', s->width - total);
    pad(o, '0', zeros);
    emit(o, body, (size_t)bodylen);
    if (s->left && s->width > total) pad(o, ' ', s->width - total);
}

static void integer(struct out *o, struct spec *s, uint64_t v, int negative, int base, int upper, char conv) {
    char digits[72];
    int n = 0;
    const char *set = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    while (v) {
        digits[sizeof digits - 1 - n++] = set[v % (uint64_t)base];
        v /= (uint64_t)base;
    }
    if (n == 0 && s->precision != 0) digits[sizeof digits - 1 - n++] = '0';
    int zeros = s->precision > n ? s->precision - n : 0;
    char prefix[4] = {0};
    if (conv == 'd' || conv == 'i') {
        if (negative) prefix[0] = '-';
        else if (s->plus) prefix[0] = '+';
        else if (s->space) prefix[0] = ' ';
    } else if (s->alt && conv == 'o' && zeros == 0 && (n == 0 || digits[sizeof digits - n] != '0')) {
        zeros = 1;
    } else if ((s->alt && (conv == 'x' || conv == 'X') && !(n == 1 && digits[sizeof digits - 1] == '0')) || conv == 'p') {
        prefix[0] = '0';
        prefix[1] = upper ? 'X' : 'x';
    }
    field(o, s, prefix, digits + sizeof digits - n, n, zeros);
}

// Decimal digits of a non-negative double: integer part and `precision`
// fraction digits, rounded half up (not correctly rounded for every value,
// which Ycode's conversions do not promise yet).
static int fixed_digits(double v, int precision, char *out, int cap) {
    if (precision > 17) precision = 17;
    double scale = 1;
    for (int i = 0; i < precision; i++) scale *= 10;
    double whole = v;
    int n = 0;
    if (whole >= 1.8e19) {  // beyond uint64: print the integer part digit by digit
        int exp = 0;
        while (whole >= 10) {
            whole /= 10;
            exp++;
        }
        for (int i = 0; i <= exp && n < cap - 2; i++) {
            int d = (int)whole;
            out[n++] = (char)('0' + d);
            whole = (whole - d) * 10;
        }
        if (precision > 0 && n < cap - 1) out[n++] = '.';
        for (int i = 0; i < precision && n < cap - 1; i++) out[n++] = '0';
        return n;
    }
    uint64_t ip = (uint64_t)v;
    double frac = v - (double)ip;
    // Round to nearest; an exact tie (frac * scale is computed exactly for
    // short binary fractions such as 3.25) goes to the even digit.
    double scaled = frac * scale;
    uint64_t fp = (uint64_t)scaled;
    double rest = scaled - (double)fp;
    if (rest > 0.5 || (rest == 0.5 && ((precision > 0 ? fp : ip) & 1))) fp++;
    if ((double)fp >= scale) {
        fp -= (uint64_t)scale;
        ip++;
    }
    char tmp[24];
    int k = 0;
    do tmp[k++] = (char)('0' + ip % 10); while ((ip /= 10) && k < 24);
    while (k && n < cap) out[n++] = tmp[--k];
    if (precision > 0 && n < cap) {
        out[n++] = '.';
        for (int i = precision - 1; i >= 0; i--) {
            if (n + i < cap) out[n + i] = (char)('0' + fp % 10);
            fp /= 10;
        }
        n += precision;
    }
    return n < cap ? n : cap;
}

static void floating(struct out *o, struct spec *s, double v, char conv) {
    char body[96];
    int n = 0;
    int upper = conv == 'F' || conv == 'E' || conv == 'G';
    char prefix[2] = {0};
    if (v < 0 || (v == 0 && 1 / v < 0)) {
        prefix[0] = '-';
        v = -v;
    } else if (s->plus) {
        prefix[0] = '+';
    } else if (s->space) {
        prefix[0] = ' ';
    }
    if (v != v || v > 1.7976931348623157e308) {
        const char *text = v != v ? (upper ? "NAN" : "nan") : (upper ? "INF" : "inf");
        struct spec plain = *s;
        plain.zero = 0;
        field(o, &plain, prefix, text, 3, 0);
        return;
    }
    int precision = s->precision < 0 ? 6 : s->precision;
    char kind = conv | 0x20;
    int exp10 = 0;
    if (kind == 'g') {
        if (precision == 0) precision = 1;
        double t = v;
        if (t != 0) {
            while (t >= 10) {
                t /= 10;
                exp10++;
            }
            while (t < 1) {
                t *= 10;
                exp10--;
            }
        }
        if (exp10 < -4 || exp10 >= precision) {
            kind = 'e';
            precision -= 1;
        } else {
            kind = 'f';
            precision -= 1 + exp10;
        }
    }
    if (kind == 'e') {
        exp10 = 0;
        if (v != 0) {
            while (v >= 10) {
                v /= 10;
                exp10++;
            }
            while (v < 1) {
                v *= 10;
                exp10--;
            }
        }
        n = fixed_digits(v, precision, body, 80);
        if (n >= 2 && body[0] == '1' && body[1] == '0') {  // rounding carried to 10.x
            v /= 10;
            exp10++;
            n = fixed_digits(v, precision, body, 80);
        }
    } else {
        n = fixed_digits(v, precision, body, 80);
    }
    if ((conv | 0x20) == 'g' && !s->alt) {  // %g drops trailing zeros
        int dot = -1;
        for (int i = 0; i < n; i++)
            if (body[i] == '.') dot = i;
        if (dot >= 0) {
            while (n > dot && body[n - 1] == '0') n--;
            if (n == dot + 1) n--;
        }
    }
    if (s->alt && precision == 0) body[n++] = '.';
    if (kind == 'e') {
        body[n++] = upper ? 'E' : 'e';
        body[n++] = exp10 < 0 ? '-' : '+';
        int e = exp10 < 0 ? -exp10 : exp10;
        if (e >= 100) body[n++] = (char)('0' + e / 100);
        body[n++] = (char)('0' + e / 10 % 10);
        body[n++] = (char)('0' + e % 10);
    }
    struct spec f = *s;
    f.precision = -1;
    field(o, &f, prefix, body, n, 0);
}

int ycl_vformat(ycl_sink sink, void *context, const char *fmt, va_list args) {
    struct out o = {sink, context, 0};
    while (*fmt) {
        const char *run = fmt;
        while (*fmt && *fmt != '%') fmt++;
        emit(&o, run, (size_t)(fmt - run));
        if (!*fmt) break;
        fmt++;
        struct spec s = {0, 0, 0, 0, 0, 0, -1, 0};
        for (;; fmt++) {
            if (*fmt == '-') s.left = 1;
            else if (*fmt == '+') s.plus = 1;
            else if (*fmt == ' ') s.space = 1;
            else if (*fmt == '#') s.alt = 1;
            else if (*fmt == '0') s.zero = 1;
            else if (*fmt == '\'') continue;
            else break;
        }
        if (*fmt == '*') {
            s.width = va_arg(args, int);
            if (s.width < 0) {
                s.left = 1;
                s.width = -s.width;
            }
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9') s.width = s.width * 10 + (*fmt++ - '0');
        }
        if (*fmt == '.') {
            fmt++;
            s.precision = 0;
            if (*fmt == '*') {
                s.precision = va_arg(args, int);
                if (s.precision < 0) s.precision = -1;
                fmt++;
            } else {
                while (*fmt >= '0' && *fmt <= '9') s.precision = s.precision * 10 + (*fmt++ - '0');
            }
        }
        for (;;) {
            if (*fmt == 'h') s.length = s.length == 'h' ? 'H' : 'h';
            else if (*fmt == 'l') s.length = s.length == 'l' ? 'L' : 'l';
            else if (*fmt == 'q' || *fmt == 'L') s.length = 'L';
            else if (*fmt == 'z' || *fmt == 'j' || *fmt == 't') s.length = *fmt;
            else break;
            fmt++;
        }
        char conv = *fmt ? *fmt++ : 0;
        switch (conv) {
        case 'd':
        case 'i': {
            int64_t v = s.length == 'l' || s.length == 'L' || s.length == 'z' || s.length == 'j' || s.length == 't'
                      ? va_arg(args, int64_t) : (int64_t)va_arg(args, int);
            if (s.length == 'h') v = (short)v;
            if (s.length == 'H') v = (signed char)v;
            integer(&o, &s, v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v, v < 0, 10, 0, conv);
            break;
        }
        case 'u':
        case 'o':
        case 'x':
        case 'X': {
            uint64_t v = s.length == 'l' || s.length == 'L' || s.length == 'z' || s.length == 'j' || s.length == 't'
                       ? va_arg(args, uint64_t) : (uint64_t)va_arg(args, unsigned);
            if (s.length == 'h') v = (unsigned short)v;
            if (s.length == 'H') v = (unsigned char)v;
            integer(&o, &s, v, 0, conv == 'u' ? 10 : conv == 'o' ? 8 : 16, conv == 'X', conv);
            break;
        }
        case 'p': {
            uint64_t v = (uint64_t)(uintptr_t)va_arg(args, void *);
            integer(&o, &s, v, 0, 16, 0, 'p');
            break;
        }
        case 'c': {
            char c = (char)va_arg(args, int);
            struct spec f = s;
            f.precision = -1;
            f.zero = 0;
            field(&o, &f, "", &c, 1, 0);
            break;
        }
        case 's': {
            const char *str = va_arg(args, const char *);
            if (!str) str = "(null)";
            int n = 0;
            while (str[n] && (s.precision < 0 || n < s.precision)) n++;
            struct spec f = s;
            f.precision = -1;
            f.zero = 0;
            field(&o, &f, "", str, n, 0);
            break;
        }
        case 'f':
        case 'F':
        case 'e':
        case 'E':
        case 'g':
        case 'G':
        case 'a':
        case 'A': {
            double v = va_arg(args, double);  // long double is double on arm64 Darwin
            floating(&o, &s, v, conv == 'a' ? 'e' : conv == 'A' ? 'E' : conv);
            break;
        }
        case 'n': {
            int *p = va_arg(args, int *);
            if (p) *p = o.count;
            break;
        }
        case '%':
            emit(&o, "%", 1);
            break;
        default:
            if (conv) emit(&o, fmt - 1, 1);
            break;
        }
    }
    return o.count;
}
