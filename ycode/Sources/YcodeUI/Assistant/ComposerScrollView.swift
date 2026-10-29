import AppKit

/// The scroll view around a multi-line message field (the Coding
/// Assistant pane's composer). With the Liquid Glass design (macOS 26 and
/// later) it is a rounded field — continuous corners, the text background
/// and a hairline in the separator color, heavier with Increase Contrast —
/// instead of the sunken bezel, which earlier systems keep
/// (`specs/ide/liquid-glass-ycode.md` §8).
@MainActor
final class ComposerScrollView: NSScrollView {
    static let cornerRadius: CGFloat = 8
    private var contrastObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autohidesScrollers = true
        guard #available(macOS 26, *) else { borderType = .bezelBorder; return }
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStroke() }
        }
        updateStroke()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStroke()
    }

    /// The stroke's color is resolved under the view's appearance (a layer
    /// color does not follow light and dark by itself).
    private func updateStroke() {
        guard #available(macOS 26, *), let layer else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = (contrast ? NSColor.secondaryLabelColor : NSColor.separatorColor).cgColor
        }
        layer.borderWidth = 1
    }
}
