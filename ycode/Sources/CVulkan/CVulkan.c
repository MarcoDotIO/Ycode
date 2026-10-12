/*
 * CVulkan.c: run-time loaded Vulkan for Ycode's Metal host back end
 * (stage8-contract.md §5.2, owner VK). Written from the Vulkan
 * specification and our own R8 harness (research/experiments/simulator/
 * metal-shaders/vk). See CVulkan.h.
 */
#include "CVulkan.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static yvk_dispatch g_vk;

const yvk_dispatch *yvk_fns(void) { return &g_vk; }

static int fail(char *err, size_t errlen, const char *fmt, ...) {
    if (err && errlen) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(err, errlen, fmt, ap);
        va_end(ap);
    }
    return -1;
}

/* ------------------------------------------------------------------ */
/* Loader                                                              */
/* ------------------------------------------------------------------ */

static void *g_lib;

int yvk_load(char *err, size_t errlen) {
    if (g_vk.vkGetInstanceProcAddr) return 0;
    const char *override = getenv("YCODE_VULKAN_LIBRARY");
    const char *names[] = {
        override,
#if defined(__APPLE__)
        "libvulkan.1.dylib",
#else
        "libvulkan.so.1",
        "libvulkan.so",
#endif
    };
    for (size_t i = 0; i < sizeof names / sizeof names[0] && !g_lib; i++) {
        if (names[i] && *names[i]) g_lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    }
    if (!g_lib) return fail(err, errlen, "no Vulkan loader (libvulkan.so.1) on this host");
    g_vk.vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(g_lib, "vkGetInstanceProcAddr");
    if (!g_vk.vkGetInstanceProcAddr) return fail(err, errlen, "the Vulkan loader has no vkGetInstanceProcAddr");
    g_vk.vkCreateInstance = (PFN_vkCreateInstance)g_vk.vkGetInstanceProcAddr(NULL, "vkCreateInstance");
    g_vk.vkEnumerateInstanceVersion =
        (PFN_vkEnumerateInstanceVersion)g_vk.vkGetInstanceProcAddr(NULL, "vkEnumerateInstanceVersion");
    g_vk.vkEnumerateInstanceExtensionProperties = (PFN_vkEnumerateInstanceExtensionProperties)
        g_vk.vkGetInstanceProcAddr(NULL, "vkEnumerateInstanceExtensionProperties");
    if (!g_vk.vkCreateInstance) return fail(err, errlen, "the Vulkan loader has no vkCreateInstance");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Device                                                              */
/* ------------------------------------------------------------------ */

static int has_extension(const VkExtensionProperties *list, uint32_t count, const char *name) {
    for (uint32_t i = 0; i < count; i++)
        if (strcmp(list[i].extensionName, name) == 0) return 1;
    return 0;
}

static uint32_t min_u32(uint32_t a, uint32_t b) { return a < b ? a : b; }

static int score_device(const VkPhysicalDeviceProperties *p) {
    switch (p->deviceType) {
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return 4;
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return 4;
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return 2;
    case VK_PHYSICAL_DEVICE_TYPE_CPU: return getenv("YCODE_VULKAN_ALLOW_CPU") ? 1 : 0;
    default: return 0;
    }
}

int yvk_context_create(yvk_context *ctx, const yvk_context_options *opts, char *err, size_t errlen) {
    memset(ctx, 0, sizeof *ctx);
    if (yvk_load(err, errlen) != 0) return -1;
    yvk_context_options defaults = {0};
    if (!opts) opts = &defaults;

    uint32_t instanceVersion = VK_API_VERSION_1_0;
    if (g_vk.vkEnumerateInstanceVersion) g_vk.vkEnumerateInstanceVersion(&instanceVersion);
    if (instanceVersion < VK_API_VERSION_1_3)
        return fail(err, errlen, "Vulkan instance version %u.%u is older than 1.3",
                    VK_API_VERSION_MAJOR(instanceVersion), VK_API_VERSION_MINOR(instanceVersion));

    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "ycode-metal-host", 1, "ycode", 1,
                             VK_API_VERSION_1_3};
    const char *layers[] = {"VK_LAYER_KHRONOS_validation"};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app};
    if (opts->validation || getenv("YCODE_VULKAN_VALIDATION")) {
        ici.enabledLayerCount = 1;
        ici.ppEnabledLayerNames = layers;
    }
    VkResult r = g_vk.vkCreateInstance(&ici, NULL, &ctx->instance);
    if (r == VK_ERROR_LAYER_NOT_PRESENT) {
        ici.enabledLayerCount = 0;
        r = g_vk.vkCreateInstance(&ici, NULL, &ctx->instance);
    }
    if (r != VK_SUCCESS) return fail(err, errlen, "vkCreateInstance failed (%d)", r);

#define YVK_LOAD_I(name) \
    g_vk.name = (PFN_##name)g_vk.vkGetInstanceProcAddr(ctx->instance, #name); \
    if (!g_vk.name) { yvk_context_destroy(ctx); return fail(err, errlen, "missing instance function " #name); }
    YVK_INSTANCE_FUNCTIONS(YVK_LOAD_I)
#undef YVK_LOAD_I

    uint32_t count = 0;
    g_vk.vkEnumeratePhysicalDevices(ctx->instance, &count, NULL);
    if (count == 0) { yvk_context_destroy(ctx); return fail(err, errlen, "no Vulkan physical device"); }
    VkPhysicalDevice devices[16];
    if (count > 16) count = 16;
    g_vk.vkEnumeratePhysicalDevices(ctx->instance, &count, devices);
    int best = -1, bestScore = 0;
    for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDeviceProperties p;
        g_vk.vkGetPhysicalDeviceProperties(devices[i], &p);
        int s = score_device(&p);
        if (p.apiVersion < VK_API_VERSION_1_3) s = 0;
        if (s > bestScore) { bestScore = s; best = (int)i; }
    }
    if (best < 0) { yvk_context_destroy(ctx); return fail(err, errlen, "no Vulkan 1.3 GPU"); }
    ctx->physical = devices[best];
    g_vk.vkGetPhysicalDeviceProperties(ctx->physical, &ctx->properties);
    g_vk.vkGetPhysicalDeviceMemoryProperties(ctx->physical, &ctx->memory);

    /* Queue family with graphics and compute. */
    uint32_t nq = 0;
    g_vk.vkGetPhysicalDeviceQueueFamilyProperties(ctx->physical, &nq, NULL);
    VkQueueFamilyProperties qp[32];
    if (nq > 32) nq = 32;
    g_vk.vkGetPhysicalDeviceQueueFamilyProperties(ctx->physical, &nq, qp);
    ctx->queueFamily = UINT32_MAX;
    for (uint32_t i = 0; i < nq; i++) {
        VkQueueFlags want = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
        if ((qp[i].queueFlags & want) == want) { ctx->queueFamily = i; break; }
    }
    if (ctx->queueFamily == UINT32_MAX) { yvk_context_destroy(ctx); return fail(err, errlen, "no graphics+compute queue"); }

    /* Extensions. */
    uint32_t next = 0;
    g_vk.vkEnumerateDeviceExtensionProperties(ctx->physical, NULL, &next, NULL);
    VkExtensionProperties *exts = calloc(next ? next : 1, sizeof *exts);
    g_vk.vkEnumerateDeviceExtensionProperties(ctx->physical, NULL, &next, exts);
    const char *enable[32];
    uint32_t nenable = 0;
#define WANT(name) (has_extension(exts, next, name) ? (enable[nenable++] = name, 1) : 0)
    int extHost = WANT(VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME);
    int extFd = WANT(VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME);
    int extEds3 = WANT(VK_EXT_EXTENDED_DYNAMIC_STATE_3_EXTENSION_NAME);
    int extBorder = WANT(VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME);
    int extDivisor = WANT(VK_EXT_VERTEX_ATTRIBUTE_DIVISOR_EXTENSION_NAME);
    int extInterlock = WANT(VK_EXT_FRAGMENT_SHADER_INTERLOCK_EXTENSION_NAME);
    int extWorkgroup = WANT(VK_KHR_WORKGROUP_MEMORY_EXPLICIT_LAYOUT_EXTENSION_NAME);
    int extMaint5 = WANT(VK_KHR_MAINTENANCE_5_EXTENSION_NAME);
    int extBary = WANT(VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME);
    int extLocalRead = WANT("VK_KHR_dynamic_rendering_local_read");
    (void)WANT(VK_EXT_SHADER_ATOMIC_FLOAT_EXTENSION_NAME);
    (void)WANT(VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME);
    (void)WANT(VK_KHR_SHADER_NON_SEMANTIC_INFO_EXTENSION_NAME);
#undef WANT
    free(exts);

    /* Query features. */
    YVKDynamicRenderingLocalReadFeatures lr = {YVK_STRUCTURE_TYPE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES};
    VkPhysicalDeviceFragmentShaderBarycentricFeaturesKHR bary = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR};
    VkPhysicalDeviceMaintenance5FeaturesKHR m5 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR};
    VkPhysicalDeviceWorkgroupMemoryExplicitLayoutFeaturesKHR wg = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_WORKGROUP_MEMORY_EXPLICIT_LAYOUT_FEATURES_KHR};
    VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT il = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT};
    VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT div = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_FEATURES_EXT};
    VkPhysicalDeviceCustomBorderColorFeaturesEXT bc = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_FEATURES_EXT};
    VkPhysicalDeviceExtendedDynamicState3FeaturesEXT eds3 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT};
    VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &f13};
    VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12};
    VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11};
    void **tail = &f13.pNext;
#define CHAIN(cond, s) if (cond) { *tail = &(s); tail = &(s).pNext; }
    CHAIN(extEds3, eds3)
    CHAIN(extBorder, bc)
    CHAIN(extDivisor, div)
    CHAIN(extInterlock, il)
    CHAIN(extWorkgroup, wg)
    CHAIN(extMaint5, m5)
    CHAIN(extBary, bary)
    CHAIN(extLocalRead, lr)
#undef CHAIN
    g_vk.vkGetPhysicalDeviceFeatures2(ctx->physical, &f2);

    yvk_features *F = &ctx->features;
    F->bufferDeviceAddress = f12.bufferDeviceAddress;
    F->descriptorIndexing = f12.descriptorIndexing && f12.runtimeDescriptorArray &&
                            f12.descriptorBindingPartiallyBound &&
                            f12.descriptorBindingSampledImageUpdateAfterBind &&
                            f12.descriptorBindingStorageImageUpdateAfterBind &&
                            f12.shaderSampledImageArrayNonUniformIndexing;
    F->dynamicRendering = f13.dynamicRendering;
    F->synchronization2 = f13.synchronization2;
    F->timelineSemaphore = f12.timelineSemaphore;
    F->maintenance4 = f13.maintenance4;
    F->subgroupSizeControl = f13.subgroupSizeControl;
    F->computeFullSubgroups = f13.computeFullSubgroups;
    F->externalMemoryHost = extHost;
    F->externalMemoryFd = extFd;
    F->shaderFloat16 = f12.shaderFloat16;
    F->shaderInt8 = f12.shaderInt8;
    F->shaderInt16 = f2.features.shaderInt16;
    F->shaderInt64 = f2.features.shaderInt64;
    F->shaderFloat64 = f2.features.shaderFloat64;
    F->storageBuffer8BitAccess = f12.storageBuffer8BitAccess;
    F->storageBuffer16BitAccess = f11.storageBuffer16BitAccess;
    F->storagePushConstant16 = f11.storagePushConstant16;
    F->storageInputOutput16 = f11.storageInputOutput16;
    F->scalarBlockLayout = f12.scalarBlockLayout;
    F->vulkanMemoryModel = f12.vulkanMemoryModel;
    F->samplerAnisotropy = f2.features.samplerAnisotropy;
    F->samplerMirrorClampToEdge = f12.samplerMirrorClampToEdge;
    F->dualSrcBlend = f2.features.dualSrcBlend;
    F->logicOp = f2.features.logicOp;
    F->independentBlend = f2.features.independentBlend;
    F->depthClamp = f2.features.depthClamp;
    F->depthBiasClamp = f2.features.depthBiasClamp;
    F->fillModeNonSolid = f2.features.fillModeNonSolid;
    F->wideLines = f2.features.wideLines;
    F->largePoints = f2.features.largePoints;
    F->shaderClipDistance = f2.features.shaderClipDistance;
    F->multiDrawIndirect = f2.features.multiDrawIndirect;
    F->drawIndirectFirstInstance = f2.features.drawIndirectFirstInstance;
    F->fragmentStoresAndAtomics = f2.features.fragmentStoresAndAtomics;
    F->vertexPipelineStoresAndAtomics = f2.features.vertexPipelineStoresAndAtomics;
    F->imageCubeArray = f2.features.imageCubeArray;
    F->textureCompressionBC = f2.features.textureCompressionBC;
    F->textureCompressionETC2 = f2.features.textureCompressionETC2;
    F->textureCompressionASTC_LDR = f2.features.textureCompressionASTC_LDR;
    F->shaderStorageImageReadWithoutFormat = f2.features.shaderStorageImageReadWithoutFormat;
    F->shaderStorageImageWriteWithoutFormat = f2.features.shaderStorageImageWriteWithoutFormat;
    F->customBorderColors = extBorder && bc.customBorderColors;
    F->extendedDynamicState3PolygonMode = extEds3 && eds3.extendedDynamicState3PolygonMode;
    F->extendedDynamicState3DepthClamp = extEds3 && eds3.extendedDynamicState3DepthClampEnable;
    F->vertexAttributeInstanceRateDivisor = extDivisor && div.vertexAttributeInstanceRateDivisor;
    F->vertexAttributeInstanceRateZeroDivisor = extDivisor && div.vertexAttributeInstanceRateZeroDivisor;
    F->fragmentShaderPixelInterlock = extInterlock && il.fragmentShaderPixelInterlock;
    F->workgroupMemoryExplicitLayout = extWorkgroup && wg.workgroupMemoryExplicitLayout;
    F->formatA8 = extMaint5 && m5.maintenance5;
    F->dynamicRenderingLocalRead = extLocalRead && lr.dynamicRenderingLocalRead;
    F->fragmentShaderBarycentric = extBary && bary.fragmentShaderBarycentric;
    F->shaderDemoteToHelperInvocation = f13.shaderDemoteToHelperInvocation;

    const char *missing = NULL;
    if (!F->bufferDeviceAddress) missing = "bufferDeviceAddress";
    else if (!F->descriptorIndexing) missing = "descriptorIndexing (runtime arrays, partially bound, update after bind)";
    else if (!F->dynamicRendering) missing = "dynamicRendering";
    else if (!F->synchronization2) missing = "synchronization2";
    else if (!F->timelineSemaphore) missing = "timelineSemaphore";
    else if (!F->maintenance4) missing = "maintenance4";
    else if (!F->subgroupSizeControl) missing = "subgroupSizeControl";
    else if (!F->externalMemoryHost) missing = "VK_EXT_external_memory_host";
    else if (!F->shaderInt64) missing = "shaderInt64";
    if (missing) { yvk_context_destroy(ctx); return fail(err, errlen, "Vulkan device lacks %s", missing); }

    /* Enable everything the device has, except robustness (performance;
       Metal does not promise bounds checks) and features that change
       allocation behaviour. */
    f2.features.robustBufferAccess = VK_FALSE;
    f12.bufferDeviceAddressMultiDevice = VK_FALSE;
    f13.robustImageAccess = VK_FALSE;
    f13.pipelineCreationCacheControl = f13.pipelineCreationCacheControl;

    /* Properties: host pointer alignment, subgroup size, descriptor limits. */
    VkPhysicalDeviceExternalMemoryHostPropertiesEXT hostp = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
    VkPhysicalDeviceVulkan12Properties p12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES, &hostp};
    VkPhysicalDeviceVulkan11Properties p11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES, &p12};
    VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p11};
    g_vk.vkGetPhysicalDeviceProperties2(ctx->physical, &p2);
    ctx->hostPointerAlignment = hostp.minImportedHostPointerAlignment ? hostp.minImportedHostPointerAlignment : 4096;
    ctx->subgroupSize = p11.subgroupSize;

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, ctx->queueFamily, 1, &prio};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, 0, 1, &qci, 0, NULL, nenable, enable, NULL};
    r = g_vk.vkCreateDevice(ctx->physical, &dci, NULL, &ctx->device);
    if (r != VK_SUCCESS) { yvk_context_destroy(ctx); return fail(err, errlen, "vkCreateDevice failed (%d)", r); }

#define YVK_LOAD_D(name) \
    g_vk.name = (PFN_##name)g_vk.vkGetDeviceProcAddr(ctx->device, #name); \
    if (!g_vk.name) { yvk_context_destroy(ctx); return fail(err, errlen, "missing device function " #name); }
    YVK_DEVICE_FUNCTIONS(YVK_LOAD_D)
#undef YVK_LOAD_D
#define YVK_LOAD_O(name) g_vk.name = (PFN_##name)g_vk.vkGetDeviceProcAddr(ctx->device, #name);
    YVK_OPTIONAL_DEVICE_FUNCTIONS(YVK_LOAD_O)
#undef YVK_LOAD_O
    if (!g_vk.vkGetMemoryHostPointerPropertiesEXT) {
        yvk_context_destroy(ctx);
        return fail(err, errlen, "missing vkGetMemoryHostPointerPropertiesEXT");
    }
    if (!F->extendedDynamicState3PolygonMode) g_vk.vkCmdSetPolygonModeEXT = NULL;
    if (!F->extendedDynamicState3DepthClamp) g_vk.vkCmdSetDepthClampEnableEXT = NULL;
    g_vk.vkGetDeviceQueue(ctx->device, ctx->queueFamily, 0, &ctx->queue);

    /* Bindless heap. */
    const VkPhysicalDeviceLimits *L = &ctx->properties.limits;
    uint32_t wantImages = opts->maxSampledImages ? opts->maxSampledImages : 65536;
    uint32_t wantSamplers = opts->maxSamplers ? opts->maxSamplers : 4096;
    uint32_t wantStorage = opts->maxStorageImages ? opts->maxStorageImages : 16384;
    ctx->heapSampledImages = min_u32(wantImages, min_u32(p12.maxDescriptorSetUpdateAfterBindSampledImages,
                                                         p12.maxPerStageDescriptorUpdateAfterBindSampledImages));
    ctx->heapSamplers = min_u32(wantSamplers, min_u32(p12.maxDescriptorSetUpdateAfterBindSamplers,
                                                      p12.maxPerStageDescriptorUpdateAfterBindSamplers));
    ctx->heapStorageImages = min_u32(wantStorage, min_u32(p12.maxDescriptorSetUpdateAfterBindStorageImages,
                                                          p12.maxPerStageDescriptorUpdateAfterBindStorageImages));
    uint32_t perStage = p12.maxPerStageUpdateAfterBindResources;
    while (ctx->heapSampledImages + ctx->heapSamplers + ctx->heapStorageImages > perStage) {
        ctx->heapSampledImages /= 2;
        ctx->heapStorageImages /= 2;
    }
    (void)L;
    VkDescriptorSetLayoutBinding binds[3] = {
        {0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, ctx->heapSampledImages, VK_SHADER_STAGE_ALL, NULL},
        {1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, ctx->heapStorageImages, VK_SHADER_STAGE_ALL, NULL},
        {2, VK_DESCRIPTOR_TYPE_SAMPLER, ctx->heapSamplers, VK_SHADER_STAGE_ALL, NULL}};
    VkDescriptorBindingFlags bflags[3];
    for (int i = 0; i < 3; i++)
        bflags[i] = VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT | VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT |
                    VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT;
    VkDescriptorSetLayoutBindingFlagsCreateInfo bfi = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO, NULL, 3, bflags};
    VkDescriptorSetLayoutCreateInfo dli = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, &bfi,
                                           VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT, 3, binds};
    r = g_vk.vkCreateDescriptorSetLayout(ctx->device, &dli, NULL, &ctx->heapLayout);
    if (r != VK_SUCCESS) { yvk_context_destroy(ctx); return fail(err, errlen, "heap layout failed (%d)", r); }
    VkDescriptorPoolSize sizes[3] = {{VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, ctx->heapSampledImages},
                                     {VK_DESCRIPTOR_TYPE_SAMPLER, ctx->heapSamplers},
                                     {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, ctx->heapStorageImages}};
    VkDescriptorPoolCreateInfo dpi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL,
                                      VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT, 1, 3, sizes};
    r = g_vk.vkCreateDescriptorPool(ctx->device, &dpi, NULL, &ctx->heapPool);
    if (r != VK_SUCCESS) { yvk_context_destroy(ctx); return fail(err, errlen, "heap pool failed (%d)", r); }
    VkDescriptorSetAllocateInfo dai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, ctx->heapPool, 1,
                                       &ctx->heapLayout};
    r = g_vk.vkAllocateDescriptorSets(ctx->device, &dai, &ctx->heapSet);
    if (r != VK_SUCCESS) { yvk_context_destroy(ctx); return fail(err, errlen, "heap set failed (%d)", r); }

    VkPushConstantRange pcr = {VK_SHADER_STAGE_ALL, 0, YVK_PUSH_CONSTANT_SIZE};
    VkPipelineLayoutCreateInfo pli = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &ctx->heapLayout, 1,
                                      &pcr};
    r = g_vk.vkCreatePipelineLayout(ctx->device, &pli, NULL, &ctx->pipelineLayout);
    if (r != VK_SUCCESS) { yvk_context_destroy(ctx); return fail(err, errlen, "pipeline layout failed (%d)", r); }

    VkCommandPoolCreateInfo cpi = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
                                   VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, ctx->queueFamily};
    r = g_vk.vkCreateCommandPool(ctx->device, &cpi, NULL, &ctx->commandPool);
    if (r != VK_SUCCESS) { yvk_context_destroy(ctx); return fail(err, errlen, "command pool failed (%d)", r); }
    return 0;
}

void yvk_context_destroy(yvk_context *ctx) {
    if (ctx->device) {
        g_vk.vkDeviceWaitIdle(ctx->device);
        if (ctx->commandPool) g_vk.vkDestroyCommandPool(ctx->device, ctx->commandPool, NULL);
        if (ctx->pipelineLayout) g_vk.vkDestroyPipelineLayout(ctx->device, ctx->pipelineLayout, NULL);
        if (ctx->heapPool) g_vk.vkDestroyDescriptorPool(ctx->device, ctx->heapPool, NULL);
        if (ctx->heapLayout) g_vk.vkDestroyDescriptorSetLayout(ctx->device, ctx->heapLayout, NULL);
        g_vk.vkDestroyDevice(ctx->device, NULL);
    }
    if (ctx->instance && g_vk.vkDestroyInstance) g_vk.vkDestroyInstance(ctx->instance, NULL);
    memset(ctx, 0, sizeof *ctx);
}

VkFormatFeatureFlags yvk_format_features(const yvk_context *ctx, VkFormat format) {
    VkFormatProperties fp = {0};
    g_vk.vkGetPhysicalDeviceFormatProperties(ctx->physical, format, &fp);
    return fp.optimalTilingFeatures;
}

VkFormatFeatureFlags yvk_format_buffer_features(const yvk_context *ctx, VkFormat format) {
    VkFormatProperties fp = {0};
    g_vk.vkGetPhysicalDeviceFormatProperties(ctx->physical, format, &fp);
    return fp.bufferFeatures;
}

/* ------------------------------------------------------------------ */
/* Memory                                                              */
/* ------------------------------------------------------------------ */

static int32_t find_memory(const yvk_context *ctx, uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < ctx->memory.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (ctx->memory.memoryTypes[i].propertyFlags & want) == want) return (int32_t)i;
    return -1;
}

int yvk_buffer_create(yvk_context *ctx, VkDeviceSize size, yvk_memory_kind kind, void *hostPointer,
                      yvk_buffer *out, char *err, size_t errlen) {
    memset(out, 0, sizeof *out);
    if (size == 0) size = 4;
    VkExternalMemoryBufferCreateInfo ext = {VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO, NULL,
                                            VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT};
    if (kind == YVK_MEMORY_IMPORT_HOST) {
        if (!hostPointer || ((uintptr_t)hostPointer % ctx->hostPointerAlignment) != 0 ||
            (size % ctx->hostPointerAlignment) != 0)
            return fail(err, errlen, "host import of %p (+%llu) is not %llu-aligned", hostPointer,
                        (unsigned long long)size, (unsigned long long)ctx->hostPointerAlignment);
    }
    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, kind == YVK_MEMORY_IMPORT_HOST ? &ext : NULL, 0,
                             size,
                             VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                                 VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                                 VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                                 VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                             VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    VkResult r = g_vk.vkCreateBuffer(ctx->device, &bi, NULL, &out->buffer);
    if (r != VK_SUCCESS) return fail(err, errlen, "vkCreateBuffer(%llu) failed (%d)", (unsigned long long)size, r);
    VkMemoryRequirements mr;
    g_vk.vkGetBufferMemoryRequirements(ctx->device, out->buffer, &mr);
    VkMemoryAllocateFlagsInfo flags = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, NULL,
                                       VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT, 0};
    VkImportMemoryHostPointerInfoEXT imp = {VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT, NULL,
                                            VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, hostPointer};
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &flags, mr.size, 0};
    int32_t type = -1;
    switch (kind) {
    case YVK_MEMORY_DEVICE:
        type = find_memory(ctx, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT |
                                                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                       VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (type < 0) type = find_memory(ctx, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        break;
    case YVK_MEMORY_HOST:
        type = find_memory(ctx, mr.memoryTypeBits,
                           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        break;
    case YVK_MEMORY_IMPORT_HOST: {
        VkMemoryHostPointerPropertiesEXT hp = {VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
        r = g_vk.vkGetMemoryHostPointerPropertiesEXT(ctx->device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT,
                                                     hostPointer, &hp);
        if (r != VK_SUCCESS) {
            g_vk.vkDestroyBuffer(ctx->device, out->buffer, NULL);
            out->buffer = VK_NULL_HANDLE;
            return fail(err, errlen, "vkGetMemoryHostPointerPropertiesEXT(%p) failed (%d)", hostPointer, r);
        }
        uint32_t bits = hp.memoryTypeBits & mr.memoryTypeBits;
        type = find_memory(ctx, bits, VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (type < 0) type = find_memory(ctx, bits, 0);
        flags.pNext = &imp;
        ai.allocationSize = size;
        break;
    }
    }
    if (type < 0) {
        g_vk.vkDestroyBuffer(ctx->device, out->buffer, NULL);
        out->buffer = VK_NULL_HANDLE;
        return fail(err, errlen, "no memory type for buffer (kind %d, bits 0x%x)", (int)kind, mr.memoryTypeBits);
    }
    ai.memoryTypeIndex = (uint32_t)type;
    r = g_vk.vkAllocateMemory(ctx->device, &ai, NULL, &out->memory);
    if (r != VK_SUCCESS) {
        g_vk.vkDestroyBuffer(ctx->device, out->buffer, NULL);
        out->buffer = VK_NULL_HANDLE;
        return fail(err, errlen, "vkAllocateMemory(%llu, kind %d) failed (%d)", (unsigned long long)ai.allocationSize,
                    (int)kind, r);
    }
    r = g_vk.vkBindBufferMemory(ctx->device, out->buffer, out->memory, 0);
    if (r != VK_SUCCESS) {
        yvk_buffer_destroy(ctx, out);
        return fail(err, errlen, "vkBindBufferMemory failed (%d)", r);
    }
    if (kind == YVK_MEMORY_IMPORT_HOST) {
        out->mapped = hostPointer;
    } else if (ctx->memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) {
        r = g_vk.vkMapMemory(ctx->device, out->memory, 0, VK_WHOLE_SIZE, 0, &out->mapped);
        if (r != VK_SUCCESS) out->mapped = NULL;
    }
    out->size = size;
    VkBufferDeviceAddressInfo da = {VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, out->buffer};
    out->address = g_vk.vkGetBufferDeviceAddress(ctx->device, &da);
    return 0;
}

void yvk_buffer_destroy(yvk_context *ctx, yvk_buffer *b) {
    if (b->buffer) g_vk.vkDestroyBuffer(ctx->device, b->buffer, NULL);
    if (b->memory) g_vk.vkFreeMemory(ctx->device, b->memory, NULL);
    memset(b, 0, sizeof *b);
}

/* ------------------------------------------------------------------ */
/* Images                                                              */
/* ------------------------------------------------------------------ */

int yvk_image_create(yvk_context *ctx, const yvk_image_info *info, yvk_image *out, char *err, size_t errlen) {
    memset(out, 0, sizeof *out);
    VkImageCreateInfo ii = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL, info->flags, info->type, info->format,
                            {info->width ? info->width : 1, info->height ? info->height : 1,
                             info->depth ? info->depth : 1},
                            info->mipLevels ? info->mipLevels : 1, info->arrayLayers ? info->arrayLayers : 1,
                            info->samples ? info->samples : VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_OPTIMAL,
                            info->usage, VK_SHARING_MODE_EXCLUSIVE, 0, NULL, VK_IMAGE_LAYOUT_UNDEFINED};
    VkResult r = g_vk.vkCreateImage(ctx->device, &ii, NULL, &out->image);
    if (r != VK_SUCCESS)
        return fail(err, errlen, "vkCreateImage(format %d, %ux%ux%u, usage 0x%x) failed (%d)", info->format,
                    ii.extent.width, ii.extent.height, ii.extent.depth, info->usage, r);
    VkMemoryRequirements mr;
    g_vk.vkGetImageMemoryRequirements(ctx->device, out->image, &mr);
    int32_t type = find_memory(ctx, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (type < 0) type = find_memory(ctx, mr.memoryTypeBits, 0);
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, mr.size, (uint32_t)type};
    r = g_vk.vkAllocateMemory(ctx->device, &ai, NULL, &out->memory);
    if (r != VK_SUCCESS) {
        g_vk.vkDestroyImage(ctx->device, out->image, NULL);
        out->image = VK_NULL_HANDLE;
        return fail(err, errlen, "image memory (%llu bytes) failed (%d)", (unsigned long long)mr.size, r);
    }
    r = g_vk.vkBindImageMemory(ctx->device, out->image, out->memory, 0);
    if (r != VK_SUCCESS) {
        yvk_image_destroy(ctx, out);
        return fail(err, errlen, "vkBindImageMemory failed (%d)", r);
    }
    return 0;
}

void yvk_image_destroy(yvk_context *ctx, yvk_image *img) {
    if (img->image) g_vk.vkDestroyImage(ctx->device, img->image, NULL);
    if (img->memory) g_vk.vkFreeMemory(ctx->device, img->memory, NULL);
    memset(img, 0, sizeof *img);
}

VkImageView yvk_view_create(yvk_context *ctx, const yvk_view_info *info, char *err, size_t errlen) {
    VkImageViewUsageCreateInfo usage = {VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO, NULL, info->usage};
    VkImageViewCreateInfo vi = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, info->usage ? &usage : NULL, 0, info->image,
                                info->viewType, info->format, info->components,
                                {info->aspect, info->baseLevel, info->levelCount ? info->levelCount : 1,
                                 info->baseLayer, info->layerCount ? info->layerCount : 1}};
    VkImageView view = VK_NULL_HANDLE;
    VkResult r = g_vk.vkCreateImageView(ctx->device, &vi, NULL, &view);
    if (r != VK_SUCCESS) {
        fail(err, errlen, "vkCreateImageView(format %d, type %d, aspect 0x%x) failed (%d)", info->format,
             info->viewType, info->aspect, r);
        return VK_NULL_HANDLE;
    }
    return view;
}

static void heap_write(yvk_context *ctx, uint32_t binding, uint32_t index, VkDescriptorType type,
                       VkImageView view, VkSampler sampler) {
    VkDescriptorImageInfo ii = {sampler, view, VK_IMAGE_LAYOUT_GENERAL};
    VkWriteDescriptorSet w = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, ctx->heapSet, binding, index, 1, type, &ii,
                              NULL, NULL};
    g_vk.vkUpdateDescriptorSets(ctx->device, 1, &w, 0, NULL);
}

void yvk_heap_write_sampled(yvk_context *ctx, uint32_t index, VkImageView view) {
    if (index < ctx->heapSampledImages) heap_write(ctx, 0, index, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, view, VK_NULL_HANDLE);
}

void yvk_heap_write_storage(yvk_context *ctx, uint32_t index, VkImageView view) {
    if (index < ctx->heapStorageImages) heap_write(ctx, 1, index, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, view, VK_NULL_HANDLE);
}

void yvk_heap_write_sampler(yvk_context *ctx, uint32_t index, VkSampler sampler) {
    if (index < ctx->heapSamplers) heap_write(ctx, 2, index, VK_DESCRIPTOR_TYPE_SAMPLER, VK_NULL_HANDLE, sampler);
}

/* ------------------------------------------------------------------ */
/* Samplers                                                            */
/* ------------------------------------------------------------------ */

VkSampler yvk_sampler_create(yvk_context *ctx, const yvk_sampler_info *s, char *err, size_t errlen) {
    VkSamplerCreateInfo si = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, NULL, 0, s->magFilter, s->minFilter,
                              s->mipmapMode, s->addressU, s->addressV, s->addressW, s->mipLodBias,
                              s->anisotropyEnable && ctx->features.samplerAnisotropy, s->maxAnisotropy,
                              s->compareEnable, s->compareOp, s->minLod, s->maxLod, s->borderColor,
                              s->unnormalizedCoordinates};
    VkSampler sampler = VK_NULL_HANDLE;
    VkResult r = g_vk.vkCreateSampler(ctx->device, &si, NULL, &sampler);
    if (r != VK_SUCCESS) {
        fail(err, errlen, "vkCreateSampler failed (%d)", r);
        return VK_NULL_HANDLE;
    }
    return sampler;
}

/* ------------------------------------------------------------------ */
/* Pipelines                                                           */
/* ------------------------------------------------------------------ */

typedef struct stage_storage {
    VkSpecializationMapEntry entries[64];
    uint32_t data[64];
    VkSpecializationInfo info;
} stage_storage;

static int make_stage(yvk_context *ctx, const yvk_shader_stage *s, VkShaderStageFlagBits bit,
                      VkPipelineShaderStageCreateInfo *out, stage_storage *st, char *err, size_t errlen) {
    VkShaderModuleCreateInfo mi = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, s->wordCount * 4, s->code};
    VkShaderModule module;
    VkResult r = g_vk.vkCreateShaderModule(ctx->device, &mi, NULL, &module);
    if (r != VK_SUCCESS) return fail(err, errlen, "vkCreateShaderModule failed (%d)", r);
    uint32_t n = s->constantCount > 64 ? 64 : s->constantCount;
    for (uint32_t i = 0; i < n; i++) {
        st->entries[i] = (VkSpecializationMapEntry){s->constants[i].id, i * 4, 4};
        st->data[i] = s->constants[i].value;
    }
    st->info = (VkSpecializationInfo){n, st->entries, n * 4, st->data};
    *out = (VkPipelineShaderStageCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, s->flags, bit,
                                             module, s->entry ? s->entry : "main", n ? &st->info : NULL};
    return 0;
}

VkPipeline yvk_compute_pipeline_create(yvk_context *ctx, const yvk_shader_stage *stage, char *err, size_t errlen) {
    stage_storage st;
    VkComputePipelineCreateInfo ci = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    if (make_stage(ctx, stage, VK_SHADER_STAGE_COMPUTE_BIT, &ci.stage, &st, err, errlen) != 0) return VK_NULL_HANDLE;
    ci.layout = ctx->pipelineLayout;
    VkPipeline p = VK_NULL_HANDLE;
    VkResult r = g_vk.vkCreateComputePipelines(ctx->device, VK_NULL_HANDLE, 1, &ci, NULL, &p);
    g_vk.vkDestroyShaderModule(ctx->device, ci.stage.module, NULL);
    if (r != VK_SUCCESS) {
        fail(err, errlen, "vkCreateComputePipelines failed (%d)", r);
        return VK_NULL_HANDLE;
    }
    return p;
}

VkPipeline yvk_graphics_pipeline_create(yvk_context *ctx, const yvk_graphics_info *g, char *err, size_t errlen) {
    VkPipelineShaderStageCreateInfo stages[2];
    stage_storage st[2];
    uint32_t nstages = 0;
    if (make_stage(ctx, &g->vertex, VK_SHADER_STAGE_VERTEX_BIT, &stages[0], &st[0], err, errlen) != 0)
        return VK_NULL_HANDLE;
    nstages = 1;
    if (g->fragment.code) {
        if (make_stage(ctx, &g->fragment, VK_SHADER_STAGE_FRAGMENT_BIT, &stages[1], &st[1], err, errlen) != 0) {
            g_vk.vkDestroyShaderModule(ctx->device, stages[0].module, NULL);
            return VK_NULL_HANDLE;
        }
        nstages = 2;
    }

    VkVertexInputBindingDescription vb[YVK_MAX_VERTEX_BINDINGS];
    VkVertexInputBindingDivisorDescriptionEXT dv[YVK_MAX_VERTEX_BINDINGS];
    uint32_t ndiv = 0;
    for (uint32_t i = 0; i < g->bindingCount && i < YVK_MAX_VERTEX_BINDINGS; i++) {
        vb[i] = (VkVertexInputBindingDescription){g->bindings[i].binding, g->bindings[i].stride,
                                                  g->bindings[i].inputRate};
        if (g->bindings[i].inputRate == VK_VERTEX_INPUT_RATE_INSTANCE && g->bindings[i].divisor != 1) {
            int ok = g->bindings[i].divisor == 0 ? ctx->features.vertexAttributeInstanceRateZeroDivisor
                                                 : ctx->features.vertexAttributeInstanceRateDivisor;
            if (ok) dv[ndiv++] = (VkVertexInputBindingDivisorDescriptionEXT){g->bindings[i].binding, g->bindings[i].divisor};
        }
    }
    VkPipelineVertexInputDivisorStateCreateInfoEXT divs = {
        VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_DIVISOR_STATE_CREATE_INFO_EXT, NULL, ndiv, dv};
    VkPipelineVertexInputStateCreateInfo vis = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                                                ndiv ? &divs : NULL, 0, g->bindingCount, vb, g->attributeCount,
                                                g->attributes};
    VkPipelineInputAssemblyStateCreateInfo ias = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, NULL, 0,
                                                  g->topology, VK_FALSE};
    VkPipelineViewportStateCreateInfo vps = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, NULL, 0, 1, NULL, 1,
                                             NULL};
    VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    rs.rasterizerDiscardEnable = g->fragment.code ? VK_FALSE : VK_TRUE;
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_CLOCKWISE;
    rs.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    ms.rasterizationSamples = g->samples ? g->samples : VK_SAMPLE_COUNT_1_BIT;
    ms.alphaToCoverageEnable = g->alphaToCoverage;
    VkPipelineDepthStencilStateCreateInfo ds = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    ds.depthCompareOp = VK_COMPARE_OP_ALWAYS;
    ds.minDepthBounds = 0.0f;
    ds.maxDepthBounds = 1.0f;
    VkPipelineColorBlendStateCreateInfo cbs = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, NULL, 0,
                                               VK_FALSE, VK_LOGIC_OP_COPY, g->colorCount, g->blend};
    VkDynamicState dyn[24];
    uint32_t ndyn = 0;
    dyn[ndyn++] = VK_DYNAMIC_STATE_VIEWPORT;
    dyn[ndyn++] = VK_DYNAMIC_STATE_SCISSOR;
    dyn[ndyn++] = VK_DYNAMIC_STATE_CULL_MODE;
    dyn[ndyn++] = VK_DYNAMIC_STATE_FRONT_FACE;
    dyn[ndyn++] = VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY;
    dyn[ndyn++] = VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE;
    dyn[ndyn++] = VK_DYNAMIC_STATE_DEPTH_BIAS;
    dyn[ndyn++] = VK_DYNAMIC_STATE_DEPTH_BIAS_ENABLE;
    dyn[ndyn++] = VK_DYNAMIC_STATE_BLEND_CONSTANTS;
    dyn[ndyn++] = VK_DYNAMIC_STATE_STENCIL_REFERENCE;
    dyn[ndyn++] = VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK;
    dyn[ndyn++] = VK_DYNAMIC_STATE_STENCIL_WRITE_MASK;
    dyn[ndyn++] = VK_DYNAMIC_STATE_STENCIL_TEST_ENABLE;
    dyn[ndyn++] = VK_DYNAMIC_STATE_STENCIL_OP;
    dyn[ndyn++] = VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE;
    dyn[ndyn++] = VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE;
    dyn[ndyn++] = VK_DYNAMIC_STATE_DEPTH_COMPARE_OP;
    if (ctx->features.extendedDynamicState3PolygonMode) dyn[ndyn++] = VK_DYNAMIC_STATE_POLYGON_MODE_EXT;
    if (ctx->features.extendedDynamicState3DepthClamp) dyn[ndyn++] = VK_DYNAMIC_STATE_DEPTH_CLAMP_ENABLE_EXT;
    VkPipelineDynamicStateCreateInfo dys = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, NULL, 0, ndyn, dyn};
    VkPipelineRenderingCreateInfo pri = {VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, NULL, 0, g->colorCount,
                                         g->colorFormats, g->depthFormat, g->stencilFormat};
    VkGraphicsPipelineCreateInfo gpi = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &pri, 0, nstages, stages,
                                        &vis, &ias, NULL, &vps, &rs, &ms, &ds, &cbs, &dys, ctx->pipelineLayout};
    VkPipeline p = VK_NULL_HANDLE;
    VkResult r = g_vk.vkCreateGraphicsPipelines(ctx->device, VK_NULL_HANDLE, 1, &gpi, NULL, &p);
    for (uint32_t i = 0; i < nstages; i++) g_vk.vkDestroyShaderModule(ctx->device, stages[i].module, NULL);
    if (r != VK_SUCCESS) {
        fail(err, errlen, "vkCreateGraphicsPipelines failed (%d)", r);
        return VK_NULL_HANDLE;
    }
    return p;
}

/* ------------------------------------------------------------------ */
/* Commands                                                            */
/* ------------------------------------------------------------------ */

VkCommandBuffer yvk_command_buffer_begin(yvk_context *ctx, char *err, size_t errlen) {
    VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, ctx->commandPool,
                                      VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb = VK_NULL_HANDLE;
    VkResult r = g_vk.vkAllocateCommandBuffers(ctx->device, &ai, &cb);
    if (r != VK_SUCCESS) {
        fail(err, errlen, "vkAllocateCommandBuffers failed (%d)", r);
        return VK_NULL_HANDLE;
    }
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                   VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    r = g_vk.vkBeginCommandBuffer(cb, &bi);
    if (r != VK_SUCCESS) {
        g_vk.vkFreeCommandBuffers(ctx->device, ctx->commandPool, 1, &cb);
        fail(err, errlen, "vkBeginCommandBuffer failed (%d)", r);
        return VK_NULL_HANDLE;
    }
    return cb;
}

int yvk_command_buffer_restart(yvk_context *ctx, VkCommandBuffer cb) {
    (void)ctx;
    if (g_vk.vkResetCommandBuffer(cb, 0) != VK_SUCCESS) return -1;
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                   VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    return g_vk.vkBeginCommandBuffer(cb, &bi) == VK_SUCCESS ? 0 : -1;
}

void yvk_command_buffer_free(yvk_context *ctx, VkCommandBuffer cb) {
    g_vk.vkFreeCommandBuffers(ctx->device, ctx->commandPool, 1, &cb);
}

static void attachment(VkRenderingAttachmentInfo *out, const yvk_attachment *a) {
    *out = (VkRenderingAttachmentInfo){VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, NULL, a->view,
                                       VK_IMAGE_LAYOUT_GENERAL,
                                       a->resolveView ? a->resolveMode : VK_RESOLVE_MODE_NONE,
                                       a->resolveView, VK_IMAGE_LAYOUT_GENERAL, a->load, a->store, a->clear};
}

void yvk_cmd_begin_rendering(VkCommandBuffer cb, const yvk_rendering_info *info) {
    VkRenderingAttachmentInfo color[YVK_MAX_COLOR_ATTACHMENTS], depth, stencil;
    uint32_t n = info->colorCount > YVK_MAX_COLOR_ATTACHMENTS ? YVK_MAX_COLOR_ATTACHMENTS : info->colorCount;
    for (uint32_t i = 0; i < n; i++) attachment(&color[i], &info->color[i]);
    attachment(&depth, &info->depth);
    attachment(&stencil, &info->stencil);
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0,
                          {{(int32_t)info->x, (int32_t)info->y}, {info->width, info->height}},
                          info->layerCount ? info->layerCount : 1, 0, n, color,
                          info->depth.view ? &depth : NULL, info->stencil.view ? &stencil : NULL};
    g_vk.vkCmdBeginRendering(cb, &ri);
}

void yvk_cmd_memory_barrier(VkCommandBuffer cb, VkPipelineStageFlags2 srcStages, VkAccessFlags2 srcAccess,
                            VkPipelineStageFlags2 dstStages, VkAccessFlags2 dstAccess) {
    VkMemoryBarrier2 b = {VK_STRUCTURE_TYPE_MEMORY_BARRIER_2, NULL, srcStages, srcAccess, dstStages, dstAccess};
    VkDependencyInfo di = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO, NULL, 0, 1, &b, 0, NULL, 0, NULL};
    g_vk.vkCmdPipelineBarrier2(cb, &di);
}

void yvk_cmd_image_layout(VkCommandBuffer cb, VkImage image, VkImageAspectFlags aspect, VkImageLayout from,
                          VkImageLayout to) {
    VkImageMemoryBarrier2 b = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, NULL,
                               VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT,
                               VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                               VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT, from, to,
                               VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, image,
                               {aspect, 0, VK_REMAINING_MIP_LEVELS, 0, VK_REMAINING_ARRAY_LAYERS}};
    VkDependencyInfo di = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO, NULL, 0, 0, NULL, 0, NULL, 1, &b};
    g_vk.vkCmdPipelineBarrier2(cb, &di);
}

VkResult yvk_submit(yvk_context *ctx, VkCommandBuffer cb, VkSemaphore signal, uint64_t value,
                    VkSemaphore waitSemaphore, uint64_t waitValue) {
    VkCommandBufferSubmitInfo cbi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, NULL, cb, 0};
    VkSemaphoreSubmitInfo sig = {VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, NULL, signal, value,
                                 VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, 0};
    VkSemaphoreSubmitInfo wait = {VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, NULL, waitSemaphore, waitValue,
                                  VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, 0};
    VkSubmitInfo2 si = {VK_STRUCTURE_TYPE_SUBMIT_INFO_2, NULL, 0, waitSemaphore ? 1u : 0u, &wait,
                        cb ? 1u : 0u, &cbi, signal ? 1u : 0u, &sig};
    return g_vk.vkQueueSubmit2(ctx->queue, 1, &si, VK_NULL_HANDLE);
}

VkSemaphore yvk_timeline_create(yvk_context *ctx, uint64_t initial) {
    VkSemaphoreTypeCreateInfo ti = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, NULL, VK_SEMAPHORE_TYPE_TIMELINE,
                                    initial};
    VkSemaphoreCreateInfo si = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &ti, 0};
    VkSemaphore s = VK_NULL_HANDLE;
    if (g_vk.vkCreateSemaphore(ctx->device, &si, NULL, &s) != VK_SUCCESS) return VK_NULL_HANDLE;
    return s;
}

VkResult yvk_timeline_wait(yvk_context *ctx, VkSemaphore semaphore, uint64_t value, uint64_t timeoutNs) {
    VkSemaphoreWaitInfo wi = {VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, NULL, 0, 1, &semaphore, &value};
    return g_vk.vkWaitSemaphores(ctx->device, &wi, timeoutNs);
}

uint64_t yvk_timeline_value(yvk_context *ctx, VkSemaphore semaphore) {
    uint64_t v = 0;
    g_vk.vkGetSemaphoreCounterValue(ctx->device, semaphore, &v);
    return v;
}

VkResult yvk_timeline_signal(yvk_context *ctx, VkSemaphore semaphore, uint64_t value) {
    VkSemaphoreSignalInfo si = {VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO, NULL, semaphore, value};
    return g_vk.vkSignalSemaphore(ctx->device, &si);
}
