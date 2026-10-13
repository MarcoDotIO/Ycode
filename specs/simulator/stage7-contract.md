# Contract: simulator stage 7 — a UIKit app, headless

Status: **active (2026-10-12)**, implementation phase 7-i (research 7-r done). Stage 7 of
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

## 3. Implementation (phase 7-i, pinned 2026-10-12)

Research landed: `app-install-launch.md` (R2) and `launch-sim-control.md`
(R3).

### 3.1 Exit criterion

On the Thor, `ycode-simd --device <dir> --runtime-paths --install-app
<host path of YcodeProbe.app> --launch dev.ycode.probe` (release build, no
debug flags): the probe app is installed through InstallCoordination,
launched through FrontBoardServices with debug stdio options, and its
`== YCODE-PROBE BEGIN … END` report appears in the stderr file the VMM
prints at the end. A process without a scene (the one-shot fallback,
`app-install-launch.md`) does not count, but is the first milestone.

### 3.2 Work (integrator, all of `ycode/`)

1. **Host control client** (`ycode-simd`): after the 708→808 exchange the
   host holds the control-channel send right. Implement the MIG client of
   `launch-sim-control.md`: 700 bind (with a session port the host owns;
   then write `RequireDomainBinding = true`), 701 register (host-side
   names, sent before the 808 reply hand-off so they exist before any job
   starts; none required yet), 702 find, 703 getenv, 704 spawn and 705
   waitpid (replace the `--oneshot` plist mechanism with real one-shots
   using fileports for stdio, keeping the option's behavior), 709. Never
   send other ids (`AbortOnUnknownIPC`). At exit, destroy the session
   port's receive right so `launchd_sim` shuts down cleanly.
2. **The launcher helper** `ylaunch` (our own guest program,
   `research/experiments/simulator/app-launch/` → move a minimal version to
   `ycode/SimShim/guest-tests/stage7/`, built on macOS like the probes,
   with the `com.apple.frontboard.debugapplications` entitlement in
   `__TEXT,__entitlements`): `install <bundle>` and `open <bundle id>
   --stdout P --stderr P [--arg …] [--env K=V …]`, failing loudly when the
   open completes with no process.
3. **Device-mode options:** `--install-app <host .app>` (copied into
   `DEV/data/tmp/ycode-apps/…` and installed by the helper through 704
   spawn), `--launch <bundle id>` (after install; stdio to
   `/tmp/ycode-app.{out,err}`, printed at the end), `--app-arg`,
   `--app-env`.
4. **Kernel support:** `proc_pidpath` for any pid; csops entitlement reads
   that open the target's executable (`app-install-launch.md` §
   entitlements); whatever install/launch hits next.
5. **Display services question** (`app-install-launch.md` open question 1):
   if UIKit stops before `didFinishLaunching` because
   `com.apple.backboard.display.services` is missing, report what
   headless backboardd does and propose the smallest host-side or
   guest-side answer before building it.

## 4. Findings and decisions (7-i, first test, 2026-10-12)

- **First test (level 3):** the probe app run as a plain one-shot blocks
  in UIKit's display-services startup call (MIG id 6001013 to
  `com.apple.backboard.display.services`) and never reaches
  `didFinishLaunching`. SpringBoard blocks on the same call.
- **Layer 1, fixed:** backboardd was stuck in its RunningBoard handshake
  because `task_info(TASK_AUDIT_TOKEN)` refused a task *name* port;
  `task_info` takes any task port flavor of a live task (xnu `task.defs`,
  level 1). Stage 6's "backboardd runs headless" therefore meant "hangs at
  start"; it now aborts honestly (below) and is throttled, so the stage-6
  full-boot check is expected to list backboardd until stage 7 lands.
- **Layer 2, open:** backboardd aborts with "Unable to load
  SimFramebuffer.framework" because `SIMULATOR_FRAMEBUFFER_FRAMEWORK` is
  empty. On the Mac it names CoreSimulator's
  `…/Platforms/iphoneos/Library/PrivateFrameworks/SimFramebuffer.framework`,
  a guest-platform (7) dylib supplied by CoreSimulator, not by the runtime
  (level 3 `ps -E`, level 4 load commands).
- **Decision (orchestrator):** Ycode will supply its **own clean-room,
  headless `SimFramebuffer.framework`** (and later `SimulatorHID`): one
  display of the device's configured geometry that presents nothing; stage
  8 replaces the headless back end with a real render path. Research first
  (§5).
- `--oneshot` with a host path inside DEV or RR is written with
  `RootedSimulatorPath = true` (`launchd-sim.md` §4.3).

## 5. Research R4: the SimFramebuffer client interface

Output: `specs/simulator/simframebuffer.md`. Question: what interface
(exported functions and ObjC classes, call order, arguments, results, Mach
services contacted) the runtime's display stack uses from
SimFramebuffer.framework, enough to implement a headless replacement; the
same survey for SimulatorHID.framework (interface only, for stage 8).

Allowed evidence: level 4 on CoreSimulator's frameworks under
`/Library/Developer/PrivateFrameworks` (exported symbol names, ObjC
class/selector/type-encoding names, load commands — `nm`, `otool -L/-l`,
ObjC metadata read at run time by our own program); level 3 black-box
runs: our own programs on the Mac that load the real framework and call
it, and our own **interposer** dylib that exports the same names, records
each call's register arguments and results, and forwards to the real
framework, loaded by a throwaway `launchd_sim` run started by our own
harness (as in `bootstrap-wire.md` §A.3) with
`SIMULATOR_FRAMEBUFFER_FRAMEWORK` pointing at it. **No disassembly or
decompilation** of any Apple binary; no `.claude/Xcode.app`, no
`research/dirty/`, no Ghidra. Argument meanings that runs cannot establish
are reported as open, not guessed.

## 6. Research R5: the IOSurface path (2026-10-12)

R4 (`simframebuffer.md`) found that with `com.apple.IOSurface.Remote`
unavailable, backboardd reports a {0,0} screen even with a headless
SimFramebuffer, and SpringBoard traps. Output:
`specs/simulator/iosurface-remote.md`: which guest components use the
host-side name `com.apple.IOSurface.Remote` (`launchd-sim.md` §6.3), the
message protocol on it (ids, layouts, port and OOL/memory-entry
descriptors, replies) for the calls the boot and a UIKit app make (create,
lookup by id, lock/unlock, properties, use counts, release), and the
minimum a Ycode host service must answer so that surfaces created by one
guest process can be looked up and mapped by another. Evidence: levels 1
(public IOSurface headers and docs), 3 (our own man-in-the-middle on the
Mac: a throwaway `launchd_sim` under our harness registers our own port
under the name via the control channel's 701 and forwards to the real
host service, recording both directions), 4 (symbol and class names). No
disassembly.

## 7. Progress (checkpoint 3, 2026-10-12)

- 7-i item 1 done: host control client (`LaunchSimControl.swift`,
  `DeviceSession.swift`): bind, `RequireDomainBinding = true`, real
  one-shots through 704/705 with fileport stdio, session teardown → clean
  `launchd_sim` exit 0. Full boot unchanged (118 jobs with a pid).
- 7-i items 2–3 done: `ylaunch` (`ycode/SimShim/guest-tests/stage7/`) and
  `--install-app`, `--launch`, `--app-arg`, `--app-env`, `--guest-tools`.
- The intermittent `launchd_sim` stall was a workqueue bug (events
  delivered before a vCPU was secured); fixed (`threads-and-events.md`
  addendum).
- **Blocker for install:** installd and installcoordinationd issue sandbox
  extensions (`__mac_syscall("Sandbox", 7, …)`); Ycode answers ENOPOLICY
  and the install fails ("Could not provide access to staging
  directory"). Next: specify sandbox extension issue/consume/release from
  levels 3 (our probe on the Mac calling the public-by-name
  `sandbox_extension_*` functions; our own Ycode runs) and implement a
  permissive answer. **Blocker for launch:** display services
  (SimFramebuffer §4–§5, IOSurface §6).

## 8. Progress (integrator I4, 2026-10-13): SpringBoard home screen

The home screen renders (CPU path, no Metal) on the Thor: first boot of a
new device 10 min 29 s to SpringBoard's home screen window, second boot of
the same device 3 min 29 s (migration not repeated, LaunchServices store
reused). Mechanisms and fixes: `first-boot.md` (data migration and the
LaunchServices seeding chain; guest volumes and `getfsstat64`;
getattrlist without `ATTR_CMN_ERROR`; a file mapped after it was written;
`msync`; Sandbox call 12 for cfprefsd; `accessx_np`; one clock).
`--skip-first-boot-migration` is no longer needed to reach the home screen;
`first-boot.md` §4 says what it skips. Screenshots:
`$YCODE_DATA/work/7-I4/shots/HOME-SCREEN-*.png`.
Not needed on this path: a host SCDynamicStore for configd_sim (it still
crashes; nothing on the way to the home screen waited for it).

## 9. Progress (integrator H, 2026-10-13): install reaches the placeholder

`--install-app` now gets the probe app to SpringBoard's home screen as an
installing placeholder ("Waiting…", `9-H/runs/p6a/shots/home-960s.png`)
after three fixes (`home-screen.md` §6): one guest volume for everything
but the runtime root (installcoordinationd's transfer-path volume check),
counted `ATTR_DIR_ENTRYCOUNT` (MobileInstallation's helper copied an empty
placeholder bundle), and work intervals in Ycode's `libsystem_kernel`
(SpringBoard aborted with "Failed to create work interval"). `ylaunch`
takes `YLAUNCH_INSTALL_SECONDS`; Ycode passes 1200. The install does not
leave the "Waiting" state within 18 minutes; the launch is not reached.

First milestone of §3.1 reached (2026-10-13): the probe app's executable,
run as a one-shot on a booted Ycode device (`--oneshot
"DEV/data/tmp/ycode-apps/YcodeProbe.app/YcodeProbe"`, delay 230 s), prints
its complete `== YCODE-PROBE BEGIN … END` report from
`application(_:didFinishLaunchingWithOptions:)` (`9-H/runs/p9a`,
`devs/p9/data/tmp/ycode-oneshot-1.err`): UIKit's display-services and
render-server start-up works under Ycode. The installed-and-launched exit
is still open (install stays "Waiting").
