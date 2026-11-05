/* Ycode freestanding <pthread.h>: the read-write lock libunwind uses, in
   the public Darwin arm64 layout (200 bytes, initializer signature
   0x2DA8B3B4). */
#ifndef YCL_PTHREAD_H
#define YCL_PTHREAD_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    long __sig;
    char __opaque[192];
} pthread_rwlock_t;
#define PTHREAD_RWLOCK_INITIALIZER {0x2DA8B3B4, {0}}
int pthread_rwlock_rdlock(pthread_rwlock_t *);
int pthread_rwlock_wrlock(pthread_rwlock_t *);
int pthread_rwlock_unlock(pthread_rwlock_t *);
#ifdef __cplusplus
}
#endif
#endif
