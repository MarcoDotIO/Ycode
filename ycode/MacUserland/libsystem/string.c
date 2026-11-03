// string.c - memory and string functions of Ycode's libSystem
// (specs/macos/libsystem.md §6). Clean-room Ycode code from the C standard's
// descriptions. The block moves use libsystem_platform's primitives.
#include "ycl.h"

YCL_EXPORT void *memmove(void *d, const void *s, size_t n) { return _platform_memmove(d, s, n); }
YCL_EXPORT void *memcpy(void *d, const void *s, size_t n) { return _platform_memmove(d, s, n); }
YCL_EXPORT void *memset(void *d, int c, size_t n) { return _platform_memset(d, c, n); }
YCL_EXPORT void bzero(void *d, size_t n) { _platform_memset(d, 0, n); }
YCL_EXPORT int memcmp(const void *a, const void *b, size_t n) { return _platform_memcmp(a, b, n); }
YCL_EXPORT int bcmp(const void *a, const void *b, size_t n) { return _platform_memcmp(a, b, n); }
YCL_EXPORT size_t strlen(const char *s) { return _platform_strlen(s); }

YCL_EXPORT void *memchr(const void *p, int c, size_t n) {
    const unsigned char *s = p;
    for (size_t i = 0; i < n; i++)
        if (s[i] == (unsigned char)c) return (void *)(s + i);
    return 0;
}

YCL_EXPORT size_t strnlen(const char *s, size_t max) {
    size_t n = 0;
    while (n < max && s[n]) n++;
    return n;
}

YCL_EXPORT int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) a++, b++;
    return (unsigned char)*a - (unsigned char)*b;
}

YCL_EXPORT int strncmp(const char *a, const char *b, size_t n) {
    for (; n; n--, a++, b++) {
        if (*a != *b || !*a) return (unsigned char)*a - (unsigned char)*b;
    }
    return 0;
}

static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
YCL_EXPORT int strcasecmp(const char *a, const char *b) {
    while (*a && lower((unsigned char)*a) == lower((unsigned char)*b)) a++, b++;
    return lower((unsigned char)*a) - lower((unsigned char)*b);
}
YCL_EXPORT int strncasecmp(const char *a, const char *b, size_t n) {
    for (; n; n--, a++, b++) {
        int x = lower((unsigned char)*a), y = lower((unsigned char)*b);
        if (x != y || !x) return x - y;
    }
    return 0;
}

YCL_EXPORT char *strchr(const char *s, int c) {
    for (;; s++) {
        if (*s == (char)c) return (char *)s;
        if (!*s) return 0;
    }
}

YCL_EXPORT char *strrchr(const char *s, int c) {
    const char *found = 0;
    for (;; s++) {
        if (*s == (char)c) found = s;
        if (!*s) return (char *)found;
    }
}

YCL_EXPORT char *strcpy(char *d, const char *s) {
    memmove(d, s, strlen(s) + 1);
    return d;
}

YCL_EXPORT char *strncpy(char *d, const char *s, size_t n) {
    size_t k = strnlen(s, n);
    memmove(d, s, k);
    if (k < n) memset(d + k, 0, n - k);
    return d;
}

YCL_EXPORT char *strcat(char *d, const char *s) {
    strcpy(d + strlen(d), s);
    return d;
}

YCL_EXPORT char *strncat(char *d, const char *s, size_t n) {
    size_t at = strlen(d), k = strnlen(s, n);
    memmove(d + at, s, k);
    d[at + k] = 0;
    return d;
}

YCL_EXPORT size_t strlcpy(char *d, const char *s, size_t size) {
    size_t n = strlen(s);
    if (size) {
        size_t k = n < size - 1 ? n : size - 1;
        memmove(d, s, k);
        d[k] = 0;
    }
    return n;
}

YCL_EXPORT size_t strlcat(char *d, const char *s, size_t size) {
    size_t at = strnlen(d, size);
    if (at == size) return size + strlen(s);
    return at + strlcpy(d + at, s, size - at);
}

YCL_EXPORT char *strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

YCL_EXPORT char *strndup(const char *s, size_t max) {
    size_t n = strnlen(s, max);
    char *p = malloc(n + 1);
    if (p) {
        memcpy(p, s, n);
        p[n] = 0;
    }
    return p;
}

YCL_EXPORT char *strstr(const char *hay, const char *needle) {
    size_t n = strlen(needle);
    if (!n) return (char *)hay;
    for (; *hay; hay++)
        if (*hay == *needle && strncmp(hay, needle, n) == 0) return (char *)hay;
    return 0;
}

YCL_EXPORT size_t strspn(const char *s, const char *accept) {
    size_t n = 0;
    while (s[n] && strchr(accept, s[n])) n++;
    return n;
}

YCL_EXPORT size_t strcspn(const char *s, const char *reject) {
    size_t n = 0;
    while (s[n] && !strchr(reject, s[n])) n++;
    return n;
}

YCL_EXPORT char *strpbrk(const char *s, const char *set) {
    s += strcspn(s, set);
    return *s ? (char *)s : 0;
}

YCL_EXPORT char *strtok_r(char *s, const char *sep, char **save) {
    if (!s) s = *save;
    if (!s) return 0;
    s += strspn(s, sep);
    if (!*s) {
        *save = 0;
        return 0;
    }
    char *end = s + strcspn(s, sep);
    if (*end) *end++ = 0;
    else end = 0;
    *save = end;
    return s;
}

YCL_EXPORT char *strtok(char *s, const char *sep) {
    static char *save;
    return strtok_r(s, sep, &save);
}

YCL_EXPORT char *strsep(char **sp, const char *sep) {
    char *s = *sp;
    if (!s) return 0;
    char *end = s + strcspn(s, sep);
    if (*end) *end++ = 0, *sp = end;
    else *sp = 0;
    return s;
}

// The fortified forms (the SDK's _FORTIFY_SOURCE): `size` is the
// destination's known size.
YCL_EXPORT void *__memcpy_chk(void *d, const void *s, size_t n, size_t size) {
    if (n > size) abort();
    return memmove(d, s, n);
}
YCL_EXPORT void *__memmove_chk(void *d, const void *s, size_t n, size_t size) {
    if (n > size) abort();
    return memmove(d, s, n);
}
YCL_EXPORT void *__memset_chk(void *d, int c, size_t n, size_t size) {
    if (n > size) abort();
    return memset(d, c, n);
}
YCL_EXPORT char *__strcpy_chk(char *d, const char *s, size_t size) {
    if (strlen(s) >= size) abort();
    return strcpy(d, s);
}
YCL_EXPORT char *__strcat_chk(char *d, const char *s, size_t size) {
    if (strlen(d) + strlen(s) >= size) abort();
    return strcat(d, s);
}
YCL_EXPORT char *__strncpy_chk(char *d, const char *s, size_t n, size_t size) {
    if (n > size) abort();
    return strncpy(d, s, n);
}
YCL_EXPORT size_t __strlcpy_chk(char *d, const char *s, size_t n, size_t size) {
    if (n > size) abort();
    return strlcpy(d, s, n);
}
YCL_EXPORT size_t __strlcat_chk(char *d, const char *s, size_t n, size_t size) {
    if (n > size) abort();
    return strlcat(d, s, n);
}

// strerror: the messages of the common errno values (public <sys/errno.h>
// meanings), in Ycode's own table.
static const struct {
    int code;
    const char *text;
} messages[] = {
    {0, "Undefined error: 0"},
    {1, "Operation not permitted"},
    {2, "No such file or directory"},
    {3, "No such process"},
    {4, "Interrupted system call"},
    {5, "Input/output error"},
    {9, "Bad file descriptor"},
    {12, "Cannot allocate memory"},
    {13, "Permission denied"},
    {14, "Bad address"},
    {16, "Resource busy"},
    {17, "File exists"},
    {20, "Not a directory"},
    {21, "Is a directory"},
    {22, "Invalid argument"},
    {24, "Too many open files"},
    {25, "Inappropriate ioctl for device"},
    {28, "No space left on device"},
    {29, "Illegal seek"},
    {30, "Read-only file system"},
    {32, "Broken pipe"},
    {34, "Result too large"},
    {35, "Resource temporarily unavailable"},
    {45, "Operation not supported"},
    {60, "Operation timed out"},
    {61, "Connection refused"},
    {63, "File name too long"},
    {66, "Directory not empty"},
    {78, "Function not implemented"},
    {84, "Value too large to be stored in data type"},
    {89, "Operation canceled"},
};

YCL_EXPORT int strerror_r(int code, char *buf, size_t size) {
    for (size_t i = 0; i < sizeof messages / sizeof messages[0]; i++) {
        if (messages[i].code == code) {
            strlcpy(buf, messages[i].text, size);
            return 0;
        }
    }
    snprintf(buf, size, "Unknown error: %d", code);
    return YCL_EINVAL;
}

YCL_EXPORT char *strerror(int code) {
    static char buf[64];
    strerror_r(code, buf, sizeof buf);
    return buf;
}
