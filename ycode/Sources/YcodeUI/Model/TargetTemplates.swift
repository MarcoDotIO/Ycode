import Foundation
import YcodePlist
import YcodeProject

/// The new-target sheet's catalog and Ycode's own target templates (the
/// project editor's "+" under the target list, reference-ui-5.md
/// §11.1.2). Contents are Ycode's own; settings follow `templates.md`.
public enum TargetTemplateCatalog {
    /// The template step's heading line.
    public static let heading = "Choose a template for your new target:"
    /// The options step's heading line.
    public static let optionsHeading = "Choose options for your new target:"
    /// The platform tabs, in order.
    public static let platforms = ["iOS", "macOS"]

    /// The template sections under a platform tab.
    public static func sections(platform: String) -> [TemplateSection] {
        func e(_ t: String, _ sym: String) -> TemplateEntry { TemplateEntry(t, defaultName: "", symbol: sym) }
        var app = [e("App", "app")]
        if platform == "macOS" { app.append(e("Command Line Tool", "terminal")) }
        return [TemplateSection(title: "Application", entries: app),
                TemplateSection(title: "Test", entries: [e("Unit Testing Bundle", "checkmark.diamond"), e("UI Testing Bundle", "checkmark.diamond")]),
                TemplateSection(title: "Framework & Library", entries: [e("Framework", "shippingbox"), e("Static Library", "building.columns")])]
    }

    /// The sections whose entries' titles contain `filter` (case-insensitive),
    /// with empty sections dropped; all of them for a blank filter.
    public static func sections(platform: String, filter: String) -> [TemplateSection] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return sections(platform: platform) }
        return sections(platform: platform).compactMap { s in
            let hits = s.entries.filter { $0.title.localizedCaseInsensitiveContains(f) }
            return hits.isEmpty ? nil : TemplateSection(title: s.title, entries: hits)
        }
    }

    /// Whether a template tests another target (the options step then
    /// offers "Target to be Tested").
    public static func isTest(_ title: String) -> Bool { title.hasSuffix("Testing Bundle") }

    public enum Failure: Error, CustomStringConvertible {
        case emptyName, duplicateName(String), unknownTemplate(String)
        public var description: String {
            switch self {
            case .emptyName: "Enter a product name."
            case .duplicateName(let n): "A target named \u{201C}\(n)\u{201D} already exists."
            case .unknownTemplate(let t): "The template \u{201C}\(t)\u{201D} isn't available."
            }
        }
    }

    /// The target and the files (paths relative to the project directory)
    /// a template makes.
    public static func make(template: String, platform: String, name raw: String, organization: String, host: (id: String, name: String)?,
                            proj: PBXProj) throws -> (target: PBXProj.NewTarget, files: [(String, String)]) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw Failure.emptyName }
        guard !proj.targets.contains(where: { $0.string("name") == name }) else { throw Failure.duplicateName(name) }
        let ios = platform == "iOS"
        let type = name.filter { $0.isLetter || $0.isNumber }
        let bundle = "\(organization).\(String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }))"
        var settings: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)"), ("SWIFT_VERSION", "6.0")]
        settings += ios ? [("SDKROOT", "iphoneos"), ("SUPPORTED_PLATFORMS", "iphoneos iphonesimulator"), ("TARGETED_DEVICE_FAMILY", "1,2")]
                        : [("SDKROOT", "macosx")]
        let std = ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"]
        switch template {
        case "App":
            settings += [("PRODUCT_BUNDLE_IDENTIFIER", .string(bundle)), ("GENERATE_INFOPLIST_FILE", "YES"), ("MARKETING_VERSION", "1.0"),
                         ("CURRENT_PROJECT_VERSION", "1"), ("CODE_SIGN_STYLE", "Automatic"), ("ENABLE_PREVIEWS", "YES")]
            if ios {
                settings += [("INFOPLIST_KEY_UIApplicationSceneManifest_Generation", "YES"), ("INFOPLIST_KEY_UILaunchScreen_Generation", "YES"),
                             ("LD_RUNPATH_SEARCH_PATHS", .array(["$(inherited)", "@executable_path/Frameworks"]))]
            } else {
                settings += [("LD_RUNPATH_SEARCH_PATHS", .array(["$(inherited)", "@executable_path/../Frameworks"]))]
            }
            let source = """
            import SwiftUI

            @main
            struct \(type.isEmpty ? "App" : type)App: App {
                var body: some Scene {
                    WindowGroup {
                        Text("\(name)")
                            .padding()
                    }
                }
            }

            """
            return (.init(name: name, productType: "com.apple.product-type.application", productPath: "\(name).app", productFileType: "wrapper.application",
                          settings: settings, phases: std, sourceFolder: name),
                    [("\(name)/\(type.isEmpty ? "App" : type)App.swift", source)])
        case "Command Line Tool":
            return (.init(name: name, productType: "com.apple.product-type.tool", productPath: name, productFileType: "compiled.mach-o.executable",
                          settings: settings, phases: ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"], sourceFolder: name),
                    [("\(name)/main.swift", "print(\"Hello from \(name)\")\n")])
        case "Unit Testing Bundle", "UI Testing Bundle":
            let ui = template == "UI Testing Bundle"
            settings += [("PRODUCT_BUNDLE_IDENTIFIER", .string(bundle)), ("GENERATE_INFOPLIST_FILE", "YES"), ("CODE_SIGN_STYLE", "Automatic")]
            if let host {
                if ui {
                    settings.append(("TEST_TARGET_NAME", .string(host.name)))
                } else {
                    let app = "\(host.name).app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/\(host.name)"
                    settings += [("BUNDLE_LOADER", "$(TEST_HOST)"), ("TEST_HOST", .string("$(BUILT_PRODUCTS_DIR)/\(app)"))]
                }
            }
            let test = ui ? """
                import XCTest

                final class \(type)UITests: XCTestCase {
                    func testLaunch() throws {
                        let app = XCUIApplication()
                        app.launch()
                    }
                }

                """ : """
                import Testing

                struct \(type) {
                    @Test func example() {
                        #expect(1 + 1 == 2)
                    }
                }

                """
            return (.init(name: name, productType: ui ? "com.apple.product-type.bundle.ui-testing" : "com.apple.product-type.bundle.unit-test",
                          productPath: "\(name).xctest", productFileType: "wrapper.cfbundle", settings: settings, phases: std,
                          dependency: host?.id, sourceFolder: name),
                    [("\(name)/\(type).swift", test)])
        case "Framework":
            settings += [("PRODUCT_BUNDLE_IDENTIFIER", .string(bundle)), ("GENERATE_INFOPLIST_FILE", "YES"), ("DEFINES_MODULE", "YES"),
                         ("SKIP_INSTALL", "YES"), ("CURRENT_PROJECT_VERSION", "1"), ("MARKETING_VERSION", "1.0"),
                         ("DYLIB_INSTALL_NAME_BASE", "@rpath"), ("INSTALL_PATH", "$(LOCAL_LIBRARY_DIR)/Frameworks")]
            return (.init(name: name, productType: "com.apple.product-type.framework", productPath: "\(name).framework",
                          productFileType: "wrapper.framework", settings: settings,
                          phases: ["PBXHeadersBuildPhase", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"], sourceFolder: name),
                    [("\(name)/\(type).swift", "public struct \(type) {\n    public init() {}\n}\n")])
        case "Static Library":
            settings += [("SKIP_INSTALL", "YES")]
            return (.init(name: name, productType: "com.apple.product-type.library.static", productPath: "lib\(name).a", productFileType: "archive.ar",
                          settings: settings, phases: ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"], sourceFolder: name),
                    [("\(name)/\(type).swift", "public struct \(type) {\n    public init() {}\n}\n")])
        default:
            throw Failure.unknownTemplate(template)
        }
    }

    /// The bundle identifier prefix: the first app target's identifier
    /// without its last component, else "com.example".
    public static func organization(of proj: PBXProj, xcodeprojURL: URL) -> String {
        for t in proj.targets {
            for c in proj.buildConfigurations(listID: t.string("buildConfigurationList")) {
                if let id = c["buildSettings"]?.dictionary?["PRODUCT_BUNDLE_IDENTIFIER"]?.string, id.contains("."), !id.contains("$") {
                    return id.split(separator: ".").dropLast().joined(separator: ".")
                }
            }
        }
        return "com.example"
    }
}

extension ProjectEditorModel {
    /// Adds a target from a template; writes its starter files (never
    /// overwriting). Returns the new target's name.
    @discardableResult
    public mutating func addTarget(template: String, platform: String, name: String, hostTarget: String?) throws -> String {
        let host = hostTarget.flatMap { h in target(named: h).map { ($0.id, h) } }
        let org = TargetTemplateCatalog.organization(of: proj, xcodeprojURL: xcodeprojURL)
        let made = try TargetTemplateCatalog.make(template: template, platform: platform, name: name, organization: org, host: host, proj: proj)
        let dir = proj.projectDirectory(xcodeprojURL: xcodeprojURL)
        for (rel, text) in made.files {
            let url = dir.appendingPathComponent(rel)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        // Projects before object version 77 have no synchronized folders:
        // the starter files go into the new group and the Sources phase.
        let id = proj.addTarget(made.target)
        if (Int(proj.objectVersion) ?? 0) < 77, let folder = made.target.sourceFolder {
            let group = proj.addSourceGroup(path: folder)
            let sources = proj.buildPhases(ofTarget: id).first(where: { $0.isa == "PBXSourcesBuildPhase" })?.id
            for (rel, _) in made.files {
                let ref = proj.addFileReference(path: (rel as NSString).lastPathComponent, to: group)
                if let sources { proj.addBuildFile(fileReference: ref, to: sources) }
            }
        }
        return made.target.name
    }

    /// Deletes a target (the target list's "−").
    public mutating func removeTarget(named name: String) {
        if let t = target(named: name) { proj.removeTarget(t.id) }
    }
}
