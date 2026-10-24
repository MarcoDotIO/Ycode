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

## 7. MT done (2026-10-12): the `YcodeMetalHost` API as built

Refinements of §5.3 (agreed): the backend gets host-global, never-reused
`MetalHandle`s (guest refs are per process/kind and reused; the service maps
them); `createTextureView` (device ops 7, 8, 27); `createComputePipeline`
returns `MetalComputePipelineInfo`; `replaceRegion`/`getBytes` take
`bytesPerImage`; optional, defaulted `createEvent`, `createFence`,
`signalEvent`, `eventValue`, `gpuAddress(ofBuffer:)`,
`gpuResourceID(ofSampler:)`. Resolvers for I3: `IOSurfaceResolver.
backing(forSurfacePort:plane:)` and `MetalGuestMemoryResolver.
region(forMemoryEntry:)`. Service: `MetalHostService(host:backend:memory:
surfaces:registryID:log:)`, `start()`, `servicePort`, `serviceNames`.

Backend rules: thread-safe; creation failures are logged, never reported to
the guest; unknown handles in commands are skipped; `release` may arrive
while submitted work uses the object; `getBytes` sees all earlier work;
command buffers on one queue run in order; `scheduled` only after IOSurface
writes are in surface memory (else the service sends 100 then 101 at
`completed`). **If `backend.isAvailable` is false, Ycode registers no
Metal names** (backboardd then renders on the CPU, R6).

Coverage: every record of the minimal home-screen set plus most others
(render 0–130 subset, compute 200–215 subset, blit 300–318 subset, events
400/401); unknown records become `.unknown` and never crash. 25 tests.

## 8. Milestone 8a-T: hello triangle (owner request, 2026-10-12)

Before the home screen: our own guest program draws the classic hello
triangle with Metal inside a Ycode device on the Thor, through
`YcodeMetalHost` → `YcodeVulkan` → `ycode-airc` on the Thor's GPU.

- **Probe** `p_metal_triangle` (our own code, owned by VK, in
  `ycode/SimShim/guest-tests/stage8/`, built on macOS like the other
  probes): a command-line tool (no UIKit, no display services) that gets
  `MTLCreateSystemDefaultDevice`, loads a **precompiled** metallib bundled
  next to it (`newLibraryWithURL:`, so the guest's shader compiler service
  is not needed), draws one triangle with per-vertex red/green/blue into a
  512×512 BGRA8 texture cleared to a dark background, reads it back with
  `getBytes`, writes it as a PNG (or raw + header) under `/tmp`, and prints
  `triangle ok` plus the device name and a few sampled pixels.
- **Run:** `ycode-simd --device D --oneshot "<path>/p_metal_triangle"`
  (with the runtime's job set or a minimal one; the Metal names must be
  registered — I3's wiring) on the Thor, release build.
- **Done when** the PNG shows the triangle with correct colors and
  orientation (compared with the same probe run under CoreSimulator on the
  Mac), and the orchestrator sends it to the owner.

## 9. SH done, first round (2026-10-12): `ycode-airc`

`ycode/Translator/` (C++17, LLVM 18, SPIRV-Tools; built on Linux). CLI:
`version | list | decls | translate | serve | corpus`; `serve` speaks
little-endian frames (u32 length, u32 JSON-header length, JSON header,
payload) with requests `translate | ping | version | shutdown`, runs each
translation in a forked child (a crash or timeout becomes an `internal`
error), and caches by SHA-256 of the module plus options. The binding ABI
(push constants, the 192-entry argument table, bindless set 0, input
attachments in set 1, specialization-constant ids) is Ycode's own design
and lives in `Translator/src/abi.h` (version 1); the reflection JSON schema
is documented at the top of `Translator/src/translate.cpp` and in SH's
report. Coverage: QuartzCore 226/228 (2 kernels call `discard_fragment`),
MTLSimDriver 12/12, IconRendering 14/14, RenderBox 68/109, CoreMaterial3D
81/191 (external `cm3d_*` calls), the whole runtime 80 %; our own corpus
26/26 GPU tests match the Metal oracle. Driver quirks handled: signed
remainder, f32→f16→f32 folding. **Next for VK:** QuartzCore's uber-shaders
take ~6 s to create as Vulkan pipelines cold — asynchronous pipeline
creation and a persistent pipeline cache are required.

## 10. Checkpoint (agent G, 2026-10-13): backboardd composites through Metal

On the Thor (patched kernel, release, `--gpu-cache-dir`), backboardd takes
its Metal path. It wraps the three LCD IOSurfaces and composites through
`YcodeMetalHost` → `YcodeVulkan`. Over 11,197 command buffers in 325 s there
were 0 translation failures, unknown records, refusals, backend errors or
Vulkan errors. The boot UI needs only 3–4 Core Animation pipelines. The
worst one takes 5.4 s to compile cold and 4.3 ms with the persistent cache.
Captures match the CPU path pixel for pixel (logo: 0 of 3,162,132 pixels
differ). A Core Animation probe of ours,
`research/experiments/simulator/metal-ca/p_ca_render.m` (public
`CARenderer` into an `MTLTexture`; 16 features: gradients, shadows, masks,
text, perspective, replicator…), matches a real iOS 27.1 simulator within 3
levels in 15 of 16 cells. The 16th is nearest-filter texel ties, where the
two GPUs round differently. `YCODE_METAL_STATS=<s>` prints per-client and
backend statistics. The home screen is still gated by SpringBoard (I4).
Next for G: backdrop blur, filters and materials; RenderBox,
CoreMaterial3D and CoreImage coverage for posters and icons; the per-frame
full-surface copy cost.

## 11. Checkpoint (integrator H, 2026-10-13): real icons through Metal

The home screen shows the real Settings and Safari icons, drawn by
iconservicesagent (IconRendering → RenderBox → Metal) through
`YcodeMetalHost` → `YcodeVulkan` on the Thor's GPU
(`9-H/runs/p1a/shots/home-540s.png`). What it took (`home-screen.md` §2,
§4): coherent `MAP_SHARED` file mappings (iconservicesagent's icon store;
its "status 70" crash loop), a device-capabilities plist for MobileGestalt
(`device-capabilities.md`; the display is now 1398 × 2034, the iPhone19,4
geometry), the draw records 2, 4, 8, 28 and op 9's packed instance count
and base vertex (`metal-sim-protocol.md` §8.3; misread, they made the GPU
run one draw for minutes until the driver reported Xid 109 and every
client's Metal was lost), a guard that skips draws of more than 2^26
vertices × instances, and event waits held on the host per Metal queue
instead of a Vulkan semaphore wait on the one shared queue. Icons appear
4–9 minutes into a boot: RenderBox compiles its shaders at run time in the
guest's MTLCompilerService. The wallpaper is still black: PosterBoard's
ExtensionKit query finds no poster extensions because every LaunchServices
record of this device lacks its platform and extension point
(`home-screen.md` §3.2, open).

## 12. Host exit: the GPU back end ends in order (agent SVC4, 2026-10-17)

**Observed (level 3, Thor runs).** Two of eight 700 s boots of the
integrated build ended with status 139 *after* the run summary
(`IA2/tb/d0`; the earlier `IB2I/v2r1` crash was a different one, in
`Process.run` while a shader translator started). `ycode-simd` called
`exit()` while the back end's completion thread was still waiting in
the driver for a timeline value. `exit()` runs the NVIDIA driver's own
teardown (its `atexit` handlers); the waiting thread then got
`VK_ERROR_DEVICE_LOST` ("waiting for serial 421 failed (-4): device
lost") and faulted inside `libnvidia-eglcore` (SIGSEGV). Nothing called
the back end's `shutdown()`: a process that ends with `exit()` runs no
Swift deinitializers.

**Rule.** No back-end thread may be inside the GPU driver when the host
process calls `exit()`. Before the run summary returns, the host ends the
Metal service and its back end in this order:

1. The Metal host service stops receiving and waits for its receive
   thread (it receives with a 200 ms timeout).
2. Each connection's serial queue finishes the request it runs; the wait
   for steps 1–2 is at most 10 s in all (`MetalHostService.shutdown
   (drainTimeout:)`; a busy connection is logged and the back end is shut
   down anyway).
3. The back end (`MetalBackend.shutdown()`, idempotent; a back end with
   nothing to end keeps the protocol's empty default):
   - finishes the pipeline compiles and saves the pipeline cache;
   - stops accepting work; the held-work thread completes what it still
     holds (events that never came) with status error (5) and ends;
   - the completion thread completes the submitted work as the GPU
     finishes it and ends after the held-work thread;
   - work the GPU has not finished `shutdownGrace` seconds (default 10)
     after the call is **abandoned**: the completion thread stops waiting
     (it waits in steps of 1 s), completes it with status error, and frees
     neither its memory nor objects that wait for it; the device is then
     not destroyed either (freeing what the GPU may still use is undefined
     behaviour) and is left to the driver's exit teardown, with no
     back-end thread inside the driver;
   - otherwise: `vkDeviceWaitIdle`, every object destroyed, the device and
     instance destroyed.
4. `ycode-simd` prints "Metal host service: shut down in N ms", then the
   other services stop and the process exits.

Paths that end with `_exit()` (snapshot capture) or a signal skip the
driver's teardown and need none of this.

**Tests.** `MachServiceTests.shutdownStopsTheServiceBeforeTheBackend`
(no GPU: the receive thread has ended when the back end's `shutdown` runs;
a second call does nothing). `VulkanBackendTests.shutdownEndsTheBackendThreads`
(GPU: finished work completes with 4, held work with 5, both threads end,
nothing abandoned, a second call returns at once).

Evidence: level 3 (Thor runs `IA2/tb/d0`, `IB2I/v2r1`: backtraces of the
host process, exit status); Vulkan 1.3 specification (level 1: objects in
use by pending command buffers must not be destroyed; `vkDeviceWaitIdle`);
Ycode design.

## 13. The GPU side of a boot and of a frame (agent SP-GPU, 2026-10-19)

Question: how much of a full boot (`YCODE_LEAN_BOOT` unset, about
200–250 s on the Thor today) and of a home-screen frame is spent on the
GPU side (shader translation, Vulkan pipeline builds, command recording,
IOSurface copies), and does the headless framebuffer let `backboardd`
render at full rate for nobody?

### 13.1 Measurements (Thor, harness boots, device in RAM, load average 15–36)

New counters in the `YCODE_METAL_STATS=<s>` backend line (diagnostics,
nothing changes otherwise): translator calls (calls answered by the back
end's in-memory cache counted apart), whole-pipeline compiles, compute
variants, submissions that waited more than 1 ms for a pipeline, CPU time
spent recording command buffers under the back-end lock, IOSurface bytes
copied in and out, and a histogram of command-buffer latency (queue to
completion). A sampler outside the VMM read the headless framebuffer's
frame record (`simframebuffer.c`, `frame <n>`) once per second.

| What | Warm caches (5 boots) | Cold caches (2 boots: empty `--gpu-cache-dir` and empty driver cache) |
|---|---|---|
| Metal command buffers per boot | 160–260 | same |
| translator calls | 48–56, 0.18–1.9 s in all (most are `ycode-airc` disk-cache hits) | 54–58, 1.3–1.6 s |
| pipelines linked (graphics pipeline libraries) | 36–45, 18–230 ms in all | 40–45, 10.5–12.4 s: one Core Animation uber-pipeline (`PBGRA_Xgc`) alone 9.5–11.4 s |
| submissions that waited for a pipeline | 0–1, at most 0.29 s (0.15 s with the translators started early, §13.2) | 4, the first frame waits 9.4–11.6 s |
| recording CPU per command buffer | 0.6–0.8 ms | same |
| command-buffer latency | 2.0 ms mean, 11.8 ms max | same |
| frames swapped before the home screen | 3–6 in the first 230 s, 50–60 when the wallpaper arrives | same |
| home_s | n1–n3 245/230/240 | 240/230 |

1. **The GPU is not on the boot's critical path.** With warm caches it
   costs under 2 s of CPU spread over the boot and at most one wait of
   0.15–0.3 s. With cold caches the first frame (the boot logo) comes about
   10 s later, but the home screen does not (240/230 s against 230–255 s):
   it is gated by process starts (`boot-profile.md`).
2. **No full-rate rendering for nobody.** The headless library completes
   each swap at once, yet `backboardd` swapped 3–6 frames in the first
   230 s of a boot and about one frame per 30 s on the idle home screen
   (80 frames in a 440 s run). Core Animation submits only on content
   change (`headless-rendering.md` §2 item 6), so viewer-driven pacing
   has nothing to throttle. The hypothesis is rejected; no pacing was
   built, and the reference simulator's pacing was not measured (it
   cannot change this result).
3. **Frames are not GPU-bound.** Settings launched at the home screen
   (`--launch com.apple.Preferences`): 543 command buffers, latency 3.1 ms
   mean (70 % under 4 ms, 99 % under 8 ms, max 27.6 ms), recording 1.7 ms
   mean of host CPU, about 20 MB of IOSurface copies per frame inside that
   latency. The screen changed at about 1.8 frames per second for 110 s:
   the rate is set by guest CPU work, not by the GPU path. Rendering
   directly into the surface memory (a linear image with an explicit row
   pitch over the imported memory, `VK_EXT_image_drm_format_modifier`,
   which the Thor has) would remove the copies but cannot raise this rate;
   it is not built.
4. **Paired, merged main line 34e5bb1 against this branch (same machine,
   alternating rounds):** base 255/225/235 (mean 238), SP-GPU 245/230/240
   (mean 238). Equal within noise, as item 1 predicts.

### 13.2 Changes

| Change | Switch | Why |
|---|---|---|
| A device boot keeps its GPU caches by default in `${XDG_CACHE_HOME:-~/.cache}/ycode/gpu` | `--gpu-cache-dir <dir>` (other place), `--no-gpu-cache`; the variables `YCODE_VULKAN_PIPELINE_CACHE` / `YCODE_AIRC_CACHE`, when set, win | Without `--gpu-cache-dir` every boot compiled the uber-pipeline again (8.5 s measured with the driver's own disk cache warm: that cache does not cover it); the reference simulator keeps its shader caches across boots. Checked: first boot 0 bytes loaded and 8.5 s compile, second boot 355,583 bytes loaded and no compile over 1 s. Concurrent processes are safe: every cache file is written to a temporary name and renamed. |
| `ycode-airc` cache keys include the translator build (version, size and modification time of the executable) | — | The key held only the version string `0.1`, so a rebuilt translator read translations made by an earlier build. The first boot after a translator change now translates again (about 1–2 s, §13.1). |
| The translator processes start with `posix_spawn` (closing every other descriptor in the child) instead of Foundation's `Process`, one start at a time | — | `Process.run` scans `/proc/self/fd` in the parent; while four translators started at once and the VMM opened and closed descriptors, that scan crashed the host once (`IB2I/v2r1`, `findMaximumOpenFromProcSelfFD`). Writes to a dead translator give `EPIPE`, never `SIGPIPE`. |
| The translator processes start in the background when the back end starts | `YCODE_AIRC_PRESTART=0`: at the first request | The first pipeline waited 0.29 s for the translator to load. |
| GPU-hang reports (`serial … still running after N s`) name the first four dispatches: grid, threadgroup size, and every bound buffer's length (the bytes of buffers of at most 64 bytes) | — | For §13.3. |

### 13.3 The `astc` kernel that runs for minutes (found and fixed: §13.5)

In 18 of 315 archived harness boots (2026-10-16…18) one command buffer
ran 10–426 s; 14 of them ended with `VK_ERROR_DEVICE_LOST`, after which
every client's Metal work fails, and while it runs the single queue
completes nothing for any client. Every time it was command buffer 2 of
`WeatherPoster` (later killed by its host, status 137), and the only
shader was the guest driver's ASTC decoder kernel `astc`
(hash 944ee7b6…, an `air64-apple-ios13.0.0-simulator` build; not the one
in `MTLSimDriver.framework/default.metallib`). Its reflection: four
buffers (`input`, `partitionTables`, a 56-byte `parameters` structure,
`zeroPartitionTables`), one written texture, the exact-grid guard on, no
barriers, so threads outside the grid do not run. It did not occur in
this agent's 11 boots. The next occurrence prints the dispatch and the
parameter bytes (§13.2), which tells a huge grid or garbage parameters
from a loop that never ends. A generic mitigation, if needed: an
iteration cap on loop back-edges in translated kernels (the translator
already restructures loops in `prepare.cpp`), and one Vulkan queue per
client so that one client's hang does not stall the others.

### 13.4 Next on the GPU side, by value

1. A cold first boot shows its first frame about 10 s late (one
   uber-pipeline). Building the fragment-shader library part first with
   `VK_PIPELINE_CREATE_DISABLE_OPTIMIZATION_BIT` and replacing it with the
   optimized build in the background would hide most of it; it matters
   only once process starts no longer dominate.
2. ~~§13.3~~ done (§13.5); one Vulkan queue per client is still open
   (§13.5.4).

Evidence: level 3 (Thor runs `SX/SPGPU/runs/{p1,w0,n1–n3,f1,d1,d2}`,
`SX/SPGPU/base/runs/b1–b3`, `SX/SPGPU/cold{1,2}/runs/c`; archived logs
of other agents' runs for §13.3; the `astc` reflection is `ycode-airc`'s
own output metadata, no shader was disassembled); level 1 (Vulkan
specification and extension texts: pipeline caches,
`VK_EXT_external_memory_host`, `VK_EXT_image_drm_format_modifier`,
`VK_PIPELINE_CREATE_DISABLE_OPTIMIZATION_BIT`; posix_spawn(3),
`posix_spawn_file_actions_addclosefrom_np` in glibc 2.34+).

### 13.5 The `astc` hang: a subgroup stuck in out-of-line helpers (agent SP-ASTC, 2026-10-19)

#### 13.5.1 Reproduction outside a boot

`KernelHangProbeTests` (opt-in, `ycode/Tests/YcodeVulkanTests`) runs one
translated kernel through `VulkanMetalBackend` on random inputs with an
8 s limit per dispatch, saves the inputs of a dispatch that does not
finish, and replays them with chosen blocks kept and placed at chosen
thread positions. The kernel was `ycode-airc`'s own SPIR-V of
944ee7b6 (the one GPU-cache entry every harness tree used: it was made
on 2026-10-13, and before e57bc14 the cache key did not change with the
translator build) and, for experiments that need retranslation, the
runtime's `astc` (571cccc2, `MTLSimDriver.framework/default.metallib`,
same reflection with a `constant` parameter buffer). Inputs: 64 × 64
random 16-byte blocks, byte tables of random partition indices, block
sizes 4–12, the parameter words the kernel's reflection and SPIR-V read
(offsets 8, 36, 40, 44, 48, 52).

| Experiment (kernel 944ee7b6 unless named) | Result |
|---|---|
| first random dispatch | does not finish |
| bisection of the 4096 blocks (others zeroed) | blocks 0 and 1 together do not finish; each alone finishes in 15 ms |
| the two blocks in threads 0 and 1, 0 and 2, 0 and 8 of one 8 × 8 threadgroup (one 32-lane subgroup) | does not finish |
| the same blocks in threads 0 and 32 (same threadgroup, other subgroup) or in other threadgroups | finishes in 15–18 ms |
| private arena zero-initialized; arena 8 × larger | does not finish (not uninitialized or out-of-range private memory) |
| loop guard with a limit of 1000 loop-header passes per invocation (571cccc2) | does not finish: no loop is iterating, the subgroup is stopped |
| 571cccc2 translated by today's translator | does not finish (not the 2026-10-13 build) |
| 571cccc2 with both helpers inlined (`AIRC_INLINE_ALL`), or the helpers' function control `None` or `Inline` instead of `DontInline`, or `--opt` (spirv-opt inlines) | finishes in about 1 s (pipeline creation included) |
| only one of the two helpers inlined | does not finish |

So the hang needs two lanes of one subgroup on different paths, each
reaching one of the kernel's two helpers, which `ycode-airc` keeps out of
line as `DontInline` SPIR-V functions (since 906c290, for driver compile
time). The Thor's driver compiles `DontInline` functions as real calls;
with lanes of one subgroup inside them on different paths the subgroup
never continues. Whether that is a driver defect or a convergence rule
the driver applies to calls, our side must not create the situation.
Why it was rare in boots: the kernel runs only when `WeatherPoster`
decodes ASTC data (it did not run at all in SP-GPU's 11 boots or in the
16 boots of §13.5.4: no translation of it was stored), and only blocks of
different kinds in one subgroup trigger it.

#### 13.5.2 Fix: helpers called under divergent control flow are inlined

`prepare.cpp`, after the per-function clean-up, runs a conservative
divergence analysis on the entry function and on every helper kept out
of line, and inlines every helper that some call reaches under divergent
control flow (then cleans the callers up again and repeats). Divergent
values: the entry function's non-pointer arguments (thread positions,
stage inputs), every helper argument, loads from private, threadgroup or
imageblock memory, atomics, calls that read memory or depend on the lane
(names with `simd`, `quad`, `thread`, `get_`, …), and everything computed
from those. A conditional branch or switch on a divergent value makes
every block reachable from it before its immediate post-dominator
divergent (this includes the body of a loop with a divergent exit), and
phis there or at that post-dominator divergent. The grid guard's branch
(`airc.grid_oob`) does not count: lanes outside the grid return and call
nothing. A helper called only in uniform control flow stays out of line,
which keeps the compile-time gain where it is safe.
`AIRC_OUTLINE_DIVERGENT=1` restores the old policy for experiments.

Results: the probe with today's translation of 571cccc2 (both helpers
now inlined) ran 180 random dispatches of 4096 blocks (seeds 1–3, 60
each) with the slowest at 22 ms; the saved two-block case finishes.
Runtime corpora translate as before (QuartzCore 228/228, MTLSimDriver
12/12, IconRendering 14/14, RenderBox 68/109, CoreMaterial3D 81/191,
CoreUI 3/17, the same as aa1bf7c). Of the 53 translations of a boot,
3 change: `Xgc` (one of 26 helpers inlined, 79,223 → 79,869 words),
`glass_background_sdf_cr_lpf` (two helpers inlined) and `SiriBlur`
(instruction order only). Cold pipeline creation (`airc-gpu --compile`,
`__GL_SHADER_DISK_CACHE=0`, 3 alternating runs each): the `PBGRA_Xgc`
uber-pipeline 5.58 s before, 5.53 s after; the glass pipeline 99 ms
before, 159 ms after. Warm boots read both from the pipeline cache.

#### 13.5.3 Containment: the loop guard

Independent of the cause, a kernel whose loop never ends would hold the
single queue the same way. `ycode-airc --loop-limit N` (serve request
`"loop_limit"`) guards every loop whose trip count scalar evolution
cannot bound by a constant: at each guarded loop header the invocation
counts one pass in a private counter; past N passes in all (over every
loop of every function) the header leaves the loop through an exit
block, with zero for the values the exit's phis would take from inside
the loop. After the budget is spent, every loop ends at its next header,
so an invocation finishes along an acyclic path. The reflection reports
`"loop_limit": N`; the cache key includes N. The host sends 2^20
(`YCODE_GPU_LOOP_LIMIT` overrides, `0` turns it off). No boot shader
has a loop without a constant bound today (none of the 53 boot
translations is guarded), so a normal boot runs the same shaders as
before. Checked on the GPU (`LoopGuardGPUTests`: a loop that waits for a
value that never comes ends with the limit, and without the guard the
same kernel does not finish in 5 s) and by `tests/ir/control-flow.sh`.
The guard does not contain the hang of §13.5.1 (no loop runs there);
§13.5.2 removes that one.

#### 13.5.4 Boots and what is left

Paired boots on the Thor (full boot, device in RAM, the two trees
booting at the same time, load average 27–60 from other agents' work):

| | aa1bf7c (`SX/IDE`) | this branch |
|---|---|---|
| warm pairs 1–6, home_s | 135, 145, 120, 190, 190, 230 (mean 168) | 110, 190, 130, 205, 165, 190 (mean 165) |
| cold pair (empty GPU caches and driver cache), home_s | 155 | 155 |
| cold pair, `PBGRA_Xgc` compile in the boot | 9.27 s | 11.78 s (offline the same, §13.5.2: load) |
| GPU-hang reports | 0 | 0 |

Equal within noise. The `astc` kernel ran in none of these boots, so they
show only that the change costs nothing; the probe shows the fix. The
warm-up boot `sp-astc-0` (not counted) ended in a host crash in
`DarwinKernel.threadGetState` (kernel IPC, not touched here); the
baseline run `SX/IDE/runs/sp-port-base-1` has the same crash.

Not built: one Vulkan queue per client. The back end numbers every
submission on one timeline and relies on one queue's order for
resources that several clients share (IOSurfaces of `backboardd` and
apps); per-client queues need cross-queue synchronization for those, a
larger change than this agent's. A stuck dispatch also cannot be
cancelled in Vulkan: recovery means a new device and every object
created again (after `VK_ERROR_DEVICE_LOST` today every client's Metal
work fails until the host restarts). Both stay open; with §13.5.2 and
§13.5.3 no known shader needs them.

Evidence: level 3 (Thor: `KernelHangProbeTests` and `LoopGuardGPUTests`
runs over `ycode-airc`'s own SPIR-V; boots `SX/SPASTC/runs/sp-astc-0–6`
against `SX/IDE/runs/sp-astc-base-0–6`, cold boots
`SX/SPASTC/cold{A,B}/runs`; corpus runs of `ycode-airc` over the
runtime's metallibs as input data; `airc-gpu --compile` timings). The
kernel was studied only through our translator's output and reflection
and through its behaviour on random inputs; no Apple binary or shader
bitcode was disassembled. Level 1: SPIR-V specification (structured
control flow, function control, `Private` variable initializers), LLVM
documentation (ScalarEvolution, LCSSA, InlineFunction).

## 14. The GPU side of a frame: copies, completion, scheduling (agent FPS-GPU, 2026-10-20)

Question (from `frame-profile.md` §7 item 2): after the guest-CPU changes
of FPS-PROF, waits for the Metal host service and for GPU completion are
the largest non-idle step of an animation frame. What do they consist of,
and what can the back end remove without changing what the guest sees?

### 14.1 Instruments (diagnostics; nothing changes without them)

`YCODE_METAL_TRACE=<file>` writes one line per Metal command buffer to
`<file>`, space-separated, `-` for a value that is absent:

| Field | Meaning |
|---|---|
| `pid`, `cbref` | the client and its command-buffer reference |
| `recv_ns`, `enter_ns`, `pipelines_ns`, `locked_ns`, `submitted_ns` | host `CLOCK_MONOTONIC`: the service received the request; the back end's `submit` began; its pipelines were ready; the back-end lock was taken; the recording was submitted to the queue (or held, §14.2 item 4) |
| `gpu_begin_ns`, `gpu_end_ns` | GPU timestamps (top and bottom of the command buffer) in the GPU's own clock: only their difference is meaningful |
| `done_ns`, `handlers_ns` | host: the completion thread saw the serial; the completion handlers had run |
| `draws`, `dispatches`, `blits`, `passes` | work in the command buffer |
| `bytes_in`, `bytes_out` | IOSurface bytes copied in before the work and back after it |
| `held` | 1: the command buffer waited on the host for an event |
| `surfaces_in`, `surfaces_out` | comma-separated IOSurface IDs copied in and written |

`<file>.ops` gets one line per Metal service request: connection,
message type, device-operation record (12) or −1, whether a reply was
sent, and the host monotonic ns when the receive thread got it, when its
connection queue started it, and when it was done. The
`YCODE_METAL_STATS=<s>` backend line adds: copy-ins skipped, the bytes
whole-surface copy-outs would have moved, completion waits that timed out
although the GPU had reached the value ("late wake-ups"), command buffers
reported scheduled at submission, and CPU waits for pending GPU writes to
a surface. `YCODE_GPU_DAMAGE_LOG=<n>` logs the first n render-pass writes
to IOSurfaces with the area that is copied back.

### 14.2 Changes

| # | Change | Switch (default on) |
|---|---|---|
| 1 | **Copy-in skipped** while the Vulkan image already holds the surface's pixels (rules in §14.3) | `YCODE_GPU_SURFACE_SKIP_IN=0` |
| 2 | **Copy-back limited to what was drawn**: for a color, depth or stencil attachment of level 0, slice 0 with load action *load*, only the union of the scissor rectangles in force at each draw of the pass (a pass starts with the whole target as its scissor). Clears and don't-care loads, other levels and slices, resolve targets, shader writes and blits copy the whole surface | `YCODE_GPU_SURFACE_DAMAGE=0` |
| 3 | **Completion polled in short slices**: the completion thread waits for the timeline semaphore 1 ms at a time and reads its counter after each slice | `YCODE_GPU_COMPLETION_POLL_US=<µs>` (minimum 50; 1000000 restores one blocking wait per second) |
| 4 | **`scheduled` at queue submission**: a command buffer's scheduled handler runs once its recording is on the Vulkan queue behind every earlier submission (Metal's meaning of scheduled), not at completion. Held work (event waits, VulkanEventWaits.swift) reports it when it is submitted. Scheduled handlers run in submission order, outside the back-end lock, and always before the same command buffer's completion handler | `YCODE_GPU_EARLY_SCHEDULED=0` |
| 5 | **CPU access to a surface waits for pending GPU writes** (needed by 4): the IOSurface service calls the back end's wait before a guest lock without `kIOSurfaceLockAvoidSync` (read-only locks included) and before a host read (`surface(id:)` for the display server, `snapshot(surfaceID:)` for screenshots). The wait is for the last submitted serial that copies back to that surface, at most 0.5 s, never under the IOSurface service's lock | with 4 |
| 6 | **A pool of translator processes for `--metal-translator`** (the path the launcher uses), started when the back end starts | `YCODE_AIRC_PROCESSES=<n>` (default 4), `YCODE_AIRC_PRESTART=0` |
| 7 | **A stuck GPU costs one timeout**: when a wait of change 5 times out and the timeline counter has not moved, later waits take only a 5 ms look until the counter moves again (a submission that never completes, `app-launch.md` §3.7, would otherwise cost 0.5 s per lock and per display read) | with 4 |

Why 3: on the Thor a blocking `vkWaitSemaphores` sometimes returned long
after the value was reached; the counter read after a timed-out slice
finds it (about 100–200 "late wake-ups" per 1,300–1,700 command buffers
in a session). Why 4: with scheduled at completion, every scheduled handler reached the
guest only after the GPU had finished the work, so anything the guest
does on scheduled waited for the GPU as well.
Why 6: one translator process serialized every translation; at a restore
or an app's first frames the render server's command buffers waited for
their pipelines behind unrelated translations.

### 14.3 Rules that keep old pixels out (change 1)

An IOSurface-backed image is *in sync* when all of these hold; otherwise
it is copied in before a command buffer reads it:

1. It was copied in or copied back at least once, and the surface's
   generation (a counter per surface plane: surface ID and byte offset)
   is the one recorded then. The generation is raised by every copy-back
   of any image of that plane, by a host write (`replaceRegion` of an
   IOSurface texture), and once more when held work that copies back is
   submitted (its copy-back was recorded earlier than it runs, so images
   that copied the surface in meanwhile no longer match it).
2. The surface's seed equals the seed recorded then. The IOSurface
   service raises the seed at every lock for writing (`iosurface-remote.md`
   §3), so a CPU write under a lock always causes a copy-in.
3. No lock of the surface is held now (a CPU writer may be in the middle
   of its write), and the surface still exists (its seed can be read).

Change 2 relies on change 1's invariant: a pass that loads its target
reads it, so the image matches the surface before the pass, and outside
the drawn area it still matches after it.

Not covered (the guest's contract): a CPU write without a lock, or under
a read-only lock, after the surface was copied in, is not seen by the
GPU until something else raises the generation or seed. Test
`ioSurfaceCopiesOnlyWhatChanged` states this behaviour; the switch turns
the skipping off if a client turns out to depend on unlocked writes.

### 14.4 Review of the ordering (no deadlock)

- Lock order: back-end lock → IOSurface service lock (the seed is read
  while recording). The reverse never happens: the IOSurface service
  calls the GPU-write wait before it takes its own lock, and the wait
  takes the back-end lock only to read the serial, not while waiting.
- The scheduled-handler lock is taken before the back-end lock, never
  under it. The completion thread, before running completion handlers,
  takes it also when another thread is still running a list of scheduled
  handlers it took (`scheduledFlushRunning`), so a completion handler
  never runs before the same command buffer's scheduled handler.
- The GPU-write wait is bounded (0.5 s; 5 ms while the GPU makes no
  progress, change 7) and waits only for work already
  on the queue; held work is not on the queue (it has no serial yet), so
  a guest thread that holds an IOSurface lock and must signal an event
  for held work cannot be waited for. A kernel that never ends would be
  waited for 0.5 s per lock, and the loop guard of §13.5.3 bounds every
  loop; the subgroup case of §13.5.1 is removed by §13.5.2.
- The waits run on host threads (the IOSurface service's receive thread,
  the display server's threads); no kernel lock of the VMM is held there
  (the guest thread is blocked in its `mach_msg` waiting for the reply).

### 14.5 Measurements

Thor, paired and serialized (`SX/FPSGPU/abmeas.sh`): this branch
(main line 391af58 + §14.2) against 391af58 built in a separate tree, the
same translator binary and a copy of the same GPU cache, each arm with
its own device and snapshot. Per round, one restored session per arm
(the frame-profile window of `frame-profile.md` §3 over a 33 s probe:
home-screen swipes, Spotlight, a tap on the dock, vertical swipes, home)
and one full cold boot per arm (pristine device in RAM, home_s by
screenshot every 5 s); arm order alternates; each step starts only when
the host load average is below 4 and no other run of ours is up; boot
slots 2–4 held.

| Round (load at the probe: branch / base) | swipe present interval p50 / p90 ms | window interval p50 / p90 ms | GPU completion wait on the critical path, ms per frame | IOSurface bytes copied per present | cold boot home_s |
|---|---|---|---|---|---|
| R1 (3.1 / 4.8) | 15.9 / 46.6 vs 15.8 / 20.6 | 13.1 / 29.0 vs 16.3 / 36.0 | 4.30 vs 4.79 | 12.5 MB vs 32.5 MB | 75 vs 105 |
| R2 (3.9 / 0.6) | 16.5 / 18.0 vs 16.6 / 18.0 | 15.9 / 37.0 vs 16.3 / 35.9 | 3.82 vs 4.72 | 11.5 MB vs 38.4 MB | 85 vs 70 |
| R3 (5.4 / 2.8) | 16.6 / 18.4 vs 11.0 / 18.0 | 15.0 / 24.2 vs 15.9 / 37.0 | 4.05 vs 4.52 | 12.7 MB vs 34.6 MB | 70 vs 70 |
| R4 (2.9 / 2.5) | 18.0 / 1541 vs 16.3 / 18.1 (see below) | 14.6 / 33.4 vs 16.0 / 35.1 | 4.03 vs 4.81 | 11.1 MB vs 38.4 MB | 70 vs 70 |

The "GPU completion wait" is the sum of the critical-path steps "host
thread: DispatchWorker (woke backboardd …)" and "host thread: ycode-simd
(woke backboardd …)" (`frame-profile.md` §2 item 7). Bytes per present:
the `YCODE_METAL_STATS` counters over the window divided by its presents.

1. **Bytes copied fall by about 65 % in every round** (11–13 MB against
   32–38 MB per present). Almost all of it is change 1: per session
   0.26 GB copied in against 21 GB on the base (1,800–3,100 copy-ins
   skipped per session). Change 2 saves under 1 % (13.0 GB copied back against 13.1
   GB for whole surfaces): the render server's passes draw across the
   whole surface. It stays (it is correct and costs nothing) but it is
   not where the gain is.
2. **GPU completion wait per frame falls by 10–21 %** (3.8–4.3 against
   4.5–4.8 ms), in all four rounds. Queue-to-completion latency: 28 % of
   command buffers under 1 ms against 14 % (R1). Changes 3 and 4 also
   show as 93–193 "late wake-ups" per session (completions the old
   blocking wait would have reported later).
3. **Swipe cadence is unchanged**: the present interval p50 during
   swipes is 16–18 ms in both arms, the 60 Hz frame clock
   (`display-stream.md` §10); the GPU path is no longer what limits it.
   R4's branch session is an outlier: the first swipes drew nothing for
   1.6 s, and the critical path of that gap is 0.54 s of `backboardd`'s
   own guest code (57 steps), not a GPU wait (surface-write waits in
   that session: 144, at most 15 ms). Window p50 is lower on the branch
   in all rounds (13–16 against 16 ms).
4. **Cold boot is unchanged** within the 5 s resolution (70–85 against
   70–105; the GPU is not on the boot's critical path, §13.1 item 1).
   A restore reached the home screen in 8.0–9.4 s against 8.8–10.1 s.
5. **Correctness**: in every session (4 measured + 3 checks per arm)
   screenshots of the home screen, Settings (opened and scrolled), the
   home screen again and the Today view were taken outside the window;
   pixel differences against the base arm's screenshots were only the
   clock and an animated spinner (131–381 pixels of 2.8 M, inside those
   areas): no stale tiles or torn regions. Every session after the first
   restored the arm's snapshot and saved it again. The swipe from the
   Today view back to the home page does not move in either arm (open
   item 4). Safari with a `data:` URL draws the page (§14.6 item 5).

### 14.6 Open items

1. Unlocked CPU writes to an IOSurface are not seen after a skipped
   copy-in (§14.3). No client in these sessions depended on them (the
   screenshots match the base); `YCODE_GPU_SURFACE_SKIP_IN=0` is the way
   out if one does.
2. `replaceRegion` of an IOSurface texture writes the surface memory at
   once; a copy-back of earlier GPU work still on the queue can overwrite
   it. That is the client's race in Metal as well, but with change 4 the
   client hears "scheduled" earlier. Not seen; a wait for the surface's
   pending writes there would close it.
3. Rendering directly into the surface memory (§13.1 item 3) would remove
   the remaining copy-backs (about 12 MB per present); it is now the
   largest GPU-side cost of a frame.
4. Swiping from the Today view back to the home page shows no change in
   either arm (main line behaviour; `frame-profile.md` §7 item 5).
5. A Vulkan submission that never completes (`app-launch.md` §3.7): the
   back end submits no GPU-side semaphore waits (held work stays on the
   host), so a submission that never finishes is GPU work that does not
   end, like §13.5. Changes 3–5 do not change what the GPU runs and so
   neither cause nor cure it; change 7 keeps such a hang from also
   costing 0.5 s per surface lock and per display read. Safari with a
   `data:` URL (full boots with the display server, a viewer attached,
   60 s after the launch): the main line at fcd8196 3 of 3 and this
   branch 4 of 4 drew the page with no submission left running; one
   branch boot (`saf5`) lost the device (`VK_ERROR_DEVICE_LOST` after a
   5.3 s command buffer, while `MercuryPosterExtension` submitted; one
   surface-write wait timed out, change 7 then held later waits to 5 ms).
   Device loss also appears in 14 other recent runs of trees without this
   branch's changes, so it is not attributed to it; too few boots to say
   more. The GPU work behind it is the open item, with §3.7's.

Evidence: Ycode design (§14.1–§14.4); level 3 (Thor sessions and boots
of Ycode's simulator, §14.5); level 1: Vulkan specification
(`vkWaitSemaphores`, timeline semaphores, queue submission order),
Metal documentation (`MTLCommandBuffer` scheduled and completed handlers,
`MTLRenderCommandEncoder` scissor rectangle), the public IOSurface
headers (`kIOSurfaceLockReadOnly`, `kIOSurfaceLockAvoidSync`, seeds).

## 15. Device loss, GPU hangs and the host side of a frame (agent GPU-2, 2026-10-23)

Questions: why do Ycode trees still lose the Vulkan device now and then,
and why does a Safari session sometimes keep one submission running for
ever (`app-launch.md` §3.7)? What is left of the "GPU completion wait"
of a frame (`frame-profile.md` §7 item 2), and what does the GPU part of a
boot cost?

### 15.1 What device loss is on the Thor

The host kernel log (readable by the `adm` group, `journalctl -k`) names
the driver's reason for every loss. From 2026-10-10 to 2026-10-23 it has
85 GPU errors, all of them Xid 109, `CTX SWITCH TIMEOUT`, all in
`ycode-simd` processes (36 of them, on 2026-10-19 10:06–10:40, are
SP-ASTC's deliberate hang probes). There is no MMU fault (Xid 31) or
graphics exception (Xid 13): the losses are not stray memory accesses.
A context-switch timeout is what the driver reports when it must switch
the GPU to another context (another simulator, the desktop) and the
running work of this context cannot be preempted in time; the driver
then kills the context, and every later submission and wait of the
process returns `VK_ERROR_DEVICE_LOST`. So device loss is a GPU hang (or
a very long dispatch or draw) *plus* another GPU client: the same hang on
an otherwise idle GPU is the "submission that never completes" of
`app-launch.md` §3.7, which never ends because nothing asks for the GPU.
The two open items are one problem.

Evidence in the run logs (level 3): every loss before 2026-10-19 that
names its work is command buffer 2 of `WeatherPoster` running the `astc`
kernel (§13.3); the later ones (`FPSGPU/runs/saf5` on 2026-10-20, a
session of 2026-10-21) are first seen when the next submission fails,
right after a process ended, and the logs of that time did not name the
running work. The process that ended is the stuck client itself in the
cases where it can be told: its host kills an extension that waits on
the GPU for too long (`WeatherPoster` ends with status 137, §13.3), so
"process ended, objects released, next submission fails" is the
consequence of the hang, not its cause.

A killed context does not always make the waiting thread's
`vkWaitSemaphores` fail: it can keep timing out. While a serial is stuck,
the completion thread now also checks the result of reading the timeline
counter once a second and treats `VK_ERROR_DEVICE_LOST` there as the loss
(then the report below runs).

### 15.2 Instruments (diagnostics)

| Switch | What it adds |
|---|---|
| `YCODE_GPU_HANG_REPORT_S=<s>` (default 2, 0 off) | A submission still running after that long is logged once with a description of its Metal command buffer: every pass with its attachments (texture size, format, samples, load and store actions, resolve), every draw with its pipeline's shaders, primitive, counts, viewport, scissor and the buffers and textures bound (lengths, offsets), indirect arguments as the CPU sees them, every dispatch and blit. The back end keeps the decoded command buffer with each pending submission for this (no copy; the strings are built only for a report). |
| VK_NV_device_diagnostic_checkpoints (on when the device has it; `YCODE_GPU_CHECKPOINTS=0` off) | A marker before every pass, draw, dispatch and blit and around the IOSurface copies. On device loss the back end logs the pending submissions (described as above) and the last markers the queue passed at the top and the bottom of the pipe, resolved to the process, command buffer, pass and command. |
| `YCODE_GPU_HANG_CAPTURE=<dir>` | A hang report also saves the command buffer's translated shaders (SPIR-V and reflection) and the bytes of every buffer it binds that the CPU can read (256 MiB at most), for offline replay. |
| `YCODE_METAL_TRACE_SEGMENTS=1` (with `YCODE_METAL_TRACE`) | A GPU timestamp after the IOSurface copy-ins, after every pass and after the copy-outs; the trace line gets `label=ns` pairs (`in`, `R<w>x<h>[s<samples>]/<draws>/<load L, C, D>[/res]`, `C<dispatches>`, `B<blits>`, `out`). |
| `YCODE_METAL_RECORD_PROFILE=1` | Host time of the parts of recording a command buffer, in the `YCODE_METAL_STATS` line. |
| `scripts/ycode-gpu-trace <trace> [--windows] [--pid P]` | Per Metal client: command buffers, recording (receive → submitted), GPU time, queue latency (submitted → completion seen), receive → handlers, GPU ms per second, IOSurface MB; per segment kind the mean, p90 and per-command-buffer GPU time. Python standard library. |

### 15.3 Where the host time of a frame went

The frame trace of a restored session (load 15 at the probe, `YCODE_METAL_RECORD_FAST=0`, i.e. before the changes below) split the
render server's command buffers (median 41–48 draws and 21 passes per
frame during swipes) like this, p50: decode (service receive → back end)
0.23 ms, recording under the back-end lock 1.27 ms, GPU 0.6–1.3 ms, queue
latency (submitted → completion seen) 0.8–1.4 ms. Recording grew by about
30 µs per draw and decoding by about 8 µs per draw (1.0–1.3 ms at
120 draws). The recording profile (`YCODE_METAL_RECORD_PROFILE`) put 95 %
of recording in the preparation of each draw (2,104 ms for 63,152 draws,
33 µs each), outside the argument tables (1.4 µs each). Three causes:

1. **The process environment read on every draw.** `skipDraws` (a
   debugging switch) was a computed property over
   `ProcessInfo.processInfo.environment`, which builds a dictionary of the
   whole environment on every call (Foundation on Linux). Read once now;
   the same for `YCODE_VULKAN_LOG`, `YCODE_VULKAN_DUMP_FUNCTIONS` and
   `YCODE_VULKAN_LIBRARY_LTO`.
2. **Quadratic decoding.** `MetalCommandDecoder.apply` took the open
   pass's command list out of the `Open` enum while the enum still held
   it, so every append copied the whole list. The list is now taken out
   with the enum cleared first and grows in place
   (`CommandDecoderTests.longPassDecodesInLinearTime`: 16 times the
   records take about 16 times as long; with the old behaviour, ratio 150
   in a debug build).
3. **Diagnostic strings on every submission**: shader names on every
   pipeline change, the first four dispatches' buffers formatted byte by
   byte, draw counts in the label. Dropped; a hang report describes the
   command buffer instead (§15.2). Argument tables are written from the
   bound slots only (bit masks) instead of visiting all 175 slots.

Also: the decoder no longer runs under the Metal host core's lock (it
held it 0.1–1 ms per render-server frame against every other request of
every process); the refs resolve through a copy of the process's ref
tables taken under the lock, which is what the lock would have shown at
that moment.

`YCODE_METAL_RECORD_FAST=0` restores causes 1–3 for A/B measurements
(the decoder's copying append included).

### 15.4 Copies and fetches stay inside their buffers

Recorded work that is invalid Vulkan usage is undefined behaviour for the
GPU, and on the Thor a copy engine or a draw that runs off the end of its
memory is a candidate for exactly the hang of §15.1. Metal validates
these before a command buffer is encoded, so they can come only from
records Ycode decodes wrongly or from garbage arguments; they are now
skipped (counted in `skipped`, the first 20 copies logged with their
region):

- buffer ↔ texture copies whose region is empty, whose row length or
  image height is below the extent, that are not aligned to a compressed
  format's blocks, whose buffer offset is not texel-aligned, or that reach
  past the end of the buffer's memory (`copyIsValid`);
- buffer ↔ buffer copies and fills that reach past either buffer;
- indexed draws whose indices reach past the index buffer, and indirect
  draws whose argument record does not fit in its buffer.

Before this, the only checks were the vertex × instance limit of direct
draws (`saneDraw`) and the image-side clamps of the copy region.

### 15.5 The `astc` hang is not gone; lane-isolated dispatch

The divergence-driven inlining of §13.5.2 did not remove it. On
2026-10-19 the first boot of an iPad (A16) device
(`ide-remote/ipad/runs/f1-a16`, the IPAD-DEVTYPE agent's run) hung in
`WeatherPoster`'s command buffer 2 for 940 s, in the `astc` kernel 944ee7b6,
translated at 19:57 by a translator with the fix: its SPIR-V (43,122 words)
has no function call left and its loops are guarded (`loop_limit`
1,048,576). The dispatch was 5 × 3 workgroups of 32 × 16 over a 150 × 42
grid. Random inputs do not reproduce it with the fixed translation: a
probe that drives the kernel through CVulkan (`scripts/gpu-probes/kprobe.c`; the same ABI as the back
end; inputs as `KernelHangProbeTests`) ran 900 dispatches of 64 × 64
blocks with workgroups of 8 × 8 and 32 × 16 (seeds 1–3), slowest 2 ms.
The real block data is what triggers it, and the hang reports and
captures of §15.2 are there to catch the next one with its inputs.

What is established (§13.5.1, and again here: the same probe with the
pre-fix translation of 944ee7b6 does not finish round 0 with 8 × 8
workgroups) is that the kernel stops only when lanes of *one subgroup*
take different paths through it; blocks in different subgroups finish.
The kernel's result does not depend on the workgroup shape: its
reflection reads only `thread_position_in_grid`, it has no threadgroup
memory, no barriers and no subgroup operations. So the back end now runs
it with **one thread per workgroup** (the grid as the workgroup count;
every subgroup has one live lane; the grid guard and push constants
unchanged), which takes the trigger away whatever the translation:

| Probe (CVulkan, 64 × 64 random blocks) | 8 × 8 workgroups | 1 × 1 workgroups |
|---|---|---|
| pre-fix translation of 944ee7b6 (helpers out of line) | round 0 does not finish | 490 dispatches (seeds 1–3), slowest 25 ms |
| current translation (inlined, guarded) | 450 dispatches, slowest 2 ms | 300 dispatches, slowest 4 ms |

The kernel runs only when a client uploads ASTC data (a poster at
boot); 4,096 blocks take 4 ms this way. `YCODE_GPU_LANE_ISOLATED=<names>`
(default `astc`, empty: none) names the kernels; a kernel whose reflection
reads workgroup-relative built-ins, uses threadgroup memory, barriers or
subgroup operations is never isolated, and an indirect dispatch keeps its
shape. Counted as `lane-isolated dispatches` in the stats line. Test:
`VulkanBackendTests.laneIsolatedKernelRunsOneThreadPerWorkgroup`.

### 15.6 The Safari hang: Core Animation's `Xgc` samples its own render target

Reproduced with this agent's build: two of three full boots that open
Safari with a `data:` URL (`SX/GPU2/safari.sh`, the method of §14.6
item 5) hung. The hang report (§15.2) of the first names WebKit's command
buffer 2 of the client process (serial 516): one render pass over an
IOSurface texture (1146 × 1740, BGRA8) with eight draws, the shaders
`Vfx+BclrXc`, `Vfx+Xc`, `VfxU10+TimgXc_Icir`, `Vfx+Xcn` and two instanced
draws of `buffer_image_blit_vert_lpf+buffer_image_blit_frag_lpf` (12 and
18 instances). The host kernel logged Xid 109 for that process 1 s later
(another simulator wanted the GPU); the back end's waits kept timing out
and never saw the loss (§15.1 adds the counter check for that).

None of the shaders has a loop or a call (our translations, from the
capture). The blit fragment shader reads one byte per pixel from a buffer
(binding 9) at `base + int(floor(min(u, uMax)) + x0 + floor(min(v, vMax)) * stride)`:
an index from interpolated coordinates, clamped only from above, so a
coordinate a little below zero reads before the buffer. On Apple's GPUs
such a read returns whatever is mapped there. On the Thor it does not
fault: a probe that imports one host page and reads the GPU address
just past it (`scripts/gpu-probes/oob.c`, our own GLSL) never completes (the wait times
out, the counter stays, the kernel log shows no MMU fault, Xid 109 follows
when another context needs the GPU); the same read inside the page
returns the value. Reads of a sparse buffer's unbound pages, in contrast,
return zero (`scripts/gpu-probes/sparse.c`). So a guest shader that reads a few bytes
outside a buffer whose memory starts or ends at an unmapped GPU address
hangs the GPU for every client: a plausible cause of the hangs and
device losses that do not involve `astc` (simple shaders can stall), not
yet proven for this command buffer (below).

Tried and rejected: importing guest memory with slack around each object
(64 KiB of the neighbouring host memory, inside the shared object arena
only), so that such a read lands in mapped memory. On the Thor's driver
imports that overlap other imports (or, outside the arena, the driver's
own mappings) make later allocations fail with
`VK_ERROR_OUT_OF_DEVICE_MEMORY` (59–92 failed allocations per Safari boot,
textures and pipelines missing, thousands of draws skipped); without it
none. It stays as an experiment (`YCODE_GPU_IMPORT_SLACK_KB`, default 0;
only inside the window ycode-simd passes, the arena).

The captured buffers do not show the read outside: replaying the two
text draws of the first capture through CVulkan with the captured bytes
(`scripts/gpu-probes/rprobe.c`, the fragment shader patched to record the smallest and
largest index with atomics) gives indices 0–45,632 and 45,633–58,138, all
inside the 262,144-byte buffer, and the draws finish. The captures are
taken 2 s after the submission, so a buffer the client rewrote meanwhile
would not show what the GPU read. Linking the replayed pipeline from
library parts as the back end does, and importing the buffers from host
pages as it does, changes nothing: they finish.

With checkpoints working (on the Thor through `vkGetQueueCheckpointDataNV`;
the "2" query is not resolved by its driver), the third hang
(`SX/GPU2/runs/sd1`, the final build, Xid 109 and device loss detected)
showed the same command buffer with a third pass and the markers: bottom
of the pipe at the marker before command 33 (`VfxXg+Xgc`, Core
Animation's uber-shader, one draw of 6 vertices), top of the pipe at the
marker before command 43 (the second text draw). The bottom marker stays
at a draw's marker until that draw has finished, so command 33 did not
finish: the GPU stopped in the `Xgc` draw (or behind it). Experiments,
each over full Safari boots of the final build:

| Variant | Hangs |
|---|---|
| as built (`sa1–3`, `sd1–4`) | 3 of 7 |
| monolithic pipelines instead of library parts (`YCODE_VULKAN_NO_PIPELINE_LIBRARY=1`, `se1–6`) | 2 of 6 |
| every translator helper inlined (`AIRC_INLINE_ALL=1`, own GPU cache; `Xgc` became 215,902 words, no call, 25 s to compile; `sg1–3`) | 1 of 3 |

So neither the library linking nor the out-of-line helpers of §13.5 are
the cause. What `Xgc` does in that draw is: its reflection marks texture
slot 0 as used, and slot 0 is bound to the pass's own color attachment
(the IOSurface texture being drawn): Core Animation reads the
destination (it orders such reads with a render-target memory barrier
between draws on Apple's GPUs). In Vulkan, sampling an image while it is
a color attachment of the same rendering is a feedback loop whose result
is undefined unless the image, its layout and the pipeline are set up for
it (`VK_EXT_attachment_feedback_loop_layout`); the back end did nothing of
the kind, and the render-target barrier record was ignored.

Change: a draw that samples a color attachment of its own pass
(slots its shaders' reflection marks used, bound to a level-0 texture of
an attachment image) samples a copy made just before the draw: the back
end ends the rendering, copies the attachment into a copy image (one per
format, size and swizzle, kept until shutdown, with its own heap index),
begins the rendering again with every attachment loaded, and points
those slots at the copy for that draw. That is Metal's texture-barrier
behaviour (the draw sees the earlier draws' results). Passes that
resolve or do not store skip it. Only the draw's scissor rectangle (two
texels wider, for filtering) is copied: Core Animation reads the
destination where it draws, and texels outside keep an older copy.
`YCODE_GPU_FEEDBACK_COPY=whole` copies the whole attachment level (the
first version, validated in the boots below), `YCODE_GPU_FEEDBACK_COPY=0`
turns the copies off; the stats line counts `feedback copies` and the
texels copied. Tests:
`VulkanBackendTests.drawSamplingItsOwnTargetReadsASnapshot`,
`VulkanBackendTests.scissoredFeedbackDrawCopiesItsScissor`.

| With the copies | Result |
|---|---|
| whole-attachment copies (`sh1–6`) | 0 of 6 boots hung; 3,195–3,546 copies per session; Safari drew the page |
| scissor copies, the default (`sj1–4`, on the main line 3aeaa9c merged) | 0 of 4 boots hung; 2,866–3,666 copies per session of 0.12–0.22 Mtexels each; Safari drew the page |

Against 6 of 16 boots without them (the three variants above together),
six clean boots in a row has a probability of about 6 % if nothing had
changed, ten about 1 %: strong evidence, not proof. Two of the seven captured hangs
(`sa2`, and `sb3` of the rejected slack build) had no `Xgc` draw in the
stuck command buffer, and their stuck draw is unknown; the text draws
(`buffer_image_blit`) are in all seven and replay cleanly offline.

### 15.7 Measurements

**Where a render-server frame's GPU time goes** (segments, §15.2;
restored session, load 15 at the probe, the build before the changes of
§15.3; per command buffer of `backboardd`, which renders the display
surface): GPU time p50 0.6 ms, p90 1.4 ms. Four passes over the
1398 × 2034 display surface with *load* (0.39 ms in all, about 0.1 ms
each), the copy-back of the surface to its memory (11.4 MB, 0.20 ms)
plus the closing barrier that makes it visible to the host (0.16 ms),
and small offscreen passes (64–576 pixels square, 15–50 µs each, mostly
the full barrier before them). The Spotlight pull-down's blur passes are
among those small passes; the pull-down ran at 59 guest frames per
second (critical path: 8.4 ms per frame waiting for the 60 Hz frame
clock, 2.6 ms waiting for the Metal service and the GPU, the rest
`notifyd` and `backboardd` guest code). The GPU clock (devfreq governor
`nvhost_podgov`) idles at 315 MHz of 1575 MHz; frames this short do not
raise it. Rendering into the surface memory directly (§14.6 item 3) is
not possible on the Thor: B8G8R8A8 with linear tiling (or the linear DRM
modifier) has no color-attachment feature.

**Boot.** A cold boot with warm GPU caches (session `warm2`, 45 s to the
home screen) spent 173 translator calls (0.30 s, disk-cache hits), 131
pipeline links (41 ms), one wait for a pipeline (2.7 ms) and recorded 150
command buffers in 73 ms (the build before §15.3: 122 in 236 ms, the
longest 54 ms). The GPU is not on the boot's critical path (§13.1).
Building the uber-pipeline's fragment part with
`VK_PIPELINE_CREATE_DISABLE_OPTIMIZATION_BIT` first (§13.4 item 1) showed
no gain in exploratory compiles of `VfxXg + Xgc` with the driver cache
off (3.6–4.9 s without optimization against 4.5–5.0 s with, load 28–32;
not a timed measurement); not built.

**Timed A/B** (`SX/bin/timed.sh` around `ide-remote/gpu2/abrun2.sh`: the
host to itself, load under 4 before each session; one warm-up session
saves the device on the build, then 3 rounds of restored sessions with
the arm order rotating; each session a 12 s window of home-screen swipes
and a 16 s window of three Spotlight pull-downs, the blur case; numbers
are the range over the 3 sessions of each arm; GPU numbers per
`backboardd` command buffer from the frame trace: recording = locked →
submitted, GPU = timestamps, queue = submitted → completion seen,
receive → handlers; present intervals and the critical path's GPU wait
per frame from `scripts/ycode-frame-profile`; probe load 2.2–5.9).

Series R (main line 3aeaa9c merged; feedback copies of the whole level).
Arm A: everything on. Arm B: `YCODE_METAL_RECORD_FAST=0
YCODE_GPU_SURFACE_WAIT_POLL_US=0` (§15.3's recording and decoding
changes and the sliced surface wait off). Arm C: `YCODE_GPU_FEEDBACK_COPY=0`.

| Swipes (ms) | A | B | C |
|---|---|---|---|
| present interval p50 / p90 | 7.5–8.7 / 17.1–18.0 | 7.4–8.7 / 17.0–17.1 | 7.1–8.6 / 16.9–18.0 |
| critical-path GPU wait per frame | 0.03–0.48 | 0.22–0.89 | 0.30–0.87 |
| recording p50 | 0.41–0.45 | 1.96–2.11 | 0.32–0.36 |
| GPU p50 / p90 | 2.23–2.27 / 2.69–3.04 | 2.14–2.53 / 2.87–3.22 | 1.23–1.28 / 1.86–2.20 |
| queue p50 | 2.35–2.41 | 2.23–2.67 | 1.33–1.44 |
| receive → handlers p50 / p90 | 3.44–3.58 / 5.67–5.89 | 5.10–5.56 / 6.96–7.80 | 2.30–2.63 / 4.07–4.52 |

| Spotlight pull-downs (ms) | A | B | C |
|---|---|---|---|
| presents in the window | 418–583 | 326–392 | 429–460 |
| present interval p50 / p90 | 9.8–15.9 / 19.0–22.7 | 11.7–15.9 / 24.4–37.0 | 9.6–10.7 / 18.1–18.6 |
| critical-path GPU wait per frame | 0.71–1.60 | 1.27–2.96 | 0.51–0.75 |
| recording p50 | 0.31–0.45 | 0.96–1.44 | 0.29–0.31 |
| GPU p50 / p90 | 0.99–1.75 / 7.25–7.36 | 0.82–1.74 / 7.32–7.38 | 0.90–0.94 / 1.99–2.19 |
| receive → handlers p50 / p90 | 2.47–3.72 / 10.2–11.0 | 2.22–4.61 / 15.1–17.1 | 2.07–2.33 / 4.29–4.88 |

So §15.3's changes cut the recording of a render-server command buffer
from about 2 ms to 0.4 ms (no overlap between the arms), and the time
from receiving a command buffer to running its handlers by 1.5–2 ms at
p50 (swipes) and 4–7 ms at p90 (pull-downs); the pull-downs presented
more frames with shorter p90 intervals (all three A sessions above all
three B sessions). The whole-level feedback copies cost about 1 ms of GPU
time per command buffer at p50 and 5 ms at p90 in the pull-downs (10,300–
13,400 copies per session, about 7 per submission of all clients); the present
cadence did not change measurably.

Series S (the build with scissor-limited copies). Arm A: as built
(scissor-limited copies). Arm B: `YCODE_GPU_FEEDBACK_COPY=whole`. Arm C:
`YCODE_GPU_FEEDBACK_COPY=0`.

| (ms) | A (scissor) | B (whole) | C (off) |
|---|---|---|---|
| swipes GPU p50 / p90 | 1.73–1.87 / 2.53–2.55 | 2.15–2.28 / 2.67–3.07 | 1.30–1.49 / 2.01–2.06 |
| swipes receive → handlers p50 | 2.89–3.16 | 3.35–3.60 | 2.43–2.50 |
| pull-downs GPU p90 | 6.68–6.73 | 7.17–7.38 | 1.99–2.08 |
| pull-downs receive → handlers p90 | 9.42–9.53 | 9.73–11.10 | 4.16–4.79 |
| copies per session (Mtexels each) | 10,400–14,900 (1.8–2.0) | 11,500–12,900 (2.9) | 0 |

Core Animation's scissor covers most of the 1398 × 2034 display surface
for most copies (1.9 of 2.8 Mtexels on average), so the scissor limit
saves about a third of the copy cost (0.4 ms GPU p50 per command
buffer in the swipes). The copies stay on by default: without them
Safari boots hang the GPU (§15.6), and a hang stops every client
(§15.8 item 2).

### 15.8 Open items

1. **Out-of-bounds GPU reads stall the Thor** (§15.6); slack imports are
   not usable on its driver. The complete remedies, both larger changes:
   - bounds in the translator: buffer lengths in the argument table (a
     new ABI: the table has no free entries) and every access through a
     pointer derived from a buffer binding clamped to it (pointers loaded
     from memory, e.g. argument buffers, have no known buffer and stay
     unchecked);
   - a sparse arena: one large sparse residency buffer per device into
     which every guest import is bound, with unbound gaps between them:
     reads of unbound pages return zero (`residencyNonResidentStrict`,
     checked with `scripts/gpu-probes/sparse.c`). Two obstacles found: sparse binding
     works in 64 KiB units (guest objects are 16 KiB-aligned runs of the
     arena) and the sparse buffer's memory types (device-local only) do
     not include the host-pointer import types; binding an import anyway
     worked on the probe but is outside the specification.
2. **One stuck submission still stops every client.** All clients share
   one device and queue; a hang that does happen ends in device loss for
   all of them (§15.1), with no recovery but a host restart. A device per
   client (contexts are killed one at a time by the driver), or a rebuild
   of the device and its objects after a loss, remain open (§13.5.4).
3. The `astc` kernel's real trigger data is still unknown (§15.5); the
   next report on a build with §15.2 saves it.
4. Two captured Safari hangs had no feedback draw (§15.6). If hangs
   continue with the copies, the next device-loss report names the draw.
5. The feedback copies run on every frame of a render server whose
   shaders may read the destination (10,000–15,000 per home-screen
   session, mostly whole-surface): 0.4–1 ms of GPU time per command buffer
   at p50 and about 5 ms at p90 in the blur case (§15.7). Two ways to
   remove most of it: (a) `VK_EXT_attachment_feedback_loop_layout`
   (present on the Thor): the usage bit at image creation, the feedback
   layout for the attachment and its descriptors, a pipeline flag or
   `VK_EXT_attachment_feedback_loop_dynamic_state`, and Metal's
   render-target barrier translated into a by-region feedback dependency;
   (b) copy only for draws that really read the destination: `Xgc`'s
   reflection marks slot 0 used whatever its uniforms select, so this
   needs the translator to report which uniform values reach the sample
   (a question for the translator, or for Core Animation's observable
   behaviour: which blend modes read the destination).

Evidence: level 3 — the host kernel log (`journalctl -k`, Xid lines),
run logs of Ycode's simulator (this agent's `SX/GPU2/runs/sa*`, `sd*`,
`se*`, `sg*`, `sh*`, `sj*`, `ip1`, sessions `ide-remote/gpu2/out/*`; other agents'
logs named in §15.1 and §15.5), hang reports, checkpoint markers and
captures of our own translations, probes over CVulkan
(`scripts/gpu-probes/`: our own GLSL and `ycode-airc`'s own SPIR-V,
random or captured inputs), the frame trace and recording profile of
§15.2, `vulkaninfo` and format queries of the Thor's driver, devfreq
files under `/sys/class/devfreq`. Level 1 — the Vulkan specification and
extension texts (`VK_NV_device_diagnostic_checkpoints`,
`VK_EXT_external_memory_host`, sparse residency and
`residencyNonResidentStrict`, `VK_EXT_attachment_feedback_loop_layout`,
`VkBufferImageCopy` valid usage, render-pass feedback loops), the Metal
documentation (render-target memory barriers, `MTLTextureUsage`), the
NVIDIA Xid table (Xid 109: context switch timeout). Ycode design for the
rest. No Apple binary, the reference tools or `research/` were opened;
Apple's simulator was not run.
