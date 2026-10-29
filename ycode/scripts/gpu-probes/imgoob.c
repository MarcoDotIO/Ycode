// imgoob: what a storage-image write outside the written view does on this
// device (stage8-contract.md §15.9). One thread writes a W x H rectangle of
// texels at (OX, OY) through a storage view of mip level LEVEL of a
// SIZE x SIZE RGBA8 image with LEVELS levels; the view is LEVEL's
// (as a Metal texture view of one level is).
// usage: imgoob SPV SIZE LEVELS LEVEL W H OX OY [ROBUST [STALE]]
//   ROBUST 1: the pipeline is created with robust image access
//   (VK_EXT_pipeline_robustness), for comparison.
//   STALE 1: the view and the image are destroyed (memory freed) after
//   their descriptor was written, before the dispatch that writes through
//   it: a heap slot that still names a released texture. STALE 2: heap
//   index 7 is written to, whose descriptor was never written.
// Exit 0 when the dispatch finished within 5 s, 1 when it did not.
// Build (from ycode/, on a host with Vulkan; stage8-contract.md §15):
//   gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o X scripts/gpu-probes/X.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 9) { fprintf(stderr, "usage: imgoob SPV SIZE LEVELS LEVEL W H OX OY [ROBUST]\n"); return 64; }
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *spv = malloc(n); if (fread(spv, 1, n, f) != (size_t)n) return 2; fclose(f);
    uint32_t size = atoi(argv[2]), levels = atoi(argv[3]), level = atoi(argv[4]);
    struct { uint32_t index; int32_t w, h, ox, oy; } pc = {1, atoi(argv[5]), atoi(argv[6]), atoi(argv[7]), atoi(argv[8])};
    int robust = argc > 9 ? atoi(argv[9]) : 0;
    int stale = argc > 10 ? atoi(argv[10]) : 0;
    char err[512]; yvk_context ctx; yvk_context_options o = {0};
    if (yvk_context_create(&ctx, &o, err, sizeof err)) { fprintf(stderr, "context: %s\n", err); return 1; }
    const yvk_dispatch *vk = yvk_fns();
    VkPipeline pipe;
    if (robust) {
        VkShaderModuleCreateInfo mi = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, (size_t)n, spv};
        VkShaderModule m; if (vk->vkCreateShaderModule(ctx.device, &mi, NULL, &m)) return 1;
        VkPipelineRobustnessCreateInfoEXT rob = {VK_STRUCTURE_TYPE_PIPELINE_ROBUSTNESS_CREATE_INFO_EXT, NULL,
            VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_DEVICE_DEFAULT_EXT, VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_DEVICE_DEFAULT_EXT,
            VK_PIPELINE_ROBUSTNESS_BUFFER_BEHAVIOR_DEVICE_DEFAULT_EXT, VK_PIPELINE_ROBUSTNESS_IMAGE_BEHAVIOR_ROBUST_IMAGE_ACCESS_EXT};
        VkComputePipelineCreateInfo ci = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, &rob, 0,
            {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_COMPUTE_BIT, m, "main", NULL},
            ctx.pipelineLayout, VK_NULL_HANDLE, 0};
        if (vk->vkCreateComputePipelines(ctx.device, VK_NULL_HANDLE, 1, &ci, NULL, &pipe)) { fprintf(stderr, "robust pipeline failed\n"); return 1; }
    } else {
        yvk_shader_stage st = {spv, n / 4, "main", NULL, 0, 0};
        pipe = yvk_compute_pipeline_create(&ctx, &st, err, sizeof err);
        if (!pipe) { fprintf(stderr, "pipeline: %s\n", err); return 1; }
    }
    yvk_image_info ii = {VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, size, size, 1, levels, 1, VK_SAMPLE_COUNT_1_BIT,
                         VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, 0};
    yvk_image img;
    if (yvk_image_create(&ctx, &ii, &img, err, sizeof err)) { fprintf(stderr, "image: %s\n", err); return 1; }
    VkComponentMapping id = {0};
    yvk_view_info vi = {img.image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT, level, 1, 0, 1, id,
                        VK_IMAGE_USAGE_STORAGE_BIT};
    VkImageView view = yvk_view_create(&ctx, &vi, err, sizeof err);
    if (!view) { fprintf(stderr, "view: %s\n", err); return 1; }
    yvk_heap_write_storage(&ctx, 1, view);
    if (stale == 2) pc.index = 7;
    VkCommandBuffer cb = yvk_command_buffer_begin(&ctx, err, sizeof err);
    VkImageMemoryBarrier2 b = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, NULL, VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, 0,
        VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, VK_ACCESS_2_SHADER_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, img.image, {VK_IMAGE_ASPECT_COLOR_BIT, 0, levels, 0, 1}};
    VkDependencyInfo di = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO, NULL, 0, 0, NULL, 0, NULL, 1, &b};
    vk->vkCmdPipelineBarrier2(cb, &di);
    if (stale == 1) {
        // The layout change must complete first; then the image goes.
        vk->vkEndCommandBuffer(cb);
        VkSemaphore t0 = yvk_timeline_create(&ctx, 0);
        yvk_submit(&ctx, cb, t0, 1, NULL, 0);
        yvk_timeline_wait(&ctx, t0, 1, 5000000000ull);
        vk->vkDestroyImageView(ctx.device, view, NULL);
        yvk_image_destroy(&ctx, &img);
        // Other allocations reuse nothing in particular; the slot still names the old view.
        cb = yvk_command_buffer_begin(&ctx, err, sizeof err);
    }
    vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vk->vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, ctx.pipelineLayout, 0, 1, &ctx.heapSet, 0, NULL);
    vk->vkCmdPushConstants(cb, ctx.pipelineLayout, VK_SHADER_STAGE_ALL, 0, sizeof pc, &pc);
    vk->vkCmdDispatch(cb, 1, 1, 1);
    yvk_cmd_memory_barrier(cb, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT);
    vk->vkEndCommandBuffer(cb);
    VkSemaphore tl = yvk_timeline_create(&ctx, 0);
    VkResult r = yvk_submit(&ctx, cb, tl, 1, NULL, 0);
    VkResult w = yvk_timeline_wait(&ctx, tl, 1, 5000000000ull);
    printf("image %u^2 levels %u, view of level %u, writes %dx%d at (%d,%d)%s%s: submit %d, %s\n", size, levels, level, pc.w, pc.h,
           pc.ox, pc.oy, robust ? " robust" : "", stale == 1 ? " through a released texture's slot" : stale == 2 ? " through a never-written slot" : "", r, w == VK_SUCCESS ? "finished" : "did not finish in 5 s");
    fflush(stdout);
    _exit(w == VK_SUCCESS ? 0 : 1);
}
