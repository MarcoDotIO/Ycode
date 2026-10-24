# Spec: reference IDE behavior, pass 3 — project editor, catalogs, destinations, templates, Organizer

Status: boundary spec from black-box observation (evidence level 3) of the
reference release on a throwaway iOS app project (objectVersion 77, one
app target, one synchronized root folder, an asset catalog, a plist).
It continues `reference-ui.md` and `reference-ui-2.md` and answers
OPEN QUESTIONs in `project-editor.md`, `plist-editor.md`,
`asset-catalog.md`, `destinations.md`, `templates.md`, `organizer.md`
and `editor-area.md`. It records behavior, labels and defaults only. It
records no colors and no assets. Ycode picks its own icons.

## 1. Project editor

1. **Opening.** Selecting the project in the navigator opens the project
   editor with the **first target** selected (General tab), not the
   project.
2. **Left column.**
   - Sections "PROJECT" (the project) and "TARGETS" (each target).
   - Footer: +/− and a Filter.
   - The column can be collapsed with a button at its top left.
3. **Target tabs:** General, Signing & Capabilities, **Resource Tags**,
   Info, Build Settings, Build Phases, Build Rules. **Project tabs:** Info,
   Build Settings, Package Dependencies.
4. **General** (an iOS app target). Collapsible sections, in this order:
   1. **Supported Destinations.**
      - A table: Destination | SDK.
      - Default iOS app rows: iPhone (iOS), iPad (iOS), "Mac (Designed for
        iPad)" (iOS), "Apple Vision (Designed for iPad)" (iOS).
      - +/− below the table.
      - The rows follow from `SUPPORTED_PLATFORMS`,
        `TARGETED_DEVICE_FAMILY`, `SUPPORTS_MACCATALYST`,
        `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` and
        `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD` (this mapping is Ycode's
        reading of the settings, not observed).
   2. **Minimum Deployments** (title has an info button). One row per SDK:
      "iOS" with an editable combo box ("27.0", from
      `IPHONEOS_DEPLOYMENT_TARGET`) and a "+".
   3. **Identity.**
      - App Category (pop-up, None).
      - Display Name (placeholder "Display Name").
      - Bundle Identifier.
      - Version (`MARKETING_VERSION`) and Build (`CURRENT_PROJECT_VERSION`).
      - Each row has a "+" (add to Info) or "→" (go to the build setting) at
        its right.
   4. **Deployment Info.**
      - iPhone Orientation and iPad Orientation: checkboxes Portrait,
        Upside Down, Landscape Left, Landscape Right.
      - Status Bar Style (Default) and "Hide during application launch".
      - A "Scene manifest →" row.
   5. **App Icons and Launch Screen.**
      - App Icon (text field holding the setting value).
      - App Icons Source ("Include all app icon assets").
      - Launch Screen File (combo, placeholder "Storyboard Base Name").
   6. **Frameworks, Libraries, and Embedded Content:** columns Name | Embed,
      empty text "Add frameworks, libraries, and embedded content here",
      +/−.
   7. **Development Assets:** empty text "Add development assets here", +/−.
   8. **Supported Intents:** columns Class Name | Authentication, empty text
      "Add intents eligible for in-app handling here", +/−.
5. **Signing & Capabilities.**
   - Top bar: a "+ Capability" button and a scope control "All | Debug |
     Release".
   - Section "Signing":
     - "Automatically manage signing" (checked by default), with the
       caption "Xcode will create and update profiles, app IDs, and
       certificates.".
     - Team (pop-up; None when unset).
     - Bundle Identifier.
   - A box per platform ("iOS"): Provisioning Profile ("Xcode Managed
     Profile" when automatic), Signing Certificate ("Apple Development"),
     and Status. With no team, Status shows a warning: "Signing for
     "<target>" requires a development team." / "Select a development team
     in the Signing & Capabilities editor."
   - Empty capabilities: "Add capabilities by clicking the "+" button
     above."
   - "+ Capability" opens a library panel titled "Capabilities":
     - a filter field and list/grid toggles;
     - an alphabetical list of capabilities with icons;
     - a detail pane with the icon, name and description of the selection.
   - With no team, the panel footer shows "Error Loading Capabilities" / "No
     development team is set. Select a team in the Signing & Capabilities
     editor.". Ycode may take its capability list from Apple's public
     capability documentation (level 1).
6. **Resource Tags:** "+", a scope "All | Prefetched", a Filter, and the
   empty text "Click the "+" button above to add a resource tag."
7. **Info.**
   - Section "Custom <Platform> Target Properties": a table Key | Type |
     Value.
     - Keys are shown by their **readable names** (Bundle name, Bundle
       identifier, InfoDictionary version, Bundle version string (short),
       Bundle version, Executable file, Application requires iPhone
       environment, Application Scene Manifest, Supported interface
       orientations, Bundle OS Type code, Launch Screen, Default
       localization, Application supports indirect input events).
     - Each row has a Type pop-up.
     - Containers show "(N items)" with a disclosure.
     - Values that come from build settings show as `$(…)`.
   - Collapsed sections below: Document Types (N), Exported Type Identifiers
     (N), Imported Type Identifiers (N), URL Types (N).
8. **Build Settings.**
   - Bar: "+" | Basic · Customized · All | Combined · Levels | Names ·
     Titles | Definitions · Values | a filter. Defaults: Basic, Combined,
     Titles, Values.
   - Each collapsible section has the header row "Setting | <level icon +
     name>". A setting defined at the shown level is drawn **bold**; an
     inherited one is drawn plain.
   - Basic shows, for an iOS app target, these sections and settings:

     | Section | Settings |
     |---|---|
     | Deployment | Installation Directory, Strip Linked Product, Targeted Device Families |
     | Info.plist Values | Application Scene Manifest (Generation), Launch Screen (Generation), Supported Interface Orientations, Supports Indirect Events |
     | Linking - General | Runpath Search Paths |
     | Packaging | Generate Info.plist File, Info.plist File, Product Bundle Identifier, Product Name |
     | Signing | Code Signing Style |
     | Versioning | Current Project Version, Marketing Version |
     | Swift Compiler - Language | Swift Language Version |
     | User-Defined | any customized setting the view has no title for, by raw name |

   - Levels view columns: Setting | Resolved | <target> | <project> | the
     platform default. The cell of the level that supplies the value is
     outlined. A setting whose value differs per configuration expands to
     one row per configuration, and its collapsed row shows "<Multiple
     values>".
9. **Build Phases.**
   - "+" and a Filter.
   - Each phase is a collapsible row "<Phase name> (N items)". Default
     order: Target Dependencies, Run Build Tool Plug-ins, Compile Sources,
     Link Binary With Libraries, Copy Bundle Resources. Phases that can be
     removed have a trash button.
   - Files from a synchronized folder are counted and listed as "<file>
     …in <folder>". Compile Sources has the columns Name | Compiler Flags.
   - "+" menu: New Copy Files Phase, New Run Script Phase | New Headers
     Phase, New Copy Bundle Resources Phase, New Compile Sources Phase, New
     Link Binary With Libraries Phase, New Build Carbon Resources Phase. A
     phase kind that already exists, or doesn't apply, is disabled.
10. **Build Rules.**
    - "+", a scope "All | Custom", a Filter.
    - Each rule is a section titled with the rule name (sorted by name),
      with the lines "Process: <file type>" and "Using: <tool spec
      identifier>" and a "Copy to Target" button.
11. **Project ▸ Info.**
    - Configurations: a table Name | Based on Configuration File, with one
      disclosure row per configuration ("No Configurations Set" when none),
      +/−.
    - "Use [<config>] for command-line builds" (pop-up).
    - "Parallelize build for command-line builds (does not apply when using
      schemes)" (checkbox, on).
    - Localizations: a table Localization | Default | Resources ("N Files
      Localized"), +/−, a "Set Default" button, and "Use Base
      Internationalization" (on).
    - There is **no deployment-target section** at project level.
12. **Project ▸ Package Dependencies:** "Packages (N items)", a table Name |
    Location | Dependency Rule, empty text "Add packages here", +/−.
13. **File inspector for a project:**
    - Identity and Type: Name; Location ("Absolute", disabled); the caption
      "Containing directory"; Full Path.
    - Project Document:
      - Compatibility (pop-up; "Xcode 16.0" for objectVersion 77);
      - Encoding: "Minimize Project References" (mirrors
        `minimizedProjectReferenceProxies`);
      - Decoding: "Strictly Validate";
      - Organization; Class Prefix.
    - Text Settings.

## 2. Property list editor

- Columns Key | Type | Value. The root row is "Root  Dictionary  (N
  items)".
- The editor **keeps the file's key order**; it does not sort.
- An integer or real shows as type "Number". Arrays and dictionaries show
  "(N items)" with a disclosure.

## 3. Asset catalog editor

1. The left outline lists sets and folders, with +/− and a Filter at the
   bottom. The inspector gains a fourth tab (attributes).
2. **Set header.** The set name is at the top left and the set type at the
   top right ("App Icon", "Color").
3. **App icon (single size).** One dashed slot labelled "1024x1024px",
   captioned "iOS" / "1,024pt". Inspector section "App Icon": Name, iOS
   (Single Size), macOS (None), watchOS (None), Appearances (None), Gamut
   (Any).
4. **Color set.** One slot captioned "Universal". Inspector section "Color
   Set":
   - Name.
   - Devices: Universal (on), iPhone, "iPad (and Mac Catalyst)", "Mac
     Catalyst Scaled", CarPlay, Mac, Apple Vision, Apple Watch, Apple TV.
   - Appearances (None) and High Contrast.
   - Gamut (Any).
   - Localization, with a "Localize…" button.
5. **"+" menu:**
   - Image Set, Color Set, Symbol Image Set, Data Set.
   - AR and Textures ▸ (Texture Set, Sprite Atlas, Cube Texture Set | AR
     Resource Group, AR Reference Image, AR Reference Object).
   - iOS ▸ (iOS App Icon, iOS Launch Image (Deprecated), Messages Extension
     Icon | Sticker Pack, Sticker, Sticker Sequence, Sticker Sequence
     Frame). The sticker items are enabled only inside a sticker pack.
   - macOS ▸, watchOS ▸, tvOS ▸, visionOS ▸.
   - Folder, Folder with Namespace, Folder from Selection.
   - Import….

## 4. Run destination menu

- A filter field at the top.
- Sections, in order:
  1. **Recent**: the current destination, with a check mark.
  2. **Devices**: "My Mac (Designed for iPad)" for an iOS app, then
     connected devices.
  3. **Simulators.**
  4. **Build**: "Any iOS Device (arm64)", "Any iOS Simulator Device (arm64,
     x86_64)".
  5. Then "Incompatible ▸" and "Manage Devices…".
- A row is the device icon, the name, and the OS version right-aligned.
- In Simulators, user-named devices come first (by name), then the
  default devices in model order (iPhone models, then iPad models, then
  visionOS devices "(Designed for iPad)", one per runtime). Refined in
  pass 5 (`reference-ui-5.md` §11.4): the order is by runtime, newest
  first, then iPhone / iPad / Apple Vision, each by name; the user-named
  devices came first only because they were on the newest runtime.

## 5. File ▸ New, templates, New Project

1. **File ▸ New ▸** (shortcuts as shown):
   - Conversation; Tab ⌘T; Editor Pane On Right ⌃⌘T; Editor Pane Below
     ⌃⌥⌘T; Window Tab; Window ⇧⌘T.
   - Empty File; File from Template… ⌘N; Target….
   - Project… ⇧⌘N; Workspace… ⌃⌘N.
   - Folder ⌥⌘N; Folder from Selection.
2. **⌘W with one tab.** With a single editor tab (tab bar hidden), the
   File menu shows **Close Window ⌘W** and Close "<file>" ⌃⌘W. With two
   or more tabs, ⌘W is Close Tab (`reference-ui-2.md` §8).
3. **New file sheet.**
   - Title "Choose a template for your new file:". Platform tabs iOS,
     macOS, watchOS, tvOS, visionOS, DriverKit. A filter field.
   - An icon grid in sections with sticky headers. iOS sections and
     templates, in order:
     - Source: Swift File, Cocoa Touch Class, Objective-C File, Header File,
       C File, C++ File, Metal File.
     - User Interface: SwiftUI View, Storyboard, View, Empty, Launch Screen.
     - Test: Swift Testing Unit Test, XCTest Unit Test, XCTest UI Launch
       Test, XCTest UI Test, Test Plan.
     - Core Data: Data Model, Mapping Model.
     - Resource: App Privacy, Asset Catalog, GeoJSON File, GPX File, Icon
       Composer Icon, Module Map, Property List, Rich Text File, SceneKit
       Catalog, SceneKit Scene File, Settings Bundle, SiriKit Intent
       Definition File, SpriteKit Action, SpriteKit Particle File, SpriteKit
       Scene, SpriteKit Tile Set, Sticker Catalog, String Catalog, Strings
       File (Legacy), Stringsdict File (Legacy), Touch Alternatives.
     - Documentation: Documentation Catalog, Article File, Extension File,
       Empty, Tutorial Table of Contents File, Tutorial File.
     - Other: Empty, Assembly File, Build Phase File List, CLIPS File,
       Configuration Settings File, Exports File, GameKit Bundle, Markdown
       File, PCH File, Shell Script, StoreKit Configuration File.
   - Buttons: Cancel, Previous (disabled on the first step), Next.
   - Next opens a save sheet: "Save As:" (the template's default name,
     "File" for Swift File, preselected), Tags, Where (folder pop-up with
     an expand button). An accessory adds Group (pop-up) and Targets (a
     checkbox list with the current target checked). Buttons Cancel and
     Create. Cancel returns to the template sheet.
4. **New Project.**
   - File ▸ New ▸ Project… first shows a **compact picker**. Header "+ New
     Project". Rows, each with a title and a subtitle:
     - App — "SwiftUI app for iPhone, iPad, Mac & Vision Pro"
     - Command Line Tool — "Terminal program for macOS"
     - Package… — "Swift package library"
     - Playground — "Explore previews & playgrounds in a Swift file"
     - Choose Template… — "Other apps, libraries, and games…"
   - Choose Template… opens a new empty workspace window with the sheet
     "Choose a template for your new project:".
     - Platform tabs: Multiplatform, iOS, macOS, watchOS, tvOS, visionOS,
       DriverKit, Other.
     - Multiplatform: Application (App, Document App, Foveated Streaming
       App, Game, Audio Unit Extension App, Safari Extension App) and
       Framework & Library (Framework).
     - iOS: Application (App, Document App, Game, Augmented Reality App, App
       Playground, Sticker Pack App, iMessage App, Safari Extension App) and
       Framework & Library (Framework, Static Library, Metal Library).
     - The last selected template is preselected.
     - Cancel closes the sheet and its empty window.
   - Options step "Choose options for your new project:" (iOS App):
     - Product Name.
     - Team (pop-up).
     - Organization Identifier.
     - Bundle Identifier: derived and grey, "<org>.ProductName" while the
       name is empty.
     - Interface: SwiftUI or Storyboard.
     - Language: Swift.
     - Testing System: None, "XCTest for Unit and UI Tests", or "Swift
       Testing with XCTest UI Tests" (default).
     - Storage: None, SwiftData or Core Data.
     - "Host in CloudKit" (disabled while Storage is None).
     - Buttons Cancel, Previous, Next. Next is disabled until a product
       name is entered.

## 6. Organizer

- Window ▸ Organizer (⌥⇧⌘O). A window with a sidebar:
  - an app picker at the top;
  - **Products**: Archives;
  - **Insights**: Overview;
  - **Reports**: Crashes, Disk Writes, Energy, Feedback, Hangs, Launches;
  - **Metrics**: Battery Usage, Disk Writes, Hang Rate, Hitches, Launch
    Time, Memory, Storage, Terminations.
- The toolbar has back/forward buttons, the page title and a notifications
  (bell) button.
- Pages without data show an empty state: "No Overview Data" / "There is
  no overview data available for version <v>.".
- The Insights, Reports and Metrics pages need App Store Connect data. Ycode
  shows the sidebar and the empty states only.

## 7. Differences from Ycode's specs (to implement)

1. Project editor:
   - open on the first target;
   - the Resource Tags tab;
   - the General sections and their order (Supported Destinations,
     Minimum Deployments, Identity, Deployment Info, App Icons and Launch
     Screen, Frameworks…, Development Assets, Supported Intents);
   - the Signing scope control, the platform box, the no-team warning and
     the capability library panel;
   - Info with readable key names and the four type sections;
   - bold for customized build settings, the Basic table, Levels columns
     and "<Multiple values>";
   - the build-phase "(N items)" titles, the "…in <folder>" rows and the
     "+" menu;
   - Build Rules with Process/Using/Copy to Target;
   - Project ▸ Info without a deployment target, with the command-line
     configuration and parallelize options;
   - the Package Dependencies table;
   - the project file inspector's Project Document section.
2. Plist editor: keep key order; type "Number"; "(N items)".
3. Asset catalog: the set header and type label, the slot captions, the
   App Icon and Color Set inspectors, and the "+" menu structure.
4. Destinations: the Recent/Devices/Simulators/Build sections, the filter
   field, Incompatible ▸, Manage Devices…, and the ordering.
5. File ▸ New submenu, the ⌘W one-tab rule, the new-file sheet sections and
   save sheet, and the New Project compact picker plus template sheet and
   options step.
6. Organizer sidebar sections and empty states.

## Evidence

| Claim | Level | Source |
|---|---|---|
| §1–§6 | 3 | Black-box observation of the reference app (Xcode 27.1, installed copy) on a throwaway project, 2026-10-17, through screenshots and its menus. No binaries were opened. Personal names, teams and the user's own apps seen on screen are not recorded. |
| §1.4 mapping to settings, §1.5 capability list source | — | Ycode's reading or a pointer to public documentation, not observed |
| §7 | — | Comparison with Ycode's specs at the time |
