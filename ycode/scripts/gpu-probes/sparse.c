// sparse: can imported host memory be bound into a sparse residency buffer,
// and do reads of its unbound parts return zero (no GPU stall)?
// usage: sparse SPV MODE   MODE 0: read inside the bound page; 1: read the unbound page after it; 2: 4 bytes before it
// Build (from ycode/, on a host with Vulkan; stage8-contract.md §15):
//   gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o X scripts/gpu-probes/X.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#define L(n) PFN_##n n = (PFN_##n)vk->vkGetDeviceProcAddr(ctx.device, #n)
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *spv = malloc(n); if (fread(spv, 1, n, f) != (size_t)n) return 2; fclose(f);
    int mode = atoi(argv[2]);
    char err[512]; yvk_context ctx; yvk_context_options o = {0};
    if (yvk_context_create(&ctx, &o, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    const yvk_dispatch *vk = yvk_fns();
    L(vkCreateBuffer); L(vkGetBufferMemoryRequirements); L(vkQueueBindSparse); L(vkGetBufferDeviceAddress);
    L(vkAllocateMemory); L(vkGetMemoryHostPointerPropertiesEXT); L(vkQueueWaitIdle);
    yvk_shader_stage st = {spv, n / 4, "main", NULL, 0, 0};
    VkPipeline pipe = yvk_compute_pipeline_create(&ctx, &st, err, sizeof err);
    VkExternalMemoryBufferCreateInfo ext = {VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO, NULL,
                                            VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT};
    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, argc > 3 ? NULL : &ext,
                             VK_BUFFER_CREATE_SPARSE_BINDING_BIT | VK_BUFFER_CREATE_SPARSE_RESIDENCY_BIT, 1ull << 30,
                             VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                             VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    VkBuffer sb; VkResult r = vkCreateBuffer(ctx.device, &bi, NULL, &sb);
    printf("create sparse buffer: %d\n", r); if (r) return 1;
    VkMemoryRequirements req; vkGetBufferMemoryRequirements(ctx.device, sb, &req);
    printf("sparse requirements: size %llu alignment %llu types 0x%x\n", (unsigned long long)req.size, (unsigned long long)req.alignment, req.memoryTypeBits);
    size_t gran = req.alignment;
    uint8_t *m = mmap(NULL, gran * 3, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    uint8_t *page = (uint8_t *)(((uintptr_t)m + gran - 1) & ~(uintptr_t)(gran - 1));
    memset(page, 0, gran); ((uint32_t *)page)[0] = 41;
    VkMemoryHostPointerPropertiesEXT hp = {VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
    r = vkGetMemoryHostPointerPropertiesEXT(ctx.device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, page, &hp);
    printf("host pointer types 0x%x (%d); common with sparse 0x%x\n", hp.memoryTypeBits, r, hp.memoryTypeBits & req.memoryTypeBits);
    uint32_t type = __builtin_ctz(hp.memoryTypeBits & req.memoryTypeBits ? hp.memoryTypeBits & req.memoryTypeBits : hp.memoryTypeBits);
    VkImportMemoryHostPointerInfoEXT imp = {VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT, NULL,
                                            VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, page};
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &imp, gran, type};
    VkDeviceMemory mem; r = vkAllocateMemory(ctx.device, &ai, NULL, &mem);
    printf("import %zu bytes: %d\n", gran, r); if (r) return 1;
    VkSparseMemoryBind b = {1ull << 20, gran, mem, 0, 0};
    VkSparseBufferMemoryBindInfo bb = {sb, 1, &b};
    VkBindSparseInfo bs = {VK_STRUCTURE_TYPE_BIND_SPARSE_INFO, NULL, 0, NULL, 1, &bb, 0, NULL, 0, NULL, 0, NULL};
    r = vkQueueBindSparse(ctx.queue, 1, &bs, VK_NULL_HANDLE);
    printf("bind sparse: %d\n", r); vkQueueWaitIdle(ctx.queue);
    VkBufferDeviceAddressInfo dai = {VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, sb};
    uint64_t base = vkGetBufferDeviceAddress(ctx.device, &dai);
    yvk_buffer out; yvk_buffer_create(&ctx, 4096, YVK_MEMORY_HOST, NULL, &out, err, sizeof err);
    ((uint32_t *)out.mapped)[0] = 7777;
    uint64_t src = base + (1ull << 20) + (mode == 0 ? 0 : mode == 1 ? gran : (uint64_t)-4);
    VkCommandBuffer cb = yvk_command_buffer_begin(&ctx, err, sizeof err);
    vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    struct { uint64_t src, dst; } pc = {src, out.address};
    vk->vkCmdPushConstants(cb, ctx.pipelineLayout, VK_SHADER_STAGE_ALL, 0, 16, &pc);
    vk->vkCmdDispatch(cb, 1, 1, 1);
    yvk_cmd_memory_barrier(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT);
    vk->vkEndCommandBuffer(cb);
    VkSemaphore tl = yvk_timeline_create(&ctx, 0);
    r = yvk_submit(&ctx, cb, tl, 1, NULL, 0);
    VkResult w = yvk_timeline_wait(&ctx, tl, 1, 5000000000ull);
    printf("mode %d: submit %d wait %d out %u (1 = read zero, 42 = read the page)\n", mode, r, w, ((uint32_t *)out.mapped)[0]);
    fflush(stdout);
    _exit(0);
}
