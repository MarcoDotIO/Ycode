# Spec: getting and managing simulator runtimes (onboarding)

Status: **draft** (B2-OBS-RUNTIME, 2026-11-04, issue #67). This spec says
how Xcode 27.1 (27A9269) presents the job "get a simulator runtime, see
what is installed, remove one": the first-launch sheet, Settings ▸
Components, the places where a missing runtime shows up, and the public
command lines (`xcodebuild` and `xcrun simctl runtime`) with their output
formats, exit statuses and errors. It is written for the clean-room work in
#68 (the runtime wizard), #69 (runtimes on a remote host) and #70 (host
provisioning). Dirty-room notes: `research/notes/obs-runtime-onboarding-2026-11-04.md`.

What this spec does **not** cover: how Apple delivers, packages, decrypts
or unpacks runtime payloads, and any design for Ycode downloading runtimes.
Whether Ycode ever downloads a runtime for the user is the owner's open
decision (#55). Everything below about Apple's download buttons describes
the reference's behavior only.

Markers: **Ycode guidance** marks advice for the implementer that is not a
fact about the reference. **To confirm** marks reference behavior known
only from documentation or strings, not yet seen on screen (§12 lists
them all).

Related: `specs/ide/settings.md` (Components pane, today read-only),
`specs/ide/destinations.md` and `specs/ide/run.md` (run destinations),
`specs/ide/device-hub.md` §I.12 (the headset checklist pattern #68 reuses),
`specs/simulator/ipad.md` §2–§3 (runtime and device-type profiles),
`specs/simulator/sim-link.md` (the remote host link), `docs/SIMULATOR.md` §3
and `docs/SIMULATOR-LINUX.md` §5 (Ycode's runtime route on Linux).

## 1. Terms

| Term | Meaning |
|---|---|
| Platform | A family of devices with its own SDKs: iOS, tvOS, watchOS, visionOS (macOS is built in). The docs and the GUI say "platform" for the SDK *and* its simulator runtime together. |
| SDK | Ships inside Xcode; named by canonical name (`iphoneos27.1`, `iphonesimulator27.1`, `appletvos27.0`, `watchos27.0`, `xros27.0`, …) with a build (`24A94403`). |
| Runtime | The simulated OS for one platform release and build. Not part of Xcode; installed separately. |
| Runtime identifier | `com.apple.CoreSimulator.SimRuntime.<Platform>-<major>-<minor>`, `<Platform>` one of `iOS`, `tvOS`, `watchOS`, `xrOS`. A **device-specific** runtime adds a suffix naming the one model it serves, e.g. `…iOS-27-2-iPhone19-4`. The identifier is **not unique**: two builds of the same release (e.g. a beta and the release) share it. |
| Build | The OS build string (`24A434`, beta builds end in a letter, e.g. `24M5291p`). The unique key of a runtime, together with the identifier. |
| Disk image | How a runtime is installed on macOS: a registered image with a UUID, listed by `simctl runtime list`. |
| Runtime bundle | `<Name>.simruntime` (e.g. `iOS 27.0.simruntime`) inside the mounted image; `Contents/Resources/RuntimeRoot/` is the simulated file system that Ycode's Linux simulator boots (§8.3). |
| Component | Anything in Settings ▸ Components: platform support, simulator runtimes, the Metal Toolchain, the documentation archive. |

Display names: the image list and identifiers say `xrOS`; runtime names,
SDK lists and the GUI say `visionOS`. Simulator platform identifiers:
`com.apple.platform.iphonesimulator`, `appletvsimulator`,
`watchsimulator`, `xrsimulator`; the device platforms are `iphoneos`,
`appletvos`, `watchos`, `xros`. `-downloadPlatform` takes the names `iOS`,
`watchOS`, `tvOS`, `visionOS`.

## 2. The routes to a runtime (overview)

| # | Route (reference) | Who starts it | Network | Ycode equivalent |
|---|---|---|---|---|
| R1 | First-launch sheet: choose platforms, Download & Install (§3) | User, once per Xcode | Apple | Wizard on first launch (#68), **without** the download step |
| R2 | Settings ▸ Components ▸ Get on a platform row (§4) | User | Apple | none (policy #55) |
| R3 | Components ▸ Add Platforms… ▸ select versions ▸ Download & Install (§4.4) | User | Apple | none (policy #55) |
| R4 | Get next to a run destination / in the preview canvas (§5.1) | User, when a platform has no runtime | Apple | Wizard opened from the destination |
| R5 | Get in the new-project template chooser banner (§5.4) | User | Apple | Wizard opened from the banner |
| R6 | Run-time prompt "Download … support for <platform>?" (§5.2) | Xcode, on Run | Apple | Wizard opened from the prompt |
| R7 | `xcodebuild -downloadPlatform` / `-downloadAllPlatforms` (§6.1) | User, Terminal | Apple | none (policy #55); the wizard may **show** the command for the user to run on a Mac |
| R8 | `xcodebuild -importPlatform <dmg>` (§6.2) | User, Terminal | none | Wizard: "use a runtime file you have" |
| R9 | `xcrun simctl runtime add <dmg>` (§7.2) | User, Terminal | none | Same as R8 |
| R10 | A runtime already registered on this Mac (any of the above, any Xcode) | — | none | Wizard: "use the runtimes your Xcode has" (§8, §11) |

R1–R7 fetch from Apple. R8–R10 need no network and are the routes the
beta's wizard can follow (#68 "Out: downloading").

## 3. First launch

(Level 1 and 4; **to confirm** on screen.)

1. When a new Xcode starts for the first time it runs its first-launch
   checks in order: the license agreement (if not yet accepted), the
   required system packages (CoreSimulator and device support; if they are
   not installed the prompt comes back; if an already-loaded part was
   updated Xcode asks to relaunch), then the **component sheet**.
2. The component sheet's subtitle invites the user to get platform SDKs,
   simulators and tools. The user selects the platforms to develop for and
   may select **Metal Toolchain** under **Additional Components**
   (third-party reports also list the predictive code-completion model
   there). The primary button is **Download & Install** (the docs also call
   it Install). Rows can show "Ready to install".
3. Choices not established: which platforms are selected by default
   (likely none besides macOS, which is built in), whether there is a Skip
   or "later" button, and what the sheet shows for a platform already
   installed by another Xcode. The docs say only "if a sheet appears on
   first launch", so the sheet is conditional.
4. Skipping (or deselecting everything) leaves Xcode usable for macOS; the
   missing platforms then surface through R2–R6 (docs: "you can manage the
   download later in the Components settings").
5. After the sheet, other one-time panes follow (seen as strings): Git
   author identity, a disclosure about external coding agents, an offer to
   copy settings from another device.
6. Failure before the sheet: Xcode says it could not check for packages to
   install and that its installation may be damaged.

Command-line counterparts (level 3): `xcodebuild -checkFirstLaunchStatus`
exits 0 with no output when nothing is pending (the help says it checks
whether first-launch tasks are needed; its output and status when they
are is **to confirm**); `xcodebuild -runFirstLaunch` installs the required
packages and accepts the license; `-checkForNewerComponents` also fetches
device-support updates published between Xcode releases. `xcrun simctl`
itself runs `xcodebuild -runFirstLaunch` (output to standard error) before
doing its job whenever the installed simulator framework is missing or
older than the one this Xcode expects, so the first `simctl` call after an
Xcode install can be slow and can install packages.

**Ycode guidance.** Offer the wizard on first launch with the same shape:
platform rows (iOS, watchOS, tvOS, visionOS) with a state each, macOS
implicitly present, a primary action, and a way to finish with nothing
selected ("Not Now"), after which the missing-runtime routes (§5) lead back
to the wizard.

## 4. Settings ▸ Components

(Level 1 for the documented parts; level 4 for the extra section, labels
and confirmations; layout, icons and progress display **to confirm**.)

### 4.1 Sections, in order

| Section | Rows | Row actions |
|---|---|---|
| **Platform Support** | One row per platform of this Xcode (iOS, watchOS, tvOS, visionOS; macOS built in): the platform's SDK + its matching runtime | Get (not installed); ⓘ → Delete |
| **Other Components** | Optional features: Metal Toolchain (described as the tools and compilers needed for the Metal framework), the developer documentation archive (for offline access) | Get; ⓘ → Turn Off / Delete |
| **Other Installed Platforms** | Simulator runtimes other than the platform rows' own (older releases, other builds); header button **Add Platforms…** | ⓘ → Delete |
| **Installed for Other Xcode Versions** | Runtimes installed for a different Xcode | ⓘ → Delete |

The pane also shows how much storage removing components would recover
(docs). A component required by this Xcode version is marked as such and
cannot be removed (string "Required dependency for this version of Xcode";
the documentation archive "cannot be removed" in some states).

### 4.2 Row states

| State | What the row shows |
|---|---|
| Not installed | **Get** button |
| Ready to install | label "Ready to install" (chosen, not started) |
| Downloading / installing | progress in the row (docs: the run destination also shows progress); detail **to confirm** |
| Installed | name, version (and build), size; ⓘ button |
| Problem | "There was a problem … with the <platform> platform that was downloaded" and an offer to download it again |
| Unsupported | "<platform> platform is unsupported" (e.g. not supported on this Mac) |
| Unknown | "Unknown Platform" (a runtime whose platform this Xcode does not know) |

Pane-level errors: "Unable to load components", "Platform reload failed",
"Status unavailable".

### 4.3 The information popover (ⓘ)

Shows the component's details (fields seen as strings include the
simulator **download method** and when the simulator was **last used**;
others **to confirm**: version, build, size, architectures), a **Copy
Information** action, and **Delete** (runtimes, platforms) or **Turn Off**
(optional features). Delete asks for confirmation:

- title: are you sure you want to remove the selected item(s);
- consequence, by kind: a simulator runtime — apps can no longer run on
  that simulator (plural form for several); a platform — it must be
  downloaded again to build and run targets that use its SDK; platform and
  simulators together — the SDKs and simulators can no longer be used.

The reference's command-line equivalent is `simctl runtime delete` (§7.3),
which shuts down booted devices of that runtime and unmounts it first.
Release-notes known issue: some removed runtimes reappear after a reboot.

### 4.4 Add Platforms (older runtimes)

1. Components ▸ Other Installed Platforms ▸ **Add Platforms…** opens a
   sheet.
2. The sheet asks the user to select simulators to download and install.
   A platform choice and a filter field in its toolbar narrow the list.
3. The user selects one or more versions and clicks **Download & Install**.
4. Empty states: no simulators are available to install (for the chosen
   platform), or no results for the filter text.

### 4.5 Sizes

The GUI's size format is **to confirm**. The command line (§7.1) prints
binary units with one decimal and a one-letter suffix (`7.3G` for
7,873,719,649 bytes) and gives exact bytes in JSON. Observed image sizes
(arm64 variants): iOS 7.3–7.9 GiB, visionOS 6.8–7.2 GiB, watchOS 3.6–3.7
GiB, tvOS 3.4–3.5 GiB. The unpacked `RuntimeRoot` is about twice the image:
iOS 27.0 ≈ 16 GiB, visionOS 27.0 ≈ 14 GiB, tvOS 27.0 and watchOS 26.5 ≈ 8
GiB.

**Ycode guidance.** Show size as the reference's command line does (one
decimal, binary units, written "GB" in the GUI is acceptable but state the
convention once), and for a copy to Linux (#69) show both the image size and
the unpacked size, since the RuntimeRoot is what lands on the host.

## 5. Where a runtime is required but missing

### 5.1 Run destination

- If the project's platform has no installed runtime, the run destination
  (and the preview canvas) shows a **Get** button. Get installs the most
  recent runtime for that platform. While it runs, the destination shows
  that a download is in progress; when it finishes the destination becomes
  selectable (docs).
- Destination reasons (strings; the first also appears in
  `xcodebuild -showdestinations` output for a missing platform, as quoted
  on public forums):
  - "<platform> <version> is not installed. To use with Xcode, first
    download and install the platform" (variants add "and Metal
    Toolchain");
  - "<platform> is downloading. The download must complete before you can
    use the platform" (plural "are downloading … downloads").
- Devices whose runtime is gone stay in CoreSimulator's device set and are
  listed as unavailable (§7.6); Xcode does not offer them as destinations.

### 5.2 Run (and build) prompts

- On Run with a platform missing, a prompt asks whether to download Xcode
  support for <platform> (and the Metal Toolchain if the scheme needs it),
  explaining that they must be installed for the scheme to run. Buttons:
  **Download & Install <platform>** (or **Download & Install Both**) and
  **Continue without Downloading**. A variant explains that the scheme
  builds an embedded Apple Watch app, so the watchOS platform is needed
  too.
- While a needed download runs: "Downloading Xcode support for <platform>",
  the downloads must complete before the scheme can run, with **Show
  Downloads…** (Window ▸ Downloads, ⇧⌘9, opens the downloads list).
- Build issues: "<platform> is not installed. Please download and install
  the platform from Xcode > Settings > Components." and a "<platform> is
  downloading. The download must complete before you can build your
  project" form.
- If something is still not usable: "<platform> is not available for use —
  wait a few moments and try again" and "<platform> is not supported on
  this Mac".

### 5.3 Previews

Previewing with an uninstalled runtime shows a placeholder in the canvas
(with Get, per §5.1) instead of falling back to macOS (release notes).

### 5.4 New project

In the template chooser, a platform that is not installed shows a banner
saying the platform is not supported, with **Get** at its right. The
project can still be created (and opened) but not built or run until the
platform is installed.

### 5.5 Command-line destinations (level 3)

- `xcodebuild -showdestinations` keeps the generic placeholders ("Any iOS
  Simulator Device", id
  `dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder`)
  eligible and lists each simulator whose runtime is below the deployment
  target as ineligible, with an `error:` field of the form
  "<device>'s <platform> Simulator <runtime version> doesn't match
  <target>'s <platform> Simulator <deployment target> deployment target.
  Upgrade <device>'s <platform> Simulator version or lower <target>'s
  deployment target."
- `xcodebuild build -destination 'platform=iOS Simulator,OS=<missing>,name=…'`
  waits for matching destinations (about 60 s here), then fails: "Unable
  to find a device matching the provided destination specifier", followed
  by the compatible and incompatible destination lists, exit status 70.

## 6. `xcodebuild` component commands

(Usage and options level 1 and 3; download behavior level 1 only, not
run.)

| Command | Purpose |
|---|---|
| `xcodebuild -downloadPlatform <iOS\|watchOS\|tvOS\|visionOS> [-exportPath <dir>] [-buildVersion <os version or build>] [-architectureVariant <universal\|arm64>]` | Download and install a runtime for that platform (the one matching this Xcode's SDK unless `-buildVersion` names another). With `-exportPath`, also save the downloaded package there for use on other Macs. |
| `xcodebuild -downloadAllPlatforms [-exportPath <dir>] [-architectureVariant …]` | The same for every platform this Xcode supports. |
| `xcodebuild -importPlatform <runtime .dmg>` | Install a runtime image saved earlier (docs example: a "… Simulator Runtime.dmg" in Downloads). Run `-runFirstLaunch` first on a fresh Mac. |
| `xcodebuild -downloadComponent MetalToolchain [-exportPath <dir>] [-buildVersion <asset version>]` | Metal Toolchain (the only component named in the help; the docs spell it `metalToolchain`). |
| `xcodebuild -importComponent <type> -importPath <bundle>` | Install a saved component. |
| `xcodebuild -deleteComponent <type>` | Remove a component. |
| `xcodebuild -showComponent <type> [-json]` | Show its status (§6.3). |
| `xcodebuild -runFirstLaunch [-checkForNewerComponents]`, `-checkFirstLaunchStatus` | §3. |

Architecture variant: by default the download matches the Mac (Apple
silicon without Rosetta destinations gets `arm64`, the smaller image);
`universal` adds x86-64 for Intel Macs and Rosetta destinations. All
runtimes seen here are arm64-only. Xcode 27 itself runs only on Apple
silicon.

### 6.1 Outputs and errors observed

All `xcodebuild` failures exit with status **70** and usually log a line
saying an error result bundle was written to a temporary folder.

| Run | Output | Exit |
|---|---|---|
| `-downloadPlatform` (no name) | `xcodebuild: error: option -downloadPlatform requires the platform name to download`, then the usage | 70 |
| `-downloadPlatform Foo` | `Could not find platform: Foo` | 70 |
| `-importPlatform <missing file>` | `importing <path>` then `File not found at <path>` | 70 |
| `-showComponent Foo` | ``xcodebuild: error: Unknown component type `Foo`.`` | 70 |
| `-checkFirstLaunchStatus` (nothing pending) | nothing | 0 |

Progress output of a real download ("x GB of y GB" style lines) and its
failure messages (no network, no space, cancelled with ⌃C) are **to
confirm**; this round ran no download.

### 6.2 What `-exportPath` produces

The docs call the result "the package" and import it with
`-importPlatform <file>.dmg`. The exact file or folder name written by
`-exportPath` is **to confirm** (an earlier, unmerged observation
suggested a folder per runtime named after SDK platform, version and
build). Ycode's wizard should accept a `.dmg` the user points at and treat
other shapes as "to confirm".

### 6.3 `-showComponent` format

Text: `Key: value` lines — `Asset Path`, `Build Version` (e.g. `27A266a`),
`Status` (`installed`), `Toolchain Identifier`, `Toolchain Search Path`.
JSON: `assetPath`, `buildVersion`, `status`, `toolchainIdentifier`,
`toolchainSearchPath`. Other `status` values **to confirm**.

## 7. `xcrun simctl` runtime commands

Usage is `simctl runtime <operation> <arguments>`. Any usage error (unknown
option such as `--help`, missing argument) prints `simctl: unrecognized
option …` where applicable, then the whole `runtime` usage, and exits
**117**.

### 7.1 `simctl runtime list [-v] [-j|--json] [--json-fd=<fd>] [--json-output=<file>]`

Text form:

```
== Disk Images ==
-- iOS --
iOS 27.1 (24A94401) - <image UUID> (Ready)
iOS 27.0 (24A434) - <image UUID> (Ready)
-- tvOS --
…
-- xrOS --
xrOS 27.0 (24M362) - <image UUID> (Ready)

Total Disk Images: 16 (94.3G)
```

- Groups in platform order iOS, tvOS, watchOS, xrOS; lines inside a group
  are **not** sorted by version.
- Line: `<platform> <version> (<build>) - <image UUID> (<state>)`.
- Footer: count and total size (binary units, one decimal; the total of
  `sizeBytes`).
- `-v`: each line is followed by indented `Key: value` lines: `State`,
  `Image Kind`, `Signature State`, `Deletable` (`YES`/`NO`), `Mounting
  Mode` (e.g. `Cryptex`), `Mount Policy` (e.g. `Automatic`), `Mount Path`,
  `Image Path`, `Size` (e.g. `7.3G`), `Bundle Path`, `Supported
  Architectures`, `Parent Mount Path`.

JSON form: an object keyed by image UUID; each value:

| Key | Type | Example / values |
|---|---|---|
| `identifier` | string | the image UUID (same as the key) |
| `runtimeIdentifier` | string | `com.apple.CoreSimulator.SimRuntime.iOS-27-0` |
| `platformIdentifier` | string | `com.apple.platform.iphonesimulator` |
| `version` | string | `27.0`, `26.4.1` |
| `build` | string | `24A434` |
| `state` | string | §7.1.1 |
| `kind` | string | §7.1.1 |
| `signatureState` | string | `Verified`, `Unknown` (others **to confirm**) |
| `deletable` | bool | `true` |
| `sizeBytes` | integer | `8067000161` |
| `supportedArchitectures` | [string] | `["arm64"]` |
| `path` | string | the registered image (a file or folder in system storage) |
| `mountPath` | string | where it is mounted |
| `parentMountPath` | string | |
| `runtimeBundlePath` | string | `<mountPath>/Library/Developer/CoreSimulator/Profiles/Runtimes/<Name>.simruntime` |
| `lastUsedAt` | string, optional | ISO 8601 UTC, only once used |

Ycode uses `runtimeIdentifier`, `version`, `build`, `platformIdentifier`,
`state`, `sizeBytes`, `deletable`, `supportedArchitectures`,
`runtimeBundlePath` and `lastUsedAt`; paths other than the bundle path are
the reference's internal storage and must not be relied on.

#### 7.1.1 Image states, unusable reasons, kinds

(States `Ready` level 3; the rest level 4.)

- **state**: `Copying`, `Verifying`, `Reading`, `Expanding`, `Mounting`,
  `Ready`, `Unusable`, `Deleting`, `Unmounting`. Only `Ready` runtimes are
  usable.
- **unusable reason** (when `Unusable`): `Missing`, `Invalid Signature`,
  `Missing Signature`, `Corrupt`, `Other Failure`, `Copy/Move Failed`,
  `Cryptex Mount Preferred`, `Mount Failed`, `Ignored`. Where these appear
  in the listing (key names) is **to confirm**.
- **kind**: `Disk Image`, `Legacy Download`, `Bundled with Xcode`,
  `Cryptex Disk Image`, `Patchable Cryptex Disk Image` (the last is every
  27.x and 26.x image seen).

### 7.2 `simctl runtime add <path> [-m|--move] [-a|--async]`

Adds a runtime disk image: it is staged, verified and mounted. When the
file system allows, the image is cloned so no extra space is used; when a
copy is needed and standard output is a terminal, progress is printed.
`--move` removes the original only after a successful add. `--async` prints
the new image's UUID and returns without waiting. Error seen: a path that
does not exist prints `(2) No such file or directory`, exit 2. Other
outcomes (invalid image, signature failure, already added) **to confirm**.
The image then passes through the states of §7.1.1.

### 7.3 `simctl runtime delete (<identifier>|all|--notUsedSinceDays <days>|--unusable|--outdated) [--dry-run] [--keep-asset]`

- `<identifier>` is an image UUID (from `runtime list`); `all` deletes every
  image. If the runtime is a disk image, booted devices on it are shut down
  and it is unmounted first.
- `-d/--notUsedSinceDays <days>`: images not used within that many days.
- `-u/--unusable`: images marked unusable.
- `-o/--outdated`: runtimes that have a newer version with the same runtime
  identifier.
- `-n/--dry-run`: print what would be deleted, delete nothing.
- `-k/--keep-asset`: keep the downloaded asset the image came from.
- Error seen: an identifier that matches nothing prints that no runtime
  disk images or bundles match `<id>` and suggests `runtime list`, then
  "No matching images found to delete"; exit 2. Dry-run output format for
  matches **to confirm**.

Devices whose runtime was deleted remain and become unavailable (§7.6).

### 7.4 Other operations (help text, level 1)

`unmount <identifier>` (shuts down its devices, unmounts, keeps the
runtime), `verify <identifier>` (re-checks the signature),
`scan-and-mount` (finds orphaned runtimes in the storage area and adds
them), `dyld_shared_cache update (<runtime>|--all) [--force]` and
`dyld_shared_cache remove (<runtime>|--all)` (queues building, or removes,
the runtime's shared cache; 27.x runtimes ship a prebuilt one per the
release notes).

### 7.5 `simctl runtime match list [-v] [-j]` and `match set`

Which runtime build Xcode uses for an SDK when several builds of the same
release are installed (it always uses a runtime of the SDK's own
version; the policy only picks the build).

Text (per SDK canonical name of the selected Xcode; note these are
**device** SDK names):

```
== Evaluation Results ==
iphoneos27.1:
    SDK Version: 27.1
    SDK Build: 24A94403
    Platform: com.apple.platform.iphoneos
    Chosen Runtime: iOS 27.1 (27.1 - 24A94401) - com.apple.CoreSimulator.SimRuntime.iOS-27-1
        User Override: (null)
        Preferred: (null)
        Default: 24A94403
```

- `Default:` shows a runtime description when a runtime with exactly the
  SDK build is installed, else just the build.
- `-v` adds `== Known SDKs ==`, `== Preferred Build Map ==`, `== User
  Overrides ==` (each `(None)` when empty) and `SDK Directory:` lines.
- JSON: object keyed by SDK canonical name; keys `sdkVersion`, `sdkBuild`,
  `sdkDirectory`, `platform`, `defaultBuild`, `chosenRuntimeBuild`.
- Observed: SDK and chosen runtime builds often differ (iOS SDK 24A94403 →
  runtime 24A94401; watchOS 24R360 → 24R362; visionOS 24M361 → release
  24M362 rather than beta 24M5291p; tvOS 24J360 → 24J360).
- Precedence (help text): a user override (`match set <sdk> <build>
  [--sdkBuild <build>]`, cleared with `--default`) beats a preferred build
  (bundled with Xcode, an exact SDK match, or a better match named by
  Apple's downloadable index), which beats the default.

### 7.6 `simctl list runtimes [-j] [-v]` and device availability

Text: `== Runtimes ==`, then `<name> (<version> - <build>) - <identifier>`
(e.g. `visionOS 26.4 (26.4.1 - 23O249a) - com.apple.CoreSimulator.SimRuntime.xrOS-26-4`);
`-v` appends ` [<bundle path>]`. The name uses the major.minor of the
identifier, the parenthesis the full version.

JSON `runtimes[]`: `identifier`, `name`, `version`, `buildversion`,
`platform` (`iOS`, `tvOS`, `watchOS`, `xrOS`), `isAvailable`,
`availabilityError` (when not available), `isInternal`,
`supportedArchitectures`, `bundlePath`, `runtimeRoot`
(`<bundlePath>/Contents/Resources/RuntimeRoot`), `lastUsage` (object keyed
by architecture, ISO 8601; `0001-01-01T00:00:00Z` means never),
`supportedDeviceTypes[]` (`identifier`, `name`, `productFamily`,
`bundlePath`). A runtime restricted to one model lists only that device
type (iOS 27.1 here: iPhone Duo only).

Devices (`simctl list devices [-j]`) are grouped by runtime. A device
whose runtime is not installed is shown under `-- Unavailable: <runtime
identifier> --` with `(unavailable, runtime profile not found using
“System” match policy)`; JSON `isAvailable: false`, `availabilityError`
with the same text. Related reasons: `device type not supported by
runtime`, `device type profile not found`. `simctl delete unavailable`
removes such devices.

## 8. Recognising a runtime

### 8.1 On a Mac

Use the listings, not the reference's private records: `simctl runtime
list -j` (images, sizes, states) joined to `simctl list runtimes -j`
(availability, device types, `runtimeRoot`) on runtime identifier **and**
build. Several Xcodes on one Mac share the same runtimes (the Components
pane lists the others' under §4.1's last section).

### 8.2 A runtime file the user has

A runtime disk image (`.dmg`) from Apple (the developer downloads site or
an `-exportPath` run). Ycode does not open it; on a Mac it hands it to
`xcodebuild -importPlatform` or `simctl runtime add` with the user's
consent (§11), then re-reads the listings.

### 8.3 A runtime bundle or RuntimeRoot (Linux, remote hosts)

| File | Keys that identify it |
|---|---|
| `<Name>.simruntime/Contents/Info.plist` | `CFBundleIdentifier` = runtime identifier; `CFBundleName` = display name (e.g. `iOS 27.0`) |
| `<Name>.simruntime/Contents/Resources/profile.plist` | `defaultVersionString`, `platformIdentifier`, `supportedArchs`, `supportedProductFamilyIDs`, `minHostVersion`, optional `restrictedToDeviceTypes` (see `ipad.md` §2.1) |
| `RuntimeRoot/System/Library/CoreServices/SystemVersion.plist` | `ProductName` (`iPhone OS` for iOS), `ProductVersion`, `ProductBuildVersion` |

A bare RuntimeRoot (as Ycode's Linux route copies it, `docs/SIMULATOR-LINUX.md`
§5) is identified by its `SystemVersion.plist`; the platform follows from
`ProductName`. Version + build is the key, as on the Mac.

## 9. Error cases and recovery (consolidated)

| Situation | Reference behavior | Level | Ycode check (guidance) |
|---|---|---|---|
| No runtime for the project's platform | Get on destination / canvas / new-project banner; run prompt; build issue | 1, 4 | "Runtime for <platform>" fails, fix: open wizard |
| Runtime older than deployment target | destinations ineligible with "doesn't match … deployment target" | 3 | fail with both versions; fix: get a newer runtime or lower the target |
| Device's runtime removed | device listed as unavailable, not a destination | 3 | list stale devices; fix: delete or retarget (`simctl upgrade` exists) |
| Download in progress | destination and run prompt say it must finish; Show Downloads… | 4 | state "in progress" (only if Ycode ever drives a download) |
| No network | **to confirm** (no IDE string found; likely the system's own error text) | — | unknown → fail with reason; Retry |
| Not enough disk space | **to confirm** | — | Ycode checks free space against §4.5 sizes **before** any copy or import |
| Download cancelled | **to confirm** (GUI cancel control and resulting row state; ⌃C on the command line) | — | partial work removed, row back to "not installed", Retry |
| Image unusable | state `Unusable` + reason (§7.1.1); Components shows "problem … download again" | 3, 4 | fail with the reason; fix: delete and re-add |
| Platform unsupported on this Mac | "… is not supported on this Mac" / "platform is unsupported" | 4 | fail; no fix |
| File not found (import/add) | `File not found at <path>` (70) / `(2) No such file or directory` (2) | 3 | fail before running anything |
| Unknown platform name | `Could not find platform: <name>` (70) | 3 | validate names locally |
| Unknown runtime id (delete) | no match message, exit 2 | 3 | refresh the list first |
| Removed runtime reappears after reboot | known issue in the release notes | 1 | re-read listings on wizard open, never cache |
| Components fail to load | "Unable to load components" | 4 | unknown state, Retry |

## 10. Exit statuses

| Tool | Status | Meaning (observed) |
|---|---|---|
| `xcodebuild` | 0 | success |
| `xcodebuild` | 70 | any error in this spec (bad option value, file not found, destination not found) |
| `simctl runtime …` | 0 | success |
| `simctl runtime …` | 2 | `No such file or directory` / no matching image |
| `simctl runtime …` | 117 | usage error (help printed) |

## 11. Notes for the clean-room implementers (#68–#70)

(**Ycode guidance**, not reference facts.)

1. **Checklist rows** (the headset pattern of `device-hub.md` §I.12: state
   ok / missing / unknown, a reason, at most one fix, Retry re-runs):
   per platform — "Runtime for <platform>" (ok = a `Ready` runtime whose
   version ≥ the SDK's or the project's deployment target); "Disk space"
   (before any copy/import, against §4.5); on Linux and remote hosts
   additionally the host checks of #69/#70.
2. **Detect only by looking.** Detection runs `simctl runtime list -j` and
   `simctl list runtimes -j` (Mac) or reads §8.3 files (Linux). Import
   (`xcodebuild -importPlatform`, `simctl runtime add`) and delete
   (`simctl runtime delete <UUID>`) run only on a click, show the exact
   command first, and re-read the listings afterwards. Prefer `--dry-run`
   to show what a bulk delete (`--unusable`, `--outdated`,
   `--notUsedSinceDays`) would remove before doing it.
3. **Row model** worth carrying from the reference: platform, version,
   build, runtime identifier, size (bytes), state, architectures, last
   used, deletable, location (this Mac / host name), and whether another
   Xcode installed it.
4. **Where the wizard opens**: first launch; a destination of a platform
   without a runtime (in place of the reference's Get); the new-project
   banner; the Run prompt; Settings ▸ Components (`settings.md`), which
   becomes a list with Remove (and Import…) instead of read-only.
5. **Remote hosts (#69)**: the same row model per host, plus the
   RuntimeRoot size (≈2× the image) for the transfer and free-space check;
   offline hosts mark their rows unknown, not missing.
6. **Never** fetch from Apple in the beta; where the reference would show
   Get, Ycode explains how to get a runtime with the user's own Xcode
   (Settings ▸ Components, or `xcodebuild -downloadPlatform <name>` on
   their Mac) and offers to use it afterwards.

## 12. To confirm by recording (GUI, once #56 allows it)

1. First-launch sheet: layout, default selections, whether macOS is shown,
   Skip/later button, behavior when platforms are already installed, the
   additional components offered (Metal Toolchain, code-completion model).
2. Components pane: row layout, version/build/size columns, the storage
   total, icons, the order of rows within sections.
3. Row progress during download and install: bar or ring, bytes or
   percent, time remaining, a cancel control, the "Ready to install" and
   "Downloading / Installing" states in context.
4. The ⓘ popover's full field list and its Delete/Turn Off confirmation
   text and buttons.
5. Add Platforms sheet: the platform control, list columns, multiselect,
   filter behavior, beta builds, what is shown for already installed
   versions.
6. Run destination Get button: placement, progress display in the
   destination, what happens on completion and on failure.
7. Run prompt (Download & Install / Continue without Downloading) and the
   Downloads window (⇧⌘9): what it lists and its controls.
8. New-project banner wording and the Get button flow.
9. Preview canvas placeholder with a missing runtime.
10. Error presentation for no network, not enough disk space, a cancelled
    download, an unusable/corrupt image, and Retry behavior.
11. After Delete: how fast the row and destinations update; whether
    devices of that runtime disappear from the destination menu at once.
12. Command line (needs an allowed download, owner's call): the progress
    lines of `-downloadPlatform`, its output when nothing is needed, the
    files `-exportPath` writes, ⌃C behavior, and `simctl runtime add`
    progress, `delete --dry-run` output.

## 13. Open questions for the owner

1. **#55**: may Ycode ever start a download from Apple on the user's
   behalf (even only by running `xcodebuild -downloadPlatform` on the
   user's own Mac, with their consent)? This decides whether R2–R7 have a
   Ycode counterpart or only an explanation.
2. Should the wizard on a Mac run `xcodebuild -importPlatform` /
   `simctl runtime add` / `simctl runtime delete` itself (with consent), or
   only show the commands for the user to run?
3. May the reference GUI flows of §12 be recorded under #56, including a
   real download on a test account or a test Mac (needed for progress,
   cancel and error states)?
4. Deleting runtimes affects the user's Xcode too (they are shared). Should
   Ycode's Remove be limited to runtimes Ycode copied (Linux, remote), and
   leave the Mac's to Xcode?

## Evidence

Levels from `AGENTS.md` rule 4. "Docs" = Apple's "Downloading and
installing additional Xcode components" and "Creating an Xcode project for
an app" pages; "RN" = Xcode 27 release notes; "help" = `xcodebuild -help`,
`xcrun simctl help runtime`, `simctl help list`; "strings" = string lists
of IDEKit, IDEFoundation and CoreSimulator (labels and message shapes
only; no disassembly). Level 4 was used because the GUI could not be
observed (no screen takeover; recording waits on #56).

| Claim | Level | Source |
|---|---|---|
| §1 identifier grammar, device-specific suffix, shared identifiers, platform ids and names | 3 | `simctl runtime list -j`, `simctl list runtimes -j`, `xcodebuild -showsdks -json` |
| §2 routes R1–R9 | 1 | Docs; help |
| §2 R10 | 3 | listings |
| §3 sheet contents (platforms, Additional Components, Download & Install/Install, Metal Toolchain) | 1 | Docs |
| §3 code-completion model in the sheet | 1 (third party) | public blog post |
| §3 order of first-launch checks, subtitle, "Ready to install", later panes, failure message | 4 | strings (IDEKit) |
| §3 `-checkFirstLaunchStatus`, `-runFirstLaunch [-checkForNewerComponents]` | 1, 3 | Docs; help; run (exit 0, no output) |
| §3 `simctl` runs `-runFirstLaunch` when CoreSimulator is older | 2 | the `simctl` wrapper script read as a text file (behavior only) |
| §4.1 three sections, Get, ⓘ, Delete/Turn Off, storage note | 1 | Docs |
| §4.1 fourth section, required-dependency mark, documentation archive | 4 | strings (IDEKit, IDEFoundation) |
| §4.2 row states and labels, pane errors | 4 | strings (IDEKit) |
| §4.3 popover fields, Copy Information, confirmation texts | 4 | strings (IDEKit) |
| §4.3 delete shuts down and unmounts; reappearing runtimes | 1 | help; RN |
| §4.4 Add Platforms steps | 1 | Docs |
| §4.4 sheet prompt and empty states | 4 | strings (IDEKit) |
| §4.5 sizes, unit format | 3 | `simctl runtime list` text and `-j`; `du` of three RuntimeRoots |
| §5.1 Get on destination and canvas, progress, most recent runtime | 1 | Docs |
| §5.1 destination reason texts | 4 | strings (IDEFoundation); public forum quotes of `-showdestinations` |
| §5.2 run prompt, buttons, Show Downloads, build issues, not available/not supported | 4 | strings (IDEKit, IDEFoundation) |
| §5.2 Window ▸ Downloads ⇧⌘9 | 3 | `specs/ide/reference-ui-5.md` (earlier GUI pass) |
| §5.3 preview placeholder | 1 | RN |
| §5.4 new-project banner and Get | 1 | Docs ("Creating an Xcode project for an app") |
| §5.5 `-showdestinations` ineligible reasons, placeholders, destination timeout, exit 70 | 3 | throwaway Swift package with an iOS 28.0 target |
| §6 command table, architecture variants, Apple-silicon-only | 1 | Docs; help; RN |
| §6.1 error outputs and exit statuses | 3 | runs with a missing name, bogus name, missing file, bogus component |
| §6.2 export result shape | 1 (partial) | Docs; exact shape to confirm |
| §6.3 `-showComponent` format | 3 | `xcodebuild -showComponent MetalToolchain [-json]` |
| §7 usage, options, exit 117 | 1, 3 | help; runs with `--help` and without arguments |
| §7.1 text and JSON formats, sort order, footer, `-v` keys | 3 | `simctl runtime list`, `-v`, `-j` |
| §7.1.1 `Ready`, kind value seen, `Verified`/`Unknown` | 3 | `simctl runtime list -j` |
| §7.1.1 full state, reason and kind lists | 4 | strings (CoreSimulator) |
| §7.2 add behavior and options | 1 | help |
| §7.2 missing-file error, exit 2 | 3 | run with a path that does not exist |
| §7.3 delete options | 1 | help |
| §7.3 no-match error, exit 2 | 3 | `delete <zero UUID> --dry-run` |
| §7.4 other operations | 1 | help; RN (prebuilt cache) |
| §7.5 match formats, observed choices | 3 | `simctl runtime match list`, `-v`, `-j` |
| §7.5 precedence and `match set` | 1 | help |
| §7.6 `list runtimes` formats, `lastUsage` sentinel, restricted runtime | 3 | `simctl list runtimes`, `-v`, `-j` |
| §7.6 unavailable-device grouping and reasons | 3 | `simctl --set <scratch set> list devices [-j]` with hand-written `device.plist` files |
| §7.6 `simctl delete unavailable`, `simctl upgrade` | 1 | `simctl help delete`, `simctl help upgrade` |
| §8.1 several Xcodes share runtimes | 4 | strings (section title) |
| §8.3 bundle and RuntimeRoot keys | 2 | `Info.plist`, `profile.plist`, `SystemVersion.plist` read with `plutil` |
| §9 rows | as cited in §3–§7 | — |
| §10 exit statuses | 3 | the runs above |
| §11 | — | Ycode guidance |
| §12, §13 | — | open items |
