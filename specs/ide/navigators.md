# Navigators

Ycode modules: `YcodeUI` (`NavigatorAreaController`), `YcodeIDECore`
(`NavigatorTree`, the project navigator's file operations).

## Selector bar

Nine navigators, in this order, selected by ⌘1 … ⌘9:

| # | Navigator | Ycode status |
|---|---|---|
| 1 | Project | implemented |
| 2 | Source Control | implemented (Changes and Repositories trees; `SourceControlNavigatorModel`) |
| 3 | Bookmarks | implemented |
| 4 | Find | implemented (Find and Replace; every kind but Asset References; see "Ycode implementation" below) |
| 5 | Issue | implemented |
| 6 | Test | implemented (discovered tests by target and suite, with result glyphs; `TestDiscovery`) |
| 7 | Debug | implemented (see debug.md) |
| 8 | Breakpoint | implemented |
| 9 | Report | implemented (build, clean, test, analyze and package reports; `ReportNavigatorModel`) |

Status checked against the code on 2026-10-28.

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
left two-segment control, ⌘0): the conversation list, transcript and
message field of `coding-assistant.md` §4.

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
under it; then the scope pop-up "In <scope>". Mode: Find, Replace. Kind:
Text, Multiple Words, Regular Expression, Symbols, Ancestor Types,
Descendent Types, Conforming Types, Call Hierarchy, Asset References;
Ycode implements all but Asset References (listed disabled). Match:
Containing (default), Matching Word, Starting With, Ending With. Scope:
Package or Project (default), its dependencies and both (disabled),
Current Find Results (the files of the last workspace search; disabled
without results), the "Containing Groups" of the selected file
(outermost first), Custom Scopes…. Return searches every file in scope,
up to 1000 matches. Text mode matches the query literally; Regular
Expression mode uses ICU syntax (NSRegularExpression). An invalid
expression and empty matches give no results. Changing an option re-runs
the last search. Results: one row per file, "name (N)", with one child
per match showing the trimmed line; selecting a match opens the file
and selects the match. Find in Workspace (Shift-Command-F) shows this
navigator and searches for the editor's selection, if any. The rest is
Ycode's own design, below.

### Ycode implementation

Modules: `YcodeIDECore/Find` (portable: `FindQuery`, `FindEngine`,
`FindScope` and `FindScopeResolver`, `FindIgnoreRules`, `ReplacePlan`
and `ReplaceHistory`, `SemanticFind`, `FindNavigatorModel`),
`YcodeLanguage/LSPFind.swift` (`workspace/symbol`, type hierarchy),
`YcodeUI` (`Navigator/FindNavigator.swift`, `FindScopeEditor.swift`,
`Window/WorkspaceWindowController+Find.swift`,
`Editor/SourceEditorController+FindCommands.swift`).

**Matching (textual kinds).**

- Text: the query literally. Regular Expression: ICU syntax; `^` and `$`
  match at line starts and ends; `.` does not cross a line; `\n` and
  `[\s\S]` do, so a match can span lines (multi-line). Its row is the
  first line; `lineSpan` counts the lines.
- Multiple Words: the query split at white space; a line matches when it
  holds every word (any order); each occurrence of each word on such a
  line is a result.
- Match styles, applied to the pattern (or to each word): Matching Word
  puts "no word character" on both sides, Starting With before, Ending
  With after. Word characters are letters, digits and `_` (lookarounds,
  not `\b`, so a query that begins with punctuation still works).
- Aa off: case-insensitive.
- Replace text: literal for Text and Multiple Words. For Regular
  Expression it is a template: `$0`…`$9` are the match and its capture
  groups; `\` escapes `$`.

**Which files.**

- Scopes (`FindScope`): the workspace (every file of the project
  navigator's tree); one project; a group, folder or file (Containing
  Groups, Find in Selected Groups…); Open Files (Ycode's addition: the
  files open in this window's editor tabs); Current Find Results; a custom
  scope.
- Folders are listed on disk: synchronized folders, package directories,
  and folder references (a file reference to a directory). Bundles are
  not entered: `xcassets`, `xcodeproj`, `xcworkspace`, `xcdatamodeld`,
  `framework`, `app` and the like.
- Inside folders only, these files are skipped:
  - names never searched: `.git`, `.svn`, `.hg`, `.build`, `.swiftpm`,
    `.build-ide`, `DerivedData`, `xcuserdata`, `node_modules`,
    `.DS_Store`, and names starting with ".";
  - the patterns of the enclosing Git repository: its
    `.git/info/exclude` and each `.gitignore` from the repository root
    down (gitignore syntax: `#`, `!`, trailing `/`, anchoring `/`, `*`,
    `?`, `[…]`, `**`).

  A file the project lists by reference is always searched. A folder the
  search starts from is searched even when the repository ignores it.
- Binaries are skipped: known binary extensions (images, archives,
  objects, media, fonts, databases); a NUL byte in the first 8 KB;
  text that is neither UTF-8 nor UTF-16 with a byte-order mark. Files
  over 16 MB are skipped.
- Editors with unsaved changes are searched instead of their files.

**Engine.** Files are searched on up to 8 threads. Results are delivered
in navigator order as each file finishes, so the outline fills from the
top. For an ASCII literal, the raw bytes are checked first and a file
without the text is never decoded. Return in the field streams the
results (a new search cancels the running one). Changing an option or
the scope re-runs the search. The search stops after 1000 matches
(the file that reaches the limit is kept whole) and the count line says
so.

**Count line.** At the right of the scope row: "N results in M files",
"1 result in 1 file", "No results", "Searching…" while running,
"(stopped at the limit)", and after a replace "Replaced N occurrences in
M files".

**Results and keyboard.** The match is bold on a pale yellow ground in
its row. Clicking a match, or moving to it with the arrow keys, opens
the file and selects the match. Find ▸ Find Next / Previous in Workspace
(⌃⌘G / ⌃⇧⌘G) step through every match across files, wrapping, selecting
the row and the text. The query field keeps the last 10 searches (its
pull-down).

**Replace mode.**

- Mode ▸ Replace adds a row under the query field: the replacement
  field (placeholder "With"), Replace and Replace All.
- Every result row gets a checkbox in place of its icon. A file's
  checkbox shows mixed when only some of its matches are checked; all
  start checked.
- A checked match reads as a preview: the match struck out on a pale red
  ground, then the replacement in bold on pale green. An unchecked match
  is dimmed.
- Replace All replaces every checked match. Replace replaces the checked
  matches of the selected rows (a file row stands for its matches).
- Before replacing, each match's text is compared with what is now at
  its range. If the file changed since the search, that match is left
  alone and counted as stale.
- Files open in an editor change there, unsaved, as one undoable edit
  each. Other files are written to disk, and the language server is told.
- Undo across files: one Replace is one step of the window's undo
  manager ("Replace N Occurrences"). That step reverts the editors' edits
  and puts every file it wrote back; redo replays both. If a file on disk
  changed since, it is left alone (a conflict) rather than overwritten.
- After a replace (or its undo), the search runs again.
- Replace works with the textual kinds. With a semantic kind the
  replacement row is disabled.
- **Decision:** Return in the replacement field does nothing destructive;
  only the buttons replace.

**Semantic kinds (language server).** They use sourcekit-lsp, which
has the whole project through Ycode's build server (`language.md`
§Build server).

- The query names the symbol. `workspace/symbol` finds candidates, kept
  when the name matches the query's match style and case. The name
  matched is the base name: "greet" for "greet(times:)". Exact names
  come first, at most 20. Each candidate's position is moved onto its
  name in its line.
- Symbols: the Match pop-up lists **Definitions** and **References**
  (Ycode's items; open question below).
  - Definitions: names containing the query, by file, with the kind's
    letter badge and the container as detail.
  - References: the exact name; `textDocument/references` (with the
    declaration) for each symbol of that name, merged and de-duplicated.
    Rows by file then line, "line: text"; heading "<name> — N
    references".
- Call Hierarchy: callable symbols; `prepareCallHierarchy`, then
  `callHierarchy/incomingCalls`, callers of callers, two levels.
  Heading "Callers of <name>".
- Ancestor Types: `typeHierarchy/supertypes`, followed up to 8 levels
  without repeating a type. Descendent Types: `typeHierarchy/subtypes`;
  for a protocol, only the protocols that refine it. Conforming Types: a
  protocol's subtypes that are not protocols (types and extensions that
  adopt it). Headings "Ancestor types of …", "Descendent types of …",
  "Types conforming to …".
- Without a server the count line reads "No language server". A server
  without a request (error −32601) gives "The language server does not
  support <kind>".
- The editor's commands start from the caret instead of a name:
  - Find ▸ Find Ancestor / Descendent / Conforming Types: the type
    hierarchy of the symbol at the caret.
  - Find Selected Symbol in Workspace and Find Call Hierarchy keep their
    `refactoring.md` §Find behavior.

  Results show in the Find navigator.

**Custom scopes.** Custom Scopes… opens an editor sheet:
- the saved scopes on the left, with + and −;
- for the selected scope: its name, "Match All | Any of the following
  rules:", then rules of a field, an operator and a value. The add-rule
  button reads "Add Rule"; each rule has a − button.
- Fields: Name, Path, Extension, Location. Operators: contains, is, is
  not, starts with, ends with, matches regular expression.
- Comparisons ignore case.
- Location's value is a folder or group path ("is" means inside it), or
  "Open Files".
- Save keeps the scopes that have a name and at least one rule. They are
  stored in the user's preferences (`Ycode.findCustomScopes`, every
  workspace).
- The scope menu lists Open Files, then the saved scopes, then Custom
  Scopes….

**Find menu items wired here** (`reference-ui-5.md` §2.5):

- Find and Replace in Workspace… (⌥⇧⌘F): this navigator in Replace mode,
  searching for the selection.
- Find Next / Previous in Workspace: enabled with results.
- Find Selected Text in Workspace: the selection as Text, Containing.
- Find Selected Words in Workspace: the selection as Text, Matching Word
  (Ycode's reading).
- Find Ancestor / Descendent / Conforming Types: enabled in a source
  editor with a language server.
- In the file:
  - Find and Select Next / Previous: the next find-bar match after the
    selection (before it), wrapping, added to the selection.
  - Select Next / Previous Occurrence: the same with the selected text
    (exact case). With only an insertion point, it first selects the word
    there.
  - Replace and Find Previous: replaces the current match, then moves to
    the match before it.
  - Use Selection for Replace (⇧⌘E): the selection becomes the find bar's
    replacement text.

**Performance** (`FindPerformanceTests`, debug builds, warm file cache;
the Mac is shared with other agents, the Linux workstation is x86-64 with
16 threads):

| Search | Mac (arm64) | Linux (x86-64) |
|---|---|---|
| List 5,000 generated Swift files (folder reference) | 0.18 s | 0.05 s |
| Rare literal (the byte pre-check rules out 99 % of files) | 0.11 s | 0.03 s |
| Common literal, 40,000 matches | 0.14 s | 0.07 s |
| Matching Word with case, 10,000 matches | 0.12 s | 0.04 s |
| Regular expression with a group, 40,000 matches | 0.13 s | 0.07 s |
| This repository's checkout: list | 0.43 s (2,500 files, `.gitignore` applied) | 0.03 s (1,369 files of `ycode/`) |
| The same: rare literal / common literal / regex | 0.29 / 0.33 / 0.27 s | 0.03 / 0.06 / 0.05 s |

## Symbols (jump bar and Open Quickly)

There is no Symbol navigator in the reference (Bookmarks took its place).
The same symbol
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

### Symbol navigator (Linux IDE)

**Decision** (orchestrator, beta 2): the Linux IDE has a Symbol navigator
at the third place of the selector bar (⌘3, where the reference has
Bookmarks; the Linux IDE has no Bookmarks navigator yet), titled
"Symbols". `SymbolNavigatorModel` (`YcodeIDEShell`) reads the scan above
for every source file of the workspace (an edited open file as edited),
off the main thread, when the navigator appears:

- Rows: one per file that declares something (its file icon and name in
  bold), then its declarations nested as the scan nests them, each with
  its letter badge (`DocumentSymbols.badge`) and name; the outline metrics
  of `metrics.md` (22-point rows, 12 points per level, the triangle at
  x 12, the badge at x 25, the name at x 45). Files and types collapse.
- The bottom bar's filter keeps the declarations whose name contains it
  (any case), the types that hold them and their files, all expanded.
  With a language server running and two or more characters typed, the
  server's `workspace/symbol` answer (0.25 s after typing stops) joins
  them: matches the scan does not see (for example a function declared
  in another function's body) are added under their file, by line, their
  LSP kind mapped to a badge.
- Selecting a declaration opens its file at its line; a file row expands
  or collapses.
- Empty: "No Symbols" (with the filter, "No declaration contains “…”").

## Test navigator

(reference-ui-2.md §6.) The test plan as root ("<scheme> (Autocreated)"),
then each test target (packages: the folder under `Tests/`; projects: the
target compiling the file), then suites and test functions with
parentheses. Plan and target rows add "N Tests, M Failing"; status
diamonds show passed and failed.

## Ycode implementation: project navigator file operations

Modules: `YcodeIDECore` (`ProjectFileOperations`, `ProjectGraphEdits`,
`FileSystemJournal`; portable, no AppKit) and `YcodeUI`
(`NavigatorAreaController+ProjectOps`,
`WorkspaceWindowController+ProjectNavigatorOps`, `AddFilesAccessory`).
This section is Ycode's design. Where the reference's behavior has not
been observed, the choice is Ycode's own and is listed under the open
questions in Evidence.

### Items, places and names

- An operation acts on **items**: a pbxproj object (a group, a file
  reference, a synchronized folder; the project row stands for the main
  group) or, for rows with no object of their own (inside a synchronized
  folder, in a package), a path on disk.
- **Where a new item goes** (New Group, New Folder, New File, Add
  Files): into the selected group or folder, at the end; with a file
  selected, into its group right after it. With no selection: the main
  group (or the package folder). In the main group, "at the end" means
  before the Products group when that group is last.
- **Default names**: "New Group", "New Folder", then "New Group 2", … ,
  free both on disk and among the group's children. In a visible window
  the new row's name is then edited in place.
- **Names** are trimmed and must not be empty, `.`, `..`, or contain `/`.
  An existing file is never overwritten.

### Effects on the project file

Every edit goes through the object graph; the writer then serializes the
whole file (`specs/formats/pbxproj.md`), so untouched objects keep their
bytes. Keys below are the object's keys (the writer sorts them).

| Operation | Disk | Project |
|---|---|---|
| New Group | a folder of that name in the group's folder (kept if it already exists) | `PBXGroup` {`children` = (), `path` = name, `sourceTree` = `<group>`} |
| New Group without Folder | — | `PBXGroup` {`children` = (), `name` = name, `sourceTree` = `<group>`} |
| New Folder, in a group | a folder | `PBXFileSystemSynchronizedRootGroup` {`path`, `sourceTree` = `<group>`}, appended to the `fileSystemSynchronizedGroups` of every target that includes a file of that group |
| New Folder, in a folder or a package | a folder | none |
| New File, in a group | the template's files | a `PBXFileReference` {`lastKnownFileType` by extension, `path` = file name, `sourceTree` = `<group>`} per top-level item; a `PBXBuildFile` in each chosen target's phase for its type (below). Without a choice: compiled files join the first target that has a Sources phase |
| New File, in a synchronized folder | the files | each target that includes the folder but was not chosen gets the file in its `PBXFileSystemSynchronizedBuildFileExceptionSet`'s `membershipExceptions` (the set is created when the target has none) |
| Add Files | copied or moved into the destination's folder, unless already there (Reference: in place; into a synchronized folder the items are always copied or moved) | a file or bundle: a reference (build files as for New File); a folder, by the Groups choice: Create groups, a `PBXGroup` with `path` and a reference per item, recursively (Finder order, hidden names skipped); Create folder references, a reference with `lastKnownFileType` = `folder` (Resources phase); Create folders, a synchronized folder in the chosen targets. A `.xcdatamodeld` is an `XCVersionGroup` (`versionGroupType` = `wrapper.xcdatamodel`, `currentVersion` from `.xccurrentversion`) |
| Remove References | — | the objects, everything under a group, the build files pointing at any of them, their places in groups; for a synchronized folder its exception sets and its entry in each target's `fileSystemSynchronizedGroups` (the key goes when it is empty) |
| Move to Trash | a reference's file, a synchronized folder or a model bundle goes to the Trash; for a group, its members' files, and then its own folder if nothing is left in it; an item in a synchronized folder | as Remove References; for an item in a synchronized folder, its paths leave the exception sets (an exception set left empty is removed, and the folder's `exceptions` key with it) |
| Rename | the file or folder is renamed when it has a location there | `path`'s last component (a plain `path` then needs no `name`; a `path` through other folders keeps `name` = the new name); `lastKnownFileType` follows a changed extension; a group without a folder gets `name`. In a synchronized folder, the exception sets' paths (and the paths under a renamed subfolder) follow |
| Move (drag, within a project) | into the destination group's own folder (a group with `path`, or the main group) when the item lies directly in its old group's folder; otherwise it stays | the object moves between `children` lists; every `<group>` path under it is rewritten so it resolves to where the file now is (a path that climbs out with `..` keeps `name`) |
| Move into a synchronized folder | into the folder | a file reference (or model) is removed with its build files; owning targets that did not have the file get an exception for it |
| Move out of a synchronized folder into a group | into the group's folder | a reference in the group, in the targets that had the file; its exception entries go |
| Group from Selection | with a folder: the folder, and the items move into it as for Move | a group at the first item's place holding the items (same group only) |
| Folder from Selection | the folder, the items move into it | in a folder: the exception paths follow. In a group (file references only): a synchronized folder at the first item's place, in every target any of the files was in; a file that was not in one of them gets an exception for it; the references and their build files go |
| Sort by Name / by Type | — | the group's `children` reordered (one level): by name, Finder order; by type, groups and folders first, then by extension, then name. The main group keeps Products last |
| Convert ▸ To Group | — | the synchronized folder (and its exception sets and target entries) is replaced, at its place, by a `PBXGroup` with its `path` holding a reference per item on disk (sub-folders as groups, Finder order); each file joins, by type, the targets it was in through the folder |
| Convert ▸ To Folder | — | a group whose tree is only groups with a one-component `path` and references named like their files (all `<group>`, all on disk, no build file with `settings`) becomes, at its place, a synchronized folder with its `path`, in every target any of its files was in; each file on disk that was not in one of those targets gets an exception there. Preflight Conversion to Folder lists what stops it |

Build phase by file type: Sources for source files (the extensions of
`FileCreator.sourceExtensions` and `.xcdatamodel`), Frameworks for
`.framework`, `.a`, `.dylib`, `.tbd`, `.xcframework`; no phase for
headers, `.xcconfig`, `.entitlements`, `.xctestplan`, `.pch`,
`.modulemap` and `Info.plist`; Resources for the rest. A missing phase is
added to the target. New object IDs are random 24-digit hex IDs not in
use (tests use `PBXProj.idSequence`).

### Undo, the Trash and consistency

- Each operation is one `ProjectEdit`: the project before and after, and
  the performed file steps (create file or folder, move, copy, trash).
  If a step fails, the steps already done are reversed and the project
  is left as it was.
- Undo reverses the steps and restores the project from before; redo
  performs them again. Undoing a creation or a copy moves the new item
  to the Trash; undoing a trash moves the item back out of it. Nothing
  is ever deleted outright. On Linux the trash is the freedesktop.org
  trash (`Trash`).
- Undo and redo go through the window's undo manager ("Undo New Group",
  "Undo Move to Trash", …). An undo is refused when the project was
  changed since by something else (it would be lost).
- Unsaved editor text is saved before an operation; editors showing a
  moved or renamed file (or a file in a moved folder) follow it.
- With Settings ▸ Source Control on, every created, moved and trashed
  path inside the repository is staged with `git add -A -- <path>`, so a
  move or rename shows as a rename (`R`), as `git mv` would record it.

### Commands

- File ▸ New ▸ Group, Group without Folder, Group from Selection, Group
  from Selection without Folder, Folder (⌥⌘N), Folder from Selection;
  File ▸ Add Files to “<project>”… (⌥⌘A); Edit ▸ Delete (⌘⌫, and ⌫ in the
  navigator); Edit ▸ Sort ▸ By Name, By Type; Edit ▸ Convert ▸ To Group
  (a selected synchronized folder), To Folder and Preflight Conversion to
  Folder (a selected group; the preflight shows its findings in an
  alert); Edit ▸ Cut (⌘X) with the navigator focused marks the selection,
  and Edit ▸ Paste ▸ Move Item Here (⌥⌘V, shown only then) moves it to the
  insertion point, as a drag would. With no navigator selection
  the group, folder and sort items are disabled; the group and sort items
  are hidden or disabled inside folders, as `reference-ui-6.md` §8 item 6
  says.
- Delete asks: "Move to Trash", "Remove References" (only when every
  item has a reference), "Cancel".
- Add Files…: an open panel (files and folders, several) with Action
  (Copy files to destination, Move files to destination, Reference files
  in place), Groups (Create folders, Create groups, Create folder
  references) and a checkbox per target, preset to the targets of the
  selected file (else the first target). Files dropped from the Finder
  use the last options, with the targets of the destination group's
  files.
- Return on a selected row renames it in place (the name without its
  extension is selected; Escape cancels).
- Drag and drop: rows onto a group, a folder or between rows; a drop on
  a file goes after it in its group; not into itself or while the filter
  is active.
- Context menu on project rows (Ycode's order, until the reference's
  menu is observed): Show in Finder; New File from Template…, New Empty
  File, Add Files to “<project>”…; Rename, Delete; New Group, New Group
  without Folder, New Group from Selection, New Group from Selection
  without Folder (not in folders), New Folder, New Folder from Selection;
  Sort by Name, Sort by Type (not in folders); Find in Selected
  File…/Groups….
- New File from Template… and New Empty File create in the navigator's
  insertion point when the project navigator has a selection (else the
  open file's folder), through the same operations (so they are undoable
  and land in the selected group, even a group without a folder).

## Council round 1 measurements (2026-11-04)

These are Project navigator observations from the council session's 1x
captures of the reference: a 1400 × 880 window, inactive, light, with the
navigator 290 wide. The test project has one synchronized root folder,
"GlassScroll" (`PBXFileSystemSynchronizedRootGroup`), holding
`ContentView.swift`, `GlassScrollApp.swift`, `Long.swift`, `Stripes.png`
and a `Models` folder of 48 Swift files. Row geometry is in `metrics.md`
§12.1, scroll bars in §12.2, the bars' glass and scroll-under in
`liquid-glass.md` §7. The checklist is `fidelity-council.md`.

1. **Sort order: folders first.** Inside the synchronized folder the
   order was Models, then ContentView, GlassScrollApp, Long, Stripes.
   With Models expanded and scrolled to the end, the list ended Model48,
   ContentView, GlassScrollApp, Long, Stripes. Subfolders come before
   files, and each is sorted by name. This answers the open question
   "folders first or mixed" (Evidence) for synchronized folders. Plain
   groups were not observed. **Correction to "Project navigator" above:**
   "folders and files mixed" holds for packages and plain directory
   listings until observed; synchronized folders put folders first. Ycode
   mixed them (ContentView, GlassScrollApp, Long, Models, Stripes).
2. **Names** show without extensions ("Long", "Stripes"), in both apps.
3. **The open file's row is selected.** At rest, with Long.swift in the
   editor, Long's row carried the selection band: 22 tall, inset 10 on
   both sides, corners about 8, #E7E7E8 on #F2F2F3 in an inactive window
   with the outline unfocused (`metrics.md` §12.1). Opening another file
   moves the band to it in the same frame as the editor change
   (`editor-area.md` §C.6). Ycode drew no selection band. The selection
   colour in an active window with the outline focused is to measure in
   round 2.
4. **Icon colour families.** Ycode draws its own icons, so only the
   colour family matters. Values are inactive-window sRGB.

   | Row | Reference | Ycode in the session |
   |---|---|---|
   | Project | blue rounded-square badge (#78AFF2) | blue |
   | Folders, synchronized root folder | light blue (#9ACBF6) | blue |
   | Swift source file | **orange** glyph (light orange #F6B59A when inactive) | **blue** "</>" glyph |
   | PNG image | blue picture badge (#78AFF2) | a generic grey-blue document |

5. **Expanding a folder** (an accessibility "disclosing" set on the
   Models row) shows all child rows in **one frame**, with no animation,
   in both apps. The reference's change came 63 ms after the input began,
   Ycode's 40 ms after.
6. **Scrolling under the bars.** Rows scroll beneath the selector capsule
   and beneath the bottom filter capsule, out to the area's edges:
   1. Under the **filter capsule** the rows stay visible, moderately
      blurred: glyph shapes and the orange icons are discernible (pixel
      change up to 109 levels).
   2. Under the **selector capsule** they show only as a faint veil (at
      most 10 levels).
   3. Nothing shows above the selector capsule.
   4. The first row below the selector, and the last above the filter
      bar, are at full contrast, with no fade.
   5. Ycode's rows stop at its bars (its change region began at y 88).
7. **Scrolling** moved the rows with the input 1:1 within a frame
   (`editor-area.md` §C.8). The longest pause between changed frames was
   23 ms in the reference and 48 ms in Ycode.

## Evidence

- Find, Symbol and Report navigator roles: Apple's public Xcode Help
  (level 1). Row formats, badges and the symbol rules are Ycode's own.
- Find options (modes, kinds, match styles, case toggle, scope menu):
  `specs/ide/reference-ui-2.md` §3 (level 3).
- OPEN QUESTION: Find result row text and the result limit.
- Find "Ycode implementation": the search engine, ignore rules, binary
  detection, count line, Replace mode's preview and checkboxes, undo
  grouping, custom-scope editor and the Symbols kind's Definitions /
  References items are Ycode's own design (no reference observation).
  The LSP requests and results: the Language Server Protocol 3.17
  specification (`workspace/symbol`, `textDocument/references`,
  `callHierarchy/*`, `typeHierarchy/*`; level 1). Their behavior on
  sourcekit-lsp is checked in `SourceKitLSPFindTests` (level 3, Ycode).
  `.gitignore` syntax: Git's public documentation (level 1).
- OPEN QUESTION (Find): the reference's semantics of Multiple Words, the
  Symbols kind's Match items, Find Selected Words in Workspace, and the
  custom-scope editor's rules; the reference's Replace preview and
  whether its Replace All saves the files; Asset References.
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
- Sort order inside synchronized folders: folders first, then files, each
  by name (council round 1, level 3). OPEN QUESTION: which names it hides,
  and the order in plain groups and packages.
- Issue grouping (by file only) and row text: `specs/ide/reference-ui-2.md`
  §1 (level 3).
- OPEN QUESTION: icons for each navigator (ours are SF Symbols chosen by
  us at runtime).
- Project navigator file operations (Ycode implementation): the pbxproj
  classes and keys (`PBXGroup` `path`/`name`,
  `PBXFileSystemSynchronizedRootGroup`, exception sets'
  `membershipExceptions`, targets' `fileSystemSynchronizedGroups`,
  `XCVersionGroup`) are `specs/formats/pbxproj.md` and the corpus
  (level 2); the menu items and their enablement in folders are
  `reference-ui-5.md` §2.2, §2.3 and `reference-ui-6.md` §8 (level 3);
  the file types added to `PBXProj.fileType` follow CocoaPods Xcodeproj's
  `FILE_TYPES_BY_EXTENSION` (MIT, level 1); git staging follows git's
  documentation (level 1). Each operation's output is checked against
  hand-written fixtures (`ycode/Tests/YcodeIDECoreTests/Fixtures/NavigatorOps`)
  and, opt-in (`YCODE_NAV_OPS_BUILD=1`), by building the result with
  `ycode build`.
- OPEN QUESTION (navigator file operations; Ycode's choices stand until
  observed): where the reference inserts new groups and files (Ycode:
  after the selected file, or at the end of a selected group); the
  default names ("New Group", "New Group 2"?); whether New Folder in a
  group adds the new synchronized folder to targets (Ycode: the targets
  of the group's files); whether Add Files writes `name` for paths
  outside the group; Add Files' options and their defaults; the Delete
  sheet's wording; Move to Trash for a group with a folder that still
  holds other files (Ycode keeps the folder); Sort by Type's order; the
  project rows' context menu; whether a move between folders keeps the
  file in the targets of a destination folder it was not in; what the
  reference's Convert ▸ To Folder accepts and how Preflight reports it.
- Council round 1 section, level 3: the council session's 1x stills and
  recordings of the reference (row order, colour runs, icon colours from
  their most saturated pixels, per-frame changes);
  `research/tools/council-r1/measure_captures.py`,
  `research/notes/council-r1-2026-11-04.md`. The test project's group
  classes come from its own `project.pbxproj` (level 2).
- The Linux IDE's Symbol navigator: Ycode's own design (the reference has
  none). swift-build's progress-line form in build logs is from SwiftPM
  6.4's own output (level 3, Ycode's builds on Linux).
