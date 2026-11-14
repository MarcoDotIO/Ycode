/*
 * COVVulkan: the C side of OpenViews' Vulkan compositor (OVRender, round
 * R5; 09-open-design.md §3.6). Written from the Vulkan 1.3 specification.
 *
 * - Loads the Vulkan loader at run time (dlopen of libvulkan.so.1, or
 *   OV_VULKAN_LIBRARY / YCODE_VULKAN_LIBRARY). Nothing links against Vulkan:
 *   hosts without it build and report that no device is available.
 * - One device (Vulkan 1.3, dynamic rendering), one graphics queue, one
 *   pipeline that draws textured quads with premultiplied-alpha blending.
 * - A target: a swapchain on a VkSurfaceKHR the platform host created, or
 *   an offscreen image. Layers are RGBA8 textures updated from CPU pixels
 *   (only the changed rectangle is copied). A frame clears the target and
 *   draws a list of layers, each with an affine transform, an opacity and a
 *   scissor rectangle; the result can be read back.
 * - Frames are synchronous: a frame's commands complete before ovk_frame
 *   returns (one frame in flight), which keeps the host's run loop simple.
 *
 * Device choice: OV_VULKAN_DEVICE selects by substring of the device name,
 * or "cpu" / "gpu" by type; otherwise discrete > integrated > virtual > CPU.
 *
 * Vendored headers: vulkan/ holds the Khronos Vulkan headers 1.3.275
 * (Apache-2.0, notices kept), the same copy as ycode/Sources/CVulkan.
 */
#ifndef OV_COVVULKAN_H
#define OV_COVVULKAN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ovk_context ovk_context;

/* One layer draw: x' = a*x + c*y + tx, y' = b*x + d*y + ty maps layer pixels
 * to target pixels; the scissor is in target pixels. */
typedef struct {
    uint32_t layer;
    float a, b, c, d, tx, ty;
    float opacity;
    int32_t scissor_x, scissor_y, scissor_w, scissor_h;
} ovk_draw;

/* Loads the Vulkan loader; 0 on success. */
int ovk_load(char *err, size_t errlen);

/* Creates a device on an instance with `extensions` (the window system's).
 * Contexts with the same extensions share one instance, destroyed when the
 * last context is (ov_vulkan.c, "Shared instances"). `with_swapchain`
 * enables VK_KHR_swapchain on the device. */
ovk_context *ovk_create(const char *const *extensions, uint32_t extension_count, int with_swapchain,
                        char *err, size_t errlen);
void ovk_destroy(ovk_context *c);

const char *ovk_device_name(const ovk_context *c);
/* 1 for a CPU implementation (lavapipe), 0 otherwise. */
int ovk_device_is_cpu(const ovk_context *c);
/* The VkInstance, for the window system to create a surface on. */
void *ovk_instance(const ovk_context *c);

/* Uses `surface` (a VkSurfaceKHR, owned by the context from now on) and
 * creates a swapchain of `width` × `height` (or the surface's size). */
int ovk_attach_surface(ovk_context *c, uint64_t surface, uint32_t width, uint32_t height, char *err, size_t errlen);
/* Uses an offscreen target of `width` × `height` (RGBA8). */
int ovk_set_offscreen(ovk_context *c, uint32_t width, uint32_t height, char *err, size_t errlen);
/* Recreates the swapchain or offscreen image at a new size. */
int ovk_resize(ovk_context *c, uint32_t width, uint32_t height, char *err, size_t errlen);
void ovk_target_size(const ovk_context *c, uint32_t *width, uint32_t *height);

/* Layers: textures of `width` × `height` RGBA8 (premultiplied). Creating an
 * existing index with another size recreates it. */
int ovk_layer_ensure(ovk_context *c, uint32_t layer, uint32_t width, uint32_t height, char *err, size_t errlen);
/* Copies the rectangle (x, y, w, h) of `rgba` (the whole layer, rows of
 * width*4 bytes) into the layer; the GPU copy happens in the next frame. */
int ovk_layer_update(ovk_context *c, uint32_t layer, const void *rgba, uint32_t x, uint32_t y, uint32_t w, uint32_t h);
void ovk_layer_release(ovk_context *c, uint32_t layer);

/* Renders a frame: clear to `clear` (premultiplied RGBA 0…1), draw the
 * layers in order, present (swapchain), and copy the result for
 * ovk_readback when `readback` is set. Returns 0, 1 when the swapchain is
 * out of date (call ovk_resize), or -1 on error. */
int ovk_frame(ovk_context *c, const ovk_draw *draws, uint32_t draw_count, const float clear[4], int readback,
              char *err, size_t errlen);
/* The last read-back frame as RGBA8 rows (width*height*4 bytes). */
int ovk_readback(ovk_context *c, void *rgba, size_t size);

#ifdef __cplusplus
}
#endif

#endif
