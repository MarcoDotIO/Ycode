# Spec: reference IDE behavior, pass 6 — fidelity audit: window identity, toolbar layout, activity texts, issue grouping, editor chrome, coding assistant pane

**Status:** boundary spec. It comes from a side-by-side audit of Ycode
(commit 5f74ef9) and the reference release, Xcode 27.1.

**What the audit observed.** Black-box observation of the running
reference (evidence level 3) in the background: accessibility trees,
window captures, plain clicks on buttons and tabs, and menu titles as
listed (not validated, without shortcuts). Two project files the
reference wrote were read as file formats (level 2). The screen could
not be taken over, so menus were not pressed and pop-ups, Settings and
keystroke-driven features were not observed (§13).

**Pass 6b.** A second pass tried to take over the screen. The
computer-use tool gave the reference only plain clicks (no typing, key
presses, right-clicks or menu presses), and the takeover was
interrupted, so it added: validated menu reads through the
accessibility API (titles, shortcuts, check marks, enabled states,
submenu structure), one toolbar click, and a fresh copy of the iOS-only
sample opened without user data. Its results are §2.4.3 (T11), §4.4–§4.5
(E9, E10), §8 items 4–6 (M4–M6) and §9.5 (A7, A4 corrected).

**Relation to earlier specs.**

- It continues `reference-ui.md` to `reference-ui-5.md`. Where they
  conflict, this spec wins; the earlier specs carry correction notes.
- It records labels, order, sizes in points, defaults, states and
  behavior. It records no colors and copies no assets. Ycode draws its
  own glyphs (SF Symbols) and app icon.
- Apple product names and third-party product names are left out of
  Ycode's UI (`AGENTS.md` rule 5). Where the reference shows one, the
  Ycode wording is given.

**Use by implementers.** §0 is the plan. §1–§10 are normative. Gap IDs
(W1, T3, …) are this pass's; they do not reuse pass-5 IDs. Every
requirement is stated here; the audit notes are not needed.

## 0. Prioritized implementation plan

**Priorities.**

- **P0:** a daily Xcode user notices it in the first minute.
- **P1:** noticed in a normal working session.
- **P2:** depth and polish.

**Rounds.** Each round is sized for one implementation agent. R38–R41
hold the P0 items and touch different files, so they can run in
parallel. R44 aligns the coding assistant that is being built now; it
starts after that work merges.

| Round | Priority | Gaps → sections | Areas and files |
|---|---|---|---|
| **R38 Window identity and first open** | P0 / P1 | W1–W4 → §1 | `Window/WorkspaceWindowController.swift` (title; the NSDocument window-title hook), `App/AppSupport.swift` (launch decision, document controller's open of non-workspace files), `Window/WelcomeWindowController.swift` (not shown when a document opens at launch), `Editor/EditorAreaController.swift`, `Editor/EmptyEditorView.swift`, `Window/WorkspaceWindowController+EditorExtras.swift` |
| **R39 Toolbar layout and activity view** | P0 / P1 | T1, T2, T4, T6, T7, T9 → §2, §3 | `Window/WorkspaceWindowController.swift` (toolbar items and order), `+ToolbarRight.swift`, `+Destinations.swift` (pop-up title), `Window/ActivityView.swift`, `Debug/DebugAreaController.swift` (toggle titles), `Inspector/InspectorAreaController.swift` |
| **R40 Editor chrome and caret** | P0 / P1 | E1–E3, E6, E7, E9, E10 → §4 | `Editor/SourceEditorController.swift` (jump bar, line/column, caret on open), `Editor/GutterView.swift` (test diamonds), `Editor/PreviewCanvasController.swift`, `Model/Previews.swift` (auto-show, canvas mode default), the minimap's user-default registration |
| **R41 Issue navigator: grouping and merging** | P0 / P1 | N1, N2 → §5 | `Navigator/IssueNavigatorModel.swift`, `Session/WorkspaceSession.swift` (live and build issue sets), `Session/LanguageSupport.swift`, `Editor/InlineIssues.swift` |
| **R42 Run, test and destination texts** | P1 | T3, T5, T11 → §3.2–§3.4, §2.4 | `Session/WorkspaceSession.swift`, `+Product.swift`, `Session/SimulatorRun.swift`, `Session/RemoteRun.swift`, `Model/DestinationMenu.swift`, `YcodeBuild` (task counts for "n/m") |
| **R43 Menus clean-up** | P1 / P2 | M1–M6 → §8 | `Model/CommandTable.swift`, `App/AppSupport.swift` (menu builder, help menu, recent-documents menu, Edit ▸ Copy / Paste submenus, dynamic titles) |
| **R44 Coding assistant pane alignment** | P1 | A1–A7 → §9 | the assistant's pane and conversation files (new), `Navigator/NavigatorAreaController.swift` (left-area switch), the toolbar New Conversation item, `Model/CommandTable.swift` (File ▸ New ▸ Conversation…, Editor ▸ Show Coding Tools) |
| **R45 Navigator, inspector and debug-area polish** | P2 | N3–N8, I1–I3, D1, E2, E4, E8, T8, T10, W5, W6 → §5.3–§7, §1.4–§1.5 | `Navigator/NavigatorAreaController.swift`, `Navigator/NavigatorBars.swift`, `Model/NavigatorTree.swift`, `Model/TestDiscovery.swift`, `Inspector/*`, `Debug/DebugAreaController.swift`, `Window/WelcomeWindowController.swift`, `Model/Templates.swift` |

**P0 items** (7):

- **W1** The window title is "<workspace> — <document>" again (§1.1).
- **W4** At first open the editor is empty under a "No Selection" jump
  bar; no Start Page (§1.3).
- **T1** The toolbar's right group never overflows; the inspector button
  stays at the far right (§2.2).
- **E3** "Line: L  Col: C" shows the real column; a newly opened file
  has its caret at 1:1 (§4.2).
- **N2** One issue row per diagnostic: live and build copies merge;
  messages start with a capital letter (§5.2).
- (with R39) **T4** The activity view shows "Building • n/m" with a
  spinner (§3.1).
- (with R41) **N1** Issues are grouped by target, then by file (§5.1).

**P1 items:** W2, W3, T2, T3, T5, T7, T11, E1, E7, E9, N3, M1, M2,
A1–A3, A5, A7.
**P2 items:** everything else (pass 6b added E10, M4, M5, M6).

## 1. Window identity, launch, first open

### 1.1 Window title (W1; restates pass 5 §3.4)

1. A workspace window's title is "<workspace display name> —
   <document name>" (an em dash with one space on each side).
   - The document is the focused editor's file name with its extension
     ("AuditApp — Model.swift").
   - With no document: the container's file name ("AuditApp —
     AuditApp.xcodeproj").
   - A package's workspace name is the package name ("AuditPkg —
     AuditPkgTests.swift"). Ycode today shows the bare "AuditPkg".
2. The title is what the accessibility title, the Window menu's window
   list and Mission Control show. It is not drawn in the title bar.
3. Ycode today sets the title and then loses it, because the document
   machinery renames the window after the document's display name. The
   window controller must supply the composed title for the document
   display name, so that every rename path yields §1.1.1.

**Acceptance.** Open AuditApp; the window list reads "AuditApp —
AuditApp.xcodeproj". Open Model.swift; it reads "AuditApp — Model.swift"
and stays so after saving, switching tabs and closing the file (back to
the container name).

> **Status (R38): done (W1).** The workspace window controller supplies
> the composed title for the document display name, and its own title
> updates go through the document's rename, so every path yields §1.1.1.
> A file shown in another editor (property list, catalog, project) is
> named with its extension. Test: `WindowIdentityR38Tests`
> (`titleSurvivesTheDocumentMachinery` fails without the fix).

### 1.2 Launch with a document; opening loose files (W2, W3)

1. Launching Ycode by opening a document (Finder, `open`, Dock drop)
   shows that document's window only. The Welcome window is shown only
   when, after launch and state restoration, no document is open.
2. Opening a source or resource file (any file that is not a project,
   workspace or package) from outside Ycode:
   - if an open workspace contains the file, Ycode brings that
     workspace's window forward and opens the file in its focused editor;
   - otherwise Ycode opens the file in a window of its own (a single-file
     window with the editor only), not an error alert.
3. The "could not be opened … URL type isn’t supported" alert must not
   appear for files Ycode can edit.

> **Status (R38): done (W2, W3).** Every open request goes through the
> document controller: a file an open workspace contains opens in that
> workspace's focused editor (the frontmost such window first); any other
> non-container file opens as a single-file document in a window with one
> source editor, titled with the file name; a file that is not UTF-8 text
> fails as a document. Opens requested while launching hold the Welcome
> window back; it shows once, only if nothing is open after launch,
> restoration and those opens. The app bundle declares source, text,
> JSON, XML and property-list files as an Alternate editor role. Tests:
> `WindowIdentityR38Tests` (`welcomeGateWaitsForOpensRequestedAtLaunch`,
> `looseFilesOpenAsSingleFilesOrInTheirWorkspace`).

### 1.3 Editor at first open (W4; supersedes pass 5 §3.5)

1. A workspace opened with no remembered editor state shows the editor
   area's jump bar with the Related Items button and "No Selection",
   and an empty editor below it. Nothing else is drawn in the editor.
2. The Start Page (Open Quickly field and Recent Files) is shown only in
   a tab or pane that the "New Editor Tabs / Panes Open With: Start Page"
   setting opens (pass 5 §9.2), and then **below** the jump bar.
3. No empty strip may sit above the jump bar (Ycode today draws a
   47-point blank cell at the top left of the editor area when the tab
   bar is hidden).

> **Status (R38): done (W4).** A new editor shows Related Items and "No
> Selection" over an empty, non-editable editor with no gutter; the Start
> Page is shown only by File ▸ New ▸ Tab and new panes per the
> Navigation setting. The blank cell was the gutter (a ruler view)
> drawing past its frame into the jump bar's row; the gutter and the
> scroll view now clip to their bounds. Closing a file (⌃⌘W) still shows
> the Start Page (pass 4 §9) until the reference is observed there. Test:
> `WindowIdentityR38Tests.firstOpenShowsAnEmptyEditorUnderNoSelection`
> (a pixel check across the gutter's edge in the jump bar's row).

### 1.4 Welcome window geometry (W5)

Size 480 × 632 (unchanged). From pass 5 §3.1, refined:

| Element | Requirement |
|---|---|
| Close button | A round button 36 × 36 at (20, 20) from the top left, an "×" glyph; no standard traffic-light buttons |
| Buttons row | "Open…", "Clone…", "New Project ⌄": widths 107, 107, 130; height 36; spacing 8; the row (360) is centered; top at y 242 |
| Recent list | In an inset box with rounded corners. No visible heading ("Recent Projects" stays as the accessibility name only). No permanently visible scroller. |
| Package rows | A package glyph, not a folder glyph |

> **Status (R45): done (W5).** The traffic lights are hidden; a round
> 36 × 36 close button ("×", accessibility title "Close") sits at
> (20, 20) and closes the window. Open…, Clone… and the New Project
> pull-down are 107, 107 and 130 wide, 36 tall, 8 apart, centered, with
> their top 242 points below the window's top. The recent list sits in a
> rounded, bordered inset box with no heading (the list keeps the
> accessibility name "Recent Projects") and an overlay scroller that
> hides itself. A package entry (a folder with a manifest) shows a
> package glyph. Test: `NavigatorInspectorR45Tests.welcomeGeometry`.

### 1.5 New Project pull-down and New Project ▸ App (W6)

1. The Welcome window's New Project pull-down lists: App, Command Line
   Tool, Package…, Playground, —, Choose Template….
2. **App** creates an untitled project at once, without a sheet:
   - folder "Untitled Project" under Ycode's own untitled-projects
     folder in the user's Library (Ycode's location, not the
     reference's);
   - one app target "MyApp" in a synchronized folder "MyApp" holding an
     asset catalog, `ContentView.swift` (a SwiftUI view with a
     `#Preview`) and `MyApp.swift` (the app entry);
   - multiplatform build settings: SDK "auto", supported platforms iOS,
     iOS Simulator, macOS, visionOS, visionOS Simulator; device families
     1, 2, 7; deployment targets the newest SDK major ("27.0");
   - a placeholder bundle identifier that needs no team;
   - the window opens with `MyApp.swift` in the editor, the inspector
     hidden, destination My Mac. Closing the window asks nothing; the
     project stays where it is.
   The file contents are Ycode's own; the setting names and values are
   interop facts (`specs/formats/pbxproj.md`).
3. Command Line Tool, Package… and Playground keep Ycode's current
   behavior (template sheet or save panel) until observed.

> **Status (R45): done (W6).** The pull-down reads App, Command Line
> Tool, Package…, Playground, —, Choose Template…. App writes, with no
> sheet, "Untitled Project" (then "Untitled Project 2", …) under
> `~/Library/Developer/Ycode/Untitled Projects/`, holding `MyApp.xcodeproj`
> (Ycode's reading for the project's name: the target's) and the
> synchronized folder "MyApp" with `MyApp.swift`, `ContentView.swift`
> (with a `#Preview`) and `Assets.xcassets`; the one app target "MyApp"
> has SDKROOT auto, SUPPORTED_PLATFORMS iphoneos iphonesimulator macosx
> xros xrsimulator, TARGETED_DEVICE_FAMILY 1,2,7, the iOS, macOS and
> visionOS deployment targets 27.0, and the bundle identifier
> `com.example.MyApp` with no team. The workspace opens on `MyApp.swift`
> with the inspector hidden and My Mac chosen (and remembered for the
> scheme, so the destination default does not replace it); the Welcome
> window closes. Test: `NavigatorInspectorR45Tests`
> (`newProjectAppCreatesAnUntitledMultiplatformProject`);
> `LaunchWelcomeR31Tests.welcomeWindowLayout` now expects the separator.

## 2. Toolbar

### 2.1 Items, order and grouping (T6, T8, T10)

Left to right. Widths are the reference's in points; "capsule" means
the items share one rounded background.

| # | Item | Kind and size | Accessibility title |
|---|---|---|---|
| 1 | Navigators \| Coding Assistant | capsule, two segments 37 × 35 | "Navigators", "Coding Assistant" |
| 2 | Run \| Stop | capsule, 36 × 35 each | "Run", "Stop" |
| 3 | Go Back \| Go Forward | capsule, 36 × 35 each | "Go Back", "Go Forward" |
| 4 | Activity view | project icon (or spinner), name, subtitle (§3) | — |
| 5 | New Conversation | button 39 wide | "New Conversation" |
| 6 | Scheme capsule | two pop-ups | "Active Scheme", "Active Run Destination" |
| 7 | Issue capsule | §2.3 | "Errors", "Issues" |
| 8 | (projects only) a notices button | 39 wide | Ycode: leave the slot out (§12) |
| 9 | Add Editor \| Editor Options | capsule, pull-downs 44 and 40 wide | "Add Editor", "Editor Options" |
| 10 | Canvas \| Assistant \| Code Review | capsule, segments 41, 40, 41 | "Canvas", "Assistant", "Code Review" |
| 11 | Hide / Show Inspector | button 39 wide, at the far right, above the inspector | state-dependent (§2.5) |

- The accessibility **title** of each item is as above. Ycode today
  exposes the toolbar item label ("Scheme" for both pop-ups) and the
  tooltip text for the two pull-downs; the tooltips stay as they are.
- Ycode's disabled "Account" item is removed.

*Status (R39): T6 closed. The Account item is gone; the scheme pop-ups'
accessibility titles are "Active Scheme" and "Active Run Destination";
the right group's pull-downs are titled "Add Editor" and "Editor
Options" with the long tooltips kept. The New Conversation slot (item 5)
stays for the coding assistant (R44).*

### 2.2 Room and collapse order (T1)

1. The right group (items 9–11) ends at the window's right edge in every
   window kind (project, workspace, package, single file). There is no
   flexible space after item 11.
2. When the toolbar is short of room, space is recovered in this order,
   and never by an overflow ("»") menu:
   1. the editor-mode capsule (item 10) becomes one pull-down showing
      the current mode's glyph and a chevron; its menu holds the three
      modes;
   2. the scheme pop-up truncates the scheme name (the destination keeps
      its full name);
   3. the activity subtitle truncates in the middle (§3.1).
3. Item 11 is never hidden.

**Acceptance.** In a 1400-point window, a build with one error and two
warnings shows the issue capsule with both counts, and items 9–11 stay
visible; the editor modes are a pull-down if needed.

*Status (R39): T1 closed. Whenever the window, the left area, the
inspector, the scheme or destination title, the issue capsule or the
activity subtitle changes width, Ycode lays the toolbar out and, while
any item would overflow, applies the steps of item 2 in order (the
scheme name shortens in steps down to 56 points, then the activity view
down to 72 points); a wider window undoes them. Ycode's reading for a
window too narrow even after every step: the items overflow by
visibility priority, Show Inspector last, then the right group, the
scheme capsule and the issue capsule; Back/Forward, the activity view
and New Conversation go first. The collapsed pull-down's own layout is
still to observe (§13).*

### 2.3 Issue capsule (T9)

- Hidden with no issues. With issues it holds an errors button
  ("⊗ N") and an issues button ("⚠ N"); a zero count is left out. Each
  opens the Issue navigator (errors filtered for the errors button is
  not required).
- It appears during a build as soon as the first issue arrives.
- Its counts follow §5.2 (one count per merged issue).

*Status (R39): T9 closed. The capsule's parts are buttons with the
accessibility titles "Errors" and "Issues" (and "Test Failures" for
`reference-ui-2.md` §2.2's failed-test count); clicking one shows the
Issue navigator.*

### 2.4 Scheme and destination pop-ups (T2, T3)

1. The destination pop-up shows the destination's glyph and **name
   only** ("My Mac", "iPhone 18 Pro"). The OS version appears only in
   the menu rows ("<name> <version>", pass 5 §2.9). Ycode today draws
   the menu row's tabbed version inside the pop-up and stretches it to
   327 points; the pop-up must size to its title.

   *Status (R39): T2 closed. The rows carry the right-aligned version
   only while the menu is open; the pop-up is as wide as a pop-up
   holding just the selected row.*
2. **Default destination** (refines pass 5 §4.3.5): when the active
   scheme's product supports macOS (its supported platforms include
   `macosx`, or SDK "auto" with macOS in the supported set), the default
   is My Mac. Only products that do not support macOS default to a
   simulator.

   *Status (R42): T3 closed. The first target supports macOS when its
   `SUPPORTED_PLATFORMS` (else its `SDKROOT`) names `macosx`; such a
   product defaults to My Mac also after the simulators are listed.
   Test: `RunTestTextsR42Tests.projectsPickTheirDefaultInTheWindow`.*
3. **Default simulator** (T11, pass 6b; replaces pass 5 §4.3.5 step 2).
   For a product that does not support macOS, with no remembered
   destination:
   1. Candidates are the simulators of the product's platform whose
      runtime is not below the deployment target and whose device
      family the product supports (iPhone before iPad for an
      iPhone-and-iPad app).
   2. Prefer the **newest-generation Pro iPhone** device type that has a
      candidate (for example "iPhone 18 Pro", not "Pro Max", "Air" or
      "e"), on the newest runtime that has a simulator of that type.
   3. If no candidate has such a type, take the first candidate in the
      Simulators order (pass 5 §11.4).
   4. If there is no candidate, the generic "Any <Platform> Simulator
      Device".

   Observed: an iOS-only app with runtimes 26.5, 27.0 and 27.1 installed
   got "iPhone 18 Pro" on 27.0, although the 27.1 runtime held
   simulators (all of a newer device type, one of them default-named)
   that come first in the Simulators order. Step 2 is Ycode's reading of
   that one observation. The menu row reads "iPhone 18 Pro 27.0"; the
   pop-up shows "iPhone 18 Pro" (§2.4.1).

**Acceptance (T11).** With simulators "Phone X" (a newer device type)
on runtime 27.1 and the standard set including "iPhone 18 Pro" on 27.0,
opening an iOS-only project with no user data selects "iPhone 18 Pro".
With no Pro iPhone installed it selects the first row of the Simulators
section.

*Status (R42): T11 closed. Ycode's reading:*

- *A simulator's device type is its `deviceTypeIdentifier` from `simctl`
  when listed (a renamed simulator keeps its type), else its name. A Pro
  iPhone type is exactly "iPhone <n> Pro"; the generation is n.*
- *Device families come from `TARGETED_DEVICE_FAMILY` ("1" iPhone, "2"
  iPad; unset: all). A simulator whose family cannot be told (a name
  such as "Phone X" with no listed type) stays a candidate. "iPhone
  before iPad" is read as the Simulators order itself (iPhone rows before
  iPad rows within a runtime); steps 3 and the acceptance take the first
  candidate in that order.*
- *Ycode's simulator rows (one per runtime root and device type, named
  "<device type> (Ycode)") are rows of the Simulators section
  (`reference-ui-5.md` §11.5) and rank there with the local simulators:
  by runtime version (a row whose version is not read yet sorts with the
  newest runtime), then family, then name. Their type is their name
  without "(Ycode)". So a local simulator of the same type and runtime
  wins (its name sorts first), and Ycode's "iPhone 18 Pro (Ycode)" on 27.0
  wins over a local Pro iPhone on an older runtime.*
- *Simulators with the same name on several runtimes keep that name in
  the destination list (the menu rows carry the version), so the pop-up
  reads "iPhone 18 Pro" and the row "iPhone 18 Pro 27.0"; earlier Ycode
  appended "(27.0)" to such names.*

*Tests: `RunTestTextsR42Tests` (`newestProIPhoneOnTheNewestRuntimeThatHasOne`,
`proGenerationsComeFromTheDeviceType`, `deviceFamiliesTheProductSupports`,
`ycodeSimulatorRowsRankWithLocalSimulators`,
`projectsPickTheirDefaultInTheWindow`).*

### 2.5 State-dependent button titles (T7)

| Button | Title while hidden | Title while shown |
|---|---|---|
| Debug bar's debug-area toggle | "show debug area" | "hide debug area" |
| Toolbar inspector toggle | "Show Inspector" | "Hide Inspector" |
| Navigator / assistant segments | selected state, not the title, changes | — |

The tooltip follows the same wording. Ycode today has a fixed "Hide
Debug Area" and an inverted inspector title.

*Status (R39): T7 closed for both toggles (title, tooltip and the
accessibility title follow every way the areas change).*

## 3. Activity view (T4, T5)

### 3.1 Layout and progress

1. Two lines: the workspace name, and a subtitle.
2. While an action runs, a small circular progress indicator replaces the
   workspace icon. No bar is drawn under the subtitle, and the subtitle
   is not underlined.
3. Long subtitles are truncated in the middle ("Finished r…ning MyApp").
4. Idle with no finished action: no subtitle (pass 5 §4.3.1).

### 3.2 Build texts

| Moment | Subtitle |
|---|---|
| The action is accepted | "Build" (the action name; "Test", "Analyze", "Archive" analogously, to confirm) |
| Planning | "Building • Planning deferred tasks" |
| Executing | "Building • <done>/<total>": finished build tasks over the tasks planned so far; the total may grow |
| Finished, success, no run follows | "Build Succeeded • Today at <time>" (pass 2) |
| Finished, failure | "Build Failed • Today at <time>" |

"•" is U+2022 with one space on each side. `<time>` is the short local
time ("1:17 PM"); "Today" becomes the date for older results (pass 2).

*Status (R39): T4 closed for the build texts and §3.1 (spinner in place
of the icon, no bar, middle truncation). The build engines report
`planning` and task counts (`BuildEvent.progress(done:total:)`, Ycode's
own plumbing): swift-build's message stream counts started and
up-to-date tasks as planned and completed and up-to-date tasks as done,
and takes a larger planned total from swift-build's own "Building n of m
tasks" progress text; an xcodebuild log counts its step headers (every
step before the latest is done); a SwiftPM log's "[n/m]" counters give
n − 1 of m. The step texts ("Compiling …") are shown only for actions
that report neither (single-file actions). "Test", "Analyze", "Archive"
and the run and test texts are R42's.*

### 3.3 Run texts

| Destination | Sequence |
|---|---|
| My Mac | build texts → "Running <product>" → after the process ends or Stop: "Finished running <product>" |
| Simulator | build texts → "Launching <product>" (also while the simulator boots; there is no separate boot text) → "Configuring Debugger Actions" (the debug bar's process area reads "Waiting to attach") → "Running <product> on <device name>" → "Finished running <product> on <device name>" |
| Ycode's remote simulator | the simulator sequence with the remote device's name. The "(1 of 3)" counters and "Booting Ycode Simulator…" are removed (pass 5 §11.5: the reference has no counter). |

A run does not open the debug area by itself (the default behaviors
leave it as it is).

*Status (R42): T5 closed for the run texts. A Mac simulator run reads
"Launching <product>" through boot, install and launch; under the
debugger "Configuring Debugger Actions" while lldb attaches (the stop
that attaching makes shows no "Paused" text; the app is resumed), then
"Running <product> on <device name>" (also after later stops and
continues), and "Finished running <product> on <device name>" at the
end. A run without the debugger goes from "Launching" to "Running". A
remote run uses the same texts with the destination row's name ("iPhone
Duo (Ycode)"); it attaches no debugger, so it has no "Configuring
Debugger Actions" step, and open retries show in the console only. The
"Stopping <product> — saving Ycode Simulator…" text after Stop stays
(Ycode's own, `run.md` §Warm boot). Not done: the debug bar's process
area ("Waiting to attach") — Ycode's debug bar has no process area yet.
Tests: `RunTestTextsR42Tests.simulatorRunSequence`,
`remoteSimulatorRunSequence`, `runTextsHaveNoCounters`.*

### 3.4 Test texts

- Build texts, then "Configuring Debugger Actions", then "Testing…"
  states as Ycode has them (not observed), then:
  - a run of **selected tests** (gutter diamond, Test navigator, Test
    Again) that passed ends in "Test Completed • Today at <time>";
  - a whole-scheme run keeps "Test Succeeded" / "Test Failed" (pass 2,
    `testing.md`) until observed.

*Status (R42): T5 closed for the test texts. A test run reads "Test" when
accepted, the build texts while the tests build (task counts from the
runner's output as for a build log: SwiftPM's "[n/m]", xcodebuild's step
headers), "Configuring Debugger Actions" once the build is done
("Build complete!", "** TEST BUILD SUCCEEDED **" or "Testing started"),
"Testing <scheme>" from the first test line, and then: a run of selected
tests (diamond, Test navigator, Perform Action ▸ Test, Test Again of
such a run) "Test Completed" (also when a test failed, as pass 2
observed; the capsule shows the failures); a whole-scheme run "Test
Succeeded" or "Test Failed" (Ycode showed "Test Completed" for a failed
whole-scheme run before). Analyze is accepted as "Analyze". Archive is
left: Ycode archives in one blocking call with no activity texts. Tests:
`RunTestTextsR42Tests.testProgressMovesForwardThroughTheTestTexts`,
`testFinishedTexts`, `testRunSequence`.*

## 4. Editor

### 4.1 Jump bar (E1, E2)

1. File components show the name **without** extension, with the file
   type's glyph ("Model"). This was pass 5 §6.1; Ycode regressed to
   "Model.swift".
2. The issue cluster at the right end is three glyph-only controls:
   "‹" (Show Previous Issue), the severity glyph menu (accessibility
   title "Issues", about 20 wide, no text), "›" (Show Next Issue). The
   glyph is the error glyph when any issue in the set is an error, else
   the warning glyph. Ycode's "Issues" text and up/down chevrons go.

> **Status (R40): done (E1, E2).** Jump-bar file components follow
> Settings ▸ General ▸ File Extensions (Hide All by default) and update
> when it changes; groups keep their names. The issue cluster is "‹", a
> 20-point glyph-only pull-down (accessibility title "Issues"), "›".
> Tests: `EditorChromeR40Tests`.

### 4.2 Line and column; caret on open (E3)

1. The debug bar's "Line: L  Col: C" counts lines and columns from 1;
   C is the column within the line (characters, a tab counting as one),
   not an offset in the file. Ycode shows document offsets today
   ("Col: 359" on line 1).
2. A file opened from a navigator, Open Quickly, `open` or a recent list
   puts the caret at line 1, column 1 unless the open names a line
   (issues, search results, breakpoints).

> **Status (R40): done (E3).** The selection change that setting the text
> posts was read against the previous file's line index, so the offset
> became the column; the index is now current first, and opening a file
> puts the caret at 1:1 (then at the named line, if any). Test:
> `EditorChromeR40Tests.lineAndColumnAreRealAndAFileOpensAtOneOne`.

### 4.3 Gutter (E4, E6)

1. On a test line (`@Test`, `func test…` in an XCTest case) the test
   diamond is drawn **in place of** the line number. It shows the last
   result once the test ran. Clicking it runs that test.
2. Issues have no gutter glyph. The issue presentation is: the token
   range underlined, the line tinted, and an annotation (severity glyph
   and message, truncated at the editor edge) after the code on that
   line. Ycode's lightbulb column left of the numbers is removed; the
   fix-it is offered from the annotation.

> **Status (R40): done (E4 with E6).** The diamond replaces the number
> (clicking it runs the test); the gutter draws no issue dot or
> lightbulb; clicking an issue's annotation opens a menu with the message
> and "Fix". Test: `EditorChromeR40Tests.testDiamondsReplaceNumbersAndIssuesHaveNoGutterGlyph`.

### 4.4 Canvas for previews (E7)

Opening a Swift file that contains a `#Preview` (or a `PreviewProvider`)
shows the canvas at once, at the right, splitting the editor 50/50,
unless the user turned the canvas off for that editor. The canvas has a
status pill at its top centre ("Canvas paused" with a refresh button
while paused) and a device pop-up at its bottom left reading
"Automatic – <device>".

> **Status (R40): done (E7).** Opening a Swift file that declares a
> preview shows the canvas, paused (no build until resumed), unless the
> user turned the canvas off in that window or Assistant or Code Review
> is on; a canvas that came up by itself goes away for a file without
> previews, one the user turned on stays. The paused pill sits at the
> top centre; a device pull-down at the bottom left reads "Automatic –
> <run destination>". Tests: `EditorChromeR40Tests` (canvas tests).
> E10 below (canvas mode on by default, pass 6b) was found after R40 and
> is still open. *(R43: closed; the note below says how E7 and E10 fit.)*

**Canvas mode default (E10, pass 6b).** Canvas mode is **on** in every
new editor. For a file without previews the toolbar's Canvas segment is
still selected and Editor ▸ Canvas still checked, but no canvas area is
drawn; the editor uses the full width. Turning the mode off is
remembered per editor (§4.4 above). Editor ▸ Layout ▸ reads Automatic
(checked), —, Canvas on Right, Canvas on Bottom, and its items are
enabled whenever canvas mode is on (M5).

> **Status (R43): done (E10).** Canvas mode is on in every new workspace
> window. While it is on, the canvas is drawn for a Swift file that
> declares a preview and left out for any other file (Editor ▸ Canvas
> stays checked, the Canvas segment selected, the editor full width);
> saving a file that gains a preview brings the canvas up. This replaces
> R40's "a canvas the user turned on stays for a file without previews":
> E7's automatic show is now simply canvas mode at work. Turning the
> mode off (Editor ▸ Canvas, the segment, Show Editor Only) is
> remembered for that window until it is turned on again; turning on
> Assistant or Code Review also ends it (the modes stay exclusive,
> `reference-ui-5.md` §4.2), and a new window starts in canvas mode.
> "Per editor" is per window in Ycode (the canvas belongs to the
> window's editor area). Tests: `EditorChromeR40Tests`
> (`canvasModeIsOnInEveryNewEditor`, `savingAPreviewBringsUpTheCanvas`,
> the updated E7 tests), `WindowChromeR32Tests.editorModesAreExclusive`.

### 4.5 Minimap (E8, E9)

**E9 (pass 6b).** The minimap is **on** by default: with no minimap key
in the user defaults, and in a workspace with no user data, Editor ▸
Minimap ⌃⇧⌘M was checked and the minimap drawn. Ycode registers its
minimap setting with default on. A user who turns it off keeps it off
(the setting is global, pass 5 §9.3).

> **Status (R43): done (E9).** `Preferences` registers its factory
> values with the defaults system; the minimap's is on. A value the user
> sets is stored and wins, so a user who turned the minimap off keeps it
> off. Tests: `EditorCommandsWindowTests.fontSizeColoringAndMinimap`,
> `MenuR43Tests.minimapIsOnInTheFactoryState`.

## 5. Navigators

### 5.1 Issue navigator grouping (N1)

The tree, top to bottom:

1. The **project row** (project glyph, "<project> <n> issue(s)"), with
   the file-less project issues as its direct children ("Update to
   recommended settings", signing).
2. One **target row** per target that has issues (target glyph,
   "<target> <n> issue(s)"), in target order.
3. Under each target, one **file row** per file (file-type glyph, name
   without extension), by name; under it the issues by line.

A file built by two targets appears under each. Package workspaces use
the package's targets. The count text after a group name is secondary
text: "1 issue", "2 issues".

### 5.2 One row per diagnostic (N2)

1. A live (language-server) issue and a build issue are the **same
   issue** when they have the same file, line, severity and message
   (compared case-insensitively on the first character). The navigator,
   the editor and the issue capsule show it once.
2. Once a build has reported issues for a file, the build's issues are
   shown for it and the live issues for it are dropped until the file is
   edited again.
3. Messages are shown with their first letter capitalized
   ("Cannot convert value…", "Initialization of immutable value…"),
   whatever their source.
4. There is never more than one file row for the same file under the
   same parent.

**Acceptance.** Build AuditApp with one unused-variable warning: the
navigator shows "MyApp 1 issue › Model › Initialization of immutable
value 'unused' was never used…", the capsule shows "⚠ 1" (plus the
project issue when present), and the editor shows one annotation.

*Status (R41): N1 and N2 closed. Ycode's readings:*

- *The project row and the target rows are siblings at the top of the
  tree; the project row is shown only when it has issues of its own
  (file-less issues, and the files no target builds, which are listed
  under it). Its glyph is the project's (a package's for packages); a
  target row's is the target glyph.*
- *A file's targets come from the project's target membership (build
  phases and synchronized folders, `reference-ui-5.md` §7.3); a
  package's targets are the folders under `Sources/` and `Tests/`, in
  that order, by name.*
- *The merge key compares file paths after standardizing them (and
  dropping the `/private` prefix of the system's temporary folders).
  The build's copy is kept; it takes the live copy's fix-its when it has
  none. A stale copy (pass 5 §5.3.2) of a merged issue is not listed
  again.*
- *§5.2.2: the build's issues stand for a file until the editor sends
  the language service a changed text for it; the next build starts
  over.*

### 5.3 Row metrics and package tree (N3, N4)

- Navigator rows are 22 points tall; the first row's top is about 7
  points below the navigator selector (the reference's first row at
  y 86 under a selector ending at y 79, window coordinates). Ycode's
  rows are 27.5 points tall and its first row starts about 23 points
  below the selector.
- Package root children (pass 5 §5.1.5) open with Sources **and** Tests
  expanded and their children collapsed.

> **Status (R45): done (N3, N4).** Navigator rows are 22 points tall at
> the medium size with no spacing between them (Ycode's reading for the
> other sizes: 18 small, 26 large); with no header shown the first row's
> top is 7 points below the selector (the outline's scroll view starts
> above a clipping container by the source-list style's own top padding,
> and the hidden header rows take no spacing). A package with no saved
> expansion opens with its root, Sources and Tests expanded; a project
> keeps its first group. Tests: `NavigatorInspectorR45Tests`
> (`rowsAre22PointsAndStartSevenBelowTheSelector`,
> `packageOpensWithSourcesAndTestsExpanded`).

### 5.4 Test navigator rows (N5)

- The root row is the project or package name ("AuditPkg 2 Tests"), not
  the test plan's name; the plan stays in the header pop-up.
- A target or suite row reads "<name> <n> Tests" only.
- Every row has the result glyph at its right end once a result exists;
  a parent's glyph is the aggregate of its children's last results.
- The header pop-up is a bordered pop-up 194 wide.

> **Status (R45): done (N5).** The root row is the workspace's display
> name (project glyph, or the package glyph) with "<n> Tests"; target,
> suite and Group by Tags rows read "<name> <n> Tests" ("1 Test"). A row
> has no result glyph until a result exists; a parent's glyph is failed
> when any child failed, else passed when any passed, else skipped. The
> plan pop-up is bordered and 194 wide (it gives way in a narrower
> navigator). Test:
> `NavigatorInspectorR45Tests.testNavigatorRootCountsAndResultGlyphs`;
> `WindowChromeR32Tests` and `TestingTests` now expect "n Tests" and no
> glyph without a result.

### 5.5 Find navigator header (N6)

- "Find › Text › Containing" is a path control: three menu-bearing
  components separated by "›", with no pop-up arrows.
- The search field's placeholder is the current kind ("Text", "Regular
  Expression", …).

> **Status (R45): done (N6).** The three components are pop-ups without
> arrows between "›" separators; the field's placeholder follows the
> kind however it changes. Test: `NavigatorInspectorR45Tests`
> (`findHeaderIsAPathWithoutArrowsAndThePlaceholderIsTheKind`).

### 5.6 Filter fields and tab titles (N7, N8)

- Every navigator filter field has its filter-options pull-down **inside**
  the field at the leading end (a funnel glyph with a chevron), no
  magnifier, and the in-field toggles at the trailing end (pass 5 §5.2).
- Every navigator selector tab keeps its accessibility title whether or
  not it is selected ("Project", "Issues", …). Ycode drops the selected
  tab's title today.

> **Status (R45): done (N7, N8).** The filter field draws no magnifier;
> the options pull-down (a funnel with a chevron) sits inside it at the
> leading end and the navigator's toggles inside it at the trailing end;
> the text and the clear button keep between them. Each selector tab
> carries its navigator's name as its accessibility title and keeps its
> glyph while selected. Tests: `NavigatorInspectorR45Tests`
> (`filterOptionsAndTogglesSitInsideTheField`,
> `selectorTabsKeepTheirTitles`).

## 6. Inspectors (I1–I3)

1. **File inspector.**
   - Thin rules separate the sections.
   - Location is a disabled pop-up for a file inside a synchronized
     folder; enabled (with the folder button) otherwise.
   - Target Membership is a bordered table: one row per target (target
     glyph, name, "Default" under it), with "+", "−" and the pencil at
     the table's bottom edge, inside the border. "+" is enabled.
   - Files of a Swift package show only Identity and Type and Text
     Settings (no On Demand Resource Tags, no Target Membership).
2. **History inspector rows**: author (emphasized) and subject on the
   left; at the right, the abbreviated commit hash (7 characters) on the
   first line and the relative date on the second.
3. **Quick Help, nothing at the caret**: "No Quick Help" and the "Search
   Documentation" button, both centered horizontally, followed by a
   rule.

> **Status (R45): done (I1–I3).** File inspector: a thin rule above every
> section after the first. Location: for a file inside a synchronized
> folder the pop-up is disabled and the folder button is not shown; for
> other files both are enabled (the folder button opens a file chooser
> and reports the choice to the window; moving the file reference is not
> wired yet). Target Membership is a bordered box holding a row per
> including target (glyph, name, "Default") and, under a rule, "+", "−"
> and the pencil; "+" is always enabled (its menu reads "No Other
> Targets" when every target has the file). Files of a Swift package show
> only Identity and Type and Text Settings. History rows: author (bold)
> over the subject on the left, the 7-character hash over the relative
> date on the right. Quick Help with nothing at the caret keeps its
> heading, then "No Quick Help" and "Search Documentation" centered and a
> rule. Tests: `NavigatorInspectorR45Tests`
> (`fileInspectorRulesLocationAndMembershipTable`,
> `windowReportsSynchronizedFoldersAndPackageFiles`,
> `historyRowsAndQuickHelpPlaceholder`);
> `WindowChromeR32Tests.fileInspectorSectionsInAWorkingCopy` now expects
> a package file's two sections.

## 7. Debug area (D1)

1. The console bar has no output-kind pop-up (Ycode's "All Output" goes;
   output filtering lives in the filter field's options and Metadata
   Options, pass 5 §8.3).
2. The console's command-entry line is shown only while a debug session
   is active. Idle, the console is a plain transcript.
3. When a debug session ends, the console prints "Debug session ended
   with code <n>: <reason>" (observed "code 9: killed" after Stop).

> **Status (R45): done (D1).** The console bar is Quick Look, Metadata
> Options, the filter field, Clear Console and the two half toggles (the
> debugger / target output toggles keep filtering the output). The
> "(lldb)" command line and the rule above it are shown only while a
> debug session is active. Stop ends a session, paused or running, with
> "Debug session ended with code 9: killed" (earlier only when paused).
> Test: `NavigatorInspectorR45Tests`
> (`consoleHasNoKindPopUpAndAnInputLineOnlyWhileDebugging`);
> `WindowChromeR32Tests.debugAreaBarsAndPrintDescription` no longer
> lists "Filter options".

## 8. Menus (M1–M6)

1. **One Open Recent.** File ▸ has exactly one "Open Recent" submenu
   (Ycode's, pass 5 §3.2). The second one that the system document
   machinery inserts is removed or prevented.
   > **Status (R43): done (M1).** The second menu is AppKit's: when the
   > app bundle declares document types and the document controller
   > allows recent documents, AppKit adds its own "Open Recent" after
   > Open… (reproduced with a minimal AppKit app). Ycode's document
   > controller now reports a `maximumRecentDocumentCount` of 0, AppKit's
   > documented way to say "do not add one"; Ycode's Open Recent keeps
   > its own list (`RecentProjects`). The File menu's delegate also
   > removes a system-made Open Recent should one appear. Tests:
   > `MenuR43Tests.fileMenuHasOneOpenRecent`.
2. **No system feedback item.** The Help menu has no "Send Ycode
   Feedback to Apple" item.

   > **Status (R43): done (M2).** AppKit inserts the item and a separator
   > at the top of the Help menu the first time the menu is read or
   > shown, before the menu's delegate updates it; it does so whether or
   > not the menu is registered as the help menu (reproduced with a
   > minimal AppKit app). No public setting turns it off, so the Help
   > menu's delegate removes it (and its separator) on every update and
   > before display; once removed it is not added again. Tests:
   > `MenuR43Tests.helpMenuHasNoSystemFeedbackItem`.
3. File ▸ New ▸ "File from Clipboard" (retitled from "New File from
   Clipboard"); enabled when the pasteboard holds text. *Pass 6b: the
   title is dynamic, see item 6.*

   > **Status (R43): done (M3, with item 6).** File ▸ New ▸ reads "File
   > from Clipboard" (disabled) or "New File from Clipboard" (enabled,
   > the pasteboard holds text). The command creates "File" ("File 2",
   > …) next to the open file, as Empty File does, holding the
   > pasteboard's text, and opens it (Ycode's design: the reference's
   > naming was not observed). Tests:
   > `MenuR43Tests.fileFromClipboardFollowsThePasteboard`.
4. **Edit ▸ Copy ▸ and Paste ▸ are submenus (M4, pass 6b).** Replaces
   pass 5 §2.3 item 3's "implement them as alternates":
   - "Copy ▸" (no shortcut on the parent): Copy ⌘C, Copy File and Line
     ⌃⌥⌘C, Copy Symbol Name ⌃⇧⌘C, Copy Qualified Symbol Name ⌃⌥⇧⌘C.
   - "Paste ▸" (no shortcut on the parent): Paste ⌘V, Move Item Here
     ⌥⌘V, Paste and Preserve Formatting ⌥⇧⌘V. Move Item Here may be
     hidden when it does not apply (one read listed it disabled, a later
     read of the same state did not list it); Ycode hides it when there
     is nothing to move.
   - The order around them is unchanged: Cut ⌘X, Copy ▸, Paste ▸,
     Duplicate ⌘D, Delete ⌘⌫.
   - Each command is enabled on its own: with the caret in a source file
     and no selection, Copy is disabled and the three Copy variants are
     enabled.

   > **Status (R43): done (M4).** Edit ▸ Copy ▸ and Paste ▸ are submenus
   > with plain items (no alternates) and no shortcut on the parents.
   > Move Item Here is hidden while nothing was cut for moving (Ycode
   > has no such cut yet, so it stays hidden). Paste and Preserve
   > Formatting now works: it inserts the pasteboard's text unchanged
   > (Ycode's Paste does not re-indent either). AppKit still adds its
   > AutoFill, Start Dictation… and Emoji & Symbols items to the Edit
   > menu with Copy and Paste in submenus (checked with a minimal
   > AppKit app). Tests: `MenuBarGoldenTests`,
   > `MenuR43Tests.copyAndPasteAreSubmenus`,
   > `MenuR43Tests.copyVariantsAndPasteAreEnabledOnTheirOwn`.
5. **Editor ▸ Layout ▸ (M5, pass 6b).** Automatic (checked), —, Canvas
   on Right, Canvas on Bottom. The items name where the **canvas** goes
   and are enabled while canvas mode is on (§4.4, E10), whether or not
   the focused file has previews.

   > **Status (R43): done (M5).** The source editor's Layout ▸ reads
   > Automatic, —, Canvas on Right, Canvas on Bottom (the other editors
   > keep Preview on Right / Preview on Bottom); the items are enabled
   > while canvas mode is on. Tests: `EditorMenuGoldenTests`,
   > `EditorCommandsWindowTests.counterpartsAndLayout`.
6. **Dynamic titles (M6, pass 6b).**

   | Item | Title when enabled | Title when disabled |
   |---|---|---|
   | File ▸ New ▸ from the pasteboard | "New File from Clipboard" (the pasteboard holds text) | "File from Clipboard" |
   | Find ▸ Find in Selected … | "Find in Selected File…" (a file selected in the project navigator) | "Find in Selected Groups…" |

   - Edit ▸ Convert ▸ "Preflight Conversion to Folder" (lower-case "to").
   - With a file inside a synchronized folder selected in the project
     navigator, File ▸ New ▸ lists only Folder ⌥⌘N and Folder from
     Selection in its last group (both enabled); the four Group items are
     hidden. With no navigator selection all six are listed, disabled.
   - Help ▸ Keyboard Hints is **on** in the factory state, so the item
     reads "Hide Keyboard Hints ⌥⌘?". Ycode keeps the item disabled
     until the hints are specified (pass 5 §2.13), titled "Show Keyboard
     Hints".

   > **Status (R43): done (M6).** Both dynamic titles follow state: "New
   > File from Clipboard" / "File from Clipboard" (item 3), and "Find in
   > Selected File…" with a file selected in the project navigator, else
   > "Find in Selected Groups…". The command now works: it shows the
   > Find navigator scoped to the selected file, group or folder
   > (enabled with any project-navigator row that has a location;
   > disabled with none). Edit ▸ Convert ▸ reads "Preflight Conversion
   > to Folder". The four Group items are hidden while the project
   > navigator's selection is a folder or inside one (a synchronized
   > folder, or a package directory, which has no groups either) and
   > listed otherwise; Folder ⌥⌘N is enabled only with a navigator
   > selection. Keyboard Hints: the item reads "Hide Keyboard Hints"
   > (the factory state, on) and stays disabled until the hints are
   > specified; the "Show Keyboard Hints" of the sentence above is the
   > title it will have once they can be turned off. Tests:
   > `MenuBarGoldenTests`,
   > `MenuR43Tests.newMenuAndFindFollowTheNavigatorSelection`,
   > `MenuR43Tests.groupItemsStayForAFileInAGroup`.
   > **Left:** Folder from Selection is still listed disabled (moving
   > the selection into a new folder is not implemented), so with a file
   > in a synchronized folder only Folder is enabled, not both.

## 9. Coding assistant pane (A1–A7)

This section is the reference layout for the assistant being built.
Ycode uses its own provider model and names no third-party product.

### 9.1 Left-area switch (A5)

1. The toolbar control "Navigators | Coding Assistant" (§2.1 item 1)
   and View ▸ Navigators ▸ Show Coding Assistant (⌘0) put the assistant
   pane in the left area, in place of the navigator. ⌘1–⌘9 and the
   Navigators segment put the navigator back.
2. Clicking the selected segment hides the left area (pass 5 §4.1).
3. The pane is shared by the window's tabs; the conversation list is
   per user, not per workspace (the reference showed the same list in
   two workspaces).

> **Status (R44): done (A5) except item 3.** The toolbar control, ⌘0
> and ⌘1–⌘9 switch the left area as described; clicking the selected
> segment collapses it. **Left (item 3):** conversations are still saved
> per workspace (`coding-assistant.md` §4). A list shared by every
> workspace needs one store for all windows and proposals that remember
> their workspace folder (they are applied relative to it); not done in
> this round. Tests: `CodingAssistantPaneR44Tests.commandZeroTogglesAndRetitles`,
> `WindowChromeR32Tests.leftSegmentsFollowTheLeftArea`.

### 9.2 Pane layout (A1)

| Part | Requirement |
|---|---|
| Header | Where the navigator selector sits: "New Conversation" with a chevron (146 × 27) and "New Group" (115 × 27), side by side, 8 apart |
| List | An outline of conversations and groups. Groups are rows with a glyph and a disclosure triangle. A group "Archive" (archive glyph) is always last and holds archived conversations; it is shown even when empty |
| Bottom | No bottom bar and no filter |
| Empty state | With no conversation, the list holds only "Archive" |

> **Status (R44): done (A1).** The header holds "New Conversation" (a
> split button: the button part and a chevron, 146 × 27) and "New
> Group" (115 × 27), 8 apart, where the navigator selector sits; both
> narrow when the area is narrower than the pair. The list is an outline:
> groups (folder glyph, disclosure triangle, oldest first) with their
> conversations, then the conversations outside any group (newest
> first), then "Archive" (archive glyph), always last and shown when
> empty. Conversations move by dragging them onto a group, onto Archive
> or onto the list, or with the context menu (Rename Conversation…, Move
> to Group ▸ <groups> / No Group, Archive or Move Out of Archive, Delete
> Conversation; on a group: Rename Group…, Delete Group, which keeps its
> conversations). Groups and the archive flag are saved with the
> conversations (older files are read). No bottom bar and no filter. Ycode
> keeps the selected conversation's transcript and message field under
> the list (`coding-assistant.md` §9). Tests:
> `CodingAssistantPaneR44Tests.paneHeaderAndListLayout`,
> `.listContextMenuOffersGroupsAndArchive`, `.groupsAndArchiveAreSaved`;
> `ConversationTests.libraryOutlineAndGroups`,
> `.libraryFileReadsTheOlderListFormat`.

### 9.3 New Conversation menu (A2)

- The chevron part of "New Conversation" opens a menu:
  - a section label "Agents" (disabled title, pass 5 §1.4);
  - one row per available agent or provider. A provider that is
    available but not set up shows a trailing "GET" button (the
    reference's install action); Ycode shows its own action word for
    setup, "Set Up", and opens Settings at the provider.
- Clicking the button part starts a conversation with the default
  provider; with none set up it opens the menu instead.

> **Status (R44): done (A2).** The chevron's menu has a disabled
> section heading, "Model Providers", then one row per Ycode back end
> under its own name (Ollama, llama.cpp, OpenAI, Claude Code, Codex,
> Antigravity) with a glyph for its kind. A ready back end's row starts a
> conversation with it (it becomes the chosen back end). A back end that
> is not set up shows its hint as the row's subtitle (the command to run
> or what to install, `coding-assistant.md` §2) and "Set Up" at the
> right; choosing it opens Settings ▸ Coding Assistant. While the back
> ends are being checked the rows are disabled with "Checking…". There
> are no install rows for other products. The button part starts a
> conversation with the chosen back end; once the back ends are checked
> and none is usable, it opens the menu instead. Tests:
> `CodingAssistantPaneR44Tests.newConversationMenuListsBackEnds`,
> `.newConversationButtonOpensTheMenuWithoutABackEnd`.

### 9.4 Prompt popover (A3)

- The toolbar's New Conversation button opens a popover anchored under
  it, about 342 × 146:
  - a multi-line prompt; its placeholder rotates through hints, the
    first being "New conversation with <provider>";
  - a bottom row: an attach button and an options button at the left,
    a round send button at the right, disabled while the prompt is
    empty.
- Clicking the toolbar button again, or Escape, closes the popover.
  Sending starts a conversation in the pane.

> **Status (R44): done (A3).** The toolbar's New Conversation button
> toggles a transient popover, 342 × 146, anchored under it. The prompt
> is multi-line (Return sends, ⇧Return adds a line); its placeholder
> rotates every 4 s through "New conversation with <back end>", "Ask
> about the current file", "Describe a change to propose" and "Select
> code, then ask what it does". The bottom row has the paperclip (attach
> the current file or the selection; the attached names show beside it)
> and an options pull-down (the back ends and models, Check Again,
> Coding Assistant Settings…) at the left and a round send button at the
> right, disabled while the prompt is empty or blank. Escape or the
> toolbar button closes it; sending closes it, shows the pane and sends
> the prompt in a new conversation. Tests:
> `CodingAssistantPaneR44Tests.toolbarPromptPopover`,
> `WindowChromeR32Tests.toolbarCenterItems`.

### 9.5 Menus (A4, A6)

- File ▸ New ▸ Conversation ⌃⌘H, Conversation in New Tab ⌃⌥⌘H,
  Conversation in Editor Pane ⌃⌥⇧⌘H (pass 5 §2.2) open the prompt in
  the pane, a new editor tab, or the next editor pane.
- Navigate ▸ Jump to Next Active Conversation ⌃⌘K moves to the next
  conversation that is producing output.
- Editor ▸ Show Coding Tools ▸ (A4, **corrected in pass 6b**): the
  pass-5 set — Show Coding Tools… ⌥⌘0, —, Explain, Document, Generate a
  Playground, Generate a Preview. A validated read listed all six,
  enabled, with a source editor focused. The one-item form recorded
  earlier came from a non-validated listing; whether the set shrinks
  when no provider was ever used is open (the observed Mac had used one
  before). Ycode lists all six and enables an item only when a provider
  is set up and, for the generate items, a source editor is focused.

  > **Status (R44): done (A4, A6, File ▸ New ▸ Conversation variants).**
  > Show Coding Tools ▸ lists all six. Explain, Document, Generate a
  > Playground and Generate a Preview are disabled once the back ends
  > have been checked and none is usable (before the first check they
  > count as set up, so the menu does not start the checks itself), and
  > otherwise keep `coding-assistant.md` §4's file rules. Show Coding
  > Tools… shows Ycode's code actions at the caret, which need no back
  > end, so it keeps its own enablement. Conversation ⌃⌘H opens the
  > prompt in the pane; Conversation in New Tab ⌃⌥⌘H opens a new
  > conversation (transcript and message field) in a new editor tab, and
  > Conversation in Editor Pane ⌃⌥⇧⌘H in the next editor pane (made when
  > the tab has one). The jump bar reads "Conversations › <title>" and
  > the tab and jump bar follow the title after the first prompt. Jump to
  > Next Active Conversation ⌃⌘K was already done. Tests:
  > `CodingAssistantPaneR44Tests.codingToolsNeedAProvider`,
  > `.conversationInNewTabAndEditorPane`,
  > `CodingAssistantUITests.stopAndJumpToActiveConversation`.
- **Show / Hide Coding Assistant (A7, pass 6b).** View ▸ Navigators ▸
  reads "Show Coding Assistant ⌘0" while the navigator (or nothing) is
  shown and **"Hide Coding Assistant ⌘0"** while the assistant pane is
  shown. ⌘0 is therefore a toggle; pressed while the assistant is shown
  it hides the assistant. What the left area shows next was not
  observed; Ycode collapses the left area, as clicking the selected
  toolbar segment does (§9.1.2). While the assistant is shown, Filter
  in Navigator ⌥⌘J is disabled; "Hide Navigator" keeps its title and has
  no shortcut.
  Replaces the earlier note that the title does not change.

  > **Status (R44): done (A7).** View ▸ Navigators ▸ reads "Hide Coding
  > Assistant ⌘0" while the pane is shown (also on a plain item with the
  > action) and "Show Coding Assistant ⌘0" otherwise; ⌘0 with the pane
  > shown collapses the left area (neither segment selected). Filter in
  > Navigator is disabled while the pane is shown; "Hide Navigator" keeps
  > its title and has no shortcut. Test:
  > `CodingAssistantPaneR44Tests.commandZeroTogglesAndRetitles`.

## 10. Smaller items

- **T10** No placeholder item for the reference's cloud-notices slot.

  > **Status (R45): done (T10).** Ycode's toolbar has no item for the
  > notices slot (§2.1 item 8). Test:
  > `NavigatorInspectorR45Tests.toolbarHasNoNoticesPlaceholder`.
- **W6** See §1.5.
- **E5** Live issues before the first build stay as they are (Ycode's
  Show Live Issues setting); they merge per §5.2.

## 11. Corrections to earlier specs

| Spec | Section | Correction |
|---|---|---|
| `reference-ui-5.md` | §3.5 | Superseded by §1.3: no Start Page at first open |
| `reference-ui-5.md` | §2.2 | "File from Clipboard" |
| `reference-ui-5.md` | §2.7 item 8 | Show Coding Tools contents depend on a provider (§9.5) |
| `reference-ui-5.md` | §4.3.5 | macOS-capable products default to My Mac (§2.4) |
| `reference-ui-5.md` | §11.5 | Simulator run texts (§3.3); counters removed |
| `reference-ui-2.md` | §2.3 | Selected-test runs end in "Test Completed" (§3.4); build progress "Building • n/m" (§3.2) |
| `run.md` | remote run activity | "(1 of 3)" counters removed (§3.3) |
| `reference-ui-5.md` | §2.3 item 3 | Copy ▸ and Paste ▸ are submenus, not alternates (§8 item 4, pass 6b) |
| `reference-ui-5.md` | §2.4 item 7 | "Show / Hide Coding Assistant ⌘0" (§9.5, A7) |
| `reference-ui-5.md` | §2.7 item 4 | Layout ▸ Canvas on Right / Canvas on Bottom, enabled in canvas mode (§8 item 5) |
| `reference-ui-5.md` | §2.13 item 6 | Keyboard hints are on in the factory state (§8 item 6) |
| `reference-ui-5.md` | §4.3.5 step 2 | Default simulator rule replaced by §2.4.3 (T11) |
| `reference-ui-5.md` | §6.5, §9.3 | Minimap default on (§4.5, E9) |
| `reference-ui.md` | §3 minimap | Factory default confirmed on (§4.5) |
| this spec | §8 item 3, §9.5 (A4) | Corrected in pass 6b (dynamic clipboard title; full Show Coding Tools set) |
| `reference-ui-5.md` | §5.3.1 | File-less issues under the project row; files grouped by target (§5.1) |
| `reference-ui-4.md` | §14.1 | No account button; "Add Editor" / "Editor Options" titles (§2.1) |

## 12. Deliberate deviations (not gaps)

- The reference's cloud-notices button and its agent product names are
  not reproduced (§2.1, §9.3). Ycode's provider setup word is "Set Up",
  not "GET".
- The untitled-project folder is Ycode's own location (§1.5).
- Ycode keeps Settings ▸ Simulators and its remote simulator destination
  (pass 5 §13).

## 13. Still to observe live

For the observer, with the reference frontmost and a tool tier that
allows typing, key presses, right-clicks and menu presses (pass 6b had
plain clicks only, and its takeover was interrupted):

- everything left in `reference-ui-5.md` §12 except: simulator run texts
  (§3.3), the Welcome New Project pull-down (§1.5), the selected-test
  result text (§3.4), the assistant pane (§9), ⌘0 with the assistant
  shown (§9.5), and the Edit menu's Copy / Paste structure (§8 item 4);
- Settings panes (all but Apple Accounts and Intelligence) and every
  pop-up's values;
- context menus: navigator rows, editor, gutter, tabs, jump bar;
- Add Editor and Editor Options pull-downs; the toolbar scheme and
  destination pop-ups as drawn (the Product ▸ Scheme and ▸ Destination
  submenus were read and match pass 5); the collapsed editor-mode
  pull-down (§2.2);
- Open Quickly and Show Quick Actions… layout and ranking; the Library;
  the find bar; the completion popup;
- which Debug / Find / Navigate items are hidden modifier alternates
  (the accessibility tree lists alternates as plain siblings); Help ▸
  Keyboard Hints behavior; Copy File and Line's text;
- a whole-scheme test (⌘U) result text; the "Test" action's first text;
- the project editor and its Editor menu;
- what the left area shows after ⌘0 hides the assistant;
- the Window menu entry of a workspace with an empty editor: pass 6b
  read "AuditPhone — New Editor" there while the accessibility title
  was "AuditPhone — AuditPhone.xcodeproj" (§1.1 stands until
  confirmed).

## Evidence

| Claim | Level | Source |
|---|---|---|
| §1.1 title form | 3 | Window accessibility titles and the Window menu listing ("AuditPkg — AuditPkgTests.swift") |
| §1.1.3 cause in Ycode | — | Ycode's own source and running build (the title shows the container name) |
| §1.2 launch and file opening | 3 / — | `open -a` of a project (reference showed one window) and of a Swift file (reference opened it in the workspace); the no-workspace single-file window is Ycode's design |
| §1.3 first open | 3 | Window capture and accessibility tree of a fresh copy (no user data) |
| §1.4 Welcome geometry | 3 | Accessibility frames of the Welcome window |
| §1.5 New Project ▸ App | 3 / 2 | Pull-down clicked once; the untitled project's `project.pbxproj` read as a file format (setting names and values) |
| §2.1 items, sizes, titles | 3 | Toolbar accessibility tree in project and package windows |
| §2.2 collapse order | 3 | Toolbar captures during builds and after a failing build |
| §2.3 issue capsule | 3 | Captures during and after builds |
| §2.4 destination title and macOS default | 3 | Toolbar captures for a multiplatform and an iOS-only copy |
| §2.5 toggle titles | 3 | Accessibility titles in both states |
| §3 activity texts | 3 | Window zooms polled during builds, runs (Mac and simulator) and a gutter test run |
| §4.1–§4.4 editor | 3 | Captures and accessibility tree with Swift, test and SwiftUI files open |
| §4.2 column semantics | — | Ycode's design from the label; the reference showed 1:1 after opening |
| §5.1–§5.2 issue tree and merging | 3 / — | Issue navigator after a build with one error and one warning; the merge key is Ycode's reading |
| §5.3–§5.6 navigator details | 3 | Accessibility frames and captures of the Project, Test, Find and Issue navigators |
| §6 inspectors | 3 | Captures of the File, History and Quick Help inspectors |
| §7 debug area | 3 | Debug area shown while idle and after Stop |
| §8 menus | 3 | Menu listings of both apps |
| §9.1–§9.4 assistant pane | 3 | Pane captures, the New Conversation menu and the toolbar popover, with no account and no provider; nothing installed or sent |
| §9.3 "Set Up", §9.5 enablement | — | Ycode's design |
| §2.4.3 default simulator (T11) | 3 / — | Fresh copy of the iOS-only sample without user data: the destination pop-up's value and the checked row of Product ▸ Destination, with the installed runtimes and device types listed by `simctl`; step 2 is Ycode's reading of one observation |
| §4.4 canvas mode default (E10), §4.5 minimap default (E9) | 3 | Editor ▸ Canvas and ▸ Minimap check marks and the Canvas segment's state, read through accessibility with the minimap key removed from the user defaults (restored afterwards) and in a workspace without user data |
| §8 items 4–6 (M4–M6) | 3 | Validated menu reads through the accessibility API in two states; submenu structure compared with known alternates, which the tree lists flat |
| §9.5 A7, A4 correction | 3 | View ▸ Navigators ▸ read before and after clicking the Coding Assistant segment; Editor ▸ Show Coding Tools ▸ read validated |
| §0 plan, files | — | Audit of Ycode at 5f74ef9 (source and a running build) |
