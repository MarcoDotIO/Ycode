// oob: what a GPU read past an imported host buffer does on this device.
// usage: oob SPV MODE   MODE 0: in-bounds read; 1: read the next host page (PROT_NONE);
//                       2: read the next host page after it was made readable (not imported)
// Build (from ycode/, on a host with Vulkan; stage8-contract.md §15):
//   gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o X scripts/gpu-probes/X.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *spv = malloc(n); if (fread(spv, 1, n, f) != (size_t)n) return 2; fclose(f);
    int mode = atoi(argv[2]);
    char err[512]; yvk_context ctx; yvk_context_options o = {0};
    if (yvk_context_create(&ctx, &o, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    const yvk_dispatch *vk = yvk_fns();
    yvk_shader_stage st = {spv, n / 4, "main", NULL, 0, 0};
    VkPipeline pipe = yvk_compute_pipeline_create(&ctx, &st, err, sizeof err);
    if (!pipe) { fprintf(stderr, "%s\n", err); return 1; }
    size_t page = 4096;
    uint8_t *m = mmap(NULL, 3 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    memset(m, 0, 3 * page);
    ((uint32_t *)m)[0] = 41; ((uint32_t *)(m + page))[0] = 99;
    yvk_buffer a, out;
    if (yvk_buffer_create(&ctx, page, YVK_MEMORY_IMPORT_HOST, m, &a, err, sizeof err)) { fprintf(stderr, "import: %s\n", err); return 1; }
    if (yvk_buffer_create(&ctx, 4096, YVK_MEMORY_HOST, NULL, &out, err, sizeof err)) return 1;
    printf("host A %p  device A 0x%llx  (same VA: %s)\n", (void *)m, (unsigned long long)a.address,
           (uint64_t)(uintptr_t)m == a.address ? "yes" : "no");
    if (mode == 1) mprotect(m + page, page, PROT_NONE);
    uint64_t src = a.address + (mode == 0 ? 0 : page);
    VkCommandBuffer cb = yvk_command_buffer_begin(&ctx, err, sizeof err);
    vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    struct { uint64_t src, dst; } pc = {src, out.address};
    vk->vkCmdPushConstants(cb, ctx.pipelineLayout, VK_SHADER_STAGE_ALL, 0, 16, &pc);
    vk->vkCmdDispatch(cb, 1, 1, 1);
    yvk_cmd_memory_barrier(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT);
    vk->vkEndCommandBuffer(cb);
    VkSemaphore tl = yvk_timeline_create(&ctx, 0);
    VkResult r = yvk_submit(&ctx, cb, tl, 1, NULL, 0);
    VkResult w = yvk_timeline_wait(&ctx, tl, 1, 5000000000ull);
    uint64_t v = 0; VkResult q = yvk_timeline_query(&ctx, tl, &v);
    printf("mode %d: submit %d wait %d query %d value %llu out %u\n", mode, r, w, q, (unsigned long long)v, ((uint32_t *)out.mapped)[0]);
    fflush(stdout);
    _exit(0);
}
