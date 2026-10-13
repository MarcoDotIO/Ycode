// movetest (Ycode's own code): checks ycode/Sources/CKVM/hostcopy.c memmove/memcpy against a byte-wise reference
// for every size 0..300 and every overlap offset -70..70.
// Build: clang -O2 -o movetest movetest.c ../../../../ycode/Sources/CKVM/hostcopy.c -ldl
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static void ref(unsigned char *d, const unsigned char *s, size_t n) {
    unsigned char t[1024];
    for (size_t i = 0; i < n; i++) t[i] = s[i];
    for (size_t i = 0; i < n; i++) d[i] = t[i];
}
int main(void) {
    static unsigned char a[2048], b[2048];
    void *(*volatile mm)(void *, const void *, size_t) = memmove;
    void *(*volatile mc)(void *, const void *, size_t) = memcpy;
    unsigned long fails = 0, checks = 0;
    for (size_t n = 0; n <= 300; n++)
        for (int off = -70; off <= 70; off++)
            for (int align = 0; align < 4; align++) {
                for (int i = 0; i < 2048; i++) a[i] = b[i] = (unsigned char)(i * 131 + n * 7 + align);
                size_t s = 600 + align, d = (size_t)((long)s + off);
                mm(a + d, a + s, n);
                ref(b + d, b + s, n);
                checks++;
                if (memcmp(a, b, sizeof a) != 0) { if (fails++ < 5) printf("memmove n %zu off %d align %d wrong\n", n, off, align); }
                if (off <= -(int)n || off >= (int)n) {
                    for (int i = 0; i < 2048; i++) a[i] = b[i] = (unsigned char)(i * 17 + n);
                    mc(a + d, a + s, n); ref(b + d, b + s, n);
                    if (memcmp(a, b, sizeof a) != 0) { if (fails++ < 5) printf("memcpy n %zu off %d wrong\n", n, off); }
                }
            }
    printf("movetest: %lu checks, %lu failures\n", checks, fails);
    return fails != 0;
}
