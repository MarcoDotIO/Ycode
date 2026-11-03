import Foundation
import Testing
@testable import YcodeIDECore
import YcodePlist
import YcodeProject
import YcodeWorkspace

/// The New Project model: the option form, the chooser and its memory,
/// every generator, the save step and `ycode new` (`specs/ide/templates.md`).
@Suite struct NewProjectTemplateTests {
    typealias ID = TemplateOptionID

    func tempDir(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-newproject-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func settings(_ p: PBXProj, _ target: String, _ config: String = "Debug") -> PlistDictionary? {
        guard let t = p.targets.first(where: { $0.string("name") == target }) else { return nil }
        return p.buildConfigurations(listID: t.string("buildConfigurationList")).first { $0.string("name") == config }?["buildSettings"]?.dictionary
    }

    func projectSettings(_ p: PBXProj, _ config: String = "Debug") -> PlistDictionary? {
        p.buildConfigurations(listID: p.project?.string("buildConfigurationList")).first { $0.string("name") == config }?["buildSettings"]?.dictionary
    }

    func gen(_ id: String, _ v: [String: String] = [:], name: String = "Pad") throws -> GeneratedProject {
        let d = try #require(ProjectTemplates.find(id))
        var values = [ID.productName: name, ID.organizationIdentifier: "org.ycode.tests"]
        if d.generator == "audioUnitApp" { values.merge([ID.subtypeCode: "demo", ID.manufacturerCode: "Demo", ID.organizationName: "Ycode"]) { a, _ in a } }
        return try ProjectGenerator.generate(d, d.makeForm(values.merging(v) { _, b in b }))
    }

    // MARK: Option form (§ Options step)

    @Test func bundleIdentifierAndRequiredFields() throws {
        let ios = try #require(ProjectTemplates.find("ios.app"))
        var f = ios.makeForm()
        // Rule 6: empty parts read "com.yourcompany" and "ProductName".
        #expect(f.bundleIdentifier == "com.yourcompany.ProductName" && f.isBundleIdentifierPlaceholder)
        #expect(f.issues == ["Enter a product name.", "Enter a value for Organization Identifier."])
        f.set(ID.organizationIdentifier, "org.ycode")
        #expect(f.bundleIdentifier == "org.ycode.ProductName" && !f.isNextEnabled)
        f.set(ID.productName, "My App+")
        #expect(f.value(ID.bundleIdentifier) == "org.ycode.My-App-" && f.isNextEnabled)
        f.set(ID.bundleIdentifier, "x")
        #expect(f.bundleIdentifier == "org.ycode.My-App-")
        // O': forbidden characters are removed from the organization.
        f.set(ID.organizationIdentifier, "org ycode!")
        #expect(f.bundleIdentifier == "orgycode.My-App-")
        f.set(ID.productName, "a/b")
        #expect(!f.isNextEnabled)
        // Not persisted: Product Name and the bundle identifier.
        #expect(f.persistedValues[ID.productName] == nil && f.persistedValues[ID.organizationIdentifier] == "org ycode!")
    }

    @Test func orderHiddenEnabledAndAllowedValues() throws {
        let ios = try #require(ProjectTemplates.find("iOS/App"))
        var f = ios.makeForm()
        // Rules 1 and 2: the lifecycle is hidden; Product Name, Team, Organization first.
        #expect(f.visibleFields.map(\.id) == [ID.productName, ID.team, ID.organizationIdentifier, ID.bundleIdentifier, ID.interface, ID.language,
                                              ID.testingSystem, ID.storage, ID.hostInCloudKit])
        #expect(f.value(ID.testingSystem) == "None" && f.value(ID.lifecycle) == "SwiftUI")
        // Rule 3: Host in CloudKit needs a storage; disabled it is false.
        #expect(!f.isEnabled(ID.hostInCloudKit))
        f.set(ID.hostInCloudKit, "true")
        #expect(!f.bool(ID.hostInCloudKit))
        f.set(ID.storage, "swiftdata")
        f.set(ID.hostInCloudKit, "YES")
        #expect(f.value(ID.storage) == "SwiftData" && f.bool(ID.hostInCloudKit))
        // Rule 4: Objective-C needs the Cocoa lifecycle (a storyboard); SwiftData the SwiftUI one.
        #expect(!f.isAllowed(ID.language, "Objective-C"))
        f.set(ID.interface, "Storyboard")
        #expect(f.value(ID.lifecycle) == "Cocoa" && f.isAllowed(ID.language, "Objective-C"))
        #expect(f.value(ID.storage) == "None")   // SwiftData moved to the first allowed value
        f.set(ID.language, "Objective-C")
        #expect(!f.isAllowed(ID.testingSystem, "Swift Testing"))
        // Titles are accepted as values.
        f.set(ID.testingSystem, "XCTest for Unit and UI Tests")
        #expect(f.value(ID.testingSystem) == "XCTest")
        // visionOS: the immersion style follows the renderer.
        var v = try #require(ProjectTemplates.find("visionos.app")).makeForm()
        #expect(!v.isEnabled(ID.immersiveSpace) && v.value(ID.immersiveSpace) == "None")
        v.set(ID.immersiveSpaceRenderer, "RealityKit")
        #expect(v.isEnabled(ID.immersiveSpace) && v.value(ID.immersiveSpace) == "Full" && !v.isAllowed(ID.immersiveSpace, "None"))
        // Ycode-unavailable values are drawn disabled.
        #expect(!v.isAllowed(ID.immersiveSpaceRenderer, "Metal 4"))
        // Audio Unit codes: four characters, an upper-case manufacturer letter.
        var au = try #require(ProjectTemplates.find("multiplatform.audio-unit-extension-app"))
            .makeForm([ID.productName: "Tone", ID.organizationIdentifier: "org", ID.organizationName: "Ycode", ID.subtypeCode: "demo", ID.manufacturerCode: "Demo"])
        #expect(au.isNextEnabled)
        au.set(ID.manufacturerCode, "demo")
        #expect(!au.isNextEnabled)
        au.set(ID.manufacturerCode, "Dem")
        #expect(au.issues.contains("The manufacturer code must be exactly four characters."))
    }

    @Test func projectOptionsBridge() throws {
        var o = ProjectOptions()
        o.productName = "Bridge"
        o.organizationIdentifier = "org.ycode"
        o.testing = .xctest
        o.setStorage(.coreData)
        o.hostInCloudKit = true
        var f = try #require(ProjectTemplates.find("ios.app")).makeForm()
        f.apply(o)
        #expect(ProjectOptions(form: f) == o)
    }

    // MARK: Chooser (§ Template chooser)

    @Test func tabsSectionsAndOrder() {
        #expect(ProjectTemplateCatalog.platforms == ["Multiplatform", "iOS", "macOS", "watchOS", "tvOS", "visionOS", "DriverKit", "Other"])
        func titles(_ tab: String) -> [[String]] { ProjectTemplates.sections(platform: tab).map { $0.entries.map(\.title) } }
        // The two observed lists (reference-ui-3.md §5.4).
        #expect(titles("Multiplatform") == [["App", "Document App", "Foveated Streaming App", "Game", "Audio Unit Extension App", "Safari Extension App"],
                                            ["Framework"]])
        #expect(titles("iOS") == [["App", "Document App", "Game", "Augmented Reality App", "App Playground", "Sticker Pack App", "iMessage App",
                                   "Safari Extension App"], ["Framework", "Static Library", "Metal Library"]])
        #expect(ProjectTemplates.sections(platform: "macOS").map(\.title) == ["Application", "Framework & Library", "Other"])
        #expect(titles("macOS")[2] == ["Generic Kernel Extension", "Installer Plug-in", "Instruments Package", "IOKit Driver", "Preference Pane", "Screen Saver"])
        #expect(ProjectTemplates.sections(platform: "DriverKit").map(\.title) == ["Driver", "Framework & Library"])
        #expect(titles("Other") == [["Empty", "External Build System"]])
        // Target-only templates are not offered.
        #expect(!ProjectTemplates.all.contains { $0.title == "Aggregate" || $0.title.hasSuffix("Testing Bundle") || $0.title == "Widget Extension" })
        #expect(Set(ProjectTemplates.all.map(\.id)).count == ProjectTemplates.all.count)
        // The filter: case- and diacritic-insensitive substring of the name.
        #expect(ProjectTemplates.sections(platform: "iOS", filter: "LIBRÁRY").map(\.title) == ["Framework & Library"])
        #expect(ProjectTemplates.sections(platform: "iOS", filter: "zzz").isEmpty)
        #expect(ProjectTemplates.find("Command Line Tool")?.id == "macos.command-line-tool")
        #expect(ProjectTemplates.find("game", platform: "tvOS")?.id == "tvos.game")
        // The Package… chooser.
        #expect(ProjectTemplates.packages.sections(platform: "Multiplatform").map { $0.entries.map(\.title) }
                == [["Library"], ["Empty", "Build Tool Plug-in", "Command Plug-in", "Swift Macro"]])
        #expect(ProjectTemplates.packages.templates(platform: "macOS").map(\.defaultSaveName) == ["MyTool", "MyExecutable"])
    }

    @Test func flowStepsAndMemory() throws {
        var m = NewProjectFlowModel(platform: "iOS")
        #expect(m.step == .template && m.selected?.id == "ios.app" && !m.isPreviousEnabled && m.isNextEnabled)
        _ = m.select("Game")
        #expect(m.selected?.id == "ios.game")
        m.setPlatform("macOS")
        #expect(m.selected?.id == "macos.app")
        m.setPlatform("iOS")
        #expect(m.selected?.id == "ios.game")   // the tab's remembered template
        m.setFilter("zzz")
        #expect(m.selected == nil && !m.isNextEnabled && m.templateCaption == "No templates match “zzz”.")
        m.setFilter("lib")
        #expect(m.selected?.id == "ios.static-library" || m.selected?.id == "ios.metal-library")
        m.setFilter("")
        m.setPlatform("Multiplatform")
        _ = m.select("Foveated Streaming App")
        #expect(m.selected?.id == "multiplatform.foveated-streaming-app" && !m.isNextEnabled && m.templateCaption.hasPrefix("Ycode cannot"))
        _ = m.select("multiplatform.app")
        #expect(m.selected?.id == "multiplatform.app")
        _ = m.next()
        #expect(m.step == .options && m.isPreviousEnabled && !m.isNextEnabled)
        m.setOption(ID.productName, "Carry")
        m.setOption(ID.organizationIdentifier, "org.carry")
        m.setOption(ID.testingSystem, "Swift Testing")
        let toSave = m.next()
        #expect(toSave)
        m.previous()
        _ = m.select("macos.framework")
        #expect(m.selected?.id == "macos.framework")
        // Shared values: Organization, Testing System and the name carry over.
        #expect(m.form.organizationIdentifier == "org.carry" && m.form.value(ID.testingSystem) == "Swift Testing" && m.form.productName == "Carry")
        m.jump(to: "macos.command-line-tool")
        #expect(m.step == .options && m.selected?.id == "macos.command-line-tool")
        #expect(NewProjectPicker.templateID(forRow: 1) == "macos.command-line-tool" && NewProjectPicker.templateID(forRow: 0) == nil)
    }

    @Test func flowPersistence() throws {
        let suite = "ycode-newproject-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var m = NewProjectFlowModel(defaults: d)
        #expect(m.platform == "Multiplatform" && m.selected?.id == "multiplatform.app")
        _ = m.select("watchos.app")
        m.setOption(ID.organizationIdentifier, "org.remembered")
        m.setOption(ID.testingSystem, "XCTest")
        m.setOption(ID.productName, "NotKept")
        m.remember(in: d)
        #expect(d.string(forKey: "YcodeNewProjectTemplate.watchOS") == "Application/App")
        let again = NewProjectFlowModel(defaults: d)
        #expect(again.platform == "watchOS" && again.selected?.id == "watchos.app")
        #expect(again.form.organizationIdentifier == "org.remembered" && again.form.value(ID.testingSystem) == "XCTest" && again.form.productName.isEmpty)
        // A persisted value no longer allowed falls back to the default.
        var objc = NewProjectFlowModel(defaults: d)
        _ = objc.select("ios.framework")
        objc.setOption(ID.language, "Objective-C")
        objc.remember(in: d)
        var back = NewProjectFlowModel(defaults: d)
        _ = back.select("ios.app")
        #expect(back.form.value(ID.language) == "Swift")
        NewProjectPicker.remember(row: 2, in: d)
        #expect(NewProjectPicker.lastRow(d) == 2)
    }

    // MARK: Generators (§ Template catalog)

    /// Every available template with each pop-up value it allows.
    static var cases: [(String, [String: String])] {
        var out: [(String, [String: String])] = []
        for d in ProjectTemplates.all where d.isAvailable {
            out.append((d.id, [:]))
            for f in d.fields where f.id != ID.team && f.forcedValue == nil {
                for c in f.choices.dropFirst() where c.unavailableReason == nil { out.append((d.id, [f.id: c.value])) }
                if f.kind == .checkbox { out.append((d.id, [f.id: f.defaultValue == "true" ? "false" : "true"])) }
            }
        }
        return out
    }

    @Test func everyTemplateGeneratesARoundTrippingProject() throws {
        for (id, values) in Self.cases {
            let g = try gen(id, values, name: "Demo Kit")
            if let entry = g.entryFile { #expect(g.contents(entry) != nil, "\(id): entry \(entry)") }
            for (path, text) in g.files where path.hasSuffix(".swift") && !path.hasSuffix("Package.swift") { #expect(!text.hasPrefix("//") || text.hasPrefix("///"), "\(id): \(path)") }
            guard let p = g.project else {
                #expect(g.contents("Package.swift") != nil, "\(id)")
                continue
            }
            let text = p.serialized(projectName: g.projectName)
            let back = try PBXProj(parsing: text)
            #expect(back.serialized(projectName: g.projectName) == text, "\(id) \(values)")
            #expect(back.objectVersion == "77" && back.project?.string("preferredProjectObjectVersion") == "77")
            #expect(projectSettings(back)?["CLANG_WARN_UNREACHABLE_CODE"]?.string == "YES", "\(id)")
            for t in back.targets {
                let name = t.string("name") ?? ""
                // Every target signs automatically; Swift targets get the Swift settings.
                if t.isa == "PBXNativeTarget" { #expect(settings(back, name)?["CODE_SIGN_STYLE"]?.string == "Automatic", "\(id): \(name)") }
                if let v = settings(back, name)?["SWIFT_VERSION"]?.string {
                    #expect(["5.0", "6.0"].contains(v) && settings(back, name)?["SWIFT_APPROACHABLE_CONCURRENCY"]?.string == "YES")
                }
                // Every synchronized folder exists in the generated files.
                for f in t.references("fileSystemSynchronizedGroups") {
                    let path = try #require(back[f]?.string("path"))
                    #expect(g.files.contains { $0.0.hasPrefix(path + "/") }, "\(id): folder \(path)")
                }
                if let bid = settings(back, name)?["PRODUCT_BUNDLE_IDENTIFIER"]?.string {
                    #expect(bid.hasPrefix("org.ycode.tests.Demo-Kit"), "\(id): \(bid)")
                }
                // Build phases stay empty unless they embed or link.
                for ph in back.buildPhases(ofTarget: t.id) where ph.isa == "PBXSourcesBuildPhase" || ph.isa == "PBXResourcesBuildPhase" {
                    #expect(ph.references("files").isEmpty, "\(id): \(name) \(ph.isa)")
                }
            }
            // An Info.plist in a synchronized folder has a membership exception.
            for (path, _) in g.files where path.hasSuffix("/Info.plist") {
                let folder = String(path.dropLast("/Info.plist".count))
                let group = back.objects.values.first { $0.isa == "PBXFileSystemSynchronizedRootGroup" && $0.string("path") == folder }
                if let group { #expect(!group.references("exceptions").isEmpty, "\(id): \(path)") }
            }
        }
    }

    @Test func iOSAppFollowsTheCatalog() throws {
        for i in ["SwiftUI", "Storyboard"] {
            for t in ["None", "XCTest", "Swift Testing"] {
                for s in ["None", "SwiftData", "Core Data"] {
                    let g = try gen("ios.app", [ID.interface: i, ID.testingSystem: t, ID.storage: s], name: "Spec App")
                    let p = try #require(g.project)
                    let swiftTesting = t == "Swift Testing" && i == "SwiftUI" || t == "Swift Testing"
                    _ = swiftTesting
                    #expect(p.targets.compactMap { $0.string("name") } == (t == "None" ? ["Spec App"] : ["Spec App", "Spec AppTests", "Spec AppUITests"]))
                    let app = try #require(settings(p, "Spec App"))
                    #expect(app["PRODUCT_BUNDLE_IDENTIFIER"]?.string == "org.ycode.tests.Spec-App")
                    #expect(app["SWIFT_VERSION"]?.string == "5.0" && app["SWIFT_DEFAULT_ACTOR_ISOLATION"]?.string == "MainActor")
                    #expect(app["SUPPORTED_PLATFORMS"] == nil && app["STRING_CATALOG_GENERATE_SYMBOLS"]?.string == "YES")
                    #expect(app["INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad"] != nil)
                    #expect(projectSettings(p)?["SDKROOT"]?.string == "iphoneos" && projectSettings(p)?["IPHONEOS_DEPLOYMENT_TARGET"] != nil)
                    #expect(projectSettings(p, "Release")?["VALIDATE_PRODUCT"]?.string == "YES")
                    // T: the C-identifier form ("My App" → My_AppApp.swift).
                    #expect(g.paths.contains("Spec App/Spec_AppApp.swift") == (i == "SwiftUI"))
                    #expect(g.paths.contains("Spec App/Base.lproj/Main.storyboard") == (i == "Storyboard"))
                    let storage = i == "Storyboard" && s == "SwiftData" ? "None" : s
                    #expect(g.paths.contains("Spec App/Item.swift") == (storage == "SwiftData"))
                    #expect(g.paths.contains("Spec App/Spec_App.xcdatamodeld/Spec_App.xcdatamodel/contents") == (storage == "Core Data"))
                    if t != "None" {
                        let unit = try #require(settings(p, "Spec AppTests"))
                        #expect(unit["PRODUCT_BUNDLE_IDENTIFIER"]?.string == "org.ycode.tests.Spec-AppTests")
                        #expect(unit["TEST_HOST"]?.string == "$(BUILT_PRODUCTS_DIR)/Spec App.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Spec App")
                        #expect(unit["IPHONEOS_DEPLOYMENT_TARGET"] != nil && settings(p, "Spec AppUITests")?["IPHONEOS_DEPLOYMENT_TARGET"] == nil)
                        #expect(unit["SWIFT_EMIT_LOC_STRINGS"]?.string == "NO")
                        let test = try #require(g.contents("Spec AppTests/Spec_AppTests.swift"))
                        #expect(test.contains(t == "XCTest" ? "import XCTest" : "import Testing"))
                    }
                }
            }
        }
        // Host in CloudKit: entitlements and an Info.plist with remote notifications.
        let cloud = try gen("ios.app", [ID.storage: "SwiftData", ID.hostInCloudKit: "true"])
        #expect(cloud.contents("Pad/Pad.entitlements")?.contains("com.apple.developer.icloud-services") == true)
        #expect(cloud.contents("Pad/Info.plist")?.contains("remote-notification") == true)
        #expect(settings(cloud.project!, "Pad")?["CODE_SIGN_ENTITLEMENTS"]?.string == "Pad/Pad.entitlements")
    }

    @Test func generatorsWriteTheCatalogsTargetsAndSettings() throws {
        func types(_ g: GeneratedProject) -> [String] { g.project!.targets.map { $0.string("productType") ?? $0.isa } }
        func names(_ g: GeneratedProject) -> [String] { g.project!.targets.compactMap { $0.string("name") } }
        // Multiplatform App: SDK auto per target, no project SDK.
        let mp = try gen("multiplatform.app")
        #expect(settings(mp.project!, "Pad")?["SDKROOT"]?.string == "auto" && projectSettings(mp.project!)?["SDKROOT"] == nil)
        #expect(settings(mp.project!, "Pad")?["INFOPLIST_KEY_UIStatusBarStyle[sdk=iphoneos*]"]?.string == "UIStatusBarStyleDefault")
        // Tests carry TestTargetID (the autocreated scheme's testables); attributes record the tools version.
        let tests = try gen("macos.app", [ID.testingSystem: "XCTest"])
        let attrs = tests.project!.project?["attributes"]?.dictionary
        #expect(attrs?["LastUpgradeCheck"]?.string == ProjectRecipe.toolsVersionDigits)
        let appID = tests.project!.targets[0].id
        #expect(tests.project!.targets.dropFirst().allSatisfy { attrs?["TargetAttributes"]?.dictionary?[$0.id]?.dictionary?["TestTargetID"]?.string == appID })
        #expect(settings(tests.project!, "PadTests")?["TEST_HOST"]?.string == "$(BUILT_PRODUCTS_DIR)/Pad.app/Contents/MacOS/Pad")
        // macOS App interfaces.
        #expect(try gen("macos.app", [ID.interface: "XIB"]).paths.contains("Pad/Base.lproj/MainMenu.xib"))
        #expect(settings(try gen("macos.app", [ID.interface: "Storyboard"]).project!, "Pad")?["INFOPLIST_KEY_NSMainStoryboardFile"]?.string == "Main")
        #expect(try gen("macos.app", [ID.interface: "XIB", ID.language: "Objective-C"]).paths.contains("Pad/main.m"))
        // Document apps: Swift 6.0, an imported type in Info.plist.
        let doc = try gen("macos.document-app")
        #expect(doc.contents("Pad/Info.plist")?.contains("UTImportedTypeDeclarations") == true)
        #expect(settings(doc.project!, "Pad")?["SWIFT_VERSION"]?.string == "6.0" && settings(doc.project!, "Pad")?["ENABLE_USER_SELECTED_FILES"]?.string == "readwrite")
        #expect(try gen("macos.document-app", [ID.interface: "XIB", ID.documentStorage: "Core Data"]).paths.contains("Pad/Document.xcdatamodeld/Document.xcdatamodel/contents"))
        // Games: iOS uses the UIKit lifecycle; multiplatform non-RealityKit is multi-SDK.
        let iosGame = try gen("ios.game", [ID.gameTechnology: "Metal"])
        #expect(iosGame.paths.contains("Pad/Shaders.metal") && settings(iosGame.project!, "Pad")?["INFOPLIST_KEY_UIRequiredDeviceCapabilities"]?.string == "metal")
        let mpGame = try gen("multiplatform.game", [ID.gameTechnology: "SpriteKit"])
        #expect(names(mpGame) == ["Pad iOS", "Pad tvOS", "Pad macOS"] && projectSettings(mpGame.project!)?["SDKROOT"] == nil)
        #expect(settings(mpGame.project!, "Pad tvOS")?["SDKROOT"]?.string == "appletvos")
        #expect(settings(mpGame.project!, "Pad iOS", "Release")?["VALIDATE_PRODUCT"]?.string == "YES")
        #expect(try gen("multiplatform.game").project!.targets.count == 1)
        // watchOS: the container or the companion app, both embedding the watch app.
        let only = try gen("watchos.app")
        #expect(types(only) == ["com.apple.product-type.application.watchapp2-container", "com.apple.product-type.application"])
        #expect(settings(only.project!, "Pad Watch App")?["INFOPLIST_KEY_WKWatchOnly"]?.string == "YES")
        #expect(settings(only.project!, "Pad Watch App")?["PRODUCT_BUNDLE_IDENTIFIER"]?.string == "org.ycode.tests.Pad.watchkitapp")
        let pair = try gen("watchos.app", [ID.watchAppType: "Watch App with New Companion iOS App", ID.testingSystem: "XCTest"])
        #expect(names(pair) == ["Pad", "Pad Watch App", "Pad Watch AppTests", "Pad Watch AppUITests"])
        #expect(settings(pair.project!, "Pad Watch App")?["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"]?.string == "org.ycode.tests.Pad")
        let embed = pair.project!.objects.values.first { $0.isa == "PBXCopyFilesBuildPhase" && $0.string("name") == "Embed Watch Content" }
        #expect(embed?.string("dstPath") == "$(CONTENTS_FOLDER_PATH)/Watch" && embed?.string("dstSubfolderSpec") == "16")
        // visionOS: the scene manifest follows the scene and immersion; tests are unit only.
        let full = try gen("visionos.app", [ID.immersiveSpaceRenderer: "RealityKit", ID.immersiveSpace: "Progressive", ID.testingSystem: "XCTest"])
        #expect(full.contents("Pad/PadApp.swift")?.contains(".immersionStyle(selection: .constant(.progressive), in: .progressive)") == true)
        #expect(full.contents("Pad/Info.plist")?.contains("UIImmersionStyleProgressive") == true && names(full) == ["Pad", "PadTests"])
        #expect(try gen("visionos.app", [ID.initialScene: "Volume"]).contents("Pad/Info.plist")?.contains("UIWindowSceneSessionRoleVolumetricApplication") == true)
        #expect(try gen("visionos.app", [ID.immersiveSpaceRenderer: "Metal"]).paths.contains("Pad/ShaderTypes.h"))
        // Libraries and tools.
        let fw = try gen("ios.framework", [ID.testingSystem: "Swift Testing"])
        #expect(types(fw) == ["com.apple.product-type.framework", "com.apple.product-type.bundle.unit-test"] && fw.paths.contains("Pad/Pad.docc/Pad.md"))
        #expect(projectSettings(fw.project!)?["VERSIONING_SYSTEM"]?.string == "apple-generic")
        #expect(try gen("ios.static-library").project!.objects.values.contains { $0.isa == "PBXCopyFilesBuildPhase" && $0.string("dstPath") == "include/$(PRODUCT_NAME)" })
        #expect(types(try gen("macos.library", [ID.libraryType: "Static"])) == ["com.apple.product-type.library.static"])
        #expect(try gen("macos.library", [ID.libraryFramework: "STL"]).paths == ["Pad/Pad.cpp", "Pad/Pad.hpp", "Pad/PadPriv.hpp"])
        #expect(try gen("macos.command-line-tool", [ID.language: "C++"]).paths == ["Pad/main.cpp"])
        #expect(types(try gen("macos.xpc-service")) == ["com.apple.product-type.xpc-service"])
        #expect(settings(try gen("macos.bundle", [ID.bundleExtension: "plugin"]).project!, "Pad")?["WRAPPER_EXTENSION"]?.string == "plugin")
        #expect(settings(try gen("macos.screen-saver").project!, "Pad")?["INFOPLIST_KEY_NSPrincipalClass"]?.string == "PadView")
        // Extensions are embedded in their app.
        let safari = try gen("multiplatform.safari-extension-app")
        #expect(names(safari) == ["Pad (iOS)", "Pad Extension (iOS)", "Pad (macOS)", "Pad Extension (macOS)"])
        #expect(safari.entryFile == "Shared (Extension)/Resources/manifest.json")
        #expect(types(try gen("ios.imessage-app")) == ["com.apple.product-type.application.messages", "com.apple.product-type.app-extension.messages"])
        #expect(types(try gen("ios.sticker-pack-app")).last == "com.apple.product-type.app-extension.messages-sticker-pack")
        #expect(try gen("multiplatform.audio-unit-extension-app", [ID.audioUnitType: "Effect"]).contents("PadExtension/Info.plist")?.contains("<string>aufx</string>") == true)
        #expect(types(try gen("driverkit.driver")) == ["com.apple.product-type.driver-extension"])
        #expect(projectSettings(try gen("driverkit.driver").project!)?["SDKROOT"]?.string == "driverkit")
        // Packages are SwiftPM's (`swift package init`); the playground is Ycode's own.
        let pkg = try gen("package.library", [ID.testingSystem: "Swift Testing"])
        #expect(pkg.packageInit?.type == "library" && pkg.packageInit?.arguments == ["--disable-xctest", "--enable-swift-testing"])
        #expect(try gen("ios.app-playground").folderName == "Pad.swiftpm")
        // The Other tab.
        #expect(try gen("other.empty").project!.targets.isEmpty)
        #expect(try gen("other.external-build-system").project!.targets.first?.string("buildToolPath") == "/usr/bin/make")
        let fov = try #require(ProjectTemplates.find("multiplatform.foveated-streaming-app"))
        #expect(throws: ProjectGeneratorError.self) { try ProjectGenerator.generate(fov, fov.makeForm([ID.productName: "X", ID.organizationIdentifier: "o"])) }
    }

    // MARK: Save step and CLI

    static let gitEnv = ["GIT_AUTHOR_NAME": "Ycode Tests", "GIT_AUTHOR_EMAIL": "tests@ycode.invalid",
                         "GIT_COMMITTER_NAME": "Ycode Tests", "GIT_COMMITTER_EMAIL": "tests@ycode.invalid", "GIT_CONFIG_NOSYSTEM": "1"]

    @Test func saveStepWritesGitAndAddsToAWorkspaceAndProject() throws {
        let dir = try tempDir("save")
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = try #require(ProjectTemplates.find("macos.command-line-tool"))
        let form = d.makeForm([ID.productName: "Tool", ID.organizationIdentifier: "org.ycode"])
        let ws = dir.appendingPathComponent("All.xcworkspace")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("libs"), withIntermediateDirectories: true)
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Workspace\n   version = \"1.0\">\n   <Group\n      location = \"group:libs\"\n      name = \"libs\">\n   </Group>\n</Workspace>\n"
            .write(to: ws.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
        #expect(NewProjectCreator.groups(in: ws).map(\.title) == ["All", "libs"])
        var save = NewProjectSaveOptions(location: dir.appendingPathComponent("libs"), saveAs: "Folder", createGitRepository: true, addTo: ws, group: "group:libs")
        save.team = "ABCDE12345"
        let created = try NewProjectCreator.create(d, form, save: save, gitEnvironment: Self.gitEnv)
        #expect(created.openURL.path.hasSuffix("libs/Folder/Tool.xcodeproj") && created.entryFile?.lastPathComponent == "main.swift")
        #expect(created.gitWarning == nil)
        // One commit "Initial Commit", no .gitignore, the embedded workspace written.
        let log = try YcodeSubprocessRun.git(["log", "--format=%s"], in: created.folder)
        #expect(log == "Initial Commit")
        #expect(!FileManager.default.fileExists(atPath: created.folder.appendingPathComponent(".gitignore").path))
        #expect(FileManager.default.fileExists(atPath: created.openURL.appendingPathComponent("project.xcworkspace/contents.xcworkspacedata").path))
        let p = try PBXProj(contentsOf: created.openURL.appendingPathComponent("project.pbxproj"))
        #expect(settings(p, "Tool")?["DEVELOPMENT_TEAM"]?.string == "ABCDE12345")
        let wsText = try String(contentsOf: ws.appendingPathComponent("contents.xcworkspacedata"), encoding: .utf8)
        #expect(wsText.contains("location = \"group:Folder/Tool.xcodeproj\""), "\(wsText)")
        #expect(try Workspace(contentsOf: ws.path).projectPaths.first?.hasSuffix("libs/Folder/Tool.xcodeproj") == true)
        // Add to a project: a new workspace holding both.
        let other = try #require(ProjectTemplates.find("other.empty"))
        let added = try NewProjectCreator.create(other, other.makeForm([ID.productName: "Second"]),
                                                 save: NewProjectSaveOptions(location: dir, createGitRepository: false, addTo: created.openURL))
        #expect(added.addedTo?.pathExtension == "xcworkspace")
        #expect(try Workspace(contentsOf: added.addedTo!.path).projectPaths.count == 2)
        // A project inside a Git work tree gets no repository of its own.
        let inner = try NewProjectCreator.create(other, other.makeForm([ID.productName: "Inner"]),
                                                 save: NewProjectSaveOptions(location: created.folder, createGitRepository: true), gitEnvironment: Self.gitEnv)
        #expect(!FileManager.default.fileExists(atPath: inner.folder.appendingPathComponent(".git").path))
        // Creating again into a non-empty folder fails.
        #expect(throws: NewFileError.self) {
            try NewProjectCreator.create(other, other.makeForm([ID.productName: "Second"]), save: NewProjectSaveOptions(location: dir, createGitRepository: false))
        }
    }

    @Test func cliCreatesListsAndValidates() throws {
        let dir = try tempDir("cli")
        defer { try? FileManager.default.removeItem(at: dir) }
        var out: [String] = [], err: [String] = []
        let status = NewProjectCLI.run(["--template", "ios.app", "--name", "Cli", "--org", "org.ycode", "--option", "storageType=SwiftData",
                                        "--option", "Testing System=XCTest for Unit and UI Tests", "--git", dir.path],
                                       out: { out.append($0) }, err: { err.append($0) }, gitEnvironment: Self.gitEnv)
        #expect(status == 0, "\(err)")
        #expect(out.last?.hasSuffix("Cli/Cli.xcodeproj") == true)
        let p = try PBXProj(contentsOf: dir.appendingPathComponent("Cli/Cli.xcodeproj/project.pbxproj"))
        #expect(p.targets.count == 3)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Cli/Cli/Item.swift").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Cli/.git").path))
        #expect(NewProjectCLI.run(["--template", "Game", "--platform", "tvOS", "--name", "TV", "--org", "o", dir.path], out: { out.append($0) },
                                  err: { err.append($0) }) == 0)
        #expect(NewProjectCLI.run(["--template", "ios.app", "--name", "Bad", "--org", "o", "--option", "storageType=Realm", dir.path],
                                  out: { _ in }, err: { err.append($0) }) == 1)
        #expect(err.last?.contains("Storage is one of") == true)
        #expect(NewProjectCLI.run(["--template", "ios.app", "--org", "o", dir.path], out: { _ in }, err: { err.append($0) }) == 1)
        #expect(err.last?.contains("Enter a product name.") == true)
        out = []
        #expect(NewProjectCLI.run(["--list", "--json"], out: { out.append($0) }, err: { _ in }) == 0)
        let list = try JSONSerialization.jsonObject(with: Data(out.joined().utf8)) as? [[String: Any]]
        #expect(list?.count == ProjectTemplates.all.count + ProjectTemplates.packages.templates.count)
    }
}

/// `git` for tests.
enum YcodeSubprocessRun {
    static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
