// kprobe: runs a translated `astc`-family kernel (ycode-airc SPIR-V +
// constant data) through CVulkan on random inputs, like
// KernelHangProbeTests, without a Swift build.
// usage: kprobe K.spv CONST.bin ROUNDS TGX TGY GRID SEED [FULLSUBGROUPS]
// Build (from ycode/, on a host with Vulkan; stage8-contract.md §15):
//   gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o X scripts/gpu-probes/X.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t s_state;
static uint64_t rnd(void) {
    s_state += 0x9E3779B97F4A7C15ull;
    uint64_t z = s_state;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(2); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    void *b = malloc(*n); if (fread(b, 1, *n, f) != *n) exit(2); fclose(f); return b;
}

int main(int argc, char **argv) {
    if (argc < 8) { fprintf(stderr, "usage: kprobe K.spv CONST.bin ROUNDS TGX TGY GRID SEED [FULLSUBGROUPS]\n"); return 64; }
    size_t spvBytes, constBytes;
    uint32_t *spv = slurp(argv[1], &spvBytes);
    uint8_t *cdata = slurp(argv[2], &constBytes);
    int rounds = atoi(argv[3]), tgx = atoi(argv[4]), tgy = atoi(argv[5]), grid = atoi(argv[6]);
    s_state = strtoull(argv[7], NULL, 10);
    int full = argc > 8 ? atoi(argv[8]) : 1;
    char err[512];
    yvk_context ctx; yvk_context_options o = {0};
    if (yvk_context_create(&ctx, &o, err, sizeof err)) { fprintf(stderr, "context: %s\n", err); return 1; }
    const yvk_dispatch *vk = yvk_fns();
    yvk_spec_constant sc[3] = {{0, (uint32_t)tgx}, {1, (uint32_t)tgy}, {2, 1}};
    yvk_shader_stage st = {spv, spvBytes / 4, "astc", sc, 3,
                           full ? VK_PIPELINE_SHADER_STAGE_CREATE_REQUIRE_FULL_SUBGROUPS_BIT : 0};
    VkPipeline pipe = yvk_compute_pipeline_create(&ctx, &st, err, sizeof err);
    if (!pipe) { fprintf(stderr, "pipeline: %s\n", err); return 1; }
    size_t blockBytes = (size_t)grid * grid * 16, tableBytes = 1 << 20;
    yvk_buffer bin, btab, bzero, bpar, bconst, btable;
    if (yvk_buffer_create(&ctx, blockBytes, YVK_MEMORY_HOST, NULL, &bin, err, sizeof err) ||
        yvk_buffer_create(&ctx, tableBytes, YVK_MEMORY_HOST, NULL, &btab, err, sizeof err) ||
        yvk_buffer_create(&ctx, tableBytes, YVK_MEMORY_HOST, NULL, &bzero, err, sizeof err) ||
        yvk_buffer_create(&ctx, 4096, YVK_MEMORY_HOST, NULL, &bpar, err, sizeof err) ||
        yvk_buffer_create(&ctx, constBytes < 16 ? 16 : constBytes, YVK_MEMORY_HOST, NULL, &bconst, err, sizeof err) ||
        yvk_buffer_create(&ctx, 192 * 8, YVK_MEMORY_HOST, NULL, &btable, err, sizeof err)) {
        fprintf(stderr, "buffer: %s\n", err); return 1;
    }
    memcpy(bconst.mapped, cdata, constBytes);
    int side = grid * 12;
    yvk_image_info ii = {VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, (uint32_t)side, (uint32_t)side, 1, 1, 1, VK_SAMPLE_COUNT_1_BIT,
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
    table[0] = bin.address; table[1] = btab.address; table[2] = bpar.address; table[3] = bzero.address;
    table[31] = bconst.address; table[32] = 1;
    VkSemaphore tl = yvk_timeline_create(&ctx, 0);
    uint32_t dims[6] = {4, 5, 6, 8, 10, 12};
    double slowest = 0;
    int first = 1;
    for (int r = 0; r < rounds; r++) {
        uint8_t tabMask = r % 3 == 2 ? 0xFF : 0x03;
        uint8_t *tab = btab.mapped, *zero = bzero.mapped;
        for (size_t i = 0; i < tableBytes; i++) tab[i] = (uint8_t)rnd() & tabMask;
        for (size_t i = 0; i < tableBytes; i++) zero[i] = r % 4 == 3 ? ((uint8_t)rnd() & 3) : 0;
        uint64_t *in = bin.mapped;
        for (size_t i = 0; i < blockBytes / 8; i++) in[i] = rnd();
        uint32_t par[16];
        for (int i = 0; i < 14; i++) par[i] = r % 5 == 4 ? (uint32_t)rnd() : 0;
        par[14] = par[15] = 0;
        uint32_t bw = dims[rnd() % 6], bh = dims[rnd() % 6];
        par[2] = grid * 16; par[9] = 0; par[10] = 0; par[11] = rnd() % 3; par[12] = bw; par[13] = bh;
        memcpy(bpar.mapped, par, sizeof par);
        VkCommandBuffer cb = yvk_command_buffer_begin(&ctx, err, sizeof err);
        if (first) { yvk_cmd_image_layout(cb, img.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL); first = 0; }
        vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
        vk->vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx.pipelineLayout, 0, 1, &ctx.heapSet, 0, NULL);
        struct { uint64_t a, b; uint32_t gx, gy, gz, pad; } pc = {btable.address, 0, (uint32_t)grid, (uint32_t)grid, 1, 0};
        vk->vkCmdPushConstants(cb, ctx.pipelineLayout, VK_SHADER_STAGE_ALL, 0, 32, &pc);
        vk->vkCmdDispatch(cb, (grid + tgx - 1) / tgx, (grid + tgy - 1) / tgy, 1);
        yvk_cmd_memory_barrier(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_HOST_BIT,
                               VK_ACCESS_2_HOST_READ_BIT);
        vk->vkEndCommandBuffer(cb);
        double t0 = now();
        VkResult sr = yvk_submit(&ctx, cb, tl, (uint64_t)r + 1, NULL, 0);
        if (sr) { printf("submit failed %d\n", sr); return 3; }
        VkResult w = yvk_timeline_wait(&ctx, tl, (uint64_t)r + 1, 8000000000ull);
        double dt = now() - t0;
        if (w != VK_SUCCESS) {
            printf("round %d: did not finish in 8 s (%d); block %ux%u mode %u params", r, w, bw, bh, par[11]);
            for (int i = 0; i < 14; i++) printf(" %x", par[i]);
            printf("\n");
            fflush(stdout);
            _exit(1);
        }
        if (dt > slowest) slowest = dt;
        yvk_command_buffer_free(&ctx, cb);
    }
    printf("%d rounds of %dx%d blocks (threadgroups %dx%d) finished; slowest %.3f s\n", rounds, grid, grid, tgx, tgy, slowest);
    return 0;
}
