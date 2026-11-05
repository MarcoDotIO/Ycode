/* Ycode freestanding <dlfcn.h>: Dl_info and dladdr (public layout). */
#ifndef YCL_DLFCN_H
#define YCL_DLFCN_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct dl_info {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;
int dladdr(const void *, Dl_info *);
void *dlsym(void *, const char *);
#define RTLD_DEFAULT ((void *)-2)
#ifdef __cplusplus
}
#endif
#endif
