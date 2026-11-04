# Testing

Ycode modules: `YcodeBuild` (`TestResultParser`, `TestOutcome`,
`TestRunner`), `YcodeUI` (`TestDiscovery`, Test navigator, gutter
diamonds, `WorkspaceSession.runTests`, `TestRunnerSelection`).

## Discovery (lexer-based, until an index exists)

In Swift sources, with comments and strings blanked out:

- **XCTest**: a `func` whose name starts with `test`, declared directly in
  the body of a type whose declaration (between its name and `{`) names
  `XCTestCase`. Suite = that type.
- **swift-testing**: a `func` preceded (since the previous declaration) by
  the `@Test` attribute, with or without arguments (`@Test("name")`).
  Suite = the directly enclosing type, if any (`@Suite` or not).
- **Objective-C XCTest**: in a file that declares `@interface C :
  XCTestCase`, each `- (void)test…` method without parameters between
  `@implementation C` and `@end`. Suite = `C`.
- Identifier: `Suite/name` or `name`. Each test also records the line
  declaring its suite (class, struct, or `@implementation`).

Discovery runs when the workspace window opens and before each test run
(both implemented). For projects the `-only-testing:` filter starts with
the target whose Sources phase (or synchronized folder) holds the test's
file.

## Running

Product ▸ Test (⌘U) runs all tests. Clicking a test's gutter diamond runs
only that test; clicking the diamond on a suite's declaration line runs
every test of that suite (each passed to the runner's filter). Results of
a partial run update only the tests that ran.

| Container | Command | Filter |
|---|---|---|
| package | `swift test` in the package folder (SwiftPM builds and runs both XCTest and swift-testing) | `--filter Suite.name\b` (the filter is a regular expression; the word boundary keeps `testAdd` from also running `testAddsMore`) |
| project / workspace | `ycodebuild … test` when the build system is swift-build and `ycodebuild` is found; else `xcodebuild … test` | `-only-testing:<Target>/<Suite>/<name>` |

Status (2026-10-28): `TestRunner` (`YcodeBuild`) builds these commands;
`TestRunnerSelection` (`YcodeUI`) swaps `xcodebuild` for `ycodebuild`
when the IDE's build system is swift-build (`build.md` §Engines) and the
runner's tool was not set explicitly. `ycodebuild` builds the test bundles
with swift-build and runs them in the platform's `xctest` runner, which
also runs swift-testing tests (`specs/xcodebuild/test-actions.md`). With
xcodebuild chosen, or when `ycodebuild` is not found, project and
workspace tests run through `xcodebuild`. `swbuild` itself still has no
test-execution step. Tests hosted in an app (2026-10-30) run in the app,
on this Mac or on the Ycode simulator ("Ycode implementation").

## Results

Lines read from the runner's merged output:

| Form | Meaning |
|---|---|
| `Test Case '-[Module.Class test]' passed (…)` / `failed` / `skipped` | XCTest outcome (Darwin) |
| `Test Case 'Class.test' passed (…)` | XCTest outcome (Linux) |
| `<file>:<line>: error: -[Module.Class test] : <message>` | XCTest failure, attached to that test |
| `<file>:<line>: error: Class.test : <message>` | XCTest failure (Linux), attached to that test |
| `✔ Test name() passed after …` | swift-testing pass |
| `✘ Test name() recorded an issue at <file>:<line>:<col>: <message>` | swift-testing failure, attached |
| `✘ Test name() failed after …` | swift-testing fail |

An outcome matches a discovered test by name, and by suite when the
runner names one (swift-testing lines do not). Failures become issues
(issue navigator, editor annotations). A Test entry is added to the Report
navigator; the activity view ends with "Test Succeeded" or "Test Failed".
*Pass 6 (`reference-ui-6.md` §3.4): a passing run of selected tests ends
in "Test Completed"; the whole-scheme text is still to observe.*

## Test navigator (⌘6)

Files → suites/classes → tests (XCTest `testName`, swift-testing
`name()`). Each row has a diamond: outlined (not run), green check
(passed), red cross (failed). A suite is red if any member failed, green
if all passed. Selecting a test opens its line.

## Gutter

Each test's declaration line shows a diamond in place of the line number
(`reference-ui-6.md` §4.3.1):
outlined (not run), filled green (passed), filled red (failed). A suite's
declaration line shows one too: red if any member failed, green if all
passed, else outlined.

## Repetitions (IDE-QUICKWINS, 2026-10-30)

The Test navigator's row menu has Run “<row>” and Run “<row>”
Repeatedly…. The second opens a sheet: **Repeat** (Fixed Iterations,
Until Failure, Retry on Failure) and **Maximum Repetitions** (default 100,
1–10000). Ycode runs the iterations itself, each a normal test run of the
same tests (its report, results, issues), and prints "Ycode: <mode>: N
iterations, M with failures." to the console at the end.

- Fixed Iterations: the tests, the maximum number of times.
- Until Failure: again while no asked-for test failed, up to the maximum.
- Retry on Failure: after a failure, only the tests that failed, until
  they pass or the maximum is reached.

Only the outcomes of the tests asked for count. Product ▸ Stop ends the
series after the current iteration. Code: `YcodeIDECore`
`TestRepetition`, `WorkspaceSession+Repetition.swift`; `YcodeUI`
`WorkspaceWindowController+TestRepetition.swift`. Tests:
`IDEQuickWinsTests.repetitionModes`,
`IDEQuickWinsUITests.runTestsRepeatedly`. Not yet: the gutter diamond's
menu, relaunching the app per iteration, test-plan repetition settings.

## Result bundles in the IDE (IDE-QUICKWINS, 2026-10-30)

File ▸ Open… of an `.xcresult` (or opening one from Finder) with a
workspace window in front adds a test report "Test <bundle name>" to that
window's Report navigator and shows its Tests page. The tests come from
`XCResultReader` (`specs/xcodebuild/result-bundle.md`): `Class/method()`
gives suite `Class` and test `method`; Success and Expected Failure pass,
Failure fails (its failure summaries become the report's issues, with file
and line), Skipped is skipped. The report's date is the bundle's
modification date. A bundle that cannot be read says so in a sheet and the
console. Not yet: coverage, logs and attachments of the bundle, the
reference's own result viewer layout. Code: `YcodeIDECore`
`ResultBundleReport.swift`; `YcodeUI`
`WorkspaceWindowController.openResultBundle`, `YcodeDocumentController`.
Tests: `IDEQuickWinsTests.resultBundleReport`,
`IDEQuickWinsUITests.openResultBundle`.

## Ycode implementation (TEST-HOST, 2026-10-30)

Tests hosted in an application (`TEST_HOST`, with `BUNDLE_LOADER` naming
the same executable) run inside that application, as in the reference.
Ycode does not use the reference's injection library or its test
configuration file: it has its own agent and its own protocol, described
here. Code: `Sources/YcodeTestAgent` (with `Sources/CYcodeTestAgentLoader`),
`YcodeXcodebuild/HostedTests.swift`, `RemoteTestHost.swift`.

### Building

swift-build (open source) builds a bundle with `TEST_HOST` into the host's
`PlugIns` folder (`Host.app/Contents/PlugIns/X.xctest` on macOS,
`Host.app/PlugIns/X.xctest` on iOS) and links it against the host
executable (`-bundle_loader`). A UI test bundle builds into
`<PRODUCT_NAME>-Runner.app/…/PlugIns`. swift-build requires entitlements
for a UI test bundle (`ENTITLEMENTS_REQUIRED` with the runner), although it
is not an executable; Ycode's signing composes them as for one
(`signing.md` §4.1).

The testing frameworks: swift-build's test-host task copies them into the
host's `Frameworks` folder (`XCTestHostTaskProducer`: `XCTest`, `Testing`,
`XCUnit`, `XCUIAutomation`, `XCTestCore`, `XCTestSupport`,
`XCTAutomationSupport` frameworks, `_Testing_Foundation.framework`,
`libXCTestSwiftSupport.dylib`, `libXCTestBundleInject.dylib`,
`lib_TestingInterop.dylib`, from the platform's developer folders; only
that one `_Testing_*` overlay, since the others share a bundle identifier),
unless `SKIP_COPYING_TEST_FRAMEWORKS` is YES, its default for Xcode 27 and
later (devices get the frameworks from their developer disk image).
ycodebuild sets it to NO for `build-for-testing` and `test` builds for a
simulator SDK, because the Ycode simulator's runtime has none of them
(`TestActions.testFrameworkCopying`). On macOS the default stays: the host
finds them through `DYLD_FRAMEWORK_PATH`, as tool-hosted runs do.

### The agent

`libYcodeTestAgent.dylib` is Ycode's own library. It links neither XCTest
nor Testing; it finds them at run time once the bundle has loaded them.
ycodebuild starts the host's executable with:

| Variable | Value |
|---|---|
| `DYLD_INSERT_LIBRARIES` | the agent (macOS: its path; the simulator: `@executable_path/Frameworks/libYcodeTestAgent.dylib`), after any libraries already there |
| `YCODE_TEST_PLAN` | JSON: `session` (a UUID), `bundles` (`path`, `module`, `only`, `skip`), `repetition` (`mode`, `count`), `launchTimeout` (seconds) |

and, on macOS, the tool-hosted run's `DYLD_FRAMEWORK_PATH`,
`DYLD_LIBRARY_PATH` and `__XCODE_BUILT_PRODUCTS_DIR_PATHS`, the plan's
environment and arguments, and `-ApplePersistenceIgnoreState YES` (no
window restoration). A host started through a SIP-protected program loses
`DYLD_*` variables, so ycodebuild starts the executable itself.

1. At load (a C constructor) the agent reads `YCODE_TEST_PLAN`; without it
   it does nothing. It removes `DYLD_INSERT_LIBRARIES` and
   `YCODE_TEST_PLAN` from the environment (the app's own child processes
   are not injected) and reports `agentLoaded`.
2. It waits for the application to finish launching: AppKit's or UIKit's
   launch notification (the exported constants' values, looked up by name),
   then one more turn of the main queue, so the app delegate's own handler
   has run. A host that posts neither runs the tests after
   `launchTimeout` seconds (30 on macOS, 120 on the simulator).
3. For each bundle in order: path relative to the host's `PlugIns` folder
   (or absolute, or `@executable_path/…`); load it (`NSBundle`); a load
   failure is an `error` report and the next bundle.
4. XCTest, when its classes are present: `+[XCTestSuite
   testSuiteForBundlePath:]`, its test cases filtered by `only`/`skip`
   (`Class`, `Class/method`, `Class/method()`, without the module), into
   a suite named "All tests" (no selection) or "Selected tests", run on the
   main thread with `-runTest`. An `XCTestObservation` observer (the
   protocol is added to Ycode's class at run time) reports each test.
   XCTest prints its usual console lines itself.
5. Swift Testing, when the bundle's image has a non-empty
   `__DATA_CONST,__swift5_tests` section (where the testing library looks
   for tests) or the bundle has no XCTest tests: the library's ABI entry
   point (`swt_abiv0_getEntryPoint`, `Documentation/ABI/JSON.md`) with
   `{"eventStreamVersion": 0, "filter": [...], "skip": [...]}`. Filters are
   anchored ID patterns (`^Module\.Suite/function\(\)(/|$)`); with no
   selection the filter is `^Module\.` (bundles loaded earlier are in the
   process too). It runs in a task, so main-actor tests have the main
   thread. The library prints its console lines on standard error; the
   agent turns its records into reports.
6. After the last bundle: `runFinished` and `exit(0)` (all passed or
   skipped), `exit(1)` (a test failed), `exit(70)` (a bundle did not load).

Repetitions (test plans): XCTest runs the selected cases again per round
(new instances): fixed iterations, until a failure, or the failing cases
again until they pass; Swift Testing gets `repetitions` and `repeatUntil`
(`fail`, `pass`). Results of the rounds are folded into one per test: a
retried test has its last status, otherwise a test failed when any round
failed.

### The protocol

Every report is one line on the host's standard error, written with one
`write`:

    ##ycode-test## {"kind": "...", "session": "<id>", "v": 1, ...}

| `kind` | Fields |
|---|---|
| `agentLoaded` | `pid`, `host` |
| `runStarted` | `reason` (`launched`, `timeout`), `bundles` |
| `bundleStarted` / `bundleLoaded` / `bundleFinished` | `path`, `module`; `loaded` on finish |
| `phase` | `framework` (`XCTest`, `Swift Testing`), `tests` |
| `iteration` | `framework`, `iteration` |
| `swiftTest` | `id`, `name`, `isSuite`, `file`, `line` (a Swift Testing test the library announced) |
| `testStarted` | `framework`, `suite` (`Class` or `Outer/Inner`), `name`, `iteration` |
| `issue` | `framework`, `suite`, `name`, `message`, `file`, `line` |
| `testFinished` | `framework`, `suite`, `name`, `status` (`passed`, `failed`, `skipped`), `duration` (XCTest) |
| `error` | `message` |
| `runFinished` | `status`, `exitCode`, `passed`, `failed`, `skipped` |

A reader ignores reports of another session (a stale output file) and
unknown kinds. Text before a report on the same line is the app's. Results
come from the libraries' console lines, read by the same parser as
tool-hosted runs (§Results); the reports route the lines to their bundle,
give Swift Testing tests their suites (a hosted bundle cannot be listed
before the run), name the test that was running when a host crashed, and
end the run.

### On this Mac

One launch of the host per bundle. The run ends when the host exits; it is
killed when the agent has not reported within 60 s (`YCODE_TEST_AGENT_TIMEOUT`;
the message names the hardened runtime's "Allow DYLD Environment Variables"
and "Disable Library Validation" exceptions, which such a host needs for
its test builds), or after `YCODE_TEST_HOST_TIMEOUT` seconds (3600). A
host that exits before `runFinished` fails the run: "<Host> exited with
status N before its tests finished (while running <Suite/test>)."

### On the Ycode simulator

One simulator run per host app, for every bundle it hosts:

1. A copy of the app gets the simulator build of the agent. The testing
   libraries are already in its `Frameworks` folder (swift-build copied
   them, "Building" above); a host without `XCTest.framework` there is an
   error ("build it with build-for-testing for this destination first").
2. It is copied to `<data>/test-apps/<App>.app` (rsync over ssh, keys
   only), apart from the IDE's run copies in `<data>/apps`.
3. One ssh command removes the device's old app output, prints the shell's
   pid, follows `<device>/data/tmp/ycode-app.err` (the app's standard
   error, where ylaunch puts it; `tail --pid` ends with the simulator) with
   each line prefixed `YCODE-APP|`, and becomes the simulator:
   `ycode-simd … --install-app <copy> --launch <bundle id> --app-env
   DYLD_INSERT_LIBRARIES=… --app-env YCODE_TEST_PLAN=…` (`--app-env`,
   ylaunch's `__Environment`, `specs/simulator/app-install-launch.md`
   §4.4).
4. The app's lines go to the parser and the console; the simulator's own
   lines are kept (the last ones are shown when the run fails). When the
   agent reports `runFinished`, ycodebuild sends SIGINT to the remote pid,
   as the IDE's Stop does (the launcher saves a warm-boot device), and
   closes the connection 150 s later at the latest. An install or launch
   failure line, no agent report within `YCODE_SIM_TEST_LAUNCH_TIMEOUT`
   (900 s; a cold boot takes minutes), or a run longer than
   `YCODE_SIM_TEST_TIMEOUT` (3600 s) stops it too.

Measured (the Thor, iPhone 18 Pro, iOS 27.0, two bundles, warm boot):
about 25 s from ycode-simd's start to the tests' end; the boot slot can add
minutes when the host is busy.

### UI tests

Ycode has no UI automation service. A UI test bundle runs in the
platform's xctest runner (on this Mac): tests that do not drive an app
pass or fail normally; a test that calls `XCUIApplication` fails with
XCTest's own message that no target application was configured. On the
Ycode simulator UI test bundles are reported as not supported. A Ycode
runner that drives apps through the simulator's HID input
(`specs/simulator/hid-input.md`) and an accessibility snapshot is future
work; the facts it needs are dirty-room questions (Evidence).

### Test plans

`.xctestplan` (JSON, `version` 1), as in open-source projects' plans:

| Key | Use |
|---|---|
| `testTargets[]` | `target` {`containerPath`, `identifier`, `name`}, `enabled` (default true), `selectedTests`, `skippedTests`, `parallelizable` (read, not used) |
| `defaultOptions`, `configurations[]` {`id`, `name`, `options`} | the options below; a configuration's option replaces the default's |
| `environmentVariableEntries[]` | {`key`, `value`, `enabled` (default true)} into the test process |
| `commandLineArgumentEntries[]` | {`argument`, `enabled`} after the host's arguments |
| `testRepetitionMode`, `maximumTestRepetitions` | `fixedIterations`, `untilFailure`, `retryOnFailure`; maximum 3 when absent (Ycode's choice) |
| `language`, `region` | the host's `-AppleLanguages (<language>)`, `-AppleLocale <language>_<region>`; the result bundle's testable language and region |
| `codeCoverage`, `testTimeoutsEnabled`, `defaultTestExecutionTimeAllowance` | read; coverage still follows the scheme and `-enableCodeCoverage` |

Every enabled configuration runs (`-only-test-configuration`,
`-skip-test-configuration` choose); with more than one, each target runs
once per configuration and the result bundle has one run summary per
configuration, named after it. The plan's targets are built by `test` and
`build-for-testing` with the scheme's.

### The IDE

Product ▸ Test (⌘U), the diamonds and Test Again run hosted tests through
ycodebuild like any project test; the Test navigator, gutter and issues
get their results from the same console lines. With the Ycode simulator
chosen, the session passes ycodebuild
`-destination 'platform=iOS Simulator,name=Ycode Simulator,arch=arm64'`
and the `YCODE_SIM_*` variables of the destination's settings
(`RemoteSimulator.testEnvironment`: host, data directory, runtime,
launcher, device directory, options, warm and lean boot).

### Tests

`HostedTestsTests.swift` (protocol, collector, plans, remote command,
`.xctestrun` keys, result-bundle reader); `HostedTestRunTests` (YcodeUITests:
⌘U on `Samples/TestHostSamples/HostMac`, and opt-in with `YCODE_E2E_*` on
HostPhone on a real Ycode simulator); `RemoteTestEnvironmentTests`.

## Ycode implementation: the Linux IDE (B2-SCM, 2026-11-04)

The SwiftUI shell (`YcodeIDEShell/TestShellModel.swift`,
`ycode-ide/TestNavigator.swift`) uses the session's discovery,
`runTests(only:)` and reports, as the AppKit IDE does:

- **Test navigator (⌘6):** the package or project with "N Tests", each
  test target (a package's `Tests/<Target>` folder), its suites, then the
  tests as `name()`. The diamond at a row's right end is outlined before a
  run, a green check, a red cross, or an arrow for skipped; a parent shows
  the aggregate (failed if any failed, else passed if any passed). The
  selected row shows a run button; its context menu has Run and Jump to
  Definition; selecting a test or suite opens its line.
- **Running:** Product ▸ Test (⌘U) runs everything; a row, a gutter
  diamond or Product ▸ Perform Action ▸ Test Again runs that selection.
  Without a toolchain on `PATH` (outside the Flatpak) Test reports what to
  install, as Build does. In the Flatpak `swift` is the host-tool wrapper
  on the sandbox's `PATH`.
- **Results:** swift-testing names a failure's file without its folder;
  the session resolves it to the discovered test's file
  (`TestFailureFiles`), so failures are issues at their lines in the
  Issue navigator and the editor.
- **Gutter:** a test's or suite's declaration line shows its diamond in
  place of the line number; clicking it runs that test or suite.
- **Report navigator (⌘9):** the runs, newest first (the core's
  `ReportNavigatorModel`); a test run's Tests page lists each test with its
  result, suite, time and failures (failed first), and its Log page the
  output.

Tests: `YcodeIDEShellTests/TestShellTests.swift` (a package with XCTest and
Swift Testing tests and a stand-in runner printing Linux output: rows,
results, issues at lines, diamonds, reports, filters, Test Again; the
Linux XCTest failure form; file resolution). End to end on Linux:
`ycode-ide` with `YCODE_IDE_TESTS=<prefix>` (`ShellDriver+Tests.swift`).

## Evidence

- Linux XCTest failure lines and Swift Testing's issue lines: black-box
  runs of `swift test` on Linux with Swift 6.4 (level 3); `--filter` as a
  regular expression with `\b`: SwiftPM's public `swift test --help` and
  runs (levels 1 and 3).
- Test navigator, ⌘U, diamonds in the gutter and navigator: Apple's public
  Xcode Help (level 1).
- XCTest and swift-testing declaration rules: the XCTest documentation and
  the open-source swift-testing project (level 1).
- Output line formats: black-box runs of `swift test` and `xcodebuild test`
  (level 3); swift-testing's and XCTest's open-source output code (level 1).
- Running one test or class from its diamond: Xcode Help (level 1);
  verified with `swift test --filter` (level 3).
- OPEN QUESTION: Xcode's exact diamond artwork/colors, whether the diamond
  also offers a menu, and how parameterized
  swift-testing tests appear in the navigator.
- Repetition modes: xcodebuild's public `-test-iterations`,
  `-run-tests-until-failure`, `-retry-tests-on-failure` (`man xcodebuild`,
  level 1). The menu items, the sheet and its labels are Ycode's
  (the reference's were not observed).
- Ycode implementation: swift-build's test-host settings and the
  frameworks it embeds (open-source swift-build, Apache-2.0, level 1);
  Swift Testing's ABI entry point, its configuration keys, filters and
  test content section (open-source swift-testing, Apache-2.0, level 1);
  XCTest's public classes and observation protocol (public documentation,
  level 1); `.xctestplan` keys from open-source projects' plans (llbuild,
  Apache-2.0; react-native, sentry-cocoa, LLM.swift, MIT; level 2);
  `ylaunch`'s environment (`app-install-launch.md`). Runs of Ycode's own
  samples with Ycode's own agent (level 3, our code).
- DIRTY-ROOM QUESTIONS (for an observation; Ycode does not need them to
  run its own hosted tests):
  1. How the reference starts a hosted test: the variables its
     `.xctestrun` `TestingEnvironmentVariables` give the host for an
     application-hosted bundle, and when the bundle is loaded relative to
     the app's launch (before or after `didFinishLaunching`).
  2. UI tests: how the runner app reaches the automation service, what an
     `XCUIApplication` launch asks of the simulator, and the minimum a
     third-party service must answer for `XCUIApplication().launch()` and
     element queries to work.
  3. Test plans: the values of `testRepetitionMode` other than
     `retryOnFailure` (Ycode reads `fixedIterations` and `untilFailure`),
     the default `maximumTestRepetitions`, whether a configuration's
     environment list replaces or merges with the default's, and the
     language and region arguments a host receives.
  4. Result bundles of hosted and UI tests: `testKind` values (Ycode
     writes `app hosted`, `UI test`) and the run summary names of a plan
     with several configurations.
  5. Whether the reference embeds the testing frameworks into the host app
     at build time in every case (swift-build as Ycode runs it did not)
     and which launch arguments it passes to a macOS test host.
