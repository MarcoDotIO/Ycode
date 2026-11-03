import Foundation
import Testing
import YcodeDebug
@testable import YcodeBuildServer
import YcodeLanguage
import YcodeSubprocess
import YcodeWorkspace
import YcodeXcodebuild

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Package products in Xcode projects (language.md §Build server, "Package
/// products"): search paths and module arguments from the build's PIF.
@Suite struct PackageProductsTests {
    @Test func impartedWordsAreExpandedFromTheClientsSettings() {
        let s = ["BUILT_PRODUCTS_DIR": "/dd/Products/Debug-iphonesimulator", "OBJROOT": "/dd/Intermediates.noindex",
                 "EFFECTIVE_PLATFORM_NAME": "-iphonesimulator"]
        #expect(PackageProducts.expand("$(BUILT_PRODUCTS_DIR)/PackageFrameworks", s) == "/dd/Products/Debug-iphonesimulator/PackageFrameworks")
        #expect(PackageProducts.expand("-fmodule-map-file=$(GENERATED_MODULEMAP_DIR)/Kit.modulemap", s)
            == "-fmodule-map-file=/dd/Intermediates.noindex/GeneratedModuleMaps-iphonesimulator/Kit.modulemap")
        #expect(PackageProducts.expand("${BUILT_PRODUCTS_DIR}", s) == "/dd/Products/Debug-iphonesimulator")
        #expect(PackageProducts.expand("$(RPATH_ORIGIN)", s) == nil)
        #expect(PackageProducts.expand("-DX", s) == "-DX")
        #expect(SettingWords.split(PackageProducts.quoted("/a b/c")) == ["/a b/c"])
    }

    /// The products' package targets, transitively: their imparted settings
    /// for the client's configuration, added to the client's.
    @Test func impartedSettingsOfAProductAndItsTargets() throws {
        let dir = try freshScratch("package-imparted")
        let proj = try SampleProject.write(.portable, in: dir)
        var graph = PackageGraphPIF()
        func target(_ guid: String, deps: [String], imparted: [String: Any]) -> [String: Any] {
            ["type": "target", "contents": ["guid": guid, "dependencies": deps.map { ["guid": $0] },
                                            "buildConfigurations": [["name": "Release", "impartedBuildProperties": ["buildSettings": [:]]],
                                                                    ["name": "Debug", "impartedBuildProperties": ["buildSettings": imparted]]]]]
        }
        graph.objects = [
            target("P", deps: ["T"], imparted: [:]),
            target("T", deps: ["C"], imparted: ["FRAMEWORK_SEARCH_PATHS": ["$(BUILT_PRODUCTS_DIR)/PackageFrameworks", "$(inherited)"],
                                                "LD_RUNPATH_SEARCH_PATHS": ["$(RPATH_ORIGIN)"]]),
            target("C", deps: ["M"], imparted: ["OTHER_SWIFT_FLAGS": "-Xcc -fmodule-map-file=$(GENERATED_MODULEMAP_DIR)/C.modulemap",
                                                "OTHER_CFLAGS": ["-Xclang", "-fno-x=$(UNKNOWN)"]]),
            // A macro: its plug-in, not its (host) imparted settings.
            ["type": "target", "contents": ["guid": "M", "name": "Macros", "productTypeIdentifier": "com.apple.product-type.tool.host-build",
                                            "buildConfigurations": [["name": "Debug", "buildSettings": ["SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES": ["Macros"]],
                                                                     "impartedBuildProperties": ["buildSettings": ["OTHER_SWIFT_FLAGS": ["-I", "/host"]]]]]]],
        ]
        let packages = PackageProducts(pif: XcodePIF(container: try Container.open(proj), packages: graph), products: ["app": ["P"]])
        let imparted = packages.imparted(for: "app", configuration: "Debug")
        #expect(imparted["FRAMEWORK_SEARCH_PATHS"] == ["$(BUILT_PRODUCTS_DIR)/PackageFrameworks"])
        #expect(imparted["OTHER_SWIFT_FLAGS"] == ["-Xcc", "-fmodule-map-file=$(GENERATED_MODULEMAP_DIR)/C.modulemap",
                                                  "-load-plugin-executable", "$(BUILD_DIR)/$(CONFIGURATION)/Macros#Macros"])
        #expect(imparted["LD_RUNPATH_SEARCH_PATHS"] == nil)
        let merged = packages.merged(["CONFIGURATION": "Debug", "BUILT_PRODUCTS_DIR": "/p", "BUILD_DIR": "/b", "OBJROOT": "/o",
                                      "FRAMEWORK_SEARCH_PATHS": "/mine"], targetID: "app")
        #expect(merged["FRAMEWORK_SEARCH_PATHS"] == "/mine /p/PackageFrameworks")
        #expect(merged["OTHER_SWIFT_FLAGS"] == "-Xcc -fmodule-map-file=/o/GeneratedModuleMaps/C.modulemap -load-plugin-executable /b/Debug/Macros#Macros")
        // A flag list with a setting it cannot expand is left out whole.
        #expect(merged["OTHER_CFLAGS"] == nil)
        #expect(packages.merged(["X": "1"], targetID: "other") == ["X": "1"])
    }
}

/// `Samples/PackageSamples`: the iOS app `LocalPackageApp` uses the local
/// package's static and dynamic products. The build server adds their
/// search paths, builds them with swift-build when it prepares the app, and
/// sourcekit-lsp then completes the package's API in the app. Needs the
/// swift-build helper and the iOS Simulator SDK (macOS); the sample's other
/// packages are fetched into the IDE's package cache when missing.
@Suite(.serialized, .timeLimit(.minutes(10))) struct PackageSamplesBuildServerTests {
    static var helper: String? {
        let env = ProcessInfo.processInfo.environment
        if let h = SwiftBuildSettingsProvider.locate(environment: env, executableDirectory: nil) { return h }
        let p = ycodeDir.appendingPathComponent("Tools/ycode-swb/.build/debug/ycode-swb").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    @Test func localPackageProductsArePreparedAndCompleted() async throws {
        guard let helper = Self.helper, SourceKitLSPBuildServerTests.hasIOSSimulatorSDK, let swiftc = ModulePreparer.locateSwiftc() else { return }
        let project = ycodeDir.appendingPathComponent("Samples/PackageSamples/PackageSamples.xcodeproj")
        let app = ycodeDir.appendingPathComponent("Samples/PackageSamples/LocalPackageApp/LocalPackageApp.swift")
        let dir = try freshScratch("package-samples")
        let context = BuildContext(derivedDataFolder: dir.appendingPathComponent("DD/PackageSamples").path,
                                   developerDirectory: Workspace.activeDeveloperDirectory())
        let model = try IndexModel(containerURL: project, context: context)
        #expect(model.diagnostics.isEmpty, "\(model.diagnostics)")
        let target = try #require(model.graph.targets.first { $0.name == "LocalPackageApp" })
        #expect(model.packages?.products[target.id]?.count == 2)
        let ctx = try #require(model.compileContext(target.id))
        let args = try #require(model.arguments(for: app.path, targetID: target.id)).arguments
        #expect(args.contains(ctx.productsDirectory + "/PackageFrameworks"), "\(args)")

        // Preparing the app builds the products: their modules are where the
        // app's `-I` looks, and the app type-checks with its index arguments.
        let steps = ModulePreparer(model: model, packageHelper: helper).prepare([target.id])
        let step = try #require(steps.first { $0.packages })
        #expect(step.succeeded, "\(step.output)")
        #expect(FileManager.default.fileExists(atPath: ctx.productsDirectory + "/LocalKit.swiftmodule"))
        #expect(FileManager.default.fileExists(atPath: ctx.productsDirectory + "/LocalKitDynamicCore.swiftmodule"))
        func typechecks(_ args: [String]) throws -> String? {
            let r = try Subprocess.run(swiftc, ["-typecheck"] + args.filter { !$0.hasSuffix(".o") && $0 != "-index-unit-output-path" },
                                       currentDirectory: URL(fileURLWithPath: ctx.projectDirectory))
            return r.status == 0 ? nil : r.stderrText
        }
        #expect(try typechecks(args) == nil)
        // A remote package with a C target (its module map), and a macro
        // (its plug-in, built for the host).
        for (name, file) in [("RemotePackageApp", "RemotePackageApp/RemotePackageApp.swift"), ("MacroApp", "MacroApp/MacroApp.swift")] {
            let t = try #require(model.graph.targets.first { $0.name == name })
            let steps = ModulePreparer(model: model, packageHelper: helper).prepare([t.id])
            #expect(steps.first { $0.packages }?.succeeded == true, "\(name): \(steps.map(\.output))")
            let path = ycodeDir.appendingPathComponent("Samples/PackageSamples/" + file).path
            let a = try #require(model.arguments(for: path, targetID: t.id)).arguments
            #expect(try typechecks(a) == nil, "\(name)")
        }

        // sourcekit-lsp through ycode-bsp completes the package's API.
        guard let lsp = SourceKitLSP.locate(), let bsp = SourceKitLSPBuildServerTests.server else { return }
        let previous = ProcessInfo.processInfo.environment["YCODE_SWB"]
        setenv("YCODE_SWB", helper, 1)
        defer { if let previous { setenv("YCODE_SWB", previous, 1) } else { unsetenv("YCODE_SWB") } }
        let folder = dir.appendingPathComponent("lsp-root")
        try BuildServerConfigFile.write(argv: [bsp, "serve", project.path, "--derived-data", dir.appendingPathComponent("DD-lsp").path,
                                               "--log", dir.appendingPathComponent("bsp.log").path], into: folder)
        let client = try LSPClient(transport: ProcessTransport(executable: lsp))
        defer { client.close() }
        try await client.initialize(root: folder, initializationOptions: BuildServerLaunch.initializationOptions)
        // The app's file with one more use of the package (not saved).
        let text = try String(contentsOf: app, encoding: .utf8) + "\nlet probe = LocalKit.greeting\n"
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var diagnostics: [LSPDiagnostic]?
        }
        let box = Box()
        let reader = Task {
            for await n in client.notifications {
                guard n.method == "textDocument/publishDiagnostics", let (url, d) = LSPDiagnostic.published(n.params),
                      url.standardizedFileURL.path == app.standardizedFileURL.path else { continue }
                box.lock.withLock { box.diagnostics = d }
            }
        }
        defer { reader.cancel() }
        client.didOpen(app, text: text)
        // Diagnostics without "no such module" once the products are prepared.
        var version = 1
        let start = Date()
        func ready() -> Bool {
            guard let d = box.lock.withLock({ box.diagnostics }) else { return false }
            return !d.contains { $0.message.lowercased().contains("no such module") }
        }
        while Date().timeIntervalSince(start) < 300, !ready() {
            try await Task.sleep(for: .milliseconds(500))
            if Date().timeIntervalSince(start) > Double(version) * 10 {
                version += 1
                client.didChange(app, text: text, version: version)
            }
        }
        let diagnostics = box.lock.withLock { box.diagnostics } ?? []
        #expect(!diagnostics.contains { $0.severity == 1 }, "\(diagnostics.map(\.message))")
        let afterDot = try SourceKitLSPBuildServerTests.position(after: "probe = LocalKit.", in: text)
        let labels = try await client.completion(app, at: afterDot).map(\.label)
        #expect(labels.contains("greeting"), "\(labels.prefix(10))")
        await client.shutdown()
    }
}
