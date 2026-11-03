// dlfcn.c - <dlfcn.h> and the _dyld_* image queries for Ycode's libSystem
// (specs/macos/libsystem.md §8). Each call goes through the table Ycode's
// dyld installed in `ycode_dyld_api` (specs/macos/dyld.md §7.2).
#include "ycl.h"
#include "yc_dyld_api.h"

extern const struct yc_dyld_api *ycode_dyld_api;

static const char no_dyld[] = "Ycode's dyld table is missing";
static int no_dyld_pending;

YCL_EXPORT void *dlopen(const char *path, int mode) {
    if (!ycode_dyld_api) {
        no_dyld_pending = 1;
        return 0;
    }
    return ycode_dyld_api->dlopen(path, mode);
}

YCL_EXPORT void *dlsym(void *handle, const char *name) {
    if (!ycode_dyld_api) {
        no_dyld_pending = 1;
        return 0;
    }
    return ycode_dyld_api->dlsym(handle, name);
}

YCL_EXPORT int dlclose(void *handle) { return ycode_dyld_api ? ycode_dyld_api->dlclose(handle) : -1; }

YCL_EXPORT char *dlerror(void) {
    if (!ycode_dyld_api) {
        int pending = no_dyld_pending;
        no_dyld_pending = 0;
        return pending ? (char *)no_dyld : 0;
    }
    return (char *)ycode_dyld_api->dlerror();
}

YCL_EXPORT int dladdr(const void *address, struct yc_dl_info *info) {
    return ycode_dyld_api ? ycode_dyld_api->dladdr(address, info) : 0;
}

YCL_EXPORT uint32_t _dyld_image_count(void) { return ycode_dyld_api ? ycode_dyld_api->image_count() : 0; }
YCL_EXPORT const void *_dyld_get_image_header(uint32_t i) { return ycode_dyld_api ? ycode_dyld_api->image_header(i) : 0; }
YCL_EXPORT const char *_dyld_get_image_name(uint32_t i) { return ycode_dyld_api ? ycode_dyld_api->image_name(i) : 0; }
YCL_EXPORT intptr_t _dyld_get_image_vmaddr_slide(uint32_t i) { return ycode_dyld_api ? ycode_dyld_api->image_slide(i) : 0; }
YCL_EXPORT void _dyld_register_func_for_add_image(void (*callback)(const void *, intptr_t)) {
    if (ycode_dyld_api) ycode_dyld_api->add_image_callback(callback);
}
