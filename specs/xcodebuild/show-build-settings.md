# xcodebuild: -showBuildSettings

Ycode: `YcodeXcodebuild` (`Plan`, `ShowBuildSettings`, `PackageBuildSettings`, `XcodePIF`,
`SwiftBuildSettingsProvider`, `Arena`, `DerivedDataName`, `Destinations`),
plus the helper `ycode/Tools/ycode-swb`. The settings themselves are
evaluated by swift-build (open source), from a PIF that Ycode generates; no
part of the reference tool is involved.

## 1. Output

Text, after the invocation header (`cli.md` §3) and the package report
(`info-commands.md` §2.3):

    Build settings from command line:            (only with overrides, see below)
        NAME = value                             (sorted by name)
    <blank>
    Build settings from configuration file '<path as given>':   (only with -xcconfig)
        NAME = value                             (the file's plain assignments, last wins)
    <blank>
    Build settings for action <action> and target <target>:
        NAME = value                             (byte order: upper case before lower case)
    <blank>

One block per target (§2). A target name with characters other than
letters, digits, non-ASCII and `, + = - _ . /` is double-quoted, `"` and `\`
backslash-escaped (the same rule quotes arguments in the invocation header).
Empty values print as `    NAME = ` (trailing space). The command-line
section lists the `NAME=value` arguments, `ARCHS` for `-arch` (values joined
by spaces) and `SDKROOT` for `-sdk` (the canonical name, e.g. `macosx27.0`,
or the path when a path was given).

`-json`: an array, one object per target: `{"action": …, "buildSettings":
{NAME: value, …}, "target": …}`, no header sections; empty values are kept.
`-quiet` drops the header and the command-line sections.

## 2. Targets, configuration and action

Without `-scheme` (legacy):

| Selection | Targets |
|---|---|
| none | the project's first target |
| `-target A -target B` | those, in the given order |
| `-alltargets` | every target in project order, **then the first target again** (observed on every corpus project) |

Configuration: `-configuration`, else the project's
`defaultConfigurationName`. A configuration the project does not have
prints the warning of `cli.md` §4 and uses the default.

With `-scheme`: the scheme's build entries whose `buildFor<Action>` flag is
set for the first action (build/install/docbuild → Running, analyze →
Analyzing, archive → Archiving, test/build-for-testing → Testing, plus the
scheme's unskipped testables for testing), in scheme order. `-target` with
`-scheme` selects that target instead. Configuration: `-configuration`, else
the scheme action's `buildConfiguration` (LaunchAction for build).

The action word printed is the first action (`build` when none). The
test actions evaluate with swift-build's `build` action (§7.2).

## 3. Evaluation through swift-build

ycodebuild writes the container's PIF and asks swift-build's build service
for the exported settings of each target
(`SWBBuildServiceSession.allExportedMacroNamesAndValues(level: .target(guid),
buildParameters:)` in the open-source `SwiftBuild` library), through the
helper `ycode-swb settings <request.json>`:

    request: {"pif": path, "parameters": <SWBBuildParameters JSON>, "levels": [{"target": guid}, …]}
    reply:   {"settings": [{NAME: value}, …], "diagnostics": […]}

The helper loads the PIF as the session's workspace, then sets system and
user info from the current process (user, group, home, environment; host OS
version and architecture). It is found through `YCODE_SWB`, then `PATH`,
then next to the `ycodebuild` executable. It pins swift-build to the head
of its `release/6.4.x` branch (§6).

On macOS swift-build finds the active developer directory itself. On other
hosts its own search takes the real path of `swift` on `PATH` and requires a
`…/usr/bin` (or `…/usr/local/bin`) folder; swiftly's `swift` is a proxy in
`~/.local/share/swiftly/bin` and the Flatpak's is a wrapper that runs the
host's, so that search fails and the session cannot be created ("Could not
initialize build system"). The helper therefore names the toolchain
(`SWBBuildService.createSession(name:swiftToolchainPath:…)`), found by
`YcodeRelease.SwiftToolchain` in this order:

1. `YCODE_SWIFT_TOOLCHAIN`, the folder that holds `usr/bin/swift`;
2. `SWIFT_EXEC`, then each `swift` on `PATH`, whose real path is in a
   `usr/bin` or `usr/local/bin` folder (`/usr/bin/swift` → `/`);
3. the first `swift` on `PATH`, asked with `-print-target-info`: the folder
   above `usr/lib/swift` in `paths.runtimeResourcePath`, if the helper sees
   `usr/bin/swift` there. This covers swiftly and, in the Flatpak, a host
   toolchain in the home folder (the sandbox sees the home folder at the same
   path).

Without one, the helper fails with swift-build's session diagnostics and
says how to name a toolchain. The toolchain gives `DEVELOPER_DIR`,
`TOOLCHAIN_DIR` and `SYSTEM_DEVELOPER_DIR`.

### PIF (Ycode's generator, `XcodePIF`)

Same object model as `specs/ide/build-pif.md`, with these rules that the
reference tool's PIF follows (black box, `xcodebuild -dumpPIF`):

| Item | Rule |
|---|---|
| workspace | `guid` = MD5 hex of the workspace name; `path` = the `.xcworkspace`, or `X.xcodeproj/project.xcworkspace` for a lone project; `projects` = every project of the container, including projects referenced from projects (`projectReferences`), recursively |
| project | `guid` = MD5 hex of the project's path **relative to the directory holding the workspace** (`Tool.xcodeproj`, `../Multi/Multi.xcodeproj`, `SQLiteCustom/src/SQLiteLib.xcodeproj`); `appPreferencesBuildSettings` {}; `classPrefix` from `attributes.CLASSPREFIX` |
| any other object | `guid` = project GUID + MD5 hex of the pbxproj object ID |
| root group | type `group`, name = project name, empty path |
| product references | left out of the group tree (the Products group stays, empty) |
| files | `fileType` from `lastKnownFileType`/`explicitFileType`; `fileTextEncoding` `utf-8` for source and text types; `regionVariantName` for variant-group children |
| synchronized folders (`PBXFileSystemSynchronizedRootGroup`) | expanded from disk: a group named like the folder; sub-folders become groups, bundle-like folders (`.xcassets`, `.xcdatamodeld`, `.lproj`, …) and files become file references, sorted Finder-like. Their files join the target's phases by type and exception sets, as `specs/ide/build-pif.md` §Synchronized folders describes (sources, frameworks, headers, resources; `.lproj` files as variant groups; build-phase exception sets; files of folders the target does not list). GUIDs: project GUID + MD5 of `<group id>/<relative path>` (Ycode's own scheme) |
| base configuration | `baseConfigurationFileReference` = the file's GUID; for `baseConfigurationReferenceAnchor` + relative path, the synchronized file's GUID |
| targets | `standard` (native), `aggregate`, `external` (legacy: `toolPath`, `arguments`, `workingDirectory`, `passBuildSettingsInEnvironment`); `customTasks` []; `dependencies` [{guid, platformFilters []}] from `PBXTargetDependency` (same project or through a `PBXContainerItemProxy` into a referenced project) |
| native target extras | `productReference` {guid, name = product file path, type `product`}; `predominantSourceCodeLanguage` `Xcode.SourceCodeLanguage.<Swift|C|Objective-C|Objective-C-Plus-Plus|C-Plus-Plus>` by majority of sources; `provisioningSourceData` per configuration {`configurationName`, `provisioningStyle` 0 when `CODE_SIGN_STYLE` (target, else project) or `TargetAttributes.ProvisioningStyle` is `Automatic`, else 1; `bundleIdentifierFromInfoPlist` = `CFBundleIdentifier` of the target's `INFOPLIST_FILE`, else ""} |
| build files | `fileReference`, or `targetReference` (target GUID) when the file is a target's product or a `PBXReferenceProxy`; `codeSignOnCopy`, `removeHeadersOnCopy`, `shouldLinkWeakly`, `headerVisibility` from `ATTRIBUTES`; `additionalCompilerOptions` from `COMPILER_FLAGS`; `platformFilters` []. Package product build files are left out |
| phases | sources, frameworks, headers, resources, copy-files (`destinationSubfolder` from `dstSubfolderSpec`: 0 → "", 1 `$(WRAPPER_NAME)`, 6 `$(EXECUTABLE_FOLDER_PATH)`, 7 `$(UNLOCALIZED_RESOURCES_FOLDER_PATH)`, 10 `$(FRAMEWORKS_FOLDER_PATH)`, 11 `$(SHARED_FRAMEWORKS_FOLDER_PATH)`, 12 `$(SHARED_SUPPORT_FOLDER_PATH)`, 13 `$(PLUGINS_FOLDER_PATH)`, 15 `$(JAVA_FOLDER_PATH)`, 16 `<builtProductsDir>`; `destinationSubpath` = `dstPath`), shell-script (`name`, `shellPath`, `scriptContents`, input/output paths and file lists, `emitEnvironment`, `alwaysOutOfDate`, `originalObjectID`, `sandboxingOverride` `basedOnBuildSetting`), rez, AppleScript |

Package dependencies are not expressed (the reference tool adds the
packages' own projects to its PIF).

## 4. Build parameters

`SWBBuildParameters` JSON: `action`, `configurationName`,
`overrides.commandLine.table` (command-line settings, `-arch`, `-sdk`),
`overrides.commandLineConfigPath` (`-xcconfig`, absolute),
`overrides.synthesized.table` (below), `arenaInfo`, `activeRunDestination`
and `activeArchitecture`.

Legacy runs send no arena (swift-build then uses the project's `build`
directory: `SYMROOT = <project dir>/build`, products in
`build/<Configuration>`) and no run destination.

Scheme runs:

- **Arena** (DerivedData). With `-derivedDataPath D`: `derivedDataPath` D,
  products `D/Build/Products`, intermediates `D/Build/Intermediates.noindex`,
  PCH `…/Intermediates.noindex/PrecompiledHeaders`, index paths under
  `D/Index.noindex`. Without it: `derivedDataPath` =
  `~/Library/Developer/Xcode/DerivedData`, and the build folder is
  `DerivedData/<name>-<hash>/Build/…`, where `<name>` is the container's name
  with spaces replaced by `_`, and `<hash>` is 28 letters: the MD5 of the
  container's path (the `.xcodeproj` or `.xcworkspace`), its two 64-bit
  big-endian halves each written as 14 base-26 digits `a`–`z`, most
  significant first.
- **Run destination**, without `-destination`: for macOS targets, My Mac
  with the host architecture (an `ARCHS=<one arch>` override picks that
  architecture), `platform`/`sdk` `macosx`, `sdkVariant` `macos`,
  `supportedArchitectures` [arm64, x86_64]. A warning lists the matching
  destinations on stderr:

      --- xcodebuild: WARNING: Using the first of multiple matching destinations:
      { platform:macOS, arch:arm64, id:<provisioning UDID>, name:My Mac }
      { platform:macOS, arch:x86_64, id:<provisioning UDID>, name:My Mac }
      { platform:macOS, name:Any Mac }

  For an iOS application that may run on the Mac
  (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` not `NO`) on an arm64 Mac: an
  `iphoneos` destination (arm64), plus synthesized device settings
  `TARGET_DEVICE_IDENTIFIER` (provisioning UDID), `TARGET_DEVICE_MODEL`
  (`hw.model`), `TARGET_DEVICE_OS_VERSION` and
  `ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION` (host macOS version, `major.minor`
  when the patch is 0), `TARGET_DEVICE_PLATFORM_NAME` `macosx`,
  `ASSETCATALOG_FILTER_FOR_DEVICE_MODEL` and
  `ASSETCATALOG_FILTER_FOR_THINNING_DEVICE_CONFIGURATION` `MacFamily20,1`,
  `BUILD_ACTIVE_RESOURCES_ONLY` `YES`. Other platforms: My Mac as above (it
  does not match, so `ONLY_ACTIVE_ARCH` resolves to NO, as observed).
  With `-destination platform=…[,arch=…]`: that platform; `generic/…`: none.
- **Code coverage** (synthesized): `CLANG_COVERAGE_MAPPING = YES` and
  `CLANG_PROFILE_DATA_DIRECTORY = <build folder>/ProfileData` when
  `-enableCodeCoverage YES`, or (without that option) when the scheme's
  `TestAction` has `codeCoverageEnabled = "YES"`, or has
  `shouldAutocreateTestPlan = "YES"` and at least one testable (generated
  schemes of targets with hosted tests included).

## 5. Without swift-build

If no helper is found, ycodebuild warns on stderr (`ycodebuild: warning:
the ycode-swb helper was not found …`) and evaluates with Ycode's own
resolver (`specs/build-settings.md`): only the levels a project defines and
a few built-ins, no specification defaults, no `-xcconfig`.

### 5.1 Apple SDKs that are not installed (Linux)

Apple's platforms and SDKs exist only in a Mac's developer directory, and
Ycode ships none (no SDK files and no platform definitions of its own). On
Linux swift-build still evaluates every target of an Apple-platform project
from its open-source specifications, the project's levels, xcconfig files
and the command line, so the output has the format of §1. What the SDK and
its platform would define is not known, and is not made up:

| Setting | On Linux |
|---|---|
| `SDKROOT` | stays as written (`macosx`, `iphoneos`), not a path |
| From the SDK and the platform: `ARCHS`, `VALID_ARCHS`, `SDK_NAME`, `SDK_VERSION`, `SDK_DIR`, `PLATFORM_NAME`, `PLATFORM_DIR`, `SUPPORTED_PLATFORMS`, `DEPLOYMENT_TARGET_SETTING_NAME`, `SWIFT_PLATFORM_TARGET_PREFIX`, … | left out |
| The bundle layout, which the product type sets per platform: `WRAPPER_EXTENSION`, `FULL_PRODUCT_NAME`, `CONTENTS_FOLDER_PATH`, `EXECUTABLE_PATH`, `INFOPLIST_PATH`, … | left out |
| `EFFECTIVE_PLATFORM_NAME` | `-unknown`, so build folders end in `-unknown` (`build/Release-unknown`) |
| `DEVELOPER_DIR`, `TOOLCHAIN_DIR`, `TOOLCHAINS` | the Swift toolchain (§3), `org.swift.<version>` |
| `XCODE_VERSION_ACTUAL`, `_MAJOR`, `_MINOR`, `XCODE_PRODUCT_BUILD_VERSION` | swift-build's placeholders for a toolchain session (`10989`, `9900`, `10890`, `99T999`) |
| `HOST_PLATFORM` | `linux` |

These are swift-build's values; the reference tool also prints
`EFFECTIVE_PLATFORM_NAME = -unknown` for an SDKROOT it cannot resolve
(`specs/build-settings.md`, open questions). Measured with Ycode's
macOS App template (Release, legacy): 604 settings on macOS, 446 on Linux;
315 names have the same value, 127 differ (paths, user, toolchain, version
placeholders), 162 are only on macOS and 4 only on Linux
(`EFFECTIVE_PLATFORM_NAME`, which is empty and so absent from that list on
macOS, `SWIFT_DEVELOPMENT_TOOLCHAIN`, `SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME`,
`TOOLCHAIN_VERSION`).

ycodebuild says so on stderr, also with `-json`: one warning per `SDKROOT`
that stayed a name with no `SDK_NAME`, and one when
`XCODE_PRODUCT_BUILD_VERSION` is the placeholder:

    ycodebuild: warning: the SDK "iphoneos" is not installed on this computer. Settings that come from the SDK and its platform (ARCHS, SDK_NAME, SDK_VERSION, PLATFORM_NAME, the bundle layout such as EXECUTABLE_PATH and WRAPPER_EXTENSION, and the SDK's defaults) are left out, and build folders end in "-unknown".
    ycodebuild: warning: there is no Xcode on this computer: XCODE_VERSION_ACTUAL, XCODE_VERSION_MAJOR, XCODE_VERSION_MINOR and XCODE_PRODUCT_BUILD_VERSION are swift-build's placeholders (99T999).

The warnings are not printed on macOS. Building such a project on Linux
still fails: it needs the SDK.

Ycode decision: no stand-in platform or SDK definitions. swift-build would
load them (`XCODE_EXTRA_PLATFORM_FOLDERS`), but their contents (the
platform's and SDK's default settings, versions, architectures) would be
guesses presented as facts.

## 6. Measured agreement

`conformance.md` gives the numbers. With swift-build `main`
(89af69d), 16 settings appeared that the reference tool does not export
(`ARCHS_ORIGINAL`, `CURRENT_SLICE`, `SLICES`, `TARGET_TRIPLES_EFFECTIVE`,
`_RESOLVED_CONFIGURATION`, …); with `release/6.4.0` four were missing and
two lists differed; with the `release/6.4.x` head (5d44ed6) the exported
names and values matched exactly. The only systematic difference is the
first element of `PATH`, which names the build service's own platform
plug-in directory.

## 7. Swift package schemes

In a package folder (`packages.md`), `-showBuildSettings -scheme <scheme>`
prints the settings of the targets the scheme builds, in the format of §1:
the invocation header, the package report (`packages.md` §2), the
command-line and configuration-file sections, then one
`Build settings for action <action> and target <target>:` block per
target; `-json` gives one object per target, `{"action", "buildSettings",
"target"}`, and `-quiet` drops the header sections as for projects.

Ycode decision: the reference tool prints no settings for package schemes
(nothing after the package report, `[]` with `-json`). ycodebuild prints
what a build of the scheme would evaluate, because scripts that read
`BUILT_PRODUCTS_DIR`, `EXECUTABLE_PATH` or `TARGET_BUILD_DIR` need them for
packages as much as for projects.

### 7.1 Targets

The targets are those of SwiftPM's build description (`swift package
dump-pif`, the same PIF the build loads), named as in that PIF and in build
logs:

| Action (the first one) | Targets, in order |
|---|---|
| `build`, `analyze`, `archive`, `install`, other actions | the scheme's build targets (`packages.md` §3): each product's product target, `<product>-product` (a product without one: its package targets), in manifest order; `<Package>-Package` takes every product |
| `test`, `build-for-testing`, `test-without-building` | those, then the scheme's test bundles (`<test>-product`, the unit-test product targets of `packages.md` §3's test rule) |
| `docbuild` | the products' package targets (the modules, `PACKAGE-TARGET:<name>`), as documentation is built per module |

`-target <name>` (repeatable) replaces that list: a package target (the
module, `PACKAGE-TARGET:<name>`, not its `-dynamic` twin of the same name),
else any build-description target with that name (`greet-product`). An
unknown name fails with `The package '<Package>' does not contain a target
named '<name>'.`, exit 65.

Dependencies of those targets (other modules, other packages) get no block
of their own, as for project schemes (§2).

### 7.2 Parameters

As for a package build (`packages.md` §3): configuration `-configuration`,
else `Debug`; the command-line settings, `-arch`, `-sdk` and `-xcconfig`;
the package's DerivedData folder (`-derivedDataPath`, else
`<DerivedData>/<Package>-<hash>`, §4); and, for the test actions, the code
coverage settings of `packages.md` §3 unless `-enableCodeCoverage NO`.

Run destination: `-destination` as for a build, where `platform=Linux[,arch=…]`
names this computer on Linux; `generic/…` gives none. A build needs a
destination (`packages.md` §2), a settings query does not: without one it
is this computer, My Mac (host architecture) on macOS and swift-build's
`linux` platform and SDK on Linux, with Linux's name for the architecture
(`x86_64`, `aarch64`). There swift-build evaluates the package for Linux
(`PLATFORM_NAME = linux`, `SDK_NAME = linux`, `SDKROOT = /`, products in
`Build/Products/<configuration>-linux-<arch>`), and the warning about the
Xcode version placeholders (§5.1) is printed; no SDK is missing, so there
is no SDK warning.

The build system action is the first action, except that `test`,
`build-for-testing` and `test-without-building` evaluate with `build`
(swift-build has no test actions and exports no settings for an action it
does not know; `ACTION = build`). The block header keeps the action word
given. This holds for projects too (§2).

### 7.3 Without swift-build

Ycode's own resolver reads projects only. Without the helper the query
fails: `Showing a Swift package's build settings needs the ycode-swb helper
(swift-build), which was not found. It ships with Ycode; set YCODE_SWB to
its path.`, exit 70.

## Evidence

- Exported-settings API, build-parameter coding (`SWBBuildParameters`,
  `SWBArenaInfo`, `SWBRunDestinationInfo`, settings tables), PIF keys and
  copy-files destination names: open-source swift-build (level 1).
- GUID and signature scheme, PIF shape, synchronized-folder expansion,
  `provisioningSourceData` rule: `xcodebuild -dumpPIF` on samples and the
  corpus, compared by key shape and by hashing candidate strings (level 3;
  no dump is kept in the repository).
- Output format, ordering, quoting, `-alltargets` repetition, the
  command-line and xcconfig sections, DerivedData name and hash, coverage
  and destination rules, warnings: black-box `xcodebuild` 27.1 runs on
  samples and the corpus, values compared setting by setting (level 3).
  The DerivedData hash agrees with open-source descriptions of the
  algorithm (level 1).
- Toolchain discovery on Linux (`swift` real path rule, fallback developer
  directory, `createSession(swiftToolchainPath:)`) and the values for an SDK
  that is not found: open-source swift-build (level 1), checked by running
  the helper on x86-64 Linux with swiftly and in the Flatpak (level 3, Ycode
  only).
- OPEN QUESTION: `MacFamily20,1` was observed on one Apple-silicon Mac; how
  it varies across Macs is unknown.
- OPEN QUESTION: default destinations for iOS apps that cannot run on the
  Mac, for watchOS/tvOS/visionOS, and Mac Catalyst variants.
- OPEN QUESTION: the PIF of package dependencies (the reference tool embeds
  SwiftPM's package projects); targets that depend on package products
  evaluate without them.
- Package schemes (§7): the reference tool's empty output is black-box
  (level 3, `packages.md`); what ycodebuild prints instead is a Ycode
  decision. Target GUIDs and names, product and test-bundle targets: the
  PIF of open-source SwiftPM's `dump-pif` (level 1). The `linux` platform
  and SDK, the Linux architecture names, and the build actions swift-build
  knows (`BuildAction`: no test action): open-source swift-build (level 1),
  checked by running the helper on macOS and on x86-64 Linux (level 3,
  Ycode only).
- OPEN QUESTION: `IDECustomDerivedDataLocation` and other user defaults that
  move DerivedData are not read.
