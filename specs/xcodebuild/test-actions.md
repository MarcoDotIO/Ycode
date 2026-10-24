# xcodebuild: test, test-without-building, build-for-testing, .xctestrun

Ycode: `YcodeXcodebuild` (`TestActions`, `TestConsoleParser`,
`XCTestRunFile`, `SwiftTestingBridge`). Grammar: `cli.md`. Build log and
banners: `build-actions.md`. Result bundles: `result-bundle.md`.

## 1. What runs

| Action | Steps | Banner word |
|---|---|---|
| `build-for-testing` | build the scheme's testing entries and testables; write the `.xctestrun` file (§4) | `TEST BUILD` |
| `test` | the same build (its failure banner says `TEST`), then run the tests | `TEST` |
| `test-without-building` | run already-built tests: with `-scheme`, located through build settings; with `-xctestrun <file>`, from the file (no project is opened) | `TEST EXECUTE` |

Test bundles: the scheme's test plan (`-testPlan <name>`, else the default
plan reference, else the scheme's testables). An enabled plan entry, or a
testable not marked skipped, names a unit-test target; its bundle is
`TARGET_BUILD_DIR/FULL_PRODUCT_NAME`. Selection: plan `selectedTests` /
`skippedTests`, then `-only-testing:` and `-skip-testing:`
(`Target[/Class[/method]]`, also `Suite/function()` for swift-testing).
`-only-testing` naming no target in the plan runs that target's bundle with
an empty selection (the runner reports `Selected tests`, 0 tests).

Each bundle runs in the platform's `xctest` runner
(`<Developer>/usr/bin/xctest [-XCTest <filter>] <bundle>`), with
`DYLD_FRAMEWORK_PATH`/`DYLD_LIBRARY_PATH` set to the products directory
plus the platform's developer frameworks and libraries,
`__XCODE_BUILT_PRODUCTS_DIR_PATHS`, and the run file's environment. The
filter is a comma-separated list of `Module.Class[/method]` and
`Module.Suite[/function()]` units. swift-testing tests run in the same
runner (the testing library joins the XCTest run); they are listed first
through the library's documented ABI entry point (open-source
swift-testing, `Documentation/ABI/JSON.md`) in a child process
(`ycodebuild __list-swift-tests <executable>`), to map console names to
suites and source files. XCTest class/method lists for `-skip-testing`
come from SwiftPM's open-source `swiftpm-xctest-helper` in the toolchain.

Tests hosted in an application (`TEST_HOST`) are not run yet: reported as
a "Testing failed" line. Code coverage (scheme setting or
`-enableCodeCoverage YES`): the build gets `CLANG_COVERAGE_MAPPING = YES`
and `CLANG_PROFILE_DATA_DIRECTORY = <build folder>/ProfileData`; each runner
writes `LLVM_PROFILE_FILE = <ProfileData>/<device id>/<UUID>-%p.profraw`,
and the raw profiles are merged with the toolchain's `llvm-profdata merge`
into `<ProfileData>/<device id>/Coverage.profdata`.

## 2. Output (stdout)

After the build log (for `test`): the runners' own console output, line
by line, unchanged (XCTest's `Test Suite '…' started at …`, `Test Case
'-[Module.Class method]' passed (0.001 seconds).`, swift-testing's `◇`/`✔`/
`✘`/`↳` lines with their zero-width-space separators). Then:

    <blank>
    Test session results, code coverage, and logs:
    \t<result bundle path, /private prefix removed>
    <blank>
    ** TEST SUCCEEDED **        (or TEST EXECUTE SUCCEEDED)
    <blank>
    Testing started

`Testing started` is written by the reference tool through a buffered
stream: on a terminal it appears where testing starts (before the runner
output), but when stdout is a pipe or file it appears **last**, after the
banner. ycodebuild reproduces both: it prints the line immediately when
stdout is a terminal and otherwise at exit. The line is printed with
`-quiet` too; `-quiet` suppresses the runner output and the session lines.

Every `test` and `test-without-building` run writes a result bundle: the
`-resultBundlePath` one, else
`<DerivedData folder>/Logs/Test/Test-<scheme>-<yyyy.MM.dd_HH-mm-ss-ZZZ>.xcresult`
(local time, e.g. `Test-CalcTests-2026.10.13_23-46-27--0400.xcresult`).
For `-xctestrun` runs ycodebuild uses the `Logs/Test` folder of the
DerivedData folder that holds the file (`…/Build/Products/x.xctestrun`).

On failure, on stderr:

    Testing failed:                       (only for errors that are not test failures)
    \t<message>
    <blank>
    Failing tests:
    \t<Class.method()>                     (XCTest; one line per failing test, run order)
    \t<Suite.function()>                   (swift-testing; nested suites joined with .)
    <blank>
    ** TEST FAILED **
    <blank>

A parameterized test that fails is listed once.

## 3. Exit status

0 when all tests passed or were skipped; 65 when a test failed, the build
failed, or a runner could not run. Errors before testing: no scheme
(`cli.md` §4, 65), scheme with no test entries (66), unknown `-testPlan`
(64): `Failed to build project <project> with scheme <scheme>.: Scheme
“<scheme>” does not have an associated test plan named “<name>”.`

## 4. The `.xctestrun` file

`build-for-testing` writes
`<Build/Products>/<scheme>_<plan>_<sdk canonical name>-<arch>.xctestrun`
(e.g. `CalcTests_CalcTests_macosx27.0-arm64.xctestrun`), an XML property
list, format version 2 (public: `man xcodebuild.xctestrun`). `test` does
not write one.

| Key | Value |
|---|---|
| `__xctestrun_metadata__` | `{FormatVersion: 2}` |
| `ContainerInfo` | `{ContainerName: <project or workspace name>, SchemeName}` |
| `TestPlan` | `{Name, IsDefault}` |
| `CodeCoverageBuildableInfos` | array (empty in ycodebuild; the reference lists each buildable's products, sources and architectures) |
| `TestConfigurations` | `[{Name: "Test Scheme Action", IsEnabled: true, TestTargets: [...]}]` |

Per test target: `BlueprintName`, `BlueprintProviderName` (project name),
`BlueprintProviderRelativePath` (`X.xcodeproj`, relative to the
container), `BundleIdentifiersForCrashReportEmphasis` ([bundle id]),
`ClangProfileDataDirectoryPath` (`__DERIVEDDATA__/Build/ProfileData`),
`CommandLineArguments`, `DefaultTestExecutionTimeAllowance` (600),
`DependentProductPaths`, `DiagnosticCollectionPolicy` (1), `DSTROOTPath`
(`/tmp/<project>.dst`), `EnvironmentVariables`,
`IsMemoryTaggingAddressSanitizerEnabled` (false),
`PreferredScreenCaptureFormat` (`screenRecording`), `ProductModuleName`,
`SystemAttachmentLifetime` / `UserAttachmentLifetime` (`deleteOnSuccess`),
`TestBundlePath`, `TestHostPath`
(`__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest` for
tool-hosted bundles), `TestingEnvironmentVariables` (`DYLD_FRAMEWORK_PATH`
= `<products>:__SHAREDFRAMEWORKS__:__PLATFORMS__/MacOSX.platform/Developer/Library/Frameworks`,
`DYLD_LIBRARY_PATH` = `<products>:__PLATFORMS__/MacOSX.platform/Developer/usr/lib`,
`__XCODE_BUILT_PRODUCTS_DIR_PATHS`, `__XPC_DYLD_FRAMEWORK_PATH`,
`__XPC_DYLD_LIBRARY_PATH` = `<products>`, `XCODE_SCHEME_NAME`,
`XCODE_TEST_PLAN_NAME`), `TestInteropMode` (`complete`), `TestLanguage`,
`TestRegion` (""), `TestTimeoutsEnabled` (false), `ToolchainsSettingValue`
([]); `OnlyTestIdentifiers` / `SkipTestIdentifiers` when a selection
applies. Paths under the products directory start with `__TESTROOT__`;
`__PLATFORMS__`, `__SHAREDFRAMEWORKS__`, `__DERIVEDDATA__` and
`__DEVELOPERUSRLIB__` are placeholders the reader expands. Reading also
accepts format version 1 (one dictionary per target at the top level).

The reference tool also writes its own diagnostic and logging variables
into `EnvironmentVariables` and `DYLD_INSERT_LIBRARIES`; ycodebuild does
not (they are tool plumbing, not part of the run's meaning).

## 5. Results gathered from the console

From XCTest lines: class, method, status (`passed`/`failed`/`skipped`),
duration; failures from `<file>:<line>: error: -[M.C m] : <message>`; skips
from `<file>:<line>: -[M.C m] : Test skipped - <message>`. From
swift-testing lines: `✔/✘ Test <name>[ with N test cases] passed|failed
after <s> seconds`, issues from `recorded an issue at <file>:<line>:<col>:
<message>` plus the `↳` detail lines after the first (the first restates
the expression), test cases of parameterized tests from `◇ Test case
passing N argument(s) <label> → <value>[, …] to <name> started.` (one
result per case, the overall status and an equal share of the time).
Identifiers: `Class/method()` and `Suite/function()`.

## Evidence

- Output order, `Testing started` placement on a pipe and on a terminal
  (pseudo-terminal capture), quiet output, the session lines, failure
  summary, exit codes, default bundle path, `.xctestrun` name and keys,
  `test` writing no `.xctestrun`: black-box `xcodebuild` 27.1 runs on a
  hand-written project with XCTest and swift-testing tests (level 3).
  The test section of ycodebuild's output matches the reference (timings
  masked, concurrent swift-testing lines as a multiset): see
  `conformance.md`.
- `.xctestrun` format: `man xcodebuild.xctestrun` (level 1) and files the
  reference tool writes (level 2).
- swift-testing console format and ABI: open-source swift-testing; XCTest
  listing: open-source SwiftPM `swiftpm-xctest-helper` (level 1).
- OPEN QUESTION: application-hosted tests (`TEST_HOST`), UI tests, test
  repetitions and parallel testing options are not implemented.
- OPEN QUESTION: the reference tool's default bundle location for
  `-xctestrun` runs (observed under a DerivedData folder whose hash is not
  the project path's).
- OPEN QUESTION: per-case status of a failing parameterized test (the
  console gives only the overall status).
