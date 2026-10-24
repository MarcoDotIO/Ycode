# xcodebuild: -version, -list, -showsdks, -showdestinations, -showTestPlans

Ycode: `YcodeXcodebuild` (`InfoCommands`, `SDKRegistry`, `Container`,
`AutocreatedScheme`, `PackageReport`, `Destinations`). Grammar and errors:
`cli.md`. JSON output everywhere is pretty-printed with two-space
indentation, `"key" : value` (space on both sides of the colon), keys sorted
the way Foundation's `JSONSerialization` sorts them (`.sortedKeys`: case-
insensitive, numeric-aware; `__ARCHS__` sorts before `ACTION`), `/` not
escaped, followed by one newline. ycodebuild produces it with
`JSONSerialization` options `[.prettyPrinted, .sortedKeys,
.withoutEscapingSlashes]`, which gives the same bytes on macOS.

## 1. -version

Two lines on stdout, exit 0:

    <product> <version>
    Build version <build>

The reference tool prints its own product name, marketing version and build
number. **ycodebuild prints Ycode's** (`Ycode 0.1` / `Build version
0.1.0-dev`) in the same two-line shape, so scripts that parse the shape keep
working but can tell the tools apart. `-json` and info items are ignored
without `-sdk`.

`-version -sdk` (no SDK name): one block per SDK (in `-showsdks` order),
each followed by a blank line, then the two version lines.

`-version -sdk <name>`: the block for that SDK and a blank line. The name is
a canonical name (`macosx27.0`), a platform name (`macosx`, the newest
version), or an SDK path. Unknown: `SDK "<name>" cannot be located.`
(exit 64).

`-version -sdk <name> <item>`: only the value of that block line, or
nothing (exit 0) if the block has no such key.

`-version -sdk [<name>] -json`: the JSON array of `-showsdks -json` (all
SDKs, or the selected one).

Block format:

    <bundle name> - <DisplayName> (<CanonicalName>)
    SDKVersion: <Version>
    Path: <SDK path, using the bundle name>
    PlatformVersion: <platform Version>
    PlatformPath: <platform directory>
    <SystemVersion.plist key>: <value>      (one line per key, keys sorted by byte order)

| Field | Source (SDK metadata files) |
|---|---|
| bundle name | the `*.sdk` entry in `<platform>/Developer/SDKs` (see §3 for which names are listed) |
| DisplayName, Version, CanonicalName, IsBaseSDK | the SDK's `SDKSettings.json` |
| platform Version, Name, Description | the platform's `Info.plist` |
| BuildID, ProductBuildVersion, ProductCopyright, ProductName, ProductUserVisibleVersion, ProductVersion, iOSSupportVersion | the SDK's `System/Library/CoreServices/SystemVersion.plist` (absent for DriverKit) |

## 2. -list

Opens the container (`cli.md` §4 for discovery errors). In a directory
without `-project`/`-workspace`, a single `.xcodeproj` is used; when there
is none and exactly one `.xcworkspace`, the workspace (also when `-scheme`
is given).

Project, text:

    Information about project "<name>":
        Targets:
            <target>                    (project order)

        Build Configurations:
            <configuration>             (configuration list order)

        If no build configuration is specified and -scheme is not passed then "<defaultConfigurationName>" is used.

        Schemes:
            <scheme>

(then one blank line). A project with no schemes at all prints
`    This project contains no schemes.` instead of the Schemes list.

Workspace, text:

    Information about workspace "<name>":
        Schemes:
            <scheme>

JSON: `{"project": {"configurations", "name", "schemes", "targets"}}` or
`{"workspace": {"name", "schemes"}}`. No header with `-json`.

### 2.1 Which schemes

Sorted with Finder-like ordering (`localizedStandardCompare`), each name once:

1. For a workspace: the workspace's own schemes. For each project of the
   container (a workspace's projects; for a project, itself): shared schemes
   (`xcshareddata/xcschemes/*.xcscheme`) and the current user's
   (`xcuserdata/<user>.xcuserdatad/xcschemes`).
2. A project that has **no scheme files at all** gets one generated scheme
   per target, named like the target, except test bundles
   (`…bundle.unit-test`, `…bundle.ui-testing`) that have a host target
   (`TargetAttributes.<id>.TestTargetID`): those join the host's scheme as
   testables. A generated scheme builds the target for every action
   (test bundles only for testing and analyzing), runs it if it is an
   application or tool, uses Debug except for profile/archive (Release),
   and its test action asks for an automatic test plan.
3. Each Swift package stored with the project adds one scheme per library
   or executable product. Such a package is either an
   `XCLocalSwiftPackageReference` (its `relativePath` is relative to the
   directory holding the `.xcodeproj`) or a file reference of type `wrapper`
   or `folder` whose directory holds a `Package.swift`. Remote packages add
   no schemes. A package added as a folder (whether or not it is also an
   `XCLocalSwiftPackageReference`) also adds one scheme per test target
   whose name is not `<product>Tests` for one of its products (such a
   test target belongs to that product's scheme); package references
   alone add no test-target schemes.

### 2.2 Generated vs. stored schemes

Generated schemes are not written to disk (black-box: no `xcuserdata`
appears after `-list`).

### 2.3 Package report

When the container uses packages, non-quiet output (all commands that open
a container) starts, after the invocation header, with:

    Resolve Package Graph
    <blank>
    <blank>
    Resolved source packages:
      <name>: <location> @ <state>
    <blank>

`<state>` is `local` for an `XCLocalSwiftPackageReference`, the pinned
version for a remote package (or `branch (abcdef0)`, or a 7-digit
revision), and the ` @ …` part is absent for a package added as a folder
(also when the same folder is also a package reference).
Order: the project's `packageReferences` order, then remaining pins.
ycodebuild does not resolve packages: remote entries come from the
`Package.resolved` of the container (`…/project.xcworkspace/xcshareddata/
swiftpm/Package.resolved` or `X.xcworkspace/xcshareddata/swiftpm/…`), and
their names from the package manifests of an existing checkout under
`DerivedData/<folder>/SourcePackages/checkouts`, else the repository name.

## 3. -showsdks

One section per platform, sections ordered by the platform `Description`
(case-insensitive): `DriverKit`, `iOS`, `iOS Simulator`, `macOS`, `tvOS`,
`tvOS Simulator`, `visionOS`, `visionOS Simulator`, `watchOS`, `watchOS
Simulator`:

    <Description> SDKs:
    \t<DisplayName padded with spaces to 30 characters>\t-sdk <CanonicalName>
    <blank>

Listed SDK entries: every `*.sdk` name in `<platform>/Developer/SDKs`,
except an unversioned name (no digit, e.g. `MacOSX.sdk`) when a versioned
name (`MacOSX27.0.sdk`, `MacOSX27.sdk`) resolves to the same directory. So
macOS appears twice when both `MacOSX27.0.sdk` and `MacOSX27.sdk` exist.
The reference tool's order of such duplicates varies between runs;
ycodebuild sorts by bundle name.

`-json`: an array of objects with `canonicalName`, `displayName`,
`isBaseSdk` (boolean), `platform` (platform `Name`), `platformPath`,
`platformVersion`, `sdkPath`, `sdkVersion`, plus every `SystemVersion.plist`
key with its first letter lowered (`buildID`, `productBuildVersion`,
`productCopyright`, `productName`, `productUserVisibleVersion`,
`productVersion`; `iOSSupportVersion` unchanged).

## 4. -showTestPlans

    Test plans associated with the scheme "<scheme>":
            <plan>

(8 spaces). Plans are the scheme's `TestPlanReference`s (file name without
`.xctestplan`); a scheme without any lists its own name.

## 5. -showdestinations

Requires a scheme (`cli.md` §4). After the header: two blank lines, then

    \tDestinations compatible with the "<scheme>" scheme:
    \t\t{ key:value, key:value, … }
    <blank>
    \tDestinations incompatible with the "<scheme>" scheme:
    \t\t{ …, error:<reason> }
    <blank>

Keys in order: `platform` (`macOS`, `iOS`, `iOS Simulator`, …), `arch`,
`id`, `OS` (simulators), `name`, `error`. My Mac's `id` is the Mac's
provisioning UDID (`system_profiler SPHardwareDataType`); `{ platform:macOS,
name:Any Mac }` follows My Mac. Incompatible entries carry
`error:<name>’s <platform> platform doesn’t match <scheme>’s supported
platforms. You can change <scheme>’s Base SDK or Supported Platforms to
support <name>.` Devices come first, then simulators grouped tvOS,
visionOS, watchOS, iOS, by name in byte order (`iPad Pro` before `iPad
mini`), then OS version; `OS` is the runtime's full version from `xcrun
simctl list -j runtimes` (`26.4.1`, not the `26.4` of the runtime
identifier). Physical devices are those with a connection (§5 of
`packages.md`); a compatible device's `arch` lists `arm64e` as `arm64`,
an incompatible one shows its CPU type (`arm64e`). In errors the scheme is
named by its first buildable (`Hello.app`, `CalcTests.xctest`). No blank
line follows the last list. `-json` does not change this output. Sources:
`xcrun simctl list -j devices|runtimes` and `xcrun devicectl list
devices` (read-only). Package schemes: `packages.md` §5.

## Evidence

- Output shapes, keys, ordering, the "no schemes" and package-report
  formats, scheme generation (including the test-host rule and that nothing
  is written), the SDK listing rule and its nondeterministic order: black-box
  runs of `xcodebuild` 27.1 on hand-written samples and the 24-project local
  corpus (level 3), see `conformance.md`.
- SDK and platform metadata keys: the installed SDKs' `SDKSettings.json`,
  `SystemVersion.plist` and platform `Info.plist` files (level 2, data files).
- JSON key order equals Foundation `JSONSerialization` `.sortedKeys` output:
  checked on the 493 keys of a `-showBuildSettings -json` run (level 3).
- DerivedData `SourcePackages/checkouts` location: observed directory layout
  (level 3).
- OPEN QUESTION: the test-target schemes the reference tool adds for some
  local packages (it listed two of three test targets of one package, and no
  `<package>-Package` scheme); ycodebuild lists products only.
- The package report's order beyond direct references is not fixed: two
  projects with the same packages list them in different orders, and the
  order varies between runs (level 3); the harness compares that block
  without order.
- Test-target schemes of folder-added packages: black-box `-list` runs on
  hand-written projects with a local package added as a reference only,
  and as a folder too, with test targets named after a library product,
  an executable product, a non-product target and neither (level 3);
  the two large corpus projects then match.
- `-showdestinations` details (byte order, runtime versions, device
  `arch`, buildable name in errors, no final blank line): black-box runs
  on an application, a library-with-tests and a tool project: identical
  line by line (level 3).
- OPEN QUESTION: the exact compatibility rules for multi-platform
  targets, and Mac Catalyst / "Designed for iPad" entries of iOS
  applications in project mode.
- OPEN QUESTION: `-list` in a directory with both a project and a workspace.
