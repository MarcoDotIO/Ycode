# Spec: the home screen — icons, wallpaper, app set (stage 8/9 findings)

Status: **reference** (integrator H, 2026-10-13). It explains how the iOS
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

### 2.2 What the host must provide

| Need | Symptom without it (Ycode, before 2026-10-13) | Ycode's answer |
|---|---|---|
| **Coherent `MAP_SHARED` file mappings.** iconservicesagent grows its store by creating a new file (`open` O_RDWR\|O_CREAT\|O_TRUNC, `lseek` to the new size − 1, `write` 1 byte), mapping it shared at a temporary address, copying the old store into it, mapping the same file again at the store's fixed address (`MAP_FIXED`) and unmapping the temporary view. The second view must see the first view's writes. | Ycode mapped files private: the fixed view read zeros, the table capacity read 0, and iconservicesagent faulted (SIGSEGV) reading `table[hash % 0]` — the "status 70" crash loop. | A `MAP_SHARED` mapping of a file open for reading and writing is a view of the host file's page cache (host `mmap` `MAP_SHARED`, registered as a KVM memory slot), so every view in every guest process and the host's own `read`/`write` see the same bytes (mmap(2), level 1). Pages wholly past the end of the file are private zeros. Read-only descriptors keep the old private or shared read-only views. `YCODE_DEBUG_PRIVATE_SHARED_FILES=1` restores the old behavior. chronod's mapped-file allocator and SQLite's `-shm` index use the same kind of mapping. |
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

### 3.2 Where Ycode stops (open)

PosterBoard logs "Rejecting updateExtensions; no extensions received": the
query returns nothing, so no poster exists and the wallpaper stays black.
Our probe `exprobe` (`research/experiments/simulator/extension-discovery/`)
shows why, on the same runtime, Mac against Ycode:

| Query | Mac | Ycode |
|---|---|---|
| `LSApplicationExtensionRecord` enumeration | 456 records | 456 records |
| `-extensionPointRecord` of `com.apple.MercuryPoster` | `com.apple.posterkit.provider` | nil |
| `-platform`, `-SDKVersion` of every app and extension record | 7, "27.1" | 0, nil |
| `LSApplicationRecord -_rawBundleFlags` (Settings) | `0x101002` | `0x1202` |
| `initWithBundleIdentifier:` of an extension | record | error −10814 from the lookup "with platform info" |
| extension point records | 279 | 279 |

lsd logs, for every one of the 162 system apps during seeding, "Placeholder
detected - Flagging bundle <id> incomplete"; the Mac logs this for none.
Ruled out by experiment (level 3): reading the executables (our probe's
`mmap` of the file with and without `MAP_RESILIENT_CODESIGN`,
`macho_for_each_slice`, `dyld_get_image_versions` all report platform 7, SDK
27.1 under Ycode); the entitlements (767 of them read for Settings, as on
the Mac); the placeholder extended attribute (absent, ENOATTR, as on the
Mac); the bundle contents (same 1039 files); installd's built-in content
rebuild (same log lines as the Mac); a fresh seeding with today's kernel
(same result). The cause is still open; the next step is to compare lsd's
registration of one app in a Mac seeding and a Ycode seeding with more of
lsd's log categories, or with our own interposer on the Mac.

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

## Evidence

| Claim | Level | Source |
|---|---|---|
| Default app set (§1) | 2, 3 | Mac `IconState.plist`, screenshot |
| Icon chain, compile timings (§2.1) | 3 | guest `log stream` (iconservicesagent, MTLCompilerService) on the Thor; Mac `log show` |
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

Level 5 was not used; `.claude/Xcode.app`, `research/dirty/` and Ghidra were
not opened.
