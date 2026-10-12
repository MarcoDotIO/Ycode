// abi.h: the Ycode Metal-on-Vulkan shader ABI that ycode-airc's SPIR-V
// follows and that the Vulkan back end implements (metal-shaders.md
// section 4.4, "bindless heap + device addresses"). The reflection
// document repeats these numbers so that a consumer can check them.
#pragma once

namespace airc::abi {

constexpr unsigned kVersion = 1;

// Push constants (32 bytes, all stages):
//   offset 0:  u64 device address of the vertex (or kernel) stage's argument table
//   offset 8:  u64 device address of the fragment stage's argument table
//   offset 16: u32 x 3 threads per grid (kernels; the exact Metal grid)
//   offset 28: u32 reserved
constexpr unsigned kPushSize = 32;
constexpr unsigned kPushTableVertexOrKernel = 0;
constexpr unsigned kPushTableFragment = 8;
constexpr unsigned kPushGrid = 16;

// Argument table: an array of u64 entries in device memory, one table per
// stage per draw or dispatch, at the address in the push constants.
constexpr unsigned kTableBuffer0 = 0;            // entries 0..30: buffer slot k = device address + offset
constexpr unsigned kTableConstantData = 31;      // device address of the function's constant data
constexpr unsigned kTableTexture0 = 32;          // entries 32..159: texture slot k = heap index
constexpr unsigned kTableSampler0 = 160;         // entries 160..175: sampler slot k = heap index
constexpr unsigned kTableConstexprSampler0 = 176;  // entries 176..191: constexpr sampler i = heap index
constexpr unsigned kTableEntries = 192;          // 1536 bytes
constexpr unsigned kMaxBuffers = 31, kMaxTextures = 128, kMaxSamplers = 16, kMaxConstexprSamplers = 16;

// Bindless heap: descriptor set 0.
constexpr unsigned kSet = 0;
constexpr unsigned kBindingSampledImages = 0;    // VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, runtime array
constexpr unsigned kBindingStorageImages = 1;    // VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, runtime array
constexpr unsigned kBindingSamplers = 2;         // VK_DESCRIPTOR_TYPE_SAMPLER, runtime array
// Heap index 0 is the null texture / null sampler (is_null_texture tests
// the handle against 0). A texture handle h names sampled-heap index h (a
// view of all mip levels; also used for size queries) and storage-heap
// index h (a view of level 0); a texture written or read-write at mip level
// L uses storage-heap index h + L, so a texture with N levels that shaders
// write reserves N consecutive storage-heap indices.

// Programmable blending ([[color(n)]] fragment inputs): input attachments in
// descriptor set 1, binding n, InputAttachmentIndex n (Vulkan dynamic
// rendering local read; not update-after-bind).
constexpr unsigned kInputAttachmentSet = 1;

// Specialization constants.
constexpr unsigned kSpecWorkgroupX = 0, kSpecWorkgroupY = 1, kSpecWorkgroupZ = 2;
constexpr unsigned kSpecThreadgroupBytes = 3;    // total threadgroup memory in bytes (multiple of 16)
constexpr unsigned kSpecRasterSampleCount = 4;   // get_num_samples() in fragment functions (default 1)
constexpr unsigned kSpecThreadgroupSlot0 = 100;  // + n: byte offset of [[threadgroup(n)]]
constexpr unsigned kSpecFunctionConstant0 = 1u << 20;  // + index * 8 + component; + index * 8 + 7: "defined"

}  // namespace airc::abi
