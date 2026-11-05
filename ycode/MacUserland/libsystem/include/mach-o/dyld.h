/* Ycode freestanding <mach-o/dyld.h>: the image callbacks libunwind uses. */
#ifndef YCL_MACH_O_DYLD_H
#define YCL_MACH_O_DYLD_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct mach_header;
void _dyld_register_func_for_add_image(void (*)(const struct mach_header *, intptr_t));
void _dyld_register_func_for_remove_image(void (*)(const struct mach_header *, intptr_t));
#ifdef __cplusplus
}
#endif
#endif
