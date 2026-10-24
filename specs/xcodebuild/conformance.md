# ycodebuild conformance harness and results

Script: `ycode/scripts/xcodebuild-conformance.py` (run with `python3 -I`).
It runs `xcodebuild` and `ycodebuild` with the same arguments in the same
directory and compares stdout, stderr and exit status. Reference results
are cached (default `ycode/.build-xcb-scratch/conformance/`, git-ignored),
so later runs execute only ycodebuild; `--refresh` re-runs the reference.
Only read-only commands run against corpus projects (nothing is built in
them and no DerivedData is written).

Inputs: `YCODE_PBXPROJ_CORPUS` (manifest, one `= path` or `~ path` per
line, as for the project-I/O corpus tests), `YCODE_SWB` (the helper).
Projects inside an application bundle are skipped: the clean-room rules
forbid opening the reference application.

Normalization: the tool path in the "Command line invocation" header;
stderr lines from the reference tool's own logging (time-stamped
`xcodebuild[pid]` lines) and ycodebuild's own `ycodebuild: warning:` lines.
Settings comparisons skip `PATH` (its first element names the build
service's location). Error cases compare the first `xcodebuild: error:`
line and the exit status.

## Cases

| Kind | Per | Compared |
|---|---|---|
| `showsdks`, `showsdks-json`, `version-sdk`, `version-sdk-name`, `version-sdk-item` | machine | exact text; JSON and `-version -sdk` blocks as multisets (their order varies in the reference tool) |
| `error:*` (12 grammar and container errors) | machine | first error line + exit status |
| `list`, `list-json` | project | exact text / equal JSON |
| `showBuildSettings` | project | target list, exit status, every value |
| `showBuildSettings-json-alltargets-{Debug,Release}` | project | the same, all targets |
| `showBuildSettings-json-scheme` | first two schemes that name a target | the same, with DerivedData and destinations |
| `error:unknown-target`, `error:unknown-scheme` | project | first error line + exit status |

## Results (re-run 2026-10-17, 24 projects; reference xcodebuild 27.1 / 27A9269)

| Kind | Runs | Identical |
|---|---:|---:|
| showsdks, showsdks-json, version-sdk (3 forms) | 5 | 5 |
| error cases (machine) | 12 | 12 |
| error:unknown-target / unknown-scheme | 48 | 48 |
| list | 24 | 24 |
| list-json | 24 | 24 |
| showBuildSettings (targets, status, all values) | 24 | 24 |
| showBuildSettings -json -alltargets Debug | 24 | 24 |
| showBuildSettings -json -alltargets Release | 24 | 24 |
| showBuildSettings -json -scheme | 26 | 26 |

Settings compared: 111,310 values printed by the reference tool; 111,310
equal, 0 different, 0 missing, 0 extra names.

`-list` output is compared with the resolved-package lines as an
unordered block (their order is not fixed in the reference tool,
`info-commands.md` §2.3). The harness points ycodebuild at the built
`ycode-swb` helper when `YCODE_SWB` is not set (without it ycodebuild
shows only project-defined settings).

Not covered by the corpus cases (machine-dependent or writes files):
`-version` (different by design), `-showdestinations` (the device list
changes; black-box runs instead, below), builds; builds are the
`--builds` cases below.

`-showdestinations` (black-box, same machine state for both tools, scratch
DerivedData): package schemes `Greeter` and `greet`, project schemes
`Hello` (application), `CalcTests` and `Tool`: all 5 identical line by
line once the reference listed its simulators (it printed none in 2 of 7
runs, `packages.md` §5 Evidence).

## Build cases (`--builds`)

`python3 -I scripts/xcodebuild-conformance.py --builds` writes
hand-written samples (a library with an XCTest + swift-testing bundle, a
macOS app, a C tool, the tool with a compile error, an app with a String
Catalog and a localized `.strings` file, three Swift package folders and a
project with a local package reference) and export-options plists, twice:
one copy for each tool, each with its own DerivedData, result bundles and
archives (the reference tool's copy in the system temporary directory: its
test runner cannot load bundles from some external volumes). Corpus
projects are never built. Reference observations are cached in
`builds-reference.json`, ycodebuild's in `builds-ycodebuild.json`;
`--refresh --only <kind>` re-runs one kind (export cases need
`archive-app` in the same run). Neither tool writes outside the work
directories: cases without `-derivedDataPath` get
`-IDECustomDerivedDataLocation=<work>/dd/default` (`cli.md`), removed
again from the echoed invocation line; every archive case names its
`-archivePath`.

Checks per case: exit status; stderr (reference logging, its
`DVTAssertions` blocks and paths masked; for `error:` cases the first
error line); the header before the build log; the trailer after it;
every banner and result-bundle line in order; the test runner section
(timings masked, concurrent swift-testing lines as a multiset); each
result bundle through `xcrun xcresulttool get build-results |
test-results summary | test-results tests | content-availability` and,
with coverage, `xcrun xccov view --report` and per-file line coverage;
archive, export, `.doccarchive` and `.xcloc` file trees; archive
`Info.plist`; exported XLIFF, source copies and `contents.json` (tool
info masked); files written by `-importLocalizations`; `-list` /
`-resolvePackageDependencies` output (unordered blocks normalized);
`.xctestrun` name and keys; `-showBuildSettings -json archive` values.
Also counted: build-log section headers present in both logs.

Results (final run 2026-10-17): **52 cases, 363 of 363 checks
identical.**

| Case group | Cases | Checks | Identical |
|---|---:|---:|---:|
| test (incl. coverage, -only-testing, -quiet), build-for-testing, test-without-building, -testPlan error | 12 | 95 | 95 |
| package folders (-list, -json, errors, settings, build, test and coverage of library, package and executable schemes, dependency) | 17 | 112 | 112 |
| -resolvePackageDependencies (project, package, none) | 3 | 18 | 18 |
| docbuild (package, project library) | 2 | 13 | 13 |
| -exportLocalizations (target, source language), -importLocalizations | 3 | 18 | 18 |
| builds with -resultBundlePath, existing bundle | 6 | 50 | 50 |
| archive settings, app and tool archives, archive with result bundle | 4 | 30 | 30 |
| export (mac-application, ad hoc manual) and export errors | 5 | 27 | 27 |
| **all** | **52** | **363** | **363** |

| Check | Runs | Identical |
|---|---:|---:|
| exit status, banners, header | 52 each | 52 each |
| stderr / error line | 43 / 9 | 43 / 9 |
| stdout (list, resolve) | 8 | 8 |
| test runner output | 15 | 15 |
| trailer | 51 | 51 |
| result bundle: availability, build-results, summary, tests | 13 each | 13 each |
| result bundle: coverage report, coverage lines | 6 each | 6 each |
| file trees, archive Info.plist | 8, 6 | 8, 6 |
| `.xctestrun` name and keys | 1, 1 | 1, 1 |
| archive settings (565 values) | 1 | 1 |

Target-level warnings of targets built in parallel (`test-quiet`), whose
order varies from run to run in both tools, are compared as a multiset.

Build-log section headers: in every case each header ycodebuild prints
also appears in the reference log. The reference logs have 2 more in each
project build (`ComputePackagePrebuildTargetDependencyGraph`, `Prepare
packages`), and the app archive 4 more (the reference signs the archived
app with an empty entitlements file). `YcodeXcodebuildTests` covers the
same paths without the reference tool.

## Evidence

- All numbers: runs of the harness on the dates above (level 3).
