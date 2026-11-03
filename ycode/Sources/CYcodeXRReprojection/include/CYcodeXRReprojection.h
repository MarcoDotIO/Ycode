/* CYcodeXRReprojection: the headset viewer's depth re-projection on the GPU
 * (specs/simulator/xr-depth.md §5). Ycode's own code.
 *
 * The newest picture of the stream (BGRA, sRGB-encoded), its inverse-depth
 * image (u16, q / 65535 = near / z) and, optionally, the foveated inset are
 * kept in textures; every headset frame each eye is drawn as a grid mesh
 * displaced by the depth, from the pose the picture was rendered for to the
 * eye's current pose (one 4 x 4 matrix, made by YcodeXRReprojection).
 *
 * Vulkan only, through vkGetInstanceProcAddr: either on the caller's device
 * (the OpenXR session's, CYcodeOpenXR's yxr_vulkan) or, for tests and the
 * benchmark, on a device of its own (the Vulkan loader, libvulkan.so.1,
 * opened at run time). Interfaces from the Vulkan 1.3 specification and the
 * CVulkan target's vendored headers (Apache-2.0). Without a loader (macOS)
 * creation fails with a message. */
#ifndef CYCODE_XR_REPROJECTION_H
#define CYCODE_XR_REPROJECTION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The caller's Vulkan objects (as yxr_vulkan_handles gives them). */
typedef struct {
    void *get_instance_proc_addr;   /* PFN_vkGetInstanceProcAddr */
    void *instance;                 /* VkInstance */
    void *physical_device;          /* VkPhysicalDevice */
    void *device;                   /* VkDevice */
    uint32_t queue_family;
    void *queue;                    /* VkQueue (the caller serialises submissions) */
    int anisotropy;                 /* the device was created with samplerAnisotropy */
} yrp_vulkan;

typedef struct yrp_context yrp_context;

/* vk NULL: an instance and device of its own (headless). NULL on failure. */
yrp_context *yrp_create(const yrp_vulkan *vk, char *error, size_t error_size);
void yrp_destroy(yrp_context *c);

/* The source picture: BGRA rows of `stride` bytes (sRGB-encoded). Copied to a
 * staging buffer now; the GPU copy is recorded by the next yrp_render. 0 ok. */
int yrp_set_colour(yrp_context *c, const void *bgra, int width, int height, int stride);

/* The same from a video picture (BT.709 limited range): its planes go to the
 * GPU, which converts them into the colour image (display-stream.md §14).
 * YRP_NV12: y and u (interleaved UV, height / 2 rows). YRP_YUV444: y, u, v, full size. 0 ok. */
enum { YRP_NV12 = 0, YRP_YUV444 = 1 };
int yrp_set_colour_yuv(yrp_context *c, int format, const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height);
int yrp_set_colour_nv12(yrp_context *c, const uint8_t *y, const uint8_t *uv, int pitch, int width, int height);

/* Runs what is staged and copies the colour image's level 0 out (BGRA;
 * `size` at least width x height x 4). For tests: it waits for the GPU. 0 ok. */
int yrp_read_colour(yrp_context *c, void *bgra, size_t size);

/* The inverse-depth image (u16 rows, no padding). 0 ok. */
int yrp_set_depth(yrp_context *c, const uint16_t *q, int width, int height);

/* The foveated inset: BGRA of `width` x `height` (sRGB; straight alpha, its
 * soft edge, blends it over the picture); it covers the source picture's pixels [x, x + w) x [y, y + h)
 * of a picture `full_width` x `full_height`. width 0 removes it. 0 ok. */
int yrp_set_inset(yrp_context *c, const void *bgra, int width, int height, int stride,
                  int x, int y, int w, int h, int full_width, int full_height);

/* The room's environment (message 0x0D): six faces of size x size in the
 * order +X, -X, +Y, -Y, +Z, -Z (rows top to bottom), format 1 = RGBA16F
 * (linear half floats), 2 = RGBA8 sRGB. Drawn at infinity behind everything. 0 ok. */
int yrp_set_environment(yrp_context *c, const void *faces, int format, int size);

/* The environment's shape: inverse-depth samples of six faces (+X ... -Z, n x n
 * each, n odd, sample j of a row at u = j / (n - 1)), so the faces are meshes
 * drawn from a point in the room; q NULL: at infinity. 0 ok. */
int yrp_set_environment_depth(yrp_context *c, const uint16_t *q, int n);

/* The world cache: six faces of `face_size` (colour + inverse depth), empty
 * until updated; 0 removes it. 0 ok. */
int yrp_cache_enable(yrp_context *c, int face_size);
/* Empties it (a recentre). */
int yrp_cache_clear(yrp_context *c);

enum { YRP_MODE_STRETCH = 0, YRP_MODE_BACKGROUND = 1, YRP_MODE_DISCARD = 2 };

typedef struct {
    float matrix[16];               /* column-major: source homogeneous view point -> destination clip */
    float tangents[4];              /* the source projection: left, right, up, down (left, down negative) */
    float near_distance;            /* the source's near (m) */
    float edge_ratio;               /* depth edge: farthest / nearest distance above this (e.g. 1.08) */
    int grid_step;                  /* depth texels per grid cell (1, 2, 4) */
    int mode;                       /* YRP_MODE_* */
} yrp_params;

/* Draws the fresh picture into the cache faces set in `face_mask` (bit f:
 * face f), with `face_matrix[f]` taking the picture's homogeneous view
 * points to face f's clip space (90 x 90 degrees, near = the picture's).
 * Newest wins where the picture covers; depth edges go in filled from their far side. 0 ok. */
int yrp_cache_update(yrp_context *c, const yrp_params *fresh, const float face_matrix[6][16], unsigned face_mask);

/* Where to draw. image 0: the context's own offscreen image (width x
 * height, B8G8R8A8_SRGB; read back with yrp_read). Otherwise a VkImage of
 * `format` with colour-attachment usage, left in COLOR_ATTACHMENT_OPTIMAL
 * (an OpenXR swapchain image). depth_image 0: a depth buffer of the
 * context's own; otherwise a D32_SFLOAT image (an OpenXR depth swapchain
 * image), left in DEPTH_STENCIL_ATTACHMENT_OPTIMAL with reverse-Z depth. */
typedef struct {
    uint64_t image;
    int64_t format;
    uint32_t width, height;
    uint64_t depth_image;
} yrp_target;

/* One eye's frame, drawn in this order: the environment (env_mask bit f:
 * face f, env_matrix[f]: face f's view points -> the eye's clip, at
 * infinity), the cache (cache_mask, cache_matrix), then the fresh picture
 * (fresh_enabled, fresh.matrix) over them with its edges faded over `fade`
 * (uv; 0: none). Matrices from YcodeXRReprojection. */
typedef struct {
    int fresh_enabled;
    yrp_params fresh;
    float fade;
    unsigned env_mask;
    float env_matrix[6][16];
    float env_gain;                 /* the environment's exposure (1: as sent) */
    unsigned cache_mask;
    float cache_matrix[6][16];
    int fresh_under;                /* 1: the fresh picture under the cache (its pose is not trusted: the head moved) */
} yrp_frame;

/* Records the uploads (if any are new) and the draws, and submits them to
 * the queue (the caller holds its queue lock). Does not wait. 0 ok. */
int yrp_render(yrp_context *c, const yrp_target *t, const yrp_frame *f);

/* Waits for every submission. 0 ok. */
int yrp_wait(yrp_context *c);

/* Waits, then copies the offscreen image (B8G8R8A8, rows of width * 4) into
 * `bgra` (capacity `size`). 0 ok. */
int yrp_read(yrp_context *c, void *bgra, size_t size);

/* GPU milliseconds of the newest finished render (uploads included), or -1. */
double yrp_gpu_ms(yrp_context *c);
/* The device's name. */
const char *yrp_device_name(yrp_context *c);
/* The last error. */
const char *yrp_error(yrp_context *c);

#ifdef __cplusplus
}
#endif

#endif
