# Spec: the display stream (live view and input for a remote viewer)

Status: **implemented** (agent SIM-VIEWER, 2026-10-19). Ycode-original
design: nothing here describes Apple software. It defines how `ycode-simd`
serves a device's display and takes input over one socket, and how the
viewer (`ycode-sim-viewer`, macOS) uses it. How input then enters the guest
is `hid-input.md`.

Code: `Sources/YcodeDisplayStream` (protocol and sockets, shared),
`Sources/CYcodeCodec` (JPEG, zlib, downscale), `Sources/ycode-simd/
DisplayServer.swift`, `DisplayTiles.swift`, `InputBridge.swift`,
`Sources/ycode-sim-viewer`, `scripts/ycode-sim-serve`, `scripts/ycode-sim-try`;
timing instruments in §10.

## 1. Transport

- `ycode-simd --device … --display-server <address>` listens on a
  **Unix-domain socket** (`unix:<path>`, mode 0600) or **TCP**
  (`<host>:<port>`, `<port>` = 127.0.0.1). The launcher uses a Unix socket
  on the simulator host and forwards it with `ssh -L <local port>:<socket>`:
  no port is opened on a shared host, and ssh supplies authentication and
  encryption. The protocol itself has no authentication: never listen on a
  non-loopback TCP address.
- A stale socket file (nobody accepting) is replaced; a live one is an error.
- **One viewer at a time.** A new connection closes the previous one (it
  gets a notice first), so a viewer can reconnect after a network drop.
- Without `--display-server` nothing of this exists. With it, before a
  viewer connects, one thread waits in `accept()`; no frame work is done.

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
| 0x81 | client hello | JSON (§3.2) |
| 0x82 | touch | §5.1 |
| 0x83 | key | §5.2 |
| 0x84 | button | §5.3 |
| 0x85 | ping | u64 token |
| 0x86 | keyframe request | empty: the next frame covers the whole image |
| 0x87 | screenshot request | u32 token |
| 0x88 | rotate | u8 orientation (1 portrait, 2 upside down, 3 landscape left, 4 landscape right) |

## 3. Control messages

### 3.1 Server hello (sent first, on connect)

JSON object: `protocol` = `"ycode-display/1"`, `deviceName`, `model`,
`pixelWidth`, `pixelHeight`, `scale`, `pointWidth`, `pointHeight`
(pixels / scale; the touch coordinate space), `orientation` (`"portrait"`),
`encodings` (the frame encodings this server can produce, from
`["jpeg", "zlib"]`), `touch`, `keyboard` (booleans: whether input is
wired to the guest), `buttons` (names from §5.3), `rotation` (false today:
rotation is not implemented, the viewer disables it).

### 3.2 Client hello

JSON: `protocol`, `client` (a name for logs), `maxFPS` (1–120), `encoding`
(`"jpeg"` or `"zlib"`), `quality` (JPEG, 1–100), `downscale` (1–4: the
stream image is ⌈pixel size / downscale⌉ per axis). The server clamps the
numbers, falls back to an encoding it has, and starts with a full frame.
The client may send another hello at any time to change settings. Until a
client hello arrives (at most 2 s) the server sends nothing but hello and
status.

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
request) is scanned as soon as the last sent frame is one interval old; the
speculative scans (settling, after input, the safety net) run at most once
per interval and never hold back the scan of a new frame. (Before
2026-10-19 every scan counted against the interval, so a settling scan that
found nothing delayed the next real frame by up to 16 ms; §10.4.) The
server learns of a new record from inotify on the record's directory (the
guest's write reaches the host file), with the 4–8 ms poll as the fallback.
Sends are blocking: on a slow link the next scan simply waits, and because
damage is computed against what the viewer has, the newest pixels always
win and no frame queue builds up.

### 4.3 Frame message (0x03)

| Bytes | Field |
|---|---|
| 8 | sequence (frames sent on this connection) |
| 8 | guest frame (the record's counter) |
| 8 | server monotonic ns when the frame was encoded |
| 4 | input sequence: the newest input event (§5) received before the scan |
| 2, 2 | stream image width, height |
| 1 | encoding: 1 JPEG, 2 zlib |
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
edge at began), and coalesces move-only messages to one per 16 ms.

### 5.2 Key (0x83)

u32 sequence, u8 down (1) / up (0), u8 0, u16 usage page (7), u16 usage
(USB HID keyboard usages; modifiers are keys 0xE0–0xE7).

### 5.3 Button (0x84)

u32 sequence, u8 button (1 home, 2 lock, 3 volume up, 4 volume down,
5 side), u8 down. The bridge sends consumer-page usages (`hid-input.md`
§5.5).

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
| `YCODE_FRAMEBUFFER_COMPLETION=delay-<ms>[-ab]` | the framebuffer library calls swap completion blocks that much later (with `-ab`, only in odd seconds of mach time); a diagnostic for §10.3 |
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

## Evidence

| Claim | Level | Source |
|---|---|---|
| The frame record (surface id, frame counter) and when it is written (§4.1) | — | Ycode source `SimGuestFrameworks/SimFramebuffer/simframebuffer.c`; `simframebuffer.md` §5.1 item 7 (frames are submitted only when content changes) |
| Surface memory reachable from the host (§4.1) | — | Ycode source `IOSurfaceService.swift` (`iosurface-remote.md`) |
| JPEG and zlib formats (§4.3, §4.4) | 1 | ITU T.81 / libjpeg-turbo API documentation; RFC 1950/1951; PNG specification (RFC 2083) |
| USB HID usages (§5.2, §5.3) | 1 | USB HID Usage Tables |
| Input path into the guest | — | `hid-input.md` (normative there) |
| Everything else (framing, message set, damage scheme, pacing, viewer) | — | Ycode design decisions |
| Warm sessions and their timings (§6, §9) | — / 3 | Ycode design; viewer `--script` sessions on the Thor, 2026-10-19 (`snapshot.md` §12.4) |
| Pacing, record watcher, bands, viewer decode path (§4.2, §4.3, §7, §10.4) | — | Ycode design decisions; Linux inotify(7) and ImageIO/vImage public documentation (level 1) |
| Timer cadence, mach-time rate (§10.2) | 3 | `p_frameclock` under `ycode-simd --exec` on the Thor |
| Target time = SwapBegin time, 60 Hz cadence, next frame ≈ 12 ms after a long frame's submit, completions not waited for (§10.2) | 3 | Ycode boots on the Thor with `YCODE_DISPLAY_TIMING=1` (and `YCODE_FRAMEBUFFER_COMPLETION=delay-30-ab`): the swap log of our own framebuffer library, i.e. the calls the runtime's render server made into it |
| Input → photon stages and the paired before/after numbers (§10.3, §10.4) | 3 | probe sessions on the Thor (server trace, swap log, HID event log); the viewer benchmark on the Mac |

No Apple binary, Apple source, or `research/` material was used for this
spec (level 5 not used; levels 2–4 not needed).
