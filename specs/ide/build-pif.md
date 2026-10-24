# Build engine 2: PIF and swift-build

Ycode modules: `YcodeBuild` (`PIFGenerator`, `SwiftBuildEngine`,
`SwiftBuildMessageReader`). CLI: `ycode pif <xcodeproj>`,
`ycode build … --engine swift-build`. The engine emits the same
`BuildEvent` stream as the xcodebuild engine (`specs/ide/build.md`).

## swift-build in brief

swift-build (swiftlang/swift-build, Apache 2.0) is the open-source build
engine. Clients describe the project model in the Project Interchange
Format (PIF) and send it with a build request to a build-service process;
the service plans tasks and runs them on llbuild. Two ways to drive it:

1. As a library: the `SwiftBuild` product (`SWBBuildService` →
   `createSession` → `sendPIF`/`loadWorkspace` → `createBuildOperation`).
   This links llbuild, swift-driver and the platform plug-ins (about 1,200
   compile units), and needs the `SWBBuildServiceBundle` executable.
2. Through its `swbuild` command-line client:
   `swbuild build <container> --target T [--configuration C]
   [--buildParametersFile F] [--derivedDataPath D]` (also `clean` via
   `--action`). A container path ending in `.json`/`.pif` is read as a PIF.

**Ycode uses (2)** so the Ycode package takes no dependency: the engine
looks for `swbuild` via `YCODE_SWBUILD`, then `PATH`. Building `swbuild`
(`swift build --product swbuild` in any package that depends on
swift-build) took under a minute on this Mac after resolution.

## PIF

A JSON array of top-level objects `{signature, type, contents}`, `type` ∈
`workspace | project | target`. References between top-level objects are
by signature; references inside a project are by GUID (unique in the whole
PIF, stable across regenerations). Booleans are the strings
`"true"`/`"false"`.

| Object | Keys Ycode writes | Source in pbxproj |
|---|---|---|
| workspace | `guid`, `name`, `path` (…/project.xcworkspace/contents.xcworkspacedata), `projects` [project signatures] | the `.xcodeproj` |
| project | `guid`, `path` (the .xcodeproj), `projectDirectory`, `projectName`, `projectIsPackage` "false", `targets` [target signatures], `groupTree`, `buildConfigurations`, `defaultConfigurationName`, `developmentRegion`, `knownRegions`, `classPrefix` | `PBXProject` and its configuration list |
| group (in `groupTree`) | `guid`, `type` "group" / "variantGroup", `name`, `path`, `sourceTree`, `children` | `PBXGroup` / `PBXVariantGroup`; the root group has `sourceTree` "<group>", empty `path` (so it is the project directory) and the project's name |
| file | `guid`, `type` "file", `path`, `sourceTree`, `fileType` | `PBXFileReference` (`lastKnownFileType` or `explicitFileType`); product references are left out |
| build configuration | `guid`, `name`, `buildSettings` (string or string-array values), `baseConfigurationFileReference` | `XCBuildConfiguration` |
| target | `guid`, `name`, `type` "standard", `productTypeIdentifier`, `productReference` {`guid`, `name`, `type` "product"}, `buildPhases`, `buildRules` [], `dependencies` [], `buildConfigurations`, `provisioningSourceData` [{`configurationName`, `provisioningStyle` 1, `bundleIdentifierFromInfoPlist` ""}] | `PBXNativeTarget` |
| build phase | `guid`, `type` (`com.apple.buildphase.sources`, `.frameworks`, `.headers`, `.resources`, `.copy-files`), `buildFiles` [{`guid`, `fileReference` or `targetReference`, optional `codeSignOnCopy`/`removeHeadersOnCopy` "true"}]; copy-files adds `destinationSubfolder`, `destinationSubpath`, `runOnlyForDeploymentPostprocessing` | `PBX*BuildPhase`, `PBXBuildFile.fileRef` (a file that is another target's product becomes `targetReference` to that target), `settings.ATTRIBUTES` |
| target dependency | {`guid`: target GUID} in the target's `dependencies` | `PBXTargetDependency.target` (in-project) |

GUIDs: `<rootObject>-<object id>`. Signatures: `WORKSPACE@<xcodeproj path>`,
`PROJECT@<project guid>`, `TARGET@<target guid>`.

Supported now: native targets of type `com.apple.product-type.tool`,
`com.apple.product-type.library.static`, `.library.dynamic`,
`com.apple.product-type.framework` and
`com.apple.product-type.application`, with in-project target
dependencies, with sources, frameworks, headers
and resources phases. For applications swift-build does the bundle work
from settings and phases: `GENERATE_INFOPLIST_FILE`/`INFOPLIST_KEY_*` (or
`INFOPLIST_FILE`) → `Contents/Info.plist`; asset catalogs in the resources
phase → `Contents/Resources/Assets.car`; the executable goes to
`Contents/MacOS/<PRODUCT_NAME>`. A project is described only if all its targets are supported
(a dependency on a skipped target could not resolve). Other product types
(tests, app extensions), synchronized folders, cross-project
dependencies, package products and shell-script phases are rejected with
a clear error, and the Build System setting's fallback then uses
xcodebuild.

Copy-files destinations (`dstSubfolderSpec` → `destinationSubfolder`):
0 `<absolute>`, 1 `$(WRAPPER_NAME)`, 6 `$(EXECUTABLE_FOLDER_PATH)`,
7 `$(UNLOCALIZED_RESOURCES_FOLDER_PATH)`, 10 `$(FRAMEWORKS_FOLDER_PATH)`,
11 `$(SHARED_FRAMEWORKS_FOLDER_PATH)`, 12 `$(SHARED_SUPPORT_FOLDER_PATH)`,
13 `$(PLUGINS_FOLDER_PATH)`, 15 `$(JAVA_FOLDER_PATH)`, 16
`<builtProductsDir>`.

### Workspaces

An `.xcworkspace` becomes one PIF: a workspace object (signature
`WORKSPACE@<path>`, `path` …/contents.xcworkspacedata) listing every
project of the workspace (`Workspace.projectPaths`), followed by each
project's objects. The target to build is the one named like the scheme in
any project.

### SwiftPM packages

Ycode does not write package PIF itself: it runs SwiftPM's own generator,
`swift package dump-pif` (open source), in the package directory, which
resolves the package graph (local `path:` dependencies included). Its
shape: one workspace; one project per package with `projectIsPackage`
"true"; per executable product a `<product>-product` target of type
`com.apple.product-type.tool`; per library target a target of type
`org.swift.product-type.common.object`; aggregate targets for test
products; and an extra "Aggregate" project with `AllExcludingTests` and
`AllIncludingTests`. Target to build: `<scheme>-product`, else the target
named like the scheme, else `AllExcludingTests`. Executables land in
`Products/<configuration>/<product>`.

## PIF source in the IDE (shared with ycodebuild)

`SwiftBuildEngine.pifSource` (a `PIFSource`) replaces the built-in
generator for projects and workspaces. The IDE sets it to
`YcodeXcodebuild.XcodePIFSource`, the generator ycodebuild uses
(`specs/xcodebuild/show-build-settings.md`): reference GUID scheme
(workspace GUID = md5 of the workspace name, project GUID = md5 of the
project path relative to the workspace's folder, object GUID = project
GUID + md5 of the object ID), the implicit `X.xcodeproj/project.xcworkspace`
path, sub-projects, synchronized folders and every target kind — so
settings that embed GUIDs (`PROJECT_GUID`, intermediate paths) match the
reference tool. `PIFGenerator` remains the engine's default when no source
is set. Packages always use SwiftPM's PIF.

## swift-build version

swift-build is pinned to the head of its `release/6.4.x` branch (revision
`5d44ed6ba16c53d56cac5fc6a2d572635aa4a979`), the version whose exported
settings match the reference tool exactly. `ycode/Tools/ycode-swb` pins it;
`swift build --product swbuild` (and `ycode-swb`, `SWBBuildServiceBundle`)
in that package builds the engine's tool. `SwiftBuildEngine.locate()`
looks at `YCODE_SWBUILD`, then for `swbuild` next to the `ycode-swb`
helper named by `YCODE_SWB`, then `PATH`.

## Product lookup without xcodebuild

`XcodebuildEngine.settingsSource` (a `BuildSettingsSource`) answers
`buildSettings(for:)` instead of `xcodebuild -showBuildSettings -json`. The
IDE sets it to `YcodeXcodebuild.SwiftBuildSettingsSource` when the
`ycode-swb` helper is found: it exports every target's settings from
swift-build for the request's configuration, derived-data arena and the
host Mac destination (the scheme's target first).

## Build parameters

Written as the `--buildParametersFile` JSON:
`{"configurationName": C, "activeRunDestination": {…}, "activeArchitecture":
A, "overrides": {"commandLine": {"table": {…}}}}`.

Run destination for My Mac (`platform=macOS`): `platform` "macosx", `sdk`
"macosx", `sdkVariant` "macos", `targetArchitecture` = host architecture,
`supportedArchitectures` ["arm64", "x86_64"], `disableOnlyActiveArch` false;
`activeArchitecture` = host. With it, `ONLY_ACTIVE_ARCH=YES` builds one
architecture. A generic destination (Any Mac) sends none and builds all.

Every request carries these overrides, plus the request's `NAME=value`
settings:

| Setting | Value | Why |
|---|---|---|
| `SDK_STAT_CACHE_ENABLE` | NO | the stat-cache tool is missing from some toolchains |
| `CODE_SIGN_IDENTITY` | `-` | Sign to Run Locally (ad-hoc) |
| `ENTITLEMENTS_DESTINATION` | (empty) | `swbuild`'s provisioning stub adds an `application-identifier` entitlement to the signature for identity `-`; macOS kills such a program at launch (exit 137) without a provisioning profile. With no destination, no entitlements are signed in. |
| `ENTITLEMENTS_REQUIRED` | NO | otherwise the build stops: "Entitlements are required for product type …" | Target: the
target named like the scheme, else the first supported target. Derived
data: the request's path, else `<project dir>/.ycode-build`.

## Message stream

`swbuild` writes each message as a decimal byte count on its own line, then
one JSON object. Ycode maps:

| `kind` | Event |
|---|---|
| `taskStarted` | `activity(executionDescription)` |
| `output` | `output` lines of the base64 `data` |
| `error`, `warning`, `note`, `remark` | `issue`: `message`; `location` {`path`, `line`, `column`} when `locationType` is `path`; `fixIts` [{`sourceRange` {`path`, `startLine`, `startColumn`, `endLine`, `endColumn`}, `textToInsert`}]; `childDiagnostics` become notes. Exact repeats (one per architecture) are dropped. |
| `buildCompleted` | `result` "ok" → success |

Other lines are passed through as output.

## Alignment with Xcode's PIF (black box)

`xcodebuild -dumpPIF <file> -project <xcodeproj>` (and `-workspace <package
dir>` for a package) writes the PIF Xcode would send. Compared on the tool
project and a one-target package (files kept outside the repository):

- Same object model and keys; Ycode now matches the root group (`<group>`,
  empty path, project name), product reference `type` "product",
  `knownRegions`, `classPrefix` and per-configuration
  `provisioningSourceData`.
- Xcode adds `predominantSourceCodeLanguage` (e.g.
  `Xcode.SourceCodeLanguage.C`) and leaves out `projectName` and
  `projectIsPackage` for projects (both optional; Ycode keeps them).
- GUIDs: Xcode uses 32-hex-digit hashes plus a per-object suffix; Ycode uses
  `<rootObject>-<object id>`. Signatures: Xcode's carry a format version
  and a content hash (`PROJECT@v11_mod=…_hash=…`, `TARGET@v11_hash=…`,
  `WORKSPACE@v11_hash=…_subobjects=…`, packages `PACKAGE@v12_hash=…`);
  Ycode's are path/GUID based. Both are opaque to swift-build as long as
  they are unique and stable; content-hash signatures would let the
  service cache objects across edits (future work).
- The Products group is present but empty in both: product references live
  only on their target.
- Packages: Xcode's package PIF has the same targets as SwiftPM's
  (`<product>-product` tool, `common.object` per target) without the extra
  "Aggregate" project; file GUIDs are path-like
  (`PACKAGE:<name>::MAINGROUP::REF_n…`); groups "AdditionalFiles" and
  "Binaries"; `productReference.name` `$(EXECUTABLE_NAME)`;
  `approvedByUser` "true". Build settings differ widely (about 90 keys,
  many with `[__platform_filter=…]` conditions, and a different default
  `MACOSX_DEPLOYMENT_TARGET`).

## Evidence

- swift-build architecture, PIF purpose, exchange and object model: the
  open-source swift-build repository (SwiftBuild.docc
  "Project Interchange Format", "Build System Architecture"; PIF key names
  in its project-model loader; `swbuild` console commands) (level 1).
- Black-box runs (level 3): `swbuild` built a one-file C command-line tool
  from Ycode's PIF; the product ran and printed its output. Without the two
  overrides above the build failed (missing stat-cache tool) or the product
  was killed at launch (exit 137, entitlement `application-identifier`).
  A syntax error produced structured errors with a fix-it inserting `;`.
- Run destination and parameter encoding: swift-build's open-source
  `SWBBuildParameters` coding (level 1); verified by a one-architecture
  build (level 3).
- Applications: a hand-written AppKit project built into an ad-hoc-signed
  bundle with a generated Info.plist and compiled asset catalog, and the
  executable ran (headless smoke flag) (level 3).
- Dependencies, frameworks, workspaces: a three-target project (static
  library, framework, tool linking the library) built in dependency order
  and the tool ran; a workspace with that project and an app project built
  the app's scheme (level 3).
- Packages: `swift package dump-pif` + `swbuild` built an executable and a
  library product with a local package dependency; the executable ran
  (level 3).
- Xcode PIF comparison: `xcodebuild -dumpPIF` outputs diffed by key shape
  (level 3); no Apple-generated file is kept in the repository.
- OPEN QUESTION: signatures by content hash (Xcode's scheme) for incremental
  PIF transfer.
- OPEN QUESTION: which of Xcode's package build settings matter for
  matching its build output.
