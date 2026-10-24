# Build: requests, engines and diagnostics

Ycode module: `YcodeBuild`. CLI: `ycode build`.

## Requests

A build request names:

| Field | Meaning | xcodebuild flag |
|---|---|---|
| container | a project (`.xcodeproj`), workspace (`.xcworkspace`) or package directory (`Package.swift`) | `-project`, `-workspace`, or the working directory |
| scheme | scheme name | `-scheme` |
| configuration | build configuration (`Debug`, `Release`) | `-configuration` |
| destination | `key=value[,key=value]` specifier, e.g. `platform=macOS,arch=arm64`, `platform=iOS Simulator,name=…` | `-destination` |
| action | `build`, `clean`, `test`, `analyze`, `build-for-testing` | trailing action word |
| derivedDataPath | where products and intermediates go | `-derivedDataPath` |
| settings | `NAME=value` overrides, highest precedence | trailing `NAME=value` arguments |

The IDE commands map as follows (shortcuts from Apple's public Xcode
keyboard-shortcut reference): Build ⌘B → `build`; Run ⌘R → `build` then
launch; Test ⌘U → `test`; Clean Build Folder ⇧⌘K → `clean`; Analyze ⇧⌘B →
`analyze`; Stop ⌘. cancels the running operation.

## Engines

A build engine takes a request and returns an operation: an ordered event
stream plus a cancel action. Events are:

- `output(line)`: one raw log line (for the build log / report navigator);
- `activity(text)`: short progress text for the toolbar activity view;
- `issue(diagnostic)`: one finished diagnostic (see below);
- `finished(result)`: status (`succeeded`, `failed`, `cancelled`), exit code
  and all issues. It is always the last event.

Engine 1 (`XcodebuildEngine`, interim) runs `xcrun xcodebuild <args>` with
stdout and stderr merged, stdin closed. Exit status 0 means success. Cancel
sends SIGINT (xcodebuild then stops its build and reports failure; Ycode
reports `cancelled`).

Engine 2 (planned, M3 proper) generates PIF from the project model and
drives swift-build's build service; it must emit the same events, so the UI
does not depend on which engine runs.

Activity text: a log line that starts with a known step verb maps to a
label plus the last path component on the line — `CompileSwift`,
`SwiftCompile`, `CompileC` → "Compiling"; `Ld` → "Linking"; `CodeSign` →
"Signing"; `CompileAssetCatalog`; `ProcessInfoPlistFile`;
`PhaseScriptExecution` → "Running script"; `Resolve Package Graph`.

## Diagnostics

Line grammar (the clang/swiftc/ld textual form, one issue per line):

```
issue    := [prefix ": "] severity ": " message
prefix   := file ":" line [":" column] | file | tool
severity := "error" | "warning" | "note" | "remark"
fixit    := 'fix-it:"' file '":{' l1 ':' c1 '-' l2 ':' c2 '}:"' text '"'
```

- The earliest `": <severity>: "` marker splits prefix from message, so a
  message may itself contain such text.
- Numbers are taken from the end of the prefix (at most two), so file paths
  may contain colons. A prefix with no numbers is a file (line 0) when it
  contains `/` or `.`, else a tool name (no location), e.g. `ld: warning:`.
- Lines that start with whitespace (source excerpts, carets) are not issues.
- A `note` attaches to the open issue; a `fix-it` line (clang's
  `-fdiagnostics-parseable-fixits` form; text uses C escapes) attaches to the
  open issue. A note with no open issue stands alone.
- An issue is complete when the next issue line or the end of the stream
  arrives.
- An exact repeat (same severity, message, location, notes, fix-its) is
  dropped: compilers repeat issues when a file is built for several
  architectures.

`ycode build --quiet` prints errors and warnings in the same line form plus
a status line on stderr; exit status 0 on success, 1 otherwise.

## Evidence

- Request flags and actions: `xcodebuild -help`/`man xcodebuild` (level 1/3).
- Diagnostic line grammar: clang and Swift compiler documentation and open
  source (`-fdiagnostics-parseable-fixits`, swift-driver) (level 1); a
  black-box `xcodebuild` run of a two-line Swift package with an undefined
  identifier gave `…/main.swift:2:7: error: cannot find 'y' in scope` (level 3).
- Step verbs in the build log: observed in `xcodebuild` output (level 3).
- Shortcuts: Apple's published Xcode keyboard-shortcut list (level 1).
- Issue grouping is by file: `specs/ide/reference-ui-2.md` §1 (level 3).
  Build log layout: same spec §5.
- OPEN QUESTION: whether build-system `note:` lines without a location appear in the issue
  navigator. Needs a GUI observation pass.
- OPEN QUESTION: exact cancel behavior of the IDE's Stop during a build.
