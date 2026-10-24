import Foundation
import Testing
import YcodePlist
@testable import YcodeProject

/// Adding and deleting targets (reference-ui-5.md §11.1.2, P2).
@Suite struct TargetMutationTests {
    func fixture() throws -> (text: String, proj: PBXProj) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Hello.xcodeproj/project", withExtension: "pbxproj"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return (text, try PBXProj(parsing: text))
    }

    static func unitTests(host: String?) -> PBXProj.NewTarget {
        .init(name: "HelloTests", productType: "com.apple.product-type.bundle.unit-test", productPath: "HelloTests.xctest",
              productFileType: "wrapper.cfbundle", settings: [("PRODUCT_NAME", "$(TARGET_NAME)"), ("GENERATE_INFOPLIST_FILE", "YES")],
              phases: ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"], dependency: host, sourceFolder: "HelloTests")
    }

    @Test func addTargetBuildsTheObjectGraph() throws {
        var (_, proj) = try fixture()
        let host = try #require(proj.targets.first)
        let id = proj.addTarget(Self.unitTests(host: host.id))
        let text = proj.serialized(projectName: "Hello")
        let back = try PBXProj(parsing: text)
        #expect(back.serialized(projectName: "Hello") == text)
        let t = try #require(back[id])
        #expect(t.isa == "PBXNativeTarget" && t.string("name") == "HelloTests" && t.string("productType") == "com.apple.product-type.bundle.unit-test")
        #expect(back.project?.references("targets").last == id)
        // One configuration per project configuration, the project's default.
        let projectConfigs = back.buildConfigurations(listID: back.project?.string("buildConfigurationList")).compactMap { $0.string("name") }
        let configs = back.buildConfigurations(listID: t.string("buildConfigurationList"))
        #expect(configs.compactMap { $0.string("name") } == projectConfigs)
        #expect(configs.allSatisfy { $0["buildSettings"]?.dictionary?["GENERATE_INFOPLIST_FILE"] == "YES" })
        #expect(back.buildPhases(ofTarget: id).map(\.isa) == ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"])
        // Product in the products group.
        let product = try #require(t.string("productReference").flatMap { back[$0] })
        #expect(product.string("path") == "HelloTests.xctest" && product.string("sourceTree") == "BUILT_PRODUCTS_DIR")
        #expect(back[back.project?.string("productRefGroup") ?? ""]?.references("children").contains(product.id) == true)
        // The dependency with its proxy.
        let dep = try #require(t.references("dependencies").first.flatMap { back[$0] })
        #expect(dep.isa == "PBXTargetDependency" && dep.string("target") == host.id)
        let proxy = try #require(dep.string("targetProxy").flatMap { back[$0] })
        #expect(proxy.string("proxyType") == "1" && proxy.string("remoteGlobalIDString") == host.id && proxy.string("remoteInfo") == "Hello")
        #expect(text.contains("/* PBXContainerItemProxy */") && text.contains("Build configuration list for PBXNativeTarget \"HelloTests\""))
    }

    @Test func addThenRemoveRestoresTheBytes() throws {
        var (text, proj) = try fixture()
        let host = try #require(proj.targets.first)
        let id = proj.addTarget(Self.unitTests(host: host.id))
        #expect(proj.serialized(projectName: "Hello") != text)
        proj.removeTarget(id)
        #expect(proj.serialized(projectName: "Hello") == text)
    }

    /// Before object version 77 the target owns no folder: adding then
    /// removing it restores the bytes, and `addSourceGroup` adds a group.
    @Test func olderProjectsGetNoFolderFromAddTarget() throws {
        let (text77, _) = try fixture()
        let text = text77.replacingOccurrences(of: "objectVersion = 77;", with: "objectVersion = 46;")
        var proj = try PBXProj(parsing: text)
        let id = proj.addTarget(Self.unitTests(host: proj.targets.first?.id))
        #expect(proj[id]?["fileSystemSynchronizedGroups"] == nil)
        #expect(!proj.objects.values.contains { $0.string("path") == "HelloTests" && $0.isa != "PBXFileReference" })
        proj.removeTarget(id)
        #expect(proj.serialized(projectName: "Hello") == text)
        let g = proj.addSourceGroup(path: "Extra")
        let main = try #require(proj.project?.string("mainGroup").flatMap { proj[$0] })
        #expect(main.references("children").suffix(2).first == g && proj[g]?.isa == "PBXGroup")
    }

    @Test func removeTargetDropsDependentsAndAttributes() throws {
        var (_, proj) = try fixture()
        let host = try #require(proj.targets.first)
        let tests = proj.addTarget(Self.unitTests(host: host.id))
        // Record TargetAttributes for both, with the test target naming its host.
        var p = try #require(proj.project)
        var attrs = p["attributes"]?.dictionary ?? PlistDictionary()
        let hostEntry: PlistValue = ["CreatedOnToolsVersion": "16.0"]
        let testEntry: PlistValue = .dictionary(PlistDictionary([("TestTargetID", PlistValue.string(host.id))]))
        attrs["TargetAttributes"] = .dictionary(PlistDictionary([(host.id, hostEntry), (tests, testEntry)]))
        p["attributes"] = .dictionary(attrs)
        proj[p.id] = p
        let before = proj.objects.count
        proj.removeTarget(host.id)
        #expect(proj[host.id] == nil && proj.project?.references("targets") == [tests])
        // The test target's dependency on it is gone with its proxy.
        #expect(proj[tests]?.references("dependencies") == [])
        #expect(!proj.objects.values.contains { $0.isa == "PBXContainerItemProxy" || $0.isa == "PBXTargetDependency" })
        let ta = proj.project?["attributes"]?.dictionary?["TargetAttributes"]?.dictionary
        #expect(ta?[host.id] == nil && ta?[tests]?.dictionary?["TestTargetID"] == nil)
        // No dangling references remain.
        let text = proj.serialized(projectName: "Hello")
        let back = try PBXProj(parsing: text)
        for o in back.objects.values {
            for (_, v) in o.attributes {
                for r in ([v.string].compactMap { $0 } + (v.array?.compactMap(\.string) ?? [])) where r.count == 24 && r.allSatisfy(\.isHexDigit) {
                    #expect(back[r] != nil || r == host.id && false, "dangling \(r) in \(o.id)")
                }
            }
        }
        #expect(proj.objects.count < before)
    }

    /// Over the local corpus (see README): adding then deleting a target
    /// restores every project byte for byte.
    @Test(.enabled(if: !PBXProjCorpusTests.entries.isEmpty, "no local corpus manifest"), arguments: PBXProjCorpusTests.entries)
    func corpusAddRemoveTarget(_ entry: String) throws {
        let (file, name) = PBXProj.locate(String(entry.dropFirst(2)))
        var proj = try PBXProj(parsing: try String(contentsOf: file, encoding: .utf8))
        let before = proj.serialized(projectName: name)
        let id = proj.addTarget(Self.unitTests(host: proj.targets.first?.id))
        proj.removeTarget(id)
        let after = proj.serialized(projectName: name)
        #expect(after == before, "\(file.path): \(firstDifference(before, after))")
    }
}


/// The first line where two texts differ (test messages).
func firstDifference(_ a: String, _ b: String) -> String {
    let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
    for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : nil) != (i < y.count ? y[i] : nil) {
        return "line \(i + 1): \(i < x.count ? x[i] : "<end>") | \(i < y.count ? y[i] : "<end>")"
    }
    return "same"
}
