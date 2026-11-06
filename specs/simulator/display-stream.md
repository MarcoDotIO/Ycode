# Spec: the display stream (live view and input for a remote viewer)

Status: **implemented** (agent SIM-VIEWER, 2026-10-19; Linux viewer, stage
timing, H.264, sound and remote x86 viewing: REMOTE-X86, 2026-10-31).
Ycode-original design: nothing here describes Apple software. It defines
how `ycode-simd` serves a device's display and sound and takes input over
one socket, and how the viewers (`ycode-sim-viewer` on macOS, §7, and on
Linux, §13) use it. How input then enters the guest is `hid-input.md`; how
a viewer reaches a simulator host without ssh is `sim-link.md`.

Code: `Sources/YcodeDisplayStream` (protocol and sockets, shared),
`Sources/CYcodeCodec` (JPEG, zlib, downscale), `Sources/ycode-simd/
DisplayServer.swift`, `DisplayTiles.swift`, `InputBridge.swift`,
`Sources/ycode-sim-viewer`, `scripts/ycode-sim-serve`, `scripts/ycode-sim-try`;
timing instruments in §10. Since REMOTE-X86: `Sources/YcodeRemoteViewer`
(the portable viewer: stream client, canvas, touches, layout, clock, sound,
scripts), `Sources/YcodeRemoteViewerSDL` (the Linux window),
`Sources/CYcodeVideo` (NVENC/NVDEC), `Sources/CYcodeCodec/audio.c` (Opus,
PulseAudio), `Sources/ycode-simd/DisplayVideo.swift`, `DisplayAudio.swift`.

## 1. Transport

- `ycode-simd --device … --display-server <address>` listens on a
  **Unix-domain socket** (`unix:<path>`, mode 0600) or **TCP**
  (`<host>:<port>`, `<port>` = 127.0.0.1). The launcher uses a Unix socket
  on the simulator host and forwards it with `ssh -L <local port>:<socket>`:
  no port is opened on a shared host, and ssh supplies authentication and
  encryption. The protocol itself has no authentication: never listen on a
  non-loopback TCP address.
- **A viewer taken over does not fight** (§1.1, XR-HUB 2026-11-02).
- A stale socket file (nobody accepting) is replaced; a live one is an error.
- **One viewer at a time.** A new connection closes the previous one (it
  gets a notice first), so a viewer can reconnect after a network drop.
- Without `--display-server` nothing of this exists. With it, before a
  viewer connects, one thread waits in `accept()`; no frame work is done.

### 1.1 Takeover

The notice the server sends the previous viewer is exactly "another viewer
connected; this one is closed" (`DisplayNotice.takenOver`). A viewer that
gets it does **not** reconnect by itself: it reports the phase `takenOver`
and waits until its user takes the display back (the hub's canvas: Take
Back or Back to Desktop; the Linux viewer: a click on the screen; the
headset viewer ends). Before, every viewer reconnected after 1 s, so two
viewers of one device took the display from each other every second. A
viewer whose connection drops for any other reason still reconnects. The
hub expects the takeover when it starts the headset viewer itself and
shows no notice then (`device-hub.md` §I.12.3).

## 2. Framing

Both directions: a sequence of messages, each

| Bytes | Field |
|---|---|
| 4 | length n (little-endian u32) of type + payload, 1 ≤ n ≤ 64 MiB |
| 1 | message type |
| n − 1 | payload |

Types 0x01–0x7F go server → client, 0x81–0xFF client → server. A receiver
skips a message of an unknown type (forward compatibility) and closes the
connection on a length out of range or a malformed known message. All
integers are little-endian; floats are IEEE.

| Type | Name | Payload |
|---|---|---|
| 0x01 | hello | JSON (§3.1) |
| 0x02 | status | JSON (§3.3) |
| 0x03 | frame | binary (§4) |
| 0x04 | pong | u64 token, u64 server monotonic ns |
| 0x05 | screenshot | u32 token, PNG bytes (empty: none available) |
| 0x06 | notice | UTF-8 text for the person (e.g. "input not delivered…") |
| 0x07 | display state | JSON (§11) |
| 0x08 | frame timing | 5 × u64: the server's stage times of the frame just sent (§12) |
| 0x09 | audio | u64 play time, u8 codec, u8 channels, u16 frames, u32 rate, data (§15) |
| 0x0A | frame view | the headset mode (§18): the view and pose of the next frame message |
| 0x0B | inset | foveated streaming (§18): the full-resolution inset around the gaze for the frame just sent |
| 0x0C | frame depth | the headset mode's depth of the frame just sent (§19, `xr-depth.md` §4.2) |
| 0x0D | environment | the room's environment cube, on request and on change (§19, `xr-depth.md` §4.3) |
| 0x10 | command answer | u32 token (the command's), UTF-8 text: the control socket's answer ("ok …" or "error: …") |
| 0x81 | client hello | JSON (§3.2) |
| 0x82 | touch | §5.1 |
| 0x83 | key | §5.2 |
| 0x84 | button | §5.3 |
| 0x85 | ping | u64 token |
| 0x86 | keyframe request | empty: the next frame covers the whole image |
| 0x87 | screenshot request | u32 token |
| 0x88 | rotate | u8 orientation (1 portrait, 2 upside down, 3 landscape left, 4 landscape right; 5 face up, 6 face down) |
| 0x89 | fold | u16 hinge angle 0–180, u8 flags (bit 0: one message, no sweep) (§11) |
| 0x8A | pose | visionOS camera pose (§17): u32 sequence, 3 × f32 position, 4 × f32 quaternion x, y, z, w |
| 0x8B | selection | visionOS gaze and hands (§17): u32 sequence, u8 flags (bit 0: hands present), u8 0, u16 0, 3 × f32 ray origin, 3 × f32 ray direction, then with hands left and right: u8 pinching, u8 allowDirect, u16 0, 3 × f32 position, 4 × f32 quaternion x, y, z, w |
| 0x8C | dial | visionOS Digital Crown (§17): u32 sequence, f32 signed turn |
| 0x8D | views | the headset mode (§18): u32 sequence, u8 flags, u8 0, u16 0, head, left eye, right eye (each 3 × f32 position, 4 × f32 quaternion) |
| 0x8E | fovea | foveated streaming (§18): u32 sequence, f32 u, f32 v (where the eyes look in the guest's view; never logged) |
| 0x8F | frame ack | u64 sequence: every frame up to it is decoded (flow control, §4.2.1) |
| 0x90 | command | u32 token, UTF-8 words of a control-socket command (`ui appearance dark`, `settings`; `simulator-features.md` §I.4); answered by 0x10, off the receive thread (a command can wait for the guest) |

## 3. Control messages

### 3.1 Server hello (sent first, on connect)

JSON object: `protocol` = `"ycode-display/1"`, `deviceName`, `model`,
`pixelWidth`, `pixelHeight`, `scale`, `pointWidth`, `pointHeight`
(pixels / scale; the touch coordinate space), `orientation` (`"portrait"`),
`encodings` (the frame encodings this server can produce, from
`["jpeg", "zlib"]`), `touch`, `keyboard` (booleans: whether input is
wired to the guest), `buttons` (names from §5.3), `rotation` (false today:
rotation is not implemented, the viewer disables it). Optional since
HUB-UI (2026-10-28): `deviceType` (Ycode's device type id, `ycode-simd
--device-type`, e.g. `iphone-duo`) and `osVersion` (the runtime,
"iOS 27.1"): the viewer draws the device's frame from the type and titles
its window with the OS (`device-hub.md` "Ycode implementation"); a viewer
without them falls back to the model identifier and the pixel size.
Optional since REMOTE-X86: `encodings` may include `"h264"` (§14), and
`audio` lists the sound codecs the server sends (`["opus", "pcm"]`, §15;
absent: no sound). Optional since VISIONOS-R9: `spatial` (true: the
server takes pose, selection and dial, §17) and `rooms` (the room keys the
device offers). Optional since XR-VIEWER: `xr` (true: the headset mode,
§18). Optional since XR-GAZE: `frameAcks` (true: the server honours a client's
`frameWindow`, §4.2.1).

### 3.2 Client hello

JSON: `protocol`, `client` (a name for logs), `maxFPS` (1–120), `encoding`
(`"jpeg"` or `"zlib"`), `quality` (JPEG, 1–100), `downscale` (1–4: the
stream image is ⌈pixel size / downscale⌉ per axis). The server clamps the
numbers, falls back to an encoding it has, and starts with a full frame.
The client may send another hello at any time to change settings. Until a
client hello arrives (at most 2 s) the server sends nothing but hello and
status. Optional since REMOTE-X86: `encoding` `"h264"` (§14),
`videoBitrate` (kbit/s, §14), `timing` (true: a frame timing message after
every frame, §12), `audio` (the sound codecs the client plays, preferred
first; absent or empty: no sound, §15). Optional since XR-VIEWER: `xr`
(`{"stereo": "adaptive" | "alternate" | "mono", "latch": n, "settleMs":
n}`: the headset mode, §18). Optional since XR-GAZE: `frameWindow` (n: at most
n frames unacknowledged, §4.2.1).

### 3.3 Status

JSON: `phase` — `"booting"` (no frame presented yet), `"live"`, or
`"stopping"` (the device is shutting down; the connection closes next) —
`uptimeMilliseconds` (since `ycode-simd` started), `guestFrames` (the
framebuffer library's frame counter), optional `message`. Sent on every
phase change, every second while booting, every 5 s while live.

## 4. Frames

### 4.1 Source

The headless framebuffer library rewrites its 96-byte frame record
(`ycode-framebuffer.state` in the device's memory directory, guest path
`DEV/ycode-memory`, `frame-profile.md` §8.1; `simframebuffer.md` and
`SimGuestFrameworks/SimFramebuffer`) on every swap: the presented IOSurface
id and a frame counter. While a viewer is connected, the server reads the
record every 4–8 ms (one `pread`) and maps the surface through the VMM's
IOSurface service (no copy).

### 4.2 Damage

The server keeps, per viewer, a copy of the image the viewer has (device
pixels, BGRA). A **scan** compares the presented surface with that copy in
tiles of 32 × downscale pixels (whole rows first, so an unchanged frame costs
one `memcmp` per row), merges changed tiles into rectangles (runs per tile
row, gaps of up to two tiles joined; equal spans in consecutive rows joined;
more than 24 rectangles or more than 60 % of the screen → one bounding box),
copies them into the viewer's image, and encodes them.

Scans happen when the frame counter changes, for 300 ms after each change
(the GPU may finish writing a surface after the swap), for 500 ms after
each input event, on a keyframe request, and once a second as a safety net.
`maxFPS` limits the frames **sent**: a new frame record (or a keyframe
request) is scanned as soon as the last sent frame is one interval old
(measured from that frame's capture since REMOTE-X86, §16.3; before, from
the end of its send, which added scan + encode + send to every interval); the
speculative scans (settling, after input, the safety net) run at most once
per interval and never hold back the scan of a new frame. (Before
2026-10-19 every scan counted against the interval, so a settling scan that
found nothing delayed the next real frame by up to 16 ms; §10.4.) The
server learns of a new record from inotify on the record's directory (the
guest's write reaches the host file), with the 4–8 ms poll as the fallback.
Sends are blocking: on a slow link the next scan simply waits, and because
damage is computed against what the viewer has, the newest pixels always
win and no frame queue builds up.

#### 4.2.1 Flow control (XR-GAZE, 2026-11-02)

A slow viewer must see the newest picture late, never a queue of old ones. Only
the server's blocking send used to push back, and between it and the decoder lie
the Unix socket, two TCP buffers (megabytes when auto-tuned: seconds of video at
a megabyte per second) and, over the link, the transport's own queue in the
viewer, which had no bound. In run 8's `--reproject off` that queue reached 11 s
(`xr-viewer.md` §13.2).

A client whose hello carries `frameWindow` n acknowledges every frame once it is
decoded (0x8F, the newest sequence; only when the server's hello says
`frameAcks`). The server captures a new picture only while fewer than n frames
are unacknowledged. While the window is full it scans nothing and encodes
nothing, so the next frame is simply the newest picture against the mirror (§4.2):
the encoder's chain stays whole and no keyframe is needed. An acknowledgement
wakes the send loop at once. A lost frame (UDP) is covered by the next
acknowledgement; if none comes for 300 ms, one more frame goes, so a lost message
cannot stop the stream. In the alternate-eye mode the window also holds back the
next eye's pose (`due`), which would otherwise be lost with the picture it is for.
Depth, timing and sound are not counted. `ycode-xr-viewer` asks for 3
(`--frame-window`; 0: none); other viewers do not ask yet and behave as before.
Over the link the transport's queue is also bounded now (16 MB: past that the TCP
reader waits, so the socket pushes back).

#### 4.2.2 Lossless once still (B3-UIKITFEEL, 2026-11-05)

JPEG tiles and video pictures are lossy, and a stream only sends a picture
when the screen changes, so before this a still screen stayed blurred and
text was never exact at 1:1. A client whose hello carries `stillLossless`
(true in every Ycode viewer: the hello initializer's default; older clients
and the Python probes leave it out) gets, once the screen is still, the parts
it last received lossy again as zlib tiles at the stream's downscale:

- The server keeps, per viewer, the tiles of its grid (32 × downscale device
  pixels) that it last sent lossy (`StillRefinement` in
  `YcodeDisplayStream`). A lossy frame marks the tiles its rectangles touch
  (an IDR picture all of them); a zlib frame clears those it covers.
- Due when nothing lossy went out and no new frame record arrived for
  **200 ms**, and the flow-control window is open. Then the marked tiles go
  as one frame of disjoint rectangles (runs of tiles per tile row, equal runs
  of consecutive rows joined), encoding 2, and are forgotten. A screen that
  keeps moving never pays for it; 200 ms looks immediate once it stops.
- The viewers need nothing new: a frame's encoding is per frame, and the
  portable canvas already converts a video picture to BGRX before tiles
  are drawn over it (§13.1); the next video picture shows again.

Checked with the UIKitFeel probe's 96 × 96 pattern of random grey levels
(`uikit-feel-ycode.md` §8.4): through JPEG q80 and H.264 the Linux window at
Pixel Accurate and the macOS window at one device pixel per display pixel
show it exactly.

### 4.3 Frame message (0x03)

| Bytes | Field |
|---|---|
| 8 | sequence (frames sent on this connection) |
| 8 | guest frame (the record's counter) |
| 8 | server monotonic ns when the frame was encoded |
| 4 | input sequence: the newest input event (§5) received before the scan |
| 2, 2 | stream image width, height |
| 1 | encoding: 1 JPEG, 2 zlib, 3 H.264 (§14) |
| 1 | flags: bit 0 = the tiles cover the whole image |
| 2 | tile count |
| per tile | u16 x, u16 y, u16 width, u16 height (stream-image pixels), u32 length, data |

JPEG tiles are baseline JPEGs (libjpeg-turbo, loaded at run time; 4:2:0,
fast DCT) whose rectangles start on 32-pixel boundaries, so they line up
with the encoder's 16-pixel blocks. A rectangle taller than 256 stream rows
is cut into **bands** at multiples of 256 stream rows from the top of the
image; the server encodes up to four bands at once, and the viewer decodes
a frame's tiles in parallel (tiles never overlap). A whole-screen change is
8 bands at full resolution. zlib tiles are RFC 1950 streams of
packed BGRA rows (lossless; more bandwidth). A viewer that cannot decode a
tile asks for a keyframe.

The input sequence gives **input → screen latency** without clock sync:
the viewer notes when it sent event k; the first frame with input sequence
≥ k is the first change the guest drew after receiving it.

### 4.4 Screenshots

A screenshot request is answered with a full-resolution PNG (zlib level 6)
of the presented surface, independent of the stream's downscale and
encoding.

## 5. Input (client → server)

Every input message starts with a u32 **sequence** number (client
counter, starting at 1). The server hands events to the HID bridge
(`hid-input.md` §7, §8) in arrival order.

### 5.1 Touch (0x82)

u32 sequence, u8 count, then count × {u8 finger (0-based), u8 phase
(0 began, 1 moved, 2 ended, 3 cancelled), u16 0, f32 x, f32 y} in **device
points** (origin top-left, portrait). A message lists every finger that is
down or ending. The bridge maps finger f to HID slot f + 1, normalizes by the
point size, marks edge contacts (`hid-input.md` §8.2: within 10 points of an
edge at began), and sends every message with its age from one thread (`hid-input.md` §14.3; until 2026-11-05 it coalesced move-only messages to one per 16 ms).

### 5.2 Key (0x83)

u32 sequence, u8 down (1) / up (0), u8 0, u16 usage page (7), u16 usage
(USB HID keyboard usages; modifiers are keys 0xE0–0xE7).

### 5.3 Button (0x84)

u32 sequence, u8 button (1 home, 2 lock, 3 volume up, 4 volume down,
5 side, 6 action), u8 down. The bridge sends the usage pairs of
`DeviceButtonTable` (consumer page, `hid-input.md` §5.5; on a watch the
pairs of `watchos.md` §5.2, the Ultra's Action button 0xFF01/0x200, and no
volume buttons). A server lists the buttons its device has in the hello's
`buttons`; a viewer sends 6 only when "action" is listed (an older server
closes the connection on an unknown value) (WATCH-W7, 2026-10-31).

## 6. Shutdown

With `--display-server`, SIGTERM, SIGINT, and SIGHUP make `ycode-simd`
send status `stopping`, end the device session (launchd_sim shuts the guest
down), and exit; a second signal, a session not yet bound, or 30 s without
an exit end it at once. With a stop snapshot configured
(`YCODE_SNAPSHOT_STOP_DIR`, the launchers' warm start, §9) the signals
belong to the snapshot's stop trigger instead: the server sends `stopping`
("the device is being saved; the next run continues from it"), closes the
viewer (its touches, keys and buttons are released in the guest), and the
device is saved (`snapshot.md` §12.2); a device that cannot be saved yet
shuts down as above. `scripts/ycode-sim-serve stop` sends SIGTERM to the
launcher and kills its process group after 150 s.

## 7. The viewer (`ycode-sim-viewer`, macOS)

*Since HUB-UI (2026-10-28) the window is Ycode's compact device window
(`device-hub.md` §2.2 and "Ycode implementation"): a unified toolbar with
the device's name and OS and the Expand │ More Actions capsule, the device
in Ycode's frame (clickable buttons), the glass control row (Home,
Screenshot, Record │ Rotate, and the iPhone Duo's poses), no button bar
and no status line (More Actions ▸ Show Frame Rate shows it); resizing the
window scales the device; the menus are View, Device and Controls
(`device-hub.md` I.5: Screenshot is now ⇧⌘S, ⌘1/⌘2/⌘3 are retired).
Expand switches the window to the hub's canvas layout (zoom segments,
Capture Keyboard). The window, canvas, frame, controls and the connection
below live in the `YcodeDeviceUI` module, which the IDE's Device Hub
uses too. The list below describes the input and decoding, which are
unchanged.*

- Window: the stream at the device's aspect ratio (resizing keeps it), a
  button bar (Home, Lock, Vol +, Vol −, Rotate — disabled until the server
  offers rotation — Screenshot) and a status line: connecting / booting
  (uptime) / live, frames per second, KB/s, the last input → screen
  latency, and the ping round trip. ⌘1 half size, ⌘2 point accurate, ⌘3
  pixel accurate.
- Mouse and keys: `hid-input.md` §8 (click/drag one finger; Option-drag
  pinch/rotate mirrored about the center, with indicator dots; Option-Shift
  two-finger pan; scroll wheel or trackpad scroll → a one-finger drag,
  ended at the end of the gesture or after 150 ms idle; momentum events are
  not forwarded, the guest makes its own; keys without ⌘ → page-7 usages,
  no repeats; ⌘ shortcuts stay with the viewer: ⇧⌘H Home, ⌘L Lock, ⌥⌘↑/↓
  volume, ⌘S screenshot to the Desktop as a PNG). Losing focus cancels
  touches and releases keys.
- Decoding (a connection thread, never the main thread): JPEG tiles are
  decoded with ImageIO in parallel and their pixels are written straight
  into the canvas (a channel permute, no Core Graphics draw); a decoded
  layout other than 8-bit RGB in 32 bits falls back to a Core Graphics draw.
  The main thread gets at most one image at a time: frames that arrive
  while it is busy replace the waiting one. The layer filters bilinearly
  (trilinear, which makes Core Animation build mipmaps of every frame, only
  when the image is shown at less than half its size).
- It reconnects every second until the server is reachable, so it can be
  started before the device.
- `--script <file>` drives it with synthesized AppKit events (the same code
  path as the mouse and keyboard) and logs input → screen latencies; used
  for end-to-end tests. Besides input, waits and screenshots it has
  `wait-home` (until the shown image is lit: less than 90 % of its samples
  darker than 24, in two looks 0.5 s apart, i.e. past the boot logo, in
  light and dark appearance) and `wait-change [percent]`
  (until the shown image differs from the one at the command's start in
  that share of 48 × 64 grey samples; it logs the time), which measure when
  the device takes input.

## 8. Measurements (2026-10-19, Thor host, Mac viewer through an ssh forward on the same LAN, round trip 0.5 ms)

| What | Result |
|---|---|
| Home-screen swipes, JPEG q80, full resolution | guest presented 6.7–7.8 fps; the viewer received 5.6–7.4 fps (all but a few frames); 350 KB/s |
| Same, `--downscale 2 --quality 70` | 6.9 fps received, 139 KB/s |
| Same, `--encoding zlib` (lossless) | 7.4 fps received, 4.8 MB/s |
| Server time per frame (scan + encode) | 2–12 ms JPEG full resolution (a full 1398 × 2034 frame about 10–15 ms), 5 ms at downscale 2, 30 ms zlib |
| Idle with a viewer connected | display threads about 1.5 % of one core (frame-record polls, the 1 s safety scan) |
| No viewer / no `--display-server` | no work (one thread in `accept()`; without the option nothing starts) |
| Input → first changed frame at the viewer | touch 90–280 ms, keys 25–520 ms, Home 140–780 ms (more when the guest is busy), Lock 1.2–1.7 s; almost all of it is the guest's own reaction (network round trip 0.5 ms on this LAN) |

The guest's own frame rate (about 7 fps while animating on this host) is
the limit, not the stream.

## 9. Sessions keep the device (warm start)

`scripts/ycode-sim-serve start` runs the IDE's launcher (`ycode-sim.sh`,
`snapshot.md` §12) with `YCODE_WARM_BOOT=1`: closing the viewer (the
launcher gets SIGTERM) saves the running device, and the next session
restores it in place. A restored device is `live` with its last frame
within about 1 s of the restore (the frame record survives the restore),
takes input at once (the HID registration is restored, `hid-input.md` §7
item 6), and shows what it showed when it was saved, with its apps, data
and settings. `--cold` boots it cold once (data kept), `--erase` starts
from a new copy of the pristine device; a new simulator build, runtime or
boot option boots cold too. A cold boot is saved only from 30 s after its
home screen (`snapshot.md` §12.4 item 4). Measured from the viewer's start:
a restore session is live in 11–15 s (of which 4.6–6.4 s are the restore
and up to 9 s the wait for the previous save), the first tap changes the
screen 0.7–1.4 s later; a cold boot reaches the home screen about 90 s
after `ycode-simd` starts (`snapshot.md` §12.4).

## 10. Frame timing and input latency (FPS-LATENCY, 2026-10-19)

### 10.1 Instruments (all off by default)

| Switch | What it records |
|---|---|
| `YCODE_DISPLAY_TIMING=1` (host environment of `ycode-simd`) | three files in the memory directory (`frame-profile.md` §8.1; while the device runs, links of the same names in `DEV/data/tmp` point to them, and the run's end leaves copies there): `ycode-framebuffer.timing` (the framebuffer library: one 48-byte entry per swap in a ring of 8192 — frame, SwapBegin's target time, mach time at SwapBegin, at SwapSubmit, when the completion block ran, surface id); `ycode-simhid.timing` (the HID bundle: one 32-byte entry per event in a ring of 4096 — host sequence, mach time taken from the port, after dispatch to the event system, kind); `ycode-display.trace` (the server, text: `sync <host ns> <guest ticks>` once a second, `input`, `record`, `frame` lines with host `CLOCK_MONOTONIC` times). The guest variables are set at boot, so a restored device keeps the setting of the boot that was saved |
| `YCODE_DISPLAY_AB=1` | paired A/B of the server's latency features: the record watcher is ignored in odd seconds, banded encoding is used on even frame sequence numbers; trace lines carry the arm |
| `YCODE_FRAMEBUFFER_COMPLETION=delay-<ms>[-ab]` | the framebuffer library calls swap completion blocks that much later (with `-ab`, only in odd seconds of mach time); a diagnostic for §10.3. `vsync`: completions at the next point of a 60 Hz grid, with that time; `vsync-block`: `SwapSubmit` also waits for it (B3-UIKITFEEL: neither moves the display link's timestamps, `uikit-feel-ycode.md` §7.2) |
| `scripts/ycode-display-probe` | a headless display-stream client (Python standard library; run with `python3 -I` on the simulator host or through a forward): scripted swipes, taps, keys, Home; per phase it prints received and guest frame rates, input → first frame, the swap cadence from the framebuffer log (`--timing`), and with `--trace <DEV/data/tmp>` the input → photon breakdown below |
| `SimShim/guest-tests/stageperf/p_frameclock` | a guest probe: can a guest thread keep a 60 Hz cadence with `mach_wait_until`, `nanosleep`, dispatch timers (leeway 0 and default), an `EVFILT_TIMER` kevent, and `mach_msg` receive timeouts; also the mach-time rate against `CLOCK_MONOTONIC` |

### 10.2 The guest frame clock

- **Timers keep 60 Hz.** `p_frameclock` under `ycode-simd --exec` on the
  Thor (load average 44): every primitive delivered 180 wakeups in 3.000 s
  (60.0 Hz); lateness p50 0.1–0.6 ms, p99 2–6 ms, no gap longer than 1.5
  periods; `nanosleep` overshoot p50 0.13 ms. The timebase is 125/3
  (24 MHz) and mach time ran −6 ppm against `CLOCK_MONOTONIC` over 18 s. So
  timer coalescing, kevent rounding, and 24 MHz scaling do not slow frames.
- **The render server paces itself at 60 Hz.** In every swap of every run,
  the target time `backboardd` passes to `SwapBegin` equals the mach time of
  the `SwapBegin` call (it is the frame's start, not a future vsync). When a
  frame takes less than a period, consecutive `SwapBegin`s are 16.0–17.5 ms
  apart (a home-screen swipe at load ≈ 20: 14 frames in a row at
  16.05–17.48 ms, 61.6 fps in one burst). When a frame takes longer, the
  next one starts about 11–14 ms after the `SwapSubmit` (not at the next
  16.67 ms grid point; §10.5 question 1), so the cadence is roughly
  1 / (build + 12 ms).
- **Swap completions do not gate frames.** Completion blocks normally run
  0.1–2 ms after the submit (p90 7–17 ms on a loaded host). With every
  completion in alternate seconds delayed by 30 ms
  (`YCODE_FRAMEBUFFER_COMPLETION=delay-30-ab`), 96 of 110 frames began
  before the previous frame's completion and the cadence did not drop, so
  completion latency is not a frame-rate lever (depth beyond one frame not
  tested).
- **What limits the frame rate is the frame's own build time**
  (`SwapBegin` → `SwapSubmit`, i.e. the render server's drawing and the GPU
  path): at the home screen p50 13–15 ms, p90 35–57 ms, max 130–340 ms
  (load 18–37). Swipes reached 23–35 fps in bursts; the Spotlight pull-down
  (blur) 8–12 fps. This belongs to the GPU/render path and the guest CPU,
  not to the frame clock, the input path, or the stream.

### 10.3 Input → photon

Medians of the labelled inputs of one probe session (8 swipes, 2 taps,
2 keys, Home; Thor load ≈ 34; host-side probe, so no network):

| Stage | Before (2026-10-19, `ab1`) | After (`ab2`) |
|---|---|---|
| server receives → handed to the HID service | 0.07 ms | 0.08 ms |
| HID message → the bundle takes it in `backboardd` | 0.08 ms | 0.12 ms |
| taken → dispatched to the event system | 1.2 ms (one 281 ms outlier) | 1.9 ms (one 342 ms outlier) |
| dispatched → the next `SwapBegin` (backboardd → app → commit) | 39 ms | 122 ms |
| `SwapBegin` → `SwapSubmit` (build) | 12.9 ms | 13.4 ms |
| submit → the server sees the record | 2.7 ms | 2.9 ms |
| record seen → frame sent (scan, encode, send) | **16.4 ms** | **2.05 ms** |
| sent → the probe has it | 0.10 ms | 0.10 ms |
| total, input → first frame (median of all labelled inputs) | 183 ms | 179 ms |

The guest's own reaction (dispatched → next `SwapBegin`, then the build)
is about 90 % of the time; it varies widely between sessions (median 39 vs
122 ms over 14 inputs each, similar host load) although nothing in that
path changed between them. Delivery into
`backboardd` takes about 0.2 ms; the server's share went from about 20 ms
to about 5 ms (§10.4). Through the viewer on the Mac, add the forward
(0.5 ms on the LAN) and the viewer's decode (§10.4).

### 10.4 Stream and viewer: changes and paired numbers

| Change | Measurement | Before | After |
|---|---|---|---|
| Pacing: settling scans no longer hold back a new frame (§4.2) | record seen → frame sent, median (`ab1` vs `ab2`) | 16.4 ms | 2.05 ms |
| Record watcher (inotify) instead of the 4–8 ms poll alone | submit → record seen, paired by second (`YCODE_DISPLAY_AB`), `ab1` / `ab2` | poll p50 2.96 / 3.54 ms | watch p50 0.79 / 1.57 ms |
| Banded, parallel JPEG encoding (§4.3) | scan + encode of frames over 60 KB, paired by frame, load ≈ 33 | p50 10.1, p90 13.8, max 41.9 ms | p50 4.6, p90 6.2, max 7.7 ms |
| Same, frames of 10–60 KB | | p50 5.7, p90 9.7 ms | p50 3.2, p90 4.7 ms |
| Viewer: parallel decode straight into the canvas (§7) | one full 1398 × 2034 frame, JPEG q80, on the Mac (load 75–900 from other jobs; interleaved, 3 rounds of 10) | one tile, ImageIO + CG draw: 10–18 ms | 8 bands, new path: 4.3–4.4 ms (pixels identical) |
| Viewer: one image waiting for the main thread at a time | — | a busy main thread queued every decoded frame | the newest replaces the waiting one |
| Viewer: no per-frame mipmaps | — | trilinear filter: mipmaps of every frame | bilinear unless shown at less than half size |

At the guest's present rates (7–35 fps) the stream is not the limit: the
probe received 158 of 170 guest frames in a swipe session, and a frame
costs the server 2–6 ms (8 bands on up to four threads). At 60 fps the
server needs about 5 ms per full-screen frame, well inside 16.7 ms. A
separate low-latency mode is therefore not needed; on a slow link
`--downscale 2` (a quarter of the pixels to encode, send, and decode) is the
lever. Moves stay coalesced to one per 16 ms (§5.1): finer delivery would
add guest work per frame without a faster frame clock.

End-to-end runs of the old and new viewer against the same device through
an ssh forward (3 alternating pairs) were dominated by the guest and by a
Mac load average of 400–900 from other jobs; they showed no regression and
are not used as evidence.

### 10.5 Open questions (for an observation of the reference)

1. When a frame takes longer than one period, when does the reference's
   render server start the next one: at the next 16.67 ms grid point, or a
   fixed time after `SwapSubmit` (as under Ycode, §10.2)? Observable with a
   logging framebuffer library on the Mac: the target times given to
   `SwapBegin` and the `SwapBegin`/`SwapSubmit` times of a busy animation.
2. Does the reference framebuffer server report a completion time `B`
   aligned to a 60 Hz vsync grid, and does the render server phase-lock to
   it? (Under Ycode, `B` is the completion's own time and frames do not
   wait for it.)
3. How does Simulator.app pace mouse-drag touches into the guest (every
   host event, or coalesced per display frame)?

## 11. Foldable devices (FOLD-IMPL, 2026-10-27; `foldable.md` §8, §10)

- **Hello.** Two optional keys: `foldable` (true for a foldable device type)
  and `displays` (the built-in panels' names, display 1 first, when more
  than one is published). `rotation` is true for a foldable. A viewer that
  does not know them ignores them.
- **Display state (0x07)**, JSON: `display` ("LCD", "LCD-1"),
  `pixelWidth`, `pixelHeight`, `scale` (the panel's own, native portrait),
  `rotation` (0/90/180/270: how far to turn the panel's image clockwise to
  show it as the device is held: the panel's upright turn — 90 for the
  inner panel, mounted at 270° — minus the device orientation's turn),
  `hingeAngle` (last sent), `targetAngle` (a sweep's target, or absent),
  `posture` (`closed`, `halfOpen`, `openFlat`), `orientation` (the device
  orientation's name). Sent by the send loop before the first frame and
  whenever it changes; when the panel or its turn changes, the next frame
  is a full one of that panel (frames are always in the panel's own
  pixels). The panel shown is `foldable.md` §10.1's choice, checked
  against the guest's frames (§10.4: a panel whose latest frame is black
  is not shown while the other panel's is not).
- **Fold (0x89)** moves the hinge (a sweep; one message with flag bit 0).
  **Rotate (0x88)** sets the device orientation of a foldable (1, 3, 4, 5,
  6; 2 is answered with a notice). A non-foldable device answers both with
  a notice, as before.
- **Touches** go to the panel shown, in its own points (native
  orientation): the viewer maps its turned picture back (`DisplayPanelState.
  nativePoint`). **Screenshots** (0x87) are of the panel shown, turned as
  shown.
- The viewer (§7) adds the fold bar and menu items of `foldable.md` §10.1
  for a foldable; script commands `fold closed|half|open|<deg>`,
  `rotate left|right`, `wait-display <name>`.

## 12. Stage timing and the clock (REMOTE-X86, 2026-10-31)

### 12.1 Frame timing (0x08)

With `timing: true` in the client hello, the server follows every frame with
a frame timing message: the frame's sequence, then four times on its
monotonic clock (ns; 0 = not known): **record seen** (the loop saw the
guest's frame record change; 0 for a speculative scan), **capture start**
(the scan began, after `IOSurfaceHostService.surface(id:)` waited for the
GPU work that writes the surface), **encode end**, **send end** (the frame's
last byte was handed to the socket). The viewer adds **received** (the
frame's last byte arrived), **decoded** and **presented** (after
`SDL_RenderPresent` returned, i.e. the frame was handed to the display
server; under Xvfb there is no photon to measure).

### 12.2 Clock offset

The viewer estimates server − client with pings (0x85/0x04: the pong
carries the server's monotonic ns): offset = s − (t0 + t1) / 2 of the ping
with the smallest round trip in the last 60 s; its error is at most half
that round trip (0.05–0.15 ms on the test LAN). Three pings go out at
hello, then one a second. All server times are mapped to the client clock
with it; `--measure <file.tsv>` writes every presented frame's stages
(client ns) and the input latencies at exit.

### 12.3 Input

Each input event's sequence number appears in the first frame the guest
drew after it (§4.3): the viewer reports input → first frame received and
→ presented. Input on the viewer → the guest's event is the one-way network
time (half the round trip: 0.15–0.35 ms on this LAN) plus the server's
delivery into `backboardd` (0.2 ms, §10.3).

## 13. The Linux viewer (`ycode-sim-viewer` on Linux)

An SDL 3 window (`YcodeRemoteViewerSDL`; libSDL3 opened at run time,
`$YCODE_SDL3_LIBRARY`, `$OV_SDL3_LIBRARY`, the loader's path,
`~/.local/lib`; no SDL at build time) on the portable viewer
(`YcodeRemoteViewer`), the same code the IDE embeds (`sim-link.md` §11).

### 13.1 Features

- The device in Ycode's frame (`DeviceFrameGeometry`: body, rounded screen,
  buttons), the stream image as a textured rounded polygon, turned for a
  foldable's turned panel; a control row (Home, Lock, Vol+, Vol−, Rotate,
  Shot, Mute, the scale mode) and a status line (Ctrl+F: phase, fps, KB/s,
  input → shown, round trip).
- Scale: fit (the default: the window; resizing scales the device), point
  accurate (one device point per window unit), pixel accurate (one device
  pixel per output pixel); the latter two resize the window.
- Input as on the Mac (§7): click and drag = one finger, Alt-drag = pinch
  about the centre, Alt-Shift-drag = two-finger pan, the wheel = a drag
  that ends 150 ms after the last step (a watch: the Digital Crown), the
  frame's buttons clickable; keys → HID usages (SDL scancodes are the USB
  HID usages), the Super key as the device's Command; Ctrl shortcuts stay
  with the window: Ctrl+Shift+H Home, Ctrl+L Lock, Ctrl+Up/Down volume,
  Ctrl+Left/Right rotate, Ctrl+Shift+S screenshot (the server's PNG, in
  `$YCODE_DEVICE_CAPTURE_DIR` or ~/Pictures), Ctrl+1/2/3 scale, Ctrl+B
  bezels, Ctrl+R refresh, Ctrl+M mute, Ctrl+= / Ctrl+− the viewer's volume,
  Ctrl+Q quit. Losing focus lifts fingers and keys. Alt shows the second
  finger's dot.
- Decoding on the connection thread: JPEG tiles with the system's libjpeg
  (`CYcodeCodec`, opened at run time; the header at build time) straight into
  the canvas, tiles of a frame in parallel; zlib tiles inflated; H.264 by
  NVDEC (§14). Only the changed rectangle is uploaded (`SDL_UpdateTexture`),
  video pictures as NV12 textures. The renderer presents without vsync as
  soon as a frame is decoded; one image waits at most.
- `--link <device> [--host N]` (`sim-link.md`), `--connect <address>`,
  `--scale`, `--fps` (default 120: the guest paces itself, §16.3),
  `--encoding jpeg|zlib|h264|auto`, `--bitrate`, `--quality`,
  `--downscale`, `--timing`, `--measure`, `--audio pulse|null|off`,
  `--audio-latency`, `--audio-wav`, `--script`, `--headless` (no window:
  receive and decode only), `--media tcp`.
- `--script` (`ViewerScript.swift`): the Mac viewer's language (waits, taps,
  drags, pinch, scroll, type, key, button, rotate, shots of the stream, the
  server and the window) plus `scale`, `stats-begin/end` (with the stage
  medians and the round trip), `latency-summary`, `audio-summary`, and
  `av-probe` (§15.4).

### 13.2 Checked (2026-10-31, x86 PC, Xvfb, renderer `opengles2` on llvmpipe)

The iPhone 18 Pro (iOS 27.0) streamed from the Thor: the home screen; a tap
on Settings opens it; a tap on Search, then typing, enters text; the Home
button returns home (screenshots `remote-x86-*.png` in the worktree folder).
The software renderer (`YCODE_SDL_RENDERER=software`) costs 16 ms per
presented frame against 2.6 ms for `opengles2`; it is not used.

## 14. Video (H.264 REMOTE-X86; HEVC, choice and measurements XR-QUALITY, 2026-11-02)

- **Encodings.** `hevc444` (HEVC Range Extensions, 4:4:4, 8-bit), `hevc`
  (HEVC 4:2:0, 8-bit), `h264` (4:2:0), then the tile encodings `jpeg` and
  `zlib`. Frame encoding byte: 3 `h264`, 4 `hevc`, 5 `hevc444`. Each video
  frame is one Annex B access unit in one tile covering the image, `isFull` =
  IDR, at the device's pixel size (`downscale` is ignored).
- **Encoder**: NVIDIA NVENC on the simulator host (the Jetson Thor's, through
  the driver's `libnvidia-encode.so.1` and `libcuda.so.1`, opened at run
  time; interfaces from the vendored MIT headers of FFmpeg's
  nv-codec-headers n12.2.72.0, `Sources/CYcodeVideo/nvheaders`). P1
  preset, ultra-low-latency tuning, no B-frames, one reference frame, an
  infinite GOP (IDR only on a keyframe request, the first frame, or a lost
  frame), parameter sets repeated with every IDR, input as BGRA (the encoder
  converts). No periodic IDR means no IDR spike, so intra refresh has nothing
  to replace. The damage the mirror found (§4.2) is copied into
  the encoder's input picture, which keeps the rest of the previous frame.
  NVENC's minimum size is above 64 × 64: the availability check opens a
  256 × 256 session. `YCODE_DISPLAY_VIDEO=0` keeps video out of the hello.
- **Rate control**, from the client hello: `videoQP` (> 0): constant QP;
  else `videoBitrate` with `videoFPS`: CBR, a VBV of one picture at that
  nominal rate; else VBR at `videoBitrate` (default 20 Mbit/s;
  `YCODE_DISPLAY_VIDEO_KBPS`), peak twice that, a VBV of one picture of the
  peak at `maxFPS` (what older clients get). The stream sends a picture only
  when it changes, so nothing later would refine a picture a rate limit had
  starved: a client on a LAN wants constant QP (the headset viewer's default,
  QP 20, §14.2). At 120 fps VBR's budget was about 42 KB a picture.
- **The colours are BT.709, limited range.** Measured on flat patches through
  every codec on the Thor: red → Y 63, U 102, V 240; green → 173, 42, 26; blue
  → 32, 240, 118; white → 235, 128, 128. Every conversion in Ycode assumed
  BT.601 until 2026-11-02, so saturated colours were wrong by up to 30 levels
  (PSNR on a synthetic UI, G channel: 27.7 dB before, 35.1 dB after). The
  encoder's VUI now says BT.709 (primaries, matrix) with the sRGB transfer.
- **Decoder**: NVDEC through `libnvcuvid.so.1` (the viewer's GPU), parser
  with no display delay, the picture copied to host memory: NV12, or three
  full planes for 4:4:4 (the chroma format follows the stream). A window
  shows NV12 as a texture (the renderer converts; SDL's default matrix for it
  is still BT.601: a follow-up) and converts 4:4:4 on the CPU; the headset
  viewer's re-projection uploads the planes and converts on the GPU
  (`shaders/yuv.frag`: into the sRGB colour image, then its mip chain), for
  every video encoding; 19 ms a picture on one CPU core at 2160 × 3840 before.
  CUDA–Vulkan interop would save the copy through host memory (3–7 ms):
  follow-up. There is no software decoder (no LGPL-only build of libavcodec
  was available on the test machine, and openh264 is not installed; both are
  follow-up options).
- **Licences**: nv-codec-headers MIT (each file); the NVIDIA driver's
  libraries are the user's, opened at run time, not redistributed.

### 14.1 Choosing the encoding

The server finds out what it can encode at run time: NVENC's
`nvEncGetEncodeGUIDs` for each codec, then `NV_ENC_CAPS_SUPPORT_YUV444_ENCODE`,
`NV_ENC_CAPS_SUPPORT_10BIT_ENCODE` and the maximum sizes. It lists the names in
the hello's `encodings` (`jpeg`, `zlib`, then `hevc444`, `hevc`, `h264` as
available; a client with no list gets its `encoding` or the first of these, as
before) and logs the capabilities. The client asks `cuvidGetDecoderCaps` for each
codec, chroma format and depth, and sends what it decodes, best first, in
the client hello's `encodings` (`encoding` holds the first, for older servers).
The server takes the first of the list it offers
(`DisplayCodecChoice.serverPick`).

**No fallback is silent.** A viewer that gets less than its first wish prints
which encoding it got, why each better one is missing (for example "jpeg: JPEG
is compiled out of this viewer"), what to expect of it, and that `--encoding` chooses.
A server whose encoder fails later logs it, sends the viewer a notice and
falls back to tiles with a keyframe.

| Machine | H.264 | HEVC 4:2:0 | HEVC 4:4:4 | AV1 |
|---|---|---|---|---|
| Thor, encode (up to 8192², H.264 4096²) | yes | yes, 10-bit too | yes, 10-bit too | GUID offered, 4:2:0 only; `nvEncLockBitstream` answers `INVALID_PARAM` with these headers: not offered, not measured |
| Thor, decode | yes | yes | yes | 4:2:0 |
| x86 RTX 4060 Ti, encode | yes | yes | yes | as the Thor |
| x86 RTX 4060 Ti, decode | yes (8-bit, 4:2:0) | yes | yes | 4:2:0 |

### 14.2 Measurements

2160 × 3840, the visionOS room with a Settings window, the x86 viewer offscreen
over the link (TCP), the moving `walk` script, 20 s per run, Thor load 30–60 from
other agents. Depth 1/4 on the same stream (1–2 MB/s of the rate). Seen → decoded
is the guest's frame record seen by the server → the picture decoded on the x86
(§12.1). One run each unless said; the picture rate follows the guest and the
load, not the codec.

| Encoding, rate control | Pictures/s | Rate | Encode | Send | Decode + copy | Seen → decoded p50 / p90 |
|---|---|---|---|---|---|---|
| zlib, over an ssh forward (run 7's path) | 5.7 | 59 MB/s | 82 ms | 80 ms | 18 ms | 201 / 234 ms |
| zlib | 8.7 | 88 MB/s | 89 ms | 15 ms | 18 ms | 228 / 258 ms |
| jpeg q80 | 36.1 | 20.4 MB/s | 9.6 ms | 3.5 ms | 3.6 ms | 19.9 / 25.1 ms |
| h264 QP 24 | 34.6 | 2.8 MB/s | 13.8 ms | 3.3 ms | 6.3 ms | 21.0 / 27.1 ms |
| hevc QP 24 | 23.1 | 1.9 MB/s | 11.4 ms | 3.3 ms | 3.9 ms | 16.3 / 22.6 ms |
| hevc444 QP 24 | 41.6 | 3.2 MB/s | 10.5 ms | 3.2 ms | 7.5 ms | 19.4 / 22.3 ms |
| hevc444 QP 24, again | 36.8, 44.3 | 2.9, 3.4 MB/s | 10.0 ms | 3.1 ms | 7.5 ms | 18.9 / 22.5, 18.9 / 21.8 ms |
| **hevc444 QP 20** | 35.1, 28.6 | 3.4, 2.8 MB/s | 10.3, 10.8 ms | 3.4, 3.2 ms | 7.5 ms | 19.4 / 22.8, 19.8 / 22.6 ms |
| h264 CBR 50 Mbit/s, VBV one picture at 30 | 25.7 | 5.9 MB/s | 14.9 ms | 3.5 ms | 6.6 ms | 23.8 / 33.2 ms |
| hevc CBR 50 Mbit/s | 29.1 | 11.3 MB/s | 11.0 ms | 3.9 ms | 5.5 ms | 20.8 / 23.5 ms |
| hevc444 CBR 50 Mbit/s | 52.6 | 20.3 MB/s | 11.1 ms | 3.4 ms | 8.7 ms | 24.8 / 28.9 ms |
| hevc444 QP 24, ssh forward | 34.4 | 2.7 MB/s | 10.1 ms | 3.4 ms | 7.5 ms | 21.7 / 29.1 ms |
| hevc444 QP 24, link, media by UDP | 33.4 | 2.6 MB/s | 10.3 ms | 3.3 ms | 7.6 ms | 19.6 / 25.6 ms |

Quality against the lossless (zlib) picture of the same still scene, PSNR in dB,
the whole picture and the Settings window (coloured icons and text):

| Encoding | Whole picture R / G / B | Window R / G / B |
|---|---|---|
| jpeg q80 | 40.9 / 45.1 / 40.3 | 39.2 / 41.4 / 37.5 |
| h264 QP 24 | 43.1 / 44.8 / 41.5 | 41.4 / 44.2 / 39.4 |
| hevc QP 24 | 43.5 / 45.3 / 41.8 | 42.0 / 45.4 / 39.8 |
| hevc444 QP 24 | 44.0 / 45.3 / 42.6 | 43.6 / 45.5 / 42.5 |
| **hevc444 QP 20** | 45.6 / 47.1 / 44.2 | 45.8 / 47.9 / 44.7 |
| h264 50 Mbit/s | 43.3 / 45.2 / 41.8 | 40.9 / 43.7 / 39.0 |
| hevc 50 Mbit/s | 45.1 / 47.5 / 43.3 | 43.5 / 48.3 / 40.8 |
| hevc444 50 Mbit/s | 46.0 / 47.5 / 44.5 | 46.1 / 48.4 / 44.9 |

On a synthetic UI of thin saturated lines (2160 × 3840, 8 px of motion a picture,
QP 24, encode and decode on the Thor): H.264 and HEVC 4:2:0 about 28.6 dB in R and 22.6 dB
in B, HEVC 4:4:4 37.7 and 36.3 dB, for 16 % more bytes on the IDR. On the
Settings window the dots of the "Apps" icon keep their colours with 4:4:4 and
smear together with 4:2:0.

**Recommendation: `hevc444` at QP 20, by the numbers.** The encoders differ by
about 4 ms in favour of HEVC (H.264 is the slowest of the three on this NVENC:
13.8 ms against 10–11 ms); 4:4:4 pays about 3.5 ms of decode and copy for its
three planes, so total latency is the same as H.264 and its p90 is lower
(22 against 27 ms). HEVC 4:2:0 is 3 ms faster at p50 and is the choice for a
viewer that wants the last milliseconds and has no coloured text to read. The
bit rate (3 MB/s) does not matter on this LAN; CBR's budget per picture costs
quality or rate without saving anything here, so it stays an option for slower links.

## 15. Sound (REMOTE-X86)

### 15.1 Server

`AudioHostService.deliver` (`audio-host.md` §13.4) gives the display
server each output block (512 frames, 48 kHz Float32 stereo, after the
device's volume) with its host play time. A per-viewer pipe (only when the
client hello lists codecs) queues it without blocking the audio service's
thread; its own thread cuts the audio into **5 ms packets** (240 frames;
a block that does not continue the previous one starts afresh), skips
silent packets, and encodes with **Opus** (`OPUS_APPLICATION_RESTRICTED_LOWDELAY`,
96 kbit/s, complexity 5, in-band FEC with 5 % expected loss; libopus opened at
run time) or as 16-bit PCM. Message 0x09: play time (server monotonic ns of
the first frame, the clock of §12), codec (1 PCM, 2 Opus), channels,
frames, rate, data. At most 200 ms waits in the pipe. Over the link the
packets go by UDP (`sim-link.md` §5).

### 15.2 Viewer

Packets are decoded on the connection thread (Opus; a single missing
packet before this one is recovered from this one's FEC) and placed on the
output's sample timeline at their play time on the viewer's clock (§12.2)
**plus a target delay** (`--audio-latency`, default 10 ms). The writer
thread feeds the output 5 ms at a time and knows when the next frame it
writes will play (PulseAudio's reported latency); a packet that would land
in the past moves the whole sound later by the shortfall (an adaptive delay
that only grows, at most 200 ms). Packets within 2 ms of the previous one's
end are joined to it (no clicks); clock drift beyond that re-places a
packet (a small jump; resampling is follow-up work). **Sync**: the video is
presented as soon as it is decoded; the sound keeps the device's own
timing delayed by the target, so the A/V offset is the target minus the
video's capture → presented time, and both are measured. The output is
PulseAudio's simple API (`libpulse-simple.so.0`, served by PipeWire's
pulse server), else a null output paced by the monotonic clock; `--audio-wav`
writes what goes to the speaker. Mute and volume are the viewer's own; the
device's volume buttons act on the guest.

### 15.3 Microphone

Not done: the viewer sends no input audio (`audio-host.md` input streams);
follow-up work.

### 15.4 Measured (2026-10-31, Thor → x86 over the link, UDP)

With Samples/StreamSamples AVSync (built on the x86, `sim-link.md` §10.1): `av-probe`
taps 10 times; each tap turns the screen white and starts a 1 kHz tone in
the same main-thread turn.

| What | Result |
|---|---|
| Sound − picture (beep plays here − white frame presented here) | p50 +2.9 ms, p90 +9.4 ms (one tap −41 ms: its frame came late) |
| Tap → white frame presented / → beep plays | p50 88 / 87 ms (the guest's reaction) |
| Packet arrival vs its play time | p50 10.1 ms early, latest 1.0 ms early: the device's output time is one 512-frame buffer (10.7 ms) after it writes |
| Play time on the viewer | device play time + 11.4 ms (10 ms target + 1.4 ms for PipeWire's 12–17 ms output latency) |
| Guest write → speaker | about 22 ms (10.7 + 11.4) |
| Losses | 380 packets, 0 late, 0 holes, 0 recovered (no loss on the LAN) |
| Bandwidth | Opus 96 kbit/s while sounding, nothing in silence |

Before the adaptive delay (fixed 10 ms target) 5 of 123 packets of a lock
sound under swipe load were late (the output's latency exceeded the target).

## 16. Remote viewing from x86 (REMOTE-X86, 2026-10-31)

### 16.1 Setup

The device (iPhone 18 Pro, iOS 27.0) runs on the Thor (arm64, KVM); the
viewer runs on an x86-64 Linux PC on the same subnet (ping 0.16 ms), in
Xvfb (no physical display session was available), renderer `opengles2` on
llvmpipe. Paths: **link** (`sim-link.md`: TCP 47800 for control and input,
frames by UDP 47801, or `--media tcp`), and **ssh** (`ssh -L` of the
device's display socket, the fallback). Workload: `run/bench.txt`, 8
home-screen page swipes, 2 Search taps, 2 Home presses, 15 s, `--timing`.

### 16.2 Results

seen → presented: the guest's frame record seen by the server → the frame
presented on the x86 (§12.1), p50 / p90 ms; capture → presented excludes the
wait for the guest's GPU (§16.4).

| Path, codec | seen → presented | capture → presented | capture → encoded | sent → received | decode | decoded → presented | bandwidth | round trip |
|---|---|---|---|---|---|---|---|---|
| **Before** (pacing from send end, 60 fps), ssh, JPEG | 16.8 / 40.4 | — | — | 1.6 / 23.1 | — | — | 1.6 MB/s | — |
| Before, link TCP, JPEG | 15.4 / 25.0 | — | 4.6 / 10.3 | 1.2 / 2.1 | 0.5 | 2.5 | 1.6 MB/s | — |
| Before, link UDP, JPEG | 14.6 / 22.9 | — | 2.9 / 5.9 | 1.5 / 3.8 | 0.4 | 2.6 | 2.0 MB/s | — |
| **After**, ssh, JPEG | 12.8 / 29.3 | 10.0 / 27.1 | 2.6 / 5.0 | 1.7 / 19.0 | 0.4 | 2.8 | 2.4 MB/s | 0.45 |
| After, link TCP, JPEG | 10.7 / 16.7 | 8.1 / 13.7 | 3.0 / 6.3 | 0.9 / 2.1 | 0.5 | 2.6 | 2.3 MB/s | 0.29 |
| After, link UDP, JPEG | **10.2 / 17.9** | **6.4 / 14.6** | 2.7 / 6.0 | 0.9 / 3.9 | 0.3 | 2.6 | 2.4 MB/s | 0.43 |
| After, ssh, H.264 | 14.2 / 20.9 | 11.5 / 18.8 | 4.9 / 6.6 | 0.4 / 6.0 | 3.1 | 2.7 | 0.38 MB/s | 0.70 |
| After, link TCP, H.264 | 13.3 / 16.4 | 11.3 / 13.7 | 5.0 / 7.3 | 0.4 / 0.6 | 3.2 | 2.7 | 0.32 MB/s | 0.40 |
| After, link UDP, H.264 | 14.0 / 16.8 | 11.8 / 14.0 | 5.1 / 7.1 | 0.6 / 1.0 | 3.2 | 2.8 | 0.37 MB/s | 0.53 |

"After" = pacing from capture (§16.3), viewer at 120 fps, JPEG on up to 8
threads. Input → first change presented (touch down on the home screen):
p50 29–57 ms across runs, almost all of it the guest's reaction; a tap in
an app (AVSync) → its white frame presented: p50 88 ms.

### 16.3 What changed, in order of effect

1. **Pacing from the capture** (`DisplayServer`, `YCODE_DISPLAY_PACE=send`
   restores the old rule): the interval of `maxFPS` was measured from the
   end of the previous send, so scan + encode + send (3–6 ms) were added to
   every interval and a 60 fps guest got at most about 45 fps with frames
   waiting. Now measured from the previous capture.
2. **Viewer at 120 fps**: the guest paces itself at 60 Hz (§10.2); a 60 fps
   gate only delayed frames that arrived a little early. Together with 1:
   seen → presented p50 14.6 → 10.2 ms, p90 22.9 → 17.9 ms (link, UDP).
   The stream now sends every distinct picture: consecutive captures are at
   least 16.7 ms apart (p10) during a swipe.
3. **The link instead of ssh**: ssh's forward added a long tail (sent →
   received p90 19 ms against 2–4 ms; its own buffering and the extra hop);
   the link's records add < 0.1 ms. TCP vs UDP is a wash on a clean LAN
   (UDP p50 lower, p90 higher: 70 datagrams of a full JPEG frame); UDP is
   kept for its behaviour under loss (no head-of-line blocking, a lost frame
   costs one keyframe).
4. **H.264**: 6–7× less bandwidth (0.32–0.38 MB/s against 2.3–2.4 MB/s) and
   the tightest p90, but 3–5 ms more at p50 (NVENC 5 ms for 1206 × 2622 at
   P1, NVDEC + copy to host 3.2 ms against JPEG's 2.7 + 0.3 ms). On this LAN
   JPEG tiles are the lower-latency choice; H.264 is the choice on slower
   links (Wi-Fi, VPN). The viewer's `--encoding auto` picks H.264 where it
   decodes it.
5. JPEG bands on up to 8 threads instead of 4 (`YCODE_DISPLAY_JPEG_THREADS`;
   not measured on its own). Tried and dropped: SDL's software renderer
   (16 ms per present).

### 16.4 Where the milliseconds go (link, UDP, JPEG, p50)

| Stage | ms |
|---|---|
| guest submit → record seen (inotify; §10.4) | ~0.8 |
| record seen → capture: the guest's GPU still drawing the surface (`gpuWriteWait`) | 2.4 |
| scan + JPEG encode (8 bands) | 2.7 |
| send + relay (simhost) + encrypt + network + decrypt + reassembly | 0.9 |
| decode (libjpeg, parallel tiles) | 0.3 |
| upload, draw, present (Xvfb, llvmpipe) | 2.6 |
| **total, record seen → presented** | **~10** (0.6 of a 60 Hz frame) |

The guest's own frame build (`SwapBegin` → `SwapSubmit`, §10.2: p50 13–15
ms) and its reaction to input (tens of ms) dominate everything the stream
adds. Targets: glass-to-glass within one to two guest frame times of the
guest's own reaction — met (the stream adds 6–10 ms p50, under one frame);
60 fps at native resolution — the stream's capacity is above 60 fps (JPEG
2.7 ms, H.264 5.1 ms per full frame; captures 16.7 ms apart at p10); the
guest itself presents 30–60 fps.

### 16.5 Next steps (proposals, not built)

- Present on a real GPU display (X11 or Wayland session) instead of Xvfb:
  the 2.6 ms of llvmpipe should drop below 1 ms; measure with a photodiode
  or a camera for true glass-to-glass.
- H.264: NVENC's sub-frame (slice) output and decoding into a GL texture
  (CUDA–GL interop) instead of a copy to host memory would remove about
  3 ms each side; capture the guest's Vulkan image directly (dmabuf → NVENC
  on the Thor's unified memory) to skip the mirror copy.
- Send damage-only JPEG tiles when they are smaller than an H.264 P-frame
  (small changes such as a blinking cursor) on the H.264 path.
- Sub-frame pipelining of JPEG: send each band as it is encoded.

## 17. visionOS input (VISIONOS-R9, 2026-10-31; `visionos.md` §5.5 and "Ycode implementation")

- **Negotiated.** A server for a Vision Pro says `spatial: true` (and
  `rooms`) in its hello. A viewer sends pose (0x8A), selection (0x8B) and
  dial (0x8C) only to such a server (an older server would skip them as
  unknown types, but a viewer must not rely on that for its own state).
- **Frame.** All values are in the stage frame of `visionos.md` §5.5.1
  (metres, y up, −Z forward, origin at the default eye point). The viewer
  makes them with `SpatialInteraction` (YcodeDisplayStream): the camera
  pose it keeps, the gaze ray through the pointer by the 90° horizontal
  projection, turned and placed by the camera, the hands at fixed
  camera-space rest points (±0.15, −0.35, −0.4) turned and placed the same
  way.
- **Server.** A pose goes to the HID bundle (`hid-input.md` §17, kind 10)
  and to vhmdd's `set_pose` (the same matrix); a selection to kind 11,
  coalesced to one per 16 ms while its pinch state does not change (pinch
  changes are never dropped); a dial to kind 8. The control socket's
  `vision …` commands (`visionos.md` "Ycode implementation") use the same
  `SpatialInteraction` and the same paths; a pose from a viewer becomes
  the camera the commands continue from.
- **Release.** When the viewer goes away, an open pinch is released (the
  hands open).

## 18. The headset mode (XR-VIEWER, 2026-11-01; `xr-viewer.md`)

- **Negotiated.** A visionOS server says `xr: true`; a viewer asks with the
  hello's `xr`. Then the viewer sends `views` (0x8D) every headset frame
  (latest wins) instead of the pose (0x8A); selections, dials, buttons and
  commands are unchanged.
- **The server** (`DisplayXRState`, `XREyeScheduler`) gives the guest the
  rendered camera — the head while it moves, the eyes in turn while it is
  still (adaptive) — and vhmdd the same pose (`visionos.md` §5.6.5). It
  counts pictures by content (a 64 × 36-sample signature), keeps damage
  per view, and sends a **frame view** (0x0A) just before each frame it
  tags: u64 frame sequence, u8 view (0 mono, 1 left, 2 right), u8 flags
  (bit 0 estimated), u16 latch, u32 pose sequence, the pose (3 × f32,
  4 × f32, stage frame), 4 × f32 field-of-view tangents (left, right, up,
  down), u64 guest frame. A frame without a frame view is mono and untagged.
- **The viewer** decodes each tagged frame into its view's canvas
  (`DisplayStreamClient.canvas(for:)`), so the eyes' damage applies to
  their own images.
- **Encodings**: as §14, with one NVENC session per view. With depth
  re-projection (§19) the planes are converted on the GPU; without, on the CPU
  into the upload. A frame view goes with its frame on the link's media
  channel (`sim-link.md` §5), so the pairing holds over UDP; a picture whose
  frame view was lost is skipped.
- **Foveated** (`xr.foveaFraction`): 0x8E in, and after each frame 0x0B:
  u64 frame sequence, u8 view, u8 encoding, u16 x, y, w, h, u16 full width
  and height, then the inset's JPEG (`xr-viewer.md` §4.5). Also
  `xr.eyeYawDegrees` (`xr-viewer.md` §4.6) and `xr.settleMs`. Numbers 0x0C
  (frame depth) and 0x0D (environment) are XR-DEPTH's.
- **Rates and latency** (`xr-viewer.md` §6; measured before the event clock
  fix: now up to 60 pictures/s and about 75 ms to the first change,
  `visionos.md` §10.28.1): the guest gave about 23
  pictures/s whether or not the camera changes every picture; a new pose
  shows from about 170 ms and settles about 250 ms later (the guest smooths
  its camera); the stream adds a few ms.

## 19. Depth and environment (XR-DEPTH, 2026-11-01; `xr-depth.md`)

- **Negotiated.** The server's hello says `xrDepth: true` and
  `xrEnvironment: true` (a visionOS server with the headset mode); the
  client hello's `xr.depthDownscale` (2, 4, 8) asks for each picture's
  depth, `xr.environment: true` for the room's environment now and on every
  change.
- **Frame depth (0x0C)** follows the frame (0x03) it belongs to: 16-bit
  inverse depth (q / 65535 = near / z; 0 nothing drawn) at the picture's
  size / n, lossless (row deltas, byte planes, zlib), with the frame
  sequence, the view, the projection's near and tangents, and flags (another
  frame's depth, windows merged, room only, a sample's low bit marks the
  windows layer). The GPU backend's depth tap
  captures it (`xr-depth.md` §3) and pairs it with the presented surface.
- **Environment (0x0D)**: six faces of the guest's environment cube (one
  mip level, RGBA16F), the cube's orientation when known, zlib. The faces
  are in the guest's own cube frame, which is left-handed against the
  stage (`xr-depth.md` §3.4): a viewer mirrors Z, it does not turn it.
- A viewer that gets no 0x0C for a frame shows that frame as before.

## Evidence

| Claim | Level | Source |
|---|---|---|
| The frame record (surface id, frame counter) and when it is written (§4.1) | — | Ycode source `SimGuestFrameworks/SimFramebuffer/simframebuffer.c`; `simframebuffer.md` §5.1 item 7 (frames are submitted only when content changes) |
| Surface memory reachable from the host (§4.1) | — | Ycode source `IOSurfaceService.swift` (`iosurface-remote.md`) |
| JPEG and zlib formats (§4.3, §4.4) | 1 | ITU T.81 / libjpeg-turbo API documentation; RFC 1950/1951; PNG specification (RFC 2083) |
| USB HID usages (§5.2, §5.3) | 1 | USB HID Usage Tables |
| Input path into the guest | — | `hid-input.md` (normative there) |
| Everything else (framing, message set, damage scheme, pacing, viewer) | — | Ycode design decisions |
| Foldable messages and the panel's turn (§11) | — | Ycode design decisions from `foldable.md` §2, §8 |
| Warm sessions and their timings (§6, §9) | — / 3 | Ycode design; viewer `--script` sessions on the Thor, 2026-10-19 (`snapshot.md` §12.4) |
| Pacing, record watcher, bands, viewer decode path (§4.2, §4.3, §7, §10.4) | — | Ycode design decisions; Linux inotify(7) and ImageIO/vImage public documentation (level 1) |
| Timer cadence, mach-time rate (§10.2) | 3 | `p_frameclock` under `ycode-simd --exec` on the Thor |
| Target time = SwapBegin time, 60 Hz cadence, next frame ≈ 12 ms after a long frame's submit, completions not waited for (§10.2) | 3 | Ycode boots on the Thor with `YCODE_DISPLAY_TIMING=1` (and `YCODE_FRAMEBUFFER_COMPLETION=delay-30-ab`): the swap log of our own framebuffer library, i.e. the calls the runtime's render server made into it |
| Input → photon stages and the paired before/after numbers (§10.3, §10.4) | 3 | probe sessions on the Thor (server trace, swap log, HID event log); the viewer benchmark on the Mac |
| Stage timing, clock offset, Linux viewer, video, sound and the remote x86 measurements (§12–§16) | — / 3 | Ycode design; REMOTE-X86 runs, Thor → x86 PC, 2026-10-31 |
| SDL 3 API and event layouts (§13) | 1 | SDL 3.4 public headers (zlib), as vendored by OpenViews |
| Flow control (§4.2.1) | — / 3 | Ycode design; XR-GAZE's offscreen runs, Thor → x86, 2026-11-02 (`xr-viewer.md` §13.2) |
| Depth and environment messages (§19) | — | Ycode design decisions (`xr-depth.md`; its evidence there) |
| H.264 and HEVC encode/decode interfaces, capability queries (§14) | 1 | NVIDIA Video Codec SDK headers via FFmpeg's nv-codec-headers (MIT); ITU-T H.264 and H.265 Annex B |
| NVENC's colour conversion, capabilities on the Thor and the x86, latencies and PSNR (§14) | 3 | XR-QUALITY's probes and runs on Ycode's own stream, Thor → x86, 2026-11-02 |
| Opus and PulseAudio interfaces (§15) | 1 | libopus 1.5.2 public `opus_defines.h` (BSD-3-Clause); PulseAudio simple API documentation |
| visionOS messages and their negotiation (§17) | — / 3 | Ycode design from `visionos.md` §5.5; VISIONOS-R9 runs on the Thor (`visionos.md` §10.25) |
| The headset mode, its messages and its measurements (§18) | — / 3 | Ycode design (`xr-viewer.md`); XR-VIEWER runs on the Thor and the x86 PC, 2026-11-01 |

No Apple binary, Apple source, or `research/` material was used for this
spec (level 5 not used; levels 2–4 not needed).
