# Parity audit: Ycode against Xcode 27.1 and its developer tools

> This is a working audit, started on 2026-10-30 and updated as gaps closed. For what
> works today, read the [README](../README.md#what-works-today) first. Names in capitals
> (PIF-PKG, NAV-OPS, ...) are the development rounds that did the work, and their dates
> are when each round landed. "The reference" means Xcode 27.1 and its simulator.

This audit answers four questions:

1. What do Xcode's other developer tools do, and which of them does Ycode
   have? The tools include Icon Composer, SF Symbols, Accessibility
   Inspector, FileMerge and Create ML.
2. Which Xcode features are not implemented yet?
3. What does the simulator cover on each platform?
4. Does the IDE work on Linux, and what would make it look and behave as it
   does on macOS?

Short answers:

- **The full IDE is macOS only.** `YcodeUI`, `YcodeDeviceUI` and `YcodeApp` are
  added to the package only under `#if os(macOS)` (`ycode/Package.swift`). On
  Linux, `ycode-ide` is a smaller window on the same model: browse, search,
  build and run, and edit and save files (§5.8, §5.9, §5.10).
- **On Linux, Ycode also has command-line tools:**
  - `ycode`: describe, settings, round trip, PIF, profile, preview list.
  - `ycodebuild`: the `xcodebuild` grammar.
  - `ycode-simd`: the simulator. It runs on arm64 Linux with KVM only.
  - `ycode-scene`: the Scene Composer core.
- **The Linux IDE.** Milestones L0 and L1 are done. L2, editing, has its first
  part: editing and safe saving, find and replace, Jump to Line, build issues
  in the editor, live issues from sourcekit-lsp, a Settings window (§5.9,
  "Done in L2"), code completion on request.
- **The biggest gaps** for a developer on either OS:
  - Projects that use Swift packages do not build: package products are
    dropped from the PIF. *(Closed by PIF-PKG, 2026-10-30: package
    products, resources, macros and build-tool plug-ins are in the PIF;
    `specs/ide/build-pif.md` §Package products, macros and plug-ins.)*
  - sourcekit-lsp has no build context for `.xcodeproj` targets.
  - No debugger attaches to apps on the Ycode simulator.
  - ~~App-hosted tests and UI tests do not run under `ycodebuild`.~~
    Closed for app-hosted tests by TEST-HOST (2026-10-30): on this Mac and
    on the Ycode simulator, through ycodebuild and ⌘U (§2.6). UI tests run
    only as far as they do not drive an app.
  - ~~The editor does not auto-indent.~~ Closed by EDITOR-TYPING
    (2026-10-30): typing rules and `YcodeSyntax` (§2.2).
  - ~~The project navigator cannot add or delete files.~~ Done by NAV-OPS
    (2026-10-30): §2.1 and §6 gap #6.

  The ranked list is in §6.

---

## 1. Method

### 1.1 What was compared

| Side | Source |
|---|---|
| Xcode 27.1 behavior | The clean-room specs (`specs/ide/`, `specs/xcodebuild/`, `specs/build-settings.md`, `specs/formats/`, `specs/simulator/`, `specs/macos/`, `specs/tools/`, `specs/frameworks/`), including the UI observations `specs/ide/reference-ui*.md`. Apple's public pages: the Xcode 27 and 27.2 release notes, the Icon Composer and SF Symbols product pages, and the Xcode resources page. |
| Ycode status | **The code**, not only the specs: `ycode/Sources/`, `ycode/Tools/`, `ycode/scripts/`, `frameworks/`, `composer/`. Also `docs/` and the specs' own status sections. |

Clean-room rules for this audit:

- I did not open `research/`, the reference tools, Ghidra, or any Apple app
  bundle.
- I ran no Apple app.
- Nothing was built or run. The audit used grep, file reads and line
  counts only.

### 1.2 How a status is decided

| Status | Meaning |
|---|---|
| **done** | Works end to end for the common case. The code path was located, and the spec's own status (or its tests) says it works. |
| **partial** | Some of the workflow works. The cell says what is missing. |
| **missing** | No code. This includes a menu item or button that is disabled or only shows an alert. |
| n.a. | Does not apply to that platform or tool. |

**How disabled menu items were found.**
- `CommandTable.u(...)` (`YcodeUI/Model/CommandTable.swift` around L198)
  gives an item the action `ycodeUnavailable<Title>:`. Nothing implements
  that action, so AppKit shows the item disabled.
- About 190 items in `CommandTable.swift` and `EditorMenu.swift` are built
  this way. They count as **missing**.
- Controls with a `noAction` target count as missing too. An example is the
  General tab's Frameworks +/− in `YcodeUI/Project/ProjectEditorTabs.swift`.

**How the key P0 claims were re-checked.** I read the code for each one:
- `YcodeXcodebuild/XcodePIF.swift` returns `nil` for package-product build
  files ("package products are not expressed yet").
- `YcodeUI/Session/RemoteRun.swift` says no debugger attaches to a remote
  run.
- `SourceTextView` (`YcodeUI/Editor/SourceEditorController.swift`) has no
  newline or indent handling. It overrides only `insertTab`. (Closed since by EDITOR-TYPING: Return,
  typed characters, Tab, Shift-Tab and Delete Backward go through the
  typing rules.)
- `YcodeBuild/SwiftBuildEngine.swift` `baseOverrides` signs ad hoc and
  drops entitlements. (Fixed by SIGNING, 2026-10-30: IDE builds go
  through `ycode-swb` and keep them; `specs/ide/signing.md`.)

### 1.3 Columns

- **Code** paths are relative to `ycode/Sources/` unless they start with a
  top-level folder.
- **macOS IDE / Linux CLI / Linux IDE** says where the feature works today.
  The Linux IDE column is "no" everywhere, because no Linux IDE exists yet.
  Read it as "what the Linux IDE must reach".
- **Effort** to finish the feature:

  | Effort | Size |
  |---|---|
  | S | Under a day, or under about 500 lines |
  | M | One agent round |
  | L | Two or three rounds |
  | XL | A new subsystem, or several rounds plus a dirty-room spec |

- **Priority:**

  | Priority | Meaning |
  |---|---|
  | P0 | Blocks common real projects |
  | P1 | Expected in daily use |
  | P2 | Useful |
  | P3 | Niche, or far off |

### 1.4 Evidence levels used

These follow `AGENTS.md` rule 4:

| Level | Source | What it supports here |
|---|---|---|
| 1 | Apple's public documentation and release notes | Xcode 27.1 behavior, the tool lists, Icon Composer, the SF Symbols terms |
| 2 | File formats | Statements about `.icon`, `Assets.car`, `.mlmodelc` and `.xcproj` |
| 3 | Black-box behavior | Measurements quoted from the specs' status sections |
| 4–5 | Binary metadata, disassembly | Not used by this audit. Some cited specs rest on them, and they say so in their own Evidence sections. |

---

## 2. Xcode feature matrix

### 2.1 Workspace and projects

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Open `.xcodeproj` | Navigator, editors, schemes | done | `specs/formats/pbxproj.md`, `specs/ide/workspace-window.md` | `YcodeProject/PBXProj.swift`, `YcodeUI/Model/WorkspaceModel.swift` | yes / yes (`ycode describe`, `ycodebuild -list`) / no | – | P3 — works |
| Open `.xcworkspace` | Several projects, shared schemes | done | `specs/formats/xcode-xml.md` | `YcodeWorkspace/Workspace.swift`, `Scheme.swift` | yes / yes / no | – | P3 — works |
| Open a package folder | `Package.swift` opened as a workspace | done | `specs/xcodebuild/packages.md` | `WorkspaceModel` `.package`, `YcodeXcodebuild/SwiftPackages.swift` | yes / yes / no | – | P3 — works |
| pbxproj round trip | Lossless, Xcode-identical output | done | `specs/formats/pbxproj.md`, `openstep-plist.md` | `YcodeProject/PBXProjWriter.swift`; `ycode roundtrip` | yes / yes / no | – | P3 — byte-identical on the corpus |
| App skills (`.skillsbundle`) | **Siri AI Developer Preview**: one bundle per target of `SKILL.md` files that guide Siri across several tool intents; validated and compiled at build time | missing (planned for Ycode 2) | `specs/formats/skills-bundle.md` | – | no / no / no | M | P2 — new in the preview; the API may change. |
| JSON project format `.xcproj` | **Xcode 27.2**: opt-in JSON project file, readable by 27.x | missing | – | – | no / no / no | M | P2 — the reference is 27.1; needed once 27.2 projects arrive. Format spec needed (level 2). |
| Typed mutations | Add or remove files, targets, packages, settings | done (library) | `specs/ide/project-editor.md` | `YcodeProject/Mutations.swift`, `TargetMutations.swift`, `PackageDependencies.swift` | yes / no command / no | S | P2 — Linux users need a CLI or API |
| Navigator file operations | Add Files, groups, delete, drag, sort, convert | done (NAV-OPS): New File into the selected group, the four Group items, Folder and Folder from Selection, Add Files… (copy, move or reference; groups, folder references or synchronized folders; targets), Delete (to the Trash or the reference only), inline rename, drag and drop (and from the Finder), Sort, Convert ▸ To Group / To Folder / Preflight, Cut and Paste ▸ Move Item Here, a row context menu; each undoable, exception sets kept for synchronized folders, git staging. Missing: nothing in this row (the reference's context menu is still to observe). | `specs/ide/navigators.md` §Ycode implementation | `YcodeIDECore/Navigator/ProjectFileOperations*.swift`, `ProjectGraphEdits.swift`; `YcodeUI/Navigator/NavigatorAreaController+ProjectOps.swift`, `Window/WorkspaceWindowController+ProjectNavigatorOps.swift` | yes (model, portable) / – / no | S | P3 |
| Target membership | File inspector checkboxes | done (includes synchronized exception sets) | `specs/ide/reference-ui-5.md` §7.3 | `YcodeUI/Model/TargetMembership.swift` | yes / – / no | – | P3 |
| Folder references | Blue folder copied as a unit | partial: shown as a leaf, not expandable | `specs/formats/pbxproj.md` | `YcodeUI/Model/NavigatorTree.swift`, `XcodePIF.swift` | partial / yes (build) / no | S | P3 |
| Synchronized (buildable) folders | Disk-backed groups with exception sets | done (IDE-SMALL): one model (`SynchronizedFolder`) for the PIF, the build server, the navigator and Target Membership. Builds take sources, resources, headers (public/private), linked frameworks and copy-phase members from the folders, with membership exceptions (folders too; inclusion for targets that do not list the folder), `/Localized:` items as variant groups, per-file compiler flags, attributes and platform filters, `explicitFileTypes` and `explicitFolders`; missing phases are added. A target with synchronized folders but no compiled source, or a missing folder, warns. The legacy `PIFGenerator` rejects them (it used to build such a target with no files and succeed). Open: the reference's per-type default phases and its report for such targets (dirty room). | `specs/ide/build-pif.md` §Synchronized folders, `specs/formats/pbxproj.md` §Synchronized folders | `YcodeProject/SynchronizedFolders.swift`, `XcodePIF.swift`, `YcodeBuildServer/BuildGraph.swift`, `YcodeIDECore/Model/NavigatorTree.swift`, `TargetMembership.swift`; sample `Samples/SyncFolderSamples` | yes / yes / no | – | P2 — the default in new projects |
| Project editor: General | Identity, destinations, frameworks and embedding, intents | partial: the Frameworks +/−, Embed pop-up and Supported Intents +/− do nothing | `specs/ide/project-editor.md`, `reference-ui-3.md` §1.4 | `YcodeUI/Project/ProjectEditorTabs.swift` (`noAction`), `ProjectEditorGeneral.swift` | partial / – / no | M | P1 — you cannot link a framework or package from the UI |
| Project editor: Signing & Capabilities | Team, profiles, ~50 capabilities | partial: writes `CODE_SIGN_STYLE` and `DEVELOPMENT_TEAM`. Only 6 macOS sandbox capabilities. | `specs/ide/project-editor.md` | `YcodeUI/Project/Capabilities.swift`, `CapabilityLibraryController.swift` | partial / – / no | L | P1 — capabilities drive entitlements |
| Project editor: Info | Editable Info.plist and generated keys | partial: read only | `specs/ide/project-editor.md` | `ProjectEditorTabs.swift` `infoView` | partial / – / no | M | P2 |
| Project editor: Build Settings | Basic/All, Combined/Levels, edit | done (includes the Defaults level from swift-build) | `specs/ide/project-editor.md`, `specs/build-settings.md` | `ProjectEditorTabs.swift`, `YcodeUI/Project/DefaultsLevel.swift` | yes / yes (`ycode settings`, `-showBuildSettings`) / no | – | P3 — 111,310 of 111,310 values match |
| Project editor: Build Phases | Phases, files, scripts, plug-ins | partial: the "Run Build Tool Plug-ins" row is display only | `specs/ide/project-editor.md` | `ProjectEditorTabs.swift`, `ProjectEditorModel.swift` | partial / – / no | S | P2 |
| Project editor: Build Rules, Resource Tags, Info (project) | Custom rules, ODR tags, configurations, localizations | done | `specs/ide/reference-ui-3.md` §1.6, §1.10, §1.11 | `YcodeUI/Project/ProjectEditorControls.swift` | yes / – / no | – | P3 |
| Package Dependencies tab | List, add, remove, edit rule | partial: add and remove only | `specs/ide/package-dependencies.md` | `ProjectEditorControls.swift`, `ProjectEditorController.swift` | partial / – / no | S | P2 |
| Add package | Collection search, URL, rule, products | partial: URL or local path and a rule. No collection search. | `specs/ide/package-dependencies.md` | `YcodeUI/Project/AddPackageController.swift` | partial / – / no | M | P2 |
| Resolve packages | Graph resolution, `Package.resolved` | done | `specs/xcodebuild/packages.md` | `YcodeBuild/PackageResolver.swift`, `YcodeXcodebuild/ResolvePackages.swift` | yes / yes / no | – | P3 |
| Update packages, reset caches | File ▸ Packages | missing (u()) | `specs/ide/package-dependencies.md` | `CommandTable.swift` | no / no / no | S | P2 |
| Local packages | Local reference, edit in place | partial: the reference can be added; its products build through swift-build (PIF-PKG). Edit in place is not done. | `specs/ide/package-dependencies.md` | `YcodeProject/PackageDependencies.swift` | partial / partial / no | M | P1 — follows from the package-product gap |
| Multiplatform targets | One target, many destinations, platform filters | partial: destinations are written; platform filters are always empty | `specs/ide/reference-ui-3.md` §1.4.1 | `ProjectEditorGeneral.swift`; `XcodePIF.swift` (`platformFilters: []`) | partial / partial / no | M | P2 |
| Scheme editor | All actions, diagnostics, pre/post actions | partial: targets, arguments, environment, working directory, configurations, Shared and the sanitizers of Diagnostics (IDE-QUICKWINS) work. The other Diagnostics rows, Instrument and archive options are disabled. Pre/post actions are display only. | `specs/ide/schemes.md`, `reference-ui-2.md` §7 | `YcodeUI/Schemes/SchemeEditorController.swift`, `YcodeWorkspace/SchemeEditing.swift` | partial / yes (scheme I/O) / no | M | P1 — no sanitizers, no pre/post scripts |
| New Scheme, Duplicate Scheme | Product ▸ Scheme | missing (u()) | `specs/ide/schemes.md` | `CommandTable.swift` | no / – / no | S | P2 |
| xcconfig | Includes, levels, conditions | done (resolution). No syntax coloring. | `specs/build-settings.md` | `YcodeSettings/XCConfig.swift`, `MacroExpression.swift` | yes / yes / no | – | P3 |
| New project templates | About 30 templates across platforms | done (NEW-PROJECT): the catalog of `templates.md` — 8 tabs, 52 New Project templates and the Package… chooser's 7 — with every option, rule and memory; 50 creatable (Foveated Streaming App and Spatial Rendering App are listed, not creatable; Objective-C in some app templates and Metal 4 are drawn disabled). Every creatable template builds on the Mac (`ycode/scripts/new-project-matrix.sh`; Metal shaders and dynamic libraries through xcodebuild until swbuild finds the downloadable Metal toolchain and signs dylibs). AppKit sheet, Linux shell sheet (no compact picker), `ycode new` | `specs/ide/templates.md` §Ycode implementation | `YcodeIDECore/Model/NewProject/`, `YcodeUI/Window/NewProjectSheet.swift`, `YcodeIDEShell/NewProjectShellModel.swift`, `ycode-ide/NewProjectSheet.swift` | yes / yes / yes | – | P3 |
| New file templates | About 60 templates | done for 40. `.icon`, SceneKit, GameKit and Mapping Model produce an empty folder. | `specs/ide/templates.md` | `YcodeUI/Model/TemplateContents.swift` | yes / no / no | M | P3 |
| New target templates | Apps, extensions, widgets, tests, frameworks | partial: App, CLT, unit and UI tests, Framework and Static Library, for iOS and macOS only. File ▸ New ▸ Target… is u(). | `specs/ide/templates.md` | `YcodeUI/Model/TargetTemplates.swift` | partial / no / no | L | P1 — no extensions or widgets |
| New workspace, Save As Workspace | Create a `.xcworkspace` | missing (u()) | `specs/ide/menus.md` | `CommandTable.swift` | no / no / no | S | P2 |

### 2.2 Source editor and language

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Text system | TextKit 2 source view | done | `specs/ide/source-editor.md` | `YcodeUI/Editor/SourceEditorController.swift` (`SourceTextView`, `NSTextLayoutManager`) | yes / – / no | – | P3 (the Linux editor is §5.3) |
| Auto-indent and bracket pairing while typing | Return re-indents; braces close | done (EDITOR-TYPING): Return indents from the structure model and splits bracket pairs; closers, `case`, `default`, `#else` re-indent; brackets and quotes pair, closers are stepped over, a selection is enclosed; Tab / Shift-Tab per the Tab key setting; ⌘/ by language; Re-Indent from the structure. Settings ▸ Editing ▸ Indentation has the switches. | `specs/ide/source-editor.md` ("Ycode implementation") | `YcodeSyntax/TypingRules.swift`, `Indentation.swift`; `YcodeUI/Editor/SourceEditorController+Typing.swift` | yes / – / no (the rules are portable) | – | P3 |
| Syntax highlighting | Semantic coloring for many languages | partial: Swift through swift-syntax's parser (incremental), and Ycode's line lexers for C, C++, Objective-C, Metal, JSON, XML/plist, Markdown, YAML, shell and build configuration files, re-lexed incrementally per line. Missing: LSP semantic tokens. | `specs/ide/source-editor.md` ("Ycode implementation") | `YcodeSyntax/` (portable), `YcodeUI/Editor/Theme.swift` | yes / – / no (`YcodeSyntax` builds and tests on Linux) | S (semantic tokens) | P2 |
| Markdown editor | **Xcode 27**: rendered Markdown with formatting tools | missing (Show Markdown is u()) | – | `YcodeUI/Model/EditorMenu.swift` | no / – / no | M | P2 — agents produce Markdown |
| Code folding | Blocks, methods, comments | done (braces) | `specs/ide/source-editor.md` | `YcodeUI/Model/FoldRegions.swift` | yes / – / no | – | P3 |
| Minimap | With landmarks | done (source); the IB minimap is u() | `specs/ide/reference-ui-5.md` §6.5 | `SourceEditorController.swift` `MinimapView` | yes / – / no | – | P3 |
| Multiple cursors | Column select, Edit All in Scope, next occurrence | partial: Select Next/Previous Occurrence is u() | `specs/ide/source-editor.md` | `Window/WorkspaceWindowController+EditorCommands.swift` | partial / – / no | S | P2 |
| Code completion | Semantic completion, predictive model | partial: LSP completion works; predictive completion is done (PREDICT, see §2.9). Weak in projects (see the next row). | `specs/ide/language.md`, `specs/ide/predictive-completion.md` | `YcodeUI/Editor/CompletionPopup.swift`, `YcodeLanguage/LSPClient.swift`, `YcodeCompletion/` | partial / yes (`ycode complete`) / no | M | P1 |
| Build context for sourcekit-lsp in `.xcodeproj` | Index from real compiler arguments | partial (LSP-BSP, 2026-10-30): Ycode's build server `ycode-bsp` gives sourcekit-lsp targets, sources, Swift and clang arguments from the settings, module-only preparation and change notifications. Package products come from the build's PIF (imparted search paths and flags, built by swift-build at preparation; FIXES-1, 2026-10-31); the IDE does not follow scheme or destination changes. | `specs/ide/language.md` §Build server | `YcodeBuildServer/`, `YcodeLanguage/BuildServerLaunch.swift`, `YcodeUI/Session/LanguageSupport.swift` | partial / yes (`ycode-bsp`) / no | S | P1 — restart on scheme/destination change |
| Quick Help | ⌥-click popover and inspector | done (LSP hover) | `specs/ide/language.md` | `YcodeUI/Inspector/QuickHelpView.swift`, `Model/QuickHelpDocument.swift` | yes / – / no | – | P3 |
| Jump to Definition | ⌃⌘J, ⌘-click, tab and pane variants | partial: the main path works. The tab and pane variants and Jump to Last Destination are u(). | `specs/ide/language.md` | `CommandTable.swift` | partial / – / no | S | P2 |
| Live issues, fix-its | Inline diagnostics, Fix All | done for packages; partial for projects (no build context) | `specs/ide/language.md` | `LanguageSupport.swift`, `Window/WorkspaceWindowController+Refactoring.swift` | partial / – / no | M | P1 |
| Rename | Workspace-wide, including IB and strings | partial: LSP rename only | `specs/ide/refactoring.md` | `+Refactoring.swift`, `YcodeLanguage/LSPRefactoring.swift` | partial / – / no | M | P2 |
| Refactor menu | About 20 refactorings | partial: 13 map to sourcekit-lsp code actions; 7 have no mapping and stay disabled | `specs/ide/refactoring.md` | `YcodeUI/Model/RefactorCatalog.swift` | partial / – / no | L | P2 |
| Find references, call hierarchy | References, callers and callees | done | `specs/ide/refactoring.md` | `+Refactoring.swift`, `YcodeLanguage/LSPCallHierarchyOutgoing.swift` | yes / – / no | – | P3 |
| Type hierarchy | Ancestor, descendant and conforming types | done (FIND-REPLACE): `typeHierarchy/*` from the caret (Find menu) or by name (Find navigator kinds) | `specs/ide/navigators.md` ("Ycode implementation") | `YcodeIDECore/Find/SemanticFind.swift`, `YcodeLanguage/LSPFind.swift`, `+Find.swift` | yes / – / core only | – | P3 |
| Code actions | ⌥⌘0 | done | `specs/ide/coding-assistant.md` §5 | `+Refactoring.swift` | yes / – / no | – | P3 |
| Formatting | swift-format | done (runs the open-source swift-format) | `specs/ide/source-editor.md` | `YcodeUI/Model/SwiftFormatTool.swift` | yes / swift-format itself / no | – | P3 |
| Placeholders | `<#…#>` tokens | done | `specs/ide/source-editor.md` | `YcodeUI/Model/Placeholders.swift` | yes / – / no | – | P3 |
| Snippets | Library snippets, user snippets | partial: built-in snippets. Create Code Snippet… is u(). | `specs/ide/library.md` | `YcodeUI/Model/LibraryItems.swift` | partial / – / no | M | P2 |
| Macro expansion | Expand Macro inline | missing (u()) | `specs/ide/reference-ui-5.md` §2.7 | `EditorMenu.swift` | no / – / no | M | P2 |
| Vim mode, relative line numbers, invisibles, scope guides | Editor toggles | partial: Invisibles and Scope Guides done (EDITOR-TYPING; scope guides from the structure model). Vim mode and relative line numbers are u(). | `specs/ide/reference-ui-5.md` §2.7, `source-editor.md` ("Ycode implementation") | `EditorMenu.swift`, `YcodeUI/Editor/SourceEditorController+Guides.swift` | partial / – / no | M (Vim: L) | P2 |
| C, ObjC, C++ | clangd semantics, counterparts | partial: counterparts work. No compile database. | `specs/ide/language.md` | `YcodeLanguage/LSPClient.swift`, `YcodeUI/Model/Counterparts.swift` | partial / – / no | M | P2 |
| Metal shader editing | Coloring and help | partial: colored as Metal (keywords, vector, matrix and texture types, `[[attributes]]`); no help | `specs/ide/source-editor.md` | `YcodeSyntax/CFamilyLexer.swift` | partial / – / no | M | P3 |
| Plist and String Catalog editors | Structured editors | done | `specs/ide/plist-editor.md`, `string-catalog.md` | `YcodeUI/Editor/PlistEditorController.swift`, `StringCatalogEditorController.swift`; Linux: `YcodeIDEShell/PlistEditorModel.swift`, `StringCatalogEditorModel.swift`, `ycode-ide/PlistEditorView.swift`, `StringCatalogEditorView.swift` | yes / – / yes | – | P3 |
| Change bars, comparison | Gutter bars; side-by-side diff | done | `specs/ide/comparison.md`, `reference-ui-4.md` §15 | `YcodeUI/Editor/GutterView.swift`, `CodeReviewViews.swift` | yes / – / no | – | P3 |
| Blame (Authors, Show Last Change for Line) | Per-line authorship | done (SCM-BRANCHES): an Authors column per editor from `git blame --porcelain` (unsaved edits included), commit details on hover; Show Last Change for Line opens that commit in history | `specs/ide/source-control.md` ("Ycode implementation") | `YcodeIDECore/SourceControl/GitBlame.swift`, `YcodeUI/Editor/GutterView.swift`, `SourceEditorController+Authors.swift` | yes / – / core only | – | P3 |
| Coverage annotations | Coverage ribbon in the editor | missing (u()). `ycodebuild` already produces coverage. | `specs/xcodebuild/coverage.md` | `EditorMenu.swift`, `YcodeXcodebuild/Coverage.swift` | no / yes (data) / no | M | P2 |

### 2.3 Navigators and Find

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Project navigator | Tree, filter, file operations | done: tree, filter, multiple selection, context menu, file operations (§2.1). | `specs/ide/navigators.md` | `YcodeIDECore/Model/NavigatorTree.swift`, `Navigator/NavigatorAreaController.swift`, `NavigatorAreaController+ProjectOps.swift` | yes / – / no | – | P3 |
| Source Control navigator | Changes, repositories, branches | done (stage, commit, push/pull, stash, cherry-pick, clone) | `specs/ide/source-control.md` | `YcodeUI/SourceControl/*` | yes / – / no | – | P3 |
| Bookmarks | Line and file bookmarks | done | `specs/ide/navigators.md` | `YcodeUI/Session/Bookmarks.swift` | yes / – / no | – | P3 |
| Symbols | Jump bar and Open Quickly (no navigator in 27) | done (lexer symbols, not the index) | `specs/ide/navigators.md` | `YcodeUI/Model/WorkspaceIndex.swift` | yes / – / no | M (to use the index) | P3 |
| Find: text and regex | Word, prefix, suffix, case, scopes | done: parallel streamed engine, multi-line regex, folder references, `.gitignore`, binary skipping, unsaved buffers, count line, keyboard and Find Next/Previous in Workspace | `specs/ide/navigators.md` ("Ycode implementation") | `YcodeIDECore/Find/*`, `YcodeUI/Navigator/FindNavigator.swift` | yes / – / core only | – | P3 — 5,000 files in ~0.13 s |
| Find: replace across the project | Replace mode, Replace All | done (FIND-REPLACE): preview, per-match and per-file checkboxes, Replace and Replace All through open editors and the disk, one undo step for every file, stale-match check | `specs/ide/navigators.md` ("Ycode implementation") | `YcodeIDECore/Find/FindReplace.swift`, `FindNavigator.swift`, `+Find.swift` | yes / – / core only | – | P3 |
| Find: other kinds | Multiple Words, Symbols, Types, Call Hierarchy, Asset References; custom scopes | done except Asset References: Multiple Words; Symbols ▸ Definitions / References, Call Hierarchy and the three type kinds through sourcekit-lsp; Open Files and custom scopes with an editor | `specs/ide/navigators.md` ("Ycode implementation") | `YcodeIDECore/Find/*`, `FindScopeEditor.swift` | yes / – / core only | S (Asset References) | P3 |
| In-file Find and Replace | Find bar and its menu items | done: Find and Select Next/Previous, Replace and Find Previous, Use Selection for Replace, Select Next/Previous Occurrence wired (FIND-REPLACE) | `specs/ide/reference-ui-5.md` §2.5, `navigators.md` ("Ycode implementation") | `YcodeUI/Editor/FindBar.swift`, `SourceEditorController+FindCommands.swift` | yes / – / no | – | P3 |
| Issue navigator | Build and live issues, filters | done (no stale rows or filter tokens) | `specs/ide/navigators.md` | `YcodeUI/Navigator/IssueNavigatorModel.swift` | yes / – / no | S | P3 |
| Test navigator | Tests from the index | partial: lexical discovery | `specs/ide/testing.md` | `YcodeUI/Model/TestDiscovery.swift` | partial / yes / no | M | P2 |
| Debug navigator | Threads, frames, gauges | partial (gauges, below) | `specs/ide/debug.md` | `YcodeUI/Debug/DebugNavigatorRows.swift` | partial / – / no | M | P2 |
| Breakpoint navigator | Grouped breakpoints | done | `specs/ide/navigators.md` | `YcodeUI/Model/BreakpointList.swift` | yes / – / no | – | P3 |
| Report navigator, build log | Nested steps, timings, history | partial: a flat log with filters. No nested steps or durations. | `specs/ide/navigators.md`, `reference-ui-2.md` §4–6 | `YcodeUI/Model/ReportModel.swift`, `Window/ReportViews.swift` | partial / yes (xcresult) / no | M | P2 |
| Open Quickly | Fuzzy files and symbols | done | `specs/ide/open-quickly.md` | `YcodeUI/Navigator/OpenQuicklyController.swift` | yes / – / no | – | P3 |
| Reveal in navigator, focus movement | Navigate menu | missing (u()) | `specs/ide/reference-ui-5.md` §2.6 | `CommandTable.swift` | no / – / no | S | P3 |

### 2.4 Build system

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| PIF → swift-build | Native build service | done (package products since PIF-PKG) | `specs/ide/build-pif.md`, `build.md` | `YcodeBuild/SwiftBuildEngine.swift`, `YcodeXcodebuild/XcodePIF.swift` | yes / yes / no | – | P0 (see the next row) |
| **Package products in project targets** | Products of package dependencies link into app targets | **done (PIF-PKG, 2026-10-30)**: local and remote packages, static and dynamic products, resources, through SwiftPM's PIF of a generated root package. `XcodePIFSource.supports` is the fallback test. Was: `XcodePIF.swift` returned `nil` for them. | `specs/ide/build-pif.md` | `YcodeXcodebuild/XcodePIF.swift`, `PackageGraphPIF.swift`, `YcodeUI/App/SettingsWindow.swift` | yes / partial (PIF; no Apple SDK) / no | L | **P0** — most real apps use SwiftPM. This also blocks macros and build plug-ins. |
| xcodebuild fallback | – | done (macOS) | `specs/ide/settings.md` | `YcodeBuild/FallbackEngine.swift`, `XcodebuildEngine.swift` | yes / n.a. / n.a. | – | P3 |
| `ycodebuild` actions | xcodebuild's command line | done: build, analyze, clean, build-for-testing, test, archive, docbuild, export (ad hoc), localization export and import. Missing: xcframework, notarized export, `-find-*`, `-showBuildSettingsForIndex`. | `specs/xcodebuild/*.md` | `YcodeXcodebuild/Xcodebuild.swift`, `BuildActions.swift` | – / yes / – | M | P1 — 363 of 363 checks match on the corpus |
| Incremental and parallel builds | From the build service | done (swift-build) | `specs/xcodebuild/build-actions.md` | `BuildActions.swift` | yes / yes / no | – | P3 |
| Script phases, Info.plist generation, single-file actions | Run Script; `INFOPLIST_KEY_*`; Compile, Preprocess and Assemble File | done | `specs/ide/build-pif.md`, `build.md` | `XcodePIF.swift`, `YcodeBuild/FileActions.swift` | yes / yes (with an SDK) / no | – | P3 |
| Asset catalog compile (`actool`) | `Assets.car`, app icon files | partial: Ycode's own compiler, `ycode assets compile` (ICON-CAR): image sets (PNG), colour sets, app icon sets and `.icon` (flattened tier) → `Assets.car`, loose PNGs, `.icns`, partial `Info.plist`; AppKit loads its cars (images, colours, app icons). swift-build runs it for `actool` with `YCODE_ASSET_COMPILER=ycode` (default off macOS); on macOS Xcode's `actool` stays the default. Missing: the layered `.icon` tier, other set kinds, asset symbols, thinning. | `specs/formats/assets-car.md` §I, `specs/ide/asset-catalog.md` | `YcodeAssetCatalog`, `YcodeBuild/AssetCompilerHook.swift` | yes / yes / partial | L (rest) | P1 on Linux |
| Icon Composer `.icon` | Layered icon document compiled into the app icon | partial: read, validated, converted and written (`YcodeIcon`, every key, specializations, resolver, frames); compiled to the flattened tier with a placeholder render or pre-flattened PNGs. No glass renderer (ICON-RENDER), no layered tier, no viewer; the template still makes an empty folder. | `specs/formats/icon-format.md` §I, `icon-compile.md` | `YcodeIcon`, `YcodeAssetCatalog/IconFlatten.swift` | yes / yes / no | L | P2 — the default icon format since Xcode 26 |
| String Catalog compile | `.xcstrings` → `.strings`/`.stringsdict`; generated symbols | done (RES-STRINGS): Ycode's `ycode strings compile` (plurals, device variations, nested device-then-plural, substitutions, states, don't translate; `xcstringstool`'s command line, `--dry-run` included) and `generate-symbols`; swift-build runs them for `xcstringstool` with `YCODE_STRINGS_COMPILER=ycode` (default off macOS and when Xcode has no `xcstringstool`). Open: the reference's exact choices (C.8). | `specs/ide/string-catalog.md` §C | `YcodeStrings`, `YcodeBuild/StringsCompilerHook.swift` | yes / yes (`ycode strings`) / no | – | P1 on Linux. |
| String extraction from source | The build syncs new and stale keys into the catalog | missing | `specs/xcodebuild/localization.md` | – | no / no / no | L | P1 — catalogs drift from the code |
| Localization export and import (`.xcloc`) | Product ▸ Export/Import | done (IDE-QUICKWINS, 2026-10-30): the IDE items run ycodebuild's export (every known language) and import in process; no language-choice or import-review sheet | `specs/xcodebuild/localization.md`, `specs/ide/build.md` §IDE tool actions | `YcodeXcodebuild/Localization.swift`, `YcodeIDECore/Model/IDEToolActions.swift` | yes / yes / no | – | P2 |
| Storyboard and XIB compile (`ibtool`) | `.nib`; the new `toolchain` mode in Xcode 27 | partial: Xcode's `ibtool` via swift-build, macOS only | `specs/ide/interface-builder.md` | – | partial / no / no | XL | P2 — nib is undocumented (level 2 spec needed) |
| Core ML compile | `.mlmodel` → `.mlmodelc` and a Swift interface | missing in Ycode (Xcode's `coremlc` only) | – | `XcodePIF.swift` (file type only) | partial / no / no | XL | P3 — workaround: `MLModel.compileModel(at:)` at run time (public API) |
| Metal compile | `.metal` → `.metallib` | partial: Xcode's `metal` via swift-build, macOS only. The Metal toolchain cannot be downloaded from Ycode. | – | – | partial / no / no | XL | P2 — no open Metal front end. `ycode-airc` only translates AIR to SPIR-V. |
| Build tool plug-ins | Package build plug-ins, trust prompt | partial (PIF-PKG): plug-ins of package targets, and plug-ins applied to project targets (Ycode hosts them; macOS only). No trust prompt. | `specs/ide/build-pif.md`, `reference-ui-5.md` §11.1 | `YcodeXcodebuild/ProjectPlugins.swift`, `ProjectEditorModel.swift` (display-only row) | yes / partial (package targets) / no | L | P1 — after package products |
| Command plug-ins | Run package command plug-ins | missing | – | – | no / no / no | M | P2 |
| Swift macros | Macro packages, trust prompt | partial (PIF-PKG): macro packages build and expand (host-built). No trust prompt. | `specs/ide/build-pif.md` | `YcodeXcodebuild/PackageGraphPIF.swift` | yes / partial / no | M | P1 |
| Code signing | Identities, profiles, automatic signing | partial: Sign to Run Locally; on macOS identities from the keychain (`security find-identity`) and installed profiles (`security cms -D`), manual and automatic choice by team, bundle id, platform, certificate, entitlements and expiry; Xcode-like diagnostics. Missing: creating certificates, devices or profiles (automatic provisioning through Apple's services), Linux signing (rcodesign designed only) | `specs/ide/signing.md` | `YcodeSigning/*`, `ycode/Tools/ycode-swb` (`SigningDelegate`) | partial / partial / no | L | P1 overall, P0 for devices |
| Entitlements | Signed into the product | done: `CODE_SIGN_ENTITLEMENTS` (settings expanded by swift-build) merged with derived entitlements (debugging, application and team identifiers, keychain group with a profile) in every build path; simulator builds carry them in `__TEXT,__entitlements` | `specs/ide/signing.md` §4 | `YcodeSigning/ProvisioningResolver.swift`, `SwiftBuildEngine.swift` (through `ycode-swb`) | yes / yes / no | – | P1 — exact derived keys of Xcode 27.1 are an open question |
| Explicit modules | Explicitly built modules (default) | not verified: left to swift-build | – | – | ? / ? / – | S | P3 |
| Build timing summary, timeline | Perform Action ▸ Build with Timing Summary | missing: the IDE item is u(); `ycodebuild` accepts the flag and ignores it | – | `CommandTable.swift`, `YcodeXcodebuild/Arguments.swift` | no / no / no | M | P2 |
| Delete Derived Data | Product menu | done (IDE-QUICKWINS): asks, then deletes the workspace's derived data folder | `specs/ide/build.md` §IDE tool actions | `IDEToolActions.swift`, `WorkspaceWindowController+ToolActions.swift` | yes / – / no | – | P2 |
| Build Documentation (DocC) | ⌃⇧⌘D | partial: the IDE item runs `ycodebuild docbuild` (open-source DocC) and reveals the archives in Finder (IDE-QUICKWINS); no documentation viewer | `specs/xcodebuild/build-actions.md` §5, `specs/ide/build.md` §IDE tool actions | `BuildActions.swift`, `IDEToolActions.swift` | yes / yes / no | M (viewer) | P2 |
| Analyze, Archive | Static analysis; `.xcarchive` | done | `specs/xcodebuild/archive.md` | `YcodeXcodebuild/Archives.swift` | yes / yes / no | – | P3 |

### 2.5 Run and debug

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Run on My Mac | Build, launch under LLDB, console | done | `specs/ide/run.md`, `debug.md` | `Window/WorkspaceWindowController+Product.swift`, `Session/WorkspaceSession.swift` | yes / no run command / no | – | P1 — works |
| Run on Mac simulators | Install, launch, attach | done (headless through `simctl`) | `specs/ide/run.md` | `YcodeUI/Session/SimulatorRun.swift` | yes / n.a. / n.a. | – | P2 |
| Run on the Ycode simulator | – (Ycode's own) | done (over ssh to `ycode-simd`, with a console stream) | `specs/ide/run.md` | `YcodeUI/Session/RemoteRun.swift`, `RemoteSimulatorTargets.swift` | yes / yes (`ycode-simd --install-app --launch`) / no | – | P1 — the main destination |
| **Debug on the Ycode simulator** | Breakpoints and stepping in a simulator app | **done** (SIM-DEBUG, 2026-10-30): a gdb-remote stub in `ycode-simd`; Run attaches lldb-dap through it. No watchpoints, no images loaded after the attach | `specs/simulator/debug-stub.md`, `specs/ide/debug.md` §Remote, `run.md` | `ycode-simd/DebugStub.swift`, `YcodeDebug/GDBRemote/`, `YcodeDarwinKernel/DebugHooks.swift`, `RemoteRun.swift` | yes / yes (`--debug-server`, the Mac's `lldb`) / no | – | P1 — works |
| Physical devices | Install, launch and attach through CoreDevice; wireless | missing: listed through `devicectl` only. A device row falls through to the Mac launch path. | `specs/ide/destinations.md`, `devices.md` | `+Product.swift`, `YcodeBuild/Destinations.swift` | no / no / no | XL | P2 — needs signing and pairing |
| Scheme arguments and environment | Run ▸ Arguments/Options | done | `specs/ide/schemes.md` | `WorkspaceSession.swift`, `SimulatorRun.swift` | yes / yes (`--app-arg`, `--app-env`) / no | – | P2 |
| LLDB session | lldb-dap: launch, attach, threads, frames | done | `specs/ide/debug.md` | `YcodeDebug/DAPClient.swift` | yes / portable library / no | – | P1 |
| Breakpoints | Line, symbolic, exception, Swift error, test failure; conditions; ignore count | done | `specs/ide/debug.md` | `YcodeUI/Model/BreakpointList.swift`, `+DebugMenu.swift` | yes / – / no | – | P1 |
| Breakpoint actions | Log, debugger command, shell, sound; several per breakpoint | partial: one action (log or command) plus auto-continue | `specs/ide/debug.md` | `YcodeUI/Debug/BreakpointEditorController.swift` | partial / – / no | S | P3 |
| Stepping | Over, into, out, by instruction, by thread | partial: the Follow Program Counter variants are u() | `specs/ide/debug.md` | `+DebugMenu.swift` | partial / – / no | S | P3 |
| Variables view, watchpoints | Locals, edit values, watch | done (write watchpoints) | `specs/ide/debug.md` | `YcodeUI/Debug/DebugAreaController.swift` | yes / – / no | – | P1 |
| LLDB console | Input, filters | partial: Hide/Show Similar Items are u() | `specs/ide/debug.md` | `YcodeUI/Debug/ConsoleRows.swift` | partial / – / no | S | P3 |
| Attach to process, Detach | By PID or name, wait for launch | done (local Mac) | `specs/ide/debug.md` | `+DebugMenu.swift` | yes / – / no | – | P2 |
| Disassembly | Disassembly view | done (read only) | `specs/ide/debug.md` | `WorkspaceWindowController.swift` | yes / – / no | – | P3 |
| View Memory, Load Symbols, Debug Crash Log | Debug Workflow menu | missing (u()) | `specs/ide/reference-ui-5.md` §2.10 | `CommandTable.swift` | no / – / no | M | P2 |
| View hierarchy debugger | 3D capture of the view tree | missing (placeholder button) | `specs/ide/debug.md` | `YcodeUI/Debug/DebugBarExtras.swift` | no / no / no | XL | P2 |
| Memory graph debugger | Object graph, leaks | missing (placeholder button) | `specs/ide/debug.md` | `DebugBarExtras.swift` | no / no / no | XL | P3 |
| GPU frame capture, Metal debugger | Capture and replay a frame | missing (internal GPU trace scripts only) | – | `ycode/scripts/ycode-gpu-trace` | no / partial (trace summary) / no | XL | P3 |
| Sanitizers | ASan, TSan, UBSan in Diagnostics | done in the IDE (IDE-QUICKWINS, 2026-10-30): Run and Test Diagnostics write the scheme attributes; builds get `ENABLE_*_SANITIZER` (swift-build), runs ASan's stack-use-after-return option. `ycodebuild` still parses `-enable*Sanitizer` and ignores it (scheme attributes are not read by it either). | `specs/ide/schemes.md` §Diagnostics | `YcodeWorkspace/SchemeDiagnostics.swift`, `YcodeIDECore/Model/SchemeDiagnosticsBuild.swift`, `SchemeEditorController.swift` | yes / no / no | S (CLI) | P1 |
| Main Thread Checker, malloc tools, zombies | Runtime checkers | missing (rows disabled) | `specs/ide/schemes.md` | `SchemeEditorController.swift` | no / no / no | M | P2 |
| Environment overrides | Appearance, text size, accessibility | partial: Ycode simulator only; Debug ▸ View Debugging ▸ Disable All and Appearance work there (IDE-QUICKWINS) | `specs/ide/debug.md` | `YcodeUI/Debug/EnvironmentOverridesPanel.swift`, `YcodeSimFeatures/EnvironmentOverrides.swift` | partial / yes (`--overrides`) / no | S | P2 |
| Simulate location | Debug bar, Debug menu, GPX | partial: the debug bar and Debug ▸ Simulate Location (IDE-QUICKWINS) work on the Ycode simulator; no GPX files, no scheme default location | `specs/ide/debug.md` | `DebugBarExtras.swift`, `YcodeSimFeatures/SimLocation.swift`, `App/MenuBarDelegate.swift` | partial / yes (`--location`) / no | S | P2 |
| CPU, memory, energy, disk and network gauges | Debug navigator gauges and reports | partial: rows only. Energy is estimated from CPU. No report pages. Nothing for remote runs. | `specs/ide/reference-ui-5.md` §11.6 | `YcodeUI/Debug/DebugPresentation.swift` | partial / no / no | M | P2 |
| Induce Device Conditions, StoreKit, GameKit | Debug menu | missing (empty or u()) | `specs/ide/reference-ui-5.md` §2.10 | `CommandTable.swift` | no / no / no | L | P3. `frameworks/storekit` has a testing engine to connect to. |

### 2.6 Testing

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Discovery: XCTest, Swift Testing | Index-based | done (lexical) | `specs/ide/testing.md` | `YcodeUI/Model/TestDiscovery.swift`, `YcodeXcodebuild/SwiftTestingBridge.swift` | yes / yes / no | S | P1 |
| Run tests | ⌘U, diamonds, Test Again, without building | done | `specs/ide/testing.md` | `YcodeBuild/TestResults.swift`, `WorkspaceSession.swift` | yes / yes (`ycodebuild test`, `swift test`) / no | – | P1 |
| Results, gutter diamonds | Per-test status | done | `specs/ide/testing.md` | `YcodeUI/Editor/GutterView.swift` | yes / yes / no | – | P1 |
| Parameterized Swift Testing cases | Per-argument results | partial: cases collapsed | `specs/xcodebuild/test-actions.md` | `YcodeXcodebuild/TestResults.swift` | partial / partial / no | M | P2 |
| **App-hosted unit tests and UI tests** | Run inside the host app or a UI-test runner on the destination | **done for app-hosted tests (TEST-HOST, 2026-10-30)**: Ycode's agent (`libYcodeTestAgent.dylib`) is inserted into the `TEST_HOST` app and runs its XCTest and Swift Testing bundles after launch, on this Mac and on the Ycode simulator (iPhone 18 Pro on the Thor; results stream back over ssh); ycodebuild and ⌘U. partial for UI tests: they run in the xctest runner, and `XCUIApplication` fails (no automation service; dirty-room questions in `testing.md`). | `specs/ide/testing.md`, `specs/xcodebuild/test-actions.md` ("Ycode implementation") | `YcodeTestAgent/`, `YcodeXcodebuild/HostedTests.swift`, `RemoteTestHost.swift` | yes / yes (agent macOS-only; the remote run from any Mac) / no | L (UI automation) | P1 — UI tests next |
| UI test recording | Record interactions as code | missing | – | – | no / no / no | XL | P3 |
| Test plans | Select, edit, create; configurations | partial: selecting and running work, with configurations (`-only/-skip-test-configuration`), environment, arguments, repetitions, language and region (TEST-HOST); Edit, New and Manage are u() | `specs/ide/testing.md` §Test plans | `YcodeXcodebuild/TestRunFiles.swift`, `TestActions.swift`, `CommandTable.swift` | partial / yes (`-testPlan`) / no | M (editor) | P1 |
| Repetitions, parallel testing | Iterations, retry, until failure; parallel clones | partial: repetitions done in ycodebuild (test plans and `-test-iterations`, `-retry-tests-on-failure`, `-run-tests-until-failure`; TEST-HOST) and in the IDE's Run Repeatedly… (Test navigator row menu; fixed, until failure, retry on failure; IDE-QUICKWINS); parallel testing missing (flags parsed and ignored); no diamond menu | `specs/xcodebuild/test-actions.md`, `specs/ide/testing.md` §Repetitions | `YcodeXcodebuild/TestActions.swift`, `YcodeIDECore/Model/TestRepetition.swift` | partial / partial / no | L (parallel) | P2 |
| Code coverage | Collect; Coverage report; editor ribbon | done (the editor's Code Coverage ribbon since IDE-QUICKWINS) | `specs/xcodebuild/coverage.md` | `YcodeXcodebuild/Coverage.swift`, `YcodeUI/Window/ReportViews.swift` | yes / yes (macOS and Linux) / no | – | P2 |
| Writing `.xcresult` | Result bundle per run | done (`ycodebuild`) | `specs/xcodebuild/result-bundle.md` | `YcodeXcodebuild/ResultBundles.swift`, `XCResultStore.swift` | no (the IDE does not ask for one) / yes / no | S | P3 |
| Reading `.xcresult` | Open bundles as reports | partial: File ▸ Open… of a bundle adds a test report (tests, failures as issues) through TEST-HOST's `XCResultReader` (IDE-QUICKWINS); `ycode results` on the command line. No coverage, logs or attachments from the bundle; the IDE's own runs still parse console output | `specs/xcodebuild/result-bundle.md`, `specs/ide/testing.md` §Result bundles in the IDE | `YcodeXcodebuild/XCResultReader.swift`, `YcodeIDECore/Model/ResultBundleReport.swift` | yes / yes / no | M (rest) | P2 |
| Test report | Insights, Tests, Coverage, history | partial: the current session only | `specs/ide/reference-ui-6.md` §3.4 | `ReportViews.swift`, `YcodeUI/Model/ReportModel.swift` | partial / – / no | M | P2 |

### 2.7 Previews, Interface Builder, asset catalogs, String Catalogs

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Preview discovery | `#Preview`, `PreviewProvider`, `@Previewable` | done (lexical) | `specs/ide/previews.md` | `YcodePreviews/PreviewDiscovery.swift` | yes / yes (`ycode preview --list`) / no | – | P1 |
| macOS previews | Canvas renders AppKit and SwiftUI | done (a long-lived Mac host renders PNGs) | `specs/ide/previews.md` | `YcodePreviews/PreviewMacHost.swift`, `YcodeUI/Model/PreviewRenderer.swift` | yes / n.a. / n.a. | – | P1 |
| iOS live previews on the Ycode simulator | Live canvas | done: payloads loaded with `dlopen`; save to new pixels in about 0.6–0.8 s. Limits: package dependencies, resources. | `specs/ide/previews.md` | `YcodePreviews/PreviewHost.swift`, `YcodeUI/Session/RemotePreviewSession.swift` | yes / host side runs on Linux / no | M | P1 |
| iOS previews without a Ycode simulator | Canvas with no setup | missing (no `simctl` preview path) | `specs/ide/previews.md` | `+LivePreviews.swift` | no / no / no | M | P2 |
| UIKit and AppKit previews | `#Preview` returning a view or controller | done | `specs/ide/previews.md` | `YcodePreviews/PreviewPayload.swift` | yes / – / no | – | P2 |
| Live and Selectable modes, variants, devices | Interactive or selectable; variant grids; `#Preview(arguments:)` (27) | partial: Live by default; light/dark variants; one trait at a time | `specs/ide/previews.md` | `YcodeUI/Editor/PreviewCanvasChrome.swift` | partial / no / no | M | P2 |
| Headless preview render on Linux | – | missing: `ycode preview --render` exits 3. It needs the OpenViews renderer (R5) or a simulator. | `specs/ide/previews.md` §Linux | `ycode/main.swift` | n.a. / no / no | XL | P2 |
| IB: open, outline, structure edits | Storyboards and XIBs | done | `specs/ide/interface-builder.md` | `YcodeUI/Model/IBDocument.swift`, `IBStructureEditing.swift` | yes / no / no | – | P2 |
| IB canvas fidelity | Real controls, per runtime | partial: labeled rectangles, scenes, segues | `specs/ide/interface-builder.md` | `YcodeUI/Editor/InterfaceBuilderController.swift` | partial / no / no | XL | P2 — could render through the simulator, like previews |
| IB inspectors | Identity, Attributes, Size, Connections | partial: a subset of attributes | `specs/ide/interface-builder.md` | `YcodeUI/Model/IBInspectorModel.swift` | partial / no / no | L | P2 |
| IB Auto Layout | Add, align, resolve, embed | partial: Add New Constraints, edit constant, delete. Align, Arrange, Embed and Resolve are u(). | `specs/ide/interface-builder.md` | `IBStructureEditing.swift`, `EditorMenu.swift` | partial / no / no | L | P2 |
| IB connections | Control-drag to create outlets, actions and segues | partial: view and disconnect only | `specs/ide/interface-builder.md` | `YcodeUI/Editor/InterfaceBuilderInspectors.swift` | partial / no / no | L | P1 — the core IB workflow |
| IB Library objects | All UIKit and AppKit objects | partial: 6 kinds | `specs/ide/library.md` | `YcodeUI/Model/LibraryItems.swift` | partial / no / no | M | P3 |
| Library window | Views, modifiers, snippets, symbols, media, colors | partial: Snippets, Symbols, IB Objects. Open Library (⌥⇧⌘L) is u(). | `specs/ide/library.md` | `YcodeUI/Editor/LibraryController.swift` | partial / no / no | M | P3 |
| Asset catalogs: image sets | Idioms, scales, appearances, slicing | partial: slots, drag-in (macOS), dark appearance. Device Image Reps, Quick Look and Slicing are u(). | `specs/ide/asset-catalog.md` | `YcodeIDECore/Model/AssetCatalog.swift`, `Editor/AssetCatalogEditorController.swift`; Linux: `YcodeIDEShell/AssetCatalogEditorModel.swift`, `ycode-ide/AssetCatalogEditorView.swift` | partial / no / partial (no drag-in) | M | P2 |
| Asset catalogs: color sets, app icon sets | Components, appearances; icon sets per platform | done | `specs/ide/asset-catalog.md` | `AssetCatalogEditorController.swift`, `ycode-ide/AssetCatalogEditorView.swift` | yes / no / yes | – | P2 |
| Asset catalogs: data, symbol, texture, AR and sticker sets | Kind-specific editors | partial: generic slots only | `specs/ide/asset-catalog.md` | `AssetCatalog.swift` | partial / no / no | M | P3 |
| `.icon` document | Opened in Icon Composer; built into the app icon | partial: built into the app icon (flattened tier, `ycode assets compile`); no editor or viewer | `specs/formats/icon-format.md` §I | `YcodeIcon`, `YcodeAssetCatalog` | partial / partial / no | L | P2 (see §3) |
| `.xcstrings` editing | Translations, states, progress | done | `specs/ide/string-catalog.md` | `YcodeStrings/StringCatalog.swift`, `YcodeUI/Editor/StringCatalogEditorController.swift` | yes / – / no | – | P1 |
| Strings from source | Catalogs fill from code at build | partial (RES-STRINGS): Refresh from Source in the catalog editor and `ycode strings extract` (swift-syntax for Swift and SwiftUI, a scanner for Objective-C and C; merge rules §C.4). Not at build time; interpolation types are guessed from syntax. | `specs/ide/string-catalog.md` §C.3–C.6 | `YcodeStrings/StringExtractor.swift`, `StringCatalogMerge.swift` | yes / yes / no | M (build-time, compiler types) | P2 |
| Plural and device variations | Edit cases | partial: shown, not editable | `specs/ide/string-catalog.md` | `StringCatalog.swift` | partial / no / no | M | P2 |
| Agent translation | **Xcode 27**: Generate Translations; MCP tools for catalogs | partial: the Ycode MCP server lists catalogs, the strings still to translate, and sets translations (`strings_catalogs`, `strings_list`, `strings_set`; ASSIST-MCP, 2026-10-31). No Generate Translations command in the editor. | `specs/ide/coding-assistant.md` §10 | `YcodeMCP/YcodeTools+Content.swift` | partial / yes (`ycode mcp`) / no | S | P2 — an editor command that asks the chosen agent |
| Convert to String Catalogs | Migrate `.strings` and `.stringsdict` | done (RES-STRINGS): a sheet of the project's tables; undoable; also `ycode strings convert` | `specs/ide/string-catalog.md` §C.5 | `YcodeStrings/StringCatalogConverter.swift`, `YcodeIDECore/Navigator/ProjectFileOperations+StringCatalogs.swift`, `YcodeUI/Window/WorkspaceWindowController+StringCatalogs.swift` | yes / yes / no | – | P3 |

### 2.8 Data models, source control, Organizer

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Core Data model editor | Entities, attributes, versions, code generation | missing (the bundle is opaque) | – | `YcodeUI/Model/NavigatorTree.swift`, `XcodePIF.swift` | no / no / no | L | P3. The `.xcdatamodel` XML is a file format (level 2); `momc` output is undocumented. |
| SwiftData | Template option (macros, no editor) | done (template) | `specs/ide/templates.md` | `YcodeUI/Model/IOSAppTemplate.swift` | yes / – / no | – | P3 |
| Git: status, stage, commit, history, comparison | Changes, commit sheet, history | done | `specs/ide/source-control.md`, `comparison.md` | `YcodeUI/SourceControl/*`, `Model/GitRepository.swift`, `GitHistory.swift` | yes / git / no | – | P1 |
| Branches and tags | Create, rename, delete, switch, tag | done (SCM-BRANCHES): create, rename, delete (unmerged after a second confirmation), check out local, remote (tracking) and detached, with stash / keep / refuse for uncommitted changes; lightweight and annotated tags; navigator context menus | `specs/ide/source-control.md` ("Ycode implementation") | `YcodeIDECore/SourceControl/GitRepository+Branches.swift`, `SourceControlRowMenu.swift`, `YcodeUI/SourceControl/SourceControlCoordinator+Branches.swift` | yes / git / core only | – | P3 |
| Merge and rebase | Merge from or into, with a conflict UI | done (SCM-BRANCHES): merge (fast-forward, merge commit, `--no-ff`) and rebase from the branch menus; conflicts open the conflict editor; Integrate ▸ Resolve Conflicts…, Continue and Abort while stopped. "Merge current into another branch" is not offered. | `specs/ide/source-control.md` ("Ycode implementation") | `GitRepository+Integration.swift` | yes / git / yes | S | P3 |
| Conflict resolution | Three-way editor | done (SCM-BRANCHES): base / ours / theirs from the index stages (or the markers), per-hunk Left, Right, both, Base or Edit, the merged result, Mark as Resolved, Continue / Abort | `specs/ide/comparison.md` ("Ycode implementation") | `YcodeIDECore/SourceControl/ThreeWayMerge.swift`, `GitRepository+Conflicts.swift`, `ConflictEditorState.swift`, `YcodeUI/SourceControl/ConflictEditorController.swift`, `ycode-ide/ConflictEditorView.swift` | yes / – / yes (B3-CONFLICT, #75) | – | P3 |
| Stash, cherry-pick | Stash, apply, pop, drop; cherry-pick | done (SCM-BRANCHES): stash push, apply, apply and delete, delete; cherry-pick and revert with conflict handling | `specs/ide/source-control.md` ("Ycode implementation") | `GitRepository+Integration.swift` | yes / git / core only | – | P3 |
| Remotes: push, pull, fetch | Choose a remote and branch; add remotes | partial (SCM-BRANCHES): add and remove remotes, fetch one remote, push a branch (setting its upstream) or a tag, delete a remote branch, pull fast-forward / merge / rebase; ahead-behind counts. The menus use the branch's remote or the first one; no remote-and-branch sheet yet. | `specs/ide/source-control.md` ("Ycode implementation") | `GitRepository+Branches.swift` | partial / git / core only | S | P2 |
| Hosting accounts (GitHub, GitLab, Bitbucket) | Sign in; hosted repositories | missing ("Accounts Are Not Supported") | `specs/ide/settings.md` | `YcodeUI/App/SettingsPanes.swift` | no / no / no | L | P2 |
| Pull requests | Create and review | missing (u()) | – | `CommandTable.swift` | no / no / no | L | P3 |
| Organizer: archives | Archive list and details | done | `specs/ide/organizer.md` | `YcodeUI/Model/Organizer.swift`, `Window/OrganizerController.swift` | yes / yes (`ycodebuild archive`) / no | – | P2 |
| Distribute App | App Store Connect, Ad Hoc, Enterprise, Developer ID, Copy App | partial: Copy App, ad hoc or re-signed with a keychain identity (nested code first, `specs/ide/signing.md` §5) | `specs/ide/organizer.md`, `specs/xcodebuild/archive.md` | `Organizer.swift`, `YcodeXcodebuild/Archives.swift` | partial / partial / no | XL | P2 — needs signing |
| Notarization | Notarize, staple | missing | `specs/xcodebuild/archive.md` | `YcodeXcodebuild/Xcodebuild.swift` | no / no / no | L | P3. The Notary REST API is public (level 1). |
| TestFlight, App Store Connect upload | Upload and manage builds | missing | – | – | no / no / no | XL | P3. The App Store Connect API is public (level 1). |
| Crashes, metrics, energy, insights | Organizer reports (27 adds Insights, Hitches, Storage, AI analysis) | missing (empty states) | `specs/ide/organizer.md` | `OrganizerController.swift` | no / no / no | XL | P3 |
| Xcode Cloud | Workflows, builds | missing (u()) | – | `CommandTable.swift` | no / no / no | XL | P3 — an Apple service |

### 2.9 Devices, documentation, playgrounds, assistant, profiler

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Device Hub (replaces Simulator.app) | Device list, canvas, inspector, compact windows | done for Ycode simulators. Apps, Profiles and Reports are placeholders. 27.2 extras (shake, memory pressure, slow animations) are missing. | `specs/ide/device-hub.md` (I.2) | `YcodeUI/Window/DevicesController*.swift`, `YcodeDeviceUI/*`, `YcodeDeviceModel/*` | yes / n.a. (the viewer is macOS) / no | M | P2 |
| Simulator management | Create, delete, runtimes, start, stop | partial: start, shut down, erase and fold for Ycode devices; Mac simulators listed only; no create, delete or runtime download | `specs/ide/devices.md`, `run.md` | `DevicesController.swift`, `Window/DeviceHubToolbar.swift` | partial / yes (`ycode-simd`, `ycode-sim`) / no | M | P2 |
| Add Watch, Vision Pro or TV device | Device Hub ▸ Add Device | partial: Apple Watch… and iPhone with Paired Watch… (PAIR-IDE) and Apple Vision Pro… (IDE-SMALL: a visionOS runtime root gives a Vision Pro row and the item creates more; Start boots to the room, Delete… erases) create Ycode devices; TV stays disabled (no tvOS simulator). Vision Pro rows are not run destinations yet | `specs/ide/device-hub.md` §I.9, §I.11 | `DeviceHubToolbar.swift`, `DevicesController+Pairing.swift`, `RemoteSimulatorTargets.swift` | partial / partial (`ycode-simd --device-type`) / no | S (TV, visionOS run destinations) | P2 |
| Vision Pro in a headset (Ycode feature) | — (the reference has no headset view of a simulator) | partial (XR-HUB), **no live headset run yet**: Device Hub ▸ Headset box, Set Up Headset… (a five-step checklist of the Linux viewer host and the Quest: GPU, OpenXR loader and runtime, WiVRn server, ycode-xr-viewer, route, adb, USB states, WiVRn app and version, tracking, connection; commands to copy, Install on Headset… after a confirmation, Connect), View in Headset / Back to Desktop (toolbar, compact window, More Actions, ⌃⌘H) moving the running device both ways without a restart. Verified: the checklist's real run on the owner's workstation (read-only); 25 offline switches each way through Mac → x86 → Thor with `--replay` (in 0.5–1.4 s, back within 0.2 s but for one unexplained 4.6 s), the device running throughout; a real tall stream on the hub's canvas. Not verified: an OpenXR session or a headset in a switch, Connect and Install on Headset… (stand-ins only), the menu paths on a headset. The display size is a boot choice (`--vision-display`): the visionOS guest takes no live change | `specs/ide/device-hub.md` §I.12, `specs/simulator/xr-viewer.md` §7.2, `display-stream.md` §1.1 | `HeadsetSetup.swift`, `HeadsetSwitch.swift`, `HeadsetCLI.swift`, `DevicesController+Headset.swift`, `HeadsetSetupWindowController.swift`, `XRControl.swift` | yes / yes (`ycode sim headset`) / hook (`ShellRemoteRun.switchHeadset`) | S (a shell device surface) | P2 |
| Paired watch simulators | Pair, unpair, make active; "Paired with … ›"; watch app runs on a phone's paired watch | done (PAIR-IDE): Device Hub pairs, unpairs (the watch is erased), switches the active watch and shows the pair; watch and phone-with-watch run destinations; the watch app is installed directly on the watch through the pairing agent | `specs/simulator/device-pairing.md` §13, `specs/ide/device-hub.md` §I.9, `destinations.md`, `run.md` | `DevicesController+Pairing.swift`, `WorkspaceWindowController+WatchRun.swift`, `YcodeIDECore/Session/RemotePairing.swift`, `RemoteWatchRun.swift` | yes / yes (`ycode-sim pair`) / no | – | P2 |
| Physical devices | Pair (also over the network in 27), prepare, install, console | missing (read-only `devicectl` list; Pair Nearby Device is disabled) | `specs/ide/devices.md` | `DevicesController.swift` | no / no / no | XL | P2 |
| DocC build | Build Documentation | partial (CLI only, §2.4) | `specs/xcodebuild/build-actions.md` | `BuildActions.swift` | no / yes / no | S | P2 |
| Documentation viewer | Documentation window; semantic search (27) | missing: opens the web URL | – | `YcodeUI/App/AppCommands.swift` | no / no / no | L | P3. swift-docc-render (Apache-2.0) can display DocC archives. |
| Quick Help | Popover and inspector | done | `specs/ide/language.md` | `QuickHelpView.swift` | yes / – / no | – | P2 |
| Playgrounds | `.playground`; `#Playground` macro (27) | missing (template and bundle recognition only) | – | `Templates.swift` | no / no / no | L | P3. `#Playground` could reuse the preview payload path. |
| Coding assistant: models and chat | Providers, conversations | done: Ollama, llama.cpp, OpenAI, agent CLIs. The reference adds Gemini and Antigravity in 27. Output limit (default 4,096 tokens), optional sampling, cut-off replies with Continue and streamed usage (coding-assistant.md §3.5, PREDICT). | `specs/ide/coding-assistant.md` | `YcodeAssistant/*`, `YcodeUI/Assistant/*` | yes / library only / no | – | P1 |
| Coding assistant: edits | Coding tools, applied edits, history | partial: the user reviews and applies proposals; no history | `specs/ide/coding-assistant.md` §9 | `+CodingAssistant.swift`, `Assistant/ProposalReviewController.swift` | partial / no / no | M | P2 |
| Coding assistant: agents, MCP, ACP, skills | **Xcode 27**: agents build, run, test and render previews through the Xcode MCP server; ACP; plug-ins with skills; plans | done (ASSIST-MCP, 2026-10-31): `ycode mcp`, Ycode's MCP server (29 tools: workspace, files, search, issues, build settings, symbols, build with progress, test, clean, run, the remote Ycode Simulator with screenshots, preview images, String Catalogs, predictive completion (`complete`, PREDICT); stdio and loopback HTTP; read-only unless `--allow-writes`); agent mode in the IDE (Claude Code and Codex get the server per request, every change is a proposal the agent waits on); ACP agents as a back end (messages, tool calls, plans, permission sheets, file I/O through Ycode); the Ycode skill. Left: plug-ins, a plans view, session history (§10.7). | `specs/ide/coding-assistant.md` §10 | `YcodeMCP/*`, `YcodeAssistant/ACP*.swift`, `+AgentMode.swift` | yes / yes (`ycode mcp`) / no (`ycode-ide` has no assistant pane yet) | S | P2 — plug-ins and a plan view |
| Predictive code completion | On-device model | done (PREDICT, 2026-10-31) with Ycode's own backend (the reference's model is encrypted and device-bound, `codelm-format.md`): Ollama by default (`/api/generate` with `suffix`, model picked by capability `insert`), `llama-server` `/infill` and OpenAI-compatible servers as advanced choices. Grey ghost text after the caret (debounced), Tab accepts what is shown, ⌥Tab all, ⌃Tab a word, ⌥ expands, Escape dismisses, typing through keeps it; Editor ▸ Show Predictive Completion ⌃⌥Space; Settings ▸ Editing switch and Completion ▸ Predictive Code Completion rows (backend, address, model, Test, explicit Ollama download); a quiet activity-view notice when the server is missing; `ycode complete` and the MCP tool `complete`. Measured 37–118 ms to first token, 160–617 ms per suggestion with a 7B model on the Mac (§8 of the spec). Linux: engine, CLI and MCP only until L2 (§5.9). | `specs/ide/predictive-completion.md` | `YcodeCompletion/*`, `YcodeAssistant/OllamaProvider+Generate.swift`, `YcodeUI/Editor/SourceEditorController+Prediction.swift`, `YcodeUI/App/TextEditingSettingsPane+Prediction.swift` | yes / yes (`ycode complete`, MCP `complete`) / no (L2) | – | P3 — the pop-up steering prediction (16.2) |
| Profile on the Ycode simulator | Instruments trace | done (Gauge) | `specs/ide/profiler.md` §5–6 | `+Product.swift`, `YcodeUI/Gauge/*`, `YcodeProfiler/*` | yes / yes (`ycode-simd --profile`, `ycode profile`) / no | – | P1 |
| Profile My Mac and Mac simulators | Any destination | missing (the macOS sampler is design only) | `specs/ide/profiler.md` §3.3 | `+Product.swift` | no / n.a. / n.a. | L | P1 |

### 2.10 Settings, accounts, Liquid Glass

| Feature | Xcode 27.1 | Status | Spec | Code | macOS IDE / Linux CLI / Linux IDE | Effort | Priority — reason |
|---|---|---|---|---|---|---|---|
| Settings window | Sidebar of panes | done: 13 panes | `specs/ide/settings.md` | `YcodeUI/App/SettingsWindow.swift`, `SettingsPanes.swift` | yes / – / no | – | P3 |
| Unused settings | General, Navigation, Text Editing | partial: `restoreWindows`, `autoUnlockFiles`, `navigationDestination`, `scopeGuides` and test parallelization are saved and never read | `specs/ide/settings.md` | `SettingsPanes.swift` | partial / – / no | S | P3 |
| Accounts | Apple ID, teams, certificates; git hosts | **missing** | `specs/ide/settings.md` | `SettingsPanes.swift` | no / no / no | XL | P1 — blocks signing and pull requests |
| Behaviors | Event → action rules, custom behaviors | partial: Build, Testing (succeeds / fails) and Running events; the event decision is shared (`BehaviorEventTracker` in YcodeIDECore); Notify shows the result bezel or a system notification in both IDEs (`specs/ide/build-notifications.md`) | `specs/ide/reference-ui-5.md` §9.4, `specs/ide/build-notifications.md` | `SettingsPanes.swift`, `YcodeIDECore/Model/Preferences.swift`, `YcodeIDECore/Model/BuildNotifications.swift`, `WorkspaceWindowController+BuildBezel.swift`, `YcodeIDEShell/ShellBuildNotifier.swift`, `ycode-ide/BuildBezel.swift` | partial / – / no | M | P2 |
| Themes, Key Bindings | Theme editing; rebinding with conflict detection | done | `specs/ide/settings.md` | `SettingsPanes.swift`, `YcodeUI/Editor/Theme.swift` | yes / – / no | – | P3 |
| Components (platforms, runtimes) | Download and remove | missing: read-only list | `specs/ide/settings.md` | `SettingsPanes.swift` | partial / no / no | L | P2 — Ycode will not redistribute runtimes; it can point at the user's own |
| Locations | DerivedData, Archives, CLT | partial: Build System pop-up only. Workspace Settings… is u(). | `specs/ide/settings.md` | `SettingsWindow.swift` | partial / – / no | S | P2 |
| Liquid Glass chrome | Glass toolbar, floating bars, flush sidebars | done on macOS 26 and later (system `NSGlassEffectView`) | `specs/ide/liquid-glass.md`, `liquid-glass-ycode.md` | `YcodeUI/App/GlassBars.swift`, `Window/GlassPanel.swift` | yes / – / approximated (§5.5) | – | P3 |
| Liquid Glass leftovers | – | partial: Welcome separators, inspector width; dark and hover states not observed | `specs/ide/liquid-glass-ycode.md` §10 | `Window/WelcomeWindowController.swift` | partial / – / no | S | P3 |
| Spacing and insets | Navigator, jump bar, inspector, debug area, Settings, Device Hub metrics | done for every spec value (UI-SPACING): first navigator row 7 below the selector in the window (was under it), header navigators no longer cut their first row, 31-point jump bar band, inspector rows inside a 12-point right inset, equal debug-area bottom bars, wrapping Settings labels, the Hub's sidebar group at the sidebar's edge. Open: metrics no spec records (outline indentation, gutter, find bar, tab bar, inspector columns, Settings layout) | `specs/ide/metrics.md` | `Navigator/NavigatorAreaController+Glass.swift`, `Editor/SourceEditorController.swift`, `Inspector/InspectorAreaController.swift`, `Debug/DebugAreaController.swift`, `App/SettingsPanes.swift`, `Window/DeviceHubToolbar.swift` | yes / – / no | S (the open metrics) | P3 |

### 2.11 Disabled menu commands

These are the u() items, by menu:

- **Ycode:** Extensions…, Behaviors ▸ No Custom Behaviors, Quit and Keep
  Windows.
- **File:**
  - New ▸ Target…, Choose Template…, Workspace….
  - Save All, Duplicate…, Save As…, Unlock…, Export….
  - Open Terminal at Location, Open in New Window.
  - Packages ▸ Reset Package Caches, Update to Latest Package Versions.
  - Save As Workspace…, Workspace Settings…, Print….
  - New ▸ Window has an action with no implementation.
- **View:** Focus Editor Pane, Change Editor Orientation, Reset Editor
  Sizes, Reset Assistant Selection, Open Library, Reload Organizer.
- **Navigate:** Reveal in Changes/Debug Navigator, the tab and next-pane
  variants, Move Focus (5), Jump to Last Destination.
- **Editor (source):** Expand Macro, Hide All Macro
  Expansions, Show Markdown, Authors, Vim Mode, Relative Line
  Numbers, Show Last Change for Line, Create Code Snippet…. (Invisibles and
  Scope Guides were wired by EDITOR-TYPING, Code Coverage by IDE-QUICKWINS.)
- **Editor (Interface Builder):** nearly all of Align, Arrange, Embed In,
  Resolve Auto Layout Issues, Localization Locking, Canvas, Guides; Minimap;
  Size to Fit Content; Refactor to Storyboard.
- **Editor (asset catalog):** Device Image Reps (9), Find References, Quick
  Look, Show Overview, Show Slicing, some Add New Asset entries.
- **Product:**
  - Perform Action ▸ Build with Timing Summary, Build and Export Test
    Products, Profile, Profile Again, Generate Optimization Profile.
  - New Scheme, Edit/New/Manage Test Plan, App Shortcuts Preview.
  - (Delete Derived Data, Build Documentation and Export/Import
    Localizations were wired by IDE-QUICKWINS.)
- **Debug:**
  - Follow Program Counter steps, Hide/Show Similar Items.
  - Library Info, Load Symbols, View Memory, Interrupt.
  - Debug Crash Log, Capture GPU Workload, View Debugging ▸ Capture View
    Hierarchy and the four Show items, Rendering (9).
  - StoreKit (8), GameKit.
  - Induce Device Conditions ▸ is empty.
  - (Simulate Location ▸, Disable All Environment Overrides and Appearance
    (5) were wired by IDE-QUICKWINS, for the Ycode simulator.)
- **Integrate:** Create Pull Request, Create Workflow, Manage Workflows.
- **Window and Help:** Rename Window Tab, Ycode Help, What's New, Release
  Notes, Provide Feedback, Hide Keyboard Hints.

Controls outside the menu bar that do nothing:
- General tab Frameworks +/−, the Embed pop-up and Supported Intents +/−.
- Accounts "+".
- The scheme editor's Diagnostics checkboxes other than the sanitizers,
  and Duplicate Scheme.
- The debug bar's View Hierarchy and Memory Graph buttons.
- Device Hub ▸ Add Device for TV, and Pair Nearby Device (Vision Pro: done
  by IDE-SMALL).
- Find navigator: the Asset References kind.
- Organizer Insights, Reports and Metrics.

---

## 3. Developer tools

### 3.1 The tools Xcode 27.1 ships or links to

| Tool | Where Apple ships it |
|---|---|
| Instruments, Device Hub, Icon Composer, Accessibility Inspector, FileMerge, Create ML | Xcode ▸ Open Developer Tool, in that order (`specs/ide/reference-ui-5.md` §2.1 item 7) |
| Simulator.app | Replaced by Device Hub in 27 |
| Reality Composer Pro, SF Symbols, Icon Composer (also standalone) | Separate downloads (Apple's Xcode resources page) |
| Additional Tools for Xcode | A separate download that needs a developer sign-in. Its contents vary by release. They include audio, graphics and hardware tools such as Network Link Conditioner, IO Registry Explorer, PacketLogger, Quartz Debug, Pixie, AU Lab, CarPlay Simulator, HomeKit Accessory Simulator and Printer Simulator (Apple forum listing for the 26 betas; level 1, unverified for 27.1). |

Ycode's own Open Developer Tool menu (`YcodeUI/App/MenuBarDelegate.swift`
`DeveloperTools`) does two things:
- It **launches Apple's installed apps** from the active developer
  directory on macOS.
- It shows Device Hub, which is Ycode's own.

Launching Apple's apps is passthrough, not parity. It does nothing on Linux.

### 3.2 Matrix

| Tool | What it does | Ycode equivalent | Status | macOS / Linux CLI / Linux IDE | Spec or code | Licensing constraints | Clean-room route | Effort | Priority |
|---|---|---|---|---|---|---|---|---|---|
| Simulator / Device Hub | Run simulated devices | Ycode simulator (`ycode-simd`), Device Hub window, `ycode-sim-viewer` (macOS and, since REMOTE-X86, Linux), `ycode-simhost` and `ycode sim remote` (Ycode's own encrypted link, `specs/simulator/sim-link.md`) | partial (§4) | viewer and Hub on macOS / `ycode-simd` and `ycode-simhost` on arm64 Linux, the viewer (picture, input, sound) and remote run on x86-64 Linux / no | `specs/simulator/`, `specs/ide/device-hub.md` | Runtimes are the user's own copy, under Apple's terms; Ycode never redistributes them | Existing specs | – | P0 (ongoing) |
| Instruments | Profiling templates | **Gauge** (`YcodeProfiler`): Time Sampler at 1000 Hz, signposts, hangs, frames, GPU command buffers; call tree, flame graph, source annotation | partial: no Allocations, Leaks, Energy, Network, Swift Concurrency, SwiftUI or System Trace; no Mac target; cannot import `.trace` | Gauge window on macOS / `ycode profile` on Linux / no | `specs/ide/profiler.md`, `YcodeProfiler/*` | Own trace format (`.gaugetrace`); Linux `perf` | Public `xctrace` docs (level 1); `.trace` import needs a dirty-room spec | L per instrument | P1 |
| Reality Composer Pro | Build RealityKit scenes, materials, timelines | **Scene Composer** (`composer/`, `frameworks/usd`) | partial: core and `ycode-scene` CLI (info, tree, cat, convert, validate, edit, components); USDA, USDC and USDZ read and write; composition. **No UI or viewport.** | CLI everywhere / yes / no | `docs/SCENE-COMPOSER.md`, `specs/tools/scene-composer/` | USD is our own Swift implementation; MaterialX is Apache-2.0; Pixar's usd-core is used only as a test oracle | Existing specs | XL | P2 |
| FileMerge (`opendiff`) | Two- and three-way file and folder comparison and merge | Compare Files (SCM-BRANCHES): Ycode ▸ Open Developer Tool ▸ Compare Files… merges two files, or three with an ancestor, in the conflict editor and saves the result; `ycode compare` prints a unified diff or a three-way merge | partial: no folder comparison | yes / yes (`ycode compare`) / core only | `specs/ide/comparison.md` ("Ycode implementation"), `YcodeIDECore/SourceControl/FileCompare.swift` | None; diff algorithms are public | Public FileMerge help and the `opendiff` man page (level 1) are enough; no dirty-room spec needed. Pairs with the conflict editor (§2.8). | M | P2 |
| Icon Composer | Layered icon document: Liquid Glass layers, Default/Dark/Mono variants, per-platform overrides, flat export. 27 adds Icon Composer 2.0 with a sharper rendering mode. | `ycode assets icon` reads, validates and converts `.icon` documents and renders a placeholder; the build compiles them (flattened tier) | partial | partial / partial / no | `YcodeIcon`, `YcodeAssetCatalog` | The user owns their artwork. Do not ship Apple's icon grids or templates (Apple Design Resources have their own license). Apple's glass rendering can only be approximated. | Specs done (`specs/formats/README-icon.md`); ICON-READER and CAR-WRITER phase 1 done; next ICON-RENDER, CAR-WRITER phase 2 (layered tier), ACTOOL-COMPAT. | L (render, viewer), XL (editor) | P2 |
| SF Symbols | Browse about 7,000 symbols; export custom-symbol templates | macOS: the Library's Symbols tab draws hand-typed names through the public `NSImage(systemSymbolName:)`, using the user's licensed system copy. OpenViews: `Image(systemName:)` goes through a pluggable symbol provider with a few of our own drawings; unknown names lay out as 0×0. | partial on macOS; missing on Linux | partial / no / no | `specs/ide/library.md`, `specs/frameworks/swiftui/09-open-design.md` §5.2 | **Apple's artwork may not be shipped or shown on Linux.** See §3.3. | The custom-symbol template format is public (Apple's "Creating custom symbol images for your app", level 1), so an importer and exporter is clean. Symbol *names* are interop identifiers; map only the ones apps use, with evidence. | M (provider and open set), L (browser) | P1 for the Linux IDE (every toolbar needs icons) |
| Accessibility Inspector | Inspect the accessibility tree; audit; simulate settings | Simulator accessibility *settings* exist (`--accessibility`, environment overrides). No tree inspection. | missing | no / no / no | `specs/simulator/simulator-features.md` | – | For Ycode simulator apps: a dirty-room spec of how the runtime exposes the accessibility tree, then a host-side inspector. For OpenViews apps on Linux: R10 exports AT-SPI with our own D-Bus client and exporter (OV-ATSPI, done 2026-10-30), so any AT-SPI inspector (Accerciser, BSD-3-Clause) shows the tree; a Ycode inspector view on top of the same protocol remains. | XL (simulator), S (Linux) | P2 |
| Create ML | Train image, text, sound, tabular and activity models without code; export `.mlmodel` | none | missing | no / no / no | – | coremltools (BSD-3-Clause) converts PyTorch and other models to `.mlmodel`/`.mlpackage`, and its protobuf spec is public | A clean route through open tools: Ycode templates that train with PyTorch and convert with coremltools, plus a `.mlmodel` viewer from the public protobuf (level 1). Compiling to `.mlmodelc` needs a dirty-room spec, or use `MLModel.compileModel(at:)` at run time in the simulator. | L | P3 |
| Network Link Conditioner | Shape bandwidth, latency and loss | none (simulator networking is passthrough) | missing | no / no / no | `specs/simulator/networking-ycode.md` | Linux `tc netem` (kernel feature) | Public NLC profile descriptions (level 1). Shape traffic in `ycode-simd`'s network path, or under the host's own control. | M | P2 |
| IO Registry Explorer | Browse the IOKit registry | `ycode-simd` serves a minimal IOKit for guests | missing as a viewer | no / partial (internal) / no | `specs/simulator/iokit-minimal.md` | – | Our own registry; a debug view is enough | S | P3 |
| HomeKit Accessory Simulator | Simulated HomeKit accessories | `frameworks/homekit` (R3) has an object model | missing as a tool | no / no / no | `specs/frameworks/homekit/` | HAP protocol docs are public | `specs/frameworks/homekit/accessory-protocols.md` | L | P3 |
| CarPlay Simulator | CarPlay screen for a device | none | missing | no / no / no | – | – | Out of scope until physical devices work | XL | P3 |
| Quartz Debug, Pixie, AU Lab, PacketLogger, Printer Simulator | Mac graphics, audio, Bluetooth and printing utilities | none | n.a. for Linux / missing | – | – | – | Low value for Ycode | – | P3 |
| `xcrun` | Find tools and SDKs | `ycodebuild -version -sdk`, `-showsdks` | partial: no `xcrun`; `-find-executable` unsupported | – / partial / – | `specs/xcodebuild/info-commands.md` | – | Public man page (level 1) | S | P2 |
| `xcodebuild` | Build, test, archive, export, settings | `ycodebuild` | done for most actions (§2.4); hosted tests done (TEST-HOST) | – / yes / – | `specs/xcodebuild/` | – | Existing specs | – | P0 |
| `simctl` | Device lifecycle and I/O | `ycode-simd` flags plus `ycode-sim` and `ycode-sim-serve` | done: boot, shutdown, erase, screenshot, location, ui, pair. partial: create, install, launch, openurl, spawn, privacy (only together with boot or launch; no separate terminate). missing: device list, push, status_bar, addmedia, keychain, pbcopy/pbpaste, recordVideo from the CLI, reboot (new in 27). | – / yes (arm64) / – | `ycode-simd/main.swift`, `ycode/scripts/` | – | Public `simctl help` (level 1). A `ycode simctl` front end with the same verbs would help scripts and agents. | M | P1 |
| `devicectl` | Physical devices through CoreDevice | none (Apple's JSON is parsed to list devices) | missing | no / no / no | `YcodeBuild/Destinations.swift` | libimobiledevice is **LGPL-2.1** (excluded by the frameworks policy unless used as a separate process); usbmuxd is GPL/LGPL | The CoreDevice protocol needs a dirty-room spec. On macOS, wrapping Apple's `devicectl` is allowed (it is the user's tool). | XL | P2 |
| `xcresulttool` | Read result bundles | `ycodebuild` writes bundles; nothing reads them | partial | – / partial / – | `specs/xcodebuild/result-bundle.md` | – | Existing spec | M | P2 |
| `xctrace` | Record and export traces from the CLI | `ycode profile record\|summary\|tree\|flame\|annotate\|symbolicate` | partial: own format | – / yes / – | `specs/ide/profiler.md` §7 | – | – | M | P2 |
| `actool`, `ibtool`, `momc`, `coremlc`, `metal`, `xcstringstool` | Resource compilers | `actool`: Ycode's `ycode assets compile` (tier-1 cars; `specs/formats/assets-car.md` §I). `xcstringstool`: Ycode's `ycode strings` (`specs/ide/string-catalog.md` §C). Others: Xcode's tools through swift-build on macOS | partial (actool, xcstringstool done) | partial (Xcode's) / no / no | §2.4 | Undocumented outputs (`Assets.car`, nib, `.mom`, `.mlmodelc`, `.metallib`); `ycode-airc` translates AIR, it does not compile Metal source | Dirty-room format specs (level 2) for `.car` and nib; xcstrings is easy (JSON in, documented formats out) | S (xcstrings) to XL (actool, ibtool, metal) | P1 on Linux |
| `codesign`, `notarytool`, `altool`, `stapler` | Sign, notarize, upload | `codesign` on macOS with ad hoc or keychain identities (builds, and export re-signing nested code first); rcodesign command line designed for Linux | missing | partial / no / no | `YcodeXcodebuild/Archives.swift` | **rcodesign** (apple-codesign, MPL-2.0, file-level copyleft; usable as a separate tool) signs and notarizes on Linux. Apple's Notary and App Store Connect REST APIs are public. | Level 1 docs for the APIs. Code signature format: public open-source references (Apple's open-source `Security`/`codesign` pieces under APSL; read, do not copy). | L | P1 |
| `swift-format` | Formatter | upstream swift-format (Apache-2.0) | done | yes / yes / – | `YcodeUI/Model/SwiftFormatTool.swift` | Apache-2.0 | – | – | P3 |
| `docc` | Documentation compiler | toolchain DocC (Apache-2.0) via `ycodebuild docbuild` | done (CLI); the viewer is missing | partial / yes / no | §2.9 | Apache-2.0 (swift-docc, swift-docc-render) | – | – | P2 |
| Transporter, TestFlight, Xcode Cloud | Delivery services | none | missing | – | – | Apple services; public APIs only where Apple offers them | – | XL | P3 |

### 3.3 SF Symbols and other licensing points

**SF Symbols.** Apple's SF Symbols page and HIG state no license terms
themselves (level 1, checked 2026-10-30). The terms come with the app and the
Xcode and Apple SDKs agreement. As quoted in Apple Developer Forums threads
and third-party notices (secondary sources), they:
- allow the symbols only for developing apps for Apple platforms;
- forbid them, or confusingly similar glyphs, in app icons, logos and
  trademarks;
- allow symbols that depict Apple products only unmodified.

Confirm the current wording in the agreement that ships with the SF Symbols
app before relying on any detail. The consequences for Ycode:

1. **The Linux IDE cannot draw SF Symbols.** Its chrome needs its own
   icons. This is also true of OpenViews apps on Linux.
2. **The macOS IDE may keep drawing symbols through the system API.** That
   uses the user's licensed copy; nothing is shipped.
3. **Guest apps in the Ycode simulator** draw symbols from the user's own
   runtime. That is unchanged and fine.
4. **Symbol names** (`star.fill`) are interop identifiers and may appear in
   specs and mapping tables. The glyphs may not.

Open icon sets Ycode could adopt for its own UI and as the default OpenViews
symbol provider:

| Set | License | Size (approx.) | Note |
|---|---|---|---|
| Lucide | ISC | 1,500+ | Stroke icons; good IDE fit |
| Phosphor | MIT | 1,200+ × 6 weights | Has weights, closest to SF's weight axis |
| Tabler Icons | MIT | 5,000+ | Large; stroke |
| Material Symbols | Apache-2.0 | 3,000+ | Variable font with weight, fill and grade axes; closest feature match (variable weight and fill) |
| Fluent UI System Icons | MIT | 2,000+ | Regular and filled pairs, like `x` and `x.fill` |
| Bootstrap Icons | MIT | 2,000+ | Plain |
| IBM Carbon icons | Apache-2.0 | 2,000+ | Plain |
| Font Awesome Free | CC BY 4.0 (icons) | 2,000+ | **Attribution required**, which is awkward for a default |

Recommendation:
- Use **Material Symbols** (variable weight and fill) or **Phosphor**
  (discrete weights) as the default provider.
- Add a table that maps the SF names apps use most to the nearest open
  glyph.
- Add an importer for the public custom-symbol SVG template, so users can
  bring their own.
- Record each set, version and license in `frameworks/swiftui/README.md`,
  as the fonts already are.

**Other licensing points:**
- **Fonts.** SF Pro and SF Mono may not be shipped. OpenViews already
  bundles Noto Sans (OFL 1.1). The Linux editor needs a monospace font:
  - Noto Sans Mono (OFL), JetBrains Mono (OFL), or Iosevka (OFL).
- **Runtimes and SDKs.** Building iOS apps on Linux needs the SDK
  (headers and `.tbd` stubs) and the toolchain resources from the user's
  own Xcode. Ycode may read them in place but must never redistribute them.
  The same holds for simulator runtimes.
- **libimobiledevice and usbmuxd** are LGPL or GPL. They are acceptable
  only as separate processes, never linked into Ycode.
- **rcodesign** is MPL-2.0. It is acceptable as an external tool; vendoring
  it would need review.
- **Apple Design Resources** (icon grids, UI kits) carry their own license.
  Do not bundle them.

---

## 4. Simulator matrix

Source: the specs' status sections. `ycode-simd` runs **only on arm64 Linux
with KVM**. x86-64 Linux would need arm64 translation, which is deferred.

Runtimes:
- iOS 27.1 (24A94401) and iOS 27.0 (24A434);
- watchOS 27.0 (24R362);
- visionOS 27.0 (24M362).

Device types: iPhone 18 Pro, iPhone Duo (foldable, 27.1 or later), iPad
(A16), iPad Pro 13-inch (M5), Vision Pro, and 13 Apple Watch types
(`ycode-simd --list-device-types`).

| Capability | iOS (iPhone) | iPadOS | watchOS | visionOS | tvOS | macOS apps on Linux |
|---|---|---|---|---|---|---|
| Boot | **done**: full service boot, 30.1 s median against 21.4 s on the reference (1.42×) (`lean-boot.md` §9) | **done**: 27.0 and 27.1 (`ipad.md` §9.1–9.2) | **done**: face draws; 13 device types (`watchos.md` §10.3–10.4) | **partial**: room shows; home view sometimes missing (`visionos.md` §10.20–10.21) | **missing**: last in the roadmap (`docs/FUTURE.md`) | n.a.: one process per run with `--macos` (`specs/macos/macos-apps.md` §9.2) |
| Display | **done**: live stream at the 60 Hz frame clock (`display-stream.md`, `frame-profile.md` §8.4) | **done**: up to 2064×2752 at 60 Hz, no 120 Hz (`ipad.md` §1.6) | **done**: 416×496, watch frame in the viewer (`watchos.md` §11) | **partial**: glass opaque, metal reflects black (`visionos.md` §10.21.7) | missing | **missing**: the window broker is design only (`macos-apps.md` §9.3) |
| Input | **done**: touch, keyboard, Home, Lock, volume; rotation on foldables only (`hid-input.md` §14) | **partial**: touch; rotation and pointer open (`ipad.md` §10) | **partial**: crown press; turn, buttons and gestures wait for W3 (`watchos.md` §11.7) | **missing**: no touches to apps; no gaze or pinch (`visionos.md` §10.21.7) | missing | missing |
| Audio out | **partial**: output discarded or written to WAV (`audio-host.md` §13) | partial | partial | partial (PHASE starts) | missing | missing |
| Audio in | missing (`simulator-features.md` §I.9) | missing | missing | missing | missing | missing |
| Camera | **done**: opt-in host webcam at ~29 fps, beyond the reference; the picker viewfinder stays grey (`camera.md` §9.6–9.7) | partial: not verified | n.a. | n.a. (no camera on the reference) | missing | missing |
| Health data | **done** beyond the reference (Ycode only): synthetic HealthKit samples by import (JSON/CSV) and scenarios through a guest agent, read-only types seeded into a shut-down store, grants for the agent and for an app's own request; HEALTH-4/5 open (`health-simulation.md` §11) | partial: not checked separately | **done**: same agent; watch samples sync to the paired phone; watch-app grants still need the card | n.a. | missing | n.a. |
| Network | **done**: host passthrough; no Bonjour or mDNS (`networking-ycode.md` §7–8) | partial: not checked separately | partial | partial | missing | missing |
| Pairing | **done**: records, CLI, endpoints, relay (§10, §12) and the IDE (Device Hub, run destinations; `device-pairing.md` §13) | n.a. | **done**: first paired face at 64.9 s against 54.4 s; a switch to a watch paired before is not followed by the phone's WatchConnectivity (§9 Q13) | n.a. | n.a. | n.a. |
| Snapshots | **done**: restore to the home screen in 6.4–11.1 s (`snapshot.md` §12.3) | **done**: restore in 5.5–5.7 s | missing: no run recorded | **missing**: shared Metal handles block saving (`visionos.md` §10.21.5) | missing | missing |
| App install and launch | **done**: own apps and the built-in apps (`app-install-launch.md`) | **done**: 9 built-in apps | **done** (PAIR-IDE): watch and phone-with-watch run destinations; installed and opened through the pairing agent (`device-pairing.md` §13) | **done**: window, volume and immersive apps; Photos crashes | missing | **partial**: C and Embedded Swift command-line samples; no Foundation yet |
| SwiftUI previews | **done**: live (`specs/ide/previews.md`) | partial: path exists, measured on iPhone only | missing | partial: payloads compile; no input | missing | n.a. |
| Profiling (Gauge) | **done**: measured on iPhone 18 Pro (`specs/ide/profiler.md` §10.2) | partial: not measured | partial: not measured | partial: not measured | missing | missing |

Other simulator gaps:
- **Fidelity.** Ycode starts 498–506 programs against 631 on the reference
  in the same window (`parity-ladder.md` §4.8).
- **Hangs.** One stuck GPU submission stops every client
  (`stage8-contract.md` §15.8).
- **simctl verbs** that are missing are listed in §3.2.
- **Device Hub 27.2 extras** are missing: shake, memory pressure, slow
  animations, Standby.

---

## 5. Linux IDE assessment

### 5.1 Inventory of `YcodeUI`, `YcodeDeviceUI` and `YcodeApp`

There are 198 Swift files and 57,344 lines. Each file is put in one bucket
by its imports and by what it does:

| Bucket | Rule | Files | Lines | Share |
|---|---|---:|---:|---:|
| 1. Pure model | Imports only Foundation and Ycode modules | 72 | 16,546 | 29 % |
| 2. AppKit for drawing or controls | AppKit views, tables, sheets, inspectors, panes: re-expressible in SwiftUI | 75 | 24,821 | 43 % |
| 3. Deep AppKit and platform code | Text system, navigators (`NSOutlineView`), window, toolbar and menu chrome, device canvas (layers, IOSurface), FSEvents, Darwin watchdog | 51 | 15,977 | 28 % |

**Bucket 1, by folder:**

| Folder | Lines | Content |
|---|---:|---|
| `Model/` | 11,539 | Command table, templates, asset catalog, String Catalog, IB document model, git history, diff, fold regions, tokenizer, workspace index, report model, test discovery, preview renderer |
| `Session/` | 3,205 | `WorkspaceSession`, remote runs, simulator runs, language support |
| `Project/` | 1,102 | Project editor model, capabilities, defaults level |
| Other | 700 | |

Most of it compiles on Linux as is. It is stuck in a macOS-only target only
because it lives in `YcodeUI`. Some pieces call macOS tools or APIs:
- `SimulatorRun` and `PreviewRenderer`'s Mac host use `simctl` and
  `PreviewMacHost`;
- `FileSystemWatcher` uses FSEvents and needs an inotify back end;
- `Preferences` uses AppKit colors and fonts, so it is in bucket 2 (L0 made
  it portable, §5.7).

**Bucket 2, by area:**

| Area | Lines |
|---|---:|
| Project and scheme editors | 4,162 |
| Window sheets and panels: Organizer, Device Hub, Welcome items, new-item sheets | 4,396 |
| Editors: asset catalog, Interface Builder, plist, String Catalog, previews, code review | 4,572 |
| Assistant | 1,980 |
| Debug area | 1,797 |
| Source-control windows | 1,784 |
| Settings panes | 1,383 |
| Gauge | 926 |
| Inspector | 805 |
| Device window controls | 1,682 |

**Bucket 3, by area:**

| Area | Lines | Main files |
|---|---:|---|
| Window controller and its extensions | 7,091 | `WorkspaceWindowController.swift`: 2,552 |
| Editor text system | 3,693 | `SourceEditorController.swift` 1,799, `GutterView`, `FindBar`, `CompletionPopup`, `InlineIssues` |
| Navigators | 2,310 | `NavigatorAreaController.swift` 1,674, built on `NSOutlineView` |
| App shell | 1,469 | `AppSupport`, `MenuBarDelegate`, `SettingsWindow`, `MainThreadWatchdog` |
| Device canvas and stream | 1,357 | |

Ycode uses no `NSDocument`. Documents are its own model objects, which
helps the port.

The libraries under the IDE are already portable:
- `YcodeBuild`, `YcodeLanguage`, `YcodeDebug`, `YcodeAssistant`,
  `YcodeXcodebuild`, `YcodeProfiler`, `YcodeSimFeatures` and
  `YcodeDisplayStream` build on Linux, with `Glibc` and
  `FoundationNetworking` where needed.
- `YcodeDeviceModel` and `YcodePreviews` import CoreGraphics. They need a
  small geometry shim, or the CGRect types that swift-corelibs-foundation
  provides.

### 5.2 What to share with the macOS IDE

**Recommended: one SwiftUI shell for both platforms, with a shared core.**

| Layer | macOS | Linux |
|---|---|---|
| `YcodeIDECore` (new): bucket 1 plus the view models pulled out of bucket 2 | shared | shared |
| Shell views, written in SwiftUI | Apple's SwiftUI, so real Liquid Glass and system controls come free | OpenViews |
| Source editor | the existing TextKit 2 editor, hosted with `NSViewRepresentable` until EditorKit matches it | **EditorKit** (§5.3) on OpenViews |
| Device canvas | `YcodeDeviceUI` (AppKit layers) | an OpenViews `Canvas` or a Vulkan surface fed by `YcodeDisplayStream` |

Why one shell rather than a separate Linux IDE:
- It avoids maintaining two IDEs.
- Every new feature is written once.
- The macOS IDE keeps its fidelity, because Apple's SwiftUI renders it.
- The Linux build exercises OpenViews on a large real app, which is the
  best conformance test it could get.

The AppKit shell stays shipping until the SwiftUI shell reaches it, screen
by screen.

The alternative is to keep AppKit on macOS and share only the core. It
costs less up front, but a Linux shell of about 40,000 lines would then
drift from the macOS one forever.

### 5.3 The editor: the hardest part

OpenViews R4 has typesetting (OVText: shaping, bidi, line breaking). It has
no editable text, and its plan has nothing past `TextField`/`SecureField`
(R8). A source editor cannot be built on `TextEditor` semantics. It needs
its own component, **EditorKit**, written once and used by the Linux shell.
Later the macOS shell can use it too.

| Piece | Approach | Reuse |
|---|---|---|
| Storage | A piece table or rope with line index and UTF-16/UTF-8 offset maps for LSP | `swift-collections` (Apache-2.0); its rope module is underscored and unstable, so pin it or write our own. `LineIndex`, `SourceChanges` and `TextCommands` in bucket 1 already exist. |
| Layout | Monospace-first line layout through OVText. Virtualized: lay out only visible lines plus a margin, cache per line, invalidate by edit range. Wrapping optional. | OVText (R4) |
| Rendering | Glyph runs and selection, caret, gutter, change bars, inline issues and minimap, drawn as display-list items | R5 renderer |
| Input | Key bindings, text input and IME composition (SDL3 text-editing events), multiple carets, undo grouping | R7 (keyboard), plus new IME work |
| Highlighting | **swift-syntax** (Apache-2.0) `SwiftParser` with incremental reparse for Swift; Ycode's line lexers for C, ObjC, C++, Metal, JSON, XML, Markdown, YAML, shell and xcconfig (tree-sitter was not needed; `source-editor.md` "Ycode implementation"); LSP semantic tokens on top | **Done:** `YcodeSyntax` (`SyntaxDocument`), used by the macOS editor too |
| Language features | Completion popup, hover, definition, rename, diagnostics, code actions | `YcodeLanguage` (already portable), plus the build-context fix (§6 #2) |
| Folding, find, placeholders, formatting | | `FoldRegions`, `Placeholders`, `SwiftFormatTool`, find model (bucket 1) |
| Accessibility | Text ranges exported over AT-SPI | R10: the Text and EditableText interfaces are exported for text inputs (OV-ATSPI); EditorKit's own text ranges and glyph extents remain |

Typing behavior (auto-indent, bracket pairing; §2.2) is a model-level
module: `YcodeSyntax`'s `TypingRules` and indentation, portable, with the
settings in `YcodeIDECore` (`Preferences.typingOptions`). The macOS editor
uses it now (EDITOR-TYPING, 2026-10-30) and EditorKit inherits it.

### 5.4 What OpenViews must provide

R5 (rendering), R7 (app, scenes, input on SDL3), R8 (controls) and R9
(containers and presentation) are done. R10 (environment, persistence,
accessibility) is done, its AT-SPI export too (OV-ATSPI, 2026-10-30: a D-Bus
client and an AT-SPI2 exporter in Swift, no third-party code). An IDE
also needs desktop pieces that `specs/frameworks/swiftui/10-plan.md` does
not list. They are proposed here as new rounds:

| Round | Content |
|---|---|
| **R11 Desktop scenes and commands** | `Window`, `WindowGroup` with several windows; `Settings` scene; `.commands`, `CommandMenu`, `CommandGroup` and `keyboardShortcut` onto a menu bar (SDL has none, so draw an in-window menu bar, or export through the DBus menu protocol); `.toolbar` with placements; `.contextMenu`; `.focusedValue` and `FocusedValues` for menu validation; `openWindow`, `dismissWindow`. Mostly level 1 (public API docs). **Done (2026-10-30, OV-R11):** an in-window menu bar (App, File, Edit, View, the app's menus, Window, Help) from the merged `commands` with standard groups (`CommandGroup` before/after/replacing), shortcuts that work with the menus closed (views' shortcuts first), F10 and arrow-key navigation, the Edit menu on R8's editing core; focused values (`focusedValue`, `focusedSceneValue`, `@FocusedValue`, `@FocusedBinding`, `@FocusedObject`); context menus (secondary click, long press, Shift+F10, list selections); window toolbars with placements, groups and spacers, and a bottom bar; the `Settings` scene, New Window, Close Window, Minimize, the window list. The DBus menu export is left for later. The `ov-mini-ide` sample has a menu bar, a toolbar with Build and Run, an outline context menu and a Settings window on X11 and Wayland. With R10: the environment follows desktop settings live, `@AppStorage`/`@SceneStorage`, and an accessibility tree, exported over AT-SPI2 since OV-ATSPI (a libatspi client sees the mini IDE's window, menu bar, outline, editor and toolbar, invokes Build and receives focus and text events on X11 and Wayland). |
| **R12 Desktop containers** | `HSplitView`, `VSplitView` and `NavigationSplitView` with three columns and resizable dividers; `List` with selection and `OutlineGroup`/`List(children:)` (the navigators); `Table` with sortable, resizable columns (build settings, String Catalog, debug variables); `DisclosureGroup`; `Inspector`; `TabView`. Overlaps R9; split if R9 is phone-first. **Done with R9 (2026-10-30) except `Table`:** split views with draggable dividers and pane limits, `NavigationSplitView` with two and three resizable columns, visibility and collapse, lists with single and multiple selection and keyboard navigation, lazy outlines with Right/Left expansion, a sidebar list style, `DisclosureGroup`, `inspector`, `TabView`; the `ov-mini-ide` sample (outline, editor over a console, sheet, alert) runs on X11 and Wayland. `Table` remains. |
| **R13 Desktop interaction** | Drag and drop (`draggable`, `dropDestination`, file URLs); clipboard; `fileImporter`/`fileExporter` through the XDG desktop portal; `.onHover`, cursors; `.help` tooltips; scroll wheel and trackpad gestures. |
| **R14 Text editing core** | Editable text storage, selection and IME behind `TextField` and `TextEditor`. This is the base EditorKit builds on (§5.3). **Done with R8 (2026-10-30):** OVText's `TextEditingModel` and `TextLayoutGeometry` (selection, word/line movement, undo, marked text, carets and hit testing); a piece table or rope, multiple carets and virtualised layout remain EditorKit's. |
| **R15 Materials** | `Material` blur and vibrancy in the R5 compositor, and an approximation of `glassEffect` (blur, tint, specular rim), so the shell resembles the macOS look. Pixel identity with Apple's glass is a non-goal (`09-open-design.md`). |
| **Symbols and fonts** | The default symbol provider with an open set (§3.3), and a monospace font. |

### 5.5 How close the Linux IDE can look to macOS

| Aspect | Expectation |
|---|---|
| Layout, metrics, structure | **Same.** It is the same SwiftUI source, and OpenViews' layout is conformance-tested against the golden values. |
| Fonts | **Different.** Noto, and a mono font, instead of SF Pro and SF Mono. Text metrics differ slightly. |
| Glyphs | **Different.** An open icon set instead of SF Symbols. |
| Materials and Liquid Glass | **Approximated.** |
| Window chrome | **Different.** Client-side decorations through SDL and the desktop. The macOS traffic lights are not reproduced: they are Apple trade dress. |

The honest target is structural parity: the same panes, commands,
shortcuts, behaviors and data. The look will resemble macOS, not be
pixel-identical.

### 5.6 Milestones

| Milestone | Content | Depends on | Rough size |
|---|---|---|---|
| **L0 Core extraction** (done, §5.7) | New target `YcodeIDECore`: move bucket 1 (16.5k lines) and split the view models out of bucket 2. An inotify `FileSystemWatcher`. A portable `Preferences` (colors and fonts as values). Run the moved `YcodeUITests` model tests on Linux. | – | M (1 round) |
| **L1 Shell skeleton** (done, §5.8) | A SwiftUI `WorkspaceView`: navigator, editor area (read-only text) and inspector; project navigator from `NavigatorTree`; issue navigator; build through `YcodeXcodebuild` in process. It runs on macOS with Apple's SwiftUI before OpenViews is ready, which proves the code is shared. | L0, R5, R7, R8, R9 (R12 for split views) | L |
| **L2 EditorKit v1** (first part done, §5.9) | Editable Swift files: storage, virtualized layout, carets, IME, undo, swift-syntax highlighting, find. Then LSP completion, hover, definition and diagnostics. | R14, L1 | XL (2–3 rounds) |
| **L3 Run and debug** | lldb-dap debug area (`YcodeDebug` is portable). Console. Run on the Ycode simulator **locally** on arm64 Linux (no ssh) or remotely from x86-64. A device canvas from `YcodeDisplayStream`. **Remote from x86-64: done (REMOTE-X86, 2026-10-31, §5.11)**. **Debugging Swift packages on Linux: done (B2-DEBUG, 2026-11-04)**: gutter breakpoints, the Debug and Breakpoint navigators, the variables view, the `(lldb)` prompt, the debug bar and Debug menu (`YcodeIDEShell/ShellDebugModel.swift`, `ycode-ide/DebugViews.swift`, `DebugGutter.swift`). Local arm64 run and debugging on the simulator remain. | L1, R12 | L |
| **L4 Editors and windows** | Project editor, scheme editor, plist and String Catalog editors, source control, Settings. Menus and toolbars. | R11, R12, R13 | XL |
| **L5 Previews, Gauge, assistant, IB, asset catalogs** | Port the remaining bucket 2 screens. Previews on Linux use the Ycode simulator path; the OpenViews renderer later serves Linux-native previews. | L4 | XL |
| **L6 Switch macOS to the SwiftUI shell** | Retire the AppKit shell screen by screen, once parity tests pass. | L4 | L |

**Pre-condition for any of this to be useful on Linux:** iOS app builds on
Linux need the user's SDK in place, plus resource compilers. See §6 #9.
Without them, the Linux IDE can edit any project but builds only packages
and resource-free targets.

### 5.7 L0 status (2026-10-30)

L0 is done. `YcodeIDECore` builds and its tests pass on macOS, x86-64 Linux
and arm64 Linux; `YcodeUI` depends on it and re-exports it, so the AppKit
shell's API and behavior are unchanged.

| What moved | Files | Lines |
|---|---:|---:|
| Bucket 1, whole files | 70 | 16,454 |
| Bucket 2 and 3 files whose model needed no AppKit: `Preferences`, `Preferences+Reference`, `DebugPresentation`, `ConsoleRows`, `Bookmarks`, `UntitledWorkspace`, `FileSystemWatcher` (the AppKit halves stay as YcodeUI extensions, 220 lines) | 7 | 1,469 |
| Model and view-model code split out of bucket 2 and 3 files: the project editor's model, report context and filters, device rows and lists, remote device sessions, Device Hub and preview commands, launch arguments, developer tools, completion and find models, preview canvas layout and settings, navigator bar specs, diff lines, toolbar fit, organizer sidebar | 28 | 1,974 |
| New: `IDEProcess`, `Trash` | 2 | 55 |
| **YcodeIDECore** | **107** | **20,034** |

`YcodeUI` went from 185 files and 54,204 lines to 113 files and 34,691
lines. 189 model tests moved from `YcodeUITests` to `YcodeIDECoreTests`.

At the UI edge, toolkit types became values: theme colors are `ThemeColor`
(sRGB, `#RRGGBB`), fonts are `EditorTheme.FontSpec`, click modifiers are
`MenuCommand.Modifiers`, and the app's quit notification is
`IDEProcess.willTerminateNotification`. `Preferences+AppKit.swift` keeps
the AppKit forms (`NSColor`, `NSFont`, `NSAppearance`,
`NSEvent.ModifierFlags`). The Linux back ends are an inotify
`FileSystemWatcher`, a freedesktop.org `Trash` for Discard, and a `/proc`
`ProcessGaugeSampler`.

What stays in YcodeUI and why:
- `CodingAssistantModel` and `CodingAssistantServices`: the services open
  the browser with `NSWorkspace`. They move once the URL opener is
  injected.
- `DebugNavigatorRows` and `SourceControlNavigatorModel`: they build
  `OutlineItem`s, the AppKit navigators' node class. L1's `NavigatorTree`
  views need a portable row type first.
- `MainThreadWatchdog`, `RemotePreviewSession`, `RemoteDisplayLink`, the
  live-preview window state, and the `WorkspaceWindowController` and
  view-controller extensions: these are window plumbing (bucket 3).

The types that are `@MainActor` (`Preferences`, `KeyBindings`,
`RecentProjects`, `WorkspaceSession`, `BookmarkStore`, `RemoteDeviceSessions`,
`SourceSymbolLocator`, `GaugeModel`) keep it. They own state that the UI
reads and mutates, or a mutable static, and none of them was `@MainActor`
because of AppKit.

L1 needs the following:
- a portable navigator row type to replace `OutlineItem`;
- an injected URL opener, so the coding assistant can move;
- the SwiftUI `WorkspaceView` on `WorkspaceSession`, `NavigatorTree`,
  `IssueNavigatorModel` and `ReportModel`.

### 5.8 L1 status (2026-10-31)

L1 is done. `ycode-ide <path>` opens a workspace window on Linux, on
OpenViews, over `YcodeIDECore`. It was driven with real X11 input
(`xdotool`) on x86-64 under Xvfb and with synthetic input through SDL's
queue on arm64 under a headless Weston (Wayland), in light and dark.

**Targets.**

| Target | Content | Builds on |
|---|---|---|
| `YcodeIDEShell` | The shell's view models, with no toolkit: `WorkspaceShellModel` (areas, the project navigator's expansion and selection, the open document, history, Find, issues, activity, build log and console, scheme and destination, commands), `ShellAppModel` (Welcome, Open, recent projects, the command-line path), `ShellCommand` (menu titles and shortcuts from `CommandTable` and `MenuTitles`), `SourceDocument` (lines of highlighted runs from `YcodeSyntax`), `SourcePalette` (Ycode Paper and Ycode Dusk), the navigator row values, `PackageBuildEngine` | macOS, Linux; tested on both |
| `ycode-ide` | The SwiftUI views, the menu bar, the toolbar, the app, and the Linux driver (`ShellDriver`) | Linux: OpenViews (`frameworks/swiftui`, a local path dependency added only when that folder is next to `ycode/`, so an rsync of `ycode/` alone still resolves). macOS: Apple's SwiftUI. It builds there but is not run, because GUI runs on the shared Mac are off limits. The macOS product is still the AppKit `YcodeApp`. |

**What the window does.**
- It opens from the command line (`ycode-ide <project, workspace, Package.swift or package folder>`), from the Welcome screen's recent list, or from File ▸ Open…. Open shows the toolkit's file dialog (`fileImporter`; on Linux OpenViews' own, since R13: a folder listing with a Go to path field, projects and workspaces chosen like files). The macOS build uses the system's.
- A `NavigationSplitView` holds the navigator (290), the editor over the debug area, and the inspector (260, `.inspector`). View ▸ Navigators / Debug Area / Inspectors and the toolbar toggle them.
- The selector bar has Project (⌘1), Find (⌘4) and Issues (⌘5), and they keep their indices in the full bar.
- The **Project navigator** is `NavigatorTree` through `List` and `DisclosureGroup`s whose expansion lives in the model. It opens with `NavigatorTree.initiallyExpanded`. `OutlineGroup` was not used: its expansion belongs to the container and no SwiftUI API sets an initial state. Selecting a file opens it. Navigate ▸ Reveal in Project Navigator (⇧⌘J) expands the file's parents and selects it.
- The **editor** was read-only for L1 (L2 replaced it, §5.9). It showed a jump bar, then the file's lines with a 48-point gutter, colored by `YcodeSyntax` (swift-syntax for Swift, line lexers for the others) as `Text` runs, built lazily. The colors are Ycode Paper in light mode and Ycode Dusk in dark mode, and keywords are bold. The line that Find or an issue points at gets the current-line color and is scrolled to. Go Back / Go Forward (⌃⌘← / ⌃⌘→, toolbar) use the core's `NavigationHistory`.
- The **Find navigator** is "Find › Text › Containing" with Aa (match case), the query field, and "In Package/Project/Workspace". Find in Workspace (⇧⌘F) shows it and focuses the field. Return runs `FindEngine` over `FindScopeResolver`'s workspace files, and rows fill in as files finish ("name (N)", then each match with its text in bold). Selecting a match opens the file at its line.
- The **Issue navigator** shows `IssueNavigatorModel.tree` from `WorkspaceSession.displayedIssues`: the project row, then targets, files and issues, each with its severity symbol and "file:line". Selecting an issue opens its line. Jump to Next / Previous Issue (⌘' / ⇧⌘') step through the issues in navigator order. A build with errors shows this navigator.
- The **toolbar** has the navigator toggle, Run | Stop, Back | Forward, the activity view ("<workspace>" over "Build Failed | Today at 12:10 AM", from `WorkspaceSession.activity`), the scheme › destination pop-ups (the core's lists), the issue capsule, and the inspector toggle.
- The **menu bar** has File (Open…, Close Project/Workspace/Package), Edit (the toolkit's), View, Find, Navigate, Product (Run, Test, Stop, Scheme ▸, Destination ▸, Build, Clean Build Folder…), Window (Welcome to Ycode) and Help. Titles, dynamic titles and shortcuts are the core's. A test checks that every command is in `CommandTable` and that no two commands share a shortcut. On Linux ⌘ is Ctrl (OpenViews' rule).
- The **debug area** shows the build log or the console, with a 28-point bottom bar. It opens when a build or run starts. ⇧⌘C shows the console.
- The **inspector** is a placeholder: Identity and Type (Name, Type, Lines, Full Path) and the workspace. *(LINUX-UI-PARITY, §5.10: the real File inspector, and the whole window laid out as the macOS IDE's.)*
- **Build** (⌘B, Product ▸ Build, toolbar) is `WorkspaceSession.build`, and **Run** (⌘R) is `WorkspaceSession.run`, which builds and then runs the product under lldb-dap with its output in the console. On x86-64 the demo package printed "Hello, world!", and the activity read "Finished running Greeter".

**Builds on Linux go through SwiftPM for packages, not `ycodebuild`.** On
Linux, `ycodebuild` cannot build a package. It lists only "My Mac" as a
destination. It refuses a package build without `-destination`, rejects
`platform=Linux`, and with `platform=macOS` it needs the `ycode-swb` helper
(swift-build), which on Linux has no macOS SDK to build against (it serves
`-showBuildSettings` since 1.0.0-beta.2). So the shell's engine on
Linux (`ShellBuildSetup.engine()`) is:
- `PackageBuildEngine` for packages: `swift build`, `swift package clean`
  and `swift test`. The terminal color sequences that the compiler writes
  even into a pipe are removed, and the summary errors ("Build failed",
  "<step> … failed with a nonzero exit code") become issues only when
  nothing else failed.
- `ycodebuild` for projects and workspaces, found as the core's test runner
  finds it.

`YCODE_IDE_ENGINE=ycodebuild` sends packages to `ycodebuild` too. The run
destination on Linux is "My Computer". A Linux host destination in
`ycodebuild` would let packages go through it.

**What OpenViews lacked** (found by L1). OV-R13 (2026-10-31) closed every
item, and the shell's workarounds are gone:

| # | Gap | L1 workaround | Since OV-R13 |
|---|---|---|---|
| 1 | No public way for an app in another package to be driven or photographed | `OpenViewsAutomation` (a separate commit) | Kept; R13 adds pointer moves (`move(to:)`) for hover and tooltips |
| 2 | A custom `ToolbarContent` type with a `body` did not compile | A `@ToolbarContentBuilder` property | `ToolbarContent` has a `body`; the shell's toolbar is `WorkspaceToolbar: ToolbarContent` |
| 3 | Shortcuts of items in a `Menu` inside `commands` worked only after that menu had been opened | View's Navigators / Debug Area / Inspectors inline between dividers | The commands host builds submenu items, so their shortcuts work at once; the shell has the three submenus again |
| 4 | `task(id:)` did not run on a view that appeared in the same update that changed the id | `onAppear` plus `onChange` | The cause was a `FocusState` write from the task scheduling no update; fixed. The Find navigator uses `task(id:)` |
| 5 | A row inside an expanded outline got no selection ID; folder rows were not selectable | An explicit `.tag` on leaf rows | Rows take their `ForEach` element's ID, folders included; `outlineInitialExpansion(_:)` (OpenViews' own API) sets initial expansion. The tag is gone |
| 6 | Identifiers set inside `List` rows were not in the accessibility tree | Drivers found rows by their text | A combined element (a row) takes the identifier set inside it, also over AT-SPI |
| 7 | No tooltips, no file dialog, no `toolbar(removing: .sidebarToggle)` (a 40-point bar over the navigator), toolbar `Label`s showed their titles | `shellHelp` a no-op; File ▸ Open… a path sheet | `help(_:)` tooltips; `fileImporter`/`fileExporter` on OpenViews' own dialog (File ▸ Open… uses it); `toolbar(removing:)`, and empty column bars are not drawn; toolbar labels show icons |
| 8 | Symbols missing | `ShellSymbols.portable` stand-ins | Drawn in OpenViews' set; the stand-ins are gone. `hammer` was also redrawn for the build bezel |
| 9 | No bundled monospace font | The system's | Noto Sans Mono (OFL-1.1) is bundled |

R13 also fixed a split-view update loop that the shell hit on every desktop
window (the sidebar toggle re-registered its toolbar each pass; 2048 passes
in 31 frames, now 3) and a double-click gesture that swallowed the next
click on another view.

**Tests.** `YcodeIDEShellTests` has 19 tests in 4 suites, which pass on
macOS and x86-64 Linux. They cover:
- the package tree and its initial expansion;
- opening a selected file with highlighting, the window title, and Reveal;
- history;
- Find in Workspace (rows, counts, match case, opening a match);
- a scripted build (the log, issue grouping, the activity text, the
  navigator switch, stepping through issues);
- area toggles with dynamic menu titles;
- Open, recents, and Close back to Welcome;
- parsing the command-line path;
- the command table (every command present, unique shortcuts, ⌘" as ⇧⌘');
- splitting lines, tokens to roles, and tabs;
- binary and missing files;
- the palettes;
- the SwiftPM arguments, activity texts, executable products, color
  stripping and summary errors.

The shell's runs (logs and screenshots outside the repository):
- x86-64 / Xvfb, real input (`xdotool`), light and dark:
  1. the window opens on the demo package;
  2. clicking a disclosure triangle and a file shows it highlighted;
  3. Ctrl+Shift+F, typing "Greeting" and Return gives "5 results in 3
     files", and a click opens the match at line 2;
  4. Product ▸ Build with the pointer shows the deliberate error ("Cannot
     convert value of type 'String' to specified type 'Int'", main.swift:8)
     in the Issue navigator and the capsule;
  5. clicking the issue opens line 8;
  6. the toolbar's inspector button and Ctrl+Shift+C work;
  7. Ctrl+R runs the clean package.
- arm64 / headless Weston, synthetic input, light and dark: steps 1–5.

### 5.9 What L2 (EditorKit) needs from L1: the plan

L1's editor is a `LazyVStack` of `Text` lines, one per line. It can show a
file but not edit it. L2 replaces `SourceView` with an EditorKit view on
OpenViews' text editing core (R14). The shell stays as it is:
`WorkspaceShellModel.document` becomes an editable buffer, and File ▸ Save
and `WorkspaceSession.noteFileEdited` follow.

1. **Storage (`YcodeEditorKit`, portable).**
   - A piece table with a line index and UTF-16 and UTF-8 offset maps (for
     LSP).
   - Undo grouping on OVText's `TextEditingModel` rules.
   - The core's `LineIndex`, `SourceChanges` and `TextCommands`, and
     `YcodeSyntax`'s `TypingRules` (auto-indent, bracket pairs; the editor
     typing settings are in `Preferences`).
   - Edits go to `SyntaxDocument.replace`, which re-highlights
     incrementally. L1's per-line runs (`SourceDocument.runs`) are the
     drawing input.
2. **Layout, virtualized.**
   - Lay out only the visible lines plus a margin, through OVText (one
     paragraph per line, cached by the line's text and runs), and drop
     cached lines that an edit touches.
   - Wrapping is optional; line height is fixed per font.
   - This needs from OpenViews: the scroll geometry
     (`onScrollGeometryChange`), and a drawing surface for glyph runs,
     selections and carets (`Canvas` with resolved text, or a public
     OVText run API).
3. **Input.**
   - Carets and selections from pointer drags.
   - Key bindings: OpenViews has no `onKeyPress` yet, and EditorKit needs
     it or a public text-input client protocol for custom views.
   - IME through SDL's text-editing events (R7 has them for `TextField`).
   - Multiple carets.
   - The clipboard and the Edit menu, through R11's focused-view editing
     actions.
4. **Editor chrome.**
   - The gutter: line numbers, the change bar, breakpoints (the core's
     `BreakpointStore`), issue markers.
   - The find bar (`EditorFind`).
   - Folding (`FoldRegions`) and placeholders (`Placeholders`).
   - The minimap later.
5. **Language features.**
   - `YcodeLanguage` with sourcekit-lsp on Linux, started by
     `WorkspaceSession`.
   - Live issues in the Issue navigator and inline.
   - A completion pop-up (an OpenViews pop-up window, R8), hover, Jump to
     Definition.
6. **Shell changes for L2.**
   - File ▸ Save.
   - Edited-file markers in the navigator and the jump bar.
   - The editor's focus for the Edit and Find menus.
   - Jump to Line (⌘L).
   - Remove the read-only notes from §5.8.
7. **OpenViews follow-ups that L2 depends on.** Done in OV-R13: items 3, 4
   and 5 of the table above, `onKeyPress` (focused view outwards, before
   the focused control; handled characters are not typed), scroll geometry
   (`onScrollGeometryChange`, R9), the bundled monospace font, the outline
   initial-expansion hook, and `GraphicsContext.draw(_ text:)` for text
   runs. `ov-editor-bench` (in `frameworks/swiftui`) measures the pattern
   L2's layer will use — a viewport-sized `Canvas` at the scroll offset
   drawing only the visible lines — on a 10 000-line file in a 1400 × 900
   window scrolled 37 points per 60 Hz frame (release builds, headless
   back end with the window's software presenter):

   | Machine | Scale 1 (mean, p95) | Scale 2 (mean, p95) | Page jumps, scale 1 |
   |---|---|---|---|
   | x86-64 workstation | 6.2 ms, 8.0 ms | 12.5 ms, 16.9 ms | 31 ms |
   | Thor (arm64) | 7.1 ms, 9.2 ms | 11.5 ms, 15.7 ms | 39 ms |

   Before R13's glyph run cache the same frames took 24.4 ms (scale 1) and
   50.9 ms (scale 2) on the workstation: the rasteriser filled every glyph
   outline each frame. A page jump (three screens a frame, only new lines)
   still draws outlines. Not done: `TextRenderer`/`Text.Layout` (the
   `Canvas` route is enough for L2), an IME client for custom views (L2
   item 3), multiple carets.
8. **Predictive completion (PREDICT).** The engine is portable and tested
   on Linux (`YcodeCompletion`); Linux has `ycode complete` and the MCP
   tool `complete` now. L2 drives one `PredictionSession` per editor
   (`specs/ide/predictive-completion.md` §7.2):
   - Settings from `PredictiveCompletionSettings.load(from:)` (the user
     default `Ycode.predictiveCompletion`), the shared Ollama address from
     `assistantOllamaURL(in:)`; `onSuggestionChange` redraws,
     `onStatusChange` feeds the status line.
   - Each edit calls `textDidChange(snapshot, location:removed:inserted:)`
     (UTF-16, before the caret-move notification); caret moves outside an
     edit call `selectionDidChange`.
   - Tab, ⌥Tab, ⌃Tab call `acceptText(.shown | .all | .word)` and insert
     the text at the anchor as an undoable edit; Escape calls `dismiss()`;
     ⌃⌥Space calls `forceRequest`; Option held draws all lines.
   - The `Canvas` layer draws the suggestion from its anchor (collapsed
     with `PredictionSession.collapsed`), covering and redrawing the rest
     of the caret line, extra lines on a filled block; the Settings rows
     of the spec's §3.5 go into the shell's settings.

#### Done in L2 (LINUX-EDITOR, 2026-11-03)

What a beta tester gets in `ycode-ide` on Linux. Unless a line says
otherwise, it was driven for real on the x86-64 workstation (private Xvfb,
`xdotool` keystrokes and clicks, light and dark, screenshots looked at) and
has unit tests.

- **`YcodeEditorKit`** (portable, no toolkit; tested on Linux and macOS):
  - `EditorBuffer`: the text in `SyntaxDocument` (its UTF-16 array and line
    index, so every edit re-highlights incrementally), the selection, marked
    text and undo. Undo groups follow OVText's rules (typing coalesces until
    the caret moves; deletions by direction; paste, cut and typing rules
    are their own steps); "unsaved" follows undo and redo back to the saved
    state. The typing rules are the AppKit editor's `TypingRules` unchanged
    (auto-indent, closing brackets and quotes, stepping over, enclosing a
    selection, Tab and Shift-Tab, Comment Selection).
  - Movement by character (grapheme clusters; a CRLF is one), word, line
    (Home goes to the text first, then column 0), document; vertical moves
    keep their column; word and line selection, and drags that extend by
    words or lines.
  - `EditorFile` and `EditorDocument`, saving: the bytes go to a temporary
    file beside the target, are flushed and read back, then renamed over
    it, and the directory is flushed: a crash or a full disk leaves the old
    file or the whole new one. Links stay links, the mode and owner carry
    over. A folder that takes no new file gets an in-place write after a
    backup copy. UTF-8 with or without a byte order mark, UTF-16 with one,
    and CRLF files (edited as LF) save back to their own form; a file with
    mixed line endings keeps its bytes. A file that is not valid UTF-8 is
    shown read-only (saving its replacement characters would destroy it).
    A save that fails leaves the buffer as it was, unsaved, and says why.
  - Changes on disk: about once a second the open files are compared with
    what was read (size, time, inode, then a hash, so a touched file is no
    change). An unedited file follows the disk; an edited one shows a banner
    (Reload from Disk, undoable; Keep My Version). A save over a change on
    disk asks first (Overwrite or Cancel); a deleted file can be saved again.
  - `EditorRecovery`: unsaved text is copied 1.5 s after typing pauses to
    `$XDG_STATE_HOME/ycode/recovery` (private files). After a crash, opening
    the file brings the text back as an undoable edit, with a banner
    (Discard). Saving, reverting or giving up the changes removes the copy.
- **The editor view** (`ycode-ide/SourceEditorView.swift`): a viewport-sized
  `Canvas` drawing only the visible lines (§5.9 item 2), the gutter over the
  text, the current line, the selection, find matches, the caret (it blinks,
  rests after 10 s), the build's issues (a dot in the gutter, a tinted line,
  the message at the line's end), a scroll indicator, and the minimap (a
  band shows what is in view; dragging it scrolls, not driven). Colors
  follow typing (seen live: a new `let`, string, comment and `struct`). On OpenViews the editor
  scrolls itself and draws again from the last layout when typing, the
  caret or scrolling change it (`TextSurfaceConnection.setNeedsDisplay`), so
  a keystroke does not lay out the whole window.
- **Input** (OpenViews' new `textSurface`, `textSurfacePointer`,
  `textSurfaceScroll`, `09-open-design.md`): typed and committed text, the
  Linux text keys (arrows, Ctrl+arrows, Home/End, Ctrl+Home/End, Page
  Up/Down (not driven), Backspace and Delete by character or word, Ctrl+A/C/X/V/Z,
  Ctrl+Shift+Z (Redo; Ctrl+Y is ⌘Y, Debug ▸ Deactivate Breakpoints, and goes
  to the menu bar), Ctrl+Insert, Shift+Insert, Shift+Delete), the
  Edit menu's items, a context menu (Cut, Copy, Paste, Select All; not
  driven), the
  system clipboard, click, drag (scrolling at the edges), shift-click,
  triple-click a line, a click in the gutter selects its line. Double-click
  a word has unit tests only: under the test Xvfb the two clicks reached the
  app bunched or more than half a second apart. Input-method composition goes through SDL's text-editing events
  (marked text underlined at the caret, the candidate window placed at the
  caret). Tried with IBus on Wayland (GNOME, 2026-11-04,
  `ycode/scripts/linux-input-method/run.sh`): Cangjie 5 and the US
  international layout's dead keys compose, with the marked text shown, in
  the source editor and in the Find field. That test found CJK text drawn
  as nothing when the system's only CJK fonts were CFF; the font fallback
  now prefers a face it can draw. Issue 23 (2026-11-04) ran the whole
  matrix, IBus and Fcitx 5 on X11 (Xvfb, `run-isolated.sh x11`) and on
  Wayland (IBus in a test GNOME Shell, `run.sh`; Fcitx 5 in a headless sway,
  `run-isolated.sh sway`), each with a Chinese input method (Cangjie 5 or
  Pinyin) and dead keys, in the editor and the Find field: all compose and
  commit. It found and fixed three faults: the caret rectangle given to the
  input method was set only when focus changed (the candidate window opened
  at the first line of a new file), so the window now passes the caret on
  after each frame where it moved; SDL's X11 driver asked XIM for no
  composition events (the hint `SDL_IME_IMPLEMENTED_UI=composition` is now
  set, so marked text shows at the caret on X11 too); and keys that reached
  a text field during a composition edited or submitted it. The candidate
  window's place was checked on the X11 screen (it opens at the caret's
  bottom edge, Fcitx 5's 10 points lower with its shadow), in the rectangles
  the IDE sends over text-input-v3, and in the rectangle sway gives Fcitx 5.
  Left as they are: Fcitx 5's XIM keeps the composition in its own window
  unless its "on the spot" option is on, and an engine's own shortcuts come
  first (IBus Pinyin and Fcitx 5's traditional-Chinese switch take
  Ctrl+Shift+F, Find in Workspace).
- **The shell:** File ▸ Save (Ctrl+S), Save All (Ctrl+Alt+S), Revert to
  Saved… and Close Document (these two with unit tests only); the unsaved mark in the jump bar, on the file's
  navigator row and in the window title ("— Edited"); unsaved text stays
  while other files are shown; closing the workspace, opening another, and
  quitting ask Save / Don't Save / Cancel (driven: Ctrl+Q; the last window's
  close button takes the same path but was not driven, the test Xvfb has no
  window manager); a build, test or run saves first, and a save
  that needs the user stops it. Find ▸ Find… (Ctrl+F), Find and Replace…
  (Ctrl+Alt+F), Find Next/Previous (Ctrl+G, Ctrl+Shift+G), Use Selection for
  Find (Ctrl+E): a bar with text or regular expression, matching word,
  matching case, "N of M", Replace (then on to the next) and All (one undo
  step; `$1` templates with regular expressions). Navigate ▸ Jump to Line…
  (Ctrl+L; "120" or "120:8"). Editor ▸ Structure: Comment Selection,
  Shift Left/Right, Move Line Up/Down. Choosing an issue puts the caret at
  its line and column.

- **Live issues** (`WorkspaceShellModel.startLanguageService`): the app starts
  sourcekit-lsp for the workspace (`YCODE_IDE_LSP=0` leaves it off; it must be
  on the `PATH`); open files are sent to it and updated 0.3 s after typing
  pauses, and its errors and warnings show in the Issue navigator and in the
  editor without saving or building. Driven on the sample package: a type
  error typed into a file showed in about 10 s (the server's first analysis)
  and went away on undo.
- **Code completion** (`EditorCompletions.swift`, the list in
  `SourceEditorView`): Ctrl+Space or Escape asks sourcekit-lsp at the caret
  (the server gets the current text first); the list filters as you type
  (prefix matches, then substring), Up/Down/Page Up/Page Down move, Return or
  Tab or a click inserts the item over the word typed (snippet stops become
  plain text, the caret at the first stop; one undo step), Escape or any
  other caret movement closes it. Requests give up after 3 s and a newer one
  replaces an older one; typing never waits. Opening the list after a "." is
  a setting, off by default for the beta. Driven: `t.` listed `Trail`'s
  members, "est" filtered to `estimatedMinutes`, Return inserted it, undo
  took it out; with sourcekit-lsp killed (`kill -9`), typing, Ctrl+Space and
  saving went on (the app ignores SIGPIPE so a dead server's pipe cannot end
  it; its last live issues stay until the workspace is opened again).
- **Settings window** (Ycode ▸ Settings…, Ctrl+,; `ShellSettingsView`): font
  size, theme, indent with spaces or tabs, tab and indent widths,
  syntax-aware indenting, closing brackets and quotes, and predictive
  completion's switch, model source (Ollama, llama.cpp server,
  OpenAI-compatible), address and model, and whether code completions open
  after a period. The same user defaults as the macOS
  IDE and `ycode complete`; open editors take a new font, theme or tab width
  at once (driven: font size and tab width, light and dark).

Measured (x86-64 workstation, release build, 1400 × 926 window under Xvfb,
`YCODE_IDE_EDITOR_BENCH`, frames timed in the window: update, layout,
drawing and presenting):

| 50,000-line Swift file | Software renderer (`OV_RENDERER=software`) | Vulkan on llvmpipe (`OV_VULKAN_DEVICE=cpu`) | Vulkan on the RTX 4060 Ti, presented to Xvfb |
|---|---|---|---|
| Open (read, lex) | 62 ms; first frame 300 ms later | same | same |
| Scrolling, 37 points a frame | 15.0 ms mean, 16.2 ms p95 | 15.8 ms mean | 53 ms mean |
| Jumps to far lines | 19.2 ms mean, 21.3 ms p95 | – | 57 ms mean |
| Typing, key to its frame | 18.9 ms mean, 21.9 ms p95 | 20.3 ms mean | 57 ms mean |
| Undo of 500 edits | 25–38 ms | same | same |
| Save (2 MB) | 12–28 ms | same | same |

Before the redraw-only path every keystroke and scroll step laid out the
whole window: 111 ms a frame. The last column is the default renderer on
this machine (the GPU is preferred), but its frames go to a virtual X server
that the GPU cannot present to directly, so most of the 53 ms is that copy;
a desktop with the GPU driving its display was not measured (the owner's
session was left alone). `OV_RENDERER=software` is the fallback if a desktop
shows the same cost. Swift files
over 20,000 lines are colored by the lexer only (`EditorBuffer.parserLineLimit`):
swift-syntax's pass over a 50,000-line file took 480 ms after each pause in
typing, on the main thread.

Not done in L2 so far: hover, Jump to Definition, predictive completion in the
editor, folding, placeholders, multiple carets, line wrapping, the change
bar and breakpoints in the gutter. Known: under
the test Xvfb, `xdotool` clicks sometimes arrive bunched in one read of
the event queue; OpenViews' filter for duplicated clicks (QA B4) then drops
the second click of a double-click. The filter now ignores clicks read
after a long frame, when their times are not reliable.

### 5.10 Linux IDE parity with Ycode's macOS IDE (LINUX-UI-PARITY, 2026-10-31)

The L1 shell worked but looked "chopped": phone-sized text, OpenViews'
generic window toolbar with titled items under the menu bar, a three-icon
selector, `List` rows at the phone's metrics, a placeholder inspector,
Paper/Dusk instead of the default theme. This round lays the Linux window
out as **Ycode's own macOS IDE** lays out its window (the reference here is
our AppKit IDE, which follows `specs/ide/*.md`; Apple's Xcode was not
observed), and moves the values both IDEs need into `YcodeIDECore`.

**Method.**
- **Paired screenshots.** `LinuxParityProbeTests` (YcodeUITests, opt-in
  with `YCODE_PARITY_DIR` and `YCODE_PARITY_PACKAGE`) opens the Greeter
  package of `ycode/scripts/linux-ui-parity/make-demo.sh` in a real
  workspace window at 1400 × 900 and photographs each state offscreen
  (`cacheDisplay` of the window's frame view; the window is never put on
  screen), light and dark, with a frame dump of every view. On Linux,
  `ycode-ide` with `YCODE_IDE_PARITY=<prefix>` (`ShellDriver.parity`) walks
  the same states through the model and photographs them under Xvfb
  (`scripts/linux-ui-parity/linux-run.sh`). The Linux window is 1400 × 926:
  OpenViews draws the menu bar in the window (26 points), so the area under
  it is the macOS window's size. `scripts/linux-ui-parity/compose.py`
  pairs the images (left macOS, right Linux; light over dark) and scores
  them.
- **Scores.** *Differing pixels*: the share of the 1400 × 900 pixels that
  differ after a Gaussian blur of radius 1.5 (a pixel differs when a
  channel differs by more than 32 of 255; the Linux menu bar is left out;
  for Welcome the panel's 480 × 632). Plain areas dominate it, so a second
  score, *differing ink*, is the same share among the pixels where either
  image departs from its own local background (text, icons, lines, fills).
  Ink scores stay well above zero even for a near match: two typefaces and
  two rasterizers never put the same antialiased pixels down, and a one-point
  offset of a line of text changes most of its ink.
- **Limits of the reference.** `cacheDisplay` does not draw the glass
  material (the capsules appear as hairline outlines on the area's color,
  so the shell draws them that way), and an offscreen window is inactive:
  its sidebar labels and toolbar glyphs are the inactive greys. The shell
  keeps active label colors for text (black / white) and takes the greys
  for glyphs. The system menu bar, menus and the open panel are not part of
  a window and cannot be captured offscreen: the Product menu and File ▸
  Open… states are Linux only and are compared by content (the menu's items
  are the AppKit IDE's, from `CommandTable`). The shell has no Settings
  window, so Settings is macOS only.

**Scores** (before: L1 as merged at `54ffbd32`; after: this branch):

| State | Light before | Light after | Dark before | Dark after |
|---|---:|---:|---:|---:|
| welcome | 10.3 % (ink 69 %) | 2.2 % (ink 40 %) | 41.5 % (ink 70 %) | 2.3 % (ink 41 %) |
| workspace | 5.4 % (ink 61 %) | 0.6 % (ink 27 %) | 2.7 % (ink 56 %) | 0.6 % (ink 25 %) |
| file | 9.1 % (ink 62 %) | 2.1 % (ink 28 %) | 7.9 % (ink 65 %) | 2.2 % (ink 29 %) |
| inspector-hidden | 6.9 % (ink 63 %) | 0.9 % (ink 21 %) | 4.0 % (ink 63 %) | 1.0 % (ink 21 %) |
| find | 11.0 % (ink 58 %) | 2.8 % (ink 30 %) | 10.3 % (ink 61 %) | 3.6 % (ink 34 %) |
| issues | 9.1 % (ink 62 %) | 2.3 % (ink 30 %) | 8.0 % (ink 65 %) | 2.5 % (ink 32 %) |
| debug | 11.2 % (ink 63 %) | 2.9 % (ink 33 %) | 10.3 % (ink 57 %) | 3.1 % (ink 34 %) |
| bezel | 11.6 % (ink 59 %) | 3.2 % (ink 31 %) | 9.7 % (ink 57 %) | 3.4 % (ink 35 %) |
| product-menu, sheet | Linux only (the macOS menu and open panel are not capturable) | | | |
| settings | macOS only (the shell has no Settings window) | | | |

Pairs (outside the repository, next to the worktrees):
`.claude/worktrees/linux-ui-parity-<state>-{before,after}.png` for welcome,
workspace, file, inspector-hidden, find, issues, debug, bezel,
product-menu, sheet and settings.

**Checklist** (✔ fixed, ≈ approximated, ✘ not done, with the reason):

| # | Item | Status | Now |
|---|---|---|---|
| 1 | App name | ✔ | "Ycode" in the menu bar and its items (OpenViews reads `OV_APP_NAME` after the `App` value is made; the shell sets it). |
| 2 | Window chrome | ≈ | No traffic lights (Apple trade dress, §5.5); the first 96 points of the navigator's toolbar band stay empty so the items line up. Client-side or server-side decorations come from the desktop. |
| 3 | Toolbar layout | ✔ | No OpenViews window toolbar: each column draws its part of the toolbar in a 52-point band, as the AppKit toolbar tracks the split view (Navigators \| Coding Assistant and Run \| Stop over the navigator; Back \| Forward, the activity view, New Conversation, scheme › destination, Add Editor and Editor Options, the editor modes over the editor; the inspector toggle over the inspector). Items 36 tall at y 8; capsule positions within 1–2 points of the macOS window's. Items move into the center band when the navigator or inspector is hidden. |
| 4 | Toolbar items icon-only, glyphs | ✔ | `WorkspaceChrome.leftPanes`, `.runStop`, `.history`, `.newConversation`, `.addEditor`, `.editorOptions`, `.editorModes`, `.inspectorToggle`: symbols and tooltips shared with the AppKit toolbar. The pill under segments that are on (Navigators, Canvas). |
| 5 | Activity view | ✔ | Package glyph, the name in 13-point bold, the activity in 11 points: "Build Failed • Today at 3:26 AM" (`WorkspaceChrome.activityFinishedText`, now the AppKit view's too). |
| 6 | Scheme › destination | ✔ | One capsule with two pop-ups (up/down chevrons) and the issue counts inside it, as on macOS. The destination's name differs by design ("My Computer" on Linux, "My Mac" on macOS). |
| 7 | Navigator selector bar | ✔ | The nine navigators (`WorkspaceChrome.navigatorSymbols`, the AppKit list), a 278 × 30 capsule 6 from the sides at y 51, icons 30 apart, the selected one accent-colored in a 30 × 24 pill; the selector's tooltips (`NavigatorBars.selectorToolTips`). The six navigators the shell does not have show their empty states (`NavigatorBars.specs`). |
| 8 | Outline rows | ✔ | The shell draws its own rows (`OutlineRows`, `NavigatorOutline`): 22 points, 12 per level, the triangle at x 12, a 16-point icon at x 25, the label at x 45 in 13 points, the first row 7 below the selector (`WorkspaceChrome`). Symbols and accent tints as the AppKit outline (`WorkspaceChrome.symbol(for:)`, shared); file names without extensions (`Preferences.fileExtensions`). Up, Down, Left and Right keep keyboard navigation. Measured: icons and labels at the same x as on macOS, rows within 2 points. |
| 9 | Find navigator | ✔ | "Find › Text › Containing" and "Aa", the search field, "In Project" and the count, rows "name  (N)" (two spaces, bold, `doc.text`), matches with `text.magnifyingglass` wrapping onto two lines. |
| 10 | Issue navigator | ✔ | "Greeter  1 issue" (bold, `app.dashed`), the file row, the issue with its severity symbol, two lines. |
| 11 | Navigator bottom bar | ✔ | The "+" circle (31 × 30) and the 242-point filter capsule with its options pull-down and the navigator's toggles, 7 above the bottom. |
| 12 | Jump bar | ✔ | Related Items, then the core's path (`WorkspaceChrome.jumpPath`, now the AppKit window's too) with symbols, "No Selection" for the symbol; the issue stepper once there are issues; a 31-point band whose first line is the toolbar's edge (y 52), the separator at y 83 — both exactly where the macOS window has them. |
| 13 | Gutter, editor font and line height | ✔ | Numbers 10 points ending 25 into the 48-point gutter, text 9 after it, 15-point lines, 12-point Noto Sans Mono: line tops within 1 point and columns within 1 point of the macOS editor (advance 7.2 against 7.24). The current line is highlighted. |
| 14 | Editor colors | ✔ | The selected theme (`Preferences.theme`, as the AppKit editor); "Ycode Default" has no colors of its own, so `WorkspaceChrome.defaultThemeColors` gives its system colors as values read from the macOS editor (keywords bold). Paper and Dusk remain choices. |
| 15 | Minimap | ≈ | 112 points with its separator; lines as bars (the AppKit minimap draws miniature text and declaration names). |
| 16 | Debug bar | ✔ | 36 points under the editor (at the window's bottom with the debug area hidden): the breakpoints glyph, "Line: 1  Col: 1", the debug-area toggle. |
| 17 | Debug area | ✔ | Variables and console side by side over 28-point bottom bars ("Auto", eye, info, filter; eye, filter, trash, the layout toggles), 135 points when opened: the bar at y 728 and the area at y 764, as on macOS. The console shows the build log until a run writes there (no Report navigator on Linux yet). |
| 18 | Inspector | ✔ | The tab capsule (File, History, Quick Help) with a 78 × 24 pill; the real File inspector (`WorkspaceShellModel.fileInspector`: Identity and Type — Name field, Type and Location pop-ups, the file name, Full Path with the reveal button — and Text Settings — encoding, line endings, indentation, widths), 12-point insets, an 80-point key column, 11-point text; "Not Applicable" without a file. |
| 19 | Split dividers, separators, backgrounds | ✔ | 290 / 850 / 260 (OpenViews' flexible frame now answers an unspecified proposal with its ideal width, so the split view takes the ideal widths); sidebar and content colors and hairlines as sampled from the macOS window. |
| 20 | Materials | ≈ | Flat: capsules are hairline outlines on the area's color, as the offscreen reference shows them (pixel identity with glass is a non-goal, §5.5). |
| 21 | Fonts and sizes | ✔ | Desktop text styles (body 13, headline 13 bold, …) and Inter for the UI: 13-point widths match the macOS IDE's ("GreeterCoreTests" 104.7 points on both); 11 points and less get +0.35 tracking (the macOS font spaces small sizes wider). Inter renders a little lighter than the macOS text at 13 points; Medium would match the darkness but is wider and wraps rows, so rows stay Regular and only the bezel title is Bold. |
| 22 | Menu bar and items | ✔ | Every menu of the AppKit menu bar from `CommandTable`: Ycode, File, Edit, View, Find, Navigate, Editor, Product, Debug, Integrate, Window, Help, with their items, order, separators, submenus, dynamic titles and shortcuts; the shell's commands enabled, the others listed disabled (as the AppKit IDE lists what it does not perform). OpenViews keeps its own Undo/Redo/pasteboard items and Quit. Menu item metrics are OpenViews' (26-point rows): the macOS menus could not be captured to measure. |
| 23 | Separators in menus | ✔ | OpenViews laid `Divider` out but never painted it; it is now drawn, and in menus it is a separator row. |
| 24 | Sheets and alerts | ≈ | File ▸ Open… is OpenViews' own file dialog; the macOS IDE uses the system's open panel (not capturable). |
| 25 | Welcome | ✔ | The macOS Welcome window's layout as a 480 × 632 panel centered in the window: the icon (Ycode has none yet; the generic blue folder, as the macOS window shows), "Ycode" 34 bold, the version, Open… / Clone… / New Project (107/107/130 × 36, 8 apart, at y 242), the recent box at x 60–420, y 295–572 with 48-point rows (`RecentProjects.folderText`), the round close button. Recent projects now persist on Linux (`UserDefaults` is synchronized). |
| 26 | Build bezel | ✔ | Unchanged geometry (200 × 200 centered); the title in Bold on Linux. |
| 27 | Focus rings, selection colors, scroll bars | ≈ | Rows select with a rounded grey fill inset 6; scroll indicators hidden in navigators, editor and console (macOS overlay scrollers are hidden at rest). Focus rings are OpenViews'. |
| 28 | Settings | ≈ | The Settings window (Ctrl+,) with the macOS panes in their order, Accounts included since 1.0.0-beta.3 (the empty list, + and its sheet); Components and Simulators are macOS only. |

**Shared constants** (`YcodeIDECore/Model/WorkspaceChrome.swift`, read by
both IDEs; the AppKit IDE's values are unchanged): window size, navigator
and inspector widths, toolbar band and item metrics, selector and filter
bar metrics, row metrics, jump bar band, gutter, minimap fraction, debug
bar and bottom bars, inspector insets and key column; the navigator,
inspector and toolbar symbols and tooltips; row symbols, the jump path,
file type names and Text Settings items; the activity line; "Ycode
Default" as values. The AppKit IDE now takes `NavigatorAreaController.symbols`,
`InspectorAreaController.symbols`, `typeName(for:)`, the toolbar's images
and tooltips, `jumpPath(for:)`, `jumpBarFileTitle`, the jump bar band, the
debug bar and bottom bar heights and the activity line from it.

**OpenViews changes** (`frameworks/swiftui`, with `LinuxUIParityTests`):
desktop text-style sizes on window-system hosts (Apple's HIG macOS sizes;
the phone table stays for the headless host and the goldens); a flexible
frame's ideal size answers an unspecified proposal; Inter 4.001 bundled
(Regular, Medium, SemiBold, Bold; SIL OFL 1.1, `Inter-OFL.txt`) with
`FontCatalog.setFamilies(_:for:)` for an app's UI family (Noto Sans stays
the default and the first fallback); the app name read lazily; `Divider`
painted; 32 new symbols in Ycode's own set (toolbar, selector, jump bar,
debug bar, inspector, navigator bar glyphs).

**Fonts.** UI: Inter 4.001 "Inter 24pt" static faces (SIL OFL 1.1,
Copyright 2016 The Inter Project Authors). Source: Noto Sans Mono (OFL
1.1, bundled since OV-R13). No Apple font is used or copied.

**What remains.**
- The minimap's miniature text and declaration labels.
- Menu metrics (row height, font) against the macOS menus: needs a
  dirty-room or on-screen measurement the clean room cannot take.
- Glass: blur and tint of the material (R15).
- Text rendering weight: OpenViews' rasterizer has no stem darkening, so
  13-point text is lighter than on macOS.
- Settings ▸ Components and Simulators, the Report navigator (the build log has no home but the
  console), the six navigators the shell lacks.

---

### 5.11 L3, remote from x86-64 (REMOTE-X86, 2026-10-31)

- **Where things run**: the device on the arm64 host (`ycode-simd`, KVM)
  behind `ycode-simhost`; the IDE, the build and the device window on the
  x86-64 PC. They talk over Ycode's own link (`specs/simulator/sim-link.md`:
  Noise XX with pinned Ed25519 identities, pairing codes, TCP 47800 for
  control and input, UDP 47801 for encrypted frames and sound); ssh remains
  a fallback (`scripts/ycode-sim-try` runs on Linux).
- **The Linux viewer** (`display-stream.md` §13): the device in its frame,
  fit / point / pixel scale, touches, multi-touch, keys, buttons, rotation,
  screenshots, the device's sound (Opus, §15), JPEG tiles or H.264 (NVENC on
  the host, NVDEC in the viewer, §14).
- **Run from the Linux IDE**: each paired host's devices are destinations;
  Run builds the iOS Simulator app on x86 (`scripts/ycode-ios-build-linux`,
  the user's SDK, §6 #9), uploads it, installs and launches it, and opens the
  device window (`YcodeIDEShell/ShellRemoteRun.swift`). The window is a
  separate SDL window; an OpenViews view of the device canvas is follow-up.
- **Latency** (`display-stream.md` §16): the stream adds 6–10 ms p50 from the
  guest's finished frame to the x86's present (under one guest frame); sound
  and picture within 3 ms p50.
- Open: debugging an app on the remote device from the Linux IDE (the debug
  stub exists, `debug-stub.md`; the link does not carry it yet), the
  microphone, an embedded canvas view.

## 6. The top 15 gaps

Ranked by value to a developer using Ycode on Linux **and** macOS. Each
entry is one agent round unless it says otherwise.

| # | Gap | Why it matters | Proposed round | Depends on | Effort |
|---|---|---|---|---|---|
| 1 | **Package products in the PIF**, then Swift macros and build-tool plug-ins | Projects that use SwiftPM do not build through swift-build. This affects most real apps, on both OSes. | **PIF-PKG**: express package products as target references in `XcodePIF`, the way swift-build's own SwiftPM PIF does (open source, level 1). Make `FallbackEngine.supports` detect anything still unsupported. Then **PIF-PLUGINS**: macro and plug-in trust. | – | L |
| 2 | **Build context for sourcekit-lsp** in `.xcodeproj` workspaces | Completion, definition, rename, live issues and C-family support are weak in every app project. | **LSP-BSP**: a Build Server Protocol server in Ycode (sourcekit-lsp supports BSP; open source, level 1) that answers compiler arguments from the PIF and swift-build. Add `-showBuildSettingsForIndex` to `ycodebuild` on the way. | #1 helps | L |
| 3 | **Debugger on the Ycode simulator** (done, SIM-DEBUG 2026-10-30: `specs/simulator/debug-stub.md`) | The main destination has no breakpoints. | **SIM-DEBUG**: a gdb-remote stub in `ycode-simd` (the protocol and LLDB's extensions are documented in LLDB's open source, level 1), built on the existing thread and task suspension. Then IDE wiring: `lldb` `process connect` through `lldb-dap`. | Threads work (done) | XL (2 rounds) |
| 4 | **Portable IDE core** (L0) | Unblocks every Linux IDE step and adds Linux tests of IDE logic now. | **IDE-CORE**: `YcodeIDECore` target, inotify watcher, portable preferences. | – | M |
| 5 | **Editor typing and highlighting** | ~~No auto-indent or bracket pairing; a lexer for 3 languages only.~~ **Done** (EDITOR-TYPING, 2026-10-30): `YcodeSyntax` (swift-syntax for Swift, line lexers for eleven more languages, incremental), typing rules in the macOS editor. Left: LSP semantic tokens. | **EDITOR-TYPING**: an indentation and pairing engine in the core; a portable `YcodeSyntax` module (swift-syntax and tree-sitter) behind the macOS editor. | #4 | M |
| 6 | ~~**Project navigator file operations**~~ (done, NAV-OPS 2026-10-30) | You could not add existing files, make groups or delete items. | **NAV-OPS** done: Add Files, New Group (with or without folder), Group/Folder from Selection, delete (move to trash or remove reference), rename in place, drag to move, sort, all undoable (`specs/ide/navigators.md` §Ycode implementation). Convert ▸ To Group / To Folder / Preflight and Cut + Move Item Here done too. | – | – |
| 7 | **App-hosted and UI tests** on the Ycode simulator and through `ycodebuild` — *app-hosted done (TEST-HOST, 2026-10-30); UI tests open* | Most iOS app tests are hosted. They fail today outside Apple's xcodebuild. | **TEST-HOST**: run the test bundle injected into the host app on the Ycode simulator (`TEST_HOST`, `XCTestConfiguration` facts from `test-actions.md`, plus a dirty-room addendum if needed). Then UI tests through the simulator's HID input. | Simulator app launch (done); #3 for debugging tests | L–XL |
| 8 | **OpenViews desktop rounds** (R8–R10 and the proposed R11–R15) | Without them there is no Linux IDE. | One round each, owned by the OpenViews track. R11 (commands and menus) and R12 (split views, outline, table) come first. | R5, R7 (in progress) | XL (6–8 rounds) |
| 9 | **Resource compilers for Linux builds** | iOS apps with assets, String Catalogs or storyboards cannot build on Linux. | ~~**RES-STRINGS**~~ done (2026-10-31): `ycode strings` compiles catalogs and generates symbols for swift-build, extracts from source, converts tables; Convert to String Catalogs and Refresh from Source in the IDE (`specs/ide/string-catalog.md` §C). An iOS app with a catalog built for the simulator on x86 Linux with a copy of the user's SDK; the non-strings settings that build needed are recorded in §C.7 for a LINUX-SDK task. **RES-ACTOOL**: spec done (`specs/formats/assets-car.md`); CAR-WRITER phase 1 done (ICON-CAR, 2026-10-30: images, colours, app icons, flattened `.icon`, the swift-build hook); remaining: phase 2 (layered tier) and ACTOOL-COMPAT (L). **RES-IBTOOL** later. | User SDK in place; dirty-room spec for `.car` | S → XL |
| 10 | **Code signing, entitlements, accounts** | Needed for devices, distribution and sandboxed apps. SIGN-1 done (2026-10-30, `specs/ide/signing.md`): IDE builds keep entitlements; keychain identities and installed profiles on macOS; simulator entitlements section; rcodesign designed for Linux. | **SIGN-1 remaining**: rcodesign signing on Linux. **SIGN-2**: an Accounts pane with an App Store Connect API key (public REST API) and automatic profiles; notarization; distribution methods. | – | L |
| 11 | **Wire existing CLI features into the IDE** (mostly done, IDE-QUICKWINS 2026-10-30: Export/Import Localizations, Build Documentation, Delete Derived Data, the Code Coverage ribbon, Simulate Location, Disable All Environment Overrides, Appearance, sanitizers, Run Repeatedly, opening `.xcresult` bundles as test reports. Left: Main Thread Checker and the other runtime checkers, `ycodebuild`'s sanitizer flags, coverage and logs from result bundles, a documentation viewer) | Cheap wins. `ycodebuild` already does the work. | **IDE-WIRE**: Export/Import Localizations, Build Documentation, Delete Derived Data, coverage annotations in the editor, an `.xcresult` reader for the report navigator (the reader exists: `XCResultReader`, `ycode results`, TEST-HOST), the Simulate Location submenu, sanitizer and Diagnostics checkboxes (build settings through swift-build), test repetitions. | – | M |
| 12 | ~~**Find and Replace across the project**, type hierarchy, the other find kinds~~ **Done** (FIND-REPLACE, 2026-10-30) | Daily refactoring need. | **FIND-2**: Replace mode with a preview and undo grouping; Symbols and Types kinds through LSP workspace symbols and type hierarchy. Left: Asset References. | #2 helps | M |
| 13 | **Source-control branch workflows** | Branch create, delete and rename; merge and rebase; a three-way conflict editor; blame; remote choice. The conflict editor doubles as a FileMerge equivalent. | **Done (SCM-BRANCHES, 2026-10-31)**: branches, merge, rebase, cherry-pick, stash, tags and remotes on `git`; the three-way conflict editor; Compare Files and `ycode compare`; Authors and Show Last Change. Left: a remote-and-branch sheet for push and pull, and folder comparison. The Linux shell's navigator, commit editor, sheet, history and change bars landed in B2-SCM (2026-11-04), its conflict editor in B3-CONFLICT (2026-11-05, #75). | – | S (left) |
| 14 | ~~**Agent mode for the coding assistant**~~ **Done** (ASSIST-MCP, 2026-10-31; `specs/ide/coding-assistant.md` §10). Left: plug-ins, a plan view, Generate Translations | The headline Xcode 27 feature. Agents build, test, run and render previews through an MCP server and ACP. Valuable from Linux CLIs too. | **ASSIST-MCP**: a Ycode MCP server (build, test, run on the simulator, screenshot, preview render, String Catalog edits) usable by Claude Code, Codex and others; ACP for in-IDE agents; skills; write mode with the existing proposal review. | – | L |
| 15 | **Developer tools set 1: symbols, icons, compare** | The Linux UI needs icons. `.icon` is the default app-icon format. FileMerge is cheap. | **TOOLS-1**: the OpenViews symbol provider with Material Symbols or Phosphor and an SF-name map (§3.3). **ICON-SPEC** (dirty room, done) → **ICON-1**: the flattened compile into the asset pipeline is done (ICON-READER, CAR-WRITER phase 1, 2026-10-30); remaining: ICON-RENDER, a `.icon` viewer, and a basic layer editor later. | #8 for the Linux UI; a dirty-room spec for `.icon` | M + L |

The next items after these, not ranked:
- Profiling on macOS, and the Allocations and Leaks instruments.
- Physical devices (`devicectl` on macOS first).
- A Network Link Conditioner in `ycode-simd`.
- visionOS input.
- The tvOS simulator.
- A `ycode simctl` front end with Apple's verbs.
- Interface Builder connections and Auto Layout.
- New target templates (extensions, widgets).
- The Core Data model editor.
- Playgrounds through the preview path.
- The JSON `.xcproj` project format from Xcode 27.2.

---

## Evidence

| Claim | Evidence | Level |
|---|---|---|
| Xcode 27.1 IDE behavior | The cited `specs/ide/*.md` and `specs/xcodebuild/*.md`, which carry their own Evidence sections | 1–3 (as the specs record) |
| Xcode 27 and 27.2 features: agents, MCP and ACP, Markdown editor, `#Playground`, `.xcproj`, Device Hub additions, Icon Composer 2.0, `simctl reboot` | Apple, "Xcode 27 Release Notes" and "Xcode 27.2 Release Notes" (developer.apple.com) | 1 |
| The developer tools list and order | `specs/ide/reference-ui-5.md` §2.1 item 7; Apple's Xcode resources page; the Additional Tools contents from an Apple Developer Forums listing (unverified for 27.1) | 1 |
| Icon Composer features | Apple's Icon Composer page (developer.apple.com/icon-composer) | 1 |
| SF Symbols terms | Apple's SF Symbols page states none. Terms as quoted in Apple Developer Forums threads and third-party package notices; confirm against the license in the SF Symbols app. | 1 (secondary) |
| Ycode status | Code reads and greps of `ycode/Sources`, `ycode/Tools`, `ycode/scripts`, `frameworks/`, `composer/` at `293ba871`. The key P0 lines were re-read (§1.2). | – (our own code) |
| Simulator matrix | The status sections of `specs/simulator/*.md`, `specs/macos/macos-apps.md`, `specs/ide/previews.md`, `specs/ide/profiler.md` | 3 (as the specs record) |
| Line counts | `wc -l` over `ycode/Sources/{YcodeUI,YcodeDeviceUI,YcodeApp}`, bucketed by imports and path | – |
| Open icon set licenses | The projects' own license files: Lucide ISC, Phosphor MIT, Tabler MIT, Material Symbols Apache-2.0, Fluent MIT, Bootstrap MIT, Carbon Apache-2.0, Font Awesome Free CC BY 4.0. Check the exact version when adopting. | 1 (public) |
| macOS text-style sizes for OpenViews' desktop text styles (§5.10) | Apple's Human Interface Guidelines, Typography ▸ Specifications (macOS) | 1 |
| Linux shell metrics and colors (§5.10) | Ycode's own macOS IDE: `LinuxParityProbeTests` offscreen captures and frame dumps, `specs/ide/metrics.md` | – (our own code) |
| Inter | The font's own name table and the SIL OFL 1.1 (`frameworks/swiftui/Sources/OVText/Resources/Fonts/Inter-OFL.txt`) | 1 |
| Not used | `research/`, the reference tools, Ghidra, Apple app bundles | – |
