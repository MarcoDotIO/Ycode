/* Ycode freestanding <stdio.h>: the stream functions libunwind uses. */
#ifndef YCL_STDIO_H
#define YCL_STDIO_H
#include <stdarg.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct __sFILE FILE;
extern FILE *__stderrp;
#define stderr __stderrp
int fprintf(FILE *, const char *, ...);
int vfprintf(FILE *, const char *, va_list);
int fflush(FILE *);
size_t fwrite(const void *, size_t, size_t, FILE *);
int snprintf(char *, size_t, const char *, ...);
#ifdef __cplusplus
}
#endif
#endif
