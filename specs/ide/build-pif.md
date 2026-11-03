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
`PROJECT@<project guid>`, `TARGET@<target guid>` (`PIFGenerator`; `XcodePIF`
hashes contents into its signatures, see "PIF source in the IDE").

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
xcodebuild. (Until IDE-SMALL `PIFGenerator` left a synchronized folder
out of the group tree without an error, so a target that took its files
from one was built with no sources and the build succeeded; it now
rejects any project with a `PBXFileSystemSynchronizedRootGroup`.) (This paragraph is `PIFGenerator`, the engine's built-in
generator. The IDE and `ycode build --engine swift-build` use `XcodePIF`
instead, which covers every target kind and package products; see "PIF
source in the IDE" and "Package products, macros and plug-ins".)

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
is set. Package folders always use SwiftPM's PIF. `ycode build --engine
swift-build` uses `XcodePIFSource` as well (since PIF-PKG).

Signatures (`XcodePIF`): `WORKSPACE@<guid>_hash=<md5>`,
`PROJECT@<guid>_hash=<md5>`, `TARGET@<guid>_hash=<md5>`, the hash being
the MD5 of the object's contents as JSON with sorted keys (a project's
contents list its targets' signatures; the workspace's its projects').
swift-build keeps build descriptions in the derived-data folder under a key
made from the signatures of the objects they come from, so a fixed
signature made it reuse a stale build description after a target changed
(for example after a package product or a plug-in output was added).

The IDE's fallback test (`FallbackEngine.supports`) can call
`XcodePIFSource.supports(_:)`: false only when the container does not load
or applies a build-tool plug-in to a project target on a host that cannot
run it (Linux, see below). `XcodePIFSource.unsupportedFeatures(_:)` names
what is missing.

**For a build server** (LSP-BSP): `XcodePIFSource.makePIF(for:)` returns
the `XcodePIF` of a request's container with its package graph, the PIF the
build sends. Serialize it (`serialized()`) and name targets with
`XcodePIF.targetGUID(_:_:)`; swift-build then answers for those targets
with the same settings and arguments the build uses.

## Synchronized folders (Ycode implementation, IDE-SMALL)

Format: `specs/formats/pbxproj.md` §Synchronized folders. Ycode module:
`YcodeProject` (`SynchronizedFolder`, `SynchronizedMember`,
`PBXProj.synchronizedMembers`, `BuildFileTypes`). One model reads each
folder from disk and decides each target's members; `XcodePIF`, the build
server's `BuildGraph`, the project navigator and the File inspector's
Target Membership all use it, so they list the same files.

**The folder's tree** (the PIF `groupTree` under the root group):

- Sub-folders are groups (`path` = their name). Hidden names (a leading
  ".", `xcuserdata`, `DerivedData`, `.build`, `.swiftpm`) are skipped;
  order is Finder-like (localized standard compare, folders and files
  mixed).
- Package-like folders are one file item: `.xcassets`, `.icon`,
  `.xcdatamodeld`, `.xcdatamodel`, `.xcmappingmodel`, `.bundle`,
  `.framework`, `.xcframework`, `.docc`, `.rcproject`,
  `.realitycomposerpro`, `.app`, `.appex`, `.scnassets`, `.spriteatlas`,
  `.mlpackage`, `.xcstickers`, `.storekit`, `.xcodeproj`, `.xcworkspace`,
  `.playground`. So is every folder the root group lists in
  `explicitFolders` (file type `folder`: copied whole as a resource).
- `<region>.lproj/<file>` files become one `variantGroup` named `<file>`
  (empty `path`) whose children are the region files (`path`
  `<region>.lproj/<file>`, `regionVariantName` `<region>`). Its
  membership key is `/Localized: <folder path>/<file>`.
- File types come from `explicitFileTypes` (relative path → type), else
  the extension (`BuildFileTypes.byExtension`, the vocabulary of
  `lastKnownFileType`).
- GUIDs: project GUID + MD5 of `<root group id>/<relative path>` (files
  and groups) or `<root group id>/<membership key>` (variant groups).
  Build files: project GUID + MD5 of `<phase id>/<root group id>/<key>`.

**A target's members.** The folders a target reads: its
`fileSystemSynchronizedGroups`, then folders it does not list whose
`PBXFileSystemSynchronizedBuildFileExceptionSet` for the target names
files (those files only), then folders with a
`PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet` for one
of its phases. An item is a member of a folder's own target unless its
exception set's `membershipExceptions` names it or a folder above it; of
another target only when that list names it.

**The phase of a member**, by file type:

| Type | Phase |
|---|---|
| `sourcecode.*` except headers and module maps; Core Data models (`.xcdatamodeld`, `.xcdatamodel`), ML models (`.mlmodel`, `.mlpackage`), intent definitions, documentation catalogs | Sources |
| frameworks, XCFrameworks, static libraries, dylibs, `.tbd` | Frameworks (linked) |
| headers (`.h`, `.hpp`, `.hh`) | Headers, when the target has a Headers phase or the header is in `publicHeaders`/`privateHeaders` (`headerVisibility` `public`/`private`; otherwise project). Without either, not built (the build server still lists it as a project header for the index) |
| `.xcconfig`, `.entitlements`, module maps, `Info.plist`, `.xctestplan` | not built |
| everything else (asset catalogs, string catalogs, storyboards, `.strings`, variant groups, explicit folders, data files) | Resources |

A build-phase exception set moves the items it names into its phase (for
example a copy-files phase) and out of their default phase; a linked
library stays linked as well (**Ycode decision**: an embedded framework is
also linked). The exception set's `additionalCompilerFlagsByRelativePath`
becomes `additionalCompilerOptions`, `attributesByRelativePath`
(`CodeSignOnCopy`, `RemoveHeadersOnCopy`, `Weak`) the build file's
`codeSignOnCopy`, `removeHeadersOnCopy`, `shouldLinkWeakly`, and
`platformFiltersByRelativePath` its `platformFilters` (`{platform}`;
`maccatalyst` is `{platform: ios, environment: macabi}`).

**Missing phases (Ycode decision).** Members join the target's first
phase of their kind; when the target has none (generated or hand-written
projects with an empty `buildPhases`), a phase of that kind is added
after the target's own (GUID from `<target id>-ycode-synchronized-<type>`).
Command-line tools, static and dynamic libraries and host tools get no
added Resources phase (they have no bundle).

**Warnings (Ycode decision; no spec records the reference's behaviour).**
Before a build, for the built targets:

- `The synchronized folder “<folder>” of target “<target>” is missing
  (<path>); the target gets no files from it.`
- `Target “<target>” compiles no source files: its synchronized folders
  (“<folder>”, …) hold none that it builds.` — a native target (not a
  resource bundle, `com.apple.product-type.bundle`) that reads
  synchronized folders, has no build file in its Sources phases, gets no
  source from its folders and no generated source from a build-tool
  plug-in.

`ycode build --engine swift-build` and the IDE report them as warnings
(`PIFSource.pifWithWarnings`; `XcodePIFSource` answers it), ycodebuild
prints `warning: <text> (in target '<target>' from project '<project>')`
and records them in the result bundle's issues. The build still runs (the
reference builds such a target; OPEN QUESTION, dirty room: what the
reference tool reports for a synchronized target with no sources).

**Sample.** `ycode/Samples/SyncFolderSamples/SyncFolderSamples.xcodeproj`
(written by hand; no template copied):

| Target | Covers |
|---|---|
| `SyncTool` (macOS tool) | nested folder (`Model/`), a folder in `membershipExceptions` (`Excluded/`, whose files are `#error`), a file taken from the `Shared` folder it does not list, per-file compiler flags on a C file (`-DYCODE_SYNC_FLAG=7`, checked by `#error`), a bridging header |
| `SyncApp` (macOS app) | sources, an asset catalog, a string catalog, `.lproj` tables, `explicitFileTypes`, `explicitFolders` (`Docs`), a file moved into a copy-files phase (SharedSupport) |
| `SyncKit` (macOS framework) | public, private and project headers by `publicHeaders`/`privateHeaders` |
| `EmptyTool` (macOS tool) | a folder with no source: the warning |

Run, each product prints one `YCODE-SYNC-SAMPLE` line, for example `tool:
Hello from a nested synchronized folder from a shared folder [flag 7]`.
Tests: `SynchronizedFolderTests` (YcodeProjectTests),
`SynchronizedFolderPIFTests` and `SynchronizedFolderBuildTests` (builds
the sample with ycodebuild through swift-build when `ycode-swb` is found),
`SynchronizedFolderGraphTests` (the build server's sources and headers;
the navigator's file rows equal the folders' files).

## Package products, macros and plug-ins

Ycode modules: `YcodeXcodebuild` (`PackageGraphLoader`, `PackageGraphPIF`,
`ProjectPlugins`, `XcodeProjectPluginSource`, `XcodePIF`), `YcodeBuild`
(`PackageResolver`). Project-file objects: `specs/ide/package-dependencies.md`.

### The package graph

`PackageGraphLoader.load()` (no work when no project of the container has a
package reference):

1. **References.** Every project's `packageReferences`: local folders
   (`XCLocalSwiftPackageReference.relativePath`, relative to the folder
   holding the `.xcodeproj`) and remote repositories
   (`XCRemoteSwiftPackageReference`). A package's identity is its folder
   name, or the last URL component without `.git`, lowercased (SwiftPM's
   rule).
2. **Pins.** The container's `Package.resolved`
   (`<workspace>/xcshareddata/swiftpm/`, versions 1 to 3). When a remote
   reference has no pin, the graph is resolved first with Ycode's
   `PackageResolver` and the file is written
   (`package-dependencies.md` §Resolution), as before a build in the
   reference tool. Each pin is then checked out at its revision in
   `<SourcePackages>/checkouts/<identity>` (cloned or fetched only when
   needed; `PackageResolver.checkout(identity:location:revision:)`).
3. **The generated root.** `<SourcePackages>/ycode-package-graph/Package.swift`
   (tools version 5.9, rewritten only when it changes) declares a package
   `ycode-package-graph` with one `.package(path:)` per local reference,
   then one per pinned checkout whose identity no local package has. A
   local package therefore overrides a remote one of the same identity, as
   a root dependency overrides a transitive one in SwiftPM; SwiftPM warns
   about the "conflicting identity", and Ycode drops that warning and the
   ones about the root's unused dependencies. Remote dependencies of local
   packages that Ycode did not pin are resolved by SwiftPM itself in its
   scratch folder.
4. **SwiftPM's PIF.** `swift package --package-path <root> --scratch-path
   <SourcePackages>/ycode-package-graph-build dump-pif`. From its output
   Ycode keeps every package project and its targets as SwiftPM wrote them,
   and drops the workspace, the generated root's project and the
   "Aggregate" project (`AllIncludingTests`, `AllExcludingTests`).
5. **Products.** In each package project, a target named `<product>-product`
   is that product: `type` `packageProduct` for a static (or automatic)
   library product, `standard` with `productTypeIdentifier`
   `com.apple.product-type.library.dynamic` for a dynamic one, `…tool` for
   an executable; test products are aggregates and are never linked.
   Targets with `productTypeIdentifier` `com.apple.product-type.tool.host-build`
   (build-tool plug-ins) are recorded by name.

`<SourcePackages>`: ycodebuild uses `-clonedSourcePackagesDirPath`, else
`<DerivedData folder>/SourcePackages` (as `-resolvePackageDependencies`).
`XcodePIFSource` (the IDE, `ycode build`) uses
`~/Library/Caches/Ycode/SourcePackages/<project>-<hash>`, the folder of the
IDE's own checkouts (`PackageDependencyModel.defaultCheckouts`, same hash),
unless its `sourcePackagesDirectory` is set.

### Project targets that use products

`XcodePIF(container:packages:)` adds the kept package projects' signatures
to the workspace's `projects` after the container's own, and their objects
after the container's. In each project target:

| pbxproj | PIF |
|---|---|
| `PBXBuildFile.productRef` → `XCSwiftPackageProductDependency` (`package`, `productName`) in any phase | build file with `targetReference` = the product's PIF target GUID. The package is the one of the `package` reference's identity; without a `package` key (local packages, as some generators write them), the first package with that product. |
| target's `packageProductDependencies` | each product (not `plugin:` ones) is an explicit `dependencies` entry `{guid, platformFilters: []}` after the target dependencies. swift-build builds explicit dependencies on package products for the depending target's platform (specialization), and package targets take part in no implicit dependencies. |
| an application (`productType` `com.apple.product-type.application…`) linking a dynamic product that no copy-files phase of its own copies | an extra copy-files phase (Ycode decision): `destinationSubfolder` `$(FRAMEWORKS_FOLDER_PATH)`, the product by `targetReference`, `codeSignOnCopy` and `removeHeadersOnCopy` "true", appended after the target's phases. |

A product that a target depends on but no package of the graph provides
stops the load with `Missing package product '<name>'` (one line per
product), instead of a link failure later.

Without a package graph (`XcodePIF(container:)`, as `-showBuildSettings`
uses it) product build files and product dependencies are left out, as
before.

What swift-build then does from SwiftPM's package PIF (no Ycode code):

- **Static products** link the product's targets' objects into the client.
- **Resources.** A package target with resources has a resource-bundle
  target (`<Package>_<Target>.bundle`); the target imparts
  `EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES` to the targets that link it, and an
  application copies those bundles into its resources folder (on iOS the
  bundle root). `Bundle.module` (generated accessor) finds it there; a
  command-line tool finds it next to itself in the products folder.
- **Dynamic products** are `lib<Name>.dylib` in the products folder, with
  install name `@rpath/lib<Name>.dylib`; the application embeds it through
  the phase above, so `LD_RUNPATH_SEARCH_PATHS` `@executable_path/Frameworks`
  finds it. A tool finds it next to itself with `@executable_path`.
- **Macros.** A macro target (`.macro`) is a host-built tool target with
  `SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES`; swift-build builds it for the
  Mac whatever the client's platform, and passes `-load-plugin-executable
  <tool>#<module>` to every Swift compile of a target that depends on it,
  directly or not. With Swift 6.4, SwiftPM's PIF uses prebuilt swift-syntax
  modules for macro targets when they are available, so a macro package
  builds quickly.
- **Package targets' build-tool plug-ins.** SwiftPM runs them while it
  writes the PIF (plug-in compiled and run by SwiftPM, with its sandbox on
  macOS) and records their build commands as `customTasks` of the target,
  with the generated files in its sources phase; the plug-in's
  host-build target depends on its tools.

**Host tools path (Ycode decision).** SwiftPM names a plug-in's tools by
where its own build would put them, `<scratch>/out/Products/<configuration>/<tool>`.
swift-build builds them (for the host) into `$(BUILD_DIR)/$(CONFIGURATION)`
of the client's build. Every string of every `customTasks` entry
(`commandLine`, `inputFilePaths`, `environment`, the sandbox profile) has
that scratch prefix replaced with `$(BUILD_DIR)/$(CONFIGURATION)` (custom
task strings are macro expressions), and the target and its project get new
signatures (`<old>-ycode-<md5 of the rewritten tasks>`): SwiftPM's
signatures are content hashes, so an unchanged one would let swift-build
reuse a build description made from the original paths.

**Simulator destinations.** `SwiftBuildEngine` sends a simulator destination
as a run destination of that simulator's SDK (`platform` = `sdk` =
`iphonesimulator`, `xrsimulator`, …; `targetArchitecture` the host's;
`supportedArchitectures` arm64, x86_64; `disableOnlyActiveArch` true for a
generic destination), with no `SDKROOT` override (it was one before). An
`SDKROOT` override applies to every target, host tools included, so macro
implementations were built for the simulator and failed ("unable to resolve
module dependency: 'SwiftCompilerPlugin'"); with the run destination
swift-build builds targets that support the platform with its SDK, even
when the project's `SDKROOT` names the device SDK, and host tools for the
Mac. ycodebuild already sent run destinations.

### Plug-ins applied to project targets

A target applies a build-tool plug-in with a `PBXTargetDependency` whose
`productRef` names an `XCSwiftPackageProductDependency` with `productName`
`plugin:<plug-in product>` (the target's `packageProductDependencies` does
not list it). Ycode hosts such plug-ins itself (`ProjectPlugins`), after the
package graph is loaded:

1. **The plug-in.** The package of the dependency's `package` reference (or
   the first package with such a plug-in);
   `swift package dump-package` (no resolution; scratch in a temporary
   folder) gives the plug-in product's target, its folder (`path`, default
   `Plugins/<target>`), its dependencies (the names the plug-in may pass to
   `tool(named:)`) and the tools version.
2. **Compiling it**, as SwiftPM compiles plug-ins: the toolchain's `swiftc`
   (on the Mac `xcrun --find swiftc`) with `-parse-as-library`,
   `-swift-version` 6 for tools version 6 and later (else 5),
   `-package-description-version <tools version>`, `-I`/`-L`/`-rpath` the
   toolchain's `usr/lib/swift/pm/PluginAPI` and `-lPackagePlugin`, `-sdk`
   the macOS SDK, the plug-in's Swift files, plus Ycode's
   `XcodeProjectPlugin` module (below). Output:
   `<SourcePackages>/ycode-plugins/<package>-<target>-<hash>`, the hash
   covering the sources, the compiler and the support module, so a
   plug-in is compiled once.
3. **The request** (SwiftPM's open plug-in protocol: each message an
   8-byte little-endian length and JSON): `createXcodeProjectBuildToolCommands`
   with a context whose `xcodeProjects` is the project (display name,
   directory, every input file) and whose `xcodeTargets` are its targets
   (display name; product name and kind `application`, `executable`,
   `framework`, `library` or `other`; input files = the files of the
   target's build phases, typed `source`, `header`, `resource` or `unknown`
   by phase), `rootProjectId` 0, `targetId` the target's index; the plug-in
   work folder `<SourcePackages>/ycode-plugins/outputs/<project>/<target>/<plug-in>`;
   tool search folders the toolchain's `bin`; each accessible tool named
   `<scratch>/out/Products/Debug/<tool>` (relocated like SwiftPM's). Paths
   are written as absolute entries with no base. The plug-in runs in its
   package's folder.
4. **Ycode's `XcodeProjectPlugin` module** (`XcodeProjectPluginSource`,
   compiled into `<SourcePackages>/ycode-plugins/support-<hash>/`). Plug-ins
   for project targets import a module of that name (an interoperability
   identifier) and conform to `XcodeBuildToolPlugin`
   (`createBuildCommands(context: XcodePluginContext, target: XcodeTarget)`);
   the public types follow Apple's public documentation:
   `XcodePluginContext` (`xcodeProject`, `pluginWorkDirectoryURL`,
   `pluginWorkDirectory`, `tool(named:)`), `XcodeProject` (`id`,
   `displayName`, `directoryURL`, `directory`, `filePaths`, `targets`),
   `XcodeTarget` (`id`, `displayName`, `product`, `inputFiles`,
   `pluginGeneratedSources`, `pluginGeneratedResources`), `XcodeProduct`
   (`id`, `name`, `kind`), `XcodeCommandPlugin`. The open-source runtime
   decodes the request into an invocation record and calls the C entry
   point `call_XcodeProjectPlugin_build_command_creation_entry_point` (and
   `…_custom_command_entry_point`), which the module defines. The record's
   type is in the runtime's SPI, which the toolchain's public interface does
   not carry, so the module reads the record by reflection (its stored
   properties as the open source declares them), calls the plug-in, and
   writes the commands as JSON
   (`[{kind: build|prebuild, displayName, executable, arguments,
   environment, inputFiles, outputFiles, outputFilesDirectory}]`) to the file
   named by `YCODE_PLUGIN_COMMANDS`, which Ycode sets and reads after the
   plug-in exits. `PluginContext.Tool` has no public initializer: the
   module builds one from a value with the same stored properties (`name`,
   `url`, the path) and checks its size, name and URL before use (Ycode
   decision; an error names the mismatch otherwise). Diagnostics the
   plug-in emits come back over the protocol and are kept.
5. **Into the PIF.** Each build command becomes a `customTasks` entry of
   the target (`commandLine` executable and arguments, `environment` as
   sorted pairs, `workingDirectory`, `executionDescription` the display
   name, `inputFilePaths` executable and inputs, `outputFilePaths`,
   `enableSandboxing` "false", `preparesForIndexing` "true"), host-tool
   paths relocated; prebuild commands run at once and the files in their
   output folder count as outputs. Outputs that are sources (`.swift`, `.c`,
   `.m`, `.mm`, `.cpp`, `.cc`, `.cxx`, `.s`) join the target's sources
   phase, other non-header outputs its resources phase, through file
   references with absolute paths in a group "Plug-in Outputs" appended to
   the project's group tree. The plug-in's host-build target (in the
   package PIF) becomes a dependency of the target, so its tools are built
   first, for the Mac.

The open-source runtime calls the project-plug-in entry point only on
Darwin (elsewhere it stops with a fatal error), so plug-ins of project
targets build only on a Mac; on Linux `XcodePIFSource.supports` is false
for such a project. Package targets' plug-ins work wherever SwiftPM runs
them. Trust prompts for macros and plug-ins are not part of this
(SwiftPM's PIF marks targets `approvedByUser` "true"); they belong to a
later round (PIF-PLUGINS).

### Samples

`ycode/Samples/PackageSamples/PackageSamples.xcodeproj`, with local
packages in `Packages/`:

| Target | Platform | Uses |
|---|---|---|
| `LocalPackageApp` | iOS | `LocalKit` (static, resource read with `Bundle.module`), `LocalKitDynamic` (dynamic) |
| `RemotePackageApp` | iOS | `Algorithms` from swift-algorithms (remote, Apache-2.0; swift-numerics comes with it) |
| `MacroApp` | iOS | `GreetMacros` (`#greeting`, a macro on swift-syntax, Apache-2.0, fetched by SwiftPM) |
| `PluginApp` | iOS | `Codegen` (its target uses `CodegenPlugin`) and `plugin:CodegenPlugin` applied to the app target (`AppMessages.codegen`) |
| `PackageSamplesMac` | macOS tool | every product above |

Each iOS app prints one line starting `YCODE-PKG-SAMPLE` to standard error at
launch and shows the same text. Build them with
`ycode build Samples/PackageSamples/PackageSamples.xcodeproj -scheme <target>
-destination 'platform=iOS Simulator' --engine swift-build` (or ycodebuild
with `-destination 'platform=iOS Simulator,arch=arm64'`).

### Product layout compared with the reference tool

Ycode takes the layout from SwiftPM's PIF: dynamic products are
`lib<Name>.dylib` in the products folder and in the app's `Frameworks`; the
reference tool's own package PIF wraps a dynamic product in a framework
(`PackageFrameworks/<Name>.framework` per its build logs and coverage
report paths, `specs/xcodebuild/packages.md` §3). OPEN QUESTION (dirty
room): the reference tool's product layout and embedding for static and
dynamic package products in an application (framework or dylib, folder,
whether it embeds dynamic products with no copy-files phase in the
project), and its settings for package targets.

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

A simulator destination (`platform=iOS Simulator`, `generic/platform=visionOS
Simulator`, also `xrOS Simulator`, `tvOS Simulator`, `watchOS Simulator`)
is a run destination of the simulator's SDK (`iphonesimulator`,
`xrsimulator`, `appletvsimulator`, `watchsimulator`): `platform` and `sdk`
the SDK, `targetArchitecture` and `activeArchitecture` the host's,
`supportedArchitectures` ["arm64", "x86_64"], `disableOnlyActiveArch` true
for a generic destination (every architecture). Targets whose
`SUPPORTED_PLATFORMS` include the simulator are built with its SDK even
when the project's `SDKROOT` names the device SDK (`xros`, visionos.md
§10.21); host tools (macros, plug-in tools) are built for the Mac. A
`SDKROOT=…` on the command line is passed as given. (Until PIF-PKG this was
an `SDKROOT` override with no run destination, which also built host tools
for the simulator; see "Package products, macros and plug-ins".)

Builds go through the `ycode-swb` helper when it is found, which answers
swift-build's provisioning questions (`signing.md` §6); such requests
override only `SDK_STAT_CACHE_ENABLE=NO`, so the project's signing
settings and entitlements apply. Without the helper, `swbuild` requests
carry these overrides, plus the request's `NAME=value` settings:

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
- Package products, macros and plug-ins (all level 1 unless noted):
  - SwiftPM's PIF of a package graph (`swift package dump-pif`; product
    targets `<product>-product`, `packageProduct` targets, resource-bundle
    targets, imparted `EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES`, macro targets,
    plug-in invocation while writing the PIF, custom tasks, the
    `<scratch>/out/Products/<configuration>` tool folder, content-hash
    signatures): swift-package-manager `release/6.4.x`,
    `Sources/SwiftBuildSupport` (`PIFBuilder.swift`,
    `PackagePIFBuilder*.swift`, `PackagePIFProjectBuilder*.swift`),
    Apache-2.0; output inspected with the toolchain's SwiftPM (level 3,
    Ycode's own packages).
  - Package products in swift-build (`PackageProductTarget`, explicit
    dependencies on package products and their specialization, no
    implicit dependencies for package targets, macro descriptors from
    `SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES` and `-load-plugin-executable`,
    `CopySwiftPackageResourcesTaskProducer`, custom-task strings as macro
    expressions, build-description signatures from object signatures,
    run-destination SDK choice): swift-build at the pinned revision
    (`SWBCore` `ProjectModel/Target.swift`, `ProjectModel/BuildFile.swift`,
    `TargetDependencyResolver.swift`, `DependencyResolution.swift`;
    `SWBTaskConstruction` `ProductPlanning/ProductPlan.swift`,
    `CopySwiftPackageResourcesTaskProducer.swift`; `SWBTaskExecution`
    `BuildDescriptionSignature.swift`), Apache-2.0.
  - The plug-in protocol and its runtime (`HostToPluginMessage`,
    `PluginToHostMessage`, framing, the invocation record and the
    `call_XcodeProjectPlugin_*` entry points, how SwiftPM compiles a
    plug-in): swift-package-manager `release/6.4.x`,
    `Sources/Runtimes/PackagePlugin` and
    `Sources/SPMBuildCore/Plugins/DefaultPluginScriptRunner.swift`,
    Apache-2.0.
  - `plugin:` product dependencies on a `PBXTargetDependency.productRef`:
    the open-source project-file libraries XcodeProj (MIT) and XcodeGen
    (MIT) write and read them this way.
  - `XcodeProjectPlugin`'s public types and members: Apple's public
    developer documentation (level 1).
  - Black-box runs (level 3, Ycode only): the samples above built with
    ycodebuild and with `ycode build --engine swift-build` for the iOS
    Simulator SDK (arm64, platform 7) and for macOS; the macOS tool printed
    the resource text, the dynamic library's text, the remote package's
    chunks, the macro's expansion and the plug-in's generated constant; the
    application bundle held `LocalKit_LocalKit.bundle` and
    `Frameworks/libLocalKitDynamic.dylib`. Before the run-destination
    change the macro sample failed for the simulator; before the
    relocation the plug-in sample failed with "Build input file cannot be
    found: …/out/Products/Debug/codegen-tool"; with SwiftPM's original
    signatures the relocated tasks were ignored (a cached build
    description).
  - On Ycode's simulator (level 3, Ycode only): the four iOS apps, built
    with `ycode build --engine swift-build`, were installed and launched
    on an iPhone 18 Pro device (iOS 27.0 runtime) on the arm64 Linux host,
    one cold boot each (`--install-app`/`--launch`). Each printed its line:
    `local: Hello from LocalKit's resource bundle; dynamic library product
    loaded`, `remote: [1, 2] [3, 4] [5, 6]`, `macro: Hello, Ycode! (expanded
    by a macro)`, `plugin: Generated in the package by a build-tool
    plug-in; Generated in the app target by a build-tool plug-in`; the
    frames showed the same text in the app.
- OPEN QUESTION: which of Xcode's package build settings matter for
  matching its build output.
- Synchronized folders (IDE-SMALL): the keys and their meaning are
  `specs/formats/pbxproj.md` §Synchronized folders (levels 1 and 2); the
  phase table, the added phases and the warnings are Ycode decisions; the
  sample was built with ycodebuild and `ycode build --engine swift-build`
  through swift-build (level 3, Ycode only): the tool printed the shared
  file's text and flag 7, the app bundle held `Assets.car`, `en.lproj` and
  `de.lproj` `Extra.strings`, `en.lproj/Localizable.strings` (from the
  string catalog), `note.txt`, the `Docs` folder and
  `SharedSupport/extra.txt`, the framework `Headers/SKGreeter.h`,
  `Headers/SyncKit.h` and `PrivateHeaders/SKPrivate.h` only.
