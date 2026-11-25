# B5-DEVICES: Device Hub and ycrun together (1.0.0-beta.5)

B5-DEVICES finished the two stopped beta 5 workstreams, B5-DEVICEHUB
(`docs/beta5/devicehub.md`) and B5-YCRUN (`docs/beta5/ycrun.md`, spec
`specs/ide/ycrun.md`), and brought them onto one branch, `b5-devicehub`.
Clean room: only `specs/`, `docs/`, Ycode's own code and the public
`xcrun simctl help` text were read. Apple's Xcode, Simulator and Device Hub
were not run or watched, and no Apple simulator was booted.

## What changed

- **Both branches follow 1.0.0-beta.4** (`ee51387d`). The one conflict was
  ShellDriver's list of walks, which keeps `YCODE_IDE_B4POLISH` and
  `YCODE_IDE_DEVICEHUB`.
- **The stopped agents' leftovers.** The Linux hub samples its picture again
  after a turn that arrives after the last frame (`DeviceHubScreen`).
  `DeviceHubLiveMacTests` now compiles (it was left uncompiled). Setting a
  host up again with ycrun keeps the devices made on it.
- **One branch.** `b5-ycrun` is merged into `b5-devicehub`.
- **The pid files in one place.** `YcrunDeviceFiles` (YcodeSimControl) names
  `<data>/ycrun/<device>.pid` and `.log`, says which devices ycrun booted,
  and holds ycrun's stop (SIGTERM, the grace, then the session killed).
  `ycrun simctl shutdown` and both hubs use it.
- **macOS hub: devices ycrun booted.** While the hub shows, it asks the host
  every 4 seconds which pid files name a live launcher
  (`DevicesController+Ycrun.swift`). Such a device is listed as Booted, its
  live screen shows (the same display socket a hub start serves), and Shut
  Down sends ycrun's SIGTERM. A host that does not answer keeps the last
  answer. This works in the hub with and without a workspace.
- **Linux hub: ycrun's hosts and settings.** `DeviceHubSimHostBackend` lists
  the hosts ycrun knows: the IDE's host in the `ycode-ide` defaults domain
  (what `ycrun remote setup` writes, and what the Linux IDE's Settings ▸
  Components ▸ Simulator Host shows), ycrun's other hosts in `hosts.json`,
  and this machine. Start boots the way `ycrun simctl boot` does (detached,
  with the pid file), so ycrun sees the device and can stop it. Shut Down is
  ycrun's SIGTERM. The live screen comes over an ssh forward of the display
  socket (keys only), held while the canvas shows it. The hub's default
  backend is `DeviceHubAllHostsBackend`: the link's paired hosts, then
  ycrun's. A ycrun host whose name a paired host already uses is listed as
  "<name> (ssh)".
- **Shared placement.** The Linux hub lists this machine only where
  `SimPlacementPolicy.localSupport` says devices run here (arm64 Linux with a
  usable `/dev/kvm`; a Mac once `macOSRunsLocally` turns true). The hub
  keeps no placement rule of its own.
- **`ycrun remote setup --link` and `ycrun remote link <name>`** (the run
  destination candidate). Over the setup's own ssh, ycrun starts the host's
  simulator service when nothing serves its port. Then the two sides
  exchange pairing files: the host's identity is trusted here, and this
  computer's identity is trusted there. The host becomes a host of Ycode's
  link, so the Linux IDE lists its devices as run destinations and its hub
  shows them. A setup with its own `--config-dir` keeps the host's link
  identity in `<config>/sim-link`. Spec: `specs/ide/ycrun.md` §8.3.
- **PARITY.** The `simctl` row points to `ycrun simctl`.
- **Docs.** `specs/ide/ycrun.md` §8.3 and §10 (Device Hub), and
  `docs/YCRUN.md` (`--link`, `remote link`, the hubs).

## Live checks (2026-11-20)

The host was the Thor, in this workstream's own folders. The data folders,
devices, ports (47930–47933) and service were this workstream's own. The
runtime and the warm templates were used read-only. Timings are wall-clock.

**ycrun, the cycle create → boot → bootstatus → io screenshot → view →
shutdown → delete:**

| Route | Setup | Boot to Booted | Screenshot | view | Shutdown | Delete |
|---|---|---|---|---|---|---|
| x86 → Thor, a fresh host folder | 17.4 s (from nothing: Ycode 1.0.0-beta.4's aarch64 release downloaded and checked, the launcher, simhost.env, guest tools copied) | 91.1 s (cold, first boot) | 1.4 s (PNG 1398 × 2034) | 1.3 s (headless viewer: hello, live, picture of the home screen) | 13.7 s | 1.1 s |
| Thor, local (arm64, KVM) | 7.3 s (`--local`, the release tree) | 89.5 s / 83.4 s (cold) | 1.2 s / 0.2 s | 0.4 s (this branch's viewer; see the candidates) | 13.1 s | 0.1 s |
| Mac → Thor | 100 s (again on the same host: nothing to install) | 90.5 s (cold) | 0.8 s | not run: the Mac's viewer has no headless mode and would put a window on the screen | 12.5 s | 0.6 s |

A device copied from the warm iPhone Duo template booted in 41 s, and shut
down in 11 s. `ycrun remote link b5-fresh` from the x86 took 1.4 s: it
started the service (port 47930) and exchanged the identities. After it,
`ycode sim remote devices --host b5-fresh` listed the host's devices over
the link.

**Linux Device Hub** (x86 IDE, `YCODE_IDE_DEVICEHUB` walk, the device
"B5 Hub Linux" on the Thor through ycrun's ssh route): Manage Devices… opens
the hub. It lists both the link host's devices and the ssh host's devices.
After Start, the live screen showed in the canvas after 25.8 s (a warm
restore). Then Home, Rotate (the device turned to landscape), Screenshot
("Screenshot Saved", the server's PNG), Settings (read from the device),
Info (Booted), the row's menu, More Actions and Shut Down all worked, and
Open Developer Tool ▸ Device Hub brought the same window forward.
Screenshots: `~/Ycode-B5-DEVICES/shots/linux-live-hub-*.png` on the x86.

**macOS Device Hub** (`DeviceHubLiveMacTests`, the hub opened without a
workspace, its window kept off every display): Start on the device
"b5-hub-mac" (a copy of the warm template) over ssh. The stream went live
after 7.5–9.7 s, and the home screen showed in the canvas after 26–39 s
(the boot logo before it). Home, Rotate, Screenshot ("Screenshot Saved",
one PNG) and Shut Down from More Actions all acted on the device. A device
`ycrun simctl boot` started from the x86 showed as Booted in the macOS hub
(one poll), its live screen came up 1.4 s after the hub opened, and Shut
Down from the hub stopped it with ycrun's SIGTERM in 6.3 s (33.3 s in an
earlier run that included the save). `ycrun simctl list` then said
Shutdown, and the pid file was gone. Pictures:
`.build-ide/b5-shots/mac-live-*.png` (window captures) and
`mac-live-*-canvas.png` (the canvas's own picture). A window kept off every
display is captured by the window server with the picture it first drew,
so for a device that was still booting when the hub connected, the window
captures show the boot logo. The canvas pictures show the home screen.

## Checking a real Apple simulator (for the orchestrator)

Clean agents may not boot Apple simulators. These steps check the simctl
path of the macOS hub with a throwaway device. They put Ycode's window and
the Simulator app on the screen, so they need the owner's OK.

1. Make a throwaway device and note its UDID:
   `xcrun simctl create "B5 Check" com.apple.CoreSimulator.SimDeviceType.iPhone-17 <an installed iOS runtime id from xcrun simctl list runtimes>`.
2. Launch Ycode from this branch (the app, `make-app.sh` or
   `.build/…/YcodeApp`), with no workspace open, and choose Ycode ▸ Open
   Developer Tool ▸ Device Hub. Then open a workspace and choose Product ▸
   Destination ▸ Manage Devices… (⇧⌘2): both must show "B5 Check" under
   Simulators.
3. Select it and press Start in the canvas. Within about 30 s,
   `xcrun simctl list devices | grep "B5 Check"` says Booted, and the
   Simulator app opens on that device
   (`open -a Simulator --args -CurrentDeviceUDID <udid>`). The canvas shows
   the capsule "Running in the Simulator app" with Show in Simulator. Home
   shows the banner that the screen is in the Simulator app.
4. Press Screenshot: the banner says "Screenshot Saved", and a PNG appears
   in the screenshot folder (`simctl io <udid> screenshot`).
5. From the row's context menu choose Restart: the row goes Shutdown, then
   Booted, within the hub's 2-second poll.
6. From More Actions choose Shut Down: simctl says Shutdown, and the canvas
   shows Start again.
7. With it shut down, choose Erase All Content and Settings… and confirm:
   `xcrun simctl erase` runs (the device's data is reset).
8. Make a failure: `xcrun simctl delete "B5 Check"` while the hub shows it,
   then Start. The banner should say "Could not start the simulator: …",
   and the next poll should drop the row.

## Tests

- `YcrunHubLinkTests` (YcodeSimControl, 7): the pid files that count, the
  SIGTERM stop, ycrun's shutdown sharing it, the link (service, identity,
  trust, over ssh only), `~/` folders on the host, a service that does not
  start, `--link` parsing.
- `DeviceHubSimHostTests` (YcodeIDEShell, 6): the host ycrun set up is listed
  with its states; an offline host; Start and Shut Down as ycrun does them;
  the ssh forward for the live screen; this machine only where the placement
  policy runs devices; link and ycrun hosts together without clashing names.
- `DeviceHubYcrunTests` (YcodeUITests, 2, offscreen): a device with a live
  pid file is Booted, Shut Down sends SIGTERM to that exact process and
  removes the pid file; an unanswering host keeps the last answer.
- `DeviceHubLiveMacTests` (opt-in): the macOS live check, and a device
  ycrun booted shown live and shut down from the hub.

## Candidates (not done here)

- The aarch64 release tarball's `ycode-sim-viewer` needs glibc 2.43, so it
  does not start on Ubuntu 24.04 (the Thor). `ycrun simctl view` on such a
  host fails unless a viewer built there is used (`YCODE_SIM_VIEWER`).
  `ycode-simd` and the launcher from the same tarball work.
- The macOS `ycode-sim-viewer` has no headless mode, so `ycrun simctl view`
  cannot be checked on a Mac without a window on the screen.
- The Linux hub's sidebar does not group devices by host. With a host that
  is both linked and set up by ycrun, the two device sets sit in one list
  (the ssh host's name carries "(ssh)" only in Info).
- The macOS hub follows ycrun's pid files on the IDE's host only. ycrun's
  other hosts (`hosts.json`) are not in the macOS hub.
- Several test suites leave defaults files in `~/.config` on Linux
  (`HeadsetSetupTests-*`, `edit-*`, `menus-b5-*`, `ycode-assistant-test-*`,
  `ycode-runtime-tests-*`, `ycode.build-notifications.*`).
  `removePersistentDomain` does not delete the file there.
- On a real home screen, the hub walk's tap lands between icons. The walk
  now reports the picture count for real devices instead of failing.
