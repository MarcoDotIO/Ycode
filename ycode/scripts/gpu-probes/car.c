// car: do buffer device addresses survive a device re-creation with
// bufferDeviceAddressCaptureReplay, for imported host memory and for
// allocated memory (metal-sim-protocol.md §8.7)? usage: car
// Build: gcc -O1 -I Sources/CVulkan/include -I Sources/CVulkan -o car scripts/gpu-probes/car.c Sources/CVulkan/CVulkan.c -ldl -lpthread
#include "CVulkan.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
typedef struct { VkBuffer b; VkDeviceMemory m; uint64_t addr, bcap, mcap; } buf;
static int make(yvk_context *ctx, void *host, VkDeviceSize size, uint64_t bcap, uint64_t mcap, int replay, buf *o) {
    const yvk_dispatch *vk = yvk_fns();
    memset(o, 0, sizeof *o);
    VkExternalMemoryBufferCreateInfo ext = {VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO, NULL,
                                            VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT};
    VkBufferOpaqueCaptureAddressCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_OPAQUE_CAPTURE_ADDRESS_CREATE_INFO, host ? &ext : NULL, bcap};
    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, replay ? (void *)&bci : (host ? (void *)&ext : NULL),
                             VK_BUFFER_CREATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT, size,
                             VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                             VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    VkResult r = vk->vkCreateBuffer(ctx->device, &bi, NULL, &o->b);
    if (r) { printf("vkCreateBuffer %d\n", r); return 1; }
    VkMemoryRequirements mr; vk->vkGetBufferMemoryRequirements(ctx->device, o->b, &mr);
    VkImportMemoryHostPointerInfoEXT imp = {VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT, NULL,
                                            VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, host};
    VkMemoryOpaqueCaptureAddressAllocateInfo mci = {VK_STRUCTURE_TYPE_MEMORY_OPAQUE_CAPTURE_ADDRESS_ALLOCATE_INFO, host ? &imp : NULL, mcap};
    VkMemoryAllocateFlagsInfo fl = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, replay ? (void *)&mci : (host ? (void *)&imp : NULL),
                                    VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT, 0};
    uint32_t bits = mr.memoryTypeBits;
    if (host) {
        VkMemoryHostPointerPropertiesEXT hp = {VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
        vk->vkGetMemoryHostPointerPropertiesEXT(ctx->device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, host, &hp);
        bits &= hp.memoryTypeBits;
    }
    uint32_t type = 0; while (!(bits & (1u << type))) type++;
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &fl, host ? size : mr.size, type};
    r = vk->vkAllocateMemory(ctx->device, &ai, NULL, &o->m);
    if (r) { printf("vkAllocateMemory %d\n", r); return 1; }
    vk->vkBindBufferMemory(ctx->device, o->b, o->m, 0);
    VkBufferDeviceAddressInfo da = {VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, o->b};
    o->addr = vk->vkGetBufferDeviceAddress(ctx->device, &da);
    PFN_vkGetBufferOpaqueCaptureAddress gb = (PFN_vkGetBufferOpaqueCaptureAddress)vk->vkGetDeviceProcAddr(ctx->device, "vkGetBufferOpaqueCaptureAddress");
    PFN_vkGetDeviceMemoryOpaqueCaptureAddress gm = (PFN_vkGetDeviceMemoryOpaqueCaptureAddress)vk->vkGetDeviceProcAddr(ctx->device, "vkGetDeviceMemoryOpaqueCaptureAddress");
    o->bcap = gb(ctx->device, &da);
    VkDeviceMemoryOpaqueCaptureAddressInfo mi = {VK_STRUCTURE_TYPE_DEVICE_MEMORY_OPAQUE_CAPTURE_ADDRESS_INFO, NULL, o->m};
    o->mcap = gm(ctx->device, &mi);
    return 0;
}
int main(void) {
    char err[512]; yvk_context a; yvk_context_options opt = {0};
    if (yvk_context_create(&a, &opt, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    printf("captureReplay feature: see vulkaninfo; device created\n");
    enum { N = 6 };
    void *pages[N]; buf ba[N], bc[N];
    for (int i = 0; i < N; i++) {
        pages[i] = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        int host = i % 2 == 0;
        if (make(&a, host ? pages[i] : NULL, 65536, 0, 0, 0, &ba[i])) return 1;
        printf("A %d %s addr 0x%llx bcap 0x%llx mcap 0x%llx\n", i, host ? "import" : "alloc ", (unsigned long long)ba[i].addr,
               (unsigned long long)ba[i].bcap, (unsigned long long)ba[i].mcap);
    }
    yvk_context_destroy(&a);
    yvk_context c;
    if (yvk_context_create(&c, &opt, err, sizeof err)) { fprintf(stderr, "%s\n", err); return 1; }
    yvk_buffer filler; yvk_buffer_create(&c, 1 << 20, YVK_MEMORY_HOST, NULL, &filler, err, sizeof err);
    printf("C filler (no replay) at 0x%llx\n", (unsigned long long)filler.address);
    for (int i = N - 1; i >= 0; i--) {  // reverse order, to see placement is by request
        int host = i % 2 == 0;
        if (make(&c, host ? pages[i] : NULL, 65536, ba[i].bcap, ba[i].mcap, 1, &bc[i])) return 1;
        printf("C %d addr 0x%llx (%s)\n", i, (unsigned long long)bc[i].addr, bc[i].addr == ba[i].addr ? "same" : "DIFFERENT");
    }
    return 0;
}
