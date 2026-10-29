import Foundation
import YcodePlist
import YcodeProject

/// Ycode's own file templates. See `specs/ide/templates.md`.
public enum FileTemplate: String, CaseIterable, Sendable {
    case swiftFile = "Swift File"
    case swiftClass = "Swift Class"
    case objcClass = "Objective-C Class"
    case header = "Header File"
    case empty = "Empty File"
    case propertyList = "Property List"

    /// File name → contents for a template and a name.
    public func files(named name: String) -> [(String, String)] {
        switch self {
        case .swiftFile: [("\(name).swift", "import Foundation\n")]
        case .swiftClass: [("\(name).swift", "import Foundation\n\nfinal class \(name) {\n    init() {}\n}\n")]
        case .objcClass: [
            ("\(name).h", "#import <Foundation/Foundation.h>\n\n@interface \(name) : NSObject\n@end\n"),
            ("\(name).m", "#import \"\(name).h\"\n\n@implementation \(name)\n@end\n"),
        ]
        case .header: [("\(name).h", "#pragma once\n")]
        case .empty: [(name, "")]
        case .propertyList: [("\(name).plist", PropertyListDocument(root: .dictionary([])).xml())]
        }
    }

    static let compiledExtensions: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp"]
}

public enum NewFileError: Error, CustomStringConvertible {
    case exists(String)
    case emptyName
    public var description: String {
        switch self {
        case .exists(let p): "\(p) already exists"
        case .emptyName: "the name is empty"
        }
    }
}

/// Creates new files on disk from templates and, inside a project, adds
/// them to the matching group and build phases. See `specs/ide/templates.md`.
public enum FileCreator {
    /// Writes a template's files into `directory`, and (for a project) adds
    /// them to the group of that folder and compiled ones to the first
    /// target's Compile Sources. Returns the new files.
    @discardableResult
    public static func create(_ template: FileTemplate, name: String, in directory: URL,
                              project: inout PBXProj?, xcodeprojURL: URL?, targets: [String]? = nil) throws -> [URL] {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw NewFileError.emptyName }
        return try write(template.files(named: name), in: directory, project: &project, xcodeprojURL: xcodeprojURL, targets: targets)
    }

    /// Files whose build phase is Compile Sources, and Copy Bundle Resources.
    static let sourceExtensions: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "metal", "s", "xcdatamodeld", "intentdefinition", "docc"]
    static let resourceExtensions: Set<String> = ["xcassets", "storyboard", "xib", "xcstrings", "strings", "stringsdict", "xcprivacy", "json",
                                                  "geojson", "gpx", "rtf", "scnassets", "scn", "sks", "bundle", "xcstickers", "icon", "gamekit"]

    /// Writes files (paths relative to `directory`; a path through a
    /// folder makes that folder, one ending in "/" is an empty folder) and
    /// adds each top-level item to the project: a file reference in the
    /// folder's group, and for `targets` (nil: compiled files go to the
    /// first target with Compile Sources) the matching build phase.
    /// Returns the top-level items.
    @discardableResult
    public static func write(_ files: [(String, String)], in directory: URL, project: inout PBXProj?, xcodeprojURL: URL?,
                             targets: [String]? = nil) throws -> [URL] {
        var top: [String] = []
        for (f, _) in files {
            let first = String(f.split(separator: "/", omittingEmptySubsequences: true).first ?? Substring(f))
            if !top.contains(first) { top.append(first) }
        }
        for t in top where FileManager.default.fileExists(atPath: directory.appendingPathComponent(t).path) {
            throw NewFileError.exists(directory.appendingPathComponent(t).path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (f, text) in files {
            let u = directory.appendingPathComponent(f)
            if f.hasSuffix("/") {
                try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let urls = top.map { directory.appendingPathComponent($0) }
        guard var proj = project, let xcodeprojURL else { return urls }
        let dir = directory.standardizedFileURL.path
        let projectDir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
        let parents = proj.parentMap()
        // A synchronized folder picks the files up by itself.
        let synced = proj.objects.values.filter { $0.isa == "PBXFileSystemSynchronizedRootGroup" }
            .compactMap { proj.resolvedPath(of: $0.id, projectDirectory: projectDir, parents: parents) }
        if synced.contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) { return urls }
        let groups = proj.objects.values.filter { $0.isa == "PBXGroup" }.sorted { $0.id < $1.id }
        let group = groups.first { proj.resolvedPath(of: $0.id, projectDirectory: projectDir, parents: parents) == dir }?.id
            ?? proj.project?.string("mainGroup") ?? ""
        let groupDir = proj.resolvedPath(of: group, projectDirectory: projectDir, parents: parents) ?? projectDir.path
        let chosen = targets.map { names in proj.targets.filter { names.contains($0.string("name") ?? "") } }
        let fallbackSources = proj.targets.lazy.compactMap { t in proj.buildPhases(ofTarget: t.id).first { $0.isa == "PBXSourcesBuildPhase" } }.first
        for u in urls {
            let rel = u.path.hasPrefix(groupDir + "/") ? String(u.path.dropFirst(groupDir.count + 1)) : u.lastPathComponent
            let ref = proj.addFileReference(path: rel, to: group)
            let ext = u.pathExtension.lowercased()
            if let chosen {
                let isa = sourceExtensions.contains(ext) ? "PBXSourcesBuildPhase" : resourceExtensions.contains(ext) ? "PBXResourcesBuildPhase" : nil
                guard let isa else { continue }
                for t in chosen {
                    if let phase = proj.buildPhases(ofTarget: t.id).first(where: { $0.isa == isa }) { proj.addBuildFile(fileReference: ref, to: phase.id) }
                }
            } else if let fallbackSources, FileTemplate.compiledExtensions.contains(ext) {
                proj.addBuildFile(fileReference: ref, to: fallbackSources.id)
            }
        }
        project = proj
        return urls
    }
}

/// Ycode's own project templates. See `specs/ide/templates.md`.
public enum ProjectTemplate: String, CaseIterable, Sendable {
    case commandLineTool = "macOS Command Line Tool"
    case app = "macOS App"
    case swiftPackage = "Swift Package"

    /// Creates `<location>/<name>/…` and returns what to open (the
    /// `.xcodeproj` or the package folder).
    public func create(name: String, organization: String, in location: URL) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw NewFileError.emptyName }
        let root = location.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw NewFileError.exists(root.path) }
        let fm = FileManager.default
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        switch self {
        case .swiftPackage:
            try write("Package.swift", """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "\(name)",
                products: [.library(name: "\(name)", targets: ["\(name)"])],
                targets: [
                    .target(name: "\(name)"),
                    .testTarget(name: "\(name)Tests", dependencies: ["\(name)"]),
                ]
            )

            """)
            try write("Sources/\(name)/\(name).swift", "public func greeting() -> String { \"\(name)\" }\n")
            try write("Tests/\(name)Tests/\(name)Tests.swift", """
            import Testing
            @testable import \(name)

            @Test func greets() {
                #expect(greeting() == "\(name)")
            }

            """)
            return root
        case .commandLineTool, .app:
            let isApp = self == .app
            let source = isApp ? "\(name)App.swift" : "main.swift"
            let text = isApp ? """
            import SwiftUI

            @main
            struct \(name.filter { $0.isLetter || $0.isNumber })App: App {
                var body: some Scene {
                    WindowGroup {
                        Text("\(name)")
                            .padding(40)
                    }
                }
            }

            """ : "print(\"\(name)\")\n"
            try write("\(name)/\(source)", text)
            let proj = try Self.makeProject(name: name, source: source, app: isApp, bundlePrefix: organization)
            let projURL = root.appendingPathComponent("\(name).xcodeproj")
            try fm.createDirectory(at: projURL, withIntermediateDirectories: true)
            try proj.serialized(projectName: name).write(to: projURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
            return projURL
        }
    }

    /// Creates the project for an options-step Finish: iOS ▸ App uses the
    /// iOS App generator; everything else the name/organization form.
    public func create(platform: String, options: ProjectOptions, in location: URL) throws -> URL {
        if self == .app && platform == "iOS" { return try IOSAppTemplate.create(options: options, in: location) }
        return try create(name: options.productName, organization: options.organizationIdentifier, in: location)
    }

    /// A one-target project built object by object.
    static func makeProject(name: String, source: String, app: Bool, bundlePrefix: String) throws -> PBXProj {
        var p = try PBXProj(parsing: "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; objects = {}; rootObject = 000000000000000000000000; }\n")
        func obj(_ attrs: [(String, PlistValue)]) -> String {
            let id = p.makeObjectID()
            p[id] = PBXObject(id: id, attributes: PlistDictionary(attrs))
            return id
        }
        func strings(_ ids: [String]) -> PlistValue { .array(ids.map(PlistValue.string)) }
        func config(_ n: String, _ settings: [(String, PlistValue)]) -> String {
            obj([("isa", "XCBuildConfiguration"), ("buildSettings", .dictionary(PlistDictionary(settings))), ("name", .string(n))])
        }
        func list(_ ids: [String]) -> String {
            obj([("isa", "XCConfigurationList"), ("buildConfigurations", strings(ids)), ("defaultConfigurationIsVisible", "0"),
                 ("defaultConfigurationName", "Release")])
        }
        let product = obj([("isa", "PBXFileReference"), ("explicitFileType", .string(app ? "wrapper.application" : "compiled.mach-o.executable")),
                           ("includeInIndex", "0"), ("path", .string(app ? "\(name).app" : name)), ("sourceTree", "BUILT_PRODUCTS_DIR")])
        let sourceRef = obj([("isa", "PBXFileReference"), ("lastKnownFileType", "sourcecode.swift"), ("path", .string(source)), ("sourceTree", "<group>")])
        let sourceGroup = obj([("isa", "PBXGroup"), ("children", strings([sourceRef])), ("path", .string(name)), ("sourceTree", "<group>")])
        let products = obj([("isa", "PBXGroup"), ("children", strings([product])), ("name", "Products"), ("sourceTree", "<group>")])
        let main = obj([("isa", "PBXGroup"), ("children", strings([sourceGroup, products])), ("sourceTree", "<group>")])
        let buildFile = obj([("isa", "PBXBuildFile"), ("fileRef", .string(sourceRef))])
        let phaseCommon: [(String, PlistValue)] = [("buildActionMask", "2147483647"), ("runOnlyForDeploymentPostprocessing", "0")]
        var phases = [
            obj([("isa", "PBXSourcesBuildPhase")] + [phaseCommon[0], ("files", strings([buildFile])), phaseCommon[1]]),
            obj([("isa", "PBXFrameworksBuildPhase")] + [phaseCommon[0], ("files", strings([])), phaseCommon[1]]),
        ]
        if app { phases.append(obj([("isa", "PBXResourcesBuildPhase")] + [phaseCommon[0], ("files", strings([])), phaseCommon[1]])) }
        var targetSettings: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)")]
        if app {
            targetSettings += [("GENERATE_INFOPLIST_FILE", "YES"), ("INFOPLIST_KEY_NSPrincipalClass", "NSApplication"),
                               ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1"),
                               ("PRODUCT_BUNDLE_IDENTIFIER", .string("\(bundlePrefix).\(name)")), ("CODE_SIGN_STYLE", "Automatic")]
        }
        let targetList = list([config("Debug", targetSettings), config("Release", targetSettings)])
        let target = obj([("isa", "PBXNativeTarget"), ("buildConfigurationList", .string(targetList)), ("buildPhases", strings(phases)),
                          ("buildRules", strings([])), ("dependencies", strings([])), ("name", .string(name)),
                          ("productName", .string(name)), ("productReference", .string(product)),
                          ("productType", .string(app ? "com.apple.product-type.application" : "com.apple.product-type.tool"))])
        let common: [(String, PlistValue)] = [("SDKROOT", "macosx"), ("MACOSX_DEPLOYMENT_TARGET", "15.0"), ("SWIFT_VERSION", "6.0"),
                                              ("ALWAYS_SEARCH_USER_PATHS", "NO")]
        let projectList = list([
            config("Debug", common + [("ONLY_ACTIVE_ARCH", "YES"), ("SWIFT_OPTIMIZATION_LEVEL", "-Onone"), ("DEBUG_INFORMATION_FORMAT", "dwarf"),
                                      ("GCC_OPTIMIZATION_LEVEL", "0"), ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG")]),
            config("Release", common + [("SWIFT_OPTIMIZATION_LEVEL", "-O"), ("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym")]),
        ])
        let project = obj([("isa", "PBXProject"), ("buildConfigurationList", .string(projectList)), ("developmentRegion", "en"),
                           ("hasScannedForEncodings", "0"), ("knownRegions", .array(["en", "Base"])), ("mainGroup", .string(main)),
                           ("productRefGroup", .string(products)), ("projectDirPath", ""), ("projectRoot", ""),
                           ("targets", strings([target]))])
        p.rootObject = project
        return p
    }
}

// MARK: - Template sheets (specs/ide/reference-ui-3.md §5)

/// One cell of a template sheet's icon grid.
public struct TemplateEntry: Equatable, Sendable {
    public var title: String
    /// The name the save step preselects.
    public var defaultName: String
    /// The file extension Ycode writes ("" = none).
    public var fileExtension: String
    public var symbol: String
    public init(_ title: String, defaultName: String = "File", ext: String = "", symbol: String = "doc") {
        self.title = title
        self.defaultName = defaultName
        fileExtension = ext
        self.symbol = symbol
    }

    /// Ycode's own template for the entry, when one exists.
    public var fileTemplate: FileTemplate? {
        switch title {
        case "Swift File": .swiftFile
        case "Cocoa Touch Class": .swiftClass
        case "Objective-C File": .objcClass
        case "Header File": .header
        case "Property List": .propertyList
        default: nil
        }
    }

    /// File name → contents for a name chosen in the save step.
    public func files(named name: String) -> [(String, String)] {
        if let t = fileTemplate { return t.files(named: name) }
        let file = fileExtension.isEmpty || name.hasSuffix("." + fileExtension) ? name : "\(name).\(fileExtension)"
        return [(file, "")]
    }
}

public struct TemplateSection: Equatable, Sendable {
    public var title: String
    public var entries: [TemplateEntry]
}

/// The new-file sheet's catalog: platform tabs, sections, filter.
public enum FileTemplateCatalog {
    /// The sheet's heading line.
    public static let heading = "Choose a template for your new file:"
    /// The platform tabs, in order.
    public static let platforms = ["iOS", "macOS", "watchOS", "tvOS", "visionOS", "DriverKit"]

    /// The template sections listed under a platform tab.
    public static func sections(platform: String) -> [TemplateSection] {
        func e(_ t: String, _ ext: String, _ name: String = "File", _ sym: String = "doc") -> TemplateEntry {
            TemplateEntry(t, defaultName: name, ext: ext, symbol: sym)
        }
        let source = TemplateSection(title: "Source", entries: [
            e("Swift File", "swift", "File", "swift"), e("Cocoa Touch Class", "swift", "Class", "c.square"),
            e("Objective-C File", "m", "File", "m.square"), e("Header File", "h", "Header", "h.square"),
            e("C File", "c", "File", "c.square"), e("C++ File", "cpp", "File", "plus.square"),
            e("Metal File", "metal", "Shaders", "cube"),
        ])
        if platform == "DriverKit" {
            return [source, TemplateSection(title: "Other", entries: [e("Empty", "", "File")])]
        }
        return [
            source,
            TemplateSection(title: "User Interface", entries: [
                e("SwiftUI View", "swift", "ContentView", "rectangle.on.rectangle"), e("Storyboard", "storyboard", "Main", "rectangle.split.3x1"),
                e("View", "xib", "View", "rectangle"), e("Empty", "xib", "Empty", "rectangle.dashed"),
                e("Launch Screen", "storyboard", "Launch Screen", "rectangle.portrait"),
            ]),
            TemplateSection(title: "Test", entries: [
                e("Swift Testing Unit Test", "swift", "Tests", "checkmark.diamond"), e("XCTest Unit Test", "swift", "Tests", "checkmark.diamond"),
                e("XCTest UI Launch Test", "swift", "UITestsLaunchTests", "checkmark.diamond"),
                e("XCTest UI Test", "swift", "UITests", "checkmark.diamond"), e("Test Plan", "xctestplan", "TestPlan", "list.bullet"),
            ]),
            TemplateSection(title: "Core Data", entries: [
                e("Data Model", "xcdatamodeld", "Model", "cylinder"), e("Mapping Model", "xcmappingmodel", "Mapping", "arrow.left.arrow.right"),
            ]),
            TemplateSection(title: "Resource", entries: [
                e("App Privacy", "xcprivacy", "PrivacyInfo"), e("Asset Catalog", "xcassets", "Media", "photo"), e("GeoJSON File", "geojson"),
                e("GPX File", "gpx"), e("Icon Composer Icon", "icon", "AppIcon", "app"), e("Module Map", "modulemap", "module"),
                e("Property List", "plist", "PropertyList", "list.bullet.rectangle"), e("Rich Text File", "rtf"),
                e("SceneKit Catalog", "scnassets", "Art"), e("SceneKit Scene File", "scn", "Scene"), e("Settings Bundle", "bundle", "Settings"),
                e("SiriKit Intent Definition File", "intentdefinition", "Intents"), e("SpriteKit Action", "sks", "Action"),
                e("SpriteKit Particle File", "sks", "Particle"), e("SpriteKit Scene", "sks", "Scene"),
                e("SpriteKit Tile Set", "sks", "TileSet"), e("Sticker Catalog", "xcstickers", "Stickers"),
                e("String Catalog", "xcstrings", "Localizable", "character.bubble"),
                e("Strings File (Legacy)", "strings", "Localizable"), e("Stringsdict File (Legacy)", "stringsdict", "Localizable"),
                e("Touch Alternatives", "plist", "TouchAlternatives"),
            ]),
            TemplateSection(title: "Documentation", entries: [
                e("Documentation Catalog", "docc", "Documentation", "book"), e("Article File", "md", "Article"),
                e("Extension File", "md", "Extension"), e("Empty", "md", "Empty"),
                e("Tutorial Table of Contents File", "tutorial", "Table Of Contents"), e("Tutorial File", "tutorial", "Tutorial"),
            ]),
            TemplateSection(title: "Other", entries: [
                e("Empty", "", "File"), e("Assembly File", "s"), e("Build Phase File List", "xcfilelist"), e("CLIPS File", "clp"),
                e("Configuration Settings File", "xcconfig", "Config"), e("Exports File", "exp"), e("GameKit Bundle", "gamekit", "GameKit"),
                e("Markdown File", "md"), e("PCH File", "pch", "PrefixHeader"), e("Shell Script", "sh", "Script", "terminal"),
                e("StoreKit Configuration File", "storekit", "Configuration"),
            ]),
        ]
    }

    /// The sections filtered by title; empty sections are dropped.
    public static func sections(platform: String, filter: String) -> [TemplateSection] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return sections(platform: platform) }
        return sections(platform: platform).compactMap { s in
            let hits = s.entries.filter { $0.title.localizedCaseInsensitiveContains(f) }
            return hits.isEmpty ? nil : TemplateSection(title: s.title, entries: hits)
        }
    }

    /// Writes an entry's files into `directory` (and the project), as
    /// `FileCreator` does for Ycode's own templates; other entries write
    /// `TemplateContents` (an empty file when it has none).
    @discardableResult
    public static func create(_ entry: TemplateEntry, name: String, in directory: URL, platform: String = "iOS",
                              project: inout PBXProj?, xcodeprojURL: URL?, targets: [String]? = nil) throws -> [URL] {
        if let t = entry.fileTemplate {
            return try FileCreator.create(t, name: name, in: directory, project: &project, xcodeprojURL: xcodeprojURL, targets: targets)
        }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { throw NewFileError.emptyName }
        let base = !entry.fileExtension.isEmpty && n.hasSuffix("." + entry.fileExtension) ? String(n.dropLast(entry.fileExtension.count + 1)) : n
        let files = TemplateContents.files(entry, name: base, platform: platform) ?? [(entry.files(named: n)[0].0, "")]
        return try FileCreator.write(files, in: directory, project: &project, xcodeprojURL: xcodeprojURL, targets: targets)
    }
}

/// The step a template sheet is on: Previous is disabled on the first.
public struct TemplateSheetSteps: Equatable, Sendable {
    public var count: Int
    public var index = 0
    public init(count: Int) { self.count = count }
    public var isPreviousEnabled: Bool { index > 0 }
    public var isLast: Bool { index == count - 1 }
    public mutating func next() { index = min(index + 1, count - 1) }
    public mutating func previous() { index = max(index - 1, 0) }
}

/// File ▸ New ▸ Project…'s compact picker.
public enum NewProjectPicker {
    /// The picker's title.
    public static let header = "New Project"
    public struct Row: Equatable, Sendable {
        public var title: String
        public var subtitle: String
    }
    /// The picker rows, in order; see `template(forRow:)`.
    public static let rows: [Row] = [
        Row(title: "App", subtitle: "SwiftUI app for iPhone, iPad, Mac & Vision Pro"),
        Row(title: "Command Line Tool", subtitle: "Terminal program for macOS"),
        Row(title: "Package…", subtitle: "Swift package library"),
        Row(title: "Playground", subtitle: "Explore previews & playgrounds in a Swift file"),
        Row(title: "Choose Template…", subtitle: "Other apps, libraries, and games…"),
    ]
    /// The index in `rows` of "Choose Template…", which opens the full sheet.
    public static let chooseTemplateIndex = 4

    /// Ycode's own template behind a row (nil: the template sheet).
    public static func template(forRow i: Int) -> ProjectTemplate? {
        switch i {
        case 0: .app
        case 1: .commandLineTool
        case 2: .swiftPackage
        default: nil
        }
    }
}

/// The New Project template sheet's catalog.
public enum ProjectTemplateCatalog {
    /// The sheet's heading line.
    public static let heading = "Choose a template for your new project:"
    /// The platform tabs, in order.
    public static let platforms = ["Multiplatform", "iOS", "macOS", "watchOS", "tvOS", "visionOS", "DriverKit", "Other"]
    static let lastKey = "YcodeLastProjectTemplate"

    /// The template sections listed under a platform tab.
    public static func sections(platform: String) -> [TemplateSection] {
        func e(_ t: String) -> TemplateEntry { TemplateEntry(t, defaultName: "", symbol: "app") }
        switch platform {
        case "Multiplatform":
            return [TemplateSection(title: "Application", entries: ["App", "Document App", "Foveated Streaming App", "Game",
                                                                    "Audio Unit Extension App", "Safari Extension App"].map(e)),
                    TemplateSection(title: "Framework & Library", entries: [e("Framework")])]
        case "iOS":
            return [TemplateSection(title: "Application", entries: ["App", "Document App", "Game", "Augmented Reality App", "App Playground",
                                                                    "Sticker Pack App", "iMessage App", "Safari Extension App"].map(e)),
                    TemplateSection(title: "Framework & Library", entries: ["Framework", "Static Library", "Metal Library"].map(e))]
        case "macOS":
            return [TemplateSection(title: "Application", entries: ["App", "Document App", "Game", "Command Line Tool"].map(e)),
                    TemplateSection(title: "Framework & Library", entries: ["Framework", "Library", "Metal Library"].map(e))]
        case "Other":
            return [TemplateSection(title: "Other", entries: ["Empty", "Swift Package"].map(e))]
        default:
            return [TemplateSection(title: "Application", entries: [e("App")])]
        }
    }

    /// Ycode's own template for a sheet choice (nil: not yet supported).
    public static func template(platform: String, title: String) -> ProjectTemplate? {
        switch (platform, title) {
        case (_, "App"): .app
        case (_, "Command Line Tool"): .commandLineTool
        case (_, "Swift Package"): .swiftPackage
        default: nil
        }
    }

    /// The last selected template ("platform/title"), preselected next time.
    public static func lastSelection(_ d: UserDefaults) -> (platform: String, title: String) {
        let parts = (d.string(forKey: lastKey) ?? "").split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, platforms.contains(parts[0]) else { return ("iOS", "App") }
        return (parts[0], parts[1])
    }
    /// Stores the chosen template for `lastSelection(_:)`.
    public static func setLastSelection(platform: String, title: String, _ d: UserDefaults) {
        d.set("\(platform)/\(title)", forKey: lastKey)
    }
}

/// The options step ("Choose options for your new project:").
public struct ProjectOptions: Equatable, Sendable {
    public static let heading = "Choose options for your new project:"
    public enum Interface: String, CaseIterable, Sendable { case swiftUI = "SwiftUI", storyboard = "Storyboard" }
    public enum Testing: String, CaseIterable, Sendable {
        case none = "None"
        case xctest = "XCTest for Unit and UI Tests"
        case swiftTesting = "Swift Testing with XCTest UI Tests"
    }
    public enum Storage: String, CaseIterable, Sendable { case none = "None", swiftData = "SwiftData", coreData = "Core Data" }

    public var productName = ""
    public var team = "None"
    public var organizationIdentifier = "com.example"
    public var interface = Interface.swiftUI
    public var language = "Swift"
    public var testing = Testing.swiftTesting
    public var storage = Storage.none
    public var hostInCloudKit = false
    public init() {}

    /// Derived; "<org>.ProductName" while the name is empty.
    public var bundleIdentifier: String {
        let n = productName.trimmingCharacters(in: .whitespaces)
        let id = n.isEmpty ? "ProductName" : String(n.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
        return "\(organizationIdentifier).\(id)"
    }
    public var isBundleIdentifierPlaceholder: Bool { productName.trimmingCharacters(in: .whitespaces).isEmpty }
    public var isCloudKitEnabled: Bool { storage != .none }
    public var isNextEnabled: Bool { !isBundleIdentifierPlaceholder }
    public mutating func setStorage(_ s: Storage) {
        storage = s
        if s == .none { hostInCloudKit = false }
    }
}

/// The Welcome window's New Project ▸ App (`specs/ide/reference-ui-6.md`
/// §1.5, W6): an untitled multiplatform SwiftUI app created at once, with
/// no sheet, in Ycode's own untitled-projects folder. The file contents
/// are Ycode's own; the setting names and values are interop facts
/// (`specs/formats/pbxproj.md`).
public enum UntitledAppProject {
    /// The folder's base name ("Untitled Project", then "… 2", "… 3").
    public static let folderName = "Untitled Project"
    /// The app target, its synchronized folder and the project's name.
    public static let targetName = "MyApp"
    /// The newest SDK major (the deployment targets).
    public static let deploymentTarget = "27.0"
    /// A placeholder bundle identifier that needs no team.
    public static let bundleIdentifier = "com.example.MyApp"
    /// SDK "auto" builds for every supported platform.
    public static let supportedPlatforms = "iphoneos iphonesimulator macosx xros xrsimulator"
    /// iPhone, iPad, Apple Vision (device families 1, 2, 7).
    public static let deviceFamilies = "1,2,7"

    /// Ycode's untitled-projects folder in the user's Library.
    public static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Ycode/Untitled Projects", isDirectory: true)
    }

    /// The first free folder under `base`: "Untitled Project", then
    /// "Untitled Project 2", …
    public static func freeFolder(in base: URL) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? folderName : "\(folderName) \(n)"
            let u = base.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    /// The created project and the file the window opens with.
    public struct Created: Equatable, Sendable {
        public var project: URL
        public var entryFile: URL
    }

    /// Creates the project in a free folder under `base`.
    public static func create(in base: URL = defaultLocation) throws -> Created {
        let root = freeFolder(in: base)
        let fm = FileManager.default
        let t = targetName
        for (rel, text) in files() {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let projURL = root.appendingPathComponent("\(t).xcodeproj")
        try fm.createDirectory(at: projURL, withIntermediateDirectories: true)
        try makeProject().serialized(projectName: t).write(to: projURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        return Created(project: projURL, entryFile: root.appendingPathComponent("\(t)/\(t).swift"))
    }

    /// The synchronized folder's files (paths under the project folder).
    static func files() -> [(String, String)] {
        let t = targetName
        return [
            ("\(t)/\(t).swift", """
            import SwiftUI

            @main
            struct \(t): App {
                var body: some Scene {
                    WindowGroup {
                        ContentView()
                    }
                }
            }

            """),
            ("\(t)/ContentView.swift", """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .imageScale(.large)
                        Text("Hello from \(t)")
                    }
                    .padding()
                }
            }

            #Preview {
                ContentView()
            }

            """),
            ("\(t)/Assets.xcassets/Contents.json", IOSAppTemplate.json(#""info" : { "author" : "ycode", "version" : 1 }"#)),
            ("\(t)/Assets.xcassets/AccentColor.colorset/Contents.json",
             IOSAppTemplate.json(#""colors" : [ { "idiom" : "universal" } ],\#n  "info" : { "author" : "ycode", "version" : 1 }"#)),
            ("\(t)/Assets.xcassets/AppIcon.appiconset/Contents.json",
             IOSAppTemplate.json(#""images" : [ { "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],\#n  "info" : { "author" : "ycode", "version" : 1 }"#)),
        ]
    }

    /// One app target whose sources are the synchronized folder.
    static func makeProject() throws -> PBXProj {
        var p = try PBXProj(parsing: "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; objects = {}; rootObject = 000000000000000000000000; }\n")
        func obj(_ attrs: [(String, PlistValue)]) -> String {
            let id = p.makeObjectID()
            p[id] = PBXObject(id: id, attributes: PlistDictionary(attrs))
            return id
        }
        func strings(_ ids: [String]) -> PlistValue { .array(ids.map(PlistValue.string)) }
        func config(_ n: String, _ settings: [(String, PlistValue)]) -> String {
            obj([("isa", "XCBuildConfiguration"), ("buildSettings", .dictionary(PlistDictionary(settings.sorted { $0.0 < $1.0 }))), ("name", .string(n))])
        }
        func list(_ ids: [String]) -> String {
            obj([("isa", "XCConfigurationList"), ("buildConfigurations", strings(ids)), ("defaultConfigurationIsVisible", "0"),
                 ("defaultConfigurationName", "Release")])
        }
        func phase(_ isa: String) -> String {
            obj([("isa", .string(isa)), ("buildActionMask", "2147483647"), ("files", strings([])), ("runOnlyForDeploymentPostprocessing", "0")])
        }
        let t = targetName
        let product = obj([("isa", "PBXFileReference"), ("explicitFileType", "wrapper.application"), ("includeInIndex", "0"),
                           ("path", .string("\(t).app")), ("sourceTree", "BUILT_PRODUCTS_DIR")])
        let folder = obj([("isa", "PBXFileSystemSynchronizedRootGroup"), ("path", .string(t)), ("sourceTree", "<group>")])
        let products = obj([("isa", "PBXGroup"), ("children", strings([product])), ("name", "Products"), ("sourceTree", "<group>")])
        let main = obj([("isa", "PBXGroup"), ("children", strings([folder, products])), ("sourceTree", "<group>")])
        let settings: [(String, PlistValue)] = [
            ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"), ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
            ("CODE_SIGN_STYLE", "Automatic"), ("CURRENT_PROJECT_VERSION", "1"), ("ENABLE_PREVIEWS", "YES"),
            ("GENERATE_INFOPLIST_FILE", "YES"),
            ("INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphoneos*]", "YES"),
            ("INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphonesimulator*]", "YES"),
            ("INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphoneos*]", "YES"),
            ("INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphonesimulator*]", "YES"),
            ("IPHONEOS_DEPLOYMENT_TARGET", .string(deploymentTarget)),
            ("LD_RUNPATH_SEARCH_PATHS", .array(["$(inherited)", "@executable_path/Frameworks"])),
            ("LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]", .array(["$(inherited)", "@executable_path/../Frameworks"])),
            ("MACOSX_DEPLOYMENT_TARGET", .string(deploymentTarget)), ("MARKETING_VERSION", "1.0"),
            ("PRODUCT_BUNDLE_IDENTIFIER", .string(bundleIdentifier)), ("PRODUCT_NAME", "$(TARGET_NAME)"),
            ("SDKROOT", "auto"), ("SUPPORTED_PLATFORMS", .string(supportedPlatforms)), ("SWIFT_VERSION", "6.0"),
            ("TARGETED_DEVICE_FAMILY", .string(deviceFamilies)), ("XROS_DEPLOYMENT_TARGET", .string(deploymentTarget)),
        ]
        let target = obj([("isa", "PBXNativeTarget"), ("buildConfigurationList", .string(list([config("Debug", settings), config("Release", settings)]))),
                          ("buildPhases", strings([phase("PBXSourcesBuildPhase"), phase("PBXFrameworksBuildPhase"), phase("PBXResourcesBuildPhase")])),
                          ("buildRules", strings([])), ("dependencies", strings([])), ("fileSystemSynchronizedGroups", strings([folder])),
                          ("name", .string(t)), ("packageProductDependencies", strings([])), ("productName", .string(t)),
                          ("productReference", .string(product)), ("productType", "com.apple.product-type.application")])
        let common: [(String, PlistValue)] = [("ALWAYS_SEARCH_USER_PATHS", "NO"), ("SWIFT_VERSION", "6.0")]
        let projectList = list([
            config("Debug", common + [("DEBUG_INFORMATION_FORMAT", "dwarf"), ("ENABLE_TESTABILITY", "YES"), ("GCC_OPTIMIZATION_LEVEL", "0"),
                                      ("ONLY_ACTIVE_ARCH", "YES"), ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG $(inherited)"),
                                      ("SWIFT_OPTIMIZATION_LEVEL", "-Onone")]),
            config("Release", common + [("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym"), ("SWIFT_COMPILATION_MODE", "wholemodule")]),
        ])
        let project = obj([("isa", "PBXProject"), ("buildConfigurationList", .string(projectList)), ("developmentRegion", "en"),
                           ("hasScannedForEncodings", "0"), ("knownRegions", .array(["en", "Base"])), ("mainGroup", .string(main)),
                           ("minimizedProjectReferenceProxies", "1"), ("preferredProjectObjectVersion", "77"),
                           ("productRefGroup", .string(products)), ("projectDirPath", ""), ("projectRoot", ""),
                           ("targets", strings([target]))])
        p.rootObject = project
        return p
    }
}
