// vkrun.c: Ycode R8 Vulkan test harness (ours, stage 8a research).
//
// Runs one compute shader (SPIR-V) with the "R8 PoC compute ABI":
//   push constants, offset 0:  uint64 buffer_address[4]  (Metal buffer slots 0..3)
//   push constants, offset 32: uint32 grid_size[3] (--grid G, default N;
//   ceil(G / X) threadgroups are dispatched)
//   specialization constants 0, 1, 2: threadgroup size x, y, z
// Slot 0 = a[i] = i, slot 1 = b[i] = 2i + 0.5, slot 2 = out (zeroed),
// slot 3 = uint32 count = N. Checks out[i] == a[i] + b[i].
//
// --host-import allocates every buffer with aligned_alloc in this process
// and imports it with VK_EXT_external_memory_host, so the GPU works
// directly on host memory (the model for guest-shared memory).
// --memfd does the same with MAP_SHARED mappings of a memfd (the way a VMM
// maps guest RAM).
// --features prints the device features and limits the translation plan
// relies on.
//
// Build: cc -O2 -o vkrun vkrun.c -lvulkan
// Usage: vkrun [--features] [--host-import | --memfd] [--n N] [--grid G] [--local X]
//              [--entry NAME] SHADER.spv
#define _GNU_SOURCE 1
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

#ifndef VK_KHR_dynamic_rendering_local_read
// Older headers (1.3.275 on the Thor) lack this extension; the layout is
// that of the Vulkan registry (structure type 1000232000).
typedef struct VkPhysicalDeviceDynamicRenderingLocalReadFeaturesKHR {
    VkStructureType sType; void *pNext; VkBool32 dynamicRenderingLocalRead;
} VkPhysicalDeviceDynamicRenderingLocalReadFeaturesKHR;
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES_KHR ((VkStructureType)1000232000)
#endif

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
    fprintf(stderr, "%s:%d: %s -> %d\n", __FILE__, __LINE__, #x, r_); exit(1); } } while (0)

static VkInstance inst;
static VkPhysicalDevice phys;
static VkDevice dev;
static VkQueue queue;
static uint32_t qfam;
static int host_import, use_memfd;
static VkDeviceSize host_align = 4096;
static PFN_vkGetMemoryHostPointerPropertiesEXT pGetHostPtrProps;

typedef struct { VkBuffer buf; VkDeviceMemory mem; void *ptr; VkDeviceSize size; uint64_t addr; } Buf;

static uint32_t find_type(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    fprintf(stderr, "no memory type for bits 0x%x flags 0x%x\n", bits, want);
    exit(1);
}

static Buf make_buf(VkDeviceSize size) {
    Buf b = {0};
    if (host_import) size = (size + host_align - 1) / host_align * host_align;
    b.size = size;
    VkExternalMemoryBufferCreateInfo ext = {VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO, NULL,
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT};
    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, host_import ? &ext : NULL, 0, size,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    CHECK(vkCreateBuffer(dev, &bi, NULL, &b.buf));
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, b.buf, &mr);
    VkMemoryAllocateFlagsInfo fl = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, NULL,
        VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT, 0};
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &fl, mr.size, 0};
    VkImportMemoryHostPointerInfoEXT imp = {VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT, NULL,
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, NULL};
    if (host_import) {
        if (use_memfd) {
            // Guest RAM in a VMM is a shared mapping of a memory file; test
            // that such a mapping imports too.
            int fd = memfd_create("vkrun-guest-ram", 0);
            if (fd < 0 || ftruncate(fd, (off_t)size) != 0) { perror("memfd"); exit(1); }
            b.ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (b.ptr == MAP_FAILED) { perror("mmap"); exit(1); }
            close(fd);
        } else {
            b.ptr = aligned_alloc(host_align, size);
        }
        memset(b.ptr, 0, size);
        VkMemoryHostPointerPropertiesEXT hp = {VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
        CHECK(pGetHostPtrProps(dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, b.ptr, &hp));
        imp.pHostPointer = b.ptr;
        fl.pNext = &imp;
        ai.allocationSize = size;
        ai.memoryTypeIndex = find_type(hp.memoryTypeBits & mr.memoryTypeBits, 0);
    } else {
        ai.memoryTypeIndex = find_type(mr.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    }
    CHECK(vkAllocateMemory(dev, &ai, NULL, &b.mem));
    CHECK(vkBindBufferMemory(dev, b.buf, b.mem, 0));
    if (!host_import) CHECK(vkMapMemory(dev, b.mem, 0, size, 0, &b.ptr));
    VkBufferDeviceAddressInfo da = {VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, b.buf};
    b.addr = vkGetBufferDeviceAddress(dev, &da);
    return b;
}

static void print_features(void) {
    VkPhysicalDeviceExternalMemoryHostPropertiesEXT hostp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
    VkPhysicalDeviceSubgroupProperties sg = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES, &hostp};
    VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &sg};
    vkGetPhysicalDeviceProperties2(phys, &p2);
    printf("device %s api %u.%u.%u\n", p2.properties.deviceName, VK_API_VERSION_MAJOR(p2.properties.apiVersion),
           VK_API_VERSION_MINOR(p2.properties.apiVersion), VK_API_VERSION_PATCH(p2.properties.apiVersion));
    printf("minImportedHostPointerAlignment %llu\n", (unsigned long long)hostp.minImportedHostPointerAlignment);
    printf("subgroupSize %u ops 0x%x stages 0x%x quadAllStages %u\n", sg.subgroupSize, sg.supportedOperations,
           sg.supportedStages, sg.quadOperationsInAllStages);
    printf("maxPushConstantsSize %u maxComputeSharedMemorySize %u maxComputeWorkGroupInvocations %u\n",
           p2.properties.limits.maxPushConstantsSize, p2.properties.limits.maxComputeSharedMemorySize,
           p2.properties.limits.maxComputeWorkGroupInvocations);

    VkPhysicalDeviceDynamicRenderingLocalReadFeaturesKHR lr = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES_KHR};
    VkPhysicalDeviceWorkgroupMemoryExplicitLayoutFeaturesKHR wg = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_WORKGROUP_MEMORY_EXPLICIT_LAYOUT_FEATURES_KHR, &lr};
    VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT il = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT, &wg};
    VkPhysicalDeviceVulkan13Features v13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &il};
    VkPhysicalDeviceVulkan12Features v12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &v13};
    VkPhysicalDeviceVulkan11Features v11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &v12};
    VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v11};
    vkGetPhysicalDeviceFeatures2(phys, &f2);
#define F(s, n) printf("%-44s %u\n", #n, (unsigned)s.n)
    F(f2.features, shaderInt64); F(f2.features, shaderInt16); F(f2.features, shaderFloat64);
    F(f2.features, fragmentStoresAndAtomics); F(f2.features, dualSrcBlend); F(f2.features, logicOp);
    F(v11, storageBuffer16BitAccess); F(v11, uniformAndStorageBuffer16BitAccess);
    F(v11, storagePushConstant16); F(v11, storageInputOutput16); F(v11, variablePointers);
    F(v12, shaderFloat16); F(v12, shaderInt8); F(v12, storageBuffer8BitAccess);
    F(v12, bufferDeviceAddress); F(v12, descriptorIndexing); F(v12, runtimeDescriptorArray);
    F(v12, descriptorBindingPartiallyBound); F(v12, descriptorBindingVariableDescriptorCount);
    F(v12, scalarBlockLayout); F(v12, vulkanMemoryModel); F(v12, vulkanMemoryModelDeviceScope);
    F(v12, shaderSubgroupExtendedTypes); F(v12, samplerFilterMinmax); F(v12, shaderBufferInt64Atomics);
    F(v13, dynamicRendering); F(v13, synchronization2); F(v13, maintenance4);
    F(v13, shaderDemoteToHelperInvocation); F(v13, subgroupSizeControl); F(v13, computeFullSubgroups);
    F(il, fragmentShaderPixelInterlock); F(il, fragmentShaderSampleInterlock);
    F(wg, workgroupMemoryExplicitLayout); F(wg, workgroupMemoryExplicitLayoutScalarBlockLayout);
    F(wg, workgroupMemoryExplicitLayout8BitAccess); F(wg, workgroupMemoryExplicitLayout16BitAccess);
    F(lr, dynamicRenderingLocalRead);
#undef F
}

int main(int argc, char **argv) {
    const char *path = NULL, *entry = "main";
    uint32_t n = 1000, local = 32, grid = 0;
    int features = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--features")) features = 1;
        else if (!strcmp(argv[i], "--host-import")) host_import = 1;
        else if (!strcmp(argv[i], "--memfd")) host_import = use_memfd = 1;
        else if (!strcmp(argv[i], "--n") && i + 1 < argc) n = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--local") && i + 1 < argc) local = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--grid") && i + 1 < argc) grid = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--entry") && i + 1 < argc) entry = argv[++i];
        else path = argv[i];
    }
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vkrun", 1, "ycode-r8", 1, VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app};
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t nd = 1;
    VkResult er = vkEnumeratePhysicalDevices(inst, &nd, &phys);
    if (er != VK_SUCCESS && er != VK_INCOMPLETE) { fprintf(stderr, "no device\n"); return 1; }
    if (features) print_features();
    if (!path) return 0;
    if (!grid) grid = n;

    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, NULL);
    VkQueueFamilyProperties *qp = calloc(nq, sizeof *qp);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, qp);
    for (qfam = 0; qfam < nq && !(qp[qfam].queueFlags & VK_QUEUE_COMPUTE_BIT); qfam++) {}
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, qfam, 1, &prio};
    VkPhysicalDeviceVulkan13Features e13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    e13.maintenance4 = VK_TRUE;
    VkPhysicalDeviceVulkan12Features e12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &e13};
    e12.bufferDeviceAddress = VK_TRUE; e12.shaderFloat16 = VK_TRUE; e12.shaderInt8 = VK_TRUE;
    e12.vulkanMemoryModel = VK_TRUE; e12.vulkanMemoryModelDeviceScope = VK_TRUE;
    e12.scalarBlockLayout = VK_TRUE; e12.storageBuffer8BitAccess = VK_TRUE;
    VkPhysicalDeviceVulkan11Features e11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &e12};
    e11.storageBuffer16BitAccess = VK_TRUE;
    VkPhysicalDeviceFeatures2 ef = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &e11};
    ef.features.shaderInt64 = VK_TRUE; ef.features.shaderInt16 = VK_TRUE;
    const char *exts[] = {VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &ef, 0, 1, &qci, 0, NULL, 1, exts, NULL};
    CHECK(vkCreateDevice(phys, &dci, NULL, &dev));
    vkGetDeviceQueue(dev, qfam, 0, &queue);
    pGetHostPtrProps = (PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(dev, "vkGetMemoryHostPointerPropertiesEXT");
    if (host_import) {
        VkPhysicalDeviceExternalMemoryHostPropertiesEXT hp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
        VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &hp};
        vkGetPhysicalDeviceProperties2(phys, &p2);
        host_align = hp.minImportedHostPointerAlignment;
    }

    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *code = malloc((size_t)len);
    if (fread(code, 1, (size_t)len, f) != (size_t)len) { perror("read"); return 1; }
    fclose(f);
    VkShaderModuleCreateInfo smi = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, (size_t)len, code};
    VkShaderModule sm;
    CHECK(vkCreateShaderModule(dev, &smi, NULL, &sm));

    VkPushConstantRange pcr = {VK_SHADER_STAGE_COMPUTE_BIT, 0, 48};
    VkPipelineLayoutCreateInfo pli = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 0, NULL, 1, &pcr};
    VkPipelineLayout pl;
    CHECK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));
    uint32_t spec[3] = {local, 1, 1};
    VkSpecializationMapEntry me[3] = {{0, 0, 4}, {1, 4, 4}, {2, 8, 4}};
    VkSpecializationInfo si = {3, me, sizeof spec, spec};
    VkComputePipelineCreateInfo cpi = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_COMPUTE_BIT, sm, entry, &si},
        pl, VK_NULL_HANDLE, 0};
    VkPipeline pipe;
    CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpi, NULL, &pipe));

    Buf a = make_buf(n * 4), b = make_buf(n * 4), o = make_buf(n * 4), c = make_buf(4);
    for (uint32_t i = 0; i < n; i++) { ((float *)a.ptr)[i] = (float)i; ((float *)b.ptr)[i] = 2.0f * i + 0.5f; ((float *)o.ptr)[i] = -1.0f; }
    *(uint32_t *)c.ptr = n;

    struct { uint64_t addr[4]; uint32_t grid[3]; uint32_t pad; } pc = {{a.addr, b.addr, o.addr, c.addr}, {grid, 1, 1}, 0};
    VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, qfam};
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
    VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &cbai, &cb));
    VkCommandBufferBeginInfo bbi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    CHECK(vkBeginCommandBuffer(cb, &bbi));
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdPushConstants(cb, pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, &pc);
    vkCmdDispatch(cb, (grid + local - 1) / local, 1, 1);
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
    CHECK(vkEndCommandBuffer(cb));
    VkSubmitInfo sub = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb};
    CHECK(vkQueueSubmit(queue, 1, &sub, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));

    uint32_t bad = 0;
    for (uint32_t i = 0; i < n; i++) {
        float want = (float)i + (2.0f * i + 0.5f);
        if (((float *)o.ptr)[i] != want) {
            if (bad < 5) fprintf(stderr, "mismatch at %u: got %f want %f\n", i, ((float *)o.ptr)[i], want);
            bad++;
        }
    }
    printf("%s: n=%u grid=%u local=%u host_import=%d entry=%s -> %s (%u mismatches)\n", path, n, grid, local, host_import,
           entry, bad ? "FAIL" : "PASS", bad);
    return bad ? 1 : 0;
}
