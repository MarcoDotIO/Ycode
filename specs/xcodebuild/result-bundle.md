# xcodebuild: result bundles (`.xcresult`)

Ycode: `YcodeXcodebuild` (`XCResultStore`, `XCRValue`, `ResultRecords`,
`ResultBundleSession`). The bundle is a file format Xcode's tools read
(`xcrun xcresulttool`, the IDE's report navigator). ycodebuild writes a
compatible subset: build results and issues, build logs, test summaries,
code coverage (`coverage.md`), test diagnostics, the archive path.

## 1. When a bundle is written

| Run | Bundle |
|---|---|
| `-resultBundlePath <path>` with any build action | `<path>` (relative to the working directory); rewritten after each action with all actions so far |
| `test`, `test-without-building` without the option | `<DerivedData folder>/Logs/Test/Test-<scheme>-<date>.xcresult` (`test-actions.md` §2) |
| other actions without the option | none |

`-resultBundlePath` naming an existing file or directory is an error found
before the "Command line invocation" header (stdout stays empty):

    xcodebuild: error: Existing file at -resultBundlePath "<absolute path, /private prefix removed>"

exit 64. Console lines (stdout):

- after the command-line settings sections, also with `-quiet`:
  `Writing result bundle at path:`, `\t<path as given>`, blank line;
- for build actions (not with `-quiet`), after each action's log and before
  its banner: a blank line, `Result bundle written to path:`, `\t<absolute
  path, /private prefix removed>`, blank line;
- for test actions, the `Test session results, code coverage, and logs:`
  lines instead (`test-actions.md` §2).

"/private prefix removed": a path under `/private/tmp`, `/private/var` or
`/private/etc` is printed from `/tmp`, `/var`, `/etc` (the top-level link
into `/private`). The same applies to `-derivedDataPath` everywhere the
reference tool prints build locations.

## 2. Bundle layout

    <name>.xcresult/
        Info.plist
        Data/
            data.<id>      one stored object
            refs.<id>      the identifiers it references

`Info.plist` (XML): `dateCreated` (date), `directoryImportMode`
(`concurrent`), `externalLocations` (empty array), `rootId` (`{hash:
<id of the root object>}`), `storage` (`{backend: fileBacked2, compression:
standard}`), `version` (`{major: 3, minor: 60}`, the legacy format version
`xcresulttool version` reports). The reader may add a `database.sqlite3`
cache next to them.

## 3. The object store

**Identifiers.** `0~` followed by the URL-safe base64 (with `=` padding)
of a 64-byte BLAKE2b digest (RFC 7693, no key). The raw identifier is the
version byte `0x00` followed by the 64 digest bytes. The digest covers the
raw identifiers of the object's references (in `refs` order) followed by
the bytes of the `data` file exactly as stored.

**refs file.** A count, then for each reference its length (65) and its
raw identifier. Counts and lengths below 128 are one byte; larger values
are `0x80 | n` followed by n big-endian bytes (247 → `81 F7`). An object
without references has the one-byte file `00`. References are listed
once each, sorted by identifier string.

**data file.** The object's encoded text (below), as a Zstandard frame
(RFC 8878; `compression: standard`). ycodebuild writes frames of raw
(stored) blocks of at most 128 KiB with a 4-byte content size and no
checksum, which every decoder accepts.

**Files and directories.** A stored file is its bytes (compressed the same
way) without references. A stored directory is the JSON listing
`[{"name": <entry>, "type": 1}, …]` (type 1 file, 2 directory), entries
sorted by name, whose references are the entries' objects **in listing
order** (not sorted). Coverage archives and diagnostics are directories.

**Object encoding** (ASCII framing, UTF-8 strings; `<n>` is a decimal byte
count):

    value     := "[" type ( field* | value* ) "]"     fields for objects and scalars; values for Array
    type      := "T" typedef | "S" <n> ":" name       spelled out the first time an object uses the type, named after
    typedef   := "[K2:_nV" <n> ":" name ( "K2:_s" typedef )? "]"   with the supertype chain
    field     := "K" <n> ":" key value
    scalar    := "[" type "K2:_vV" <n> ":" text "]"     String, Int, Bool (true/false), Double, Date

Keys are in ascending byte order; optional properties that are absent are
left out; empty arrays are written. Dates are local time
`yyyy-MM-dd'T'HH:mm:ss.SSSZ`. Doubles are written in shortest
round-trip form. A reference is an object of type `Reference` with `id`
(String) and `targetType` (a `TypeDefinition` object: `name`, optional
`supertype`). This is the same tree `xcresulttool get object --legacy
--format json` prints (`_type._name`, `_value`, `_values`).

## 4. Records ycodebuild writes

Type and property names are those of `xcresulttool formatDescription get
--legacy` (version 3.60). Root: `ActionsInvocationRecord` {`metadataRef` →
`ActionsInvocationMetadata` {`creatingWorkspaceFilePath`,
`uniqueIdentifier` (UUID), `schemeIdentifier` (`EntityIdentifier`:
`containerName` "<name> project"/"<name> workspace", `entityName` scheme,
`entityType` "scheme", `sharedState` "shared")}, `metrics`, `issues`,
`actions`, `archive` (`ArchiveInfo {path}` after `archive`)}.

Each `ActionRecord`: `schemeCommandName`, `schemeTaskName`, `title`,
`startedTime`, `endedTime`, `runDestination`, `buildResult`,
`actionResult`, `testPlanName` (test actions).

| Action | command / task | title |
|---|---|---|
| build | Run / Build | `Build "<scheme>"` |
| clean | Run / Build | `Clean "<scheme>"` |
| test | Test / BuildAndAction | `Testing project <project> with scheme <scheme>` |
| archive | Archive / BuildAndAction | `Archiving project <project> with scheme <scheme>` |
| no scheme | Run / Build | none |

`ActionResult` (`resultName` "build" or "action"; `status` "succeeded",
"failed" or "notRequested"): `metrics` (`ResultMetrics`: error, warning,
analyzer warning, tests, failed, skipped counts), `issues`
(`ResultIssueSummaries`), `coverage` (`CodeCoverageInfo
{hasCoverageData: false}`), `logRef` → `ActivityLogSection`, `testsRef` →
`ActionTestPlanRunSummaries`. Build issues are `IssueSummary` {`issueType`
(the compiler's category such as "Semantic Issue", else "Error"/"Warning",
"Swift Compiler Error"/"Warning" for Swift), `message` (first letter
capitalized), `documentLocationInCreatingWorkspace` (`DocumentLocation`:
`concreteTypeName` "DVTTextDocumentLocation", `url`
`file://<path>#EndingColumnNumber=<c>&EndingLineNumber=<l>&StartingColumnNumber=<c>&StartingLineNumber=<l>&Timestamp=<seconds since 2001>`,
zero-based numbers)}; the same issue reported by several targets is
summarized once. Test failures are `TestFailureIssueSummary` (with
`testCaseName` `Class.method()`, `issueType` "Uncategorized", location
`#EndingLineNumber=<l>&StartingLineNumber=<l>`).

Build log: `ActivityLogSection` {`domainType`
"Xcode.IDEActivityLogDomainType.BuildLog", `title` "Building project <p>
with scheme <s>", `startTime`, `duration`, `result`, `messages`
(`ActivityLogMessage` for issues not tied to a task), `subsections`: one
`ActivityLogCommandInvocationSection` per task (`title` = the task's
execution description, `commandDetails` = the log header and command
lines, `emittedOutput`, `exitCode`, its messages)}. Test action log: a
section "Test <scheme>" (`com.apple.dt.unit.cocoaUnitTest`) with one
subsection per test target.

Run destination (`ActionRunDestinationRecord`): `displayName` "My Mac",
`targetArchitecture`, `localComputerRecord` and `targetDeviceRecord`
(`ActionDeviceRecord` from `system_profiler`/`sysctl`: identifier
(provisioning UDID), model code and name, CPU kind and cores, RAM, OS
version and build, native architecture, platform record
`com.apple.platform.macosx`/"macOS"), `targetSDKRecord` (`ActionSDKRecord`:
identifier, name, version of the SDK). For `archive` the target device is
the generic "Any Mac" (identifier
`dvtdevice-IDEOSXSupportCore.IDEMacPlaceholder-macosx:placeholder`, model
"GenericmacOS", architecture `undefined_arch`, counts 0). Builds without a
scheme record every destination field empty.

Test summaries: `ActionTestPlanRunSummaries` → one
`ActionTestPlanRunSummary` ("Test Scheme Action") → per bundle
`ActionTestableSummary` {`name`, `targetName`, `projectRelativePath`,
`identifierURL` `test://com.apple.xcode/<project>/<target>`, `testKind`
"xctest-tool hosted", `tests`}. XCTest results nest as groups `All tests`
(or `Selected tests`) → `<target>.xctest` → class → `ActionTestMetadata`;
swift-testing suites are top-level groups (listed in the order their first
function started; for parameterized tests the first test case), free
functions top-level metadata. `ActionTestSummaryGroup` and
`ActionTestMetadata` carry `identifier` (`Class/method()`), `identifierURL`
(`…/<Class>/<method>` without parentheses for XCTest, with them for
swift-testing; parameterized cases add `?args=<SHA-256 hex of the argument
value>`), `name`, `duration`, `testStatus` ("Success", "Failure",
"Skipped"); metadata has `summaryRef` → `ActionTestSummary`
(`failureSummaries` of `ActionTestFailureSummary` {message, fileName,
lineNumber, issueType "Assertion Failure", `sourceCodeContext.location`},
`skipNoticeSummary` (`Test skipped - <message>` for XCTest), `arguments`
(`TestArgument` with parameter label and value description)).

## 5. Compatibility checked

`xcresulttool` (version 25115) reads ycodebuild's bundles: `get
build-results`, `get test-results summary|tests`, `get
content-availability`, `get log --type build|action`, `get object
--legacy`, `metadata get`. Their JSON equals that of the reference tool's
bundles for the same sample runs, apart from times, UUIDs and the run
order of concurrent tests (`conformance.md`); `xccov view` reads their
coverage (`coverage.md`).

## Evidence

- Layout, `Info.plist` keys, store files, identifier digest and refs
  encoding, compression, object encoding, record types and values:
  bundles written by `xcodebuild` 27.1 for hand-written sample projects,
  studied as files (level 2), with the type schema printed by
  `xcresulttool formatDescription get --legacy` and the JSON of `get
  object --legacy` (level 3). BLAKE2b: RFC 7693; Zstandard: RFC 8878;
  SHA-256: FIPS 180-4 (level 1).
- Console lines, existing-path error, rewrite per action, default test
  bundle: black-box runs (level 3).
- Directory listings and their reference order: reference bundles'
  coverage archives and diagnostics (level 2).
- OPEN QUESTION: titles and command names for analyze, install and
  build-for-testing (not probed; Ycode's choice is in the table's style).
- OPEN QUESTION: the argument hash for tests with several arguments
  (observed only for one argument: SHA-256 of its description).
- OPEN QUESTION: the suite order rule (one observation) and `LogStoreManifest.plist`
  in `Logs/Test` (written by the reference tool; not by ycodebuild).
