# Spec: reference IDE behavior, pass 2 — issues, find, reports, tests, schemes, tabs, debug bars

Status: boundary spec from black-box observation (evidence level 3) of the
reference release on a throwaway Swift package with a library target, an
executable target and a Swift Testing target. It continues
`specs/ide/reference-ui.md` and answers OPEN QUESTIONs in
`navigators.md`, `build.md`, `editor-area.md`, `debug.md` and
`schemes.md`. It describes visible behavior, labels and defaults only. It
records no colors and copies no assets. Ycode chooses its own icons
(SF Symbols) wherever an icon is mentioned.

## 1. Issue navigator

1. **Structure.** The root row is the workspace (or package) name,
   followed in secondary text by "`N issues`". Under it is one group per
   **file**. A group's title is the file name **without its extension**,
   with the file-type icon. The leaves are issues: a severity icon, then the
   message.
2. **Grouping** is by file only. The navigator has no by-type switch.
3. **Order:** groups are sorted by file name. Inside a group, issues keep
   the compiler's order.
4. **Row text.** The message wraps to at most **three lines** and the
   third line ends in an ellipsis. The selected row grows to show the
   whole message.
5. **Stale issues.** When a later build no longer produces an issue from an
   earlier build (for example, the file moved or is no longer compiled), the
   old issue remains in its own group with a **grey (stale)** severity
   icon until the next full build, while fresh issues use the normal
   icons. Stale and fresh groups can have the same title.
6. **Selection** opens the file in the editor at the issue's location.
7. **Bottom bar,** from left to right:
   - a filter-options button;
   - the text filter;
   - the toggle "Show only issues from open documents and recently built
     sources";
   - the toggle "Show only errors".
8. **Filter-options menu** sections:
   - "Additional Filtering", with the item "Deprecation";
   - "Add Filter", which offers filter tokens: an issue-kind token (for
     example kind = Build) and a "≠ Deprecation" token;
   - "Clear Recents".

   Tokens join the text filter.

## 2. Toolbar issue counts and the activity view

1. The issue counts sit in their own capsule to the right of the
   scheme/destination capsule: the error icon and count, then the warning
   icon and count. A count of zero is left out, and with no issues the
   capsule is hidden. The counts include stale issues.
2. After a test run with failures, the capsule shows a test-failure icon
   and the number of failed tests.
3. The activity view subtitle after an action is "`<Result> • Today at
   <time>`". Observed results: "Build Failed", "Test Completed", and
   "Finished running `<product>`".
4. The right end of the editor jump bar has previous/next-issue arrows
   with a severity icon between them. They are present while the file has
   issues.

## 3. Find navigator

1. **Header:** a path of three pop-ups, "`<Mode> › <Kind> › <Match>`",
   with an "Aa" (match case) toggle at the right. Below it are the search
   field, with recent-search history, and a scope pop-up labelled
   "In `<scope>`".
2. **Mode:** Find, Replace.
3. **Kind**, in order:
   - Text
   - Multiple Words
   - Regular Expression
   - Symbols
   - Ancestor Types
   - Descendent Types (sic)
   - Conforming Types
   - Call Hierarchy
   - Asset References
4. **Match**, for Text: Containing (default), Matching Word, Starting
   With, Ending With.
5. **Scope pop-up**, in a package workspace:
   1. Package (the default; check mark), Package Dependencies, Package and
      Package Dependencies.
   2. Separator, then "Current Find Results" (disabled without results).
   3. Separator, then the section "Containing Groups", listing the groups
      that contain the selected file, outermost first.
   4. Separator, then "Custom Scopes…".

   In a project workspace the first three items say "Project" instead of
   "Package", and the pop-up reads "In Project" (observed in pass 5,
   `reference-ui-5.md` §5.4).

## 4. Report navigator

1. The top segmented control is **Local | Cloud**, with Local selected.
2. **Groups:** one per scheme (the scheme icon and name), plus a
   "Package" group for package operations ("Resolve Packages",
   "Reload Package…").
3. **Row:** an action icon, the title, then the time in secondary text
   ("Build  Today, 3:46 AM"). Rows are newest first. A failed run has an
   error badge at the row's right end.
4. A **test run** row is titled "`<scheme>/<test plan>`". It expands to:
   Insights, Coverage (with the total percentage at the right), Tests
   (with the failure badge), Log, and Build.
5. **Bottom bar:** a round filter-scope button, then a filter field with a
   "recent only" (clock) toggle.

## 5. Build log

1. **Scope bar:** "All | Recent", then "All Messages | All Issues | Errors
   Only" (All Issues is the default), an "Export…" button, and a filter
   field.
2. **Sections:** one per target. The bold title is "Build target
   `<name>`". The subtitle is "`<Project|Package> <name> | Configuration
   <config> | Destination <destination> | SDK <sdk name and version>`".
   For a package, the executable product's target is shown as
   "`<name>-product`".
3. **Steps nest:**
   1. a group step ("Compiling `<file>`  0.1 seconds");
   2. the task inside it ("Compile `<file>`  0.1 seconds");
   3. the task's issues.

   Each step row carries an issue-count badge and a transcript (details)
   button at its right.
4. **Footer:** a large status icon, "`Build <succeeded|failed>
   <M/D/YY>, <time>  <duration> seconds`", and on the next line
   "`N errors, M warnings`".

## 6. Test navigator and test report

1. **Test navigator header:** the test-plan pop-up ("`<name>
   (Autocreated)`" for a package), a list-mode toggle and a tag button.
2. **Tree:** the plan root, then the test target, then each test function
   with its parentheses (`circleArea()`). The plan and target rows add
   "`N Tests, M Failing`" in secondary text. Status diamonds at the right
   end are green for passed and red for failed.
3. **Report summary page:**
   - Title "`<scheme>/<plan>`", the line "Built with `<platform version>`",
     and at the right "Started `<date>` at `<time>` · Ran for `<n>`
     seconds".
   - A "Tests" card: a ring chart with the total in the centre ("2 Tests"),
     and a legend of Passed and Failure with their counts.
   - A table "Devices & Configurations | Passed | Failure". Its rows are a
     device row ("MacBook Pro macOS 27.2"), then the configuration row
     ("Test Scheme Action") with proportional bars that hold the counts.
   - "Test Failures  `N` total failure(s)": each failing test with its
     first failure message.
4. **Tests page:**
   - Header: the plan name and "`N failed and M passed · Test plan with K
     test target(s)`".
   - Filter pop-ups: "Failed Tests (N)", "Failed Runs (N)", the device,
     the configuration, and the tags ("Untagged Tests"), plus a text
     filter.
   - Columns: Test | Duration. Rows run from target to test, each test
     with its duration in seconds ("0.00076s"), then failure rows:
     "`<File>.swift:<line>: <message>`", followed by the expectation's
     evaluated expansion on its own line.
5. **Coverage page:** a "Show Test Bundles" checkbox and a filter.
   Columns: Name | Coverage (a bar plus "NN.N%") | Executable Lines. Rows
   expand from target to file.

## 7. Scheme editor

1. **Sheet layout:**
   - The left column lists Build, Run, Test, Profile, Analyze and Archive.
     Each item's subtitle is its configuration; for Build it is
     "`N targets`". Each item has a disclosure that reveals Pre-actions,
     the action itself, and Post-actions.
   - The detail header is the scheme icon and name.
   - Bottom bar: "Duplicate Scheme", "Manage Schemes…", a "Shared"
     checkbox, and the default button "Close".
   - The sheet reopens on the last action and tab that were used.
2. **Build:**
   - Build Order radios: "Dependency Order" and "Manual Order
     (Deprecated)".
   - Build Options: "Find Implicit Dependencies" (on).
   - Override Architectures pop-up: "Match Run Destination", with an info
     button.
   - Build Debugging: "Task Backtraces" and "Modules Report" (both off).
   - Targets table columns: Targets | Analyze | Test | Run | Profile |
     Archive, with checkboxes. Footer: +/− and a filter.
3. **Run tabs:** Info, Arguments, Options, Diagnostics.
   - **Info:**
     - Build Configuration.
     - Executable pop-up.
     - "Debug executable" (on).
     - Debug Process As: radio "Me (`<user>`)" (selected) or "root".
     - LLDB Init File: a text field with placeholder
       `$(SRCROOT)/LLDBInitFile` and a choose button.
     - Launch: radio "Automatically" (selected) or "Wait for the
       executable to be launched".
   - **Arguments:**
     - A collapsible "Arguments Passed On Launch" list (empty state "No
       Arguments", +/−).
     - A collapsible "Environment Variables" table with columns Name |
       Value (empty state "No Environment Variables", +/−).
     - "Expand Variables Based On" pop-up.
   - **Options,** in order, with defaults:

     | Row | Control and default |
     |---|---|
     | Core Location | "Allow Location Simulation" on; Default Location: None |
     | App Data | None |
     | Routing App Coverage File | None |
     | GameKit Configuration | "Enable Debug Mode" off |
     | StoreKit Configuration | None |
     | GPU Frame Capture | Automatically |
     | Persistent State | "Launch app without state restoration" off |
     | Document Versions | "Allow debugging when browsing versions" on |
     | Working Directory | "Use custom working directory:" off; path placeholder `$(BUILT_PRODUCTS_DIR)` with a choose button |
     | Background Asset Packs | None, with a choose button |
     | Localization Debugging | "Show non-localized strings" off |
     | App Language | System Language |
     | App Region | System Region |
     | Distribution | App Store |
     | Simulated Apple Foundation Models Availability | Off |
     | XPC Services | "Debug XPC services used by app" on |
     | Queue Debugging | "Enable backtrace recording" off |
     | Console | "Xcode (with Standard Input)" |
   - **Diagnostics,** in order. Default off unless marked "on".
     - Runtime Sanitization (sub-label "Requires recompilation"):
       - Address Sanitizer, with the indented "Detect use of stack after
         return" (enabled only with ASan);
       - Thread Sanitizer (info button);
       - Undefined Behavior Sanitizer.
     - Runtime API Checking: Main Thread Checker (on); Thread Performance
       Checker (on, info button).
     - Memory Management:
       - Hardware Memory Tagging, with the indented "Fall back to Guard
         Malloc";
       - the status line "Not checking allocations.";
       - Malloc Scribble, Malloc Guard Edges, Zombie Objects, Malloc Stack
         Logging, and Memory Graph on Resource Exception.
     - Metal:
       - API Validation (on, help button), with the indented "Include load
         and store actions" and "Log non-fatal actions";
       - Shader Validation (help button), with indented children that are
         enabled only when it is on: a radio "Raise Runtime Issues on
         Error" with a "Set Breakpoint" button, a radio "Abort on Error",
         "Log allocation stack traces" (checked), and "Detect GPU stack
         overflow" (checked);
       - Metal Performance HUD;
       - Log Graphics Overview.
     - Core AI: "Include Model Debug Information" (help button).
4. **Test** (when the scheme uses test plans, the Test detail has no
   tabs):
   - Build Configuration.
   - Debugger: "Debug executable" (on).
   - Debug Process As: radios, disabled.
   - LLDB Init File.
   - A "Test Plans | Default" table. Each row shows the plan name, a
     subtitle "`N test target(s), M configuration(s)`", and a go-to arrow;
     a Default radio marks one plan. Footer: +/−.
5. **Profile tabs:** Info, Arguments, Options. Info holds Build
   Configuration (Release), Executable, and Instrument ("Ask on Launch").
6. **Analyze:** Build Configuration only.
7. **Archive:**
   - Build Configuration (Release).
   - Archive Name (a text field holding the scheme name).
   - Options: "Reveal Archive in Organizer" (on) and "Allow Archiving for
     Simulator" (off).
8. **Product ▸ Scheme submenu:** Choose Scheme ⌃0, Select Next Scheme ⌃⌘],
   Select Previous Scheme ⌃⌘[, Edit Scheme… ⌘<, New Scheme…, Manage
   Schemes…, then the list of schemes with a check mark on the active one.

## 8. Editor tabs

1. **Show and hide.** The editor tab bar is toggled by View ▸ Show Editor
   Tab Bar / Hide Editor Tab Bar. When shown, a single tab fills the width
   as one capsule holding the file icon and the file name without its
   extension.
2. **Reuse.** With Settings ▸ Navigation "Pin Editor Tabs: Manually" and
   "With Double-click: Same as Click" (the observed settings), opening a
   file from the navigator replaces the current **unpinned** tab. No new
   tab is created.
3. **Pinning.**
   - View ▸ Pin Editor Tab (⇧⌘P) pins the current tab, and a pin icon
     appears at the tab's right end.
   - While the current tab is pinned, opening a file adds a new tab to its
     right.
   - Tabs share the bar's width equally, and the selected tab is
     highlighted.
4. **Hover.** Hovering a tab shows a close "×" at its left end. The
   tooltip shows the name and the group path ("Obs › Sources › ObsKit").
5. **Close commands** (File menu, with two tabs open):
   - Close Tab ⌘W
   - Close "`<file name with extension>`" ⌃⌘W
   - Close Editor Pane ⌃⇧⌘W (disabled with one pane)
   - Close Window ⇧⌘W
   - Close `<Project|Package>` ⌃⌥⌘W

   ⌘W therefore closes the **tab**. Closing the last tab is left to
   Ycode's existing rule.
6. **Other File menu items:** Duplicate Editor Tab, Open in New Tab ⌥⌘O,
   Open in New Window, Open Terminal at Location, Open with External
   Editor.
7. **Window menu:** Rename Window Tab… ⌥⇧⌘T, Show Previous Window Tab
   ⌃⇧⇥, Show Next Window Tab ⌃⇥, Move Tab to New Window, Merge All
   Windows. All are disabled without window tabs.

## 9. Debug area bars

1. **Variables bar:**
   - A scope pop-up with Auto (default), Local Variables, and "All
     Variables, Registers, Globals and Statics". Registers appear only in
     the third scope; Auto does not show them by default.
   - A Quick Look button and an info button.
   - A filter.
2. **Console bar,** from left to right:
   - a Quick Look button;
   - an output-options button that opens a popover. The popover holds a
     "Metadata" switch (on) and checkboxes for the metadata columns: Type,
     Timestamp, Library, PID:TID, Subsystem, Category (all off by
     default);
   - a filter field with its own filter-options button;
   - a clear (trash) button;
   - the two toggles that show the variables view and the console.
3. **End of a run.** The console prints "Program ended with exit code:
   `N`" as its own paragraph after the program's output.

## 10. Package workspace navigator

The root is the package name. Its children, in order: "Package" (the
manifest), "Sources", "Tests". With the observed settings, file names are
shown without extensions.

## 11. Differences from Ycode's specs (to implement)

1. Issue navigator:
   - group by file under a root with "N issues";
   - stale issues with grey icons;
   - messages wrap to three lines, and the selected row expands;
   - the two bottom toggles, with the tooltips given above;
   - the token filter menu.
2. A separate toolbar issue capsule whose counts include stale issues.
3. Find navigator: the three pop-ups and their item lists, "Aa", and the
   scope menu sections.
4. Report navigator:
   - Local | Cloud;
   - scheme and Package groups;
   - row text "`<title>  <relative day>, <time>`";
   - test runs titled "`<scheme>/<plan>`" with five children.
5. Build log: the scope bar, the target section subtitle, the nested step
   rows, and the footer format.
6. The test report summary, Tests and Coverage pages as in §6.
7. The scheme editor panes, their order and defaults as in §7.
8. Editor tab behavior and the close-command set as in §8.
9. The debug area bars, the scope names and the console metadata popover
   as in §9.

## Evidence

| Claim | Level | Source |
|---|---|---|
| §1–§10 | 3 | Black-box observation of the reference app (Xcode 27.1, installed copy) driven through its menus and controls on a throwaway package, 2026-10-17. Screenshots and the accessibility tree only. No binaries were opened. |
| §3.5, last sentence | 3 | Confirmed in pass 5 (`reference-ui-5.md` §5.4). |
| §11 | — | Comparison with Ycode's specs at the time. |
