import Foundation
import Testing
import YcodeProject
@testable import YcodeBuild

/// Uses a git repository made in a temporary directory as the "remote";
/// never the network.
@Suite(.serialized) struct PackageResolverTests {
    static func sh(_ args: String..., in dir: URL) throws {
        _ = try PackageResolver.run("/usr/bin/env", Array(args), in: dir,
                                    environment: ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"])
    }

    /// A package `Kit` with tags 1.0.0, 1.2.0, 1.2.3, 2.0.0-beta, 2.0.0 and a `dev` branch.
    static func makeRemote() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-pkg-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/Kit"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Kit", products: [.library(name: "Kit", targets: ["Kit"]), .library(name: "KitExtras", targets: ["Kit"])],
                              targets: [.target(name: "Kit")])

        """.write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try sh("git", "init", "-q", "-b", "main", in: repo)
        for (i, tag) in ["1.0.0", "1.2.0", "1.2.3", "2.0.0-beta", "2.0.0"].enumerated() {
            try "public let v = \(i)\n".write(to: repo.appendingPathComponent("Sources/Kit/Kit.swift"), atomically: true, encoding: .utf8)
            try sh("git", "add", "-A", in: repo)
            try sh("git", "commit", "-q", "-m", tag, in: repo)
            try sh("git", "tag", tag, in: repo)
        }
        try sh("git", "checkout", "-q", "-b", "dev", in: repo)
        try "public let v = 99\n".write(to: repo.appendingPathComponent("Sources/Kit/Kit.swift"), atomically: true, encoding: .utf8)
        try sh("git", "commit", "-q", "-am", "dev", in: repo)
        try sh("git", "checkout", "-q", "main", in: repo)
        return repo
    }

    @Test func versionSelection() throws {
        let repo = try Self.makeRemote()
        let url = repo.absoluteString
        let vs = try PackageResolver.availableVersions(url: url)
        #expect(vs.map(\.tag) == ["1.0.0", "1.2.0", "1.2.3", "2.0.0-beta", "2.0.0"])
        func pick(_ r: SwiftPackageRequirement) -> String? { PackageResolver.select(r, from: vs)?.tag }
        #expect(pick(.upToNextMajor(from: "1.0.0")) == "1.2.3")
        #expect(pick(.upToNextMinor(from: "1.2.0")) == "1.2.3")
        #expect(pick(.upToNextMinor(from: "1.0.0")) == "1.0.0")
        #expect(pick(.exact("1.2.0")) == "1.2.0")
        #expect(pick(.range(from: "1.1.0", to: "2.0.0")) == "1.2.3")
        #expect(pick(.upToNextMajor(from: "2.0.0")) == "2.0.0")
        #expect(pick(.upToNextMajor(from: "3.0.0")) == nil)
    }

    @Test func resolvesWritesPinsAndListsProducts() throws {
        let repo = try Self.makeRemote()
        let work = repo.deletingLastPathComponent().appendingPathComponent("work")
        let resolver = PackageResolver(checkoutsDirectory: work.appendingPathComponent("checkouts"))
        let pin = try resolver.resolve(url: repo.absoluteString, requirement: .upToNextMajor(from: "1.0.0"))
        #expect(pin.identity == "kit" && pin.version == "1.2.3" && pin.revision.count == 40)
        #expect(try String(contentsOf: pin.checkout.appendingPathComponent("Sources/Kit/Kit.swift"), encoding: .utf8) == "public let v = 2\n")
        // Re-resolving with another rule reuses the checkout.
        let dev = try resolver.resolve(url: repo.absoluteString, requirement: .branch("dev"))
        #expect(dev.branch == "dev" && dev.version == nil)
        #expect(try String(contentsOf: dev.checkout.appendingPathComponent("Sources/Kit/Kit.swift"), encoding: .utf8) == "public let v = 99\n")
        #expect(try PackageResolver.products(ofPackageAt: dev.checkout) == ["Kit", "KitExtras"])
        let text = String(decoding: PackageResolver.resolvedFile([pin]), as: UTF8.self)
        #expect(text.contains("\"identity\" : \"kit\"") && text.contains("\"version\" : \"1.2.3\"") && text.contains("\"version\" : 2"))
        #expect(text.contains("\"kind\" : \"remoteSourceControl\""))
        let r = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect((r?["pins"] as? [Any])?.count == 1)
    }
}
