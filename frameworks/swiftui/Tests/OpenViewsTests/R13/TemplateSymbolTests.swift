import OVRender
import Testing

// The IDE's New Project templates must not fall back to the question-mark
// stand-in (`SymbolArtwork.placeholder`): this is their list.
@Suite struct TemplateSymbolTests {
    static let names = [
        "app.badge", "archivebox", "building.columns", "camera.viewfinder", "cpu", "cpu.fill", "cube", "cube.transparent", "doc", "doc.richtext", "eye",
        "face.smiling", "gamecontroller", "gauge.with.dots.needle.33percent", "gearshape", "globe", "hammer", "macwindow", "message", "mountain.2",
        "number", "play", "play.rectangle", "point.3.connected.trianglepath.dotted", "rectangle.on.rectangle", "shippingbox",
        "shippingbox.and.arrow.backward", "sparkles.tv", "terminal", "terminal.fill", "timer", "tv", "waveform",
    ]

    @Test func everyTemplateSymbolIsDrawn() {
        for name in Self.names {
            #expect(SymbolArtwork.all[name] != nil, "\(name)")
            #expect(SymbolArtwork.all[name]?.operations.isEmpty == false, "\(name)")
        }
    }
}
