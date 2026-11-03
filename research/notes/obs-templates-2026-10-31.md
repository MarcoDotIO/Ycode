# OBS-TEMPLATES (2026-10-31): the New Project flow of Xcode 27.1

Dirty-room notes in prose and tables, with no code. They record how the
reference's project templates are organized, how its options work and
what each template creates. The boundary spec written from them is
`specs/ide/templates.md` (§§ "Template chooser", "Options step",
"Template catalog", "Save step"). No template file text, no icons and no
images were copied. The raw material (a copy of the template
definitions, a resolver's JSON dumps and renderings) is in
`research/dirty/templates/`, which is never committed.

## 0. Method and limits

- **Level 2 (main source).** Xcode keeps its project templates as
  folders named `<Name>.xctemplate`. Each has a `TemplateInfo.plist`
  and the template's own source files. They sit in seven
  "Project Templates" folders: one in the shared developer library and
  one in each platform (iPhoneOS, MacOSX, AppleTVOS, WatchOS, XROS,
  DriverKit). The reference holds 359 template folders, and 358 of them
  have a `TemplateInfo.plist`. These plists were read as a file format
  (keys, identifiers, option values, setting names). A small resolver,
  written in the dirty room and kept in the session scratchpad, follows
  the `Ancestors` chains, merges the options, evaluates the option units
  for given choices and lists targets, settings, file *names* and
  components. Template source files were not read for content. The
  only exceptions are the entitlements and Info.plist fragments. For
  those, only the plist **key names** and their standard values were
  taken: UTIs, entitlement keys, scene roles.
- **Level 3 (confirmation).** The resolver's output was compared with
  project files that real Xcode releases had created from these
  templates. These are projects on the owner's drive created by Xcode
  16.2–26.4 (`CreatedOnToolsVersion`, real 24-hex object IDs). They were
  read as a file format. No names, teams or bundle identifiers were
  recorded. Some agent-written projects claim
  `CreatedOnToolsVersion = 27.1` but have synthetic IDs, so they were
  set aside. The resolver agrees with the real files on every point
  checked: project and target settings, the app and test targets,
  `latest_<platform>` resolution, the watch companion layout, the
  visionOS Metal app, and synchronized folders with their exceptions.
  The reference's own user defaults were read for **key names and value
  types only**. The organization identifier and team values were
  masked.
- **Level 4 (only for the GUI parts).** The UI strings of three of the
  reference's nibs (the template chooser, the project save accessory
  and the Git option view) and the names of the defaults keys in
  IDEKit's string table. No disassembly and no decompilation (no
  level 5).
- **Not done.** No GUI clicks and no screen takeover. Templates cannot
  be instantiated from the command line, so no project was created with
  the reference for this pass. The layout of the sheets stays as
  observed in `reference-ui-3.md` §5 and `reference-ui-6.md` §1.5.

## 1. The template file format (as observed)

### 1.1 Top-level keys

| Key | Count | Meaning (as used) |
|---|---|---|
| `Kind` | 358 | `Xcode.Xcode3.ProjectTemplateUnitKind` (350), `Xcode.IDESwiftPackageSupport.PackageTemplateKind` (7, the Package… flow), `Xcode.IDESwiftPackageUI.TextSubstitutionPlaygroundsAppTemplateKind` (1, App Playground) |
| `Identifier` | 358 | unique reverse-DNS id (`com.apple.dt.unit.…`); `Ancestors` refers to these |
| `Ancestors` | 319 | ordered list of ancestor ids; inherited depth-first, ancestors before the template itself |
| `Concrete` | 198 | true = selectable; abstract units only feed others |
| `TargetOnly` / `ProjectOnly` | 17 / 1 | inherited; TargetOnly hides a template from New Project, ProjectOnly from New Target |
| `SortOrder` | 51 | number (once a string) ordering templates in a section |
| `Description` | 189 | the template's description sentence |
| `Image` | 204 | an SF Symbol name (`SystemSymbolName`) or a bundle image name |
| `Options` | 280 | option list (§1.2) |
| `Targets` | 259 | target fragments, merged by position or by `TargetIdentifier` |
| `Project` | 20 | project-level `SDK`, `SharedSettings`, `Configurations` |
| `Nodes`, `Definitions` | 176 / 205 | file nodes and their definitions (§1.3) |
| `Components` | 7 | sub-templates instantiated as further targets, each with a `Name` |
| `AssociatedTargetSpecification` | 38 | "Embed in …" / "Target to be Tested" pop-up for New Target |
| `NameOfInitialFileForEditor` | 19 | file opened in the editor after creation |
| `SuppressTopLevelGroup` | 4 | no top-level folder named after the unit |
| `Platforms` | 35 | platform identifiers (`com.apple.platform.iphoneos`, …) |
| `OptionConstraints` | 20 | `DefaultIfAssociatedTarget` / `RequirementIfAssociatedTarget` |
| `PackageType`, `DefaultCompletionName` | 7 / 8 | package templates: the SwiftPM init type and the default name |
| `MainTemplateFile`, `AllowedTypes`, `SupportsSwiftPackage`, `Name`, `Summary` | 1 each | App Playground only |
| `MacOSSDKVersionMin` | 6 | minimum macOS SDK for some extensions |

### 1.2 Options

Option keys seen: `Identifier`, `Name` (the label, with a trailing
colon for text and pop-up fields), `Description` (tooltip), `Type`
(`text`, `static`, `popup`, `checkbox`, `companionAppTargetChooser`),
`Values`, `ValueTitles` (shown titles parallel to `Values`), `Default`,
`Override` (forced value; the option is not shown), `Value` (for
`static`), `Required`, `NotPersisted`, `EmptyReplacement`,
`Placeholder`, `SortOrder`, `RequiredOptions` (the option is enabled
only when other options have the given values), `RequiredOptionsForValues`
(per value: that value is allowed only when other options have the
given values), `ConditionalOverride` (one: macOS lifecycle), `Variables`
(per value: macros that the value defines), and `Units`.

`Units` maps an option value (or `*`) to a unit, or to a list of units
each with its own `RequiredOptions`. A unit can carry the same content
as a template: `Nodes`, `Definitions`, `Targets`, `Project`,
`Components`. Options with the same identifier merge along the ancestor
chain. Later (more derived) templates override plain fields, and units
accumulate.

An option with no `Name` or with an `Override` is never shown. Its
value comes from the `Override`, or else from the first of its values
whose `RequiredOptionsForValues` hold. The app lifecycle (`appLifecycle`)
works this way. It follows Interface: SwiftUI gives the SwiftUI
lifecycle, Storyboard or XIB gives the Cocoa/UIKit lifecycle.

### 1.3 Nodes and definitions

A node is a colon-separated path. Its first segment is a file path
relative to the unit's folder, for example `ContentView.swift` or
`Info.plist:UIBackgroundModes`. A `*` first segment means "any file".
Macros of the form `___NAME:modifier___` may contain a colon, so a
reader must not split on it. A definition is either text (content,
Apple's; not recorded) or a dictionary with:

- `Path`: the template file to copy;
- `Group`: a subfolder or group;
- `TargetIdentifiers`: the targets the file belongs to; an empty list
  means no target. Info.plist and entitlements files use this;
- `SortOrder`;
- `OmitFromProjectStructure`;
- `SubstituteMacros`;
- `AssetGeneration`: asset catalog slots to create, per platform
  (`appicon`, `solidimagestack`, `tvappicon`);
- `BuildAttributes`;
- `IsPackageReference` / `IsTopLevel` / `LinkPackageProducts`: a local
  package, and the products it links.

### 1.4 Macros seen (names only)

`___PACKAGENAME___` (product name; inside a component, the component's
name), `___PACKAGENAMEASIDENTIFIER___` (C-identifier form),
`___PACKAGENAMEASRFC1034IDENTIFIER___`, `___PACKAGENAME:identifier___`,
`___PARENTPACKAGENAME___` (the including template's name),
`___TARGETNAME:c99ExtIdentifier___`, `___FILEBASENAME___`,
`___VARIABLE_<option>___` with modifiers `bundleIdentifier`,
`RFC1034Identifier`, `identifier`, `XML`, `___COPYRIGHT___`,
`___BESTMACOSVERSION___`, `___ASSOCIATEDTARGET_bundleIdentifier___`,
`___ASSOCIATEDTARGET_bundleName___`, and the setting values
`latest_iphoneos`, `latest_macosx`, `latest_appletvos`,
`latest_watchos`, `latest_xros`, `latest_driverkit`.

In real projects, `latest_<platform>` and `___BESTMACOSVERSION___`
were written as that SDK's version (major.minor) at creation time. For
example, Xcode 26.0.1 wrote 26.0, Xcode 26.2 wrote 26.2, and Xcode 16.2
wrote iOS 18.2, watchOS 11.2 and macOS 15.x. The reference's SDKs are
iOS 27.1, with macOS, tvOS, watchOS, visionOS and DriverKit at 27.0.

## 2. Chooser facts

- The **tab** is the top folder (`MultiPlatform`, `iOS`, `macOS`,
  `watchOS`, `tvOS`, `visionOS`, `DriverKit`, `Other`). The **section**
  is the second folder (`Application`, `Framework & Library`, `Other`,
  `Driver`, and others). The template's name is its folder name without
  `.xctemplate`; App Playground uses its `Name` key instead. The
  `MultiPlatform` folder is shown as "Multiplatform".
- **Visibility in New Project:** concrete `ProjectTemplateUnitKind`
  templates whose inherited `TargetOnly` is not set, plus the
  App Playground kind. Every "Application Extension", "Test" and
  "System Extension" template inherits `TargetOnly`. So do App Clip,
  Sticker Pack Extension, iMessage Extension and Other ▸ Aggregate.
  Package-kind templates appear only in the Package… flow.
- **Order within a section:** ascending `SortOrder`. Templates without
  one come after those with one. Ties go by name. This reproduces both
  observed lists in `reference-ui-3.md` §5 exactly. Section order is
  alphabetical by folder name in every case seen. Only two tabs were
  observed, so this is OPEN for the others.
- **Persistence (defaults key names, level 3/4):**
  - `Xcode3ProjectTemplateChooserAssistantSelectedTemplateSection`: the
    last tab, by its display name (for example "Multiplatform").
  - `Xcode3ProjectTemplateChooserAssistantSelectedTemplateName_<Tab>`:
    the last template on each tab, as "<Section>/<Template>" (for
    example "Application/App"). The format string in IDEKit is
    `%@SelectedTemplateName_%@`.
  - `Xcode3PackageTemplateChooserAssistantSelectedTemplateSection`: the
    same for the package chooser.
  - `IDEFileTemplateChooserAssistantSelectedTemplateSection`: the New
    File sheet's last tab, stored as a platform identifier.
  - `IDETemplateOptions`: a dictionary of option values by option
    identifier. It is shared by all templates and skips `NotPersisted`
    options. The keys seen were `appLifecycle`, `bundleIdentifierPrefix`,
    `hasDocumentation`, `hostInCloudKit`, `immersiveSpaceStyle`,
    `languageChoice`, `primarySceneType`, `secondarySceneType`,
    `storageType`, `testingSystem` (= "Swift Testing") and
    `userInterface`. This explains why the options step showed
    "Swift Testing …" as the default in `reference-ui-3.md`: the
    template's own default is None.
  - `IDETemplateCompletionDefaultPath`: the last save folder (string).
  - `IDECreateQuickly.PreviousChoice`: the compact picker's last row.
    The raw values in IDEKit are `app`, `commandLineTool`, `package`,
    `playground` and `template`.
  - `IDEDisableGitSupportForNewProjects` (boolean): set on this Mac. Its
    exact effect on the Git checkbox is OPEN.
- **Filter:** the chooser nib binds the filter field to `filterString`.
  The controller keeps `filteredTemplates` (a dictionary) and
  `filteredCategories`. The matching rule was not observed.

## 3. Save step facts

- The project save panel's accessory (Xcode3UI nib) has a Git row, an
  "Add to:" pop-up (`destinationWorkspacePopUp`) and a "Group:" pop-up
  (`destinationGroupPopUp`).
- The Git row comes from an IDEKit nib. Its label is "Source Control:",
  its checkbox reads "Create Git repository on my Mac", and its tooltip
  says that a local Git repository is created inside the project folder.
- IDESourceControlUI contains the string "Initial Commit". Real
  repositories created by Xcode 16.3–26.x have one first commit titled
  exactly "Initial Commit". It holds the `.pbxproj`,
  `project.xcworkspace/contents.xcworkspacedata`, the user's
  `xcschememanagement.plist` and every template file. It does not hold
  `UserInterfaceState.xcuserstate`. **No `.gitignore` was created**:
  none of five such repositories had one in the first commit, and no
  `gitignore` string was found in the IDEKit or source-control
  binaries. The repository root is the project folder
  `<location>/<Product Name>/`.
- IDEKit strings: "Do you want to save this project in a new
  workspace?" and "You can only combine content with this project in a
  workspace." These are what Xcode asks when "Add to:" names a project
  rather than a workspace.

## 4. Generated structure facts (level 3 confirmations)

- Template-created projects (Xcode 16.2–26.4) are written with
  `objectVersion = 77` and `preferredProjectObjectVersion = 77`. Their
  attributes are `BuildIndependentTargetsInParallel = 1`,
  `LastSwiftUpdateCheck` and `LastUpgradeCheck` (the Xcode version as
  four digits, for example 2600), and per target
  `CreatedOnToolsVersion` (the Xcode version) and `TestTargetID` (for
  test targets). They also have `developmentRegion = en`,
  `knownRegions = (en, Base)`, `minimizedProjectReferenceProxies = 1`,
  `hasScannedForEncodings = 0` and empty `projectDirPath` and
  `projectRoot`. The configuration lists have
  `defaultConfigurationName = Release`. The quick New Project ▸ App path
  instead writes a canned project with `objectVersion = 90`
  (`reference-ui-6.md` §1.5).
- Every target's top folder is one `PBXFileSystemSynchronizedRootGroup`
  (path = the folder name, `sourceTree = "<group>"`). It is listed in
  the target's `fileSystemSynchronizedGroups`. Build phases are written
  empty. The main group holds the folders, then `Products`. A file that
  is in no target but sits in a synchronized folder (`Info.plist`) gets
  a `PBXFileSystemSynchronizedBuildFileExceptionSet` with
  `membershipExceptions = (Info.plist)` for its target. Its comment is
  `Exceptions for "<folder>" folder in "<target>" target`. Entitlements
  files get no exception.
- `CODE_SIGN_STYLE = Automatic` is added to every target. When a team
  is chosen, `DEVELOPMENT_TEAM` is added too. Neither comes from a
  template.
- Test targets: the unit-test target gets `TEST_HOST` =
  `$(BUILT_PRODUCTS_DIR)/<App>.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/<App>`
  and `BUNDLE_LOADER = $(TEST_HOST)`. The UI-test target gets
  `TEST_TARGET_NAME = <App>`. Both get a `TestTargetID` attribute and a
  target dependency on the app. Only the unit-test target copies the
  app's deployment target (from the template's
  `SettingsToCopyFromTargetBeingTested`). Xcode 26.0 also wrote a
  second UI-test file, `<N>UITestsLaunchTests.swift`. No 27.1 template
  contains it.
- Multi-SDK projects (the watch app with its companion): the
  project-level configurations carry no `SDKROOT` or deployment target.
  Each target carries its own `SDKROOT` and `<PLATFORM>_DEPLOYMENT_TARGET`,
  and the Release configurations carry `VALIDATE_PRODUCT = YES`. The
  container gets a copy phase "Embed Watch Content"
  (`dstPath = "$(CONTENTS_FOLDER_PATH)/Watch"`, `dstSubfolderSpec = 16`)
  and a target dependency on the watch app. The watch app gets
  `INFOPLIST_KEY_WKCompanionAppBundleIdentifier` and
  `SKIP_INSTALL = YES`.
- No shared schemes are written. Schemes are created automatically
  (only `xcuserdata/<user>.xcuserdatad/xcschemes/xcschememanagement.plist`
  appears).

## 5. Open questions

1. Filter matching: substring of the name only, or of the description
   too? Case and diacritics? Do empty sections and tabs hide?
2. Section order for the tabs that were not observed (alphabetical
   assumed).
3. Whether a pop-up value whose `RequiredOptionsForValues` fail is
   hidden or disabled. Observed: "Language: Swift" only, menu not
   opened.
4. Where Team sits among the options when a template lists Language
   before Organization Identifier (Framework, Static Library, Safari).
   The observed iOS App order is Product Name, Team, Organization
   Identifier, Bundle Identifier, Interface, Language, ….
5. Whether the reference shows template descriptions anywhere in the
   27.1 chooser (not seen in `reference-ui-3.md`).
6. How the RealityKit multiplatform Game's "Include … Application"
   checkboxes change the single target: its `SUPPORTED_PLATFORMS` lists
   all four platforms in the template.
7. `latest_iphoneos` with the reference's iOS 27.1 SDK: 27.1 by the
   26.x evidence, but the canned App project uses 27.0.
8. Effect of `IDEDisableGitSupportForNewProjects` on the checkbox's
   initial state, and whether the checkbox remembers its last state.
9. What Playground (compact picker) creates.
10. "Watch App for Existing iOS App" in New Project, where no iOS app
    target exists yet: hidden, disabled, or a file dialog?
