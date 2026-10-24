import Foundation
import Testing
import YcodeProject
@testable import YcodeBuild

/// Transitive resolution against local git repositories (never the network).
@Suite(.serialized) struct PackageGraphTests {
    /// A package repo named `name` whose manifest depends on `deps`
    /// (`.package(url:…)` lines), with one commit per tag.
    static func repo(_ root: URL, _ name: String, deps: [String], tags: [String]) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/\(name)"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
                              dependencies: [\(deps.joined(separator: ", "))],
                              targets: [.target(name: "\(name)")])

        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try PackageResolverTests.sh("git", "init", "-q", "-b", "main", in: dir)
        for (i, t) in tags.enumerated() {
            try "public let v = \(i)\n".write(to: dir.appendingPathComponent("Sources/\(name)/\(name).swift"), atomically: true, encoding: .utf8)
            try PackageResolverTests.sh("git", "add", "-A", in: dir)
            try PackageResolverTests.sh("git", "commit", "-q", "-m", t, in: dir)
            try PackageResolverTests.sh("git", "tag", t, in: dir)
        }
        return dir
    }

    @Test func transitiveAndConflicts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-graph-\(UUID().uuidString)")
        let b = try Self.repo(root, "Base", deps: [], tags: ["1.0.0", "1.1.0", "2.0.0"])
        let a = try Self.repo(root, "App", deps: ["\n.package(url: \"\(b.absoluteString)\", from: \"1.0.0\")"], tags: ["0.1.0"])
        let resolver = PackageResolver(checkoutsDirectory: root.appendingPathComponent("checkouts"))

        let pins = try resolver.resolveGraph([(a.absoluteString, .upToNextMajor(from: "0.1.0"))])
        #expect(pins.map(\.identity) == ["app", "base"])
        #expect(pins.map(\.version) == ["0.1.0", "1.1.0"])

        // The project also pins Base to 1.0.0: both rules allow it.
        let both = try resolver.resolveGraph([(a.absoluteString, .exact("0.1.0")), (b.absoluteString, .exact("1.0.0"))])
        #expect(both.first { $0.identity == "base" }?.version == "1.0.0")

        // 2.x for Base conflicts with App's 1.x requirement.
        #expect {
            try resolver.resolveGraph([(a.absoluteString, .exact("0.1.0")), (b.absoluteString, .upToNextMajor(from: "2.0.0"))])
        } throws: { e in
            let s = "\(e)"
            return s.contains("could not be resolved") && s.contains("base") && s.contains("the project requires 2.0.0 – Next Major")
                && s.contains("app 0.1.0 requires 1.0.0 – 2.0.0")
        }
        // A branch and a version rule on the same package conflict.
        #expect(throws: PackageResolver.ResolveError.self) {
            try resolver.resolveGraph([(a.absoluteString, .exact("0.1.0")), (b.absoluteString, .branch("main"))])
        }
    }

    @Test func resolvedV3AndOriginHash() {
        #expect(SHA256.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex(Array(String(repeating: "a", count: 1000).utf8)).count == 64)
        let h = PackageResolver.originHash(rootLocations: ["https://example.com/a.git", "https://example.com/b.git"])
        #expect(h == SHA256.hex(Array("https://example.com/a.githttps://example.com/b.git".utf8)))
        let pin = PackageResolver.Pin(identity: "a", location: "https://example.com/a.git", revision: String(repeating: "0", count: 40),
                                      version: "1.0.0", branch: nil, checkout: URL(fileURLWithPath: "/tmp"))
        let text = String(decoding: PackageResolver.resolvedFileV3([pin], originHash: h), as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"originHash\" : \"\(h)\",\n  \"pins\" : [\n"))
        #expect(text.hasSuffix("  \"version\" : 3\n}\n"))
    }
}
