/* Ycode freestanding <string.h>: the functions libunwind uses. */
#ifndef YCL_STRING_H
#define YCL_STRING_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
void *memset(void *, int, size_t);
int memcmp(const void *, const void *, size_t);
size_t strlen(const char *);
int strcmp(const char *, const char *);
void bzero(void *, size_t);
#ifdef __cplusplus
}
#endif
#endif
