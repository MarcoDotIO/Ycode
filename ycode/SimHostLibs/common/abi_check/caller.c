/*
 * ABI probe (caller side), compiled with the library flags by
 * common/abi_check.py. Clean-room Ycode code.
 */
int yc_abi_variadic(int n, ...);
int yc_abi_many(long, long, long, long, long, long, long, long, char, short);

__attribute__((visibility("default"))) int yc_abi_call_variadic(void)
{
    return yc_abi_variadic(1, 0x11, 0x22l);
}

__attribute__((visibility("default"))) int yc_abi_call_many(void)
{
    return yc_abi_many(0, 1, 2, 3, 4, 5, 6, 7, (char)0x41, (short)0x1234);
}
