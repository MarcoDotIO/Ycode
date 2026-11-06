import OVRender
import Testing

// The Linux IDE's Interface Builder editor must not fall back to the
// question-mark stand-in: its inspector tabs, outline rows and canvas bar.
@Suite struct InterfaceBuilderSymbolTests {
    static let names = [
        "person.crop.rectangle", "slider.horizontal.3", "ruler", "arrow.right.circle", "square.dashed", "cube", "rectangle.on.rectangle",
        "sidebar.left", "plus", "checkmark.circle", "moon", "iphone", "rectangle.split.2x1", "minus", "arrow.clockwise", "line.3.horizontal",
        "plus.rectangle.on.rectangle", "exclamationmark.triangle", "square.stack.3d.up", "line.3.horizontal.decrease.circle",
        "rectangle.portrait.and.arrow.right", "checkmark.circle.fill", "circle", "circle.fill", "xmark", "magnifyingglass",
        // The Library panel (B3-IB2): tabs and header toggles.
        "square.on.circle", "photo", "paintpalette", "star.square", "square.grid.2x2", "list.bullet", "sidebar.right", "chevron.down",
    ]

    @Test func everySymbolIsDrawn() {
        for name in Self.names {
            let art = SymbolArtwork.all[name]
            #expect(art != nil, "\(name)")
            #expect(art.map { !$0.operations.isEmpty } == true, "\(name)")
        }
    }
}
