# Xcode 27.1 GUI observations — pass 2 (black-box, level 3)

Dirty-room prose. Observed 2026-10-17 on a throwaway Swift package
("Obs": library ObsKit, executable Obs, test target ObsTests with Swift
Testing) in the session scratchpad. No assets copied, no colours
recorded. Purpose: answer OPEN QUESTIONs in `specs/ide/*.md`.

## Issue navigator

- Tree: root row = workspace/package name with the icon and a grey
  "N issues" count after the name. Children = one group per **file**,
  titled with the file name **without extension** and the file-type
  icon. Leaf rows = severity icon (error, warning) + message text.
- No by-file/by-type switch is visible in the navigator. Grouping is by
  file.
- Long messages wrap to at most three lines and end in an ellipsis. The
  selected row expands to show the full message.
- Group order observed: Broken, Broken, Shapes (alphabetical by file name).
- **Stale issues**: after the erroring file moved, the next build showed a
  second "Broken" group whose icons are grey (stale) while the new one is
  red. The toolbar counts include stale errors (it showed 4 errors where
  the build itself reported 2).
- Selecting an issue opens its file in the editor. (In our scratch location
  the jump-to-line and inline annotations did not appear, probably a
  /tmp vs /private/tmp path mismatch; not recorded as behaviour.)
- Bottom filter bar: a filter-options button left of the field, then two
  toggles at the right. Tooltips: "Show only issues from open documents and
  recently built sources" (clock icon) and "Show only errors" (! icon).
- Filter-options menu sections: "Additional Filtering" (Deprecation),
  "Add Filter" with tokens (an ISSUE KIND token, e.g. Build, and a
  "≠ DEPRECATION" token), "Clear Recents". The filter is token-based.

## Toolbar after builds

- The activity view title is the package name. The subtitle is
  "Build Failed • Today at 3:46 AM" or "Test Completed • Today at 3:48 AM".
- The issue counts sit in their own capsule to the right of the
  scheme/destination capsule: error icon + count, then warning icon + count.
  After a test run with a failure, the capsule showed a test-failure
  (diamond-cross) icon + 1, and the warning count was gone (incremental
  build, no recompile).
- The editor jump bar's right end has previous/next issue arrows with the
  severity icon between them.

## Find navigator

- The top row is a path of three pop-ups, "Find › Text › Containing", with an
  "Aa" (match case) toggle at the far right. Below it are the search field
  (with history) and a scope pop-up ("In Package").
- Pop-up 1: Find, Replace.
- Pop-up 2 (search type): Text, Multiple Words, Regular Expression, Symbols,
  Ancestor Types, Descendent Types (spelled so), Conforming Types, Call
  Hierarchy, Asset References.
- Pop-up 3 (match style for Text): Containing, Matching Word, Starting With,
  Ending With.
- Scope pop-up (package workspace): Package (checked), Package Dependencies,
  Package and Package Dependencies; separator; Current Find Results
  (disabled without results); separator; section "Containing Groups" with
  the groups that contain the selected file (Sources, ObsKit); separator;
  "Custom Scopes…".

## Report navigator

- Top segmented control: Local | Cloud.
- Groups: one per scheme (here "Obs", scheme icon), plus a "Package" group
  for package operations.
- Rows: activity icon + title + grey timestamp ("Build  Today, 3:46 AM"),
  newest first; failed runs have a red error badge at the right.
  Package rows: "Resolve Packages", "Reload Package…" (titles truncated).
- A test run row is titled "<scheme>/<test plan>" ("Obs/Obs  Today,
  3:48 AM") and expands to children: Insights, Coverage (with "100%" at
  the right), Tests (failure badge), Log, Build.
- Bottom: a circular button at the left, then a filter field with a clock
  toggle.

## Build log (report editor)

- Scope bar: "All | Recent" (segmented), then "All Messages | All Issues |
  Errors Only" (segmented; All Issues selected by default), an "Export…"
  button, and a filter field.
- One section per target: bold "Build target <name>" and the subtitle
  "Package Obs | Configuration Debug | Destination My Mac | SDK macOS 27.0"
  (for a package, the executable target shows as "<name>-product").
- Steps nest: "Compiling Broken.swift  0.1 seconds" > "Compile
  Broken.swift  0.1 seconds" > issue rows. Each step has an issue-count
  badge and a details (transcript) button on the right.
- Footer: a large status icon, "Build failed  10/17/26, 3:46 AM  0.6
  seconds", and "2 errors, 3 warnings" on the next line.

## Test navigator and test report

- Test navigator header: a test-plan pop-up ("Obs (Autocreated)"), a list
  toggle button, and a tag button. Tree: plan root "Obs  2 Tests, 1
  Failing", target "ObsTests  2 Tests, 1 Failing", then test functions
  "circleArea()", "greeting()". Status diamonds at the right are green for
  pass and red for fail.
- Test report summary: title "Obs/Obs", "Built with macOS 27.2", and at the
  right "Started 10/17/26 at 3:48 AM · Ran for 7.5 seconds". A card "Tests
  Ran for 7.5 seconds" with a ring chart (total in the centre, "2 Tests")
  and a legend "Passed 1", "Failure 1". A table "Devices &
  Configurations | Passed | Failure" with the row "MacBook Pro macOS 27.2" >
  "Test Scheme Action" with green and red bars holding the counts. A list
  "Test Failures  1 total failure" with "greeting()" and its message.
- Tests page: header "Obs" (test plan icon), "1 failed and 1 passed · Test
  plan with 1 test target". Filter pop-ups: "Failed Tests (1)", "Failed
  Runs (1)", device ("MacBook Pro macOS 27.2"), "Test Scheme Action",
  "Untagged Tests", and a filter field. Table columns: Test | Duration.
  Rows: target "ObsTests" > "greeting()" with duration "0.00076s" >
  issue "ObsTests.swift:8: Expectation failed: greet("a") == "Hello, b"",
  then the evaluated expansion on the next line (greet("a") → "Hello, a").
- Coverage page: "Show Test Bundles" checkbox and a filter at the top.
  Columns: Name | Coverage (bar + percentage "100.0%") | Executable Lines.
  Rows are expandable (target > files).

## Product menu (package workspace)

Run ⌘R, Test ⌘U, Profile ⌘I, Analyze ⇧⌘B, Archive, Stop ⌘. (disabled when
idle) | Build For ▸, Perform Action ▸ | Build ⌘B, Clean Build Folder… ⇧⌘K,
Delete Derived Data…, Clear Test Results ⌃⌥⌘K (disabled without results),
Clear All Issues | Build Documentation ⌃⇧⌘D | Show Build Folder in Finder,
Copy Build Folder Path | Export Localizations…, Import Localizations…
(disabled for a package) | Scheme ▸, Destination ▸, Test Plan ▸ | App
Shortcuts Preview.

## Scheme editor (package scheme "Obs")

- Sheet. Left column: actions Build ("2 targets"), Run, Test, Profile,
  Analyze, Archive, each with its configuration as a subtitle (Run Debug,
  Test Debug, Profile Release, Analyze Debug, Archive Release) and a
  disclosure that expands to Pre-actions / <action> / Post-actions. Top of
  the detail: scheme icon + name. Bottom bar: "Duplicate Scheme",
  "Manage Schemes…", a "Shared" checkbox (checked), and "Close" (default
  button).
- The sheet reopened on the last-used Run tab (Arguments), not on Info.
- **Build:** Build Order radio (Dependency Order; Manual Order
  (Deprecated)); Build Options "Find Implicit Dependencies" (on);
  "Override Architectures" pop-up "Match Run Destination" with an info
  button; Build Debugging checkboxes "Task Backtraces", "Modules Report".
  Targets table columns: Targets | Analyze | Test | Run | Profile |
  Archive; rows were the test plan/target group "Obs" (only Test checked,
  greyed) and the executable "Obs" (all five checked). Footer +/– and a
  Filter field.
- **Run** tabs: Info, Arguments, Options, Diagnostics.
  - Info: Build Configuration (Debug); Executable pop-up (Obs); "Debug
    executable" checkbox (on); Debug Process As radio "Me (<user>)" / root;
    LLDB Init File text field with placeholder $(SRCROOT)/LLDBInitFile and a
    folder button; Launch radio "Automatically" / "Wait for the executable
    to be launched".
  - Arguments: disclosure sections "Arguments Passed On Launch" (empty
    state "No Arguments", +/–) and "Environment Variables" (columns Name |
    Value, empty state "No Environment Variables", +/–); bottom "Expand
    Variables Based On" pop-up (Obs).
  - Options, in order: Core Location ("Allow Location Simulation" on;
    Default Location None); App Data (None); Routing App Coverage File
    (None); GameKit Configuration ("Enable Debug Mode" off); StoreKit
    Configuration (None); GPU Frame Capture (Automatically); Persistent
    State ("Launch app without state restoration" off); Document Versions
    ("Allow debugging when browsing versions" on); Working Directory ("Use
    custom working directory:" off, placeholder $(BUILT_PRODUCTS_DIR) with a
    folder button); Background Asset Packs (None, folder button);
    Localization Debugging ("Show non-localized strings" off); App Language
    (System Language); App Region (System Region); Distribution (App
    Store); Simulated Apple Foundation Models Availability (Off); XPC
    Services ("Debug XPC services used by app" on); Queue Debugging
    ("Enable backtrace recording" off); Console ("Xcode (with Standard
    Input)").
  - Diagnostics: Runtime Sanitization (sub-label "Requires recompilation"):
    Address Sanitizer (+ indented "Detect use of stack after return",
    disabled), Thread Sanitizer (info button), Undefined Behavior
    Sanitizer — all off. Runtime API Checking: Main Thread Checker (on),
    Thread Performance Checker (on, info button). Memory Management:
    Hardware Memory Tagging (off; indented "Fall back to Guard Malloc"
    disabled), the note "Not checking allocations.", Malloc Scribble, Malloc
    Guard Edges, Zombie Objects, Malloc Stack Logging, Memory Graph on
    Resource Exception — all off. Metal: API Validation (on, help button)
    with indented "Include load and store actions", "Log non-fatal
    actions" (off); Shader Validation (off, help) with disabled children
    (radio "Raise Runtime Issues on Error" + "Set Breakpoint" button, "Abort
    on Error", checked "Log allocation stack traces", checked "Detect GPU
    stack overflow"); Metal Performance HUD; Log Graphics Overview (off).
    Core AI: "Include Model Debug Information" (off, help).
- **Test** (test-plan scheme, no tabs): Build Configuration (Debug);
  Debugger "Debug executable" (on); Debug Process As (disabled radios);
  LLDB Init File; a table "Test Plans | Default" with row "Obs
  (Autocreated)" / "1 test target, 1 configuration", a go-to arrow, and
  the Default radio selected; footer +/–.
- **Profile** tabs: Info, Arguments, Options. Info: Build Configuration
  (Release), Executable (Obs), Instrument ("Ask on Launch").
- **Analyze**: only Build Configuration (Debug).
- **Archive**: Build Configuration (Release), Archive Name (text, "Obs"),
  Options "Reveal Archive in Organizer" (on), "Allow Archiving for
  Simulator" (off).
- Product ▸ Scheme submenu: Choose Scheme ⌃0, Select Next Scheme ⌃⌘],
  Select Previous Scheme ⌃⌘[ (disabled with one scheme), Edit Scheme… ⌘<,
  New Scheme…, Manage Schemes…, then the scheme list with a check mark.

## Editor tabs (user settings: Pin Editor Tabs = Manually, double-click =
same as click; editor tab bar was hidden by the user)

- View menu: "Show Editor Tab Bar" / "Hide Editor Tab Bar" toggles it.
  "Pin Editor Tab" is ⇧⌘P.
- With the bar visible and one tab, the tab fills the width as one capsule
  with the file icon + name (no extension).
- Navigator single-click or double-click replaces the content of the
  current unpinned tab (no new tab).
- After Pin Editor Tab, the tab shows a pin icon at its right end; the next
  navigator click opens a **new** tab to its right, and tabs share the width
  equally. The selected tab is highlighted.
- Hovering a tab shows a close "×" at its left end, and a tooltip with the
  name and the path ("Obs › Sources › ObsKit").
- File menu with two tabs: Close Tab ⌘W, Close "<file>" ⌃⌘W, Close Editor
  Pane ⌃⇧⌘W (disabled with one pane), Close Window ⇧⌘W, Close Package
  ⌃⌥⌘W; also Duplicate Editor Tab, Open in New Tab ⌥⌘O, Open in New
  Window, Open Terminal at Location, Open with External Editor.
- Window menu: Rename Window Tab… ⌥⇧⌘T, Show Previous Window Tab ⌃⇧⇥,
  Show Next Window Tab ⌃⇥, Move Tab to New Window, Merge All Windows (all
  disabled without window tabs); Developer Documentation ⇧⌘0, Welcome to
  Xcode ⇧⌘1, Downloads, Organizer ⌥⇧⌘O; Touch Bar ▸; Bring All to Front;
  Remove Window from Set; the window list ("Obs — <editor title>").

## Project navigator (package)

- Root: package name. Children in order: "Package" (manifest), "Sources",
  "Tests". Files show without extensions here ("main", "Shapes").

## Debug area after a run

- The run finished without stopping. The breakpoint marker was drawn
  outlined, likely unresolved at our scratch path. The console showed the
  program output, then "Program ended with exit code: 0" as its own
  paragraph. Activity view: "Finished running Obs".
- Variables-view bottom bar: scope pop-up with Auto (default), Local
  Variables, "All Variables, Registers, Globals and Statics". Then an eye
  (Quick Look) button and an info button, then a filter.
- Console bottom bar: an eye (Quick Look) button, an output-options button
  that opens a popover with a "Metadata" switch (on) and checkboxes Type,
  Timestamp, Library, PID:TID, Subsystem, Category (all off), then a filter
  field with a filter-options button, a trash (clear) button, and the two
  split toggles (show variables / show console).

# Pass 3 (2026-10-17 afternoon): project editor, catalogs, templates, Organizer

Sample: a hand-written iOS app project "ObsApp" (objectVersion 77, one app
target, one synchronized root folder with two Swift files, an asset
catalog with AccentColor and AppIcon, and a plist with keys zeta, alpha,
middle in that order). Personal names, teams, org identifiers and the
user's own app names seen on screen are not recorded.

## Project navigator
- The synchronized folder shows as a folder. Its children are sorted by
  name, with extensions hidden: Assets, ContentView, ObsAppApp, Settings.
- After the project opened, the toolbar showed a warning count of 1
  (signing: no development team) and the destination "iPhone 18 Pro".

## Project editor
- Selecting the project row opened the editor on the **target**
  (General tab), not on the project. The left column lists PROJECT
  (ObsApp) and TARGETS (ObsApp), with +/− and a Filter at the bottom, and
  a collapse button at its top.
- Target tabs: General, Signing & Capabilities, Resource Tags, Info,
  Build Settings, Build Phases, Build Rules.
- **General**, in order:
  - Supported Destinations: a table Destination | SDK with rows iPhone
    (iOS), iPad (iOS), "Mac (Designed for iPad)" (iOS), "Apple Vision
    (Designed for iPad)" (iOS), and +/−.
  - Minimum Deployments: "iOS" with a combo box "27.0" and "+", and an info
    button by the title.
  - Identity: App Category (pop-up None), Display Name (placeholder
    "Display Name"), Bundle Identifier, Version (1.0), Build (1). Each has
    a "+" or "→" at the right.
  - Deployment Info: iPhone Orientation (Portrait, Upside Down,
    Landscape Left, Landscape Right checkboxes), iPad Orientation (same),
    Status Bar Style (Default), "Hide during application launch", and a
    "Scene manifest →" row.
  - App Icons and Launch Screen: App Icon (AppIcon), App Icons Source
    ("Include all app icon assets"), Launch Screen File (combo,
    placeholder "Storyboard Base Name").
  - Frameworks, Libraries, and Embedded Content: Name | Embed, empty text
    "Add frameworks, libraries, and embedded content here", +/−.
  - Development Assets: empty text "Add development assets here", +/−.
  - Supported Intents: Class Name | Authentication, empty text "Add
    intents eligible for in-app handling here", +/−.
- **Signing & Capabilities:**
  - A "+ Capability" button, then a scope control "All | Debug | Release".
  - Section "Signing": "Automatically manage signing" (on) with the note
    "Xcode will create and update profiles, app IDs, and certificates.";
    Team (pop-up, None here); Bundle Identifier.
  - A grouped "iOS" box: Provisioning Profile "Xcode Managed Profile",
    Signing Certificate "Apple Development", and Status with a warning:
    "Signing for "ObsApp" requires a development team." / "Select a
    development team in the Signing & Capabilities editor."
  - Empty state below: "Add capabilities by clicking the "+" button above."
  - **The capability library** is a panel titled "Capabilities" with a
    filter field and list/grid toggles. It has an alphabetical list (5G
    Network Slicing, Access Wi-Fi Information, Accessibility Merchant API,
    Accessory Data Provider, Accessory Setup Extension, Accessory Transport
    Extension, Accessory Transport Security, Account Creation Requirements,
    App Attest, App Attest Opt-In, App Groups, …) and a detail pane with the
    icon, the name and a description. Without a team, the footer reads "Error
    Loading Capabilities / No development team is set. Select a team in the
    Signing & Capabilities editor."
- **Resource Tags:** "+", a scope "All | Prefetched", a Filter, and the
  empty text "Click the "+" button above to add a resource tag."
- **Info:**
  - Section "Custom iOS Target Properties": a table Key | Type | Value
    showing human-readable key names, with type pop-ups. Generated values
    show as `$(…)`. Observed order: Bundle name, Bundle identifier,
    InfoDictionary version, Bundle version string (short), Bundle version,
    Executable file, Application requires iPhone environment, Application
    Scene Manifest (Dictionary, 2 items), Supported interface orientations
    (Array, 3 items), Bundle OS Type code, Launch Screen (Dictionary, 1
    item), Default localization, Application supports indirect input
    events.
  - Collapsed sections: Document Types (0), Exported Type Identifiers (0),
    Imported Type Identifiers (0), URL Types (0).
- **Build Settings:**
  - Bar: "+", then Basic | Customized | All, Combined | Levels, Names |
    Titles, Definitions | Values, and a filter field. Defaults: Basic,
    Combined, Titles, Values.
  - Sections are collapsible, each with a header row "Setting | <target
    icon> ObsApp". Settings defined at this level are **bold**; inherited
    ones are plain.
  - Basic showed: Deployment (Installation Directory, Strip Linked Product,
    Targeted Device Families); Info.plist Values (Application Scene
    Manifest (Generation), Launch Screen (Generation), Supported Interface
    Orientations, Supports Indirect Events); Linking - General (Runpath
    Search Paths); Packaging (Generate Info.plist File, Info.plist File,
    Product Bundle Identifier, Product Name); Signing (Code Signing Style);
    Versioning (Current Project Version, Marketing Version); Swift Compiler
    - Language (Swift Language Version "Swift 6"); User-Defined
    (ASSETCATALOG_COMPILER_APPICON_NAME,
    ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME and ENABLE_PREVIEWS
    appeared here by raw name).
  - Levels view columns: Setting | Resolved | <target> | <project> (and the
    platform default further right). The winning level's cell is boxed.
    Settings that differ per configuration expand to Debug and Release rows
    and show "<Multiple values>".
- **Build Phases:**
  - "+" and a Filter. Phases are collapsible rows titled "<Phase> (N
    items)": Target Dependencies, Run Build Tool Plug-ins, Compile Sources,
    Link Binary With Libraries, Copy Bundle Resources. Removable phases
    have a trash button.
  - Members of the synchronized folder are counted and listed as
    "ContentView.swift  …in ObsApp". Compile Sources has the columns
    Name | Compiler Flags.
  - The "+" menu: New Copy Files Phase, New Run Script Phase | New
    Headers Phase, New Copy Bundle Resources Phase, New Compile Sources
    Phase, New Link Binary With Libraries Phase, New Build Carbon
    Resources Phase. The last four are disabled because those phases
    already exist or don't apply.
- **Build Rules:** "+", a scope "All | Custom", a Filter. System rules are
  listed by name (Compile Reality Assets, Compile SceneKit Shaders,
  Compile Skybox, Compress PNG Files, Copy SceneKit Assets, …), each with
  "Process: <file type>" and "Using: <tool spec identifier>" lines and a
  "Copy to Target" button.
- **Project** (PROJECT row) tabs: Info, Build Settings, Package
  Dependencies.
  - Info: section Configurations, a table Name | Based on Configuration
    File with disclosure rows Debug and Release ("No Configurations Set"),
    +/−, "Use [Release] for command-line builds", and "Parallelize build
    for command-line builds (does not apply when using schemes)" (on).
    Section Localizations: a table Localization | Default | Resources
    (Base, "0 Files Localized"; English ✓, "0 Files Localized"), +/−, a
    "Set Default" button, and "Use Base Internationalization" (on). No
    deployment-target section.
  - Package Dependencies: section "Packages (0 items)", a table Name |
    Location | Dependency Rule, the empty text "Add packages here", +/−.
- **File inspector for the project:** Identity and Type (Name, Location
  Absolute (disabled), "Containing directory", Full Path); Project Document
  (Compatibility pop-up "Xcode 16.0" for objectVersion 77; Encoding
  "Minimize Project References" checked; Decoding "Strictly Validate"
  unchecked; Organization; Class Prefix); Text Settings.

## Property list editor
- Columns Key | Type | Value. The Root row is "Dictionary (3 items)". The
  file's **key order is kept**: zeta, alpha, middle. An integer shows as
  type "Number". An array shows "(2 items)" with a disclosure.

## Asset catalog editor
- The left outline lists sets (AccentColor, AppIcon) with +/− and a Filter
  at the bottom. The inspector gets a fourth tab (attributes).
- AppIcon set: a header label "AppIcon" on the left and the type "App Icon"
  on the right. One dashed slot labelled "1024x1024px", captioned "iOS"
  / "1,024pt". Inspector "App Icon": Name; iOS (Single Size); macOS (None);
  watchOS (None); Appearances (None); Gamut (Any).
- AccentColor set: header "AccentColor" and type "Color"; one slot
  "Universal". Inspector "Color Set": Name; Devices checkboxes Universal
  (on), iPhone, iPad (and Mac Catalyst), Mac Catalyst Scaled (info
  button), CarPlay, Mac, Apple Vision, Apple Watch, Apple TV; Appearances
  (None); High Contrast; Gamut (Any); Localization with a "Localize…"
  button.
- "+" menu: Image Set, Color Set, Symbol Image Set, Data Set, AR and
  Textures ▸ (Texture Set, Sprite Atlas, Cube Texture Set | AR Resource
  Group, AR Reference Image, AR Reference Object) | iOS ▸ (iOS App Icon,
  iOS Launch Image (Deprecated), Messages Extension Icon | Sticker Pack,
  Sticker, Sticker Sequence, Sticker Sequence Frame), macOS ▸, watchOS ▸,
  tvOS ▸, visionOS ▸ | Folder, Folder with Namespace, Folder from
  Selection | Import….

## Run destination menu
- A filter field at the top. Sections: "Recent" (the current destination
  checked); "Devices" ("My Mac (Designed for iPad)", then connected
  devices); "Simulators"; "Build" ("Any iOS Device (arm64)", "Any iOS
  Simulator Device (arm64, x86_64)"); then "Incompatible ▸" and "Manage
  Devices…".
- Each row has a device icon, the name, and the OS version right-aligned
  ("27.0", "27.1", "26.5"). Simulators with custom names came first,
  alphabetically, then the default devices by model family (iPhone 17,
  17 Pro, 17 Pro Max, 17e, 18 Pro Max, Air, then iPad, then Apple Vision
  Pro "(Designed for iPad)" per runtime).

## File menu
- With a single editor tab (tab bar hidden), ⌘W is **Close Window** and
  ⌃⌘W is Close "<file>". With two tabs it was Close Tab ⌘W (pass 2).
- New ▸: Conversation, Tab ⌘T, Editor Pane On Right ⌃⌘T, Editor Pane
  Below ⌃⌥⌘T, Window Tab, Window ⇧⌘T | Empty File, File from Template…
  ⌘N, Target… | Project… ⇧⌘N, Workspace… ⌃⌘N | Folder ⌥⌘N, Folder from
  Selection.

## New File from Template sheet
- Title "Choose a template for your new file:". Platform tabs: iOS, macOS,
  watchOS, tvOS, visionOS, DriverKit. Filter field. Icon grid in sections
  with sticky headers:
  - Source: Swift File, Cocoa Touch Class, Objective-C File, Header File,
    C File, C++ File, Metal File.
  - User Interface: SwiftUI View, Storyboard, View, Empty, Launch Screen.
  - Test: Swift Testing Unit Test, XCTest Unit Test, XCTest UI Launch
    Test, XCTest UI Test, Test Plan.
  - Core Data: Data Model, Mapping Model.
  - Resource: App Privacy, Asset Catalog, GeoJSON File, GPX File, Icon
    Composer Icon (two entries), Module Map, Property List, Rich Text File,
    SceneKit Catalog, SceneKit Scene File, Settings Bundle, SiriKit Intent
    Definition File, SpriteKit Action, SpriteKit Particle File, SpriteKit
    Scene, SpriteKit Tile Set, Sticker Catalog, String Catalog, Strings
    File (Legacy), Stringsdict File (Legacy), Touch Alternatives.
  - Documentation: Documentation Catalog, Article File, Extension File,
    Empty, Tutorial Table of Contents File, Tutorial File.
  - Other: Empty, Assembly File, Build Phase File List, CLIPS File,
    Configuration Settings File, Exports File, GameKit Bundle, Markdown
    File, PCH File, Shell Script, StoreKit Configuration File.
- Buttons: Cancel, Previous (disabled on the first step), Next. Swift File
  → Next opens a save sheet: "Save As:" ("File" preselected), Tags,
  Where (folder pop-up + expand button), plus an accessory with Group
  (pop-up) and Targets (a checkbox list, the current target checked).
  Buttons Cancel and Create. Cancel goes back to the template sheet.

## New Project
- File ▸ New ▸ Project… first shows a **compact picker**, not the sheet:
  header "+ New Project"; rows with icon, title and subtitle: "App —
  SwiftUI app for iPhone, iPad, Mac & Vision Pro", "Command Line Tool —
  Terminal program for macOS", "Package… — Swift package library",
  "Playground — Explore previews & playgrounds in a Swift file", "Choose
  Template… — Other apps, libraries, and games…".
- Choose Template… opens a new empty workspace window with the template
  sheet "Choose a template for your new project:". Platform tabs:
  Multiplatform, iOS, macOS, watchOS, tvOS, visionOS, DriverKit, Other.
  - Multiplatform: Application (App, Document App, Foveated Streaming App,
    Game, Audio Unit Extension App, Safari Extension App); Framework &
    Library (Framework).
  - iOS: Application (App, Document App, Game, Augmented Reality App, App
    Playground, Sticker Pack App, iMessage App, Safari Extension App);
    Framework & Library (Framework, Static Library, Metal Library).
  - The last selection was remembered (Framework was preselected).
- The options step "Choose options for your new project:" (iOS App):
  - Product Name.
  - Team (pop-up).
  - Organization Identifier.
  - Bundle Identifier: grey and derived, "<org>.ProductName" while the
    name is empty.
  - Interface: SwiftUI or Storyboard.
  - Language: Swift.
  - Testing System: None, "XCTest for Unit and UI Tests", or "Swift
    Testing with XCTest UI Tests" (the default).
  - Storage: None, SwiftData or Core Data.
  - "Host in CloudKit" (disabled while Storage is None).
  - Buttons: Cancel, Previous, Next. Next stays disabled until a name is
    entered.
  - Tooltip on Interface: "The type of user interface."
- Cancel closed the sheet and its empty window.

## Organizer (Window ▸ Organizer ⌥⇧⌘O)
- Window with a sidebar:
  - an app picker at the top;
  - Products: Archives;
  - Insights: Overview;
  - Reports: Crashes, Disk Writes, Energy, Feedback, Hangs, Launches;
  - Metrics: Battery Usage, Disk Writes, Hang Rate, Hitches, Launch Time,
    Memory, Storage, Terminations.
- The toolbar has back/forward buttons, the page title and a bell button.
- Overview empty state: "No Overview Data" / "There is no overview data
  available for version 1.0."

# Pass 4 (2026-10-18 late evening): source control, debugging, Quick Help, refactoring, previews

Samples: a copy of "ObsApp" in a git repository (branch feature/observe, two
commits, one modified tracked file and one untracked file) and the "Obs"
package, with a breakpoint, a background dispatch queue and a doc-commented
function. Both live at a path with no symlinks. The user's identity, as shown
in the commit header, is not recorded.

## Source control status in the project navigator
- Files carry status letters at the right: "M" (modified), "?" (untracked).
- The debug bar's right end shows the current branch with a branch icon
  ("feature/observe").

## Source Control navigator (⌘2)
- Segmented control at the top: **Changes | Repositories**.
- **Changes:**
  - A header row "<repo> <branch>" (branch in secondary text).
  - A group "Uncommitted Changes" with a count.
  - One row per changed item with its icon, name (no extension) and a boxed
    status letter (?, M). Untracked workspace user data (project.xcworkspace,
    xcuserdata) shows too.
- **Selecting a change opens the commit editor:**
  - Header: author avatar, name and email, an "Amend "<short hash>"" switch,
    and a "Commit" button with a menu chevron. It's disabled until there's a
    message.
  - A message field with the placeholder "Commit message (required)".
  - Scope "All Changes | Unstaged | Staged" and a "Stage All" button.
  - One collapsible card per file. Its title is the icon and name (for a
    workspace: "<project> / project.xcworkspace"). Its right end has a discard
    (↺) button and the status letter. The body is the diff: line numbers,
    context lines, and added lines highlighted with a bar at the left. A new
    file shows its whole content numbered.
- **File inspector** while a change is selected: Identity and Type with
  "Working Copy" and "Relative Path" rows, then "On Demand Resource Tags"
  ("Only resources are taggable"), "Target Membership" (the target with
  "Default" and +/−/edit buttons), and Text Settings.
- **Repositories:**
  - Root "<repo> <branch>". Groups: Branches, Recents, Tags, Stashes,
    Remotes.
  - Branch names with "/" are grouped into folders ("feature" ▸ observe).
- **Selecting a branch** shows its history:
  - Scope "All | Last 24 Hours | Last 7 Days | Last 30 Days" and a Filter.
  - Commit rows: avatar, author, a branch tag ("main"), the message, then the
    short hash and the relative day ("Today") at the right.
  - The inspector gains a fourth (branch) tab: "Branch": Name, Remote ("No
    Remote"), Remote Branch ("No Remote Branch").
- **Selecting a commit:**
  - A lower pane shows the commit: path bar "Commit › <repo> › No
    Selection", author name and email, date "Oct 18, 2026 at 11:46 PM", a
    hash badge, and the message.
  - Inspector "Commit": Identifier (full hash), Date, Author, Verification
    ("Commit unverified"), Branches (every branch that contains it), "Commit
    Message", and "Files" (icon, name, status letter A/M/D).

## Integrate menu
- Section "Source Control": Commit… ⌥⌘C, Push…, Pull… ⌥⌘X, Fetch Changes,
  Refresh File Status | Stage All Changes, Stage Changes in Selected Files,
  Unstage All Changes, Unstage Changes in Selected Files, Mark Selected Files
  as Resolved | Add Selected Files, Cherry-Pick…, Stash Changes… | Discard All
  Changes…, Move Selected Files to Trash… | Clone…, New Git Repository….
- Section "Xcode Cloud": Create Workflow…, Manage Workflows….
- Items that don't apply to the selection are disabled.

## Inline issues in the editor
- Once paths resolve (no /tmp symlink), each issue line is tinted and has a
  severity icon and the message at the right end, truncated with "…". The
  offending symbol is underlined.
- After an edit, existing annotations turn grey (stale) until the next
  build.

## Running and the debugger
- The activity view reads "Running Obs", then "Paused Obs" at a breakpoint,
  then "Finished running Obs".
- **Breakpoint hit:**
  - The editor line is highlighted green with the annotation "Thread 2:
    breakpoint 1.1 (1)".
  - The debug navigator (⌘7) opens automatically.
  - The console shows the "(lldb)" prompt in a green band.
- **Debug navigator:**
  - Process row "Obs  PID 95225" with two buttons at its right.
  - Gauges: CPU (0%), Memory (Zero KB), Energy Impact ("Very High", with a
    bar), Disk (Zero KB/s), Network (Zero KB/s).
  - Threads: "Thread 1  Queue: com.apple.main-thread (serial)" (shown
    truncated "co…read (serial)"), "Thread 2  Queue: <label> (serial)",
    "Thread 3".
  - The stopped thread expands to frames "0 Circle.area()", "1 work(_:)",
    "2 closure #1 in …". Then a dotted separator, then system frames greyed
    ("10 _pthread_wqthread"). Frames from the user's code have a user icon.
  - Bottom bar: filter field, then three icons (layers, process view options
    gear, and a blue control).
- **Debug bar while paused:**
  - Breakpoints toggle, Continue, Step Over, Step Into, Step Out.
  - Then, by tooltip: "Enable Backtrace in Editor", "Debug View
    Hierarchy", "Debug Memory Graph", "Environment Overrides", "Simulate
    Location".
  - Then the path "Obs › Thread 2 › 0 Circle.area()".
- **Variables view (Auto):** the rows load after a delay (spinner). Rows are
  "A self: ObsKit.Circle" (argument badge "A") and "L unused: Int = 3",
  "L neverMutated: Double = 9" (local badge "L"), in the form "name: Type
  = value".
- **Stop** prints "Debug session ended with code 9: killed" (highlighted) and
  "Program ended with exit code: 9".

## Breakpoint navigator (⌘8)
- Root "<project>  N Breakpoint(s)", then a file group "Shapes.swift", then
  the row: a kind badge (M for a method), "area()  7", "ID 1.1", and a blue
  enabled marker at the right.
- Bottom: "+" opens Swift Error Breakpoint, Exception Breakpoint…, Symbolic
  Breakpoint…, Runtime Issue Breakpoint…, Constraint Error Breakpoint, Test
  Failure Breakpoint. Then a filter field with two toggles.
- Breakpoints are kept per user in the package's or project's user data and
  carry over to a copy of it.

## Quick Help inspector (third inspector tab)
- Undocumented symbol: title ("Circle"), a declaration box ("struct
  Circle"), a link to the defining file ("Shapes.swift"), "Open in Developer
  Documentation".
- Documented symbol, in order:
  - title "greet(_:)" and the summary line;
  - the declaration box, wrapped;
  - the file link;
  - "Parameters" (name, then its description);
  - "Return Value";
  - "Discussion" (the body paragraphs);
  - a "Note" callout box (title "Note" and its text);
  - "Open in Developer Documentation".

## Editor menu and Refactor submenu
- Editor menu, in order:
  - Show Editor Only ⌘↩
  - ✓Canvas ⌥⌘↩, Assistant ⌃⌥⌘↩, Code Review ⌥⇧⌘↩, Layout ▸
  - Show Completions ⌃Space, Show Predictive Completion ⌃⌥Space, Show Coding
    Tools ▸, Edit All in Scope ⌃⌘E, Show Callers…, Expand Macro, Hide All
    Macro Expansions, Refactor ▸
  - Fix All Issues ⌃⌥⌘F, Show Issues ⌃⌥⌘L, Hide All Issues ⌃⌘L, Show Markdown
  - Selection ▸, Structure ▸, Code Folding ▸, Syntax Coloring ▸, Font Size ▸,
    Choose Theme…
  - ✓Inline Comparison, Side By Side Comparison
  - ✓Minimap ⌃⇧⌘M, Authors ⌃⇧⌘A, Code Coverage
  - Vim Mode, Relative Line Numbers
  - Invisibles, Scope Guides, ✓Wrap Lines ⌃⇧⌘L
  - Show Last Change for Line, Create Code Snippet…
- Refactor ▸, in order:
  - Rename…
  - Extract Selection to File, Extract to Function, Extract to Method,
    Extract to Variable, Extract All Occurrences
  - Add Missing Abstract Class Overrides, Add Missing Protocol Requirements,
    Add Missing Switch Cases, Convert to Switch, Convert to Regex Builder,
    Expand Default, Generate Memberwise Initializer, Generate Missing Function
    Definitions, Wrap in NSLocalizedString
  - Convert Function to Async, Change Localized String Key, Convert Localized
    String to Symbol, Convert to Localized String Literal

  Items that don't apply at the cursor are disabled.

## Empty editor
- With no file open, the editor area shows an "Open Quickly" search field
  and a "Recent Files" list. Each row has the file icon, the name without
  extension, and a breadcrumb of its folder path.

## SwiftUI preview canvas
- With a #Preview in the file and the canvas on, the canvas sits below the
  editor in a narrow window.
- First it shows a "Canvas paused" capsule with a resume button. After
  resume, a tab "ContentView" (spinner while it builds, then an eye icon),
  then the device-framed preview.
- Bottom bar: four mode buttons at the left (the first, selected, has the
  tooltip "Live"), the zoom pop-up "30%" in the middle, and three buttons at
  the right (zoom to fit, device settings, canvas settings).
- The first build took about 60–120 s.

## Not observed this pass
- Interface Builder: opening a storyboard was refused by the session's
  safety check ("could not verify which document this window is editing").
- Rename in place, completion and Open Quickly ranking: these need typing,
  which this session's access level doesn't allow.

## Interface Builder (storyboard opened from the Finder side)
- Layout: the document outline is a column to the left of the canvas, with a
  Filter at the bottom. The canvas shows each scene with a title bar ("View
  Controller") above a device-shaped frame, and an entry-point arrow pointing
  at the initial scene.
- Outline: "View Controller Scene" › "View Controller" › "View" › Safe Area,
  then the subviews named by their content with a kind badge ("L" Hello for a
  label, "B" Tap for a button), then "Constraints" (collapsible). After the
  view controller come First Responder, Exit and Storyboard Entry Point. Each
  has its own icon.
- Selecting a subview in the outline selects it on the canvas: handles,
  plus alignment-guide lines through the centre for its centring
  constraints. The jump bar shows the whole path: <project> › <group> ›
  Main › View Controller Scene › View Controller › View › Hello.
- The inspector area has seven tabs for a storyboard: File, History, Quick
  Help, Identity, Attributes, Size, Connections.
- Canvas bottom bar:
  - left: an outline toggle, "+", an issues indicator, the appearance
    toggle, an orientation button and a layout button;
  - the device pop-up ("iPhone 16");
  - zoom "−  79%  +";
  - right: update frames, align, pin (add constraints), resolve
    auto-layout issues, embed in.
- Not observed: the inspectors' contents. Clicks into the inspector were
  refused by the session's safety check.

# Pass 4b (2026-10-19, Xcode in full screen after a restart, two windows)

## Interface Builder inspectors
- **View Controller ▸ Attributes:**
  - Simulated Metrics: Size, Top Bar, Bottom Bar, Keyboard (all "Inferred").
  - View Controller: Title; "Is Initial View Controller" (on); Activity Name.
  - Layout: Adjust Scroll View Insets (on), Hide Bottom Bar on Push, Resize
    View From NIB (on), Use Full Screen (Deprecated).
  - Extend Edges: Under Top Bars (on), Under Bottom Bars (on), Under Opaque
    Bars.
  - Transition Style (Cover Vertical); Presentation (Automatic); Defines
    Context; Provides Context.
  - Content Size: "Use Preferred Explicit Size", with Width 393 and Height
    852 (disabled).
  - Key Commands: a table with +/−, and Key ("Enter ⌘ Key") and Selector
    ("action") fields.
- **View Controller ▸ Identity:**
  - Custom Class: Class (placeholder "UIViewController", a go-to arrow and a
    pop-up), Module ("None"), "Inherit Module From Target" (disabled).
  - Identity: Storyboard ID, Restoration ID, "Use Storyboard ID".
  - User Defined Runtime Attributes: Key Path | Type | Value, +/−.
  - Document: Label (placeholder "Xcode Specific Label"), a row of colour
    tags (clear + 7 colours), Object ID ("vc1", the XML id), Lock
    ("Inherited - (Nothing)"), Localizer Hint (placeholder "Comment For
    Localizer").
- **View Controller ▸ Size:** "View Controller": Simulated Size (Fixed).
- **View Controller ▸ Connections:**
  - Triggered Segues: manual.
  - Outlets: searchDisplayController, and view, connected to "View" (a
    capsule with an × to disconnect).
  - Presenting Segues: Relationship, Show, Show Detail, Present Modally,
    Present As Popover, Embed, Push (deprecated), Modal (deprecated),
    Custom.
  - Referencing Outlets: New Referencing Outlet.
  - Referencing Outlet Collections: New Referencing Outlet Collection.
  - Each row has a connection circle at the right.
- **Label ▸ Attributes, "Label" section:**
  - Text (Plain), then the text field ("Hello"); "+" Color ("Default (Label
    Color)"); "+" Font ("System 17.0", with a font button).
  - Dynamic Type "Automatically Adjusts Font"; Alignment segments (left,
    centre selected, right, justified, natural); Lines (1).
  - Behavior: Enabled (on), Highlighted. Tooltip: "Shows Expansion Text".
  - Baseline (Align Centers); Line Break (Truncate Tail); Strategy
    (Standard); Autoshrink (Fixed Font Size); Tighten Letter Spacing.
  - Sizing Rule (Typographic); "+" Highlighted (Default); "+" Shadow
    (Default); Shadow Offset (Width 0, Height −1).
- **Label ▸ Attributes, "View" section:**
  - Content Mode (Left), Semantic (Unspecified), Tag (0).
  - Interaction: User Interaction Enabled, Multiple Touch.
  - Alpha (1); "+" Background (Default); "+" Tint (Default).
  - Drawing: Opaque, Hidden, Clears Graphics Context (on), Clips to Bounds,
    Autoresize Subviews (on).
  - Stretching: X 0, Y 0, Width 1, Height 1.
  - The "+" buttons add per-trait variations.
- **Label ▸ Size:**
  - Label: Desired Width (Automatic).
  - View: Show (Frame Rectangle), with X/Y/Width/Height (177 / 415.67 / 39 /
    21); Arrange (Position View); Layout (Inferred (Constraints)); Layout
    Margins (Default); "+" Preserve Superview Margins, Follow Readable
    Width, Safe Area Relative Margins (on).
  - Constraints: a diagram, and a scope "All | This Size Class".
  - Groups "Horizontal" ("Align Center X to: Superview", Edit) and
    "Vertical" ("Align Center Y to: Superview", Edit), then "Showing 2 of 2".
  - Content Hugging Priority: Horizontal 250, Vertical 250.
  - Content Compression Resistance Priority: Horizontal 750, Vertical 750.
  - Intrinsic Size: Default (System Defined). Ambiguity: Always Verify.
- When a controller is selected, the scene title bar shows the scene's
  objects as icons (controller, first responder, exit).
- A small canvas overview (minimap) appears in the canvas's top-right corner
  while scrolling.

## Window menu (Xcode 27)
- There is no "Devices and Simulators" item. Devices are managed from the
  run destination menu's "Manage Devices…". The window list shows each
  window as "<project> — <document>".

## Toolbar right group, by tooltip
- An account/cloud button (blue dot).
- "Add Editor Tabs or Editor Panes".
- "Adjust Editor Options", a menu: Layout ▸ | ✓Inline Comparison, Side By
  Side Comparison | Minimap, Authors, Code Coverage | Invisibles, Scope
  Guides, ✓Wrap Lines | Choose Workspace Theme….
- A three-way toggle: "Show Canvas", "Show Assistant", and Code Review (⇆).

## Code Review mode
- **Inline:** changed lines are tinted with a bar in the gutter.
- **Debug bar:** "‹ N change(s) ›" (previous and next), then the left
  source ("Uncommitted Changes"), a swap button ⇆, and the right source
  ("Last Commit").
- **Source pop-up:** a two-column popover.
  - Left: "Branches & Tags" search, "Recents", and branches (the current one
    marked "(current)").
  - Right: "Commits" search, "Uncommitted Changes", "Unstaged/Staged
    Changes", and the commit list (author, date, short hash, subject).
- **Side By Side:** the working copy on the left and the comparison source
  on the right (read-only). A curved ribbon joins each change region, and an
  insertion marker shows where the added lines would go.

## Assistant editor
- A second pane with its own jump bar: a close (×) button, then the mode
  pop-up ("Counterparts"). It shows "No Editor" when there's nothing to show.
- Modes: Counterparts | Superclasses, Subclasses, Siblings, Extensions,
  Categories, Protocols | User Interfaces | Includes, Included By | Callers,
  Callees | Test Classes, Test Callers | Preprocess, Assembly | Disassembly |
  Generated Interface ▸ | Documentation Preview.

## Preview canvas (continued)
- In a wide window the canvas sits to the right of the editor. The
  activity view says "Preparing iPhone Simulator" while the preview builds.
- **Bottom bar:**
  - left: Live (▶, selected), Selectable, a crosshair button and a variants
    (grid) button;
  - centre: the zoom pop-up ("81%");
  - right: a capture button, the device button and canvas settings.
- **Device menu:** "✓ Automatic – <device>" | Recent (the device) | iPhone
  "Dynamic Island", iPhone "Touch ID", iPad 11-inch, iPad 13-inch (secondary
  text in grey) | Devices (connected devices) | More ▸.
- **Canvas settings popover:** switches for Display, Color Scheme,
  Contrast, Control Borders, Orientation, Dynamic Type (all off).
