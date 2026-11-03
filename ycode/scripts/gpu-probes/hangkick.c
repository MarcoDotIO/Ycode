// hangkick: what ends a stuck submission on this device (metal-sim-protocol.md
// §8.7)? A one-thread kernel reads address 0 (null) or loops until the host
// writes a word (loop); after 3 s the probe either creates a second device
// and submits there (KICK 1), waits the stuck device idle (KICK 2) or does
// nothing (KICK 0), then destroys the device and runs a kernel on a third.
// usage: hangkick oob.spv loop.spv null|loop|ok 0|1|2
// Build (from ycode/, on a host with Vulkan):
//   glslangValidator --target-env vulkan1.3 -V scripts/gpu-probes/oob.comp -o oob.spv (also loop.comp)
//   gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o hangkick scripts/gpu-probes/hangkick.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static uint32_t *load(const char *p, long *n) {
    FILE *f = fopen(p, "rb"); fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *s = malloc(*n); if (fread(s, 1, *n, f) != (size_t)*n) exit(2); fclose(f); return s;
}
static int run(yvk_context *ctx, uint32_t *spv, long n, uint64_t src, uint64_t dst, VkSemaphore *tlOut) {
    char err[512]; const yvk_dispatch *vk = yvk_fns();
    yvk_shader_stage st = {spv, n / 4, "main", NULL, 0, 0};
    VkPipeline pipe = yvk_compute_pipeline_create(ctx, &st, err, sizeof err);
    if (!pipe) { fprintf(stderr, "%s\n", err); return 1; }
    VkCommandBuffer cb = yvk_command_buffer_begin(ctx, err, sizeof err);
    vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    struct { uint64_t src, dst; } pc = {src, dst};
    vk->vkCmdPushConstants(cb, ctx->pipelineLayout, VK_SHADER_STAGE_ALL, 0, 16, &pc);
    vk->vkCmdDispatch(cb, 1, 1, 1);
    vk->vkEndCommandBuffer(cb);
    *tlOut = yvk_timeline_create(ctx, 0);
    return yvk_submit(ctx, cb, *tlOut, 1, NULL, 0);
}
int main(int argc, char **argv) {
    long nn, nl; uint32_t *spvNull = load(argv[1], &nn), *spvLoop = load(argv[2], &nl);
    const char *mode = argv[3]; int kick = atoi(argv[4]);
    char err[512]; yvk_context a; yvk_context_options o = {0};
    if (yvk_context_create(&a, &o, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    yvk_buffer out; if (yvk_buffer_create(&a, 4096, YVK_MEMORY_HOST, NULL, &out, err, sizeof err)) return 1;
    memset(out.mapped, 0, 4096);
    VkSemaphore tl; int r;
    double t0 = now();
    if (!strcmp(mode, "null")) r = run(&a, spvNull, nn, 0, out.address, &tl);
    else if (!strcmp(mode, "loop")) r = run(&a, spvLoop, nl, out.address + 64, out.address, &tl);
    else r = run(&a, spvNull, nn, out.address + 128, out.address, &tl);
    printf("A submit %d\n", r); fflush(stdout);
    VkResult w = yvk_timeline_wait(&a, tl, 1, 3000000000ull);
    uint64_t v = 0; VkResult q = yvk_timeline_query(&a, tl, &v);
    printf("A after %.1f s: wait %d query %d value %llu\n", now() - t0, w, q, (unsigned long long)v); fflush(stdout);
    if (kick == 1 && w != VK_SUCCESS) {
        yvk_context b;
        double tk = now();
        if (yvk_context_create(&b, &o, err, sizeof err)) { fprintf(stderr, "B: %s\n", err); return 1; }
        yvk_buffer ob; yvk_buffer_create(&b, 4096, YVK_MEMORY_HOST, NULL, &ob, err, sizeof err); memset(ob.mapped, 0, 4096);
        VkSemaphore tb; int rb = run(&b, spvNull, nn, ob.address + 128, ob.address, &tb);
        printf("B created in %.2f s, submit %d\n", now() - tk, rb); fflush(stdout);
        for (int s = 0; s < 30; s++) {
            VkResult wb = yvk_timeline_wait(&b, tb, 1, 1000000000ull);
            uint64_t va = 0, vb = 0; VkResult qa = yvk_timeline_query(&a, tl, &va), qb = yvk_timeline_query(&b, tb, &vb);
            printf("  +%.1f s: B wait %d (value %llu, q %d), A query %d value %llu\n", now() - tk, wb, (unsigned long long)vb, qb, qa,
                   (unsigned long long)va); fflush(stdout);
            if (qa == VK_ERROR_DEVICE_LOST && wb == VK_SUCCESS) break;
            if (wb == VK_ERROR_DEVICE_LOST) break;
        }
        printf("B out %u\n", ((uint32_t *)ob.mapped)[0]);
    }
    if (kick == 2) {
        double tw = now();
        VkResult wi = yvk_fns()->vkDeviceWaitIdle(a.device);
        uint64_t va = 0; VkResult qa = yvk_timeline_query(&a, tl, &va);
        printf("vkDeviceWaitIdle: %d after %.2f s; A query %d value %llu\n", wi, now() - tw, qa, (unsigned long long)va); fflush(stdout);
    }
    if (!strcmp(mode, "loop")) { ((uint32_t *)out.mapped)[0] = 0xdeadbeef; }
    double td = now();
    printf("destroying A...\n"); fflush(stdout);
    yvk_context_destroy(&a);
    printf("A destroyed in %.2f s\n", now() - td); fflush(stdout);
    yvk_context c;
    if (yvk_context_create(&c, &o, err, sizeof err)) { fprintf(stderr, "C: %s\n", err); return 1; }
    yvk_buffer oc; yvk_buffer_create(&c, 4096, YVK_MEMORY_HOST, NULL, &oc, err, sizeof err); memset(oc.mapped, 0, 4096);
    ((uint32_t *)oc.mapped)[32] = 41;
    VkSemaphore tc; int rc = run(&c, spvNull, nn, oc.address + 128, oc.address, &tc);
    VkResult wc = yvk_timeline_wait(&c, tc, 1, 5000000000ull);
    printf("C submit %d wait %d out %u (expect 42)\n", rc, wc, ((uint32_t *)oc.mapped)[0]);
    fflush(stdout);
    _exit(0);
}
