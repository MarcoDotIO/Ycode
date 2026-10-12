/*
 * Private memcpy/memmove/memset/memcmp for each host library.
 *
 * Clean-room Ycode code. The compiler may emit calls to these four names
 * for structure copies and initialization even in -ffreestanding code. The
 * host libraries link no C library, so each library carries its own hidden
 * (non-exported) copy. A library that defines any of these names itself
 * suppresses this whole file.
 *
 * Built with -fno-builtin, so these loops are never turned back into calls.
 */
#include "yc_base.h"

YC_HIDDEN void *memcpy(void *dst, const void *src, yc_size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

YC_HIDDEN void *memmove(void *dst, const void *src, yc_size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d == s || n == 0) return dst;
    if (d < s || d >= s + n) {
        while (n--) *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

YC_HIDDEN void *memset(void *dst, int c, yc_size_t n)
{
    unsigned char *d = dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

YC_HIDDEN int memcmp(const void *a, const void *b, yc_size_t n)
{
    const unsigned char *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y) return (int)*x - (int)*y;
    return 0;
}
