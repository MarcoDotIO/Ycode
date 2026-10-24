# xcodebuild: Swift package folders

Ycode: `YcodeXcodebuild` (`SwiftPackage`, `PackageCommands`). Applies when
the working directory has a `Package.swift`, no `.xcodeproj` or
`.xcworkspace`, no `-project`/`-workspace`, and the command is `-list`,
`-showBuildSettings` or has `-scheme`. (Other commands keep the "does not
contain an Xcode project" error of `cli.md` §4.) The package folder is
not written to.

## 1. Reading the package

ycodebuild runs the toolchain's open-source SwiftPM
(`<toolchain>/usr/bin/swift package --package-path <dir> --scratch-path
<tmp>/ycodebuild-spm/<hash> …`): `describe --type json` (name, products
with their type and targets, targets with type, folder and dependencies),
`show-dependencies --format json` (dependency names, paths or URLs,
versions) and, for builds, `dump-pif` (the build description swift-build
loads; its target names are the ones the reference tool's logs show:
`Greeter`, `greet-product`, `GreeterTests-product`).

## 2. Output

After the "Command line invocation" header (not with `-quiet`/`-json`):

    Resolve Package Graph
    <blank>
    <blank>
    Resolved source packages:
      <Package>: <folder>
      <Dependency>: <folder> @ local        (local packages; others @ <version>)
    <blank>

The reference tool prints the package and its dependencies in an order
that varies between runs. Folders are printed with the `/private` prefix
removed (`result-bundle.md` §1).

**Schemes**: one per product (implicit executable products included),
plus `<Package>-Package` when there is more than one product, sorted as
Finder sorts names (`greet`, `GreetKit`, `Tools-Package`). `-list`:

    Information about workspace "<Package>":
        Schemes:
            <scheme>
    <blank>

`-list -json`: `{"workspace": {"name": <Package>, "schemes": [...]}}`.

**Errors** (after the package report):

| Situation | Message | Exit |
|---|---|---|
| `-showBuildSettings` without `-scheme` | `Unable to open workspace '<cwd as given>', and no scheme name was provided.` | 65 |
| unknown scheme | the workspace form of `cli.md` §4 | 65 |
| test action on a scheme without tests | `Scheme <name> is not currently configured for the test action.` | 66 |
| build action without `-destination` | `Building a Swift package requires that a destination is provided using the "-destination" option. The "-showdestinations" option can be used to list the available destinations.` | 70 |

**`-showBuildSettings -scheme`** prints no settings (text: nothing after
the package report; `-json`: an empty array), as the reference tool does
for package schemes.

**Destination warning**: for `-destination platform=macOS[,arch=…]` the
`Using the first of multiple matching destinations` warning lists My Mac
in each matching architecture, then with the Mac Catalyst variant, the
DriverKit variant and the "Designed for [iPad,iPhone]" variant (arm64,
and without `arch` also `arm64e.x1`, `arm64_32`; the reference tool's
order of these last two varies).

## 3. Building and testing

| Scheme | Builds (build-description targets) | Tests |
|---|---|---|
| a product | its product target (`<product>-product`) | the package's test targets when the product is the primary one (the first executable product, else the first product); otherwise none |
| `<Package>-Package` | every product's product target | every test target |

Test targets build as their product targets (`<test>-product`, unit-test
bundles). Configuration `Debug` unless `-configuration`. Build locations:
`-derivedDataPath`, else `~/Library/Developer/Xcode/DerivedData/<Package>-<hash
of the package folder path>` (`show-build-settings.md` §4). Builds,
logs, banners, test runs, result bundles and exit statuses then follow
`build-actions.md`, `test-actions.md` and `result-bundle.md`, with
"workspace" where those say "project" (`Testing workspace Greeter with
scheme Greeter`, `Building workspace … with scheme …`). Test runs of
package schemes gather code coverage unless `-enableCodeCoverage NO`
(`coverage.md`). The coverage report lists:

1. each library product of the scheme (not executables), named like the
   product, with no files and 0 of 0 lines; its product path is
   `<products>/PackageFrameworks/<name>_<hash>_PackageProduct.framework/<name>_<hash>_PackageProduct`,
   `<hash>` being the one in the PIF target GUID
   `PACKAGE-TARGET:<name>-<hash>-dynamic` that SwiftPM's `dump-pif`
   prints (it may start with `-`, as in `GreetKit_-5A022E1B30D510D9_PackageProduct`);
2. then each test target with a test bundle, named like the target, with
   the bundle executable as product path and the files in the target's
   folder only (the library sources are not reported).

The report's totals are the sums of these.

## 4. -resolvePackageDependencies

`xcodebuild -resolvePackageDependencies [-project|-workspace]
[-clonedSourcePackagesDirPath <dir>]` (also in a package folder). The
source-packages folder is `<dir>`, else `<DerivedData folder>/SourcePackages`.

- Projects and workspaces: the remote references of every project
  (`XCRemoteSwiftPackageReference`, `specs/ide/package-dependencies.md`)
  are resolved with Ycode's `PackageResolver` (git and SwiftPM's public
  command line; checkouts in `<source packages>/checkouts/<identity>`), and
  `Package.resolved` (version 3) is written in the project's (or
  workspace's) `xcshareddata/swiftpm/`. Local references need nothing.
- Package folders: SwiftPM's `swift package resolve` with the
  source-packages folder as its scratch path (it holds `artifacts/`,
  `checkouts/`, `repositories/`, `workspace-state.json`, as in the
  reference tool's folder).

Output (stdout): the header, the `Resolve Package Graph` report (§2;
remote packages as `  <name>: <url> @ <version>`), then

    resolved source packages: <names in the report's order, separated by ", ">

(with nothing after the colon and its space when there are no packages);
exit 0. A resolution failure is an `xcodebuild: error:` line naming the
conflicting requirements, exit 65.

## 5. -showdestinations

`-showdestinations -scheme <scheme>` lists only compatible destinations
(packages build for every platform), with no incompatible section and no
blank line after the list:

1. My Mac (`platform:macOS, arch:<host>, id:<provisioning UDID>,
   name:My Mac`), then My Mac with `variant:Mac Catalyst`,
   `variant:DriverKit` and `variant:Designed for [iPad,iPhone]` (arm64
   hosts), each when the platform SDK it needs is installed (iOS,
   DriverKit, iOS);
2. physical devices that have a connection (`xcrun devicectl list
   devices`: a `transportType`; a paired watch without one is left out):
   `platform, arch, id, name`, `arch` being the CPU type with `arm64e`
   listed as `arm64`;
3. the generic destinations of the installed platforms, in this order:
   `{ platform:DriverKit, name:Any DriverKit Host }`, `{ platform:iOS,
   id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS
   Device }`, `{ platform:iOS Simulator,
   id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder,
   name:Any iOS Simulator Device }`, `{ platform:macOS, name:Any Mac }`,
   `{ platform:macOS, variant:Mac Catalyst, name:Any Mac }`, then tvOS,
   visionOS and watchOS like iOS (`DVTiOSDevicePlaceholder-<sdk>` for
   devices, `DVTiOSDeviceSimulatorPlaceholder-<simulator sdk>`; SDKs
   `appletvos`, `xros`, `watchos`, `appletvsimulator`, `xrsimulator`,
   `watchsimulator`);
4. the simulators as in `info-commands.md` §5.

## Evidence

- Every observable above: black-box `xcodebuild` 27.1 runs in three
  hand-written packages (a library with tests, a library and a tool with
  tests, a tool using the first package by path) (level 3); build
  targets read from the reference logs' target names and dependency
  graphs.
- SwiftPM commands and the PIF they print: open source (level 1).
- OPEN QUESTION: the primary-product rule for test targets (observed for
  one package with a library and an executable, one with a single
  library).
- Package coverage (§3): result bundles of the reference tool for the
  `Greeter`, `Tools-Package` and `greet` schemes read with `xccov view
  --report --json` (level 3); the framework name's hash compared with the
  GUIDs of SwiftPM's `dump-pif` (open source, level 1). The harness
  compares the report and every file's lines for these three schemes:
  identical (`conformance.md`).
- OPEN QUESTION: products with several targets, and test targets without
  a bundle, in the coverage report (not observed).
- `-showdestinations` (§5): black-box runs on two package folders,
  compared with ycodebuild's output line by line: identical. Device and
  simulator data from `xcrun devicectl list devices` and `xcrun simctl
  list -j devices|runtimes` (read-only). The reference tool sometimes
  prints no simulators at all (2 of 7 runs, also in project mode), a
  timing effect of its device discovery; ycodebuild always lists them.
- OPEN QUESTION: which SDKs gate the variants and generic destinations
  (all were installed), and devices of other platforms or with other CPU
  types.
- `-resolvePackageDependencies` output, summary line, and the
  source-packages folder layout: black-box runs on a project with a local
  package reference and on a package folder with a local dependency
  (level 3). Remote references could not be observed without network;
  their report line follows the `-list` report format
  (`info-commands.md` §2.3), and resolution is Ycode's
  (`specs/ide/package-dependencies.md`).
- OPEN QUESTION: the reference tool also creates an empty
  `xcshareddata/swiftpm/configuration` folder in the project; for
  projects it fills `artifacts/`, `repositories/` and
  `workspace-state.json`, which ycodebuild does not write.
