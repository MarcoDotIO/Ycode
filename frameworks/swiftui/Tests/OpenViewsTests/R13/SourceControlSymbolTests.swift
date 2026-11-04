import OVRender
import Testing

// The Linux IDE's Source Control, Test and Report navigators must not fall
// back to the question-mark stand-in: the symbols they use.
@Suite struct SourceControlSymbolTests {
    static let names = [
        "externaldrive", "tray", "arrow.uturn.backward", "clock.arrow.circlepath", "square.and.pencil", "diamond", "diamond.fill",
        "checkmark.diamond.fill", "xmark.diamond.fill", "scope", "t.square", "c.square", "arrow.triangle.branch", "cloud", "tag", "folder",
        "arrow.right.circle", "checkmark.diamond", "list.bullet.rectangle", "doc.text", "hammer", "play.fill",
    ]

    @Test func everyNavigatorSymbolIsDrawn() {
        for name in Self.names {
            #expect(SymbolArtwork.all[name] != nil, "\(name)")
            #expect(SymbolArtwork.all[name]?.operations.isEmpty == false, "\(name)")
        }
    }
}
