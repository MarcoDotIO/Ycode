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
  identified by its identifier, not by its title.

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
`ycode-simd` path, device name (default `ycode-device`), and Additional
arguments (host-side `ycode-simd` options such as `--shim`, `--host-stubs`,
`--host-libs`, `--runtime-paths`, `--metal-translator`, `--gpu-cache-dir`,
`--timeout-ms`; split into words as a shell would — quotes group,
backslash escapes — and appended after the generated options, each
single-quoted). SSH runs with
`-o BatchMode=yes`: keys only, never a password prompt.

Settings ▸ Simulators also has **Lean boot** (a checkbox, **on by
default**) with the help text "Faster boot for development: skips
background services such as Siri, Spotlight, suggestions and photo
analysis. Turn off to boot every service, as the reference simulator
does." and a "Keep services" text field (comma-separated launchd labels,
empty by default). When Lean boot is on, the remote command sets the
environment of `ycode-simd` through `env`: `exec env
YCODE_LEAN_BOOT=daemons [YCODE_LEAN_BOOT_KEEP='<labels>'] '<ycode-simd>'
…` (`specs/simulator/lean-boot.md`). When it is off, neither variable is
set. Lean boot is a development convenience, not parity: the reference
simulator boots every service, and benchmarks against it use a full
boot.

Settings ▸ Simulators also has **Warm boot from snapshot** (a checkbox,
**on by default**) with the help text "Keeps the device's state between
runs: when a run stops, the device is saved, and the next run continues
from it in seconds instead of booting; apps and their data stay until the
device is erased. Saves are replaced when the simulator or the runtime
changes. Turn off to boot from scratch every time." The remote command always passes it: `exec env
YCODE_WARM_BOOT=1|0 [YCODE_LEAN_BOOT=…] '<ycode-simd>' …` (§Warm boot).

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

### Warm boot

The reference IDE's simulator just boots; how long that takes is Ycode's
choice. A cold boot of the Ycode simulator to the home screen takes
80–120 s on the reference Linux host (full boot); a restore of a snapshot
of the booted device (`specs/simulator/snapshot.md`) takes 8–12 s. So the
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

## Evidence

- `simctl` subcommands and options: `xcrun simctl help` and
  `xcrun simctl help launch` (level 1); behavior checked on the reference
  Mac with a throwaway device (level 3).
- lldb attach by pid: lldb-dap's documented attach arguments (level 1).
- ycode-simd options: Ycode's own `ycode-simd` and
  `specs/simulator/app-install-launch.md`.
- Warm boot: the reference simulator boots a device and keeps its data
  (observable, level 3); `xcrun simctl help erase` (erase a device's
  contents and settings) and Apple's documentation that an app's data
  container and keychain items are kept when the app is updated (level
  1); the snapshot, restore, save-at-stop and fallback behavior and the
  timings are Ycode's own design and our runs on the reference Linux host
  through the launcher and `RemoteRunEndToEndTests` (level 3).
- Test devices: the profiler's finding that the old sweep deleted other
  agents' `ycode-test-*` devices, and `TestSimulatorDevicesTests` (level 3).
- OPEN QUESTION: the reference IDE's simulator boot UI (it opens the
  Simulator app; Ycode does not), app-icon/launch-screen handling, and
  device logs beyond stdout/stderr.
