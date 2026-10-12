/*
 * ABI probe (callee side), compiled with the library flags by
 * common/abi_check.py. Clean-room Ycode code.
 */
typedef __builtin_va_list va_list_t;

__attribute__((visibility("default"))) int yc_abi_variadic(int n, ...)
{
    va_list_t ap;
    __builtin_va_start(ap, n);
    int a = __builtin_va_arg(ap, int);
    long b = __builtin_va_arg(ap, long);
    __builtin_va_end(ap);
    return a + (int)b + n;
}

/* Ten arguments: the 9th (char) and 10th (short) go on the stack. */
__attribute__((visibility("default"))) int yc_abi_many(long a0, long a1, long a2, long a3, long a4, long a5,
                                                       long a6, long a7, char c8, short s9)
{
    return (int)(a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7) + c8 + s9;
}
