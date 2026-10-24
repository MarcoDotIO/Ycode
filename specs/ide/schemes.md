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

Rows and defaults follow reference-ui-2.md §7. Rows whose scheme
attributes are not in Ycode's specs (Build Order, Override
Architectures, Build Debugging, Debug executable, Debug Process As, LLDB
Init File, Launch, Expand Variables Based On, the Options rows other than
the working directory, every Diagnostics row, Instrument, Archive Name
and options) show their observed default and are disabled.

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
