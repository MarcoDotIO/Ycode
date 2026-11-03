import Foundation
import Testing
@testable import YcodeIDECore

/// What the app says about itself (the About window, Help ▸ Report a Bug…,
/// the icon's drawing) on macOS and Linux.
@Suite struct ProductIdentityTests {
    @Test func bugReportCarriesVersionAndPlatformAndNothingPrivate() throws {
        let url = ProductIdentity.bugReportURL()
        #expect(url.absoluteString.hasPrefix("https://github.com/MarcoDotIO/Ycode/issues/new?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }) == [
            "template": "bug_report.yml", "version": ProductIdentity.version,
            "platform": ProductIdentity.platformOption, "os": ProductIdentity.systemVersion,
        ])
        #expect(!url.absoluteString.contains(NSUserName()))
    }

    /// The query's names and the platform choice are the form's.
    @Test func bugReportMatchesTheForm() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // An rsync of ycode/ alone has no .github folder.
        guard let form = try? String(contentsOf: root.appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml"), encoding: .utf8) else { return }
        for id in ["id: version", "id: platform", "id: os"] { #expect(form.contains(id)) }
        #if arch(arm64) || os(Linux)
        #expect(form.contains(ProductIdentity.platformOption))
        #endif
    }

    @Test func systemVersionNamesNoUser() {
        #expect(!ProductIdentity.systemVersion.isEmpty)
        #expect(!ProductIdentity.systemVersion.contains(NSUserName()))
    }

    @Test func notAffiliatedAndLicenseAreStated() {
        #expect(ProductIdentity.notAffiliated.contains("not affiliated"))
        #expect(ProductIdentity.license == "MIT License")
        #expect(ProductIdentity.fullVersionText.contains(ProductIdentity.version))
    }

    @Test func experimentalNoticeSaysWhatTheSimulatorNeeds() {
        #expect(ExperimentalNotice.simulator.contains("Linux arm64"))
        #expect(ExperimentalNotice.simulator.contains("KVM"))
        #expect(ExperimentalNotice.simulator.contains("obtain yourself"))
    }

    @Test func cloneFolderNames() {
        #expect(GitRepository.cloneFolderName(for: "https://example.com/a/Widget.git") == "Widget")
        #expect(GitRepository.cloneFolderName(for: "https://example.com/a/Widget/") == "Widget")
        #expect(GitRepository.cloneFolderName(for: "git@example.com:a/Widget.git") == "Widget")
        #expect(GitRepository.cloneFolderName(for: "git@example.com:Widget.git") == "Widget")
        #expect(GitRepository.cloneFolderName(for: "/srv/git/Widget.git") == "Widget")
        #expect(GitRepository.cloneFolderName(for: "  ") == "Repository")
    }

    @Test func gitErrorsReadAsMessages() {
        let e: Error = GitRepository.GitError(description: "Cloning into 'x'...\nfatal: repository 'y' does not exist\n")
        #expect(e.localizedDescription == "repository 'y' does not exist")
    }

    @Test func openingWhatIsNotAProjectSaysSo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect {
            _ = try WorkspaceModel(url: dir)
        } throws: { error in
            error.localizedDescription.contains("is not a project, workspace or package")
        }
    }

    /// The views draw the icon from `ProductIconGeometry`; its source is the SVG.
    @Test func iconGeometryMatchesTheSVG() throws {
        typealias G = ProductIconGeometry
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let svg = root.appendingPathComponent("packaging/icon/ycode-icon.svg")
        // An rsync of ycode/ alone has no packaging folder.
        guard let text = try? String(contentsOf: svg, encoding: .utf8) else { return }
        for color in [G.fieldTop, G.fieldBottom, G.chevronColor, G.caretColor] { #expect(text.contains(color)) }
        func n(_ v: Double) -> String { String(Int(v)) }
        #expect(text.contains("stroke-width=\"\(n(G.strokeWidth))\""))
        let c = G.chevron
        #expect(text.contains("M\(n(c[0].0)) \(n(c[0].1))L\(n(c[1].0)) \(n(c[1].1))L\(n(c[2].0)) \(n(c[2].1))"))
        #expect(text.contains("M\(n(G.caret[0].0)) \(n(G.caret[0].1))V\(n(G.caret[1].1))"))
        let a = G.fieldMin, b = G.fieldMax, s = G.cornerStart, k = G.cornerControl
        #expect(text.contains("M\(n(a + s)) \(n(a))H\(n(b - s))C\(n(b - k)) \(n(a)) \(n(b)) \(n(a + k)) \(n(b)) \(n(a + s))V"))
    }
}
