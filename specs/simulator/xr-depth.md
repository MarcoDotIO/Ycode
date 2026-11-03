# Spec: depth re-projection for the headset viewer

Status: **implemented** (agent XR-DEPTH, 2026-11-01; the surround by default,
the camera hold and sweep, the cube's frame and probe: XR-DEPTH-2,
2026-11-02). Measurements in §8.
Ycode-original design. It extends the headset viewer (`xr-viewer.md`) and
the display stream (`display-stream.md` §19) so that the x86 viewer can
re-project the newest picture of Ycode's visionOS simulator to the current
head pose every headset frame (90 Hz), make both eyes from one view, and
fill everything around the guest's 90° view. It follows public
specifications only: the Vulkan 1.3 specification (cube-map face
selection, depth formats, compute and graphics pipelines), the OpenXR 1.1
specification (`XR_KHR_composition_layer_depth`), RFC 1950 (zlib), and the
GLSL 4.50 specification with the `GL_EXT_*` extensions named in the
shaders; the shaders are compiled by glslc (shaderc, Apache-2.0) once and
committed as SPIR-V words. Nothing of Apple's is read: the depth comes from
Ycode's own replay of the guest's Metal work (attachments, sizes, formats,
sample counts, clear values), never from the guest's shaders.

Code: `Sources/YcodeVulkan/VulkanDepthTap.swift` and `shaders/depth_tap.comp`
(the Thor's tap), `Sources/ycode-simd/DisplayXRDepth.swift` (the messages),
`Sources/YcodeDisplayStream/XRDepth.swift` (message types),
`Sources/YcodeXRReprojection` (codec, geometry, CPU reference, GPU
wrapper, the environment's calibration), `Sources/CYcodeXRReprojection` and
`shaders/reproject.{vert,frag}` (the GPU path),
`Sources/YcodeDisplayStream/XRCamera.swift` (camera hold and sweep),
`Sources/YcodeXRViewer/XRDepthView.swift` (the viewer's use), `scripts/xr-depth-shaders.sh` (SPIR-V regeneration). Tests:
`Tests/YcodeXRReprojectionTests`.

## 1. Why

The guest renders one view per picture at about 23–30 pictures per second
and smooths its camera: a new pose first shows about 100–170 ms later and
settles over about 250 ms more (`xr-viewer.md` §6, `visionos.md` §5.5.12).
Shown as is, every headset frame displays a picture whose viewpoint is
that old; the runtime's own re-projection corrects only rotation, and
alternate-eye stereo updates each eye at about 1.3 Hz. With each picture's
depth the viewer moves the picture's geometry to where each eye is now:
translation and rotation are corrected every headset frame, and both eyes
come from one picture with the wearer's own eye separation.

## 2. The guest's depth

The guest's one camera (`visionos.md` §5.6.1) has tangents (1, 1, h/w,
h/w), reverse-Z with an infinite far plane and near 0.1 m. Its depth
buffer therefore holds **d = near / z** (z the view distance along −Z):
1 at the near plane, 0 at infinity. This is inverse depth, which is what a
re-projection needs: a point's parallax under a sideways step b is b · d /
near in tangent units, linear in d. Ycode carries depth as this value,
quantised to 16 bits (q = round(d · 65535), q = 0: nothing drawn). The
resolution at distance z is z² / (near · 65535): 0.15 mm at 1 m, 3.8 mm at
5 m, 15 mm at 10 m.

## 3. Capturing depth on the simulator host (the tap)

### 3.1 Which depth

Ycode's frame maps (`visionos.md` §10.12.4, §10.20.1, §10.24.1) give a
steady frame of backboardd: the room drawn into backboardd's own 3840 ×
2160 `BGRA8Unorm_sRGB` target with a `Depth32Float` depth attachment; the
windows (the home view, app windows, their glass) drawn in a 4× pass
whose colour resolves into the windows layer, with a 4-sample
`Depth32Float_Stencil8` depth the guest discards; and the compose passes
that copy the room into the passthrough layer. wakeboardd composes the
layers into the presented surface.

While a viewer asks for depth, every render pass at least 1024 × 576 with
a depth attachment at level 0 and at least one command is a candidate:

| Pass | Rule |
|---|---|
| single-sampled (the room) | starts the command buffer's capture over (the last such pass wins: the room is drawn after the passthrough layer's first pass) |
| multisampled with a colour resolve (the windows) | merges into the capture, nearest wins; its depth store is forced to STORE (Metal's DontCare) |
| multisampled without a resolve | ignored |

**Only the windows layer's opaque texels count** (XR-ICONS, 2026-11-02;
§5.6). A layer's transparent parts write depth too: the rectangle under a
home icon's name is almost wholly transparent, and with its depth the wall
and television behind it rode along at the icon's 1.2 m. The merge counts a
texel only when the pass's resolved colour has alpha ≥ 0.25
(`YCODE_XR_DEPTH_ALPHA`; 0: every texel, as before). The windows pass's
colour and depth must have one size, or every texel counts.

**A sample says whose it is.** Its low bit is 1 for the windows layer and 0
for the room (a room sample stays at least 2, since 0 means nothing drawn),
which costs one step of the 16 bits: 8 mm at 5 m. Flag `windowsMarked` (bit
3) tells a viewer; without it the viewer clears the bit, so an older
server's depth marks nothing.

A pass that clears depth to a value above 0.5 is treated as standard Z
(stored 1 − near / z) and converted; reverse-Z passes clear to 0.

### 3.2 The copy

At the end of a candidate pass the backend records, in the same command
buffer and with a full memory barrier, one compute dispatch of Ycode's own
shader (`depth_tap.comp`) on the backend's bindless heap: the tap makes
its own sampled view of the depth image (depth aspect, a 2D or 2D
multisample view, sample 0) in a heap slot of its own, and the shader
writes one u16 per n × n block, the **nearest** value of the block (so
the edge of a near surface is never pushed back), two per 32-bit word,
into a host-visible buffer of a 4-entry ring (by buffer device address).
At the end of the command buffer the capture's serial is written behind
the data (`vkCmdUpdateBuffer`, then a barrier to host reads); the CPU
copies a capture out only when it reads the serial before and after the
copy. Nothing waits on the GPU; the guest's own work and the copy share
the command buffer.

### 3.3 Pairing depth with the picture (provenance)

Each command buffer's written images (colour and resolve attachments,
blit destinations, textures a kernel may write) take its capture's serial
or, without one, the newest serial among the images it reads (loaded
attachments, textures bound for sampling, blit sources). An IOSurface
written so carries the serial: wakeboardd's compose reads the layers
backboardd wrote, so the presented surface carries the serial of
backboardd's frame. The display server asks for the depth of the surface
it presents; when provenance has nothing for it, the newest capture goes
out with the flag `otherFrame`.

### 3.4 The environment cube

The room's environment cube that the guest uses for reflections
(`visionos.md` §10.23.4, §10.24.2) is recognised when the guest creates it:
an `RGBA16Float` cube, 256², 9 levels, shader-read only. While a viewer
wants the environment, the top level (256² per face; 128² until XR-QUALITY) is copied into
a host buffer at the end of a command buffer every 2 s; when its content
hash changes (a new room), the server sends it.

**Its frame and where it was taken** (measured 2026-11-02, §8.3; Ycode's
own fit of the cube against the guest's pictures and their depth, no
look at the guest's code). The cube is a panorama of the room in a
left-handed frame: the stage direction (x, y, z) is the cube direction
(x, y, −z), with no turn (its +Z face shows what is ahead of the default
eye point). It was taken at a probe in the room, not at the head: in the
living room 1.6 m ahead of the default eye point and 0.2 m above it. Its
values are linear light at about 1 / 0.62 of the picture's (§8.3). The
server sends the faces as the guest holds them; the viewer mirrors.

Diagnostics: `YCODE_XR_DEPTH_LOG=1` logs the first 40 candidate passes
(size, depth format, samples, load and store actions, clear value,
colours, resolve, process) and the environment's changes.

## 4. Messages (`display-stream.md` §19)

### 4.1 Negotiation

Server hello: `xrDepth: true`, `xrEnvironment: true` (a visionOS server
with the headset mode). Client hello: `xr.depthDownscale` (2, 4 or 8; 0 or
absent: no depth) and `xr.environment` (true: send it now and on every
change; there is no other client message).

### 4.2 Frame depth (0x0C, server → client)

Sent right after the frame message (0x03) it belongs to (and after its
frame view 0x0A):

| Bytes | Field |
|---|---|
| 8 | frame sequence (the 0x03 it belongs to) |
| 8 | guest frame |
| 1 | encoding: 1 = zlib of byte planes of row deltas, 2 = raw |
| 1 | view (0 mono, 1 left, 2 right) |
| 2 | flags: bit 0 depth of another frame (no provenance), bit 1 windows merged, bit 2 room only, bit 3 a sample's low bit marks the windows layer (§3.1) |
| 2, 2 | width, height (the picture's size / n, rounded up) |
| 4 | f32 near (m) |
| 16 | 4 × f32 tangents (left, right, up, down; left and down negative) |
| 8 | the server's monotonic ns of the capture (recording time) |
| 4 | data length |
| n | data |

Encoding 1: each row is delta-coded from its left neighbour (its first
sample from the sample above), the u16 deltas are split into a plane of
low bytes then a plane of high bytes, and both are compressed together
with zlib (RFC 1950, level 1). Lossless; planes and walls make the high
plane almost constant.

### 4.3 Environment (0x0D, server → client)

| Bytes | Field |
|---|---|
| 4 | serial (increments per change) |
| 1 | encoding: 1 zlib, 2 raw |
| 1 | format: 1 RGBA16F (linear half floats, as the guest holds them), 2 RGBA8 sRGB |
| 2 | face size |
| 1 | mip level taken |
| 1 | flags: bit 0 orientation known |
| 2 | 0 |
| 16 | 4 × f32 orientation quaternion x, y, z, w (cube frame → stage frame; identity unless known) |
| 4 | f32 exposure hint |
| 4 | data length |
| n | six faces +X, −X, +Y, −Y, +Z, −Z (Vulkan's order), rows top to bottom |

The faces are in the guest's cube frame. Without bit 0 the viewer takes
the frame as measured (§3.4): mirrored in Z, no turn. With bit 0 (no
server sets it today) the quaternion turns an unmirrored cube.

## 5. Re-projection on the viewer

### 5.1 Geometry

A source pixel at (u, v) ∈ [0, 1]² (v down) with sample q is the
homogeneous view point (tan x, tan y, −1, q / 65535 / near) with tan x =
l + u (r − l), tan y = t − v (t − b) for the source's tangents: w is the
inverse depth, so a point at infinity has w = 0 and moves with rotation
only. One 4 × 4 matrix, M = P_eye · V_eye · S, takes these points to the
eye's clip space: S the source's local → base-space transform (its pose,
or a cube face's basis), V_eye the eye's view matrix, P_eye Vulkan's clip
space for the eye's tangents with reverse-Z and an infinite far plane
(depth = near / z again). The source pose is the picture's **tag** (the
frame view 0x0A, mapped to the base space by the anchor): in continuous
motion a picture shows the pose sent about 100 ms before it
(`visionos.md` §5.5.12), and the tag names the pose the picture shows.

### 5.2 The mesh and the fill

The picture is drawn as a grid with one vertex per `step` depth texels
(default 1: 961 × 541 points at depth 960 × 540, 541 × 961 for the
2160 × 3840 display), two triangles per cell,
no vertex buffer (every vertex follows from its index). Each vertex reads
its triangle's three depths. A triangle whose farthest / nearest distance
is above 1.08 crosses a depth edge. How far the move has stretched it is
its longest side against the same side with all three corners at the far
corner's depth; at the picture's own viewpoint that is exactly 1. Modes:
**background** (default) pushes it to the far corner's depth (× 0.999), so
real surfaces win, samples the picture at its own place while unstretched,
and in one colour of the background, read half a cell past the far corner
away from the near one, by a stretch of 1.5 (so an uncovered area takes the
background's colour, and an edge that barely moved stays sharp); **discard**
keeps it the same way until a stretch of 1.5 and then drops it (what lies
under shows: with a cache, the fresh picture is drawn twice, filled under the
cache and discarding over it, §5.3); **stretch** keeps the rubber sheet.
(Until XR-QUALITY every such triangle took one flat colour, moved or not: a
band of 4 picture pixels around every depth edge, staircased, in the fill and
in the cache: the curtains, lamps and shelves of run 7.) The colour is an sRGB
texture (filtering in linear light) with a full mip chain rebuilt for each
picture, sampled trilinearly with anisotropy 8 (minified sampling:
`xr-viewer.md` §12.3), the foveated inset (`xr-viewer.md` §4.5) a second one sampled inside its
rectangle. `XRReferenceWarp` is the same algorithm on the CPU (nearest
colour sample): the tests compare the GPU with it, and the viewer measures
the disoccluded area with it at 192 × 212 twice a second.

### 5.3 The world cache and the environment

The guest renders 90° horizontally; the headset shows about 94° per eye
and turns freely. So that nothing is ever black (the owner's goal), each
eye is drawn in this order:

1. **Environment** (0x0D): the cube in its own frame (mirrored, §3.4),
   behind everything, at the exposure (0.62 until calibrated,
   `--env-gain`). Before a calibration it is drawn at infinity about the
   eye (one quad per face: exact for rotation, wrong by the probe's offset
   in parallax). After the sweep (§5.5) the viewer has final pictures in
   every direction, so it knows surface points of the room in the stage
   frame and how bright they are; `XREnvironmentCalibration` finds the
   probe (the point from which the cube best correlates with them: a grid
   search over ±6 m, refined to 5 cm), the exposure (the median ratio
   picture / cube) and the room's box (1 % and 99 % of the points per
   axis). The cube is then drawn **on that box from the probe**: each face
   is a 17 × 17 mesh whose inverse depths (33² samples) put it on the box,
   so its walls stand where the pictures have them and move with parallax.
   A recentre or a new room puts it back at infinity until the next sweep.
2. **World cache**: a cube of six faces (default 2048² each, colour RGBA8
   sRGB + inverse depth R32F) about the anchor (the stage's origin), in
   the base space. A picture goes into the cache only once it is
   **final** (§5.5), at most every 250 ms. It is drawn into the faces it
   can see with its depth edges filled from their far side (left empty,
   they were holes wherever the cache showed; since XR-ICONS an edge stretched
   beyond 1.5 is left out, and what lay there stays, or the fresh picture's fill
   shows, §5.6), newest wins where it covers
   (the colour and depth attachments are loaded, a depth buffer cleared
   per update orders the picture's own triangles). **The room only**: triangles
   touching a sample of the windows layer stay out (§3.1, §5.6). `--cache-all` takes
   every picture. Its inverse depth relative to the face is written from
   the rasteriser's depth (Ycode's projection makes depth = near / z). Its
   colour has a mip chain, rebuilt per face after an update (a face's corners
   hold about three times the pixels per degree of its centre), and a partly
   empty filtered texel takes its colour from the premultiplied average. The
   faces are drawn to each eye as depth-displaced meshes of about 384
   cells a side whatever the face size (background mode, empty texels
   (alpha 0) dropped), so parallax stays right and the cost stays fixed.
3. **The fresh picture**: first filled (background mode) under the cache,
   so a disocclusion the cache has not seen takes the background's colour;
   then, once **final**, over the cache (the depth buffer cleared between)
   with its disocclusions discarded (the cache or the fill shows there),
   alpha-blended with a ramp over the outer 4 % of its edges so its seams
   fade into the cache. While it is not final (the head is turning and
   the guest's picture shows a smoothed pose its tag only estimates), the
   cache goes over it: the room stays where it is, and the moving picture
   shows only where the cache is empty, and its windows layer over all of it
   (the cache has none). During a sweep a picture that is
   not final is not drawn.
4. **The hands**: XR-VIEWER's quad layers on top.

A recentre moves the anchor: the cache is emptied about the new origin.

### 5.4 Submission

Each eye is drawn into the session's rendered swapchain
(`yxr_acquire_render`, CYcodeOpenXR's hook b) at the runtime's
recommended size, under the queue lock, and submitted with `render[i]`
set, at the eye's current pose and its own field of view: the runtime's
own re-projection then corrects only the few milliseconds of its
prediction. When the runtime offers `XR_KHR_composition_layer_depth`, the
eye's depth (reverse-Z, minDepth 0, maxDepth 1, nearZ = +∞, farZ = the
eye's near) can be chained with hook c; WiVRn 26.9 does not offer it, so
it is not used today.

### 5.5 The guest's camera: hold, final pictures, sweep

With one view (`--stereo synth` or `mono`), the viewer decides what the
guest's camera is told (`XRCamera.swift`):

- **Hold.** The camera keeps one pose while the head stays within 2 cm
  and 3° of it (`--hold-band`; 1.5 cm and 1.5° until XR-GAZE); past that it follows the head until the head has rested
  (within 3 mm and 0.3°) for 150 ms, and holds there. Small motion is made
  up by the re-projection every headset frame; the guest renders nothing
  new for it (it renders only when its camera or its content changes,
  §8.2), and a picture shows exactly the pose it was told.
- **Final pictures.** A picture is final when it arrived 800 ms or more
  after the camera came to rest (`--cache-hold`: the guest's smoothing has
  converged, §8.2); or when it arrived after the camera came to rest and
  no newer one has come for 300 ms (`--cache-settle`; 500 ms during a
  sweep: a turn's last picture, as the guest stops rendering once it has
  converged); or 1.5 s after the camera came to rest (nothing new came:
  the picture was already right). A final picture is re-tagged with the
  camera's pose, drawn over the cache and goes into it. A stall of the
  guest can make a picture final too early; the next final one replaces it.
  A picture that is not final goes **under the cache only while the camera moves
  fast** (over 20° a second or 20 cm a second, `--fresh-top-speed`), and 350 ms after the
  camera came to rest (`--fresh-top`) it is on top at the camera's pose: only the cache
  waits for a final picture (`xr-viewer.md` §13.5).
- **Sweep** (`--sweep`, on by default with one view and a cache). At the
  start (0.3 s after the first picture) and 1.5 s after a recentre the
  camera visits the whole sphere once from the head's position: rows of
  yaws spaced by the view's width less 12°, the zenith and the nadir, and
  a stop of its own for any direction those leave out (`XRSweep`); each
  stop ends with its final picture or after 2.5 s. With the 2160 × 3840
  display (90° × 121°) that is 7 stops (5 yaws, up, down), 6.6–10 s; with
  3840 × 2160, 17–24. Then the cache holds the room everywhere, the
  environment is calibrated (§5.3) and the camera follows the head again.
  A new room (the environment's serial changes) empties the cache and
  sweeps again. "Nothing new came" does not apply during a sweep (a slow
  guest's last stop would go in at this stop's pose); a stop out of time with a
  picture of its own goes in with that picture.

### 5.6 Small floating windows: the tube from a home icon to the wall (XR-ICONS, 2026-11-02)

A home icon is a disc about 18 cm across at 1.2 m, before a wall at 5 m. Under
any eye offset, including half the eye separation with a still head, the old
path drew beside each icon bands and blocks that reach from it towards the wall
(`.claude/worktrees/xr-icons-reprojected-icons.png`, outside git). This is the owner's
"cylinder to the back wall" of headset run 8: shown that crop, they confirmed it. Three
causes, largest first by eye:

1. **The name's rectangle carried the wall** (§3.1): blocks of wall and
   television at the icon's depth.
2. **The cache stored the windows layer and fills.** With a head off the cache's
   centre, each edge went in as a fill beside the disc, at the wall's depth, over
   what was known of the wall; the disc went in over the wall too. The fills stayed
   in the room as bands and pale patches, and two copies of a disc could show.
   Now the cache holds the room only, and stretched edges are left out (§5.3).
3. **The fill.** A disocclusion nothing has seen still takes the background's
   colour by triangle (§5.2). It is what remains beside an icon until the head has
   seen the wall behind it. The wall behind an icon is in no picture the stream
   sends, because the stream sends the composed picture.

Also: the environment on its calibrated box could stand in front of a wall's
fill, so the depth is now cleared after it.

**Tried and dropped: a fill along the shift.** Reading the fill along the near
corner's shift with a slight blur (mip level 2) looked smoother in the crops, and
was worse against the guest's own picture. Alternating runs on one device, icons,
RMS error at eye offsets of 6.2, 9.2 and 15.2 cm: 18.3, 20.9, 14.0 against 13.4,
13.6, 13.8 for the existing fill. With an app window: 11.4, 8.7, 12.0 and 12.7,
8.5, 11.8 against 13.4, 8.5, 9.7 and 9.4, 8.3, 9.4. So §5.2's fill stays. (A
second run of the new fill on icons, 76.4 and 68.6 at two of the offsets, was a
shot with the view pitched down, apparently a sweep's stop, and is left out. An
app's window, faded behind the home view, was in the icon runs too.)

**How it is judged.** The offscreen viewer's right eye against the guest's own
full-resolution picture with its camera at that eye's position, the picture
mapped through the eye's tangents, over the icons' part of the eye (800 × 330 of
1350 × 1485), `eye` and truth on the same device (boot `c5`, load 9–17), head held
8 s per position, shot after 6 s:

| Eye offset | Old viewer (the depth's rectangles already gone) | This round |
|---|---|---|
| 6.2 cm | 13.2 (2.95 % of pixels off by more than 30) | 12.4 (2.73 %) |
| 9.2 cm | 14.3 (3.03 %) | 11.8 (2.45 %) |
| 15.2 cm | 13.3 (3.10 %) | 10.3 (2.25 %) |

The numbers understate it: the remaining error is mostly edges and the guest's
slight dimming, and the bands are few pixels. Crops: `xr-icons-truth-oldviewer-final-{6,15}cm.png`.
The old path with the old depth on an earlier boot (`c1`) showed the same bands
and more, at 16.9–27.6 in the step script of 4 s per position, not the same
measure; it is `xr-icons-truth-before-after-{6,15}cm.png`.

**What it costs.** While the guest is still settling after a head step, the windows
layer comes from a picture whose pose is only estimated, where it used to come
from the cache at its last settled place. In the 4 s step script, at 12 cm
(scripted jumps, load 14–17), the icons stood about 18 pixels of the 1350-pixel eye off
2 s after a step, which scores worse than the old path (27–31 against 17–28) although
the picture is cleaner, and were in place by about 4 s. Right after a 12 cm jump back one shot showed
half discs: the depth's mark and the colour disagree while the guest moves fast, and
only marked texels draw over the cache. A real head moves far less per frame,
but this needs the headset to judge. During a sweep (the start, a recentre) a picture
that is not final is not drawn, so the windows layer shows only at final pictures.

**What remains.**
- Edges still step by the depth's texel (a shelf, a disc's rim: 4 picture pixels).
  `--depth 2` halves it, at 2.8 ms GPU per eye against 1.0 and 5.2 Mbit/s for the depth;
  not the default.
- A name's letters are small and break up when the head is well off.
- **The room behind a window.** The guest's room layer has the real wall behind
  every icon. Streaming it as a fourth view into the cache (with the room's own
  depth) would replace the fill, not improve it. Not done: it touches the stream, the
  encoder's views and the viewer.

## 6. Stereo

`--stereo synth` (the default with re-projection) asks the server for
`mono` and draws each eye from the newest picture at the eye's own pose
(the headset's views, i.e. the wearer's IPD): continuous stereo at the
headset's rate, every picture shown to both eyes. Alternate and adaptive
stay available (`--stereo adaptive`, the default with `--reproject off`,
is XR-VIEWER's mode for comparison); with re-projection on, each eye shows
the newest picture of any view re-projected to it, and an eye picture is
final at once (the server shows an eye only once settled, and its tag
names it).

**`--eye-yaw`** turns only eye pictures (`xr-viewer.md` §4.6); the head's
view is never turned, so with `--stereo synth` or `mono` it has no effect.
It is not needed there: the eyes' outer 9° beyond the guest's ±45° come
from the cache (§5.3). With adaptive or alternate and re-projection, the
turned eye pictures are re-projected by their tags like any other.

The foveated inset (`--foveate`) works with every mode: an inset of an
unchanged picture (the gaze moved, the held camera did not) is uploaded as
it comes.

## 7. The viewer

`ycode-xr-viewer … --reproject on|off` (default: on when the server's hello
says `xrDepth`), `--stereo synth|adaptive|alternate|mono` (default synth;
adaptive with `--reproject off`; with a server that sends no depth, synth
shows the one view in both eyes without re-projection and says so),
`--depth 2|4|8` (default 4), `--grid n` (default 1), `--cache n` (0 or
256–2048, default 2048), `--sweep on|off`, `--cache-hold ms`,
`--cache-settle ms`, `--env-yaw` (a turn after the mirror; it also keeps the
cube at infinity), `--env-gain`, `--environment off`. Without a headset, `--replay <script> --reproject on`
re-projects offscreen at 1350 × 1485 per eye (`--offscreen WxH`) on a
Vulkan device of its own (`--reproject-shots <dir>`: a PNG of the right eye
every 2 s, the newest depth beside it, the environment's faces, and each
camera pose's first final picture as PNG, raw u16 depth and JSON pose:
the inputs of §8.1 and §8.3). The summary
at exit gives: headset frames, pictures with and without depth, GPU ms
per eye (timestamp queries, uploads included), the loop's CPU time, the
viewpoint the re-projection corrected (the distance and angle between the
picture's tag and the eye at display, p50 and p90), the picture's pose age
at display, the disoccluded fraction, and the depth's bandwidth.

## 8. Measurements

Runs of 2026-11-02 on the Thor (this branch's release build, visionOS 27.0
runtime, `YCODE_VISION_SCREEN=2160x3840`, the living room, Thor load 2–58
from other agents) with the x86 viewer offscreen (`--replay` scripts of
held poses; RTX 4060 Ti; eyes 2700 × 2970 unless said). The stream went
through an ssh forward, so its send times are not the link's.

### 8.1 The depth's scale

Two final pictures of a sideways step of the camera (0.2 m), block-matched
along the rows (80 × 80 pixel patches with texture and a unique best
match): the measured parallax against the one the depth predicts (b / z).

| What | Patches | Measured / predicted |
|---|---|---|
| The room (0.98–5.4 m), patches of one depth | 119 | median 0.996 (p10 0.980, p90 1.006) |
| The home view's icons (the windows pass, 1.20 m) | 8 | 180–181 px against 180.6 px |
| The TV, a lamp, a picture on the far wall (5.0–5.4 m) | 3 | 40–43 px against 40–43 px |

The depth is metric to 1 %, the windows' as well as the room's;
`YCODE_XR_DEPTH_WINDOWS=0` is not needed. The bowed picture edges of the
first headset shots came from pictures shown at a wrong pose (a turn's
last picture tagged with a pose of the turn), not from the depth: what the
camera hold and the final-picture rule of §5.5 address.

### 8.2 The guest's pictures

A held camera gives no new pictures (30 in 18 s with five steps of the
camera; others only when content changed). After a step of the camera:
first changed picture about 290 ms later, the converged one about 630 ms
later, 3 pictures in all, about 170 ms apart (load 58). During continuous
motion (the `walk` script) the guest gave about 7.5 pictures per second at
2160 × 3840: 152 and 159 frames in 20 s without depth, 144 and 148 with
(about 5 % fewer, within the run-to-run spread under the shared load).
Depth on the stream: 0.35–3 Mbit/s (about 1.4 typical; 8.4 while every
picture of an animation was sent).

### 8.3 The environment

The cube's luminance against final pictures of every direction (their
surface points from the depth), over frames and probe positions:

| Frame, probe | Correlation |
|---|---|
| as sent, any turn, at the head | 0.16 (no turn stands out) |
| mirrored Z, any turn, at the head | 0.25 |
| as sent, turn and probe fitted | 0.53 |
| mirrored Z, no turn, probe fitted at (0, 0.2, −1.6) m | **0.75** (9 pictures), **0.91** (the 7 sweep stops) |

The fit takes 90 ms on the x86 for 28 560 points. The picture's linear
luminance against the cube's is linear over the cube's range 0.1–1.5 with
a ratio of 0.61–0.65 (exposure 0.62–0.63; lights above 1.5 clip). The
earlier calibration (a turn against one picture, at the head) gave turns of
22–30° at correlations 0.50–0.53: an artefact of the probe's offset. On
offscreen shots the cube drawn on the box matches the pictures' walls, TV
and window.

### 8.4 Cost on the x86 (one eye, 2700 × 2970, GPU timestamps)

| Settings | p50 | p99 (uploads included) |
|---|---|---|
| cache 1024, grid 2 (the old default) | 1.65 ms | 6.6 ms |
| cache 2048, grid 2 | 1.0–1.6 ms | 1.8–6.6 ms |
| **cache 2048, grid 1** (default) | 1.2–1.3 ms | 2.3–3.0 ms; 6.4 ms in a frame that uploads a new 2160 × 3840 picture |
| cache 2048, grid 1, depth ½ | 2.2 ms | 3.1 ms |
| no cache | 0.6–0.7 ms | 2.7–4.7 ms |

Both eyes: about 2.5 ms per headset frame, 6–9 ms in a frame that uploads
a new picture (the upload is in the first eye's submission), against the
11.1 ms period; the x86 GPU at 40–45 % with the offscreen loop at 90 Hz
(near 0 % idle). The loop's CPU time is 0.1 ms. The 2048² cache uses about
200 MB of GPU memory. Without a headset this does not include WiVRn's
compositor or its encoder.

### 8.5 Coverage

After the sweep (7 stops in 6.6–10.2 s, every stop with a final picture),
offscreen shots of the right eye looking along 8 yaws, up, down and 12 cm
to either side showed the room in every direction, sharp (the cache at
2048² has about 23 pixels per degree, the guest's picture about 24): no
black anywhere. A slow turn (40° left and back in 3 s, 30° right in 2 s)
kept the room in place in every shot. What remains visible: the fill's
streaks beside near objects in the other eye (the wall's colour across a
disocclusion, a few centimetres wide at 1 m), and steps of 4 picture
pixels along depth edges (the depth is at ¼ resolution).

## 9. Open questions and next steps

- **Other rooms.** The cube's frame (mirrored, no turn) and the exposure
  were measured in the living room; the probe and the box are fitted per
  room after each sweep. A room whose walls are not along the stage's axes
  would need a turned box.
- **Moving content during a turn.** While the head turns, the cache goes
  over the moving pictures, so content that changes (a video, typing)
  shows its last final state until the head rests (about 0.6–1 s).
- **Immersion.** A change of the immersion (the thumbstick) changes what
  the room shows; the cache keeps the old state until each direction is
  seen again. A sweep after an immersion change is not done.
- **Real heads.** The hold's band (1.5 cm, 1.5°) and the final-picture
  times come from scripted poses; the headset run must show whether a
  wearer's head keeps the camera held while reading.
- **Depth layers.** When a runtime offers `XR_KHR_composition_layer_depth`,
  pass each eye's depth (§5.4).
- **Moving content** (videos, animations) in the cache stays as last seen
  until the guest's view covers it again (§5.3, by design).

## Evidence

| Claim | Level | Source |
|---|---|---|
| The windows layer's transparent depth, the cache's fills, the measurements of §5.6 | 3 | Ycode's own simulator on the Thor (boots `s1`, `c1`–`c5`, visionOS 27.0, 2160 × 3840), the x86 viewer offscreen, raw depth dumps; tests `DepthTapGPUTests`, `XRReprojectorGPUTests.theWindowsLayerStaysOutOfTheCache`, `aStretchedEdgeIsNotStoredInTheCache` |
| The guest's projection (reverse-Z, infinite far, near 0.1, tangents) | — | `visionos.md` §5.6.1, §5.5.12 (Ycode's spec; its evidence there) |
| The passes of a frame (room target and depth, the 4× windows pass, layers) | — | `visionos.md` §10.12.4, §10.20.1, §10.24.1 (Ycode's frame maps) |
| The environment cube's format, size and levels | — | `visionos.md` §10.23.4, §10.24.2 |
| The guest's smoothing and render delay | — | `xr-viewer.md` §6, `visionos.md` §5.5.12 |
| Cube-map face selection, depth formats, multisample views, timestamps, buffer device addresses | 1 | Vulkan 1.3 specification |
| `XR_KHR_composition_layer_depth` | 1 | OpenXR 1.1 specification and registry |
| zlib | 1 | RFC 1950 / 1951 |
| The tap's candidates, their depth contents, provenance pairing, costs (§8) | 3 | Ycode's own simulator on the Thor with `YCODE_XR_DEPTH_LOG=1`, 2026-11-01 |
| The depth's scale, the guest's picture timing, the cube's frame, probe and exposure (§3.4, §8.1–§8.3) | 3 | Ycode's own simulator on the Thor: its streamed pictures, depth and environment, fitted on the x86, 2026-11-02 |
| Everything else (messages, codec, mesh, fill modes, cache, order) | — | Ycode design decisions |

No Apple binary, Apple software, reference tool or `research/` material was
used for this spec.
