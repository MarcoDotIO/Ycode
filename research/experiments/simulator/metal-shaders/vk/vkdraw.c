// vkdraw.c: Ycode R8 Vulkan render test (ours, stage 8a research).
//
// Draws one full-screen triangle into a 64x64 RGBA8 image with a vertex
// and a fragment shader (SPIR-V, entry points given on the command line)
// using the "R8 PoC graphics ABI" of airc:
//   vertex attributes: location 0 = float2 position (binding 0),
//                      location 1 = half4 color (binding 1, R16G16B16A16_SFLOAT)
//   push constants: vertex buffer slots 0..3 at offset 0 (slot 1 = an
//                   Xform { float2 scale, offset } buffer by device address),
//                   fragment buffer slots 0..3 at offset 32
//   set 0 binding 0: sampled images [16], binding 1: samplers [16]
//                   (slot 0 = a 2x2 RGBA8 texture: red, green / blue, white;
//                    nearest filtering)
// The viewport has a negative height so that Metal's clip space (y up)
// lands the right way up. Every pixel is checked against the texel the
// Metal convention selects; the image is also written as a PPM file.
//
// Build: cc -O2 -o vkdraw vkdraw.c -lvulkan
// Usage: vkdraw VS.spv VS_ENTRY FS.spv FS_ENTRY [OUT.ppm]
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
    fprintf(stderr, "%s:%d: %s -> %d\n", __FILE__, __LINE__, #x, r_); exit(1); } } while (0)
#define W 64
#define H 64

static VkPhysicalDevice phys;
static VkDevice dev;

static uint32_t find_type(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    fprintf(stderr, "no memory type\n");
    exit(1);
}

typedef struct { VkBuffer b; VkDeviceMemory m; void *p; uint64_t addr; } Buf;

static Buf buffer(VkDeviceSize size, VkBufferUsageFlags usage) {
    Buf r;
    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, size,
        usage | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT, VK_SHARING_MODE_EXCLUSIVE};
    CHECK(vkCreateBuffer(dev, &bi, NULL, &r.b));
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, r.b, &mr);
    VkMemoryAllocateFlagsInfo fl = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, NULL, VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT};
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &fl, mr.size,
        find_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
    CHECK(vkAllocateMemory(dev, &ai, NULL, &r.m));
    CHECK(vkBindBufferMemory(dev, r.b, r.m, 0));
    CHECK(vkMapMemory(dev, r.m, 0, size, 0, &r.p));
    VkBufferDeviceAddressInfo da = {VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, r.b};
    r.addr = vkGetBufferDeviceAddress(dev, &da);
    return r;
}

static VkImage image(uint32_t w, uint32_t h, VkImageUsageFlags usage, VkDeviceMemory *mem) {
    VkImageCreateInfo ii = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL, 0, VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM,
        {w, h, 1}, 1, 1, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_OPTIMAL, usage, VK_SHARING_MODE_EXCLUSIVE, 0, NULL,
        VK_IMAGE_LAYOUT_UNDEFINED};
    VkImage img;
    CHECK(vkCreateImage(dev, &ii, NULL, &img));
    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(dev, img, &mr);
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, mr.size,
        find_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
    CHECK(vkAllocateMemory(dev, &ai, NULL, mem));
    CHECK(vkBindImageMemory(dev, img, *mem, 0));
    return img;
}

static void barrier(VkCommandBuffer cb, VkImage img, VkImageLayout from, VkImageLayout to,
                    VkPipelineStageFlags2 s0, VkAccessFlags2 a0, VkPipelineStageFlags2 s1, VkAccessFlags2 a1) {
    VkImageMemoryBarrier2 b = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, NULL, s0, a0, s1, a1, from, to,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkDependencyInfo di = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO, NULL, 0, 0, NULL, 0, NULL, 1, &b};
    vkCmdPipelineBarrier2(cb, &di);
}

static VkShaderModule module(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *code = malloc((size_t)len);
    if (fread(code, 1, (size_t)len, f) != (size_t)len) { perror("read"); exit(1); }
    fclose(f);
    VkShaderModuleCreateInfo ci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, (size_t)len, code};
    VkShaderModule m;
    CHECK(vkCreateShaderModule(dev, &ci, NULL, &m));
    return m;
}

static uint16_t half_one(void) { return 0x3C00; }

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: vkdraw VS.spv VS_ENTRY FS.spv FS_ENTRY [OUT.ppm]\n"); return 2; }
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vkdraw", 1, "ycode-r8", 1, VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app};
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t nd = 1;
    VkResult er = vkEnumeratePhysicalDevices(inst, &nd, &phys);
    if (er != VK_SUCCESS && er != VK_INCOMPLETE) return 1;
    uint32_t qfam = 0, nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, NULL);
    VkQueueFamilyProperties qp[16];
    if (nq > 16) nq = 16;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, qp);
    while (qfam < nq && !(qp[qfam].queueFlags & VK_QUEUE_GRAPHICS_BIT)) qfam++;
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, qfam, 1, &prio};
    VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    f13.dynamicRendering = VK_TRUE; f13.synchronization2 = VK_TRUE; f13.maintenance4 = VK_TRUE;
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &f13};
    f12.bufferDeviceAddress = VK_TRUE; f12.shaderFloat16 = VK_TRUE; f12.shaderInt8 = VK_TRUE;
    VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &f12};
    VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &f11};
    f2.features.shaderInt64 = VK_TRUE; f2.features.shaderInt16 = VK_TRUE;
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, 0, 1, &qci};
    CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
    VkQueue queue;
    vkGetDeviceQueue(dev, qfam, 0, &queue);

    // Resources.
    VkDeviceMemory cmem, tmem;
    VkImage color = image(W, H, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &cmem);
    VkImage tex = image(2, 2, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, &tmem);
    VkImageViewCreateInfo vi = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, NULL, 0, color, VK_IMAGE_VIEW_TYPE_2D,
        VK_FORMAT_R8G8B8A8_UNORM, {0}, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkImageView cview, tview;
    CHECK(vkCreateImageView(dev, &vi, NULL, &cview));
    vi.image = tex;
    CHECK(vkCreateImageView(dev, &vi, NULL, &tview));
    VkSamplerCreateInfo sci = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, NULL, 0, VK_FILTER_NEAREST, VK_FILTER_NEAREST,
        VK_SAMPLER_MIPMAP_MODE_NEAREST, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE};
    VkSampler smp;
    CHECK(vkCreateSampler(dev, &sci, NULL, &smp));

    static const uint8_t texels[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
    Buf staging = buffer(16, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    memcpy(staging.p, texels, 16);
    Buf pos = buffer(3 * 8, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    float verts[6] = {-1, -1, 3, -1, -1, 3};
    memcpy(pos.p, verts, sizeof verts);
    Buf col = buffer(3 * 8, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    for (int i = 0; i < 12; i++) ((uint16_t *)col.p)[i] = half_one();
    Buf xform = buffer(16, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    float xf[4] = {1, 1, 0, 0};
    memcpy(xform.p, xf, sizeof xf);
    Buf readback = buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT);

    // Descriptors: 16 sampled images and 16 samplers (all slots filled).
    VkDescriptorSetLayoutBinding binds[2] = {
        {0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 16, VK_SHADER_STAGE_FRAGMENT_BIT, NULL},
        {1, VK_DESCRIPTOR_TYPE_SAMPLER, 16, VK_SHADER_STAGE_FRAGMENT_BIT, NULL}};
    VkDescriptorSetLayoutCreateInfo dli = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 2, binds};
    VkDescriptorSetLayout dsl;
    CHECK(vkCreateDescriptorSetLayout(dev, &dli, NULL, &dsl));
    VkDescriptorPoolSize ps[2] = {{VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 16}, {VK_DESCRIPTOR_TYPE_SAMPLER, 16}};
    VkDescriptorPoolCreateInfo dpi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 2, ps};
    VkDescriptorPool pool;
    CHECK(vkCreateDescriptorPool(dev, &dpi, NULL, &pool));
    VkDescriptorSetAllocateInfo dai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, pool, 1, &dsl};
    VkDescriptorSet set;
    CHECK(vkAllocateDescriptorSets(dev, &dai, &set));
    VkDescriptorImageInfo imgs[16], smps[16];
    for (int i = 0; i < 16; i++) {
        imgs[i] = (VkDescriptorImageInfo){VK_NULL_HANDLE, tview, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
        smps[i] = (VkDescriptorImageInfo){smp, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_UNDEFINED};
    }
    VkWriteDescriptorSet wr[2] = {
        {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 0, 0, 16, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, imgs},
        {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 1, 0, 16, VK_DESCRIPTOR_TYPE_SAMPLER, smps}};
    vkUpdateDescriptorSets(dev, 2, wr, 0, NULL);

    // Pipeline.
    VkPushConstantRange pcr = {VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, 64};
    VkPipelineLayoutCreateInfo pli = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &dsl, 1, &pcr};
    VkPipelineLayout pl;
    CHECK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));
    VkPipelineShaderStageCreateInfo st[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, module(argv[1]), argv[2]},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, module(argv[3]), argv[4]}};
    VkVertexInputBindingDescription vb[2] = {{0, 8, VK_VERTEX_INPUT_RATE_VERTEX}, {1, 8, VK_VERTEX_INPUT_RATE_VERTEX}};
    VkVertexInputAttributeDescription va[2] = {{0, 0, VK_FORMAT_R32G32_SFLOAT, 0}, {1, 1, VK_FORMAT_R16G16B16A16_SFLOAT, 0}};
    VkPipelineVertexInputStateCreateInfo vis = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, NULL, 0, 2, vb, 2, va};
    VkPipelineInputAssemblyStateCreateInfo ias = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, NULL, 0,
        VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    VkViewport vp = {0, H, W, -(float)H, 0, 1};  // Metal clip space: y up
    VkRect2D sc = {{0, 0}, {W, H}};
    VkPipelineViewportStateCreateInfo vps = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, NULL, 0, 1, &vp, 1, &sc};
    VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    rs.cullMode = VK_CULL_MODE_NONE; rs.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState cba = {0};
    cba.colorWriteMask = 0xF;
    VkPipelineColorBlendStateCreateInfo cbs = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, NULL, 0, VK_FALSE,
        VK_LOGIC_OP_COPY, 1, &cba};
    VkFormat cf = VK_FORMAT_R8G8B8A8_UNORM;
    VkPipelineRenderingCreateInfo pri = {VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, NULL, 0, 1, &cf};
    VkGraphicsPipelineCreateInfo gpi = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &pri, 0, 2, st, &vis, &ias, NULL,
        &vps, &rs, &ms, NULL, &cbs, NULL, pl};
    VkPipeline pipe;
    CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpi, NULL, &pipe));

    // Commands.
    VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, qfam};
    VkCommandPool cpool;
    CHECK(vkCreateCommandPool(dev, &cpci, NULL, &cpool));
    VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, cpool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &cbai, &cb));
    VkCommandBufferBeginInfo bbi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    CHECK(vkBeginCommandBuffer(cb, &bbi));
    barrier(cb, tex, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_PIPELINE_STAGE_2_NONE, 0,
            VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT);
    VkBufferImageCopy up = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {2, 2, 1}};
    vkCmdCopyBufferToImage(cb, staging.b, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &up);
    barrier(cb, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT, VK_ACCESS_2_SHADER_SAMPLED_READ_BIT);
    barrier(cb, color, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_PIPELINE_STAGE_2_NONE, 0,
            VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
    VkRenderingAttachmentInfo ca = {VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, NULL, cview,
        VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, 0, VK_NULL_HANDLE, 0, VK_ATTACHMENT_LOAD_OP_CLEAR,
        VK_ATTACHMENT_STORE_OP_STORE, {.color = {{0, 0, 0, 0}}}};
    VkRenderingInfo ri = {VK_STRUCTURE_TYPE_RENDERING_INFO, NULL, 0, {{0, 0}, {W, H}}, 1, 0, 1, &ca};
    vkCmdBeginRendering(cb, &ri);
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pl, 0, 1, &set, 0, NULL);
    uint64_t pc[8] = {0, xform.addr, 0, 0, 0, 0, 0, 0};
    vkCmdPushConstants(cb, pl, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof pc, pc);
    VkBuffer vbs[2] = {pos.b, col.b};
    VkDeviceSize offs[2] = {0, 0};
    vkCmdBindVertexBuffers(cb, 0, 2, vbs, offs);
    vkCmdDraw(cb, 3, 1, 0, 0);
    vkCmdEndRendering(cb);
    barrier(cb, color, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT);
    VkBufferImageCopy down = {0, 0, 0, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {W, H, 1}};
    vkCmdCopyImageToBuffer(cb, color, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.b, 1, &down);
    CHECK(vkEndCommandBuffer(cb));
    VkSubmitInfo sub = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb};
    CHECK(vkQueueSubmit(queue, 1, &sub, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));

    // Check: Metal convention puts texel row 0 (red, green) at the top.
    const uint8_t *px = readback.p;
    unsigned bad = 0;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            const uint8_t *want = texels + 4 * ((y < H / 2 ? 0 : 2) + (x < W / 2 ? 0 : 1));
            if (memcmp(px + 4 * (y * W + x), want, 4) != 0) {
                if (bad < 4) fprintf(stderr, "pixel %d,%d = %u %u %u %u, want %u %u %u %u\n", x, y,
                    px[4 * (y * W + x)], px[4 * (y * W + x) + 1], px[4 * (y * W + x) + 2], px[4 * (y * W + x) + 3],
                    want[0], want[1], want[2], want[3]);
                bad++;
            }
        }
    if (argc > 5) {
        FILE *o = fopen(argv[5], "wb");
        fprintf(o, "P6\n%d %d\n255\n", W, H);
        for (int i = 0; i < W * H; i++) fwrite(px + 4 * i, 1, 3, o);
        fclose(o);
    }
    printf("vkdraw: %s/%s + %s/%s -> %s (%u of %d pixels wrong)\n", argv[1], argv[2], argv[3], argv[4],
           bad ? "FAIL" : "PASS", bad, W * H);
    return bad ? 1 : 0;
}
