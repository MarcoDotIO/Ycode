// Milestone A sample: printf, argv, environment, exit status
// (specs/macos/macos-apps.md §9.1). Ycode's own test program.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    printf("hello from a macOS arm64 program (argc %d)\n", argc);
    for (int i = 1; i < argc; i++) printf("argv[%d] = %s\n", i, argv[i]);
    const char *home = getenv("YCODE_SAMPLE");
    printf("YCODE_SAMPLE = %s\n", home ? home : "(unset)");
    printf("numbers: %d %u %x %ld %lld %5d|%-5d| %05.1f %s %c %%\n", -42, 42u, 0xBEEF, -1234567890123L, 9007199254740993LL,
           7, 7, 3.25, "str", 'Z');
    char buffer[64];
    snprintf(buffer, sizeof buffer, "%s-%d", "snprintf", 64);
    puts(buffer);
    return argc > 1 && strcmp(argv[1], "fail") == 0 ? 3 : 0;
}
