// pinprobe: does the GPU keep reading host memory imported with
// VK_EXT_external_memory_host when the host kernel moves or drops the
// pages under the import while a dispatch reads them (stage8-contract.md §15.9)?
// usage: pinprobe SPV MODE [MIB] [ROUNDS]
//   MODE 0: nothing; 1: madvise(MADV_COLLAPSE) on the range (the host
//   kernel copies the pages into huge pages and remaps them: page
//   migration, as khugepaged and compaction do with THP "always");
//   2: madvise(MADV_DONTNEED); 3: mmap(MAP_FIXED) of new anonymous memory
//   over the range; 4: write every page from the CPU (a control).
// The operation runs about 0.2 s after the submission; the dispatch reads
// the range ROUNDS times (several seconds). Prints whether the dispatch
// finished within 20 s and what the operation returned.
// Build (from ycode/, on a host with Vulkan; stage8-contract.md §15):
//   gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o X scripts/gpu-probes/X.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#ifndef MADV_COLLAPSE
#define MADV_COLLAPSE 25
#endif
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: pinprobe SPV MODE [MIB] [ROUNDS]\n"); return 64; }
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *spv = malloc(n); if (fread(spv, 1, n, f) != (size_t)n) return 2; fclose(f);
    int mode = atoi(argv[2]);
    size_t len = (size_t)(argc > 3 ? atoi(argv[3]) : 8) << 20;
    uint32_t rounds = argc > 4 ? (uint32_t)atoi(argv[4]) : 400;
    char err[512]; yvk_context ctx; yvk_context_options o = {0};
    if (yvk_context_create(&ctx, &o, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    const yvk_dispatch *vk = yvk_fns();
    yvk_shader_stage st = {spv, n / 4, "main", NULL, 0, 0};
    VkPipeline pipe = yvk_compute_pipeline_create(&ctx, &st, err, sizeof err);
    if (!pipe) { fprintf(stderr, "%s\n", err); return 1; }
    // A 2 MiB-aligned range of small pages (no huge page yet).
    uint8_t *raw = mmap(NULL, len + (2 << 20), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    uint8_t *m = (uint8_t *)(((uintptr_t)raw + (2 << 20) - 1) & ~(uintptr_t)((2 << 20) - 1));
    madvise(m, len, MADV_NOHUGEPAGE);
    for (size_t i = 0; i < len; i += 4) *(uint32_t *)(m + i) = 1;
    madvise(m, len, MADV_HUGEPAGE);
    yvk_buffer a, out;
    if (yvk_buffer_create(&ctx, len, YVK_MEMORY_IMPORT_HOST, m, &a, err, sizeof err)) { fprintf(stderr, "import: %s\n", err); return 1; }
    if (yvk_buffer_create(&ctx, 4096, YVK_MEMORY_HOST, NULL, &out, err, sizeof err)) return 1;
    memset(out.mapped, 0, 16);
    VkCommandBuffer cb = yvk_command_buffer_begin(&ctx, err, sizeof err);
    vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    struct { uint64_t src, dst; uint32_t words, rounds; } pc = {a.address, out.address, (uint32_t)(len / 4), rounds};
    vk->vkCmdPushConstants(cb, ctx.pipelineLayout, VK_SHADER_STAGE_ALL, 0, sizeof pc, &pc);
    vk->vkCmdDispatch(cb, 64, 1, 1);
    yvk_cmd_memory_barrier(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT);
    vk->vkEndCommandBuffer(cb);
    VkSemaphore tl = yvk_timeline_create(&ctx, 0);
    VkResult r = yvk_submit(&ctx, cb, tl, 1, NULL, 0);
    struct timespec ts = {0, 200000000};
    nanosleep(&ts, NULL);
    volatile uint32_t *prog = (volatile uint32_t *)out.mapped;
    uint32_t before = prog[1];
    int rc = 0, e = 0;
    switch (mode) {
    case 1: rc = madvise(m, len, MADV_COLLAPSE); e = errno; break;
    case 2: rc = madvise(m, len, MADV_DONTNEED); e = errno; break;
    case 3: rc = mmap(m, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == m ? 0 : -1; e = errno; break;
    case 4: for (size_t i = 0; i < len; i += 4096) m[i] = 1; break;
    }
    VkResult w = yvk_timeline_wait(&ctx, tl, 1, 20000000000ull);
    printf("mode %d: operation %d (%s) at round %u; submit %d, %s; rounds done %u of %u, sum %u\n", mode, rc, rc ? strerror(e) : "ok",
           before, r, w == VK_SUCCESS ? "finished" : "did not finish in 20 s", prog[1], rounds, prog[0]);
    fflush(stdout);
    _exit(w == VK_SUCCESS ? 0 : 1);
}
