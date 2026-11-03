# OBS-VISION-RRM observations (agent OBS-VISION-RRM, 2026-11-01)

Dirty-room notes behind `specs/simulator/visionos.md` §5.6.7
(rasterization rate maps and foveation). Prose only. Recorder output,
status dumps, string lists, crash reports and screenshots stay in the
agent scratch folder (`_agents/scratch/2026-11-01-obs-vision-rrm/dirty/`,
outside the repository). No disassembly or decompilation was used (level 5
not used); Ghidra, the reference tools folder and the IPSW were not
opened; nothing was decrypted.

## Questions (owner, for XR-VIEWER on a Quest Pro with eye tracking)

1. Does any guest process use Metal rasterization rate maps (backboardd's
   compositor passes, RealityKit, CompositorServices / an app's layer),
   and what gates it: the device's capability answer, the simulated
   headset (`wakeboardctl status`, wakeboardd `hmd.*` preferences), a
   CompositorServices configuration, or a constant?
2. If a host-side input enables it, does the guest then render with rate
   maps: zones and rates, fixed or gaze-driven, which gaze source, and
   what does the compositor present?
3. What the rate-map path looks like at the Metal level as the guest uses
   it.

## Short answers

1. **No guest process uses rate maps.** RealityKit asks the device once
   per process (`supportsRasterizationRateMapWithLayerCount:` 2, answer
   NO); nothing else asks. Two gates, both inside the guest: the
   simulator Metal driver answers NO / 0 / nil by itself (no host
   message, unchanged by any host hand-shake value), and wakeboardd's
   simulator HMD reports foveation unsupported and eye tracking disabled
   whatever its preferences say.
2. **Nothing enables them**, so there are no zones, rates or gaze source
   to report. Forcing the device's answer to YES in every process (a
   diagnostic inside the guest, not a host input) changed nothing.
   wakeboardd presents the whole 3840 × 2160 image.
3. At the Metal level the guest only ever asks the one question and gets
   NO; no map is created, set on a pass or sent to the host. The public
   interface is summarized in the spec for the record.

## Setup

- Xcode 27.1. `ycode-test-vision8-rrm27` on visionOS 27.0 could not be
  created ("Download the visionOS 27.0 simulator runtime"; the two 27.0
  builds share an identifier, as earlier agents found). All runs used
  `ycode-test-vision8-rrm`, Apple Vision Pro (4K) on **visionOS 27.2
  (24N120)**. One device, one boot at a time, deleted at the end;
  `device_set.plist` identical before and after; no device type created.
- Tools (sources in `research/experiments/visionos/rrm/`, built with
  `build.sh` into the scratch folder):
  - `rrmpeek.dylib`, inserted into every job with
    `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`. Per process it logs the
    simulator device's `supportsRasterizationRateMapWithLayerCount:`
    (answer, layer count, calling image), `newRasterizationRateMapWithDescriptor:`
    (descriptor and result), `maxRasterizationRateLayerCount`,
    `supportsVariableRateRasterization`, `setRasterizationRateMap:` on the
    render-pass descriptor class, and every one-word getter or setter
    whose name mentions foveation, VRR, rasterization rate or eye tracking
    in the compositor, RealityKit, RealitySimulation, CoreComposite,
    SpatialConnect and Metal-driver images and the main executable. It
    can also list such methods in every other image (`RP_SEEN_ALL`) and,
    as a diagnostic only, force the device's answer to YES
    (`RP_FORCE_RRM`).
  - `rrmcli`, run with `simctl spawn`: the device's answers, which class
    and image define each rate-map method, the Mach messages the task
    sent during 1000 calls of each query (`task_info` event counters), a
    decoder shader compile, and map creation with a one-layer and a
    two-layer descriptor (screen 3840 × 2160, 5 × 3 zones, rates
    0.25/0.5/1/0.5/0.25 by 0.5/1/0.5).
  - `StereoProbe` (existing) with a new `-fovforce` option: asks for
    foveation even when unsupported, and logs each drawable's rate maps.
  - `mslog.dylib` (the Metal-protocol recorder and in-process test server
    of `research/experiments/simulator/metal-sim/`, rebuilt for xrOS).
  - `stereopeek.dylib` (existing) for wakeboardd's `NSUserDefaults` reads.
  - `exp.sh`: restores the preferences, sets keys, boots with the
    recorders, records `wakeboardctl status`, screenshots, `rrmcli` and
    `StereoProbe`.

## Runs

| Run | Inputs | Result |
|---|---|---|
| r0 baseline | none | RealityKit asks `supportsRasterizationRateMap…:2` → NO once in backboardd, RealityEnvironment, pointeruid, datamigrator, AccessibilityUIServer, RealityLauncher/Widgets/Notifications and StereoProbe; no map made or set; 9 × "Layered VRR Not Enabled"; StereoProbe: foveation unsupported, `rasterizationRateMaps` 0 |
| r1 forced device | `RP_FORCE_RRM=1` (diagnostic), StereoProbe `-fovforce` | RealityKit gets YES, still makes no map and sets none; StereoProbe: `variableRasterizationRateIsNotSupported`, no layer renderer; screenshot equal to r0 (only clock-like differences) |
| r2 foveation keys + custom | the r3 keys plus `com.apple.compositor.foveation.custom` YES (wakeboardd and backboardd domains) | wakeboardd aborts each time a layer is created (18 crash reports; abort in CompositorServices' layer-defaults reading); `wakeboardctl` shows "HMD State: Configuring…", process uptime 0 s; boot itself reports finished |
| r3 foveation keys | wakeboardd: `hmd.foveation.recommendation-mode` 1, `hmd.foveation.use-constant-cr`, `…vrr.use-max-ppd-of-clients`, `…vrr.show`, `…gaze.show`, `…eyetracking.show`, `…pixel-grouping.override-enabled`, `…enable-static-foveation-detail-enhancement`, `hmd.motion-to-photon-measurements.eye.foveation-enabled` (YES); backboardd `CAREVisualizeVRRRateZones` YES | every key read with the set value (read log); nothing changes: no maps, "VRR Not Enabled", foveation unsupported, screenshot equal to r0 except the probe's new icon |
| r4 early hooks | none; recorder hooks the device before its first use, lists matching methods everywhere | wakeboardd never calls the rate-map query (hooked at +0.48 s, first device query at +0.50 s); method list below |
| r5 CoreComposite | none; CoreComposite and SpatialConnect accessors hooked | none of their VRR accessors was called in any process |
| fake host | `rrmcli` against the real host with `mslog`, and against the test server with `hostFeatureProfile` 0, 1, 5, 10, 11, 12, 20, 100 and `version` 11 | same answers every time; the real-host capture holds only three hand-shakes and one op 37 |

## Detail

### The device (level 3; level 4 for defining class and image)

- `MTLSimDevice` (the guest driver `MTLSimDriver.framework`) defines
  `supportsRasterizationRateMapWithLayerCount:`,
  `newRasterizationRateMapWithDescriptor:` and
  `maxRasterizationRateLayerCount`; `supportsVariableRateRasterization`
  is Metal's base device class.
- Answers: NO for layer counts 0–4; `maxRasterizationRateLayerCount` 0;
  `supportsVariableRateRasterization` NO; map creation nil for one and
  two layers, no exception, no log line. `supportsVertexAmplificationCount:2`
  NO and families Apple1, Apple2, Common1 only, as in §4.5.
- Mach messages sent by the task during 1000 calls of each query: 2, the
  same as for the counter alone (each `task_info` is itself a message);
  map creation: 2. The `mslog` capture of the real host shows only the
  three hand-shakes and op 37 (limits) for the whole probe run, so none of
  these questions reaches the host.
- With the test server answering the hand-shake with `hostFeatureProfile`
  0 … 100 and `version` 11, every answer stayed the same.
- A fragment shader that takes `constant rasterization_rate_map_data &`
  and decodes with `rasterization_rate_map_decoder` compiles in the guest
  (`newLibraryWithSource:`). (A first version that put the opaque data
  type in a struct failed with "incomplete type", as it would anywhere.)

### Who asks, and who would use maps (level 3)

- Callers of the rate-map query, by calling image: only RealityKit's
  engine (CoreRE), once per process, layer count 2. Metal itself calls
  `supportsVariableRateRasterization` once at device set-up in every
  process.
- RealityKit's engine has a VRR path (level 4 names: render-graph node
  "VRRUnwarp", a VRR unwarp kernel, "Rate map dimension", engine settings
  `CAREVisualizeVRRRateZones`, `CAREEnableNonVRRAniso`,
  `CAREEnableCurvedUILayerFoveation` (logged "now enabled" at start),
  function constants `EnableVRR`, `EnableVRROnCapableDevice`). Its
  pipeline compiles in the log carry `EnableNonVRRAnisotropy=0` only.
- wakeboardd's compositor (CoreComposite) has VRR state (level 4:
  `CCDeviceCapabilities deviceSupportsVRR`,
  `CCWarpIntermediateDataDescriptor deviceSupportsVRR`/`setDeviceSupportsVRR:`,
  `CCXRData isVRREnabled`, `isVRRWithDedicatedStereoInputs`,
  `CCRasterizationRateMapState`); none of these accessors was called.
- CompositorServices' swapchain link has `vrrDecoderDataBuffers`; read
  as nil in wakeboardd, backboardd and the app, four times per layer at
  set-up.
- backboardd's RealitySimulation headset object polls eye tracking about
  150 times a second; the answer is always NO. `RSUserSettings isVRREnabled`
  exists and was never called. The SpatialConnect framework logs
  "Registering foveation system and component" at start.
- `wakeboardctl status`: per link "Layered VRR Not Enabled"; per layer
  "supports eye tracking: Disabled"; "AX static foveation: Disabled";
  per display link "Static Foveation: Disabled".

### wakeboardd's preferences (level 3; key names level 4)

The foveation keys wakeboardd reads at start, with the values read when
unset (from the OBS-VISION-STEREO read log, confirmed here):
`hmd.foveation.recommendation-mode` 0; `hmd.foveation.use-constant-cr`
NO; `hmd.foveation.vrr.show`, `…gaze.show`, `…eyetracking.show`,
`…pixel-grouping.show`, `…pixel-grouping.override-enabled`,
`…vrr.use-max-ppd-of-clients`,
`…enable-static-foveation-detail-enhancement` NO;
`hmd.foveation.<eye>.<n>.min-ppd/max-ppd/cr` and
`hmd.foveation.<eye>.gaze-uncertainty` unset (0);
`hmd.foveation.compositor.pixel-grouping-1x-radius` and `-2x-radius` 10;
`hmd.foveation.compositor.resample-coefficients.*` unset;
`hmd.services.gaze` YES; the gaze display manager's filters (for example
`hmd.gaze-display-manager.extreme-cutoff-angle` 30); CompositorServices'
`com.apple.CompositorServices.configuration.disable-foveation` unset,
`com.apple.compositor.foveation.custom` NO,
`com.apple.compositor.foveation.max-ppd-transition.b` and `.duration` 5,
`com.apple.compositor.eye-tracking-authorization-denied` unset.

Run r3 set the switchable ones (list in the table); they were read with
the new values and nothing changed. Run r2 added
`com.apple.compositor.foveation.custom` YES: wakeboardd then aborted
each time a layer was created, while CompositorServices read the layer's
defaults (the crash report's faulting thread is in the layer set-up; it
carries no message). The custom set presumably needs its parameter keys
(`com.apple.compositor.foveation.max-ppd.0` and others); their types are
unknown and were not tried, because the switch alone cannot add
eye tracking or a device that makes maps.

### Apps (level 1, 3)

- Capabilities: `supportsFoveation` false; layouts without options
  dedicated, shared, layered; with the foveation option dedicated and
  layered (the shared layout is the one CompositorServices does not offer
  with foveation).
- With `isFoveationEnabled` true anyway:
  `LayerRenderer.Properties(configuration:)` throws
  `variableRasterizationRateIsNotSupported` (C
  `cp_layer_renderer_configuration_error_code_variable_rasterization_rate_is_not_supported`,
  −16 in `cp_error.h`); the layer renderer is never delivered; the probe's
  process was gone within 15 s.
- Normal configuration: one view, drawables with no rate maps.

## What this means for Ycode

- Parity needs nothing: the reference driver answers the rate-map
  questions itself, and Ycode runs it unchanged. Ycode's host has no
  message to answer and nothing to advertise.
- A foveated picture for the headset viewer has to be made on the host
  side, by Ycode's own code: fragment shading rate in the Metal→Vulkan
  layer on the passes into the layer textures (gaze-centred, full-size
  textures, so the guest's later passes are unaffected), or gaze-based
  quality in the display stream. Both are Ycode features, off in parity
  runs. Whether the Thor's driver offers Vulkan fragment shading rate is
  open.

## Level 4 used

`strings` of the guest Metal driver; printable strings of the shared-cache
images MTLSimImplementation, Metal, RealityKit, CoreRE,
CompositorServices and CompositorNonUI (read as a file format, with the
OBS-VISION-STEREO `cachestr.py`); the earlier string lists of wakeboardd
and CompositorNonUI; Objective-C class, method and type-encoding names
from the running processes' runtime (our recorder). No code was read.
