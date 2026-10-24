# xcodebuild: -showBuildSettings

Ycode: `YcodeXcodebuild` (`Plan`, `ShowBuildSettings`, `XcodePIF`,
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

The action word printed is the first action (`build` when none).

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
| synchronized folders (`PBXFileSystemSynchronizedRootGroup`) | expanded from disk: a group named like the folder; sub-folders become groups, bundle-like folders (`.xcassets`, `.xcdatamodeld`, `.lproj`, …) and files become file references, sorted Finder-like. Their files join the target's sources phase (source code, Core Data models, ML models, intent definitions, documentation catalogs) or resources phase (everything else except headers, xcconfigs, entitlements, `Info.plist`, test plans), minus `membershipExceptions`. GUIDs: project GUID + MD5 of `<group id>/<relative path>` (Ycode's own scheme) |
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

## 6. Measured agreement

`conformance.md` gives the numbers. With swift-build `main`
(89af69d), 16 settings appeared that the reference tool does not export
(`ARCHS_ORIGINAL`, `CURRENT_SLICE`, `SLICES`, `TARGET_TRIPLES_EFFECTIVE`,
`_RESOLVED_CONFIGURATION`, …); with `release/6.4.0` four were missing and
two lists differed; with the `release/6.4.x` head (5d44ed6) the exported
names and values matched exactly. The only systematic difference is the
first element of `PATH`, which names the build service's own platform
plug-in directory.

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
- OPEN QUESTION: `MacFamily20,1` was observed on one Apple-silicon Mac; how
  it varies across Macs is unknown.
- OPEN QUESTION: default destinations for iOS apps that cannot run on the
  Mac, for watchOS/tvOS/visionOS, and Mac Catalyst variants.
- OPEN QUESTION: the PIF of package dependencies (the reference tool embeds
  SwiftPM's package projects); targets that depend on package products
  evaluate without them.
- OPEN QUESTION: `IDECustomDerivedDataLocation` and other user defaults that
  move DerivedData are not read.
