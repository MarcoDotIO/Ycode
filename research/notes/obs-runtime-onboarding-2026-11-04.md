# Notes: how Xcode 27.1 gets and manages simulator runtimes (onboarding view)

B2-OBS-RUNTIME, 2026-11-04, issue #67. Dirty-room observations in prose. They
feed `specs/simulator/runtime-onboarding.md`. Raw captures (help texts, the
text and JSON listings, the error runs, string lists) are in
`research/dirty/runtime-onboarding/` and the session scratch area; neither is
committed.

Reference: Xcode 27.1 (27A9269) on macOS 27.2, the active developer
directory. The machine already had sixteen runtime disk images (iOS, tvOS,
watchOS and visionOS, releases 26.4.1 to 27.2, one device-specific iOS
build and one visionOS beta build), so the "nothing installed" state could
not be seen directly.

## 1. Method and limits

- Level 1: Apple's documentation page "Downloading and installing
  additional Xcode components" (read through its public documentation
  data), the page "Creating an Xcode project for an app" (the Get button in
  the template chooser), the Xcode 27 release notes (items about Components
  and runtimes), and the help texts of `xcodebuild` and `simctl`.
- Level 2: files read as formats with `plutil`: one runtime bundle's
  `Info.plist`, its `profile.plist`, the `SystemVersion.plist` inside its
  `RuntimeRoot`, a device's `device.plist`, and CoreSimulator's image
  record `images.plist` (structure only).
- Level 3: read-only command runs: `simctl runtime list` (text, `-v`,
  `-j`), `simctl list runtimes` (text, `-v`, `-j`), `simctl runtime match
  list` (text, `-v`, `-j`), `xcodebuild -help`, `-showsdks [-json]`,
  `-checkFirstLaunchStatus`, `-showComponent MetalToolchain [-json]`,
  `-showdestinations` on a throwaway Swift package, and error runs that
  cannot change anything (a path that does not exist, an identifier that
  does not exist, a platform name that does not exist, a missing argument).
  A throwaway device set in the scratch area (three hand-written
  `device.plist` files, read through `simctl --set … list devices`) gave the
  availability messages for a missing runtime and a missing device type
  without touching the real device set.
- Level 4: string lists of the IDE frameworks (IDEKit, IDEFoundation) and of
  CoreSimulator, searched for the user-facing words of the Components pane,
  the first-launch sheet, the run-destination prompts and the image states.
  **Why level 4 was needed:** the GUI could not be observed (no screen
  takeover; screen recording waits on #56), and levels 1–3 do not show the
  Components pane's section names beyond the documented three, the
  first-launch sheet's wording, or the run-time prompts. Only short labels
  and the shape of messages were taken; nothing was disassembled or
  decompiled.
- Not done, by the brief: no download, import, add, delete, unmount,
  verify, scan-and-mount or `match set`; nothing under the system or user
  `Library/Developer` changed; no GUI launch; nothing about how payloads are
  delivered, decrypted or unpacked. The older `obs-runtime` branch was not
  used.

## 2. What the public documentation says (level 1)

The components page describes three sections in Settings ▸ Components:
Platform Support (platforms one can develop for), Other Components (optional
features that can be turned on or off, for example the Metal Toolchain) and
Other Installed Platforms (simulator runtimes for other devices and OS
releases). The pane shows what is installed and how much storage removing
it would recover. Each row not installed has a Get button. An information
button opens a dialog with Delete or Turn Off, depending on the component.
Older runtimes are added with Add Platforms: a dialog where one picks a
platform, narrows the list with a filter field in its toolbar, selects one
or more versions and clicks Download & Install.

Other places the same job appears, per the docs: a Get button in the
project template chooser for a platform that is not installed (a banner
says the platform is not supported, and the project can be created but not
built or run); a Get button next to the run destination and in the canvas
when a project's platform has no runtime, which installs the most recent
runtime for that platform, with the run destination showing progress and
becoming selectable when done; a first-launch sheet where one selects the
app's platforms, can tick Metal Toolchain under Additional Components, and
clicks Install; and a dialog with a Download button when a build needs the
Metal Toolchain and it is missing. The docs say a project for a platform
that is still installing can be created or opened but not built or run
until the install finishes.

Command lines in the docs: `-downloadPlatform` (name iOS, watchOS, tvOS or
visionOS) with optional `-exportPath`, `-buildVersion` and
`-architectureVariant universal|arm64`; `-downloadAllPlatforms`; on another
Mac, select the Xcode, run `-runFirstLaunch`, then `-importPlatform <dmg>`;
`-runFirstLaunch -checkForNewerComponents` for hardware support between
releases (packages land in the user's Developer `Packages` folder);
`-downloadComponent metalToolchain [-exportPath]` and `-importComponent`.
By default the downloaded variant follows the Mac (Apple silicon gets the
arm64-only variant unless Rosetta destinations are in use). Xcode 27 runs
only on Apple silicon (release notes).

Release notes worth carrying over: a fixed bug where Components showed Get
for runtimes already present; previews with an uninstalled runtime now show
a placeholder instead of falling back to macOS; an open known issue that
some deleted runtimes reappear after a reboot; Interface Builder documents
no longer need a simulator runtime to compile.

## 3. The first-launch sheet (level 1 and 4, not seen)

The sheet's subtitle is a single line inviting the user to get platform
SDKs, simulators and tools; its primary button is Download & Install. A row
can read "Ready to install". The first-launch controller's log lines show
the order of what it does: license agreement (if not yet accepted), the
required system packages (with a prompt again if they were not installed,
and a relaunch request if a loaded bundle was updated), then the optional
download prompt, then other first-run panes seen as strings (Git author
identity, a disclosure about external coding agents, a "copy settings from
another device" offer). It can fail early with a message that it could not
check for packages and that the installation may be damaged. Whether the
sheet has a Skip button, which platforms are ticked by default, and what is
shown for macOS were not established. Third-party writing says the sheet
also offers the predictive code completion model.

`simctl` is a small wrapper that runs `xcodebuild -runFirstLaunch` (to
standard error) before the real tool whenever the installed CoreSimulator
framework is missing or older than the version that Xcode expects. So the
first `simctl` call after installing a new Xcode can install system
packages. `xcodebuild -checkFirstLaunchStatus` printed nothing and exited 0
on this machine (nothing pending).

## 4. Settings ▸ Components (level 1 and 4, not seen)

Strings show four section titles in this order: Platform Support, Other
Components, Other Installed Platforms, and **Installed for Other Xcode
Versions** (runtimes installed for a different Xcode). Other row-related
strings: "Ready to install", "Downloading / Installing", "Unknown Platform",
"Required dependency for this version of Xcode", "Installed for other Xcode
versions", a Metal Toolchain description line, and the developer
documentation archive as another optional component. The information
popover offers "Copy Information" and has fields such as the simulator
download method and the date it was last used. The Add Platforms sheet's
prompt asks the user to select simulators to download and install; empty
states say no simulators are available to install (for a platform, or for a
filter with no results). Remove confirmations: one asks whether the user is
sure they want to remove the selected items, and explains the consequence:
for a simulator runtime, apps can no longer run on that simulator; for a
platform, it must be downloaded again to build and run targets that use its
SDK; for both, the SDKs and simulators can no longer be used. Problem rows:
a platform that was downloaded but has a problem asks to be downloaded
again; an unsupported platform says so. Pane-level failures read "Unable to
load components" and "Platform reload failed".

Nothing in the IDE strings describes a disk-space, network or cancellation
message for runtime downloads; those messages probably come from the
system's download service. They must be recorded on screen.

## 5. Where a runtime is required but missing (levels 1, 3, 4)

- **Run destination.** The destination menu gets a Get button (docs).
  Destination strings: "<platform> is not installed. To use with Xcode,
  first download and install the platform" (with variants that add the
  Metal Toolchain), and "<platform> is downloading. The download must
  complete before you can use the platform" (singular and plural). The
  first form matches what public developer forums quote from
  `xcodebuild -showdestinations` output for a missing platform.
- **Running a scheme.** A prompt titled like "Download Xcode support for
  <platform>?" (or "… and Metal Toolchain?") with Download & Install (or
  Download & Install Both) and Continue without Downloading; while a
  download runs, a prompt says the downloads must complete before the scheme
  can run and offers Show Downloads…. A special case covers a scheme that
  builds an embedded watch app (the watch platform must be installed too).
  Window ▸ Downloads (⇧⌘9) exists in the reference menu (an earlier GUI pass)
  and is probably where Show Downloads leads.
- **Build issues.** "<platform> is not installed. Please download and
  install the platform from Xcode > Settings > Components." and the
  "is downloading … must complete before you can build your project" form.
- **xcodebuild, black-box.** With every platform installed, a package whose
  iOS deployment target (28.0) is above every installed runtime lists each
  simulator as ineligible with a reason of the form "<device>'s <platform>
  Simulator <version> doesn't match <target>'s <platform> Simulator
  <version> deployment target. Upgrade <device>'s … or lower <target>'s
  deployment target." The placeholders ("Any iOS Simulator Device" and so
  on) stay eligible. A build with `-destination
  'platform=iOS Simulator,OS=28.0,name=iPhone 17'` waited about 60 s for
  destinations, then failed with "Unable to find a device matching the
  provided destination specifier" and exit status 70.
- **CoreSimulator, black-box.** In the throwaway device set, a device whose
  runtime does not exist is listed under a group headed "Unavailable:
  <runtime identifier>" with the reason "runtime profile not found using
  “System” match policy" (the device's `runtimePolicy` is "System"); a
  device type the runtime does not support gives "device type not supported
  by runtime"; an unknown device type gives "device type profile not found".
  In JSON these are `isAvailable: false` plus `availabilityError`.
- **Previews:** a placeholder (release notes).

## 6. Command lines, black-box (level 3)

- `simctl runtime list` groups disk images by platform ("-- iOS --",
  "-- tvOS --", "-- watchOS --", "-- xrOS --") under "== Disk Images ==";
  each line is "<platform> <version> (<build>) - <image UUID> (<state>)";
  the order within a group is not sorted by version; the footer is "Total
  Disk Images: <n> (<size>)" with binary units and one decimal (the sum of
  all sizes, 94.3G for about 101.3 GB). `-v` adds one indented
  "Key: value" block per image (state, image kind, signature state,
  deletable, mounting mode, mount policy, mount path, image path, size,
  bundle path, supported architectures, parent mount path).
- `simctl runtime list -j` is an object keyed by image UUID. Keys seen:
  `build`, `deletable`, `identifier`, `kind`, `lastUsedAt` (only when the
  image was used), `mountPath`, `parentMountPath`, `path`,
  `platformIdentifier`, `runtimeBundlePath`, `runtimeIdentifier`,
  `signatureState`, `sizeBytes`, `state`, `supportedArchitectures`,
  `version`. Values seen: kind "Patchable Cryptex Disk Image" for all;
  state "Ready" for all; signatureState "Verified" or "Unknown";
  architectures `["arm64"]`. The mount path is either under
  CoreSimulator's `Volumes` folder or under a system mount area. Two
  visionOS 27.0 images (a release and a beta build) share one runtime
  identifier.
- CoreSimulator strings give the full set of image states (Copying,
  Verifying, Reading, Expanding, Mounting, Ready, Unusable, Deleting,
  Unmounting), the reasons an image is unusable (Missing, Invalid
  Signature, Missing Signature, Corrupt, Other Failure, Copy/Move Failed,
  Cryptex Mount Preferred, Mount Failed, Ignored) and the image kinds (Disk
  Image, Legacy Download, Bundled with Xcode, Cryptex Disk Image, Patchable
  Cryptex Disk Image).
- `simctl list runtimes` prints "<name> (<version> - <build>) -
  <identifier>" (`-v` appends the bundle path in brackets). Names use
  "visionOS" where the image list says "xrOS". JSON: `runtimes` array with
  `bundlePath`, `buildversion`, `runtimeRoot`, `identifier`, `version`,
  `isInternal`, `isAvailable`, `name`, `platform` (iOS, tvOS, watchOS,
  xrOS), `supportedArchitectures`, `supportedDeviceTypes` (each with
  `bundlePath`, `name`, `identifier`, `productFamily`) and `lastUsage`
  (an object keyed by architecture, with a year-1 timestamp meaning never).
  The iOS 27.1 runtime lists one device type (the iPhone Duo); the
  device-specific 27.2 build has identifier suffix `-iPhone19-4` and one
  device type.
- `simctl runtime match list` prints, per SDK canonical name of the
  selected Xcode (device-platform names: `iphoneos27.1`, `appletvos27.0`,
  `watchos27.0`, `xros27.0`), the SDK version and build, the platform, the
  chosen runtime, and the user override, preferred and default lines. JSON
  keys: `chosenRuntimeBuild`, `defaultBuild`, `platform`, `sdkBuild`,
  `sdkDirectory`, `sdkVersion`. `-v` adds "Known SDKs", "Preferred Build
  Map" and "User Overrides" sections (both "(None)" here). The SDK builds
  differ from the chosen runtime builds (iOS SDK 24A94403 chose runtime
  24A94401; watchOS 24R360 chose 24R362; visionOS 24M361 chose the release
  24M362, not the beta 24M5291p; tvOS matched exactly).
- Errors: `simctl runtime add <missing path>` prints "(2) No such file or
  directory" and exits 2; `simctl runtime delete <unknown id> --dry-run`
  prints that no runtime disk images or bundles match and suggests
  `runtime list`, then "No matching images found to delete", exit 2;
  `simctl runtime <op> --help` and `simctl runtime delete` without an
  argument print "unrecognized option" (for the former) and the usage, exit
  117. `xcodebuild -importPlatform <missing path>` prints "importing <path>"
  then "File not found at <path>", exit 70; `-downloadPlatform Foo` prints
  "Could not find platform: Foo", exit 70; `-downloadPlatform` without a
  name and `-showComponent Foo` print "xcodebuild: error: …" (the former
  followed by the usage), exit 70; all `xcodebuild` error runs also logged
  that they wrote an error result bundle to a temporary folder.
- `xcodebuild -showComponent MetalToolchain` prints "Key: value" lines
  (asset path, build version, status "installed", toolchain identifier,
  toolchain search path); `-json` gives `assetPath`, `buildVersion`,
  `status`, `toolchainIdentifier`, `toolchainSearchPath`.
- `xcodebuild -help` lists the usage lines for `-downloadPlatform`,
  `-downloadAllPlatforms`, `-importPlatform`, `-downloadComponent`,
  `-importComponent`, `-deleteComponent`, `-showComponent [-json]`, plus
  `-checkFirstLaunchStatus`, `-runFirstLaunch [-checkForNewerComponents]`
  and `-prepareDeviceSupport` with `-platform`, `-osVersion`, `-modelCode`,
  `-architecture`. The help names Metal Toolchain as the only supported
  component. Note the docs spell the component `metalToolchain`, the help
  `MetalToolchain`; `-showComponent MetalToolchain` worked.

## 7. Files read as formats (level 2)

- A runtime bundle `<Name>.simruntime/Contents/`: `Info.plist`
  (`CFBundleIdentifier` is the runtime identifier, `CFBundleName` the
  display name), `Resources/profile.plist` (`defaultVersionString`,
  `platformIdentifier`, `minHostVersion`, `supportedArchs`,
  `supportedProductFamilyIDs`, `supportedFeatures`, `requiredHostServices`,
  `pairingRequirements`, and in some runtimes `restrictedToDeviceTypes`),
  and `Resources/RuntimeRoot/`, whose
  `System/Library/CoreServices/SystemVersion.plist` has `ProductName`
  ("iPhone OS" for iOS), `ProductVersion` and `ProductBuildVersion`. The
  unpacked RuntimeRoot is about twice the image size (iOS 27.0 about 16 GiB,
  visionOS 27.0 about 14 GiB, tvOS 27.0 and watchOS 26.5 about 8 GiB).
- A device's `device.plist`: `UDID`, `deviceType`, `name`, `runtime`,
  `runtimePolicy` ("System"), `state`, `isDeleted`, `isEphemeral`.
- CoreSimulator's image record (`Images/images.plist`): an `images` array
  whose entries carry a UUID, state (an integer), last-state-change and
  last-used dates, mounting mode and mount policy, write policy, the source
  path and runtime info (build, bundle identifier, bundle path,
  internal flag, platform identifier, architectures, and the version as one
  integer with the major in the upper bits, 27.0 as 0x1B0000). It is
  CoreSimulator's private state; the public listing carries the same facts.

## 8. The decrypted asset's container (follow-up, 2026-11-04)

**Protocol deviation.** On 2026-11-04 a clean-room agent (the route B
implementer) read decrypted asset data directly to learn its container
format. That is dirty-room work done in the clean room. This round
observed the format properly and `specs/simulator/runtime-downloads.md`
§4.3 and §5.0 now carry it with evidence, so the clean code has a spec
behind it.

Context: the owner decided the same day that Ycode may download runtimes
from Apple and decrypt them with the key in the asset service's answer
(decisions O1 and O2 in the downloads spec).

Method. One Metal Toolchain asset (27A266a, the one Xcode 27.1 maps to)
was fetched by the downloads spec's §4 steps: a query to the asset service
that describes this Mac with its own values, then the download from
Apple's CDN (800 MiB in about 8 s), with the size and SHA-256 checked
against the answer. macOS's own `aea` tool decrypted it with the key from
the answer, kept in a private file in the git-ignored dirty folder and
never printed. Apple's `aa list -v` was run on the plaintext, and the
plaintext was read as bytes with small scripts of mine kept outside the
repository, decompressing chunks with Python's standard `lzma`. Nothing was
installed. The download, plaintext, key and answer were deleted
afterwards.

Findings, in prose:

- The downloaded file is an encrypted-archive container: magic `AEA1`,
  profile 1 (symmetric, unsigned), no auth data, padded to a whole number
  of MiB.
- The plaintext is not an archive of files but four Apple Archive
  metadata entries, which Apple's `aa list` calls a manifest, two extract
  parts and a "dst-fixup" part. The key that names the operation and a
  "label" key (`main`) are not in Apple's public header. `aa extract` on
  the plaintext extracts nothing.
- The manifest lists the three later parts with their payload size, their
  offset (from the end of the manifest entry) and their entry size; the
  numbers match the file exactly.
- Each later part's payload is a pbzx stream (4 MiB chunks, each either
  one XZ stream or stored as is). Decompressed, it is again an Apple
  Archive stream: in the extract parts, file entries with path, data and
  an error-correcting-code blob; in the fix-up part, one entry per file
  with owner, group, mode and SHA-256 and no data.
- The mode values include the file-type bits.
- Every file's SHA-256 matched the fix-up part. The files are the asset
  folder of the downloads spec's §5.1: the disk image, the restore
  plists, the firmware side files, and `Info.plist` and `version.plist`.
- The asset record's unarchived size is the sum of the file sizes, each
  rounded up to 4 KiB.

A runtime asset was not downloaded in this round. That runtime assets use
the same layout is expected but still to confirm.
