// sbext: our probe of the simulator's sandbox-extension calls (stage 7,
// specs/simulator/sandbox-extensions.md). Calls the exported functions
// sandbox_extension_issue_file / _consume / _release (interop names; the
// prototypes are our own declarations) and prints what comes back.
// Usage: sbext <class> <path> [flags]
//        sbext consume <token>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
extern int64_t sandbox_extension_consume(const char *token);
extern int sandbox_extension_release(int64_t handle);

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "consume")) {
        errno = 0;
        int64_t h = sandbox_extension_consume(argv[2]);
        printf("consume -> %lld errno %d\n", (long long)h, errno);
        if (h >= 0) { errno = 0; int r = sandbox_extension_release(h); printf("release(%lld) -> %d errno %d\n", (long long)h, r, errno); }
        return 0;
    }
    if (argc < 3) { fprintf(stderr, "usage: sbext <class> <path> [flags] | consume <token>\n"); return 64; }
    uint32_t flags = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 0;
    errno = 0;
    char *token = sandbox_extension_issue_file(argv[1], argv[2], flags);
    int e = errno;
    printf("issue(%s, %s, 0x%x) -> %s errno %d\n", argv[1], argv[2], flags, token ? token : "NULL", e);
    if (!token) return 1;
    printf("token length %zu\n", strlen(token));
    errno = 0;
    int64_t h = sandbox_extension_consume(token);
    printf("consume -> %lld errno %d\n", (long long)h, errno);
    errno = 0;
    int64_t h2 = sandbox_extension_consume(token);
    printf("consume again -> %lld errno %d\n", (long long)h2, errno);
    errno = 0;
    printf("consume garbage -> %lld errno %d\n", (long long)sandbox_extension_consume("not-a-token"), errno);
    if (h >= 0) { errno = 0; int r = sandbox_extension_release(h); printf("release(%lld) -> %d errno %d\n", (long long)h, r, errno); }
    if (h2 >= 0) { errno = 0; int r = sandbox_extension_release(h2); printf("release(%lld) -> %d errno %d\n", (long long)h2, r, errno); }
    errno = 0;
    printf("release(999999) -> %d errno %d\n", sandbox_extension_release(999999), errno);
    free(token);
    return 0;
}
