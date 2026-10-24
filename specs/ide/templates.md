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
