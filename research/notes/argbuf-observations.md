# Argument buffers, op 29 and the visionOS room on the reference (OBS-ARGBUF, 2026-10-30)

Dirty-room observations in prose. The specs that carry the results are
`specs/simulator/metal-sim-protocol.md` §4.3 (argument buffers) and §8.3
(op 29), `specs/simulator/visionos.md` §9 Q24–Q27, and the pointer in
`specs/simulator/app-launch.md` §3.9. Raw captures stayed in
`research/dirty/argbuf/` (git-ignored).

## What was run

- Two throwaway devices, both created for this round and deleted at the
  end: `ycode-test-argbuf-ios27` (iPhone 18 Pro, iOS 27.0 24A434) and
  `ycode-test-argbuf-xr` (Apple Vision Pro, visionOS 27.0 24M362). Only one
  was booted at a time. No other simulator was touched, nothing was
  clicked, and the screen was never taken over: `simctl` (boot, spawn,
  `io screenshot`, `log stream`) only.
- Our recorder (`mslog.c`) inserted into our own probe (`argprobe.m`, run
  with `simctl spawn`), into WeatherPoster and PosterBoard for one iOS
  boot, and into backboardd for one visionOS first boot. The recorder's
  in-process test server was extended to answer ops 16 and 17 so the
  "who writes the members" question could be asked without the real host.
- A decoder for the layout description (`msargbuf.py`), written from the
  captures by comparing descriptions of layouts that differ in one thing.
- No disassembly or decompilation (level 5 not used; level 4 only for a
  name search: which runtime shader library contains a function name),
  Ghidra and the IPSW were not opened, and nothing was decrypted.

## How the layout description was worked out

The probe's layouts were built in pairs that differ in one respect: the
same three members with dense ids and with sparse ids; one buffer at id 1
and at id 1000; every inline scalar type in one struct; a nested struct
used twice; arrays of resources in the `array<>` form and as C arrays; a
pointer to a struct; descriptor-built layouts in index order and out of
it. Diffing their descriptions showed which bytes carry the id, the
offset, the kind and the access, and where the variable-length parts
(names, nested structs, pointee structs) sit. The grammar that came out
consumes every one of the 32 probe descriptions and the visionOS
home view's description to the last byte.

Three facts decided the offset question:

1. The description states each member's offset outright, and it equals
   the offset that the guest's own reflection reports and the place the
   host writes. Ids never shift anything.
2. The writes appear when op 19 returns and do not appear when the test
   server answers instead of the host, so it is the host that writes.
3. `constantDataAtIndex:` asks the host too (op 35), and the answer is the
   member's offset counted from the start of the buffer.

An earlier row of the protocol spec read op 17's reply as length then
alignment. A test-server reply with deliberately different values showed
the driver takes the first half as the alignment; the probes' replies
(`0x00180008` for a 24-byte, 8-aligned layout) agree.

## WeatherPoster

The reference's cold iOS 27.0 boot started WeatherPoster twice; both
instances drew only RenderBox pipelines and made no argument encoder, so
the encoder behind Ycode's ids 200, 201, 230 and 231 could not be
recorded in that process. Opening the runtime's VFX shader library with
the public Metal API showed that the skybox fragment function named in
Ycode's hang report has no argument buffer of its own. The offset rule
does not depend on the struct, so the fix does not need that capture.

## The visionOS room (Q24, Q26)

backboardd with the recorder from the first moment of a cold first boot
reached the room with the home view at about 22 s (screenshot at 140 s
shows the living room with all icons and names). Over the next 148 s
every room pass held all five room draws. The 768 × 432 linearized-depth
pass is there too, about twice a second, with the same four colour
targets Ycode's trace showed and two extra draws. So the room parts that
Ycode's guest leaves out are a consequence of something the host hands
back, not something the reference does as well.

The 36-index instanced depth draws arrive as op 29 with base instance 0
in the low half and, in a few hundred records, leftover bytes in the high
half: the same 0x3FF0, 0x40AE and 0x40A0 that Ycode once read as base
instances. A probe draw over leftover bytes rendered with the low half
only.

## Q27

See `visionos.md` §9 Q27 for the boots, the times and the answer.

## Costs

The whole-boot recorder in visionOS backboardd writes about 2 GB and half
a million files in three minutes (light mode); it was stopped once the
room had been up for two and a half minutes. Load from other agents
peaked at a load average of several hundred during the run; the probe
runs themselves take seconds.
