// queuekick: does work on a second queue of the same device run while the
// first queue holds a submission that never ends (metal-sim-protocol.md
// §8.8)? Queue 0 runs loop.comp (groups × 32 threads, each spinning until
// the host writes a word); after 1 s the probe submits oob.comp (one
// thread: dst = src + 1) on queue Q (0 = behind the hang, 1 = a second
// queue) N times and times each. With `idle` it then waits the device idle
// (the watchdog's way to end the hang). Finally it releases the loop.
// Q = 2: the work goes to a second device (another GPU context) made before
// the hang, waited for up to 10 s each.
// usage: queuekick oob.spv loop.spv groups Q N [idle]
// Build as hangkick.c.
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static uint32_t *load(const char *p, long *n) {
    FILE *f = fopen(p, "rb"); if (!f) exit(2); fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *s = malloc(*n); if (fread(s, 1, *n, f) != (size_t)*n) exit(2); fclose(f); return s;
}
static VkPipeline pipeline(yvk_context *ctx, uint32_t *spv, long n) {
    char err[512];
    yvk_shader_stage st = {spv, n / 4, "main", NULL, 0, 0};
    VkPipeline p = yvk_compute_pipeline_create(ctx, &st, err, sizeof err);
    if (!p) { fprintf(stderr, "%s\n", err); exit(1); }
    return p;
}
static VkResult run(yvk_context *ctx, uint32_t q, VkPipeline pipe, uint32_t groups, uint64_t src, uint64_t dst,
                    VkSemaphore tl, uint64_t value) {
    char err[512]; const yvk_dispatch *vk = yvk_fns();
    VkCommandBuffer cb = yvk_command_buffer_begin(ctx, err, sizeof err);
    vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    struct { uint64_t src, dst; } pc = {src, dst};
    vk->vkCmdPushConstants(cb, ctx->pipelineLayout, VK_SHADER_STAGE_ALL, 0, 16, &pc);
    vk->vkCmdDispatch(cb, groups, 1, 1);
    vk->vkEndCommandBuffer(cb);
    return yvk_submit_on(ctx, q, cb, tl, value, NULL, NULL, 0);
}
int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: queuekick oob.spv loop.spv groups Q N [idle]\n"); return 2; }
    long nn, nl; uint32_t *spvOob = load(argv[1], &nn), *spvLoop = load(argv[2], &nl);
    uint32_t groups = (uint32_t)atoi(argv[3]), q = (uint32_t)atoi(argv[4]); int count = atoi(argv[5]);
    int idle = argc > 6 && !strcmp(argv[6], "idle");
    char err[512]; yvk_context a; yvk_context_options o = {0};
    o.queues = 2;
    if (yvk_context_create(&a, &o, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    printf("queues %u\n", a.queueCount);
    yvk_buffer out; if (yvk_buffer_create(&a, 4096, YVK_MEMORY_HOST, NULL, &out, err, sizeof err)) return 1;
    memset(out.mapped, 0, 4096);
    volatile uint32_t *w = out.mapped;
    VkPipeline loop = pipeline(&a, spvLoop, nl), oob = pipeline(&a, spvOob, nn);
    VkSemaphore tlHang = yvk_timeline_create(&a, 0), tlWork = yvk_timeline_create(&a, 0);
    yvk_context b; yvk_context *wc = &a; uint32_t wq = q; yvk_buffer outB = out;
    uint64_t waitNs = 2000000000ull;
    if (q == 2) {
        if (yvk_context_create(&b, &o, err, sizeof err)) { fprintf(stderr, "B: %s\n", err); return 1; }
        if (yvk_buffer_create(&b, 4096, YVK_MEMORY_HOST, NULL, &outB, err, sizeof err)) return 1;
        memset(outB.mapped, 0, 4096);
        wc = &b; wq = 0; oob = pipeline(&b, spvOob, nn); tlWork = yvk_timeline_create(&b, 0);
        waitNs = 10000000000ull;
    }
    volatile uint32_t *wb = outB.mapped;
    double t0 = now();
    VkResult r = run(&a, 0, loop, groups, out.address + 64, out.address, tlHang, 1);
    printf("hang submitted on queue 0 (%u groups): %d\n", groups, r); fflush(stdout);
    VkResult wh = yvk_timeline_wait(&a, tlHang, 1, 1000000000ull);
    printf("hang after %.2f s: %d (1 = still running)\n", now() - t0, wh); fflush(stdout);
    int ok = 0;
    for (int i = 1; i <= count; i++) {
        wb[64] = 40 + i;
        double ts = now();
        VkResult rs = run(wc, wq, oob, 1, outB.address + 64 * 4, outB.address + 128 * 4, tlWork, (uint64_t)i);
        VkResult ww = yvk_timeline_wait(wc, tlWork, (uint64_t)i, waitNs);
        printf("work %d on queue %u: submit %d wait %d in %.2f ms, out %u (expect %d)\n", i, q, rs, ww,
               (now() - ts) * 1e3, wb[128], 41 + i);
        fflush(stdout);
        if (ww == VK_SUCCESS && wb[128] == (uint32_t)(41 + i)) ok++;
        if (ww != VK_SUCCESS) break;
    }
    uint64_t vh = 0; VkResult qh = yvk_timeline_query(&a, tlHang, &vh);
    printf("hang still running: %s (query %d)\n", vh < 1 ? "yes" : "no", qh);
    printf("RESULT queue %u: %d of %d ran while queue 0 was stuck\n", q, ok, count);
    if (idle) {
        double ti = now();
        VkResult wi = yvk_fns()->vkDeviceWaitIdle(a.device);
        printf("vkDeviceWaitIdle: %d after %.2f s\n", wi, now() - ti);
    }
    w[0] = 0xdeadbeef;
    VkResult we = yvk_timeline_wait(&a, tlHang, 1, 3000000000ull);
    printf("hang released: %d\n", we);
    fflush(stdout);
    _exit(0);
}
