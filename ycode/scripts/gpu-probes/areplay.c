// areplay: replays one captured dispatch of an `astc`-family kernel (hang
// capture of VulkanHangReport.swift, stage8-contract.md §15.2) through
// CVulkan with the captured bytes, and reports whether it finishes.
// usage: areplay K.spv CONST.bin IN.bin IN_OFF TAB.bin TAB_OFF PAR.bin PAR_OFF ZERO.bin ZERO_OFF
//                GRIDX GRIDY TEXW TEXH [ISO [GUARD [SLACKMASK [REPEAT]]]]
//   K.spv: the capture's kernel SPIR-V; CONST.bin: its reflection's constant
//   data (base64 decoded); the four buffers bound as the hang report lists
//   them (b0 input, b1 partition tables, b2 parameters, b3 zero partition
//   tables) with their binding offsets; the grid of the dispatch; the size
//   of the written texture (RGBA8, one level).
//   ISO 1: one thread per workgroup (lane-isolated, as the back end runs
//   `astc`); 0: 32 x 16 workgroups.
//   GUARD 0: exact-size buffers in host-visible device memory;
//         1: each buffer 64 KiB into a larger zeroed allocation;
//         2: each buffer imported from host pages with its last byte at the
//            end of the import (a read past it reaches unmapped memory).
//   SLACKMASK (with GUARD 2): bit i gives buffer i (and bit 4 the constant
//   data) GUARD 1 instead, to find the buffer read out of bounds.
//   REPEAT: dispatches in the command buffer (default 1).
// Environment: POLLUTE=<pollute.spv> runs that kernel (pollute.comp) over
// POLLUTE_GROUPS (default 4096) workgroups of 64 before each dispatch, so
// that the private memory the kernel finds holds what an earlier kernel left
// there (POLLUTE_PATTERN: 0 pseudo-random, otherwise that word), as in a
// boot where other kernels ran before; without it a fresh context's private
// memory is zero.
// Exit 0 when the dispatch finished within 8 s, 1 when it did not.
// Build (from ycode/, on a host with Vulkan; stage8-contract.md §15):
//   gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o X scripts/gpu-probes/X.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static void *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(2); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    void *b = malloc(*n ? *n : 1); if (*n && fread(b, 1, *n, f) != *n) exit(2); fclose(f); return b;
}
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

// Loads `path` and returns the device address of byte `off` of it, placed per `guard`.
static uint64_t place(yvk_context *ctx, const char *path, size_t off, int guard, const char *name) {
    size_t n; uint8_t *d = slurp(path, &n);
    yvk_buffer b; char err[256];
    if (guard == 2) {
        size_t page = 65536, len = (n + page - 1) / page * page;
        uint8_t *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        memset(m, 0, len);
        size_t start = len - n;
        memcpy(m + start, d, n);
        if (yvk_buffer_create(ctx, len, YVK_MEMORY_IMPORT_HOST, m, &b, err, sizeof err)) { fprintf(stderr, "%s: %s\n", name, err); exit(1); }
        printf("%s: %zu bytes, end of an import of %zu at 0x%llx\n", name, n, len, (unsigned long long)b.address);
        return b.address + start + off;
    }
    size_t pad = guard ? 65536 : 0;
    if (yvk_buffer_create(ctx, n + 2 * pad + 16, YVK_MEMORY_HOST, NULL, &b, err, sizeof err)) { fprintf(stderr, "%s: %s\n", name, err); exit(1); }
    memset(b.mapped, 0, n + 2 * pad + 16);
    memcpy((uint8_t *)b.mapped + pad, d, n);
    printf("%s: %zu bytes%s\n", name, n, pad ? ", 64 KiB of zeros around" : "");
    return b.address + pad + off;
}

int main(int argc, char **argv) {
    if (argc < 15) { fprintf(stderr, "usage: see the header\n"); return 64; }
    size_t spvBytes; uint32_t *spv = slurp(argv[1], &spvBytes);
    int gx = atoi(argv[11]), gy = atoi(argv[12]), tw = atoi(argv[13]), th = atoi(argv[14]);
    int iso = argc > 15 ? atoi(argv[15]) : 1;
    int guard = argc > 16 ? atoi(argv[16]) : 0;
    int slack = argc > 17 ? (int)strtol(argv[17], NULL, 0) : 0;
    int repeat = argc > 18 ? atoi(argv[18]) : 1;
    int tgx = iso ? 1 : 32, tgy = iso ? 1 : 16;
    char err[512]; yvk_context ctx; yvk_context_options o = {0};
    if (yvk_context_create(&ctx, &o, err, sizeof err)) { fprintf(stderr, "context: %s\n", err); return 1; }
    const yvk_dispatch *vk = yvk_fns();
    yvk_spec_constant sc[3] = {{0, (uint32_t)tgx}, {1, (uint32_t)tgy}, {2, 1}};
    yvk_shader_stage st = {spv, spvBytes / 4, "astc", sc, 3, VK_PIPELINE_SHADER_STAGE_CREATE_REQUIRE_FULL_SUBGROUPS_BIT};
    if (iso) st.flags = 0;
    VkPipeline pipe = yvk_compute_pipeline_create(&ctx, &st, err, sizeof err);
    if (!pipe) { fprintf(stderr, "pipeline: %s\n", err); return 1; }
    const char *names[5] = {"input", "partitionTables", "parameters", "zeroPartitionTables", "constants"};
    int g[5];
    for (int i = 0; i < 5; i++) g[i] = guard == 2 && (slack >> i & 1) ? 1 : guard;
    uint64_t a0 = place(&ctx, argv[3], strtoul(argv[4], NULL, 0), g[0], names[0]);
    uint64_t a1 = place(&ctx, argv[5], strtoul(argv[6], NULL, 0), g[1], names[1]);
    uint64_t a2 = place(&ctx, argv[7], strtoul(argv[8], NULL, 0), g[2], names[2]);
    uint64_t a3 = place(&ctx, argv[9], strtoul(argv[10], NULL, 0), g[3], names[3]);
    uint64_t ac = place(&ctx, argv[2], 0, g[4], names[4]);
    yvk_buffer btable;
    if (yvk_buffer_create(&ctx, 192 * 8, YVK_MEMORY_HOST, NULL, &btable, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    yvk_image_info ii = {VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, (uint32_t)tw, (uint32_t)th, 1, 1, 1, VK_SAMPLE_COUNT_1_BIT,
                         VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, 0};
    yvk_image img;
    if (yvk_image_create(&ctx, &ii, &img, err, sizeof err)) { fprintf(stderr, "image: %s\n", err); return 1; }
    VkComponentMapping id = {0};
    yvk_view_info vi = {img.image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1, id,
                        VK_IMAGE_USAGE_STORAGE_BIT};
    VkImageView view = yvk_view_create(&ctx, &vi, err, sizeof err);
    if (!view) { fprintf(stderr, "view: %s\n", err); return 1; }
    yvk_heap_write_storage(&ctx, 1, view);
    yvk_heap_write_sampled(&ctx, 1, view);
    uint64_t *table = btable.mapped;
    memset(table, 0, 192 * 8);
    table[0] = a0; table[1] = a1; table[2] = a2; table[3] = a3; table[31] = ac; table[32] = 1;
    VkSemaphore tl = yvk_timeline_create(&ctx, 0);
    VkCommandBuffer cb = yvk_command_buffer_begin(&ctx, err, sizeof err);
    yvk_cmd_image_layout(cb, img.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL);
    VkPipeline polluter = VK_NULL_HANDLE;
    yvk_buffer bres;
    const char *pspv = getenv("POLLUTE");
    uint32_t pattern = getenv("POLLUTE_PATTERN") ? (uint32_t)strtoul(getenv("POLLUTE_PATTERN"), NULL, 0) : 0;
    uint32_t pgroups = getenv("POLLUTE_GROUPS") ? (uint32_t)atoi(getenv("POLLUTE_GROUPS")) : 4096;
    if (pspv) {
        size_t pn; uint32_t *pcode = slurp(pspv, &pn);
        yvk_shader_stage ps = {pcode, pn / 4, "main", NULL, 0, 0};
        polluter = yvk_compute_pipeline_create(&ctx, &ps, err, sizeof err);
        if (!polluter || yvk_buffer_create(&ctx, 4096, YVK_MEMORY_HOST, NULL, &bres, err, sizeof err)) { fprintf(stderr, "polluter: %s\n", err); return 1; }
    }
    vk->vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx.pipelineLayout, 0, 1, &ctx.heapSet, 0, NULL);
    struct { uint64_t a, b; uint32_t gx, gy, gz, pad; } pc = {btable.address, 0, (uint32_t)gx, (uint32_t)gy, 1, 0};
    for (int r = 0; r < repeat; r++) {
        if (polluter) {
            struct { uint64_t result; uint32_t seed, pattern; } ppc = {bres.address, (uint32_t)r * 7919u + 1u, pattern};
            vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, polluter);
            vk->vkCmdPushConstants(cb, ctx.pipelineLayout, VK_SHADER_STAGE_ALL, 0, sizeof ppc, &ppc);
            vk->vkCmdDispatch(cb, pgroups, 1, 1);
            yvk_cmd_memory_barrier(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                   VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT);
        }
        vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
        vk->vkCmdPushConstants(cb, ctx.pipelineLayout, VK_SHADER_STAGE_ALL, 0, 32, &pc);
        vk->vkCmdDispatch(cb, (gx + tgx - 1) / tgx, (gy + tgy - 1) / tgy, 1);
        yvk_cmd_memory_barrier(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                               VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT);
    }
    vk->vkEndCommandBuffer(cb);
    double t0 = now();
    VkResult sr = yvk_submit(&ctx, cb, tl, 1, NULL, 0);
    if (sr) { printf("submit failed %d\n", sr); return 3; }
    VkResult w = yvk_timeline_wait(&ctx, tl, 1, 8000000000ull);
    double dt = now() - t0;
    printf("grid %dx%d iso %d guard %d slack 0x%x: %s (%.3f s)\n", gx, gy, iso, guard, slack,
           w == VK_SUCCESS ? "finished" : "did not finish in 8 s", dt);
    fflush(stdout);
    _exit(w == VK_SUCCESS ? 0 : 1);
}
