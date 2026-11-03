/* CYcodeXRReprojection (specs/simulator/xr-depth.md §5). Ycode's own code;
 * Vulkan interfaces from the Vulkan 1.3 specification and the CVulkan
 * target's vendored headers (Apache-2.0). The shaders are Ycode's own GLSL
 * (shaders/), compiled to SPIR-V by scripts/xr-depth-shaders.sh. */
#include "CYcodeXRReprojection.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

#define VK_NO_PROTOTYPES 1
#include "../CVulkan/vulkan/vulkan_core.h"
#include "reproject_spv.h"

#define IFUNCS(X) \
    X(vkGetDeviceProcAddr) X(vkGetPhysicalDeviceMemoryProperties) X(vkGetPhysicalDeviceProperties) X(vkGetPhysicalDeviceFeatures) \
    X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkCreateDevice) X(vkDestroyInstance)

#define DFUNCS(X) \
    X(vkGetDeviceQueue) X(vkDestroyDevice) X(vkDeviceWaitIdle) \
    X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) X(vkBindBufferMemory) \
    X(vkAllocateMemory) X(vkFreeMemory) X(vkMapMemory) \
    X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) \
    X(vkCreateImageView) X(vkDestroyImageView) X(vkCreateSampler) X(vkDestroySampler) \
    X(vkCreateDescriptorSetLayout) X(vkDestroyDescriptorSetLayout) X(vkCreatePipelineLayout) X(vkDestroyPipelineLayout) \
    X(vkCreateDescriptorPool) X(vkDestroyDescriptorPool) X(vkAllocateDescriptorSets) X(vkUpdateDescriptorSets) \
    X(vkCreateShaderModule) X(vkDestroyShaderModule) X(vkCreateGraphicsPipelines) X(vkDestroyPipeline) \
    X(vkCreateRenderPass) X(vkDestroyRenderPass) X(vkCreateFramebuffer) X(vkDestroyFramebuffer) \
    X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) \
    X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkResetCommandBuffer) \
    X(vkCmdPipelineBarrier) X(vkCmdCopyBufferToImage) X(vkCmdCopyImageToBuffer) X(vkCmdBlitImage) \
    X(vkCmdBeginRenderPass) X(vkCmdEndRenderPass) X(vkCmdBindPipeline) X(vkCmdBindDescriptorSets) \
    X(vkCmdPushConstants) X(vkCmdSetViewport) X(vkCmdSetScissor) X(vkCmdDraw) \
    X(vkCmdClearAttachments) X(vkCmdClearColorImage) \
    X(vkQueueSubmit) X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences) \
    X(vkCreateQueryPool) X(vkDestroyQueryPool) X(vkCmdResetQueryPool) X(vkCmdWriteTimestamp) X(vkGetQueryPoolResults)

enum { RING = 6, MAX_TARGETS = 16, MAX_PASSES = 4 };

typedef struct {
    float m[16];
    float tangents[4];
    float inset[4];
    float near_distance, ratio;
    int32_t grid_w, grid_h, mode;
    float fade, gain;
} push_block;

typedef struct { VkBuffer buffer; VkDeviceMemory memory; void *mapped; VkDeviceSize size; int last_slot; } staging;

typedef struct {
    VkImage image; VkDeviceMemory memory; VkImageView view;
    VkFormat format; int width, height;
    VkImageLayout layout;
    int dirty;                       /* the staging buffer holds newer content */
    int upload_width, upload_height; /* the size of the staged content */
    staging stage;
    int levels;                      /* mip levels (0, 1: one) */
    int mipped;                      /* a full mip chain, filled after each write */
    VkImageUsageFlags extra_usage;
    VkImageView target_view;         /* level 0 as a render target, when mipped */
} texture;

enum { PIPE_ENV = 0, PIPE_CACHE = 1, PIPE_FRESH = 2, PIPES = 3 };

typedef struct { VkFormat format; int external_depth; VkRenderPass pass; VkPipeline pipeline[PIPES]; } pass_entry;

typedef struct {
    uint64_t image, depth_image; VkFormat format; uint32_t width, height;
    VkImageView view, depth_view; VkFramebuffer framebuffer;
    VkImage own_depth; VkDeviceMemory own_depth_memory;
    unsigned long long used;
} target_entry;

typedef struct { VkCommandBuffer cb; VkFence fence; int pending; int timed; } slot;

/* What a draw samples: colour, inverse depth, inset (descriptor set). */
typedef struct { texture *colour, *depth, *inset; VkDescriptorSet set; int stale; } source;

/* One face of the world cache: colour (RGBA8 sRGB, alpha 0 = empty) and
 * inverse depth (R32F), both render targets and sampled. */
typedef struct { texture colour, depth; VkFramebuffer framebuffer; } cache_face;

struct yrp_context {
    int own;                          /* instance and device are ours */
    void *lib;
    PFN_vkGetInstanceProcAddr gipa;
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    uint32_t family;
#define DECL(f) PFN_##f f;
    IFUNCS(DECL) DFUNCS(DECL)
#undef DECL
    VkPhysicalDeviceMemoryProperties memory;
    VkPhysicalDeviceProperties props;
    VkSampler linear, nearest;
    VkDescriptorSetLayout set_layout;
    VkPipelineLayout layout;
    VkDescriptorPool pool;
    VkShaderModule vert, frag, cache_frag;
    VkCommandPool cmd_pool;
    VkQueryPool queries;
    slot ring[RING];
    int next;
    texture colour, depth, inset;     /* the fresh picture */
    /* A video picture's planes and their conversion into `colour` (display-stream.md §14). */
    texture plane[3];
    int yuv_dirty, yuv_format;
    source yuv;
    VkDescriptorSet yuv_set;
    VkShaderModule yuv_vert, yuv_frag;
    VkRenderPass yuv_pass;
    VkPipeline yuv_pipeline;
    VkFramebuffer colour_fb;
    uint32_t colour_fb_width, colour_fb_height;
    int colour_mips_stale;
    int anisotropy;
    texture zero_depth, empty;        /* 1 x 1 dummies: depth 0 (infinity), transparent colour */
    texture env[6], env_depth[6];
    int env_ready, env_step;
    float inset_rect[4];
    source fresh, env_src[6], cache_src[6];
    cache_face cache[6];
    int cache_size;
    VkImage cache_zbuf; VkDeviceMemory cache_zbuf_memory; VkImageView cache_zview;
    VkRenderPass cache_pass; VkPipeline cache_pipeline;
    pass_entry passes[MAX_PASSES]; int pass_count;
    target_entry targets[MAX_TARGETS];
    unsigned long long use_counter;
    /* the offscreen image */
    VkImage off; VkDeviceMemory off_memory; uint32_t off_width, off_height;
    staging readback;
    double gpu_ms;
    char name[256];
    char error[512];
};

static void fail(yrp_context *c, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(c->error, sizeof c->error, fmt, ap);
    va_end(ap);
}

static void mark_stale(yrp_context *c);

const char *yrp_error(yrp_context *c) { return c ? c->error : "no context"; }
const char *yrp_device_name(yrp_context *c) { return c ? c->name : ""; }

static int memory_type(yrp_context *c, uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < c->memory.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (c->memory.memoryTypes[i].propertyFlags & want) == want) return (int)i;
    return -1;
}

static int staging_make(yrp_context *c, staging *s, VkDeviceSize size, VkBufferUsageFlags usage) {
    if (s->buffer && s->size >= size) return 0;
    if (s->buffer) { c->vkDestroyBuffer(c->device, s->buffer, NULL); c->vkFreeMemory(c->device, s->memory, NULL); memset(s, 0, sizeof *s); }
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = size;
    bi.usage = usage;
    if (c->vkCreateBuffer(c->device, &bi, NULL, &s->buffer) != VK_SUCCESS) { fail(c, "vkCreateBuffer failed"); return -1; }
    VkMemoryRequirements r;
    c->vkGetBufferMemoryRequirements(c->device, s->buffer, &r);
    int t = memory_type(c, r.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = r.size;
    ai.memoryTypeIndex = (uint32_t)t;
    if (t < 0 || c->vkAllocateMemory(c->device, &ai, NULL, &s->memory) != VK_SUCCESS) { fail(c, "no host-visible memory"); return -1; }
    c->vkBindBufferMemory(c->device, s->buffer, s->memory, 0);
    c->vkMapMemory(c->device, s->memory, 0, VK_WHOLE_SIZE, 0, &s->mapped);
    s->size = size;
    s->last_slot = -1;
    return 0;
}

static int mip_count(int w, int h) {
    int n = 1, m = w > h ? w : h;
    while (m > 1) { m >>= 1; n++; }
    return n;
}

static int image_make_levels(yrp_context *c, VkFormat format, uint32_t w, uint32_t h, uint32_t levels, VkImageUsageFlags usage,
                             VkImage *image, VkDeviceMemory *memory) {
    VkImageCreateInfo ii = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ii.imageType = VK_IMAGE_TYPE_2D;
    ii.format = format;
    ii.extent = (VkExtent3D){ w, h, 1 };
    ii.mipLevels = levels;
    ii.arrayLayers = 1;
    ii.samples = VK_SAMPLE_COUNT_1_BIT;
    ii.tiling = VK_IMAGE_TILING_OPTIMAL;
    ii.usage = usage;
    ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    if (c->vkCreateImage(c->device, &ii, NULL, image) != VK_SUCCESS) { fail(c, "vkCreateImage %ux%u format %d failed", w, h, format); return -1; }
    VkMemoryRequirements r;
    c->vkGetImageMemoryRequirements(c->device, *image, &r);
    int t = memory_type(c, r.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (t < 0) t = memory_type(c, r.memoryTypeBits, 0);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = r.size;
    ai.memoryTypeIndex = (uint32_t)t;
    if (c->vkAllocateMemory(c->device, &ai, NULL, memory) != VK_SUCCESS) { fail(c, "image memory"); return -1; }
    c->vkBindImageMemory(c->device, *image, *memory, 0);
    return 0;
}

static int image_make(yrp_context *c, VkFormat format, uint32_t w, uint32_t h, VkImageUsageFlags usage, VkImage *image, VkDeviceMemory *memory) {
    return image_make_levels(c, format, w, h, 1, usage, image, memory);
}

static VkImageView view_make_levels(yrp_context *c, VkImage image, VkFormat format, VkImageAspectFlags aspect, uint32_t levels) {
    VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vi.image = image;
    vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vi.format = format;
    vi.subresourceRange = (VkImageSubresourceRange){ aspect, 0, levels, 0, 1 };
    VkImageView v = VK_NULL_HANDLE;
    if (c->vkCreateImageView(c->device, &vi, NULL, &v) != VK_SUCCESS) fail(c, "vkCreateImageView failed");
    return v;
}

static VkImageView view_make(yrp_context *c, VkImage image, VkFormat format, VkImageAspectFlags aspect) {
    VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vi.image = image;
    vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vi.format = format;
    vi.subresourceRange = (VkImageSubresourceRange){ aspect, 0, 1, 0, 1 };
    VkImageView v = VK_NULL_HANDLE;
    if (c->vkCreateImageView(c->device, &vi, NULL, &v) != VK_SUCCESS) fail(c, "vkCreateImageView failed");
    return v;
}

/* Waits for every pending submission. */
int yrp_wait(yrp_context *c) {
    if (!c) return -1;
    for (int i = 0; i < RING; i++)
        if (c->ring[i].pending) c->vkWaitForFences(c->device, 1, &c->ring[i].fence, VK_TRUE, UINT64_MAX);
    return 0;
}

static void texture_drop(yrp_context *c, texture *t) {
    if (t->target_view) c->vkDestroyImageView(c->device, t->target_view, NULL);
    if (t->view) c->vkDestroyImageView(c->device, t->view, NULL);
    if (t->image) c->vkDestroyImage(c->device, t->image, NULL);
    if (t->memory) c->vkFreeMemory(c->device, t->memory, NULL);
    t->target_view = VK_NULL_HANDLE; t->view = VK_NULL_HANDLE; t->image = VK_NULL_HANDLE; t->memory = VK_NULL_HANDLE;
    t->width = t->height = 0;
    t->layout = VK_IMAGE_LAYOUT_UNDEFINED;
}

/* (Re)creates a texture at w x h (waits for the GPU first: its descriptor changes). */
static int texture_size(yrp_context *c, texture *t, int w, int h) {
    if (t->image && t->width == w && t->height == h) return 0;
    yrp_wait(c);
    texture_drop(c, t);
    t->levels = t->mipped ? mip_count(w, h) : 1;
    if (image_make_levels(c, t->format, (uint32_t)w, (uint32_t)h, (uint32_t)t->levels,
                          VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | (t->mipped ? VK_IMAGE_USAGE_TRANSFER_SRC_BIT : 0) | t->extra_usage,
                          &t->image, &t->memory)) return -1;
    t->view = view_make_levels(c, t->image, t->format, VK_IMAGE_ASPECT_COLOR_BIT, (uint32_t)t->levels);
    if (!t->view) return -1;
    if (t->extra_usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) {
        t->target_view = view_make(c, t->image, t->format, VK_IMAGE_ASPECT_COLOR_BIT);
        if (!t->target_view) return -1;
    }
    t->width = w; t->height = h;
    mark_stale(c);
    return 0;
}

/* Makes the staging buffer ready for new content of `bytes`: waits for the
 * GPU copy that last read it. */
static void *stage_begin(yrp_context *c, texture *t, size_t bytes) {
    if (t->stage.buffer && t->stage.last_slot >= 0 && c->ring[t->stage.last_slot].pending)
        c->vkWaitForFences(c->device, 1, &c->ring[t->stage.last_slot].fence, VK_TRUE, UINT64_MAX);
    if (staging_make(c, &t->stage, bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT)) return NULL;
    return t->stage.mapped;
}

int yrp_set_colour(yrp_context *c, const void *bgra, int width, int height, int stride) {
    if (!c || width <= 0 || height <= 0) return -1;
    uint8_t *dst = stage_begin(c, &c->colour, (size_t)width * height * 4);
    if (!dst) return -1;
    const uint8_t *src = bgra;
    if (stride == width * 4) memcpy(dst, src, (size_t)width * height * 4);
    else for (int y = 0; y < height; y++) memcpy(dst + (size_t)y * width * 4, src + (size_t)y * stride, (size_t)width * 4);
    c->colour.upload_width = width; c->colour.upload_height = height; c->colour.dirty = 1;
    c->yuv_dirty = 0;
    return 0;
}

/* A plane's rows into its staging buffer. */
static int plane_stage(yrp_context *c, texture *t, VkFormat format, const uint8_t *src, int pitch, int width, int height, int bytes_per_texel) {
    if (t->format != format) { yrp_wait(c); texture_drop(c, t); t->format = format; }
    size_t row = (size_t)width * bytes_per_texel;
    uint8_t *dst = stage_begin(c, t, row * height);
    if (!dst) return -1;
    if ((size_t)pitch == row) memcpy(dst, src, row * height);
    else for (int y = 0; y < height; y++) memcpy(dst + (size_t)y * row, src + (size_t)y * pitch, row);
    t->upload_width = width; t->upload_height = height; t->dirty = 1;
    return 0;
}

int yrp_set_colour_yuv(yrp_context *c, int format, const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height) {
    if (!c || width <= 0 || height <= 0 || !y || !u) return -1;
    if (plane_stage(c, &c->plane[0], VK_FORMAT_R8_UNORM, y, pitch, width, height, 1)) return -1;
    if (format == YRP_YUV444) {
        if (!v) return -1;
        if (plane_stage(c, &c->plane[1], VK_FORMAT_R8_UNORM, u, pitch, width, height, 1)) return -1;
        if (plane_stage(c, &c->plane[2], VK_FORMAT_R8_UNORM, v, pitch, width, height, 1)) return -1;
    } else {
        if (plane_stage(c, &c->plane[1], VK_FORMAT_R8G8_UNORM, u, pitch, (width + 1) / 2, height / 2, 2)) return -1;
    }
    c->yuv_format = format;
    c->colour.upload_width = width; c->colour.upload_height = height;
    c->colour.dirty = 0;    /* whatever BGRA was staged is older */
    c->yuv_dirty = 1;
    return 0;
}

int yrp_set_colour_nv12(yrp_context *c, const uint8_t *y, const uint8_t *uv, int pitch, int width, int height) {
    return yrp_set_colour_yuv(c, YRP_NV12, y, uv, NULL, pitch, width, height);
}

int yrp_set_depth(yrp_context *c, const uint16_t *q, int width, int height) {
    if (!c || width <= 0 || height <= 0) return -1;
    void *dst = stage_begin(c, &c->depth, (size_t)width * height * 2);
    if (!dst) return -1;
    memcpy(dst, q, (size_t)width * height * 2);
    c->depth.upload_width = width; c->depth.upload_height = height; c->depth.dirty = 1;
    return 0;
}

int yrp_set_inset(yrp_context *c, const void *bgra, int width, int height, int stride,
                  int x, int y, int w, int h, int full_width, int full_height) {
    if (!c) return -1;
    if (width <= 0 || height <= 0 || full_width <= 0 || full_height <= 0) {
        memset(c->inset_rect, 0, sizeof c->inset_rect);
        return 0;
    }
    uint8_t *dst = stage_begin(c, &c->inset, (size_t)width * height * 4);
    if (!dst) return -1;
    const uint8_t *src = bgra;
    for (int r = 0; r < height; r++) memcpy(dst + (size_t)r * width * 4, src + (size_t)r * stride, (size_t)width * 4);
    c->inset.upload_width = width; c->inset.upload_height = height; c->inset.dirty = 1;
    /* The rectangle in source uv; its soft edge (alpha) blends in the shader. */
    c->inset_rect[0] = (float)x / (float)full_width;
    c->inset_rect[1] = (float)y / (float)full_height;
    c->inset_rect[2] = (float)(x + w) / (float)full_width;
    c->inset_rect[3] = (float)(y + h) / (float)full_height;
    return 0;
}

static void mark_stale(yrp_context *c) {
    c->fresh.stale = 1;
    c->yuv.stale = 1;
    for (int f = 0; f < 6; f++) { c->env_src[f].stale = 1; c->cache_src[f].stale = 1; }
}

static void source_update(yrp_context *c, source *s) {
    if (!s->stale || !s->set) return;
    VkDescriptorImageInfo info[3] = {
        { c->linear, s->colour->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { c->nearest, s->depth->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        { c->linear, s->inset->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
    };
    VkWriteDescriptorSet w[3];
    for (int i = 0; i < 3; i++) {
        w[i] = (VkWriteDescriptorSet){ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
        w[i].dstSet = s->set;
        w[i].dstBinding = (uint32_t)i;
        w[i].descriptorCount = 1;
        w[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        w[i].pImageInfo = &info[i];
    }
    c->vkUpdateDescriptorSets(c->device, 3, w, 0, NULL);
    s->stale = 0;
}

/* Descriptor sets change only while nothing in flight uses them. */
static void sources_update(yrp_context *c) {
    int stale = c->fresh.stale;
    for (int f = 0; f < 6; f++) stale |= c->env_src[f].stale | (c->cache_size ? c->cache_src[f].stale : 0);
    if (!stale) return;
    yrp_wait(c);
    source_update(c, &c->fresh);
    for (int f = 0; f < 6; f++) {
        source_update(c, &c->env_src[f]);
        if (c->cache_size) source_update(c, &c->cache_src[f]);
    }
}

static void barrier(yrp_context *c, VkCommandBuffer cb, VkImage image, VkImageAspectFlags aspect,
                    VkImageLayout from, VkImageLayout to, VkAccessFlags srcAccess, VkAccessFlags dstAccess,
                    VkPipelineStageFlags src, VkPipelineStageFlags dst) {
    VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    b.srcAccessMask = srcAccess;
    b.dstAccessMask = dstAccess;
    b.oldLayout = from;
    b.newLayout = to;
    b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange = (VkImageSubresourceRange){ aspect, 0, VK_REMAINING_MIP_LEVELS, 0, 1 };
    c->vkCmdPipelineBarrier(cb, src, dst, 0, 0, NULL, 0, NULL, 1, &b);
}

static void barrier_levels(yrp_context *c, VkCommandBuffer cb, VkImage image, uint32_t level, uint32_t count, VkImageLayout from, VkImageLayout to,
                           VkAccessFlags srcAccess, VkAccessFlags dstAccess, VkPipelineStageFlags src, VkPipelineStageFlags dst) {
    VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    b.srcAccessMask = srcAccess;
    b.dstAccessMask = dstAccess;
    b.oldLayout = from;
    b.newLayout = to;
    b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, level, count, 0, 1 };
    c->vkCmdPipelineBarrier(cb, src, dst, 0, 0, NULL, 0, NULL, 1, &b);
}

/* Fills levels 1… from level 0 with linear blits (in linear light on an sRGB
 * format, Vulkan's blit rule), so minified sampling does not alias. All levels
 * end up in SHADER_READ_ONLY_OPTIMAL; level 0 is expected there, written. */
static void record_mips(yrp_context *c, VkCommandBuffer cb, texture *t) {
    if (t->levels <= 1) return;
    const VkPipelineStageFlags shaders = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    barrier_levels(c, cb, t->image, 0, 1, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                   VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
                   VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT | shaders, VK_PIPELINE_STAGE_TRANSFER_BIT);
    int w = t->width, h = t->height;
    for (int l = 1; l < t->levels; l++) {
        int nw = w > 1 ? w / 2 : 1, nh = h > 1 ? h / 2 : 1;
        barrier_levels(c, cb, t->image, (uint32_t)l, 1, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                       0, VK_ACCESS_TRANSFER_WRITE_BIT, shaders, VK_PIPELINE_STAGE_TRANSFER_BIT);
        VkImageBlit b;
        memset(&b, 0, sizeof b);
        b.srcSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, (uint32_t)l - 1, 0, 1 };
        b.srcOffsets[1] = (VkOffset3D){ w, h, 1 };
        b.dstSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, (uint32_t)l, 0, 1 };
        b.dstOffsets[1] = (VkOffset3D){ nw, nh, 1 };
        c->vkCmdBlitImage(cb, t->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, t->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &b, VK_FILTER_LINEAR);
        barrier_levels(c, cb, t->image, (uint32_t)l, 1, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                       VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
        w = nw; h = nh;
    }
    barrier_levels(c, cb, t->image, 0, (uint32_t)t->levels, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                   VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, shaders);
}

/* Records the upload of a texture whose staging buffer is newer. */
static void record_upload(yrp_context *c, VkCommandBuffer cb, texture *t, int slot_index) {
    if (!t->dirty || !t->image) return;
    barrier(c, cb, t->image, VK_IMAGE_ASPECT_COLOR_BIT, t->layout, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy r = { 0 };
    r.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
    r.imageExtent = (VkExtent3D){ (uint32_t)t->width, (uint32_t)t->height, 1 };
    c->vkCmdCopyBufferToImage(cb, t->stage.buffer, t->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &r);
    barrier(c, cb, t->image, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    t->layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    t->dirty = 0;
    t->stage.last_slot = slot_index;
}

/* The video picture's planes → the colour image's level 0, on the GPU. */
static void record_yuv(yrp_context *c, VkCommandBuffer cb, int si) {
    if (!c->yuv_dirty || !c->colour_fb || !c->colour.image) return;
    int planes = c->yuv_format == YRP_YUV444 ? 3 : 2;
    for (int i = 0; i < planes; i++) record_upload(c, cb, &c->plane[i], si);
    VkRenderPassBeginInfo rb = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    rb.renderPass = c->yuv_pass;
    rb.framebuffer = c->colour_fb;
    rb.renderArea.extent = (VkExtent2D){ (uint32_t)c->colour.width, (uint32_t)c->colour.height };
    c->vkCmdBeginRenderPass(cb, &rb, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport v = { 0, 0, (float)c->colour.width, (float)c->colour.height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, { (uint32_t)c->colour.width, (uint32_t)c->colour.height } };
    c->vkCmdSetViewport(cb, 0, 1, &v);
    c->vkCmdSetScissor(cb, 0, 1, &sc);
    c->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, c->yuv_pipeline);
    c->vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, c->layout, 0, 1, &c->yuv_set, 0, NULL);
    push_block pb;
    memset(&pb, 0, sizeof pb);
    pb.mode = c->yuv_format == YRP_YUV444 ? 1 : 0;
    c->vkCmdPushConstants(cb, c->layout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof pb, &pb);
    c->vkCmdDraw(cb, 3, 1, 0, 0);
    c->vkCmdEndRenderPass(cb);
    c->colour.layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    c->yuv_dirty = 0;
    c->colour_mips_stale = 1;
}

static void record_uploads(yrp_context *c, VkCommandBuffer cb, int si) {
    if (c->colour.dirty) c->colour_mips_stale = 1;
    record_upload(c, cb, &c->colour, si);
    record_yuv(c, cb, si);
    if (c->colour_mips_stale) { record_mips(c, cb, &c->colour); c->colour_mips_stale = 0; }
    record_upload(c, cb, &c->depth, si);
    record_upload(c, cb, &c->inset, si);
    record_upload(c, cb, &c->zero_depth, si);
    record_upload(c, cb, &c->empty, si);
    for (int f = 0; f < 6; f++) { record_upload(c, cb, &c->env[f], si); record_upload(c, cb, &c->env_depth[f], si); }
}

/* A graphics pipeline over the one layout: `depth` 0 none, 1 test and
 * write (GREATER: reverse-Z); `blend` alpha blending; `targets` colour
 * attachments. */
static VkPipeline pipeline_make(yrp_context *c, VkRenderPass pass, VkShaderModule vert, VkShaderModule frag, int depth, int blend, int targets) {
    VkPipelineShaderStageCreateInfo st[2] = { { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO },
                                              { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO } };
    st[0].stage = VK_SHADER_STAGE_VERTEX_BIT; st[0].module = vert; st[0].pName = "main";
    st[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; st[1].module = frag; st[1].pName = "main";
    VkPipelineVertexInputStateCreateInfo vin = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
    vp.viewportCount = 1; vp.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rs.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO };
    ds.depthTestEnable = depth ? VK_TRUE : VK_FALSE;
    ds.depthWriteEnable = depth ? VK_TRUE : VK_FALSE;
    ds.depthCompareOp = VK_COMPARE_OP_GREATER;
    VkPipelineColorBlendAttachmentState ba[2];
    memset(ba, 0, sizeof ba);
    for (int i = 0; i < 2; i++) ba[i].colorWriteMask = 0xF;
    if (blend) {
        ba[0].blendEnable = VK_TRUE;
        ba[0].srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        ba[0].dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        ba[0].colorBlendOp = VK_BLEND_OP_ADD;
        ba[0].srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        ba[0].dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        ba[0].alphaBlendOp = VK_BLEND_OP_ADD;
    }
    VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    cb.attachmentCount = (uint32_t)targets; cb.pAttachments = ba;
    VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dy = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
    dy.dynamicStateCount = 2; dy.pDynamicStates = dyn;
    VkGraphicsPipelineCreateInfo gp = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    gp.stageCount = 2; gp.pStages = st;
    gp.pVertexInputState = &vin; gp.pInputAssemblyState = &ia; gp.pViewportState = &vp;
    gp.pRasterizationState = &rs; gp.pMultisampleState = &ms; gp.pDepthStencilState = &ds;
    gp.pColorBlendState = &cb; gp.pDynamicState = &dy;
    gp.layout = c->layout; gp.renderPass = pass;
    VkPipeline p = VK_NULL_HANDLE;
    if (c->vkCreateGraphicsPipelines(c->device, VK_NULL_HANDLE, 1, &gp, NULL, &p) != VK_SUCCESS) fail(c, "vkCreateGraphicsPipelines failed");
    return p;
}

/* The eye pass for a target format: colour (cleared to black) and a
 * reverse-Z depth buffer (cleared to 0, far). */
static pass_entry *pass_for(yrp_context *c, VkFormat format, int external_depth) {
    for (int i = 0; i < c->pass_count; i++)
        if (c->passes[i].format == format && c->passes[i].external_depth == external_depth) return &c->passes[i];
    if (c->pass_count == MAX_PASSES) { fail(c, "too many target formats"); return NULL; }
    pass_entry *e = &c->passes[c->pass_count];
    VkAttachmentDescription a[2];
    memset(a, 0, sizeof a);
    a[0].format = format;
    a[0].samples = VK_SAMPLE_COUNT_1_BIT;
    a[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    a[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    a[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    a[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    a[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    a[0].finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    a[1] = a[0];
    a[1].format = VK_FORMAT_D32_SFLOAT;
    a[1].storeOp = external_depth ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE;
    a[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    VkAttachmentReference cr = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkAttachmentReference dr = { 1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sp = { 0 };
    sp.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sp.colorAttachmentCount = 1;
    sp.pColorAttachments = &cr;
    sp.pDepthStencilAttachment = &dr;
    VkSubpassDependency dep = { 0 };
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
    dep.dstStageMask = dep.srcStageMask;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT;
    VkRenderPassCreateInfo rp = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rp.attachmentCount = 2; rp.pAttachments = a;
    rp.subpassCount = 1; rp.pSubpasses = &sp;
    rp.dependencyCount = 1; rp.pDependencies = &dep;
    if (c->vkCreateRenderPass(c->device, &rp, NULL, &e->pass) != VK_SUCCESS) { fail(c, "vkCreateRenderPass failed"); return NULL; }
    e->pipeline[PIPE_ENV] = pipeline_make(c, e->pass, c->vert, c->frag, 0, 0, 1);
    e->pipeline[PIPE_CACHE] = pipeline_make(c, e->pass, c->vert, c->frag, 1, 0, 1);
    e->pipeline[PIPE_FRESH] = pipeline_make(c, e->pass, c->vert, c->frag, 1, 1, 1);
    if (!e->pipeline[0] || !e->pipeline[1] || !e->pipeline[2]) return NULL;
    e->format = format;
    e->external_depth = external_depth;
    c->pass_count++;
    return e;
}

static void target_drop(yrp_context *c, target_entry *t) {
    if (t->framebuffer) c->vkDestroyFramebuffer(c->device, t->framebuffer, NULL);
    if (t->view) c->vkDestroyImageView(c->device, t->view, NULL);
    if (t->depth_view) c->vkDestroyImageView(c->device, t->depth_view, NULL);
    if (t->own_depth) c->vkDestroyImage(c->device, t->own_depth, NULL);
    if (t->own_depth_memory) c->vkFreeMemory(c->device, t->own_depth_memory, NULL);
    memset(t, 0, sizeof *t);
}

static target_entry *target_for(yrp_context *c, uint64_t image, uint64_t depth_image, VkFormat format,
                                uint32_t w, uint32_t h, VkRenderPass pass) {
    target_entry *lru = &c->targets[0];
    for (int i = 0; i < MAX_TARGETS; i++) {
        target_entry *t = &c->targets[i];
        if (t->framebuffer && t->image == image && t->depth_image == depth_image && t->format == format && t->width == w && t->height == h) {
            t->used = ++c->use_counter;
            return t;
        }
        if (t->used < lru->used) lru = t;
    }
    if (lru->framebuffer) { yrp_wait(c); target_drop(c, lru); }
    target_entry *t = lru;
    t->image = image; t->depth_image = depth_image; t->format = format; t->width = w; t->height = h;
    t->view = view_make(c, (VkImage)(uintptr_t)image, format, VK_IMAGE_ASPECT_COLOR_BIT);
    VkImage depth = (VkImage)(uintptr_t)depth_image;
    if (!depth) {
        if (image_make(c, VK_FORMAT_D32_SFLOAT, w, h, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, &t->own_depth, &t->own_depth_memory)) { target_drop(c, t); return NULL; }
        depth = t->own_depth;
    }
    t->depth_view = view_make(c, depth, VK_FORMAT_D32_SFLOAT, VK_IMAGE_ASPECT_DEPTH_BIT);
    if (!t->view || !t->depth_view) { target_drop(c, t); return NULL; }
    VkImageView views[2] = { t->view, t->depth_view };
    VkFramebufferCreateInfo fi = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
    fi.renderPass = pass;
    fi.attachmentCount = 2;
    fi.pAttachments = views;
    fi.width = w; fi.height = h; fi.layers = 1;
    if (c->vkCreateFramebuffer(c->device, &fi, NULL, &t->framebuffer) != VK_SUCCESS) { fail(c, "vkCreateFramebuffer failed"); target_drop(c, t); return NULL; }
    t->used = ++c->use_counter;
    return t;
}

/* One mesh draw of a source. */
static void draw_source(yrp_context *c, VkCommandBuffer cb, source *s, const float m[16], const float tangents[4],
                        const float inset[4], float near_distance, float ratio, int step, int mode, float fade, float gain) {
    c->vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, c->layout, 0, 1, &s->set, 0, NULL);
    push_block pb;
    memcpy(pb.m, m, sizeof pb.m);
    memcpy(pb.tangents, tangents, sizeof pb.tangents);
    if (inset) memcpy(pb.inset, inset, sizeof pb.inset); else memset(pb.inset, 0, sizeof pb.inset);
    pb.near_distance = near_distance > 0 ? near_distance : 0.1f;
    pb.ratio = ratio > 1 ? ratio : 1.08f;
    if (step < 1) step = 1;
    int dw = s->depth->width > 0 ? s->depth->width : 1, dh = s->depth->height > 0 ? s->depth->height : 1;
    pb.grid_w = dw / step + 1; if (pb.grid_w < 2) pb.grid_w = 2;
    pb.grid_h = dh / step + 1; if (pb.grid_h < 2) pb.grid_h = 2;
    pb.mode = mode;
    pb.fade = fade;
    pb.gain = gain > 0 ? gain : 1;
    c->vkCmdPushConstants(cb, c->layout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof pb, &pb);
    c->vkCmdDraw(cb, (uint32_t)((pb.grid_w - 1) * (pb.grid_h - 1) * 6), 1, 0, 0);
}

static const float face_tangents[4] = { -1, 1, 1, -1 };
/* The cache's mesh: about 384 cells a side whatever the face's size (a face is
   drawn for every eye every frame; its triangles are most of the frame's cost). */
static int cache_step(const yrp_context *c) { int s = c->cache_size / 384; return s < 1 ? 1 : s; }
/* The cache faces' near: their inverse depth is YRP_CACHE_NEAR / distance. */
#define YRP_CACHE_NEAR 0.1f

/* The next ring slot, its earlier use finished (and its GPU time read). */
static slot *slot_begin(yrp_context *c, int *index) {
    int si = c->next;
    c->next = (c->next + 1) % RING;
    slot *s = &c->ring[si];
    if (s->pending) {
        c->vkWaitForFences(c->device, 1, &s->fence, VK_TRUE, UINT64_MAX);
        if (s->timed && c->queries) {
            uint64_t ts[2];
            if (c->vkGetQueryPoolResults(c->device, c->queries, (uint32_t)si * 2, 2, sizeof ts, ts, sizeof(uint64_t),
                                         VK_QUERY_RESULT_64_BIT) == VK_SUCCESS)
                c->gpu_ms = (double)(ts[1] - ts[0]) * c->props.limits.timestampPeriod / 1e6;
        }
        s->pending = 0;
    }
    c->vkResetFences(c->device, 1, &s->fence);
    c->vkResetCommandBuffer(s->cb, 0);
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    c->vkBeginCommandBuffer(s->cb, &bi);
    s->timed = 0;
    *index = si;
    return s;
}

static int slot_submit(yrp_context *c, slot *s) {
    if (c->vkEndCommandBuffer(s->cb) != VK_SUCCESS) { fail(c, "vkEndCommandBuffer failed"); return -1; }
    VkSubmitInfo sub = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    sub.commandBufferCount = 1;
    sub.pCommandBuffers = &s->cb;
    if (c->vkQueueSubmit(c->queue, 1, &sub, s->fence) != VK_SUCCESS) { fail(c, "vkQueueSubmit failed"); return -1; }
    s->pending = 1;
    return 0;
}

/* Fresh textures at their staged sizes. */
static int yuv_prepare(yrp_context *c);

static int fresh_sizes(yrp_context *c) {
    if (c->colour.upload_width && texture_size(c, &c->colour, c->colour.upload_width, c->colour.upload_height)) return -1;
    if (c->yuv_dirty && yuv_prepare(c)) return -1;
    if (c->depth.upload_width && texture_size(c, &c->depth, c->depth.upload_width, c->depth.upload_height)) return -1;
    if (c->inset.upload_width && texture_size(c, &c->inset, c->inset.upload_width, c->inset.upload_height)) return -1;
    return 0;
}

/* The conversion's pass (made once), its framebuffer on the colour image, and its
 * descriptors on the planes; waits only when one of those has to change. */
static int yuv_prepare(yrp_context *c) {
    int planes = c->yuv_format == YRP_YUV444 ? 3 : 2;
    int changed = 0;
    for (int i = 0; i < planes; i++) {
        texture *t = &c->plane[i];
        VkImage before = t->image;
        if (texture_size(c, t, t->upload_width, t->upload_height)) return -1;
        changed |= before != t->image;
    }
    if (!c->yuv_pass) {
        VkAttachmentDescription a;
        memset(&a, 0, sizeof a);
        a.format = c->colour.format;
        a.samples = VK_SAMPLE_COUNT_1_BIT;
        a.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        a.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        a.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        a.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        a.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        a.finalLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        VkAttachmentReference cr = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        VkSubpassDescription sp = { 0 };
        sp.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        sp.colorAttachmentCount = 1;
        sp.pColorAttachments = &cr;
        VkSubpassDependency dep[2];
        memset(dep, 0, sizeof dep);
        dep[0].srcSubpass = VK_SUBPASS_EXTERNAL; dep[0].dstSubpass = 0;
        dep[0].srcStageMask = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT;
        dep[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        dep[0].srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        dep[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT;
        dep[1].srcSubpass = 0; dep[1].dstSubpass = VK_SUBPASS_EXTERNAL;
        dep[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep[1].dstStageMask = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT;
        dep[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        dep[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT;
        VkRenderPassCreateInfo rp = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
        rp.attachmentCount = 1; rp.pAttachments = &a;
        rp.subpassCount = 1; rp.pSubpasses = &sp;
        rp.dependencyCount = 2; rp.pDependencies = dep;
        if (c->vkCreateRenderPass(c->device, &rp, NULL, &c->yuv_pass) != VK_SUCCESS) { fail(c, "YUV render pass"); return -1; }
        c->yuv_pipeline = pipeline_make(c, c->yuv_pass, c->yuv_vert, c->yuv_frag, 0, 0, 1);
        if (!c->yuv_pipeline) return -1;
    }
    if (!c->colour.target_view) { fail(c, "the colour image is no render target"); return -1; }
    if (!c->colour_fb || c->colour_fb_width != (uint32_t)c->colour.width || c->colour_fb_height != (uint32_t)c->colour.height || c->fresh.stale) {
        yrp_wait(c);
        if (c->colour_fb) c->vkDestroyFramebuffer(c->device, c->colour_fb, NULL);
        VkFramebufferCreateInfo fi = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        fi.renderPass = c->yuv_pass;
        fi.attachmentCount = 1;
        fi.pAttachments = &c->colour.target_view;
        fi.width = (uint32_t)c->colour.width; fi.height = (uint32_t)c->colour.height; fi.layers = 1;
        if (c->vkCreateFramebuffer(c->device, &fi, NULL, &c->colour_fb) != VK_SUCCESS) { c->colour_fb = VK_NULL_HANDLE; fail(c, "YUV framebuffer"); return -1; }
        c->colour_fb_width = (uint32_t)c->colour.width; c->colour_fb_height = (uint32_t)c->colour.height;
    }
    if (changed || c->yuv.stale) {
        yrp_wait(c);
        /* 4:2:0 has no third plane: binding 2 takes the first, the shader does not read it. */
        VkDescriptorImageInfo info[3] = {
            { c->linear, c->plane[0].view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            { c->linear, c->plane[1].view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            { c->linear, (planes == 3 ? c->plane[2] : c->plane[0]).view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        };
        VkWriteDescriptorSet w[3];
        for (int i = 0; i < 3; i++) {
            w[i] = (VkWriteDescriptorSet){ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
            w[i].dstSet = c->yuv_set;
            w[i].dstBinding = (uint32_t)i;
            w[i].descriptorCount = 1;
            w[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            w[i].pImageInfo = &info[i];
        }
        c->vkUpdateDescriptorSets(c->device, 3, w, 0, NULL);
        c->yuv.stale = 0;
    }
    return 0;
}

int yrp_read_colour(yrp_context *c, void *bgra, size_t size) {
    if (!c) return -1;
    if (fresh_sizes(c)) return -1;
    sources_update(c);
    size_t bytes = (size_t)c->colour.width * c->colour.height * 4;
    if (!c->colour.image || size < bytes) { fail(c, "no colour image, or the buffer is too small"); return -1; }
    if (staging_make(c, &c->readback, bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT)) return -1;
    int si;
    slot *s = slot_begin(c, &si);
    record_uploads(c, s->cb, si);
    barrier_levels(c, s->cb, c->colour.image, 0, 1, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                   VK_ACCESS_SHADER_READ_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy r = { 0 };
    r.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
    r.imageExtent = (VkExtent3D){ (uint32_t)c->colour.width, (uint32_t)c->colour.height, 1 };
    c->vkCmdCopyImageToBuffer(s->cb, c->colour.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c->readback.buffer, 1, &r);
    barrier_levels(c, s->cb, c->colour.image, 0, 1, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                   VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    if (slot_submit(c, s)) return -1;
    c->vkWaitForFences(c->device, 1, &s->fence, VK_TRUE, UINT64_MAX);
    s->pending = 0;
    memcpy(bgra, c->readback.mapped, bytes);
    return 0;
}

int yrp_render(yrp_context *c, const yrp_target *target, const yrp_frame *f) {
    if (!c || !target || !f) return -1;
    if (fresh_sizes(c)) return -1;
    VkFormat format = target->image ? (VkFormat)target->format : VK_FORMAT_B8G8R8A8_SRGB;
    uint64_t image = target->image;
    if (!image) {
        if (!c->off || c->off_width != target->width || c->off_height != target->height) {
            yrp_wait(c);
            if (c->off) {
                for (int i = 0; i < MAX_TARGETS; i++) if (c->targets[i].image == (uint64_t)(uintptr_t)c->off) target_drop(c, &c->targets[i]);
                c->vkDestroyImage(c->device, c->off, NULL); c->vkFreeMemory(c->device, c->off_memory, NULL); c->off = VK_NULL_HANDLE;
            }
            if (image_make(c, VK_FORMAT_B8G8R8A8_SRGB, target->width, target->height,
                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &c->off, &c->off_memory)) return -1;
            c->off_width = target->width; c->off_height = target->height;
        }
        image = (uint64_t)(uintptr_t)c->off;
    }
    pass_entry *pe = pass_for(c, format, target->depth_image != 0);
    if (!pe) return -1;
    target_entry *te = target_for(c, image, target->depth_image, format, target->width, target->height, pe->pass);
    if (!te) return -1;
    sources_update(c);
    int si;
    slot *s = slot_begin(c, &si);
    s->timed = c->queries != VK_NULL_HANDLE;
    if (s->timed) {
        c->vkCmdResetQueryPool(s->cb, c->queries, (uint32_t)si * 2, 2);
        c->vkCmdWriteTimestamp(s->cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c->queries, (uint32_t)si * 2);
    }
    record_uploads(c, s->cb, si);

    VkClearValue clear[2];
    memset(clear, 0, sizeof clear);
    clear[0].color.float32[3] = 1;
    clear[1].depthStencil.depth = 0;     /* reverse-Z: far */
    VkRenderPassBeginInfo rb = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    rb.renderPass = pe->pass;
    rb.framebuffer = te->framebuffer;
    rb.renderArea.extent = (VkExtent2D){ target->width, target->height };
    rb.clearValueCount = 2;
    rb.pClearValues = clear;
    c->vkCmdBeginRenderPass(s->cb, &rb, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport v = { 0, 0, (float)target->width, (float)target->height, 0, 1 };
    VkRect2D sc = { { 0, 0 }, { target->width, target->height } };
    c->vkCmdSetViewport(s->cb, 0, 1, &v);
    c->vkCmdSetScissor(s->cb, 0, 1, &sc);
    if (c->env_ready && f->env_mask) {
        c->vkCmdBindPipeline(s->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pe->pipeline[PIPE_ENV]);
        for (int i = 0; i < 6; i++) if (f->env_mask & (1u << i))
            draw_source(c, s->cb, &c->env_src[i], f->env_matrix[i], face_tangents, NULL, 0.1f, 1e9f, c->env_step, YRP_MODE_STRETCH, 0, f->env_gain);
    }
    int has_cache = c->cache_size && f->cache_mask;
    VkClearAttachment clear_depth = { VK_IMAGE_ASPECT_DEPTH_BIT, 0, { .depthStencil = { 0, 0 } } };
    VkClearRect whole = { { { 0, 0 }, { target->width, target->height } }, 0, 1 };
    /* The environment is behind everything: on its calibrated box it can stand
       in front of a wall of the picture, and of the fill at that wall's depth
       (a pale patch of the cube where an icon has moved off the wall). */
    if (c->env_ready && f->env_mask) c->vkCmdClearAttachments(s->cb, 1, &clear_depth, 1, &whole);
    /* The cache: depth-displaced faces, empty texels dropped. */
#define DRAW_CACHE() do { \
        c->vkCmdBindPipeline(s->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pe->pipeline[PIPE_CACHE]); \
        for (int i = 0; i < 6; i++) if (f->cache_mask & (1u << i)) \
            draw_source(c, s->cb, &c->cache_src[i], f->cache_matrix[i], face_tangents, NULL, YRP_CACHE_NEAR, \
                        f->fresh.edge_ratio, cache_step(c), YRP_MODE_BACKGROUND | 16, 0, 1); \
    } while (0)
    if (f->fresh_under && has_cache) {
        /* The head moved: the guest's picture shows a smoothed pose the tag
           only estimates, so the settled cache wins where it has content. */
        if (f->fresh_enabled) {
            c->vkCmdBindPipeline(s->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pe->pipeline[PIPE_FRESH]);
            draw_source(c, s->cb, &c->fresh, f->fresh.matrix, f->fresh.tangents, c->inset_rect, f->fresh.near_distance,
                        f->fresh.edge_ratio, f->fresh.grid_step, f->fresh.mode, 0, 1);
            c->vkCmdClearAttachments(s->cb, 1, &clear_depth, 1, &whole);
        }
        DRAW_CACHE();
        if (f->fresh_enabled) {
            /* The windows layer is never in the cache: over it, from the picture. */
            c->vkCmdClearAttachments(s->cb, 1, &clear_depth, 1, &whole);
            c->vkCmdBindPipeline(s->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pe->pipeline[PIPE_FRESH]);
            draw_source(c, s->cb, &c->fresh, f->fresh.matrix, f->fresh.tangents, c->inset_rect, f->fresh.near_distance,
                        f->fresh.edge_ratio, f->fresh.grid_step, YRP_MODE_DISCARD | 128, 0, 1);
        }
    } else {
        if (has_cache) {
            /* Under the cache, the picture with its disocclusions filled from
               their far corners: an uncovered area the cache has not seen takes
               the background's colour, not the environment's. */
            if (f->fresh_enabled && f->fresh.mode == YRP_MODE_BACKGROUND) {
                c->vkCmdBindPipeline(s->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pe->pipeline[PIPE_FRESH]);
                draw_source(c, s->cb, &c->fresh, f->fresh.matrix, f->fresh.tangents, c->inset_rect, f->fresh.near_distance,
                            f->fresh.edge_ratio, f->fresh.grid_step, YRP_MODE_BACKGROUND, 0, 1);
                c->vkCmdClearAttachments(s->cb, 1, &clear_depth, 1, &whole);
            }
            DRAW_CACHE();
        }
        if (f->fresh_enabled) {
            /* The fresh picture wins over the cache wherever it covers. */
            if (has_cache) c->vkCmdClearAttachments(s->cb, 1, &clear_depth, 1, &whole);
            c->vkCmdBindPipeline(s->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pe->pipeline[PIPE_FRESH]);
            /* Over a cache, disocclusions show the cache or the fill above (discard); alone, the background. */
            int mode = f->fresh.mode == YRP_MODE_BACKGROUND && has_cache ? YRP_MODE_DISCARD : f->fresh.mode;
            draw_source(c, s->cb, &c->fresh, f->fresh.matrix, f->fresh.tangents, c->inset_rect, f->fresh.near_distance,
                        f->fresh.edge_ratio, f->fresh.grid_step, mode | (f->fade > 0 ? 32 : 0), f->fade, 1);
        }
    }
#undef DRAW_CACHE
    c->vkCmdEndRenderPass(s->cb);
    if (s->timed) c->vkCmdWriteTimestamp(s->cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, c->queries, (uint32_t)si * 2 + 1);
    return slot_submit(c, s);
}

/* ---- the world cache ---- */

static void cache_drop(yrp_context *c) {
    yrp_wait(c);
    for (int f = 0; f < 6; f++) {
        if (c->cache[f].framebuffer) c->vkDestroyFramebuffer(c->device, c->cache[f].framebuffer, NULL);
        c->cache[f].framebuffer = VK_NULL_HANDLE;
        texture_drop(c, &c->cache[f].colour);
        texture_drop(c, &c->cache[f].depth);
    }
    if (c->cache_zview) c->vkDestroyImageView(c->device, c->cache_zview, NULL);
    if (c->cache_zbuf) c->vkDestroyImage(c->device, c->cache_zbuf, NULL);
    if (c->cache_zbuf_memory) c->vkFreeMemory(c->device, c->cache_zbuf_memory, NULL);
    c->cache_zview = VK_NULL_HANDLE; c->cache_zbuf = VK_NULL_HANDLE; c->cache_zbuf_memory = VK_NULL_HANDLE;
    c->cache_size = 0;
}

static int cache_pass_make(yrp_context *c) {
    if (c->cache_pass) return 0;
    VkAttachmentDescription a[3];
    memset(a, 0, sizeof a);
    for (int i = 0; i < 2; i++) {
        a[i].format = i == 0 ? VK_FORMAT_R8G8B8A8_SRGB : VK_FORMAT_R32_SFLOAT;
        a[i].samples = VK_SAMPLE_COUNT_1_BIT;
        a[i].loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        a[i].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        a[i].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        a[i].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        a[i].initialLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        a[i].finalLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }
    a[2] = a[0];
    a[2].format = VK_FORMAT_D32_SFLOAT;
    a[2].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    a[2].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    a[2].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    a[2].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    VkAttachmentReference cr[2] = { { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL }, { 1, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL } };
    VkAttachmentReference dr = { 2, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sp = { 0 };
    sp.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sp.colorAttachmentCount = 2;
    sp.pColorAttachments = cr;
    sp.pDepthStencilAttachment = &dr;
    VkSubpassDependency dep[2];
    memset(dep, 0, sizeof dep);
    dep[0].srcSubpass = VK_SUBPASS_EXTERNAL; dep[0].dstSubpass = 0;
    dep[0].srcStageMask = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
    dep[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    dep[0].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    dep[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT;
    dep[1].srcSubpass = 0; dep[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    dep[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep[1].dstStageMask = VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    dep[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dep[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    VkRenderPassCreateInfo rp = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rp.attachmentCount = 3; rp.pAttachments = a;
    rp.subpassCount = 1; rp.pSubpasses = &sp;
    rp.dependencyCount = 2; rp.pDependencies = dep;
    if (c->vkCreateRenderPass(c->device, &rp, NULL, &c->cache_pass) != VK_SUCCESS) { fail(c, "cache render pass"); return -1; }
    c->cache_pipeline = pipeline_make(c, c->cache_pass, c->vert, c->cache_frag, 1, 0, 2);
    return c->cache_pipeline ? 0 : -1;
}

/* Clears every cache face to empty (alpha 0, depth 0) in SHADER_READ_ONLY. */
static int cache_reset(yrp_context *c) {
    int si;
    slot *s = slot_begin(c, &si);
    VkClearColorValue zero = { { 0, 0, 0, 0 } };
    VkImageSubresourceRange r = { VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0, 1 };
    for (int f = 0; f < 6; f++) {
        texture *ts[2] = { &c->cache[f].colour, &c->cache[f].depth };
        for (int k = 0; k < 2; k++) {
            barrier(c, s->cb, ts[k]->image, VK_IMAGE_ASPECT_COLOR_BIT, ts[k]->layout, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    VK_ACCESS_SHADER_READ_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
            c->vkCmdClearColorImage(s->cb, ts[k]->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &zero, 1, &r);
            barrier(c, s->cb, ts[k]->image, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
            ts[k]->layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        }
    }
    return slot_submit(c, s);
}

int yrp_cache_enable(yrp_context *c, int face_size) {
    if (!c) return -1;
    if (face_size <= 0) { cache_drop(c); mark_stale(c); return 0; }
    if (c->cache_size == face_size) return 0;
    cache_drop(c);
    if (cache_pass_make(c)) return -1;
    uint32_t n = (uint32_t)face_size;
    for (int f = 0; f < 6; f++) {
        texture *ts[2] = { &c->cache[f].colour, &c->cache[f].depth };
        VkFormat fm[2] = { VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_R32_SFLOAT };
        for (int k = 0; k < 2; k++) {
            ts[k]->format = fm[k];
            /* The colour has mips: a face's corners hold about three times the pixels per degree of its centre. */
            ts[k]->levels = k == 0 ? mip_count(face_size, face_size) : 1;
            if (image_make_levels(c, fm[k], n, n, (uint32_t)ts[k]->levels,
                                  VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                                  &ts[k]->image, &ts[k]->memory)) return -1;
            ts[k]->view = view_make_levels(c, ts[k]->image, fm[k], VK_IMAGE_ASPECT_COLOR_BIT, (uint32_t)ts[k]->levels);
            ts[k]->target_view = view_make(c, ts[k]->image, fm[k], VK_IMAGE_ASPECT_COLOR_BIT);
            ts[k]->width = face_size; ts[k]->height = face_size;
            ts[k]->layout = VK_IMAGE_LAYOUT_UNDEFINED;
        }
    }
    if (image_make(c, VK_FORMAT_D32_SFLOAT, n, n, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, &c->cache_zbuf, &c->cache_zbuf_memory)) return -1;
    c->cache_zview = view_make(c, c->cache_zbuf, VK_FORMAT_D32_SFLOAT, VK_IMAGE_ASPECT_DEPTH_BIT);
    for (int f = 0; f < 6; f++) {
        VkImageView views[3] = { c->cache[f].colour.target_view, c->cache[f].depth.target_view, c->cache_zview };
        VkFramebufferCreateInfo fi = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        fi.renderPass = c->cache_pass; fi.attachmentCount = 3; fi.pAttachments = views;
        fi.width = n; fi.height = n; fi.layers = 1;
        if (c->vkCreateFramebuffer(c->device, &fi, NULL, &c->cache[f].framebuffer) != VK_SUCCESS) { fail(c, "cache framebuffer"); return -1; }
    }
    c->cache_size = face_size;
    mark_stale(c);
    return cache_reset(c);
}

int yrp_cache_clear(yrp_context *c) {
    if (!c || !c->cache_size) return 0;
    return cache_reset(c);
}

int yrp_cache_update(yrp_context *c, const yrp_params *p, const float face_matrix[6][16], unsigned face_mask) {
    if (!c || !p || !c->cache_size || !face_mask) return c && c->cache_size ? 0 : -1;
    if (fresh_sizes(c)) return -1;
    sources_update(c);
    int si;
    slot *s = slot_begin(c, &si);
    record_uploads(c, s->cb, si);
    uint32_t n = (uint32_t)c->cache_size;
    VkViewport v = { 0, 0, (float)n, (float)n, 0, 1 };
    VkRect2D sc = { { 0, 0 }, { n, n } };
    for (int f = 0; f < 6; f++) {
        if (!(face_mask & (1u << f))) continue;
        VkClearValue clear[3];
        memset(clear, 0, sizeof clear);
        VkRenderPassBeginInfo rb = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
        rb.renderPass = c->cache_pass;
        rb.framebuffer = c->cache[f].framebuffer;
        rb.renderArea.extent = (VkExtent2D){ n, n };
        rb.clearValueCount = 3;
        rb.pClearValues = clear;
        c->vkCmdBeginRenderPass(s->cb, &rb, VK_SUBPASS_CONTENTS_INLINE);
        c->vkCmdSetViewport(s->cb, 0, 1, &v);
        c->vkCmdSetScissor(s->cb, 0, 1, &sc);
        c->vkCmdBindPipeline(s->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, c->cache_pipeline);
        /* The room only. The windows layer (the depth's low bit) stays out: it
           changes and moves, and stored here it replaced what was known of the
           room behind it. Depth edges go in at their far side, sharp while the
           move from the picture's viewpoint to the cache's centre has not
           stretched them. Stretched ones are not stored: a fill kept here stays
           in the room as a ghost beside what made it, and what lay there stays;
           an area nothing has seen is filled when it is drawn, from the fresh
           picture under the cache. */
        draw_source(c, s->cb, &c->fresh, face_matrix[f], p->tangents, c->inset_rect, p->near_distance, p->edge_ratio,
                    p->grid_step, YRP_MODE_DISCARD | 64, 0, 1);
        c->vkCmdEndRenderPass(s->cb);
        record_mips(c, s->cb, &c->cache[f].colour);
    }
    return slot_submit(c, s);
}

int yrp_set_environment(yrp_context *c, const void *faces, int format, int size) {
    if (!c || !faces || size <= 0 || (format != 1 && format != 2)) return -1;
    VkFormat fm = format == 1 ? VK_FORMAT_R16G16B16A16_SFLOAT : VK_FORMAT_R8G8B8A8_SRGB;
    size_t bpp = format == 1 ? 8 : 4, face = (size_t)size * size * bpp;
    for (int f = 0; f < 6; f++) {
        if (c->env[f].format != fm) { yrp_wait(c); texture_drop(c, &c->env[f]); c->env[f].format = fm; }
        void *d = stage_begin(c, &c->env[f], face);
        if (!d) return -1;
        memcpy(d, (const uint8_t *)faces + face * f, face);
        c->env[f].upload_width = size; c->env[f].upload_height = size; c->env[f].dirty = 1;
        if (texture_size(c, &c->env[f], size, size)) return -1;
    }
    for (int f = 0; f < 6; f++) c->env_src[f].colour = &c->env[f];
    c->env_ready = 1;
    mark_stale(c);
    return 0;
}

int yrp_set_environment_depth(yrp_context *c, const uint16_t *q, int n) {
    if (!c) return -1;
    if (!q || n < 3) {
        for (int f = 0; f < 6; f++) c->env_src[f].depth = &c->zero_depth;
        c->env_step = 1;
        mark_stale(c);
        return 0;
    }
    size_t bytes = (size_t)n * n * 2;
    for (int f = 0; f < 6; f++) {
        void *d = stage_begin(c, &c->env_depth[f], bytes);
        if (!d) return -1;
        memcpy(d, q + (size_t)f * n * n, bytes);
        c->env_depth[f].upload_width = n; c->env_depth[f].upload_height = n; c->env_depth[f].dirty = 1;
        if (texture_size(c, &c->env_depth[f], n, n)) return -1;
        c->env_src[f].depth = &c->env_depth[f];
    }
    /* A step of 2 over an odd n: grid corners fall on samples j = 2 i, the last on n - 1. */
    c->env_step = 2;
    mark_stale(c);
    return 0;
}

double yrp_gpu_ms(yrp_context *c) {
    if (!c) return -1;
    return c->gpu_ms > 0 ? c->gpu_ms : -1;
}

int yrp_read(yrp_context *c, void *bgra, size_t size) {
    if (!c || !c->off) { if (c) fail(c, "nothing rendered offscreen"); return -1; }
    size_t bytes = (size_t)c->off_width * c->off_height * 4;
    if (size < bytes) { fail(c, "buffer too small"); return -1; }
    if (staging_make(c, &c->readback, bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT)) return -1;
    yrp_wait(c);
    int si = c->next;
    c->next = (c->next + 1) % RING;
    slot *s = &c->ring[si];
    s->pending = 0;
    s->timed = 0;
    c->vkResetFences(c->device, 1, &s->fence);
    c->vkResetCommandBuffer(s->cb, 0);
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    c->vkBeginCommandBuffer(s->cb, &bi);
    barrier(c, s->cb, c->off, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy r = { 0 };
    r.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
    r.imageExtent = (VkExtent3D){ c->off_width, c->off_height, 1 };
    c->vkCmdCopyImageToBuffer(s->cb, c->off, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c->readback.buffer, 1, &r);
    barrier(c, s->cb, c->off, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            VK_ACCESS_TRANSFER_READ_BIT, 0, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
    c->vkEndCommandBuffer(s->cb);
    VkSubmitInfo sub = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    sub.commandBufferCount = 1;
    sub.pCommandBuffers = &s->cb;
    if (c->vkQueueSubmit(c->queue, 1, &sub, s->fence) != VK_SUCCESS) { fail(c, "vkQueueSubmit failed"); return -1; }
    s->pending = 1;
    c->vkWaitForFences(c->device, 1, &s->fence, VK_TRUE, UINT64_MAX);
    s->pending = 0;
    memcpy(bgra, c->readback.mapped, bytes);
    return 0;
}

/* ------------------------------------------------------------------ */

static int load(yrp_context *c, const yrp_vulkan *vk) {
    if (vk) {
        c->gipa = (PFN_vkGetInstanceProcAddr)vk->get_instance_proc_addr;
        c->instance = (VkInstance)vk->instance;
        c->physical = (VkPhysicalDevice)vk->physical_device;
        c->device = (VkDevice)vk->device;
        c->queue = (VkQueue)vk->queue;
        c->family = vk->queue_family;
        c->anisotropy = vk->anisotropy;
        if (!c->gipa || !c->instance || !c->device || !c->queue) { fail(c, "incomplete Vulkan handles"); return -1; }
    } else {
        c->own = 1;
        const char *names[] = { "libvulkan.so.1", "libvulkan.so", "libvulkan.1.dylib", NULL };
        for (int i = 0; names[i] && !c->lib; i++) c->lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
        if (!c->lib) { fail(c, "the Vulkan loader (libvulkan.so.1) is not installed"); return -1; }
        c->gipa = (PFN_vkGetInstanceProcAddr)dlsym(c->lib, "vkGetInstanceProcAddr");
        if (!c->gipa) { fail(c, "vkGetInstanceProcAddr missing"); return -1; }
        PFN_vkCreateInstance create = (PFN_vkCreateInstance)c->gipa(NULL, "vkCreateInstance");
        VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
        app.pApplicationName = "ycode-xr-reprojection";
        app.apiVersion = VK_API_VERSION_1_1;
        VkInstanceCreateInfo ii = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
        ii.pApplicationInfo = &app;
        if (!create || create(&ii, NULL, &c->instance) != VK_SUCCESS) { fail(c, "vkCreateInstance failed"); return -1; }
    }
#define LOADI(f) c->f = (PFN_##f)c->gipa(c->instance, #f); if (!c->f) { fail(c, "Vulkan: %s missing", #f); return -1; }
    IFUNCS(LOADI)
#undef LOADI
    if (c->own) {
        uint32_t n = 0;
        c->vkEnumeratePhysicalDevices(c->instance, &n, NULL);
        if (n == 0) { fail(c, "no Vulkan device"); return -1; }
        VkPhysicalDevice devs[8];
        if (n > 8) n = 8;
        c->vkEnumeratePhysicalDevices(c->instance, &n, devs);
        /* Prefer a discrete GPU, then any. */
        c->physical = devs[0];
        for (uint32_t i = 0; i < n; i++) {
            VkPhysicalDeviceProperties pr;
            c->vkGetPhysicalDeviceProperties(devs[i], &pr);
            if (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) { c->physical = devs[i]; break; }
        }
        uint32_t qn = 0;
        c->vkGetPhysicalDeviceQueueFamilyProperties(c->physical, &qn, NULL);
        VkQueueFamilyProperties q[16];
        if (qn > 16) qn = 16;
        c->vkGetPhysicalDeviceQueueFamilyProperties(c->physical, &qn, q);
        c->family = UINT32_MAX;
        for (uint32_t i = 0; i < qn; i++) if (q[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { c->family = i; break; }
        if (c->family == UINT32_MAX) { fail(c, "no graphics queue"); return -1; }
        float prio = 1;
        VkDeviceQueueCreateInfo qi = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
        qi.queueFamilyIndex = c->family; qi.queueCount = 1; qi.pQueuePriorities = &prio;
        VkPhysicalDeviceFeatures have, want;
        memset(&want, 0, sizeof want);
        c->vkGetPhysicalDeviceFeatures(c->physical, &have);
        want.samplerAnisotropy = have.samplerAnisotropy;
        c->anisotropy = have.samplerAnisotropy == VK_TRUE;
        VkDeviceCreateInfo di = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
        di.queueCreateInfoCount = 1; di.pQueueCreateInfos = &qi;
        di.pEnabledFeatures = &want;
        if (c->vkCreateDevice(c->physical, &di, NULL, &c->device) != VK_SUCCESS) { fail(c, "vkCreateDevice failed"); return -1; }
    }
#define LOADD(f) c->f = (PFN_##f)c->vkGetDeviceProcAddr(c->device, #f); if (!c->f) { fail(c, "Vulkan: %s missing", #f); return -1; }
    DFUNCS(LOADD)
#undef LOADD
    if (c->own) c->vkGetDeviceQueue(c->device, c->family, 0, &c->queue);
    c->vkGetPhysicalDeviceMemoryProperties(c->physical, &c->memory);
    c->vkGetPhysicalDeviceProperties(c->physical, &c->props);
    snprintf(c->name, sizeof c->name, "%s", c->props.deviceName);
    return 0;
}

static int dummy(yrp_context *c, texture *t, VkFormat format, const uint8_t value[4], size_t bytes) {
    t->format = format;
    if (texture_size(c, t, 1, 1)) return -1;
    void *d = stage_begin(c, t, 4);
    if (!d) return -1;
    memcpy(d, value, bytes);
    t->upload_width = 0;     /* the next real content sets the size */
    t->dirty = 1;
    return 0;
}

static VkDescriptorSet set_make(yrp_context *c) {
    VkDescriptorSetAllocateInfo ai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    ai.descriptorPool = c->pool; ai.descriptorSetCount = 1; ai.pSetLayouts = &c->set_layout;
    VkDescriptorSet s = VK_NULL_HANDLE;
    if (c->vkAllocateDescriptorSets(c->device, &ai, &s) != VK_SUCCESS) fail(c, "descriptor set");
    return s;
}

yrp_context *yrp_create(const yrp_vulkan *vk, char *error, size_t error_size) {
    yrp_context *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    if (load(c, vk)) goto fail;
    VkSamplerCreateInfo si = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    si.magFilter = si.minFilter = VK_FILTER_LINEAR;
    si.addressModeU = si.addressModeV = si.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    /* Trilinear, and anisotropic where the device has it: the warp and the cache's
       corners minify the picture, and more along one axis than the other. */
    si.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    si.maxLod = VK_LOD_CLAMP_NONE;
    if (c->anisotropy) { si.anisotropyEnable = VK_TRUE; si.maxAnisotropy = 8; }
    if (c->vkCreateSampler(c->device, &si, NULL, &c->linear) != VK_SUCCESS) { fail(c, "sampler"); goto fail; }
    si.anisotropyEnable = VK_FALSE;
    si.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    si.maxLod = 0;
    si.magFilter = si.minFilter = VK_FILTER_NEAREST;
    if (c->vkCreateSampler(c->device, &si, NULL, &c->nearest) != VK_SUCCESS) { fail(c, "sampler"); goto fail; }
    VkDescriptorSetLayoutBinding b[3];
    for (int i = 0; i < 3; i++)
        b[i] = (VkDescriptorSetLayoutBinding){ (uint32_t)i, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1,
                                               VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, NULL };
    VkDescriptorSetLayoutCreateInfo li = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    li.bindingCount = 3; li.pBindings = b;
    if (c->vkCreateDescriptorSetLayout(c->device, &li, NULL, &c->set_layout) != VK_SUCCESS) { fail(c, "set layout"); goto fail; }
    VkPushConstantRange pr = { VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(push_block) };
    VkPipelineLayoutCreateInfo pl = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pl.setLayoutCount = 1; pl.pSetLayouts = &c->set_layout;
    pl.pushConstantRangeCount = 1; pl.pPushConstantRanges = &pr;
    if (c->vkCreatePipelineLayout(c->device, &pl, NULL, &c->layout) != VK_SUCCESS) { fail(c, "pipeline layout"); goto fail; }
    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 3 * 14 };
    VkDescriptorPoolCreateInfo pi = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    pi.maxSets = 14; pi.poolSizeCount = 1; pi.pPoolSizes = &ps;
    if (c->vkCreateDescriptorPool(c->device, &pi, NULL, &c->pool) != VK_SUCCESS) { fail(c, "descriptor pool"); goto fail; }
    VkShaderModuleCreateInfo sm = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    sm.codeSize = sizeof yrp_vert_spv; sm.pCode = yrp_vert_spv;
    if (c->vkCreateShaderModule(c->device, &sm, NULL, &c->vert) != VK_SUCCESS) { fail(c, "vertex shader"); goto fail; }
    sm.codeSize = sizeof yrp_frag_spv; sm.pCode = yrp_frag_spv;
    if (c->vkCreateShaderModule(c->device, &sm, NULL, &c->frag) != VK_SUCCESS) { fail(c, "fragment shader"); goto fail; }
    sm.codeSize = sizeof yrp_cache_frag_spv; sm.pCode = yrp_cache_frag_spv;
    if (c->vkCreateShaderModule(c->device, &sm, NULL, &c->cache_frag) != VK_SUCCESS) { fail(c, "cache fragment shader"); goto fail; }
    sm.codeSize = sizeof yrp_yuv_vert_spv; sm.pCode = yrp_yuv_vert_spv;
    if (c->vkCreateShaderModule(c->device, &sm, NULL, &c->yuv_vert) != VK_SUCCESS) { fail(c, "YUV vertex shader"); goto fail; }
    sm.codeSize = sizeof yrp_yuv_frag_spv; sm.pCode = yrp_yuv_frag_spv;
    if (c->vkCreateShaderModule(c->device, &sm, NULL, &c->yuv_frag) != VK_SUCCESS) { fail(c, "YUV fragment shader"); goto fail; }
    VkCommandPoolCreateInfo cp = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cp.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cp.queueFamilyIndex = c->family;
    if (c->vkCreateCommandPool(c->device, &cp, NULL, &c->cmd_pool) != VK_SUCCESS) { fail(c, "command pool"); goto fail; }
    for (int i = 0; i < RING; i++) {
        VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
        ca.commandPool = c->cmd_pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
        if (c->vkAllocateCommandBuffers(c->device, &ca, &c->ring[i].cb) != VK_SUCCESS) { fail(c, "command buffer"); goto fail; }
        VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        if (c->vkCreateFence(c->device, &fi, NULL, &c->ring[i].fence) != VK_SUCCESS) { fail(c, "fence"); goto fail; }
    }
    if (c->props.limits.timestampPeriod > 0) {
        VkQueryPoolCreateInfo qi = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO };
        qi.queryType = VK_QUERY_TYPE_TIMESTAMP; qi.queryCount = RING * 2;
        if (c->vkCreateQueryPool(c->device, &qi, NULL, &c->queries) != VK_SUCCESS) c->queries = VK_NULL_HANDLE;
    }
    static const uint8_t black[4] = { 0, 0, 0, 0 };
    /* The picture: mips for minified sampling, and a render target for the video conversion. */
    c->colour.mipped = 1;
    c->colour.extra_usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (dummy(c, &c->colour, VK_FORMAT_B8G8R8A8_SRGB, black, 4) || dummy(c, &c->depth, VK_FORMAT_R16_UNORM, black, 2) ||
        dummy(c, &c->inset, VK_FORMAT_B8G8R8A8_SRGB, black, 4) || dummy(c, &c->zero_depth, VK_FORMAT_R16_UNORM, black, 2) ||
        dummy(c, &c->empty, VK_FORMAT_B8G8R8A8_SRGB, black, 4)) goto fail;
    for (int f = 0; f < 6; f++) { c->env[f].format = VK_FORMAT_R16G16B16A16_SFLOAT; c->env_depth[f].format = VK_FORMAT_R16_UNORM; }
    c->env_step = 1;
    c->fresh = (source){ &c->colour, &c->depth, &c->inset, set_make(c), 1 };
    for (int f = 0; f < 6; f++) {
        c->env_src[f] = (source){ &c->env[f], &c->zero_depth, &c->empty, set_make(c), 1 };
        c->cache_src[f] = (source){ &c->cache[f].colour, &c->cache[f].depth, &c->empty, set_make(c), 1 };
        if (!c->env_src[f].set || !c->cache_src[f].set) goto fail;
    }
    if (!c->fresh.set) goto fail;
    c->yuv_set = set_make(c);
    if (!c->yuv_set) goto fail;
    c->yuv.stale = 1;
    /* The environment's faces sample a transparent dummy until one arrives. */
    for (int f = 0; f < 6; f++) c->env_src[f].colour = &c->empty;
    c->gpu_ms = -1;
    return c;
fail:
    if (error && error_size) snprintf(error, error_size, "%s", c->error[0] ? c->error : "creation failed");
    yrp_destroy(c);
    return NULL;
}

void yrp_destroy(yrp_context *c) {
    if (!c) return;
    if (c->device && c->vkDeviceWaitIdle) {
        yrp_wait(c);
        cache_drop(c);
        if (c->cache_pipeline) c->vkDestroyPipeline(c->device, c->cache_pipeline, NULL);
        if (c->cache_pass) c->vkDestroyRenderPass(c->device, c->cache_pass, NULL);
        for (int i = 0; i < MAX_TARGETS; i++) if (c->targets[i].framebuffer || c->targets[i].view) target_drop(c, &c->targets[i]);
        for (int i = 0; i < c->pass_count; i++) {
            for (int k = 0; k < PIPES; k++) if (c->passes[i].pipeline[k]) c->vkDestroyPipeline(c->device, c->passes[i].pipeline[k], NULL);
            c->vkDestroyRenderPass(c->device, c->passes[i].pass, NULL);
        }
        if (c->colour_fb) c->vkDestroyFramebuffer(c->device, c->colour_fb, NULL);
        if (c->yuv_pipeline) c->vkDestroyPipeline(c->device, c->yuv_pipeline, NULL);
        if (c->yuv_pass) c->vkDestroyRenderPass(c->device, c->yuv_pass, NULL);
        if (c->yuv_vert) c->vkDestroyShaderModule(c->device, c->yuv_vert, NULL);
        if (c->yuv_frag) c->vkDestroyShaderModule(c->device, c->yuv_frag, NULL);
        texture *ts[20] = { &c->colour, &c->depth, &c->inset, &c->zero_depth, &c->empty,
                            &c->env[0], &c->env[1], &c->env[2], &c->env[3], &c->env[4], &c->env[5],
                            &c->env_depth[0], &c->env_depth[1], &c->env_depth[2], &c->env_depth[3], &c->env_depth[4], &c->env_depth[5],
                            &c->plane[0], &c->plane[1], &c->plane[2] };
        for (int i = 0; i < 20; i++) {
            texture_drop(c, ts[i]);
            if (ts[i]->stage.buffer) { c->vkDestroyBuffer(c->device, ts[i]->stage.buffer, NULL); c->vkFreeMemory(c->device, ts[i]->stage.memory, NULL); }
        }
        if (c->readback.buffer) { c->vkDestroyBuffer(c->device, c->readback.buffer, NULL); c->vkFreeMemory(c->device, c->readback.memory, NULL); }
        if (c->off) { c->vkDestroyImage(c->device, c->off, NULL); c->vkFreeMemory(c->device, c->off_memory, NULL); }
        for (int i = 0; i < RING; i++) if (c->ring[i].fence) c->vkDestroyFence(c->device, c->ring[i].fence, NULL);
        if (c->queries) c->vkDestroyQueryPool(c->device, c->queries, NULL);
        if (c->cmd_pool) c->vkDestroyCommandPool(c->device, c->cmd_pool, NULL);
        if (c->vert) c->vkDestroyShaderModule(c->device, c->vert, NULL);
        if (c->frag) c->vkDestroyShaderModule(c->device, c->frag, NULL);
        if (c->cache_frag) c->vkDestroyShaderModule(c->device, c->cache_frag, NULL);
        if (c->pool) c->vkDestroyDescriptorPool(c->device, c->pool, NULL);
        if (c->layout) c->vkDestroyPipelineLayout(c->device, c->layout, NULL);
        if (c->set_layout) c->vkDestroyDescriptorSetLayout(c->device, c->set_layout, NULL);
        if (c->linear) c->vkDestroySampler(c->device, c->linear, NULL);
        if (c->nearest) c->vkDestroySampler(c->device, c->nearest, NULL);
        if (c->own) c->vkDestroyDevice(c->device, NULL);
    }
    if (c->own && c->instance && c->vkDestroyInstance) c->vkDestroyInstance(c->instance, NULL);
    if (c->lib) dlclose(c->lib);
    free(c);
}
