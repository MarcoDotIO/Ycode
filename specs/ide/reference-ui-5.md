# Spec: reference IDE behavior, pass 5 — fidelity audit: menus and shortcuts, launch, window chrome, navigators, editor commands, inspectors, settings

**Status:** boundary spec. It comes from a fidelity audit of Ycode
(commit aa1bf7c) against the reference release, Xcode 27.1.

**What the audit observed.** It used black-box observation of the
running reference (evidence level 3): the accessibility tree and the
validated menu bar, read in the background. Exact shortcuts come from
the menu bar's key equivalents. The user's key-binding set was empty,
so every shortcut here is a factory default. One file format was studied
(level 2).

**Relation to earlier specs.**

- It continues `reference-ui.md` to `reference-ui-4.md`.
- Where they conflict, this spec wins. The earlier specs carry
  correction notes that point here.
- It records labels, order, shortcuts, defaults and behavior only. It
  records no colors and copies no assets. Ycode picks its own icons
  (SF Symbols).
- Apple product names are left out of Ycode's UI (`AGENTS.md` rule 5).
  Where the reference shows one, the Ycode wording is given.

**Use by implementers.**

- §0 is the plan.
- §1 defines the menu conventions.
- §2 is the normative menu bar.
- §3–§11 are the other areas.
- Gap IDs (L1, M3, …) match the matrix in the audit notes. Implementers
  don't need the notes: every requirement is stated here.

## 0. Prioritized implementation plan

**Priorities.**

- **P0:** a daily Xcode user notices it in the first minute.
- **P1:** noticed in a normal working session.
- **P2:** depth.

**Rounds.** Each round below is sized for one implementation agent and
lists the areas it touches. Rounds R29–R31 are the P0 set and can run in
parallel: they touch different files, except that R29 and R30 both edit
the menu tables, so R30 starts from R29's `CommandTable`.

| Round | Priority | Scope (gap IDs → sections) | Areas and files |
|---|---|---|---|
| **R29 Menu bar** | P0 | M1–M4, M8–M13, M20–M26 → §1, §2.0–§2.6, §2.9–§2.13 (structure, titles, shortcuts; the Product and Debug actions themselves are R36 and R34) | `Model/CommandTable.swift`, `App/AppSupport.swift` (menu builder: alternates, section labels, conditional items, dynamic titles), `Model/KeyBindings`, `validateMenuItem` in `Window/WorkspaceWindowController.swift`; a golden test of the whole menu bar against §2. Commands Ycode can't perform are still listed disabled (`menus.md` rule). |
| **R30 Editor menu and text commands** | P0 / P1 | M5–M7, M14–M17, M12 (editor items), E3 → §2.7, §2.8, §6.3–§6.5 | `Model/EditorMenu.swift` (one menu per editor kind), `Editor/SourceEditorController.swift`, `Editor/GutterView.swift`, `Model/FoldRegions.swift`, `Model/Counterparts.swift`, the git diff used by Code Review, `Editor/PlistEditorController.swift`, `Editor/InterfaceBuilderController.swift`, `Editor/AssetCatalogEditorController.swift`. Uses the open-source `swift-format` tool for the Format commands. |
| **R31 Launch, Welcome, recents, first view** | P0 / P1 | L1–L5, L8, L9, T1, T4, N1–N5 → §3, §4.3, §5.1 | `App/AppSupport.swift`, a new `Window/WelcomeWindowController.swift`, `Window/WorkspaceWindowController.swift`, `Window/ActivityView.swift`, `Model/NavigatorTree.swift`, `Model/Preferences.swift`, `Model/DestinationMenu.swift` and the destination default in `YcodeBuild` |
| **R32 Window chrome** | P1 | T2, T3, T5–T7, E1, E2, E4–E6, I1–I5, N6–N8, N11–N14, D1, D2 → §4, §5.2–§5.3, §6.1–§6.2, §7, §8 | `Window/WorkspaceWindowController.swift` (toolbar), `+ToolbarRight.swift`, `Editor/SourceEditorController.swift` (jump bars), `Inspector/InspectorAreaController.swift`, `Navigator/NavigatorAreaController.swift` and `+Debug`, `Debug/DebugAreaController.swift` |
| **R33 Settings** | P1 | S1–S6 → §9 | `App/SettingsPanes.swift`, `App/SettingsWindow.swift`, `Model/Preferences.swift`, and navigation routing in the window controller |
| **R34 Debugger menus and breakpoint persistence** | P1 | L6, M19, N10, D3 → §2.10, §10 | `Model/WorkspaceModel.swift` (breakpoint store), `Session/WorkspaceSession.swift`, `Debug/*`, the Debug menu entries; the breakpoint file of §10.1 |
| **R35 Project editor and catalog leftovers** | P2 (P1 for P1) | P1–P8, P10–P12, P14, P16, I6 → §11 | `Project/ProjectEditorController.swift`, `ProjectEditorTabs.swift`, `ProjectEditorReference.swift`, `ProjectEditorModel.swift`, `Editor/AssetCatalogEditorController.swift`, `YcodePlist` (binary key order), `Window/NewItemSheets.swift`, `Schemes/SchemeEditorController.swift`, `Window/ReportViews.swift` |
| **R36 Product actions** *(build-system work)* | P1 / P2 | M18, T8, P9, P13 → §2.9, §11.4 | `Session/WorkspaceSession.swift`, `YcodeBuild` (build for running/testing/profiling, run without building, compile one file, test again, clean immediately), the destination submenu, project-level checks for the issue capsule |
| **R37 Simulator-side items** *(simulator work)* | P2 | D4, P15, R1, R2 → §11.5 | `Session/RemoteRun.swift`, `Session/SimulatorRun.swift`, the destination menu, the preview activity text; Debug View Hierarchy and Memory Graph stay placeholders until the simulator supports them |

**P0 items** (13). Each fails in the first minute:

- **L1** Launching with no document shows the Welcome window, not an Open
  panel (§3.1).
- **L2** Window ▸ Welcome to Ycode is ⇧⌘1 (§3.1, §2.12).
- **L3** File ▸ Open Recent works (§3.2).
- **M1** Shortcut conflicts are fixed (§2.0):
  - ⇧⌘A = Show Quick Actions…;
  - ⌘0 = Show Coding Assistant;
  - ⌥⌘0 = Show Coding Tools…;
  - ⌥⇧⌘← / → fold and unfold methods and functions.
- **M2** Re-Indent ⌃I moves to Editor ▸ Structure (§2.7).
- **M3** Every default shortcut in §2 is assigned. About 71 are missing
  today.
- **M4** View ▸ Editor holds the jump-bar commands ⌃1–⌃6 (§2.4).
- **M5** Editor ▸ Font Size: ⌘+, ⌘-, ⌃⌘0 (§2.7, §6.4).
- **M6** Editor ▸ Structure has the full set, including Move Line Up/Down
  ⌥⌘[ / ⌥⌘] and Add Documentation ⌥⌘/ (§2.7, §6.4).
- **M7** Editor ▸ Code Folding has the reference set and shortcuts (§2.7,
  §6.4).
- **T1** An iOS app project defaults to an iOS Simulator destination, not
  My Mac (§4.3).
- **N1** The project navigator hides the product-reference group
  (Products) (§5.1).
- **N2** File extensions are hidden by default (§5.1, §9.1).

**P1 items** (33). They are grouped by round above:

- R29: M8–M13, M20, M24.
- R30: M14, M15, E3.
- R31: L4, T4, N3, N4, N5.
- R32: T2, T3, E1, E2, E4, I1, I2, N6, N8.
- R33: S1–S3.
- R34: L6, M19, N10.
- R35: P1.
- R36: M18.

**P2 items** (48): everything else in §2–§11.

## 1. Menu conventions

1. **Listed but disabled.** Every item in §2 is present. An item whose
   command Ycode does not implement is shown disabled, under the rule in
   `menus.md`. It keeps its reference shortcut, so the shortcut can't be
   taken by something else.
2. **Alternates.** An item marked *alt(⌥)* (or *alt(⌃)*, *alt(⌃⇧)*, …) is an
   alternate of the item just above it. It is hidden until that modifier is
   held, and then it replaces the item above it in place (AppKit's
   alternate items: the same key, more modifiers). Marked "(seen)" means
   the visible menu was observed without it. Ycode must not list alternates
   as separate visible items.
3. **Dynamic titles.** A title shown as "A / B" changes with state. A title
   containing `<file>` names the focused document by its file name with
   extension, in curly quotes ("Close “Model.swift”"). With no document, the
   generic title in brackets is used.
4. **Section labels.** An item marked *label* is a disabled, non-clickable
   title that heads a section of the same menu ("Source Control"). It is
   not a submenu.
5. **Conditional items.** An item marked *when …* is hidden otherwise. When
   it is hidden, the separators around it collapse to one.
6. **System items.** Items marked *system* come from macOS (Services,
   AutoFill, Start Dictation…, Emoji & Symbols, the window-tiling items,
   Touch Bar, the window list). Ycode must not add its own copies. Where
   the system adds an item whose shortcut collides with §2, the system
   item is removed or its shortcut cleared, never the §2 item. Ycode today
   gets "Close All ⌥⇧⌘W" and a fn-F full-screen item this way.
7. **Separators.** "—" is a separator.
8. **Shortcut notation.**
   - ⌃⌥⇧⌘ order; keys are written as on a US keyboard.
   - "⇧⌘[" and "⌘{" are the same keystroke. Ycode should store the shifted
     character the way AppKit expects for that key.
   - F-keys carry no implicit modifier.
9. **Test.** One golden test walks Ycode's menu bar and compares titles
   (the generic forms), order, separators, alternates and shortcuts with
   this section. A second test checks that no two enabled-or-disabled items
   share a shortcut, alternates excepted. Developer Documentation ⇧⌘0 is
   one command listed in two menus (§2.12, §2.13); it counts once.

## 2. Menu bar (normative)

Menus in order: Ycode, File, Edit, View, Find, Navigate, Editor, Product,
Debug, Integrate, Window, Help.

### 2.0 Shortcut corrections (P0, M1, M2, M7)

| Shortcut | Reference command (this spec) | Ycode today |
|---|---|---|
| ⇧⌘A | View ▸ Show Quick Actions… | Editor ▸ Show Coding Tools ▸ Show Code Actions |
| ⌘0 | View ▸ Navigators ▸ Show Coding Assistant | View ▸ Navigators ▸ Show/Hide Navigator |
| ⌥⌘0 | Editor ▸ Show Coding Tools ▸ Show Coding Tools… | View ▸ Inspectors ▸ Show/Hide Inspector |
| ⌥⇧⌘← / ⌥⇧⌘→ | Editor ▸ Code Folding ▸ Fold / Unfold Methods & Functions | Fold All / Unfold All |
| ⌃I | Editor ▸ Structure ▸ Re-Indent | Edit ▸ Format ▸ Re-Indent |
| ⌥⇧⌘W | File ▸ Close Other Window Tabs (alt) | AppKit's "Close All" |
| ⌃⌘F | View ▸ Enter / Exit Full Screen | AppKit's fn-F item |

**What moves where.**

- Show/Hide Navigator and Show/Hide Inspector have **no** default
  shortcut. The toolbar buttons and View menu items toggle them.
- Ycode's "Show Code Actions" keeps no shortcut. It moves to the source
  editor's context menu and stays reachable through Editor ▸ Show Coding
  Tools ▸ Show Coding Tools… (§2.7).
- ⌘0 and Show Coding Assistant switch the left area to the Coding
  Assistant pane, as the toolbar segment does (§4.1;
  `coding-assistant.md` §4).

### 2.1 Ycode (application menu)

1. About Ycode
2. Ycode Extensions…
3. —
4. Settings… ⌘,
5. Behaviors ▸: one item per custom behavior, or "No Custom Behaviors"
   (disabled); — ; Edit Behaviors… (opens Settings ▸ Behaviors).
6. —
7. Open Developer Tool ▸: one item per developer tool found in the active
   developer directory, in the order Instruments, Device Hub, Icon
   Composer, Accessibility Inspector, FileMerge, Create ML. A tool that is
   not installed is left out. Then — and More Developer Tools… (opens
   Apple's public downloads page). Choosing a tool opens that app.
8. Services ▸ *system*
9. —
10. Hide Ycode ⌘H, Hide Others ⌥⌘H, Show All
11. —
12. Quit Ycode ⌘Q, Quit and Keep Windows ⌥⌘Q *alt(⌥)*

### 2.2 File

1. **New ▸**
   - Conversation ⌃⌘H
     - Conversation in New Tab ⌃⌥⌘H *alt(⌥), seen*
     - Conversation in Editor Pane ⌃⌥⇧⌘H *alt(⌥⇧), seen*
   - —
   - Tab ⌘T
   - —
   - Editor Pane On Right ⌃⌘T, Editor Pane Below ⌃⌥⌘T, Window Tab, Window
     ⇧⌘T
   - —
   - Empty File; File from Clipboard (enabled when the pasteboard holds
     text; title corrected in `reference-ui-6.md` §8); File from Template… ⌘N; Target…
   - —
   - Project… ⇧⌘N
     - Choose Template… ⌥⇧⌘N *alt(⌥), seen*
   - Workspace… ⌃⌘N
   - —
   - Group, Group without Folder, Group from Selection, Group from Selection
     without Folder, Folder ⌥⌘N, Folder from Selection
2. —
3. Add Files to “<project>”… ⌥⌘A [Add Files…]; Add Package Dependencies…
4. —
5. Open… ⌘O; Open Recent ▸ (§3.2); Open Quickly… ⇧⌘O
6. —
7. **The close group:**
   - Close Window / Close Tab ⌘W: "Close Tab" with two or more tabs in the
     window, else "Close Window". With no workspace window the title is
     "Close Tab, Editor Pane, Window Tab, or Window".
     - Close Other Tabs ⌥⌘W *alt(⌥), seen*
   - Close “<file>” ⌃⌘W [Close Document]
   - Close Editor Pane ⌃⇧⌘W (disabled with one pane)
     - Close Other Editor Panes ⌃⌥⇧⌘W *alt(⌥), seen*
   - Close Window ⇧⌘W (the title is "Close Window Tab" when the window has
     window tabs)
     - Close Other Window Tabs ⌥⇧⌘W *alt(⌥), seen*
   - Close Project / Close Workspace / Close Package ⌃⌥⌘W (by container)
8. —
9. Duplicate Editor Tab; Save ⌘S; Save All ⌥⌘S; Duplicate… ⇧⌘S; Save As…
   ⌥⇧⌘S; Revert to Saved…; Unlock…; Export…
10. —
11. Show in Finder; Open Terminal at Location; Open in New Tab ⌥⌘O ("Open
    in New Tabs" with several files selected); Open in New Window; Open with
    External Editor
12. —
13. Packages ▸: Reset Package Caches, Resolve Package Versions, —, Update
    to Latest Package Versions
14. —
15. Save As Workspace…; Project Settings… / Workspace Settings… / Package
    Settings… (by container)
16. —
17. Page Setup…; Print… ⌘P

### 2.3 Edit

1. Undo ⌘Z ("Undo <action>"); Redo ⇧⌘Z ("Redo <action>")
2. —
3. Cut ⌘X; Copy ⌘C; Paste ⌘V; Duplicate ⌘D; Delete ⌘⌫.
   - Copy has three variants: Copy File and Line ⌃⌥⌘C, Copy Symbol Name
     ⌃⇧⌘C, Copy Qualified Symbol Name ⌃⌥⇧⌘C.
   - Paste has two variants: Move Item Here ⌥⌘V, Paste and Preserve
     Formatting ⌥⇧⌘V.
   - Whether the variants are modifier alternates or a submenu is still
     open (§12). Implement them as alternates of Copy and Paste.
   - *Pass 6b: they are submenus, "Copy ▸" and "Paste ▸", each holding
     the plain command first; see `reference-ui-6.md` §8 item 4.*
4. —
5. Select All ⌘A
6. —
7. The bookmark group:
   - Bookmark “<file>” Line <n> ⌃⌘' [Bookmark Line]
   - Bookmark “<file>” Line <n>… ⌃⌥⌘' [Bookmark Line With Dialog]
   - Bookmark “<file>” ⌃⇧⌘' [Bookmark File]
   - Bookmark “<file>”… ⌃⌥⇧⌘' [Bookmark File With Dialog]
8. —
9. Sort ▸: By Name, By Type. These sort the selected group's children in
   the project navigator.
10. Format ▸: the standard macOS text Format menu (Show Fonts ⌃⇧⌘T, Show
    Colors, Font ▸, Text ▸, Spelling and Grammar ▸ with Show Spelling and
    Grammar ⌘: and Check Document Now ⌘;, Substitutions ▸,
    Transformations ▸, Speech ▸), as AppKit provides it.
11. —
12. Convert ▸: To Group, To Folder, Preflight Conversion To Folder, To
    String Catalogs….
13. —
14. AutoFill ▸ *system*; Start Dictation… *system*; Emoji & Symbols *system*

### 2.4 View

1. **Editor ▸**
   - Focus Editor Pane ⌃⇧⌘↩
   - —
   - Show Related Items ⌃1
   - Show Previous History ⌃2
   - Show Previous Files History ⌃⌘2
   - Show Next History ⌃3
   - Show Next Files History ⌃⌘3
   - Show Top Level Items ⌃4
   - Show Group Files ⌃5
   - Show Document Items ⌃6

   These open the focused editor's jump-bar menus from the keyboard (§6.1).
   Canvas, Assistant, Code Review and Minimap are **not** here; they are in
   the Editor menu.
2. —
3. Show/Hide Editor Tab Bar; Pin Editor Tab ⇧⌘P; Change Editor
   Orientation; Reset Editor Sizes; Reset Assistant Selection ⌥⇧⌘Z
4. —
5. Show Quick Actions… ⇧⌘A. Ycode: a command palette that lists every
   enabled menu command by title and runs the chosen one. Its layout is
   still to observe (§12).
6. —
7. **Navigators ▸**
   - Project ⌘1, Source Control ⌘2, Bookmarks ⌘3, Find ⌘4, Issues ⌘5, Tests
     ⌘6, Debug ⌘7, Breakpoints ⌘8, Reports ⌘9
   - —
   - Show Coding Assistant ⌘0 (*pass 6b: "Hide Coding Assistant" while
     the pane is shown, so ⌘0 toggles it; `reference-ui-6.md` §9.5*)
   - Show/Hide Navigator (no shortcut)
   - Filter in Navigator ⌥⌘J (focuses the current navigator's filter
     field)
8. **Debug Area ▸**
   - Activate Console ⇧⌘C
   - —
   - Show/Hide Debug Area ⇧⌘Y
9. **Inspectors ▸**
   - one item per inspector tab of the focused editor, in tab order, ⌥⌘1,
     ⌥⌘2, … (File, History, Quick Help for a source file; seven for
     Interface Builder)
   - —
   - Show/Hide Inspector (no shortcut)
10. Show Library ⇧⌘L; Open Library ⌥⇧⌘L (opens the Library as a window that
    stays open); Reload Organizer ⌃R (enabled while the Organizer is
    frontmost)
11. —
12. Choose Theme…
13. —
14. Show/Hide Toolbar ⌥⌘T; Customize Toolbar…; Show Window Tab Bar; Show All
    Window Tabs ⇧⌘\
15. —
16. Enter / Exit Full Screen ⌃⌘F

### 2.5 Find

"<scope>" is "Project" in a project workspace, "Workspace" in a workspace,
and "Package" in a package (§5.4).

1. Find in <scope> ⇧⌘F (no ellipsis)
2. Find and Replace in <scope>… ⌥⇧⌘F
3. Find Next in <scope> ⌃⌘G
4. Find Previous in <scope> ⌃⇧⌘G
5. —
6. Find Selected Text in <scope>; Find Selected Words in <scope>; Find
   Selected Symbol in <scope> ⌃⇧⌘F; Find Call Hierarchy ⌃⇧⌘H; Find
   Ancestor Types; Find Descendent Types; Find Conforming Types; Find in
   Selected Groups…
7. —
8. Find… ⌘F; Find and Replace… ⌥⌘F; Find Next ⌘G; Find Previous ⇧⌘G; Find
   and Select Next ⌥⌘G; Find and Select Previous ⌥⇧⌘G
9. —
10. Replace; Replace All; Replace and Find Next; Replace and Find Previous
11. —
12. Use Selection for Find ⌘E; Use Selection for Replace ⇧⌘E; Select Next
    Occurrence ⌥⌘E; Select Previous Occurrence ⌥⇧⌘E
13. —
14. Select All Find Matches; Select Find Matches in Selection
15. —
16. Hide Find Bar

**Behavior.**

- Find Next / Previous in <scope> step through the Find navigator's
  results and open each one.
- Find and Select Next / Previous add the next match to the selection
  (one more insertion point).
- Select Next / Previous Occurrence do the same with the selected text.
- Select All Find Matches selects every match in the file.

### 2.6 Navigate

1. Reveal in Project Navigator ⇧⌘J; Reveal in Changes Navigator ⇧⌘M;
   Reveal in Debug Navigator ⇧⌘D; Open using Tab ⌥⌘,; Open in Next Editor
   Pane ⌥⌘< *alt(⇧), inferred*
2. —
3. Move Focus to Next Area ⌥⌘`; Move Focus to Previous Area ⌥⇧⌘`; Move
   Focus to Next Editor Pane ⌃`; Move Focus to Previous Editor Pane ⌃⇧`;
   Move Focus to Editor Pane… ⌘J
4. —
5. Show Previous Tab ⇧⌘[; Show Next Tab ⇧⌘]
6. —
7. History:
   - Show Next Location in History ⌃⌘→
     - … using Tab ⌃⌥⌘→ *alt(⌥), inferred*
     - … in Next Editor Pane ⌃⌥⇧⌘→ *alt(⌥⇧), inferred*
   - Show Previous Location in History ⌃⌘←, with the same two alternates
     ⌃⌥⌘← and ⌃⌥⇧⌘←
8. —
9. Jump to Next Active Conversation ⌃⌘K
10. —
11. Jump to Selection ⌥⌘L
12. Jump to Definition ⌃⌘J
    - … using Tab ⌃⌥⌘J *alt*
    - … in Next Editor Pane ⌃⌥⇧⌘J *alt*
13. Jump to Original Source/Generated Interface; Jump to Last Destination
14. —
15. Jump to Next Issue ⌘'; Jump to Previous Issue ⇧⌘'
16. —
17. Bookmarks: Jump to Next Bookmark ⌃;; Jump to Next Bookmark In Workspace
    ⌃⌥;; Jump to Previous Bookmark ⌃: (⌃⇧;); Jump to Previous Bookmark In
    Workspace ⌃⌥: (⌃⌥⇧;)
18. —
19. Jump to Program Counter ⌃⌘P
20. —
21. *when a source editor is focused:*
    - Jump to Next Counterpart ⌃⌘↑ (alternates "… using Tab" ⌃⌥⌘↑ and "… in
      Next Editor Pane" ⌃⌥⇧⌘↑)
    - Jump to Previous Counterpart ⌃⌘↓ (alternates ⌃⌥⌘↓ and ⌃⌥⇧⌘↓)
    - Jump to Line in “<file>”… ⌘L
22. —
23. *when a source editor is focused:* Jump to Next Placeholder ⌃/; Jump to
    Previous Placeholder ⌃? (⌃⇧/)
24. —
25. *when a source editor is focused:* Jump to Next Change ⌃\; Jump to Next
    Local or Upstream Change ⌃⌥\ *alt(⌥)*; Jump to Previous Change ⌃| (⌃⇧\);
    Jump to Previous Local or Upstream Change ⌃⌥| *alt(⌥)*

**Behavior.**

- **Jump to Selection** scrolls the focused editor to its selection.
- **Jump to Last Destination** returns to the place the last jump left.
- **The "using Tab" variants** open the destination in a new tab. **The
  "in Next Editor Pane" variants** open it in the next pane, creating one
  when there is none.
- **Counterparts** cycle through the counterparts of `editor-area.md`, in
  that order, wrapping.
- **Placeholders** do what Tab and ⇧Tab already do in `source-editor.md`.
- **Changes** move to the start of the next or previous change region of
  the change gutter (§6.3), wrapping. "Local or Upstream" includes
  upstream changes when an upstream comparison is known; otherwise it is
  the same as the local command.

### 2.7 Editor (source editor focused)

1. Show Editor Only ⌘↩
2. —
3. Canvas ⌥⌘↩ (checked while shown); Assistant ⌃⌥⌘↩; Code Review ⌥⇧⌘↩ (the
   three are mutually exclusive, §4.2)
4. Layout ▸: Automatic (checked); —; Editor on Left; Editor on Top. This is
   where the editor sits relative to the canvas. Automatic is the
   width-based rule of `previews.md`. The items are disabled while the
   canvas is hidden. *Pass 6b: the items read "Canvas on Right" and
   "Canvas on Bottom" and are enabled whenever canvas mode is on;
   `reference-ui-6.md` §8 item 5.*
5. —
6. Show Completions ⌃Space
7. Show Predictive Completion ⌃⌥Space
8. Show Coding Tools ▸: Show Coding Tools… ⌥⌘0; —; Explain, Document,
   Generate a Playground, Generate a Preview. Show Coding Tools… shows the
   code actions at the caret (`refactoring.md`'s former "Show Code
   Actions"). The other four send the selection (or the file) to the
   coding assistant (`coding-assistant.md` §4, with their enablement).
   *Pass 6b: the reference's submenu holds the full set, validated as
   enabled; `reference-ui-6.md` §9.5 (A4).*
9. Edit All in Scope ⌃⌘E (§6.4)
10. Show Callers…
11. Expand Macro; Hide All Macro Expansions
12. Refactor ▸, as in `reference-ui-4.md` §8.2, with two changes:
    - "Extract to File" is added before "Extract Selection to File";
    - items that don't apply at the caret may be **hidden**, not just
      disabled. The fourth group (async and localized-string items) was
      hidden for an ordinary Swift file.
13. —
14. Fix All Issues ⌃⌥⌘F; Show Issues ⌃⌥⌘L; Show / Hide All Issues ⌃⌘L
15. —
16. Show Markdown
17. —
18. Selection ▸: Select All Symbols; Split Selection By Lines; Balance
    Delimiters; —; Select Column Up ⌃⇧↑; Select Column Down ⌃⇧↓
19. Structure ▸:
    - Re-Indent ⌃I; Shift Left ⌘[; Shift Right ⌘]
    - —
    - Reformat To Width ⌃⌥I; Format to Multiple Lines ⌃M; Format Selection
      ⌃⌥⇧I; Format File ⌃⇧I. In a Swift file the last two read "Format
      Selection with ‘swift-format’" and "Format File with ‘swift-format’".
    - —
    - Move Line Up ⌥⌘[; Move Line Down ⌥⌘]; Comment Selection ⌘/; Add
      Documentation ⌥⌘/
20. Code Folding ▸:
    - Fold ⌥⌘←; Unfold ⌥⌘→; Unfold All (no shortcut)
    - —
    - Fold Methods & Functions ⌥⇧⌘←; Unfold Methods & Functions ⌥⇧⌘→
    - —
    - Fold Comment Blocks ⌃⇧⌘←; Unfold Comment Blocks ⌃⇧⌘→
21. Syntax Coloring ▸: Default for File Type (checked); None; —; one item per
    language Ycode can color, alphabetical. The effective language of a
    "Default" file carries the mixed-state mark.
22. Font Size ▸: Increase ⌘+; Decrease ⌘-; —; Reset ⌃⌘0
23. Choose Theme...
24. —
25. Inline Comparison (checked); Side By Side Comparison
26. —
27. Minimap ⌃⇧⌘M (checked); Authors ⌃⇧⌘A; Code Coverage
28. —
29. Vim Mode; Relative Line Numbers (enabled only in Vim mode)
30. —
31. Invisibles; Scope Guides; Wrap Lines ⌃⇧⌘L (checked)
32. —
33. Show Last Change for Line; Create Code Snippet…

**Ycode differences to remove.**

- "Line Numbers" is not in this menu; it lives in Settings ▸ Editing ▸
  Display.
- "Add New Constraints…" belongs only to the Interface Builder Editor menu
  (§2.8).
- Layout ▸ no longer holds "Assistant Mode" or "Split Editor". Assistant
  modes are chosen in the assistant's jump bar (`reference-ui-4.md` §16).
  Splits are File ▸ New ▸ Editor Pane On Right / Below.

### 2.8 Editor menu for other editors

The first block is always: Show Editor Only ⌘↩; —; Preview ⌥⌘↩ (the canvas
item is titled **Preview** here); Assistant ⌃⌥⌘↩; Code Review ⌥⇧⌘↩; Layout
▸ (Automatic; —; Preview on Right; Preview on Bottom). After it:

- **Property list:**
  - —
  - Add Item
  - Value Type ▸: Array, Dictionary, —, Boolean, Data, Date, Number, String
  - —
  - Raw Keys and Values (shows raw key names instead of readable ones)
- **Storyboard / xib:**
  - —
  - Align ▸ (Left Edges ⌘[, Right Edges ⌘], Top Edges, Bottom Edges, —,
    Horizontal Centers, Vertical Centers, Baselines, —, Horizontally in
    Container, Vertically in Container)
  - Arrange ▸ (Send to Front, Send to Back, Send Forward, Send Backward)
  - Size to Fit Content ⌘=; Update Frames ⌥⌘=
  - —
  - Embed In ▸ (View, View Without Inset, Scroll View, Stack View, —,
    Navigation Controller, Tab Bar Controller); Unembed
  - —
  - Resolve Auto Layout Issues ▸ (Selected Views: Update Frames, Update
    Constraint Constants, Add Missing Constraints, Reset to Suggested
    Constraints ⌥⇧⌘=, Clear Constraints; —; All Views in Container: the
    same five)
  - Refactor to Storyboard…
  - Localization Locking ▸ (Nothing ✓, All Properties, Localizable
    Properties, Non-localizable Properties, —, Reset Locking Controls)
  - —
  - Document Outline (checked); Reveal in Document Outline; Minimap ⌃⇧⌘M
  - —
  - Canvas ▸ (Constraints ✓, Intrinsic Size Constraints Contributing To
    Ambiguity, Involved Views For Selected Constraints, Layout Rectangles,
    Bounds Rectangles, Device Bezels ✓, Placeholder Backgrounds ✓)
  - Zoom ▸ (Zoom to 6.25%, 12.5%, 25%, 50%, 75%, Zoom to 100% ⌃⌘=, 125%,
    150%, 200%, 300%, 400%, —, Zoom to Fit, —, Zoom In, Zoom Out)
  - —
  - Snap to Guides (checked); Guides ▸ (Add Horizontal Guide ⌘_, Add
    Vertical Guide ⌃⌘|)
  - Ycode's existing "Add New Constraints…" belongs here, after Update
    Frames.
- **Asset catalog:**
  - —
  - Add New Asset ▸ (the "+" menu of `reference-ui-3.md` §3.5, plus macOS
    ▸ macOS App Icon, macOS Generic Icon, Icon Status Badge, Sidebar Icon;
    watchOS ▸ watchOS App Icon, Complication Placeholder; tvOS ▸ tvOS App
    Icon and Top Shelf Image, tvOS Launch Image (Deprecated), —, Image
    Stack, Image Stack Layer, —, Game Center Dashboard Image, Game Center
    Leaderboard, Game Center Leaderboard Set; visionOS ▸ visionOS App Icon,
    visionOS App Icon Layer)
  - Delete Selected Items
  - —
  - Device Image Reps ▸ (Universal, iPhone, iPad, Mac Catalyst Scaled,
    CarPlay, Mac, Apple Vision, Apple Watch, Apple TV)
  - —
  - Find References to Item
  - —
  - Quick Look; Show in Finder; Open in External Editor
  - —
  - Show Overview (checked); Show Slicing

The project editor's Editor menu was not observed (§12).

### 2.9 Product

1. Run ⌘R, Run… ⌥⌘R *alt(⌥), seen*
2. Test ⌘U, Test… ⌥⌘U *alt*
3. Profile ⌘I, Profile… ⌥⌘I *alt*
4. Analyze ⇧⌘B, Analyze… ⌥⇧⌘B *alt*
5. Archive, Archive… *alt(⌥)*
6. Stop ⌘.

   The "…" variants open the scheme editor on that action, then run it.
7. —
8. Build For ▸: Running ⇧⌘R; Testing ⇧⌘U; Profiling ⇧⌘I
9. Perform Action ▸:
   - Run Without Building ⌃⌘R; Test Without Building ⌃⌘U; Profile Without
     Building ⌃⌘I
   - —
   - Build with Timing Summary; Build and Export Test Products
   - —
   - Test ⌃⌥⌘U (the tests selected in the Test navigator, or the test at the
     caret); Test Again ⌃⌥⌘G; Test Without Building Again; Profile; Profile
     Again
   - —
   - Compile “<file>” ⌃⌘B [Compile File]; Analyze “<file>” ⌃⇧⌘B
   - —
   - Preprocess “<file>”; Assemble “<file>”
   - —
   - Generate Optimization Profile…
10. —
11. Build ⌘B; Clean Build Folder… ⇧⌘K; Clean Build Folder Immediately ⌥⇧⌘K
    (no confirmation); Delete Derived Data…; Clear Test Results ⌃⌥⌘K; Clear
    All Issues
12. —
13. Build Documentation ⌃⇧⌘D
14. —
15. Show Build Folder in Finder; Copy Build Folder Path
16. —
17. Export Localizations…; Import Localizations… (disabled in a package
    workspace)
18. —
19. Scheme ▸ (`reference-ui-2.md` §7.8): Choose Scheme ⌃0; Select Next
    Scheme ⌃⌘]; Select Previous Scheme ⌃⌘[; —; Edit Scheme… ⌘<; New
    Scheme…; Manage Schemes…; —; one item per scheme, the active one
    checked.
20. Destination ▸:
    - Choose Destination ⌃⇧0 (opens the toolbar destination menu); Select
      Next Destination ⌃⌥⌘]; Select Previous Destination ⌃⌥⌘[
    - —
    - Show All Run Destinations
    - —
    - label "Devices", then the device rows
    - —
    - label "Simulators", then the simulator rows
    - —
    - label "Build", then the generic rows
    - —
    - Incompatible ▸
    - —
    - Manage Devices… ⇧⌘2

    Rows and ordering are as in §11.4. Rows read "<name> <OS version>",
    and the active destination is checked.
21. Test Plan ▸: Select Next Test Plan; Select Previous Test Plan; —; Edit
    Test Plan ⌘>; New Test Plan…; Manage Test Plans…; —; one item per test
    plan of the scheme, the active one checked ("<scheme> (Autocreated)"
    when the scheme has none).
22. —
23. App Shortcuts Preview

### 2.10 Debug

1. Pause / Continue ⌃⌘Y. The title is "Pause" while running and
   "Continue" while paused.
2. Continue To Current Line ⌃⌘C (runs to the caret's line in the focused
   editor)
3. Step Over F6; Step Over Instruction ⌃F6; Step Over Thread ⌃⇧F6
4. Step Into F7; Step Into Instruction ⌃F7; Step Into Thread ⌃⇧F7
5. Step Out F8

   The Instruction and Thread items may be ⌃ / ⌃⇧ alternates (§12). Until
   that is confirmed, they are visible items.
6. —
7. Step Over and Follow Program Counter; Step Into and Follow Program
   Counter; Step Out and Follow Program Counter
8. —
9. Deactivate / Activate Breakpoints ⌘Y
10. Breakpoints ▸:
    - Create Breakpoint at Current Line ⌘\ (removes it when one exists)
    - Enable / Disable Breakpoints at Current Line
    - Create Column Breakpoint
    - Delete Column Breakpoints at Current Line
    - Create Swift Error Breakpoint
    - Create Exception Breakpoint…
    - Create Symbolic Breakpoint… ⌥⌘\
    - Create Test Failure Breakpoint
    - Delete All Breakpoints
11. —
12. Console ▸:
    - Copy Row with Visible Metadata ⌥⇧C; Copy Row with All Metadata; Copy
      Row without Metadata
    - —
    - Jump To Source ⌥⇧⌘J
    - —
    - Hide Similar Items ▸ and Show Similar Items ▸, each with Type,
      Process, PID, Library, Subsystem, Category, TID
    - —
    - Clear Console ⌘K; Reload Console ⌥⌘K; Select Last Output ⌥⇧⌘A
13. Debug Workflow ▸:
    - Navigate to Source File when Process Pauses (checked by default)
    - Synchronize Insertion Point to Program Counter
    - Always Show Disassembly
    - Show Library Info…
    - Load Symbols… (shown while debugging)
    - View Memory ⌃⌥⇧⌘M
    - Interrupt Debugger Operation ⌃C

    Ycode's "View Process by Queue" moves out of this menu into the Debug
    navigator's process view options (`reference-ui-4.md` §5.3).
14. —
15. Attach to Process by PID or Name…; Attach to Process ▸ (filled with
    running processes, "Getting Process List…" while it loads); Detach;
    Debug Executable…; Debug Crash Log…
16. —
17. Capture GPU Workload; Simulate Location ▸; Induce Device Conditions ▸;
    View Debugging ▸:
    - Capture View Hierarchy
    - —
    - Show View Frames, Show Alignment Rectangles, Show View Drawing, Show
      Responsive Scrolling Status
    - —
    - Configure Environment Overrides…, Disable All Environment Overrides
    - —
    - Rendering ▸ (Color Blended Layers, Color Hits Green and Misses Red,
      Color Copied Images, Color Layer Formats, Color Immediately, Color
      Misaligned Images, Color Offscreen-Rendered Yellow, Color Compositing
      Fast-Path Blue, Flash Updated Regions)
    - Appearance ▸ (System Appearance, —, Light, Dark, High Contrast Light,
      High Contrast Dark)
18. —
19. StoreKit ▸ (Manage Transactions…, —, Approve Transaction, Decline
    Transaction, Refund Purchase, Resolve Issue, Request Price Increase
    Consent, Edit Subscription, —, Delete Transaction); GameKit ▸ (Manage
    Game Progress…)

### 2.11 Integrate

This replaces the item list of `reference-ui-4.md` §3; the enablement
rules in `source-control.md` stay.

1. **Source Control** *label*
2. Commit… ⌥⌘C; Push…; Pull… ⌥⌘X; Fetch Changes; Refresh File Status
3. —
4. Stage All Changes
5. Stage Changes in “<file>” [Stage Selected Files]
6. Unstage All Changes
7. Unstage Changes in Selected Files [Unstage Selected Files]
8. Mark Selected Files as Resolved [Mark as Resolved]
9. —
10. Add Selected Files [Add] (untracked files)
11. Cherry-Pick…
12. Stash Changes…
13. —
14. *when the repository has a remote (inferred):* Create Pull Request…
15. —
16. Discard All Changes…
17. Discard Changes in “<file>”… [Discard Changes in Selected Files…]. When
    an untracked file is selected in a navigator, this reads "Move Selected
    Files to Trash…" (`reference-ui-4.md` §3).
18. —
19. Clone…; New Git Repository…
20. —
21. **Cloud** *label* (the reference names its CI service here; Ycode
    writes "Cloud"); Create Workflow…; Manage Workflows… (disabled)

**Titles.**

- `<file>` (observed for Stage and Discard) is the focused editor's file
  when no navigator selection applies.
- With a navigator selection, the titles read "… in Selected Files"
  (`reference-ui-4.md` §3).
- The bracketed titles are those shown with no workspace.

### 2.12 Window

1. Minimize ⌘M; Minimize All ⌥⌘M *alt (system)*; Zoom; Zoom All *alt
   (system)*; Fill and Center *system*
2. —
3. Move & Resize ▸ *system*; Full Screen Tile ▸ *system*
4. —
5. Rename Window Tab… ⌥⇧⌘T; Show Previous Window Tab ⌃⇧⇥; Show Next Window
   Tab ⌃⇥; Move Tab to New Window; Merge All Windows
6. —
7. Developer Documentation ⇧⌘0; Welcome to Ycode ⇧⌘1; Downloads ⇧⌘9;
   Organizer ⌥⇧⌘O
8. —
9. Touch Bar ▸ *system*
10. —
11. Bring All to Front; Arrange in Front *system*; Remove Window from Set
    *system*
12. —
13. The window list *system*. Each workspace window is "<workspace> —
    <document>" (§3.4), and the key window is checked.

Ycode lists none of the *system* items itself. Today it adds Minimize All
and Zoom All a second time.

Developer Documentation opens Apple's public developer documentation web
site in the default browser; Ycode has no documentation viewer. Downloads
opens Settings ▸ Components.

### 2.13 Help

1. Developer Documentation ⇧⌘0 (the same command as in the Window menu)
2. Human Interface Guidelines ⇧⌘H (opens Apple's public HIG pages)
3. —
4. Ycode Help; What's New in Ycode; Release Notes; The Swift Programming
   Language (swift.org); Provide Feedback… (the project's issue tracker)
5. —
6. Show / Hide Keyboard Hints ⌥⌘? (behavior still to observe, §12; disabled
   until then). *Pass 6b: the hints are on in the factory state (the
   item reads "Hide Keyboard Hints").*
7. Show Quick Help for Selected Item ⌃⌘? (shows the Quick Help popover for
   the symbol at the caret)
8. Search Documentation for Selected Text ⌃⌥⌘/ (opens a documentation
   search for the selection)

Ycode omits the reference's two account and service help items (they name
Apple services).

## 3. Launch, Welcome window, recents, window identity

### 3.1 Welcome window (L1, L2)

1. **When it shows.**
   - Launching Ycode with no document to open shows the Welcome window and
     no Open panel.
   - Window ▸ Welcome to Ycode (⇧⌘1) shows it at any time.
2. **Window.** 480 × 632 points, titled "Welcome to Ycode" (accessibility
   title). No title text is drawn. It opens centered. From top to bottom:
   - a round close button at the top left;
   - Ycode's application icon (Ycode's own artwork);
   - "Ycode", then "Version <short version>";
   - three buttons in one row: "Open…" (the Open panel), "Clone…"
     (Integrate ▸ Clone…), and a pull-down "New Project" with a chevron
     (its items are the New Project compact picker rows of
     `reference-ui-3.md` §5.4, to confirm live);
   - a list headed "Recent Projects" (the heading is the list's
     accessibility name). It shows the recent workspaces of §3.2, newest
     first. Each row is the container icon, the name without extension in
     primary text, and the folder path abbreviated from the volume name in
     secondary text ("External/Samples/…"), with each text as its own
     tooltip. The first row is selected. Double-click or Return opens it.
3. **Lifetime.** Opening a workspace from the Welcome window closes it.
   Opening one from elsewhere (Finder, command line, Open Recent) leaves it
   open.

**Acceptance.**

- Launching without arguments shows the Welcome window within one second,
  and no Open panel appears.
- ⇧⌘1 brings it back after it was closed.
- The list matches File ▸ Open Recent.

### 3.2 Open Recent (L3)

1. File ▸ Open Recent ▸ lists recently opened workspaces (projects,
   workspaces, packages), newest first. These are the containers the
   document controller recorded, not files.
2. **Titles.**
   - A title is the container's file name (for example
     "ObsApp.xcodeproj") or the package folder name ("Obs").
   - When two entries have the same title, each becomes "<title> —
     <parent folder name>", with an em dash and two spaces before the
     folder name exactly as observed ("ObsApp.xcodeproj —  ycode-observe-
     ide-audit").
3. Then —, then Clear Menu.
4. Entries survive relaunch. An entry whose file is missing is removed.

**Acceptance.** Open two copies of the same project from different
folders, quit, relaunch: both entries are listed with their folder names,
and Clear Menu empties the list and the Welcome list.

### 3.3 Window size and areas

- The default frame is 1400 × 900 **including** the toolbar. Today
  Ycode's content area is 1400 × 900, so the frame is 949 tall (L5).
- At first open the navigator (Project) and the inspector are shown and
  the debug area is hidden.

### 3.4 Window title (L4)

1. The window's title is "<workspace display name> — <document name>".
   - The document name is the focused editor's file name with extension
     ("ObsApp — Model.swift").
   - With no document it is the container's file name ("ObsApp —
     ObsApp.xcodeproj").
   - A package's display name is the package name.
2. The title is not drawn in the title bar; the toolbar shows the name
   (§4). It appears in the Window menu, Mission Control and the Dock menu.

### 3.5 Editor at first open (L8; to confirm live)

> **Correction (pass 6, `reference-ui-6.md` §1.3):** confirmed live: the
> reference shows no Start Page at first open. The editor is empty under a
> "No Selection" jump bar; the Start Page appears only where the New
> Editor Tabs / Panes setting opens it.

- The reference shows the editor area's jump bar with "No Selection" and
  an empty editor.
- Ycode lays its Start Page (Open Quickly + Recent Files) over the whole
  editor, hiding the jump bar.
- Until the live check (§12): keep the Start Page, but below the jump bar,
  not over it.
- The Start Page's Recent Files list survives relaunch (L9), stored per
  workspace in user data.

## 4. Toolbar

### 4.1 Left control: Navigators | Coding Assistant (T2)

1. A two-segment control whose segments are exclusive. At most one is
   selected:
   - **Navigators** is selected while the left area shows a navigator.
   - **Coding Assistant** is selected while it shows the Coding Assistant
     pane (`coding-assistant.md` §4).
2. Clicking the unselected segment shows that content (opening the area if
   needed). Clicking the selected segment hides the left area, and then
   neither segment is selected.
3. The segments follow every way of changing the area: View ▸ Navigators
   items, ⌘1–⌘9, ⌘0, and window restoration.
4. Tooltips: "Navigators", "Coding Assistant".

**Acceptance.**

- At open, Navigators is selected.
- After View ▸ Navigators ▸ Hide Navigator, neither is selected.
- After ⌘0, Coding Assistant is selected.

### 4.2 Editor Mode: Canvas | Assistant | Code Review (T3)

1. Three exclusive segments. **At most one** mode is on in the focused
   editor:
   - turning one on turns the others off;
   - clicking the selected segment turns it off, leaving none selected.
2. The Editor menu items Canvas / Assistant / Code Review (and "Preview"
   for non-source editors) follow the same rule. The segments mirror the
   menu state.
3. Tooltips: "Show Canvas", "Show Assistant", "Show Code Review".

**Acceptance.**

- Turning on the Assistant while the canvas is shown hides the canvas.
- Turning on Code Review while the Assistant is shown closes the
  assistant pane.
- Clicking the selected segment leaves no mode on.

### 4.3 Center and title (T1, T4–T7)

1. **Title area.** The workspace's icon and name, with no subtitle while
   idle: Ycode's "Ready" is removed. The activity subtitle appears only
   while an action runs or after it finishes (`reference-ui-2.md` §2.3).
2. **Run / Stop.** Tooltips "Build and then run the current scheme" and
   "Stop the running scheme or application". **Go Back / Go Forward**:
   "Show Previous Location in History" and "Show Next Location in History".
3. **New Conversation button.** A button sits before the scheme pill; it
   starts a conversation in the Coding Assistant pane
   (`coding-assistant.md` §4).
4. **The pill's two pop-ups** have the accessibility names "Active Scheme"
   and "Active Run Destination".
5. **Default destination (T1).** When a scheme has no remembered
   destination, choose the first entry of this list that applies:
   1. My Mac when the product's platform is macOS;
   2. otherwise the first simulator of the product's platform in §11.4
      order whose OS version is not below the deployment target
      (*pass 6b: replaced by `reference-ui-6.md` §2.4.3, which prefers the
      newest-generation Pro iPhone*);
   3. otherwise the generic "Any <Platform> Simulator Device".

   My Mac is never the default for an iOS-only product. Remember the
   choice per scheme in user data.

   *Pass 6 (`reference-ui-6.md` §2.4): "the product's platform is macOS"
   means the product supports macOS (a multiplatform app defaults to My
   Mac).*

**Acceptance.** Opening the iOS sample selects an iOS simulator, and ⌘R
builds for the iOS Simulator SDK.

## 5. Navigators

### 5.1 Project navigator: first view (N1–N5)

1. **Products group.** The project's product-reference group (the
   `productRefGroup` of `specs/formats/pbxproj.md`, usually "Products") is
   **not shown**.
2. **Expansion.** At first open (no saved state), the project row and its
   first child group are expanded. After that, expansion is saved per
   workspace in user data.
3. **Status letters** appear on file rows only, never on the project,
   group or folder rows (amends `source-control.md` §Project navigator
   badges).
4. **File extensions.** File names are shown **without extensions** by
   default. Settings ▸ General ▸ File extensions defaults to **Hide All**,
   the factory default.
5. **Package workspaces.** The root's children are "Package" (the
   manifest), then "Sources", then "Tests", then the other items by name
   (`reference-ui-2.md` §10).

**Acceptance.**

- The iOS sample shows "ObsApp ▸ ObsApp ▸ Assets, ContentView, Main,
  Model, Notes, ObsAppApp, Settings", with no Products row and no letter on
  the two top rows.

### 5.2 Bottom bars, headers, empty states (N6, N7, N8, N12, N14)

Each navigator has its own bottom bar. The left button is a pull-down
menu; "—" means none. The filter's placeholder is always "Filter" and
it has a leading filter-options pull-down.

| Navigator | Header | Left button (tooltip) | In-field toggles (title, tooltip, default) | Empty state (two lines) |
|---|---|---|---|---|
| Project | — | "+" | "Recent files" — "Show only recent files" (off); "Files with source-control status" — "Show only files with source-control status" (off) | — |
| Source Control | Changes \| Repositories | a pull-down (contents to observe) | — | Ycode keeps its "No Repository" |
| Bookmarks | — | "…" (more) pull-down | "Incomplete Items" — "Show only incomplete items" (off) | "No Bookmarks" / "Click the '…' button to add bookmarks" |
| Find | Find › Text › Containing, Aa ("Case Sensitive"), field, scope | — | — (plain filter) | none |
| Issues | — | — (the filter takes the full width) | "Show only latest issues" — "Show only issues from open documents and recently built sources" (off); "Only errors" — "Show only errors" (off) | "No Issues" |
| Tests | test-plan pop-up; "Mode" with two radio buttons "Group by Test Hierarchy" (default) and "Group by Tags" | "+" — "Add a new test target or class" | "Show Only Included Tests" (off); "Recent Tests" — "Show only recent tests and open documents" (off) | "No Tests" / "Click the ⊕ button to add test targets" |
| Debug | — | — | "Show compressed stack frames" — "Show only stack frames with debug symbols and between libraries" (**on**); "Show only interesting content" — "Show only crashed threads and threads with debug symbols" (off); "Show only running blocks" — "Show only running blocks when in Queues view" (**on**) | "No Debug Session" |
| Breakpoints | — | "+" — "Create a breakpoint" | "Modified breakpoints" — "Show only modified breakpoints"; "Enabled breakpoints" — "Show only enabled breakpoints" (both off) | "No Breakpoints" |
| Reports | Local \| Cloud ("Show Local Reports", "Show Cloud Reports") | pull-down | "Recent reports filter" — "Show only recent reports" (off) | "No Logs" |

**Toggle behavior.**

- **Incomplete Items.** Bookmarks gain a done state, toggled from the
  bookmark's context menu. Ycode stores it as `done: true` in its
  bookmarks file. The toggle hides done bookmarks.
- **Show Only Included Tests** hides tests that the active test plan
  skips.
- **Recent Tests** keeps tests of open files and of the last run.
- **Show compressed stack frames** is Ycode's existing system-frame
  folding.
- **Show only interesting content** keeps the stopped thread and threads
  with user frames.
- **Show only running blocks** applies to the queue view.
- **Modified breakpoints** keeps breakpoints with a condition, ignore
  count or action.

**Selector tooltips**, exactly: "Show the Project navigator", "Show the
Source Control navigator", "Show the Bookmark navigator", "Show the Find
navigator", "Show the Issue navigator", "Show the Test navigator", "Show
the Debug Navigator", "Show the Breakpoints Navigator", "Show the Report
navigator".

**Test navigator rows.** The status diamonds go at the **right** end of
the rows (`reference-ui-2.md` §6.2). Group by Tags groups tests by their
swift-testing tags, with "Untagged Tests" last.

### 5.3 Issue navigator (N9, N10, N11)

1. **Issues without a file** are rows directly under the root, after the
   file groups. They are not in a "Build System" group.
   *Pass 6 (`reference-ui-6.md` §5.1): they are rows directly under the
   project row, which comes before the target rows; files are grouped by
   target, one row per file (§5.2.4).*
2. **Stale issues.** The next build of the same scheme replaces stale
   issues; Clean is not needed. An issue from the previous build that the
   new build does not report is removed when that build finishes. Issues
   in files the new build did not compile stay stale (grey) until a build
   compiles them.
3. Each group shows the file-type icon of its file.

### 5.4 Find navigator scope

- The scope pop-up reads "In Project" in a project workspace, "In
  Workspace" in a workspace, and "In Package" in a package. The first
  three scope items use the same word (`reference-ui-2.md` §3.5,
  confirmed).
- The search field keeps a recent-search history (its pull-down).

## 6. Editor area and source editor

### 6.1 Jump bar (E1, E2, M4)

1. **Order:** Related Items (a grid icon, tooltip "Navigate to Related
   Items"), then the path components: workspace › groups › file without
   extension › symbol ("No Selection"). There are **no back/forward
   buttons** in the jump bar; history is in the toolbar.
2. **Right end:** Show Previous Issue (tooltip "Show Previous Issue"), an
   "Issues" pull-down listing the file's issues, and Show Next Issue
   ("Show Next Issue"). (Refined by `reference-ui-6.md` §4.1.2: three
   glyph-only controls, "‹", the severity glyph, "›".)
   - The three are present while the workspace has issues.
   - The arrows move through the file's issues and then the next files'
     issues, like ⌘' and ⇧⌘'.
3. **Keyboard menus.** View ▸ Editor's ⌃1–⌃6 open the jump-bar menus:
   - ⌃1: Related Items;
   - ⌃2 / ⌃3: the history menus;
   - ⌃⌘2 / ⌃⌘3: the same, files only;
   - ⌃4: the top-level component;
   - ⌃5: the group's files;
   - ⌃6: the document's symbols.

   Each opens at the jump bar under the component. Typing filters the open
   menu.
4. **Assistant jump bar (E4).** A close button ("Close this Editor Pane"),
   then the mode pop-up (`reference-ui-4.md` §16), then the path. It has no
   history buttons.

### 6.2 Debug bar (E6)

- Left: the breakpoints toggle.
- Right, in order: "Line: N  Col: N", the branch button, and the debug-area
  toggle at the far right.
- The branch button shows the branch with a branch glyph. Its tooltip is
  "Shows a list of available branches". It opens a menu of local branches
  with the current one checked; choosing one switches branch with `git
  switch` (refused with an alert when the working tree has conflicts).

### 6.3 Change gutter (E3)

1. **Where.** An 11-pt column at the far left of the gutter, left of the
   line numbers, shown in normal editing whenever the file is in a git
   working copy.
2. **Bars.** One bar per change region against the index and HEAD:
   - added and modified lines get a bar;
   - deleted lines get a short mark between the lines where they were.
3. **Accessibility and tooltips.** Each bar's accessibility description is
   "Local modification on lines <a> through <b>" ("on line <a>" for one
   line). The column's tooltip names the kind: "Unstaged change" or
   "Staged change".
4. **Refresh.** The bars update after each edit, against the editor's
   text, after a 0.5 s pause.
5. **Navigation.** Navigate ▸ Jump to Next / Previous Change moves between
   regions (§2.6).
6. **Click.** Clicking a bar opens Code Review mode on that region
   (Inline Comparison).

**Acceptance.** Editing line 13 of a committed file shows a bar on line
13 within one second, and ⌃\ moves the caret to it.

### 6.4 Editing commands behind the Editor menu (M5–M7, M15)

| Command | Behavior |
|---|---|
| Font Size ▸ Increase / Decrease / Reset (⌘+, ⌘-, ⌃⌘0) | Change the source editor font size for all editors by one point (minimum 6, maximum 48). Reset returns to the theme's size. The change is a user setting, not a theme edit. |
| Move Line Up / Down (⌥⌘[, ⌥⌘]) | Move the lines touched by the selection up or down by one line, keeping the selection on them. One undo step each. Disabled at the first / last line. |
| Re-Indent (⌃I) | Re-indent the selected lines, or the caret's line, to the indentation the language rules give. |
| Add Documentation (⌥⌘/) | Insert a doc-comment template above the declaration at the caret: `///` lines with the summary placeholder, and `- Parameters:`, `- Returns:` and `- Throws:` placeholders as the declaration needs (Swift Markup, public). |
| Reformat To Width (⌃⌥I) | Re-wrap the selected comment paragraph to the "Reformat code at column" setting (§9.3). |
| Format to Multiple Lines (⌃M) | Put each element of the argument, parameter or collection list at the caret on its own line. |
| Format Selection / Format File (⌃⌥⇧I, ⌃⇧I) | Run the toolchain's open-source `swift-format` on the selection or the file. Swift files only; other languages disabled. |
| Fold Methods & Functions / Unfold … (⌥⇧⌘← / →) | Fold or unfold every function, method, initializer and accessor body in the file. |
| Fold Comment Blocks / Unfold … (⌃⇧⌘← / →) | Fold or unfold every multi-line comment and every run of three or more `//` lines. |
| Unfold All (no shortcut) | Open every fold. |
| Select Column Up / Down (⌃⇧↑ / ⌃⇧↓) | Add an insertion point on the line above or below, at the same column (clamped to the line end). Typing then edits at every insertion point. Escape returns to one. |
| Split Selection By Lines | Turn a multi-line selection into one selection per line. |
| Balance Delimiters | Select the text between the nearest enclosing matching delimiters; again, include the delimiters. |
| Select All Symbols / Edit All in Scope (⌃⌘E) | Select every occurrence, in the current scope, of the symbol at the caret, as multiple selections for simultaneous editing. Uses the language server's document highlights. |
| Copy File and Line (⌃⌥⌘C) | Put "<file name>:<line>" for the caret on the pasteboard (exact form to confirm live, §12). |
| Copy Symbol Name / Copy Qualified Symbol Name | Put the symbol at the caret ("increment(by:)") / with its enclosing types ("Counter.increment(by:)") on the pasteboard. |
| Duplicate (⌘D) | Duplicate the selection, or the caret's line when the selection is empty, right after it. |

### 6.5 Minimap (E5)

- Width: about 13–14 % of the editor's width (observed 128 pt for a 962-pt
  editor, 73 pt for a 480-pt split), at least 60 pt.
- It carries labels for the file's declarations ("landmarks", the jump
  bar's symbol list) at their positions.
- *Pass 6b: on by default (factory default confirmed with no user key);
  `reference-ui-6.md` §4.5.*

## 7. Inspectors (I1–I5)

1. **Tab bar.** The inspector tabs fill the bar's width as equal segments,
   with tooltips "Show the File inspector", "Show the History inspector",
   "Show Quick Help inspector". Editor-specific tabs follow them.
2. **Nothing selected.** The File inspector shows "Not Applicable",
   centered.
3. **File inspector, file in a git working copy.** The sections, in order:
   1. **Identity and Type:** Name, Type, Location (and file name), Full
      Path, **Working Copy** (the repository's top-level folder), **Relative
      Path** (the path inside it).
   2. **On Demand Resource Tags:** a disabled field with the placeholder
      "Only resources are taggable". For resources it is a tag token field
      editing the file's `ASSET_TAGS`; Ycode shows it disabled for all
      files for now.
   3. **Target Membership:** one row per target that includes the file:
      the target's icon and name, with the membership kind under it
      ("Default").
      - "+" (tooltip "Choose which targets include this file") lists the
        project's targets to add.
      - "−" ("Remove this file from selected targets") removes the
        selected ones.
      - The pencil ("Edit target membership options") is disabled.
      - For files in a synchronized folder, membership edits write the
        folder's exception sets (`specs/formats/pbxproj.md`).
   4. **Text Settings.**

   Outside git, Working Copy and Relative Path are omitted.
4. **History inspector.** One row per commit that changed the focused
   file, newest first (`git log --follow -- <file>`). Each row shows the
   author name, the subject in a second line, and the relative date at the
   right ("Today", "Yesterday", else a date, as in `source-control.md`).
   Selecting a row shows the commit in Code Review against the working
   copy. With no commits: "No History".
5. **Quick Help, caret not on a symbol.** A section "Quick Help" holding
   "No Quick Help" and a "Search Documentation" button (opens a
   documentation search for the word at the caret).
6. **Asset catalogs (I6).** The set inspector moves out of the editor into
   a fourth inspector tab (`reference-ui-3.md` §3.1).

## 8. Debug area (D1, D2)

1. **Variables bar:** the scope pop-up, "Quick Look", "**Print
   Description**" (prints the selected variable's description to the
   console, like `po`), and the filter.
2. **Height.** When a behavior or a run opens the debug area, it opens at
   the remembered height, or 135 points the first time.
3. **Console bar** order: Quick Look, Metadata Options, the filter with its
   options, Clear Console, then the two half toggles at the far right.

## 9. Settings (S1–S6)

Pane rows marked "(stored)" are kept in the user defaults and shown, but
change nothing in Ycode yet. Every other row must take effect. Where only
the default value was observed, Ycode offers that value plus the
alternatives named here, pending the live pass (§12).

### 9.1 General

| Section | Row | Control and default | Effect |
|---|---|---|---|
| Starting Points | Restore open projects and workspaces | pop-up: Use System Setting (default), Always, Never | Reopens last session's workspace windows at launch. "Use System Setting" follows macOS "Close windows when quitting an application". |
| Navigation and Files | Navigator size | pop-up: Use System Setting (default), Small, Medium, Large | Row size and font of all navigators |
| | Bookmark navigator detail / Find navigator detail / Issue navigator detail | pop-ups: Up to 1 / 2 / 3 / 4 / 5 Lines; default Up to 3 Lines | Maximum lines per row before the ellipsis |
| | Window tabs have independent sidebar widths | toggle, off | Each window tab keeps its own navigator and inspector widths |
| | Automatically unlock files | toggle, off | Unlocks locked files without asking when edited |
| | File extensions | pop-up: Hide All (**default**), Show All | §5.1 |
| Issues | Issue presentation | pop-up: Show Inline (default), Show Minimized | Inline annotations full or as an icon only |
| | Predictive Issues | toggle, on | Existing |
| | Stop build on first error | toggle, on | Cancels the build at the first error |
| Test Parallelization | Testing on Mac / Testing on Simulator | pop-ups: Automatic (default), Off | Passed to the test runner (stored until R36) |
| Report Navigator | Local report history | pop-up: Up to 10 / 20 / 50 / 100 Reports; default Up to 20 | Prunes older reports |
| Settings Import & Export | Export…, Import… | buttons | Writes / reads Ycode's user settings as one JSON file ("Keep a copy in iCloud" is left out) |
| Reset Ycode | Reset Settings: Reset…; "Don't ask me" warnings: Reset All | buttons | Clears Ycode's user defaults / suppression flags after a confirmation |

### 9.2 Navigation

This replaces Ycode's "Activation" and "Navigation Style" rows.

| Row | Default | Effect |
|---|---|---|
| New Editor Tabs Open With | Start Page | File ▸ New ▸ Tab shows the Start Page. The other option is "Same Document" (the current file). |
| New Editor Panes Open With | Same Document | A new editor pane shows the focused pane's file. The other option is Start Page. |
| Pin Editor Tabs | Manually | Tabs pin only with ⇧⌘P (`reference-ui-2.md` §8). The other option, Automatically, pins a tab when its document is edited. |
| Click on Code: With Option | Shows Quick Help | Existing ⌥-click |
| Click on Code: With Command | Jumps to Definition | Existing ⌘-click |
| Click on Code: With Command & Control | Jumps to Definition | ⌃⌘-click does the same |
| Navigation: Destination | Focused Editor Pane | Navigator clicks open in the focused pane |
| Navigation: With Option | Uses New Unpinned Tab | ⌥-click in a navigator opens the file in a new tab |
| Navigation: With Option & Shift | Uses Next Editor Pane | ⌥⇧-click opens it in the next pane, creating one |
| Navigation: With Double-click | Same as Click | — |
| Use Window Tabs In Full Screen | on | (stored) |
| Animate Open Quickly With Multiple Editor Panes | on | (stored) |

### 9.3 Editing

**Main page:** Ycode's current rows, plus:

- "Convert existing files on save" (off): when on, saving converts the
  file to the default encoding and line endings;
- Localized Strings: "Automatically generate string catalog comments" (on,
  stored).

**Display page**, in order, with defaults:

1. Line numbers (on)
2. Code folding ribbon (off)
3. Code structure headers (on): the sticky header showing the enclosing
   declaration while scrolling
4. MARK separators (on): a line above `// MARK: -`
5. Code coverage iteration counts (on, stored)
6. Condition on #endif lines (on): shows the `#if` condition after
   `#endif`
7. Scope guides: pop-up None (default)
8. Reformat code at column: 80, used by Reformat To Width and the guide
9. Show reformatting guide (off): the page guide at that column. It
   replaces Ycode's "Page guide at column"
10. Automatically reformat when completing (off, stored)
11. Dim inactive code (on): inactive `#if` branches drawn dimmed
12. Highlight instances of selected symbol (on) and Highlighting delay
    (0.25)
13. Editor overscroll: pop-up None / Small / Medium (default) / Large, the
    blank space after the last line
14. Line Wrapping: Wrap lines to editor width (on); Indent wrapped lines
    (4 spaces)
15. Documentation Comments: Fade delimiters (on); Fade comment delimiters
    (on)

The minimap is **not** a Display row; it is the Editor ▸ Minimap toggle
(⌃⇧⌘M), saved as a user setting.

### 9.4 Appearance and Behaviors (S5, S6)

**Appearance.**

- Three thumbnails, System, Light and Dark, replace the segmented
  control.
- A live code preview follows them.
- Theme: a "Choose…" button and the theme name, then one color row per
  token kind (Plain Text, Comments, Documentation Comments, … in Ycode's
  token set).
- Fonts: one font row per token kind.

**Behaviors.**

- Add the categories Intelligence (empty: the coding assistant has no
  behavior events yet) and Playgrounds.
- Action labels read "Navigator: <name>", "Debugger: Show Current Views",
  "Debugger: Hide Debugger If No Output", "Notify with bezel or system
  notification".
- Each event group can be collapsed.

## 10. Breakpoint persistence (L6) and the Debug menu (M19)

### 10.1 Storage

Breakpoints are saved per user with the container and reloaded when it
opens.

**Location.**

- Projects:
  `<project>.xcodeproj/xcuserdata/<user>.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist`.
- Workspaces: the same path under `<workspace>.xcworkspace/`.
- Packages: `.swiftpm/xcode/xcuserdata/<user>.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist`.

**Format** (observed in a file the reference wrote; level 2):

- XML in the reference's attribute-per-line style (`specs/formats/xcode-xml.md`).
- Root element `Bucket` with `uuid` (an uppercase UUID), `type = "1"` and
  `version = "2.0"`.
- Inside it, `Breakpoints`, holding one `BreakpointProxy` per breakpoint.

**A line breakpoint** is a `BreakpointProxy` with `BreakpointExtensionID =
"Xcode.Breakpoint.FileBreakpoint"`. It contains one `BreakpointContent`
with these attributes, in this order:

| Attribute | Value |
|---|---|
| `uuid` | uppercase UUID |
| `shouldBeEnabled` | `Yes` / `No` |
| `ignoreCount` | decimal |
| `continueAfterRunningActions` | `Yes` / `No` |
| `filePath` | relative to the container's folder |
| `startingColumnNumber`, `endingColumnNumber` | `9223372036854775807` when the breakpoint has no column |
| `startingLineNumber`, `endingLineNumber` | the line |
| `landmarkName` | the enclosing declaration's name ("area()") |
| `landmarkType` | `7` for a function or method; the only value seen |

**Rules.**

- Ycode reads and writes this file.
- It writes `landmarkName` and `landmarkType` only for function and method
  landmarks.
- Elements and attributes it does not understand (other breakpoint kinds,
  conditions, actions) are kept unchanged on rewrite.
- Ycode's own kinds without an observed encoding (symbolic, exception,
  Swift error, test failure) and conditions and actions are stored in
  `ycode-breakpoints.json` next to the bookmarks file until their encoding
  is observed.
- The file is rewritten only when the breakpoint set changes.

**Acceptance.**

- Set a breakpoint, quit, reopen: it is there.
- Opening the project in the reference shows the line breakpoint Ycode
  saved (manual check).

### 10.2 Debug menu commands

The §2.10 items work as follows:

- **Enable / Disable Breakpoints at Current Line** toggles them.
- **Create Column Breakpoint** adds a breakpoint at the caret's column. In
  DAP that is a `SourceBreakpoint` with `column`.
- **Delete All Breakpoints** asks for confirmation, then removes every
  breakpoint.
- **Create Test Failure Breakpoint** adds an exception-filter breakpoint
  for test failures when the adapter offers one; otherwise it is disabled.
- **Continue To Current Line** sends a temporary breakpoint at the caret's
  line, then `continue`.
- **Step Over / Into Instruction** use `granularity: "instruction"`.
- **Step … Thread** steps only the selected thread (`singleThread: true`).
- **Reload Console** re-renders the console with the current metadata
  options.
- **Select Last Output** selects the last output paragraph.
- **Jump To Source** opens the source location of the selected console row
  when it has one.

## 11. Other areas

### 11.1 Project editor (P1–P6)

1. The Build Settings tab opens with **Basic** selected (`reference-ui-3.md`
   §1.8). Ycode opens on Customized today.
2. The left column has a footer: "+" (add a target, opening the target
   template sheet), "−" (delete the selected target after a confirmation)
   and a Filter. It also has a collapse button at its top.
3. Resource Tags, Build Rules, Project ▸ Info and Package Dependencies use
   real controls (segmented scopes, tables with +/−, buttons, pop-ups) as
   `reference-ui-3.md` §1.6 and §1.10–§1.12 describe. Today they are plain
   text.
4. Build Phases:
   - the "Run Build Tool Plug-ins" phase row appears after Target
     Dependencies, even when it is empty;
   - there is no configuration pop-up on this tab.
5. Info: generated keys (`INFOPLIST_KEY_*`) show readable names, the same
   names as file keys. Containers expand. Build-setting values show as
   `$(…)`.
6. General: +/− of Supported Destinations add and remove destinations by
   writing the settings named in `reference-ui-3.md` §1.4.1. Minimum
   Deployments "+" adds a platform row. The "+" / "→" buttons of Identity
   rows add the key to Info, or reveal the setting in Build Settings.

### 11.2 Catalogs and plists (P7, P8)

- Asset catalog folders are rows of their own, with their sets as
  children. All "+" items can be created.
- The plist editor keeps the key order of binary property lists too.

### 11.3 Templates, schemes, reports (P10–P12)

- Choose Template… opens a real empty workspace window behind the sheet.
- Every template in the grid creates its documented content. The minimum
  is a non-empty, buildable file for each Source template.
- The save sheet's Group pop-up lists the project's groups. The Targets
  list checks the target of the selected file.
- Scheme editor:
  - the Build targets table and the Test plans table have +/− footers and
    a filter;
  - "No Arguments" and "No Environment Variables" empty states;
  - the Test plan rows' subtitle and go-to arrow.
- Test report: every filter pop-up of the Tests page works, and Coverage
  rows expand from target to files.

### 11.4 Destinations (P9; supersedes the ordering in `reference-ui-3.md` §4)

1. **Simulators are ordered:**
   - by runtime version, newest first;
   - within a runtime, iPhone devices, then iPad, then Apple Vision;
   - each group by name in localized standard order ("iPhone 17", "iPhone
     17 Pro", "iPhone 17 Pro Max", "iPhone 17e", "iPhone 18 Pro", "iPhone
     Air").
2. **Apple Vision** rows for an iOS app read "Apple Vision Pro (Designed
   for iPad, <runtime version>)".
3. **Hidden versions.** Simulators whose runtime is below the deployment
   target are not in Simulators. They are in Incompatible ▸.
4. **Incompatible ▸ rows** read "<name> (<reason>) <OS version>", with
   reasons "mismatched platform" and "OS version lower than deployment
   target". When the same name exists for several runtimes, "(<runtime>)"
   comes before the reason.
5. **Show All Run Destinations** (Product ▸ Destination) opens the
   destination menu with Incompatible expanded.

### 11.5 Ycode's remote simulator destination (R1, R2)

- The remote "Ycode Simulator" device is listed in the **Simulators**
  section, not in a section of its own. Its row reads "<device name>
  <runtime version>" and sorts with the newest runtime.
- Ycode's three-step activity text stays until the reference's simulator
  run strings are observed (§12, item 12). Then it adopts them, keeping a
  step counter only if the reference has one. *Pass 6: observed; the
  reference has no counter. See `reference-ui-6.md` §3.3.*

### 11.6 Smaller items

- Issue capsule project checks (T8): "Signing for "<target>" requires a
  development team." and "Update to recommended settings" are
  project-level warnings, shown directly under the root of the Issue
  navigator and counted in the capsule. The second is offered when the
  project's settings differ from the recommended set. That set is
  build-system work, out of scope until specified.
- Preview builds set the activity text "Preparing <family> Simulator"
  (P15).
- Debug navigator: process-row buttons, the Energy Impact bar, and the
  third bottom toggle as in §5.2 (D3).
- Interface Builder inspector leftovers (P14), as in `reference-ui-4.md`
  §13.
- Commit inspector Files rows carry file icons (P16).

## 12. Still to observe live

These steps are for the observer, not the implementer:

- context menus;
- the toolbar and jump-bar pull-down contents (Add Editor, Editor Options,
  Related Items, ⌃4–⌃6, Issues, branch, the navigators' "+" / "…" and
  filter-options menus, the Welcome window's New Project);
- the Settings panes Notifications, Shortcuts, Source Control,
  Components, Locations, Editing ▸ Completion and Editing ▸ Indentation,
  and the alternative values of every pop-up in §9;
- Open Quickly and Show Quick Actions… layout and ranking;
- the Start Page and the editor at first open (§3.5);
- the Library;
- the find bar;
- the completion popup;
- Edit ▸ Copy / Paste variants and the Debug, Find and Navigate
  candidate alternates;
- a simulator run's activity strings;
- the all-pass test result text;
- ⌘0 when the coding assistant is shown;
- the project editor's Editor menu;
- Help ▸ Keyboard Hints;
- Copy File and Line's exact text.

The exact steps are in the audit notes, §5.

## 13. Deliberate deviations (not gaps)

- **Coding assistant (updated 2026-10-27).** Ycode now has one
  (`coding-assistant.md`): the toolbar segment, ⌘0, the New Conversation
  button, File ▸ New ▸ Conversation, Navigate ▸ Jump to Next Active
  Conversation and Editor ▸ Show Coding Tools ▸ Explain / Document /
  Generate a Playground / Generate a Preview work. The deviations that
  remain:
  - the transcript is in the left area with the conversation list, not in
    the editor area; Conversation in New Tab and Conversation in Editor
    Pane stay disabled;
  - Show Coding Tools… ⌥⌘0 shows the code actions, not a prompt popover;
  - no conversation groups, history slider, `@` references, issue
    "Generate Fix" button, reasoning pop-up, MCP tools or ACP agents;
  - changes are always proposed and reviewed; agent tools run read-only;
  - the settings pane is "Coding Assistant", with Ycode's own rows
    (`coding-assistant.md` §6), not "Intelligence".
- Ycode has no cloud CI service. Its menu items are present and disabled.
- Apple service names are not used. The Settings pane is "Accounts", not
  "Apple Accounts". The Integrate section label is "Cloud". The Help menu
  leaves out the service help items. The application is named Ycode
  everywhere the reference says Xcode ("Welcome to Ycode", "Ycode Help",
  "Quit Ycode").
- Settings ▸ Simulators (Ycode's remote simulator) stays, before
  Locations.

## Evidence

| Claim | Level | Source |
|---|---|---|
| §1 conventions, alternates marked "seen" | 3 | Visible menus in passes 2–4 (`reference-ui-2.md` §7.8, §8; `reference-ui-3.md` §5.1) together with this pass's accessibility listing, which lists alternates as items |
| §2 menu items, order, separators, shortcuts, dynamic titles, Editor menus per editor | 3 | The reference's menu bar read through the accessibility API (titles, key equivalents, modifier masks, marks, enabled state), 2026-10-19, in two states (no workspace; source editor and five other editors focused). The user's key-binding set was empty, so the shortcuts are factory defaults. No menu item was pressed. |
| "inferred" alternates (§2.6), Debug Instruction/Thread variants (§2.10) | — | Inference from the item titles and AppKit's alternate rule; to confirm (§12) |
| §3.1 Welcome window layout and size | 3 | Accessibility tree and screenshot of the reference's Welcome window |
| §3.1 New Project pull-down contents, lifetime rule | 3 / — | Lifetime partly observed (it stayed open after `open`); the pull-down contents are inferred from `reference-ui-3.md` §5.4 |
| §3.2 Open Recent titles, disambiguation, Clear Menu | 3 | Menu listing with two same-named projects |
| §3.3–§3.4 frame, window title | 3 | Window accessibility title and Window-menu entries |
| §4.1–§4.3 toolbar control kinds, exclusivity, tooltips | 3 | Accessibility tree, and background clicks on the segments with the resulting state read back |
| §4.3.5 default destination rule | 3 / — | The reference chose an iOS simulator for an iOS app with no user data; the ordered rule is Ycode's design |
| §5.1 Products hidden, expansion, letters on files only | 3 | Project navigator accessibility tree of a fresh copy; the `productRefGroup` is in the file (level 2) |
| §5.1 Hide All is the factory default | 3 | The setting showed Hide All while the user's preferences hold no file-extension key (only key names were checked) |
| §5.2 per-navigator bars, tooltips, defaults, empty states | 3 | Accessibility tree and screenshots of each navigator, opened by clicking its selector tab |
| §5.2 toggle behaviors | — | Ycode's reading of the tooltip texts |
| §5.3.1 fileless issues at the root | 3 | Issue navigator tree with the project-level issue |
| §5.3.2 stale-issue replacement on the next build | 3 / — | `reference-ui-2.md` §1.5 observation; the per-file rule is Ycode's reading |
| §5.4 "In Project" | 3 | Find navigator scope pop-up |
| §6.1–§6.2 jump bar and debug bar order, tooltips | 3 | Accessibility tree with a Swift file and a plist open, and the assistant split |
| §6.2 branch menu behavior, §7.4 history row selection, §3.1 New Project pull-down use | — | Ycode's design; the menu contents are to observe |
| §2.10 "Load Symbols… (shown while debugging)", §2.11 "Create Pull Request… when the repository has a remote" | — | Inferred: present in the no-workspace listing, absent in the project listing |
| §6.1.3 ⌃1–⌃6 open the jump-bar menus | 3 / — | Item titles and shortcuts observed; the mapping to components follows the titles |
| §6.3 change gutter | 3 | The gutter's accessibility elements (column, bar description, tooltip) with an unstaged modification; refresh timing and click action are Ycode's design |
| §6.4 command behaviors | 1 / — | Multiple insertion points and column selection: Xcode 10's public release notes; Swift Markup doc comments: public documentation; swift-format: open-source tool; the rest is Ycode's reading of the titles |
| §6.5 minimap width | 3 | Minimap frames in three editor widths |
| §7 inspector sections, tooltips, history rows, Quick Help empty state | 3 | Accessibility tree of each inspector tab |
| §8 debug area bars | 3 | Accessibility tree with the debug area shown while idle |
| §9 rows and defaults | 3 | `reference-ui.md` §4; alternative pop-up values not observed |
| §9 effects | — | Ycode's design from the row titles and their explanations |
| §10.1 breakpoint file path and format | 2 | A `Breakpoints_v2.xcbkptlist` the reference wrote for our sample package, studied as a file format |
| §10.1 storage rules for unobserved kinds | — | Ycode's design |
| §10.2 DAP mappings | 1 | Debug Adapter Protocol specification (`singleThread`, `granularity`, `column`) |
| §11.4 ordering, Vision titles, Incompatible reasons | 3 | Product ▸ Destination submenu listing |
| §11.1–§11.3, §11.5–§11.6 | 3 / — | Earlier passes' observations restated as requirements, plus Ycode's design where marked |
| §0 plan, priorities, file lists | — | Audit of Ycode at aa1bf7c (source and a running debug build) against this and the earlier specs |
