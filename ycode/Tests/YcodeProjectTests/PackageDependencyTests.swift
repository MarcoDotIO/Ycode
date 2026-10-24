import Foundation
import Testing
import YcodePlist
@testable import YcodeProject

@Suite struct PackageDependencyTests {
    func fixture() throws -> (text: String, proj: PBXProj) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Hello.xcodeproj/project", withExtension: "pbxproj"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return (text, try PBXProj(parsing: text))
    }

    /// Renames object IDs everywhere in the graph (so random IDs can be
    /// compared with a fixture's).
    func renamed(_ p: PBXProj, _ map: [String: String]) -> PBXProj {
        func r(_ v: PlistValue) -> PlistValue {
            switch v {
            case .string(let s): .string(map[s] ?? s)
            case .array(let a): .array(a.map(r))
            case .dictionary(let d): .dictionary(PlistDictionary(d.map { ($0.key, r($0.value)) }))
            default: v
            }
        }
        var out = p
        out.objects = [:]
        for (id, o) in p.objects {
            let nid = map[id] ?? id
            out.objects[nid] = PBXObject(id: nid, attributes: PlistDictionary(o.attributes.map { ($0.key, r($0.value)) }))
        }
        return out
    }

    @Test func readsFixturePackages() throws {
        let (_, proj) = try fixture()
        let refs = proj.packageReferences
        #expect(refs.count == 1 && refs[0].displayName == "swift-argument-parser")
        #expect(refs[0].location == .remote(url: "https://github.com/apple/swift-argument-parser.git", requirement: .upToNextMajor(from: "1.5.0")))
        #expect(proj.packageProducts(ofTarget: proj.targets[0].id).map(\.name) == ["ArgumentParser"])
    }

    @Test func removeThenAddIsByteExact() throws {
        var (text, proj) = try fixture()
        let target = proj.targets[0].id
        proj.removePackage("0F0000000000000000000001")
        let removed = proj.serialized(projectName: "Hello")
        #expect(!removed.contains("ArgumentParser") && !removed.contains("XCRemoteSwiftPackageReference") && !removed.contains("packageReferences"))
        #expect(removed.contains("packageProductDependencies = (\n\t\t\t);"))
        _ = try PBXProj(parsing: removed)
        let pkg = proj.addRemotePackage(url: "https://github.com/apple/swift-argument-parser.git", requirement: .upToNextMajor(from: "1.5.0"))
        let product = proj.addPackageProduct("ArgumentParser", package: pkg, toTarget: target)
        let bf = try #require(proj.objects.values.first { $0.string("productRef") == product }).id
        let back = renamed(proj, [pkg: "0F0000000000000000000001", product: "0F0000000000000000000002", bf: "0A0000000000000000000003"])
        #expect(back.serialized(projectName: "Hello") == text)
    }

    @Test func requirementsRoundTrip() throws {
        let all: [SwiftPackageRequirement] = [.upToNextMajor(from: "1.0.0"), .upToNextMinor(from: "1.2.0"), .exact("2.0.1"),
                                              .range(from: "1.0.0", to: "3.0.0"), .branch("main"), .revision("0123456789abcdef")]
        var (_, proj) = try fixture()
        for r in all {
            #expect(SwiftPackageRequirement(plist: r.plist) == r)
            let id = proj.addRemotePackage(url: "https://example.com/a/\(r.kind).git", requirement: .exact("0.0.1"))
            proj.setRequirement(r, ofPackage: id)
            let again = try PBXProj(parsing: proj.serialized(projectName: "Hello"))
            #expect(again.packageReferences.first { $0.id == id }?.location == .remote(url: "https://example.com/a/\(r.kind).git", requirement: r))
        }
        let text = proj.serialized(projectName: "Hello")
        #expect(text.contains("\t\t\t\tkind = versionRange;\n\t\t\t\tmaximumVersion = 3.0.0;\n\t\t\t\tminimumVersion = 1.0.0;\n"))
        #expect(text.contains("/* XCRemoteSwiftPackageReference \"branch\" */"))
    }

    @Test func localPackageAndNewFrameworksPhase() throws {
        var (_, proj) = try fixture()
        let target = proj.targets[0].id
        // Drop the frameworks phase so adding a product creates one.
        let fw = try #require(proj.buildPhases(ofTarget: target).first { $0.isa == "PBXFrameworksBuildPhase" })
        proj.removePackage("0F0000000000000000000001")
        var t = try #require(proj[target])
        t["buildPhases"] = .array(t.references("buildPhases").filter { $0 != fw.id }.map(PlistValue.string))
        proj[target] = t
        proj[fw.id] = nil
        let local = proj.addLocalPackage(relativePath: "../Kit")
        proj.addPackageProduct("Kit", package: local, toTarget: target)
        let out = proj.serialized(projectName: "Hello")
        #expect(out.contains("isa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ../Kit;"))
        #expect(out.contains("/* XCLocalSwiftPackageReference \"../Kit\" */"))
        #expect(out.contains("/* Kit in Frameworks */ = {isa = PBXBuildFile; productRef = "))
        let phases = proj.buildPhases(ofTarget: target).map(\.isa)
        #expect(phases.firstIndex(of: "PBXFrameworksBuildPhase") == phases.firstIndex(of: "PBXSourcesBuildPhase")! + 1)
        proj.removePackage(local)
        #expect(!proj.serialized(projectName: "Hello").contains("Kit"))
    }
}
