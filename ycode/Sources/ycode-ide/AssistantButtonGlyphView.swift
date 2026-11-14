import Foundation
import SwiftUI
import YcodeIDECore

/// The toolbar's coding assistant button on the Linux IDE (council round
/// 9, row 214; round 10, row 239; `AssistantButtonGlyph`): the shared
/// bubble outline stroked with one conic gradient centred on the bubble,
/// clockwise from the top through the measured stops (one pixel wide at
/// 1x), the plus with its own linear gradient, in a 36-point glass circle whose
/// light capsule darkens to #F2F2F2 under the pointer (dark: no change),
/// as the macOS `AssistantToolbarButton`.
struct AssistantGlyphView: View {
    typealias G = AssistantButtonGlyph
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    static func path(_ elements: [G.Element]) -> Path {
        var p = Path()
        for e in elements {
            switch e {
            case let .move(x, y): p.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): p.addLine(to: CGPoint(x: x, y: y))
            case let .quad(x, y, cx, cy): p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case let .curve(x, y, c1x, c1y, c2x, c2y):
                p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    /// The stops as the toolkit's gradient: location = degrees ÷ 360.
    static func gradient(dark: Bool) -> Gradient {
        Gradient(stops: G.stops.map { s in
            let v = dark ? s.dark : s.light
            return Gradient.Stop(color: Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255,
                                              blue: Double(v & 0xFF) / 255),
                                 location: CGFloat(s.degrees / 360))
        })
    }

    var body: some View {
        let dark = scheme == .dark
        // Row 239: the box on whole pixels wherever the circle lands, so the
        // outline's sides each fall on one pixel column or row at 1x.
        GeometryReader { g in
            let o = g.frame(in: .global).origin, k = max(1, displayScale)
            let dx = ((o.x * k).rounded() - o.x * k) / k, dy = ((o.y * k).rounded() - o.y * k) / k
            Canvas { ctx, _ in
                ctx.translateBy(x: dx, y: dy)
                // Clockwise from the top: the conic starts at -90° (the toolkit's 0° is the positive x axis).
                let shading = GraphicsContext.Shading.conicGradient(Self.gradient(dark: dark), center: CGPoint(x: G.center.x, y: G.center.y),
                                                                    angle: .degrees(-90))
                let outline = CGFloat(G.bubbleStroke(scale: Double(displayScale)))
                ctx.stroke(Self.path(G.bubble), with: shading, style: StrokeStyle(lineWidth: outline, lineCap: .round, lineJoin: .round))
                // The plus has its own linear gradient, top to bottom.
                let (top, bottom) = G.plusInkY
                let plus = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [AssistantCircleButton.fill(G.plusTop), AssistantCircleButton.fill(G.plusBottom)]),
                    startPoint: CGPoint(x: G.plusCenter.x, y: top), endPoint: CGPoint(x: G.plusCenter.x, y: bottom))
                ctx.stroke(Self.path(G.plus), with: plus, style: StrokeStyle(lineWidth: CGFloat(G.plusStroke), lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: CGFloat(G.width), height: CGFloat(G.height))
        .accessibilityHidden(true)
    }
}

/// New Conversation's glass circle: the glyph, the capsule's fill at rest
/// and under the pointer (row 214), a pressed state of Ycode's own.
struct AssistantCircleButton: View {
    typealias G = AssistantButtonGlyph
    var help: String
    var target: String
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    static func fill(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var body: some View {
        let c = ShellColors(scheme)
        let dark = scheme == .dark
        Button(action: action) {
            AssistantGlyphView()
                .frame(width: CGFloat(G.diameter), height: CGFloat(G.diameter))
                .background {
                    Circle().fill(Self.fill(G.capsule(dark: dark, hovered: hovered)))
                        .overlay { Circle().stroke(c.capsuleStroke, lineWidth: 1) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(AssistantPressStyle())
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .shellTarget(target)
    }
}

/// Pressed: the capsule a little darker (Ycode's own; the reference's was
/// not captured).
struct AssistantPressStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        configuration.label
            .overlay {
                if configuration.isPressed {
                    Circle().fill(Color.black.opacity(AssistantButtonGlyph.pressedOverlayOpacity(dark: dark)))
                }
            }
    }
}
