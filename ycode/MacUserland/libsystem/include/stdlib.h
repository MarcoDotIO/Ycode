/* Ycode freestanding <stdlib.h>: the functions libunwind uses. */
#ifndef YCL_STDLIB_H
#define YCL_STDLIB_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *malloc(size_t);
void *calloc(size_t, size_t);
void free(void *);
void abort(void) __attribute__((noreturn));
char *getenv(const char *);
#ifdef __cplusplus
}
#endif
#endif
