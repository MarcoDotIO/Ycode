# Contract: simulator stage 7 — a UIKit app, headless

Status: **active (2026-10-12)**, research phase 7-r. Stage 7 of
`docs/SIMULATOR-LINUX.md`: the probe app
(`research/experiments/simulator/ProbeApp`, our own code) is installed in
a Ycode device, launched, and prints its `== YCODE-PROBE BEGIN … END`
report from `application(_:didFinishLaunchingWithOptions:)`.

## 1. What is unknown (research first)

1. **App install and launch inside the guest.** On the Mac, `simctl
   install`/`launch` go through host tools (CoreSimulator and its bridge
   job). Ycode needs a path that uses only the runtime's own guest
   components plus Ycode's code: where an app bundle must live, which
   daemon registers it (installd/installcoordinationd, LaunchServices
   `lsd`), and how a launch request reaches SpringBoard/FrontBoard. A
   guest-side Ycode helper program (our own code, built against the iOS
   simulator SDK, possibly calling private interfaces by name as an interop
   client) is acceptable if the Mac's simulator shows it works.
2. **The host control channel** (`launchd-sim.md` §6.1–§6.3,
   `bootstrap-wire.md` §9): how the host registers host-side Mach names
   into the guest's `user/<uid>` domain (`launch_sim_register_endpoint` in
   `liblaunch_sim`), and the other operations (`startsession`/bind,
   `findendpoint`, `getenv`, `spawn`). This gates every host service:
   configd now, display/HID/GPU/audio in stage 8.

## 2. Research agents (phase 7-r)

| Agent | Question | Output |
|---|---|---|
| **R2** | §1 item 1 | `specs/simulator/app-install-launch.md` |
| **R3** | §1 item 2 | `specs/simulator/launch-sim-control.md` |

Rules (`CLAUDE.md` rule 4): level 1 (Apple open source, public docs, SDK
headers), level 3 (black-box runs of our own programs on this Mac's
booted iOS simulator and, for R3, our own macOS programs that load the
runtime's `liblaunch_sim.dylib` and call its exported functions against a
port our program serves, recording the messages), level 4 (exported symbol
names and load commands only). **No disassembly or decompilation**, no
`.claude/Xcode.app`, no `research/dirty/`, no Ghidra. Function signatures
that cannot be established from levels 1, 3, and 4 are reported as open,
not guessed into the spec. Our probe sources go under
`research/experiments/simulator/<name>/` (sources and build scripts only).

## 3. Implementation (phase 7-i, after 7-r)

Pinned when the research lands.
