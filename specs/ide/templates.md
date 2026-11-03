# New File and New Project

Ycode modules: `YcodeUI` (`FileTemplates`, `ProjectTemplates`,
`NewFileController`, `NewProjectController`), `YcodeProject` (mutations).

Ycode's templates are its own, written for Ycode: minimal contents, no
header comments, no copied wording.

Correction (2026-10-19): the sheets' layout and flow are
`reference-ui-3.md` §5. That means a sectioned template grid per platform
and then a save sheet for New File; the compact picker, then the template
sheet in an empty workspace window, then the options step for New
Project. This file keeps the template contents and generated-project
rules. `reference-ui-5.md` §11.3 lists the remaining gaps.

## New File (⌘N)

A sheet with a template list, a Name field, and Create. Templates:

| Template | Files | Content |
|---|---|---|
| Swift File | `Name.swift` | `import Foundation` |
| Swift Class | `Name.swift` | a `final class Name` with an empty `init()` |
| Objective-C Class | `Name.h`, `Name.m` | `@interface Name : NSObject` / `@implementation Name` |
| Header File | `Name.h` | `#pragma once` |
| Empty File | `Name` (as typed) | empty |
| Property List | `Name.plist` | an empty dictionary in XML form |

Files are written to the folder of the selected file (else the project's
directory, else the package's `Sources/<first target>` folder); an
existing file is never overwritten (Create fails).

Project update (`.xcodeproj` containers): the files get file references in
the group whose folder is the destination (else the main group); `.swift`,
`.m`, `.mm`, `.c`, `.cpp` files are added to the Compile Sources phase of
the project's first target that has one. When the destination is inside a
file-system-synchronized folder, or the container is a package, the
project is not changed (the folder picks the file up).

Correction (2026-10-30, NAV-OPS): in the IDE, new files are created
through the project navigator's operations (`navigators.md` §Ycode
implementation). With a project navigator selection they go to its
insertion point: the selected group (also a group without a folder), or
after the selected file in its group. The save step's Targets choose the
build phases; in a synchronized folder, every target that includes the
folder but is not checked gets an exception for the new file. Creation
is undoable.

## New Project (⇧⌘N)

A sheet with templates, Product Name, Organization Identifier (bundle id
prefix) and a location; Create writes `<location>/<Product Name>/…` and
opens it.

| Template | Result |
|---|---|
| macOS Command Line Tool | `Name.xcodeproj` with one `com.apple.product-type.tool` target; `Name/main.swift` printing a line |
| macOS App | `Name.xcodeproj` with one application target (`GENERATE_INFOPLIST_FILE`, `PRODUCT_BUNDLE_IDENTIFIER` = `<org>.<Name>`, `INFOPLIST_KEY_NSPrincipalClass` = `NSApplication`); `Name/NameApp.swift`: a SwiftUI `App` with one window showing a text |
| Swift Package | `Package.swift` (tools 6.0), `Sources/Name/Name.swift`, `Tests/NameTests/NameTests.swift` (one swift-testing test) |

Generated projects are built object by object with YcodeProject and
written by the pbxproj writer (object version 77): a main group with the
source folder group and a Products group, Debug and Release configurations
at project level (`SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET`,
`SWIFT_VERSION`, optimization and debug-info settings) and target level
(`PRODUCT_NAME = $(TARGET_NAME)`), sources and frameworks phases (plus
resources for apps).

### iOS App (options step)

Chosen from the compact picker's App row or the template sheet's iOS ▸
App, then the options step. Inputs: Product Name (`N`), Organization
Identifier (`O`), Interface, Testing System, Storage. Interface is
SwiftUI (the default, below) or Storyboard (see "Storyboard interface"). `T` is
`N` with only letters and digits kept (the Swift type prefix; "App" when
empty). Bundle identifier = `ProjectOptions.bundleIdentifier`.

Files under `<location>/N/`:

| Path | Always / when | Content |
|---|---|---|
| `N.xcodeproj/project.pbxproj` | always | see below |
| `N/TApp.swift` | always | `@main struct TApp: App` with a `WindowGroup { ContentView() }`; with SwiftData adds `.modelContainer(for: Item.self)`; with Core Data injects the persistence controller's view context as `\.managedObjectContext` |
| `N/ContentView.swift` | always | a SwiftUI view showing `N` (SwiftData: a list of `Item` with an Add button; Core Data: a list of `Item` from a fetch request) |
| `N/Assets.xcassets` | always | `Contents.json`, `AccentColor.colorset`, `AppIcon.appiconset` (one universal iOS 1024 slot, no image) |
| `N/Item.swift` | Storage = SwiftData | `@Model final class Item` with a `timestamp: Date` |
| `N/Persistence.swift` | Storage = Core Data | a `PersistenceController` that loads an `NSPersistentContainer(name: "N")` |
| `N/N.xcdatamodeld/N.xcdatamodel/contents` | Storage = Core Data | one entity `Item`, attribute `timestamp` (Date), codegen class definition |
| `NTests/NTests.swift` | Testing ≠ None | XCTest: `final class NTests: XCTestCase` with one test; Swift Testing: `import Testing`, one `@Test` |
| `NUITests/NUITests.swift` | Testing ≠ None | XCTest UI test that launches `XCUIApplication()` |

Targets (all `PBXNativeTarget`, each with Sources, Frameworks and
Resources phases):

| Target | `productType` | When |
|---|---|---|
| `N` | `com.apple.product-type.application` (`N.app`) | always |
| `NTests` | `com.apple.product-type.bundle.unit-test` (`NTests.xctest`) | Testing ≠ None |
| `NUITests` | `com.apple.product-type.bundle.ui-testing` (`NUITests.xctest`) | Testing ≠ None |

Test targets depend on `N` through `PBXTargetDependency` +
`PBXContainerItemProxy` (`proxyType = 1`, `remoteGlobalIDString` = the
app target). The Core Data model is a `XCVersionGroup`
(`versionGroupType = wrapper.xcdatamodel`) in the app's Sources phase.

Project-level settings (Debug/Release): `SDKROOT = iphoneos`,
`IPHONEOS_DEPLOYMENT_TARGET = 18.0`, `SWIFT_VERSION = 6.0`,
`ALWAYS_SEARCH_USER_PATHS = NO`, plus the Debug/Release optimization and
debug-info settings of the macOS templates.

App target settings: `PRODUCT_NAME = $(TARGET_NAME)`,
`PRODUCT_BUNDLE_IDENTIFIER = O.N'`, `GENERATE_INFOPLIST_FILE = YES`,
`INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`,
`INFOPLIST_KEY_UILaunchScreen_Generation = YES`,
`INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES`,
`TARGETED_DEVICE_FAMILY = "1,2"`,
`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`,
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`,
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor`,
`MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`,
`CODE_SIGN_STYLE = Automatic`, `ENABLE_PREVIEWS = YES`,
`LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks")`.

Unit-test target: `PRODUCT_BUNDLE_IDENTIFIER = <app id>Tests`,
`GENERATE_INFOPLIST_FILE = YES`, `BUNDLE_LOADER = $(TEST_HOST)`,
`TEST_HOST = $(BUILT_PRODUCTS_DIR)/N.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/N`.
UI-test target: `PRODUCT_BUNDLE_IDENTIFIER = <app id>UITests`,
`GENERATE_INFOPLIST_FILE = YES`, `TEST_TARGET_NAME = N`. Both carry
`TARGETED_DEVICE_FAMILY`, `SUPPORTED_PLATFORMS` and `CODE_SIGN_STYLE` as
the app does. The Testing System choice changes only `NTests.swift`'s
framework; the targets are the same for both non-None choices.

Storage = SwiftData or Core Data with Host in CloudKit: not modeled yet
(no entitlements are written; the flag is ignored).

#### Storyboard interface

Interface = Storyboard replaces the SwiftUI sources with a UIKit scene-based
app (Apple's UIKit app life cycle). Files under `<location>/N/N/`:

| Path | Content |
|---|---|
| `AppDelegate.swift` | `@main class AppDelegate: UIResponder, UIApplicationDelegate`; `application(_:didFinishLaunchingWithOptions:)` returns `true`; `application(_:configurationForConnecting:options:)` returns a `UISceneConfiguration` named "Default Configuration" for the session's role |
| `SceneDelegate.swift` | `class SceneDelegate: UIResponder, UIWindowSceneDelegate` with `var window: UIWindow?` (UIKit creates the window from the scene's storyboard) |
| `ViewController.swift` | `class ViewController: UIViewController` |
| `Base.lproj/Main.storyboard` | one scene: the initial view controller, class `ViewController`, `customModule` = the product module, `customModuleProvider="target"`, a root view with the system background color |
| `Base.lproj/LaunchScreen.storyboard` | one scene: a plain `UIViewController` with the system background color |
| `Info.plist` | only the scene manifest (below) |
| `Assets.xcassets` | as for SwiftUI |

Storage files (`Item.swift`; `Persistence.swift` + the data model) are
written as for SwiftUI but no view uses them. No `ContentView.swift`,
no `TApp.swift`.

Storyboards are XML `document` elements with
`type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB"`,
`version="3.0"`, `targetRuntime="iOS.CocoaTouch"`, `useAutolayout="YES"`,
`useSafeAreas="YES"`, and `initialViewController` = the view controller
`id`. Each `scene` (`sceneID`) holds `objects` with the `viewController`
(`sceneMemberID="viewController"`, a `view key="view"`) and the
`IBFirstResponder` placeholder. Object IDs are any unique strings
(Ycode uses `Ycd-<kind>-<n>`). `ibtool --compile` must accept both with
no errors or warnings.

Info.plist (`INFOPLIST_FILE = N/Info.plist`, merged with the generated
plist): `UIApplicationSceneManifest` = { `UIApplicationSupportsMultipleScenes`
= false; `UISceneConfigurations` = { `UIWindowSceneSessionRoleApplication`
= [ { `UISceneConfigurationName` = "Default Configuration";
`UISceneDelegateClassName` = `$(PRODUCT_MODULE_NAME).SceneDelegate`;
`UISceneStoryboardFile` = "Main" } ] } }. The file is in the app group
but in no build phase.

Project: each storyboard is a `PBXVariantGroup` (`name` = `Main.storyboard`
/ `LaunchScreen.storyboard`) with one `PBXFileReference` child
(`name = Base`, `path = Base.lproj/<file>`, `lastKnownFileType =
file.storyboard`); both variant groups are in the Resources phase with the
asset catalog. App target settings differ from SwiftUI: add
`INFOPLIST_FILE = N/Info.plist`, `INFOPLIST_KEY_UIMainStoryboardFile = Main`,
`INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen`; drop
`INFOPLIST_KEY_UIApplicationSceneManifest_Generation`,
`INFOPLIST_KEY_UILaunchScreen_Generation` and `ENABLE_PREVIEWS`. Test
targets are unchanged.

## Template chooser (New Project)

Added 2026-10-31 (OBS-TEMPLATES). This section and the next three
describe the reference's whole New Project flow as data. The flow is
made of the compact picker (`reference-ui-3.md` §5.4,
`reference-ui-6.md` §1.5), the template sheet, the options step and
the save step. The template names, option labels, option values and
setting names are interop facts. Every template summary is Ycode's own
wording. Ycode's file contents remain its own (§ "New Project" above).

### Entries and where they come from

The reference's catalog is a set of template *units*. A unit is
*concrete* (it can be picked) or *abstract* (it only feeds other
units). A concrete unit inherits from an ordered list of ancestors. A
Ycode catalog does not have to copy this layering. It needs only the
resolved result per template: the option list, then the targets,
settings and files for each set of choices. The tables below give
that result.

- **Tab** = the platform group: Multiplatform, iOS, macOS, watchOS,
  tvOS, visionOS, DriverKit, Other, in that order.
- **Section** = the category within a tab: Application,
  Framework & Library, Driver, Other.
- **Name** = the template's name as shown.
- **Shown in New Project** when the template is concrete and is not
  *target-only*. Target-only templates are offered only by File ▸
  New ▸ Target…. They are every Application Extension, Test and
  System Extension template, plus iOS App Clip, iOS Sticker Pack
  Extension, iOS iMessage Extension and Other ▸ Aggregate. The
  template Other ▸ Empty is *project-only*: it is never offered by
  New Target. Package templates are offered only by Package… (below).
  App Playground is a project-chooser entry of its own kind (below).
- **Section order:** alphabetical. **Template order within a section:**
  ascending sort key. Templates without a key come after those with
  one, and ties are broken by name. The keys are in the tables
  ("—" = none). Rule and keys reproduce the two observed lists exactly.
- A section with no shown template is not drawn. Every tab has at
  least one section.

### Tabs, sections and templates (New Project)

Multiplatform:

| Section | Template | Key | Ycode summary |
|---|---|---|---|
| Application | App | 1 | One SwiftUI app target for iOS, iPadOS, macOS and visionOS |
| Application | Document App | 1 | The same, built around a document type |
| Application | Foveated Streaming App | 10 | An iOS sender app and a visionOS receiver app that stream to each other |
| Application | Game | 10 | A game for iOS, tvOS, macOS and visionOS in the chosen game technology |
| Application | Audio Unit Extension App | 30 | A host app with an Audio Unit extension |
| Application | Safari Extension App | — | iOS and macOS apps, each with a Safari web extension |
| Framework & Library | Framework | 1 | A framework built for every Apple platform |

iOS:

| Section | Template | Key | Ycode summary |
|---|---|---|---|
| Application | App | 1 | An iOS app (SwiftUI or UIKit storyboard) |
| Application | Document App | 2 | An iOS document-based app |
| Application | Game | 10 | An iOS game (SceneKit, SpriteKit, Metal 4 or Metal) |
| Application | Augmented Reality App | 11 | An iOS AR app (RealityKit, SceneKit, SpriteKit or Metal) |
| Application | App Playground | 12 | A Swift Playgrounds app package (`.swiftpm`) |
| Application | Sticker Pack App | 30 | A Messages sticker pack with no code |
| Application | iMessage App | 31 | A Messages-only app with an iMessage extension |
| Application | Safari Extension App | — | An iOS app with a Safari web extension |
| Framework & Library | Framework | 1 | An iOS framework |
| Framework & Library | Static Library | 10 | An iOS static library |
| Framework & Library | Metal Library | — | A standalone `.metallib` |

macOS:

| Section | Template | Key | Ycode summary |
|---|---|---|---|
| Application | App | 1 | A macOS app (SwiftUI, storyboard or XIB) |
| Application | Document App | 1 | A macOS document-based app |
| Application | Game | 10 | A macOS game (RealityKit, SceneKit, SpriteKit, Metal 4 or Metal) |
| Application | Spatial Rendering App | 11 | A macOS app that renders an immersive space for Apple Vision Pro |
| Application | Command Line Tool | 50 | A command-line tool (Swift, Objective-C, C++ or C) |
| Application | Safari Extension App | — | A macOS app with a Safari web or app extension |
| Framework & Library | Framework | 1 | A macOS framework |
| Framework & Library | Library | 10 | A dynamic or static library (Cocoa, C++ STL or plain C) |
| Framework & Library | XPC Service | 100 | An XPC service bundle |
| Framework & Library | Bundle | 101 | A loadable bundle with a chosen extension |
| Framework & Library | Metal Library | — | A standalone `.metallib` |
| Other | Generic Kernel Extension | — | A C kernel extension |
| Other | IOKit Driver | — | A C++ IOKit kernel extension |
| Other | Installer Plug-in | — | An Installer pane plug-in |
| Other | Instruments Package | — | An Instruments package |
| Other | Preference Pane | — | A System Settings pane bundle |
| Other | Screen Saver | — | A screen saver bundle |

watchOS:

| Section | Template | Key | Ycode summary |
|---|---|---|---|
| Application | App | 1 | A watchOS app, alone or with a companion iOS app |
| Framework & Library | Framework | 1 | A watchOS framework |
| Framework & Library | Static Library | 10 | A watchOS static library |

tvOS:

| Section | Template | Key | Ycode summary |
|---|---|---|---|
| Application | App | 1 | A tvOS app (SwiftUI or storyboard) |
| Application | Game | 10 | A tvOS game (RealityKit, SceneKit, SpriteKit, Metal 4 or Metal) |
| Framework & Library | Framework | 1 | A tvOS framework |
| Framework & Library | Static Library | 10 | A tvOS static library |
| Framework & Library | Metal Library | — | A standalone `.metallib` |

visionOS:

| Section | Template | Key | Ycode summary |
|---|---|---|---|
| Application | App | 1 | A visionOS app with a window or a volume, and optionally an immersive space |
| Application | Immersive Environment App | 1 | A visionOS app that opens a full or progressive environment |
| Framework & Library | Framework | 1 | A visionOS framework |
| Framework & Library | Static Library | 10 | A visionOS static library |

DriverKit:

| Section | Template | Key | Ycode summary |
|---|---|---|---|
| Driver | Driver | — | A DriverKit driver extension |
| Framework & Library | Framework | 1 | A DriverKit framework |
| Framework & Library | Library | 10 | A DriverKit dynamic or static library |

Other:

| Section | Template | Key | Ycode summary |
|---|---|---|---|
| (none) | Empty | — | A project with no targets |
| (none) | External Build System | — | A legacy target that runs a build tool |

The Other tab's templates sit directly in the tab, in no named
section. Ycode draws them in one unnamed section.

Each template also has an icon: an SF Symbol name or an image of
Xcode's own. Ycode uses its own symbols. A one-line description exists
for each template, but whether 27.1 shows it in the chooser was not
observed (OPEN).

### Package… (package chooser)

The compact picker's Package… row opens a second chooser of the same
shape. It has its own remembered tab (below).

| Tab | Section | Template | Key | SwiftPM init type | Options |
|---|---|---|---|---|---|
| Multiplatform | Library | Library | 100 | `library` | Testing System: None / XCTest / Swift Testing (default None) |
| Multiplatform | Other | Empty | 100 | `empty` | none |
| Multiplatform | Other | Build Tool Plug-in | 200 | `build-tool-plugin` | none |
| Multiplatform | Other | Command Plug-in | 300 | `command-plugin` | Testing System: None / XCTest / Swift Testing (default None) |
| Multiplatform | Other | Swift Macro | 400 | `macro` | Testing System: None / XCTest (default XCTest) |
| macOS | Executable | Command-Line Tool | 100 | `tool` (ArgumentParser) | none |
| macOS | Executable | Executable | 200 | `executable` | none |

Default save names: MyLibrary, MyPackage, MyBuildToolPlugin,
MyCommandPlugin, MyMacro, MyTool and MyExecutable. The package content
is what `swift package init --type <type>` writes, with the testing
flags that match the Testing System choice. That makes the content
SwiftPM's (open source), not the template's. The template data names
the type as `command-line-tool` and `swift-macro`. SwiftPM's names are
`tool` and `macro`.

### Compact picker rows

The rows' internal values are `app`, `commandLineTool`, `package`,
`playground` and `template`, in that order. The last chosen row is
remembered. What each row does:

- **App:** the canned untitled multiplatform project
  (`reference-ui-6.md` §1.5). No sheet.
- **Command Line Tool:** the macOS Command Line Tool options step.
- **Package…:** the package chooser.
- **Playground:** OPEN (not observed).
- **Choose Template…:** a new empty workspace window with the template
  sheet.

### Filter

The sheet has a filter field. Its matching rule was not observed
(OPEN). Ycode's reading is a case- and diacritic-insensitive substring
match on the template name within the current tab. Sections with no
match are hidden. While the filter has text and matches nothing, the
tab shows an empty state.

### Persistence

| What | Scope | Stored as |
|---|---|---|
| Selected tab | per chooser (project, package, file) | the tab's display name ("Multiplatform", "iOS"); the file chooser stores a platform identifier |
| Selected template | per chooser and per tab | "`<Section>/<Template>`", for example "Application/App" |
| Option values | all templates, by option identifier | a dictionary from identifier to value; options marked not-persisted (Product Name, Bundle Identifier, the Audio Unit codes, …) are not stored |
| Save folder | global | the last folder chosen in the save step |
| Compact picker row | global | the row's internal value |

On open, the sheet selects the stored tab and that tab's stored
template. With nothing stored it selects the first template of the
first section. Switching tabs selects that tab's stored template. Each
option starts at its stored value when the value is still allowed
(§ "Options step"), else at its default. That is why the options step
showed "Swift Testing with XCTest UI Tests" as the default: the
template's own default is None.

## Template catalog

### Notation

- `N`: Product Name.
- `O`: Organization Identifier.
- `B`: bundle identifier = `O'` + "." + `rfc1034(N)`. Here `O'` is `O`
  with the characters that a bundle identifier forbids removed, and
  `rfc1034` replaces every character other than A–Z, a–z, 0–9, "-"
  and "." with "-". This is Ycode's
  `ProjectOptions.bundleIdentifier`.
- `T`: the C-identifier form of `N` (characters other than letters,
  digits and "_" become "_"; a leading digit gets a "_" prefix). It is
  used in file names such as `TApp.swift`, `T.docc` and `T.h`. The
  existing iOS App row's "letters and digits only" rule is a
  simplification. Xcode turns "My App" into `My_AppApp.swift`.
- `V(p)`: the SDK version of platform `p` at creation time
  (major.minor; for example 26.2 with Xcode 26.2). It is written for
  the template value `latest_<p>`. The macOS value written for
  `MACOSX_DEPLOYMENT_TARGET` is the macOS SDK version too.
- A **component** is a sub-template instantiated with a name of its
  own. Inside it, `N` means the component's name. Each component gets
  its own top-level folder named after it, unless noted otherwise.

### Generated project, common to all templates

These are written in the current object style: `objectVersion = 77`,
`preferredProjectObjectVersion = 77`, objects as in
`specs/formats/pbxproj.md`. Template-created projects from Xcode 16 to
26.4 use 77. The quick App row writes 90. Which one 27.1 writes for
template projects is OPEN, and Ycode uses 77.

- `PBXProject` attributes: `BuildIndependentTargetsInParallel = 1`,
  `LastSwiftUpdateCheck` and `LastUpgradeCheck` (the IDE version as
  four digits, for example `2710`), and `TargetAttributes`. Each target
  gets `CreatedOnToolsVersion` (for example `27.1`). Test targets also
  get `TestTargetID` (the tested target's id). Further fields:
  `developmentRegion = en`, `knownRegions = (en, Base)`,
  `hasScannedForEncodings = 0`, `minimizedProjectReferenceProxies = 1`,
  `mainGroup`, `productRefGroup`, and empty `projectDirPath` and
  `projectRoot`. When an organization name is known it is written as
  the `ORGANIZATIONNAME` attribute.
- Debug and Release configurations at project and target level, each
  list with `defaultConfigurationIsVisible = 0` and
  `defaultConfigurationName = Release`.
- **Project-level settings in every template** (in both configurations
  unless marked):
  - `ALWAYS_SEARCH_USER_PATHS = NO`;
  - `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES`;
  - `CLANG_ANALYZER_NONNULL = YES`;
  - `CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE`;
  - `CLANG_CXX_LANGUAGE_STANDARD = "gnu++20"`;
  - `CLANG_ENABLE_MODULES = YES`;
  - `CLANG_ENABLE_OBJC_ARC = YES`;
  - `CLANG_ENABLE_OBJC_WEAK = YES`;
  - `CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING`, `_BOOL_CONVERSION`,
    `_COMMA`, `_CONSTANT_CONVERSION`, `_DEPRECATED_OBJC_IMPLEMENTATIONS`,
    `_DOCUMENTATION_COMMENTS`, `_EMPTY_BODY`, `_ENUM_CONVERSION`,
    `_INFINITE_RECURSION`, `_INT_CONVERSION`,
    `_NON_LITERAL_NULL_CONVERSION`, `_OBJC_IMPLICIT_RETAIN_SELF`,
    `_OBJC_LITERAL_CONVERSION`, `_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER`,
    `_RANGE_LOOP_ANALYSIS`, `_STRICT_PROTOTYPES`, `_SUSPICIOUS_MOVE`,
    `_UNREACHABLE_CODE` and `__DUPLICATE_METHOD_MATCH`, all `= YES`;
  - `CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR`;
  - `CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR`;
  - `CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE`;
  - `COPY_PHASE_STRIP = NO`;
  - `ENABLE_STRICT_OBJC_MSGSEND = YES`;
  - `ENABLE_USER_SCRIPT_SANDBOXING = YES`;
  - `GCC_C_LANGUAGE_STANDARD = gnu17`;
  - `GCC_NO_COMMON_BLOCKS = YES`;
  - `GCC_WARN_64_TO_32_BIT_CONVERSION = YES`;
  - `GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR`;
  - `GCC_WARN_UNDECLARED_SELECTOR = YES`;
  - `GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE`;
  - `GCC_WARN_UNUSED_FUNCTION = YES`;
  - `GCC_WARN_UNUSED_VARIABLE = YES`;
  - `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`;
  - `MTL_FAST_MATH = YES`;
  - Debug only: `DEBUG_INFORMATION_FORMAT = dwarf`,
    `ENABLE_TESTABILITY = YES`, `GCC_DYNAMIC_NO_PIC = NO`,
    `GCC_OPTIMIZATION_LEVEL = 0`,
    `GCC_PREPROCESSOR_DEFINITIONS = ("DEBUG=1", "$(inherited)")`,
    `MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE`, `ONLY_ACTIVE_ARCH = YES`;
  - Release only: `DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"`,
    `ENABLE_NS_ASSERTIONS = NO`, `MTL_ENABLE_DEBUG_INFO = NO`;
  - when Language is Swift (or the template has no Language option):
    `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"` and
    `SWIFT_OPTIMIZATION_LEVEL = "-Onone"` (Debug only),
    `SWIFT_COMPILATION_MODE = wholemodule` (Release only).
  - The platform's SDK and deployment target (table below). Release
    adds `VALIDATE_PRODUCT = YES` for iOS, tvOS, watchOS and visionOS.
- **Platform rows** (project level). Multiplatform templates set them
  per target instead.

  | Platform | `SDKROOT` | Deployment setting |
  |---|---|---|
  | iOS | `iphoneos` | `IPHONEOS_DEPLOYMENT_TARGET = V(iOS)` |
  | macOS | `macosx` | `MACOSX_DEPLOYMENT_TARGET = V(macOS)` |
  | tvOS | `appletvos` | `TVOS_DEPLOYMENT_TARGET = V(tvOS)` |
  | watchOS | `watchos` | `WATCHOS_DEPLOYMENT_TARGET = V(watchOS)` |
  | visionOS | `xros` | `XROS_DEPLOYMENT_TARGET = V(visionOS)` |
  | DriverKit | `driverkit` | `DRIVERKIT_DEPLOYMENT_TARGET = V(DriverKit)`; also `CLANG_CXX_LANGUAGE_STANDARD = "gnu++20"` |

- **Multi-SDK projects** (watchOS App with a companion, Safari
  Extension App, the per-platform Game targets): when the targets need
  different SDKs, the project-level configurations carry no `SDKROOT`
  and no deployment target. Each target carries its own platform row
  in both configurations, plus `VALIDATE_PRODUCT = YES` in Release
  where the table above says so.
- **Every target** also gets `CODE_SIGN_STYLE = Automatic`. When a team
  is chosen it also gets `DEVELOPMENT_TEAM = <team id>`. Neither comes
  from a template.
- **Folders.** Every target's top-level folder is a
  `PBXFileSystemSynchronizedRootGroup` (`path` = the folder name,
  `sourceTree = "<group>"`). It is listed in that target's
  `fileSystemSynchronizedGroups`. The main group lists the folders in
  creation order, then `Products`. Build phases are written but stay
  empty: the synchronized folders supply their members. A folder whose
  files belong to several targets (a "Shared" component) is listed in
  each of those targets. A template file that belongs to no target
  (`Info.plist`) but sits in a synchronized folder gets a
  `PBXFileSystemSynchronizedBuildFileExceptionSet`
  (`membershipExceptions = (Info.plist)`, `target` = that folder's
  target). Its comment is `Exceptions for "<folder>" folder in
  "<target>" target`, and the root group lists it in `exceptions`.
  Entitlements files need no exception. Subfolders in the tables
  (`Resources/`, `Base.lproj/`, `Common/…`) are plain directories
  inside the synchronized folder.
- **Products:** one `PBXFileReference` per target product
  (`explicitFileType`, `includeInIndex = 0`,
  `sourceTree = BUILT_PRODUCTS_DIR`) in the `Products` group.
- **Schemes:** none are written. They are created automatically on
  first open (`schemes.md`). Only
  `xcuserdata/<user>.xcuserdatad/xcschemes/xcschememanagement.plist`
  and `project.xcworkspace/contents.xcworkspacedata` (one `self:`
  FileRef) appear next to `project.pbxproj`.
- **Opening:** after creation the editor opens the template's initial
  file, given in the tables. With none given, the project editor opens
  (Ycode's reading).

### Common target blocks

These blocks recur in the tables below.

**Swift settings** (every target whose language is Swift):
`SWIFT_VERSION = 5.0` (6.0 where noted),
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`,
`SWIFT_APPROACHABLE_CONCURRENCY = YES`. App and app-extension targets
also get `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. With Objective-C
(or C, C++), all four are absent.

**App target (any platform):**
- `PRODUCT_NAME = $(TARGET_NAME)`;
- `PRODUCT_BUNDLE_IDENTIFIER = B`;
- `GENERATE_INFOPLIST_FILE = YES`;
- `MARKETING_VERSION = 1.0`;
- `CURRENT_PROJECT_VERSION = 1`;
- `SWIFT_EMIT_LOC_STRINGS = YES`;
- `STRING_CATALOG_GENERATE_SYMBOLS = YES`;
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`;
- `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor`;
- `ENABLE_PREVIEWS = YES` when the interface is SwiftUI;
- the Swift settings;
- phases Sources, Frameworks, Resources;
- `productType = com.apple.product-type.application`.

**iOS app additions:**
- `TARGETED_DEVICE_FAMILY = "1,2"`;
- `LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks")`;
- `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES`;
- `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone =
  "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft
  UIInterfaceOrientationLandscapeRight"`;
- `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` = the same
  three orientations plus `UIInterfaceOrientationPortraitUpsideDown`;
- with the SwiftUI lifecycle:
  `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES` and
  `INFOPLIST_KEY_UILaunchScreen_Generation = YES`.

**macOS app additions:**
- `ENABLE_APP_SANDBOX = YES`;
- `ENABLE_USER_SELECTED_FILES = readonly` (`readwrite` in Document
  App);
- `REGISTER_APP_GROUPS = YES`;
- `INFOPLIST_KEY_NSHumanReadableCopyright` = a copyright line (Ycode's
  own wording, with the year and the organization name);
- `LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/../Frameworks")`;
- with the Cocoa lifecycle: `INFOPLIST_KEY_NSPrincipalClass =
  NSApplication` and `INFOPLIST_KEY_NSViewGestureRecognizerIsExclusive = NO`.

**Asset catalog** `Assets.xcassets`: `Contents.json`, an
`AccentColor.colorset` with no color, and an `AppIcon` set. The icon's
slot structure depends on the platform:
- iOS and macOS: an `appiconset`. iOS has one universal 1024 slot. For
  macOS, Ycode uses the macOS sizes of `asset-catalog.md`.
- visionOS and tvOS: a `solidimagestack`
  (`AppIcon.solidimagestack`).
- tvOS adds a `brandassets` group "App Icon & Top Shelf Image".
- watchOS: an `appiconset` with one watchOS 1024 slot.

A multiplatform catalog holds the slot sets of every platform the
target includes.

**Test components** (when Testing System is not None):

| Target | `productType` | Folder | Settings beyond the Swift settings |
|---|---|---|---|
| `NTests` | `com.apple.product-type.bundle.unit-test` | `NTests/NTests.swift` (`T`-form file name) | `PRODUCT_NAME = $(TARGET_NAME)`, `PRODUCT_BUNDLE_IDENTIFIER = O'.rfc1034(N)Tests`, `GENERATE_INFOPLIST_FILE = YES`, `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`, `SWIFT_EMIT_LOC_STRINGS = NO`, `STRING_CATALOG_GENERATE_SYMBOLS = NO`, the app's `TARGETED_DEVICE_FAMILY` / `SUPPORTED_PLATFORMS` / `SDKROOT` when it has them, the app's deployment target copied (app-hosted tests only), `TEST_HOST = $(BUILT_PRODUCTS_DIR)/N.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/N` and `BUNDLE_LOADER = $(TEST_HOST)` (app-hosted tests only; framework tests have no host) |
| `NUITests` | `com.apple.product-type.bundle.ui-testing` | `NUITests/NUITests.swift` | the same, without the copied deployment target and the host settings, plus `TEST_TARGET_NAME = N` |

- Both test targets depend on the tested target through
  `PBXTargetDependency` and `PBXContainerItemProxy`
  (`proxyType = 1`), and both carry the `TestTargetID` attribute.
- Testing System = XCTest gives an XCTest unit-test file. Swift Testing
  gives a Swift Testing unit-test file, and is offered only when
  Language is Swift. In both cases the UI-test file uses XCTest.
- 27.1 writes one UI-test file. Xcode 26.0 also wrote a second one
  (`NUITestsLaunchTests.swift`).
- Templates whose Testing System has no "…for Unit and UI Tests"
  titles add the unit-test target only: frameworks, libraries, all
  visionOS templates. visionOS has no UI testing.

**Storage** (apps with a Storage option):
- SwiftData adds `Item.swift`, a model with one timestamp, and the
  views use it.
- Core Data adds `Persistence.swift` and `T.xcdatamodeld` (one entity,
  `Item`, with a `timestamp` attribute).
- Host in CloudKit (enabled only when Storage is not None) adds:
  - `T.entitlements` in no target, with
    `CODE_SIGN_ENTITLEMENTS = N/T.entitlements`;
  - `Info.plist` in no target, with `INFOPLIST_FILE = N/Info.plist`,
    holding `UIBackgroundModes = (remote-notification)`;
  - the CloudKit store variant of the storage code.
- The entitlements keys are:
  - iOS and tvOS: `aps-environment = development`;
  - macOS: `com.apple.developer.aps-environment = development`;
  - Multiplatform: both of the above;
  - every platform: `com.apple.developer.icloud-container-identifiers
    = ()` and `com.apple.developer.icloud-services = (CloudKit)`.
- The macOS app gets no Info.plist.

**Framework (any platform):**
- `productType = com.apple.product-type.framework`;
- phases Headers, Sources, Frameworks, Resources;
- `PRODUCT_NAME = $(TARGET_NAME:c99extidentifier)`;
- `PRODUCT_BUNDLE_IDENTIFIER = B`;
- `GENERATE_INFOPLIST_FILE = YES`;
- `INSTALL_PATH = $(LOCAL_LIBRARY_DIR)/Frameworks`;
- `SKIP_INSTALL = YES`;
- `DYLIB_COMPATIBILITY_VERSION = 1`;
- `DYLIB_CURRENT_VERSION = 1`;
- `DYLIB_INSTALL_NAME_BASE = @rpath`;
- `ENABLE_MODULE_VERIFIER = YES`;
- `MODULE_VERIFIER_SUPPORTED_LANGUAGES = "objective-c objective-c++"`;
- `MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS = "gnu17 gnu++20"`;
- `INFOPLIST_KEY_NSHumanReadableCopyright` (copyright line);
- `LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks",
  "@loader_path/Frameworks")` (macOS: `../Frameworks`);
- with Swift: `BUILD_LIBRARY_FOR_DISTRIBUTION = YES`,
  `SWIFT_INSTALL_MODULE = YES`, `SWIFT_INSTALL_OBJC_HEADER = NO`;
- with Objective-C: `DEFINES_MODULE = YES`;
- project-level: `VERSIONING_SYSTEM = apple-generic`,
  `CURRENT_PROJECT_VERSION = 1`, `VERSION_INFO_PREFIX = ""`;
- files: `<T>.swift` (Swift) or the umbrella header `<T>.h`
  (Objective-C), and `T.docc` when Include Documentation is on (the
  default);
- platform family: iOS `1,2`, tvOS `3`, watchOS `4`, visionOS `7` plus
  `SUPPORTED_PLATFORMS = "xros xrsimulator"`;
- the Multiplatform Framework uses `SDKROOT = auto`,
  `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros xrsimulator"`,
  `TARGETED_DEVICE_FAMILY = "1,2,7"` and
  `ALLOW_TARGET_PLATFORM_SPECIALIZATION = YES`, with the iOS, macOS
  and visionOS deployment targets set on the target.

**Static library (iOS, tvOS, watchOS, visionOS):**
- `productType = com.apple.product-type.library.static`;
- phases Sources, Frameworks, and a Copy Files phase
  (`dstSubfolderSpec = 16`, `dstPath = "include/$(PRODUCT_NAME)"`);
- `PRODUCT_NAME = $(TARGET_NAME)`, `OTHER_LDFLAGS = -ObjC`,
  `SKIP_INSTALL = YES`, and the platform's family;
- files: `T.swift` (Swift) or `T.h` + `T.m` (Objective-C).

**Metal Library (iOS, macOS, tvOS):**
- `productType = com.apple.product-type.metal-library`;
- one Sources phase and `PRODUCT_NAME = $(TARGET_NAME)`;
- one file, `T.metal`;
- project-level `MTL_FAST_MATH = YES`, plus
  `MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE` in Debug and `NO` in
  Release;
- the only option is Product Name.

**Embedding.** A component that the tables mark *embedded* gets a
`PBXTargetDependency` from its host and a Copy Files phase in the
host. The phase names follow the reference's naming:

| Embedded product | Phase name | `dstSubfolderSpec` | `dstPath` |
|---|---|---|---|
| app extension (`.appex`) | Embed Foundation Extensions | 13 | "" |
| watch app in an iOS app | Embed Watch Content | 16 | `$(CONTENTS_FOLDER_PATH)/Watch` |
| framework | Embed Frameworks | 10 | "" |
| XPC service | Embed XPC Services | 16 | `$(CONTENTS_FOLDER_PATH)/XPCServices` |
| driver extension | Embed System Extensions | 16 | `$(SYSTEM_EXTENSIONS_FOLDER_PATH)` |

Build files in an embed phase carry
`settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }`. Frameworks also
carry `CodeSignOnCopy`. In a new project the "Embed in Application"
choice of Framework, XPC Service and Driver is "None", so those three
templates embed nothing.

### Catalog by template

Option lists name the option identifiers. Their labels, values and
rules are in § "Options step". Every template has `productName`
first. Every template except Empty and Metal Library also has
`bundleIdentifierPrefix` and the derived `bundleIdentifier`. Neither
is repeated below. A file list gives paths inside the target's folder
`N/` (`<component>/` for components).

#### Multiplatform

| Template | Options (after name and identifiers) | Targets and files |
|---|---|---|
| App | testingSystem, storageType, hostInCloudKit | One app target `N`, SwiftUI: `SDKROOT = auto`, `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros xrsimulator"`, `TARGETED_DEVICE_FAMILY = "1,2,7"`, `IPHONEOS_`/`MACOSX_`/`XROS_DEPLOYMENT_TARGET` = their `V`, the macOS app additions (sandbox, readonly files, app groups), and the iOS-only keys as `[sdk=iphoneos*]` and `[sdk=iphonesimulator*]` variants: `INFOPLIST_KEY_UIApplicationSceneManifest_Generation`, `…UIApplicationSupportsIndirectInputEvents`, `…UILaunchScreen_Generation` = `YES`, and `INFOPLIST_KEY_UIStatusBarStyle = UIStatusBarStyleDefault`. Plain orientation keys; `LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks` and `[sdk=macosx*] = @executable_path/../Frameworks`. The project has no `SDKROOT`. Files `TApp.swift`, `ContentView.swift`, `Assets.xcassets` (iOS + macOS icon slots). Initial file `ContentView.swift`. Tests and storage as in the common blocks; the test targets repeat the platform settings |
| Document App | testingSystem, storageTypeDocument (None, SwiftData) | As App with `SWIFT_VERSION = 6.0`, `ENABLE_USER_SELECTED_FILES = readwrite`, `INFOPLIST_KEY_UISupportsDocumentBrowser[sdk=iphoneos*]` / `[sdk=iphonesimulator*] = YES` and `INFOPLIST_FILE = N/Info.plist`. Info.plist (in no target) declares one document type (`CFBundleDocumentTypes`: role Editor, `LSItemContentTypes` = one placeholder UTI, `NSUbiquitousDocumentUserActivityType = $(PRODUCT_BUNDLE_IDENTIFIER).<suffix>`) and imports that UTI (`UTImportedTypeDeclarations`: conforms to `public.plain-text`, one filename extension). Files `TApp.swift` (a `DocumentGroup`), `TDocument.swift` (a `FileDocument` holding text), `ContentView.swift`, `Assets.xcassets`. SwiftData: `SWIFT_VERSION = 5.0`, `Item.swift` instead of `TDocument.swift`, and the UTI conforms to `com.apple.package` with `LSHandlerRank = Default`. Ycode chooses its own placeholder UTI and extension |
| Foveated Streaming App | iOSPlatform, visionOSPlatform (checkboxes, both on) | Components: "`N` Shared" (folder only: one logging file in both apps), "`N` iOS" (app target `N iOS`: `SUPPORTED_PLATFORMS = iphoneos`, family `1,2`, `INFOPLIST_FILE`, `INFOPLIST_KEY_NSCameraUsageDescription`, entitlements with `keychain-access-groups`), "`N` visionOS" (app target `N visionOS`: `SUPPORTED_PLATFORMS = xros`, family `7`, entitlements `com.apple.developer.foveated-streaming-session = true`; files for an app model, a data-channel view, an immersive view and a receiver model, plus `Resources/` with USD scenes and materials) and "Packages" (a local package `Packages/StreamingSessionDependencies` whose products `StreamingSession` and `CloudXRKit` the iOS app links). Unchecking a platform drops its component and its resources. Device-only platforms: no simulators |
| Game | gameType (RealityKit, SceneKit, SpriteKit, Metal 4, Metal; default RealityKit), languageChoice, iOSPlatform, visionOSPlatform, tvOSPlatform (enabled only with iOS on), OSXPlatform | **RealityKit:** one app target `N` with `SDKROOT = auto`, `SUPPORTED_PLATFORMS` = iOS, macOS, tvOS and visionOS devices and simulators, family `1,2,3,7`, all four deployment targets, `INFOPLIST_KEY_NSCameraUsageDescription`; files `TApp.swift`, `ContentView.swift`, a spin component and `Assets.xcassets` (icon sets for the checked platforms). How the checkboxes narrow the one target is OPEN. **SceneKit, SpriteKit, Metal 4, Metal:** a "`N` Shared" folder (members of every platform target) with the game's scene or renderer files and `Assets.xcassets`, plus one app target per checked platform among iOS (`N iOS`: storyboard, Info.plist, a game view controller), tvOS (`N tvOS`: also app and scene delegates) and macOS (`N macOS`: app delegate and game view controller). Each has its own `SDKROOT` and deployment target (a multi-SDK project). visionOS is not offered for these. Objective-C is allowed for SceneKit, SpriteKit and Metal |
| Audio Unit Extension App | ORGANIZATIONNAME (text, required), audioUnitType (Instrument, Generator, Effect, Music Effect, MIDI Processor, Speech Synthesizer; default MIDI Processor), audioUnitSubtypeCode and audioUnitManufacturerCode (4-character text, required), hasUserInterface ("Presents User Interface" / "No User Interface"), testingSystem, storageType, hostInCloudKit | Multiplatform host app `N` (as App, plus `CODE_SIGN_ENTITLEMENTS` with `inter-app-audio = true`, `ENABLE_HARDENED_RUNTIME = YES`, `INFOPLIST_KEY_CFBundleDisplayName = T`, `OTHER_LDFLAGS = -framework AudioToolbox -framework AVFoundation`). Its files are a validation view, a host model, a view model and `Common/` with audio, MIDI and UI helpers plus a sample sound. An *embedded* app extension `NExtension` (`com.apple.product-type.app-extension`, multiplatform like the app, `SKIP_INSTALL = YES`, `INFOPLIST_FILE` whose Info.plist holds `NSExtension` (`NSExtensionAttributes` ▸ `AudioComponents` with description, factory function, manufacturer, name, sandbox-safe, subtype, tags, type and version; extension point and principal class) and `XPCService`; type code, subtype code, manufacturer code and tags follow the options) holds the audio unit, a DSP kernel header, parameters, `UI/` views and a bridging header. The type changes the DSP files (oscillator for Instrument and Generator, buffered bus for Effect and Music Effect, none for Speech Synthesizer). No User Interface drops `UI/` and adds a factory file |
| Safari Extension App | languageChoice (Swift, Objective-C) | Components: "Shared (App)" (asset catalog, an HTML page with style, script and icon, a view controller; members of both apps), "Shared (Extension)" (the web-extension handler and `Resources/` with `manifest.json`, `_locales`, `images`, background/content/popup scripts and pages; members of both extensions), "iOS (App)" (app target `N (iOS)`: SDK iphoneos, `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, storyboard UIKit app, `INFOPLIST_KEY_CFBundleDisplayName = N`, `OTHER_LDFLAGS = -framework SafariServices -framework WebKit`), "macOS (App)" (app target `N (macOS)`: SDK macosx, `MACOSX_DEPLOYMENT_TARGET = 12.0`, sandbox, hardened runtime, outgoing network, `NSMainStoryboardFile = Main`), "iOS (Extension)" and "macOS (Extension)" (app extensions `N Extension (iOS)`, deployment 15.0, and `N Extension (macOS)`, deployment 12.0, each *embedded* in its app; `PRODUCT_NAME = "N Extension"`, `PRODUCT_BUNDLE_IDENTIFIER = B.Extension`, `OTHER_LDFLAGS = -framework SafariServices`). App identifiers: `B` for both apps. Initial file `manifest.json` |
| Framework | testingSystem (None, XCTest, Swift Testing; unit tests only), hasDocumentation | Framework block, multiplatform row. Language is fixed to Swift |

#### iOS

| Template | Options | Targets and files |
|---|---|---|
| App | userInterface (SwiftUI, Storyboard), languageChoice (Objective-C only with Storyboard), testingSystem, storageType, hostInCloudKit | As the existing "iOS App" rows above, with the settings corrected by the common blocks. The app adds no `SUPPORTED_PLATFORMS` |
| Document App | userInterface (SwiftUI; Storyboard titled "UIKit"), languageChoice, testingSystem, storageTypeDocument (None, SwiftData) | SwiftUI: `SWIFT_VERSION = 6.0`, `INFOPLIST_KEY_UISupportsDocumentBrowser = YES`, `INFOPLIST_FILE = N/Info.plist` (document type and imported UTI as Multiplatform), files `TApp.swift`, `TDocument.swift`, `ContentView.swift`, `Assets.xcassets`. UIKit: an app delegate, a scene delegate, a document-browser view controller, a document view controller, a `UIDocument` subclass and `Base.lproj/LaunchScreen.storyboard`, with `INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen` and the scene manifest in Info.plist (`UIApplicationSupportsMultipleScenes = false`, one configuration named "Default Configuration" with the scene delegate); the document type adds `UIDocumentClass`. SwiftData: `SWIFT_VERSION = 5.0`, `Item.swift` |
| Game | gameType (SceneKit, SpriteKit, Metal 4, Metal; default SpriteKit), integrateGK (enabled only for SpriteKit), languageChoice, testingSystem | UIKit lifecycle (app delegate, scene delegate, `Base.lproj/Main.storyboard`, `Base.lproj/LaunchScreen.storyboard`, Info.plist with the scene manifest), `INFOPLIST_KEY_UIMainStoryboardFile = Main`, `INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen`, `INFOPLIST_KEY_UIStatusBarHidden = YES`, `INFOPLIST_FILE`, and a game view controller. SpriteKit: a scene file, an actions file and the scene class. SceneKit: `art.scnassets`. Metal and Metal 4: renderer, shaders, shared types header, `SWIFT_OBJC_BRIDGING_HEADER = $(TARGET_NAME)/ShaderTypes.h`, `INFOPLIST_KEY_UIRequiredDeviceCapabilities = metal`. Integrate GameplayKit changes only file content |
| Augmented Reality App | contentType (RealityKit, SceneKit, SpriteKit, Metal; default RealityKit), userInterface (RealityKit needs SwiftUI; the others need Storyboard), languageChoice, testingSystem | Always the UIKit lifecycle (app delegate, scene delegate, LaunchScreen storyboard, Info.plist). Settings: `INFOPLIST_KEY_NSCameraUsageDescription`, `INFOPLIST_KEY_UIRequiredDeviceCapabilities = arkit` (`arkit metal` for Metal), `INFOPLIST_KEY_UIStatusBarHidden = YES`, `INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen`, `INFOPLIST_FILE`. RealityKit adds `ContentView.swift`. SceneKit, SpriteKit and Metal add `Base.lproj/Main.storyboard`, a view controller and their content (`art.scnassets`; a scene and its class; renderer, shaders and a bridging header, landscape-right only). Initial file `ContentView.swift` |
| App Playground | productName ("App Name:"), bundleIdentifierPrefix, bundleIdentifier | Not an Xcode project. A package folder `N.swiftpm` holding `Package.swift` (an iOS application product), the app entry file, `ContentView.swift` and `.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata`. Default name "My App". Initial file `ContentView.swift`. The manifest's format is Swift Playgrounds' public app-package form |
| Sticker Pack App | none | No top-level app folder. Target `N` (`com.apple.product-type.application.messages`, a Resources phase only, `INFOPLIST_KEY_NSStickerSharingLevel = OS`) with an *embedded* extension `N StickerPackExtension` (`com.apple.product-type.app-extension.messages-sticker-pack`, Resources only, `SKIP_INSTALL = YES`) whose folder holds `Stickers.xcstickers` |
| iMessage App | languageChoice | Target `N` (`com.apple.product-type.application.messages`, Resources only, `INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen`, its own `Assets.xcassets`), with an *embedded* extension `N MessagesExtension` (`com.apple.product-type.app-extension.messages`, links `Messages.framework`, `INFOPLIST_FILE`, `SKIP_INSTALL = YES`). The extension's files are `Base.lproj/MainInterface.storyboard`, `Assets.xcassets` and a messages view controller |
| Safari Extension App | languageChoice, testingSystem | Storyboard UIKit app `N` (`IPHONEOS_DEPLOYMENT_TARGET = 17.0` on the target, `INFOPLIST_KEY_CFBundleDisplayName = N`, `OTHER_LDFLAGS = -framework SafariServices -framework WebKit`, a web page with style and icon, a view controller) with an *embedded* extension `N Extension` (`com.apple.product-type.app-extension`, deployment 15.0, `OTHER_LDFLAGS = -framework SafariServices`, web-extension handler and resources as Multiplatform) |
| Framework | languageChoice, testingSystem, hasDocumentation | Framework block |
| Static Library | languageChoice | Static library block |
| Metal Library | none | Metal Library block |

#### macOS

| Template | Options | Targets and files |
|---|---|---|
| App | userInterface (SwiftUI, Storyboard, XIB), languageChoice (Objective-C only with Storyboard or XIB), testingSystem, storageType, hostInCloudKit | App + macOS blocks. SwiftUI: `TApp.swift`, `ContentView.swift`. Storyboard: app delegate, view controller, `Base.lproj/Main.storyboard`, `INFOPLIST_KEY_NSMainStoryboardFile = Main`. XIB: app delegate and `Base.lproj/MainMenu.xib`, `INFOPLIST_KEY_NSMainNibFile = MainMenu`. Objective-C adds `main.m` and `.h` / `.m` pairs. The macOS test targets copy `MACOSX_DEPLOYMENT_TARGET` |
| Document App | userInterface, languageChoice, testingSystem, storageTypeDocument (None, SwiftData, Core Data; Core Data only with Storyboard or XIB) | SwiftUI as Multiplatform Document App (Swift 6.0, `INFOPLIST_FILE`, document type and UTI). Storyboard: an `NSDocument` subclass and `Main.storyboard`. XIB: `Document.xib` and `MainMenu.xib`. Core Data: an `NSPersistentDocument` subclass and `Document.xcdatamodeld` |
| Game | gameType (RealityKit, SceneKit, SpriteKit, Metal 4, Metal; default SpriteKit; RealityKit only with Swift), integrateGK, languageChoice, testingSystem | Target-level `MACOSX_DEPLOYMENT_TARGET = V(macOS)`, `INFOPLIST_KEY_NSMainStoryboardFile = Main`, app delegate, `Main.storyboard`, a view controller and the technology's files (as iOS Game). RealityKit uses the SwiftUI app files instead, without a storyboard |
| Spatial Rendering App | secondarySceneType ("Immersive Space Renderer:", Metal or Metal 4), immersiveSpaceStyle (Full, Progressive), testingSystem | A macOS SwiftUI app that renders an immersive space on a paired Apple Vision Pro: `MACOSX_DEPLOYMENT_TARGET = V(macOS)` on the target, `SWIFT_OBJC_BRIDGING_HEADER = $(TARGET_NAME)/ShaderTypes.h`; files `TApp.swift`, `ContentView.swift`, `Assets.xcassets` (with a visionOS image stack), an app model, an immersive-space toggle button, a renderer, shaders and a shared types header |
| Command Line Tool | languageChoice (Swift, Objective-C, C++, C) | `com.apple.product-type.tool`. Phases Sources, Frameworks, and Copy Files (`dstPath = /usr/share/man/man1/`, `dstSubfolderSpec = 0`, `runOnlyForDeploymentPostprocessing = 1`). One file: `main.swift`, `main.m`, `main.cpp` or `main.c`. No bundle identifier setting, no Info.plist |
| Safari Extension App | safariExtensionType ("Type:", Safari App Extension or Safari Web Extension; default Web), languageChoice, testingSystem | Storyboard app `N` (macOS block, hardened runtime, `INFOPLIST_KEY_CFBundleDisplayName`, `OTHER_LDFLAGS = -framework SafariServices -framework WebKit`, a web page, a view controller) with an *embedded* extension `N Extension` (`MACOSX_DEPLOYMENT_TARGET = 12.0`, sandbox, hardened runtime). Web: handler plus web resources as Multiplatform. App Extension: handler, a XIB view controller, a script and a toolbar icon |
| Framework | languageChoice, testingSystem, hasDocumentation | Framework block (macOS) |
| Library | libraryFramework ("Framework:", Cocoa, "STL (C++ Library)", "None (Plain C/C++ Library)"), libraryType ("Type:", Dynamic, Static) | Dynamic: `com.apple.product-type.library.dynamic`, `EXECUTABLE_PREFIX = lib`, `DYLIB_COMPATIBILITY_VERSION = 1`, `DYLIB_CURRENT_VERSION = 1`. Static: `com.apple.product-type.library.static`, without the dylib versions. Phases Headers, Sources, Frameworks; `SKIP_INSTALL = YES`. Cocoa: `T.h` + `T.m`. STL: `T.hpp`, `TPriv.hpp`, `T.cpp` with `GCC_ENABLE_CPP_EXCEPTIONS = YES`, `GCC_ENABLE_CPP_RTTI = YES`, `GCC_SYMBOLS_PRIVATE_EXTERN = YES`. Plain: no files |
| XPC Service | languageChoice, apiLevel ("API Level", "Low Level - libXPC" or "High Level - NSXPCConnection"; default High) | `com.apple.product-type.xpc-service`, `INFOPLIST_FILE` (an `XPCService` dictionary with `ServiceType`), sandbox, `SKIP_INSTALL = YES`. High level: a service class, a protocol and `main.swift` (or the `.h`/`.m` set). Low level: a types file and `main.swift`. Embedded in nothing in a new project |
| Bundle | bundleExtension ("Bundle Extension:", text, default "bundle") | `com.apple.product-type.bundle`, `WRAPPER_EXTENSION` = the option, `INSTALL_PATH = $(LOCAL_LIBRARY_DIR)/Bundles`, `INFOPLIST_KEY_NSPrincipalClass = ""`, `SKIP_INSTALL = YES`. No files |
| Metal Library | none | Metal Library block |
| Generic Kernel Extension | none | `com.apple.product-type.kernel-extension`, `WRAPPER_EXTENSION = kext`, target-level `MACOSX_DEPLOYMENT_TARGET`, Info.plist, `T.c` |
| IOKit Driver | none | As Generic Kernel Extension, with `T.hpp` and `T.cpp` (an IOService subclass) |
| Installer Plug-in | none | `com.apple.product-type.bundle`, `INSTALL_PATH = $(HOME)/Library/Bundles`, `INFOPLIST_KEY_NSMainNibFile = MyInstallerPane`, `INFOPLIST_KEY_NSPrincipalClass = InstallerSection`; Info.plist, a pane class (`.h` / `.m`), its XIB, strings files and an `InstallerSections.plist` |
| Instruments Package | none | `com.apple.product-type.instruments-package`, one Sources phase, `INSTALL_PATH = $(LOCAL_LIBRARY_DIR)/Instruments/Packages`; one file `N.instrpkg` |
| Preference Pane | none | `com.apple.product-type.bundle`, `WRAPPER_EXTENSION = prefPane`, `INSTALL_PATH = $(HOME)/Library/PreferencePanes`, `INFOPLIST_KEY_NSMainNibFile` and `INFOPLIST_KEY_NSPrincipalClass` = `T`; a pane class, a TIFF icon and a XIB |
| Screen Saver | none | `com.apple.product-type.bundle`, `WRAPPER_EXTENSION = saver`, `INSTALL_PATH = "$(HOME)/Library/Screen Savers"`, `INFOPLIST_KEY_NSPrincipalClass = TView`; a view class (`.h` / `.m`) |

#### watchOS

The App template's "Create Companion iOS App" option
(`companionAppStyle`) decides the layout:

| Choice | Targets and folders |
|---|---|
| Watch-only App (default) | Container `N` (`com.apple.product-type.application.watchapp2-container`, iOS SDK, a Resources phase only, `PRODUCT_BUNDLE_IDENTIFIER = B`, `INFOPLIST_KEY_CFBundleDisplayName = N`, no folder) with the *embedded* watch app `N Watch App` (folder of the same name) |
| Watch App with New Companion iOS App | A full iOS SwiftUI app `N` (the iOS App block, folder `N/` with `TApp.swift`, `ContentView.swift`, `Assets.xcassets`, `INFOPLIST_KEY_CFBundleDisplayName = N`) with the *embedded* watch app `N Watch App` |
| Watch App for Existing iOS App | Only `N Watch App`, embedded in the chosen existing iOS app. This needs an iOS app target, so it is a New Target case. In a new project it is unavailable (Ycode's reading; OPEN) |

The watch app `N Watch App` is
`com.apple.product-type.application` with SDK watchos:
- `TARGETED_DEVICE_FAMILY = 4`, `SKIP_INSTALL = YES`;
- `PRODUCT_BUNDLE_IDENTIFIER = B.watchkitapp`;
- `INFOPLIST_KEY_CFBundleDisplayName = N` (the parent's name);
- `INFOPLIST_KEY_UISupportedInterfaceOrientations =
  "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown"`;
- `LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks")`;
- the App target block (SwiftUI);
- files `TApp.swift` (named after the parent), `ContentView.swift`
  and `Assets.xcassets` (watch icon).

Watch-only sets `INFOPLIST_KEY_WKWatchOnly = YES`. With a companion,
the watch app sets `INFOPLIST_KEY_WKCompanionAppBundleIdentifier = B`
instead. The project is multi-SDK: each target has its own
`SDKROOT`, deployment target and Release `VALIDATE_PRODUCT`. Tests
(unit and UI) belong to the watch app (`N Watch AppTests`,
`N Watch AppUITests`) and copy `WATCHOS_DEPLOYMENT_TARGET`.

Language and the app lifecycle are fixed to Swift and SwiftUI. The
options are companionAppStyle and testingSystem. The initial file is
`ContentView.swift`.

| Template | Options | Targets and files |
|---|---|---|
| Framework | hasDocumentation, languageChoice, testingSystem | Framework block (family 4) |
| Static Library | languageChoice, testingSystem | Static library block (family 4) |

#### tvOS

| Template | Options | Targets and files |
|---|---|---|
| App | userInterface (SwiftUI, Storyboard), languageChoice, testingSystem, storageType, hostInCloudKit | App block with `TARGETED_DEVICE_FAMILY = 3`, `INFOPLIST_KEY_UIUserInterfaceStyle = Automatic`, `INFOPLIST_KEY_UILaunchScreen_Generation = YES`. SwiftUI files as iOS App. Storyboard adds a view controller, `Main.storyboard`, `LaunchScreen.storyboard`, an app delegate, a scene delegate and Info.plist. Host in CloudKit also sets `ENABLE_APP_SANDBOX = YES` and `ENABLE_USER_SELECTED_FILES = readonly` |
| Game | gameType (RealityKit, SceneKit, SpriteKit, Metal 4, Metal; default RealityKit; RealityKit only with Swift), integrateGK, languageChoice, testingSystem | RealityKit: SwiftUI app files with an app delegate and a spin component. The others: `Main.storyboard`, Info.plist, scene delegate, game view controller and the technology's files as iOS Game |
| Framework | languageChoice, testingSystem, hasDocumentation | Framework block (family 3) |
| Static Library | languageChoice | Static library block (family 3) |
| Metal Library | none | Metal Library block |

#### visionOS

| Template | Options | Targets and files |
|---|---|---|
| App | primarySceneType ("Initial Scene:", Window or Volume), secondarySceneType ("Immersive Space Renderer:", None, RealityKit, Metal, Metal 4; default None), immersiveSpaceStyle ("Immersive Space:", None, Mixed, Progressive, Full; default Full; enabled only when a renderer is chosen, and None only with no renderer), testingSystem (unit tests only) | App block with `TARGETED_DEVICE_FAMILY = 7`, `SUPPORTED_PLATFORMS = "xros xrsimulator"` (Metal 4: `xros` only), `INFOPLIST_FILE = $(TARGET_NAME)/Info.plist`. Info.plist (in no target) holds `UIApplicationSceneManifest`: `UIApplicationSupportsMultipleScenes = true`; `UIApplicationPreferredDefaultSceneSessionRole` = `UIWindowSceneSessionRoleApplication` (Window) or `UIWindowSceneSessionRoleVolumetricApplication` (Volume); `UISceneConfigurations` empty, or with a renderer `UISceneSessionRoleImmersiveSpaceApplication = ({UISceneInitialImmersionStyle = UIImmersionStyleMixed / …Progressive / …Full})`. Files: `TApp.swift`, `ContentView.swift`, `Assets.xcassets` (image stack), `Resources/` with a USD scene and materials. A renderer adds an app model, an immersive-space toggle button and `Resources/Immersive.usda`; RealityKit adds an immersive view; Metal and Metal 4 add a renderer, shaders, a shared types header and `SWIFT_OBJC_BRIDGING_HEADER = $(TARGET_NAME)/ShaderTypes.h` |
| Immersive Environment App | immersiveSpaceStyle (Progressive, Full; default Full), testingSystem | As App, with an immersive space from the start: an app model, a toggle button, a video player view and model, an immersive view, and `Resources/` with an environment scene, a sky dome and ground. Info.plist as App with the chosen immersion style |
| Framework | languageChoice, testingSystem, hasDocumentation | Framework block (family 7) |
| Static Library | languageChoice | Static library block (family 7) |

#### DriverKit

| Template | Options | Targets and files |
|---|---|---|
| Driver | none beyond the identifiers | `com.apple.product-type.driver-extension`, links `DriverKit.framework`, phases Headers, Sources, Frameworks, Resources, `PRODUCT_NAME = $(inherited)`, `SKIP_INSTALL = YES`, `INFOPLIST_FILE = N/Info.plist` (an `IOKitPersonalities` entry named `T` with the matching and user-server keys, and `OSBundleUsageDescription`); files `T.cpp`, `T.iig`, Info.plist |
| Framework | hasDocumentation | Framework block on the DriverKit SDK; an umbrella header `T.h` (no Swift) |
| Library | libraryType ("Type:", Dynamic, Static) | `com.apple.product-type.library.dynamic` (or `.static`), `EXECUTABLE_PREFIX = lib`, `SKIP_INSTALL = YES`; phases Headers, Sources, Frameworks; no files |

#### Other

| Template | Options | Result |
|---|---|---|
| Empty | productName only | A project with Debug and Release configurations, the project-level settings and no targets |
| External Build System | buildToolPath ("Build Tool:", text, default `/usr/bin/make`) | One `PBXLegacyTarget` `N`: `buildToolPath` = the option, `buildArgumentsString = "$(ACTION)"`, and (Ycode's reading of the format's usual defaults, not in the template) `passBuildSettingsInEnvironment = 1` with an empty `buildWorkingDirectory`; settings `PRODUCT_NAME = $(TARGET_NAME)`, `OTHER_CFLAGS = ""`, `OTHER_LDFLAGS = ""`, Debug `DEBUGGING_SYMBOLS = YES`, `GCC_GENERATE_DEBUGGING_SYMBOLS = YES`, `GCC_OPTIMIZATION_LEVEL = 0`, `DEBUG_INFORMATION_FORMAT = dwarf`, Release `DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"`. No folder |

### Differences from Ycode's iOS App row (to fix)

The rows in § "New Project" above predate this pass. They differ
from the reference as follows:

- `SWIFT_VERSION` is 5.0, not 6.0. Document Apps use 6.0.
- `IPHONEOS_DEPLOYMENT_TARGET` is `V(iOS)`, not 18.0.
- The app target adds `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`,
  `SWIFT_APPROACHABLE_CONCURRENCY`,
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
  `SWIFT_EMIT_LOC_STRINGS = YES`,
  `STRING_CATALOG_GENERATE_SYMBOLS = YES` and both orientation keys.
- The app target has no `SUPPORTED_PLATFORMS`.
- The project level carries the full warning set and the Swift
  configuration settings listed above.
- Test bundle identifiers are `O'.rfc1034(N)Tests` and `…UITests`.
  They equal `<app id>Tests` only when `N` is already RFC 1034-safe.
- The test targets carry `SWIFT_EMIT_LOC_STRINGS = NO` and
  `STRING_CATALOG_GENERATE_SYMBOLS = NO`. Only the unit-test target
  copies `IPHONEOS_DEPLOYMENT_TARGET`.
- Folders are synchronized root groups, one per target, with empty
  build phases. Info.plist (Storyboard or CloudKit) needs the
  membership exception.
- Host in CloudKit writes the entitlements and Info.plist listed under
  Storage. It is no longer ignored.
- Every target gets `CODE_SIGN_STYLE = Automatic`. With a team chosen,
  `DEVELOPMENT_TEAM` too.

## Options step

The sheet's title is "Choose options for your new project:"
(`reference-ui-3.md` §5.4). Its buttons are Cancel, Previous and Next.

### Field model

Each option of the template is one row: a label at the left and a
control at the right.

| Kind | Control | Value |
|---|---|---|
| `text` | a text field; the placeholder is shown when the field is empty (where given) | the string |
| `static` | grey text that cannot be edited (Bundle Identifier, the Testing System of UI-test bundles) | derived from other options |
| `popup` | a pop-up button; each item shows its value's title (the value itself when no title is given) | one of the values |
| `checkbox` | a checkbox whose title is the label (no label at the left) | `true` / `false` |
| `companionAppTargetChooser` | a pop-up of the three companion choices; with "…for Existing iOS App", a second pop-up of the project's iOS app targets (New Target) | one of the values |

Rules, applied whenever any value changes:

1. **Hidden options.** An option with no label, or with a forced value,
   is not shown. Examples are the app lifecycle, the Framework's
   Language (forced to Swift) and the watch app's language and
   lifecycle. Its value is the forced value. Without one, it is the
   first of its values that is allowed by rule 4.
2. **Order.** Options are shown by ascending sort key. An option
   without a key counts as 0. Ties keep the template's order, which
   puts the inherited options first. Product Name always comes first
   (key −2).
3. **Enabled.** An option with *requirements* is enabled only while
   every named option has one of the listed values. While disabled it
   keeps showing its value. Its effective value is then its first
   allowed value: `false` for a checkbox, "None" where None exists.
   Examples:
   - Host in CloudKit needs Storage ∈ {SwiftData, Core Data};
   - Integrate GameplayKit needs Game Technology = SpriteKit;
   - Include tvOS Application needs Include iOS Application;
   - visionOS Immersive Space needs a renderer;
   - Spatial Rendering's Immersive Space needs Metal or Metal 4.
4. **Allowed values.** A value with *per-value requirements* is
   available only while those requirements hold. Examples:
   - Objective-C needs the Cocoa lifecycle and a Storyboard or XIB
     interface;
   - Swift Testing needs Language = Swift;
   - SwiftData needs the SwiftUI lifecycle;
   - macOS Document Core Data needs the Cocoa lifecycle;
   - AR RealityKit needs SwiftUI and Swift; AR SceneKit, SpriteKit
     and Metal need Storyboard;
   - Game RealityKit needs Swift (macOS, tvOS);
   - Multiplatform Game Objective-C needs a non-RealityKit
     technology;
   - visionOS "None" immersion needs no renderer, and the other styles
     need one.

   An unavailable value is drawn disabled in the pop-up. The
   reference may hide it instead (OPEN). If the current value becomes
   unavailable, the option moves to its first available value.
   Because the lifecycle is hidden, choosing Interface = Storyboard
   switches the lifecycle to Cocoa, which in turn makes Objective-C
   available.
5. **Required.** Product Name, Organization Identifier and every
   option marked required (Build Tool, the Audio Unit's Organization
   Name and both codes, the Background Upload URL base) must be
   non-empty. Next stays disabled until they are. The Audio Unit codes
   must be exactly four characters, and the manufacturer code needs at
   least one upper-case letter. Their placeholders say so; Ycode
   checks this on Next.
6. **Empty replacement.** While Product Name is empty, the derived
   fields use "ProductName" in its place. While Organization
   Identifier is empty, they use "com.yourcompany". So Bundle
   Identifier reads `com.yourcompany.ProductName` with both empty, and
   `<org>.ProductName` with only the name empty (as observed).
7. **Initial values.** Each option starts at its persisted value
   (§ "Persistence") when that value is still allowed, else at its
   default. Product Name, Bundle Identifier and the not-persisted
   options always start at the default (empty for text). Organization
   Identifier is persisted.
8. **Team.** The IDE inserts a Team pop-up right after Product Name.
   It lists the signed-in teams and "None", and it is not a template
   option. The team chosen sets `DEVELOPMENT_TEAM`. Where a template
   puts Language before Organization Identifier (Multiplatform Safari
   Extension App, the frameworks and static libraries), Team is placed
   after Product Name too (Ycode's reading; OPEN).
9. **Bundle Identifier** = `B` (§ "Notation"), recomputed on every
   keystroke. The watch app's own identifier, `B.watchkitapp`, is not
   shown.
10. **Previous** returns to the template sheet and keeps the values.
    **Next** goes to the save step.

### Common options

| Identifier | Label | Kind | Values (titles) | Default | Requirements |
|---|---|---|---|---|---|
| `productName` | Product Name: (App Playground: App Name:) | text | — | empty | required; not persisted |
| `bundleIdentifierPrefix` | Organization Identifier: | text | — | persisted value | required |
| `bundleIdentifier` | Bundle Identifier: | static | `B` | — | not persisted |
| `userInterface` | Interface: | popup | SwiftUI, Storyboard (iOS Document App titles it "UIKit"), XIB (macOS only) | SwiftUI | — |
| `appLifecycle` | (hidden) | popup | SwiftUI, Cocoa | SwiftUI | SwiftUI needs Interface SwiftUI; Cocoa needs Storyboard or XIB |
| `languageChoice` | Language: | popup | Swift, Objective-C (Command Line Tool adds C++ and C) | Swift | Objective-C as in rule 4 (apps only) |
| `testingSystem` | Testing System: | popup | None; XCTest ("XCTest for Unit and UI Tests"); Swift Testing ("Swift Testing with XCTest UI Tests"). Templates with unit tests only show plain "XCTest" and "Swift Testing" | None | Swift Testing needs Swift |
| `storageType` | Storage: | popup | None, SwiftData, Core Data | None | SwiftData needs the SwiftUI lifecycle |
| `storageTypeDocument` | Storage: | popup | None, SwiftData (macOS adds Core Data) | None | as above; Core Data needs Cocoa |
| `hostInCloudKit` | Host in CloudKit | checkbox | — | false | Storage ≠ None |
| `hasDocumentation` | Include Documentation | checkbox | — | true | — |
| `gameType` | Game Technology: | popup | RealityKit, SceneKit ("SceneKit (Deprecated)"), SpriteKit, Metal 4, Metal (iOS has no RealityKit) | RealityKit (iOS, macOS: SpriteKit) | per template |
| `integrateGK` | Integrate GameplayKit | checkbox | — | false | Game Technology = SpriteKit |
| `contentType` | Content Technology: | popup | RealityKit, SceneKit ("SceneKit (Deprecated)"), SpriteKit, Metal | RealityKit | per value (AR App) |
| `iOSPlatform`, `visionOSPlatform`, `tvOSPlatform`, `OSXPlatform` | Include iOS / visionOS / tvOS / macOS Application | checkbox | — | true | tvOS needs iOS on |
| `primarySceneType` | Initial Scene: | popup | Window, Volume | Window | — |
| `secondarySceneType` | Immersive Space Renderer: | popup | None, RealityKit, Metal, Metal 4 (Spatial Rendering: Metal, Metal 4) | None (Spatial Rendering: Metal) | — |
| `immersiveSpaceStyle` | Immersive Space: | popup | None, Mixed, Progressive, Full (Spatial Rendering and Immersive Environment: Progressive, Full) | Full | a renderer chosen |
| `companionAppStyle` | Create Companion iOS App | companion chooser | Watch-only App, Watch App with New Companion iOS App, Watch App for Existing iOS App | Watch-only App | — |
| `safariExtensionType` | Type: | popup | Safari App Extension, Safari Web Extension | Safari Web Extension | — |
| `libraryFramework` | Framework: | popup | Cocoa, STL (C++ Library), None (Plain C/C++ Library) | Cocoa | — |
| `libraryType` | Type: | popup | Dynamic, Static | Dynamic | — |
| `apiLevel` | API Level | popup | Low Level - libXPC, High Level - NSXPCConnection | High Level - NSXPCConnection | — |
| `bundleExtension` | Bundle Extension: | text | — | bundle | — |
| `buildToolPath` | Build Tool: | text | — | `/usr/bin/make` | required |
| `ORGANIZATIONNAME` | Organization Name: | text | — | empty (placeholder: a company name) | required |
| `audioUnitType` | Audio Unit Type: | popup | Instrument, Generator, Effect, Music Effect, MIDI Processor, Speech Synthesizer | MIDI Processor | — |
| `audioUnitSubtypeCode`, `audioUnitManufacturerCode` | Subtype Code:, Manufacturer Code: | text | — | empty (placeholders state the 4-character rule) | required; not persisted |
| `hasUserInterface` | User Interface: | popup | Presents User Interface, No User Interface | Presents User Interface | not persisted |

Persisted keys share one namespace. Choosing Testing System = Swift
Testing in one template preselects it in every template that has the
option.

### Option effects (summary)

The catalog gives the full result. In short:

- Interface and Language swap file sets and remove the SwiftUI-only
  settings.
- Testing System adds test components.
- Storage adds model files.
- Host in CloudKit adds entitlements and Info.plist.
- Game and content technology choose file sets and settings.
- The platform checkboxes add or remove per-platform components.
- Initial Scene and the immersive options change the Info.plist scene
  manifest and add the immersive-space files.
- Companion style chooses between a watch-only container and a full
  iOS app.
- Safari Type chooses the web or app extension files.
- Library Framework and Type choose files and the product type.
- API Level chooses the XPC files.
- The Audio Unit options fill the extension's `AudioComponents` entry
  and choose DSP and UI files.
- Include Documentation adds `T.docc`.

## Save step

Next opens a save panel attached to the sheet's window.

- **Name field:** "Save As:" holds the product name. The created folder
  is `<location>/<Product Name>/`. Changing the field does not rename
  the product (Ycode's reading). A package template's name field
  starts at its default name (MyLibrary, …).
- **Location:** starts in the last folder used. The default is
  Ycode's choice of the user's Developer folder, or the home folder.
- **Accessory** (one row each, left labels):
  - **Source Control:** checkbox "Create Git repository on my Mac"
    (tooltip: a local Git repository is created inside the project
    folder). Whether it remembers its last state, and how the
    "disable Git for new projects" default affects it, is OPEN.
    Ycode remembers the last state and starts checked.
  - **Add to:** a pop-up. Its first item is "Don't add to any project
    or workspace". After a separator come the open workspaces and
    projects. The first item is the default when the sheet runs in the
    new empty window that Choose Template… opened. When the sheet runs
    on a window with an open workspace, that workspace is the default.
  - **Group:** a pop-up of the chosen workspace's or project's groups
    (and synchronized folders). It is disabled while Add to is "Don't
    add…".
- **Buttons:** Cancel returns to the options step. Create creates the
  project.

What Create does, in order:

1. If `<location>/<Product Name>` exists, the panel asks whether to
   replace it (the standard save-panel confirmation). Ycode refuses to
   overwrite a non-empty folder unless the user confirms.
2. Writes the project (§ "Template catalog") and remembers the folder
   as the default path.
3. With Create Git repository: runs `git init` in the project folder
   and stages every created file. These are the template files,
   `project.pbxproj`, `project.xcworkspace/contents.xcworkspacedata` and
   the user's `xcschememanagement.plist`, but not
   `UserInterfaceState.xcuserstate`. It then makes **one commit titled
   "Initial Commit"** with the user's Git identity. **No `.gitignore`
   is written.** When the folder is already inside a Git work tree,
   no new repository is made (Ycode's reading; the reference's
   behavior is OPEN).
4. With Add to = a workspace: adds a `FileRef` to the new
   `.xcodeproj` in that workspace's `contents.xcworkspacedata`, inside
   the chosen group. With Add to = a project, the reference asks
   whether to save that project in a new workspace, because projects
   can be combined only in a workspace. Ycode offers the same choice.
5. Opens the result:
   - **Add to = none:** the new project opens in the window that
     hosted the sheet (the empty window from Choose Template…). The
     editor shows the template's initial file. The project navigator
     shows the project, the initial file is selected, and the first
     scheme is chosen.
   - **Added to a workspace:** that workspace's window stays and shows
     the new project in its navigator.
   - **App Playground:** opens the `.swiftpm` package.
   - **Package templates:** open the package folder.

Cancel in the save panel, Previous or Cancel in the options step, and
Cancel in the template sheet create nothing. Cancel in the template
sheet also closes the empty window it opened.

## Ycode implementation (NEW-PROJECT, 2026-11-01)

Clean room: written from this spec, `reference-ui-3.md` §5, `metrics.md`,
`pbxproj.md`, `build-pif.md` and Apple's public documentation. Template
contents are Ycode's own.

### Modules

| Piece | Where |
|---|---|
| Option model: kinds, sort keys, hidden and forced values, requirements, per-value requirements, Ycode-unavailable values, required fields, empty replacements, persisted values | `YcodeIDECore/Model/NewProject/TemplateOptions.swift` (`TemplateOptionField`, `TemplateChoice`, `TemplateOptionsForm`) |
| Catalog: tabs, sections, sort keys, the order rule, the filter, the Package… chooser | `ProjectTemplateDescriptors.swift` (`ProjectTemplates.all`, `.projects`, `.packages`, `TemplateChooserCatalog`) |
| Generators and the common blocks | `ProjectGenerator.swift` (shared blocks, test components, storage, CloudKit), `+Apps.swift`, `+Games.swift`, `+Libraries.swift`, `InterfaceBuilderFiles.swift` (storyboards and XIBs) |
| pbxproj construction | `ProjectRecipe.swift`: object version 77, `preferredProjectObjectVersion = 77`, project attributes (`LastSwiftUpdateCheck`, `LastUpgradeCheck`, `CreatedOnToolsVersion` from `ProjectRecipe.toolsVersion` = 27.1, `TestTargetID`, `ORGANIZATIONNAME`), the project-level settings, platform rows (project level, or per target for multi-SDK and SDK-`auto` projects), Swift settings, `CODE_SIGN_STYLE`/`DEVELOPMENT_TEAM`, one synchronized folder per target with Info.plist exceptions, empty phases, embed and Copy Files phases, SDK framework links |
| Flow: steps, tab and per-tab memory, shared option values, picker rows | `NewProjectFlowModel.swift` (`NewProjectFlowModel`, `NewProjectPicker.templateID(forRow:)`) |
| Save step: write, Git, Add to, Group | `NewProjectCreator` in the same file |
| `ycode new` | `NewProjectCLI.swift` |
| AppKit sheet | `YcodeUI/Window/NewProjectSheet.swift` (`NewProjectSheetController`, `NewProjectSaveAccessory`, `NewProjectFlow`), the grid of `NewFileTemplateGrid.swift` |
| Linux shell | `YcodeIDEShell/NewProjectShellModel.swift` (state, portable), `ycode-ide/NewProjectSheet.swift` (OpenViews view) |

`V(p)` is `xcrun --sdk <p> --show-sdk-version` (major.minor) on a Mac,
cached; elsewhere 27.0. Schemes are not written: the autocreated schemes
(`TestTargetID` gives the tested target's scheme its testables).

### Ycode's choices for the open questions

1. Filter: case- and diacritic-insensitive substring of the name in the
   current tab; sections without a match hidden; an empty state line
   "No templates match “…”." (as proposed above).
2. Section order beyond the two observed tabs: alphabetical, as the rule
   says; the Other tab is one unnamed section.
3. Template descriptions: the Ycode summaries are shown in a caption
   line under the grid.
4. Multiplatform RealityKit Game checkboxes: the one target lists the
   checked platforms in `SUPPORTED_PLATFORMS`, `TARGETED_DEVICE_FAMILY`
   and the deployment targets.
5. Object version: 77 for template projects.
6. Playground row: opens the iOS ▸ App Playground options step.
7. Watch App for Existing iOS App: drawn disabled in New Project.
8. Team placement: right after Product Name in every template.
9. Hidden versus disabled values: drawn disabled.
10. Git checkbox memory: remembered (`YcodeNewProjectCreateGitRepository`),
    checked the first time; a folder inside a Git work tree gets no new
    repository. The save panel's existing-folder confirmation moves the
    old folder to the Trash before writing.

Further Ycode decisions: Add to = a project offers "Save both projects in
a new workspace" (on by default; off adds a sub-project reference);
after Create the project opens in a window at the sheet window's frame
(the empty window closes); the compact picker's App row makes the
untitled project (`reference-ui-6.md` §1.5) from File ▸ New ▸ Project…
too.

### Differences from the catalog (Ycode does not generate these yet)

- Values drawn disabled with a tooltip: Objective-C in games, AR,
  document, Safari, iMessage and XPC templates (Ycode writes them in
  Swift; Objective-C is offered for the App, Framework, Static Library,
  Library and Command Line Tool templates); Metal 4 everywhere; AR
  Metal; Safari App Extension; Speech Synthesizer; Watch App for
  Existing iOS App.
- Templates shown but not creatable: Foveated Streaming App (needs the
  streaming package) and Spatial Rendering App.
- Reduced file sets (Ycode's own): SpriteKit games build their scene in
  code (no `.sks` scene or actions files), SceneKit games an empty
  `art.scnassets`; the Audio Unit app has a host view, the unit, and a
  factory or view controller (no DSP kernel, MIDI helpers or sample
  sound); the Safari resources have no images; the Preference Pane has
  no TIFF icon; visionOS `Resources/` holds one small USD scene per
  space.
- The New Project compact picker on Linux is not drawn: the Welcome
  screen's New Project and File ▸ New ▸ Project… open the template sheet.

### Build check

`ycode/scripts/new-project-matrix.sh <dir>` creates every template and
the option combinations below with `ycode new` and builds each with
Ycode's build path (`ycode build --engine swift-build`, packages with
`swift build`). Results on the Mac (2026-11-01), 129 cases: every
creatable template and the listed combinations (iOS App: Interface ×
Testing System × Storage, Objective-C, CloudKit; every Game technology on
every tab; the visionOS App's scenes × renderers × immersion styles;
watchOS both layouts; the Library's frameworks × types; the DriverKit
templates with `CODE_SIGNING_ALLOWED=NO`) build through `swbuild`, except
two groups the build path cannot do yet, which were built with
`xcodebuild` instead (own samples, nothing studied):

- `.metal` sources (Metal games, Metal Library, the visionOS Metal
  renderer): on a host whose Metal toolchain is a downloadable
  component, the default toolchain's `metal` is a stub that only `xcrun`
  resolves, and `swbuild` calls the stub.
- macOS dynamic libraries: `swbuild`'s signing stub asks for
  entitlements for the dynamic-library product type.

External Build System and Empty have nothing to build; the Swift Macro
and Command-Line Tool packages need their package dependencies fetched
and were created only. On x86-64 Linux the Package… templates (Library,
Empty, Build Tool Plug-in, Command Plug-in, Executable) build with
`swift build`; Xcode-project templates need an Apple SDK there (the iOS
recipe of `ycode-ios-build-linux` needs the user's SDK copy, not
available to this run). OPEN for the build path: let `SwiftBuildEngine`
use the downloaded Metal toolchain, and sign dynamic libraries without
entitlements.

## Evidence

- Correction 2026-10-19: sheet layout and flow per `reference-ui-3.md` §5 (level 3).
- New File / New Project commands, shortcuts and sheet flow (choose a
  template, name, location): Apple's public Xcode Help (level 1).
- Project structure and setting names: `specs/formats/pbxproj.md`,
  `specs/build-settings.md` (levels 1–3); generated projects build with
  swift-build (level 3).
- Template lists and categories, the sheets, the save step and the New
  Project compact picker: `specs/ide/reference-ui-3.md` §5 (level 3).
- OPEN QUESTION: where Xcode places new files (selected group vs. folder).
- iOS App generation: product types, `TEST_HOST`/`BUNDLE_LOADER`,
  `TEST_TARGET_NAME`, `GENERATE_INFOPLIST_FILE` and the `INFOPLIST_KEY_*`
  settings are documented in Apple's Build Settings Reference and in
  swift-build's open-source xcspecs (level 1); `PBXTargetDependency`,
  `PBXContainerItemProxy`, `XCVersionGroup` from `specs/formats/pbxproj.md`
  (level 2); asset catalog `Contents.json` and the SwiftData/Core Data
  APIs from Apple's public documentation (level 1); the generated project
  builds for the iOS Simulator with `xcodebuild` (level 3). File
  contents are Ycode's own.
- Storyboard interface: the scene life cycle, `UISceneConfiguration`,
  `UIApplicationSceneManifest` and its keys, `UIMainStoryboardFile` and
  `UILaunchStoryboardName` are from Apple's public UIKit and Information
  Property List documentation; `INFOPLIST_KEY_*` from the Build Settings
  Reference (level 1). Storyboard XML elements are the public file format
  as observed in open-source iOS projects; the generated storyboards are
  verified with `ibtool --compile` and an `xcodebuild` simulator build
  (levels 2–3). `PBXVariantGroup` / `Base.lproj`: `specs/formats/pbxproj.md`
  (level 2).
- Template chooser and catalog (2026-10-31, OBS-TEMPLATES; dirty notes
  `research/notes/obs-templates-2026-10-31.md`):
  - tabs, sections, names, sort keys, the target-only and project-only
    rules, options, targets, product types, settings, file names,
    components, entitlement and Info.plist key names: the reference's
    template definitions read as a file format (level 2);
  - the order rule checked against the two observed lists in
    `reference-ui-3.md` §5 (level 3);
  - generated-project facts (object version, attributes, synchronized
    folders and their Info.plist exception, signing settings,
    `latest_<platform>` = the SDK version, multi-SDK settings at target
    level, the watch embed phase, test host settings, the 27.1
    single UI-test file): checked against project files written by
    Xcode 16.2–26.4 (level 2/3);
  - persistence keys and value types: the reference's user defaults
    and IDEKit's string table (levels 3–4);
  - package types: SwiftPM's open-source `swift package init` (level 1);
  - the embed-phase table: the pbxproj format as seen in open-source
    projects (level 2);
  - template summaries: Ycode's own wording.
  - OPEN: filter rule, section order beyond Multiplatform and iOS,
    template descriptions in the 27.1 chooser, the RealityKit Game's
    platform checkboxes, the template path's `objectVersion` in 27.1,
    Playground, and Watch App for Existing iOS App in New Project.
- Options step and save step (2026-10-31, OBS-TEMPLATES):
  - option kinds, labels, values, value titles, defaults, required
    and not-persisted flags, requirements and per-value requirements:
    the template definitions (level 2);
  - the observed iOS App field order, the disabled Host in CloudKit,
    the derived Bundle Identifier and the disabled Next:
    `reference-ui-3.md` §5.4 (level 3);
  - persisted option values: the reference's user defaults (level 3);
  - the save accessory's rows and labels (Source Control checkbox,
    Add to, Group): the reference's nib strings (level 4);
  - "Initial Commit" and no `.gitignore`: a string in the reference's
    source-control UI framework (level 4), and the first commits of
    repositories that Xcode 16.3–26.x created (level 3);
  - the new-workspace question for Add to = a project: the reference's
    IDEKit strings (level 4);
  - window reuse after Choose Template…: `reference-ui-3.md` §5.4
    (level 3);
  - Team placement, the save panel's defaults, the Git checkbox
    memory, the existing-repository case, and hidden versus disabled
    values: Ycode's reading, OPEN.
