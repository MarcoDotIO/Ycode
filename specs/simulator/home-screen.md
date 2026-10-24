# Spec: the home screen — icons, wallpaper, app set (stage 8/9 findings)

Status: **reference** (integrator H, 2026-10-13; §3.2–§3.6 and §6 updated by
integrator J, 2026-10-13). It explains how the iOS
27.1 simulator runtime (24A94401) produces the home screen's icons and
wallpaper, what each step needs from the host, and what Ycode changed to
supply it. Facts come from black-box runs on this Mac (a throwaway iPhone
Duo device, `simctl`, our own probe programs, `log show`), from Ycode runs
on the Thor (VMM traces, `log stream` one-shots inside the guest, our own
probes run as one-shots), and from public documentation. No disassembly or
decompilation was used.

Terms: **RR** (RuntimeRoot), **DEV** (the device directory), as in
`launchd-sim.md`.

## 1. What a fresh device shows

A fresh iOS 27.1 device of type iPhone Duo (model `iPhone19,4`) shows
**Settings** on page one and **Safari** in the dock, the default wallpaper,
the status bar and the search button (`device-capabilities.md` §4). The
short app set is the runtime's default, not a fault: SpringBoard writes
exactly these two icons into `DEV/data/Library/SpringBoard/IconState.plist`.

## 2. Icons

### 2.1 The chain (level 3, guest logs on the Mac and under Ycode)

1. SpringBoard asks `iconservicesagent` (Mach service
   `com.apple.iconservices`) for each icon at the size it needs. First it
   gets an `ISPlaceholderIcon` (the grey rounded square), then the app's
   `ISBundleIdentifierIcon`.
2. iconservicesagent looks the icon up in its persistent store under
   `DEV/data/Containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/…`.
   On a miss it generates the image: IconRendering ("using hardware
   renderer") draws the app's layered icon through RenderBox, which uses
   Metal.
3. RenderBox builds its pipelines from Metal source at run time: each
   "Metal Compiling Shader" is a request to the guest's own
   `MTLCompilerService` (an XPC service of the Metal framework), which
   returns AIR; the pipeline's functions then reach the host Metal service
   as single-function metallibs (`metal-sim-protocol.md` §6) and are
   translated by `ycode-airc`. On the Thor each compile takes 0.1–1 s in
   the guest and a pipeline build 0.5–3.8 s; the first icons of a boot take
   minutes (Safari's icon about 5 minutes after the start of a second
   boot). The Mac does the same work in about 20 ms per shader.
4. The finished image is written into the store and sent to SpringBoard.
5. **Every boot renders the icons again**, on the Mac too: at its start
   iconservicesagent logs "While initializing cache, one or more
   preconditions have been met to delete previous cache" and "Resetting
   icon cache" (Mac reboot of a throwaway device and every Ycode boot,
   level 3), and the Metal shader cache inside the store goes with it
   ("fopen failed for data file", "Invalidating cache"). So the render
   time of item 3 is paid on every cold boot. On the Thor the first
   shader compile also waited for the start of `MTLCompilerService`, which
   Ycode's start hold kept back for 22–34 s; since 2026-10-19 that start
   is not held (`scheduling-policy.md` §4.2 "on demand", §7.3) and the
   icons come with the wallpaper, 60–75 s after the start. A warm start
   (`snapshot.md` §12) restores them drawn.

### 2.2 What the host must provide

| Need | Symptom without it (Ycode, before 2026-10-13) | Ycode's answer |
|---|---|---|
| **Coherent `MAP_SHARED` file mappings.** iconservicesagent grows its store by creating a new file (`open` O_RDWR\|O_CREAT\|O_TRUNC, `lseek` to the new size − 1, `write` 1 byte), mapping it shared at a temporary address, copying the old store into it, mapping the same file again at the store's fixed address (`MAP_FIXED`) and unmapping the temporary view. The second view must see the first view's writes. | Ycode mapped files private: the fixed view read zeros, the table capacity read 0, and iconservicesagent faulted (SIGSEGV) reading `table[hash % 0]` — the "status 70" crash loop. | A `MAP_SHARED` mapping of a file open for reading and writing is a view of the host file's page cache (host `mmap` `MAP_SHARED`, registered as a KVM memory slot), so every view in every guest process and the host's own `read`/`write` see the same bytes (mmap(2), level 1). Pages wholly past the end of the file are zeros until the file grows over them, and read-only `PROT_READ` views of files under writable prefixes are views too (since 2026-10-17, `service-fidelity.md` §10; before, pages past the end at map time stayed private for good and read-only descriptors got private copies). `YCODE_DEBUG_PRIVATE_SHARED_FILES=1` restores the old behavior. chronod's mapped-file allocator and SQLite's `-shm` index use the same kind of mapping. |
| **MobileGestalt answers** (`SIMULATOR_CAPABILITIES`) | CoreUI: "couldn't get 'kMGArtworkDeviceIdiom' from MGCopyAnswer" | `device-capabilities.md` |
| **Correct draw records.** RenderBox draws with `drawIndexedPrimitives` records whose last word packs a 16-bit instance count and a 16-bit base vertex (op 9), and uses the long forms 2, 4, 8, 28. | Op 9 read as a 32-bit instance count gave draws of 2^27–2^31 instances; the Thor's GPU ran one for minutes, the driver logged Xid 109 "CTX SWITCH TIMEOUT", and every later Metal submission of every process was lost (device lost). | The records as `metal-sim-protocol.md` §8.3 now lists them; draws of more than 2^26 vertices × instances are reported and skipped (they can only come from a misread record). |
| **Event waits that do not block other queues** | (latent) a command buffer that waits for an `MTLEvent` signaled by a later command buffer of another queue would block the one shared Vulkan queue forever | §4 |

### 2.3 Result

On the Thor, a device booted with these changes shows the real Settings and
Safari icons, rendered through Ycode's Metal host service on the GPU
(screenshots `9-H/runs/p1a/shots/home-540s.png`, `p1b/shots/home-540s.png`).

## 3. Wallpaper

### 3.1 The chain

1. SpringBoard asks PosterBoard (`com.apple.PosterBoard`, an app-like
   daemon) for the lock- and home-screen posters
   (`com.apple.posterboardservices`).
2. PosterBoard finds the poster providers with ExtensionKit: an `_EXQuery`
   for the extension point `com.apple.posterkit.provider`, answered in
   process from the LaunchServices database ("LS database observing
   started"). On the Mac it receives 29 extensions.
3. PosterBoard asks each provider for its descriptors and builds the
   default configurations; on the Mac the lock screen's poster is
   `com.apple.MercuryPoster` (`MercuryPosterExtension.appex` in
   `RR/System/Library/ExtensionKit/Extensions`), recorded in
   `DEV/data/Library/Application Support/PRBPosterExtensionDataStore/61/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3`
   (table `poster`, `posterRoleMembership` role `PRPosterRoleLockScreen`).
4. Each extension is launched by runningboardd as a launchd job
   (`extension<com.apple.MercuryPoster…>`, "Creating and launching job",
   `_ManagedBy` `com.apple.runningboard`) and renders its poster with Metal.

### 3.2 What Ycode lacked: every app registered as a placeholder

Before 2026-10-13 PosterBoard logged "Rejecting updateExtensions; no
extensions received": the query returned nothing, so no poster existed and
the wallpaper stayed black. Our probe `exprobe`
(`research/experiments/simulator/extension-discovery/`) showed why, on the
same runtime, Mac against Ycode:

| Query | Mac | Ycode before | Ycode after §3.3 |
|---|---|---|---|
| `LSApplicationExtensionRecord` enumeration | 456 records | 456 records | 456 |
| `-extensionPointRecord` of `com.apple.MercuryPoster` | `com.apple.posterkit.provider` | nil | `com.apple.posterkit.provider` |
| `-platform`, `-SDKVersion` of app and extension records | 7, "27.1" | 0, nil | 7, "27.1" |
| `LSApplicationRecord -_rawBundleFlags` (Settings) | `0x101002` | `0x1202` | `0x101002` |
| `initWithBundleIdentifier:` of an extension | record | error −10814 | record |

lsd logged, for every one of the 162 system apps during seeding,
"Placeholder detected - Flagging bundle <id> incomplete" (Mac: none; Ycode
now: none).

### 3.3 Cause: no file identifiers without VOL_CAP_FMT_PATH_FROM_ID

Our probes and interposer for this section and §3.4, §7 are in
`research/experiments/simulator/lsd-placeholder/` (`build.sh`).

**How lsd registers a system app at first boot** (level 3: lsd's own log with
the LaunchServices and MobileInstallation subsystems at debug level, through
`DEV/data/Library/Preferences/Logging/Subsystems/<subsystem>.plist` with
`DEFAULT-OPTIONS` `Level` `Enable`/`Persist` = `Debug`, the os_log(5) format;
and the system calls of lsd, Ycode's `--trace-name lsd` against our own
interposer on the Mac):

1. MobileInstallation's scanner, running inside lsd ("InstalledContentLibrary"),
   enumerates `RR/Applications` (getattrlistbulk), reads each bundle's
   Info.plist, checks the `com.apple.installd.placeholder` extended attribute
   (absent), reads the executable's Mach-O header and its entitlements section,
   and builds one record per app (class `ICLAppRecord`; `IsPlaceholder = 0`).
   The records are identical on the Mac and under Ycode (our probe `icprobe`,
   which runs the scanner by class and selector name and prints each record).
2. LaunchServices then registers the record ("registering app bundle",
   "Building bundle record for app"). It makes a *file node* for the bundle and
   for its executable (a cached set of `getattrlist` attributes: common
   `0xd61f9e0d`, directory `0x5`, file `0x1`, extended `0x350`, options
   `0x25`). On the Mac it then asks the executable's Finder info, **opens the
   executable and reads its first 8 KiB** (`F_NOCACHE`, `read`, `pread`): the
   Mach-O header with the platform, SDK and UUIDs. Under Ycode it skipped that
   read.
3. An app record without executable information is, for LaunchServices, an
   app that is still being installed: "Placeholder detected - Flagging bundle
   incomplete"; the record has platform 0, no SDK version; its extensions get
   no extension point; ExtensionKit's queries (PosterBoard's
   `com.apple.posterkit.provider`) find nothing.

**Why it skipped the read.** The file node's *file identifier*
(`-[FSNode getFileIdentifier:error:]`, class and selector names read at run
time) failed under Ycode with −10813 (data unavailable) while
`NSURLFileIdentifierKey` worked. Our probe `fsnprobe` made the same call on
the Mac and under Ycode; `volcaps` read `ATTR_VOL_CAPABILITIES`: the Mac's
runtime volume reports format capabilities `0x029b6edf`, Ycode reported
`0x00020f47`. One of the missing bits is `VOL_CAP_FMT_PATH_FROM_ID`
(`0x4000`, sys/attr.h: the volume can return a path for an object id,
fsgetpath(2)). With our interposer clearing only that bit in the Mac's
getattrlist replies, the Mac's `getFileIdentifier:` fails the same way, and a
reseed of the Mac's LaunchServices database (lsd restarted with the
interposer through `launchctl setenv DYLD_INSERT_LIBRARIES`, database files
removed) logs exactly 162 "Placeholder detected" lines. A file identifier is
only useful to LaunchServices if it can later find the file by it; without
one it does not record the executable.

**Ycode's answer.** Every Ycode volume reports `VOL_CAP_FMT_PATH_FROM_ID`,
and the calls that use it work (`ObjectPaths.swift`):

| Call | Ycode |
|---|---|
| `fsgetpath` (427), `fsgetpath_ext` (217) | `(fsid.val[0], object id)` → the guest path, NUL-terminated; returns the length with the NUL; ENOSPC if the buffer is short; ENOENT for an unknown id; EINVAL for an unknown volume. Object id 2 is the volume's root (as on APFS); other ids are inode numbers (ATTR_CMN_FILEID, `st_ino`) |
| `openbyid_np` (479) | opens that path with the given flags |

Ycode remembers the path of every object getattrlist reports and, for an id
it has not seen, walks the volume's directories (at most once per volume
every 30 s). After the change a fresh device's seeding logs no placeholder,
records have platform 7 and SDK 27.1, and `com.apple.MercuryPoster` has its
extension point (run `9-J/runs/f3`, probe run `x1`).

**Also matched to the Mac on the way (level 3, not needed for the fix; a
reseed with only these still had 162 placeholders):**

| Attribute or call | Mac (runtime volume) | Ycode now |
|---|---|---|
| `st_uid`/`st_gid` of runtime-root files | 0 / 80 (root:admin) | the same (the host's /System prefix: 0 / 0) |
| `access(W_OK)` on a read-only volume; `X_OK` without x bits | EROFS; EACCES | the same (before: always 0) |
| ATTR_CMN_GEN_COUNT | nonzero (1 for never-modified files) | nonzero, derived from the change time |
| ATTR_CMN_ADDEDTIME | the creation time | the birth time (else the change time) |
| ATTR_CMN_DATA_PROTECT_FLAGS | 3 on the runtime volume | 3 on read-only volumes; the protection class elsewhere |
| ATTR_DIR_LINKCOUNT | 1 | 1 (before: the host's link count) |
| ATTR_CMNEXT_CLONEID | the file id | the file id (before: 0) |
| ATTR_CMNEXT_EXT_FLAGS | `EF_NO_XATTRS` (2) when the object has no extended attributes | the same |
| ATTR_CMN_FNDRINFO | 32 bytes are packed, but the bit is in the returned set only when the object has Finder info | still always returned (kept; our interposer showed lsd does not depend on it) |

### 3.4 After discovery: who may launch a poster

With the extensions registered, PosterBoard finds the poster providers,
launches them through runningboardd (MercuryPoster, EmojiPoster and others
start, log "Scene did connect" and capture snapshots), and SpringBoard asks
for its own instance of the lock-screen poster (`extension<com.apple.MercuryPoster[config:…]>`,
hosted in SpringBoard's poster scene). That request failed, about 250 times
per boot: "Bootstrapping failed … RBSRequestErrorDomain 5 … originator
doesn't have entitlement com.apple.runningboard.primitiveattribute AND
originator doesn't have entitlement com.apple.runningboard.assertions.frontboard";
SpringBoard logged "snapshot failure reason 'Poster scene is not ready: no
content'". The same refusal stopped `--launch`: FrontBoard's open request
for the probe app ended in `FBSOpenApplicationServiceErrorDomain` 5.

**Mechanism (level 3, `--trace-name runningboardd` and `launchd_sim`, the
Mac's runningboardd log, our probes `ljprobe` and `csprobe`).** SpringBoard
has both entitlements (its `__TEXT,__entitlements` section). runningboardd
honors an entitlement only for processes whose launchd job it knows: for
each new client it asks launchd_sim for the job of the pid (AppServerSupport,
class `OSLaunchdJob`, `+copyJobWithPid:`, `-getCurrentJobInfo`). On the Mac
it then logs "Resolved pid N to [osservice<com.apple.backboardd>:N]"; under
Ycode launchd_sim answered "Requestor lacks required entitlement" (error
144), runningboardd logged "Launchd didn't have information for pid",
named every daemon `anon<backboardd>`, `anon<SpringBoard>`, … and "Process
anon<SpringBoard> does not have permission to have entitlement
com.apple.runningboard.primitiveattribute". runningboardd carries the right
launchd entitlements (`com.apple.private.xpc.launchd.job-manager` =
`com.apple.runningboard`, `…launchd.app-server`), and launchd_sim reads them
from the executable as on the Mac. What differed is the code-signing status
(`csops` `CS_OPS_STATUS`) of the runtime's executables:

| Process | Mac (`csprobe`) | Ycode before |
|---|---|---|
| runningboardd, SpringBoard, backboardd, launchd_sim | `0x26004201` (CS_SIGNED, CS_PLATFORM_BINARY, CS_DYLD_PLATFORM, CS_ENTITLEMENTS_VALIDATED, CS_KILL, CS_VALID) | `0x22000201` (no CS_PLATFORM_BINARY, no CS_ENTITLEMENTS_VALIDATED) |
| a probe of ours (linker-signed) | `0x22020201` | `0x22020201` |

The runtime's executables carry a CodeDirectory `platform` byte of 0, yet
the Mac reports them as platform binaries (the runtime image's code is
trusted as the system's). Ycode derived the status from the `platform`
byte alone. **Ycode now reports `0x26004201` and validation category 1 for
every signed executable below the runtime root** (`CodeSigningInfo`,
`DarwinKernel.setPlatformCodeRoots`, set by `ycode-simd` in device mode).
With that one change runningboardd resolves `osservice<…>` identities,
SpringBoard's launch requests go through, and the probe app launches
(§6).

### 3.5 Region queries for render buffers

Poster extensions (EmojiPoster) logged "[com.apple.coreanimation:Render]
failed to query region 0x… (1440000 bytes)" thousands of times: QuartzCore
asks `mach_vm_region` about the buffers it renders into, and Ycode's
`libsystem_kernel` did not have it. It is now Ycode-private Mach routine 21
(`0x7963_2015`; `mach_vm_region` and `vm_region_64`, the caller's own task;
mach/vm_region.h, level 1): the first mapping at or above the address,
adjacent pieces of the same kind and protection merged, in the flavors
`VM_REGION_BASIC_INFO_64` (9), `VM_REGION_BASIC_INFO` (10),
`VM_REGION_TOP_INFO` (12) and `VM_REGION_EXTENDED_INFO` (13); share mode
`SM_PRIVATE` for anonymous memory, `SM_COW` for private file mappings,
`SM_SHARED` for shared memory; KERN_INVALID_ADDRESS past the last mapping,
KERN_INVALID_ARGUMENT for a short count or another flavor.

### 3.6 Result

With §3.3–§3.5 a device whose LaunchServices database was seeded by the
fixed kernel shows the default wallpaper (the Mercury poster, rendered by
`MercuryPosterExtension` through Metal) behind the Settings and Safari
icons: `9-J/runs/w4/shots/home-480s.png` … `home-960s.png` (second boot;
the wallpaper is there by 480 s). A device seeded before 2026-10-13 keeps
its placeholder records; it needs a fresh seeding (a new device, or its
LaunchServices database files in `DEV/data/var/db/lsd/` removed).

## 4. Metal event waits on the host

All Metal queues of all guest processes share one Vulkan queue in Ycode.
`encodeWaitForEvent:value:` (record 400) used to become a Vulkan semaphore
wait on that queue, which held up every later submission — other
processes' frames and the command buffer that was to signal the event.
Metal orders only the command buffers of one queue (MTLCommandQueue,
MTLEvent documentation; level 1). Ycode now keeps such work on the host:
the rest of the command buffer is recorded at once but held, per (process,
Metal queue), until the event reaches the value (a CPU signal or a GPU
signal of another queue); later command buffers of the same queue are held
behind it; other queues continue. A wait for a value already reached costs
nothing. Objects released meanwhile are destroyed after the held work has
completed. A held wait is reported every 10 s.

## 5. Other kernel calls added

| Call | Answer |
|---|---|
| `pathconf` (191), `fpathconf` (192) | values of `sys/unistd.h` names for a case-sensitive, case-preserving volume; unknown names EINVAL |
| `thread_selfcounts` (186) | ENOTSUP (no per-thread counters) |
| `setpriority` (96) | 0 for the known `which` values, EINVAL otherwise |

## 6. Installing an app (stage 7 exit path)

`ycode-simd --install-app` runs our helper `ylaunch install`
(`app-install-launch.md` §4.1) as a one-shot. Three host gaps stopped the
install on the Thor; all three are closed:

1. **Volumes.** installcoordinationd checks that the app it is to copy
   ("transfer path") is on the same volume as its staging location; it
   learns the volumes with getattrlist `ATTR_VOL_UUID` of `/private/var`
   and `/System/Library`. Ycode reported every directory prefix as a volume
   of its own, so the device directory and `/System` had different UUIDs:
   "_CheckTransferPathForSeed: Expected volume UUID … to match the volume
   UUID corresponding to location [system-defined]" (MIInstallerErrorDomain
   232), and the app asset was never transferred. On the Mac a simulator
   process sees `/System/Library`, `/private/var`, `/private/tmp` and the
   device directory on one device (`stat` `st_dev` 16777229 for all four,
   level 3). **Ycode's model (replaces `first-boot.md` §3's "every directory
   prefix is a volume"):** the runtime root is a volume of its own (device
   `0x01000011`, mounted at RR, as the Mac's runtime disk image is); every
   other directory prefix (DEV, `/System`, `/private/var/tmp`,
   `/private/tmp`, job directories) is part of "/"'s volume (device
   `0x01000010`, mount point "/", one UUID); `getfsstat` lists "/" and RR.
2. **`ATTR_DIR_ENTRYCOUNT`.** MobileInstallation's helper service
   (`com.apple.MobileInstallationHelperService`) copies a bundle directory
   into installd's staging area and copies the contents only when
   getattrlist reports a nonzero entry count. Ycode derived the count from
   the directory's link count, which on Linux file systems counts only
   subdirectories, so a placeholder bundle (files only) arrived empty and
   installd failed with "Info.plist missing" (MIInstallerErrorDomain 35).
   Ycode now counts the entries.
3. **Work intervals.** SpringBoard (UIKit) aborts with "Failed to create
   work interval" when `work_interval_create` fails; Ycode's
   `libsystem_kernel` returned ENOSYS. It now implements the work-interval
   calls as a kernel without that scheduler feature would: they succeed and
   change nothing (`SimHostLibs/kernel/workinterval.c`).

An install takes minutes on the Thor (placeholder after about 2.5 minutes);
`ylaunch` waits up to `YLAUNCH_INSTALL_SECONDS` (Ycode passes 1200) for the
completion and retries the open request for up to `YLAUNCH_RETRY_SECONDS`
(600).

**Stage-7 exit reached (2026-10-13, integrator J).** Before §3.3 the install
never left SpringBoard's "Waiting…" state: LaunchServices registered the
installed app, too, as an incomplete placeholder. Before §3.4 the open
request failed ("process was not provided", FBSOpenApplicationServiceErrorDomain
5) because runningboardd refused SpringBoard's launch request. With both,
`ycode-simd --install-app YcodeProbe.app --launch dev.ycode.probe` installs
the app through InstallCoordination ("ylaunch: installed dev.ycode.probe"),
launches it through FrontBoardServices with debug stdio options ("ylaunch:
launched dev.ycode.probe pid 463"; its environment has
`XPC_SERVICE_NAME=UIKitApplication:dev.ycode.probe[…][rb-legacy]`, as on
the Mac), the app's scene comes to the front (teal screen), and the VMM
prints the `== YCODE-PROBE BEGIN … END` report from the app's stderr file
(run `9-J/runs/w3`). The guest helper is
`ycode/SimShim/guest-tests/stage7/ylaunch.m` (built by
`build-stage7.sh`), not the research version in
`research/experiments/simulator/app-launch/`, whose `install` subcommand
uses the refused LaunchServices interface.

## 7. Guest `log stream` one-shots that stop (open)

A `log stream` one-shot stops printing after a few minutes when it is
busy; quiet streams (narrow predicates, a few thousand lines) run to the
end of the run (`9-J/runs/w3`, `a2`: 24 and 28 minutes). Observed (level 3,
`--trace-name log`, `--trace-name notifyd`, `--debug-thread-report
--debug-no-session-end`):

| Run | Stream | Stops after | What the `log` process does at the end |
|---|---|---|---|
| `9-J/runs/w1`, `w2` | posters and SpringBoard (≈40 000–50 000 lines) | 9 min 41 s | (not traced) |
| `t3`, `t4` | everything | 5.5 min, 2.4 min (traced) | the message thread waits on a lock (`__ulock_wait2`) held by another thread that waits for notifyd's reply to request 1023 (notify MIG); notifyd is idle with nothing queued on its ports |
| `t6` | everything | 1.8 min | the message thread is busy in user code (it calls only `mach_absolute_time` and `madvise`) with 6 messages from logd queued on its port, delivered knote suppressed; it never writes again |

The process stays alive until the session ends. The cause is not known;
the next step is to trace the `log` process and logd together with the
thread report and look at what the message thread loops on. Until then: use
narrow predicates (`LOGPRED` in the run scripts) for long runs.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Default app set (§1) | 2, 3 | Mac `IconState.plist`, screenshot |
| Icon chain, compile timings (§2.1) | 3 | guest `log stream` (iconservicesagent, MTLCompilerService) on the Thor; Mac `log show` |
| The icon cache is reset at every boot, Mac and Ycode; the MTLCompilerService hold (§2.1 item 5) | 3 | Mac `log show` after `simctl shutdown`/`boot` of a throwaway device; Ycode `log stream` one-shots and `sched:` lines (runs i2, a1–a3, 2026-10-19) |
| Store growth sequence and fault (§2.2) | 3 | VMM fault report and trap ring of iconservicesagent |
| `mmap` shared semantics | 1 | mmap(2) |
| Draw record layouts (§2.2) | 3 | our `mtlvary` under `mslog` on the Mac; RenderBox's record bodies logged by Ycode |
| Xid 109 | 3 | the Thor's kernel log (journalctl -k) |
| Wallpaper chain (§3.1) | 3 | Mac guest logs (PosterBoard, runningboardd), Mac `PRBPosterExtensionDataStore` read with `sqlite3` |
| LaunchServices differences (§3.2) | 3, 4 | `exprobe` (class and selector names read at run time) on the Mac and under Ycode; lsd and installd logs |
| Event-wait ordering (§4) | 1 | Metal documentation |
| `pathconf` names and values | 1 | `sys/unistd.h`, pathconf(2) |
| Install gaps (§6): volume check, entry count, work intervals | 3 | Ycode `--trace-name` traces of installcoordinationd, installd, the helper service; guest logs; SpringBoard crash report |
| Mac volumes (§6 item 1) | 3 | `stat -f %d` on this Mac |
| Work-interval API names and signatures | 1 | xnu libsyscall (Apple open source) |

| lsd's registration steps, the executable read on the Mac (§3.3) | 3 | debug-level logging preferences (os_log(5) format) on a throwaway Mac device and under Ycode; Ycode `--trace-name lsd`; our interposer `lstrace` (os_log output) loaded into the Mac simulator's lsd with `launchctl setenv DYLD_INSERT_LIBRARIES` and a reseed |
| MobileInstallation's records identical (§3.3) | 3, 4 | our probes `miprobe`, `icprobe` (class and selector names read at run time; a minimal entitlements section of our own) |
| File node identifier, volume capabilities (§3.3) | 3, 4 | our probes `fsnprobe`, `volcaps`, `urlprobe`; `FSNode` selector names read at run time |
| PATH_FROM_ID causes the placeholders (§3.3) | 3 | `lstrace` clearing that capability bit in the Mac's lsd: 162 placeholders; clearing nothing: 0 |
| VOL_CAP_FMT_*, fsgetpath, openbyid_np semantics | 1 | sys/attr.h, fsgetpath(2), sys/fsgetpath.h |
| Attributes matched on the way (§3.3 table) | 3 | `urlprobe`, `fndr`, `ids` on the Mac (host and simulator) and under Ycode |
| RunningBoard identities, launchd's answer, code-signing status (§3.4) | 3, 4 | Ycode `--trace-name runningboardd`, `--trace-name launchd_sim`; the Mac's runningboardd log; our probes `ljprobe` (AppServerSupport `OSLaunchdJob`, names read at run time) and `csprobe` (csops) on the Mac and under Ycode |
| `csops` status bits | 1 | xnu `osfmk/kern/cs_blobs.h` |
| mach_vm_region flavors and layouts (§3.5) | 1 | mach/vm_region.h, mach/vm_statistics.h |
| Wallpaper, install and launch results (§3.6, §6) | 3 | runs `9-J/runs/w3`, `w4` |
| Log-stream stops (§7) | 3 | runs `9-J/runs/t3`, `t4`, `t6` (traces, thread and vCPU reports) |

Level 5 was not used; `.claude/Xcode.app`, `research/dirty/` and Ghidra were
not opened.
