import Foundation

/// The image editor's geometry and timing (`specs/ide/editor-area.md`
/// §C.6, E.3, F.8; `fidelity-council.md` rows 72 and 109), shared by the
/// macOS IDE (`ImageViewerController`) and the Linux IDE (`ImageEditorView`):
/// the image scaled down to fit (never up) and centred in a box 20 below
/// the jump bar, 20 from each side and 60 above the bottom bar; a 20-point
/// button 20 above the bottom bar; the switch to the editor at once, the
/// image when it has decoded, "Loading…" only when it still has not after
/// about 450 ms.
public enum ImageEditorMetrics {
    public static let topMargin = 20.0
    public static let bottomMargin = 60.0
    public static let sideMargin = 20.0
    public static let buttonHeight = 20.0
    public static let buttonBottomGap = 20.0
    /// The button's title runs this far inside each end.
    public static let buttonTitleInset = 10.0
    public static let buttonCornerRadius = 5.0
    public static let buttonFontSize = 12.0
    /// "Loading…" waits this long for the image.
    public static let loadingDelay: TimeInterval = 0.45
    /// What the editor says when the file cannot be decoded.
    public static let failureText = "Unable to open the image"

    /// The box the image fits in, for an editor area `width` × `height`
    /// under the jump bar: (x, y, width, height).
    public static func fitBox(width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        (sideMargin, topMargin, max(0, width - 2 * sideMargin), max(0, height - topMargin - bottomMargin))
    }

    /// The image's drawn rect in a box: scaled down to fit (never up) and
    /// centred.
    public static func fittedRect(imageWidth: Double, imageHeight: Double,
                                  box: (x: Double, y: Double, width: Double, height: Double)) -> (x: Double, y: Double, width: Double, height: Double) {
        guard imageWidth > 0, imageHeight > 0, box.width > 0, box.height > 0 else { return (0, 0, 0, 0) }
        let scale = min(1, box.width / imageWidth, box.height / imageHeight)
        let w = imageWidth * scale, h = imageHeight * scale
        return (box.x + box.width / 2 - w / 2, box.y + box.height / 2 - h / 2, w, h)
    }
}
