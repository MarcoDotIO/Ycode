# Navigators

Ycode module: `YcodeUI` (`NavigatorAreaController`, `NavigatorTree`).

## Selector bar

Nine navigators, in this order, selected by ⌘1 … ⌘9:

| # | Navigator | Ycode status |
|---|---|---|
| 1 | Project | implemented |
| 2 | Source Control | empty placeholder |
| 3 | Bookmarks | implemented |
| 4 | Find | implemented (literal text) |
| 5 | Issue | implemented |
| 6 | Test | empty placeholder |
| 7 | Debug | implemented (see debug.md) |
| 8 | Breakpoint | implemented |
| 9 | Report | implemented (build logs) |

Order and names follow `specs/ide/reference-ui.md` §2 and §7.

Correction (2026-10-19): each navigator's bottom bar, header, toggles,
tooltips and empty state are in `reference-ui-5.md` §5.2. The bar below is
the shared part; the toggles differ per navigator, and Reports' empty
state is "No Logs".

Bottom bar (reference-ui.md §2): a "+" menu (Project: New File…;
Bookmarks: Bookmark File, Bookmark Line; Breakpoints: the breakpoint
kinds), a filter field with a leading options menu, and, for the Project
navigator, two in-field toggles: Recent files (files opened in this
window) and Files with source-control status. Filters combine; a group
stays when a row under it matches. An empty navigator shows a centered
"No Issues" / "No Breakpoints" / "No Bookmarks" style message.

The left area can instead show the Coding Assistant pane (the toolbar's
left two-segment control). Ycode has no assistant; the pane is a
placeholder that says so.

## Bookmarks navigator

Rows grouped by file (file name), each bookmark showing its label and
line. Edit ▸ Bookmark Line labels the caret's line with its trimmed text;
Bookmark File labels the file with its name; the "with Dialog" variants
ask for the label first. A second bookmark on the same line replaces the
first. Navigate ▸ Jump to Next / Previous Bookmark moves among the
focused file's line bookmarks, wrapping; the "In Workspace" variants
continue through all files in path order. Bookmarks are saved per user as
JSON (`[{file, line?, label}]`, sorted keys) at
`<container>/xcuserdata/<user>.xcuserdatad/ycode-bookmarks.json`
(packages: under `.swiftpm/xcode/`), a Ycode-own file name.

## Project navigator

- Project: the top row is the project; below it, the main group's children
  in file order, except the product-reference group (`productRefGroup`,
  "Products"), which is not shown (correction 2026-10-19,
  `reference-ui-5.md` §5.1). At first open the project row and its first
  group are expanded. `PBXGroup`, `PBXVariantGroup`, `XCVersionGroup` are
  groups; `PBXFileReference` rows are files; a
  `PBXFileSystemSynchronizedRootGroup` is a folder whose rows are the
  directory's contents read from disk. Row names are `name`, else the last
  component of `path`. Paths resolve as in `specs/formats/pbxproj.md`.
- Workspace: the workspace row, then one project subtree per project.
- Package: the folder row, then the directory contents.
- Directory listings skip hidden names and `.build`, `.swiftpm`,
  `xcuserdata`, `DerivedData`; bundles (`.xcassets`, `.xcodeproj`, …) are
  leaves. Order: localized standard compare, folders and files mixed.
- Selecting a file opens it in the editor.

## Issue navigator

(reference-ui-2.md §1.) The root row is the workspace name with "N
issues" in secondary text; under it one group per file, titled with the
file name without its extension and sorted by name; issues with no file are
rows directly under the root, after the groups (correction 2026-10-19,
`reference-ui-5.md` §5.3; formerly a "Build System" group). Inside a group issues keep the compiler's
order. Each row shows the severity symbol and the message, wrapped to at
most three lines; the selected row grows to show all of it. Selecting it
opens the file at the line. Notes are not rows. ⌘' and ⇧⌘' step through
issues. Bottom bar: the filter, "Show only issues from open documents and
recently built sources" (Ycode: files opened in this window, plus issues
with no file) and "Show only errors". Not yet: stale-issue (grey) rows
and the filter-token menu. Stale issues are replaced by the next build,
not only by Clean (`reference-ui-5.md` §5.3).

## Breakpoint navigator

Breakpoints grouped by file (sorted by path), each row "line N"; disabled
or deactivated breakpoints are drawn pale.

## Find navigator

(reference-ui-2.md §3.) A header of three pop-ups, "Mode › Kind ›
Match", with an "Aa" match-case toggle (off) at the right; the query field
under it; then the scope pop-up "In <scope>". Mode: Find (Replace listed,
disabled). Kind: Text, Multiple Words, Regular Expression, Symbols,
Ancestor Types, Descendent Types, Conforming Types, Call Hierarchy, Asset
References; Ycode implements Text and Regular Expression, the others are
listed disabled. Match: Containing (default), Matching Word, Starting
With, Ending With. Scope: Package or Project (default), its dependencies
and both (disabled), Current Find Results (the files of the last
workspace search; disabled without results), the "Containing Groups" of
the selected file (outermost first), Custom Scopes… (disabled). Return
searches every text file in scope (by extension), up to 1000 matches.
Text mode matches the query literally; Regular Expression mode uses ICU
syntax (NSRegularExpression); Matching Word wraps the pattern in word
boundaries, Starting With puts one before it, Ending With one after it. An invalid expression and empty matches give no results.
Changing an option re-runs the last search. Results: one row per file, "name (N)",
with one child per match showing the trimmed line; selecting a match opens
the file at that line. Find in Workspace (Shift-Command-F) shows this
navigator and searches for the editor's selection, if any.

## Symbols (jump bar and Open Quickly)

There is no Symbol navigator (Bookmarks took its place). The same symbol
scan feeds the jump bar's symbol component and Open Quickly: one row per source file that has top-level declarations; children are the
declarations in file order, and (Swift) each type's members nest under
it: properties (`var`/`let`, badge V), initializers (`init`, I),
functions, nested types, and enum cases (`case`, one row per `case`
keyword, named by its first element). Declarations inside function
bodies are not listed. Each row has a letter badge (C class/interface, S
struct, E enum, P protocol, X extension, A actor, F function, T typealias,
M macro). Swift: `class struct enum protocol extension actor func
typealias macro` followed by a name at brace depth 0 (comments, strings
and directives ignored; `class func` is not a class). C/ObjC: `@interface`,
`@implementation`, `struct`/`enum` with a body, and function definitions
(name, parameter list, then `{`).

## Report navigator

(reference-ui-2.md §4.) A "Local | Cloud" control at the top (Cloud
disabled). One group per scheme; inside, one row per finished action of
this window, newest first: the action ("Build", "Clean") with
"<relative day>, <time>" in secondary text and an error badge when it
failed. A test run is "<scheme>/<plan>" (plan: the scheme's default test
plan, else "<scheme> (Autocreated)") with the children Insights,
Coverage, Tests, Log and Build. Selecting a build row shows the build log
(reference-ui-2.md §5: "All | Recent", "All Messages | All Issues | Errors
Only" (All Issues), Export…, a filter; the section "Build target <name>"
with "<Project|Package> <name> | Configuration <c> | Destination <d>"; the
footer "Build <succeeded|failed> <M/D/YY>, <time>  <n> seconds" and "N
errors, M warnings"). A test run shows its summary; Tests and Coverage
show those pages (reference-ui-2.md §6; Ycode records no durations or
coverage yet, shown as "—" and "No coverage data"). Not yet: the
Package group, nested step rows in the log, the SDK in the subtitle.

## Test navigator

(reference-ui-2.md §6.) The test plan as root ("<scheme> (Autocreated)"),
then each test target (packages: the folder under `Tests/`; projects: the
target compiling the file), then suites and test functions with
parentheses. Plan and target rows add "N Tests, M Failing"; status
diamonds show passed and failed.

## Evidence

- Find, Symbol and Report navigator roles: Apple's public Xcode Help
  (level 1). Row formats, badges and the symbol rules are Ycode's own.
- Find options (modes, kinds, match styles, case toggle, scope menu):
  `specs/ide/reference-ui-2.md` §3 (level 3).
- OPEN QUESTION: Find result row text and the result limit.
- Find scope label "In Project" in a project workspace: confirmed
  (`reference-ui-5.md` §5.4, level 3).
- Products group hidden, first-view expansion, fileless issues at the
  root, per-navigator bars: `reference-ui-5.md` §5 (level 3).
- Navigator order, Bookmarks, the bottom bar and the Coding Assistant
  segment: `specs/ide/reference-ui.md` (level 3).
- Report navigator rows and grouping (by scheme, newest first, no date
  groups): `specs/ide/reference-ui-2.md` §4 (level 3).


- Navigator names, order and ⌘1–⌘9: Apple's public Xcode Help and
  keyboard-shortcut reference (level 1).
- pbxproj group classes: `specs/formats/pbxproj.md` (level 2).
- OPEN QUESTION: Xcode's sort order inside synchronized folders (folders
  first or mixed) and which names it hides.
- Issue grouping (by file only) and row text: `specs/ide/reference-ui-2.md`
  §1 (level 3).
- OPEN QUESTION: icons for each navigator (ours are SF Symbols chosen by
  us at runtime).
