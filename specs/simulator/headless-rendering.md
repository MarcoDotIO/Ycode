# Spec: headless rendering and frame capture without Metal

Status: **reference** for stage 7 and stage 8 (agent R6). It answers one
question: when the host offers no Metal service, does the render server of
the iOS 27.1 runtime (24A94401) still put real pixels into the swapchain
surfaces that the framebuffer library receives? It then gives the method
Ycode can use to save the current frame as an image, and the behavior that
Ycode's SimFramebuffer replacement (`simframebuffer.md`) and IOSurface host
service (`iosurface-remote.md`) must have so that the saved frames are
valid.

Every fact comes from black-box runs of our own programs on this Mac's
simulator (level 3). Some facts also use public documentation (level 1),
and the names of functions in a stack sample, of environment variables,
and of loaded images (level 4). No Apple binary was disassembled or
decompiled, and no instruction bytes were read. Our programs are in
`research/experiments/simulator/render-check/` (Appendix A).

Terms:

- **Render server**: QuartzCore's window server in `backboardd`. Its
  framebuffer connection is named `CAWindowServer` (`simframebuffer.md` §5.1).
- **Display buffers**: the IOSurfaces of the built-in display that the
  render server creates and passes to `SFBSwapchainSwapAddSurface`
  (`iosurface-remote.md` §1.2). Each one has the name `LCD`.
- **Frame**: one swap: `SwapBegin`, `SwapAddSurface`, `SwapSetCallback`,
  `SwapSubmit` (`simframebuffer.md` §5.1 step 7).
- **Headless boot**: a boot of a throwaway iPhone Duo device that has the
  capture framebuffer library (`sfbcapture.c`, R4's headless library plus
  capture) and has every `com.apple.metal.simulator*` name and
  `com.apple.gputools.service.simulator` denied in every process. The
  real IOSurface service is used unless a section names our test service.
- **Service boot**: a headless boot in which `backboardd` and SpringBoard
  are restarted against our IOSurface test service (`isdump.c`, which is R5's
  test server plus a dump facility), as in `iosurface-remote.md` §7.2.
- **Reference boot**: a normal CoreSimulator boot of the same device, with
  nothing of ours in it.

## 1. Answer

**Yes.** Without Metal host services, the render server draws real
pixels into the display buffers and submits them. Ycode can take a
screenshot by saving the last submitted surface.

1. **No Metal device.** With the Metal names absent, a guest process gets
   no Metal device: `MTLCreateSystemDefaultDevice` returns nil and
   `MTLCopyAllDevices` returns 0 devices. In a reference boot they return
   one device, "Apple iOS simulator GPU".
2. **CPU renderer.** The render server then draws with its CPU
   rasterizer. A stack sample of `backboardd` while it draws shows frames
   under `CA::WindowServer::SimServer` and `CA::WindowServer::SimDisplay`
   that are in `CA::OGL::SWContext` and `CA::OGL::SW::*` (scan conversion,
   texture sampling). The same sample in a reference boot shows
   `CA::OGL::MetalContext`, with no `SW` frames. QuartzCore logs nothing
   when it selects the CPU renderer.
3. **Trigger.** The only trigger is that no Metal device exists. No
   environment variable or default had to be set. `backboardd`'s QuartzCore
   read 405 distinct `CA_*` environment variables. All of them were unset
   in both kinds of boot, and no name suggests a choice of renderer.
4. **Pixels.** The pixels are correct for UIKit content. All three
   captures came from the frames that `backboardd` submitted (Appendix B):

   | Screen | Result |
   |---|---|
   | SpringBoard home screen | Status bar, app icons (Settings, Safari), search button and page dots are drawn. The wallpaper is **black** (item 5). |
   | Settings, after `simctl launch com.apple.Preferences` | The complete Settings list. The background colour (245, 245, 249) is the same as in the reference screenshot. The row icons are **grey placeholders** (item 5). |
   | Our probe app (`ProbeApp`, `systemTeal` root view) | A teal screen (0, 195, 208), the same value as the reference screenshot. Less than 0.4 % of the pixels differ, at the status bar and the item 6 disc. |

5. **What needs Metal in other processes.** Some content comes from other
   processes, and those processes need Metal themselves:
   - **Wallpaper.** The poster extensions (PosterBoard) draw with Metal.
     SpringBoard logs "Poster scene is not ready". `AegirPoster` traps in
     a Metal quad class of NanoUniverse. The wallpaper stays black.
   - **Icons.** `iconservicesagent` renders symbol-based icons through
     CoreImage. CoreImage logs "No Metal renderer available" and
     "No supported back-end renderer is usable". `iconservicesagent` then
     traps in CoreUI's icon-stack code: 24 crash reports in the headless
     boots and none in the reference boot. Settings shows placeholder
     icons.

   These are not render-server failures. A Metal device for guest
   processes (the stage 8a track, `metal-shaders.md`) is the smallest path
   to full fidelity. A first screenshot does not need it.
6. **Differences from the reference that are not explained.** App screens
   show a black disc of about 100 px at the top right, near (1252, 142) of
   1398 × 2034, under the status-bar clock. The reference screenshot does
   not have it (§7 item 2).
7. **Cost.** In `backboardd`, Metal tries again to reach the host driver.
   One first boot of about 3.5 minutes had 8469 loads of `MTLSimDriver`
   from Metal and 8469 XPC connection attempts to
   `com.apple.metal.simulator`. One look-up of
   `com.apple.metal.simulator.backboardd` was also denied. R4 saw the same
   thing (`simframebuffer.md` §7 item 11). Ycode's answer to these
   look-ups must be cheap.

## 2. What the render server does per frame (observed)

1. **Buffers.** The render server creates three display buffers per
   built-in display at the start of the window server. Each one is
   W × H of the display mode, `'BGRA'`, with bytes per row = W × 4 rounded
   up to 128 (1398 × 2034: 5632 bytes per row, allocation 11 468 800). It
   uses them **strictly round-robin** (A, B, C, A, …) in every run. This
   includes runs where swaps were never completed.
2. **One surface per swap.** `SwapAddSurface` is called once per frame,
   with source and destination rects (0, 0, W, H).
3. **Order on the IOSurface service, per frame, for the surface being
   drawn** (relay capture of `backboardd`):
   1. Method 4 lock with options 0 (a write lock, which increments the
      seed);
   2. drawing;
   3. Method 5 unlock with options 0;
   4. Method 4/5 with options 1 (a read-only lock and unlock);
   5. Method 11, which removes the value `FVDSurfaceRectOfInterest`;
   6. `SFBSwapchainSwapSubmit` (located by our library's own lock, made
      inside `Submit`, which comes at this point in the stream);
   7. Method 17 (`IsInUse`).

   The next frame begins on the next buffer.
4. **The frame is complete at Submit.** The write lock is released before
   `SwapSubmit`. Every captured surface held a complete screen, not only
   the changed region.
5. **Seeds.** The seed of a display buffer increases by exactly one for
   each frame drawn into it (the write lock). For example, buffer seeds
   are 1, 1, 1, 2, 2, 2, … over the first frames.
6. **Frames only on change.** About 220–260 frames come in the first
   10 s after `backboardd` restarts: the boot logo overlay (the first frames
   have about 1 % non-black pixels), the spinner, then the home screen.
   After that, frames come only when content changes. An idle screen gives
   no frames for minutes. Our TickApp changes its content 5 times a second
   and gives 60–90 frames per 10 s.
7. **Time to draw.** Write-lock spans on this Mac (Apple silicon, times
   including our relay's overhead) were: median 1.1 ms, 90th percentile
   11–25 ms, maximum 255 ms (app launch transitions). The CPU renderer
   cost grows with the changed area. Thor numbers are open (§7 item 4).

## 3. Frame capture (the format Ycode needs)

### 3.1 Which surface, and when

- **The current frame** is the IOSurface that was passed to
  `SFBSwapchainSwapAddSurface` in the **most recent swap that was then
  submitted** with `SFBSwapchainSwapSubmit`, on the swapchain of the
  built-in display (type 0, display 1). A swap that was begun but not
  submitted does not count.
- **At Submit**, Ycode's framebuffer library records:
  - a sequence number;
  - the surface ID: `IOSurfaceGetID` of the `SwapAddSurface` argument. It
    is a public call that the client answers from its cached state,
    without a request to the service;
  - the target time that `SwapBegin` received;
  - the submit time.

  The library sends this record to the host, by Ycode's own channel.
- **The pixels are in the host service's memory for that ID.** In a
  service boot, a read of the surface through `backboardd`'s mapping and
  a read of the test service's own memory for the same ID were
  **byte-identical** for the home screen, Settings and the probe app. The
  host does not need to copy anything out of the guest.
- **Idle.** No new submit means that the last frame is still current. A
  capture taken 20 s after the last submit was correct. The surface is not
  written again until the render server has drawn into the other two
  buffers (§2 item 1).

### 3.2 Tear-free copy

The render server write-locks a buffer again only after two further frames
(round-robin of three). A copy can still overlap with that write. Two
rules both work:

1. Copy synchronously in `SwapSubmit`, before the call returns. The
   render server is then waiting.
2. Copy on the host, and use the seed: read the surface's seed in the
   service, copy, then read the seed again. If the seed changed (a write
   lock happened, §2 item 5), discard the copy and use the newer current
   frame.

A copy that the host takes some time after Submit will often not show the
frame that was submitted. In our runs, with content changing 5 times a
second, a service dump taken less than a second after the framebuffer read
of the same ID had different bytes, because the buffer had been drawn
again. Rule 2 detects this case.

### 3.3 Pixel layout and conversion

| Property | Value |
|---|---|
| Size | width × height of the display mode (`SIMULATOR_MAINSCREEN_WIDTH/HEIGHT`; 1398 × 2034 here) |
| Row pitch | bytes per row of the surface (SurfaceState offset 20); 5632 here. Bytes after width × 4 in a row are padding |
| Pixel | 4 bytes, memory order **B, G, R, A** (`'BGRA'`, `0x42475241`) |
| Alpha | 255 in every rendered pixel; the buffer is opaque. A buffer that was never drawn stays zero (alpha 0) |
| Colour | 8-bit sRGB. The display buffers carry the attachments colour primaries 1 and transfer function 13 (`iosurface-remote.md` §1.2). Flat colours match the reference PNG exactly, and that PNG is tagged "sRGB IEC61966-2.1" |

To PNG: for each row, take width × 4 bytes, write R = byte 2, G = byte 1,
B = byte 0, drop alpha, and add an `sRGB` chunk (`raw2png.py`).

### 3.4 Reference screenshots (for comparison)

On the iPhone Duo device type, `xcrun simctl io <dev> screenshot` without
`--display` saves the **other** built-in display (2007 × 2853, `LCD-1`).
For the display that the headless library offers, pass
`--display=<UUID>` of the 1398 × 2034 port that `simctl io <dev>
enumerate` lists. The result is an RGBA PNG tagged sRGB.

## 4. Requirements on Ycode's IOSurface service and framebuffer library

Results of service boots with one change each. The check is the TickApp
liveness test: frames in 10 s, and two captures 3 s apart whose counters
must differ. Each variant restarts `backboardd` and SpringBoard.

| Variant | Frames per 10 s | Pixels |
|---|---|---|
| test service, everything answered (three runs) | 72, 90, 60 | correct, counter advancing |
| Methods 4 **and** 5 refused (lock/unlock fail) | 90 | **all zero (black, alpha 0)**, in every frame |
| Method 5 refused (unlock fails) | 60 | correct |
| `SurfaceState` omitted from replies of Methods 3–21 (client seeds stay 0) | 60 | correct |
| seed never incremented (`SurfaceState` still sent) | 61 | correct |
| Method 17 (`IsInUse`) refused | 90 | correct |
| swaps **never completed** (no callback) | 88; in a second run 60 in each of 12 windows (2 min) | correct, also after 2 min |
| every completion delayed by 100 ms | 60 | correct |

Requirements:

1. **Lock must succeed.** Method 4 must succeed, with options 0 and 1, for
   the display buffers. If it fails, the render server still submits
   frames, but it draws nothing into them. Unlock failure is tolerated, but
   Ycode should answer it correctly (`iosurface-remote.md` §8 item 10).
2. **Shared memory.** The memory that the service hands out (Method 2
   `MemoryObject`) must be the memory that the host reads. Writes made
   through the guest mapping must be visible to the host without a copy
   (`iosurface-remote.md` §6; §3.1 above).
3. **No Metal names** (`iosurface-remote.md` §8 design note). If a Metal
   device exists, the render server uses its Metal path and needs a Metal
   service that understands Ycode's surfaces.
4. **Seed.** The seed is not needed for drawing. Ycode's tear check
   (§3.2) needs the R5 rule: a lock without the read-only bit increments
   the seed (`iosurface-remote.md` §3.1). It also needs the seed to be
   readable on the host by surface ID.
5. **Swap completions** are not needed for drawing or presenting: 2
   minutes without any completion were normal, and so were 100 ms delays.
   Ycode should still call each completion block once, with the target
   time and the completion time (`simframebuffer.md` §7 item 7). The real
   server does this, and other clients of the completion (frame pacing)
   were not tested.
6. **Report each submit.** The framebuffer library must give the host
   the ID of each submitted surface (§3.1). This is the only addition to
   R4's headless behavior that capture needs. The library may keep a
   reference (`CFRetain`) to the last submitted surface until the next
   submit. Our prototype does this, and the display buffers were never
   released during a run.
7. **`IsInUse` and use counts** do not affect drawing (variant above). A
   library that does not change use counts is sufficient.
8. **Nothing else of the capture is in the guest.** Our prototype's
   read-only locks and reads in `backboardd` were harmless. Ycode reads
   on the host and needs no guest call.

## 5. Recipe for the first Ycode screenshot

1. Offer no Metal names, and answer their look-ups fast (§1 item 7).
2. Run Ycode's IOSurface host service with requirements 1, 2 and 4 of §4.
3. In Ycode's SimFramebuffer library, at `SFBSwapchainSwapSubmit`, send
   `(sequence, IOSurfaceGetID(surface), target time)` to the host. Then
   complete the swap as R4 describes.
4. On a screenshot request, take the surface ID of the last record. Look
   it up in the service. Copy height rows of bytes-per-row bytes, with the
   seed check of §3.2, and convert as in §3.3.

Expected result on the home screen: a black wallpaper with drawn icons and
a drawn status bar. UIKit apps without Metal content draw in full.

## 6. Method notes and pitfalls

- **Use a continuously changing app to check liveness.** In our first
  service-boot variants we launched Settings and the probe app after a
  restart of `backboardd` and SpringBoard. Their launches were sometimes
  slow or hung for minutes. This happened in a control run too. The
  captures were then stale for reasons that had nothing to do with the
  variant. Those runs are not used in §4. The TickApp measure is not
  affected.
- `simctl spawn` processes in a device booted with `SIMCTL_CHILD_`
  variables inherit those variables. That includes the deny list, so the
  "Metal present" check had to be made in a reference boot.
- A `getenv` interposer inserted into every job must not use
  thread-local storage. `libmalloc` calls `getenv` before libSystem has
  set up thread-local storage, so `launchd_sim` aborted once in
  `_tlv_bootstrap_error`. Our first build did this, and it was fixed.
- In a service boot, processes that were not restarted (poster
  extensions, widget renderer) keep using the real IOSurface service.
  `backboardd` looks up their surfaces in ours. IDs from two services can
  name different surfaces. This may explain the transient pattern in §7
  item 3, which a single-service Ycode would not have.

## 7. Open questions

1. **Metal-only content.** The wallpaper (poster extensions) and the
   CoreImage icon renderer of `iconservicesagent` need a Metal device.
   Open questions:
   - whether either one has a CPU path that a documented switch can
     select (CoreImage's public `kCIContextUseSoftwareRenderer` was not
     tried);
   - whether the crashes of `iconservicesagent` cost anything beyond
     placeholder icons.
2. **The black disc** at the top right of app screens (§1 item 6). It
   could be the sensor region that SpringBoard draws when the framebuffer
   library reports no mask path (`SFBDisplayGetMaskPath` returns NULL in
   the headless library; CoreSimulator gives a PDF mask), but this is not
   tested.
3. **A transient striped pill.** One service-boot capture of the probe
   app, taken 8 s after launch, shows a status-bar pill filled with
   purple/blue horizontal noise. A later capture of the same app does not
   show it. The cause is not known; see the §6 note on two services.
4. **Cost on the Thor.** The CPU renderer runs in `backboardd`. Frame
   times for full-screen transitions on the Thor's cores are not known.
5. **The second built-in display** of the iPhone Duo is not offered by the
   headless library. Device types with one display were not available for
   the 27.1 runtime on this Mac.
6. **Frame pacing.** Whether the render server adapts its frame rate to
   completion times (completions delayed by 100 ms gave the same rate as
   the control), and how the real server's blocking `Submit` (up to
   0.1 s) interacts with it.
7. **The meaning of the value `FVDSurfaceRectOfInterest`**, which the
   render server removes from every display buffer each frame. Only its
   name is known.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Pixels are non-blank and correct on home, Settings, probe (§1 item 4) | 3 | `sfbcapture.c` dumps in headless boots (real IOSurface service) and service boots; `raw2png.py`; `pngdiff.py` against reference screenshots |
| No Metal device without the names; one device in a reference boot (§1 item 1) | 3 | `mtlprobe.m` run with `simctl spawn` in both kinds of boot |
| CPU renderer vs Metal renderer (§1 item 2) | 4 | function **names** in `sample` output of `backboardd` (black-box tool output; no code or instruction bytes read), headless and reference boots |
| No switch needed; environment variables read (§1 item 3) | 3 + 4 | `rcenv.c` `getenv` interposer in `backboardd`: variable names and whether set |
| No fallback log line; CoreImage and PosterKit messages (§1 items 2, 5) | 3 | `log show` of the headless and reference boots |
| Crashes of `iconservicesagent`, `AegirPoster` (§1 item 5) | 3 | crash reports (frame names, black-box output), counted per boot window |
| Metal retry counts (§1 item 7) | 3 | `rcenv.c` `dlopen` and look-up/XPC deny counters |
| Buffers, round-robin, one surface per swap, seeds per frame (§2) | 3 | `frames.log` of `sfbcapture.c` (public IOSurface getters) in every run |
| Per-frame request order, lock options, `FVDSurfaceRectOfInterest`, lock spans (§2 items 3, 7) | 3 | R5's relay (`isinterpose.c`) captures of `backboardd` in service boots |
| Frame complete at Submit; idle validity (§2 item 4, §3.1) | 3 | order of our library's lock in the relay stream; dumps taken 20 s after the last frame |
| Guest mapping and service memory identical (§3.1) | 3 | `isdump.c` dump by surface ID vs `sfbcapture.c` dump: `cmp` equal, three screens |
| Layout, alpha, sRGB (§3.3) | 1 + 3 | public `IOSurfaceRef.h` getters; dumps; reference PNG profile (`sips`); attachments from `iosurface-remote.md` §1.2 |
| `simctl io screenshot --display` behavior (§3.4) | 3 | `simctl io enumerate` and screenshots |
| Requirements and variants (§4) | 3 | `run-server.sh` variants with `isserver_r6.h` switches and `sfbcapture.c` opts; TickApp captures |
| Recipe (§5) | — | Ycode design from §1–§4 |

No disassembly or decompilation was used (level 5 was not used). No
`.claude/Xcode.app`, `research/dirty/` or Ghidra project was opened. No
executable memory was read. Pixel reads were only of IOSurface memory
(display buffers). Crash reports, log lines and stack samples were read as
black-box output, for names only.

## Appendix A. Programs and method

Sources (ours) are in `research/experiments/simulator/render-check/`.
`build.sh <out>` builds them for `arm64-apple-ios27.0-simulator` into a
directory outside the repository.

| File | What it is |
|---|---|
| `sfbcapture.c` | R4's headless framebuffer library plus capture: `frames.log` (one line per submit: surface ID, size, bytes per row, format, seed, sampled pixel summary) and on-request dumps of the last submitted surface (`<dir>/snap` → `<name>.raw` + `<name>.txt`). Switches: `SFBH_NO_CALLBACK`, `SFBC_DELAY_CB`, `SFBC_NO_LOCK`, `SFBC_STATS`, and an `opts` file for restarted processes |
| `rcenv.c` | `DYLD_INSERT_LIBRARIES` logger of `getenv` (name, caller image, set or unset) and `dlopen`, with a look-up/XPC deny list |
| `isdump.c`, `isserver_r6.h` | R5's test IOSurface server as a launchd job, plus dump by surface ID and a surface list. `isserver_r6.h` is R5's `isserver.h` plus the switch `YC_SRV_FREEZESEED` |
| `mtlprobe.m` | `MTLCreateSystemDefaultDevice` / `MTLCopyAllDevices` probe |
| `TickApp/` | a UIKit app whose content changes 5 times a second (liveness) |
| `raw2png.py`, `pngdiff.py` | dump → PNG (standard library only); PNG comparison |
| `run-headless.sh` | headless boot: home, Settings, probe, TickApp captures |
| `run-reference.sh` | reference boot: `simctl io screenshot`, Metal probe, stack sample |
| `run-server.sh` | service boot and per-variant restarts (`RC_REFUSE`, `RC_NOSTATE`, `RC_FREEZESEED`, `RC_SFBOPTS`, `RC_MODE=tick`) |

Method: one throwaway iPhone Duo device on the 27.1 runtime, created and
deleted by this agent. The order of runs was:
1. two headless boots (the first one a first boot);
2. one reference boot;
3. one service boot with 20 variant restarts (the first 9 used the
   unreliable app-launch check, §6).

The probe app is `research/experiments/simulator/ProbeApp`, unmodified.
Raw dumps, logs and PNGs stayed in the agent's scratch directory.

## Appendix B. Captures

The PNGs from these runs are in the session scratch directory
(`agent-R6/final/`). They are not part of the repository:

- `headless-home.png`, `headless-settings.png`, `headless-probe.png`:
  headless boot, framebuffer-side capture, real IOSurface service.
- `service-home.png`, `service-settings.png`, `service-tick1.png`:
  host-service-side capture by surface ID.
- `service-probe-transient-pill.png`: the §7 item 3 pattern.
- `nocompletion-tick-after-2min.png`, `lockrefused-black.png`: §4
  variants.
- `reference-home.png`, `reference-settings.png`, `reference-probe.png`:
  CoreSimulator reference screenshots of the same display.
