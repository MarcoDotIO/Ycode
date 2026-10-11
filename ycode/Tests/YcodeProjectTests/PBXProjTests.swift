import Foundation
import Testing
import YcodePlist
@testable import YcodeProject

private func fixture(_ name: String) throws -> (text: String, proj: PBXProj) {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name).xcodeproj/project", withExtension: "pbxproj"))
    let text = try String(contentsOf: url, encoding: .utf8)
    return (text, try PBXProj(parsing: text))
}

@Suite struct PBXProjModelTests {
    @Test func readsObjectGraph() throws {
        let (_, proj) = try fixture("Hello")
        #expect(proj.objectVersion == "77")
        #expect(proj.project?.isa == "PBXProject")
        #expect(proj.targets.map { $0.string("name") } == ["Hello"])
        let configs = proj.buildConfigurations(listID: proj.targets[0].string("buildConfigurationList"))
        #expect(configs.map { $0.string("name") } == ["Debug", "Release"])
        #expect(configs[0]["buildSettings"]?.dictionary?["PRODUCT_BUNDLE_IDENTIFIER"] == "org.example.Hello-World")
    }

    @Test func writesFixtureByteForByte() throws {
        let (text, proj) = try fixture("Hello")
        #expect(proj.serialized(projectName: "Hello") == text)
    }

    @Test func regeneratesCommentsAfterRename() throws {
        var (_, proj) = try fixture("Hello")
        proj["0B0000000000000000000001"]?["path"] = "App.swift"
        let out = proj.serialized(projectName: "Hello")
        #expect(out.contains("0A0000000000000000000001 /* App.swift in Sources */ = {"))
        #expect(out.contains("0B0000000000000000000001 /* App.swift */,"))
    }

    @Test func legacyCommentStyleIsDetectedAndKept() throws {
        let (text, _) = try fixture("Hello")
        let legacy = text
            .replacingOccurrences(of: #" configuration for PBXNativeTarget "Hello""#, with: "")
            .replacingOccurrences(of: #" configuration for PBXProject "Hello""#, with: "")
        let proj = try PBXProj(parsing: legacy)
        #expect(!proj.style.qualifiedConfigurationComments)
        #expect(proj.serialized(projectName: "Hello") == legacy)
    }

    @Test func newObjectIDsAreUniqueHex() throws {
        let (_, proj) = try fixture("Hello")
        let id = proj.makeObjectID()
        #expect(id.count == 24)
        #expect(id.allSatisfy { $0.isHexDigit })
        #expect(proj[id] == nil)
    }

    @Test func repositoryNameFromURL() {
        #expect(PBXProjWriter.repositoryName("https://github.com/apple/swift-argument-parser.git") == "swift-argument-parser")
        #expect(PBXProjWriter.repositoryName("git@host:org/Thing") == "Thing")
    }
}

/// Regression over real projects that are not checked in. The manifest lists
/// one path per line, prefixed `=` (Xcode-written: must match byte for byte)
/// or `~` (edited by other tools: must be lossless and idempotent).
/// Override the manifest location with `YCODE_PBXPROJ_CORPUS`.
@Suite struct PBXProjCorpusTests {
    static let manifest: URL = {
        if let env = ProcessInfo.processInfo.environment["YCODE_PBXPROJ_CORPUS"] { return URL(fileURLWithPath: env) }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("research/dirty/pbxproj-corpus.txt")
    }()

    static let entries: [String] = {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { $0.count > 2 }
    }()

    @Test(.enabled(if: !entries.isEmpty, "no local corpus manifest"), arguments: entries)
    func roundTrip(_ entry: String) throws {
        let exact = entry.hasPrefix("=")
        let path = String(entry.dropFirst(2))
        let (file, name) = PBXProj.locate(path)
        let original = try String(contentsOf: file, encoding: .utf8)
        let proj = try PBXProj(parsing: original)
        let written = proj.serialized(projectName: name)
        if exact {
            #expect(written == original, "\(path)")
        }
        let reparsed = try PBXProj(parsing: written)
        #expect(reparsed.objects.mapValues(\.attributes.canonicalized) == proj.objects.mapValues(\.attributes.canonicalized),
                "lossless: \(path)")
        #expect(reparsed.rootObject == proj.rootObject)
        #expect(reparsed.serialized(projectName: name) == written, "idempotent: \(path)")
    }
}
