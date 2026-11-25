import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject

/// A project fresh from any of Ycode's New Project templates carries the
/// running IDE version in `LastUpgradeCheck` and so raises no "Update to
/// recommended settings" warning (`specs/ide/issues.md` §1 item 5), as the
/// reference's own templates do, although it leaves keys such as
/// `DEAD_CODE_STRIPPING` unset (the templates add nothing to avoid it).
@Suite struct TemplateRecommendedSettingsTests {
    typealias ID = TemplateOptionID

    @Test func everyTemplateProjectHasTheRecommendedSettings() throws {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-template-recommended-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: top) }
        var checked = 0
        var report: [String] = []
        for d in ProjectTemplates.all where d.isAvailable && !d.isPackage {
            var values = [ID.productName: "Fresh", ID.organizationIdentifier: "org.ycode.tests"]
            if d.generator == "audioUnitApp" { values.merge([ID.subtypeCode: "demo", ID.manufacturerCode: "Demo", ID.organizationName: "Ycode"]) { a, _ in a } }
            let dir = top.appendingPathComponent(d.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let opened = try? ProjectGenerator.create(d, d.makeForm(values), in: dir) else { continue }
            let xcodeproj: URL
            if opened.pathExtension == "xcodeproj" {
                xcodeproj = opened
            } else if let found = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "xcodeproj" }) {
                xcodeproj = found
            } else { continue }
            let proj = try PBXProj(contentsOf: xcodeproj)
            let changes = RecommendedSettings.changes(in: proj, projectName: xcodeproj.deletingPathExtension().lastPathComponent,
                                                      projectDirectory: proj.projectDirectory(xcodeprojURL: xcodeproj))
            checked += 1
            if !changes.isEmpty || RecommendedSettings.lastUpgradeCheck(proj) != RecommendedSettings.ideVersionDigits {
                report.append("\(d.id): \(RecommendedSettings.lastUpgradeCheck(proj) ?? "no LastUpgradeCheck") \(changes.map(\.title))")
            }
        }
        // The other entry points: the untitled App (Welcome's App row), the
        // iOS App template, and `ProjectTemplate`'s macOS App and Command
        // Line Tool.
        var legacy: [URL] = [try UntitledAppProject.create(in: top.appendingPathComponent("untitled")).project]
        var o = ProjectOptions()
        o.productName = "Phone"
        legacy.append(try IOSAppTemplate.create(options: o, in: top.appendingPathComponent("legacy-ios")))
        for t in [ProjectTemplate.app, .commandLineTool] {
            legacy.append(try t.create(name: "Old", organization: "org.ycode.tests", in: top.appendingPathComponent("legacy-\(t.rawValue.count)")))
        }
        for x in legacy where x.pathExtension == "xcodeproj" {
            let proj = try PBXProj(contentsOf: x)
            let changes = RecommendedSettings.changes(in: proj, projectName: x.deletingPathExtension().lastPathComponent,
                                                      projectDirectory: proj.projectDirectory(xcodeprojURL: x))
            checked += 1
            if !changes.isEmpty || RecommendedSettings.lastUpgradeCheck(proj) != RecommendedSettings.ideVersionDigits {
                report.append("\(x.lastPathComponent): \(RecommendedSettings.lastUpgradeCheck(proj) ?? "no LastUpgradeCheck") \(changes.map(\.title))")
            }
        }
        #expect(checked > 10)
        // The templates match the reference's settings: no key added to
        // pass the check (the gate does it).
        #expect(!ProjectRecipe.common().contains { $0.0 == "DEAD_CODE_STRIPPING" })
        // The version the templates write is the one the check compares.
        #expect(ProjectRecipe.toolsVersionDigits == RecommendedSettings.ideVersionDigits)
        #expect(report.isEmpty, "\(report.joined(separator: "\n"))")
    }
}
