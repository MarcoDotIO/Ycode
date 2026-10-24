// rprobe: replays one captured draw of the buffer_image_blit pipeline
// (hang capture of VulkanHangReport.swift) through CVulkan, with the
// captured buffer bytes, and reports whether it finishes.
// usage: rprobe CAPDIR VS FS GLOBALS ATLAS INSTANCES V1OFF FIRST_INSTANCE COUNT SCX SCY SCW SCH [GUARD]
//   VS, FS: the capture's SPIR-V files (FS may be a patched copy that records
//   the smallest and largest atlas index in fragment table entry 20);
//   GLOBALS, ATLAS, INSTANCES: the capture's buffer files bound as the hang
//   report lists them (v2 = GLOBALS+$V2OFF, f1 = GLOBALS+$F1OFF,
//   f5 = GLOBALS+$F5OFF, f9 = ATLAS, v1 = INSTANCES+V1OFF).
//   GUARD 1: each buffer 64 KiB into a larger allocation; 2: each buffer
//   imported from its own host pages, as the back end imports guest memory.
// Build (from ycode/, on a host with Vulkan; stage8-contract.md §15):
//   gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o X scripts/gpu-probes/X.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static void *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(2); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    void *b = malloc(*n); if (fread(b, 1, *n, f) != *n) exit(2); fclose(f); return b;
}

typedef struct { yvk_buffer b; uint64_t addr; } gbuf;

static gbuf load(yvk_context *ctx, const char *dir, const char *name, int guard) {
    char p[1024]; snprintf(p, sizeof p, "%s/%s", dir, name);
    size_t n; void *d = slurp(p, &n);
    gbuf g; char err[256];
    if (guard == 2) {
        // As the back end imports guest memory: the buffer's own pages, imported exactly.
        size_t len = (n + 65535) & ~(size_t)65535;
        void *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        memcpy(m, d, n);
        if (yvk_buffer_create(ctx, len, YVK_MEMORY_IMPORT_HOST, m, &g.b, err, sizeof err)) { fprintf(stderr, "%s\n", err); exit(1); }
        g.addr = g.b.address;
        printf("%s imported at 0x%llx (+%zu)\n", name, (unsigned long long)g.addr, len);
        return g;
    }
    size_t pad = guard ? 65536 : 0;
    if (yvk_buffer_create(ctx, n + 2 * pad, YVK_MEMORY_HOST, NULL, &g.b, err, sizeof err)) { fprintf(stderr, "%s\n", err); exit(1); }
    memset(g.b.mapped, 0, n + 2 * pad);
    memcpy((char *)g.b.mapped + pad, d, n);
    g.addr = g.b.address + pad;
    return g;
}

int main(int argc, char **argv) {
    if (argc < 14) { fprintf(stderr, "usage: see the header\n"); return 64; }
    const char *dir = argv[1];
    int v1off = atoi(argv[7]), first = atoi(argv[8]), count = atoi(argv[9]);
    int scx = atoi(argv[10]), scy = atoi(argv[11]), scw = atoi(argv[12]), sch = atoi(argv[13]);
    int guard = argc > 14 ? atoi(argv[14]) : 0;
    char err[512]; yvk_context ctx; yvk_context_options o = {0};
    if (yvk_context_create(&ctx, &o, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    const yvk_dispatch *vk = yvk_fns();
    size_t vn, fnn;
    char p[1024];
    snprintf(p, sizeof p, "%s/%s", dir, argv[2]); uint32_t *vs = slurp(p, &vn);
    snprintf(p, sizeof p, "%s/%s", dir, argv[3]); uint32_t *fs = slurp(p, &fnn);
    yvk_graphics_info g; memset(&g, 0, sizeof g);
    g.vertex = (yvk_shader_stage){vs, vn / 4, "buffer_image_blit_vert_lpf", NULL, 0, 0};
    g.fragment = (yvk_shader_stage){fs, fnn / 4, "buffer_image_blit_frag_lpf", NULL, 0, 0};
    g.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
    g.samples = VK_SAMPLE_COUNT_1_BIT;
    g.colorCount = YVK_MAX_COLOR_ATTACHMENTS;
    for (int i = 0; i < YVK_MAX_COLOR_ATTACHMENTS; i++) g.colorFormats[i] = VK_FORMAT_UNDEFINED;
    g.colorFormats[0] = VK_FORMAT_B8G8R8A8_UNORM;
    g.blend[0].colorWriteMask = 0xF;
    VkPipeline pipe;
    if (getenv("LIB") && ctx.features.graphicsPipelineLibrary) {
        // As the back end builds render pipelines: four library parts, fast-linked.
        VkPipeline parts[4] = {yvk_library_vertex_input(&ctx, &g, err, sizeof err),
                               yvk_library_pre_raster(&ctx, &g.vertex, 0, err, sizeof err),
                               yvk_library_fragment_shader(&ctx, &g.fragment, g.samples, err, sizeof err),
                               yvk_library_fragment_output(&ctx, &g, err, sizeof err)};
        pipe = yvk_library_link(&ctx, parts, 4, 0, err, sizeof err);
        printf("pipeline linked from libraries\n");
    } else {
        pipe = yvk_graphics_pipeline_create(&ctx, &g, err, sizeof err);
    }
    if (!pipe) { fprintf(stderr, "pipeline: %s\n", err); return 1; }
    gbuf glob = load(&ctx, dir, argv[4], guard), atlas = load(&ctx, dir, argv[5], guard), inst = load(&ctx, dir, argv[6], guard);
    yvk_buffer tv, tf;
    yvk_buffer_create(&ctx, 192 * 8, YVK_MEMORY_HOST, NULL, &tv, err, sizeof err);
    yvk_buffer_create(&ctx, 192 * 8, YVK_MEMORY_HOST, NULL, &tf, err, sizeof err);
    uint64_t *v = tv.mapped, *f = tf.mapped;
    memset(v, 0, 192 * 8); memset(f, 0, 192 * 8);
    // Offsets of the globals bindings (environment V2OFF, F1OFF, F5OFF; the
    // defaults are the first capture's).
    int v2off = getenv("V2OFF") ? atoi(getenv("V2OFF")) : 512, f1off = getenv("F1OFF") ? atoi(getenv("F1OFF")) : 5888;
    int f5off = getenv("F5OFF") ? atoi(getenv("F5OFF")) : 5120;
    v[1] = inst.addr + v1off; v[2] = glob.addr + v2off;
    f[1] = glob.addr + f1off; f[5] = glob.addr + f5off; f[9] = atlas.addr;
    yvk_buffer dbg; yvk_buffer_create(&ctx, 4096, YVK_MEMORY_HOST, NULL, &dbg, err, sizeof err);
    ((int32_t *)dbg.mapped)[0] = 0x7fffffff; ((int32_t *)dbg.mapped)[1] = (int32_t)0x80000000;
    f[20] = dbg.address;
    yvk_image_info ii = {VK_IMAGE_TYPE_2D, VK_FORMAT_B8G8R8A8_UNORM, 1146, 1740, 1, 1, 1, VK_SAMPLE_COUNT_1_BIT,
                         VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, 0};
    yvk_image img; if (yvk_image_create(&ctx, &ii, &img, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    VkComponentMapping id = {0};
    yvk_view_info vi = {img.image, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_B8G8R8A8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1, id,
                        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT};
    VkImageView view = yvk_view_create(&ctx, &vi, err, sizeof err);
    VkCommandBuffer cb = yvk_command_buffer_begin(&ctx, err, sizeof err);
    yvk_cmd_image_layout(cb, img.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL);
    yvk_rendering_info ri; memset(&ri, 0, sizeof ri);
    ri.color[0] = (yvk_attachment){view, NULL, VK_RESOLVE_MODE_NONE, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_STORE_OP_STORE, {{{0}}}};
    ri.colorCount = YVK_MAX_COLOR_ATTACHMENTS; ri.width = 1146; ri.height = 1740; ri.layerCount = 1;
    yvk_cmd_begin_rendering(cb, &ri);
    vk->vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    vk->vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipelineLayout, 0, 1, &ctx.heapSet, 0, NULL);
    VkViewport vp = {0, 1740, 1146, -1740, 0, 1};
    vk->vkCmdSetViewport(cb, 0, 1, &vp);
    VkRect2D sc = {{scx, scy}, {(uint32_t)scw, (uint32_t)sch}};
    vk->vkCmdSetScissor(cb, 0, 1, &sc);
    vk->vkCmdSetCullMode(cb, VK_CULL_MODE_NONE);
    vk->vkCmdSetFrontFace(cb, VK_FRONT_FACE_CLOCKWISE);
    vk->vkCmdSetPrimitiveTopology(cb, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP);
    vk->vkCmdSetPrimitiveRestartEnable(cb, 0);
    vk->vkCmdSetDepthBiasEnable(cb, 0);
    vk->vkCmdSetDepthBias(cb, 0, 0, 0);
    float bc[4] = {0}; vk->vkCmdSetBlendConstants(cb, bc);
    vk->vkCmdSetStencilReference(cb, VK_STENCIL_FACE_FRONT_AND_BACK, 0);
    vk->vkCmdSetStencilCompareMask(cb, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
    vk->vkCmdSetStencilWriteMask(cb, VK_STENCIL_FACE_FRONT_AND_BACK, 0xFF);
    vk->vkCmdSetStencilTestEnable(cb, 0);
    vk->vkCmdSetStencilOp(cb, VK_STENCIL_FACE_FRONT_AND_BACK, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_COMPARE_OP_ALWAYS);
    vk->vkCmdSetDepthTestEnable(cb, 0);
    vk->vkCmdSetDepthWriteEnable(cb, 0);
    vk->vkCmdSetDepthCompareOp(cb, VK_COMPARE_OP_ALWAYS);
    if (vk->vkCmdSetPolygonModeEXT) vk->vkCmdSetPolygonModeEXT(cb, VK_POLYGON_MODE_FILL);
    if (vk->vkCmdSetDepthClampEnableEXT) vk->vkCmdSetDepthClampEnableEXT(cb, 0);
    struct { uint64_t a, b; uint32_t g[4]; } pc = {tv.address, tf.address, {0, 0, 0, 0}};
    vk->vkCmdPushConstants(cb, ctx.pipelineLayout, VK_SHADER_STAGE_ALL, 0, 32, &pc);
    vk->vkCmdDraw(cb, 4, (uint32_t)count, 0, (uint32_t)first);
    vk->vkCmdEndRendering(cb);
    vk->vkEndCommandBuffer(cb);
    VkSemaphore tl = yvk_timeline_create(&ctx, 0);
    VkResult r = yvk_submit(&ctx, cb, tl, 1, NULL, 0);
    VkResult w = yvk_timeline_wait(&ctx, tl, 1, 4000000000ull);
    printf("instances %d..%d (v1 @%d, scissor %d,%d %dx%d, guard %d): %s (submit %d)\n", first, first + count - 1, v1off,
           scx, scy, scw, sch, guard, w == VK_SUCCESS ? "finished" : "DID NOT FINISH", r);
    printf("atlas index range read (patched FS only): %d .. %d\n", ((int32_t *)dbg.mapped)[0], ((int32_t *)dbg.mapped)[1]);
    fflush(stdout);
    _exit(w == VK_SUCCESS ? 0 : 1);
}
