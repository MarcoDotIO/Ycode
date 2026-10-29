# Spec: the host camera layer

Status: **implemented** (agent CAMERA-HOST, 2026-10-27). Code:
`ycode/Sources/YcodeHostServices/Camera/`, `ycode/Sources/CYcodeCamera/`,
`IOSurfaceHostService.makeHostSurface` and friends, and
`ycode/Sources/ycode-simd/CameraCommand.swift`. Tests:
`ycode/Tests/YcodeHostServicesTests/Camera*Tests.swift`.

This spec covers what the host does with a camera: find it, negotiate a
format, stream it, convert each frame into a pixel format an iOS guest
uses, and put the result in a small ring of host-made IOSurfaces that
guests can map. It does not cover how the guest's camera stack reaches
those surfaces; that is the guest-facing round, written against
`camera.md` (the reference observation of the simulator's camera, by
another agent). §9 lists what that round must add.

Everything here comes from public documentation (the Linux V4L2 API,
ITU-T T.81, ITU-R BT.601/BT.709, ISO/IEC 23001-8, Apple's public
CoreVideo and IOSurface headers for interop constants) and from runs of
Ycode's own code against a USB webcam on the Thor. No Apple binary,
simulator or Xcode was run or read for this work.

Terms: **source format**, a pixel layout a camera sends (V4L2 FourCC,
first character in the low byte); **output format**, a pixel layout Ycode
hands the guest (CoreVideo OSType, first character in the high byte);
**ring**, the surfaces of one stream.

## 1. Pieces

| Piece | Role |
|---|---|
| `V4L2` (Swift) and `v4l2.c` | Device discovery and enumeration, the ioctl calls. Linux only; elsewhere every call returns `ENOSYS` and the device list is empty. |
| `CameraNegotiation` | Picks (source format, size, interval) for a request (§3.2). Pure. |
| `V4L2Capture` | An open, streaming device (§3.3). |
| `SyntheticCamera` | The test pattern behind the same interface (§7). |
| `CameraConverter`, `convert.c`, `jpeg.c` | Source frame → surface pixels (§4). |
| `CameraSurfaceLayout`, `CameraSurfaceRing` | Surface geometry and the ring (§5). |
| `CameraHostService` | Device selection, the capture thread, frame delivery, absence handling (§5, §6). |
| `ycode-simd --camera-list / --camera-probe` | Diagnostics (§8). |

`CameraCapture` is the one interface both sources implement: `device`,
`format` (what the open stream delivers), `next(timeoutMilliseconds:)` (a
raw frame, nil on timeout, throws `CameraError.gone` when the device went
away), `recycle(_:)` (the buffer goes back), `close()`.

## 2. Devices

### 2.1 Discovery

The capture devices are the nodes `/dev/video<N>` (in number order) that
open read-write and whose `VIDIOC_QUERYCAP` device capabilities (or
capabilities, without `V4L2_CAP_DEVICE_CAPS`) have both
`V4L2_CAP_VIDEO_CAPTURE` (`0x1`) and `V4L2_CAP_STREAMING` (`0x04000000`).
A UVC camera has two nodes; its metadata node (`V4L2_CAP_META_CAPTURE`
only) is left out. Nodes that do not open are reported as problems
(`EACCES`: the account needs the `video` group; `EBUSY`: another program).

A device's ID is `v4l2:<bus_info>` (`VIDIOC_QUERYCAP.bus_info`, e.g.
`v4l2:usb-<controller>-<port path>`): stable while the camera stays on the
same USB port, unlike the node number. Its name is `card`.

### 2.2 Enumeration

For each `VIDIOC_ENUM_FMT` format of the capture queue:
`VIDIOC_ENUM_FRAMESIZES` (discrete sizes as listed; a stepwise or
continuous range becomes the common sizes from 160x120 to 3840x2160 that
the range and its steps allow), and for each size
`VIDIOC_ENUM_FRAMEINTERVALS` (discrete intervals as listed; a range gives
its fastest end, 1/30 s when inside, and its slowest end). Intervals are
kept fastest first.

### 2.3 Selection

`YCODE_CAMERA` (or the `selection` argument): `auto` (default) the first
V4L2 capture device, else the synthetic camera; `synthetic`; `none` (no
camera: `start` fails with `noDevice`); a node path (`/dev/video0`); or a
device ID. A named device that is absent is an error, not a fallback.

### 2.4 Observed: the Thor's webcam

A Logitech HD Webcam C615 (USB `046d:082c`, driver `uvcvideo`): node 0 is
capture (device caps `0x04200001`), node 1 metadata. Formats:

| Format | Sizes and rates |
|---|---|
| `YUYV` | 640x480 and smaller (160x120 … 800x448) at 30 fps; 864x480 and 800x600 at 24; 1024x576 and 960x720 at 15; 1280x720 at 10; 1600x896 at 7.5; 1920x1080 at 5 |
| `MJPG` | every size from 160x120 to 1920x1080 at 30 fps |

Every size also offers the slower rates down to 5 fps. Its Motion-JPEG
frames have no DHT segment (the Annex K tables apply, §4.3) and carry a
DRI (restart intervals). The driver timestamps buffers on
`CLOCK_MONOTONIC`.

## 3. Streams

### 3.1 Request

`CameraConfiguration`: width, height, frames per second, output format
(`'420v'` by default), ring size (4), whether delivered frames stay held
until released (§5.3), whether synthetic frames stand in while the device
is absent (§6), and optionally one source format to restrict negotiation
to (diagnostics). Ycode does not scale: **the output has the negotiated
size**, which the stream reports.

### 3.2 Negotiation

Among the formats Ycode converts (`NV12`, `YUYV`, `UYVY`, `YU12`, `YV12`,
`MJPG`; others such as `H264` are skipped), each (format, size) is ranked by,
in order:

1. size: the requested size; else the smallest size that covers it (both
   sides at least as large); else the largest smaller size;
2. whether its fastest rate reaches the requested rate (within 5 %);
3. format preference, in the order above (uncompressed first);
4. the faster rate.

The interval is the slowest one that still reaches the requested rate, or
the fastest one when none does. With the C615: 1280x720 at 30 → MJPEG
1280x720 at 30; 640x480 at 30 → YUYV; 1280x720 at 10 → YUYV at 10.

### 3.3 Opening and streaming

1. `open(O_RDWR | O_NONBLOCK | O_CLOEXEC)`.
2. `VIDIOC_S_FMT` (capture, the chosen size and format, `V4L2_FIELD_NONE`).
   The driver's answer is used (size, `bytesperline`, colorimetry); a
   driver that answers with a format Ycode does not convert fails the open.
3. `VIDIOC_G_PARM` / `VIDIOC_S_PARM` with the interval when the driver has
   `V4L2_CAP_TIMEPERFRAME`; the driver's interval is reported.
4. `VIDIOC_REQBUFS` (4, `V4L2_MEMORY_MMAP`), `VIDIOC_QUERYBUF` and `mmap`
   each, `VIDIOC_QBUF` each, `VIDIOC_STREAMON`.
5. Per frame: `poll(POLLIN)` with a 200 ms timeout, `VIDIOC_DQBUF`; the
   frame is converted, then the buffer goes back with `VIDIOC_QBUF`.
   Buffers with `V4L2_BUF_FLAG_ERROR`, zero `bytesused`, or (MJPEG) not
   starting with `FF D8`, and `DQBUF` failing with `EIO`, are skipped and
   counted (`corruptFrames`).
6. Close: `VIDIOC_STREAMOFF`, `munmap`, `VIDIOC_REQBUFS(0)`, `close`.

`EBUSY` at any step means another program holds the camera; the error says
so and nothing is taken from that program. `poll` reporting `POLLERR`,
`POLLHUP` or `POLLNVAL` without data, and `ENODEV`, mean the device went
away (§6).

### 3.4 Timestamps

A frame's presentation time is the buffer's timestamp when its flags say
`V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC` (`0x2000` in the `0xe000` mask), which
UVC drivers set to the capture time on `CLOCK_MONOTONIC`; otherwise
`CLOCK_MONOTONIC` at dequeue. Nanoseconds. A frame's duration is the
stream's nominal interval. Synthetic frames are stamped `start + n ×
interval`. Mapping these host times into the guest's time base
(`mach_absolute_time`) is the guest-facing round's job (§9).

## 4. Conversion

### 4.1 Colorimetry of a source

| Source | Range | Matrix |
|---|---|---|
| `MJPG` (JFIF), or colorspace `V4L2_COLORSPACE_JPEG` | full | BT.601 |
| others | the driver's `quantization` (`V4L2_QUANTIZATION_FULL_RANGE` → full; default and `LIM_RANGE` → video) | the driver's `ycbcr_enc` (`709` → BT.709); default: BT.709 for `V4L2_COLORSPACE_REC709`, otherwise BT.601 |

The C615 reports the defaults for YUYV: video range, BT.601.

### 4.2 Arithmetic

Every source is described as three component pointers with a sample step
and a row stride each, and chroma subsampling `hsub × vsub` (packed 4:2:2:
step 2 for luma, 4 for chroma, `2 × 1`; NV12: chroma step 2, `2 × 2`;
I420/YV12: three planes, `2 × 2`; a decoded JPEG: its own sampling; grey
JPEG: one neutral chroma byte with step and stride 0).

- **Bi-planar 4:2:0** (`'420v'`, `'420f'`): luma copied through a range
  map; each output chroma sample (one per 2 × 2 luma block) is the rounded
  mean `(a + b + c + d + 2) >> 2` of the source chroma samples at the
  block's four luma positions (so 4:2:2 averages two rows; 4:2:0 copies),
  then mapped. Odd sizes repeat the last column or row.
- **Range maps** (rounding to nearest, half away from zero):
  video → full: `Y' = (Y − 16) × 255 / 219`, `C' = 128 + (C − 128) × 255 / 224`;
  full → video: `Y' = 16 + Y × 219 / 255`, `C' = 128 + (C − 128) × 224 / 255`;
  results clamped to 0…255.
- **BGRA**: each pixel from its own luma and the chroma sample covering it
  (no interpolation), alpha 255. With `d = Cb − 128`, `e = Cr − 128`,
  16-bit fixed-point coefficients (×65536) and round-to-nearest:

| | luma term | R: e | G: d | G: e | B: d |
|---|---|---|---|---|---|
| video, BT.601 | (Y − 16) × 76309 | 104597 | −25675 | −53279 | 132201 |
| video, BT.709 | (Y − 16) × 76309 | 117489 | −13975 | −34925 | 138438 |
| full, BT.601 | Y × 65536 | 91881 | −22553 | −46802 | 116130 |
| full, BT.709 | Y × 65536 | 103206 | −12276 | −30679 | 121609 |

These are `Kr`, `Kb` of each recommendation (BT.601: 0.299/0.114; BT.709:
0.2126/0.0722), scaled by 255/219 (luma) and 255/224 (chroma) for video
range. Examples (tested): video BT.601 `(16,128,128)` → black,
`(235,128,128)` → white, `(81,90,240)` → B 0 G 0 R 254; full BT.601
`(0,128,255)` → R 178.

### 4.3 Motion-JPEG

Ycode's own baseline decoder (`jpeg.c`, from ITU-T T.81): sequential DCT,
Huffman coding, 8-bit samples, 1 or 3 components, sampling factors 1 or 2,
interleaved or single-component scans, restart intervals (DC predictions
reset at each `RSTn`), 8- or 16-bit quantization tables, byte stuffing.
When a stream has no DHT the tables of Annex K.3 (K.3–K.6) are used, as
UVC Motion-JPEG relies on. Progressive, lossless, hierarchical and
arithmetic-coded frames, 12-bit samples, more than 3 components and
sampling factors above 2 are refused (`-2`); malformed data is `-1`.
The inverse DCT is the scaled algorithm of Arai, Agui and Nakajima
(dequantizers prescaled), single-precision; flat blocks decode exactly.
Output is one plane per component at its own sampling; §4.2 converts.
The decoder keeps its buffers between frames.

Cost on the Thor (release build, one capture thread; decode plus
conversion into `'420v'`): MJPEG 1280x720 8.9 ms, 1920x1080 17.5 ms;
YUYV 640x480 0.5 ms, 1280x720 1.6 ms. The C615 delivers 1080p MJPEG at
30 fps with no drops.

## 5. Surfaces

### 5.1 Layout (`CameraSurfaceLayout`)

Rows are multiples of 128 bytes and plane offsets multiples of 16 KiB (the
alignments of `Limits`, `iosurface-remote.md` §4.4).

| Output | Top level | Planes |
|---|---|---|
| `'BGRA'` (`0x42475241`) | bytes per element 4, bytes per row `align(4w, 128)`, allocation `align(row × h, 16384)` | none |
| `'420v'` (`0x34323076`), `'420f'` (`0x34323066`) | bytes per element 1, bytes per row 0 | 0: offset 0, w × h, element 1 byte, row `align(w, 128)`; 1: offset `align(size₀, 16384)`, ⌈w/2⌉ × ⌈h/2⌉, element 2 bytes (Cb Cr), row `align(2⌈w/2⌉, 128)`; allocation `align(end of plane 1, 16384)` |

1280x720 `'420v'`: planes at 0 and 933 888, rows 1280, allocation
1 409 024. Bi-planar surfaces carry the attachments (Method 21)
`YCbCrMatrixIndex` 6 (BT.601) or 1 (BT.709), `ColorPrimariesIndex` 1,
`TransferFunctionIndex` 1 (ISO/IEC 23001-8 code points).

### 5.2 Host-made surfaces (`IOSurfaceHostService`)

- `makeHostSurface(width:height:pixelFormat:bytesPerElement:bytesPerRow:allocationSize:planes:name:attachments:)`:
  a surface with the full layout, whose creation properties are the public
  keys a guest client would pass (`IOSurfaceWidth`, `…Height`,
  `…PixelFormat`, `…BytesPerElement`, `…BytesPerRow`, `…AllocSize`,
  `IOSurfaceName`, and `IOSurfacePlaneInfo` with `IOSurfacePlaneWidth`,
  `…Height`, `…BytesPerRow`, `…Offset`, `…Size`, `…BytesPerElement` per
  plane), so Methods 2 (look-up by ID), 6 (plane state), 10 and 21 answer
  as for a guest-made surface. It has a Method-14 port (a receive right of
  the host task) that keeps it alive; returns the port and the surface
  (ID, shared memory, layout).
- `releaseHostSurface(port:)`: drops the host's hold; the surface lives on
  while a guest connection references it (§8 item 8 of that spec).
- `hostDidWrite(id:)`: raises the seed, as a guest write lock does, so
  readers that skip unchanged surfaces see the new frame.
- `guestUsage(id:)`: the use count (Methods 15/16), lock count (4/5) and
  connection references.

### 5.3 The ring (`CameraSurfaceRing`) and delivery

A stream has `ringSize` surfaces named `ycode-camera <i>`. For each frame
the next slot after the last written one is taken that is not being
written, not held by the consumer, and has use count and lock count 0
(the guest is not reading it). With none free the frame is dropped and
counted (`droppedBefore` on the next frame). The frame is converted
straight into the surface's shared memory, the seed raised, and the
callback gets a `CameraFrame`:

| Field | Meaning |
|---|---|
| `sequence` | Ycode's counter for the stream, from 0, no gaps |
| `deviceSequence` | V4L2 `sequence` (synthetic: frame number) |
| `surfaceID`, `surfacePort`, `seed`, `slot` | the surface (ID for Method 2 `LookupID`; port: host-task name of its Method-14 port) |
| `format`, `width`, `height` | output format and size |
| `presentationTime`, `duration` | §3.4, nanoseconds |
| `droppedBefore` | frames dropped since the previous delivery |
| `synthetic` | a synthetic frame (synthetic device or stand-in) |

The callback runs on the capture thread (`ycode-camera`). With
`holdFramesUntilReleased` a delivered slot is not reused until
`release(frame)`; otherwise it is free once the callback returns (the
guest's use count still protects a surface it is reading). `stop()` ends
the thread, closes the device and releases every surface the service made.
Counters: `delivered`, `dropped`, `conversionTotal`, `conversionMax`.

## 6. Absence and hot-plug

- No camera at start with `auto`: the synthetic camera.
- The device goes away mid-stream (`ENODEV`, poll error/hang-up): event
  `.disconnected(deviceID:fallback:)`. With `syntheticWhileAbsent` (the
  default) the synthetic pattern continues at the stream's size and rate,
  frames marked `synthetic`, into the same ring; otherwise nothing is
  delivered.
- While absent, the device list is read once a second; when a device with
  the same ID (any V4L2 camera, for `auto`) appears it is opened with the
  same request: event `.reconnected(format)`. A different size gets a new
  ring; the old ring's surfaces are released at `stop()` (a consumer may
  still hold frames in them).
- Events also include `.started(format)` and `.stopped`.

## 7. The synthetic camera

Device ID `synthetic`, name "Ycode Synthetic Camera", one format `YUYV`
(video range, BT.601: the same conversion path as a webcam), any even size
of at least 64 x 48 (the list offers 320x240 … 1920x1080 at 60/30/15). It
paces itself to the interval (or not, for tests: frames return at once with
the same timestamps).

### 7.1 Pattern

- Rows `[0, ⌊2h/3⌋ even)`: eight 75 % colour bars of width ⌊w/8⌋ (the last
  takes the rest): white, yellow, cyan, green, magenta, red, blue, black
  (R, G, B each 0 or 191), as BT.601 video-range Y'CbCr rounded
  (yellow: 161, 44, 142).
- Then a grey ramp, luma `16 + 219x/(w−1)`, to the counter strip.
- The counter strip: the last `max(4, ⌊h/24⌋ even)` rows, 32 cells of
  width ⌊w/32⌋, the frame number's bits most significant first: luma 235
  for 1, 16 for 0. `SyntheticCamera.readCounter` reads it back from any
  luma or grey channel (cell centres; each must read below 60 or above
  180).
- A white (luma 235) square of side `max(8, ⌊h/6⌋ even)`, vertically
  centred in the bars, moving `max(2, ⌊w/64⌋ even)` pixels per frame
  across the width and back.
- The frame number (modulo 10⁸) in decimal, top left, 3 x 5 pixel glyphs
  scaled by `max(2, ⌊h/48⌋)`, white on black.

Chroma under the square, digits and strip is 128.

## 8. Diagnostics

`ycode-simd --camera-list`: every camera (V4L2, then synthetic) with its
formats (unconverted ones marked), sizes and rates, and open problems.

`ycode-simd --camera-probe [--camera SEL] [--frames N] [--size WxH]
[--fps F] [--pixel-format 420v|420f|BGRA] [--source-format FOURCC]
[--out file.png] [--scale K]` (defaults: auto, 30, 1280x720, 30,
`'420v'`): streams through `CameraHostService` into host-made surfaces of
an IOSurface service on a fresh `DarwinSystem` host task (no VM), prints
the negotiated stream, the surface IDs, one line per frame (sequence,
device sequence, surface, seed, presentation time and its delta, drops,
and for synthetic frames the counter read back from the surface), the
events, the measured rate and the conversion cost, and writes the last
frame as PNG (downscaled K times). Exit 0; 69 no camera, busy, or no
permission; 64 usage; 1 otherwise. Both run on any host (the synthetic
camera only, off Linux).

## 9. For the guest-facing round

The guest-facing round is done (agent CAMERA-GUEST, 2026-10-28):
`camera.md` §9 ("Ycode implementation") describes the endpoint
`dev.ycode.camera` (`CameraGuestService`, on top of this layer), the
per-device opt-in, and Ycode's guest capture layer. How it uses this
layer:

- `CameraHostService.devices()` / `resolve(_:)` give the one device it
  presents (camera.md §9.2: an iPhone's back or front camera, an iPad's
  external camera), with the sizes Ycode converts and their rate ranges.
- A stream opens with `holdFramesUntilReleased` and no synthetic stand-in;
  each frame goes to the guest by surface ID (the guest maps it through
  `IOSurfaceLookup`, `iosurface-remote.md`), and the guest's release
  (a one-way message when the app lets the buffer go) calls `release(_:)`.
- Presentation times become guest mach ticks with a reading of the
  guest's counter taken around a reading of CLOCK_MONOTONIC (camera.md
  §9.2 "Time").
- Orientation and mirroring are applied in the guest (camera.md §9.4); the
  host adds no metadata beyond §5.1.

Still open: scaling (the guest is offered only the camera's own sizes, so
none is needed yet); the top-level bytes per row of planar surfaces (0;
`iosurface-remote.md` §Open 4); and snapshot/restore of a streaming
camera (not designed or tested: the camera runs were cold boots).

## Evidence

| Claim | Level |
|---|---|
| V4L2 ioctls, structures, capability and buffer flags, timestamp flags, colorimetry enums, `EBUSY`/`ENODEV` semantics, metadata nodes (§2, §3) | 1 (Linux kernel media API documentation, `linux/videodev2.h`) |
| The C615's nodes, formats, sizes, rates, missing DHT, DRI, monotonic timestamps; costs and rates (§2.4, §4.3) | 3 (Ycode's own `--camera-list`/`--camera-probe` and opt-in hardware test on the Thor, 2026-10-27; one frame's markers listed with ffmpeg's stream copy) |
| JPEG decoding, Annex K tables, restart handling (§4.3) | 1 (ITU-T T.81 / ISO/IEC 10918-1); the scaled IDCT from Arai, Agui and Nakajima (1988), checked against a direct 8 x 8 IDCT |
| Matrices, ranges (§4.2) | 1 (ITU-R BT.601, BT.709) |
| Output pixel format codes `'420v'`, `'420f'`, `'BGRA'` | 1 (public `CVPixelBuffer.h`) |
| IOSurface creation and plane keys, attachment keys, alignments (§5) | 1 (public `IOSurfaceRef.h`); `iosurface-remote.md` §3.2, §4.4, §5.2 |
| Attachment code points (§5.1) | 1 (ISO/IEC 23001-8); values seen in boots in `iosurface-remote.md` §3.2 |
| Layout choices, ring policy, negotiation order, synthetic pattern, events (§3.2, §5–§7) | Ycode design (no reference behaviour claimed) |
