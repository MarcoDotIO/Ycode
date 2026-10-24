# Testing

Ycode modules: `YcodeBuild` (`TestResultParser`, `TestOutcome`,
`TestRunner`), `YcodeUI` (`TestDiscovery`, Test navigator, gutter
diamonds, `WorkspaceSession.runTests`).

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
| package | `swift test` in the package folder (SwiftPM builds and runs both XCTest and swift-testing) | `--filter Suite.name` |
| project / workspace | `xcodebuild … test` | `-only-testing:<Target>/<Suite>/<name>` |

swift-build is not used to run tests yet: `swbuild` builds test bundles
but has no test-execution step, so test runs use SwiftPM or xcodebuild
(OPEN QUESTION: driving `xctest` / the swift-testing entry point on
swift-build products).

## Results

Lines read from the runner's merged output:

| Form | Meaning |
|---|---|
| `Test Case '-[Module.Class test]' passed (…)` / `failed` / `skipped` | XCTest outcome (Darwin) |
| `Test Case 'Class.test' passed (…)` | XCTest outcome (Linux) |
| `<file>:<line>: error: -[Module.Class test] : <message>` | XCTest failure, attached to that test |
| `✔ Test name() passed after …` | swift-testing pass |
| `✘ Test name() recorded an issue at <file>:<line>:<col>: <message>` | swift-testing failure, attached |
| `✘ Test name() failed after …` | swift-testing fail |

An outcome matches a discovered test by name, and by suite when the
runner names one (swift-testing lines do not). Failures become issues
(issue navigator, editor annotations). A Test entry is added to the Report
navigator; the activity view ends with "Test Succeeded" or "Test Failed".

## Test navigator (⌘6)

Files → suites/classes → tests (XCTest `testName`, swift-testing
`name()`). Each row has a diamond: outlined (not run), green check
(passed), red cross (failed). A suite is red if any member failed, green
if all passed. Selecting a test opens its line.

## Gutter

Each test's declaration line shows a diamond left of the line number:
outlined (not run), filled green (passed), filled red (failed). A suite's
declaration line shows one too: red if any member failed, green if all
passed, else outlined.

## Evidence

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
