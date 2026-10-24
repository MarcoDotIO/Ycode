import AppKit
import Foundation
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeUI

@MainActor
@Suite(.serialized) struct IOSAppTemplateTests {
    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-iosapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func options(_ name: String, _ testing: ProjectOptions.Testing, _ storage: ProjectOptions.Storage) -> ProjectOptions {
        var o = ProjectOptions()
        o.productName = name
        o.organizationIdentifier = "org.ycode.tests"
        o.testing = testing
        o.setStorage(storage)
        return o
    }

    func settings(_ p: PBXProj, target: PBXObject, _ config: String = "Debug") -> PlistDictionary? {
        p.buildConfigurations(listID: target.string("buildConfigurationList")).first { $0.string("name") == config }?.attributes["buildSettings"]?.dictionary
    }

    @Test(arguments: ProjectOptions.Testing.allCases)
    func targetsPerTestingSystem(_ testing: ProjectOptions.Testing) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ProjectTemplate.app.create(platform: "iOS", options: options("Tour", testing, .none), in: dir)
        let p = try PBXProj(contentsOf: url.appendingPathComponent("project.pbxproj"))
        let names = p.targets.map { $0.string("name") ?? "" }
        if testing == .none {
            #expect(names == ["Tour"])
        } else {
            #expect(names == ["Tour", "TourTests", "TourUITests"])
            let unit = try #require(p.targets.first { $0.string("name") == "TourTests" })
            #expect(unit.string("productType") == "com.apple.product-type.bundle.unit-test")
            #expect(settings(p, target: unit)?["TEST_HOST"]?.string == "$(BUILT_PRODUCTS_DIR)/Tour.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Tour")
            let ui = try #require(p.targets.first { $0.string("name") == "TourUITests" })
            #expect(ui.string("productType") == "com.apple.product-type.bundle.ui-testing")
            #expect(settings(p, target: ui)?["TEST_TARGET_NAME"]?.string == "Tour")
            #expect(ui.references("dependencies").count == 1)
            let test = try String(contentsOf: dir.appendingPathComponent("Tour/TourTests/TourTests.swift"), encoding: .utf8)
            #expect(test.contains(testing == .xctest ? "import XCTest" : "import Testing"))
        }
        let app = try #require(p.targets.first)
        #expect(app.string("productType") == "com.apple.product-type.application")
        let s = try #require(settings(p, target: app))
        #expect(s["PRODUCT_BUNDLE_IDENTIFIER"]?.string == "org.ycode.tests.Tour")
        #expect(s["GENERATE_INFOPLIST_FILE"]?.string == "YES")
        #expect(s["TARGETED_DEVICE_FAMILY"]?.string == "1,2")
        let proj = try #require(p.project)
        let ps = try #require(p.buildConfigurations(listID: proj.string("buildConfigurationList")).first?.attributes["buildSettings"]?.dictionary)
        #expect(ps["SDKROOT"]?.string == "iphoneos")
        // Writer round trip.
        let text = try String(contentsOf: url.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        #expect(try PBXProj(parsing: text).serialized(projectName: "Tour") == text)
    }

    @Test func storageVariants() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try ProjectTemplate.app.create(platform: "iOS", options: options("Data", .none, .swiftData), in: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Data/Data/Item.swift").path))
        #expect(try String(contentsOf: dir.appendingPathComponent("Data/Data/DataApp.swift"), encoding: .utf8).contains(".modelContainer(for: Item.self)"))
        let url = try ProjectTemplate.app.create(platform: "iOS", options: options("Core", .none, .coreData), in: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Core/Core/Core.xcdatamodeld/Core.xcdatamodel/contents").path))
        let p = try PBXProj(contentsOf: url.appendingPathComponent("project.pbxproj"))
        #expect(p.objects(isa: "XCVersionGroup").first?.string("path") == "Core.xcdatamodeld")
    }

    func storyboardOptions(_ name: String, _ testing: ProjectOptions.Testing = .none) -> ProjectOptions {
        var o = options(name, testing, .none)
        o.interface = .storyboard
        return o
    }

    @Test func storyboardVariant() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ProjectTemplate.app.create(platform: "iOS", options: storyboardOptions("Board"), in: dir)
        let fm = FileManager.default
        for f in ["AppDelegate.swift", "SceneDelegate.swift", "ViewController.swift", "Base.lproj/Main.storyboard",
                  "Base.lproj/LaunchScreen.storyboard", "Info.plist"] {
            #expect(fm.fileExists(atPath: dir.appendingPathComponent("Board/Board/\(f)").path), "\(f)")
        }
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("Board/Board/ContentView.swift").path))
        let p = try PBXProj(contentsOf: url.appendingPathComponent("project.pbxproj"))
        #expect(Set(p.objects(isa: "PBXVariantGroup").compactMap { $0.string("name") }) == ["Main.storyboard", "LaunchScreen.storyboard"])
        let app = try #require(p.targets.first)
        let s = try #require(settings(p, target: app))
        #expect(s["INFOPLIST_KEY_UIMainStoryboardFile"]?.string == "Main")
        #expect(s["INFOPLIST_KEY_UILaunchStoryboardName"]?.string == "LaunchScreen")
        #expect(s["INFOPLIST_FILE"]?.string == "Board/Info.plist")
        #expect(s["INFOPLIST_KEY_UILaunchScreen_Generation"] == nil)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: dir.appendingPathComponent("Board/Board/Info.plist")), format: nil) as? [String: Any]
        let manifest = try #require(plist?["UIApplicationSceneManifest"] as? [String: Any])
        let cfg = ((manifest["UISceneConfigurations"] as? [String: Any])?["UIWindowSceneSessionRoleApplication"] as? [[String: Any]])?.first
        #expect(cfg?["UISceneStoryboardFile"] as? String == "Main")
        #expect(cfg?["UISceneDelegateClassName"] as? String == "$(PRODUCT_MODULE_NAME).SceneDelegate")
        let text = try String(contentsOf: url.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        #expect(try PBXProj(parsing: text).serialized(projectName: "Board") == text)
    }

    /// Finish on the options step (the compact picker's App row) creates it.
    @Test func finishCreatesIOSApp() throws {
        _ = NSApplication.shared
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try WorkspaceModel(url: try WindowSnapshotTests().samplePackage())
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: host), loadDestinations: false, startLanguageService: false)
        let td = TestDefaults("ios-app-template")
        defer { td.remove() }
        wc.templateDefaults = td.defaults
        wc.newProjectLocation = dir
        let sheet = wc.projectPickerChose(0)
        sheet.options = options("Picked", .swiftTesting, .swiftData)
        sheet.nextClicked()
        let url = try #require(wc.lastCreatedProject)
        let p = try PBXProj(contentsOf: url.appendingPathComponent("project.pbxproj"))
        #expect(p.targets.map { $0.string("name") ?? "" } == ["Picked", "PickedTests", "PickedUITests"])
    }

    /// Builds the generated project for the iOS Simulator when an SDK exists.
    @Test(.timeLimit(.minutes(10))) func buildsForSimulator() async throws {
        guard let sdk = run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"]), sdk.status == 0, !sdk.out.isEmpty,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/xcodebuild") else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let variants = [("SimApp", options("SimApp", .swiftTesting, .swiftData)), ("CoreApp", options("CoreApp", .swiftTesting, .coreData)),
                        ("BoardApp", storyboardOptions("BoardApp", .xctest))]
        for (name, opts) in variants {
            let url = try ProjectTemplate.app.create(platform: "iOS", options: opts, in: dir)
            // Off the main actor: suites running in parallel (debugger
            // sessions) need it while xcodebuild runs.
            let args = ["-project", url.path, "-alltargets", "-sdk", "iphonesimulator", "-configuration", "Debug",
                        "SYMROOT=\(dir.path)/build", "OBJROOT=\(dir.path)/obj", "CODE_SIGNING_ALLOWED=NO", "build"]
            let r = await Task.detached { Self.run("/usr/bin/xcodebuild", args) }.value
            #expect(r?.status == 0, "\(name): \(r?.out.suffix(3000) ?? "")")
        }
    }

    func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String)? { Self.run(tool, args) }

    nonisolated static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
