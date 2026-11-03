/*
 * ov_vulkan.c: OpenViews' Vulkan compositor (see COVVulkan.h). Written from
 * the Vulkan 1.3 specification.
 */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#define VK_NO_PROTOTYPES 1
#include "vulkan/vulkan_core.h"
#include "include/COVVulkan.h"
#include "ov_shaders.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Dispatch                                                            */
/* ------------------------------------------------------------------ */

#define OVK_GLOBAL(X) \
    X(vkCreateInstance) \
    X(vkEnumerateInstanceExtensionProperties)

#define OVK_INSTANCE(X) \
    X(vkDestroyInstance) \
    X(vkEnumeratePhysicalDevices) \
    X(vkGetPhysicalDeviceProperties) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkGetPhysicalDeviceMemoryProperties) \
    X(vkGetPhysicalDeviceFormatProperties) \
    X(vkEnumerateDeviceExtensionProperties) \
    X(vkCreateDevice) \
    X(vkGetDeviceProcAddr)

#define OVK_SURFACE(X) \
    X(vkDestroySurfaceKHR) \
    X(vkGetPhysicalDeviceSurfaceSupportKHR) \
    X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR) \
    X(vkGetPhysicalDeviceSurfaceFormatsKHR)

#define OVK_DEVICE(X) \
    X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkDeviceWaitIdle) \
    X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) \
    X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkResetCommandBuffer) X(vkQueueSubmit) \
    X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences) \
    X(vkCreateSemaphore) X(vkDestroySemaphore) \
    X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) \
    X(vkAllocateMemory) X(vkFreeMemory) X(vkMapMemory) X(vkUnmapMemory) \
    X(vkCreateImageView) X(vkDestroyImageView) \
    X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) X(vkBindBufferMemory) \
    X(vkCreateSampler) X(vkDestroySampler) \
    X(vkCreateDescriptorSetLayout) X(vkDestroyDescriptorSetLayout) \
    X(vkCreateDescriptorPool) X(vkDestroyDescriptorPool) X(vkAllocateDescriptorSets) X(vkFreeDescriptorSets) \
    X(vkUpdateDescriptorSets) \
    X(vkCreatePipelineLayout) X(vkDestroyPipelineLayout) X(vkCreateShaderModule) X(vkDestroyShaderModule) \
    X(vkCreateGraphicsPipelines) X(vkDestroyPipeline) \
    X(vkCmdPipelineBarrier) X(vkCmdCopyBufferToImage) X(vkCmdCopyImageToBuffer) \
    X(vkCmdBeginRendering) X(vkCmdEndRendering) X(vkCmdBindPipeline) X(vkCmdSetViewport) X(vkCmdSetScissor) \
    X(vkCmdBindDescriptorSets) X(vkCmdPushConstants) X(vkCmdDraw)

#define OVK_SWAPCHAIN(X) \
    X(vkCreateSwapchainKHR) X(vkDestroySwapchainKHR) X(vkGetSwapchainImagesKHR) \
    X(vkAcquireNextImageKHR) X(vkQueuePresentKHR)

#define DECLARE(name) PFN_##name name;
typedef struct {
    PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;
    OVK_GLOBAL(DECLARE)
    OVK_INSTANCE(DECLARE)
    OVK_SURFACE(DECLARE)
    OVK_DEVICE(DECLARE)
    OVK_SWAPCHAIN(DECLARE)
} ovk_fns;
#undef DECLARE

static void *g_lib;
static PFN_vkGetInstanceProcAddr g_gipa;

static int fail(char *err, size_t errlen, const char *fmt, ...) {
    if (err && errlen) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(err, errlen, fmt, ap);
        va_end(ap);
    }
    return -1;
}

int ovk_load(char *err, size_t errlen) {
    if (g_gipa) return 0;
    const char *names[] = {
        getenv("OV_VULKAN_LIBRARY"), getenv("YCODE_VULKAN_LIBRARY"),
#if defined(__APPLE__)
        "libvulkan.1.dylib", "libMoltenVK.dylib",
#else
        "libvulkan.so.1", "libvulkan.so",
#endif
    };
    for (size_t i = 0; i < sizeof names / sizeof names[0] && !g_lib; i++)
        if (names[i] && *names[i]) g_lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!g_lib) return fail(err, errlen, "no Vulkan loader (libvulkan) on this host");
    g_gipa = (PFN_vkGetInstanceProcAddr)dlsym(g_lib, "vkGetInstanceProcAddr");
    if (!g_gipa) return fail(err, errlen, "the Vulkan loader has no vkGetInstanceProcAddr");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Context                                                             */
/* ------------------------------------------------------------------ */

#define MAX_IMAGES 8

typedef struct {
    int live;
    uint32_t w, h;
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkDescriptorSet set;
    VkBuffer staging;
    VkDeviceMemory staging_memory;
    uint8_t *mapped;
    int initialized;
    int pending;
    uint32_t px, py, pw, ph;
} ovk_layer;

struct ovk_context {
    ovk_fns f;
    VkInstance instance;
    VkPhysicalDevice phys;
    VkDevice device;
    VkQueue queue;
    uint32_t family;
    VkPhysicalDeviceMemoryProperties mem;
    char name[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE];
    int is_cpu;
    int has_swapchain_ext;

    VkCommandPool pool;
    VkCommandBuffer cmd;
    VkFence fence;
    VkSemaphore acquired, rendered;

    VkDescriptorSetLayout dsl;
    VkDescriptorPool dpool;
    VkPipelineLayout layout;
    VkPipeline pipeline;
    VkFormat pipeline_format;
    VkShaderModule vs, fs;
    VkSampler sampler;

    /* Target. */
    VkFormat format;
    uint32_t width, height;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    uint32_t image_count;
    VkImage images[MAX_IMAGES];
    VkImageView views[MAX_IMAGES];
    int swap_transfer_src;
    VkImage off_image;
    VkDeviceMemory off_memory;
    VkImageView off_view;

    VkBuffer read_buffer;
    VkDeviceMemory read_memory;
    uint8_t *read_mapped;
    size_t read_size;
    int read_bgra;

    ovk_layer *layers;
    uint32_t layer_count;
};

const char *ovk_device_name(const ovk_context *c) { return c->name; }
int ovk_device_is_cpu(const ovk_context *c) { return c->is_cpu; }
void *ovk_instance(const ovk_context *c) { return (void *)c->instance; }
void ovk_target_size(const ovk_context *c, uint32_t *w, uint32_t *h) {
    *w = c->width;
    *h = c->height;
}

static int memory_type(const ovk_context *c, uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < c->mem.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (c->mem.memoryTypes[i].propertyFlags & want) == want) return (int)i;
    return -1;
}

static int has_ext(const VkExtensionProperties *list, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++)
        if (strcmp(list[i].extensionName, name) == 0) return 1;
    return 0;
}

static int contains_ci(const char *hay, const char *needle) {
    size_t n = strlen(needle);
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < n && p[i] && ((p[i] | 32) == (needle[i] | 32))) i++;
        if (i == n) return 1;
    }
    return 0;
}

ovk_context *ovk_create(const char *const *extensions, uint32_t extension_count, int with_swapchain,
                        char *err, size_t errlen) {
    if (ovk_load(err, errlen) != 0) return NULL;
    ovk_context *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->f.vkGetInstanceProcAddr = g_gipa;
#define LOAD_GLOBAL(name) c->f.name = (PFN_##name)g_gipa(NULL, #name);
    OVK_GLOBAL(LOAD_GLOBAL)
#undef LOAD_GLOBAL
    if (!c->f.vkCreateInstance) {
        fail(err, errlen, "the Vulkan loader has no vkCreateInstance");
        free(c);
        return NULL;
    }
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "OpenViews",
                             .pEngineName = "OVRender", .apiVersion = VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
                                .enabledExtensionCount = extension_count, .ppEnabledExtensionNames = extensions};
    VkResult r = c->f.vkCreateInstance(&ici, NULL, &c->instance);
    if (r != VK_SUCCESS) {
        fail(err, errlen, "vkCreateInstance failed (%d)", r);
        free(c);
        return NULL;
    }
#define LOAD_INSTANCE(name) c->f.name = (PFN_##name)g_gipa(c->instance, #name);
    OVK_INSTANCE(LOAD_INSTANCE)
    OVK_SURFACE(LOAD_INSTANCE)
#undef LOAD_INSTANCE

    uint32_t n = 0;
    c->f.vkEnumeratePhysicalDevices(c->instance, &n, NULL);
    if (n == 0) {
        fail(err, errlen, "no Vulkan devices");
        ovk_destroy(c);
        return NULL;
    }
    VkPhysicalDevice *devs = calloc(n, sizeof *devs);
    c->f.vkEnumeratePhysicalDevices(c->instance, &n, devs);
    const char *want = getenv("OV_VULKAN_DEVICE");
    int best = -1, best_score = -1;
    uint32_t best_family = 0;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        c->f.vkGetPhysicalDeviceProperties(devs[i], &p);
        if (VK_API_VERSION_MAJOR(p.apiVersion) < 1 || (VK_API_VERSION_MAJOR(p.apiVersion) == 1 && VK_API_VERSION_MINOR(p.apiVersion) < 3))
            continue;
        uint32_t qn = 0;
        c->f.vkGetPhysicalDeviceQueueFamilyProperties(devs[i], &qn, NULL);
        VkQueueFamilyProperties qp[16];
        if (qn > 16) qn = 16;
        c->f.vkGetPhysicalDeviceQueueFamilyProperties(devs[i], &qn, qp);
        int family = -1;
        for (uint32_t q = 0; q < qn; q++)
            if (qp[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                family = (int)q;
                break;
            }
        if (family < 0) continue;
        if (with_swapchain) {
            uint32_t en = 0;
            c->f.vkEnumerateDeviceExtensionProperties(devs[i], NULL, &en, NULL);
            VkExtensionProperties *ex = calloc(en ? en : 1, sizeof *ex);
            c->f.vkEnumerateDeviceExtensionProperties(devs[i], NULL, &en, ex);
            int ok = has_ext(ex, en, VK_KHR_SWAPCHAIN_EXTENSION_NAME);
            free(ex);
            if (!ok) continue;
        }
        int score;
        switch (p.deviceType) {
        case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: score = 4; break;
        case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: score = 3; break;
        case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: score = 2; break;
        case VK_PHYSICAL_DEVICE_TYPE_CPU: score = 1; break;
        default: score = 0; break;
        }
        if (want && *want) {
            int is_cpu = p.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU;
            if (strcmp(want, "cpu") == 0) score = is_cpu ? 10 : -1;
            else if (strcmp(want, "gpu") == 0) score = is_cpu ? -1 : score + 5;
            else score = contains_ci(p.deviceName, want) ? 10 : -1;
        }
        if (score > best_score) {
            best_score = score;
            best = (int)i;
            best_family = (uint32_t)family;
        }
    }
    if (best < 0 || best_score < 0) {
        free(devs);
        fail(err, errlen, "no Vulkan 1.3 device with a graphics queue%s%s", want ? " matching OV_VULKAN_DEVICE=" : "", want ? want : "");
        ovk_destroy(c);
        return NULL;
    }
    c->phys = devs[best];
    free(devs);
    c->family = best_family;
    VkPhysicalDeviceProperties props;
    c->f.vkGetPhysicalDeviceProperties(c->phys, &props);
    snprintf(c->name, sizeof c->name, "%s", props.deviceName);
    c->is_cpu = props.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU;
    c->f.vkGetPhysicalDeviceMemoryProperties(c->phys, &c->mem);

    float priority = 1;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = c->family,
                                   .queueCount = 1, .pQueuePriorities = &priority};
    VkPhysicalDeviceVulkan13Features f13 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .dynamicRendering = VK_TRUE};
    const char *dext[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13, .queueCreateInfoCount = 1,
                              .pQueueCreateInfos = &qci, .enabledExtensionCount = with_swapchain ? 1 : 0,
                              .ppEnabledExtensionNames = with_swapchain ? dext : NULL};
    r = c->f.vkCreateDevice(c->phys, &dci, NULL, &c->device);
    if (r != VK_SUCCESS) {
        fail(err, errlen, "vkCreateDevice failed (%d) on %s", r, c->name);
        ovk_destroy(c);
        return NULL;
    }
    c->has_swapchain_ext = with_swapchain;
#define LOAD_DEVICE(name) c->f.name = (PFN_##name)c->f.vkGetDeviceProcAddr(c->device, #name);
    OVK_DEVICE(LOAD_DEVICE)
    if (with_swapchain) { OVK_SWAPCHAIN(LOAD_DEVICE) }
#undef LOAD_DEVICE
    c->f.vkGetDeviceQueue(c->device, c->family, 0, &c->queue);

    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                   .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = c->family};
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkSemaphoreCreateInfo sci = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    if (c->f.vkCreateCommandPool(c->device, &pci, NULL, &c->pool) != VK_SUCCESS ||
        c->f.vkCreateFence(c->device, &fci, NULL, &c->fence) != VK_SUCCESS ||
        c->f.vkCreateSemaphore(c->device, &sci, NULL, &c->acquired) != VK_SUCCESS ||
        c->f.vkCreateSemaphore(c->device, &sci, NULL, &c->rendered) != VK_SUCCESS) {
        fail(err, errlen, "could not create the command pool or synchronisation objects");
        ovk_destroy(c);
        return NULL;
    }
    VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = c->pool,
                                       .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    c->f.vkAllocateCommandBuffers(c->device, &cai, &c->cmd);

    /* Pipeline objects that do not depend on the target format. */
    VkDescriptorSetLayoutBinding b = {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                                      .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT};
    VkDescriptorSetLayoutCreateInfo dlci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &b};
    c->f.vkCreateDescriptorSetLayout(c->device, &dlci, NULL, &c->dsl);
    VkDescriptorPoolSize ps = {.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 256};
    VkDescriptorPoolCreateInfo dpci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                                       .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT, .maxSets = 256,
                                       .poolSizeCount = 1, .pPoolSizes = &ps};
    c->f.vkCreateDescriptorPool(c->device, &dpci, NULL, &c->dpool);
    VkPushConstantRange pcr = {.stageFlags = VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 48};
    VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
                                       .pSetLayouts = &c->dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
    c->f.vkCreatePipelineLayout(c->device, &plci, NULL, &c->layout);
    VkShaderModuleCreateInfo vsci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof ov_layer_vert_spv,
                                     .pCode = ov_layer_vert_spv};
    VkShaderModuleCreateInfo fsci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof ov_layer_frag_spv,
                                     .pCode = ov_layer_frag_spv};
    c->f.vkCreateShaderModule(c->device, &vsci, NULL, &c->vs);
    c->f.vkCreateShaderModule(c->device, &fsci, NULL, &c->fs);
    VkSamplerCreateInfo smp = {.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_LINEAR,
                               .minFilter = VK_FILTER_LINEAR, .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
                               .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                               .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .maxLod = 0};
    c->f.vkCreateSampler(c->device, &smp, NULL, &c->sampler);
    if (!c->dsl || !c->dpool || !c->layout || !c->vs || !c->fs || !c->sampler) {
        fail(err, errlen, "could not create the pipeline objects");
        ovk_destroy(c);
        return NULL;
    }
    return c;
}

static int ensure_pipeline(ovk_context *c, VkFormat format, char *err, size_t errlen) {
    if (c->pipeline && c->pipeline_format == format) return 0;
    if (c->pipeline) c->f.vkDestroyPipeline(c->device, c->pipeline, NULL);
    c->pipeline = VK_NULL_HANDLE;
    VkPipelineShaderStageCreateInfo stages[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = c->vs, .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = c->fs, .pName = "main"},
    };
    VkPipelineVertexInputStateCreateInfo vi = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo ia = {.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                                                 .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP};
    VkPipelineViewportStateCreateInfo vp = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1};
    VkPipelineRasterizationStateCreateInfo rs = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                                                 .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
                                                 .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1};
    VkPipelineMultisampleStateCreateInfo ms = {.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                               .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
    VkPipelineColorBlendAttachmentState att = {
        .blendEnable = VK_TRUE,
        .srcColorBlendFactor = VK_BLEND_FACTOR_ONE, .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .colorBlendOp = VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE, .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, .alphaBlendOp = VK_BLEND_OP_ADD,
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT};
    VkPipelineColorBlendStateCreateInfo cb = {.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1,
                                              .pAttachments = &att};
    VkDynamicState dyn[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo ds = {.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = dyn};
    VkPipelineRenderingCreateInfo rci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1,
                                         .pColorAttachmentFormats = &format};
    VkGraphicsPipelineCreateInfo gci = {.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &rci, .stageCount = 2,
                                        .pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vp,
                                        .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb,
                                        .pDynamicState = &ds, .layout = c->layout};
    VkResult r = c->f.vkCreateGraphicsPipelines(c->device, VK_NULL_HANDLE, 1, &gci, NULL, &c->pipeline);
    if (r != VK_SUCCESS) return fail(err, errlen, "vkCreateGraphicsPipelines failed (%d)", r);
    c->pipeline_format = format;
    return 0;
}

static int make_buffer(ovk_context *c, VkDeviceSize size, VkBufferUsageFlags usage, VkBuffer *buf, VkDeviceMemory *mem, uint8_t **mapped) {
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage,
                              .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
    if (c->f.vkCreateBuffer(c->device, &bci, NULL, buf) != VK_SUCCESS) return -1;
    VkMemoryRequirements req;
    c->f.vkGetBufferMemoryRequirements(c->device, *buf, &req);
    int t = memory_type(c, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (t < 0) return -1;
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = (uint32_t)t};
    if (c->f.vkAllocateMemory(c->device, &mai, NULL, mem) != VK_SUCCESS) return -1;
    c->f.vkBindBufferMemory(c->device, *buf, *mem, 0);
    return c->f.vkMapMemory(c->device, *mem, 0, VK_WHOLE_SIZE, 0, (void **)mapped) == VK_SUCCESS ? 0 : -1;
}

static int make_image(ovk_context *c, uint32_t w, uint32_t h, VkFormat format, VkImageUsageFlags usage, VkImage *img,
                      VkDeviceMemory *mem, VkImageView *view) {
    VkImageCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = format,
                             .extent = {w, h, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
                             .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
                             .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    if (c->f.vkCreateImage(c->device, &ici, NULL, img) != VK_SUCCESS) return -1;
    VkMemoryRequirements req;
    c->f.vkGetImageMemoryRequirements(c->device, *img, &req);
    int t = memory_type(c, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (t < 0) t = memory_type(c, req.memoryTypeBits, 0);
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = (uint32_t)t};
    if (t < 0 || c->f.vkAllocateMemory(c->device, &mai, NULL, mem) != VK_SUCCESS) return -1;
    c->f.vkBindImageMemory(c->device, *img, *mem, 0);
    VkImageViewCreateInfo vci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = *img, .viewType = VK_IMAGE_VIEW_TYPE_2D,
                                 .format = format, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    return c->f.vkCreateImageView(c->device, &vci, NULL, view) == VK_SUCCESS ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* Targets                                                             */
/* ------------------------------------------------------------------ */

static void destroy_target(ovk_context *c) {
    if (!c->device) return;
    c->f.vkDeviceWaitIdle(c->device);
    for (uint32_t i = 0; i < c->image_count; i++)
        if (c->views[i]) c->f.vkDestroyImageView(c->device, c->views[i], NULL);
    memset(c->views, 0, sizeof c->views);
    c->image_count = 0;
    if (c->swapchain) c->f.vkDestroySwapchainKHR(c->device, c->swapchain, NULL);
    c->swapchain = VK_NULL_HANDLE;
    if (c->off_view) c->f.vkDestroyImageView(c->device, c->off_view, NULL);
    if (c->off_image) c->f.vkDestroyImage(c->device, c->off_image, NULL);
    if (c->off_memory) c->f.vkFreeMemory(c->device, c->off_memory, NULL);
    c->off_view = VK_NULL_HANDLE;
    c->off_image = VK_NULL_HANDLE;
    c->off_memory = VK_NULL_HANDLE;
    if (c->read_buffer) c->f.vkDestroyBuffer(c->device, c->read_buffer, NULL);
    if (c->read_memory) c->f.vkFreeMemory(c->device, c->read_memory, NULL);
    c->read_buffer = VK_NULL_HANDLE;
    c->read_memory = VK_NULL_HANDLE;
    c->read_mapped = NULL;
}

static int make_readback(ovk_context *c, char *err, size_t errlen) {
    c->read_size = (size_t)c->width * c->height * 4;
    if (make_buffer(c, c->read_size, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &c->read_buffer, &c->read_memory, &c->read_mapped) != 0)
        return fail(err, errlen, "could not create the read-back buffer");
    return 0;
}

int ovk_set_offscreen(ovk_context *c, uint32_t width, uint32_t height, char *err, size_t errlen) {
    destroy_target(c);
    c->width = width ? width : 1;
    c->height = height ? height : 1;
    c->format = VK_FORMAT_R8G8B8A8_UNORM;
    c->read_bgra = 0;
    if (make_image(c, c->width, c->height, c->format, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                   &c->off_image, &c->off_memory, &c->off_view) != 0)
        return fail(err, errlen, "could not create the offscreen image");
    if (make_readback(c, err, errlen) != 0) return -1;
    return ensure_pipeline(c, c->format, err, errlen);
}

static int make_swapchain(ovk_context *c, uint32_t width, uint32_t height, char *err, size_t errlen) {
    VkSurfaceCapabilitiesKHR caps;
    if (c->f.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(c->phys, c->surface, &caps) != VK_SUCCESS)
        return fail(err, errlen, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR failed");
    VkExtent2D ext = caps.currentExtent;
    if (ext.width == 0xFFFFFFFFu) {
        ext.width = width;
        ext.height = height;
    }
    if (ext.width < caps.minImageExtent.width) ext.width = caps.minImageExtent.width;
    if (ext.height < caps.minImageExtent.height) ext.height = caps.minImageExtent.height;
    if (ext.width == 0 || ext.height == 0) return 1;
    uint32_t fn = 0;
    c->f.vkGetPhysicalDeviceSurfaceFormatsKHR(c->phys, c->surface, &fn, NULL);
    VkSurfaceFormatKHR formats[64];
    if (fn > 64) fn = 64;
    c->f.vkGetPhysicalDeviceSurfaceFormatsKHR(c->phys, c->surface, &fn, formats);
    /* Our pixels are already sRGB-encoded: prefer UNORM formats so they are
     * stored as is. */
    VkSurfaceFormatKHR chosen = fn ? formats[0] : (VkSurfaceFormatKHR){VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR};
    for (uint32_t i = 0; i < fn; i++)
        if ((formats[i].format == VK_FORMAT_B8G8R8A8_UNORM || formats[i].format == VK_FORMAT_R8G8B8A8_UNORM) &&
            formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            chosen = formats[i];
            break;
        }
    c->format = chosen.format;
    c->read_bgra = chosen.format == VK_FORMAT_B8G8R8A8_UNORM || chosen.format == VK_FORMAT_B8G8R8A8_SRGB;
    c->swap_transfer_src = (caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0;
    uint32_t count = caps.minImageCount + 1;
    if (caps.maxImageCount && count > caps.maxImageCount) count = caps.maxImageCount;
    if (count > MAX_IMAGES) count = MAX_IMAGES;
    VkCompositeAlphaFlagBitsKHR alpha = (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
        ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : (VkCompositeAlphaFlagBitsKHR)(caps.supportedCompositeAlpha & -caps.supportedCompositeAlpha);
    VkSwapchainCreateInfoKHR sci = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = c->surface, .minImageCount = count,
        .imageFormat = chosen.format, .imageColorSpace = chosen.colorSpace, .imageExtent = ext, .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | (c->swap_transfer_src ? VK_IMAGE_USAGE_TRANSFER_SRC_BIT : 0),
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = caps.currentTransform, .compositeAlpha = alpha,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE};
    VkResult r = c->f.vkCreateSwapchainKHR(c->device, &sci, NULL, &c->swapchain);
    if (r != VK_SUCCESS) return fail(err, errlen, "vkCreateSwapchainKHR failed (%d)", r);
    c->width = ext.width;
    c->height = ext.height;
    c->image_count = MAX_IMAGES;
    c->f.vkGetSwapchainImagesKHR(c->device, c->swapchain, &c->image_count, c->images);
    for (uint32_t i = 0; i < c->image_count; i++) {
        VkImageViewCreateInfo vci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = c->images[i],
                                     .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = c->format,
                                     .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
        if (c->f.vkCreateImageView(c->device, &vci, NULL, &c->views[i]) != VK_SUCCESS)
            return fail(err, errlen, "could not create a swapchain image view");
    }
    if (c->swap_transfer_src && make_readback(c, err, errlen) != 0) return -1;
    return ensure_pipeline(c, c->format, err, errlen);
}

int ovk_attach_surface(ovk_context *c, uint64_t surface, uint32_t width, uint32_t height, char *err, size_t errlen) {
    if (!c->has_swapchain_ext) return fail(err, errlen, "the context was created without swapchain support");
    destroy_target(c);
    if (c->surface && c->surface != (VkSurfaceKHR)(uintptr_t)surface) c->f.vkDestroySurfaceKHR(c->instance, c->surface, NULL);
    c->surface = (VkSurfaceKHR)(uintptr_t)surface;
    VkBool32 ok = VK_FALSE;
    c->f.vkGetPhysicalDeviceSurfaceSupportKHR(c->phys, c->family, c->surface, &ok);
    if (!ok) return fail(err, errlen, "the device's queue cannot present to this surface");
    int r = make_swapchain(c, width, height, err, errlen);
    return r < 0 ? -1 : 0;
}

int ovk_resize(ovk_context *c, uint32_t width, uint32_t height, char *err, size_t errlen) {
    if (c->surface) {
        destroy_target(c);
        int r = make_swapchain(c, width, height, err, errlen);
        return r < 0 ? -1 : 0;
    }
    return ovk_set_offscreen(c, width, height, err, errlen);
}

/* ------------------------------------------------------------------ */
/* Layers                                                              */
/* ------------------------------------------------------------------ */

void ovk_layer_release(ovk_context *c, uint32_t i) {
    if (i >= c->layer_count || !c->layers[i].live) return;
    ovk_layer *l = &c->layers[i];
    c->f.vkDeviceWaitIdle(c->device);
    if (l->set) c->f.vkFreeDescriptorSets(c->device, c->dpool, 1, &l->set);
    if (l->view) c->f.vkDestroyImageView(c->device, l->view, NULL);
    if (l->image) c->f.vkDestroyImage(c->device, l->image, NULL);
    if (l->memory) c->f.vkFreeMemory(c->device, l->memory, NULL);
    if (l->staging) c->f.vkDestroyBuffer(c->device, l->staging, NULL);
    if (l->staging_memory) c->f.vkFreeMemory(c->device, l->staging_memory, NULL);
    memset(l, 0, sizeof *l);
}

int ovk_layer_ensure(ovk_context *c, uint32_t i, uint32_t w, uint32_t h, char *err, size_t errlen) {
    if (w == 0) w = 1;
    if (h == 0) h = 1;
    if (i >= c->layer_count) {
        uint32_t n = i + 8;
        ovk_layer *grown = realloc(c->layers, n * sizeof *grown);
        if (!grown) return fail(err, errlen, "out of memory");
        memset(grown + c->layer_count, 0, (n - c->layer_count) * sizeof *grown);
        c->layers = grown;
        c->layer_count = n;
    }
    ovk_layer *l = &c->layers[i];
    if (l->live && l->w == w && l->h == h) return 0;
    ovk_layer_release(c, i);
    l->w = w;
    l->h = h;
    if (make_image(c, w, h, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                   &l->image, &l->memory, &l->view) != 0 ||
        make_buffer(c, (VkDeviceSize)w * h * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &l->staging, &l->staging_memory, &l->mapped) != 0)
        return fail(err, errlen, "could not create a %ux%u layer", w, h);
    VkDescriptorSetAllocateInfo dai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = c->dpool,
                                       .descriptorSetCount = 1, .pSetLayouts = &c->dsl};
    if (c->f.vkAllocateDescriptorSets(c->device, &dai, &l->set) != VK_SUCCESS) return fail(err, errlen, "out of layer descriptors");
    VkDescriptorImageInfo dii = {.sampler = c->sampler, .imageView = l->view, .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet wds = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = l->set, .descriptorCount = 1,
                                .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii};
    c->f.vkUpdateDescriptorSets(c->device, 1, &wds, 0, NULL);
    l->live = 1;
    memset(l->mapped, 0, (size_t)w * h * 4);
    l->pending = 1;
    l->px = 0;
    l->py = 0;
    l->pw = w;
    l->ph = h;
    return 0;
}

int ovk_layer_update(ovk_context *c, uint32_t i, const void *rgba, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (i >= c->layer_count || !c->layers[i].live) return -1;
    ovk_layer *l = &c->layers[i];
    if (x >= l->w || y >= l->h) return 0;
    if (x + w > l->w) w = l->w - x;
    if (y + h > l->h) h = l->h - y;
    const uint8_t *src = rgba;
    size_t stride = (size_t)l->w * 4;
    for (uint32_t row = y; row < y + h; row++)
        memcpy(l->mapped + row * stride + (size_t)x * 4, src + row * stride + (size_t)x * 4, (size_t)w * 4);
    if (l->pending) {
        uint32_t x0 = l->px < x ? l->px : x, y0 = l->py < y ? l->py : y;
        uint32_t x1 = l->px + l->pw > x + w ? l->px + l->pw : x + w, y1 = l->py + l->ph > y + h ? l->py + l->ph : y + h;
        l->px = x0;
        l->py = y0;
        l->pw = x1 - x0;
        l->ph = y1 - y0;
    } else {
        l->pending = 1;
        l->px = x;
        l->py = y;
        l->pw = w;
        l->ph = h;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Frames                                                              */
/* ------------------------------------------------------------------ */

static void barrier(ovk_context *c, VkImage img, VkImageLayout from, VkImageLayout to, VkAccessFlags src, VkAccessFlags dst,
                    VkPipelineStageFlags src_stage, VkPipelineStageFlags dst_stage) {
    VkImageMemoryBarrier b = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = src, .dstAccessMask = dst,
                              .oldLayout = from, .newLayout = to, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                              .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
                              .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    c->f.vkCmdPipelineBarrier(c->cmd, src_stage, dst_stage, 0, 0, NULL, 0, NULL, 1, &b);
}

int ovk_frame(ovk_context *c, const ovk_draw *draws, uint32_t count, const float clear[4], int readback, char *err, size_t errlen) {
    if (!c->swapchain && !c->off_image) return fail(err, errlen, "no target");
    uint32_t index = 0;
    VkImage target = c->off_image;
    VkImageView target_view = c->off_view;
    if (c->swapchain) {
        VkResult r = c->f.vkAcquireNextImageKHR(c->device, c->swapchain, UINT64_MAX, c->acquired, VK_NULL_HANDLE, &index);
        if (r == VK_ERROR_OUT_OF_DATE_KHR) return 1;
        if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR) return fail(err, errlen, "vkAcquireNextImageKHR failed (%d)", r);
        target = c->images[index];
        target_view = c->views[index];
    }
    c->f.vkResetFences(c->device, 1, &c->fence);
    c->f.vkResetCommandBuffer(c->cmd, 0);
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    c->f.vkBeginCommandBuffer(c->cmd, &bi);

    /* Uploads of changed layer pixels. */
    for (uint32_t i = 0; i < c->layer_count; i++) {
        ovk_layer *l = &c->layers[i];
        if (!l->live || !l->pending) continue;
        barrier(c, l->image, l->initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, l->initialized ? VK_ACCESS_SHADER_READ_BIT : 0, VK_ACCESS_TRANSFER_WRITE_BIT,
                l->initialized ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
        if (!l->initialized) {
            l->px = 0;
            l->py = 0;
            l->pw = l->w;
            l->ph = l->h;
        }
        VkBufferImageCopy region = {.bufferOffset = ((VkDeviceSize)l->py * l->w + l->px) * 4, .bufferRowLength = l->w,
                                    .bufferImageHeight = l->h, .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                    .imageOffset = {(int32_t)l->px, (int32_t)l->py, 0}, .imageExtent = {l->pw, l->ph, 1}};
        c->f.vkCmdCopyBufferToImage(c->cmd, l->staging, l->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        barrier(c, l->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
        l->initialized = 1;
        l->pending = 0;
    }

    barrier(c, target, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, 0, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
    VkRenderingAttachmentInfo att = {.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = target_view,
                                     .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                                     .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                     .clearValue.color.float32 = {clear[0], clear[1], clear[2], clear[3]}};
    VkRenderingInfo ri = {.sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = {{0, 0}, {c->width, c->height}}, .layerCount = 1,
                          .colorAttachmentCount = 1, .pColorAttachments = &att};
    c->f.vkCmdBeginRendering(c->cmd, &ri);
    VkViewport vp = {0, 0, (float)c->width, (float)c->height, 0, 1};
    c->f.vkCmdSetViewport(c->cmd, 0, 1, &vp);
    c->f.vkCmdBindPipeline(c->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, c->pipeline);
    for (uint32_t i = 0; i < count; i++) {
        const ovk_draw *d = &draws[i];
        if (d->layer >= c->layer_count || !c->layers[d->layer].live || d->opacity <= 0) continue;
        ovk_layer *l = &c->layers[d->layer];
        int32_t x0 = d->scissor_x < 0 ? 0 : d->scissor_x, y0 = d->scissor_y < 0 ? 0 : d->scissor_y;
        int32_t x1 = d->scissor_x + d->scissor_w, y1 = d->scissor_y + d->scissor_h;
        if (x1 > (int32_t)c->width) x1 = (int32_t)c->width;
        if (y1 > (int32_t)c->height) y1 = (int32_t)c->height;
        if (x1 <= x0 || y1 <= y0) continue;
        VkRect2D sc = {{x0, y0}, {(uint32_t)(x1 - x0), (uint32_t)(y1 - y0)}};
        c->f.vkCmdSetScissor(c->cmd, 0, 1, &sc);
        float push[12] = {d->a, d->c, d->tx, d->opacity, d->b, d->d, d->ty, 0,
                          (float)l->w, (float)l->h, (float)c->width, (float)c->height};
        c->f.vkCmdBindDescriptorSets(c->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, c->layout, 0, 1, &l->set, 0, NULL);
        c->f.vkCmdPushConstants(c->cmd, c->layout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof push, push);
        c->f.vkCmdDraw(c->cmd, 4, 1, 0, 0);
    }
    c->f.vkCmdEndRendering(c->cmd);

    int can_read = c->read_buffer && (!c->swapchain || c->swap_transfer_src);
    VkImageLayout final_layout = c->swapchain ? VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    if (readback && can_read) {
        barrier(c, target, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
        VkBufferImageCopy region = {.bufferRowLength = c->width, .bufferImageHeight = c->height,
                                    .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {c->width, c->height, 1}};
        c->f.vkCmdCopyImageToBuffer(c->cmd, target, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c->read_buffer, 1, &region);
        if (c->swapchain)
            barrier(c, target, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_ACCESS_TRANSFER_READ_BIT, 0,
                    VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
    } else if (c->swapchain) {
        barrier(c, target, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, final_layout, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, 0,
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
    }
    c->f.vkEndCommandBuffer(c->cmd);

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &c->cmd};
    if (c->swapchain) {
        si.waitSemaphoreCount = 1;
        si.pWaitSemaphores = &c->acquired;
        si.pWaitDstStageMask = &wait_stage;
        si.signalSemaphoreCount = 1;
        si.pSignalSemaphores = &c->rendered;
    }
    VkResult r = c->f.vkQueueSubmit(c->queue, 1, &si, c->fence);
    if (r != VK_SUCCESS) return fail(err, errlen, "vkQueueSubmit failed (%d)", r);
    int status = 0;
    if (c->swapchain) {
        VkPresentInfoKHR pi = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &c->rendered,
                               .swapchainCount = 1, .pSwapchains = &c->swapchain, .pImageIndices = &index};
        r = c->f.vkQueuePresentKHR(c->queue, &pi);
        if (r == VK_ERROR_OUT_OF_DATE_KHR || r == VK_SUBOPTIMAL_KHR) status = 1;
        else if (r != VK_SUCCESS) status = fail(err, errlen, "vkQueuePresentKHR failed (%d)", r);
    }
    c->f.vkWaitForFences(c->device, 1, &c->fence, VK_TRUE, UINT64_MAX);
    return status;
}

int ovk_readback(ovk_context *c, void *rgba, size_t size) {
    if (!c->read_mapped || size < c->read_size) return -1;
    memcpy(rgba, c->read_mapped, c->read_size);
    if (c->read_bgra) {
        uint8_t *p = rgba;
        for (size_t i = 0; i < c->read_size; i += 4) {
            uint8_t t = p[i];
            p[i] = p[i + 2];
            p[i + 2] = t;
        }
    }
    return 0;
}

void ovk_destroy(ovk_context *c) {
    if (!c) return;
    if (c->device) {
        c->f.vkDeviceWaitIdle(c->device);
        for (uint32_t i = 0; i < c->layer_count; i++) ovk_layer_release(c, i);
        free(c->layers);
        destroy_target(c);
        if (c->pipeline) c->f.vkDestroyPipeline(c->device, c->pipeline, NULL);
        if (c->vs) c->f.vkDestroyShaderModule(c->device, c->vs, NULL);
        if (c->fs) c->f.vkDestroyShaderModule(c->device, c->fs, NULL);
        if (c->sampler) c->f.vkDestroySampler(c->device, c->sampler, NULL);
        if (c->layout) c->f.vkDestroyPipelineLayout(c->device, c->layout, NULL);
        if (c->dpool) c->f.vkDestroyDescriptorPool(c->device, c->dpool, NULL);
        if (c->dsl) c->f.vkDestroyDescriptorSetLayout(c->device, c->dsl, NULL);
        if (c->acquired) c->f.vkDestroySemaphore(c->device, c->acquired, NULL);
        if (c->rendered) c->f.vkDestroySemaphore(c->device, c->rendered, NULL);
        if (c->fence) c->f.vkDestroyFence(c->device, c->fence, NULL);
        if (c->pool) c->f.vkDestroyCommandPool(c->device, c->pool, NULL);
        c->f.vkDestroyDevice(c->device, NULL);
    }
    if (c->surface && c->f.vkDestroySurfaceKHR) c->f.vkDestroySurfaceKHR(c->instance, c->surface, NULL);
    if (c->instance && c->f.vkDestroyInstance) c->f.vkDestroyInstance(c->instance, NULL);
    free(c);
}
