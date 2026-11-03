import Foundation
import Testing
import YcodeDebug
@testable import YcodeBuildServer
import YcodeIDECore
import YcodeLanguage

/// The Find navigator's semantic kinds on sourcekit-lsp through
/// `ycode-bsp` (specs/ide/navigators.md §Find navigator, "Ycode
/// implementation"): on the portable sample project, references to the
/// framework's `Greeter` come from all three targets (Kit, App, AppTests),
/// Symbols ▸ Definitions finds the declaration, Call Hierarchy finds the
/// test that calls `greet(times:)`, and the type hierarchy crosses from
/// the framework into the app.
@Suite(.serialized, .timeLimit(.minutes(8))) struct SourceKitLSPFindTests {
    /// Additions to the sample: a protocol, an open class and its
    /// subclasses, in the framework and in the app.
    static let kitTypes = """

    public protocol Greeting { func greet(times: Int) -> String }
    extension Greeter: Greeting {}
    open class BaseGreeter { public init() {} }
    public final class LoudGreeter: BaseGreeter {}

    """
    static let appTypes = """

    final class AppGreeter: BaseGreeter {}
    struct Polite: Greeting { func greet(times: Int) -> String { "" } }
    func run() -> String { Polite().greet(times: 1) }

    """

    @Test func referencesDefinitionsCallersAndTypesAcrossTargets() async throws {
        guard let lsp = SourceKitLSP.locate(), let bsp = SourceKitLSPBuildServerTests.server else { return }
        let dir = try freshScratch("find-portable")
        let project = try SampleProject.write(.portable, in: dir)
        let sample = project.deletingLastPathComponent()
        let greeterURL = sample.appendingPathComponent("Kit/Greeter.swift")
        let mainURL = sample.appendingPathComponent("App/main.swift")
        try (SampleProject.greeter + Self.kitTypes).write(to: greeterURL, atomically: true, encoding: .utf8)
        try (SampleProject.appMainPortable + Self.appTypes).write(to: mainURL, atomically: true, encoding: .utf8)
        let folder = dir.appendingPathComponent("lsp-root")
        try BuildServerConfigFile.write(argv: [bsp, "serve", project.path, "--derived-data", dir.appendingPathComponent("DD").path,
                                               "--log", dir.appendingPathComponent("bsp.log").path], into: folder)
        let client = try LSPClient(transport: ProcessTransport(executable: lsp))
        defer { client.close() }
        try await client.initialize(root: folder, initializationOptions: BuildServerLaunch.initializationOptions)
        let greeter = try String(contentsOf: greeterURL, encoding: .utf8)
        client.didOpen(greeterURL, text: greeter)
        client.didOpen(mainURL, text: try String(contentsOf: mainURL, encoding: .utf8))
        // The index covers every target once synchronized (sourcekit-lsp's extension).
        _ = try await client.request("workspace/synchronize", ["index": true])

        // References to Greeter, from the declaration in the framework.
        let decl = try SourceKitLSPBuildServerTests.position(after: "public struct Gree", in: greeter)
        let refs = try await client.references(greeterURL, at: decl)
        let files = Set(refs.map(\.url.lastPathComponent))
        #expect(files.isSuperset(of: ["Greeter.swift", "main.swift", "AppTests.swift"]), "\(refs.map(\.url.path))")

        // The same through the Find navigator's Symbols ▸ References, by name.
        let byName = await SemanticFind.run(FindQuery("Greeter", kind: .symbols, match: .matchingWord, ignoreCase: false, symbolRole: .references),
                                            service: client)
        #expect(Set(byName.nodes.map(\.title)).isSuperset(of: ["Greeter.swift", "main.swift", "AppTests.swift"]), "\(byName)")
        #expect(byName.heading.hasPrefix("Greeter — ") && byName.count >= 3)
        // A reference row reads "line: text" and opens that line.
        let appRow = try #require(byName.nodes.first { $0.title == "main.swift" }?.children.first)
        #expect(appRow.title == "3: let g = Greeter(name: \"Ycode\")" && appRow.line == 3)

        // Symbols ▸ Definitions.
        let defs = await SemanticFind.run(FindQuery("Greet", kind: .symbols, match: .startingWith, ignoreCase: false), service: client)
        let defNames = defs.nodes.flatMap(\.children).map(\.title)
        #expect(defNames.contains("Greeter") && defNames.contains("Greeting"), "\(defs)")

        // Call Hierarchy: the test calls the framework's greet(times:), the
        // app's run() calls its own (names are qualified by their type).
        let callers = await SemanticFind.run(FindQuery("greet", kind: .callHierarchy, match: .matchingWord), service: client)
        let kitGreet = try #require(callers.nodes.first { $0.title == "Greeter.greet(times:)" }, "\(callers)")
        #expect(kitGreet.children.map(\.title) == ["AppTests.testGreeting()"] && kitGreet.children[0].path?.hasSuffix("AppTests/AppTests.swift") == true)
        #expect(callers.nodes.first { $0.title == "Polite.greet(times:)" }?.children.map(\.title) == ["run()"], "\(callers)")

        print("FIND-LSP references to Greeter: \(refs.count) in \(files.sorted()); callers of greet: \(callers.count)")
        // Type hierarchy, when the server has it.
        guard client.provides("typeHierarchy") else {
            print("FIND-LSP type hierarchy: not provided")
            await client.shutdown()
            return
        }
        let down = await SemanticFind.run(FindQuery("BaseGreeter", kind: .descendentTypes, match: .matchingWord), service: client)
        let downNames = down.nodes.flatMap(\.flattened).map(\.title)
        #expect(downNames.contains("LoudGreeter") && downNames.contains("AppGreeter"), "\(down)")
        let up = await SemanticFind.run(FindQuery("AppGreeter", kind: .ancestorTypes, match: .matchingWord), service: client)
        #expect(up.nodes.flatMap(\.flattened).map(\.title).contains("BaseGreeter"), "\(up)")
        let conforming = await SemanticFind.run(FindQuery("Greeting", kind: .conformingTypes, match: .matchingWord), service: client)
        #expect(conforming.nodes.flatMap(\.flattened).map(\.title).contains("Polite"), "\(conforming)")
        print("FIND-LSP type hierarchy: descendents of BaseGreeter \(downNames), conforming to Greeting \(conforming.nodes.flatMap(\.flattened).map(\.title))")
        await client.shutdown()
    }
}
