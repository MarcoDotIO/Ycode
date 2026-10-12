/*
 * string.c - the _platform_* memory and string functions of Ycode's
 * libsystem_platform.
 *
 * Clean-room Ycode code. Behavior follows the C standard and the public
 * man pages (memmove(3), memccpy(3), memset_pattern(3), strlcpy(3),
 * strnlen(3), bzero(3), ...). The simulator's libsystem_c re-exports the
 * standard names under these _platform_ names (host-library-surface.md
 * section 7), so memcpy and memmove both reach _platform_memmove.
 *
 * Built with -ffreestanding -fno-builtin: the compiler never turns these
 * loops into calls to the functions being defined.
 */
#include "yc_platform.h"

typedef yc_u64 __attribute__((may_alias, aligned(1))) yc_unaligned_u64;
typedef yc_u64 __attribute__((may_alias)) yc_word;

#define WORD sizeof(yc_word)
#define ONES 0x0101010101010101ull
#define HIGHS 0x8080808080808080ull
/* Nonzero iff some byte of w is zero. */
#define HAS_ZERO(w) (((w) - ONES) & ~(w) & HIGHS)

YC_EXPORT void *YC_FN(_platform_memmove)(void *dst, const void *src, yc_size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d == s || n == 0)
        return dst;
    if ((yc_uintptr_t)d - (yc_uintptr_t)s >= n) {
        /* Forward: the destination does not start inside the source. */
        if ((((yc_uintptr_t)d ^ (yc_uintptr_t)s) & (WORD - 1)) == 0) {
            while (n && ((yc_uintptr_t)d & (WORD - 1))) {
                *d++ = *s++;
                n--;
            }
            while (n >= 4 * WORD) {
                yc_word a = ((const yc_word *)s)[0], b = ((const yc_word *)s)[1];
                yc_word c = ((const yc_word *)s)[2], e = ((const yc_word *)s)[3];
                ((yc_word *)d)[0] = a;
                ((yc_word *)d)[1] = b;
                ((yc_word *)d)[2] = c;
                ((yc_word *)d)[3] = e;
                d += 4 * WORD;
                s += 4 * WORD;
                n -= 4 * WORD;
            }
            while (n >= WORD) {
                *(yc_word *)d = *(const yc_word *)s;
                d += WORD;
                s += WORD;
                n -= WORD;
            }
        }
        while (n--)
            *d++ = *s++;
    } else {
        /* Backward: the regions overlap with the destination above. */
        d += n;
        s += n;
        if ((((yc_uintptr_t)d ^ (yc_uintptr_t)s) & (WORD - 1)) == 0) {
            while (n && ((yc_uintptr_t)d & (WORD - 1))) {
                *--d = *--s;
                n--;
            }
            while (n >= WORD) {
                d -= WORD;
                s -= WORD;
                *(yc_word *)d = *(const yc_word *)s;
                n -= WORD;
            }
        }
        while (n--)
            *--d = *--s;
    }
    return dst;
}

YC_EXPORT void *YC_FN(_platform_memccpy)(void *dst, const void *src, int c, yc_size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    unsigned char ch = (unsigned char)c;
    while (n--) {
        unsigned char v = *s++;
        *d++ = v;
        if (v == ch)
            return d;
    }
    return YC_NULL;
}

YC_EXPORT void *YC_FN(_platform_memchr)(const void *p, int c, yc_size_t n)
{
    const unsigned char *s = p;
    unsigned char ch = (unsigned char)c;
    for (; n; n--, s++)
        if (*s == ch)
            return (void *)s;
    return YC_NULL;
}

YC_EXPORT int YC_FN(_platform_memcmp)(const void *a, const void *b, yc_size_t n)
{
    const unsigned char *x = a, *y = b;
    while (n >= WORD && *(const yc_unaligned_u64 *)x == *(const yc_unaligned_u64 *)y) {
        x += WORD;
        y += WORD;
        n -= WORD;
    }
    for (; n; n--, x++, y++)
        if (*x != *y)
            return (int)*x - (int)*y;
    return 0;
}

/* 0 when all n bytes at p are zero, 1 otherwise. */
YC_EXPORT int YC_FN(_platform_memcmp_zero_aligned8)(const void *p, yc_size_t n)
{
    const unsigned char *s = p;
    while (n >= WORD) {
        if (*(const yc_unaligned_u64 *)s != 0)
            return 1;
        s += WORD;
        n -= WORD;
    }
    for (; n; n--, s++)
        if (*s)
            return 1;
    return 0;
}

static void fill_bytes(unsigned char *d, yc_u64 pattern, yc_size_t n)
{
    while (n && ((yc_uintptr_t)d & (WORD - 1))) {
        *d++ = (unsigned char)pattern;
        n--;
    }
    while (n >= WORD) {
        *(yc_word *)d = pattern;
        d += WORD;
        n -= WORD;
    }
    while (n--)
        *d++ = (unsigned char)pattern;
}

YC_EXPORT void *YC_FN(_platform_memset)(void *dst, int c, yc_size_t n)
{
    fill_bytes(dst, (yc_u64)(unsigned char)c * ONES, n);
    return dst;
}

YC_EXPORT void YC_FN(_platform_bzero)(void *dst, yc_size_t n)
{
    fill_bytes(dst, 0, n);
}

YC_EXPORT void YC_FN(__bzero)(void *dst, yc_size_t n)
{
    fill_bytes(dst, 0, n);
}

/* memset_pattern{4,8,16}: repeat the pattern over len bytes; the last copy
 * may be partial. */
static void fill_pattern(unsigned char *d, const unsigned char *pat, yc_size_t plen, yc_size_t len)
{
    yc_size_t i = 0;
    while (len--) {
        *d++ = pat[i];
        if (++i == plen)
            i = 0;
    }
}

YC_EXPORT void YC_FN(_platform_memset_pattern4)(void *dst, const void *pattern, yc_size_t len)
{
    fill_pattern(dst, pattern, 4, len);
}

YC_EXPORT void YC_FN(_platform_memset_pattern8)(void *dst, const void *pattern, yc_size_t len)
{
    fill_pattern(dst, pattern, 8, len);
}

YC_EXPORT void YC_FN(_platform_memset_pattern16)(void *dst, const void *pattern, yc_size_t len)
{
    fill_pattern(dst, pattern, 16, len);
}

YC_HIDDEN yc_size_t __yc_strlen(const char *str)
{
    const char *s = str;
    /* Bytes up to the next 8-byte boundary, then whole aligned words (an
     * aligned word never crosses a page boundary). */
    while ((yc_uintptr_t)s & (WORD - 1)) {
        if (*s == 0)
            return (yc_size_t)(s - str);
        s++;
    }
    for (;;) {
        yc_word w = *(const yc_word *)s;
        if (HAS_ZERO(w))
            break;
        s += WORD;
    }
    while (*s)
        s++;
    return (yc_size_t)(s - str);
}

YC_EXPORT yc_size_t YC_FN(_platform_strlen)(const char *s)
{
    return __yc_strlen(s);
}

YC_EXPORT yc_size_t YC_FN(_platform_strnlen)(const char *s, yc_size_t max)
{
    yc_size_t n = 0;
    while (n < max && s[n])
        n++;
    return n;
}

YC_EXPORT char *YC_FN(_platform_strchr)(const char *s, int c)
{
    char ch = (char)c;
    for (;; s++) {
        if (*s == ch)
            return (char *)s;
        if (*s == 0)
            return YC_NULL;
    }
}

YC_EXPORT int YC_FN(_platform_strcmp)(const char *a, const char *b)
{
    const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
    while (*x && *x == *y) {
        x++;
        y++;
    }
    return (int)*x - (int)*y;
}

YC_EXPORT int YC_FN(_platform_strncmp)(const char *a, const char *b, yc_size_t n)
{
    const unsigned char *x = (const unsigned char *)a, *y = (const unsigned char *)b;
    for (; n; n--, x++, y++) {
        if (*x != *y)
            return (int)*x - (int)*y;
        if (*x == 0)
            return 0;
    }
    return 0;
}

YC_EXPORT char *YC_FN(_platform_strcpy)(char *dst, const char *src)
{
    char *d = dst;
    while ((*d++ = *src++) != 0) {
    }
    return dst;
}

YC_EXPORT char *YC_FN(_platform_strncpy)(char *dst, const char *src, yc_size_t n)
{
    char *d = dst;
    while (n && *src) {
        *d++ = *src++;
        n--;
    }
    while (n--)
        *d++ = 0;
    return dst;
}

/* strlcpy: copy at most size-1 bytes, always terminate when size > 0,
 * return strlen(src). */
YC_EXPORT yc_size_t YC_FN(_platform_strlcpy)(char *dst, const char *src, yc_size_t size)
{
    yc_size_t len = __yc_strlen(src);
    if (size) {
        yc_size_t n = len < size - 1 ? len : size - 1;
        YC_FN(_platform_memmove)(dst, src, n);
        dst[n] = 0;
    }
    return len;
}

/* strlcat: append to a string in a buffer of the given total size; return
 * the length the result would have had (strnlen(dst, size) + strlen(src)). */
YC_EXPORT yc_size_t YC_FN(_platform_strlcat)(char *dst, const char *src, yc_size_t size)
{
    yc_size_t dlen = YC_FN(_platform_strnlen)(dst, size);
    yc_size_t slen = __yc_strlen(src);
    if (dlen == size)
        return size + slen;
    yc_size_t room = size - dlen - 1;
    yc_size_t n = slen < room ? slen : room;
    YC_FN(_platform_memmove)(dst + dlen, src, n);
    dst[dlen + n] = 0;
    return dlen + slen;
}

YC_EXPORT char *YC_FN(_platform_strstr)(const char *hay, const char *needle)
{
    if (*needle == 0)
        return (char *)hay;
    yc_size_t nlen = __yc_strlen(needle);
    for (; *hay; hay++) {
        if (*hay == *needle && YC_FN(_platform_strncmp)(hay, needle, nlen) == 0)
            return (char *)hay;
    }
    return YC_NULL;
}
