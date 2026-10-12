/*
 * bitops.c - ffs/ffsl/ffsll and fls/flsl/flsll of Ycode's libsystem_platform.
 *
 * Clean-room Ycode code. ffs(3): the 1-based index of the least significant
 * set bit, 0 for 0. fls(3): the 1-based index of the most significant set
 * bit, 0 for 0.
 */
#include "yc_base.h"

YC_EXPORT int YC_FN(ffs)(int v) { return v ? __builtin_ctz((unsigned)v) + 1 : 0; }
YC_EXPORT int YC_FN(ffsl)(long v) { return v ? __builtin_ctzl((unsigned long)v) + 1 : 0; }
YC_EXPORT int YC_FN(ffsll)(long long v) { return v ? __builtin_ctzll((unsigned long long)v) + 1 : 0; }
YC_EXPORT int YC_FN(fls)(int v) { return v ? 32 - __builtin_clz((unsigned)v) : 0; }
YC_EXPORT int YC_FN(flsl)(long v) { return v ? (int)(8 * sizeof(long)) - __builtin_clzl((unsigned long)v) : 0; }
YC_EXPORT int YC_FN(flsll)(long long v) { return v ? 64 - __builtin_clzll((unsigned long long)v) : 0; }
