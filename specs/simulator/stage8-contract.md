# Contract: simulator stage 8a — Metal for the simulator, on Vulkan

Status: **active (2026-10-12)**, research phase 8a-r. Requested by the
owner: build Ycode's Metal translation layer before taking the first
screenshot, so the screenshot shows real rendering.

## 1. Goal

In the simulator, Metal (and QuartzCore's compositing, which uses it)
runs in guest processes through the runtime's simulator Metal driver,
which sends work to a **host** service (`com.apple.metal.simulator` and
per-client names, `launchd-sim.md` §6.3). On the Mac that service runs the
work on the Mac's GPU. Ycode will implement that host service itself and
execute the work on the host GPU through **Vulkan**, translating shaders
just in time to SPIR-V.

First host: the Thor — NVIDIA Thor integrated GPU, Vulkan 1.4 (driver
580), `VK_EXT_external_memory_host` (guest-shared memory can back Vulkan
buffers and images directly), `VK_KHR_external_memory_fd`,
`VK_EXT_external_memory_dma_buf`, float16/int8, float64, subgroup size
32; `glslangValidator` and `spirv-val` installed.

Exit criterion for stage 8a (to be refined after research): backboardd
composites the SpringBoard home screen through Ycode's Metal host service
on the Thor's GPU, and `ycode-simd --screenshot` saves it as a PNG with
real pixels.

## 2. Research phase 8a-r

| Agent | Question | Output |
|---|---|---|
| **R7** | The host protocol of the simulator Metal driver: connection and naming (`com.apple.metal.simulator`, `.SpringBoard`, `.backboardd`, …), device and capability queries, resource creation and memory sharing (buffers, textures, heaps, IOSurface-backed textures, `iosurface-remote.md`), library and function creation (**what form shaders reach the host in**: source, AIR/metallib, or something else), pipeline states, the encoding of command buffers (render, compute, blit), synchronization and completion, presentation to SimFramebuffer swapchains | `specs/simulator/metal-sim-protocol.md` |
| **R8** | The shader path: the metallib container and the AIR form as file formats (level 2, reading the runtime's own `.metallib` files and our own compiled ones), the AIR intrinsics and metadata that compiled shaders use (level 4 names, level 3 our own compiled shaders), and a translation plan to SPIR-V for Vulkan on the Thor using open-source tooling (LLVM, Khronos SPIRV-LLVM-Translator, SPIRV-Tools) with license notes; the Vulkan features and limits the translation needs, checked on the Thor | `specs/simulator/metal-shaders.md` |

Rules (`CLAUDE.md` rule 4): level 1 (Apple open source, public Metal
documentation and the Metal Shading Language and metallib-related public
documents, Khronos specs), level 2 (file formats), level 3 (black-box runs
of our own programs: R7 uses the man-in-the-middle method of
`iosurface-remote.md` — a throwaway `launchd_sim` or device whose host-side
Metal names point at our own forwarding port, recording both directions —
plus our own Metal test programs), level 4 (symbol, class, selector names).
**No disassembly or decompilation** of any Apple binary; no
`.claude/Xcode.app`; no `research/dirty/`; no Ghidra. Shaders inside the
runtime are input data: Ycode translates them at run time and never
copies them into the repository.

## 3. Implementation (phase 8a-i)

Pinned after research: likely a `YcodeMetal` host service in the VMM (host
task, XPC/Mach per R7), a shader translator module (AIR → SPIR-V), a
Vulkan back end (resources over guest-shared memory, command replay,
synchronization), and presentation into the IOSurfaces that the headless
SimFramebuffer presents, captured by `--screenshot`.
