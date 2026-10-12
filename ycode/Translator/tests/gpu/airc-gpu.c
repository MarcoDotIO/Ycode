// airc-gpu.c: runs ycode-airc's SPIR-V on the Thor's Vulkan device with the
// Ycode Metal-on-Vulkan ABI (src/abi.h: push constants with argument-table
// addresses, buffers as device addresses, a bindless heap of sampled and
// storage images and samplers in set 0) and compares the results with the
// outputs of the same shaders on Metal (mtl-oracle.m). Follows the pattern
// of R8's vkrun.c and vkdraw.c.
//
// Build: cc -O2 -o airc-gpu airc-gpu.c -lvulkan -lm
// Usage: airc-gpu TESTS.txt SPV_DIR ORACLE_DIR OUT_DIR [TEST...]
//        airc-gpu --compile VS.spv VS_ENTRY FS.spv FS_ENTRY   (pipeline creation time)
//   SPV_DIR holds <library>.<function>.spv and .json from ycode-airc
//   (fragment functions translated with --link-vertex).
#define _GNU_SOURCE 1
#include <vulkan/vulkan.h>
#include <math.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "gpu-data.h"

// ABI (src/abi.h)
enum { kPushSize = 32, kTableEntries = 192, kTableConstantData = 31, kTableTexture0 = 32, kTableSampler0 = 160,
       kTableConstexprSampler0 = 176, kHeapImages = 4096, kHeapSamplers = 256 };

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
    fprintf(stderr, "%s:%d: %s -> %d\n", __FILE__, __LINE__, #x, r_); exit(1); } } while (0)

static VkInstance inst;
static VkPhysicalDevice phys;
static VkDevice dev;
static VkQueue queue;
static uint32_t qfam;
static VkDescriptorSetLayout heapLayout;
static VkDescriptorPool pool;
static VkDescriptorSet heap;
static VkPipelineLayout layout;
static VkCommandPool cmdPool;
static uint32_t nextImage = 1, nextSampler = 1;

typedef struct { VkBuffer buf; VkDeviceMemory mem; void *ptr; VkDeviceSize size; uint64_t addr; } Buf;
typedef struct { VkImage img; VkDeviceMemory mem; VkImageView view; VkFormat fmt; uint32_t w, h, d, bpp, heap; } Img;

static uint32_t findType(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    fprintf(stderr, "no memory type\n");
    exit(1);
}

static Buf makeBuf(VkDeviceSize size, VkBufferUsageFlags usage) {
    Buf b = {0};
    b.size = size ? size : 16;
    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, b.size,
        usage | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT |
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    CHECK(vkCreateBuffer(dev, &bi, NULL, &b.buf));
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, b.buf, &mr);
    VkMemoryAllocateFlagsInfo fl = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, NULL, VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT, 0};
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &fl, mr.size,
        findType(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
    CHECK(vkAllocateMemory(dev, &ai, NULL, &b.mem));
    CHECK(vkBindBufferMemory(dev, b.buf, b.mem, 0));
    CHECK(vkMapMemory(dev, b.mem, 0, b.size, 0, &b.ptr));
    memset(b.ptr, 0xCD, b.size);
    VkBufferDeviceAddressInfo da = {VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, b.buf};
    b.addr = vkGetBufferDeviceAddress(dev, &da);
    return b;
}

static Buf dataBuf(const void *data, size_t n) {
    Buf b = makeBuf(n, 0);
    if (data) memcpy(b.ptr, data, n);
    return b;
}

static VkCommandBuffer beginCmd(void) {
    VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, cmdPool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &ai, &cb));
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    CHECK(vkBeginCommandBuffer(cb, &bi));
    return cb;
}

static void endCmd(VkCommandBuffer cb) {
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
    CHECK(vkEndCommandBuffer(cb));
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb};
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));
    vkFreeCommandBuffers(dev, cmdPool, 1, &cb);
}

static void writeImageDescriptor(uint32_t index, VkImageView view, int storage) {
    VkDescriptorImageInfo ii = {VK_NULL_HANDLE, view, VK_IMAGE_LAYOUT_GENERAL};
    VkWriteDescriptorSet w = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, heap, storage ? 1u : 0u, index, 1,
        storage ? VK_DESCRIPTOR_TYPE_STORAGE_IMAGE : VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, &ii, NULL, NULL};
    vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
}

// Creates an image (2D or 3D), uploads `data`, and puts it in the heap
// (sampled, and storage when `storage`). Layout GENERAL throughout.
static Img makeImage(VkFormat fmt, uint32_t w, uint32_t h, uint32_t d, uint32_t bpp, const void *data, int storage, int attachment) {
    Img im = {0};
    im.fmt = fmt; im.w = w; im.h = h; im.d = d; im.bpp = bpp;
    VkImageUsageFlags usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (storage) usage |= VK_IMAGE_USAGE_STORAGE_BIT;
    if (attachment) usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    VkImageCreateInfo ci = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL, 0, d > 1 ? VK_IMAGE_TYPE_3D : VK_IMAGE_TYPE_2D, fmt,
        {w, h, d}, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_OPTIMAL, usage, VK_SHARING_MODE_EXCLUSIVE, 0, NULL,
        VK_IMAGE_LAYOUT_UNDEFINED};
    CHECK(vkCreateImage(dev, &ci, NULL, &im.img));
    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(dev, im.img, &mr);
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, mr.size, findType(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
    CHECK(vkAllocateMemory(dev, &ai, NULL, &im.mem));
    CHECK(vkBindImageMemory(dev, im.img, im.mem, 0));
    VkImageViewCreateInfo vi = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, NULL, 0, im.img, d > 1 ? VK_IMAGE_VIEW_TYPE_3D : VK_IMAGE_VIEW_TYPE_2D, fmt,
        {0}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    CHECK(vkCreateImageView(dev, &vi, NULL, &im.view));
    VkCommandBuffer cb = beginCmd();
    VkImageMemoryBarrier ib = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_GENERAL, VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, im.img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &ib);
    Buf staging = {0};
    if (data) {
        staging = dataBuf(data, (size_t)w * h * d * bpp);
        VkBufferImageCopy bc = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {w, h, d}};
        vkCmdCopyBufferToImage(cb, staging.buf, im.img, VK_IMAGE_LAYOUT_GENERAL, 1, &bc);
    } else {
        VkClearColorValue zero = {{0}};
        VkImageSubresourceRange r = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(cb, im.img, VK_IMAGE_LAYOUT_GENERAL, &zero, 1, &r);
    }
    endCmd(cb);
    im.heap = nextImage++;
    writeImageDescriptor(im.heap, im.view, 0);
    if (storage) writeImageDescriptor(im.heap, im.view, 1);
    return im;
}

static void readImage(Img *im, void *out) {
    size_t n = (size_t)im->w * im->h * im->d * im->bpp;
    Buf b = makeBuf(n, 0);
    VkCommandBuffer cb = beginCmd();
    VkBufferImageCopy bc = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {im->w, im->h, im->d}};
    vkCmdCopyImageToBuffer(cb, im->img, VK_IMAGE_LAYOUT_GENERAL, b.buf, 1, &bc);
    endCmd(cb);
    memcpy(out, b.ptr, n);
}

static uint32_t makeSampler(VkFilter filter, VkSamplerAddressMode mode, VkBool32 compare, VkCompareOp op, VkBool32 unnormalized) {
    VkSamplerCreateInfo si = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, NULL, 0, filter, filter, VK_SAMPLER_MIPMAP_MODE_NEAREST,
        mode, mode, mode, 0.0f, VK_FALSE, 1.0f, compare, op, 0.0f, unnormalized ? 0.0f : 1000.0f,
        VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK, unnormalized};
    VkSampler s;
    CHECK(vkCreateSampler(dev, &si, NULL, &s));
    uint32_t index = nextSampler++;
    VkDescriptorImageInfo ii = {s, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED};
    VkWriteDescriptorSet w = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, heap, 2, index, 1, VK_DESCRIPTOR_TYPE_SAMPLER, &ii, NULL, NULL};
    vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
    return index;
}

// ---------------------------------------------------------------------------
// Reflection (a few keys, found by text search)

static char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *p = malloc((size_t)n + 1);
    if (fread(p, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(p); return NULL; }
    fclose(f);
    p[n] = 0;
    if (len) *len = (size_t)n;
    return p;
}

static long jsonNumber(const char *json, const char *key, long dflt) {
    char k[96];
    snprintf(k, sizeof k, "\"%s\": ", key);
    const char *p = strstr(json, k);
    return p ? strtol(p + strlen(k), NULL, 10) : dflt;
}

static size_t b64decode(const char *s, uint8_t *out) {
    static int8_t map[256];
    static int init;
    if (!init) {
        memset(map, -1, sizeof map);
        const char *a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (int i = 0; a[i]; i++) map[(uint8_t)a[i]] = (int8_t)i;
        init = 1;
    }
    size_t n = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (; *s && *s != '"'; s++) {
        if (map[(uint8_t)*s] < 0) continue;
        acc = (acc << 6) | (uint32_t)map[(uint8_t)*s];
        bits += 6;
        if (bits >= 8) { bits -= 8; out[n++] = (uint8_t)(acc >> bits); }
    }
    return n;
}

// Fills the stage's argument table entries that come from the function
// itself: constant data and constexpr samplers.
static void functionEntries(const char *json, uint64_t *table) {
    const char *cd = strstr(json, "\"constant_data\"");
    if (cd) {
        const char *b = strstr(cd, "\"base64\": \"");
        long size = jsonNumber(cd, "size", 0);
        uint8_t *bytes = malloc((size_t)size + 4);
        b64decode(b + 11, bytes);
        Buf buf = dataBuf(bytes, (size_t)size);
        table[kTableConstantData] = buf.addr;
    }
    const char *cs = strstr(json, "\"constexpr_samplers\"");
    const char *end = cs ? strstr(cs, "]") : NULL;
    for (const char *p = cs; p && (p = strstr(p, "\"table_entry\": ")) && p < end; p++) {
        long entry = strtol(p + 15, NULL, 10);
        const char *st = strstr(p, "\"state\": \"");
        uint64_t w = strtoull(st + 10, NULL, 16);
        unsigned addr = w & 7, mag = (w >> 9) & 3, cmp = (w >> 16) & 7, pixel = (w >> 15) & 1;
        static const VkSamplerAddressMode modes[] = {VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT};
        static const VkCompareOp ops[] = {VK_COMPARE_OP_NEVER, VK_COMPARE_OP_LESS, VK_COMPARE_OP_LESS_OR_EQUAL, VK_COMPARE_OP_GREATER,
            VK_COMPARE_OP_GREATER_OR_EQUAL, VK_COMPARE_OP_EQUAL, VK_COMPARE_OP_NOT_EQUAL, VK_COMPARE_OP_ALWAYS};
        table[entry] = makeSampler(mag ? VK_FILTER_LINEAR : VK_FILTER_NEAREST, modes[addr & 3], cmp != 0, ops[cmp], pixel);
    }
}

static VkShaderModule loadModule(const char *path) {
    size_t len;
    char *code = slurp(path, &len);
    if (!code) { fprintf(stderr, "cannot read %s\n", path); exit(1); }
    VkShaderModuleCreateInfo ci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, len, (uint32_t *)code};
    VkShaderModule m;
    CHECK(vkCreateShaderModule(dev, &ci, NULL, &m));
    free(code);
    return m;
}

// ---------------------------------------------------------------------------
// Device

static void initDevice(void) {
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "airc-gpu", 1, "ycode", 1, VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app};
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1;
    VkResult er = vkEnumeratePhysicalDevices(inst, &n, &phys);
    if (er != VK_SUCCESS && er != VK_INCOMPLETE) { fprintf(stderr, "no device\n"); exit(1); }
    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, NULL);
    VkQueueFamilyProperties *qp = calloc(nq, sizeof *qp);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, qp);
    for (qfam = 0; qfam < nq && !((qp[qfam].queueFlags & VK_QUEUE_GRAPHICS_BIT) && (qp[qfam].queueFlags & VK_QUEUE_COMPUTE_BIT)); qfam++) {}
    // Enable every supported feature of these structures (but robust access).
    VkPhysicalDeviceWorkgroupMemoryExplicitLayoutFeaturesKHR wg = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_WORKGROUP_MEMORY_EXPLICIT_LAYOUT_FEATURES_KHR};
    VkPhysicalDeviceShaderAtomicFloatFeaturesEXT af = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT, &wg};
    VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &af};
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &f13};
    VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12};
    VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11};
    vkGetPhysicalDeviceFeatures2(phys, &f2);
    f2.features.robustBufferAccess = VK_FALSE;
    f13.robustImageAccess = VK_FALSE;
    const char *exts[] = {"VK_KHR_workgroup_memory_explicit_layout", "VK_EXT_shader_atomic_float"};
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, qfam, 1, &prio};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, 0, 1, &qci, 0, NULL, 2, exts, NULL};
    CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
    vkGetDeviceQueue(dev, qfam, 0, &queue);
    VkCommandPoolCreateInfo cp = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, qfam};
    CHECK(vkCreateCommandPool(dev, &cp, NULL, &cmdPool));

    // The bindless heap (set 0).
    VkDescriptorSetLayoutBinding b[3] = {
        {0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, kHeapImages, VK_SHADER_STAGE_ALL, NULL},
        {1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, kHeapImages, VK_SHADER_STAGE_ALL, NULL},
        {2, VK_DESCRIPTOR_TYPE_SAMPLER, kHeapSamplers, VK_SHADER_STAGE_ALL, NULL}};
    VkDescriptorBindingFlags bf[3];
    for (int i = 0; i < 3; i++) bf[i] = VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT | VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;
    VkDescriptorSetLayoutBindingFlagsCreateInfo bfi = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO, NULL, 3, bf};
    VkDescriptorSetLayoutCreateInfo li = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, &bfi,
        VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT, 3, b};
    CHECK(vkCreateDescriptorSetLayout(dev, &li, NULL, &heapLayout));
    VkDescriptorPoolSize ps[3] = {{VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, kHeapImages}, {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, kHeapImages},
        {VK_DESCRIPTOR_TYPE_SAMPLER, kHeapSamplers}};
    VkDescriptorPoolCreateInfo pi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT, 1, 3, ps};
    CHECK(vkCreateDescriptorPool(dev, &pi, NULL, &pool));
    VkDescriptorSetAllocateInfo dai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, pool, 1, &heapLayout};
    CHECK(vkAllocateDescriptorSets(dev, &dai, &heap));
    VkPushConstantRange pcr = {VK_SHADER_STAGE_ALL, 0, kPushSize};
    VkPipelineLayoutCreateInfo pli = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &heapLayout, 1, &pcr};
    CHECK(vkCreatePipelineLayout(dev, &pli, NULL, &layout));
    // Heap index 0: the null texture and the null sampler.
    uint32_t zero = 0;
    Img nullImg = makeImage(VK_FORMAT_R8G8B8A8_UNORM, 1, 1, 1, 4, &zero, 1, 0);
    writeImageDescriptor(0, nullImg.view, 0);
    writeImageDescriptor(0, nullImg.view, 1);
    nextImage = 1;
    VkSamplerCreateInfo si = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    si.maxLod = 1000.0f;
    VkSampler s;
    CHECK(vkCreateSampler(dev, &si, NULL, &s));
    VkDescriptorImageInfo ii = {s, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED};
    VkWriteDescriptorSet w = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, heap, 2, 0, 1, VK_DESCRIPTOR_TYPE_SAMPLER, &ii, NULL, NULL};
    vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
}

// ---------------------------------------------------------------------------
// Tests

typedef struct {
    char kind[16], name[64], lib[64], fn[64], fn2[64];
    uint32_t grid[3], tg[3];
    long outBytes;
    char compare[16];
} Test;

static int compare(const Test *t, const uint8_t *got, const uint8_t *want, size_t n) {
    size_t bad = 0, first = (size_t)-1;
    if (!strcmp(t->compare, "exact")) {
        for (size_t i = 0; i + 4 <= n; i += 4)
            if (memcmp(got + i, want + i, 4)) { if (first == (size_t)-1) first = i; bad++; }
    } else if (!strcmp(t->compare, "approx")) {
        for (size_t i = 0; i + 4 <= n; i += 4) {
            float a, b;
            memcpy(&a, got + i, 4);
            memcpy(&b, want + i, 4);
            float tol = 1e-3f * fmaxf(1.0f, fabsf(b));
            if (!(fabsf(a - b) <= tol) && !(isnan(a) && isnan(b))) { if (first == (size_t)-1) first = i; bad++; }
        }
    } else {
        size_t pixels = n / 4;
        for (size_t i = 0; i < pixels; i++)
            for (int c = 0; c < 4; c++)
                if (abs((int)got[i * 4 + c] - (int)want[i * 4 + c]) > 2) { if (first == (size_t)-1) first = i * 4; bad++; break; }
        if (bad * 200 <= pixels) {
            if (bad) printf("  (%zu of %zu pixels differ)\n", bad, pixels);
            bad = 0;
        }
    }
    if (bad) {
        uint32_t g, w;
        memcpy(&g, got + first, 4);
        memcpy(&w, want + first, 4);
        float gf, wf;
        memcpy(&gf, &g, 4);
        memcpy(&wf, &w, 4);
        printf("  %zu mismatches; first at byte %zu (word %zu): got 0x%08x (%g) want 0x%08x (%g)\n", bad, first, first / 4, g, gf, w, wf);
    }
    return bad == 0;
}

static int runCompute(const Test *t, const char *spvDir, uint8_t **outData, size_t *outLen) {
    char path[512], jpath[512];
    snprintf(path, sizeof path, "%s/%s.%s.spv", spvDir, t->lib, t->fn);
    snprintf(jpath, sizeof jpath, "%s/%s.%s.json", spvDir, t->lib, t->fn);
    char *json = slurp(jpath, NULL);
    if (!json) { printf("  no reflection %s\n", jpath); return 0; }
    VkShaderModule m = loadModule(path);
    uint32_t spec[6] = {t->tg[0], t->tg[1], t->tg[2], 0, 0, 0};
    VkSpecializationMapEntry me[6] = {{0, 0, 4}, {1, 4, 4}, {2, 8, 4}, {3, 12, 4}, {100, 16, 4}, {101, 20, 4}};
    uint32_t nspec = 3;
    if (!strcmp(t->name, "t_tg_dynamic")) {
        long st = jsonNumber(json, "static_bytes", 0);
        uint32_t base = (uint32_t)((st + 15) / 16 * 16);
        if (base < 16) base = 16;
        spec[4] = base;
        spec[5] = base + 256;
        spec[3] = base + 256 + 128;
        nspec = 6;
    }
    VkSpecializationInfo si = {nspec, me, nspec * 4, spec};
    VkComputePipelineCreateInfo cpi = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_COMPUTE_BIT, m, t->fn, &si}, layout, VK_NULL_HANDLE, 0};
    VkPipeline pipe;
    CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpi, NULL, &pipe));

    Buf table = makeBuf(kTableEntries * 8, 0);
    uint64_t *tab = table.ptr;
    memset(tab, 0, kTableEntries * 8);
    functionEntries(json, tab);
    Buf out = makeBuf((VkDeviceSize)t->outBytes, 0);
    Buf extra = {0};
    Img tex = {0};
    const char *n = t->name;
    if (!strncmp(n, "add_", 4)) {
        uint32_t count = (uint32_t)(t->outBytes / 4);
        float *a = malloc(count * 4), *b = malloc(count * 4);
        gd_add_inputs(a, b, count);
        tab[0] = dataBuf(a, count * 4).addr;
        tab[1] = dataBuf(b, count * 4).addr;
        tab[2] = out.addr;
        tab[3] = dataBuf(&count, 4).addr;
    } else {
        tab[0] = out.addr;
    }
    if (!strcmp(n, "t_struct")) {
        uint32_t pairs[64 * 8];
        gd_pairs(pairs);
        float scale = 1.5f;
        tab[1] = dataBuf(pairs, sizeof pairs).addr;
        tab[2] = dataBuf(&scale, 4).addr;
    }
    if (!strcmp(n, "t_atomic")) {
        uint32_t z[4] = {0};
        extra = dataBuf(z, 16);
        tab[1] = extra.addr;
    }
    if (!strcmp(n, "t_device_barrier")) {
        uint32_t z[256] = {0};
        tab[1] = dataBuf(z, sizeof z).addr;
    }
    if (!strncmp(n, "t_tex_", 6) && strcmp(n, "t_tex_3d")) {
        float t0[16 * 16 * 4];
        gd_tex0(t0);
        Img i0 = makeImage(VK_FORMAT_R32G32B32A32_SFLOAT, 16, 16, 1, 16, t0, 1, 0);
        tab[kTableTexture0 + 0] = i0.heap;
    }
    if (!strcmp(n, "t_argbuf")) {
        // Argument buffer written by the CPU: texture and sampler handles
        // (heap indices) and a buffer device address (abi.h).
        float t0[16 * 16 * 4];
        gd_tex0(t0);
        Img i0 = makeImage(VK_FORMAT_R32G32B32A32_SFLOAT, 16, 16, 1, 16, t0, 0, 0);
        float data[256];
        gd_argbuf_data(data);
        uint64_t ab[3] = {i0.heap, makeSampler(VK_FILTER_NEAREST, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_FALSE, VK_COMPARE_OP_NEVER, VK_FALSE),
                          dataBuf(data, sizeof data).addr};
        tab[1] = dataBuf(ab, sizeof ab).addr;
    }
    if (!strcmp(n, "t_tex_rw") || !strcmp(n, "t_imageblock_slice")) {
        tex = makeImage(VK_FORMAT_R32G32B32A32_SFLOAT, 16, 16, 1, 16, NULL, 1, 0);
        tab[kTableTexture0 + 1] = tex.heap;
    }
    if (!strcmp(n, "t_tex_sample")) {
        tab[kTableSampler0 + 0] = makeSampler(VK_FILTER_LINEAR, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_FALSE, VK_COMPARE_OP_NEVER, VK_FALSE);
        tab[kTableTexture0 + 5] = 0;  // null texture
    }
    if (!strcmp(n, "t_tex_uint")) {
        uint32_t t2[256];
        gd_tex2(t2);
        tex = makeImage(VK_FORMAT_R32_UINT, 16, 16, 1, 4, t2, 1, 0);
        tab[kTableTexture0 + 2] = tex.heap;
    }
    if (!strcmp(n, "t_tex_3d")) {
        uint8_t t3[256];
        gd_tex3(t3);
        Img i3 = makeImage(VK_FORMAT_R8G8B8A8_UNORM, 4, 4, 4, 4, t3, 0, 0);
        tab[kTableTexture0 + 3] = i3.heap;
    }

    struct { uint64_t table[2]; uint32_t grid[3]; uint32_t pad; } pc = {{table.addr, 0}, {t->grid[0], t->grid[1], t->grid[2]}, 0};
    VkCommandBuffer cb = beginCmd();
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &heap, 0, NULL);
    vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_ALL, 0, sizeof pc, &pc);
    vkCmdDispatch(cb, (t->grid[0] + t->tg[0] - 1) / t->tg[0], (t->grid[1] + t->tg[1] - 1) / t->tg[1], (t->grid[2] + t->tg[2] - 1) / t->tg[2]);
    endCmd(cb);

    size_t len = (size_t)t->outBytes + (extra.buf ? 16 : 0) + (tex.img ? (size_t)tex.w * tex.h * tex.bpp : 0);
    uint8_t *res = malloc(len + 1);
    memcpy(res, out.ptr, (size_t)t->outBytes);
    size_t at = (size_t)t->outBytes;
    if (extra.buf) { memcpy(res + at, extra.ptr, 16); at += 16; }
    if (tex.img) readImage(&tex, res + at);
    *outData = res;
    *outLen = len;
    free(json);
    return 1;
}

static int runRender(const Test *t, const char *spvDir, uint8_t **outData, size_t *outLen) {
    char vpath[512], vjson[512], fpath[512], fjson[512];
    snprintf(vpath, sizeof vpath, "%s/%s.%s.spv", spvDir, t->lib, t->fn);
    snprintf(vjson, sizeof vjson, "%s/%s.%s.json", spvDir, t->lib, t->fn);
    snprintf(fpath, sizeof fpath, "%s/%s.%s.spv", spvDir, t->lib, t->fn2);
    snprintf(fjson, sizeof fjson, "%s/%s.%s.json", spvDir, t->lib, t->fn2);
    char *vj = slurp(vjson, NULL), *fj = slurp(fjson, NULL);
    if (!vj || !fj) { printf("  missing reflection\n"); return 0; }
    uint32_t w = t->grid[0], h = t->grid[1];
    VkShaderModule vm = loadModule(vpath), fm = loadModule(fpath);
    VkPipelineShaderStageCreateInfo st[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, vm, t->fn, NULL},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, fm, t->fn2, NULL}};
    VkVertexInputBindingDescription vb = {0, GD_VERTEX_STRIDE, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription va[2] = {{0, 0, VK_FORMAT_R32G32_SFLOAT, 0}, {1, 0, VK_FORMAT_R16G16B16A16_SFLOAT, 8}};
    VkPipelineVertexInputStateCreateInfo vis = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, NULL, 0, 1, &vb, 2, va};
    VkPipelineInputAssemblyStateCreateInfo ias = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, NULL, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, VK_FALSE};
    // Metal clip space has y up: a negative viewport height.
    VkViewport vp = {0.0f, (float)h, (float)w, -(float)h, 0.0f, 1.0f};
    VkRect2D sc = {{0, 0}, {w, h}};
    VkPipelineViewportStateCreateInfo vps = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, NULL, 0, 1, &vp, 1, &sc};
    VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState cba = {0};
    cba.colorWriteMask = 0xF;
    VkPipelineColorBlendStateCreateInfo cbs = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    cbs.attachmentCount = 1;
    cbs.pAttachments = &cba;
    VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
    VkPipelineRenderingCreateInfo rci = {VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, NULL, 0, 1, &fmt};
    VkGraphicsPipelineCreateInfo gpi = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &rci, 0, 2, st, &vis, &ias, NULL, &vps, &rs, &ms,
        NULL, &cbs, NULL, layout, VK_NULL_HANDLE, 0, VK_NULL_HANDLE, 0};
    VkPipeline pipe;
    CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpi, NULL, &pipe));

    Img target = makeImage(fmt, w, h, 1, 4, NULL, 0, 1);
    uint8_t verts[4 * GD_VERTEX_STRIDE];
    gd_vertices(verts);
    Buf vbuf = makeBuf(sizeof verts, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    memcpy(vbuf.ptr, verts, sizeof verts);
    float xform[4] = {1.0f, 1.0f, 0.0f, 0.0f};
    Buf vt = makeBuf(kTableEntries * 8, 0), ft = makeBuf(kTableEntries * 8, 0);
    memset(vt.ptr, 0, kTableEntries * 8);
    memset(ft.ptr, 0, kTableEntries * 8);
    uint64_t *vtab = vt.ptr, *ftab = ft.ptr;
    functionEntries(vj, vtab);
    functionEntries(fj, ftab);
    vtab[0] = vbuf.addr;
    vtab[1] = dataBuf(xform, sizeof xform).addr;
    uint8_t texel[8 * 8 * 4];
    gd_draw_texture(texel);
    Img tex = makeImage(VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 1, 4, texel, 0, 0);
    ftab[kTableTexture0 + 0] = tex.heap;
    ftab[kTableSampler0 + 0] = makeSampler(VK_FILTER_NEAREST, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_FALSE, VK_COMPARE_OP_NEVER, VK_FALSE);

    struct { uint64_t table[2]; uint32_t grid[3]; uint32_t pad; } pc = {{vt.addr, ft.addr}, {0, 0, 0}, 0};
    VkCommandBuffer cb = beginCmd();
    VkRenderingAttachmentInfo att = {VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, NULL, target.view, VK_IMAGE_LAYOUT_GENERAL};
    att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.clearValue.color.float32[3] = 1.0f;
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, {{0, 0}, {w, h}}, 1, 0, 1, &att, NULL, NULL};
    vkCmdBeginRendering(cb, &ri);
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &heap, 0, NULL);
    vkCmdPushConstants(cb, layout, VK_SHADER_STAGE_ALL, 0, sizeof pc, &pc);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(cb, 0, 1, &vbuf.buf, &off);
    vkCmdDraw(cb, 4, 1, 0, 0);
    vkCmdEndRendering(cb);
    endCmd(cb);
    uint8_t *res = malloc((size_t)w * h * 4);
    readImage(&target, res);
    *outData = res;
    *outLen = (size_t)w * h * 4;
    return 1;
}

// --compile VS.spv VS_ENTRY FS.spv FS_ENTRY: time the creation of a
// graphics pipeline from two modules (driver compile time).
static int compileOnly(char **argv) {
    struct timespec t0, t1;
    VkShaderModule vm = loadModule(argv[0]), fm = loadModule(argv[2]);
    VkPipelineShaderStageCreateInfo st[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, vm, argv[1], NULL},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, fm, argv[3], NULL}};
    VkVertexInputBindingDescription vb = {0, GD_VERTEX_STRIDE, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription va[2] = {{0, 0, VK_FORMAT_R32G32_SFLOAT, 0}, {1, 0, VK_FORMAT_R16G16B16A16_SFLOAT, 8}};
    VkPipelineVertexInputStateCreateInfo vis = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, NULL, 0, 1, &vb, 2, va};
    VkPipelineInputAssemblyStateCreateInfo ias = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, NULL, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, VK_FALSE};
    VkViewport vp = {0, 64, 64, -64, 0, 1};
    VkRect2D sc = {{0, 0}, {64, 64}};
    VkPipelineViewportStateCreateInfo vps = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, NULL, 0, 1, &vp, 1, &sc};
    VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    rs.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState cba[4] = {{0}};
    for (int i = 0; i < 4; i++) cba[i].colorWriteMask = 0xF;
    VkPipelineColorBlendStateCreateInfo cbs = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    cbs.attachmentCount = 4;
    cbs.pAttachments = cba;
    VkFormat fmts[4] = {VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM};
    VkPipelineRenderingCreateInfo rci = {VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, NULL, 0, 4, fmts};
    VkGraphicsPipelineCreateInfo gpi = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &rci, 0, 2, st, &vis, &ias, NULL, &vps, &rs, &ms,
        NULL, &cbs, NULL, layout, VK_NULL_HANDLE, 0, VK_NULL_HANDLE, 0};
    VkPipeline pipe;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpi, NULL, &pipe));
    clock_gettime(CLOCK_MONOTONIC, &t1);
    printf("pipeline created in %.1f ms\n", (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 6 && !strcmp(argv[1], "--compile")) {
        initDevice();
        return compileOnly(argv + 2);
    }
    if (argc < 5) {
        fprintf(stderr, "usage: airc-gpu TESTS.txt SPV_DIR ORACLE_DIR OUT_DIR [TEST...]\n");
        return 2;
    }
    initDevice();
    char *list = slurp(argv[1], NULL);
    if (!list) return 2;
    int pass = 0, failed = 0;
    for (char *line = strtok(list, "\n"); line; line = strtok(NULL, "\n")) {
        if (line[0] == '#' || !line[0]) continue;
        Test t = {0};
        char a[12][64];
        int k = sscanf(line, "%15s %63s %63s %63s %63s %63s %63s %63s %63s %63s %63s %15s", t.kind, t.name, t.lib, a[0], a[1], a[2], a[3], a[4],
                       a[5], a[6], a[7], t.compare);
        if (k < 12) continue;
        int selected = argc == 5;
        for (int i = 5; i < argc; i++) selected |= !strcmp(argv[i], t.name);
        if (!selected) continue;
        uint8_t *got = NULL;
        size_t len = 0;
        int ok;
        if (!strcmp(t.kind, "compute")) {
            strcpy(t.fn, a[0]);
            for (int i = 0; i < 3; i++) { t.grid[i] = (uint32_t)atoi(a[1 + i]); t.tg[i] = (uint32_t)atoi(a[4 + i]); }
            t.outBytes = atol(a[7]);
            ok = runCompute(&t, argv[2], &got, &len);
        } else {
            strcpy(t.fn, a[0]);
            strcpy(t.fn2, a[1]);
            t.grid[0] = (uint32_t)atoi(a[2]);
            t.grid[1] = (uint32_t)atoi(a[3]);
            ok = runRender(&t, argv[2], &got, &len);
        }
        if (ok) {
            char path[512];
            snprintf(path, sizeof path, "%s/%s.bin", argv[4], t.name);
            FILE *f = fopen(path, "wb");
            if (f) { fwrite(got, 1, len, f); fclose(f); }
            snprintf(path, sizeof path, "%s/%s.bin", argv[3], t.name);
            size_t wl = 0;
            char *want = slurp(path, &wl);
            if (!want) { printf("%-18s NO ORACLE\n", t.name); ok = 0; }
            else if (wl != len) { printf("%-18s FAIL size %zu, oracle %zu\n", t.name, len, wl); ok = 0; }
            else {
                ok = compare(&t, got, (uint8_t *)want, len);
                printf("%-18s %s\n", t.name, ok ? "PASS" : "FAIL");
            }
        } else {
            printf("%-18s FAIL (not run)\n", t.name);
        }
        ok ? pass++ : failed++;
        fflush(stdout);
    }
    printf("gpu tests: %d passed, %d failed\n", pass, failed);
    return failed ? 1 : 0;
}
