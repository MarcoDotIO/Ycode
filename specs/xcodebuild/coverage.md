# xcodebuild: code coverage in result bundles

Ycode: `YcodeXcodebuild` (`Coverage`, `CoverageData`). Related:
`test-actions.md` §1 (profiles), `result-bundle.md` (the store).

When a test run collects coverage (the scheme's "Gather coverage" setting
or `-enableCodeCoverage YES`), the result bundle's test `ActionResult`
carries `coverage` (`CodeCoverageInfo`): `hasCoverageData` true,
`reportRef` → the **coverage report** (a stored file), `archiveRef` → the
**coverage archive** (a stored directory). Both references have no
`targetType`. The root `metrics` gain `totalCoveragePercentage` (Double,
covered / executable lines, 0–1). `xcrun xccov view --report` reads the
report; `xccov view --archive [--file-list | --file <path>]` reads the
archive.

## 1. Data gathered

Inputs: the merged profile `<ProfileData>/<device id>/Coverage.profdata`
(raw profiles of earlier runs in that folder are removed before a run),
and the binaries of the projects' targets: for each target with an
executable (`TARGET_BUILD_DIR/EXECUTABLE_PATH`, not static libraries).
The toolchain's open-source `llvm-cov` provides:

- `llvm-cov export -instr-profile <profdata> <binary> [-object <binary>]…`
  (JSON format 3): per file its *segments* (line, column, count,
  has-count, region entry, gap); per function its mangled name, entry
  count and regions (the first region's start line is the function's line
  number);
- `llvm-cov report -show-functions …` with those files: per function the
  executable (`Lines`) and missed (`Miss`) line counts.

Function names are the simplified demangled form (open-source
`swift-demangle --simplified`: `static Calc.add(_:_:)`, `implicit closure
#1 in AddTests.testAdd()`, `Counter.init()`); other symbols as `llvm-cov`
prints them. Files are attributed to the target whose Sources phase lists
them or whose synchronized folder contains them; targets without files
are left out. Order: unit-test bundles first, then the other targets of
the projects (scheme order, then project order); functions by line.
A file's covered/executable lines are the sums over its functions (lines
shared by a function and its closures count once per function); a
target's and the report's are the sums below them.

Per-line data (for the archive), lines 1 through the last executable
line, follows LLVM's line-coverage rules (open source,
`LineCoverageStats`): the *wrapped* segment is the last segment before
the line; *region starts* are segments on the line with a count that
enter a region and are not gaps. A line is executable unless its first
segment starts a region without a count, and only when the wrapped
segment has a count or a region starts on it. Its count is the largest of
the wrapped count and the counts of the regions starting on it. Its
**subranges** are the column ranges `[1, first segment)`, `[segment,
next segment)`, …, `[last segment, end of line)` with their counts (the
first with the wrapped count), listed when the range has a count different
from the line's; the last range's length is written as 0 ("to the end of
the line"); adjacent listed ranges with the same count merge.

## 2. The coverage archive

A directory stored in the result bundle (`result-bundle.md` §3,
directories) with three files:

`Metadata.plist`: XML plist `{formatVersion: 1}`.

`Index` (little-endian): u32 file count; per file (sorted by path) u64
offset of its path in this file and u64 offset of its data in
`Coverage`; then the paths, each a u16 byte length and the UTF-8 bytes.

`Coverage` (little-endian), one block per file:

    u32 run count
    per run:      u32 execution count (0 for lines that are not executable)
                  u32 flags: bit 31 = executable, bits 16–30 = run length − 1, bits 0–15 = 0
    u32 subrange count
    per subrange: u32 line, u32 column, u32 length (0 = to the end of the line), u32 count, u32 0

Runs cover lines 1 through the last executable line, consecutive lines
with the same executability and count forming one run.

## 3. The coverage report

A binary-plist keyed archive (`NSKeyedArchiver`, root key `root`) of:

| Class (chain to `XCTHCoverageDataContainer`, `NSObject`) | Keys |
|---|---|
| `XCTHCodeCoverage` | `name` (a UUID string), `coveredLines`, `executableLines` (integers), `buildableCoverageObjects` (`NSArray` of targets), `creationErrors` (empty `NSMutableArray`) |
| `XCTHCodeCoverageTarget` | `name` (product name, `CalcTests.xctest`, `libCalcKit.a`), `buildableIdentifier` (`<target id>:primary`), `productPath` (the executable, or the product for static libraries), `coveredLines`, `executableLines`, `sourceFiles` (`NSMutableArray` of files) |
| `XCTHCodeCoverageFile` | `name` (file name), `documentLocation` (absolute path), `coveredLines`, `executableLines`, `functions` (`NSMutableData`, below) |

`functions` (little-endian): u32 count; per function six u32: covered
lines, executable lines, line number, executable lines, execution count,
0; then the names in the same order, each followed by a NUL byte.

**Archive structure** (the keyed-archive format, so any reader of it
decodes the report; ycodebuild writes it itself, without a platform
archiver, so every platform gives the same bytes): top-level keys
`$archiver` = `NSKeyedArchiver`, `$version` = 100000, `$top` = {`root`:
UID 1}, `$objects`. `$objects[0]` is `$null`; an object is a dictionary of
its keys plus `$class`, values being integers inline and UIDs for
strings, arrays (`NS.objects`: UIDs) and data (`NS.data`). Objects are
numbered depth-first in key order: an object's index comes before the
objects its keys refer to, and its class dictionary (`$classname`,
`$classes` = the chain) follows them, added at its class's first use
only. Equal strings share one entry. The plist is `bplist00` (format
from CoreFoundation's open-source binary-plist reader and writer):
dictionary keys sorted, integers in the smallest of 1/2/4 bytes (8 for
negative values), ASCII strings as such and others as UTF-16BE, object
references and offsets in the smallest width that fits.

## 4. Diagnostics

Test runs also store `diagnosticsRef` (a directory) on the test
`ActionResult`, so `content-availability` reports `hasDiagnostics`. Per
test bundle: `<target>-<UUID>-Configuration-Test Scheme
Action-Iteration-1/<target>-<UUID>/StandardOutputAndStandardError.txt`
with the runner's console output. (The reference tool adds a session log,
`scheduling.log` and a `My Mac_<device id>/testmanagerd.log` from its test
daemon; ycodebuild has no such daemon.)

## Evidence

- Report classes, keys and the function table, archive files and their
  binary layouts, reference forms, `totalCoveragePercentage`, diagnostics
  folder names: result bundles written by `xcodebuild` 27.1 with
  `-enableCodeCoverage YES` for hand-written projects, studied as files
  (level 2), cross-checked with `xccov view` output (level 3).
- Function line counts equal `llvm-cov report -show-functions`, and line
  counts and subranges equal the rules above, on every line of the sample
  files: `xccov view --report --json` and `--archive --json --file` give
  identical output for the reference's and ycodebuild's bundles
  (`conformance.md`). LLVM line rules, `llvm-cov` and `swift-demangle`:
  open source (level 1).
- Archive structure: the reference's report studied as a file (level 2);
  the object order is the one a keyed archiver gives for these keys, so
  a report ycodebuild writes has the same `$objects` layout as one from
  the macOS archiver for the same data (checked with `plutil -p`), and
  `xccov` reads it (`conformance.md`, `test-coverage`). `bplist00`:
  CoreFoundation open source (level 1). Unit test
  `CoverageFormatTests.reportArchiveClasses` pins the bytes for a fixed
  report on macOS and Linux.
- OPEN QUESTION: the meaning of the function table's fourth field
  (observed equal to the executable lines) and of the zero fields.
- OPEN QUESTION: Objective-C/C functions, templates and macro expansions
  (only Swift samples observed). Package schemes: `packages.md` §3.
- OPEN QUESTION: whether adjacent subranges with the same count are
  merged (not observed).
