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

## 4. Research results (8a-r done, 2026-10-12)

- `metal-sim-protocol.md` (R7): three sim2host XPC connections per process
  (`!CPX`); host-owned textures and private buffers, guest-shared buffers;
  shaders arrive once per function at pipeline creation as single-function
  AIR metallibs; keyed pipeline descriptors; segmented command buffers
  (~70 record types); completion events 100 (scheduled) and 101
  (completed); IOSurface textures by IOSurface.Remote port; **backboardd
  presents after event 100, so the host must not send 100 until the
  frame's pixels are in the surface**; the minimal home-screen set (§ "Minimal set").
- `metal-shaders.md` (R8): metallib/AIR formats; 97 intrinsic families for
  the home-screen set; translation = LLVM bitcode reader + our own SPIR-V
  emitter in a separate process, SPIRV-Tools validation, cache by `HASH`;
  bindless descriptor heap + buffer device addresses; a working PoC on the
  Thor (compute and render, correct output, ~18 ms per function). The Thor
  has LLVM 18 dev, SPIRV-Tools, glslang, Vulkan 1.4 (no
  `storageInputOutput16`, no tile image).

## 5. Implementation phase 8a-i (pinned 2026-10-12)

### 5.1 Exit criterion

On the Thor, release build, `ycode-simd --device D --runtime-paths
--timeout-ms 240000 --screenshot home.png --screenshot-at 200` (no debug
flags): backboardd composites through Ycode's Metal host service on the
Thor's GPU, and `home.png` shows the SpringBoard home screen (wallpaper and
icons), comparable to a Mac `simctl io screenshot` of the same device type.
Then the probe app launched with `--launch dev.ycode.probe` shows its UI
in a second capture.

### 5.2 Modules and owners

| Owner | Module | Contents |
|---|---|---|
| **MT** | `Sources/YcodeMetalHost/` (Swift; deps YcodeXPC, YcodeDarwinKernel) + `Tests/YcodeMetalHostTests/` | The host service: names, the three connections and handshake, object creation/release, the keyed pipeline-descriptor decoder, the command-buffer segment/record decoder into a backend-neutral command model, events 100/101 ordering, read-backs and `replaceRegion`. Talks to a `MetalBackend` (§5.3) and an `IOSurfaceResolver`. Unit tests from the spec's layouts. |
| **VK** | `Sources/CVulkan/` (C; loads `libvulkan.so.1` with `dlopen`, so macOS still builds) + `Sources/YcodeVulkan/` (Swift) + tests | `MetalBackend` on Vulkan 1.3+: device, buffers over guest-shared memory (`VK_EXT_external_memory_host`), host-owned images, IOSurface images over the surface's shared memory, bindless descriptor heap + device addresses (per `metal-shaders.md` §4), pipelines from SPIR-V, command replay, fences/timeline semaphores for events. Runs on the Thor; on other hosts reports "no GPU". |
| **SH** | `ycode/Translator/` (C++17 against LLVM 18 + SPIRV-Tools; CMake; built on Linux by `Translator/build.sh`) | `ycode-airc`: metallib function → SPIR-V + JSON reflection (stage, entry, bindings/argument table, vertex inputs, varyings by name, workgroup size), per `metal-shaders.md`. Starts from R8's PoC (`research/experiments/simulator/metal-shaders/airc/`, our own code). Coverage target: every function in QuartzCore's metallibs translates and passes `spirv-val` (runtime shaders read at test time, never copied into the repo), then the rest of the home-screen set. A persistent mode (requests over stdin/stdout) and a cache keyed by `HASH`. |
| **I3** | everything else in `ycode/` | Wiring: register the Metal names (`com.apple.metal.simulator` and the per-client names) via 701 before jobs start, start the service with the Vulkan backend, provide `IOSurfaceResolver` from its IOSurface service and the guest-memory host pointers `YcodeVulkan` imports; frame capture (`--screenshot`). Must not edit MT/VK/SH files; Package.swift entries for the new targets are added by I3 once, then left alone. |

### 5.3 Pinned interface (`YcodeMetalHost`, Swift; MT writes it first)

```
public protocol MetalBackend: AnyObject {
    var isAvailable: Bool { get }
    func limits() -> MetalLimits                         // device op 37
    func createBuffer(_ ref: UInt32, length: Int, storage: MetalStorage, guestMemory: GuestSharedRegion?) throws
    func createTexture(_ ref: UInt32, _ desc: MetalTextureDescriptor, iosurface: IOSurfaceBacking?) throws
    func createSampler(_ ref: UInt32, _ desc: MetalSamplerDescriptor) throws
    func createDepthStencilState(_ ref: UInt32, _ desc: MetalDepthStencilDescriptor) throws
    func createFunction(_ ref: UInt32, metallib: [UInt8]) throws        // translation may be lazy
    func createRenderPipeline(_ ref: UInt32, _ desc: MetalRenderPipelineDescriptor) throws
    func createComputePipeline(_ ref: UInt32, function: UInt32) throws
    func replaceRegion(texture: UInt32, _ region: MetalRegion, level: Int, slice: Int, bytes: [UInt8], bytesPerRow: Int) throws
    func getBytes(texture: UInt32, _ region: MetalRegion, level: Int, slice: Int, into: GuestSharedRegion, bytesPerRow: Int) throws
    func release(_ ref: UInt32)
    func submit(_ commandBuffer: MetalCommandBuffer, scheduled: @escaping () -> Void, completed: @escaping (_ status: Int) -> Void)
}
```

`GuestSharedRegion` gives a host pointer, length, and a stable identity for
import; `IOSurfaceBacking` gives the surface's region, width, height,
bytes per row, and pixel format. `scheduled` must be called only when the
frame's writes to IOSurface-backed attachments are complete (R7 §7). MT may
refine names and add cases; changes after VK starts go through the
orchestrator.

### 5.4 Rules

Clean room as before: levels 1–4, no disassembly, no `.claude/Xcode.app`,
no `research/dirty/`, no Ghidra; runtime shaders are input data, never
copied into the repository. Builds: macOS `--scratch-path /tmp/yc-8-<X>`;
Thor `$YCODE_DATA/work/8-<X>/`; scripts in the session
scratchpad `agent-<X>/`; SSH keys only; no sudo; no commits.

## 6. Note from R6 (`headless-rendering.md`, 2026-10-12)

Without any Metal device, backboardd's window server renders on the CPU by
itself (`CA::OGL::SWContext`, level 3 function names from a stack sample):
apps and the home-screen chrome draw correctly; the **wallpaper** (poster
extensions) and some **icons** (CoreImage in iconservicesagent) need Metal
in their own processes. So the Metal layer's first visible payoff is the
wallpaper and icons, not the compositor. With a Metal device present,
backboardd switches to its Metal path, so Ycode's service must then be
complete enough for backboardd's render records (§4). Denied Metal
look-ups are frequent (8,469 per boot): Ycode's answer must be cheap.
