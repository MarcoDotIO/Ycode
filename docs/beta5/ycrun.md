# B5-YCRUN work log (1.0.0-beta.5)

The owner asked on 2026-11-17 for "our own ycrun that can launch simulators
in macOS and (on host if ARM, through remote simulator device if x86)", with
the remote simulator set up through ycrun too. Clean room: specs, docs,
Ycode's own code and the public `xcrun simctl help` text only.

## What landed

- `ycrun` (new executable, macOS and Linux) and `YcodeSimControl` (its
  library): `ycode/Sources/ycrun/`, `ycode/Sources/YcodeSimControl/`.
- **Placement seam**: `SimPlacementPolicy.decide` (arm64 Linux with usable
  KVM: local; x86-64 Linux and macOS: the simulator host;
  `--local`/`--remote`/`--host`). The Mac's switch for the MACHOST port is
  `SimPlacementPolicy.macOSRunsLocally`.
- **`ycrun simctl`**: list (with where each device lives, `-j`,
  `--json-output=`, `--all-hosts`), create, delete, rename, boot, bootstatus,
  shutdown, reboot, erase, install, launch (with `SIMCTL_CHILD_`), io
  screenshot, location, ui, pair, unpair, pair_activate, and `view` (Ycode
  only). Unsupported verbs and options exit 69 with the reason.
- **`ycrun remote`**: setup (interactive, or every step as a flag), list,
  status, test, remove. Key-only ssh with the `ssh-copy-id` step printed on
  failure; root steps printed, never run.
- **Settings**: the default host is the IDEs' own (`Ycode.remote.*` and the
  setup wizard's host in the IDE defaults domain), so the macOS IDE, both
  IDEs' Settings ▸ Simulator Host and Device Hub see it; more hosts in
  `~/.config/ycode/ycrun/hosts.json`.
- **Packaging**: `Contents/Helpers/ycrun` in the app (`make-app.sh`; checked by
  `verify-dmg.sh`), `/app/bin/ycrun` in the Flatpak and tarball
  (`build-ycode.sh`), `ycrun --install-link` for the PATH.
- **Docs**: `docs/YCRUN.md`, `specs/ide/ycrun.md`, `packaging/README.md`.

## Decisions made on the way

- **SIGTERM, not SIGINT, stops a device ycrun booted.** A boot is detached
  with `nohup setsid sh -c … &` so it outlives the ssh session. A
  non-interactive shell's background job starts with SIGINT ignored, and a
  shell cannot trap a signal ignored at its start, so the launcher never saw
  SIGINT (found in the stand-in live run: every stop waited the full 150 s).
  The launcher traps TERM the same way, and `ycode-simhost` already stops
  devices with SIGTERM.
- **A host is its destination plus its data folder**, so one machine can serve
  two data folders (found when two test hosts on the Thor replaced each other).
- **Apps install at launch**: Ycode's simulator installs and launches an app as
  the device starts, so `install` copies and records the app and `launch`
  restarts the device with it (warm boot makes that seconds).
- **UDIDs** are ycode-simd's own: the live run on the Thor printed the same
  UDID in ycrun's `create` and in ycode-simd's boot line.

## Live checks (2026-11-17)

The Thor rebooted that morning: its user had no `/dev/kvm` access (ACL for gdm
only, not in the kvm group), so no device could boot there. The plumbing was
checked with the real launcher up to KVM, and end to end with a stand-in
launcher (a script that answers like `ycode-sim`: a "device" that runs until a
signal, a control socket reply, a 1×1 PNG screenshot, a "launched … pid" line).

- Thor, local route: `ycrun simctl list` decides remote and says why; `--local`
  is refused with the kvm group fix; `ycrun remote setup --local` installs into
  the Thor folder, finds the runtime, makes the first device, and lists the
  KVM step; `ycrun remote test local` passes everything but `/dev/kvm`.
- x86 → Thor: `ycrun remote setup` (real tree and runtime) → checks, install,
  runtime iOS 27.1, first device, IDE settings in a test domain; `simctl list`
  shows the four devices on the host; a real `boot` reaches ycode-simd, which
  stops at `open /dev/kvm failed (errno 13)`, and ycrun shows the log and the
  fix. With the stand-in: create (simctl-style type id) → boot → bootstatus →
  io screenshot (PNG) → install → launch (`<id>: 4242`, 6 s) → shutdown (1.8 s)
  → erase → delete → `remote remove`.
- Mac → Thor: the same setup and real boot failure, then the stand-in cycle
  (boot, screenshot, `ui appearance`, install, launch, shutdown, JSON list),
  then both hosts removed and the test defaults domain deleted.

**Done 2026-11-20 (B5-DEVICES)**: real boots, screenshots, `view`, shutdowns and
deletes on all three routes, and setup on a fresh host folder; see
`docs/beta5/devices.md`.

## Tests

`YcodeSimControlTests` (38 tests, 4 suites): placement on every host kind and
the overrides; device types, runtimes, UDIDs, device selection, states,
displays, the launched-pid reading; every verb against a fake host (commands,
JSON, exit statuses, unsupported verbs, SIMCTL_CHILD_, list to a file); the
setup wizard with fake ssh (key failure → `ssh-copy-id`, never a password or
sudo; full setup writing the IDE settings both IDEs' Settings page and Device
Hub read; KVM denied; not arm64; interactive answers; two data folders on one
machine; remove; option parsing; `--install-link` plans).
