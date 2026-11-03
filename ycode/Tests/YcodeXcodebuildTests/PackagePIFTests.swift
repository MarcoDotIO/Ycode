import Foundation
import Testing
import YcodeBuild
@testable import YcodeXcodebuild

// Package products, macros' and plug-ins' PIF (specs/ide/build-pif.md
// §Package products). Fixtures are written at test time.

/// A project whose tool target `App` links a local package's static and
/// dynamic products (and optionally a remote package's product), applies a
/// build-tool plug-in (`plugin:GenPlugin`, no `package` key, as open-source
/// generators write it), and whose application target `Shell` links the
/// dynamic product only. IDs are arbitrary.
func packageProjectText(remote: Bool = true, plugin: Bool = true, shell: Bool = true) -> String {
    var o: [String] = []
    func id(_ n: Int) -> String { String(format: "C1%022d", n) }
    var refs = [id(50)]
    if remote { refs.append(id(51)) }
    if plugin { refs.append(id(52)) }
    var targets = [id(20)]
    if shell { targets.append(id(70)) }
    o.append("\(id(1)) = {isa = PBXProject; buildConfigurationList = \(id(60)); developmentRegion = en; knownRegions = (en, Base); mainGroup = \(id(2)); packageReferences = (\(refs.joined(separator: ", "))); productRefGroup = \(id(4)); projectDirPath = \"\"; projectRoot = \"\"; targets = (\(targets.joined(separator: ", "))); };")
    o.append("\(id(2)) = {isa = PBXGroup; children = (\(id(3)), \(id(4))); sourceTree = \"<group>\"; };")
    o.append("\(id(3)) = {isa = PBXGroup; children = (\(id(10)), \(id(11))); path = App; sourceTree = \"<group>\"; };")
    o.append("\(id(4)) = {isa = PBXGroup; children = (\(id(12)), \(id(77))); name = Products; sourceTree = \"<group>\"; };")
    o.append("\(id(10)) = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = \"<group>\"; };")
    o.append("\(id(11)) = {isa = PBXFileReference; lastKnownFileType = text; path = Msg.gen; sourceTree = \"<group>\"; };")
    o.append("\(id(12)) = {isa = PBXFileReference; explicitFileType = \"compiled.mach-o.executable\"; includeInIndex = 0; path = App; sourceTree = BUILT_PRODUCTS_DIR; };")
    var products = [id(30), id(31)]
    if remote { products.append(id(32)) }
    var linked = [id(41), id(42)]
    if remote { linked.append(id(43)) }
    o.append("\(id(20)) = {isa = PBXNativeTarget; buildConfigurationList = \(id(21)); buildPhases = (\(id(22)), \(id(23)), \(id(24))); buildRules = (); dependencies = (\(plugin ? id(25) : "")); name = App; packageProductDependencies = (\(products.joined(separator: ", "))); productName = App; productReference = \(id(12)); productType = \"com.apple.product-type.tool\"; };")
    o.append("\(id(21)) = {isa = XCConfigurationList; buildConfigurations = (\(id(26)), \(id(27))); defaultConfigurationName = Release; };")
    let toolSettings = "PRODUCT_NAME = \"$(TARGET_NAME)\"; SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; SWIFT_VERSION = 5.0; LD_RUNPATH_SEARCH_PATHS = \"@executable_path\"; CODE_SIGN_STYLE = Automatic;"
    o.append("\(id(26)) = {isa = XCBuildConfiguration; buildSettings = {\(toolSettings)}; name = Debug; };")
    o.append("\(id(27)) = {isa = XCBuildConfiguration; buildSettings = {\(toolSettings)}; name = Release; };")
    o.append("\(id(22)) = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\(id(40))); runOnlyForDeploymentPostprocessing = 0; };")
    o.append("\(id(23)) = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\(linked.joined(separator: ", "))); runOnlyForDeploymentPostprocessing = 0; };")
    o.append("\(id(24)) = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (\(plugin ? id(44) : "")); runOnlyForDeploymentPostprocessing = 0; };")
    if plugin {
        o.append("\(id(25)) = {isa = PBXTargetDependency; productRef = \(id(33)); };")
        o.append("\(id(33)) = {isa = XCSwiftPackageProductDependency; productName = \"plugin:GenPlugin\"; };")
        o.append("\(id(52)) = {isa = XCLocalSwiftPackageReference; relativePath = Gen; };")
        o.append("\(id(44)) = {isa = PBXBuildFile; fileRef = \(id(11)); };")
    }
    o.append("\(id(30)) = {isa = XCSwiftPackageProductDependency; package = \(id(50)); productName = Kit; };")
    o.append("\(id(31)) = {isa = XCSwiftPackageProductDependency; package = \(id(50)); productName = KitDyn; };")
    o.append("\(id(40)) = {isa = PBXBuildFile; fileRef = \(id(10)); };")
    o.append("\(id(41)) = {isa = PBXBuildFile; productRef = \(id(30)); };")
    o.append("\(id(42)) = {isa = PBXBuildFile; productRef = \(id(31)); };")
    o.append("\(id(50)) = {isa = XCLocalSwiftPackageReference; relativePath = Kit; };")
    if remote {
        o.append("\(id(32)) = {isa = XCSwiftPackageProductDependency; package = \(id(51)); productName = RemoteThing; };")
        o.append("\(id(43)) = {isa = PBXBuildFile; productRef = \(id(32)); };")
        o.append("\(id(51)) = {isa = XCRemoteSwiftPackageReference; repositoryURL = \"https://example.invalid/team/remote-kit.git\"; requirement = {kind = upToNextMajorVersion; minimumVersion = 1.0.0; }; };")
    }
    if shell {
        o.append("\(id(70)) = {isa = PBXNativeTarget; buildConfigurationList = \(id(74)); buildPhases = (\(id(71))); buildRules = (); dependencies = (); name = Shell; packageProductDependencies = (\(id(73))); productName = Shell; productReference = \(id(77)); productType = \"com.apple.product-type.application\"; };")
        o.append("\(id(71)) = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\(id(72))); runOnlyForDeploymentPostprocessing = 0; };")
        o.append("\(id(72)) = {isa = PBXBuildFile; productRef = \(id(73)); };")
        o.append("\(id(73)) = {isa = XCSwiftPackageProductDependency; package = \(id(50)); productName = KitDyn; };")
        o.append("\(id(74)) = {isa = XCConfigurationList; buildConfigurations = (\(id(75)), \(id(76))); defaultConfigurationName = Release; };")
        o.append("\(id(75)) = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = Shell; SDKROOT = iphoneos; }; name = Debug; };")
        o.append("\(id(76)) = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = Shell; SDKROOT = iphoneos; }; name = Release; };")
        o.append("\(id(77)) = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Shell.app; sourceTree = BUILT_PRODUCTS_DIR; };")
    }
    o.append("\(id(60)) = {isa = XCConfigurationList; buildConfigurations = (\(id(61)), \(id(62))); defaultConfigurationName = Debug; };")
    o.append("\(id(61)) = {isa = XCBuildConfiguration; buildSettings = {ONLY_ACTIVE_ARCH = YES; }; name = Debug; };")
    o.append("\(id(62)) = {isa = XCBuildConfiguration; buildSettings = {}; name = Release; };")
    return "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n"
        + o.map { "\t\t" + $0 }.joined(separator: "\n") + "\n\t};\n\trootObject = \(id(1));\n}\n"
}

/// The local packages of the fixture: `Kit` (a static product with a
/// resource, a dynamic product) and `Gen` (a build-tool plug-in for package
/// and project targets that turns `<Name>.gen` into `enum <Name> { static
/// let text }`).
func writePackageFixture(remote: Bool = false, plugin: Bool = true, shell: Bool = false) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("ycode-pif-pkg-\(UUID().uuidString)")
    func write(_ text: String, _ path: String) throws {
        let url = dir.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try write(packageProjectText(remote: remote, plugin: plugin, shell: shell), "Pkgs.xcodeproj/project.pbxproj")
    try write("""
    import Kit
    import KitDynCore
    print("kit: \\(Kit.greeting); dyn: \\(KitDynCore.value)\(plugin ? "; gen: \\(Msg.text)" : "")")

    """, "App/main.swift")
    try write("generated by the project plug-in\n", "App/Msg.gen")
    try write("""
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(name: "Kit", platforms: [.macOS(.v14), .iOS(.v17)],
        products: [.library(name: "Kit", targets: ["Kit"]), .library(name: "KitDyn", type: .dynamic, targets: ["KitDynCore"])],
        targets: [.target(name: "Kit", resources: [.process("Resources")]), .target(name: "KitDynCore")])

    """, "Kit/Package.swift")
    try write("""
    import Foundation
    public enum Kit {
        public static var greeting: String {
            (Bundle.module.url(forResource: "greeting", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "missing")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    """, "Kit/Sources/Kit/Kit.swift")
    try write("from the resource bundle\n", "Kit/Sources/Kit/Resources/greeting.txt")
    try write("public enum KitDynCore { public static let value = 7 }\n", "Kit/Sources/KitDynCore/KitDynCore.swift")
    if plugin {
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Gen", platforms: [.macOS(.v14)],
            products: [.plugin(name: "GenPlugin", targets: ["GenPlugin"])],
            targets: [.executableTarget(name: "gen-tool"),
                      .plugin(name: "GenPlugin", capability: .buildTool(), dependencies: ["gen-tool"])])

        """, "Gen/Package.swift")
        try write("""
        import Foundation
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let text = (try? String(contentsOf: input, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = input.deletingPathExtension().lastPathComponent
        try! "enum \\(name) { static let text = \\"\\(text)\\" }\\n".write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)

        """, "Gen/Sources/gen-tool/main.swift")
        try write("""
        import Foundation
        import PackagePlugin

        @main struct GenPlugin: BuildToolPlugin {
            func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] { [] }
        }

        #if canImport(XcodeProjectPlugin)
        import XcodeProjectPlugin
        extension GenPlugin: XcodeBuildToolPlugin {
            func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
                let tool = try context.tool(named: "gen-tool")
                return target.inputFiles.map(\\.url).filter { $0.pathExtension == "gen" }.map { input in
                    let output = context.pluginWorkDirectoryURL.appending(path: input.deletingPathExtension().lastPathComponent + ".swift")
                    return .buildCommand(displayName: "Generating \\(output.lastPathComponent)", executable: tool.url,
                                         arguments: [input.path, output.path], inputFiles: [input], outputFiles: [output])
                }
            }
        }
        #endif

        """, "Gen/Plugins/GenPlugin/GenPlugin.swift")
    }
    return dir.appendingPathComponent("Pkgs.xcodeproj")
}

/// SwiftPM-shaped package PIF (`swift package dump-pif`) for the fixture's
/// packages, with the generated root and the aggregate project.
func cannedPackagePIF(kitDirectory: String, remoteDirectory: String, root: String) -> Data {
    func target(_ guid: String, _ name: String, type: String = "standard", productType: String? = nil) -> [String: Any] {
        var c: [String: Any] = ["guid": guid, "name": name, "type": type]
        if let productType { c["productTypeIdentifier"] = productType }
        return ["signature": "sig-" + guid, "type": "target", "contents": c]
    }
    func project(_ guid: String, _ dir: String, _ targets: [String]) -> [String: Any] {
        ["signature": "sig-" + guid, "type": "project",
         "contents": ["guid": guid, "projectDirectory": dir, "path": dir + "/Package.swift", "targets": targets.map { "sig-" + $0 }]]
    }
    let objects: [[String: Any]] = [
        ["signature": "ws", "type": "workspace", "contents": ["guid": "Workspace:" + root, "projects": [String]()]],
        project("PACKAGE:kit", kitDirectory, ["P:Kit", "P:KitDyn", "T:Kit", "T:Gen", "P:KitTests"]),
        target("P:Kit", "Kit-product", type: "packageProduct"),
        target("P:KitDyn", "KitDyn-product", productType: "com.apple.product-type.library.dynamic"),
        target("T:Kit", "Kit", productType: "org.swift.product-type.library.static"),
        target("T:Gen", "GenPlugin", productType: "com.apple.product-type.tool.host-build"),
        target("P:KitTests", "KitPackageTests-product", type: "aggregate"),
        project("PACKAGE:remote-kit", remoteDirectory, ["P:Remote"]),
        target("P:Remote", "RemoteThing-product", type: "packageProduct"),
        project("PACKAGE:root", root, ["P:RootTests"]),
        target("P:RootTests", "rootPackageTests-product", type: "aggregate"),
        project("AGGREGATE", kitDirectory, ["A:All", "A:Excl"]),
        target("A:All", "AllIncludingTests", type: "aggregate"),
        target("A:Excl", "AllExcludingTests", type: "aggregate"),
    ]
    return try! JSONSerialization.data(withJSONObject: objects)
}

@Suite struct PackagePIFTests {
    func fixture() throws -> (Container, PackageGraphPIF, URL) {
        let proj = try writePackageFixture(remote: true, plugin: true, shell: true)
        let dir = proj.deletingLastPathComponent().path
        var graph = try PackageGraphPIF.parse(cannedPackagePIF(kitDirectory: dir + "/Kit", remoteDirectory: "/sp/checkouts/remote-kit",
                                                               root: "/sp/ycode-package-graph"), rootDirectory: "/sp/ycode-package-graph")
        graph.pluginOutputs = [:]
        return (try ContainerLocator.loadProjectContainer(proj), graph, proj)
    }

    /// SwiftPM's PIF loses the generated root and the aggregate project;
    /// products are the `<name>-product` targets, by package identity.
    @Test func parsesSwiftPMPackagePIF() throws {
        let (_, graph, _) = try fixture()
        #expect(graph.packages.map(\.identity) == ["kit", "remote-kit"])
        #expect(graph.projectSignatures == ["sig-PACKAGE:kit", "sig-PACKAGE:remote-kit"])
        let kit = try #require(graph.package(identity: "kit"))
        #expect(kit.products.keys.sorted() == ["Kit", "KitDyn"])
        #expect(kit.products["Kit"]?.targetType == "packageProduct" && kit.products["Kit"]?.isDynamic == false)
        #expect(kit.products["KitDyn"]?.isDynamic == true)
        #expect(kit.pluginTargets == ["GenPlugin": "T:Gen"])
        #expect(graph.product("RemoteThing", identity: nil)?.guid == "P:Remote")
        #expect(graph.dynamicProductGUIDs == ["P:KitDyn"])
        let kept = graph.objects.compactMap { $0["signature"] as? String }
        #expect(!kept.contains("sig-PACKAGE:root") && !kept.contains("sig-AGGREGATE") && !kept.contains("sig-A:All"))
    }

    /// Product build files become target references to the products' PIF
    /// targets, the products are explicit dependencies, the workspace lists
    /// the package projects, and the package objects follow the project's.
    @Test func productsAreTargetReferences() throws {
        let (container, graph, _) = try fixture()
        let pif = XcodePIF(container: container, packages: graph)
        let objects = pif.objects()
        let ws = objects[0]["contents"] as! [String: Any]
        let projects = ws["projects"] as! [String]
        #expect(projects.count == 3 && projects[0].hasPrefix("PROJECT@") && Array(projects[1...]) == ["sig-PACKAGE:kit", "sig-PACKAGE:remote-kit"])
        let app = try #require(objects.compactMap { $0["contents"] as? [String: Any] }.first { $0["name"] as? String == "App" })
        let phases = app["buildPhases"] as! [[String: Any]]
        let frameworks = try #require(phases.first { $0["type"] as? String == "com.apple.buildphase.frameworks" })
        #expect((frameworks["buildFiles"] as! [[String: Any]]).map { $0["targetReference"] as? String } == ["P:Kit", "P:KitDyn", "P:Remote"])
        let deps = (app["dependencies"] as! [[String: Any]]).compactMap { $0["guid"] as? String }
        #expect(deps == ["P:Kit", "P:KitDyn", "P:Remote"])
        // A tool gets no embed phase.
        #expect(!phases.contains { $0["destinationSubfolder"] as? String == "$(FRAMEWORKS_FOLDER_PATH)" })
        #expect(objects.contains { $0["signature"] as? String == "sig-P:KitDyn" })
    }

    /// Without the package graph, product build files are left out (the
    /// former behavior, which ycodebuild's settings queries keep).
    @Test func withoutPackagesProductsAreLeftOut() throws {
        let (container, _, _) = try fixture()
        let objects = XcodePIF(container: container).objects()
        let app = try #require(objects.compactMap { $0["contents"] as? [String: Any] }.first { $0["name"] as? String == "App" })
        let frameworks = (app["buildPhases"] as! [[String: Any]]).first { $0["type"] as? String == "com.apple.buildphase.frameworks" }
        #expect((frameworks?["buildFiles"] as? [Any])?.isEmpty == true)
        #expect((app["dependencies"] as! [Any]).isEmpty)
    }

    /// An application gets a copy-files phase that embeds the dynamic
    /// products it links into its Frameworks folder, signed on copy.
    @Test func applicationsEmbedDynamicProducts() throws {
        let (container, graph, _) = try fixture()
        let objects = XcodePIF(container: container, packages: graph).objects()
        let shell = try #require(objects.compactMap { $0["contents"] as? [String: Any] }.first { $0["name"] as? String == "Shell" })
        let embed = try #require((shell["buildPhases"] as! [[String: Any]]).first { $0["type"] as? String == "com.apple.buildphase.copy-files" })
        #expect(embed["destinationSubfolder"] as? String == "$(FRAMEWORKS_FOLDER_PATH)")
        let files = embed["buildFiles"] as! [[String: Any]]
        #expect(files.count == 1 && files[0]["targetReference"] as? String == "P:KitDyn" && files[0]["codeSignOnCopy"] as? String == "true")
    }

    /// Signatures hash the contents, so a changed target gets a new one
    /// (swift-build keys its build descriptions by them).
    @Test func signaturesFollowContents() throws {
        let (container, graph, proj) = try fixture()
        let a = XcodePIF(container: container, packages: graph).objects()
        let b = XcodePIF(container: container, packages: graph).objects()
        #expect(a.map { $0["signature"] as? String } == b.map { $0["signature"] as? String })
        let appSignature = { (objects: [[String: Any]]) in
            objects.first { ($0["contents"] as? [String: Any])?["name"] as? String == "App" }?["signature"] as? String
        }
        #expect(appSignature(a)?.hasPrefix("TARGET@") == true && appSignature(a)?.contains("_hash=") == true)
        let text = try String(contentsOf: proj.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        try text.replacingOccurrences(of: "MACOSX_DEPLOYMENT_TARGET = 14.0", with: "MACOSX_DEPLOYMENT_TARGET = 15.0")
            .write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        let c = XcodePIF(container: try ContainerLocator.loadProjectContainer(proj), packages: graph).objects()
        #expect(appSignature(c) != appSignature(a))
        #expect(c[0]["signature"] as? String != a[0]["signature"] as? String)
    }

    /// Plug-in commands become custom tasks whose host tool is relocated to
    /// the client build's products folder; their Swift outputs join the
    /// sources phase through a group of absolute paths; the plug-in's target
    /// is a dependency.
    @Test func pluginOutputsBecomeCustomTasksAndSources() throws {
        let (container, base, _) = try fixture()
        var graph = base
        let project = container.projects[0]
        let app = try #require(project.targets.first { $0.string("name") == "App" })
        graph.pluginOutputs[ProjectPlugins.key(project, app.id)] = ProjectPlugins.TargetOutputs(
            pluginTargetGUIDs: ["T:Gen"],
            commands: [.init(displayName: "Generating Msg.swift", executable: "/sp/scratch/out/Products/Debug/gen-tool",
                             arguments: ["/p/App/Msg.gen", "/sp/out/Msg.swift"], environment: ["A": "1"], workingDirectory: "/p",
                             inputFiles: ["/p/App/Msg.gen"], outputFiles: ["/sp/out/Msg.swift"])])
        graph.relocateHostTools(scratchDirectory: "/sp/scratch")
        let objects = XcodePIF(container: container, packages: graph).objects()
        let t = try #require(objects.compactMap { $0["contents"] as? [String: Any] }.first { $0["name"] as? String == "App" })
        let task = try #require((t["customTasks"] as? [[String: Any]])?.first)
        #expect(task["commandLine"] as? [String] == ["$(BUILD_DIR)/$(CONFIGURATION)/gen-tool", "/p/App/Msg.gen", "/sp/out/Msg.swift"])
        #expect(task["inputFilePaths"] as? [String] == ["$(BUILD_DIR)/$(CONFIGURATION)/gen-tool", "/p/App/Msg.gen"])
        #expect(task["outputFilePaths"] as? [String] == ["/sp/out/Msg.swift"])
        #expect((task["environment"] as? [[String]]) == [["A", "1"]])
        #expect((t["dependencies"] as! [[String: Any]]).contains { $0["guid"] as? String == "T:Gen" })
        let sources = try #require((t["buildPhases"] as! [[String: Any]]).first { $0["type"] as? String == "com.apple.buildphase.sources" })
        let refs = (sources["buildFiles"] as! [[String: Any]]).compactMap { $0["fileReference"] as? String }
        let projectContents = try #require(objects.compactMap { $0["contents"] as? [String: Any] }.first { $0["groupTree"] != nil })
        let group = try #require(((projectContents["groupTree"] as! [String: Any])["children"] as! [[String: Any]]).last)
        let file = try #require((group["children"] as? [[String: Any]])?.first)
        #expect(file["path"] as? String == "/sp/out/Msg.swift" && file["sourceTree"] as? String == "<absolute>")
        #expect(refs.contains(file["guid"] as! String))
    }

    /// SwiftPM's own plug-in tasks get the same relocation and new
    /// signatures (the project's target list follows).
    @Test func relocatesPackageCustomTasks() throws {
        let objects: [[String: Any]] = [
            ["signature": "P1", "type": "project", "contents": ["guid": "PACKAGE:x", "projectDirectory": "/x", "targets": ["T1"]]],
            ["signature": "T1", "type": "target", "contents": ["guid": "T", "name": "X", "type": "standard",
                                                                 "customTasks": [["commandLine": ["/s/out/Products/Debug/tool", "a"]]]]],
        ]
        var graph = try PackageGraphPIF.parse(JSONSerialization.data(withJSONObject: objects), rootDirectory: "/root")
        graph.relocateHostTools(scratchDirectory: "/s")
        let target = try #require(graph.objects.first { $0["type"] as? String == "target" })
        let task = ((target["contents"] as! [String: Any])["customTasks"] as! [[String: Any]])[0]
        #expect(task["commandLine"] as? [String] == ["$(BUILD_DIR)/$(CONFIGURATION)/tool", "a"])
        let newSignature = try #require(target["signature"] as? String)
        #expect(newSignature.hasPrefix("T1-ycode-"))
        let project = graph.objects.first { $0["type"] as? String == "project" }!
        #expect((project["contents"] as! [String: Any])["targets"] as? [String] == [newSignature])
        #expect(graph.projectSignatures == [project["signature"] as! String] && graph.projectSignatures[0] != "P1")
    }

    /// The generated root: one path dependency per package, local packages
    /// first and overriding remote ones of the same identity.
    @Test func rootManifestListsEveryPackage() throws {
        let proj = try writePackageFixture(remote: true, plugin: true)
        let dir = proj.deletingLastPathComponent().standardizedFileURL.path
        let loader = PackageGraphLoader(container: try ContainerLocator.loadProjectContainer(proj), sourcePackagesDirectory: URL(fileURLWithPath: "/sp"))
        #expect(loader.references.map(\.identity) == ["kit", "remote-kit", "gen"])
        let pins = [PackageResolver.Pin(identity: "remote-kit", location: "https://example.invalid/team/remote-kit.git", revision: "abc",
                                        version: "1.0.0", branch: nil, checkout: URL(fileURLWithPath: "/sp/checkouts/remote-kit")),
                    PackageResolver.Pin(identity: "kit", location: "https://example.invalid/kit.git", revision: "def",
                                        version: "1.0.0", branch: nil, checkout: URL(fileURLWithPath: "/sp/checkouts/kit"))]
        let dirs = loader.packageDirectories(pins: pins)
        #expect(dirs == [dir + "/Kit", dir + "/Gen", "/sp/checkouts/remote-kit"])
        let text = PackageGraphLoader.rootManifest(packageDirectories: ["/a/K\"it", "/b"])
        #expect(text.hasPrefix("// swift-tools-version: 5.9\n"))
        #expect(text.contains(".package(path: \"/a/K\\\"it\"),\n") && text.contains(".package(path: \"/b\"),\n"))
        #expect(text.contains("name: \"ycode-package-graph\""))
    }

    /// The plug-in message of SwiftPM's protocol: the project, its targets
    /// with their input files, the work folder and the tools.
    @Test func pluginRequestDescribesTheProject() throws {
        let proj = try writePackageFixture(remote: false, plugin: true, shell: true)
        let project = try ContainerLocator.loadProjectContainer(proj).projects[0]
        let app = try #require(project.targets.first { $0.string("name") == "App" })
        let data = ProjectPlugins.WireInput.message(project: project, target: app, pluginWorkDirectory: "/w/out",
                                                    tools: ["gen-tool": "/t/gen-tool"], toolSearchDirectories: ["/bin"])
        let msg = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(msg["createXcodeProjectBuildToolCommands"] as? [String: Any])
        #expect(body["rootProjectId"] as? Int == 0 && body["targetId"] as? Int == 0)
        let context = try #require(body["context"] as? [String: Any])
        let paths = (context["paths"] as! [[String: Any]]).map { "/" + ($0["subpath"] as! String) }
        let targets = context["xcodeTargets"] as! [[String: Any]]
        #expect(targets.map { $0["displayName"] as? String } == ["App", "Shell"])
        #expect(((targets[1]["product"] as! [String: Any])["kind"] as? [String: Any])?.keys.first == "application")
        let files = targets[0]["inputFiles"] as! [[String: Any]]
        #expect(files.map { "\(paths[$0["basePathId"] as! Int])/\($0["name"] as! String)|\($0["type"] as! String)" }
                == [proj.deletingLastPathComponent().standardizedFileURL.path + "/App/main.swift|source",
                    proj.deletingLastPathComponent().standardizedFileURL.path + "/App/Msg.gen|resource"])
        #expect(paths[context["pluginWorkDirId"] as! Int] == "/w/out")
        let tool = (context["accessibleTools"] as! [String: [String: Any]])["gen-tool"]!
        #expect(paths[tool["path"] as! Int] == "/t/gen-tool")
    }

    /// The plug-in's answers: length-framed JSON messages (URLs as
    /// Foundation encodes them), and the commands file Ycode's
    /// XcodeProjectPlugin module writes.
    @Test func pluginRepliesAreRead() throws {
        func frame(_ obj: [String: Any]) -> Data {
            let json = try! JSONSerialization.data(withJSONObject: obj)
            var n = UInt64(json.count).littleEndian
            return withUnsafeBytes(of: &n) { Data($0) } + json
        }
        let data = frame(["emitDiagnostic": ["severity": "warning", "message": "careful", "file": "/a.swift", "line": 3]])
            + frame(["defineBuildCommand": ["configuration": ["version": 2, "displayName": "Gen", "executable": ["relative": "file:///t/gen"],
                                                              "arguments": ["x"], "environment": ["K": "V"]],
                                            "inputFiles": [["relative": "file:///in.gen"]], "outputFiles": ["/out.swift"]]])
        let replies = ProjectPlugins.WireOutput.replies(in: data)
        #expect(replies.count == 2)
        if case .diagnostic(let d) = replies[0] { #expect(d == "/a.swift:3: warning: careful") } else { Issue.record("not a diagnostic") }
        if case .build(let c) = replies[1] {
            #expect(c.executable == "/t/gen" && c.arguments == ["x"] && c.environment == ["K": "V"])
            #expect(c.inputFiles == ["/in.gen"] && c.outputFiles == ["/out.swift"])
        } else { Issue.record("not a build command") }
        let file = try JSONSerialization.data(withJSONObject: [
            ["kind": "build", "displayName": "", "executable": "/t/gen", "arguments": ["a"], "environment": [String: String](),
             "inputFiles": ["/i"], "outputFiles": ["/o.swift"]],
            ["kind": "prebuild", "displayName": "Pre", "executable": "/t/pre", "arguments": [String](), "environment": [String: String](),
             "outputFilesDirectory": "/pre"],
        ])
        let commands = ProjectPlugins.WireOutput.commands(inFile: file)
        if case .build(let c) = commands[0] { #expect(c.displayName == nil && c.outputFiles == ["/o.swift"]) } else { Issue.record("build") }
        if case .prebuild(let c, let dir) = commands[1] { #expect(c.displayName == "Pre" && dir == "/pre") } else { Issue.record("prebuild") }
        var outputs = ProjectPlugins.TargetOutputs()
        outputs.commands = [.init(displayName: nil, executable: "/t", arguments: [], environment: [:], workingDirectory: nil, inputFiles: [],
                                  outputFiles: ["/g/A.swift", "/g/B.h", "/g/C.json"])]
        #expect(outputs.generatedSources == ["/g/A.swift"] && outputs.generatedResources == ["/g/C.json"])
    }

    /// The IDE's fallback test: plug-ins of project targets need a Mac.
    @Test func supportsReportsPluginsOffTheMac() throws {
        let proj = try writePackageFixture(remote: false, plugin: true)
        #expect(XcodePIFSource.supports(BuildRequest(container: .project(proj.path))) == ProjectPlugins.isSupported)
        let plain = try writePackageFixture(remote: false, plugin: false)
        #expect(XcodePIFSource.supports(BuildRequest(container: .project(plain.path))))
    }
}

/// SwiftPM's generator on real packages (the toolchain's `swift`; Linux too).
@Suite(.serialized, .timeLimit(.minutes(10))) struct PackageGraphLoaderTests {
    static var swiftAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: PackageGraphLoader.defaultSwift())
    }

    @Test func loadsTheLocalPackageGraph() throws {
        guard Self.swiftAvailable else { return }
        let proj = try writePackageFixture(remote: false, plugin: false, shell: true)
        let container = try ContainerLocator.loadProjectContainer(proj)
        let sp = proj.deletingLastPathComponent().appendingPathComponent("SourcePackages")
        let graph = try #require(try PackageGraphLoader(container: container, sourcePackagesDirectory: sp).load())
        #expect(graph.packages.map(\.identity) == ["kit"])
        let kit = try #require(graph.package(identity: "kit"))
        #expect(kit.products["Kit"]?.targetType == "packageProduct")
        #expect(kit.products["KitDyn"]?.isDynamic == true)
        // The generated root lives in the source-packages folder, not in the package.
        #expect(FileManager.default.fileExists(atPath: sp.appendingPathComponent("ycode-package-graph/Package.swift").path))
        #expect(!FileManager.default.fileExists(atPath: proj.deletingLastPathComponent().appendingPathComponent("Kit/.build").path))
        let objects = XcodePIF(container: container, packages: graph).objects()
        let app = try #require(objects.compactMap { $0["contents"] as? [String: Any] }.first { $0["name"] as? String == "App" })
        let deps = (app["dependencies"] as! [[String: Any]]).compactMap { $0["guid"] as? String }
        #expect(deps == [kit.products["Kit"]!.guid, kit.products["KitDyn"]!.guid])
        // Every target reference resolves to a target of the PIF.
        let guids = Set(objects.filter { $0["type"] as? String == "target" }.compactMap { ($0["contents"] as? [String: Any])?["guid"] as? String })
        for d in deps { #expect(guids.contains(d)) }
    }
}

extension PackageGraphLoaderTests {
    /// A product no package provides is an error, not a link failure later.
    @Test func missingProductsAreReported() throws {
        guard Self.swiftAvailable else { return }
        let proj = try writePackageFixture(remote: false, plugin: false)
        let file = proj.appendingPathComponent("project.pbxproj")
        try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "productName = KitDyn;", with: "productName = Nope;")
            .write(to: file, atomically: true, encoding: .utf8)
        let loader = PackageGraphLoader(container: try ContainerLocator.loadProjectContainer(proj),
                                        sourcePackagesDirectory: proj.deletingLastPathComponent().appendingPathComponent("SourcePackages"))
        #expect { _ = try loader.load() } throws: { "\($0)".contains("Missing package product 'Nope'") }
    }
}

/// Builds the fixture with swift-build (ycodebuild) and runs the tool: a
/// local package's static product with its resource bundle, its dynamic
/// product, and a build-tool plug-in applied to the project target.
@Suite(.serialized, .timeLimit(.minutes(15))) struct PackageBuildEndToEndTests {
    @Test func buildsAndRunsATargetThatUsesPackages() throws {
        #if os(macOS)
        guard let helper = SwiftBuildEndToEndTests.helper else { return }
        let proj = try writePackageFixture(remote: false, plugin: true)
        let dir = proj.deletingLastPathComponent().path
        let dd = dir + "/DerivedData"
        let b = SwiftBuildEndToEndTests().run(["-scheme", "App", "-derivedDataPath", dd, "build"], cwd: dir, helper: helper)
        #expect(b.code == 0, "\(b.out.suffix(3000)) \(b.err)")
        let exe = dd + "/Build/Products/Debug/App"
        #expect(FileManager.default.fileExists(atPath: dd + "/Build/Products/Debug/libKitDyn.dylib"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(out == "kit: from the resource bundle; dyn: 7; gen: generated by the project plug-in\n")
        #endif
    }
}
