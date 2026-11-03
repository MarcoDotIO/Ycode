import Foundation
import YcodePlist
import YcodeProject
import YcodeSubprocess

/// What a template generates: the project folder's files, the pbxproj
/// (nil for packages) and the initial file.
public struct GeneratedProject {
    /// The folder created under the chosen location ("N", or "N.swiftpm").
    public var folderName: String
    /// Paths relative to the folder; a path ending in "/" is an empty folder.
    public var files: [(String, String)]
    public var project: PBXProj?
    /// The project's name (`N.xcodeproj`).
    public var projectName: String
    /// The file the editor shows first (relative to the folder).
    public var entryFile: String?
    /// A package made by `swift package init` (written by SwiftPM).
    public var packageInit: (type: String, arguments: [String])?

    public init(folderName: String, files: [(String, String)], project: PBXProj?, projectName: String, entryFile: String?) {
        self.folderName = folderName
        self.files = files
        self.project = project
        self.projectName = projectName
        self.entryFile = entryFile
    }

    /// The file names of the folder, sorted (tests).
    public var paths: [String] { files.map(\.0).sorted() }

    public func contents(_ path: String) -> String? { files.first { $0.0 == path }?.1 }

    /// The embedded workspace every project carries (one `self:` FileRef).
    static let selfWorkspace = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Workspace
       version = "1.0">
       <FileRef
          location = "self:">
       </FileRef>
    </Workspace>

    """

    /// Writes `<location>/<folderName>/…`; returns what to open. Fails
    /// without writing anything when the folder exists and is not empty.
    @discardableResult
    public func write(in location: URL) throws -> URL {
        let root = location.appendingPathComponent(folderName, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path), !((try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty ?? false) {
            throw NewFileError.exists(root.path)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let (type, args) = packageInit {
            try SwiftPackageInit.run(type: type, name: projectName, arguments: args, in: root)
        }
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            if rel.hasSuffix("/") {
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        guard let project else { return root }
        let projURL = root.appendingPathComponent("\(projectName).xcodeproj", isDirectory: true)
        let ws = projURL.appendingPathComponent("project.xcworkspace", isDirectory: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        try project.serialized(projectName: projectName).write(to: projURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try Self.selfWorkspace.write(to: ws.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
        return projURL
    }
}

/// Runs SwiftPM's `swift package init` (the Package… templates' content is
/// SwiftPM's own, `templates.md` § "Package…").
enum SwiftPackageInit {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func swift() -> String? {
        let env = ProcessInfo.processInfo.environment
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/usr/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/share/swiftly/bin"]
        return dirs.map { "\($0)/swift" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(type: String, name: String, arguments: [String], in dir: URL) throws {
        guard let swift = swift() else { throw Failure(description: "swift was not found; the package cannot be created.") }
        let out = try Subprocess.run(swift, ["package", "init", "--type", type, "--name", name] + arguments, currentDirectory: dir)
        guard out.status == 0 else {
            throw Failure(description: "swift package init failed: \(out.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

public enum ProjectGeneratorError: LocalizedError, CustomStringConvertible, Equatable {
    case unavailable(String)
    case invalid([String])
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .unavailable(let t): "Ycode cannot create “\(t)” projects yet."
        case .invalid(let issues): issues.joined(separator: " ")
        }
    }
}

/// Writes projects from (template, options) following `templates.md` §
/// "Template catalog". Every generated file's text is Ycode's own;
/// setting names and values, product types and plist keys are interop
/// facts from the spec.
public enum ProjectGenerator {
    /// Generates without touching the disk (packages made by SwiftPM are
    /// written by `GeneratedProject.write`).
    public static func generate(_ d: ProjectTemplateDescriptor, _ form: TemplateOptionsForm, team: String? = nil) throws -> GeneratedProject {
        guard d.isAvailable else { throw ProjectGeneratorError.unavailable(d.title) }
        guard form.isNextEnabled else { throw ProjectGeneratorError.invalid(form.issues) }
        let c = GenContext(d: d, f: form, team: team.flatMap { $0 == "None" || $0.isEmpty ? nil : $0 })
        if d.isPackage { return package(c, type: String(d.generator.dropFirst("package:".count))) }
        switch d.generator {
        case "app": return try app(c)
        case "documentApp": return try documentApp(c)
        case "game": return try game(c)
        case "arApp": return try arApp(c)
        case "visionApp": return try visionApp(c, environment: false)
        case "immersiveEnvironmentApp": return try visionApp(c, environment: true)
        case "watchApp": return try watchApp(c)
        case "framework": return try framework(c)
        case "staticLibrary": return try staticLibrary(c)
        case "library": return try macLibrary(c)
        case "driverKitLibrary": return try driverKitLibrary(c)
        case "metalLibrary": return try metalLibrary(c)
        case "bundle": return try bundle(c)
        case "commandLineTool": return try commandLineTool(c)
        case "xpcService": return try xpcService(c)
        case "kernelExtension": return try kernelExtension(c, iokit: false)
        case "iokitDriver": return try kernelExtension(c, iokit: true)
        case "installerPlugin": return try installerPlugin(c)
        case "instrumentsPackage": return try instrumentsPackage(c)
        case "preferencePane": return try preferencePane(c)
        case "screenSaver": return try screenSaver(c)
        case "safariExtensionApp": return try safariExtensionApp(c)
        case "audioUnitApp": return try audioUnitApp(c)
        case "iMessageApp": return try iMessageApp(c)
        case "stickerPackApp": return try stickerPackApp(c)
        case "driver": return try driver(c)
        case "appPlayground": return appPlayground(c)
        case "empty": return try recipe(c, [], [])
        case "externalBuildSystem": return try externalBuildSystem(c)
        default: throw ProjectGeneratorError.unavailable(d.title)
        }
    }

    /// Generates and writes `<location>/<name>/…`; returns what to open.
    @discardableResult
    public static func create(_ d: ProjectTemplateDescriptor, _ form: TemplateOptionsForm, in location: URL) throws -> URL {
        try generate(d, form).write(in: location)
    }
}

/// The values a generator reads (`templates.md` § Notation).
struct GenContext {
    let d: ProjectTemplateDescriptor
    let f: TemplateOptionsForm
    var team: String?

    /// `N`.
    var n: String { f.productName }
    /// `T`: the C-identifier form of `N`.
    var t: String { n.templateTypeName }
    var module: String { n.templateModuleName }
    /// `B`.
    var bundleID: String { f.bundleIdentifier }
    var sdk: TemplateSDK { d.sdk }
    var lit: String { n.swiftLiteral }
    var objc: Bool { option(TemplateOptionID.language) == "Objective-C" }
    var swiftUI: Bool { option(TemplateOptionID.interface).isEmpty || option(TemplateOptionID.interface) == "SwiftUI" }
    var organizationName: String { f.value(TemplateOptionID.organizationName) }

    enum Testing { case none, xctest, swiftTesting }
    var testing: Testing {
        guard d.fields.contains(where: { $0.id == TemplateOptionID.testingSystem }) else { return .none }
        switch f.value(TemplateOptionID.testingSystem) {
        case "XCTest": return .xctest
        case "Swift Testing": return .swiftTesting
        default: return .none
        }
    }

    func option(_ id: String) -> String { f.value(id) }
    func on(_ id: String) -> Bool { f.bool(id) }

    /// A copyright line (Ycode's own wording).
    var copyright: String {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return "© \(year) \(organizationName.isEmpty ? n : organizationName)"
    }
}

// MARK: - Common blocks (`templates.md` § "Common target blocks")

extension ProjectGenerator {
    static func json(_ body: String) -> String { "{\n  \(body)\n}\n" }
    static let info = #""info" : { "author" : "ycode", "version" : 1 }"#

    static func pd(_ pairs: [(String, PropertyListItem)]) -> PropertyListItem {
        .dictionary(pairs.map { PropertyListEntry(key: $0.0, value: $0.1) })
    }

    static func infoPlist(_ pairs: [(String, PropertyListItem)]) -> String { PropertyListDocument(root: pd(pairs)).xml() }

    static let macIconSizes = ["16x16", "32x32", "128x128", "256x256", "512x512"]

    /// `Assets.xcassets`: an accent color and the platforms' icon sets.
    static func assets(_ folder: String, platforms: [String]) -> [(String, String)] {
        var out = [("\(folder)/Assets.xcassets/Contents.json", json(info)),
                   ("\(folder)/Assets.xcassets/AccentColor.colorset/Contents.json", json(#""colors" : [ { "idiom" : "universal" } ],\#n  "# + info))]
        var slots: [String] = []
        for p in platforms {
            switch p {
            case "iOS": slots.append(#"{ "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }"#)
            case "macOS": slots += macIconSizes.flatMap { s in ["1x", "2x"].map { #"{ "idiom" : "mac", "scale" : "\#($0)", "size" : "\#(s)" }"# } }
            case "watchOS": slots.append(#"{ "idiom" : "universal", "platform" : "watchos", "size" : "1024x1024" }"#)
            default: break
            }
        }
        if !slots.isEmpty {
            out.append(("\(folder)/Assets.xcassets/AppIcon.appiconset/Contents.json",
                        json(#""images" : [ \#(slots.joined(separator: ", ")) ],\#n  "# + info)))
        }
        // visionOS and tvOS: a solid image stack (front, middle, back layers).
        if platforms.contains("visionOS") || platforms.contains("tvOS") {
            let stack = "\(folder)/Assets.xcassets/AppIcon.solidimagestack"
            let layers = ["Front", "Middle", "Back"]
            out.append(("\(stack)/Contents.json", json(#""info" : { "author" : "ycode", "version" : 1 },\#n  "layers" : [ "#
                + layers.map { #"{ "filename" : "\#($0).solidimagestacklayer" }"# }.joined(separator: ", ") + " ]")))
            for l in layers {
                out.append(("\(stack)/\(l).solidimagestacklayer/Contents.json", json(info)))
                out.append(("\(stack)/\(l).solidimagestacklayer/Content.imageset/Contents.json",
                            json(#""images" : [ { "idiom" : "vision", "scale" : "2x" } ],\#n  "# + info)))
            }
        }
        return out
    }

    /// The App target block (any platform).
    static func appBlock(_ c: GenContext, bundleID: String, swiftUI: Bool, icon: Bool = true) -> [(String, PlistValue)] {
        var s: [(String, PlistValue)] = [
            ("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(bundleID)), ("GENERATE_INFOPLIST_FILE", "YES"),
            ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1"), ("SWIFT_EMIT_LOC_STRINGS", "YES"),
            ("STRING_CATALOG_GENERATE_SYMBOLS", "YES"), ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
        ]
        if icon { s.append(("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon")) }
        if swiftUI { s.append(("ENABLE_PREVIEWS", "YES")) }
        return s
    }

    static let iPhoneOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
    static let iPadOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"

    /// iOS app additions.
    static func iosAdditions(swiftUILifecycle: Bool) -> [(String, PlistValue)] {
        var s: [(String, PlistValue)] = [
            ("TARGETED_DEVICE_FAMILY", "1,2"), ("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/Frameworks"]),
            ("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents", "YES"),
            ("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone", .string(iPhoneOrientations)),
            ("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad", .string(iPadOrientations)),
        ]
        if swiftUILifecycle {
            s += [("INFOPLIST_KEY_UIApplicationSceneManifest_Generation", "YES"), ("INFOPLIST_KEY_UILaunchScreen_Generation", "YES")]
        }
        return s
    }

    /// macOS app additions.
    static func macAdditions(_ c: GenContext, cocoa: Bool, document: Bool = false, suffix: String = "") -> [(String, PlistValue)] {
        var s: [(String, PlistValue)] = [
            ("ENABLE_APP_SANDBOX\(suffix)", "YES"), ("ENABLE_USER_SELECTED_FILES\(suffix)", document ? "readwrite" : "readonly"),
            ("REGISTER_APP_GROUPS\(suffix)", "YES"), ("INFOPLIST_KEY_NSHumanReadableCopyright", .string(c.copyright)),
        ]
        if suffix.isEmpty { s.append(("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/../Frameworks"])) }
        if cocoa { s += [("INFOPLIST_KEY_NSPrincipalClass", "NSApplication"), ("INFOPLIST_KEY_NSViewGestureRecognizerIsExclusive", "NO")] }
        return s
    }

    /// The Multiplatform App's platform settings (§ Multiplatform ▸ App).
    static func multiplatformApp(_ c: GenContext) -> [(String, PlistValue)] {
        var s: [(String, PlistValue)] = [("SDKROOT", "auto"), ("SUPPORTED_PLATFORMS", .string(TemplateSDK.multiplatform.supportedPlatforms)),
                                         ("TARGETED_DEVICE_FAMILY", "1,2,7")]
        s += TemplateSDK.multiplatform.platformRow
        s += macAdditions(c, cocoa: false, suffix: "").filter { $0.0 != "LD_RUNPATH_SEARCH_PATHS" }
        for sdk in ["iphoneos", "iphonesimulator"] {
            s += [("INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=\(sdk)*]", "YES"),
                  ("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=\(sdk)*]", "YES"),
                  ("INFOPLIST_KEY_UILaunchScreen_Generation[sdk=\(sdk)*]", "YES"),
                  ("INFOPLIST_KEY_UIStatusBarStyle[sdk=\(sdk)*]", "UIStatusBarStyleDefault")]
        }
        s += [("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone", .string(iPhoneOrientations)),
              ("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad", .string(iPadOrientations)),
              ("LD_RUNPATH_SEARCH_PATHS", ["@executable_path/Frameworks"]), ("LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]", ["@executable_path/../Frameworks"])]
        return s
    }

    /// The settings a platform's app target gets for `sdk`.
    static func platformApp(_ c: GenContext, sdk: TemplateSDK, swiftUILifecycle: Bool, document: Bool = false) -> [(String, PlistValue)] {
        switch sdk.sdkroot {
        case "iphoneos": return iosAdditions(swiftUILifecycle: swiftUILifecycle)
        case "macosx": return macAdditions(c, cocoa: !swiftUILifecycle, document: document)
        case "auto": return multiplatformApp(c)
        case "appletvos":
            return [("TARGETED_DEVICE_FAMILY", "3"), ("INFOPLIST_KEY_UIUserInterfaceStyle", "Automatic"),
                    ("INFOPLIST_KEY_UILaunchScreen_Generation", "YES"), ("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/Frameworks"])]
        case "xros":
            return [("TARGETED_DEVICE_FAMILY", "7"), ("SUPPORTED_PLATFORMS", "xros xrsimulator"),
                    ("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/Frameworks"])]
        case "watchos":
            return [("TARGETED_DEVICE_FAMILY", "4"), ("SKIP_INSTALL", "YES"), ("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/Frameworks"]),
                    ("INFOPLIST_KEY_UISupportedInterfaceOrientations", "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown")]
        default: return []
        }
    }

    /// Icon-set platforms for a target SDK.
    static func iconPlatforms(_ sdk: TemplateSDK) -> [String] {
        switch sdk.sdkroot {
        case "auto": ["iOS", "macOS"]
        case "iphoneos": ["iOS"]
        case "macosx": ["macOS"]
        case "watchos": ["watchOS"]
        case "appletvos": ["tvOS"]
        case "xros": ["visionOS"]
        default: []
        }
    }

    /// Settings of the tested target that test bundles repeat.
    static func repeatedPlatform(_ settings: [(String, PlistValue)], deployment: Bool) -> [(String, PlistValue)] {
        settings.filter { k, _ in
            ["TARGETED_DEVICE_FAMILY", "SUPPORTED_PLATFORMS", "SDKROOT"].contains(k) || (deployment && k.hasSuffix("_DEPLOYMENT_TARGET"))
        }
    }

    static func unitTestSource(_ c: GenContext, type: String, module: String) -> String {
        switch c.testing {
        case .xctest:
            return """
            import XCTest
            @testable import \(module)

            final class \(type): XCTestCase {
                func testExample() throws {
                    XCTAssertEqual(1 + 1, 2)
                }
            }

            """
        default:
            return """
            import Testing
            @testable import \(module)

            struct \(type) {
                @Test func example() {
                    #expect(1 + 1 == 2)
                }
            }

            """
        }
    }

    static func uiTestSource(type: String) -> String {
        """
        import XCTest

        final class \(type): XCTestCase {
            @MainActor
            func testLaunch() throws {
                let app = XCUIApplication()
                app.launch()
            }
        }

        """
    }

    /// Test components (§ "Test components"): the unit-test target (and,
    /// with `ui`, the UI-test target) for `host`.
    static func tests(_ c: GenContext, host: String, hostSettings: [(String, PlistValue)], hostIsApp: Bool, ui: Bool, sdk: TemplateSDK? = nil)
        -> (targets: [ProjectRecipe.Target], files: [(String, String)]) {
        guard c.testing != .none else { return ([], []) }
        let org = TemplateOptionsForm.bundleIdentifier(organization: c.f.organizationIdentifier, name: host)
        let common: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)"), ("GENERATE_INFOPLIST_FILE", "YES"), ("MARKETING_VERSION", "1.0"),
                                              ("CURRENT_PROJECT_VERSION", "1"), ("SWIFT_EMIT_LOC_STRINGS", "NO"),
                                              ("STRING_CATALOG_GENERATE_SYMBOLS", "NO")]
        let unit = "\(host)Tests"
        var us = common + [("PRODUCT_BUNDLE_IDENTIFIER", .string(org + "Tests"))] + repeatedPlatform(hostSettings, deployment: hostIsApp)
        if hostIsApp {
            // App-hosted unit tests copy the app's deployment target.
            for row in (sdk ?? c.sdk).platformRow where row.0 != "SDKROOT" && !us.contains(where: { $0.0 == row.0 }) { us.append(row) }
            let macHost = (sdk ?? c.sdk).sdkroot == "macosx"
            us += [("BUNDLE_LOADER", "$(TEST_HOST)"),
                   ("TEST_HOST", .string(macHost ? "$(BUILT_PRODUCTS_DIR)/\(host).app/Contents/MacOS/\(host)"
                                                : "$(BUILT_PRODUCTS_DIR)/\(host).app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/\(host)"))]
        }
        var targets = [ProjectRecipe.Target(name: unit, productType: "com.apple.product-type.bundle.unit-test", productPath: "\(unit).xctest",
                                            productFileType: "wrapper.cfbundle", folders: [unit], settings: us,
                                            dependencies: [host], links: hostIsApp ? [] : [host], testedTarget: host, sdk: sdk)]
        var files = [("\(unit)/\(unit.templateTypeName).swift", unitTestSource(c, type: unit.templateTypeName, module: host.templateModuleName))]
        if ui {
            let uiName = "\(host)UITests"
            let s = common + [("PRODUCT_BUNDLE_IDENTIFIER", .string(org + "UITests")), ("TEST_TARGET_NAME", .string(host))]
                + repeatedPlatform(hostSettings, deployment: false)
            targets.append(.init(name: uiName, productType: "com.apple.product-type.bundle.ui-testing", productPath: "\(uiName).xctest",
                                 productFileType: "wrapper.cfbundle", folders: [uiName], settings: s, dependencies: [host], testedTarget: host, sdk: sdk))
            files.append(("\(uiName)/\(uiName.templateTypeName).swift", uiTestSource(type: uiName.templateTypeName)))
        }
        return (targets, files)
    }

    /// A recipe → generated project. A single-SDK project carries the
    /// platform row at project level.
    static func recipe(_ c: GenContext, _ targets: [ProjectRecipe.Target], _ files: [(String, String)], entry: String? = nil,
                       projectSDK: TemplateSDK?? = .none, swift: Bool = true) throws -> GeneratedProject {
        var r = ProjectRecipe(name: c.n, targets: targets, files: files)
        switch projectSDK {
        case .some(let s): r.projectSDK = s
        case .none: r.projectSDK = c.sdk.sdkroot == "auto" ? nil : c.sdk
        }
        r.team = c.team
        let override = c.option("deploymentTarget").trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { r.deploymentOverride = override }
        r.organizationName = c.organizationName.isEmpty ? nil : c.organizationName
        r.swift = swift
        if c.sdk.sdkroot == "driverkit" { r.projectSettings.append(("CLANG_CXX_LANGUAGE_STANDARD", "gnu++20")) }
        return GeneratedProject(folderName: c.n, files: files, project: try r.makeProject(), projectName: c.n, entryFile: entry)
    }

    /// Storage files (§ Storage) for an app folder; the CloudKit variant
    /// adds entitlements, Info.plist and settings.
    static func storage(_ c: GenContext, folder: String, sdk: TemplateSDK) -> (files: [(String, String)], settings: [(String, PlistValue)], exceptions: [String]) {
        let kind = c.option(TemplateOptionID.storage)
        let cloud = c.on(TemplateOptionID.hostInCloudKit) && kind != "None"
        var files: [(String, String)] = []
        switch kind {
        case "SwiftData":
            files.append(("\(folder)/Item.swift", """
            import Foundation
            import SwiftData

            @Model
            final class Item {
                var timestamp: Date = Date.now

                init(timestamp: Date) {
                    self.timestamp = timestamp
                }
            }

            """))
        case "Core Data":
            files.append(("\(folder)/Persistence.swift", """
            import CoreData

            /// The app's Core Data stack.
            struct PersistenceController {
                static let shared = PersistenceController()
                let container: \(cloud ? "NSPersistentCloudKitContainer" : "NSPersistentContainer")

                init(inMemory: Bool = false) {
                    container = \(cloud ? "NSPersistentCloudKitContainer" : "NSPersistentContainer")(name: "\(c.t)")
                    if inMemory {
                        container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
                    }
                    container.loadPersistentStores { _, error in
                        if let error { print("The store did not load: \\(error)") }
                    }
                    container.viewContext.automaticallyMergesChangesFromParent = true
                }
            }

            """))
            files.append(("\(folder)/\(c.t).xcdatamodeld/\(c.t).xcdatamodel/contents", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="1" systemVersion="1" minimumToolsVersion="Automatic" sourceLanguage="Swift" \(cloud ? "usedWithCloudKit=\"YES\" " : "")userDefinedModelVersionIdentifier="">
                <entity name="Item" representedClassName="Item" syncable="YES" codeGenerationType="class">
                    <attribute name="timestamp" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
                </entity>
            </model>

            """))
        default: break
        }
        guard cloud else { return (files, [], []) }
        var ent: [(String, PropertyListItem)] = []
        switch sdk.sdkroot {
        case "macosx": ent.append(("com.apple.developer.aps-environment", .string("development")))
        case "auto": ent += [("aps-environment", .string("development")), ("com.apple.developer.aps-environment", .string("development"))]
        default: ent.append(("aps-environment", .string("development")))
        }
        ent += [("com.apple.developer.icloud-container-identifiers", .array([])),
                ("com.apple.developer.icloud-services", .array([.string("CloudKit")]))]
        files.append(("\(folder)/\(c.t).entitlements", infoPlist(ent)))
        var settings: [(String, PlistValue)] = [("CODE_SIGN_ENTITLEMENTS", .string("\(folder)/\(c.t).entitlements"))]
        var exceptions: [String] = []
        if sdk.sdkroot != "macosx" {
            files.append(("\(folder)/Info.plist", infoPlist([("UIBackgroundModes", .array([.string("remote-notification")]))])))
            settings.append(("INFOPLIST_FILE", .string("\(folder)/Info.plist")))
            exceptions.append("Info.plist")
        }
        return (files, settings, exceptions)
    }

    /// One app target.
    static func appTarget(_ name: String, settings: [(String, PlistValue)], sdk: TemplateSDK? = nil, exceptions: [String] = [],
                          folders: [String]? = nil, swift: Bool = true) -> ProjectRecipe.Target {
        var t = ProjectRecipe.Target(name: name, productType: "com.apple.product-type.application", productPath: "\(name).app",
                                     productFileType: "wrapper.application", folders: folders ?? [name], exceptions: exceptions, settings: settings, sdk: sdk)
        if !swift { t.swiftVersion = nil }
        return t
    }
}
