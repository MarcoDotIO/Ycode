# visionOS renderer observations (agent VISIONOS-OBS, 2026-10-27)

Dirty-room notes behind `specs/simulator/visionos.md` §9 (Q5, Q9, Q10, Q11)
and §10.6. Prose only. Our recorder and probe sources, raw recorder output,
logs and screenshots stay in `research/dirty/visionos-obs/` (git-ignored).
Method levels as in AGENTS.md rule 4. No disassembly or decompilation was
used; Ghidra and the reference tools folder were not opened; no firmware or
IPSW was touched. Binary metadata (level 4) was limited to imported symbol
names (`nm -u`), the linked-library list and printable strings of the
runtime's binaries and dyld cache, as earlier notes did.

## Setup

- This Mac, Xcode 27.1, visionOS 27.0 runtime **24M362**, device type Apple
  Vision Pro (`…Apple-Vision-Pro-4K`). One device, `ycode-test-visionos-obs`,
  erased or recreated between cold boots; deleted at the end. No other
  simulator was touched.
- **Our recorder** (`ycrec.dylib`, our own code): inserted with
  `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` into every job of a boot, inert except
  in the processes it is told to watch. When `MTLCreateSystemDefaultDevice`
  or `MTLCopyAllDevices` returns a device, it reroutes every instance method
  of the device's concrete class (own and inherited, 658 methods for
  `MTLSimDevice`) through the ObjC forwarding path and logs selector,
  arguments, result and the calling image. Unlike Ycode's `mtlwatch` it
  does not wrap the device in a proxy, so object identity is unchanged, and
  it extends the same treatment to every `MTLSim…` class whose instances a
  watched call returns (buffers, heaps, textures, queues, command buffers,
  shared events and their handles, argument encoders, pipeline states). It
  also interposes the SimFramebufferClient calls that wakeboardd imports
  (signatures from `simframebuffer.md` §3) and, on request, injects faults
  (a selector returning nil, an event port of 0, a command buffer reporting
  an error, a delay per Metal call, the n-th device creation returning nil).
- **Our probe** (`mtlprobe`): calls `MTLCreateSystemDefaultDevice` and
  prints every argument-free capability getter of the device class plus
  parameterized queries; then exercises a shared-event handle, an argument
  encoder of two pointers and heap sizing. Run with `simctl spawn`, once
  linked with the earlier Metal message recorder (`mslog.c` from
  `research/experiments/simulator/metal-sim/`, rebuilt for the visionOS
  simulator SDK) to see the host messages.
- With the recorder in backboardd, the reference boot reached the home view
  in the living room as usual (first boot 22 s to `bootstatus` terminal), so
  the observations are of a working boot. With method rerouting enabled in
  wakeboardd, the first boot stalled (wakeboardd's compositor serves
  backboardd synchronously and became too slow); wakeboardd was therefore
  recorded at the SimFramebuffer level only.

## Q10: device calls during backboardd's render-manager start (level 3)

- backboardd gets its device from RealitySimulation's render server, on the
  main thread, 0.13 s after the process starts; the class is
  `MTLSimDevice : _MTLDevice`, name "Apple xrOS simulator GPU". The device
  is created (and returned from the driver's cache) again later by other
  CoreRE components: the CA layer contents cache, a global-device helper,
  the image presentation texture processor, the video light-spill
  generator, then CompositorNonUI (layer renderer and system settings) and
  QuartzCore. All return the same object.
- RealityKit's render manager start (CoreRE) asks, in this order:
  `supportsFamily:` 1005 NO, 2002 NO; `supportsRasterizationRateMapWithLayerCount:` 2
  NO; `areProgrammableSamplePositionsSupported` NO;
  `supportsVertexAmplificationCount:` 2 NO; `supportsFamily:` 1004 NO, 1002
  YES; `supportsLayeredRendering` YES; `supportsFamily:` 1004, 1007, 2002, 0
  NO; `supportsSeparateDepthStencil` NO; `supportsFamily:` 2002, 1003, 3002,
  5001, 1006 NO. Each `supportsFamily:` is answered through the driver's
  internal three-argument form with the same answer. This is exactly the
  list R1 recorded under Ycode (§10.4), with the same answers.
- Later queries of the start (Metal's own validation and CoreRE): the 2D/3D/
  cube/1D/array/buffer texture limits (8192, 2048, 2048, 8192, 2048,
  67 108 864), `supportsNonPrivateDepthStencilTextures` NO,
  `supportsNonPrivateMSAATextures` NO, `supportsMemorylessRenderTargets`
  YES, `supportsFamily:` 1001 YES, 1008 NO, 1010 NO, `supportsFunctionPointers`
  NO, `supportsShaderBarycentricCoordinates` NO, `supportsTextureSwizzle`
  YES, `maxBufferLength` 268 435 456, `supportsTextureWriteRoundingMode:` 0
  YES, `requiresRaytracingEmulation` YES, `argumentBuffersSupport` 0,
  `supportsRaytracing` NO, `maxTotalComputeThreadsPerThreadgroup` 512,
  `deserializerSupportsSharedEvents` YES, `supportsSharedTextureHandles`
  YES, `supportsBufferWithIOSurface` NO. MPS (after the render manager)
  asks a further twenty feature getters, all NO, and
  `maxComputeThreadgroupMemory` 16 384.
- The probe's full dump (about 330 getters) agrees with §4.5 and adds
  facts, for example `supportsFamily:` 3001 YES (Common1), 1001/1002 YES,
  every other family NO; sample counts 1 and 4 only;
  `maxThreadsPerThreadgroup` 512 × 512 × 512; `maxTotalComputeThreadsPerThreadgroup`
  512; `maxThreadgroupMemoryLength` 16 384; `supportsArgumentBuffers` YES,
  `argumentBuffersSupport` 0 (tier 1); `supportsResourceHeaps` YES; `supportsASTCTextureCompression` YES;
  `registryID` from the host's hand-shake; `deserializerVersion` 10.
- Every one of these answers is computed inside the guest driver. The only
  capability message to the host is the limits query (device op 37, as
  `metal-sim-protocol.md` §4.2 says); the reference host's reply was 1024,
  1024, 1024 and 32 768, which the driver caps to 512, 512, 512, 16 384. So
  a host cannot change any capability answer except, through op 37, the
  thread and threadgroup-memory limits. Ycode's op-37 z value of 64 shows
  through as `maxThreadsPerThreadgroup` z = 64; R1 already showed 512 does
  not clear the abort.
- datamigrator starts the same render manager (through CoreRE's default
  device helper) and asks the same questions in the same order with the
  same answers.

## The reference order of the render-manager start (level 3)

From the recorder, backboardd, cold first boot (times from the device
creation; a repeat boot is faster because the compiled shader is cached):

1. The capability questions above (1 ms).
2. Four 16-byte shared buffers with initial bytes; four sampler states.
3. Texture manager: a command queue labelled `uploadFallbackTextureQueue`;
   a private, untracked heap requested at 28 032 bytes (granted 32 768);
   four 1 × 1 RGBA8 fallback textures (three 2D, one 3D) from that heap plus
   a 64 × 64 seven-level texture; their contents uploaded with one blit
   command buffer, committed and **waited for** (completion with no error
   about 14 ms later).
4. Three CoreRE metallibs loaded by URL (`default`, `mvf`, `custom`); the
   binary archive is absent ("Could not locate file
   'default-binaryarchive.metallib'", error level, also in the reference).
5. Mesh manager queue and a third queue; drawing manager: three fences, two
   shared events and one event, three RGBA16Float textures, a 64-byte
   buffer; one more fence for the render-graph allocator.
6. A private, tracked heap of 67 633 280 bytes requested (granted
   67 649 536) by CA render persistent data. No texture is placed in it
   during the start.
7. The compute function `computeSDFGradient` specialized and its pipeline
   compiled (1.6 s cold through MTLCompilerService, a few ms when cached);
   pipeline creation returns an object.
8. Log "Device doesn't suport light clustering" (default level).
9. CA layer contents cache: one more `MTLCreateSystemDefaultDevice`, then
   **no Metal call**; the VFX manager creates a command queue. This is the
   end of the render-manager start.
10. Log "ImportGraphicsResources: initializing …", "MRLightingService being
    added", "NetworkSyncManager: initialized" and the rest of the engine
    start; then a two-pointer argument encoder (layout through
    `serializeStructType:version:`, encoded length 16, alignment 8);
    DirectResource's commit signalling makes a shared event, asks it for a
    shared-event handle and reads the handle's `eventPort` (a send right,
    non-zero); then the global-device helper, the image presentation
    session, MPS, and audio.

The strings of the dyld cache place the assertion text "Render manager was
requested but failed to initialize." among the engine's own strings (next
to the engine-count and nested-tick assertions and the configuration keys
`metalIndependentRenderServiceEnabled`, `preloadEngineAssets`,
`enableMRLighting`), consistent with the check sitting in the engine start
right after the render-manager start returns (level 4). Under Ycode the
last thing seen before the abort was the device creation of step 9 and the
light-clustering message of step 8, and "ImportGraphicsResources" was
never logged: the render-manager start returned failure somewhere in steps
1–9, without an error that R1's capture showed.

## What does not cause the abort in the reference (level 3, fault injection)

Each case is a boot of the reference with one injected fault in backboardd
(and datamigrator); "start completed" means "ImportGraphicsResources" and
"Starting render loop" were logged.

| Fault | Result |
|---|---|
| Shared-event handle returns nil | start completed, boot completed, home view |
| Shared-event handle's event port reads 0 | start completed; later the host's command-buffer deserializer aborted (SimMetalHost "fatal error while deserializing") and backboardd aborted in a frame-completion check |
| Every command buffer reports status Error with an error object for 4 s | start completed |
| Compute pipeline creation returns nil | start completed (ImportGraphicsResources logged), later aborts and restarts every ~10 s, no render loop |
| Argument encoder (`newArgumentEncoderWithArguments:structType:`) returns nil | start completed |
| The second device creation (CA layer contents cache) returns nil | start completed |
| `newCommandQueue` returns nil (every call for 4 s) | start completed |
| `newHeapWithDescriptor:` returns nil | start completed |
| `newSharedEvent`, `newFence`, `newTextureWithDescriptor:` (device and heap), `newSamplerStateWithDescriptor:` return nil | start completed |
| `newLibraryWithURL:error:` returns nil | not the Ycode signature: "newLibraryWithURL failed." and many "makeFunctionWithDescriptor error" messages (error level), then an uncaught exception in the vertex-fetch prewarm (drawing manager), restart every ~10 s |
| `newBufferWithLength:options:` returns nil | not the Ycode signature: a null access in the drawing manager start |
| 15 ms added to every Metal method call for 8 s (start stretched to 8.2 s) | start completed |

None of these reproduced "Render manager was requested but failed to
initialize". The render-manager start tolerates single missing objects and
command-buffer errors, and it is not time-limited at the scale of seconds;
the failures that do stop it (missing libraries or buffers) log errors or
crash elsewhere. So R1's abort is not explained by a capability answer, a
nil device-level object, slowness, or a failed command buffer.

## Q9: backboardd's logs in the window (level 3)

- With `log config --mode level:debug,persist:debug` for `com.apple.re`,
  `com.apple.Metal`, `com.apple.RealitySimulation`,
  `com.apple.RealitySystemSupport`, `com.apple.coreanimation` and others in
  the device, a repeat boot logged, between "Initializing shared simulation
  and host server" and "ImportGraphicsResources", only default-level
  messages: the three Metal connections to
  `com.apple.metal.simulator.backboardd`, "EntitlementManager initialized",
  "MTLCounter API disabled …", one "MTLLibrary <path> newLibraryWithURL
  <n>ms" per metallib, the missing binary archive (error level), "API
  function cache initialized", "DebugSettingsManager has been disabled and
  not initialized", "com.apple.re.enableSynchronousCommandQueue is enabled",
  "Encoder Split: Logging Disabled.", "Vertex fetch functions compiled in
  0ms", "Function specialization completed for function
  computeSDFGradient", (cold only: a MTLCompilerService connection and
  "Metal Compiling Shader", "Compiling PSO RT name=computeSDFGradient …")
  "PSO compilation completed for compute pipeline computeSDFGradient", and
  **"Device doesn't suport light clustering"**. No debug-level message
  falls in this window (debug messages exist elsewhere in the boot).
- So the light-clustering message is normal. The only error-level messages
  of the whole start are the missing binary archive and an asset-path parse
  error for `engine:throttleGhosted.rematerial`; both also occur in every
  reference boot.
- Host and guest services used in the window: the three Metal connections
  (per-process name), MTLCompilerService on a cold boot, cfprefsd. Nothing
  from RealitySimulation's servers or wakeboardd is contacted before the
  engine start ends.

## Shared-event handles on the wire (level 3, our probe with `mslog`)

- `newSharedEventHandle` sends **messageType 17** on the connection of type
  1 with the key `eventRef` (uint64, the shared event's ref) and no
  command record. The reply holds `eventPort` (a Mach send right) and
  `labelTraceID` (uint64 0). The handle's `eventPort` is that right; in the
  probe it was a valid send right.
- `newSharedEventWithHandle:` sends **messageType 18** on the same
  connection with `eventPort` (the send right) and a `command` record of op
  40 (0x28) with a zero u32 body; the reply's `replyData` is u32 ref, u32
  0: a new event ref. Setting the first event's value to 5 (op 30 on the
  type-0 connection) and reading the second (op 41) returned 5: both refs
  name one host event.
- Archiving the handle with `NSKeyedArchiver` (secure coding) failed in the
  probe (no bytes); cross-process transfer is evidently by the Mach right.
- Neither message type is in `metal-sim-protocol.md` §2.4; Ycode's host
  answers unknown message types with an empty dictionary. Under the
  reference, a handle whose port is 0 later broke the host's
  command-buffer deserializer.
- The probe also showed the reference's heap sizing answers: 1 × 1 RGBA8
  private (2D or 3D) 128 bytes, alignment 128; 3840 × 2160 RGBA16Float
  render target 67 371 008, 128; a 1000-byte private buffer 1000, 256; a
  heap requested at 28 032 bytes reports size 32 768. An argument encoder of
  two read-only pointers: encoded length 16, alignment 8 (host op 17 reply).
  `minimumLinearTextureAlignmentForPixelFormat:` 16 for RGBA8, BGRA8 sRGB,
  RGBA16Float and R32Float (op 33).

## Q11 and Q5: wakeboardd's presentation (level 3)

- SimFramebuffer calls before any swap, in order: `SFBConnectionCreate`
  (name "wakeboardd"), `Connect`, `CopyDisplays` (one display), `GetType`
  (0), `GetDeviceSize` (3840 × 2160), `SFBDisplayCreateSwapchain` with mode
  **2** and no options, `GetDeviceSize`, `GetCurrentMode` (id 1, 3840 ×
  2160, scale 2, `'BGRA'`, 6000). This is exactly R1's list under Ycode.
  One swapchain only.
- **Pulse.** wakeboardd decides "first boot" by creating a POSIX named
  semaphore `wakeboardd.first-boot` (level 4: its imports `sem_open`,
  `sem_unlink`, `sem_close` and the strings "wakeboardd.first-boot",
  "wakeboard.is-running"; level 3: on this Mac the semaphore existed from an
  earlier session, and after we removed it the next boot logged "This the
  first boot of wakeboardd …" and Config → Pulse, while every boot with the
  semaphore present went Config → Ready → RealTimeStarting → Run). On macOS
  such semaphores are host-wide and outlive the device, so the reference
  pulses only on the first visionOS boot after the host starts (or after
  the semaphore is removed).
- **During Pulse wakeboardd submits no swap.** In the Pulse boot: swapchain
  created 0.32 s after start, "First frame displayed" at 0.61 s without any
  `SwapBegin`, backboardd's render loop at 4.9 s, backboardd's swapchains
  moved to slots Top and SyntheticPassthrough at 8.4 s, and the **first
  `SwapBegin` at 19.9 s**, in the same millisecond as "creating real time
  thread" and Pulse → RealTimeStarting → Run. That transition came right
  after SurfBoard logged "User presence detected", "Transitioning headset to
  in use..." and "Attempting to set hmd state to 2". So under Ycode, where
  SurfBoard dies with backboardd, a wakeboardd in Pulse that never swaps is
  the reference behavior, not a separate fault.
- Without Pulse the first swap comes 0.2–0.3 s after the swapchain, at the
  Run transition, before backboardd's render loop exists (4–5 s later).
- **Swap pattern (Run state).** One thread (the real-time thread) per
  frame: `SwapBegin` with target time **0**, one `SwapAddSurface` (source
  and destination 0, 0, 3840, 2160; trailing integers 0, 0),
  `SwapSetCallback` with context NULL and a **non-zero** pointer-sized third
  argument (constant within the process), `SwapSubmit` (0.2–0.8 ms against
  the macOS server). Two IOSurfaces alternate. Cadence exactly 60 per second
  (600 swaps per 10.0 s over three minutes), unchanged when backboardd's
  swapchains arrive. The completion callback runs on another thread 1–20 ms
  after the submit, with no error, A = 0 (the target given) and B the
  completion time in ticks.
- With method rerouting in wakeboardd (repeat boot) one command buffer was
  created during start-up and none was seen per frame by our recorder; the
  per-frame GPU work of the real-time thread did not pass through the
  rerouted methods, so its Metal traffic per frame is open.

## Evidence summary

| Claim | Level | Source |
|---|---|---|
| Selector list, order and answers during the render-manager start (backboardd, datamigrator) | 3 | our recorder, cold boots 3 and 4 |
| Full capability dump | 3 | our probe |
| Only op 37 reaches the host; reference reply values | 3 | our probe with `mslog` |
| Start order, heaps, pipelines, events, encoders | 3 | our recorder with object classes |
| Fault-injection table | 3 | 15 boots with our recorder's faults |
| Assertion text location among engine strings | 4 | `strings` of the runtime's dyld cache |
| Debug-level log window | 3 | `log config` + `log show --debug` in the device |
| messageType 17/18 | 3 | our probe with `mslog` |
| Pulse semaphore | 3, 4 | `nm -u`, `strings` of wakeboardd; boots with and without the semaphore |
| wakeboardd swap pattern and timing | 3 | our recorder's SimFramebuffer interposition, five first boots |

Level 5 was not used.

# The render-manager start with Ycode's recorder (agent VISIONOS-OBS2, 2026-10-27)

Dirty-room notes for `specs/simulator/visionos.md` §9 Q13/Q14 and §10.8.
Prose only. The recorder copy, the size probe, the scripts and the raw
logs are in `research/dirty/visionos-obs2/` (git-ignored). No disassembly
or decompilation was used. Ghidra, the IPSW and the reference tools folder
were not opened. The levels are as in AGENTS.md rule 4.

## Setup

- This Mac, Xcode 27.1, visionOS 27.0 runtime 24M362 (the chosen runtime
  for the `xros27.0` SDK). One device, `ycode-test-visionos-obs2`
  (Apple Vision Pro, 4K device type), created for this round and
  deleted at the end. No other simulator was touched.
- **Recorder.** A copy of Ycode's `mtlrec.m`, built with the visionOS
  simulator SDK like `build-visionos.sh` does. It was inserted with
  `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` and recorded backboardd only
  (`MTLREC_PROCS`). Three additions:
  1. A preference-read log. The four CFPreferences app-value functions
     are interposed, and `NSUserDefaults objectForKey:` is rerouted on
     the main thread. Each read is logged with key, domain, value and
     caller chain.
  2. The wall clock at load, so that recorder times can be matched
     with `log show`.
  3. An optional substitution of the `heapTextureSizeAndAlignWithDescriptor:`
     answer by R2a's host formula.

  A first build called `localtime_r` in its constructor. That deadlocked
  backboardd in `notify_register` before launchd's services were up, so
  the copy writes the raw epoch time. Ycode's own recorder does not have
  this problem; it is noted here for anyone who adds a clock to a
  constructor.
- **Boots.** b1: cold, caller chains, `dlopen`/`dlsym`, preference log.
  b2: an allocation window from `CALayerContentsCache`. b3: an allocation
  window from the render server's first device, filtered to "VFX". b4:
  the heap-size substitution. b5: frequent accessors as well
  (`MTLREC_ALL=1`). Each boot completed (`simctl bootstatus`) and
  logged "ImportGraphicsResources" and "Starting render loop". The windows slow
  the main thread a lot: b3 reached the engine start only after about
  31 s, and the start still completed.
- **Size probe** (`sizeprobe`, our own code): it asks the reference
  device for heap size-and-align answers. It covers 4 170 texture
  descriptors (14 pixel formats; sizes from 1 × 1 to 4096 × 4096; usages
  0, ShaderRead, ShaderRead + ShaderWrite, ShaderRead + RenderTarget and
  RenderTarget; one level or a full chain; the 1D, array, cube, 3D,
  texture-buffer and 4× multisample types). It also covers 45 buffer
  queries and 26 heaps, and places one texture in a heap. It ran with
  `simctl spawn`.

## What the reference start does (level 3)

- Up to the CA layer contents cache's device, the reference start under
  Ycode's recorder is the same as R2a's list under Ycode: the same
  stages, the same object counts and the same answers. The heap sizes
  are the only exception. The material manager makes ten 16-byte buffers
  and buffers of 64, 128, 1024, 2048 and 131 072 bytes, and ten sampler
  states. The texture manager makes 29 heap size queries and 29 heap
  textures, and waits for one blit upload. The shader manager loads
  three metallibs. The mesh manager makes a 64-buffer queue. The drawing
  manager makes two 1024-buffer queues, 67 fences, two shared events,
  two events, six textures and the clipping SDF array (262 region
  uploads). The CA render persistent data makes the 64 MiB heap and the
  `computeSDFGradient` pipeline. VISIONOS-OBS's shorter list (four
  buffers, four samplers, five heap textures) came from its recorder,
  which saw fewer calls.
- After the CA layer contents cache's device, the order is:
  1. the HistogramAndGlow and light-clustering defaults, and the "Device
     doesn't suport light clustering" message;
  2. the shadow render manager's constructor (allocations only);
  3. **the VFX manager's hookup**. It reads
     `com.apple.re.enableVFXUseRERenderCommandQueue` once (a guarded
     static), then calls `newCommandQueue` on the device. That becomes a
     queue descriptor with 64 buffers and medium QoS, and gets a label;
  4. the primitive renderer's 23 buffers, with the same sizes as under
     Ycode;
  5. the cascaded-shadow, decals and soft-shadow defaults.

  The render manager's start then returns. The engine continues with the
  deformation manager, the focus-level manager (about 70 breakthrough
  defaults), MR lighting, assets, a 15-argument encoder, a shared event
  and its handle, VFX client-side rendering, audio and video. The log
  shows "ImportGraphicsResources" about 3 ms after the last of the three
  defaults.
- So the VFX command queue does not end the start. It comes right before
  the primitive-shape stage. Under Ycode the shadow constructor and the
  primitive-shape stage run, but the hookup does not. This is the first
  stage whose result differs.
- The VFX manager is constructed and initialized in the engine start,
  before the render manager. Its initialization makes three dispatch
  queues and a cached command-encoder object. It makes no Metal call and
  reads no preference. The VFX, VFXBase and VFXAssets images are loaded
  in backboardd (vmmap) without any `dlopen`.
- Return offsets in the render manager's start (one cache, so they are
  comparable with Ycode's chains): material manager +1116, samplers
  +1208, texture manager +1392, shader manager +1448, mesh manager +1580,
  drawing manager +2100, shadow render manager +2968, VFX hookup +2996,
  primitive renderer +3344, the three defaults +3364, +3400, +3440. In the
  engine start: VFX manager construction +11440, its initialization
  +11452, the render manager +12152. These are level 4 facts.
- "Compiling PSO RT name=computeSDFGradient tgsimotew=0 fc=" is logged in
  every one of the five boots, repeat boots included. VISIONOS-OBS's
  "cold only" did not hold on this device, so the line is not a
  difference.
- Defaults: before "ImportGraphicsResources" backboardd reads 269
  distinct keys, 128 of them `com.apple.re.*`. Every `com.apple.re.*` key
  is unset. The keys with values are registered defaults read by the
  render server (`VirtualDisplayWidth` 2732, `VirtualDisplayHeight`
  2048, `VirtualDisplayRefreshRate` 90, `PointsPerMeter` 1000,
  `CurrentMaxNits` 108, `MaxEDRValue` 1, and others); no preference file
  of the device holds them.
- Properties read in the start: only the device's `name`, once, while
  the compute pipeline is made. No heap, resource-address or memory
  property is read before the VFX queue (b5 recorded every accessor).

## Heap sizes (level 3)

- The start's 31 size queries and their answers are in visionos.md
  §10.8.3. The texture-manager heap request (28 032) is the 29 answers
  placed one after another at their alignments. The CA heap request
  (67 633 280) is the 4096 × 4096 answer plus 128.
- b4 replaced every answer with R2a's host formula. The engine then asked
  for 69 632 and 67 108 992 bytes, the values seen under Ycode, and the
  start completed with the VFX queue. The heap sizes are therefore not
  the cause of the abort.
- The probe shows the following:
  - Heap buffers are always length, 256.
  - A heap's `size` and `currentAllocatedSize` are the request rounded up
    to 16 KiB, and `usedSize` grows by the placed texture's answer.
  - `maxAvailableSizeWithAlignment:` is size − used.
  - Heap textures report `allocatedSize` 0.
  - The minimum linear and texture-buffer alignments are 16 for every
    format tested.
  - The device's `recommendedMaxWorkingSetSize` is 0 and
    `hasUnifiedMemory` is NO.
- Texture answers follow a tiled layout with 16 KiB tiles and a
  compression-metadata term. The term is added for ShaderRead or
  RenderTarget textures of at least 16 × 16, and not for usage 0 or
  ShaderWrite textures. The fitted rule (stated in §10.8.3) reproduces
  every single-level 2D answer and every power-of-two mip chain. It does
  not reproduce non-power-of-two mip chains or 4× multisample textures.
  Our script `tools/fit2.py` checks the rule against the probe output.

## What is left (Q14)

- Why Ycode's render manager skips the hookup is not known. The reference
  shows no host-visible input that differs. The fault injections of
  VISIONOS-OBS also showed that a missing VFX queue does not fail the
  start. So the decision comes from engine state that was set before
  return offset +2996. The clean side can locate it with Ycode's own
  recorder (visionos.md §10.8.4 item 2). If that measurement points to a
  stage before the render manager, the same recorder windows can be run
  here on that stage for comparison.

## Evidence summary

| Claim | Level | Source |
|---|---|---|
| Start order, counts, VFX queue before the primitive-shape stage | 3 | Ycode's recorder in reference boots b1–b5 |
| Preference reads and their values | 3 | the recorder copy's preference log |
| Return offsets, component names | 4 | caller chains named with `dladdr` |
| Heap sizes are not the cause | 3 | b4 (substituted answers) |
| Size-and-align answers, heap rounding, alignments, the fitted rule | 3 | the start's own queries; our size probe |
| VFX images loaded without `dlopen` | 3 | `vmmap` of the reference backboardd; recorder `dlopen` log |

Level 5 was not used.

# The render manager's flag bytes and shared textures (agent VISIONOS-OBS3, 2026-10-27)

Dirty-room notes for `specs/simulator/visionos.md` §9 Q15 and Q16 and
§10.10, and for `metal-sim-protocol.md` §5.10. Prose only. The recorder
build, our probes, scripts, raw logs and the one level-5 extract are in
`research/dirty/visionos-obs3/` (git-ignored). Ghidra, the IPSW and the
reference tools folder were not opened. Nothing was decrypted.

## Setup

- This Mac, Xcode 27.1, visionOS 27.0 runtime 24M362 (the chosen runtime
  for the `xros27.0` SDK). One device, `ycode-test-visionos-obs3` (Apple
  Vision Pro, 4K device type), created for this round and deleted at the
  end. No other simulator was touched.
- **Recorder.** Ycode's `mtlrec.dylib` built unchanged with
  `build-visionos.sh` for boots q1–q5 and h1. For q6, q7 a copy with one
  addition, an answer substitution: for the names given, a caller that
  passes an 8-byte buffer to `sysctlbyname` and gets a 4-byte integer
  receives it as 8 bytes (zero-extended) with the returned length 8. The
  substitution is active only in the recorded process (backboardd).
- **Metal message recorder.** `mslog.c` from
  `research/experiments/simulator/metal-sim/`, built for the visionOS
  simulator SDK, in our probes (`simctl spawn`) and in backboardd and
  wakeboardd during whole boots (m1: the Metal connections; m2: the
  connections to `com.apple.wakeboard*`; m3: `com.apple.iokit*`).
- **Probes** (our own code): `sysctlsize` (how many bytes integer sysctls
  write for buffers of 2, 4, 8 and 16 bytes); `shtex2` (a shared texture
  made like wakeboardd's layers, its surface's values, its handle, the
  handle opened in the same process); `shtex3` (surfaces made with chosen
  creation properties, then a handle and `newSharedTextureWithHandle:`);
  `shtex4` (surface allocation size against the heap size answer).
- **Shared-cache slide.** The render manager's identifying word (+0x10,
  a CoreRE string) was `0x1b073c978` on the Mac too: the simulator's
  shared cache sits at the same address as under Ycode, so the block match
  of Q15 needed no adjustment.

## Q15: the bytes at the three points (level 3)

With the recorder settings of Q15 (q1; again in q5):

| Point | RM +0xd0 … +0xd7 |
|---|---|
| RM+1984 (render context manager constructed) | `01 00 00 00 01 01 00 00` |
| RM+2072 (after the CPU-count query) | `0e 00 00 00 01 01 00 00` |
| CA layer contents cache (later in the start) | `0e 00 00 00 01 01 00 00` |

So in the reference the two flag bytes stay 1. The u32 becomes 14, the
Mac's `hw.physicalcpu`.

**The bytes decide the start in the reference too.** q3: the recorder
wrote 0 into +0xd4 and +0xd5 at RM+1984. They stayed 0 at RM+2028,
RM+2072 and later, and backboardd aborted with "Render manager was
requested but failed to initialize" on every restart (four in the
window), exactly as under Ycode. So nothing in the span sets them again;
in the reference they are simply never cleared.

**What the span reads.** A look-up log of the start (q2, q4) shows the
same sequence in the reference as R2b found under Ycode: a default read
(the synchronous command queue) at RM+1836, its log line at RM+1932, the
render context manager (allocation at RM+1976, constructor at +1984), and
at RM+2028 the first CPU-count query of the whole process,
`sysctlbyname("hw.physicalcpu")`. No earlier `sysctl` of a CPU count
happens in backboardd. Because the span makes no other call, the clearing
under Ycode had to come from the one call it makes: the query itself.

**Level 5, once, and why.** Black-box levels could not name the input:
the span makes no call that a recorder can change (R2b ruled out the CPU
count, defaults, the engine configuration, the render manager's copy of
its configuration and its arguments), and its decision uses memory only.
To see which memory, the 36 instructions from RM+1936 to RM+2080 were
read from the loaded CoreRE in the reference device and disassembled
(extract and listing in `research/dirty/visionos-obs3/l5/`). Result,
stated as behavior: the render manager stores the render context
manager, frame manager and job service pointers, then asks
`sysctlbyname("hw.physicalcpu")` with the **address of its own field
+0xd0 as the buffer and a buffer length of 8**. Nothing else in the span
touches +0xd4 or +0xd5. The flag bytes are the four bytes after a 4-byte
integer inside that 8-byte buffer.

**Black-box confirmation (level 3).** The reference kernel writes a
4-byte integer sysctl as 4 bytes whatever the buffer size, and returns
length 4 (`sysctlsize`, table in §10.10.1 of the spec). Ycode's sysctl
table gives a caller whose buffer is exactly 8 bytes an 8-byte value, so
under Ycode the zero upper half of the count lands on +0xd4 … +0xd7. With
the recorder's substitution in the reference (q6: the same answer as
Ycode, for `hw.physicalcpu` only, in backboardd only), the bytes read
`0e 00 00 00 00 00 00 00` at RM+2072 (q7) and backboardd aborted with the
same assertion on every restart (13 in q6), with no render loop. The
substitution was made only at RM+2028 (the only 8-byte-buffer query of
that name in backboardd). A boot with the same recorder build and no
substitution (h1) started normally.

## Q16: shared textures (level 3)

**`messageType` 19 (our probe and wakeboardd in a boot).** Request:
`command`, an op-42 record of 44 bytes (header u32 42, u32 44, then the
36-byte texture descriptor of §5.2), and `messageType`. Reply, from the
macOS host: exactly two keys, `iosurfaceXPCObject` (a Mach send right)
and `replyData` (8 bytes: u32 texture ref, u32 0). No `fatalError` or
`error` key was present in any of 16 replies in a boot. wakeboardd made
16 shared textures in one boot: per layer, frames of a colour texture
(`BGRA8Unorm_sRGB`, word 1 `0x00510543`) and a depth texture
(`Depth32Float`, word 1 `0x00fc0543`), 3840 × 2160, 2D array of length 1,
private: two frames for layer 1, three each for layers 2 and 3.

**The surface.** In the guest the surface has width 0, height 0, 1 byte
per element, 0 bytes per row, pixel format 0 and no planes; its
allocation size is the heap size answer for the same descriptor plus 16
bytes (33 947 664 for the 3840 × 2160 layers, whose heap answer is
33 947 648 with alignment 16 384; 16 528 for a 64 × 64 BGRA8 ShaderRead
texture; 144 for 1 × 1). `IOSurfaceCopyAllValues` returns
`CreationProperties`, `HorizontalDisparityAdjustment` (0) and
`IOSurfaceName` ("Metal"). The creation properties are
`IOSurfaceAllocSize`, `IOSurfaceName` "Metal",
`IOSurfacePixelSizeCastingAllowed` 1, `IOSurfaceProtectionOptions` 0,
`kAGXCompressionMode` 0, and the `kMetal…` keys that describe the
texture (registry ID, type, pixel format, width, height, depth, array
length, mipmap level count, sample count, usage, resource options,
GPU optimization, swizzle key, rotation, CSC matrix, footprint, sparse
value, resource index, write access pattern). **There is no
`MetalSharedTexture` key**, in the creation properties or among the
surface's values.

**What a handle needs.** `newSharedTextureHandle` makes the handle from
the texture's surface; while doing so the guest reads the surface's
`CreationProperties` and then looks up its Metal devices. `shtex3`:
a surface whose creation properties hold `kMetalRegistryID` equal to the
device's `registryID` (a number) gives a handle whose device is the
simulator GPU; without that key, or with a different value, our probe
crashed inside the handle's initializer; a string value raised an
exception (the value is read as an unsigned 64-bit number). The R2b
guess that the handle needs `MetalSharedTexture` is wrong.

**Opening a handle sends `messageType` 20**, in the same process and in
a second process alike. Request: `command` (op 43, length 12, body u32
0), `iosurface` (the surface's Mach send right, obtained with
`IOSurfaceCreateXPCObject`), and `label` (string) when the handle has a
label. Reply: `replyData`, 36 bytes: u32 texture ref, then the
descriptor words 1–8 of the texture as the host knows it; the options
half of word 6 carries the hazard-tracking mode (`0x0220` for a private,
tracked texture) where the creation request had `0x0020`. In a boot,
backboardd sent twelve: layers 2 and 3, three frames, colour and depth,
labels "wakeboardd-layer N [frame i/3 protection:0 size:3840x2160
recorder:False]: Color (Layered)" or "…: Depth (Layered)"; wakeboardd
sent four for its own layer 1. For a surface the guest made itself with
the full `kMetal…` set, the host answered message 20 with the descriptor
read from those properties; with only `kMetalRegistryID`, the reply was
empty and `newSharedTextureWithHandle:` returned nil.

**How the handles travel (m2, h1).** backboardd calls wakeboardd's
`com.apple.wakeboard.hmdpresentable.owner` with an NSXPC message
`newControlledLayerWithObserver:channelRequest:completionHandler:`; the
reply carries an `NSXPCListenerEndpoint`, a ring-buffer channel
description and a proxy for the owned layer. wakeboardd then calls back
`ownedLayerDidStartWithLayerID:configuration:…` with the layer
configuration (colour format 81, depth format 252, usage 5, frame count
3, layout 2). The swapchain description reaches backboardd as an NSXPC
argument: a `cp_swapchain` whose links each decode textures; each texture
is an `MTLSharedTextureHandle` that encodes its IOSurface as an XPC
object (the handle refuses keyed archiving: "may only be encoded by an
NSXPCCoder"). backboardd turns that XPC object into a surface through
the IOSurface service (reply keys `Limits`, `MemoryObject`,
`SurfaceState`, `PropertiesDictionary`), reads its `CreationProperties`,
then calls `newSharedTextureWithHandle:`, which sends message 20 with the
surface's port (`MachPort` from the IOSurface service).

## Pulse, presence and the IOPM assertion (level 3)

- SurfBoard produces user presence itself in the simulator: during its own
  start, after it starts the inactivity shutdown scheduler, it logs
  "Acquiring simulated user presence assertion", takes an idle-timer
  assertion "SurfBoard Simulated User Presence" with user presence
  requested, then "User presence detected", "Transitioning headset to in
  use...", "Attempting to set hmd state to 2" and "Set hmd state to 2
  (wb:2), resulting state 2". No input from the host or from the user is
  involved. In this round's boots the first-boot semaphore existed, so
  wakeboardd went Config → Ready → RealTimeStarting → Run before SurfBoard
  started; §10.6.6 has the pulsing order.
- The reference backboardd logs no "Failed to acquire IOPM assertion". Its
  DisplayReveal logs "Acquiring wake assertion with identifier: …, reason:
  Initial Boot User Active" (backboardd's start) and "Relinquishing wake
  assertion …" about 40 s later. The power-assertion service in the
  device is host-side: `launchctl print user/501` lists
  `com.apple.PowerManagement.control` with flag H (host-side = 1), next
  to `com.apple.metal.simulator` and `com.apple.IOSurface.Remote`. It is a
  MIG service, not XPC (m3 recorded no XPC connection to it). Its message
  format was not recorded.

## Evidence summary

| Claim | Level | Source |
|---|---|---|
| Bytes at the three points; bytes cleared in the reference reproduce the abort | 3 | Ycode's recorder in boots q1, q3, q5 |
| Look-up sequence of the span; first CPU-count query of the process | 3 | recorder look-ups, q2, q4 |
| The span asks `hw.physicalcpu` into the render manager's +0xd0 with an 8-byte length | 5 | 36 instructions read from the loaded image and disassembled, kept in `research/dirty/visionos-obs3/l5/` |
| Integer sysctls write 4 bytes whatever the buffer | 3 | `sysctlsize` |
| An 8-byte answer clears the bytes and causes the abort | 3 | recorder substitution, q6, q7; control h1 |
| `messageType` 19 and 20 requests and replies | 3 | `mslog` in `shtex2`, `shtex3` and in the m1 boot |
| Surface values, creation properties, allocation size | 3 | `shtex2`, `shtex4` |
| What a handle needs | 3 | `shtex3` (seven cases) |
| Handle transport | 3, 4 | `mslog` m2 (NSXPC payload names), recorder look-ups with caller chains h1 (names by `dladdr`, level 4) |
| Simulated presence, DisplayReveal assertion, host-side power service | 3 | `log show` of SurfBoard, wakeboardd, backboardd; `launchctl print user/501`; `mslog` m3 |

Level 5 was used once, for the 36 instructions named above, after the
black-box levels had failed (reason above). Nothing derived from it
enters the specs except as behavior that the level-3 experiments q6/q7
confirm independently.

# Encoder records, layer events and the first frames (agent VISIONOS-OBS4, 2026-10-27)

Dirty-room notes for `specs/simulator/visionos.md` §9 Q18–Q20 and §10.12,
and for `metal-sim-protocol.md` §5.8 and §8. Prose only. Our probes, the
recorder copies, the scripts, raw logs and frames are in
`research/dirty/visionos-obs4/` (git-ignored). Ghidra, the IPSW and the
reference tools folder were not opened; nothing was disassembled or
decrypted.

## Setup

- This Mac, Xcode 27.1, visionOS 27.0 runtime 24M362, device
  `ycode-test-visionos-obs4` (Apple Vision Pro, 4K device type), created
  for this round and deleted at the end. No other simulator was touched.
- **Pulsing boots.** wakeboardd pulses only when the host-wide POSIX
  semaphore `wakeboardd.first-boot` is absent (§10.6.6). Before each boot
  that had to match Ycode's start (f2, m1, m2) we removed it with
  VISIONOS-OBS's `semunlink` tool; wakeboardd then went Config → Pulse and
  left Pulse at SurfBoard's "User presence detected", as under Ycode. Boot
  f1 was a boot of the freshly erased device with the semaphore present
  (no Pulse); it is used only for comparison. In f1 (erase and boot) our
  library was not loaded into wakeboardd; in the boots without erase it
  was.
- **layerpeek** (our own library): in wakeboardd it wraps
  `SFBSwapchainSwapAddSurface` and, for the first four swaps and every
  15th after them, locks the swapped IOSurface read-only and computes
  statistics over every 4th pixel of every 4th row (pixels with any
  non-zero byte, pixels with non-zero alpha, mean B, G, R, A); it keeps a
  4× downsampled copy whenever the surface changes between black and not
  black, and every 10 s. In backboardd it reroutes
  `-[MTLSimDevice newSharedTextureWithHandle:]` (public ObjC runtime),
  keeps the textures whose handle label says "Color", and twice a second
  copies slice 0 of each into a shared buffer with a blit on its own
  command queue and computes the same statistics.
- **mslog4**: `mslog.c` with one change (a send right is printed with its
  port name, read with libxpc's exported `xpc_mach_send_get_right`), built
  for the visionOS simulator SDK, in backboardd and wakeboardd with segment
  dumps (light mode).
- **mtlrec4**: Ycode's `mtlrec.m` with `MTLRenderCommandEncoder` added to
  its protocol list and the argument setters kept, in backboardd together
  with mslog4 (boot m2), so that encoder calls and the records they make
  can be matched in the same command buffer.
- **encprobe, encprobe2** (our own probes, `simctl spawn` with mslog4 and
  `MTL_DEBUG_LAYER=0`): one render and one compute encoder; each call
  under test is preceded by a separator record whose value is the step
  number (`setStencilReferenceValue:` with 1000 + step in the render
  encoder, `setStageInRegion:` with origin x 2000 + step in the compute
  encoder). With the validation layer on, the probe stopped at a pipeline
  with `maxVertexAmplificationCount` 2 ("not supported on this device"), so
  it was run with the layer off. encprobe2's command buffer killed the
  device's Metal host process ("Connection interrupted" on all three
  connections) after the submission had been recorded; it contained a
  colour store action and colour store-action options for attachment
  indices 2 and 3, which the pass did not have. The records were already
  captured.
- Boots: f1 (erased, no Pulse; layerpeek, screenshots every 2 s), f2
  (Pulse; layerpeek, screenshots every 1 s), m1 (Pulse; mslog4 in
  backboardd and wakeboardd), m2 (Pulse; mtlrec4 and mslog4 in
  backboardd). Each reached `bootstatus` and the home view in the living
  room.

## Q18: the encoder records (level 3)

The probes show each call's record directly (separator, record,
separator):

- **24** is `updateFence:afterStages:` and **25** is
  `waitForFence:beforeStages:` of the render encoder. Body: u32 fence ref,
  u32 render stages (`MTLRenderStages`: 1 vertex, 2 fragment, 3 both).
  The fence ref is the one `newFence` returned (fences have their own
  counter from 1). So `04 00 00 00 02 00 00 00` is "fence 4, fragment
  stage".
- **212** is the compute encoder's `updateFence:` and **213** its
  `waitForFence:`; body u32 fence ref (0x34 and 0x10 are fence refs).
- **132** is `setVisibilityResultMode:offset:`; body u64 offset, then u64
  mode (0 disabled, 1 boolean, 2 counting): Boolean with offset 8 gave
  `08 0… 01 0…`; Counting with 0x30 gave `30 0… 02 0…`; Disabled with
  offset 0x123 kept the offset. backboardd sends Disabled, 0.

**In backboardd.** In boot m2 the recorder saw backboardd call
`updateFence:afterStages:` and `waitForFence:beforeStages:` with stage 2
only, `setVisibilityResultMode:offset:` with 0, 0, and the compute
encoder (class `MTLSerializerComputeCommandEncoder`) `updateFence:` and
`waitForFence:`. In one command buffer the calls and the records match
one for one: the compute encoder `waitForFence:` (fence A),
`setComputePipelineState:`, three `setTexture:atIndex:`, five
`setBuffer:offset:atIndex:`, one dispatch, `updateFence:` (fence B) was
the segment 213 (14), 208, 206 ×3, 203 ×5, 200, 212 (15); the next render
encoder's `waitForFence:beforeStages:` A, 2 and B, 2, then pipeline,
depth-stencil state, cull mode, winding, viewports, three
`setVertexBytes`, four `setFragmentBytes`, one instanced draw,
`useResources:count:usage:stages:`, cull mode, fill mode, stencil
reference and the closing `updateFence:afterStages:` was the segment 26,
25 (14, 2), 25 (15, 2), 116, 104, 107, 115, 131, 125 ×6, 110 ×8, 5, 137,
107, 124, 119, 24 (16, 2). Each `set…Bytes` call makes two binding records
(below).

Counts in boot m1 (≈ 50 s of backboardd): 24: 11 690, 25: 29 893, 132:
15 139, 212: 2 890, 213: 28 042. backboardd creates and releases fences
all the time (14 652 `newFence` requests, `messageType` 12 op 13, in the
same boot); fence refs are reused (they stayed below 70). No other record
op that §8 does not list appears in backboardd or wakeboardd.

**Other records the probes made** (not used by backboardd or wakeboardd):

| Op | Call | Body |
|---|---|---|
| 22 | render `memoryBarrierWithResources:count:afterStages:beforeStages:` | u32 count, u16 after stages, u16 before stages, u32 ref × count |
| 27 | render `useHeap:stages:`, `useHeaps:count:stages:` | u32 count, u16 stages, then u32 heap ref × count starting at byte 6 (unaligned), zero-padded to a multiple of 4 |
| 134 | `useHeap:`, `useHeaps:count:` (render and compute) | u32 count, u32 heap ref × count |
| 118 | `setScissorRects:count:` | u32 count, u32 0, then per rect u64 x, y, width, height |
| 103 | `setColorStoreActionOptions:atIndex:` | u64 options, u32 index |
| 105 | `setDepthStoreAction:` | u64 action |
| 106 | `setDepthStoreActionOptions:` | u64 options |
| 120 | `setStencilStoreAction:` | u64 action |
| 121 | `setStencilStoreActionOptions:` | u64 options |

Corrections and confirmations of §8:

- **Buffer range form (125, 110, 203 with count > 1)**: per slot, a u32
  ref followed by its u64 offset (pairs, unaligned), not all refs then all
  offsets. `setVertexBuffers:{a, b} offsets:{16, 32} withRange:{5, 2}`
  gave index 5, count 2, ref a, offset 16, ref b, offset 32. The body
  length is the same for both readings, so a length check cannot tell
  them apart.
- **102** `setColorStoreAction:atIndex:`: u32 action, then u32 index
  (action 1 index 0; action 2 index 2).
- **209** `setStageInRegion:`: the six u64 are the **size** first, then the
  origin (origin x 2035, size 1, 1, 1 gave 1, 1, 1, 2035, 0, 0).
- **`setVertexBytes`, `setFragmentBytes` and the compute `setBytes`** each
  make two binding records (125, 110 or 203, count 1) naming the driver's
  inline-bytes buffer, the second with an offset 256 bytes past the
  first's (0 and 0x100; 0x200 and 0x300; 0x400 and 0x500), whatever the
  length (16 or 64 bytes).
- 135, 137, 211, 215, 23 as §8 lists them; 23 confirmed as u16 scope,
  u8 after, u8 before.
- No record: `setVertexAmplificationCount:viewMappings:` (the device
  answers `supportsVertexAmplificationCount:` 2 with NO; backboardd asks
  it repeatedly, 2 048 times in its first 12 s in m2, and gets NO), the compute `setImageblockWidth:height:`.
  `setTileBytes:length:atIndex:` and
  `setThreadgroupMemoryLength:offset:atIndex:` are not implemented by the
  simulator's render encoder (unrecognized selector).

## Q19: the layer events (level 3)

In boot m1 (and in VISIONOS-OBS3's m1 capture, which shows the same
pattern without port names):

| Process | 17 | 18 |
|---|---|---|
| wakeboardd | 3: event refs 1 and 2 (for the layers it hands to backboardd), then 3 (for its own Apple-logo layer) | 2: one pair for its own layer |
| backboardd | 1: its own event ref 3, at start-up, not a layer event | 4: one pair for each of its two layers |

So per layer: one 17 by the layer's owner (wakeboardd), and two 18 by
the process that opens the layer, sent within half a millisecond of each
other:

1. `eventPort` = a real send right, `command` op 40 (body u32 0), and
   `label` "Did all render event for layer=N pid=P <process name>" (for
   example "… layer=1 pid=6050 backboardd", "… layer=3 pid=6039 Apple
   Logo"). Reply: `replyData` 8 bytes, u32 event ref, u32 0.
2. `eventPort` = **MACH_PORT_NULL** (port name 0), `command` op 40, no
   `label`. Reply: **an empty dictionary** (no `replyData`, no `error`).

The recorder in backboardd (m2) shows where the second comes from:
backboardd calls `newSharedEventWithHandle:` twice per layer, the second
time with a **nil handle**, and in the reference that call returns **nil**.
Under Ycode the host answers the null-port 18 with a fresh event, so
backboardd gets an event object where the reference gets nil.

What the layer events carry (m1): backboardd's two opened events (refs 4
and 5) are signalled once per presented frame by a GPU signal in a small
command buffer committed right after the frame's command buffer. The
small command buffer is: signal own event 1 = n, signal own event 2 = n,
wait event 4 = n − 1, signal event 4 = n, wait event 5 = m − 1, signal
event 5 = m. The frame's command buffer begins with a wait on event 2 =
n − 1. wakeboardd's command buffers never wait for or signal its exported
refs 1 and 2 (it signals only the event it opened for its own logo
layer, as backboardd does for its layers); it reads their values from the
CPU, `messageType` 12 op 41 on its exported
refs 1 and 2, once per swap and layer (2 703 and 2 704 reads in the boot);
the values it reads follow backboardd's signals (last read 2 210 and 2 199
against backboardd's last signals 2 212 and 2 201). The frame slot of a
layer that a signal announces is (value − 1) mod 3: event 4 = 12 followed
the frame that resolved into layer 1's frame 3/3, 13 into frame 1/3, 14
into 2/3; event 5 = 1 followed layer 2's frame 1/3, 2 frame 2/3, 3 frame
3/3. The eleven warm-up frames at the start of the render loop signal
only backboardd's own events 1 and 2, not the layer events; the first
layer-event signals are those of the first frame after Run (event 4 = 12,
event 5 = 1).

## Q20: the first frames after Run (level 3)

**Boot f2 (Pulse), swapped surfaces in wakeboardd.** SurfBoard logged
"User presence detected" at 27.278 (wall clock of that boot), wakeboardd
went Pulse → RealTimeStarting → Run and the first `SwapAddSurface` came at
27.284. The surfaces are 3840 × 2160, 15 360 bytes per row, pixel format
`BGRA`, two alternating. Their content:

| Time | Swaps | Content |
|---|---|---|
| 27.284 | 1 … 44 | all bytes zero (alpha zero too) |
| 28.03 … 34.4 | 45 … ~430 | the Apple logo, a 36 × 45 sample region at the centre (≈ 0.2 % of samples), alpha at most 3 of 255 in the samples, colour ≈ 0 |
| 34.53 … 35.5 | ~435 … 495 | the room and home view fade in: mean (R, G, B, A) from (34, 33, 30, 11) to (160, 156, 146, 255) |
| from 35.5 | | the room with the home view, opaque, unchanged statistics |

So the display is black (and transparent) for about 7.25 s after Run. The
room appears about 50 ms after backboardd logs "Compiling PSO …
name=composeSyntheticEnvironmentDefinition
tech=ComposeWithSyntheticEnvironment vtx=fullScreen2Vert frag=fsCompose"
(34.477). Before that come RealityEnvironment's "Active synthetic
environment changed to LivingRoomDay" (32.415), backboardd's asset load of
the render graph `composeSyntheticEnvironment.rerendergraph` (32.658 to
32.669) and RealityLauncher's "Reveal transition appearance state changed
[isVisible: true, name: Applications, type: app, newValue: appearing]"
(33.118). In m1 the same sequence ran (Run at 07.056, environment set at
12.054, render graph at 12.336, continuous rendering from about 14.2).

**Boot f2, backboardd's layer textures.** backboardd opened the six
colour and six depth layer textures at 24.37, 70 ms after "Starting
render loop". The colour textures (2D array, `BGRA8Unorm_sRGB`,
3840 × 2160, array length 1) read back **all zero, alpha included**, from
the first sample (25.39) until Run. In the first sample after Run (27.48)
layer 1 (slot Top) frame 1/3 held the Apple logo (alpha up to 41 of 255);
layer 2 (slot SyntheticPassthrough) was still all zero. From the sample
at 34.95, layer 1's frames held the home view's icons on a transparent
background (≈ 2 % of samples non-zero) and layer 2's frames the room,
opaque (mean R, G, B ≈ 160, 155, 145; A 255). Later samples of single
frames sometimes read all zero (a frame being cleared when sampled).

**Boot f1 (no Pulse, for comparison).** wakeboardd went Config → Ready →
Run at once. backboardd's layer 2 (Top in that boot) read all zero for
3.6 s, then full-screen opaque black (alpha 255) that faded out over
about 5 s (the DisplayReveal obscuring), then zero, then the home icons;
layer 3 (passthrough) went from zero to opaque black and then to the room.
Screenshots showed black, the boot logo with a progress bar, black, then
the room.

**Reference frame.** `research/dirty/visionos-obs4/reference-frame-swap600-960x540.png`
is the 600th swapped surface of boot f2 (10 s after Run), downsampled
4×: the simulated living room by day (sofa in the foreground, a low
table, a television on a sideboard against the back wall, framed plant
prints on the left wall, floor lamps, a shelf unit on the right, a window
with curtains), with the home view floating in front of the back wall:
two rows of round app icons (Widgets, Siri, Safari, Photos; More Apps,
Settings, Files, Passwords) and a small vertical tab bar at their left.

## What backboardd renders into the layers (level 3, boot m1)

The layers are written by ordinary render passes whose attachments are
the refs that `messageType` 20 returned to backboardd:

| Layer (slot) | How it is written |
|---|---|
| 1 (Top) | As the **resolve attachment** of colour attachment 0: colour 0 is backboardd's own 2D-multisample texture (`BGRA8Unorm_sRGB`, 4 samples, 3840 × 2160, private), depth a 4-sample `Depth32Float_Stencil8` texture; load action Clear, clear colour (0, 0, 0, 0), store action **MultisampleResolve**, resolve level 0, slice 0; the depth store action is DontCare |
| 2 (SyntheticPassthrough) | As **colour attachment 0** directly, with the layer's own depth texture as the depth attachment: load Clear, clear colour (0, 0, 0, 0), store Store; later in the same frame a second pass on the same colour texture with load Load, store Store, no depth, one indexed draw of 6 indices |

The 4× pass is the one with many draws: in a steady-state frame it has
19 draws, most of them short indexed draws of 6 132 indices. The same pass
began every one of the eleven warm-up frames too (one draw each); so
the Top layer frames were cleared to (0, 0, 0, 0) through the resolve
before Run.

A steady-state frame (60 per second once the room is shown) is one
command buffer on backboardd's queue 3 with, in order: wait for own event
2 = n − 1; layer 2 frame k (clear, 1 draw); an own 3840 × 2160
`BGRA8Unorm_sRGB` target with depth (clear (0, 0, 0, 1), 6 draws); a
160 × 128 two-slice `RGBA16Float` target (1 draw); a compute encoder (28
records, dispatches); the 4× pass resolving into layer 1 frame k
(19 draws); layer 2 frame k again (load, 1 draw). The render and compute
encoders are chained by fences (24/25, 212/213), and small blit encoders
(fills and fence updates) sit between them. Then the small command buffer
with the event signals of Q19.

**Cadence.** backboardd does not draw every display frame before the
room is ready: eleven warm-up frames at the start of the render loop
(about 11 ms apart, "Render loop did finish warming frames"), then
nothing until Run; at Run one frame (layer 2 frame 1/3 and layer 1 frame
3/3, one draw each: the logo); then almost nothing for about 7 s; then
continuous rendering at 60 frames per second from the moment the
environment's compose pass is ready. wakeboardd swaps 60 times per second
throughout and shows the last frame each layer's event announces.

## Evidence summary

| Claim | Level | Source |
|---|---|---|
| Ops 24, 25, 132, 212, 213 and the other records of the table; corrections to 102, 209 and the range form; two records per `set…Bytes` | 3 | encprobe, encprobe2 under mslog4 (separator records) |
| The same calls in backboardd make those records in the same command buffer; counts | 3 | boot m2 (mtlrec4 and mslog4 in backboardd); boot m1 (mslog4) |
| 17/18 per layer, the null port, the empty reply, nil from `newSharedEventWithHandle:` | 3 | mslog4 in boot m1 (port names); mtlrec4 in boot m2; OBS3's m1 capture |
| Layer events: signals, waits, CPU reads, value → frame slot | 3 | mslog4 in backboardd and wakeboardd, boot m1 |
| Swapped-surface and layer content over time; reference frame | 3 | layerpeek in boots f1, f2; `simctl io screenshot` |
| Log lines and their times | 3 | `log show` of backboardd, wakeboardd, SurfBoard, RealityEnvironment, RealityLauncher in each boot |
| How the layers are written; frame structure and cadence | 3 | mslog4 segment dumps of boot m1, decoded with our scripts |

Level 5 was not used.

# Where the room's asset comes from (agent VISIONOS-OBS5, 2026-10-27)

Dirty-room observations for `specs/simulator/visionos.md` §9 Q21 and
§10.15. Prose only. Our recorder library, probe, scripts, raw logs,
listings and screenshots are in `research/dirty/visionos-obs5/`
(git-ignored). Ghidra, the IPSW and the reference tools folder were not
opened; nothing was disassembled or decrypted.

## Setup

- This Mac, Xcode 27.1, visionOS 27.0 runtime 24M362 (selected by its
  bundle path when the device was created), device
  `ycode-test-visionos-obs5` (Apple Vision Pro, 4K device type), created
  for this round and deleted at the end. No other simulator was touched.
  Every boot was a first boot: the device was erased before each.
- No Mac-wide state was changed. The `wakeboardd.first-boot` semaphore was
  left as it was (these questions do not need a pulsing boot), no system
  setting was changed and no dialog was clicked.
- Capture per boot: `simctl spawn … log stream` and `log show` (info and
  debug) of mobileassetd, RealityEnvironment, nsurlsessiond, backboardd,
  wakeboardd, RealityLauncher, SurfBoard and the subsystems
  `com.apple.SystemEnvironments*` and `com.apple.MobileAsset*`; `lsof` of
  the guest's mobileassetd, RealityEnvironment and nsurlsessiond every few
  seconds (guest processes are ordinary processes of the Mac, so `lsof`,
  `lsof -i`, `nettop` and `ps eww` work without privileges); `simctl io
  screenshot`; listings of `DEV/data` after the boot.
- **fsrec** (our own library, inserted with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`):
  in the processes it is told to watch it logs every `open`, `openat`,
  `stat`, `lstat`, `fstatat`, `access`, `getattrlist`, `getattrlistbulk`
  (with a hex copy of the returned records), `__getdirentries64`,
  `readlink`, `fopen`, `mmap` of a file and the non-cancelable opens, each
  with path, flags and result. Two optional switches: one refuses every
  `connect`/`connectx` to a non-loopback IPv4 or IPv6 address in every
  guest process (ENETUNREACH), which takes the guest off the network
  without touching the Mac's settings; the other rewrites the records that
  `getattrlistbulk` returns for one directory (see boot b5).
- **bulkprobe** (our own probe, built for the Mac and for the visionOS
  simulator SDK): one `getattrlistbulk` call per combination of three
  request sets and four option values, printing the returned common set and
  the word after the attribute set of the first record.

| Boot | What was added | Network |
|---|---|---|
| b1 | nothing | on |
| b2 | fsrec in RealityEnvironment and mobileassetd | on |
| b3 | fsrec in RealityEnvironment, backboardd, mobileassetd, nsurlsessiond; connects refused in every guest process | off for the guest |
| b4 | fsrec (with `fopen`/`mmap`) in RealityEnvironment and backboardd | on |
| b5 | fsrec in RealityEnvironment; its `getattrlistbulk` records for the rooms folder rewritten to carry `ATTR_CMN_ERROR` | on |

## Q21 (a): the catalog block (level 3)

In b1 RealityEnvironment's SystemEnvironments logs "Catalog assets [28]"
5 ms after mobileassetd's answer. Each of the six rooms appears twice:

- `state=installed`, a version `1.1.19` to `1.1.23`, an `assetID`, and
  `path=RR/System/Library/Assets/SystemEnvironments/SyntheticEnvironments/<room>/AssetData`;
- `state=unavailable version=1.0.0` with another `assetID` and no path
  (the same entry that Ycode's guest lists).

`Starfish` is `state=unavailable`; the fifteen immersive Environments are
`state=notPresent`. "Chosen assets [22]" then names the installed entry of
each room (for example "primary: [LivingRoomDay] { state=installed
version=1.1.20 … }"). The version is the room's `Info.plist`
`MobileAssetProperties` values `_CompatibilityVersion`.`ContentMajorVersion`.`ContentMinorVersion`
(KitchenDay 1.1.23, LivingRoomNight 1.1.19). How the `assetID` of an
installed room is formed was not found (it is not the SHA-1 of the room
name, of the bundle name, of the path or of the `Info.plist` bytes).

The same block after the catalog download (b1, 60 s later) has 49 entries;
the rooms are still listed as installed from the runtime.

## Q21 (b): mobileassetd (level 3)

mobileassetd's answer is the same as under Ycode. In b1, at the first
query (MA_QUERY_ASSET_TYPE, return type 2): "Catalog fileLocation:
DEV/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_SystemEnvironmentAsset/com_apple_MobileAsset_SystemEnvironmentAsset.xml",
"Could not load catalog", then "determineAssets: … found 0 assets with
result 2 (MAQueryCatalogNotDownloaded) --> From 0 listed in the catalog and
0 local (0/0 downloaded, 0 preinstalled) … 0 installedNotInCatalog, 0
installedWithOS, 0 requiredByOS; --> Merged to 0 assets". fsrec in
mobileassetd (b2) shows the same failed look-up as under Ycode:
`getattrlist` of `DEV/data/System/Library/AssetsV2/PreinstalledAssetsV2/InstallWithOs`
→ ENOENT. mobileassetd never opens the rooms folder.

After the catalog download (b1): "found 21 assets with result 0
(MAQuerySuccessful) --> From 21 listed in the catalog and 0 local (0/0
downloaded, 0 preinstalled) … (0 installed, 21 server-only, 0
preinstalled) … 0 installedWithOS". The downloaded catalog lists 21 assets
under 16 `EnvironmentKey` values (the immersive Environments and
`Starfish`); none of the six rooms is in it. MobileAsset never counts the
rooms; RealityEnvironment adds them itself.

## Q21 (c): the room without the network (level 3)

In b3 the guest had no network (fsrec refused 156 connects in
nsurlsessiond and 60 in mobileassetd; the Mac kept its network).
RealityEnvironment logged "Catalog assets [28]" with the six rooms
installed, "Active synthetic environment changed to LivingRoomDay" 0.1 s
later, "Setting synthetic environment asset { name=LivingRoomDay,
path=…/AssetData/livingroom_day.usdc }", and backboardd compiled
`composeSyntheticEnvironmentDefinition` about 0.5 s after that. Screenshots 42 s
and 119 s after the boot command show the living room with the home view.
The catalog download began 60 s after the query ("Done waiting for MA
daemon, catalog download starting") and failed: mobileassetd "Sending
download result 60 (MADownloadCannotConnectToHost)"; RealityEnvironment
"Refreshing assets failed: SystemEnvironments.AssetError.downloadError(SystemEnvironments.AssetError.DownloadError.mobileAsset(60)),
retrying in 60.0…". Nothing else changed; the room stayed. In b1 (network
on) too the room was active and composed a full minute before the first
catalog download began.

## Q21 (d): files after the boot, and who opens what (level 3)

`DEV/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_SystemEnvironmentAsset/`
after a boot with the network: only the catalog
`com_apple_MobileAsset_SystemEnvironmentAsset.xml` (29 623 bytes) and a
copy of it named `….xml.purged`, both written by the catalog download; no
`.asset` folder. After the boot without the network the folder does not
exist. No room is ever downloaded or copied into the device.

Opens of room files (fsrec, b2–b4; `SE` =
`RR/System/Library/Assets/SystemEnvironments/SyntheticEnvironments`):

| Process | Path | How |
|---|---|---|
| RealityEnvironment | `SE` and every directory below it | listed (below) |
| RealityEnvironment | `SE/<room>/Info.plist`, six rooms | `open` read-only, non-blocking ("Loading tuning data. { name='Info.plist' …}") |
| RealityEnvironment | `SE/<room>/AssetData/Config.plist`, six rooms | `getattrlist`, then `open` read-only ("Attempting to configure environment. { name=… state=installed }") |
| RealityEnvironment | `SE/LivingRoomDay/AssetData/livingroom_day.usdc` | `stat` and `getattrlist` only |
| backboardd | the same `.usdc` | `stat`, `lstat`, then `fopen` "rb" and a read-only `mmap` of the whole file (twice: two loads) |
| backboardd | the six `.ktx` files in `SE/LivingRoomDay/AssetData/0/` | `lstat`, `fopen` "rb", read-only `mmap` of the whole file |

The scene file name is the `combinedScene` value of `Config.plist`. Only
the active room's scene and textures are opened.

## Where the asset comes from

From the runtime itself. The rooms are files of the runtime disk image
(mounted read-only at `/Library/Developer/CoreSimulator/Volumes/xrOS_24M362`,
sealed APFS), reached through the runtime root that every guest process
already uses. Not from MobileAsset, not from the network, not from a host
service, a shared folder or a mount. No environment variable names an
asset location: the guest processes' variables are the usual ones
(`SIMULATOR_ROOT` and `IPHONE_SIMULATOR_ROOT` = the runtime root; `HOME`,
`CFFIXED_USER_HOME`, `SIMULATOR_SHARED_RESOURCES_DIRECTORY`,
`IPHONE_SHARED_RESOURCES_DIRECTORY` = `DEV/data`; `TMPDIR`, the
`SIMULATOR_MAINSCREEN_*`, `SIMULATOR_MODEL_IDENTIFIER` RealityDevice14,1,
`SIMULATOR_PRODUCT_CLASS` N301, `SIMULATOR_RUNTIME_*` and the CoreSimulator
socket and framework paths). RealityEnvironment builds the room folder
path from the root: before the listing it `lstat`s
`RR/AppleInternal/Assets/SystemEnvironments/{KnownEnvironmentsInternal.plist,EphemeralEnvironments,InternalEnvironments,ExternalEnvironments}`
(all ENOENT) and `SE` (a directory).

**Network, for the record.** The guest's mobileassetd and nsurlsessiond
open TCP connections from the Mac's own address to Apple hosts on port 443
(`lsof -i`); the SystemEnvironmentAsset catalog comes from the Pallas
service ("Using Pallas URL 'https://gdmf.apple.com/v2/assets' via selection
'Customer External'"; a log line names a `mesu.apple.com/assets/visionos/…`
XML fallback that this asset type does not use). We downloaded nothing
ourselves.

## Why Ycode's guest does not see the rooms (level 3)

RealityEnvironment finds the rooms with a deep, depth-first listing of
`SE` (one thread, about 7 ms):

1. `getattrlist` of `SE` with `ATTR_CMN_RETURNED_ATTRS`, `FULLPATH`,
   `OBJTYPE`, `DEVID` (options `FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS |
   FSOPT_ATTR_CMN_EXTENDED`); `getattrlist` of `SE` with the set of step 3
   (options `FSOPT_NOFOLLOW | FSOPT_REPORT_FULLSIZE | FSOPT_ATTR_CMN_EXTENDED`);
   `getattrlist` of `SE` with `ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES`.
2. `open(SE, O_RDONLY | O_DIRECTORY | O_CLOEXEC)`.
3. `getattrlistbulk` with common `0xf01f9e0d` (returned attrs, name, fsid,
   objtype, the four times, owner, group, access mask, flags, generation
   count, document id, added time, error, data-protection flags), dir
   `0x5` (link count, mount status), file `0x1` (link count), extended
   `0x240` (real device id, extended flags), options `0x20`
   (`FSOPT_ATTR_CMN_EXTENDED`), buffer 18 600 bytes → 6 records.
4. For each record whose object type is a directory, before the next
   record is used: open that directory by its full path (same flags) and
   list it the same way; each listing is read until `getattrlistbulk`
   returns 0. So: `SE/LivingRoomDay` (2: `AssetData` directory,
   `Info.plist` file), `…/AssetData` (4), `…/AssetData/0` (5 or 6), then
   the next room.
5. After the whole tree: the six `Info.plist` reads.

Every record the reference returns has returned common set `0xd01f9e0d`,
that is everything requested **except `ATTR_CMN_ERROR`**, and **no error
word**: the name reference follows the 20-byte attribute set directly.
Directories return dir `0x5` and file 0, files dir 0 and file `0x1`;
extended `0x240` always; object type 2 for directories, 1 for files;
record lengths 184 to 232 bytes, multiples of 8.

bulkprobe on the rooms folder (in the guest and on the Mac) and on
`DEV/data/Library` (in the guest), APFS in every case: with
`FSOPT_PACK_INVAL_ATTRS` (options `0x8` or `0x28`) the returned common set
equals the requested one, `ATTR_CMN_ERROR` included, and a zero error word
follows the attribute set; without it (`0x0`, `0x20`) neither the bit nor
the word is there. A request without `ATTR_CMN_ERROR` never gets it.
`specs/simulator/first-boot.md` §3 item 2 says that getattrlistbulk packs
the error word even without an error; that holds only with
`FSOPT_PACK_INVAL_ATTRS`.

Ycode's `getattrlistbulk` returns the bit and packs a zero word for every
record whenever the bit is requested. **Boot b5 reproduces Ycode's failure
in the reference**: fsrec rewrote the records of the two listings of `SE`
into that form (bit added to the returned set, zero word inserted after
the set, record padded to 8 bytes; nothing else changed). RealityEnvironment
then opened `SE` and listed it, opened nothing below it and read no
`Info.plist`; "Catalog assets [22]" had `[LivingRoomDay] { state=unavailable
version=1.0.0 … }` only; "Active synthetic environment changed to
LivingRoomDay" was followed 60 ms later by "setSyntheticSceneAsset: Error
loading asset: SystemEnvironments.EnvironmentAssetError.configurationError";
backboardd never compiled `composeSyntheticEnvironmentDefinition`. The
screenshot shows the home view's icons on black. These are R4b's lines
under Ycode (§10.14.3), in order.

## Evidence summary

| Claim | Level | Source |
|---|---|---|
| Catalog block, chosen assets, versions, paths, states | 3 | `log show` of RealityEnvironment, boots b1–b4 |
| mobileassetd answers, catalog location, the InstallWithOs look-up | 3 | `log show` of mobileassetd (b1); fsrec in mobileassetd (b2) |
| Downloaded catalog: 21 assets, no room | 3 | the device's catalog file read with `plistlib` (key names and `EnvironmentKey` values only) |
| Room loads without the guest's network; download error 60; retry | 3 | boot b3 (fsrec refusing connects), `log show`, screenshots |
| Files under `AssetsV2` after a boot | 3 | `find` of `DEV/data` after b1–b4 |
| Opens of the room files and by which process | 3 | fsrec in RealityEnvironment, backboardd (b2–b4) |
| No asset variable, host folder or mount | 3 | `ps eww` of the guest processes; `mount`; fsrec path lists |
| Network hosts | 3 | mobileassetd log lines; `lsof -i`, `nettop` (b1) |
| The listing sequence, request sets, returned records | 3 | fsrec records decoded with our script (b2, b4) |
| `ATTR_CMN_ERROR` packing rule | 3 | bulkprobe on the Mac and in the guest |
| Ycode's record form reproduces the failure in the reference | 3 | boot b5 |
| Ycode packs the error word in every record | — | Ycode's `AttributeList.swift` (our own code) |

Level 5 was not used.

# Guest audio: what the host's audio service answers (agent VISIONOS-OBS6, 2026-10-27)

Dirty-room observations for `specs/simulator/visionos.md` §9 Q22 and
§10.17, and the boundary spec `specs/simulator/audio-host.md`. Prose only.
Our recorder, probe, scripts, raw logs and screenshots are in
`research/dirty/visionos-obs6/` (git-ignored). Ghidra, the IPSW and the
reference tools folder were not opened; nothing was disassembled or
decrypted; level 4 was not needed.

## Setup

- This Mac, Xcode 27.1. visionOS 27.0 runtime 24M362, device
  `ycode-test-vos-audio-1` (Apple Vision Pro, 4K device type); iOS 27.1
  (24A94401), device `ycode-test-ios-audio-1` (the only device type that
  runtime accepts here). Both created for this round and deleted at the
  end; no other simulator was touched. visionOS boots were first boots (the
  device erased before each). The iOS device's first boot with the
  recorder failed to start launchd_sim once; a plain first boot followed,
  and the recorded iOS boot `i1` was its second boot.
- No Mac setting was changed. Audio went to the Mac's default output (a
  Bluetooth headset at the time); our probe's IO wrote silence (or values
  of 10⁻²⁰), and one probe run played the keyboard-click system sound in
  the iOS guest.
- **audrec** (our own library, inserted into every guest process with
  `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`): interposes `mach_msg`,
  `mach_msg_overwrite` and `mach_msg2_internal` and logs, with send and
  receive sizes, options and timeouts, every message sent to a port that
  came from a look-up of an audio name or arrived in a message from one,
  every message sent by an audio image, and the replies (header,
  descriptors, inline bytes, out-of-line data); the look-ups and XPC
  connections of names containing "audio"; eventlink, semaphore, memory
  entry and mapping calls; workgroup creation from a port; opens and
  renames of the simulator audio files. Optional parts: a dump of the
  mapped IO region at chosen cycles; a relay that puts a port of its own
  in place of the client's notification port, logs every notification and
  forwards or drops it; and reply rewriting (empty object lists, a device
  list reduced to one device plus the client's own aggregates, empty
  control and custom-property lists, an error for aggregate creation, a
  null or failed workgroup reply), and failing look-ups of chosen names
  (1102).
- **audprobe** (our own probe, built for both simulator SDKs, run with
  `simctl spawn`): lists the system object and every device, stream and
  their properties through the public CoreAudio property API, optionally
  runs an output IOProc on the default output device for 1 or 2 s
  (counting callbacks and printing the timestamps it receives), or plays a
  system sound.
- Scripts: `hal.py` (one line per request and reply, four-character codes
  and text decoded), `seltab.py` (requests grouped by message, selector,
  scope and object class), `region.py` (IO region fields per cycle).

| Boot | Recorder setting | Purpose |
|---|---|---|
| b1 | none | Q22 (a), (c) as the reference does it |
| b2 | recorder in every process, region dump every 1000 cycles | the full protocol |
| b3 | `com.apple.audio.audiohald` and `…coreaudiod` look-ups fail | Q22 (d) |
| b4 | object lists reduced, device list one device | first try at a minimal service (aggregate missing from the list: invalid, see below) |
| b4b | as b4, and the client's own aggregates kept in the list | minimal lists |
| b5 | aggregate creation answered with an error | is the aggregate needed |
| b6 | as b4b, and control and custom-property lists empty | smaller still |
| b7 | full, notifications relayed and logged, 8 KiB dumps | notifications, whole property lists |
| b8 | as b6, notifications dropped | the minimal service |
| i1 | iOS, recorder in every process | iOS comparison |

## Q22 (a): backboardd's PHASE start and the default output device (level 3)

Boot b1 (no recorder): backboardd logs "[REPhaseContext engine]
Initializing Phase audio engine... update mode = manual", then PHASE's set-up (spatializer, HRIR databases, "Enabled bus 0
for Audio IO", AudioUnit plug-in discovery), "Creating DefaultDeviceAggregate"
and "Built valid aggregate", "Hardware output: 2 channels with layout
UseChannelDescriptions", "initialized: output asbd < 2 ch, 44100 Hz,
Float32, deinterleaved>", "setting output type = headphones (bluetooth)",
the 37 environment presets, "engine@…: created with mode default, sr 48000
Hz" and "Initializing Phase audio engine complete." 7.7 s after the first
line (b2: 6.7 s), with no "Failed to initialize". Most of the 7.7 s passes
in AudioUnit plug-in discovery, not on the wire.

The HAL's default output device, as the guest sees it, is the Mac's
default output device: the guest talks to the Mac's own audio daemon. On
the wire it was a Bluetooth headset: UID `<address>:output`, transport
`'blue'`, nominal rate 44 100 Hz (available 16 000 and 44 100), one output
stream of 2 channels (virtual and physical format linear PCM Float32,
interleaved, 8 bytes per frame), buffer 512 frames (range 14…1024),
latency 8 961 frames, safety offset 0, zero-timestamp period 2 732, no
input streams; its input half was a separate device. Through the public
API the probe listed 9 of the 12 devices on the wire (the client hides
some), with the default output 137 in the client's own numbering against
27553 on the wire. PHASE ran its IO not on this device but on the private
aggregate `iOSSimulatorAudioDevice-<pid>-0` that AVAudioSession's
simulator implementation made over it.

## Q22 (b): the wire protocol (level 3)

Only `com.apple.audio.audiohald` is used, looked up with
`bootstrap_look_up2` by CoreAudio; `com.apple.audio.coreaudiod` was never
looked up by any of the 482 processes of b2 or any process of i1. The
protocol is a MIG-style one: requests 1010000 + n, replies + 100, the NDR
record, send-once reply ports, 30 s send and receive timeouts. The full
table, the object model, the property lists and the IO protocol are in
`audio-host.md` §2–§10; what follows is how they were found.

- Our probe's calls showed which message each API call makes: getting a
  UInt32, Float64, string, array, property list or qualified property each
  has its own message; "has property" (13) precedes every get. Per-object
  send rights come from message 2; the client then registers a wildcard
  listener (35) on each object.
- backboardd before IO, full service (b2): 1 234 requests (200 objects
  looked up: 15 plug-ins, 3 boxes, 2 clocks, 12 devices, 17 streams, about
  65 controls, 13 IO contexts, 60 process objects, the aggregate and its
  subdevice). Ten other visionOS processes do the same walk in their
  first second of audio use; only backboardd starts IO in 150 s.
- Each client makes one IO context per listed device (message 3, with the
  device's `'ioct'` property list sent back unchanged) and registers a port
  on it (message 10); no notification ever came on those ports.
- The aggregate (message 5) and its rule: in b4 our rewriting left the
  new aggregate out of the device list; the client logged "failed to find
  the device", asked again with the same UID, the real service refused
  (`'nope'`), and after ten tries ("Unable to build a valid aggregate after
  10 tries") PHASE failed. b4b, which kept the aggregate in the list, ran.
- IO: message 63 returns the IO port, a memory entry and the region size;
  message 59 a workgroup port that the client turns into an
  "AudioHALC Workgroup". The cycle is a pair of 24-byte header-only
  messages: client to IO port with the last wake's ID, service to the
  client's wake port with ID + 1, every 11.6 ms (512 frames at 44.1 kHz);
  a wake with ID 0 resets the count after a late cycle (38 resets in b7).
  No eventlink or semaphore call was made by audio code; the cycle is pure
  Mach messages. The region's first page holds the timing record and four
  timestamps that matched, field for field, the timestamps our probe's
  IOProc received; the output buffer is at 0x8000 (our probe's 10⁻²⁰ values
  appeared there, 4 096 bytes per cycle).
- Notifications (b7, relayed): 48 property-changed messages (ID 1010500)
  in backboardd's first 150 s, all on the port of message 71: device list,
  process list, the aggregate's `'dch2'` and `'srnd'`, the device's
  `'appv'`, `'went'`, `'gone'`, process `'pir?'`/`'pdv#'`, `'powh'`.
- Minimum: b4b, b6 and b8 started PHASE and loaded the room with an empty
  plug-in, box, clock, tap and process list, a device list of the default
  output device plus the client's aggregates, no controls, no custom
  properties and no notifications. backboardd then sent 225 requests
  before and around IO start. b5 (aggregate refused) failed like Ycode.
- The workgroup port is required: in the iOS guest, a null port or an
  error in message 59's reply made AudioDeviceStart fail (89) after three
  tries.
- Real-time consumption could not be varied (the reference service paces
  itself). The client takes every time from the region and blocks only on
  the wake, so a host that paces wakes from the guest's own clock and
  discards the data should be enough; untested.

## Q22 (c): the audio settings plist (level 3)

`DEV/data/var/run/simulatoraudio/audiosettings.plist`, the path in
`SIMULATOR_AUDIO_SETTINGS_PATH`. It exists in the reference, but not at
backboardd's first open: the host prepares only
`DEV/data/var/run/com.apple.coresimulator.audio.plist` (input and output
UIDs, use-host-default flags, both true) and the empty `simulatoraudio/`
directory; the guest's CoreSimulatorBridge reads the host file one second
after it starts and writes `audiosettings.plist` (temporary file, then
rename) with `sim_input_device_uid`, `sim_output_device_uid`,
`sim_ringer_state` 1 and `sim_volume` 60, and rewrites it 14 s later.
backboardd's first open fails with ENOENT ("Failed to open audio settings
plist!", AudioSession) in every reference boot too; its later opens
succeed, and every other audio client (RealityEnvironment, SurfBoard,
RealityLauncher, …, iOS's systemsoundserver-simd) found the file. The
volume becomes the 0.6 that the client sets as `'appv'` on the output
device. The first-open failure is harmless.

## Q22 (d): the reference without the service (level 3)

Boot b3: every guest look-up of `com.apple.audio.audiohald` and
`com.apple.audio.coreaudiod` answered 1102 by our library (no Mac setting
changed). backboardd logs exactly Ycode's sequence: "there is no system
object" (and again about every 1.1 s), "Could not find default device for
dOut", and "PHASEEngine … Failed to initialize with mode default, sr 48000
Hz" (581 times in 150 s). The room loads, and 0.4 to 0.8 s after
"Compiling PSO … composeSyntheticEnvironmentDefinition" backboardd aborts
with 'API Misuse', "Cannot create a PHASEMaterial with nil or invalid
PHASEEngine"; launchd restarts it, the room loads again and it aborts
again: 12 cycles in 150 s. Refusing only the aggregate (b5) gives the same
failure (10 cycles).

## iOS 27.1 (level 3)

Same service name, same message IDs, sizes, objects and replies. In boot
i1 SpringBoard registers ("com.apple.springboard") and walks the objects
(1 086 messages, 12 IO contexts, no IO); our probe's IO on iOS gave the same
region layout and cycle; the click sound made systemsoundserver-simd
register, create `iOSSimulatorAudioDevice-<pid>-0`, map a 245 760-byte
region and run 1 484 cycles. Ycode's iOS guests therefore have had no audio
either; nothing on iOS aborts because of it in the boots seen (no PHASE
material is made at start).

## Evidence summary

| Claim | Level | Source |
|---|---|---|
| PHASE start lines, timing, hardware output, engine rate | 3 | `log show` of backboardd, b1, b2 |
| Default output device and its properties; client-side numbering | 3 | audprobe in the visionOS guest; audrec (b2, b8) |
| Endpoints used and not used | 3 | audrec look-up and XPC hooks, b2, i1 |
| Messages, sizes, layouts, timeouts | 3 | audrec, probe runs p2–p5, b2, b7, b8 |
| Objects, order, replies; minimal service | 3 | audrec with reply rewriting, b4–b8 |
| Notifications | 3 | audrec relay, b7, b8 |
| Region layout, cycle, reset, stop | 3 | region dumps (p3, b2, b7, ip1); probe IOProc timestamps |
| Workgroup port required | 3 | probe runs ip3 (iOS) |
| Settings files and who writes them | 3 | audrec file hooks (b2), the files |
| Without the service the reference aborts as Ycode does | 3 | b3 (look-ups refused), b5 (aggregate refused) |
| iOS uses the same protocol | 3 | i1, ip1, ip2 |

Level 4 and level 5 were not used.
