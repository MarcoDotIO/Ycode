/*
 * Ycode stage-3 guest test program (specs/simulator/stage3-contract.md
 * section 9). Original Ycode code. Built for the iOS simulator platform by
 * build.sh in this directory, then run under ycode-simd --exec.
 */
#include <unistd.h>

int main(void)
{
    static const char line[] = "hello from the iOS simulator runtime on Linux\n";
    write(1, line, sizeof line - 1);    /* 46 bytes */
    return 0;
}
