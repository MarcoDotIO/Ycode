import Foundation
import Testing
@testable import YcodeBuild

/// A package with an executable product, a library product, and a local
/// package dependency.
func writePackages(at root: URL) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    func write(_ rel: String, _ text: String) throws {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try write("Dep/Package.swift", """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "Dep", products: [.library(name: "Greeting", targets: ["Greeting"])],
                          targets: [.target(name: "Greeting")])

    """)
    try write("Dep/Sources/Greeting/Greeting.swift", "public func greeting(_ who: String) -> String { \"hello, \\(who)\" }\n")
    try write("App/Package.swift", """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "App",
        platforms: [.macOS(.v15)],
        products: [.executable(name: "hello", targets: ["hello"]), .library(name: "Core", targets: ["Core"])],
        dependencies: [.package(path: "../Dep")],
        targets: [
            .target(name: "Core", dependencies: [.product(name: "Greeting", package: "Dep")]),
            .executableTarget(name: "hello", dependencies: ["Core"]),
        ])

    """)
    try write("App/Sources/Core/Core.swift", "import Greeting\npublic func message() -> String { greeting(\"swift-build\") }\n")
    try write("App/Sources/hello/main.swift", "import Core\nprint(message())\n")
    return root.appendingPathComponent("App")
}

@Suite(.serialized, .timeLimit(.minutes(5))) struct SwiftBuildPackageTests {
    @Test func targetSelection() {
        let pif = Data(#"[{"type":"target","contents":{"name":"hello-product"}},{"type":"target","contents":{"name":"Core"}}]"#.utf8)
        #expect(SwiftBuildEngine.packageTarget(pif: pif, scheme: "hello") == "hello-product")
        #expect(SwiftBuildEngine.packageTarget(pif: pif, scheme: "Core") == "Core")
        #expect(SwiftBuildEngine.packageTarget(pif: pif, scheme: nil) == "AllExcludingTests")
    }

    @Test func buildsExecutableAndLibraryProducts() async throws {
        #if os(macOS)
        guard let tool = SwiftBuildEndToEndTests.swbuild else { return }
        let dir = try writePackages(at: ideScratch.appendingPathComponent("swiftbuild-pkg"))
        let engine = SwiftBuildEngine(swbuild: tool)
        let dd = dir.appendingPathComponent(".ycode-build").path
        let request = BuildRequest(container: .init(path: dir.appendingPathComponent("Package.swift").path), scheme: "hello",
                                   destination: "platform=macOS", derivedDataPath: dd)
        let result = await engine.start(request).run()
        #expect(result.status == .succeeded, "\(result.issues)")
        let exe = try #require(engine.executablePath(for: request))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "hello, swift-build\n")

        var lib = request
        lib.scheme = "Core"
        #expect(await engine.start(lib).run().status == .succeeded)
        #endif
    }
}
