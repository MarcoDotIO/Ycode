import Foundation
import Testing
import YcodeBuild
import YcodeEditorKit
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Council round 8, group A, rows 197 and 198 on the Linux IDE's model and
/// the values both IDEs share (`specs/ide/fidelity-council.md`): the open
/// file's navigator selection and the current-line band across an
/// appearance change, and the narrow toolbar's collapsed issue capsule.
@MainActor
@Suite(.serialized) struct CouncilR8ChromeShellTests {
    /// Row 197 (I04): the open file's row selected and the caret on a line;
    /// the appearance goes Dark → Light → Dark. The selection, the open
    /// file and the caret's line stay, and the band is #353535 on #262626
    /// in dark and #EEEEEE on white in light.
    @Test func selectionAndBandSurviveAnAppearanceChange() throws {
        let saved = Preferences.shared
        defer { Preferences.shared = saved }
        let suite = "ycode-r8-appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Preferences.shared = Preferences(defaults: defaults)
        Preferences.shared.appearance = .dark

        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        let file = pkg.path("Sources/DemoCore/Greeting.swift")
        let ids = try #require(m.root.idPath(to: file))
        for id in ids.dropLast() { m.setExpanded(id, true) }
        m.selection = ids.last
        let buffer = try #require(m.editor?.buffer)
        #expect(m.editor?.path == file)
        buffer.setCaret(40)
        let line = buffer.caretLine
        #expect(line > 0)

        for mode in [Preferences.Appearance.light, .dark, .light] {
            Preferences.shared.appearance = mode
            m.preferencesChanged()
            #expect(m.selection == ids.last, "\(mode): selection \(m.selection ?? "-")")
            #expect(m.editor?.path == file && m.editor?.buffer === buffer, "\(mode): editor \(m.editor?.path ?? "-")")
            #expect(buffer.caretLine == line, "\(mode): caret line \(buffer.caretLine)")
            let p = SourcePalette.forAppearance(dark: mode == .dark, theme: Preferences.shared.theme)
            let want = mode == .dark ? ("#353535", "#262626") : ("#EEEEEE", "#FFFFFF")
            #expect(p.currentLine.hex == want.0 && p.background.hex == want.1, "\(mode): band \(p.currentLine.hex) on \(p.background.hex)")
        }
    }

    /// Row 198 (N02): at 1100 points with an error and a warning the issue
    /// capsule holds the error's octagon alone, centred in a round capsule
    /// 39 × 36 of its own; wide, both kinds with their counts.
    @Test func narrowIssuesCollapseToTheMostSevereGlyph() {
        let k = IssueSummary.Capsule.self
        let both = IssueSummary([Diagnostic(severity: .error, message: "e"), Diagnostic(severity: .warning, message: "w")])
        let digit: (String) -> Double = { Double($0.count) * 6 }
        let shown = k.shownParts(both.parts, symbolsOnly: true)
        #expect(shown == [.init(kind: .error, count: 1)])
        #expect(shown.first?.kind.collapsedSymbol == "xmark.octagon.fill")
        #expect(k.width(both.parts, symbolsOnly: true, countWidth: digit) == 39 && k.collapsedWidth == 39 && k.height == 36)
        #expect(abs(k.collapsedSymbolX() * 2 + k.symbolWidth - k.collapsedWidth) < 0.001)
        // A warning alone keeps its triangle; wide, every kind with its count.
        let warn = IssueSummary([Diagnostic(severity: .warning, message: "w")])
        #expect(k.shownParts(warn.parts, symbolsOnly: true).first?.kind.collapsedSymbol == IssueSummary.Kind.warning.symbol)
        #expect(k.shownParts(both.parts, symbolsOnly: false).map(\.kind) == [.error, .warning])
        #expect(k.width(both.parts, symbolsOnly: false, countWidth: digit) == 111)
    }
}
