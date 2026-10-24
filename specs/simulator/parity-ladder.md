# Spec: boot parity with the Mac's simulator, and the service ladder

Status: **method and first measurements** (agent Lb, 2026-10-17). It makes
the lean-boot comparison (`lean-boot.md`) scientific: the same 23-label
lean profile is measured on Apple's simulator on the Mac, the two
platforms are compared with one end point, and a ladder re-enables the 23
services one at a time on both platforms to find which services cost
Ycode more than they cost the Mac.

Facts come from black-box runs of the Mac's simulator through `xcrun
simctl` and `ps` on throwaway devices (level 3), files the simulator
writes, read as formats (level 2), and Ycode boots on the Thor (level 3).
No Xcode or runtime binary was opened, disassembled or decompiled.

Terms as in `lean-boot.md`: **full** (no profile), **lean** (the 23 labels
of `LeanBootProfile.defaultDisabledLabels` disabled through
`TMP/disabled.plist`; Ycode `YCODE_LEAN_BOOT=daemons`), **lean-log** (lean
plus the 40 level-off log subsystems; Ycode `all`). **First boot**: the
first boot of a new device (it runs the data migration, `first-boot.md`).
**Subsequent boot**: a later boot of a device whose data was migrated.

## 1. End point and boot kinds

**home_s** is the same on both platforms: seconds from the start of the
boot to the first screenshot of the main display whose mean brightness,
after conversion to grey and scaling to 70 × 102 pixels, is above 60. The
boot logo is about 3, the wallpapered home screen about 130. On Ycode the
harness (`SX/bin/homewatch.py`) reads frames that `ycode-simd
--screenshot-at` writes every 5 s from 20 s on, so Ycode's home_s is
rounded up to a multiple of 5 s. On the Mac the tool polls `xcrun simctl
io <dev> screenshot --display=primary` about once a second (each call
takes 0.3–1 s). On the iPhone Duo type `primary` is the 1398 × 2034 LCD,
the display Ycode renders (`device-capabilities.md`). Frames that met the
threshold were checked by eye: wallpaper, status bar, Settings and Safari
icons.

The Mac also gives **bootstatus_s**, when `xcrun simctl bootstatus <dev>
-b` returns. It is not used for parity: on subsequent boots it returns
5–25 s before the home screen.

**Boot start**: Mac, the call of `simctl bootstatus -b` (which boots the
device); Ycode, the start of `ycode-simd`.

**Kinds of boot.** A Ycode harness run boots a copy of a golden device that
was first-booted once (`lean-boot.md` §5), with a new TMP: it is a
**subsequent boot**. The Mac's equivalent is the second boot of a device
(shutdown, boot). The Mac's first boot is measured too; Ycode's first boot
(data migration, about 10.5 min on the 2026-10-13 build, `first-boot.md`)
was not measured on the current build and is not part of the ladder.

## 2. Method on the Mac (reproducible)

Tool: `tools/mac-sim-lean-boot.py` (summary: `tools/mac-sim-lean-summary.py`).
It uses only `xcrun simctl`, `ps`, and files the simulator writes.

1. Device: `simctl create ycode-test-<tag>-<mode>-<n>
   com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
   com.apple.CoreSimulator.SimRuntime.iOS-27-1` (iOS 27.1, 24A94401: the
   runtime and device type of the Thor's golden device). A new device for
   every run; deleted, with its TMP, at the end.
2. Profile, written before the first boot while the device is shut down:
   **lean** writes `TMP/disabled.plist` (XML plist, label → `true`) with the
   23 labels, read from `LeanBoot.swift` so both platforms use one list
   (`lean-boot.md` §3.1: the Mac honours a hand-written file). **lean-log**
   also writes the 40 level-off files into
   `DEV/data/Library/Preferences/Logging/Subsystems/` (`lean-boot.md` §4.4).
   `--keep` takes labels off the list (ladder step base+k); `--enable`
   disables only the given labels (all-but-one). Every lean run was
   checked: no program of a disabled label appears in `launchd.log`.
3. Boot 1 (first boot), then `simctl shutdown`, 3 s pause, boot 2 (second
   boot). For each boot:
   - home_s and bootstatus_s (§1);
   - **CPU**: `ps -axo pid,ppid,time,command` every 5 s; the device's
     processes are the descendants of the `launchd_sim` whose arguments
     name the UDID. Per pid the last cumulative CPU time seen counts, so a
     process that exits between samples loses at most 5 s of work. A pid
     is named after the program it runs last (`xpcproxy_sim` execs the
     daemon under the same pid; an exited, unreaped process shows as
     `(name)` cut to 16 characters and keeps its earlier name). The window
     is the first 120 s (`--sample-at`); `--second-sample-at 700` makes the
     second boot's window as long as a Ycode harness run;
   - **procs**: the device's processes alive at the end of the window;
     **seen**: distinct pids in the window;
   - **spawns**: "Successfully spawned `<program>`[pid]" lines in
     `TMP/launchd.log` at the end of the window, per program;
   - **crashes**: `.ips` reports in `~/Library/Logs/DiagnosticReports`
     (and `Retired/`) that contain the UDID (the `coalitionName` field is
     `com.apple.CoreSimulator.SimDevice.<UDID>`) and whose header
     `timestamp` lies in the window;
   - **contention**: other booted simulator devices, and the cores used by
     all other processes during the window (difference of the sum of
     cumulative `ps` CPU times, minus the device's own).
4. Modes are interleaved per round (full, lean, lean-log, full, …) so
   that slow drifts in host load hit all modes alike.

Commands (campaign r3 of this spec):

    python3 -I tools/mac-sim-lean-boot.py --order full,lean,lean-log --runs 4 \
        --prefix ycode-test-L3 --out OUT
    python3 -I tools/mac-sim-lean-summary.py --diff ycode-test-L3-full ycode-test-L3-lean OUT

Host: arm64 Mac (14 cores, 36 GB), macOS 27.2, shared with other agents.
During r3 3–4 other simulator devices were booted and other processes used
4.6 cores on average (0.7–9.7); load is reported per boot and is the main
source of noise. Campaigns r1 (2–3 runs per mode, earlier agent) and r2 (1–2 runs,
heavy and unrecorded contention) gave the same picture with more spread
(§3.1, pooled column).

## 3. Results

### 3.1 The Mac (campaign r3, n = 4 per mode, 2026-10-17)

| Mode | Boot | home_s each | Mean ± sd | Pooled r1–r3 mean (median, n) | bootstatus_s | Procs alive / seen (120 s) | Device CPU s (120 s) | Spawns | Crash reports |
|---|---|---|---|---|---|---|---|---|---|
| full | first | 39.8, 38.1, 49.1, 47.0 | 43.5 ± 5.4 | 47.4 (45.1, 9) | 31.4 | 242 / 307 | 582 | 321 | 2 |
| lean | first | 46.2, 42.5, 41.4, 43.0 | 43.3 ± 2.1 | 44.0 (43.6, 8) | 31.4 | 227 / 311 | 578 | 325 | 7 |
| lean-log | first | 34.0, 37.3, 57.5, 39.6 | 42.1 ± 10.5 | 49.8 (39.6, 7) | 28.9 | 223 / 306 | 589 | 320 | 9 |
| full | second | 21.9, 20.7, 18.8, 24.3 | 21.4 ± 2.3 | 26.2 (22.3, 9) | 10.3 | 223 / 276 | 500 | 281 | 10 |
| lean | second | 23.3, 26.5, 27.0, 20.4 | 24.3 ± 3.1 | 25.8 (23.1, 8) | 19.7 | 183 / 216 | 353 | 218 | 7 |
| lean-log | second | 12.0, 19.3, 23.9, 22.3 | 19.4 ± 5.3 | 19.1 (19.3, 7) | 9.2 | 188 / 216 | 365 | 218 | 3 |

- **On the Mac the lean profile does not make the boot faster.** The
  home_s differences (first boot −0.2 s, second boot +2.9 s) are inside one
  standard deviation. lean-log's −2 s on the second boot is also inside
  the noise.
- On the second boot lean starts 63 fewer programs in the first 120 s
  (281 → 218, −23 %) and the device uses 147 s less CPU (500 → 353, −29 %;
  −80 s, −16 %, without the one outlier boot lean-3, which had 9.7 other
  cores busy). On the first boot spawns and CPU do not change: the data
  migration and the wallpaper extensions dominate it, and most of the 23
  jobs have not started yet.
- Crash reports occur in every mode at a similar rate:
  `AppIntentsLiveEntityService` (1–2 per boot), `SettingsSearchReindexService`,
  `assistantd`, `routined`, now and then `PosterBoard`. None is a restart
  loop. None of the 23 programs left a crash report in 120 s.
- The largest and most variable CPU consumer is the wallpaper (poster)
  extensions: 50–264 s per 120 s window, 30–40 % of the device's CPU, in
  every mode.

### 3.2 What accounts for the Mac's lean-vs-full difference

From `mac-sim-lean-summary.py --diff` (r3, mean per boot, CPU s in the
120 s window):

| | First boot | Second boot |
|---|---|---|
| All device processes | +4.7 | +146.8 (+80 without the outlier) |
| The 23 programs themselves | +25.6 | +20.2 |
| Largest of the 23 | intelligenceplatformd 7.8, siriactionsd 3.3, homed 3.2, photoanalysisd 2.2, searchd 1.8, siriinferenced 1.5, suggestd 1.3 | siriactionsd 3.6, homed 2.7, searchd 2.4, siriinferenced 1.9, photoanalysisd 1.8, spotlightknowledged.updater 1.6, suggestd 1.2 |
| Processes they cause (absent or smaller in lean) | BackgroundShortcutRunner 3.3, ShortcutsTopHitsExtension 2.4 | diagnosticd +11.4 (log traffic of the extra processes), amsengagementd +10.2, BackgroundShortcutRunner 9.3, intelligenceflowd 4.2, intelligencecontextd 2.7, intents_helper 2.3, nsurlsessiond 3.3 |
| Rest | poster extensions −21 (noise) | poster and widget extensions, SpringBoard, backboardd: +40, within their run-to-run spread |

Per label, pooled over all 18 full boots of r1–r3 (9 first, 9 second;
first 120 s): the boots in which launchd started the program, mean CPU s,
mean starts. Ycode: starts in a 700 s full run (off1–off4).

| Label | Mac: started in | Mac CPU s | Mac starts | Ycode starts | Group (§4.2) |
|---|---|---|---|---|---|
| facetimemessagestored | 0/18 | 0 | 0 | 56–60 | A |
| intelligencetasksd | 0/18 | 0 | 0 | 16 (crashes) | A |
| knowledgeconstructiond | 0/18 | 0 | 0 | 1 | A |
| proactiveeventtrackerd | 0/18 | 0 | 0 | 57–61 | A |
| sensorkitd | 0/18 | 0 | 0 | 1 | A |
| spotlightknowledged | 0/18 | 0 | 0 | 1 | A |
| mlhostd | 6/18 | 0.00 | 1.1 | 18–34 | A |
| pairedsyncd | 3/18 | 0.06 | 0.2 | 59–62 | A |
| mediaanalysisd | 7/18 | 0.21 | 0.4 | 1 | A |
| nanoregistrylaunchd | 12/18 | 0.22 | 0.7 | 1 | A (enables pairedsyncd) |
| parsec-fbf | 9/18 | 0.10 | 0.5 | 0–1 | B |
| parsecd | 16/18 | 0.29 | 0.9 | 1 | B |
| textunderstandingd | 17/18 | 0.45 | 0.9 | 1 | B |
| accessibility.axassetsd | 18/18 | 0.53 | 1.0 | 1 | B |
| siriknowledged | 18/18 | 0.66 | 1.0 | 1 | B |
| spotlightknowledged.updater | 17/18 | 0.72 | 0.9 | 1 | B |
| suggestd | 18/18 | 0.93 | 1.0 | 1 | B |
| siriinferenced | 18/18 | 0.94 | 1.0 | 1 | B |
| searchd | 18/18 | 1.39 | 1.0 | 41–49 | B |
| photoanalysisd | 18/18 | 1.79 | 1.0 | 1 | B |
| homed | 18/18 | 3.03 | 1.0 | 1 | B |
| siriactionsd | 18/18 | 3.31 | 1.0 | 1 | B |
| intelligenceplatformd | 11/18 | 4.05 | 0.6 | 1 | B |

(r1 sampled CPU once at 120 s, so its CPU figures miss programs that had
exited; r2–r3 sample every 5 s.)

So on the Mac the 23 services are cheap (about 20–26 CPU s of 500–580, 4 %)
and off the path to the home screen. Each one starts at most once in the
first two minutes, except mlhostd (up to 5 starts on some second boots).
On Ycode six of them start 16–62 times in 700 s.

### 3.3 The same wall time as a Ycode run (700 s)

A Ycode harness run lasts 700 s, so its restart counts cover 700 s of
wall time. Campaigns r4 and r5 (`--second-sample-at 700`, second boot;
two full devices, one lean) give the Mac's counts over the same window
(launchd spawns in `TMP/launchd.log`; Ycode: the same lines in the guest's
`launchd.log`, runs off1–off4 and d1–d5, msd1):

| Window 700 s, subsequent boot | Mac full | Mac lean | Ycode full | Ycode lean |
|---|---|---|---|---|
| Programs started (all) | 357, 385 | 244 | 548–580 | 286–295 |
| Ycode ÷ Mac | | | 1.53 | 1.20 |
| intelligencetasksd starts (each one crashes) | 15, 15 (every ~10 s from 363 s and 428 s on; a crash report each) | 0 | 16 (about 40 fatal guest conditions) | 0 |
| mlhostd starts (exit 0 after ~0.2 s) | 52, 55 | 0 | 18–34 | 0 |
| proactiveeventtrackerd starts | 0, 0 | 0 | 57–61 | 0 |
| facetimemessagestored starts | 0, 0 | 0 | 56–60 | 0 |
| pairedsyncd starts | 1, 1 | 0 | 59–62 | 0 |
| searchd starts | 1, 1 | 0 | 41–49 | 0 |
| Device CPU s in 700 s | 669, 678 | 464 | — | — |

- **intelligencetasksd's crash loop and mlhostd's short restarts happen on
  the Mac too**, from 6–7 minutes after the boot. Ycode reproduces them
  (same count for intelligencetasksd, fewer for mlhostd). They are Mac
  behaviour, not Ycode bugs; Ycode's 40 guest fatal conditions in a full
  run are this loop.
- **Four restart loops are Ycode's own:** proactiveeventtrackerd,
  facetimemessagestored, pairedsyncd and searchd start 41–62 times on
  Ycode and at most once on the Mac. They account for the whole excess of
  Ycode's full boot in program starts (Ycode 548–580 against Mac 357–385:
  these four give +214). With the lean profile Ycode starts 1.2 × as many
  programs as the Mac, spread over many programs (datamigrator 6 against
  2, eligibilityd 4 against 1, wallpaper extensions).
- In the 700 s window the full boot also runs the paired-watch companion
  family on both platforms (companionappd, addressbooksyncd,
  NPKCompanionAgent, bulletindistributord: about 32 CPU s on the Mac),
  enabled by nanoregistrylaunchd, and BackgroundShortcutRunner (16 s).
- Two full devices and one lean device: the counts are a behaviour
  reference, not a timing.

### 3.4 Mac against Ycode

Ycode numbers: `lean-boot.md` §7 (Thor harness, same binary within each
comparison, 700 s runs, n = 4 full, 6 lean, 3 lean-log); work counts
from the runs' exit summaries. Mac numbers: §3.1, campaign r3.

| | Mac full | Mac lean | Ycode full | Ycode lean | Ycode ÷ Mac, full | Ycode ÷ Mac, lean |
|---|---|---|---|---|---|---|
| home_s, subsequent boot (mean ± sd) | 21.4 ± 2.3 | 24.3 ± 3.1 | 510 ± 43 | 285 ± 25 | **23.8** | **11.7** |
| home_s, lean-log / `all` | — | 19.4 ± 5.3 | — | 265 ± 9 | — | 13.7 |
| home_s, first boot | 43.5 ± 5.4 | 43.3 ± 2.1 | not measured (≈ 640 on the 2026-10-13 build) | not measured | (≈ 15) | — |
| full ÷ lean | 0.88 | | 1.79 | | | |
| Programs started in 700 s (§3.3) | 371 (357, 385) | 244 | 567 (548–580) | 292 (286–295) | 1.53 | 1.20 |
| Process images in 700 s (Ycode: `xpcproxy_sim` and the program it execs count separately) | — | — | 1100–1165 | 576–595 | | |
| Restart loops in 700 s | intelligencetasksd, mlhostd | none | the same two, plus proactiveeventtrackerd, facetimemessagestored, pairedsyncd, searchd | none | | |

**Reading.** The 23 services cost the Mac nothing on the path to the home
screen, but they cost Ycode 225 s (44 % of its full boot). Ycode is 11.7
times slower than the Mac with the lean profile and 23.8 times slower
without it. So about half of Ycode's full-boot gap to the Mac comes from
these 23 services, and the rest is the general speed of Ycode
(`stage6-contract.md`, the speed work). Part of that half is work that the
Mac does not do at all in the same wall time (§3.3: four restart loops),
and part is services that do far more work on Ycode than on the Mac:
suggestd, parsecd and axassetsd make 18.7 %, 9.4 % and 7.6 % of Ycode's
guest traps (`lean-boot.md` §1.2) but use under 1 CPU s each of the Mac's
500–580 in the first two minutes (§3.2).

## 4. Parity target and the ladder

### 4.1 Targets and tolerance

1. **Speed parity (the end goal):** Ycode lean subsequent-boot home_s ≤
   1.25 × Mac lean subsequent-boot home_s, both measured by this spec's
   method, n ≥ 4 each. The Mac reference is the mean over interleaved runs
   with no other simulator booted (contention under 1 core). Today: 285 s
   against 24.3 s, ratio 11.7. The 25 % covers the Mac's own run-to-run
   spread (sd 9–13 % of the mean under load) and Ycode's 5 s frame grid.
2. **Shape parity (what the ladder tests, reachable before 1):** each
   service costs Ycode the same *fraction* of the boot that it costs the
   Mac. With base = lean, for ladder step k:

       δY(k) = (homeY(base+k) − homeY(base+k−1)) / homeY(base)
       δM(k) = (homeM(base+k) − homeM(base+k−1)) / homeM(base)

   The step's time test passes when **δY(k) − δM(k) ≤ τ**, with
   τ = max(0.05, 2·SE), SE the standard error of δY(k) − δM(k) from the
   runs (with n = 3 Ycode, sd ≈ 9 %, and n = 4 Mac, sd ≈ 12 % as in r3,
   SE ≈ 0.11, so τ ≈ 0.22 per step; one slow Mac boot widens it a lot,
   §4.4; more runs make τ smaller). For the whole ladder:
   homeY(full)/homeY(lean) ≤ homeM(full)/homeM(lean) + 0.10. Today 1.79
   against 0.88: it fails, by 0.81.
3. **Behaviour (the second half of every step, no tolerance on time):**
   over the same wall-time window (700 s, the Ycode harness run; Mac
   `--second-sample-at 700`), for the step's program:
   - **starts**: Ycode's launchd spawn count ≤ the Mac's + 2; a program the
     Mac starts, Ycode starts too;
   - **no crash loop**: no abnormal exit (signal other than SIGKILL from
     the harness, or a fatal guest condition) that the Mac does not show as
     a crash report for that program;
   - **idle and exit**: if the Mac's process is alive at the end of the
     window, so is Ycode's; if it exits on the Mac, Ycode's exits with the
     same status (`launchd.log` "exited" lines on both).

   Work counts are a cross-check, not a test: Ycode's added program starts
   per step (guest `launchd.log`) should be close to the Mac's.

   Applied to today's full boots (§3.3): intelligencetasksd (16 against 15)
   and mlhostd (18–34 against 52–55) pass the start test; proactiveeventtrackerd,
   facetimemessagestored, pairedsyncd and searchd fail it.

A service **passes** its step when the time test and all behaviour tests
pass. A failing service is a Ycode bug to find (a missing or wrong host
answer that makes the guest retry, crash or loop), not a reason to leave
the service off by default.

### 4.2 Order

The order is in `tools/parity-ladder-order.txt`; it comes from the Mac
measurements of §3.2.

- **Group A (steps 1–10): services the Mac starts in fewer than half of
  its boots** (§3.2 table), plus nanoregistrylaunchd, which enables
  pairedsyncd (`lean-boot.md` §1.1) and so must come before it:
  knowledgeconstructiond, sensorkitd, spotlightknowledged, mediaanalysisd,
  nanoregistrylaunchd, intelligencetasksd, mlhostd, proactiveeventtrackerd,
  facetimemessagestored, pairedsyncd. Their Mac cost is zero within
  noise, so their expected Ycode delta is zero too, and any measured
  Ycode delta is Ycode's own. Inside the group the quiet ones come first
  (ties broken by Ycode's restart count), so the early steps check the
  method before the loops. Two of them loop on the Mac as well, after
  about 7 minutes (§3.3: intelligencetasksd 15 crashes, mlhostd 52–55 short
  runs in 700 s), at well under 1 CPU s; the behaviour test (§4.1 item 3)
  expects Ycode to match those counts. Three loop only on Ycode
  (proactiveeventtrackerd 57–61, facetimemessagestored 56–60, pairedsyncd
  59–62 starts in 700 s, against 0, 0 and 1).
- **Group B (steps 11–23): services the Mac starts in (almost) every
  boot**, by rising Mac CPU cost: parsec-fbf, parsecd, textunderstandingd,
  accessibility.axassetsd, siriknowledged, spotlightknowledged.updater,
  suggestd, siriinferenced, searchd, photoanalysisd, homed, siriactionsd,
  intelligenceplatformd. Each step adds a little more expected cost, so a
  step with a large Ycode delta stands out from its neighbours.

Cumulative steps can hide interactions (a service started by another).
**Leave-one-out** (all 23 enabled except one; `mac-only`, `ycode-only`)
measures each service's own cost against the full boot, for the services
whose step fails and to check the cumulative result.

### 4.3 Running it

`tools/parity-ladder.sh` (the Ycode side needs `YCODE_THOR` and
`YCODE_SX`; machine names stay out of the repository):

    tools/parity-ladder.sh order                 # the 23 steps
    tools/parity-ladder.sh mac-pair 10 4 OUT     # Mac: 4 rounds of (base, base+10), interleaved
    tools/parity-ladder.sh mac 10 4 OUT          # Mac base+10 only, 4 new devices
    tools/parity-ladder.sh mac-only com.apple.homed 4 OUT
    tools/parity-ladder.sh mac-summary --diff ycode-test-L-ladder10-lean ycode-test-L-ladder0-lean OUT
    tools/parity-ladder.sh ycode 10 lad10 L2     # Ycode base+10, one harness run
    tools/parity-ladder.sh ycode-only com.apple.homed lo-homed-1 L2
    tools/parity-ladder.sh ycode-result lad10 L2 # home_s, guest_fatal, spawns of the 23

Ycode runs use `YCODE_LEAN_BOOT=daemons`, `YCODE_LEAN_BOOT_KEEP` = the
labels enabled again, and the `lean-boot.md` §7 harness settings
(`BENCH_TMPFS=1 BENCH_NOKILL=1 BENCH_SECS=700`). `ycode-result` reads
the spawn counts from this boot's TMP: the golden device keeps older TMPs
under other UDIDs, so the UDID `ycode-simd` prints is used.

Protocol: the base (step 0) and every step are measured n ≥ 3 on Ycode
and n ≥ 4 on the Mac, on one Ycode binary, interleaved with the base on
each platform. A full ladder costs 23 × 3 Ycode runs plus base runs
(about 15 h of boot-slot time, 5 h of wall time with all 3 slots) and
23 × 4 pairs of Mac devices (about 5.5 min per device, 17 h).

### 4.4 First step measured (smoke test, 2026-10-17)

One Ycode run of step 10 (all of Group A enabled again, binary of
`lean-boot.md` §7 L2, 2026-10-17 18:47), and four interleaved Mac pairs
of base and step 10 (`parity-ladder.sh mac-pair 10 4`, 20:29–21:05).

Mac (home_s, s; CPU and starts in the first 120 s):

| Mac | Boot | home_s each | Mean ± sd (median) | Device CPU s | Group A programs' CPU s | Starts |
|---|---|---|---|---|---|---|
| base | first | 35.6, 43.5, 41.6, 46.6 | 41.8 ± 4.6 (42.6) | 596 | 0 | 322 |
| base+10 | first | 41.3, 56.4, 57.1, 60.6 | 53.9 ± 8.6 (56.8) | 532 | 0.7 | 304 |
| base | second | 21.8, 23.0, 27.3, 29.6 | 25.4 ± 3.7 (25.2) | 336 | 0 | 212 |
| base+10 | second | 13.2, 78.3, 25.6, 30.2 | 36.8 ± 28.6 (27.9) | 306 | 0.9 | 220 |

In those 120 s the Mac started mediaanalysisd and nanoregistrylaunchd
once, pairedsyncd at most once and mlhostd 0–6 times, and none of the
other six. The 78.3 s boot ran while other processes used 7.6 cores.

| Ycode run | home_s | guest_fatal | Process images | Guest traps | Group A spawns |
|---|---|---|---|---|---|
| base (d4, d5, msd1) | 325, 300, 260 | 1–3 | 576–590 | 12.3–12.6 M | 0 |
| base+10 (lad10) | 375 | 46 | 1201 | 18.6 M | intelligencetasksd 16, mlhostd 49, proactiveeventtrackerd 61, facetimemessagestored 59, pairedsyncd 60, others 1 |
| full (off1–off4) | 455–560 | 42–46 | 1100–1165 | 22.7–26.3 M | as base+10, plus searchd 41–49 |

Ycode: the 13 labels still disabled were written (`lean boot: 13 jobs
disabled`), and the guest's `launchd.log` shows the expected programs
started again, so `YCODE_LEAN_BOOT_KEEP` reaches the guest through the
harness.

Applying §4.1 to step 10 (subsequent boot):

- **Time test: not decided.** δY = (375 − 285) / 285 = +0.32 (n = 1
  against the 6 base runs; +0.27 against the 3 base runs of the same
  binary). δM = +0.45 by the mean, +0.11 by the median, −0.09 without the
  78.3 s boot. With these Mac spreads τ is 0.46 or more, so the test
  cannot fail or pass a step of this size. The Mac's first boot did slow
  down (+12.1 s, +29 %, 2.5 standard errors), but its CPU did not grow
  (Group A's own programs: under 1 CPU s), so this is more likely load than
  work.
- **Behaviour test: fails** for proactiveeventtrackerd (61 starts against
  0 on the Mac in 700 s), facetimemessagestored (59 against 0) and
  pairedsyncd (60 against 1); intelligencetasksd (16 against 15) and
  mlhostd (49 against 52–55) pass, and so do the five quiet ones (1 start
  each; the Mac starts mediaanalysisd and nanoregistrylaunchd once too
  and the other three not at all, which is within + 2).
- Work: step 10 adds 306 program starts on Ycode (292 → 598 in 700 s) and
  brings back the 40-odd fatal guest conditions of the full boot; on the
  Mac Group A adds under 1 CPU s and about 8 starts in 120 s.

So step 10 costs Ycode about 80–90 s (n = 1), some 40 % of its 225 s
lean-vs-full difference, while Group A costs the Mac nothing measurable.
It holds three of the four Ycode-only restart loops of §3.3, the prime
suspects. The
next runs are the single steps 6–10 (and leave-one-out for the three
looping services) to split the 90 s between them.

### 4.5 What limits the method today

- **Mac noise.** The Mac is shared with other agents' simulators (3–4
  other devices booted, 1–9 cores busy). Its home_s spread (sd 9–13 %,
  one of the eight boots of §4.4 at 2.8 times the median) makes per-step time tests too
  coarse for single services. Remedy: measure the Mac side with no other
  simulator booted, or raise n; until then the behaviour test decides.
- **Different windows.** The Mac reaches the home screen in about 25 s,
  Ycode in about 300 s; timer-driven work (intelligencetasksd's loop
  starts after about 7 minutes on the Mac) therefore falls before
  Ycode's home screen but after the Mac's. Restart counts are compared
  over equal wall time (700 s), home_s over the boot.
- **Ycode's frame grid.** home_s is a multiple of 5 s on Ycode.
- **Different device states (found by agent SVC4, `service-fidelity.md`
  §12).** The Mac references above are new devices; Ycode's benchmark
  device was first booted four days earlier, so maintenance work that is
  due once a day is overdue on it at every boot. That alone makes
  proactiveeventtrackerd and facetimemessagestored loop: the Mac given the
  Ycode device's data starts them 42 and 41 times in 700 s. The behaviour
  test needs the **same device state** on both platforms: give a
  throwaway Mac device the Ycode run's `DEV/data` before its first boot
  (§4.6), or measure Ycode on a device as new as the Mac's.
- **The Mac changes.** Reference counts age with the Mac's host software
  and load: after the update to macOS 27.2 (26B5112a; same runtime,
  24A94401), the Mac with the same device data restarts the three
  state-driven loops every 10.2–10.8 s (68–69 starts in 700 s) where it
  restarted them every ~14 s (41–42) before (§4.7). Record the Mac's
  macOS build and runtime with every reference, and re-measure the Mac
  side when either changes.

### 4.6 Group A behaviour test on Ycode (agent SVC4, 2026-10-17)

Ycode: step 10 (all of Group A enabled again), runs `lad10a`, `lad10b`
(build 15bc7d9: ordered GPU shutdown, shared file views that follow the
file's size), lean otherwise (`lean boot: 13 jobs disabled`), 700 s,
`BENCH_KEEPDEV=1`. Mac references: new devices (§3.3, r4/r5, full boot)
and a Mac device with the Ycode device's data (`service-fidelity.md`
§12.1, full boot). Exit kinds from `launchd.log` on both platforms.

| Program | Ycode starts (a, b) | Ycode end | Mac new device | Mac, same data | Test vs same data |
|---|---|---|---|---|---|
| knowledgeconstructiond | 1, 1 | alive | 0 | 1, alive | **pass** |
| sensorkitd | 1, 1 | alive | 0 | 0 | **pass** (≤ +2) |
| spotlightknowledged | 1, 1 | alive | 0 | 1, alive | **pass** |
| mediaanalysisd | 1, 1 | alive | ≤ 1 | 1, alive | **pass** |
| nanoregistrylaunchd | 1, 1 | alive | ≤ 1 | 1, alive | **pass** |
| intelligencetasksd | 16, 16 | SIGTRAP each | 15 | 15, SIGTRAP each (crash reports) | **pass** |
| mlhostd | 57, 57 | exit(0) | 52, 55 | 28, exit(0) | fails the count (pass against new devices) |
| proactiveeventtrackerd | 64, 65 | exit(1) | 0 | 42, exit(1) | fails the count; same loop, same exit |
| facetimemessagestored | 62, 62 | exit(0) | 0 | 41, exit(0) | fails the count; same loop, same exit |
| pairedsyncd | 63, 64 | exit(0) | 1 | 1, exit(0) | **fails** |

home_s 275 and 295 s; `guest_fatal` 13–14 (16 intelligencetasksd
crashes, as on the Mac); exit status 0 both.

Reading:

- Six of ten pass. The three loops whose cause is the device's state
  (mlhostd, proactiveeventtrackerd, facetimemessagestored) loop on the
  Mac too with the same data and end the same way; Ycode starts them
  1.4–2 × as often because each Mac start waits in the Adaptive hold
  (`service-fidelity.md` §7, §12.2) while Ycode starts them at once.
- pairedsyncd fails for a reason that is Ycode's: the order of two starts
  (`service-fidelity.md` §12.3) — on Ycode a client's lookup succeeds
  after nanoregistrylaunchd enabled the job, its message stays queued,
  and every exit is followed by a new start. Remedy: the Adaptive hold
  (scheduling work).
- The start rule "≤ Mac + 2" is too strict for a job that loops on both
  platforms at the throttle's rate: the count then measures the restart
  interval, not the behaviour. Proposed refinement (not yet adopted):
  for such a job compare the exit kind and the presence of the loop, and
  report the start ratio as a cost.

### 4.7 Full boot with the start hold, against the Mac (agent PRIO, 2026-10-19)

Ycode: full boot (all 23 labels enabled), start hold on (now the default,
`scheduling-policy.md` §4.2), runs h1a, h3–h5 (and q8–q11 with thread
QoS: the same counts). Mac: two throwaway devices given run h5's
`DEV/data` before their first boot (macOS 27.2 26B5112a, Xcode 27.1
27A9269, iOS 27.1 runtime 24A94401); one ran 700 s, one was shut down from
outside after 354 s. Details in `scheduling-policy.md` §7.

| Program | Ycode main line (m1–m5) | Ycode with the hold | Mac, same data, 700 s | Test vs same data |
|---|---|---|---|---|
| pairedsyncd | 65–66, exit(0) | **1**, exit(0) | 1, exit(0) | **pass** (was fail) |
| replicatord | 2 (one abort) | **1**, alive | 1, alive | **pass** |
| mlhostd | 49–54, exit(0) | 51–56, exit(0) | 68, exit(0) | **pass** |
| proactiveeventtrackerd | 64–66, exit(1) | 65–67, exit(1) | 69, exit(1) | **pass** |
| facetimemessagestored | 64, exit(0) | 65, exit(0) | 68, exit(0) | **pass** |
| intelligencetasksd | 16, SIGTRAP | 16, SIGTRAP | 16, SIGTRAP | **pass** |
| parsecd, axassetsd | 1, 1 | 1, 1 (held 6–52 s) | 1, 1 (held 1.6–2.8 s) | **pass** |
| fileindexerd | 16 (crashes) | 9–14 (crashes) | 1 | fails (`service-fidelity.md` §11) |
| Programs started in 700 s | — | 503 (h5) | 631 | |

So all of Group A now passes the behaviour test against the Mac with the
same device data. With the remeasured Mac the start rule "≤ Mac + 2"
holds for the three state-driven loops as well; the refinement proposed
in §4.6 is not needed for them. The remaining full-boot restart loop that
is Ycode's own is fileindexerd (FSEvents, `service-fidelity.md` §11).

## Evidence

| Claim | Level |
|---|---|
| Mac home_s, bootstatus_s, CPU, process and spawn counts, crash reports, contention (§2, §3.1, §3.2) | 3 (`xcrun simctl create/boot/io screenshot/bootstatus/shutdown/delete` on ycode-test-* devices, `ps`; `TMP/launchd.log` and `.ips` reports read as formats) |
| `disabled.plist` honoured on the Mac; disabled programs never spawned (§2) | 3 (`launchd.log` of every lean boot) |
| Display `primary` is the 1398 × 2034 LCD (§1) | 3 (`simctl io --display`, image size); `device-capabilities.md` |
| `.ips` header `timestamp` and body `coalitionName` fields (§2) | 2 (report files read as JSON) |
| Ycode home_s, guest_fatal, images, traps, spawns (§3.3, §3.4, §4.4) | 3 (Thor harness runs, exit summaries, guest `launchd.log`) |
| Ycode first boot ≈ 640 s (§3.4) | 3 (`first-boot.md`, 2026-10-13 build) |
| Mac restart counts over 700 s; intelligencetasksd and mlhostd loops on the Mac (§3.3) | 3 (`TMP/launchd.log`, `.ips` reports; r4, r5) |
| Mac step 10 against base (§4.4) | 3 (four interleaved pairs of new devices) |
| Order, tolerance and pass rules (§4) | design (derived from the measurements above) |
| Group A and the full boot with the start hold, against the Mac with the same device data (§4.7) | 3 (Thor runs h1a, h3–h5, q8–q11, m1–m5; Mac devices `ycode-test-prio-aged-1`, `-2`, `launchd.log`) |
| Group A on Ycode and on the Mac with the same device data (§4.5, §4.6) | 3 (Thor runs `lad10a`, `lad10b`; Mac device `ycode-test-svc4-aged-1`, `launchd.log`, `.ips` reports) |
