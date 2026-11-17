# Schemes: the scheme editor and Manage Schemes

Ycode modules: `YcodeWorkspace` (`Scheme` editing extension), `YcodeUI`
(`SchemeEditorController`, `ManageSchemesController`). File format:
`specs/formats/xcode-xml.md` §Scheme.

## Concepts (public docs)

A scheme names the targets to build and the settings for six actions:
Build, Run, Test, Profile, Analyze and Archive. Schemes are stored per
container (project or workspace). A shared scheme lives in
`xcshareddata/xcschemes/<Name>.xcscheme`; a user scheme in
`xcuserdata/<user>.xcuserdatad/xcschemes/<Name>.xcscheme`.

## Scheme editor sheet

Opened with Product ▸ Scheme ▸ Edit Scheme… (⌘<) for the scheme selected in
the toolbar. Layout (reference-ui-2.md §7): a list of the six actions on
the left, each with its configuration as subtitle (Build: "N targets");
the scheme's icon and name as the header; the selected action's pane on
the right; at the bottom "Duplicate Scheme" (disabled), "Manage
Schemes…", a "Shared" checkbox (moves the file as in Manage Schemes) and
"Close". The sheet reopens on the window's last action and tab.

| Action | Element | Pane in Ycode |
|---|---|---|
| Build | `BuildAction` | Build Order, Build Options ▸ Find Implicit Dependencies (`buildImplicitDependencies`), Override Architectures, Build Debugging; Targets table Targets / Analyze / Test / Run / Profile / Archive (`buildFor<Action>` on each `BuildActionEntry`) |
| Run | `LaunchAction` | tabs Info, Arguments, Options, Diagnostics |
| Test | `TestAction` | Build Configuration, Debugger, Debug Process As, LLDB Init File, Test Plans / Default |
| Profile | `ProfileAction` | tabs Info (configuration, Executable, Instrument), Arguments, Options |
| Analyze | `AnalyzeAction` | Build Configuration |
| Archive | `ArchiveAction` | Build Configuration, Archive Name, Reveal Archive in Organizer, Allow Archiving for Simulator |

Rows and defaults follow reference-ui-2.md §7. Rows with a scheme
attribute (§Options) are editable; rows whose attribute is not in Ycode's
evidence (§Options, "Still disabled") show their observed default and are
disabled.

Run ▸ Info: Build Configuration pop-up (the container's configuration names,
read from the project's build configuration list), Executable (the
`BuildableProductRunnable`'s `BuildableName`, or "None").
Run ▸ Arguments: "Arguments Passed On Launch" and "Environment Variables"
tables; each row has an enable checkbox and editable text (name and value
for variables); + and − add and remove rows.
Run ▸ Options: "Use custom working directory" (`useCustomWorkingDirectory`,
`customWorkingDirectory` on `LaunchAction`; placeholder
`$(BUILT_PRODUCTS_DIR)`).

On Run, the enabled arguments (each split into words as a shell would),
the enabled environment variables and the custom working directory are
passed to the program: lldb-dap `launch` `args`, `env` (`KEY=VALUE`) and
`cwd`; Mac simulator runs pass the arguments after the bundle id and the
variables through simctl's `SIMCTL_CHILD_` prefix. Build-setting
expansion (`$(…)`) is not done.

Product ▸ Scheme: Choose Scheme (⌃0, opens the toolbar pop-up), Select
Next / Previous Scheme (⌃⌘] / ⌃⌘[), Edit Scheme… (⌘<), New Scheme…
(disabled), Manage Schemes…. Not yet: the list of schemes in the
submenu.

## Diagnostics (IDE-QUICKWINS, 2026-10-30)

Run ▸ Diagnostics' **Runtime Sanitization** rows are editable; the Test
pane has the same four rows for the test action. Each is an attribute of
the action element, `"YES"` when on and removed when off:

| Row | Attribute | Build setting (swift-build) | At run time |
|---|---|---|---|
| Address Sanitizer | `enableAddressSanitizer` | `ENABLE_ADDRESS_SANITIZER = YES` | – |
| Detect use of stack after return (enabled only with ASan) | `enableASanStackUseAfterReturn` | – | `ASAN_OPTIONS` gains `detect_stack_use_after_return=1` (appended with `:` to a value the scheme sets) |
| Thread Sanitizer | `enableThreadSanitizer` | `ENABLE_THREAD_SANITIZER = YES` | – |
| Undefined Behavior Sanitizer | `enableUBSanitizer` | `ENABLE_UNDEFINED_BEHAVIOR_SANITIZER = YES` | – |

- Address and Thread Sanitizer exclude each other (clang rejects the
  pair): turning one on turns the other off; turning ASan off clears its
  option.
- Builds take the settings as command-line overrides
  (`BuildRequest.settings`): Build, Run, Analyze and Build For ▸ Running
  from `LaunchAction`; Test, Build For ▸ Testing and Test Without Building
  from `TestAction`; Clean none. Project tests pass them to the test tool as
  `NAME=value`. swift-build adds the `-fsanitize=` options and copies the
  sanitizer runtime into the product. Packages (no scheme file) get none.
- Still disabled: Main Thread Checker, Thread Performance Checker, the
  memory-management, Metal and Core AI rows. They need runtime checkers
  Ycode does not have.

Code: `YcodeWorkspace` `SchemeDiagnostics`, `YcodeIDECore`
`SchemeDiagnosticsBuild.swift`, `WorkspaceModel.buildRequest`,
`WorkspaceSession.launchOptions`; `YcodeUI` `SchemeEditorController`.
Tests: `IDEQuickWinsTests`, `IDEQuickWinsUITests.schemeDiagnosticsReachTheBuild`.

## Options (B4-WORKFLOWS, P-109)

Each editable row writes one attribute of its action element (created in
canonical order when missing); an absent attribute reads as the default
in the table. "remove" means the attribute is deleted.

| Row (action) | Attribute | On / choices | Off / default |
|---|---|---|---|
| Build ▸ Build Order | `BuildAction@parallelizeBuildables` | Dependency Order `YES` | Manual Order `NO` (absent: Dependency Order) |
| Build ▸ Override Architectures | `BuildAction@buildArchitectures` | Match Run Destination `Automatic`, Universal `All` | Use Target Settings: remove |
| Run, Test ▸ Debug executable | `selectedDebuggerIdentifier`, `selectedLauncherIdentifier` | `Xcode.DebuggerFoundation.Debugger.LLDB`, `Xcode.DebuggerFoundation.Launcher.LLDB` | `""`, `Xcode.IDEFoundation.Launcher.PosixSpawn` (absent: on) |
| Run, Test ▸ Debug Process As | `debugAsWhichUser` | root `root` | Me: remove |
| Run, Test ▸ LLDB Init File | `customLLDBInitFile` | the path | empty: remove |
| Run ▸ Info ▸ Launch | `LaunchAction@launchStyle` | Wait `1` | Automatically `0` |
| Run ▸ Info ▸ Executable | `BuildableProductRunnable` (child) / `askForAppToLaunch` | a target's reference / Ask on Launch `YES` | None: no runnable |
| Run ▸ Arguments ▸ Expand Variables Based On | `MacroExpansion/BuildableReference` (child, after the runnable) | a target | None: remove (the runnable is used) |
| Allow Location Simulation | `allowLocationSimulation` | `YES` | `NO` (absent: on) |
| GPU Frame Capture | `enableGPUFrameCaptureMode` | Metal `1`, Disabled `3` | Automatically: remove |
| Launch app without state restoration | `ignoresPersistentStateOnLaunch` | `YES` | `NO` |
| Allow debugging when browsing versions | `debugDocumentVersioning` | `YES` | `NO` (absent: on) |
| Show non-localized strings | `showNonLocalizedStrings` | `YES` | remove |
| App Language / App Region | `language` / `region` | a language code (`en`, `fr`, …) / a region code (`US`, `GB`, …) | System: remove |
| Main Thread Checker | `disableMainThreadChecker` | on: remove | `YES` |
| Thread Performance Checker | `disablePerformanceAntipatternChecker` | on: remove | `YES` |
| Metal ▸ API Validation | `enableGPUValidationMode` | on: remove | `1` |
| Metal ▸ Shader Validation | `enableGPUShaderValidationMode` | `2` | remove |
| Metal Performance HUD | `showGraphicsOverview` | `Yes` | remove |
| Log Graphics Overview | `logGraphicsOverview` | `Yes` | remove |
| Archive ▸ Archive Name | `ArchiveAction@customArchiveName` | the name | empty or the scheme's name: remove |
| Archive ▸ Reveal Archive in Organizer | `revealArchiveInOrganizer` | `YES` | `NO` (absent: on) |
| Profile ▸ Instrument | `savedToolIdentifier` | Ask on Launch (the only item) | — |

**Duplicate Scheme** writes a copy named "<name> Copy" ("<name> Copy 2",
…) next to the scheme's file and lists it.

**Still disabled** (no attribute in Ycode's evidence): Task Backtraces,
Modules Report, Default Location, App Data, Routing App Coverage File,
GameKit and StoreKit Configuration, Background Asset Packs, Distribution,
Simulated Apple Foundation Models Availability, XPC Services, Queue
Debugging, Console, Hardware Memory Tagging, Guard Malloc and the Malloc,
Zombie and memory-graph rows, the Metal sub-options, Core AI, and Allow
Archiving for Simulator.

**Escape** (P-110): the first Escape (or ⌘.) ends a text field's editing
and discards the typed value; with nothing being edited it closes the
sheet as Close does.

## Autocreated schemes (P-108)

A project with no scheme files shows one scheme per target (the toolbar
already listed them). Edit Scheme… opens such a scheme from the model
(`WorkspaceModel.schemeForEditing`): it builds the target, tests itself
or the test bundles it hosts, runs an application or tool, and asks for an
automatic test plan (the scheme `xcodebuild -list` autocreates). It has
the current user's scheme URL but no file: Close writes it only when it
changed, and then writes the project's other autocreated schemes too, so
the list stays the same. Manage Schemes lists autocreated schemes with
their container; turning Shared on writes the file first, then moves it.

## Writing

Edits change the in-memory XML tree; Close writes the file if the
serialized text differs from what is on disk (so an unchanged scheme is
never rewritten, and the writer's byte-exact round trip holds).

- `buildConfiguration` is set on the action element (the element is created
  in canonical child order if missing).
- Arguments: `LaunchAction/CommandLineArguments/CommandLineArgument
  [argument, isEnabled=YES|NO]`; the container element is removed when the
  list is empty and inserted after the runnable when created.
- Environment: `LaunchAction/EnvironmentVariables/EnvironmentVariable
  [key, value, isEnabled]`, inserted after `CommandLineArguments` (or the
  runnable).
- Options: `useCustomWorkingDirectory = "YES"` plus
  `customWorkingDirectory`; turning it off removes both attributes.

## Manage Schemes

A list of the container's schemes with columns Name, Container and Shared.
Turning Shared on moves the file from the user directory to
`xcshareddata/xcschemes` (creating directories); off moves it back to the
current user's directory. The file's bytes are unchanged by a move.

## Evidence

- Scheme concepts, the six actions, the editor's action list, Run's Info /
  Arguments / Options tabs, Manage Schemes and the Shared checkbox: Apple's
  public Xcode Help ("Customizing the build schemes for a project") and
  developer documentation (level 1).
- Element and attribute names: `specs/formats/xcode-xml.md` (level 2).
- `useCustomWorkingDirectory` / `customWorkingDirectory`: corpus scheme files
  (level 2).
- Pane contents, order and defaults: `specs/ide/reference-ui-2.md` §7
  (level 3).
- OPEN QUESTION: sheet size, and how the IDE orders
  schemes in Manage Schemes (`xcschememanagement.plist`).
- OPEN QUESTION: where a newly created `CommandLineArguments` element goes
  when a `LaunchAction` has other children (ours: right after the runnable).
- Sanitizer attributes (`enableAddressSanitizer`,
  `enableASanStackUseAfterReturn`, `enableThreadSanitizer`,
  `enableUBSanitizer`, read as `== "YES"`, written only when on): the
  open-source XcodeProj library (tuist, MIT), `XCScheme+LaunchAction.swift`
  (level 1). Build settings: open-source swift-build (Apache-2.0),
  `BuiltinMacros.swift` and `SanitizerTaskProducer.swift` (level 1).
  `detect_stack_use_after_return`: LLVM's AddressSanitizer documentation
  (level 1). That ASan and TSan cannot be combined: clang's documentation
  (level 1).
- §Options attribute names, values and defaults: the open-source XcodeProj
  library (tuist, MIT), `XCScheme+LaunchAction.swift`,
  `XCScheme+BuildAction.swift`, `XCScheme+TestAction.swift`,
  `XCScheme+ProfileAction.swift`, `XCScheme+ArchiveAction.swift` and
  `XCScheme.swift` (level 1). Ycode's readings, not in that source: the
  PosixSpawn launcher identifier for Debug executable off, Build Order as
  `parallelizeBuildables`, and the language and region code lists
  (OPEN QUESTIONS for a level 2 corpus check).
- Autocreated schemes: `specs/xcodebuild/info-commands.md` §2.1 (level 3).
- OPEN QUESTION: whether Xcode's Test action uses its own Diagnostics or
  the Run action's when "Use the Run action's arguments and environment"
  is on; Ycode uses the test action's own attributes.
