/*
 * CVulkan: the C side of Ycode's Vulkan back end for the simulator's Metal
 * host service (specs/simulator/stage8-contract.md §5.2, owner VK).
 *
 * - Loads the Vulkan loader at run time (dlopen of libvulkan.so.1, then
 *   vkGetInstanceProcAddr / vkGetDeviceProcAddr). Nothing links against
 *   Vulkan, so macOS and hosts without a GPU build and simply report that no
 *   device is available.
 * - Creates one device with the features of specs/simulator/metal-shaders.md
 *   §4–§5 (buffer device addresses, bindless descriptor heap, dynamic
 *   rendering, synchronization2, timeline semaphores, subgroup size control,
 *   VK_EXT_external_memory_host).
 * - Offers the struct-heavy operations (device, buffers including host-memory
 *   import, images and views, samplers, pipelines, dynamic rendering,
 *   barriers, submission) as flat C calls. Swift calls simple vkCmd*
 *   functions through the dispatch table returned by yvk_fns().
 *
 * Vendored headers: Sources/CVulkan/vulkan/ (vulkan_core.h, vk_platform.h, vk_video/) are the
 * Khronos Vulkan headers, version 1.3.275 (from Ubuntu's libvulkan-dev on
 * the Thor). License: Apache-2.0 (SPDX line in each file; Copyright The
 * Khronos Group Inc.). Apache-2.0 allows redistribution with the license
 * notice kept, which the files carry unchanged.
 */
#ifndef YCODE_CVULKAN_H
#define YCODE_CVULKAN_H

#define VK_NO_PROTOTYPES 1
#include "../vulkan/vulkan_core.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* VK_KHR_dynamic_rendering_local_read is newer than the vendored headers. */
#ifndef VK_KHR_dynamic_rendering_local_read
typedef struct YVKDynamicRenderingLocalReadFeatures {
    VkStructureType sType;
    void *pNext;
    VkBool32 dynamicRenderingLocalRead;
} YVKDynamicRenderingLocalReadFeatures;
#define YVK_STRUCTURE_TYPE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES ((VkStructureType)1000232000)
#endif

/* ------------------------------------------------------------------ */
/* Dispatch table                                                      */
/* ------------------------------------------------------------------ */

#define YVK_INSTANCE_FUNCTIONS(X) \
    X(vkDestroyInstance) \
    X(vkEnumeratePhysicalDevices) \
    X(vkGetPhysicalDeviceProperties) \
    X(vkGetPhysicalDeviceProperties2) \
    X(vkGetPhysicalDeviceFeatures2) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkGetPhysicalDeviceMemoryProperties) \
    X(vkGetPhysicalDeviceFormatProperties) \
    X(vkGetPhysicalDeviceImageFormatProperties) \
    X(vkEnumerateDeviceExtensionProperties) \
    X(vkCreateDevice) \
    X(vkGetDeviceProcAddr)

#define YVK_DEVICE_FUNCTIONS(X) \
    X(vkDestroyDevice) \
    X(vkGetDeviceQueue) \
    X(vkDeviceWaitIdle) \
    X(vkQueueSubmit2) \
    X(vkQueueWaitIdle) \
    X(vkAllocateMemory) \
    X(vkFreeMemory) \
    X(vkMapMemory) \
    X(vkUnmapMemory) \
    X(vkCreateBuffer) \
    X(vkDestroyBuffer) \
    X(vkGetBufferMemoryRequirements) \
    X(vkBindBufferMemory) \
    X(vkGetBufferDeviceAddress) \
    X(vkCreateImage) \
    X(vkDestroyImage) \
    X(vkGetImageMemoryRequirements) \
    X(vkBindImageMemory) \
    X(vkGetImageSubresourceLayout) \
    X(vkCreateImageView) \
    X(vkDestroyImageView) \
    X(vkCreateSampler) \
    X(vkDestroySampler) \
    X(vkCreateShaderModule) \
    X(vkDestroyShaderModule) \
    X(vkCreateDescriptorSetLayout) \
    X(vkDestroyDescriptorSetLayout) \
    X(vkCreateDescriptorPool) \
    X(vkDestroyDescriptorPool) \
    X(vkAllocateDescriptorSets) \
    X(vkUpdateDescriptorSets) \
    X(vkCreatePipelineLayout) \
    X(vkDestroyPipelineLayout) \
    X(vkCreateComputePipelines) \
    X(vkCreatePipelineCache) \
    X(vkDestroyPipelineCache) \
    X(vkGetPipelineCacheData) \
    X(vkCreateGraphicsPipelines) \
    X(vkDestroyPipeline) \
    X(vkCreateCommandPool) \
    X(vkDestroyCommandPool) \
    X(vkAllocateCommandBuffers) \
    X(vkFreeCommandBuffers) \
    X(vkBeginCommandBuffer) \
    X(vkEndCommandBuffer) \
    X(vkResetCommandBuffer) \
    X(vkCreateSemaphore) \
    X(vkDestroySemaphore) \
    X(vkWaitSemaphores) \
    X(vkSignalSemaphore) \
    X(vkGetSemaphoreCounterValue) \
    X(vkCmdPipelineBarrier2) \
    X(vkCmdBeginRendering) \
    X(vkCmdEndRendering) \
    X(vkCmdBindPipeline) \
    X(vkCmdBindDescriptorSets) \
    X(vkCmdPushConstants) \
    X(vkCmdBindVertexBuffers) \
    X(vkCmdBindIndexBuffer) \
    X(vkCmdDraw) \
    X(vkCmdDrawIndexed) \
    X(vkCmdDrawIndirect) \
    X(vkCmdDrawIndexedIndirect) \
    X(vkCmdDispatch) \
    X(vkCmdDispatchIndirect) \
    X(vkCmdSetViewport) \
    X(vkCmdSetScissor) \
    X(vkCmdSetCullMode) \
    X(vkCmdSetFrontFace) \
    X(vkCmdSetPrimitiveTopology) \
    X(vkCmdSetPrimitiveRestartEnable) \
    X(vkCmdSetDepthBias) \
    X(vkCmdSetDepthBiasEnable) \
    X(vkCmdSetBlendConstants) \
    X(vkCmdSetStencilReference) \
    X(vkCmdSetStencilCompareMask) \
    X(vkCmdSetStencilWriteMask) \
    X(vkCmdSetStencilTestEnable) \
    X(vkCmdSetStencilOp) \
    X(vkCmdSetDepthTestEnable) \
    X(vkCmdSetDepthWriteEnable) \
    X(vkCmdSetDepthCompareOp) \
    X(vkCmdCopyBuffer) \
    X(vkCmdCopyBufferToImage) \
    X(vkCmdCopyImageToBuffer) \
    X(vkCmdCopyImage) \
    X(vkCmdBlitImage) \
    X(vkCmdFillBuffer) \
    X(vkCmdUpdateBuffer) \
    X(vkCmdClearColorImage) \
    X(vkCreateQueryPool) \
    X(vkDestroyQueryPool) \
    X(vkCmdResetQueryPool) \
    X(vkCmdWriteTimestamp2) \
    X(vkGetQueryPoolResults)

/* Optional device functions (extensions); NULL when not present. */
#define YVK_OPTIONAL_DEVICE_FUNCTIONS(X) \
    X(vkGetMemoryHostPointerPropertiesEXT) \
    X(vkCmdSetPolygonModeEXT) \
    X(vkCmdSetDepthClampEnableEXT) \
    X(vkCmdSetCheckpointNV) \
    X(vkGetQueueCheckpointDataNV) \
    X(vkGetQueueCheckpointData2NV)

typedef struct yvk_dispatch {
    PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;
    PFN_vkCreateInstance vkCreateInstance;
    PFN_vkEnumerateInstanceVersion vkEnumerateInstanceVersion;
    PFN_vkEnumerateInstanceExtensionProperties vkEnumerateInstanceExtensionProperties;
#define YVK_DECL(name) PFN_##name name;
    YVK_INSTANCE_FUNCTIONS(YVK_DECL)
    YVK_DEVICE_FUNCTIONS(YVK_DECL)
    YVK_OPTIONAL_DEVICE_FUNCTIONS(YVK_DECL)
#undef YVK_DECL
} yvk_dispatch;

/* The process-wide dispatch table (filled by yvk_load and yvk_context_create). */
const yvk_dispatch *yvk_fns(void);

/* Loads the Vulkan loader. Returns 0 on success, -1 with a message in err. */
int yvk_load(char *err, size_t errlen);

/* ------------------------------------------------------------------ */
/* Device                                                              */
/* ------------------------------------------------------------------ */

typedef struct yvk_features {
    /* Required (context creation fails without them). */
    VkBool32 bufferDeviceAddress, descriptorIndexing, dynamicRendering, synchronization2,
             timelineSemaphore, maintenance4, subgroupSizeControl, computeFullSubgroups,
             externalMemoryHost;
    /* Optional, enabled when present. */
    VkBool32 shaderFloat16, shaderInt8, shaderInt16, shaderInt64, shaderFloat64,
             storageBuffer8BitAccess, storageBuffer16BitAccess, storagePushConstant16,
             storageInputOutput16, scalarBlockLayout, vulkanMemoryModel,
             samplerAnisotropy, samplerMirrorClampToEdge, dualSrcBlend, logicOp,
             independentBlend, depthClamp, depthBiasClamp, fillModeNonSolid, wideLines,
             largePoints, shaderClipDistance, multiDrawIndirect, drawIndirectFirstInstance,
             fragmentStoresAndAtomics, vertexPipelineStoresAndAtomics, imageCubeArray,
             textureCompressionBC, textureCompressionETC2, textureCompressionASTC_LDR,
             shaderStorageImageReadWithoutFormat, shaderStorageImageWriteWithoutFormat,
             customBorderColors, extendedDynamicState3PolygonMode, extendedDynamicState3DepthClamp,
             vertexAttributeInstanceRateDivisor, vertexAttributeInstanceRateZeroDivisor,
             fragmentShaderPixelInterlock, workgroupMemoryExplicitLayout, formatA8,
             dynamicRenderingLocalRead, fragmentShaderBarycentric, shaderDemoteToHelperInvocation,
             externalMemoryFd,
             /* VK_EXT_graphics_pipeline_library with fast linking and
                independent interpolation decorations. */
             graphicsPipelineLibrary,
             /* VK_NV_device_diagnostic_checkpoints, enabled when present and
                YCODE_GPU_CHECKPOINTS is not 0 (diagnostics of GPU hangs). */
             diagnosticCheckpoints;
} yvk_features;

typedef struct yvk_context {
    VkInstance instance;
    VkPhysicalDevice physical;
    VkDevice device;
    VkQueue queue;
    uint32_t queueFamily;
    VkPhysicalDeviceProperties properties;
    VkPhysicalDeviceMemoryProperties memory;
    VkDeviceSize hostPointerAlignment;
    uint32_t subgroupSize;
    yvk_features features;
    /* The bindless heap (metal-shaders.md §4.4): set 0. */
    VkDescriptorSetLayout heapLayout;
    VkDescriptorPool heapPool;
    VkDescriptorSet heapSet;
    uint32_t heapSampledImages;   /* binding 0: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE[heapSampledImages] */
    uint32_t heapStorageImages;   /* binding 1: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE[heapStorageImages] */
    uint32_t heapSamplers;        /* binding 2: VK_DESCRIPTOR_TYPE_SAMPLER[heapSamplers] (ycode-airc's abi.h) */
    /* The one pipeline layout every pipeline uses: set 0 = heap, push
       constants [0, YVK_PUSH_CONSTANT_SIZE) for all stages. */
    VkPipelineLayout pipelineLayout;
    VkCommandPool commandPool;
    /* Used by every pipeline creation (internally synchronized). */
    VkPipelineCache pipelineCache;
} yvk_context;

#define YVK_PUSH_CONSTANT_SIZE 128u

typedef struct yvk_context_options {
    uint32_t maxSampledImages;    /* 0 = default (65536, capped by the device) */
    uint32_t maxSamplers;         /* 0 = default (4096) */
    uint32_t maxStorageImages;    /* 0 = default (16384) */
    int validation;               /* 1: enable VK_LAYER_KHRONOS_validation when installed */
} yvk_context_options;

/* Creates the instance, device, queue, heap and pipeline layout. Returns 0,
   or -1 with a message (e.g. "no Vulkan loader", "missing feature X"). */
int yvk_context_create(yvk_context *ctx, const yvk_context_options *opts, char *err, size_t errlen);
void yvk_context_destroy(yvk_context *ctx);

/* (Re)creates ctx->pipelineCache from earlier cache data (NULL/0: empty;
   data from another driver or device is ignored by Vulkan). 0 or -1. */
int yvk_pipeline_cache_create(yvk_context *ctx, const void *data, size_t size);
/* The cache's current data: call with data NULL for the size. VkResult. */
VkResult yvk_pipeline_cache_data(yvk_context *ctx, void *data, size_t *size);

/* Format support for optimal tiling (VkFormatFeatureFlags). */
VkFormatFeatureFlags yvk_format_features(const yvk_context *ctx, VkFormat format);
VkFormatFeatureFlags yvk_format_buffer_features(const yvk_context *ctx, VkFormat format);

/* ------------------------------------------------------------------ */
/* Buffers                                                             */
/* ------------------------------------------------------------------ */

typedef enum yvk_memory_kind {
    YVK_MEMORY_DEVICE = 0,       /* device-local (host-visible too if the device has such a type) */
    YVK_MEMORY_HOST = 1,         /* host-visible, coherent, mapped */
    YVK_MEMORY_IMPORT_HOST = 2,  /* VK_EXT_external_memory_host import of hostPointer */
} yvk_memory_kind;

typedef struct yvk_buffer {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *mapped;                 /* host pointer when host-visible or imported, else NULL */
    VkDeviceSize size;
    VkDeviceAddress address;
} yvk_buffer;

/* hostPointer and size must be multiples of ctx->hostPointerAlignment for
   YVK_MEMORY_IMPORT_HOST. */
int yvk_buffer_create(yvk_context *ctx, VkDeviceSize size, yvk_memory_kind kind, void *hostPointer,
                      yvk_buffer *out, char *err, size_t errlen);
void yvk_buffer_destroy(yvk_context *ctx, yvk_buffer *buffer);

/* ------------------------------------------------------------------ */
/* Images                                                              */
/* ------------------------------------------------------------------ */

typedef struct yvk_image_info {
    VkImageType type;
    VkFormat format;
    uint32_t width, height, depth;
    uint32_t mipLevels, arrayLayers;
    VkSampleCountFlagBits samples;
    VkImageUsageFlags usage;
    VkImageCreateFlags flags;
} yvk_image_info;

typedef struct yvk_image {
    VkImage image;
    VkDeviceMemory memory;
} yvk_image;

int yvk_image_create(yvk_context *ctx, const yvk_image_info *info, yvk_image *out, char *err, size_t errlen);
void yvk_image_destroy(yvk_context *ctx, yvk_image *image);

typedef struct yvk_view_info {
    VkImage image;
    VkImageViewType viewType;
    VkFormat format;
    VkImageAspectFlags aspect;
    uint32_t baseLevel, levelCount, baseLayer, layerCount;
    VkComponentMapping components;
    VkImageUsageFlags usage;      /* 0 = inherit from the image */
} yvk_view_info;

VkImageView yvk_view_create(yvk_context *ctx, const yvk_view_info *info, char *err, size_t errlen);

/* Heap writes (layout GENERAL). */
void yvk_heap_write_sampled(yvk_context *ctx, uint32_t index, VkImageView view);
void yvk_heap_write_storage(yvk_context *ctx, uint32_t index, VkImageView view);
void yvk_heap_write_sampler(yvk_context *ctx, uint32_t index, VkSampler sampler);

/* ------------------------------------------------------------------ */
/* Samplers                                                            */
/* ------------------------------------------------------------------ */

typedef struct yvk_sampler_info {
    VkFilter magFilter, minFilter;
    VkSamplerMipmapMode mipmapMode;
    VkSamplerAddressMode addressU, addressV, addressW;
    float mipLodBias, maxAnisotropy, minLod, maxLod;
    VkBool32 anisotropyEnable, compareEnable, unnormalizedCoordinates;
    VkCompareOp compareOp;
    VkBorderColor borderColor;
} yvk_sampler_info;

VkSampler yvk_sampler_create(yvk_context *ctx, const yvk_sampler_info *info, char *err, size_t errlen);

/* ------------------------------------------------------------------ */
/* Pipelines                                                           */
/* ------------------------------------------------------------------ */

typedef struct yvk_spec_constant {
    uint32_t id;
    uint32_t value;
} yvk_spec_constant;

typedef struct yvk_shader_stage {
    const uint32_t *code;         /* SPIR-V words */
    size_t wordCount;
    const char *entry;
    const yvk_spec_constant *constants;
    uint32_t constantCount;
    VkPipelineShaderStageCreateFlags flags;
} yvk_shader_stage;

VkPipeline yvk_compute_pipeline_create(yvk_context *ctx, const yvk_shader_stage *stage, char *err, size_t errlen);

#define YVK_MAX_COLOR_ATTACHMENTS 8
#define YVK_MAX_VERTEX_BINDINGS 32
#define YVK_MAX_VERTEX_ATTRIBUTES 32

typedef struct yvk_vertex_binding {
    uint32_t binding, stride;
    VkVertexInputRate inputRate;
    uint32_t divisor;             /* instance rate only; 1 = every instance, 0 = constant */
} yvk_vertex_binding;

typedef struct yvk_graphics_info {
    yvk_shader_stage vertex;
    yvk_shader_stage fragment;    /* code NULL: rasterization disabled */
    uint32_t bindingCount;
    yvk_vertex_binding bindings[YVK_MAX_VERTEX_BINDINGS];
    uint32_t attributeCount;
    VkVertexInputAttributeDescription attributes[YVK_MAX_VERTEX_ATTRIBUTES];
    VkPrimitiveTopology topology;
    VkSampleCountFlagBits samples;
    VkBool32 alphaToCoverage;
    uint32_t colorCount;
    VkFormat colorFormats[YVK_MAX_COLOR_ATTACHMENTS];
    VkPipelineColorBlendAttachmentState blend[YVK_MAX_COLOR_ATTACHMENTS];
    VkFormat depthFormat, stencilFormat;
} yvk_graphics_info;

/* Graphics pipeline libraries (VK_EXT_graphics_pipeline_library). Each
   part uses the shared pipeline layout and the dynamic state list of
   yvk_graphics_pipeline_create; yvk_library_link fast-links four parts
   (vertex input, pre-rasterization, fragment shader, fragment output). */
VkPipeline yvk_library_vertex_input(yvk_context *ctx, const yvk_graphics_info *info, char *err, size_t errlen);
VkPipeline yvk_library_pre_raster(yvk_context *ctx, const yvk_shader_stage *vertex, int rasterizerDiscard,
                                  char *err, size_t errlen);
VkPipeline yvk_library_fragment_shader(yvk_context *ctx, const yvk_shader_stage *fragment, VkSampleCountFlagBits samples,
                                       char *err, size_t errlen);
VkPipeline yvk_library_fragment_output(yvk_context *ctx, const yvk_graphics_info *info, char *err, size_t errlen);
VkPipeline yvk_library_link(yvk_context *ctx, const VkPipeline *libraries, uint32_t count, int optimize,
                            char *err, size_t errlen);

/* Dynamic state: viewport, scissor, cull mode, front face, primitive
   topology, depth bias (+enable), blend constants, stencil reference /
   compare mask / write mask / test enable / op, depth test / write /
   compare; polygon mode and depth clamp when EDS3 provides them. */
VkPipeline yvk_graphics_pipeline_create(yvk_context *ctx, const yvk_graphics_info *info, char *err, size_t errlen);

/* ------------------------------------------------------------------ */
/* Commands                                                            */
/* ------------------------------------------------------------------ */

VkCommandBuffer yvk_command_buffer_begin(yvk_context *ctx, char *err, size_t errlen);
/* Resets and begins a command buffer that has completed. */
int yvk_command_buffer_restart(yvk_context *ctx, VkCommandBuffer cb);
void yvk_command_buffer_free(yvk_context *ctx, VkCommandBuffer cb);

typedef struct yvk_attachment {
    VkImageView view;             /* VK_NULL_HANDLE: unused */
    VkImageView resolveView;      /* VK_NULL_HANDLE: no resolve */
    VkResolveModeFlagBits resolveMode;
    VkAttachmentLoadOp load;
    VkAttachmentStoreOp store;
    VkClearValue clear;
} yvk_attachment;

typedef struct yvk_rendering_info {
    uint32_t x, y, width, height;
    uint32_t layerCount;
    uint32_t colorCount;
    yvk_attachment color[YVK_MAX_COLOR_ATTACHMENTS];
    yvk_attachment depth;
    yvk_attachment stencil;
} yvk_rendering_info;

/* All attachments are used in VK_IMAGE_LAYOUT_GENERAL. */
void yvk_cmd_begin_rendering(VkCommandBuffer cb, const yvk_rendering_info *info);

/* A full memory dependency: srcStages/srcAccess -> dstStages/dstAccess. */
void yvk_cmd_memory_barrier(VkCommandBuffer cb, VkPipelineStageFlags2 srcStages, VkAccessFlags2 srcAccess,
                            VkPipelineStageFlags2 dstStages, VkAccessFlags2 dstAccess);
/* Layout transition of a whole image (all levels and layers of aspect). */
void yvk_cmd_image_layout(VkCommandBuffer cb, VkImage image, VkImageAspectFlags aspect,
                          VkImageLayout from, VkImageLayout to);

/* Submits cb; signals the timeline semaphore with value; optionally waits
   for (waitSemaphore, waitValue) first. Returns VkResult. */
VkResult yvk_submit(yvk_context *ctx, VkCommandBuffer cb, VkSemaphore signal, uint64_t value,
                    VkSemaphore waitSemaphore, uint64_t waitValue);
VkSemaphore yvk_timeline_create(yvk_context *ctx, uint64_t initial);
/* Diagnostic checkpoints (VK_NV_device_diagnostic_checkpoints; nothing
   without it): a marker in the command stream, and after device loss the
   last markers the queue passed, top and bottom of the pipe. Returns the
   number written to markers/stages (at most max). */
void yvk_cmd_checkpoint(VkCommandBuffer cb, uint64_t marker);
uint32_t yvk_queue_checkpoints(yvk_context *ctx, uint64_t *markers, uint64_t *stages, uint32_t max);
/* Waits until semaphore >= value or timeoutNs passes. VK_SUCCESS or VK_TIMEOUT. */
VkResult yvk_timeline_wait(yvk_context *ctx, VkSemaphore semaphore, uint64_t value, uint64_t timeoutNs);
uint64_t yvk_timeline_value(yvk_context *ctx, VkSemaphore semaphore);
/* The counter and the call's result (VK_ERROR_DEVICE_LOST once the driver
   has killed the context, which a timed-out wait does not always say). */
VkResult yvk_timeline_query(yvk_context *ctx, VkSemaphore semaphore, uint64_t *value);
VkResult yvk_timeline_signal(yvk_context *ctx, VkSemaphore semaphore, uint64_t value);

/* Starts a helper process (the shader translator) with pipes on its stdin
   and stdout; stderr is inherited. Every other descriptor of this process
   is closed in the child (posix_spawn with closefrom on Linux, the
   close-on-exec default on Darwin), without scanning /proc/self/fd in
   this process. Returns 0, or an errno value. *toChild and *fromChild are
   close-on-exec in this process. */
int yvk_spawn_piped(const char *path, char *const argv[], int *pid, int *toChild, int *fromChild);
/* Writes all bytes; a closed reader gives EPIPE, never SIGPIPE (the signal
   is blocked in the calling thread and a pending one is consumed).
   Returns 0 or an errno value. */
int yvk_write_all(int fd, const void *bytes, size_t length);
/* Reads exactly length bytes. Returns 0, an errno value, or -1 at end of file. */
int yvk_read_exactly(int fd, void *bytes, size_t length);
/* Ends a helper process: SIGKILL, then waits for it. */
void yvk_end_child(int pid);

#ifdef __cplusplus
}
#endif
#endif /* YCODE_CVULKAN_H */
