# Spec: a device's first boot — data migration and the LaunchServices database

Status: **reference** for stage 7 (integrator I4, 2026-10-12). It explains
why the first boot of a new device takes longer than later boots, which
guest components take part, what marks the work as done, and what the
host (Ycode) must provide so that the work can finish. Facts come from
black-box runs on this Mac (iOS 27.1 runtime 24A94401, a throwaway iPhone
Duo device, `xcrun simctl boot` / `bootstatus` / `spawn … log show`, the
device directory read as files), from our own probe programs run on the
Mac's simulator and under Ycode, and from Ycode runs on the Thor. No
disassembly or decompilation was used.

Terms are as in `launchd-sim.md`: **RR** (RuntimeRoot), **DEV** (the device
directory; `DEV/data` is the guest's writable world).

## 1. The chain on the first boot

1. **backboardd asks for migration and waits.** Early in its start,
   backboardd connects to `com.apple.datamigrator` (a launchd_sim job) and
   waits for the answer before it brings up the display ("calling thread
   blocking on migration queue"; the client is identified as
   `com.apple.backboardd`). It shows the progress window (Apple logo and
   bar) meanwhile. SpringBoard waits for backboardd, so the home screen
   cannot appear before migration ends.
2. **datamigrator decides.** It compares `LastSystemVersion` in
   `DEV/data/Library/Preferences/com.apple.migration.plist` with the
   runtime build. Missing or different: "System build version changed from
   (null) to 24A94401. Migration necessary." Equal: "System build version
   unchanged … Migration not necessary" and backboardd continues at once
   (§2).
3. **Plugins run.** datamigrator gathers the 35 bundles of
   `RR/System/Library/DataClassMigrators/*.migrator`, orders them (some run
   "user-agnostic" first, some "concurrent after" another), and runs each in
   the job `com.apple.migrationpluginwrapper`. Each logs "completed migration
   for <id> (<bundle>, …) (<seconds> s) with success 1". On the Mac all 35
   took 17 s; the slowest, `com.apple.-0LaunchServicesMigrator`
   (`00LaunchServicesMigrator.migrator`), took 11.7 s; every other plugin
   took under 2 s.
4. **The LaunchServices plugin waits for lsd.** It connects to
   `com.apple.lsd.rebuild` and is told "Database was seeding; client will
   retry and block". So are SpringBoard, runningboardd, and a dozen other
   daemons that ask LaunchServices anything during the seeding.
5. **lsd seeds its database on its own first start.** When
   `DEV/data/var/db/lsd/com.apple.LaunchServices-33554481-v2.csstore` does
   not exist (`33554481` is the schema version lsd logs), lsd builds a new
   store, in this order (log lines in quotes):
   - "Registering CoreTypes bundle" (`RR/System/Library/CoreServices/MobileCoreTypes.bundle`);
   - "Registering extension points" … "Done reregistering extension points";
   - handler preferences, "Registering canonical names", "Registering
     framework bundle localized strings";
   - "#LSDatabaseBuilder Seeding database with UID: 501" and "calling into
     InstalledContentLibrary to register all content": every system app
     bundle of the runtime is registered, one `TransactionLog` sequence per
     app ("begin inspect ICLAppRecord", "registering app bundle", "Building
     bundle record for app", "Built bundle record for app", "Registered
     bundle status = success", "registered app bundle", "end inspect").
     iOS 27.1 has 162 of them; SpringBoard (`com.apple.springboard`) is one;
   - "LSDatabaseBuilder: posting LSNotificationDatabaseSeedingComplete";
   - the store is saved: `com.apple.LaunchServices-33554481-v2.csstore`
     (7.8 MB on the Mac) and `SystemDataOnly-com.apple.LaunchServices-33554481-v2.csstore`,
     plus `com.apple.LaunchServices.unregisteredtypes-501.db` and
     `com.apple.LaunchServicesAppProtectionStore.plist`.
   lsd does this whether or not datamigrator runs; the migrator only waits
   for it.
6. **datamigrator writes the result** (§2) and answers backboardd. On the
   Mac the boot reached `bootstatus` "terminal" 22 s after `simctl boot`.

SpringBoard looks up its own application record in LaunchServices early in
its start. When the record is missing (an empty or partial store) it ends
with the uncaught exception "Got nil for _systemAppInfo." (level 3, Ycode
runs before the fixes of §3).

## 2. What marks the work as done

`DEV/data/Library/Preferences/com.apple.migration.plist` after the first
boot (binary plist, level 2):

| Key | Value |
|---|---|
| `LastSystemVersion` | the runtime build, `24A94401` |
| `DMLastMigrationResults` | `{buildVersion = 24A94401; success = <bool>}` |
| `DMUserDataDisposition` | `{buildVersion = 24A94401; EraseIsRapidReturnToService = false; SyntheticDidUpgrade = false}` |
| `DMMigrationPluginResults` | per plugin id: `kDMMigrationPluginResultsBundlePathKey` (host path of the bundle), `kDMMigrationPluginResultsDuration` (seconds, real), `kDMMigrationPluginResultsPhaseDescription` (`kDMMigrationPhaseDescriptionDidFinishWithSuccess`) |

- On the Mac, `success` was **false** even though all 35 plugins succeeded:
  datamigrator logged "Reporting migration failure due to migration progress
  window incident" and `bootstatus` printed "Data Migration Failed". The boot
  went on normally. Only `LastSystemVersion` decides whether the next boot
  migrates (§1 item 2).
- **Second boot of the same device** (shutdown, boot): datamigrator logged
  "Migration not necessary"; lsd opened the existing store (no seeding);
  `bootstatus` was terminal after **2 s** (first boot: 22 s).

**Before the first boot** CoreSimulator puts 90 entries into a new device's
`data` directory (not runtime daemons): sample media under `Media/`
(`DCIM/100APPLE`, `PhotoData`, `Downloads`, `iTunes_Control`), the
`Library/AddressBook` databases, `Library/Preferences/.GlobalPreferences.plist`
(`AppleLanguages = (en-US)`, `AppleLocale = en_US`),
`Library/Preferences/com.apple.UIAutomation.plist` (`UIAutomationEnabled =
true`), `var/run/memory_warning_simulation` and `var/spool/mdt`. None of
them is a migration marker.

## 3. What lsd needs from the host: file-system volumes

lsd registers each bundle together with the volume it is on ("adding
container for <FSNode> path = '<mount point>'", "Adding database record for
volume … with volume ID <n>"). It learns the volume through Foundation's
URL resource values. Our probe `fsprobe` (§5) shows what the Mac's
simulator reports and what Ycode reported before the fix:

| Query on a directory in RR | Mac simulator | Ycode before | Ycode after |
|---|---|---|---|
| `stat` `st_dev` | `0x100002b` | host device (`0x801`, the same for RR and DEV) | `0x1000011` (RR's volume) |
| `statfs` `f_mntonname`, `f_fsid` | the runtime volume's mount point, `{0x100002b, 0x1a}` | the prefix root, `{0x801, 0x1a}` | the prefix root, `{0x1000011, 0x1a}` |
| `NSURLVolumeURLKey` | `file:///Library/Developer/CoreSimulator/Volumes/iOS_24A94401/` | **nil**, error NSCocoaErrorDomain 4 | `file://<RR>/` |
| `NSURLVolumeIsReadOnlyKey`, `…IsLocalKey` | 1, 1 | 0, 0 | 1, 1 |
| `NSURLVolumeNameKey` | "iOS 27.1 Simulator" | nil | the prefix root's name |
| `contentsOfDirectoryAtURL:` | 134 entries | **error 256** (underlying ENOTDIR) | 134 entries |

Two Ycode gaps caused the failures (level 3, Ycode traces of `fsprobe`):

1. **`getfsstat64` returned 0 volumes.** Foundation finds a file's volume by
   reading its `ATTR_CMN_FSID` (getattrlist) and looking for the
   `struct statfs` with that `f_fsid` in the `getfsstat64` list. With no
   entries there is no mount point: lsd logged "createVolumeURL: no
   mountpoint for path: (null)", and every app registration ended with
   `TransactionLog` status 0 ("…:5:4:2:0:registered app bundle") instead of
   1. The store kept only CoreTypes and extension points.
2. **getattrlist packed `ATTR_CMN_ERROR`.** `getattrlist` (not
   `getattrlistbulk`) neither packs `ATTR_CMN_ERROR` nor lists it in the
   returned set; Ycode packed a zero word, which shifted every later
   attribute. Foundation's directory listing asks for it and read a
   non-directory object type (our probe `gadump` on the Mac: request
   `0xf01f9e0d/0/5/1/0x240`, options `0x25`, returned common set
   `0xd01f9e0d`, the name reference right after the returned set).
   `getattrlistbulk` does pack it (a zero word) and returns the bit, even
   without an error (our probe `gabulk`).

**Ycode's model (normative for Ycode).** In device mode every directory
prefix of the guest file system is a volume: its root is the mount point
(`statfs`, getattrlist `ATTR_VOL_MOUNTPOINT`), and everything below it has
the volume's device as `st_dev` and `f_fsid.val[0]` (`ATTR_CMN_DEVID`,
`ATTR_CMN_FSID`). Devices: `0x01000010` for "/" and the synthetic
directories above the prefixes, then `0x01000011 + i` for prefix *i* in
the order `ycode-simd` lists them (the runtime root first). A single-file
prefix (a host library) belongs to the runtime root's volume. An open
descriptor keeps the device it was opened on. `getfsstat64` lists "/" and
every directory prefix, one `struct statfs` (2168 bytes) each, in that
order; a null buffer returns the count. The same host file reached through
two prefixes (for example `/System` and `RR/System`) is two files, as it
is on the Mac (the host's `/System` and the runtime's).

## 4. `--skip-first-boot-migration`

The option writes `com.apple.migration.plist` before the boot with
`LastSystemVersion`, `DMLastMigrationResults = {buildVersion, success =
true}` and `DMUserDataDisposition` as in §2 (no `DMMigrationPluginResults`),
unless the file exists. Effect: datamigrator answers "not necessary",
backboardd does not wait, and none of the 35 plugins runs. lsd still seeds
its database on its first start (§1 item 5), so SpringBoard still gets its
record. What is skipped is the plugins' own work (containers, keychain,
profiles, accounts, Safari and other data). It is faithful for reaching the
home screen and not for a device whose migrated data matters. A later boot
of the same device without the option behaves as the Mac's second boot.

## 5. Probes

`research/experiments/simulator/lsd-seed/` (our own sources):

- `fsprobe.m`: for each path, `stat`, `statfs`, getattrlist volume
  attributes, the URL volume keys one by one, and a directory listing.
- `gadump.c`: one getattrlist call with the given groups and options; hex
  dump of the reply.
- `gabulk.c`: one getattrlistbulk call; hex dump of the first records.
- `timeprobe.c`, `timeprobe2.m`, `clockprobe.c`, `trapbench.c`: wall clock
  and counter reads, counter skew between threads, cost of one trap.
- `growprobe.c`: buffer growth by vm_allocate/vm_copy/vm_deallocate next to
  malloc-style aligned regions (checks contents after each step).
- `prefprobe.m`: one preference written through cfprefsd; does the file
  appear.

## 6. After the volumes: what else the path to the home screen needed

Found with Ycode runs on the Thor (level 3) after §3 was fixed:

1. **A file mapped after it was written read as zeros.** lsd saves its
   store by creating a temporary file in `DEV/data/tmp` (`O_CREAT|O_EXCL`,
   so empty when opened), writing it, `fstat`, then mapping it read-only
   (`mmap` of the whole file) as the new in-memory store, and unlinking it.
   Ycode's private file mapping used the file size recorded when the file
   was **opened** (0), so every byte read as zero: lsd logged "Failed to
   read DB header, generating new one", then "Failed to get unit … from
   store" and every later registration failed; a later save computed a
   checksum over a bogus 1 GiB length and crashed (SIGSEGV in libz). It
   showed after about 130 of the 162 apps, once the shared read-only file
   window no longer served the mapping. Ycode now reports a file's current
   size to the mapping code. With that, all 162 apps register, seeding
   completes ("posting LSNotificationDatabaseSeedingComplete") and the store
   is saved (7.1 MB) in about 15 minutes on the Thor.
2. **`msync` was missing.** chronod's mapped-file allocator calls `msync`
   and asserts that it returns 0 ("Assertion failed: (rc == 0), function
   sync, file AFBMappedFileAllocator.mm"); chronod crashed in a loop.
   SpringBoard sends chronod a synchronous BoardServices XPC request from a
   serial queue during startup; its main thread then waits (`kevent_id`,
   `NOTE_WL_SYNC_WAIT`) for that queue, and the reply never came, so
   SpringBoard stopped right after "UI unlocked" and never pushed its home
   screen window. Ycode now answers `msync` (argument checks of the manual
   page; nothing to flush, because Ycode maps files private).
3. **SpringBoard waits for the migration milestone too.** SpringBoard's
   check-in with backboardd logs "checkIn(first): (waits for migration:
   YES)", then "checkIn(first): complete" and "Milestone reached:
   FBSServiceMilestoneDataMigrationCompleted" once backboardd's
   datamigrator call has returned. Only then does it initialize FrontBoard
   and build the home screen.
4. **Time must be one clock.** For a while Ycode's library read the
   counter (`CNTVCT_EL0`) in place for `mach_absolute_time`. Under KVM each
   vCPU of a guest process has its own counter offset (our probe
   `clockprobe.c`: the counter of vCPU 0 and of the other vCPUs of one
   process differed by 0.11 s, and both differed from the kernel's mach
   time); backboardd logged negative durations ("AttentionAwareness ready
   in -22.1682s") and the boot stalled. The library uses the kernel's mach
   time again (traps −3/−4) until the VMM aligns every vCPU's counter.

5. **Preferences were never written.** cfprefsd creates a missing
   preferences plist (`open` with `O_CREAT`), then makes Sandbox call 12
   (`__mac_syscall("Sandbox", 12, …)`, argument block: the new descriptor,
   flags 0x102, the path) and, when that fails, deletes the file again. Ycode
   answered ENOPOLICY, so every preference write failed ("Couldn't write
   values for keys … Path not accessible") and `DEV/data/Library/Preferences`
   stayed empty — including datamigrator's `com.apple.migration.plist`
   (written through cfprefsd), so the next boot migrated again. Ycode now
   allows call 12, as it allows the check call (2). Our probe `prefprobe.m`
   (write, synchronize, look for the file) succeeds on the Mac's simulator and
   now under Ycode.
6. **`accessx_np`** (BSD 284 `access_extended`) was an unimplemented library
   function; Foundation's file checks call it (CoreServicesInternal imports
   it; 194 calls in one boot). Ycode implements it as `access` (existence).

**Result (2026-10-13):** the second boot of a device whose LaunchServices
store was built by an earlier boot, with `--skip-first-boot-migration`
(release build, `--debug-no-metal`, CPU rendering): SpringBoard pushes
`SBHomeScreenWindow` 4 min 9 s after the start, and the screenshot at
300 s shows the home screen (status bar "Carrier", Wi-Fi, time; the
Settings icon and one dock icon as grey placeholders; black wallpaper), as
`headless-rendering.md` §1 predicts without Metal.

**Ycode timings (Thor, release build, `--debug-no-metal`, 2026-10-13, all
items above fixed):**

| Boot | Seeding done | Migration | Home screen window |
|---|---|---|---|
| First boot of a new device | 6 min 04 s | ended 9 min 39 s (35 plugins, 2 watchdogged) | 10 min 29 s |
| Second boot of the same device, no option | none (store loaded) | "Migration not necessary" | 3 min 29 s |

The second boot behaves as on the Mac (§2): datamigrator reads
`LastSystemVersion` from the `com.apple.migration.plist` that the first boot
wrote through cfprefsd (`DMLastMigrationResults.success` false and two
plugins not successful, as on the Mac where the flag is also false), and lsd
opens the saved store.

**Full first boot (no option), earlier run:** datamigrator ran all 35 plugins in 9 min
54 s (the LaunchServices plugin 318 s, waiting for lsd's seeding; the others
0.2–31 s). Its watchdog killed two plugins that ran past their budget
("watchdog coordinator killing pid …", AppleAccountMigrator and
MobileSafari, reported as failures) and the migration still ended
("migrationDidEnd"). SpringBoard pushed its home screen window 10 min 43 s
after the start. In earlier runs the wrapper was killed and respawned in a
loop; those runs had the clock fault of item 4.

**Open:** seeding and plugin speed (single kernel lock; see the integrator's
report).

## Evidence

| Claim | Level | Source |
|---|---|---|
| The chain, log lines, plugin list and timings (§1) | 3 | `simctl spawn <dev> log show` of a throwaway device's first boot on this Mac |
| backboardd is the client that blocks (§1 item 1) | 3 | datamigrator's log: client pid and its signing identifier |
| Migration marker keys and values, second-boot decision and timing (§2) | 2, 3 | `com.apple.migration.plist` read with `plutil` after each boot; the second boot's datamigrator log; `bootstatus` times |
| Pre-boot device contents (§2) | 2 | directory listing of the device right after `simctl create` |
| Volume values, listing results (§3 table) | 3 | `fsprobe` on the Mac's simulator and under Ycode on the Thor |
| getfsstat and getattrlist calls that Foundation makes (§3 items 1–2) | 3 | Ycode `--exec --trace` of `fsprobe` |
| `ATTR_CMN_ERROR` in getattrlist vs getattrlistbulk (§3 item 2) | 3 | `gadump`, `gabulk` on the Mac's simulator |
| Attribute and option bit meanings, `struct statfs` layout | 1 | xnu `sys/attr.h`, `sys/mount.h`; getattrlist(2), getattrlistbulk(2), getfsstat(2) |
| lsd registration status before and after (§3, §6) | 3 | `log stream` one-shot inside Ycode runs (TransactionLog lines) |
| Zero-filled store mapping, msync assertion, SpringBoard's wait chain, home screen (§6) | 3 | Ycode runs on the Thor: `log stream` one-shots, `--trace-name` traces of lsd and SpringBoard, blocked-thread reports, screenshots |
| Per-vCPU counter offsets (§6 item 4) | 3 | `clockprobe.c` under `ycode-simd --exec` on the Thor |
| Preference writes, Sandbox call 12 (§6 item 5) | 3 | `prefprobe.m` on the Mac's simulator and under Ycode; a `--trace-name cfprefsd` trace |
| `msync` arguments and errors | 1 | msync(2) manual page; xnu `bsd/kern/kern_mman.c` |
| Ycode's volume model, option semantics (§3, §4), `msync` answer | — | Ycode decisions |

Level 5 was not used. `.claude/Xcode.app`, `research/dirty/`, and Ghidra
were not opened.
