import Foundation
import OVRender

// Rendering views to pixels without a window: the headless back end
// (round R5) and `ImageRenderer`. A view graph is laid out, lowered to a
// display list and rasterised by ThorVG on the CPU (OVRender).

/// Headless rendering of a view into pixels (tests, previews, `ycode
/// preview --render`).
@MainActor
package enum HeadlessRenderer {
    /// Lays `view` out as the content of a window of `size` points (no safe
    /// area) and renders it at `scale` pixels per point.
    package static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, colorScheme: ColorScheme = .light,
                                        background: RenderColor? = nil,
                                        environment: (inout EnvironmentValues) -> Void = { _ in }) -> PixelImage {
        let graph = makeGraph(view, mode: .window(size, safeAreaInsets: EdgeInsets()), scale: scale, colorScheme: colorScheme,
                              environment: environment)
        graph.update()
        let px = PixelSize(width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)))
        let bg = background ?? (colorScheme == .dark ? .black : .white)
        return SoftwareRasterizer().render(RenderFrame(displayList: graph.displayList(), scale: Double(scale), background: bg), size: px)
    }

    package static func makeGraph<V: View>(_ view: V, mode: HostLayout.Mode, scale: CGFloat, colorScheme: ColorScheme,
                                           environment: (inout EnvironmentValues) -> Void = { _ in }) -> ViewGraph {
        var env = EnvironmentValues()
        env.displayScale = scale
        env.colorScheme = colorScheme
        environment(&env)
        var symbols = OpenSymbolProvider()
        symbols.displayScale = scale
        return ViewGraph(rootView: view, environment: env, layout: HostLayout(mode, symbols: symbols))
    }
}

/// Renders a view to an image. OpenViews has no `CGImage`/`UIImage` on
/// Linux; the image is available as PNG data (`pngData`), a Ycode addition.
@MainActor
public final class ImageRenderer<Content: View>: ObservableObject {
    public var content: Content
    public var label: Text?
    /// The proposal for the root view (unspecified: its ideal size).
    public var proposedSize: ProposedViewSize = .unspecified
    /// Pixels per point.
    public var scale: CGFloat = 1
    public var isOpaque = false

    public init(content: Content) { self.content = content }

    /// The rendered pixels (premultiplied RGBA8) and the view's size in
    /// points.
    package func renderPixels(colorScheme: ColorScheme = .light) -> (PixelImage, CGSize)? {
        let graph = HeadlessRenderer.makeGraph(content, mode: .proposal(proposedSize), scale: scale, colorScheme: colorScheme)
        graph.update()
        guard let size = graph.layoutResult?.root.placedSize, size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else { return nil }
        let px = PixelSize(width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)))
        let bg: RenderColor = isOpaque ? (colorScheme == .dark ? .black : .white) : .clear
        let img = SoftwareRasterizer().render(RenderFrame(displayList: graph.displayList(), scale: Double(scale), background: bg), size: px)
        return (img, size)
    }

    /// The view rendered as a PNG file's bytes, or nil when it has no area.
    public var pngData: Data? { renderPixels().map { PNGCodec.encode($0.0) } }

    /// Renders the view and hands its size and a drawing function to
    /// `renderer`; the drawing function draws the view into a graphics
    /// context.
    public func render(rasterizationScale: CGFloat = 1, renderer: (CGSize, (inout GraphicsContext) -> Void) -> Void) {
        let graph = HeadlessRenderer.makeGraph(content, mode: .proposal(proposedSize), scale: scale * rasterizationScale, colorScheme: .light)
        graph.update()
        let size = graph.layoutResult?.root.placedSize ?? .zero
        let list = graph.displayList()
        renderer(size) { ctx in ctx.append(list) }
    }
}
