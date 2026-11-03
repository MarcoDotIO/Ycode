# OBS-VISION-STEREO observations (agent OBS-VISION-STEREO, 2026-11-01)

Dirty-room notes behind `specs/simulator/visionos.md` §5.6 (views and
stereo). Prose only. Raw recorder output, status dumps, string lists,
slice read-backs and screenshots stay in the agent scratch folder
(`dirty/`, outside the repository). No disassembly or decompilation was
used (level 5 not used); Ghidra, the reference tools folder and the IPSW
were not opened; nothing was decrypted. Level 4 was limited to `strings`
of `wakeboardd`, `wakeboardctl` and `vhmdd`, printable strings of the
`wakeboard`, `CompositorServices` and `CompositorNonUI` images in the
runtime's shared cache (read as a file format: the cache header's
mappings and the `.map` file), and `nm -u` / `otool -L` of `wakeboardd`.

## Questions (from XR-VIEWER)

- Q-XR1: what decides how many views wakeboardd and backboardd render,
  i.e. the view count of the controlled layer wakeboardd gives backboardd?
- Q-XR2: if a host can set it to two, what changes (layer textures,
  amplification or layered instancing, per-view camera, presentation)?
- Q-XR3: in a normal boot, do backboardd's two-slice passes (the
  160 × 128 × 2 glass source) render two camera positions or the same view?
- Q-XR4: does any vhmdd command set an IPD, an eye offset, a view count or
  a stereo mode?

## Setup

- Xcode 27.1. A visionOS 27.0 device still could not be created ("runtime
  path not found", two 27.0 builds share one identifier, as OBS-VISION-CROWN
  found). The runs used **visionOS 27.2 (24N120)**, device type Apple
  Vision Pro (4K) (`ycode-test-vision5-a`); Apple Vision
  Pro (at 2732x2048) was tried as `ycode-test-vision5-b` but 27.2 refused
  to create it. One device booted at a time; deleted at the end; `device_set.plist` compared before and after.
  No clicks, no screen takeover; only `simctl` and our own tools.
- Tools (sources in `research/experiments/visionos/`):
  - `StereoProbe.app` (new): a full immersive space with a CompositorServices
    `CompositorLayer`. Logs the layer capabilities (layouts, foveation,
    formats), the configuration, the properties (view count, texture
    topologies) and, per frame, the drawables, each view's transform,
    tangents, texture map and projection, the textures' sizes and array
    lengths. It clears view 0 red, view 1 green, others blue. Launch
    argument `-layout dedicated|shared|layered`.
  - `stereopeek.dylib` (new, `research/experiments/visionos/stereo/`):
    inserted into a boot. In backboardd it logs textures made with array
    length ≥ 2, the shared layer textures it opens, render passes whose
    colour target is an array texture (render-target array length,
    attachments), and in those passes the viewport, vertex-amplification,
    vertex-bytes and draw calls (with instance counts); after such a pass it
    appends a blit of every slice into a buffer of its own and compares the
    slices. In wakeboardd it logs the descriptors of the shared textures it
    makes, the rectangles of every `SFBSwapchainSwapAddSurface`, and every
    `NSUserDefaults` read (key, type, value).
  - The earlier look-up recorder (`mtlrec`, VISIONOS-OBS4) in wakeboardd for
    `getenv`, C-API preference reads, MobileGestalt and feature flags.
  - `exp.sh` / `setprefs.py`: write wakeboardd preference keys into the shut
    down device's `com.apple.wakeboardd.plist`, boot, record `wakeboardctl
    status`, run StereoProbe, take screenshots.
  - `wakeboardctl` (in the runtime, `usr/bin`), run with `simctl spawn`: its
    only subcommand is `status`, a text dump of wakeboardd's state.

## Public documentation (level 1)

The SDK's CompositorServices headers (Xcode 27.1, `XRSimulator27.0.sdk`):

- `cp_drawable_get_view_count`: "For a device with stereoscopic video, you
  render two views … you typically render only one view in Simulator."
- `cp_drawable_add_render_context`: usable "when the layer renderer is using
  layered layout or in platforms that only render one view (ex: simulator)".
- `cp_layer_renderer_layout`: dedicated = 0 (one 2D texture per view),
  shared = 1 (one 2D texture, views side by side, a viewport each), layered
  = 2 (one 2D-array texture, one slice per view).
- `cp_layer_renderer_properties_get_view_count`; texture topologies with
  array length and texture type.

## Q-XR1: what decides the view count

### What the reference does (level 3)

- **wakeboardd's HMD is a "Sim" HMD.** `wakeboardctl status` prints a
  section `SimHMD` with `Type: Sim`, HMD state `Run`, content mode `MR`,
  compositor 60 fps, and per layer slot (Top, Bottom, HUD1, HUD2, Synthetic
  Passthrough) the swapchain with three chain links. Each link prints its
  colour texture (3840 × 2160 `BGRA8Unorm_sRGB`, private, lossless
  compression), depth texture (3840 × 2160 `Depth32Float`), `layout:
  Layered`, and a **Left** and a **Right** per-eye block. Left: depth range
  {∞, 0.1}, tangents (1, 1, 0.5625, 0.5625), a reverse-Z infinite
  projection (near 0.1), viewport (0, 0, 3840, 2160). **Right: every field
  zero** (tangents 0, projection all zero, viewport 0 × 0). The per-frame
  record has two eye slots; the simulator fills the first only. The same
  holds for backboardd's two layers (Top uid 2, Synthetic Passthrough uid
  3) and for an app's layer (StereoProbe, slot Bottom).
- **The layer textures have array length 1.** wakeboardd made every layer
  texture with `newSharedTextureWithDescriptor:` as a 2D array (type 3) of
  array length 1, 3840 × 2160, colour format 81, depth 252, usage 0x5;
  backboardd opened them with labels "wakeboardd-layer N [frame i/3 …]:
  Color (Layered)" / "Depth (Layered)", array length 1.
- **An app is given one view.** StereoProbe, every layout: capabilities
  report foveation unsupported, layouts [0, 1, 2] without options and
  [0, 2] with foveation, colour formats [71, 81, 110, 94, 115], depth
  [252, 260]. Properties: **view count 1**, one texture topology (array
  length 1; type 2DArray for layered, 2D for dedicated and shared). Every
  frame: one drawable, one view, `drawableTargetViewCount` 1, texture
  3840 × 2160 array length 1, view transform **identity** (no eye offset),
  tangents (1, 1, 0.5625, 0.5625), texture map (texture 0, slice 0,
  viewport 0, 0, 3840, 2160), projection columns (1, 0, 0, 0), (0, 1.7778,
  0, 0), (0, 0, 0, −1), (0, 0, 0.1, 0). The screenshot shows the red
  (view 0) clear behind the app's window.
- **The device answers** (as before): `supportsVertexAmplificationCount:`
  2 NO.
- **wakeboardd's inputs.**
  - Environment variables it reads (look-up recorder): only the standard
    simulator ones (`SIMULATOR_ROOT`, `SIMULATOR_MODEL_IDENTIFIER`,
    `SIMULATOR_FRAMEBUFFER_FRAMEWORK`, `SIMULATOR_DEVICE_NAME`,
    `SIMULATOR_RUNTIME_BUILD_VERSION`, `SIMULATOR_UDID`, `HOME`, …) and
    Metal, ImageIO, logging and dispatch debugging variables. None names
    views, stereo or eyes. No MobileGestalt question was asked.
  - Preferences: wakeboardd reads its `hmd.*` keys through `NSUserDefaults`
    (standard defaults, domain `com.apple.wakeboardd`; the device's
    `DEV/data/Library/Preferences/com.apple.wakeboardd.plist` holds only
    `hmd.preferred-languages` after boot). About 500 reads at start. The
    ones that describe the layers, with the values read when unset:
    `hmd.input.texture-color-format` 81, `hmd.input.texture-depth-format`
    252, `hmd.input.texture-layout` 2, `hmd.input.texture-compression-type`
    0, `hmd.display.color-format` 81, `hmd.display.alpha-format` 0,
    `hmd.display.mode` 1, `hmd.display.texture-layout` 0,
    `hmd.display.swapchain.depth` 2. These match the controlled-layer
    configuration that wakeboardd gives backboardd (colour 81, depth 252,
    layout 2). **No key read names a view count, stereo, mono, an eye or an
    IPD.**
  - SimFramebuffer: wakeboardd imports only `SFBConnectionCreate`,
    `…Connect`, `…CopyDisplays`, `SFBDisplayGetType`,
    `SFBDisplayGetCurrentMode`, `SFBDisplayGetDeviceSize`,
    `SFBDisplayCreateSwapchain` and the four swap calls (level 4, `nm -u`).
    It asks the display nothing about layers, swapchain counts or extended
    properties.
- **Level 4 names** consistent with this: wakeboardd's strings include the
  C++ type `SimHMD`, "Mono Composite Buffer", "Mono Composite Encoder",
  `composite_N_layers_vertex_func`, "Failed to find a display with type
  SimDisplayTypeIntegrated"; CompositorNonUI's strings include the property
  names `is_mono`, `screen_size_per_view`, `physical_size_per_view`,
  `textureProperties.view_count` and the service
  `com.apple.wakeboard.hmdproperties` (from which an app's layer gets its
  capabilities and properties).

### Setting the candidate keys (level 3)

Each run: device shut down, `com.apple.wakeboardd.plist` rewritten with
`hmd.preferred-languages` plus the key, boot with `stereopeek`, 20 s, then
`wakeboardctl status`, StereoProbe, screenshots. The recorder confirmed
that wakeboardd read each value set.

| Key = value | Layers (backboardd, wakeboardd) | View count | Picture |
|---|---|---|---|
| none (baseline) | Layered, 2D array length 1 | 1 | normal |
| `hmd.display.texture-layout` = 1, 2, 3, 4 | Layered, array length 1 | 1 | normal (in the run with 2 a later read returned 0) |
| `hmd.display.mode` = 0, 2, 3 | Layered, array length 1 | 1 | normal |
| `hmd.input.texture-layout` = 0 | **Dedicated**: 2D textures labelled "Color (Left)" / "Depth (Left)" | 1 | normal |
| `hmd.input.texture-layout` = 1 | **Shared**: 2D, 3840 × 2160 (not twice as wide) | 1 | normal |
| backboardd `SimulatedHeadset` = YES (written to `com.apple.RealitySimulation`, `com.apple.RealitySystemSupport` and `com.apple.backboardd`; backboardd read YES) | Layered, array length 1 | 1 | normal |

In every run the per-eye Right block of `wakeboardctl status` stayed zero
and the two-slice passes left slice 1 empty.

backboardd's own reads (about 2 200 with `stereopeek` in backboardd) were
searched for view, stereo, eye, IPD, FOV, camera and headset names: they
include `CameraScale` 1, `VirtualDisplayWidth`/`Height` 2732/2048,
`VirtualDisplayRefreshRate` 90, FOV thresholds for window placement
(`FovHorizontalAngleThresholdDegrees` 80 and others), the
`EmbeddedStereoContent.*` and `DepthMitigation.FOV.*` engine settings
(unset), `com.apple.compositor.stereo-resolution-multiplexing.lower-ppd-eye-index`
0, `RunInSimulator` NO (hand input) and `SimulatedHeadset` NO; none is a
view count.

### Conclusion

The view count is not a constant the host can reach. The layer layout
and formats are wakeboardd defaults (`hmd.input.*`), but the number of
views is fixed by wakeboardd's simulator HMD: one view, identity eye
transform, the Right per-eye slot left empty. No environment variable,
MobileGestalt answer, SimFramebuffer property, device-type value, vhmdd
command or tried preference changes it. **Q-XR1 has no host-settable
answer**; XR-VIEWER keeps alternate-eye stereo.

## Q-XR2: what two views would change

Not observable: nothing produced two views. What the reference shows of
the shape a second view would take, for the record: the per-frame record
already has a Right slot; the layered layout gives one 2D-array texture
whose array length is the view count; RealityKit's targets are already
two-slice arrays and its clears already run per slice with instancing;
the device refuses vertex amplification for 2, so a second view would
have to be layered instancing; presentation is one 3840 × 2160 surface.

## Q-XR3: the two-slice passes in a normal boot

backboardd allocates some RealityKit render targets as two-slice arrays
(level 3, `stereopeek`): `SyntheticColor` 160 × 128 × 2 `RGBA16Float` with
`SyntheticDepth` 160 × 128 × 2 `Depth32Float`, an unnamed 224 × 192 × 2
`RGBA16Float` with `VCADepthStencil` 224 × 192 × 2 (format 260), 40 × 32 × 2
and 56 × 48 × 2 `RGBA16Float` compute targets, and a 64 × 64 × 2 sampled
texture. In the `SyntheticColor` pass:

- render-target array length 2, colour attachment slice 0, one viewport
  (0, 0, 160, 128) set with `setViewports:count:` 1;
- first draw: a four-vertex strip with **instance count 2** (the clear
  quad, once per slice, i.e. layered instancing selecting the slice per
  instance);
- then the room: five `drawIndexedPrimitives` calls **without an instance
  count** (one instance each: 41 520, 57 543, 162 624, 20 328 and 48
  indices);
- `setVertexAmplificationCount:viewMappings:` was never called in any
  pass.

Read-back of both slices after the pass (146 read-backs over 15 boots):
in 51 slice 0 held the room (mean RGBA 0.370, 0.353, 0.313, 1.0) and slice
1 was **all zero** (alpha 0); in the rest both slices were zero (passes
without the room, e.g. while loading). The
224 × 192 × 2 pass likewise drew its clear quad with two instances and left
slice 1 zero.

So the second slice is not a second eye: the passes are laid out for two
views (RealityKit's per-view arrays), the clear runs per slice, and the
scene is drawn once, into slice 0, with the single camera. There is no eye
offset to measure.

## Q-XR4: vhmdd

vhmdd's command and key strings (level 4; 621 strings in 27.2) are exactly
the list of `visionos.md` §5.5.4 and §5.5.9: `get_pose`, `set_pose`
(`pose`: one float4x4, the device pose), `request_environments`,
`set_active_environment`, `set_controls_enabled`, `get_controls_enabled`,
`observe_hand_mode`, `set_hand_mode`, `change_immersion_level`,
`get_immersion_level`, `set_cursor_visible`, `recenter_open_apps`,
`simulate_facetime_session`, and their events. None mentions an IPD, a
pupil, an eye, a view, a field of view, a projection or stereo.

Level 3 (our client `vhm` against the booted device): `set_ipd`,
`get_ipd`, `set_stereo`, `set_view_count`, `get_view_count`,
`set_eye_offset` and `get_display_info` each got the reply `{error:
"Unknown command: <cmd>"}`; `get_immersion_level` and `get_pose` answered
as usual (pose identity). OBS-VISION-CROWN recorded "Connection
interrupted" for commands vhmdd does not answer; in this run unknown
commands got the error reply on the same connection.

## Presentation

wakeboardd presents one surface per swap: `SFBSwapchainSwapAddSurface` with
source and destination (0, 0, 3840, 2160), two IOSurfaces alternating, as
in `visionos.md` §10.6.6.

The camera's vertical tangent 0.5625 equals 2160 / 3840. A check with the
2732 × 2048 device type was planned, but visionOS 27.2 refused to create
that type ("Incompatible device"), so whether the tangents follow the
display size is not tested.

## Notes for Ycode

- `wakeboardctl status` is a cheap parity check on any boot that runs the
  reference wakeboardd (HMD type, layer slots, layouts, texture sizes, the
  per-eye blocks).
- An app's `CompositorLayer` frames go to wakeboardd's Bottom slot as a
  layered 3840 × 2160 swapchain of three links, like backboardd's layers.
