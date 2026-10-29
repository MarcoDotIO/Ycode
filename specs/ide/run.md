# Run on simulators

Ycode modules: `YcodeUI` (`Simctl`, `AppBundle`, `SimulatorRunState`,
`RemoteSimulator`, `RemoteSimulatorSettings`, `WorkspaceSession`
run extensions, `WorkspaceWindowController.runProduct`,
`SimulatorsSettingsPane`); the host-side launcher
`ycode/scripts/ycode-sim.sh` (§Warm boot).

## Choosing the run path

Product ▸ Run (⌘R) looks at the destination:

- macOS (My Mac): build, then launch under lldb-dap (`debug.md`).
- An iOS-family simulator (a `simctl` device; destination kind
  simulator): build for that destination, then run on the Mac simulator
  (below).
- **Ycode Simulator**: build for the generic iOS Simulator
  destination, then run on the remote Ycode simulator (below). This
  destination is listed only when Settings ▸ Simulators is filled in. It
  is a row of the destination menu's **Simulators** section (no section
  of its own, `reference-ui-5.md` §11.5) that reads "Ycode Simulator
  <runtime version>" and sorts with the other simulators by that version
  (with the newest runtime while the version is unknown). The version is
  the runtime root's `System/Library/CoreServices/SystemVersion.plist`
  `ProductVersion`, read once per runtime root over ssh (`cat '<runtime
  root>/System/Library/CoreServices/SystemVersion.plist'`, off the main
  thread) and kept in user defaults; until then, a dotted version after
  "iOS" in the runtime root's path, if any. The destination is
  identified by its identifier, not by its title. With more than one
  runtime root or device type there is one such row per runtime and type,
  titled "<device type> (Ycode) <runtime version>" (§Runtimes and device
  types; this replaces the single "Ycode Simulator" title).

The app bundle a simulator build makes: the build engine's product path
with the configuration folder suffixed `-iphonesimulator` and without
`Contents/MacOS/<exe>` (e.g. `…/Products/Debug-iphonesimulator/App.app`).
OPEN QUESTION: whether every engine uses that folder name for every
product type.

## Mac simulator (`xcrun simctl`)

Ycode never opens the Simulator app; devices boot headless.

1. `simctl bootstatus <udid> -b`: boots the device if needed and waits
   until it has finished booting.
2. `simctl install <udid> <App.app>`.
3. `simctl launch --console --terminate-running-process
   [--wait-for-debugger] <udid> <bundle id>` stays attached; the app's
   stdout and stderr arrive on simctl's output and go to the debug
   console as Target Output (a `<bundle id>: <pid>` line, when printed,
   is not shown). With `--stdout=`/`--stderr=` files the app's output
   stayed empty in our runs, so Ycode does not use them (OPEN QUESTION).
4. The app's pid: the newest host process whose command line contains
   `/<App>.app/<executable>` (`pgrep -n -f`); simulator apps are host
   processes.
5. Debugging (the default for Run): the launch waits for the debugger;
   Ycode attaches lldb-dap by pid (with the app's executable as
   `program`, so lldb selects the simulator platform), sends the
   breakpoints, and resumes the app once after the attach stop. simctl
   exiting ends the run ("Program ended with exit code: N").
6. Stop (⌘.): `simctl terminate <udid> <bundle id>`, and the debug session
   is disconnected.

simctl's own output is read from a file, not a pipe: processes it starts
can keep a pipe open after simctl exits.

Tests create their own device `ycode-test-ide-<pid>-<uuid>` (`simctl
create` from an installed iOS runtime and one of its iPhone device types;
`<pid>` is the test process) and record its UDID. Cleanup shuts down and
deletes a device only when its current name starts with `ycode-test-` **and**
its UDID is one this test process created; any other device is refused (the
refusal is itself tested). Other tools and agents also name their devices
`ycode-test-…` (the boot tools' `ycode-test-L…`, a parallel run of the suite
in another checkout), so the prefix alone is not enough. Devices a killed run
left behind are swept only when they are named `ycode-test-ide-<pid>-<uuid>`
and that pid no longer runs.

## Remote Ycode simulator

Settings ▸ Simulators (user defaults only, never files in a project):
SSH destination (`user@host`), remote data directory, runtime root,
`ycode-simd` path, device name (default `ycode-device`), other runtime
roots (§Runtimes and device types), and Additional
arguments (host-side `ycode-simd` options such as `--shim`, `--host-stubs`,
`--host-libs`, `--runtime-paths`, `--metal-translator`, `--gpu-cache-dir`,
`--timeout-ms`; split into words as a shell would — quotes group,
backslash escapes — and appended after the generated options, each
single-quoted). SSH runs with
`-o BatchMode=yes`: keys only, never a password prompt.

Settings ▸ Simulators also has **Lean boot** (a checkbox, **off by
default**) with the help text "Development option: skips background
services such as Siri, Spotlight, suggestions and photo analysis, so apps
that use them see them missing. Off (the default), every service boots, as
the reference simulator does." and a "Keep services" text field
(comma-separated launchd labels, empty by default; it applies only while
Lean boot is on). When Lean boot is on, the remote command sets the
environment of `ycode-simd` through `env`: `exec env
YCODE_LEAN_BOOT=daemons [YCODE_LEAN_BOOT_KEEP='<labels>'] '<ycode-simd>'
…` (`specs/simulator/lean-boot.md`). When it is off, neither variable is
set and the device boots every service. The reference simulator boots
every service, so IDE runs do too by default (since 2026-10-27; before,
Lean boot was on by default). Lean boot stays a development convenience.

The setting is kept in the user defaults under
`Ycode.remote.leanBootChoice`. Until 2026-10-27 it was on by default and
kept under `Ycode.remote.leanBoot`, which every save of the pane wrote, so
a stored `true` there mostly recorded the old default. That key is no
longer read, and the next save removes it: after the update every user
runs a full boot once, and a user who wants Lean boot turns it on again
(it is then remembered). Switching Lean boot on or off changes the warm
boot's fingerprint (§Warm boot, item 2: the `YCODE_LEAN_BOOT*` variables),
so the next run discards a snapshot of the other kind and boots cold
once. The setting applies to every Ycode simulator row (each runtime root
and device type, §Runtimes and device types); each row has its own device
directory (the iOS 27.1 iPhone Duo row keeps `ycode-device`) and its own
snapshot, so each row boots cold once, at its next run, after the switch.

Settings ▸ Simulators also has **Warm boot from snapshot** (a checkbox,
**on by default**) with the help text "Keeps the device's state between
runs: when a run stops, the device is saved, and the next run continues
from it in seconds instead of booting; apps and their data stay until the
device is erased. Saves are replaced when the simulator or the runtime
changes. Turn off to boot from scratch every time." The remote command always passes it: `exec env
YCODE_WARM_BOOT=1|0 [YCODE_LEAN_BOOT=…] '<ycode-simd>' …` (§Warm boot).

Settings ▸ Simulators also has **Camera** (a pop-up: **Off** (the default),
Host webcam, Synthetic pattern) with the help text "Gives apps a camera: the
host's USB webcam (or a test pattern when it has none) appears as the
device's back camera (an iPad's external camera). The reference simulator
has no camera, so the default is Off." It is the device's camera setting of
`specs/simulator/camera.md` ("Ycode implementation"): until the user picks a
value the remote command passes nothing (the device keeps its own setting,
off for a new device); once picked (defaults key `Ycode.remote.camera`) every
run (and Device Hub's Start) passes `--camera off|on|synthetic` at the end of
the command, and the device keeps
the last value. The launcher's warm-boot fingerprint includes the option, so
a change boots cold once. The host's guest tools must hold
`libYcodeCamera.dylib` (`SimGuestAgents/build-camera.sh`) for apps to see
the camera.

Run:

1. `ssh -o BatchMode=yes <dest> "mkdir -p '<data>/apps'"`.
2. `rsync -az --delete -e "ssh -o BatchMode=yes" <App.app>/
   <dest>:<data>/apps/<App.app>/`.
3. `ssh -o BatchMode=yes <dest> "echo YCODE-REMOTE-PID $$; exec
   env YCODE_WARM_BOOT=1|0 [YCODE_LEAN_BOOT=daemons …] '<ycode-simd>' --device '<data>/devices/<device>' --runtime-root
   '<runtime root>' --install-app '<data>/apps/<App.app>' --launch
   '<bundle id>'"` (single-quoted arguments; the options are those of
   `ycode-simd`'s device mode, `specs/simulator/app-install-launch.md`).
   The first line gives the remote pid (not shown). The activity view shows
   a determinate status driven by the output: "Booting Ycode Simulator…
   (1 of 3)" from the start; "Launching <App>… (2 of 3)" at the first line
   mentioning install, launch or open, with " — retry N" for each "no
   completion within …" line (a retry, not an error); "Running <App> on
   Ycode Simulator (3 of 3)" at "launched <bundle id> pid N". Lines before
   that point (and the launched line) go to the console as Debugger Output
   (Ycode status); later lines as Target Output, except the launcher's
   own lines ("ycode-sim: …"), which are Ycode status. When ycode-simd
   ends by itself the console prints "Ycode Simulator ended with status N"
   (ycode-simd's exit status) and the activity is "Finished running
   <App>" (status 0) or "Run failed".

   > **Correction (pass 6, `reference-ui-6.md` §3.3):** the reference's
   > simulator run reads "Launching <App>" (also while booting),
   > "Configuring Debugger Actions", "Running <App> on <device name>",
   > "Finished running <App> on <device name>", with no step counter. The
   > "(1 of 3)" counters and the separate boot text are to be replaced by
   > that sequence; the console lines above stay.
   > *Status (R42): done. The activity reads "Launching <App>" from the
   > upload until the launched line (open retries show in the console
   > only), then "Running <App> on <device>", and after the run "Finished
   > running <App> on <device>"; <device> is the destination row's name
   > ("iPhone Duo (Ycode)"). No debugger attaches to a remote run, so it
   > has no "Configuring Debugger Actions" step.*
4. Stop: `ssh <dest> "kill -INT <pid>"`, sent off the main thread; the
   launcher turns it into the save at the stop (§Warm boot item 5). The
   local ssh process is **not** signalled at once: the connection stays
   open so the launcher's report reaches the console (as Ycode status,
   like every line after Stop), and the activity reads "Stopping <App> —
   saving Ycode Simulator…" (warm boot on) or "Stopping <App>…" (off).
   The local ssh process gets SIGINT
   - 0.5 s after the launcher's "ycode-sim: warm boot: the device was
     saved; …" or "… the device was not saved; …" line (the launcher is
     done; ycode-simd's teardown is not waited for), then the console
     prints "Ycode Simulator stopped";
   - at once when the `kill` could not be delivered (ssh's status is not
     0; the console says so);
   - 150 s after Stop if the run has not ended (longer than the
     launcher's own 120 s stop timeout; the console says so);
   - at once at a second Stop.

   Stop before the remote pid has arrived sends the `kill` when it
   arrives. Stop during the upload ends the run before anything is
   launched. A stopped run's activity is "Finished running <App>",
   whatever the exit status.

Tests use a local script in place of ssh (it drops the options and the
destination and runs the command with `/bin/sh`) and a stand-in
`ycode-simd`; rsync runs for real between local folders. No network.
An opt-in end-to-end test (`RemoteRunEndToEndTests`, `YCODE_E2E_*`
variables, full boot unless `YCODE_E2E_LEAN_BOOT=1`, warm boot unless
`YCODE_E2E_WARM_BOOT=0`) runs a real app on a real host and prints the
times to the home screen and to the launch.

### Runtimes and device types

The host can hold more than one simulator runtime (the reduced iOS 27.1
runtime with Settings and Safari only, and the iOS 27.0 runtime with Maps,
Calendar, Photos, Messages and the other apps of
`specs/simulator/home-apps.md` §4–§5), and `ycode-simd` boots several
device types (`--device-type`, `specs/simulator/ipad.md` §4).
**Ycode decision:** the remote simulator offers one run destination per
runtime root and device type.

- Settings ▸ Simulators keeps **Runtime root** (the primary runtime) and
  adds **Other runtime roots** (paths separated by commas or new lines;
  empty by default) with the help text "More simulator runtimes on the
  host, separated by commas. Each runtime adds a run destination for every
  device type it supports (for example iOS 27.0 with iPads and its full app
  set). Every runtime and device type has its own device, so data and saved
  state are kept apart." User defaults: `Ycode.remote.otherRuntimeRoots`
  (array of strings).
- Each root's version is read from the host as for the primary root (§Choosing
  the run path), once per root, and kept per root in
  `Ycode.remote.runtimeVersions` (root → version; the primary root's also
  under the single-runtime keys as before). Until it is known, a version in
  the root's path is used.
- Device types and the runtimes they run on (the device type's
  `minRuntimeVersion`, `ipad.md` §3.2): iPhone Duo (`iphone-duo`, 27.1 and
  later), iPad (A16) (`ipad-a16`, 18.3 and later), iPad Pro 13-inch (M5)
  (`ipad-pro-13-m5`, 26.0 and later). A root whose version is unknown offers
  every type. On 27.1 the iPads are Ycode identities without a reference
  (CoreSimulator restricts that runtime to the iPhone Duo; `ipad.md` §8 D1).
- **Rows.** For each root (the primary first) and each type that runs on its
  version, a row "<device type> (Ycode)" with the runtime version, e.g.
  "iPhone Duo (Ycode) 27.1", "iPad Pro 13-inch (M5) (Ycode) 27.0". They sort
  with the simulators by runtime, then iPhone before iPad. The primary root's
  first type, when it is the iPhone Duo, keeps the identifier
  `ycode-remote-simulator` and the device directory `<device name>` that
  Ycode used before runtimes were choosable, so an existing device, its
  snapshot and a remembered destination stay. Every other row's identifier
  is `ycode-remote-simulator:<type id>@<runtime root>` and its device
  directory `<device name>-<type id>-<runtime version>` (the version, or the
  root's last path component when the version is unknown, as a file name).
  A remembered identifier that no longer exists selects the primary row.
- **Run.** The command names the row's runtime root and device directory and
  adds `--device-type <id>` unless the type is the iPhone Duo (`ycode-simd`'s
  default, so the primary row's command and its snapshot fingerprint are
  unchanged):
  `… --device '<data>/devices/<device name>-ipad-pro-13-m5-27.0'
  --runtime-root '<27.0 root>' '--device-type' 'ipad-pro-13-m5'
  --install-app …`.
- **Per-runtime state.** Device directory, snapshot (the launcher keys
  snapshots by device directory and fingerprints the arguments, so the
  runtime root and the type are in it, §Warm boot item 2), erase, and the
  Devices and Simulators row are per row: the Devices window lists one
  "<device type> (Ycode)" row per runtime and type with its runtime version,
  and Erase All Content and Settings… erases that row's device only. The GPU
  caches (`--gpu-cache-dir`: the Vulkan pipeline cache and `ycode-airc`'s
  translation cache) stay shared: both are keyed by content (the shader
  function's hash and the translator version; the driver's own pipeline
  keys), so two runtimes' shaders do not collide.
- `ycode-simd` records the runtime a device booted in
  `DEV/ycode-runtime` and refuses to boot that device on an older runtime
  version (`specs/simulator/ipad.md` §9.2), so a row whose root was changed
  to an older runtime reports the device instead of breaking its data.

### Settings and Environment Overrides (FEAT-IMPL, 2026-10-27)

The run command launches the app with `--environment-overrides` after
`--launch '<bundle id>'` (Ycode's overrides library is inserted into the
app; `debug.md` §Environment Overrides). The launcher counts it as an app
option, so it is not part of the warm boot's fingerprint. The settings of
a running device (`devices.md` §Settings) and the debug bar's overrides and
location go through the launcher like the fold commands: `ycode-sim
--device '<dev>' --control ui|accessibility|location|audio|overrides|settings …`,
answered at once by the running `ycode-simd` (no boot slot). The launcher
also passes `--ui`, `--accessibility`, `--location`, `--audio`,
`--overrides` and `--settings` straight to `ycode-simd`, which writes the
persistent settings of a stopped device into its files for the next boot
(`specs/simulator/simulator-features.md` "Ycode implementation" §I.4).

### Folding (iPhone Duo rows)

A running iPhone Duo is folded from Devices and Simulators (`devices.md`
§Folding): each command is one ssh call of the launcher, `ycode-sim
--device '<dev>' --control fold|rotate|state …`, which the launcher hands
to `ycode-simd` at once (no boot slot) and which reaches the running
device through its control socket (`specs/simulator/foldable.md` §10.1).
A foldable device boots with Ycode's HID bundle, which carries the hinge.

### Warm boot

The reference IDE's simulator just boots; how long that takes is Ycode's
choice. A cold boot of the Ycode simulator to the home screen took
80–120 s on the reference Linux host (full boot, 2026-10-19); on the main
line of 2026-10-27 it takes about 30 s on an idle host (median of timed
boots, full boot: `specs/simulator/lean-boot.md` §9,
`scheduling-policy.md` §7.5) and 40–240 s while other boots load the
host; a restore of a snapshot of the booted device
(`specs/simulator/snapshot.md`) takes 5–12 s. So the
remote "ycode-simd path" is normally a host-side launcher,
`ycode/scripts/ycode-sim.sh` (installed on the host as `ycode-sim`, with
host paths in a `ycode-sim.conf` next to it), which runs `ycode-simd` and,
with `YCODE_WARM_BOOT=1`, makes restore the default warm-boot path. It
takes the same arguments and keeps the remote pid contract (Stop's SIGINT
reaches the launcher, which stops `ycode-simd`). A plain `ycode-simd` path
ignores the variable and always boots cold. The launcher:

1. Takes the device lock (a `flock` on `$YCODE_SIM_DATA/snapshots/
   <device>/.lock`, held until the run's save is in place: a second run
   of the same device prints "waiting for the previous run of this device
   to end and its save to finish") and a boot slot (a `flock` on one of
   `$YCODE_SIM_LOCKS/boot.N`, shared with benchmark runs).
2. Decides whether the device's snapshot (`$YCODE_SIM_DATA/snapshots/
   <device>/current`) is valid. It is discarded (deleted in the
   background) when its stamp's fingerprint differs — a hash of the
   `ycode-simd` binary, shim, host stubs, translator, host libraries and
   guest frameworks (path, size, mtime), the runtime root's
   `SystemVersion.plist`, every argument except the app options
   (`--install-app`, `--launch`, `--app-arg`, `--app-env`) and the
   `YCODE_LEAN_BOOT*` variables — or when the device directory is gone
   (erased) or is not the one the snapshot was made for (its inode
   number is recorded), or the snapshot was made for another device
   path, or it is incomplete, or **the device directory is no longer in
   the snapshot's state** (`device-sync` does not name the snapshot: a
   run used the device after the snapshot and ended without saving it).
   The device directory itself is never replaced: a discarded snapshot
   means a cold boot of the device as it is, with its data.
3. **Valid snapshot: restore in place.** `ycode-simd` runs with
   `YCODE_RESTORE_DIR`, `YCODE_RESTORE_LAZY=1` and
   `YCODE_RESTORE_LENIENT=1` on the device directory as the snapshot left
   it, with the usual app options: the app is installed (over the copy
   already on the device, which keeps its data container) and launched
   after the restore exactly as after a boot. The launcher watches
   screenshots for the home screen (two frames in a row with mean
   luminance above 60) and prints "ycode-sim: home screen at N s …". The
   restore **has failed** when `ycode-simd` ends before the home screen,
   when no home screen appears within 120 s (`YCODE_WARM_HOME_TIMEOUT_S`),
   when the restored guest has not answered a request within 60 s
   (`YCODE_WARM_LIVE_TIMEOUT_S`) or presented a new frame within 90 s
   (`YCODE_WARM_FRAME_TIMEOUT_S`; the restored frame is lit from the start,
   `snapshot.md` §12.5), or when the app steps have not finished 300 s
   after the start (`YCODE_WARM_APP_TIMEOUT_S`). Then the launcher asks
   `ycode-simd` for a thread report (SIGUSR1) into the run log, kills it,
   prints "ycode-sim: warm boot: the restore failed …; discarding the
   snapshot and booting cold", discards the snapshot and continues with
   step 4 in the same run (same pid, same slot). A restored run that
   later ends by itself with a non-zero status also discards the snapshot.
   The last runs' logs stay in `runs/<device>/logs/` and host crash reports,
   symbolized by the launcher, in `runs/<device>/crashes/` (`snapshot.md`
   §12.5).
4. **No valid snapshot: cold boot.** `ycode-simd` boots cold with the app
   steps held until 60 s after the home screen (`YCODE_SNAPSHOT_WHEN_FILE`
   written by the home-screen watcher, `YCODE_SNAPSHOT_DELAY_MS=60000`,
   the settle time `YCODE_WARM_SETTLE_MS`, `YCODE_SNAPSHOT_HOLD_APPS`; at
   most 480 s). No snapshot is taken then.
5. **Stop: the device is saved.** Every warm-boot run passes
   `YCODE_SNAPSHOT_STOP_DIR` (a directory on the RAM file system when it
   has 6 GB free, else in the data directory). Stop (Ycode's SIGINT; the
   launcher sends `ycode-simd` SIGTERM), the end of `--timeout-ms`, or the
   ssh channel going away (SIGHUP) ends the run like this: `ycode-simd`
   kills the launched app, lets the device settle 2 s, writes a snapshot
   (pause 3–5 s), prints "snapshot: exiting after the snapshot" and exits
   without running the guest again, so the device directory stays as the
   snapshot recorded it. The launcher (which ignores SIGPIPE, so a closed
   ssh channel does not end it, and tees `ycode-simd`'s output with
   `tee -p`) prints "ycode-sim: warm boot: the device was saved; the next
   run continues from it" and hands the save to a background job that
   moves it to `snapshots/<device>/current` and marks the device directory
   as being in its state; that job holds the device lock. A stop during
   the app steps, a crash, or a quiesce that does not settle saves
   nothing ("the device was not saved; the next run boots it cold (its
   data stays)"). If `ycode-simd` has not ended 120 s after the stop
   (`YCODE_WARM_STOP_TIMEOUT_S`) it is killed.
6. Without `YCODE_WARM_BOOT=1` the launcher execs `ycode-simd` directly
   (the old cold path).
7. `ycode-sim --erase --device <device dir>` erases the device (as
   `xcrun simctl erase`): after the device lock it discards the snapshot
   and the device directory; the next run boots a new device. The IDE
   calls it from Devices and Simulators: the remote simulator is a row of
   the Simulators list, and its context menu has "Erase All Content and
   Settings…", which asks first (Erase / Cancel) and runs `ssh -o
   BatchMode=yes <dest> "exec '<ycode-simd path>' --erase --device
   '<data>/devices/<device>'"`. It is refused while a workspace runs an
   app on the remote simulator. (OPEN QUESTION: where the reference IDE
   puts device erase; `devices.md` has no command for it.) A test device
   can also be erased by deleting its directory, which the launcher
   detects.

A restored device runs every service a full boot runs: the snapshot is
of a full boot (or of a lean boot when Lean boot is on, which is part of
the fingerprint), and nothing is killed or skipped at restore.

**The device keeps its state between runs**, as the reference simulator's
device does until it is erased: an app's files in its data container,
its preferences and keychain items, the apps installed by earlier runs
and settings changed on the device survive every run that ends with a
save, and a cold boot (after a failed restore, a crash, or a new
simulator build) starts from the same data (`snapshot.md` §12.2 has the
design and the trade-off: each stop costs a 3–5 s pause and a background
save, which a Run right after a Stop waits for).

Measured through the IDE path (Mac → ssh → launcher on the reference
host, probe app, full boot, 2026-10-19, host shared with up to four other
boots, load 25–55). Times in seconds from the start of `ycode-simd`;
"Run" is from ⌘R on the Mac (upload and slot wait included):

| Run | Home screen | App launched | From Run: home / launched |
|---|---|---|---|
| cold + capture, launcher on the host (load 5–9) | 81.0, 81.4 | ≈116 (10 s settle), ≈275 (60 s settle) | — |
| cold + capture (4 runs; 2 after a failed restore) | 100.9–122.5 | — | 108–156 / 196–258 |
| cold, warm boot off (1 run) | — | — | — / 252 |
| restore, launcher on the host (load 5) | 6.5 | 35.2 | — |
| restore (3 runs) | 7.8, 9.2, 12.4 | ≈32, ≈43, 86 | 13.9 / 47.9 (run without a slot wait) |

The settle time matters: a snapshot taken 10 s after the home screen
(while launchd was still starting held daemons) restored to the home
screen but its app install never finished; 60 s after it, installs after
a restore finished in every run. Restores also failed now and then with
"no vCPU for thread N" (closed: `snapshot.md` §12.1); the fallback
booted cold.

With the device kept between runs (2026-10-19, agent SNAP-FIX, launcher
and IDE path, probe app that counts its launches in its preferences, a
file and the keychain; `snapshot.md` §12.3):

| Run | Home screen | App launched | From Run: home / launched |
|---|---|---|---|
| restore in place, launcher on the host (5 runs, load 10–40) | 6.4–11.1 | 26.2–30.2 | — |
| restore in place through the IDE | 6.5 | 23.3 | 9.4 / 23.6 |
| cold through the IDE (new simulator build) | 40.4 | 120.4 | 46.7 / 120.8 |
| Stop → launcher done (save written) | — | — | 5.1–6.1 s after the stop; the move to the data volume 2–5 s more |

Every run that followed a saved one found the data of all earlier runs;
a cold boot after a simulator rebuild found it as well; after
`ycode-sim --erase` the device was new.

Full boot as the default (2026-10-27, agent SVC-FULL; Mac → ssh →
launcher through `RemoteRunEndToEndTests`, probe app, warm boot on, one
device copied from the golden device; the host was shared with other
agents' boots, load 30–120, which made every boot slower than the timed
30 s):

| Run | Lean boot | Launcher | Home screen | App launched | Stop → saved |
|---|---|---|---|---|---|
| 1 | off (default) | "no snapshot yet; cold boot"; no "lean boot" line, every service runs | 285.5 s | 361.4 s | 14.1 s |
| 2 | on | "discarding the snapshot (… the boot options changed)"; cold; "lean boot: 23 jobs disabled" | 150.8 s | 228.5 s | 5.1 s |
| 3 | off | discards run 2's lean snapshot; cold full boot | 140.8 s | 214.5 s | 5.6 s |
| 4 (after the merge with the per-runtime rows, new build) | off | "the simulator build … changed"; cold full boot | 85.5 s | 161.5 s | 5.6 s |

Times are from the start of `ycode-simd`. All four runs passed the test
(the app launched, Stop saved the device). Guest fatal conditions in the
full boots: fileindexerd and intelligencetasksd
(`specs/simulator/service-fidelity.md` §11, §13); in the lean boot,
AppIntentsLiveEntityService (which also writes crash reports on the Mac,
`parity-ladder.md` §3.1; once in run 4 too).

## Evidence

- `simctl` subcommands and options: `xcrun simctl help` and
  `xcrun simctl help launch` (level 1); behavior checked on the reference
  Mac with a throwaway device (level 3).
- lldb attach by pid: lldb-dap's documented attach arguments (level 1).
- ycode-simd options: Ycode's own `ycode-simd` and
  `specs/simulator/app-install-launch.md`.
- Lean boot off by default, the settings key and the snapshot switch
  between lean and full: Ycode design; the full and lean boots through
  the IDE path above are our runs (level 3), and the reference simulator
  boots every service (`specs/simulator/parity-ladder.md`, level 3).
- Warm boot: the reference simulator boots a device and keeps its data
  (observable, level 3); `xcrun simctl help erase` (erase a device's
  contents and settings) and Apple's documentation that an app's data
  container and keychain items are kept when the app is updated (level
  1); the snapshot, restore, save-at-stop and fallback behavior and the
  timings are Ycode's own design and our runs on the reference Linux host
  through the launcher and `RemoteRunEndToEndTests` (level 3).
- Camera: Ycode design (the reference simulator has no camera,
  `specs/simulator/camera.md` §1); `CameraSettingTests` (no network).
- Runtimes and device types: the device types' `minRuntimeVersion` and the
  runtimes' device-type support (`specs/simulator/ipad.md` §2.1, §3.2, level
  2); rows, identifiers, device directories, the per-root versions and the
  shared GPU caches are Ycode decisions, tested by `RemoteRuntimesTests`
  (no network); the 27.0 boots behind them: `specs/simulator/ipad.md` §9.2
  (level 3, Ycode on the Thor).
- Test devices: the profiler's finding that the old sweep deleted other
  agents' `ycode-test-*` devices, and `TestSimulatorDevicesTests` (level 3).
- OPEN QUESTION: the reference IDE's simulator boot UI (it opens the
  Simulator app; Ycode does not), app-icon/launch-screen handling, and
  device logs beyond stdout/stderr.
