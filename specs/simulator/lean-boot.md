# Spec: the lean boot profile, logging off, and the golden device

Status: **implemented, off by default; a development option** (agent L,
2026-10-17; agent SVC-FULL, 2026-10-27: IDE runs no longer turn it on by
default, §9). It describes how Ycode can make the guest do less work while
it boots, without losing what a developer needs: the home screen, app
install, app launch and normal app behavior. `ycode-simd` and the harness
boot every service unless `YCODE_LEAN_BOOT` asks otherwise; since
2026-10-27 the IDE does too (`specs/ide/run.md`, Lean boot off by default).

Facts come from the runtime's job plists read as data files (level 2),
from black-box runs of the Mac's simulator through `xcrun simctl` on a
throwaway device (level 3), from the public `launchctl(1)` and
`launchd.plist(5)` manual pages (level 1), and from Ycode boots on the Thor
(level 3). No disassembly or decompilation was used.

Terms are as in `launchd-sim.md`: **RR** (RuntimeRoot), **DEV** (the device
directory), **TMP** (launchd_sim's per-device temporary directory,
`/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>`; on Ycode the
host path `DEV/private-var-tmp/<that name>`).

## 1. Why the boot does a lot of work

A Ycode boot runs the guest's own daemons. The boot is bound by the
global kernel lock (`stage6-contract.md`, the speed ledger), so the time
to the home screen follows the total amount of guest work more than the
cost of any one trap. Making a trap cheaper did not move the boot time;
making the guest do less can.

### 1.1 Which jobs start (inventory)

The iOS 27.1 runtime has 364 job plists: 329 in
`RR/System/Library/LaunchDaemons`, 25 in `LaunchAngels`, 9 in
`LaunchAgents` and 1 in `RR/Developer/Library/LaunchDaemons`. A further set
in `RR/System/Library/NanoLaunchDaemons` is not in `Paths`; the job
`com.apple.nanoregistrylaunchd` enables those labels at run time ("Setting
service com.apple.pairedsyncd to enabled (initiated by nanoregistrylaunchd)"
in `TMP/launchd.log`).

How a job comes to run (launchd.plist(5) keys, counted over the plists):

| Trigger | Plist key | Jobs |
|---|---|---|
| At load | `RunAtLoad` true | 23 (SpringBoard, backboardd, logd, runningboardd, assistantd, axassetsd, locationd, …) |
| Kept alive | `KeepAlive` true or a condition dictionary (`PathState`, `SuccessfulExit`, `Crashed`, `AfterInitialDemand`) | 44 |
| On demand | `MachServices` (a lookup of one of the names starts the job) | 348 jobs, 1,512 names |
| On an event | `LaunchEvents` (notifyd, distnoted, XPC activity, background tasks, …) | 213 |
| Off in the plist | `Disabled` true, or a feature-flag condition dictionary | 10 (`com.apple.locate`, `com.apple.resourcegrabberd`, flag-gated ones) |

`TMP/launchd.log` gives the reason for every start ("Successfully spawned
`<name>`[pid] because `<reason>`"). In one 900 s Ycode boot (integration
branch, 2026-10-17) about 250 jobs started. Reasons were `ipc (mach)`,
`xpc event`, `launch job demand`, `speculative`, `event publisher`,
`system support` and `inefficient`.

### 1.2 Where the guest work goes

Per-process trap counts from the exit summary of three 900 s Ycode boots
(level 3; mean per boot, about 30.7 M traps in all):

| Process | Traps per boot | Share | Starts per boot | Started because |
|---|---|---|---|---|
| suggestd | 5.73 M | 18.7 % | 1 | `ipc (mach)` |
| diagnosticd | 3.08 M | 10.0 % | 1 | `ipc (mach)` (§4) |
| parsecd | 2.88 M | 9.4 % | 1 | `event publisher` |
| axassetsd | 2.32 M | 7.6 % | 1 | `RunAtLoad` |
| logd_helper | 1.51 M | 4.9 % | 1 | `ipc (mach)` |
| homed | 1.22 M | 4.0 % | 1 | `ipc (mach)` |
| launchd_sim | 0.97 M | 3.2 % | 1 | — |
| searchd | 0.82 M | 2.7 % | 56 | `ipc (mach)`, `xpc event`; exits 0 when idle |
| proactiveeventtrackerd | 0.31 M | 1.0 % | 77 | `xpc event`; exits 1 |
| pairedsyncd | 0.24 M | 0.8 % | 79 | `ipc (mach)`; exits 0 ("pairing store path was nil") |
| facetimemessagestored | 0.22 M | 0.7 % | 75 | `xpc event`; exits 0 |
| mlhostd | 0.11 M | 0.4 % | 45 | `xpc event`; exits 0 |
| intelligencetasksd | — | — | 16 | `xpc event`; ends on an XPC peer requirement |

The first four processes alone are 46 % of all traps. Their worker
threads loop many times a second. Every restart also costs a process
spawn and an exec.

## 2. Switches (Ycode)

| Variable | Values | Effect |
|---|---|---|
| `YCODE_LEAN_BOOT` | unset/`0` (default): off; `1` or `daemons`: §3; `logging`: §4.4; `all`: both | the profile |
| `YCODE_LEAN_BOOT_DISABLE` | `label,label` | more labels to disable (with `daemons`/`all`) |
| `YCODE_LEAN_BOOT_KEEP` | `label,label` | labels taken off the list |
| `YCODE_DEVICE_TEMPLATE` | a golden device directory | §5 |

When the profile is on, `ycode-simd` prints one line, for example
`ycode-simd: lean boot: 23 jobs disabled, 40 log subsystems off`.

## 3. Disabled jobs

### 3.1 The mechanism: launchd's disabled overrides

`launchctl disable <domain>/<label>` is the documented way to stop a job
from loading (launchctl(1): "disables the service … future loads of the
service will fail"). Black-box on the Mac (throwaway iOS 27.1 device):

1. `xcrun simctl spawn <dev> launchctl disable system/com.apple.suggestd`
   and `… user/501/com.apple.parsecd` change no file under the device
   directory. They write **`TMP/disabled.plist`**: an XML property list,
   a flat dictionary of label → `true`. (`launchctl` warns that the
   `system/` form should be `user/foreground/` for this label; the result is
   the same file.) `launchctl print-disabled system` and `print-disabled
   user/501` both list the two labels.
2. TMP survives a device shutdown and boot on the Mac. At the next boot
   `launchd.log` is rotated to `launchd.log.1`, the overrides are still in
   force, and the disabled jobs are **not loaded at all** (absent from
   `launchctl list`; `launchctl print system/<label>`: "Could not find
   service").
3. A `disabled.plist` written by hand into TMP while the device is shut
   down has the same effect at the next boot (24 labels; all 24 listed by
   `print-disabled`).
4. A lookup of a disabled job's Mach service fails at once: `launchd.log`
   shows "failed lookup: name = …, requestor = …, error = 3: No such
   process". The device still boots to the home screen, and an app
   (Settings) launches.

`launchd-sim.md` §4.2 already names the file. `false` for a label means
enabled (`launchctl enable`), and it wins over the plist's `Disabled` key.

**Ycode.** With `daemons` or `all`, `ycode-simd` creates TMP itself before
the boot (mode 0700, the mode launchd_sim gives it) and writes
`TMP/disabled.plist` with every label of the profile set to `true`. An
explicit `false` already present stays (§3.3: Ycode's TMP is new for each
boot today, so there is none yet). Nothing in RR is changed and no job
plist is copied.

### 3.2 The list

The default list holds on-demand background jobs that are not on the path
to the home screen, app install or app launch, and that cost the most work
(§1.2) or restart again and again:

| Group | Labels | Why |
|---|---|---|
| Suggestions and search | `com.apple.suggestd`, `com.apple.parsecd`, `com.apple.parsec-fbf`, `com.apple.searchd`, `com.apple.spotlightknowledged`, `com.apple.spotlightknowledged.updater` | 28 % of traps; searchd restarts 56× |
| Accessibility assets | `com.apple.accessibility.axassetsd` | 7.6 % of traps (asset downloads) |
| Proactive, intelligence, Siri, media analysis | `com.apple.proactiveeventtrackerd`, `com.apple.mlhostd`, `com.apple.intelligencetasksd`, `com.apple.intelligenceplatformd`, `com.apple.knowledgeconstructiond`, `com.apple.textunderstandingd`, `com.apple.siriactionsd`, `com.apple.siriinferenced`, `com.apple.siriknowledged`, `com.apple.mediaanalysisd`, `com.apple.photoanalysisd`, `com.apple.sensorkitd` | restart loops (77×, 45×, 16×); background analysis |
| Paired watch | `com.apple.nanoregistrylaunchd`, `com.apple.pairedsyncd` | pairedsyncd restarts 79× on a device with no watch; nanoregistrylaunchd enables the companion family |
| Other | `com.apple.facetimemessagestored`, `com.apple.homed` | 75× restarts; 4 % of traps |

Not on the list, on purpose: logd, logd_helper, diagnosticd (§4),
notifyd, cfprefsd, runningboardd, backboardd, SpringBoard, PosterBoard,
lsd, installd, installcoordinationd, containermanagerd, MobileInstallation
helpers, dasd (app background tasks), biomed (used by many clients),
mobileassetd, tccd, configd_sim and every app or extension job.

### 3.3 What a developer loses

With the list: Spotlight search on the home screen, Siri, suggestions
(contacts/events found in apps, app suggestions), CoreSpotlight indexing
for apps, HomeKit, a paired watch, FaceTime message storage, and on-device
media/photo analysis. App code that talks to these services gets the same
failure as on a device where the service is missing (lookup error 3). A
developer who needs one adds its label to `YCODE_LEAN_BOOT_KEEP`.

Ycode differs from the Mac in one point that the profile does not change:
Ycode moves the previous boot's TMP aside at every boot
(`DeviceMode.swift`, `prepare()`), so a `launchctl disable` made by a user
inside the guest lasts for one boot only. On the Mac it lasts until the
device is erased.

## 4. Logging off

### 4.1 What the stream costs

`launchd-sim.md` §8.1: diagnosticd starts a system-mode stream client for
itself and writes `DEV/data/Library/Preferences/Logging/
com.apple.diagnosticd.filter.plist` with `global` = 0x9_0007_0000; every
process that reads the filter then sends every log message to diagnosticd
as XPC (about 300 000 messages per boot). The Mac's simulator writes the
same file with the same value (read as a format, level 2), and `log config
--status` in the guest reports `System mode = INFO STREAM_LIVE
PRIVATE_DATA`.

### 4.2 What does not work (black-box on the Mac)

- `log config --mode "level:off"` in the guest fails: "log: Simulator
  unable to set system mode" (exit 64). No file changes.
- Disabling `com.apple.diagnosticd` (§3.1) and removing the filter plist:
  the guest still reports `STREAM_LIVE`, and every process looks the
  service up again and again (8,443 failed lookups of
  `com.apple.diagnosticd` in `launchd.log` within 40 s, from dasd,
  SpringBoard, cfprefsd, …). That is more work, not less, so diagnosticd
  stays enabled in every profile.

### 4.3 What breaks the boot: `OS_ACTIVITY_MODE=disable`

`OS_ACTIVITY_MODE=disable` is a publicly documented environment variable
(the usual Xcode scheme variable to silence os_log). A Ycode boot with it in
`Bootstrap.Child` (every launchd child gets it), together with §3, did not
reach the home screen: SpringBoard aborted 17 times with an uncaught
`NSInvalidArgumentException` ("-[__NSSetM addObject:]: object cannot be
nil"), 369 fatal guest conditions against 40 without it (level 3, run
`all1`, 2026-10-17). Ycode does not use it.

### 4.4 The mechanism: per-subsystem level off

`xcrun simctl spawn <dev> log config --subsystem <S> --mode "level:off"`
works in the simulator (exit 0) and writes
`DEV/data/Library/Preferences/Logging/Subsystems/<S>.plist` (binary plist):

    { "DEFAULT-OPTIONS" = { "Level" = { "Enable" = "off"; "Persist" = "off"; }; }; }

This is the documented per-subsystem configuration of log(1); the same
directory already holds Ycode harness files that raise levels.

The busiest subsystems were taken from a Mac simulator boot of the same
runtime (`log show --last 10m --info --style ndjson` right after boot,
160 k messages; level 3). The 40 busiest named subsystems, without
`com.apple.runtime-issues` (Xcode's runtime-issue reports), carried 68 % of
the messages; 15 % had no subsystem. The list is in
`LeanBootProfile.loggingOffSubsystems`.

**Ycode.** With `logging` or `all`, `ycode-simd` writes the level-off file
for each listed subsystem that has no file yet, and records the names in
`DEV/ycode-lean-logging.txt`. A boot without the profile removes the
recorded files that still hold exactly that content. A file someone else
wrote is never changed.

Not established: whether level off stops a process from sending the
messages to diagnosticd's system-mode client. On the Mac, an active
`log stream --level debug` client still received messages of a subsystem
after it was set to level off (processes already running, a client that
asks for debug). §7 measures the effect under Ycode.

What a developer loses: the listed Apple subsystems' messages in `log
show`/`log stream` in the guest. App subsystems are not touched.

## 5. The golden device

### 5.1 Black-box: `xcrun simctl clone`

On the Mac, `xcrun simctl clone <source> <name>` (source shut down):

- copies every file of the source's `data` directory with the same size
  and modification time (9,233 of 9,234 files compared; the one missing
  was a transient token file);
- writes a new `device.plist` with a new UDID and name (and without
  `lastUsedAt`);
- does not copy TMP (no `disabled.plist` or `launchd.log` for the clone);
- leaves files in `data` that mention the old UDID unchanged; the
  bootstrap plist is rewritten at the clone's boot.

The clone boots; `com.apple.migration.plist` came with the data, so the
first-boot migration chain (`first-boot.md`) does not run again.

### 5.2 Ycode

`YCODE_DEVICE_TEMPLATE=<golden DEV>`: when DEV has no `data` directory
yet, `ycode-simd` copies `<golden DEV>/data` to `DEV/data` before
preparing the device (`cp -a --reflink=auto` on Linux: modes and times
kept, shared blocks where the file system allows). Ycode derives the UDID
from the DEV path (`DeviceLayout.stableUDID`), so the copy gets a new
identity, as with `simctl clone`. A DEV that already has `data` is never
overwritten.

A golden device records its runtime build and device type
(`DEV/ycode-runtime`, `DEV/ycode-device-type`; `ipad.md` §9.2): another
type is refused, another build warned about. Making a golden device, once per runtime build: boot a new DEV to the home
screen (the first boot pays the data migration, about 10 minutes on the
Thor), let it end, and keep that DEV unchanged as the template. Every
benchmark run already works this way (the harness copies one first-booted
device for each run, and each copy boots with its own UDID).

## 6. dyld launch closures

The question was whether the guest's dyld tries to persist launch
closures and fails. Black-box on the Mac: after a boot, a second boot and
an app launch, the device directory has no file or directory whose name
contains `dyld` and no `*.closure` file; the simulator's dyld uses the
runtime's shared cache (`DYLD_SHARED_CACHE_DIR`,
`RR/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64*`,
present on the Thor). The Ycode golden device has none either. There is no
closure store for Ycode to provide.

## 7. Measurements

Thor harness (`SX/bin/bench.sh`), CPU governor `performance`, device in RAM
(`BENCH_TMPFS=1`), fixed 700 s runs (`BENCH_NOKILL=1 BENCH_SECS=700`),
2026-10-17 01:48–04:15, interleaved with other agents' boots. Base: main
line + speed-int 28ef252 (select, SCDynamicStore host, diagnosticd host
socket off); the cooperative-workqueue change is not in it. Same binary for
each comparison, profile switched by `YCODE_LEAN_BOOT` only. `home_s` has a
5 s granularity; traps and process images are per 700 s run.

| Profile | Runs | home_s | Mean | Guest traps (M) | Process images | guest_fatal |
|---|---|---|---|---|---|---|
| off | off1–off4 | 455, 520, 505, 560 | 510 | 22.7–26.3 (mean 24.5) | 1100–1165 | 39–41 |
| `daemons` | d1–d5, msd1 | 275, 290, 260, 325, 300, 260 | 285 (−44 %) | 12.3–13.7 (mean 12.8) | 576–595 | 1–3 |
| `all` (daemons + logging) | a2, a3, msa1 | 260, 275, 260 | 265 | 10.6–13.2 (mean 11.7) | 592–694 | 3–10 |

- **Daemons.** The boot reaches the home screen 225 s (44 %) sooner, and
  the guest makes half the traps. The guest crash count drops from about
  40 to 1–3: the 40 were intelligencetasksd's restart loop; the rest are
  replicatord aborts that the base has too.
- **Logging (on top of daemons).** diagnosticd's traps fall from
  1.66–1.69 M to 0.92–1.14 M (−40 %) and Mach messages per run from
  about 500 k to about 400 k (`YCODE_DEBUG_MACH_STATS=1`, msd1/msa1;
  runningboardd → diagnosticd 42.9 k → 27.2 k, SpringBoard 25.2 k →
  14.9 k). Against the paired `daemons` runs on the same binary (d4, d5,
  msd1: 325, 300, 260) the home time is 265 against 295, within the noise
  of n = 3. So level off does reduce the stream to diagnosticd (§4.4,
  answered for Ycode), but the boot-time effect is small.
- **Home screen and apps.** Every `daemons` and `all` run reached the
  wallpapered home screen (frames checked: dock icons, Settings, Safari).
  With `daemons`, the probe app (`--install-app YcodeProbe.app --launch
  dev.ycode.probe`, run dapp1) installed and launched; it printed its
  device information (UIKit `iOS 27.1`) and ran until the end of the run.
- `OS_ACTIVITY_MODE=disable` (§4.3): home screen not reached.
- **The Mac.** The same 23 labels on the Mac's simulator (same runtime
  and device type) do not change the time to the home screen there
  (subsequent boot: full 21.4 s, lean 24.3 s, n = 4 each). Ycode is 23.8
  times slower than the Mac without the profile and 11.7 times with it.
  Of the restart loops in §1.2, intelligencetasksd and mlhostd also loop
  on the Mac; proactiveeventtrackerd, facetimemessagestored, pairedsyncd
  and searchd loop only on Ycode. `parity-ladder.md` has the method, the
  numbers and the ladder that re-enables the services one at a time.

## 8. Recommendation

Boot every service (no profile): that is parity with the Mac, whose
simulator boots every service, and since the scheduling work
(`scheduling-policy.md` §4.2, §7.5) and the service fixes
(`service-fidelity.md`) it costs Ycode about 1 s to the home screen (§9).
`YCODE_LEAN_BOOT=daemons` (or `all`) stays as a development option for
boots that do not need Spotlight, Siri, suggestions, HomeKit or a paired
watch and want less guest work after the home screen (for example a
profiling run that should not see those services); it removes services
that an app under development may use, and `YCODE_LEAN_BOOT_KEEP` brings
any of them back. Benchmarks against the Mac are full boots
(`parity-ladder.md`).

## 9. Full boot as the IDE default (agent SVC-FULL, 2026-10-27)

From 2026-10-17 to 2026-10-27 IDE runs used `YCODE_LEAN_BOOT=daemons` by
default (Settings ▸ Simulators ▸ Lean boot, on), because a full boot then
took 455–560 s to the home screen against 260–325 s lean (§7). On the
main line of 2026-10-27 (5f74ef9) the difference is about 1 s:

Thor, `SX/bin/timed.sh` around the series (no other `ycode-simd`, load
under 4 at the start), one copy of the golden device at its own path,
booted once before the series, cold boots with the default switches
(start hold, boot priority), arms alternated each round, home from the
home watch (`YCODE_HOME_WATCH`), 5 s held after home (series
`svcfull` T, 13:30–13:39):

| Arm | n | home_s each | median | mean ± sd | range | guest fatal by home + 5 s |
|---|---|---|---|---|---|---|
| full (no profile) | 6 | 32.29, 29.02, 30.89, 31.29, 29.08, 29.34 | **30.12** | 30.32 ± 1.37 | 29.02–32.29 | 1–3 (intelligencetasksd) |
| lean (`daemons`, 23 jobs disabled) | 6 | 27.60, 27.89, 31.43, 30.30, 30.88, 27.56 | **29.09** | 29.28 ± 1.79 | 27.56–31.43 | 0 |

- Full against lean: +1.0 s by the median (+3.5 %), +1.0 s by the mean,
  less than one standard deviation of either arm. The kernel lock was held
  5.2–6.6 s per full boot against 4.6–5.1 s lean (exit summaries).
- Against the Mac (`parity-ladder.md` §3.4, subsequent boot, r3): full
  30.3 s against 21.4 s (1.42 ×), lean 29.3 s against 24.3 s (1.21 ×).
  Ycode's full ÷ lean is 1.04; the Mac's is 0.88 in r3 and 1.02 pooled
  over r1–r3 (by the means), so the shape test of `parity-ladder.md`
  §4.1 (≤ the Mac's + 0.10) passes against the pooled Mac numbers and
  misses by 0.06 against r3 alone, within the Mac's own spread.
- The behaviour of the 23 services in a full boot, against the Mac with
  the same device data: `parity-ladder.md` §4.8.
- Measurement conditions: cold boots of one copy of the golden device
  that had already booted once at its own path, with the machine to
  itself and the home screen from the home watch. The 75–80 s timed boots
  in `service-fidelity.md` §11 and §14 are two-boot A/B pairs that only
  compare a change with its base (§11 detects the home screen on 5 s
  screenshots); compare boot times within one series, not across series.
  A copy's first boot at a new path is slower (57 s, run `f700q`,
  `parity-ladder.md` §4.8).

So the IDE's default is now a full boot (`specs/ide/run.md`): Lean boot is
a checkbox that is off by default, and a stored `true` from the old
default is not carried over. Warm-boot snapshots of a lean boot and of a
full boot are never shared: the launcher's fingerprint includes the
`YCODE_LEAN_BOOT*` variables (`run.md` §Warm boot, item 2).

## Evidence

| Claim | Level |
|---|---|
| Job counts and launch keys (§1.1, §3.2) | 2 (RR job plists read as data, `plistlib`) |
| Start reasons, `nanoregistrylaunchd` enabling the Nano jobs (§1.1) | 3 (`TMP/launchd.log` of Ycode boots, read as a format) |
| Per-process traps and restart counts (§1.2) | 3 (Ycode exit summaries, three 900 s boots) |
| `launchctl disable` writes `TMP/disabled.plist`, label → true; survives shutdown; disabled jobs not loaded; hand-written file honored; lookups fail with error 3; home screen and app launch still work (§3.1) | 3 (`xcrun simctl` on a throwaway device, file diffs, `launchctl print-disabled`, `launchctl list`, screenshots) |
| `launchctl disable`/`enable` semantics | 1 (launchctl(1)) |
| `Disabled` plist key | 1 (launchd.plist(5)); 2 (RR plists) |
| `log config --mode` refused in the simulator; `STREAM_LIVE` status; lookup storm without diagnosticd (§4.2) | 3 (`xcrun simctl spawn … log config`, `launchd.log`) |
| filter plist value on the Mac (§4.1) | 2 (file read as a format) |
| `OS_ACTIVITY_MODE=disable` (§4.3): the variable | 1 (public developer documentation and forums) |
| SpringBoard abort loop with it | 3 (Ycode run `all1`) |
| `log config --subsystem … level:off` file and format; busiest subsystems; stream client still served (§4.4) | 3 (`xcrun simctl spawn … log config`, `log show`, `log stream`, files read as formats) |
| `simctl clone` copies data with times, new identity, no TMP (§5.1) | 3 (`xcrun simctl clone`, tree diff) |
| No closure files in a device (§6) | 3 (Mac device tree after boot and app launch) |
| Boot times, trap and image counts, crash counts, Mach traffic, app install/launch (§7) | 3 (Ycode boots on the Thor, exit summaries, `YCODE_DEBUG_MACH_STATS`) |
| Full against lean on the 2026-10-27 main line (§9) | 3 (Thor, `ide-remote/svcfull` series T: run logs' home-watch lines and exit summaries) |
| The IDE default and the settings migration (§9) | Ycode design (`specs/ide/run.md`) |
