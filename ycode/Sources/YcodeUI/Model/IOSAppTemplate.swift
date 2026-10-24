import Foundation
import YcodePlist
import YcodeProject

/// The iOS App project generator (specs/ide/templates.md, "iOS App").
public enum IOSAppTemplate {
    public enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        public var description: String {
            switch self { case .unsupported(let s): "\(s) is not yet supported" }
        }
    }

    /// Creates `<location>/<Product Name>/…`; returns the `.xcodeproj`.
    public static func create(options: ProjectOptions, in location: URL) throws -> URL {
        let name = options.productName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw NewFileError.emptyName }
        let root = location.appendingPathComponent(name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw NewFileError.exists(root.path) }
        let type = name.filter { $0.isLetter || $0.isNumber }
        let t = type.isEmpty || type.first!.isNumber ? "App" + type : type
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let tests = options.testing != .none
        for (rel, text) in files(name: name, type: t, options: options) { try write(rel, text) }
        let proj = try makeProject(name: name, options: options, tests: tests)
        let projURL = root.appendingPathComponent("\(name).xcodeproj")
        try fm.createDirectory(at: projURL, withIntermediateDirectories: true)
        try proj.serialized(projectName: name).write(to: projURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        return projURL
    }

    static func files(name n: String, type t: String, options: ProjectOptions) -> [(String, String)] {
        let lit = n.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var out: [(String, String)] = []
        let scene: String
        let content: String
        switch options.storage {
        case .none:
            scene = "        WindowGroup {\n            ContentView()\n        }\n"
            content = """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                        Text("\(lit)")
                    }
                    .padding()
                }
            }

            #Preview {
                ContentView()
            }

            """
        case .swiftData:
            scene = "        WindowGroup {\n            ContentView()\n        }\n        .modelContainer(for: Item.self)\n"
            content = """
            import SwiftData
            import SwiftUI

            struct ContentView: View {
                @Environment(\\.modelContext) private var context
                @Query(sort: \\Item.timestamp) private var items: [Item]

                var body: some View {
                    NavigationStack {
                        List(items) { item in
                            Text(item.timestamp, style: .time)
                        }
                        .navigationTitle("\(lit)")
                        .toolbar {
                            Button("Add") { context.insert(Item(timestamp: .now)) }
                        }
                    }
                }
            }

            """
            out.append(("\(n)/Item.swift", """
            import Foundation
            import SwiftData

            @Model
            final class Item {
                var timestamp: Date
                init(timestamp: Date) {
                    self.timestamp = timestamp
                }
            }

            """))
        case .coreData:
            scene = "        WindowGroup {\n            ContentView()\n                .environment(\\.managedObjectContext, PersistenceController.shared.container.viewContext)\n        }\n"
            content = """
            import CoreData
            import SwiftUI

            struct ContentView: View {
                @Environment(\\.managedObjectContext) private var context
                @FetchRequest(sortDescriptors: [SortDescriptor(\\.timestamp)]) private var items: FetchedResults<Item>

                var body: some View {
                    NavigationStack {
                        List(items) { item in
                            Text(item.timestamp ?? .now, style: .time)
                        }
                        .navigationTitle("\(lit)")
                        .toolbar {
                            Button("Add") {
                                let item = Item(context: context)
                                item.timestamp = .now
                                try? context.save()
                            }
                        }
                    }
                }
            }

            """
            out.append(("\(n)/Persistence.swift", """
            import CoreData

            struct PersistenceController {
                static let shared = PersistenceController()
                let container: NSPersistentContainer

                init(inMemory: Bool = false) {
                    container = NSPersistentContainer(name: "\(lit)")
                    if inMemory {
                        container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
                    }
                    container.loadPersistentStores { _, error in
                        if let error { print("Store failed to load: \\(error)") }
                    }
                    container.viewContext.automaticallyMergesChangesFromParent = true
                }
            }

            """))
            out.append(("\(n)/\(n).xcdatamodeld/\(n).xcdatamodel/contents", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="1" systemVersion="1" minimumToolsVersion="Automatic" sourceLanguage="Swift" userDefinedModelVersionIdentifier="">
                <entity name="Item" representedClassName="Item" syncable="YES" codeGenerationType="class">
                    <attribute name="timestamp" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
                </entity>
            </model>

            """))
        }
        let module = n.map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
        if options.interface == .storyboard {
            out.insert(contentsOf: storyboardFiles(name: n, module: module), at: 0)
        } else {
            let imports = options.storage == .swiftData ? "import SwiftData\nimport SwiftUI" : "import SwiftUI"
            out.insert(("\(n)/\(t)App.swift", "\(imports)\n\n@main\nstruct \(t)App: App {\n    var body: some Scene {\n\(scene)    }\n}\n"), at: 0)
            out.insert(("\(n)/ContentView.swift", content), at: 1)
        }
        out.append(("\(n)/Assets.xcassets/Contents.json", json(#""info" : { "author" : "ycode", "version" : 1 }"#)))
        out.append(("\(n)/Assets.xcassets/AccentColor.colorset/Contents.json",
                    json(#""colors" : [ { "idiom" : "universal" } ],\#n  "info" : { "author" : "ycode", "version" : 1 }"#)))
        out.append(("\(n)/Assets.xcassets/AppIcon.appiconset/Contents.json",
                    json(#""images" : [ { "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],\#n  "info" : { "author" : "ycode", "version" : 1 }"#)))
        switch options.testing {
        case .none: break
        case .xctest:
            out.append(("\(n)Tests/\(n)Tests.swift", """
            import XCTest
            @testable import \(module)

            final class \(t)Tests: XCTestCase {
                func testExample() throws {
                    XCTAssertTrue(true)
                }
            }

            """))
        case .swiftTesting:
            out.append(("\(n)Tests/\(n)Tests.swift", """
            import Testing
            @testable import \(module)

            struct \(t)Tests {
                @Test func example() {
                    #expect(Bool(true))
                }
            }

            """))
        }
        if options.testing != .none {
            out.append(("\(n)UITests/\(n)UITests.swift", """
            import XCTest

            final class \(t)UITests: XCTestCase {
                @MainActor
                func testLaunch() throws {
                    let app = XCUIApplication()
                    app.launch()
                }
            }

            """))
        }
        return out
    }

    /// The UIKit scene-based sources, storyboards and scene-manifest Info.plist.
    static func storyboardFiles(name n: String, module: String) -> [(String, String)] {
        func board(_ id: String, _ vc: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="1" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" useSafeAreas="YES" initialViewController="Ycd-vc-\(id)">
                <scenes>
                    <scene sceneID="Ycd-sc-\(id)">
                        <objects>
                            <viewController id="Ycd-vc-\(id)"\(vc) sceneMemberID="viewController">
                                <view key="view" contentMode="scaleToFill" id="Ycd-vw-\(id)">
                                    <rect key="frame" x="0.0" y="0.0" width="393" height="852"/>
                                    <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                                    <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                                </view>
                            </viewController>
                            <placeholder placeholderIdentifier="IBFirstResponder" id="Ycd-fr-\(id)" userLabel="First Responder" sceneMemberID="firstResponder"/>
                        </objects>
                    </scene>
                </scenes>
                <resources>
                    <systemColor name="systemBackgroundColor">
                        <color white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>
                    </systemColor>
                </resources>
            </document>

            """
        }
        return [
            ("\(n)/AppDelegate.swift", """
            import UIKit

            @main
            class AppDelegate: UIResponder, UIApplicationDelegate {
                func application(_ application: UIApplication,
                                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
                    true
                }

                func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                                 options: UIScene.ConnectionOptions) -> UISceneConfiguration {
                    UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
                }
            }

            """),
            ("\(n)/SceneDelegate.swift", """
            import UIKit

            class SceneDelegate: UIResponder, UIWindowSceneDelegate {
                var window: UIWindow?
            }

            """),
            ("\(n)/ViewController.swift", """
            import UIKit

            class ViewController: UIViewController {
                override func viewDidLoad() {
                    super.viewDidLoad()
                }
            }

            """),
            ("\(n)/Base.lproj/Main.storyboard", board("001", " customClass=\"ViewController\" customModule=\"\(module)\" customModuleProvider=\"target\"")),
            ("\(n)/Base.lproj/LaunchScreen.storyboard", board("101", "")),
            ("\(n)/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>UIApplicationSceneManifest</key>
            \t<dict>
            \t\t<key>UIApplicationSupportsMultipleScenes</key>
            \t\t<false/>
            \t\t<key>UISceneConfigurations</key>
            \t\t<dict>
            \t\t\t<key>UIWindowSceneSessionRoleApplication</key>
            \t\t\t<array>
            \t\t\t\t<dict>
            \t\t\t\t\t<key>UISceneConfigurationName</key>
            \t\t\t\t\t<string>Default Configuration</string>
            \t\t\t\t\t<key>UISceneDelegateClassName</key>
            \t\t\t\t\t<string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
            \t\t\t\t\t<key>UISceneStoryboardFile</key>
            \t\t\t\t\t<string>Main</string>
            \t\t\t\t</dict>
            \t\t\t</array>
            \t\t</dict>
            \t</dict>
            </dict>
            </plist>

            """),
        ]
    }

    static func json(_ body: String) -> String { "{\n  \(body)\n}\n" }

    static func makeProject(name: String, options: ProjectOptions, tests: Bool) throws -> PBXProj {
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
        func ref(_ path: String, _ type: String) -> String {
            obj([("isa", "PBXFileReference"), ("lastKnownFileType", .string(type)), ("path", .string(path)), ("sourceTree", "<group>")])
        }
        func build(_ r: String) -> String { obj([("isa", "PBXBuildFile"), ("fileRef", .string(r))]) }
        func phase(_ isa: String, _ files: [String]) -> String {
            obj([("isa", .string(isa)), ("buildActionMask", "2147483647"), ("files", strings(files.map(build))),
                 ("runOnlyForDeploymentPostprocessing", "0")])
        }
        func product(_ path: String, _ type: String) -> String {
            obj([("isa", "PBXFileReference"), ("explicitFileType", .string(type)), ("includeInIndex", "0"),
                 ("path", .string(path)), ("sourceTree", "BUILT_PRODUCTS_DIR")])
        }
        func group(_ path: String?, _ children: [String], name: String? = nil) -> String {
            var a: [(String, PlistValue)] = [("isa", "PBXGroup"), ("children", strings(children))]
            if let name { a.append(("name", .string(name))) }
            if let path { a.append(("path", .string(path))) }
            a.append(("sourceTree", "<group>"))
            return obj(a)
        }
        let n = name
        let type = n.filter { $0.isLetter || $0.isNumber }
        let t = type.isEmpty || type.first!.isNumber ? "App" + type : type
        let appID = options.bundleIdentifier
        let device: [(String, PlistValue)] = [("TARGETED_DEVICE_FAMILY", "1,2"), ("SUPPORTED_PLATFORMS", "iphoneos iphonesimulator"),
                                              ("CODE_SIGN_STYLE", "Automatic"), ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1")]

        // App sources.
        let storyboard = options.interface == .storyboard
        var sources = storyboard
            ? ["AppDelegate.swift", "SceneDelegate.swift", "ViewController.swift"].map { ref($0, "sourcecode.swift") }
            : [ref("\(t)App.swift", "sourcecode.swift"), ref("ContentView.swift", "sourcecode.swift")]
        switch options.storage {
        case .none: break
        case .swiftData: sources.append(ref("Item.swift", "sourcecode.swift"))
        case .coreData: sources.append(ref("Persistence.swift", "sourcecode.swift"))
        }
        var appChildren = sources
        if options.storage == .coreData {
            let model = ref("\(n).xcdatamodel", "wrapper.xcdatamodel")
            let version = obj([("isa", "XCVersionGroup"), ("children", strings([model])), ("currentVersion", .string(model)),
                               ("path", .string("\(n).xcdatamodeld")), ("sourceTree", "<group>"),
                               ("versionGroupType", "wrapper.xcdatamodel")])
            sources.append(version)
            appChildren.append(version)
        }
        var resources: [String] = []
        if storyboard {
            for b in ["Main", "LaunchScreen"] {
                let base = obj([("isa", "PBXFileReference"), ("lastKnownFileType", "file.storyboard"), ("name", "Base"),
                                ("path", .string("Base.lproj/\(b).storyboard")), ("sourceTree", "<group>")])
                let v = obj([("isa", "PBXVariantGroup"), ("children", strings([base])), ("name", .string("\(b).storyboard")),
                             ("sourceTree", "<group>")])
                appChildren.append(v)
                resources.append(v)
            }
            appChildren.append(ref("Info.plist", "text.plist.xml"))
        }
        let assets = ref("Assets.xcassets", "folder.assetcatalog")
        appChildren.append(assets)
        resources.insert(assets, at: 0)
        let appProduct = product("\(n).app", "wrapper.application")
        var appSettings: [(String, PlistValue)] = [
            ("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(appID)), ("GENERATE_INFOPLIST_FILE", "YES"),
            ("INFOPLIST_KEY_UIApplicationSceneManifest_Generation", "YES"), ("INFOPLIST_KEY_UILaunchScreen_Generation", "YES"),
            ("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents", "YES"),
            ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"), ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
            ("ENABLE_PREVIEWS", "YES"), ("LD_RUNPATH_SEARCH_PATHS", .array(["$(inherited)", "@executable_path/Frameworks"])),
        ]
        if storyboard {
            let drop: Set<String> = ["INFOPLIST_KEY_UIApplicationSceneManifest_Generation", "INFOPLIST_KEY_UILaunchScreen_Generation", "ENABLE_PREVIEWS"]
            appSettings.removeAll { drop.contains($0.0) }
            appSettings += [("INFOPLIST_FILE", .string("\(n)/Info.plist")), ("INFOPLIST_KEY_UIMainStoryboardFile", "Main"),
                            ("INFOPLIST_KEY_UILaunchStoryboardName", "LaunchScreen")]
        }
        appSettings += device
        let appTarget = obj([("isa", "PBXNativeTarget"),
                             ("buildConfigurationList", .string(list([config("Debug", appSettings), config("Release", appSettings)]))),
                             ("buildPhases", strings([phase("PBXSourcesBuildPhase", sources), phase("PBXFrameworksBuildPhase", []),
                                                      phase("PBXResourcesBuildPhase", resources)])),
                             ("buildRules", strings([])), ("dependencies", strings([])), ("name", .string(n)),
                             ("productName", .string(n)), ("productReference", .string(appProduct)),
                             ("productType", "com.apple.product-type.application")])
        var groups = [group(n, appChildren)]
        var targets = [appTarget]
        var products = [appProduct]

        // Test targets.
        var testPairs: [(String, String)] = []
        if tests {
            testPairs = [("\(n)Tests", "com.apple.product-type.bundle.unit-test"), ("\(n)UITests", "com.apple.product-type.bundle.ui-testing")]
        }
        let projectID = p.makeObjectID() // reserved for the PBXProject (proxies point at it)
        for (tn, ptype) in testPairs {
            let src = ref("\(tn).swift", "sourcecode.swift")
            groups.append(group(tn, [src]))
            let prod = product("\(tn).xctest", "wrapper.cfbundle")
            products.append(prod)
            let proxy = obj([("isa", "PBXContainerItemProxy"), ("containerPortal", .string(projectID)), ("proxyType", "1"),
                             ("remoteGlobalIDString", .string(appTarget)), ("remoteInfo", .string(n))])
            let dep = obj([("isa", "PBXTargetDependency"), ("target", .string(appTarget)), ("targetProxy", .string(proxy))])
            var s: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(appID + (ptype.hasSuffix("unit-test") ? "Tests" : "UITests"))),
                                             ("GENERATE_INFOPLIST_FILE", "YES")]
            if ptype.hasSuffix("unit-test") {
                s += [("BUNDLE_LOADER", "$(TEST_HOST)"), ("TEST_HOST", .string("$(BUILT_PRODUCTS_DIR)/\(n).app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/\(n)"))]
            } else {
                s += [("TEST_TARGET_NAME", .string(n))]
            }
            s += device
            targets.append(obj([("isa", "PBXNativeTarget"),
                                ("buildConfigurationList", .string(list([config("Debug", s), config("Release", s)]))),
                                ("buildPhases", strings([phase("PBXSourcesBuildPhase", [src]), phase("PBXFrameworksBuildPhase", []),
                                                         phase("PBXResourcesBuildPhase", [])])),
                                ("buildRules", strings([])), ("dependencies", strings([dep])), ("name", .string(tn)),
                                ("productName", .string(tn)), ("productReference", .string(prod)), ("productType", .string(ptype))]))
        }
        let productsGroup = group(nil, products, name: "Products")
        let main = group(nil, groups + [productsGroup])
        let common: [(String, PlistValue)] = [("SDKROOT", "iphoneos"), ("IPHONEOS_DEPLOYMENT_TARGET", "18.0"), ("SWIFT_VERSION", "6.0"),
                                              ("ALWAYS_SEARCH_USER_PATHS", "NO")]
        let projectList = list([
            config("Debug", common + [("ONLY_ACTIVE_ARCH", "YES"), ("SWIFT_OPTIMIZATION_LEVEL", "-Onone"), ("DEBUG_INFORMATION_FORMAT", "dwarf"),
                                      ("GCC_OPTIMIZATION_LEVEL", "0"), ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
                                      ("ENABLE_TESTABILITY", "YES")]),
            config("Release", common + [("SWIFT_OPTIMIZATION_LEVEL", "-O"), ("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym"),
                                        ("VALIDATE_PRODUCT", "YES")]),
        ])
        p[projectID] = PBXObject(id: projectID, attributes: PlistDictionary([
            ("isa", "PBXProject"), ("buildConfigurationList", .string(projectList)), ("developmentRegion", "en"),
            ("hasScannedForEncodings", "0"), ("knownRegions", .array(["en", "Base"])), ("mainGroup", .string(main)),
            ("productRefGroup", .string(productsGroup)), ("projectDirPath", ""), ("projectRoot", ""), ("targets", strings(targets)),
        ]))
        p.rootObject = projectID
        return p
    }
}
