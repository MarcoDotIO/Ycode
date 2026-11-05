/* Ycode freestanding <assert.h>. */
#ifndef YCL_ASSERT_H
#define YCL_ASSERT_H
#ifdef __cplusplus
extern "C" {
#endif
void __assert_rtn(const char *, const char *, int, const char *) __attribute__((noreturn));
#ifdef __cplusplus
}
#endif
#endif
#undef assert
#ifdef NDEBUG
#define assert(e) ((void)0)
#else
#define assert(e) ((void)((e) ? 0 : (__assert_rtn(__func__, __FILE__, __LINE__, #e), 0)))
#endif
