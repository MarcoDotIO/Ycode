// locale.c - locales for Ycode's libSystem (specs/macos/libsystem.md §12).
// Clean-room Ycode code from the C standard, POSIX and the public
// <xlocale.h> interface.
//
// Ycode's libSystem has one set of locale data: the C/POSIX locale, with
// UTF-8 as the multibyte encoding (wchar.c). setlocale and newlocale accept
// "C", "POSIX", "" and any name ending in ".UTF-8"/".utf8" (reported back as
// given) and behave like the C locale for collation, numbers and
// classification. `locale_t` values are pointers to a small Ycode record;
// LC_GLOBAL_LOCALE is (locale_t)-1 and NULL means the current locale, as in
// <xlocale.h>.
#include "ycl.h"

enum { LC_ALL = 0, LC_COLLATE, LC_CTYPE, LC_MONETARY, LC_NUMERIC, LC_TIME, LC_MESSAGES, LC_COUNT };

struct ycl_locale {
    char names[LC_COUNT][64];
};

static struct ycl_locale c_locale = {{"C", "C", "C", "C", "C", "C", "C"}};
static struct ycl_locale global_locale = {{"C", "C", "C", "C", "C", "C", "C"}};
static os_unfair_lock locale_lock;

// lconv: the public <locale.h> layout.
struct ycl_lconv {
    char *decimal_point, *thousands_sep, *grouping, *int_curr_symbol, *currency_symbol, *mon_decimal_point,
        *mon_thousands_sep, *mon_grouping, *positive_sign, *negative_sign;
    char int_frac_digits, frac_digits, p_cs_precedes, p_sep_by_space, n_cs_precedes, n_sep_by_space, p_sign_posn,
        n_sign_posn, int_p_cs_precedes, int_n_cs_precedes, int_p_sep_by_space, int_n_sep_by_space,
        int_p_sign_posn, int_n_sign_posn;
};

static struct ycl_lconv c_lconv = {
    ".", "", "", "", "", "", "", "", "", "", 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127,
};

static int known_name(const char *name) {
    if (!*name || !strcmp(name, "C") || !strcmp(name, "POSIX")) return 1;
    const char *dot = strrchr(name, '.');
    return dot && (!strcmp(dot, ".UTF-8") || !strcmp(dot, ".utf8") || !strcmp(dot, ".UTF8") || !strcmp(dot, ".utf-8"));
}

static const char *canonical(const char *name) { return !*name ? "C" : name; }

YCL_EXPORT char *setlocale(int category, const char *name) {
    if (category < LC_ALL || category >= LC_COUNT) return 0;
    if (!name) return global_locale.names[category];
    if (!known_name(name)) return 0;
    os_unfair_lock_lock(&locale_lock);
    if (category == LC_ALL)
        for (int i = 0; i < LC_COUNT; i++) strlcpy(global_locale.names[i], canonical(name), 64);
    else
        strlcpy(global_locale.names[category], canonical(name), 64);
    os_unfair_lock_unlock(&locale_lock);
    return global_locale.names[category];
}

YCL_EXPORT struct ycl_lconv *localeconv(void) { return &c_lconv; }
YCL_EXPORT struct ycl_lconv *localeconv_l(void *locale) {
    (void)locale;
    return &c_lconv;
}

// Mask bits of newlocale (<xlocale.h>): LC_COLLATE_MASK 1 << 0 ... LC_MESSAGES_MASK 1 << 5.
YCL_EXPORT struct ycl_locale *newlocale(int mask, const char *name, struct ycl_locale *base) {
    if (!name || !known_name(name)) {
        ycl_errno = 2;  // ENOENT
        return 0;
    }
    struct ycl_locale *l = base && base != &c_locale && base != (void *)-1 ? base : malloc(sizeof *l);
    if (!l) return 0;
    if (l != base) *l = base == (void *)-1 ? global_locale : base ? *base : c_locale;
    for (int i = 1; i < LC_COUNT; i++)
        if (mask & (1 << (i - 1))) strlcpy(l->names[i], canonical(name), 64);
    return l;
}

YCL_EXPORT struct ycl_locale *duplocale(struct ycl_locale *l) {
    struct ycl_locale *copy = malloc(sizeof *copy);
    if (!copy) return 0;
    *copy = l == (void *)-1 ? global_locale : l ? *l : c_locale;
    return copy;
}

YCL_EXPORT int freelocale(struct ycl_locale *l) {
    if (l && l != &c_locale && l != (void *)-1) free(l);
    return 0;
}

static unsigned long thread_locale_key;
static int thread_locale_ready;
int pthread_key_create(unsigned long *, void (*)(void *));
void *pthread_getspecific(unsigned long);
int pthread_setspecific(unsigned long, const void *);

YCL_EXPORT struct ycl_locale *uselocale(struct ycl_locale *l) {
    os_unfair_lock_lock(&locale_lock);
    if (!thread_locale_ready) thread_locale_ready = pthread_key_create(&thread_locale_key, 0) == 0;
    os_unfair_lock_unlock(&locale_lock);
    struct ycl_locale *old = thread_locale_ready ? pthread_getspecific(thread_locale_key) : 0;
    if (!old) old = (struct ycl_locale *)-1;
    if (l && thread_locale_ready) pthread_setspecific(thread_locale_key, l == (void *)-1 ? 0 : l);
    return old;
}

YCL_EXPORT const char *querylocale(int mask, struct ycl_locale *l) {
    struct ycl_locale *loc = l == (void *)-1 || !l ? &global_locale : l;
    for (int i = 1; i < LC_COUNT; i++)
        if (mask & (1 << (i - 1))) return loc->names[i];
    return loc->names[LC_CTYPE];
}

YCL_EXPORT int ___mb_cur_max_l(void *locale) {
    (void)locale;
    return 1;
}

YCL_EXPORT char *nl_langinfo(int item) {
    // <langinfo.h>: CODESET 0, D_T_FMT 1, D_FMT 2, T_FMT 3, RADIXCHAR 50,
    // THOUSEP 51, YESEXPR 52, NOEXPR 53, CRNCYSTR 56.
    switch (item) {
    case 0: return "UTF-8";
    case 1: return "%a %b %e %H:%M:%S %Y";
    case 2: return "%m/%d/%y";
    case 3: return "%H:%M:%S";
    case 50: return ".";
    case 51: return "";
    case 52: return "^[yY]";
    case 53: return "^[nN]";
    default: return "";
    }
}
YCL_EXPORT char *nl_langinfo_l(int item, void *locale) {
    (void)locale;
    return nl_langinfo(item);
}

// --- collation (byte order in the C locale) ---

YCL_EXPORT int strcoll(const char *a, const char *b) { return strcmp(a, b); }
YCL_EXPORT int strcoll_l(const char *a, const char *b, void *locale) {
    (void)locale;
    return strcmp(a, b);
}
YCL_EXPORT size_t strxfrm(char *d, const char *s, size_t n) {
    size_t len = strlen(s);
    if (n) strlcpy(d, s, n);
    return len;
}
YCL_EXPORT size_t strxfrm_l(char *d, const char *s, size_t n, void *locale) {
    (void)locale;
    return strxfrm(d, s, n);
}

// --- the _l forms of classification and conversion ---

int isalnum(int), isalpha(int), isblank(int), iscntrl(int), isdigit(int), isgraph(int), islower(int),
    isprint(int), ispunct(int), isspace(int), isupper(int), isxdigit(int), tolower(int), toupper(int);
int iswalnum(int), iswalpha(int), iswblank(int), iswcntrl(int), iswdigit(int), iswgraph(int), iswlower(int),
    iswprint(int), iswpunct(int), iswspace(int), iswupper(int), iswxdigit(int), towlower(int), towupper(int);
int iswctype(int, unsigned long);

#define LOCALE_FORM(name) \
    YCL_EXPORT int name##_l(int c, void *locale) { (void)locale; return name(c); }
LOCALE_FORM(isalnum) LOCALE_FORM(isalpha) LOCALE_FORM(isblank) LOCALE_FORM(iscntrl) LOCALE_FORM(isdigit)
LOCALE_FORM(isgraph) LOCALE_FORM(islower) LOCALE_FORM(isprint) LOCALE_FORM(ispunct) LOCALE_FORM(isspace)
LOCALE_FORM(isupper) LOCALE_FORM(isxdigit) LOCALE_FORM(tolower) LOCALE_FORM(toupper)
LOCALE_FORM(iswalnum) LOCALE_FORM(iswalpha) LOCALE_FORM(iswblank) LOCALE_FORM(iswcntrl) LOCALE_FORM(iswdigit)
LOCALE_FORM(iswgraph) LOCALE_FORM(iswlower) LOCALE_FORM(iswprint) LOCALE_FORM(iswpunct) LOCALE_FORM(iswspace)
LOCALE_FORM(iswupper) LOCALE_FORM(iswxdigit) LOCALE_FORM(towlower) LOCALE_FORM(towupper)
YCL_EXPORT int iswctype_l(int c, unsigned long mask, void *locale) {
    (void)locale;
    return iswctype(c, mask);
}
YCL_EXPORT unsigned long wctype(const char *name) {
    static const struct {
        const char *name;
        unsigned long mask;
    } classes[] = {{"alnum", 0x500},  {"alpha", 0x100}, {"blank", 0x20000}, {"cntrl", 0x200},
                   {"digit", 0x400},  {"graph", 0x800}, {"lower", 0x1000},  {"print", 0x40000},
                   {"punct", 0x2000}, {"space", 0x4000}, {"upper", 0x8000}, {"xdigit", 0x10000}};
    for (size_t i = 0; i < sizeof classes / sizeof classes[0]; i++)
        if (!strcmp(name, classes[i].name)) return classes[i].mask;
    return 0;
}
YCL_EXPORT unsigned long wctype_l(const char *name, void *locale) {
    (void)locale;
    return wctype(name);
}

long long strtoll(const char *, char **, int);
unsigned long long strtoull(const char *, char **, int);
YCL_EXPORT long strtol_l(const char *s, char **end, int base, void *locale) {
    (void)locale;
    return (long)strtoll(s, end, base);
}
YCL_EXPORT long long strtoll_l(const char *s, char **end, int base, void *locale) {
    (void)locale;
    return strtoll(s, end, base);
}
YCL_EXPORT unsigned long strtoul_l(const char *s, char **end, int base, void *locale) {
    (void)locale;
    return (unsigned long)strtoull(s, end, base);
}
YCL_EXPORT unsigned long long strtoull_l(const char *s, char **end, int base, void *locale) {
    (void)locale;
    return strtoull(s, end, base);
}

size_t mbrtowc(int *, const char *, size_t, void *);
size_t wcrtomb(char *, int, void *);
int mbtowc(int *, const char *, size_t);
int wctomb(char *, int);
size_t mbsrtowcs(int *, const char **, size_t, void *);
size_t wcsrtombs(char *, const int **, size_t, void *);
size_t mbsnrtowcs(int *, const char **, size_t, size_t, void *);
size_t wcsnrtombs(char *, const int **, size_t, size_t, void *);
YCL_EXPORT size_t mbrtowc_l(int *pwc, const char *s, size_t n, void *ps, void *locale) {
    (void)locale;
    return mbrtowc(pwc, s, n, ps);
}
YCL_EXPORT size_t wcrtomb_l(char *s, int wc, void *ps, void *locale) {
    (void)locale;
    return wcrtomb(s, wc, ps);
}
YCL_EXPORT int mbtowc_l(int *pwc, const char *s, size_t n, void *locale) {
    (void)locale;
    return mbtowc(pwc, s, n);
}
YCL_EXPORT int wctomb_l(char *s, int wc, void *locale) {
    (void)locale;
    return wctomb(s, wc);
}
YCL_EXPORT size_t mbsrtowcs_l(int *d, const char **s, size_t n, void *ps, void *locale) {
    (void)locale;
    return mbsrtowcs(d, s, n, ps);
}
YCL_EXPORT size_t wcsrtombs_l(char *d, const int **s, size_t n, void *ps, void *locale) {
    (void)locale;
    return wcsrtombs(d, s, n, ps);
}
YCL_EXPORT size_t mbsnrtowcs_l(int *d, const char **s, size_t nms, size_t n, void *ps, void *locale) {
    (void)locale;
    return mbsnrtowcs(d, s, nms, n, ps);
}
YCL_EXPORT size_t wcsnrtombs_l(char *d, const int **s, size_t nwc, size_t n, void *ps, void *locale) {
    (void)locale;
    return wcsnrtombs(d, s, nwc, n, ps);
}
YCL_EXPORT int btowc_l(int c, void *locale) {
    (void)locale;
    return c >= 0 && c < 0x80 ? c : -1;
}
YCL_EXPORT int wctob_l(int c, void *locale) {
    (void)locale;
    return c >= 0 && c < 0x80 ? c : -1;
}
YCL_EXPORT size_t mbrlen_l(const char *s, size_t n, void *ps, void *locale) {
    (void)locale;
    return mbrtowc(0, s, n, ps);
}

int vsnprintf(char *, size_t, const char *, va_list);
int vasprintf(char **, const char *, va_list);
int vfprintf(FILE *, const char *, va_list);
YCL_EXPORT int snprintf_l(char *s, size_t n, void *locale, const char *fmt, ...) {
    (void)locale;
    va_list a;
    va_start(a, fmt);
    int r = vsnprintf(s, n, fmt, a);
    va_end(a);
    return r;
}
YCL_EXPORT int vsnprintf_l(char *s, size_t n, void *locale, const char *fmt, va_list a) {
    (void)locale;
    return vsnprintf(s, n, fmt, a);
}
YCL_EXPORT int asprintf_l(char **s, void *locale, const char *fmt, ...) {
    (void)locale;
    va_list a;
    va_start(a, fmt);
    int r = vasprintf(s, fmt, a);
    va_end(a);
    return r;
}
YCL_EXPORT int vasprintf_l(char **s, void *locale, const char *fmt, va_list a) {
    (void)locale;
    return vasprintf(s, fmt, a);
}
YCL_EXPORT int fprintf_l(FILE *f, void *locale, const char *fmt, ...) {
    (void)locale;
    va_list a;
    va_start(a, fmt);
    int r = vfprintf(f, fmt, a);
    va_end(a);
    return r;
}
YCL_EXPORT int sprintf_l(char *s, void *locale, const char *fmt, ...) {
    (void)locale;
    va_list a;
    va_start(a, fmt);
    int r = vsnprintf(s, (size_t)-1 >> 1, fmt, a);
    va_end(a);
    return r;
}
