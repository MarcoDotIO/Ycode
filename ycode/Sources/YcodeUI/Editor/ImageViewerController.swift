import AppKit
import ImageIO
import UniformTypeIdentifiers
import YcodeIDECore

/// The editor for an image file (`specs/ide/editor-area.md` §C.6): the
/// image scaled to fit and centred on the editor's background, with
/// "Open with Preview" under it. No gutter, minimap, frame or scroll area.
/// While the file decodes, "Loading…" is centred in its place.
@MainActor
public final class ImageViewerController: NSViewController {
    public let url: URL
    /// The decoded image's properties (nil until it has loaded).
    public private(set) var properties: ImageFileProperties?
    /// Called once the image has decoded (the inspector fills in its values).
    public var onLoaded: ((ImageFileProperties) -> Void)?
    /// The image as shown, and the "Open with Preview" button (tests).
    public let imageView = FittedImageView()
    public let previewButton = NSButton(title: "Open with Preview", target: nil, action: nil)
    public let loadingLabel = NSTextField(labelWithString: "Loading…")
    private var loading: Task<Void, Never>?

    public init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whether Ycode shows `url` in the image viewer: any image type the
    /// system can decode (PNG, JPEG, GIF, TIFF, HEIC, PDF is not one).
    public static func handles(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    public override func loadView() {
        let root = ImageViewerBackground()
        loadingLabel.font = .systemFont(ofSize: 13)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        previewButton.target = self
        previewButton.action = #selector(openWithPreview(_:))
        ImageViewerLayout.stylePreviewButton(previewButton)
        imageView.isHidden = true
        for v in [imageView, loadingLabel, previewButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let g = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: g.topAnchor, constant: ImageViewerLayout.topMargin),
            imageView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: ImageViewerLayout.sideMargin),
            imageView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -ImageViewerLayout.sideMargin),
            imageView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -ImageViewerLayout.bottomMargin),
            loadingLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            previewButton.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            previewButton.heightAnchor.constraint(equalToConstant: ImageViewerLayout.buttonHeight),
            previewButton.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -ImageViewerLayout.buttonBottomGap),
        ])
        view = root
        load()
    }

    /// Decodes the file off the main thread; the image is drawn in one
    /// frame when it is ready, with no fade.
    private func load() {
        let url = url
        loading = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { ImageFileProperties.decode(url) }.value
            guard let self, !Task.isCancelled else { return }
            self.loadingLabel.isHidden = true
            guard let decoded else {
                self.loadingLabel.stringValue = "Unable to open the image"
                self.loadingLabel.isHidden = false
                return
            }
            self.properties = decoded.properties
            self.imageView.image = NSImage(cgImage: decoded.image, size: decoded.properties.pointSize)
            self.imageView.isHidden = false
            self.onLoaded?(decoded.properties)
        }
    }

    /// Waits for the image to decode (tests).
    public func loaded() async { await loading?.value }

    @objc private func openWithPreview(_ sender: Any?) {
        guard view.window?.isVisible == true else { return }
        let config = NSWorkspace.OpenConfiguration()
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    deinit { MainActor.assumeIsolated { loading?.cancel() } }
}

/// The image viewer's geometry (`editor-area.md` §C.6): the fit box is the
/// editor's height less 20 above and 60 below; the button is 20 tall,
/// 20 above the bottom bar, so 20 below the box.
public enum ImageViewerLayout {
    public static let topMargin: CGFloat = 20
    public static let bottomMargin: CGFloat = 60
    public static let sideMargin: CGFloat = 20
    public static let buttonHeight: CGFloat = 20
    public static let buttonBottomGap: CGFloat = 20

    /// The image's drawn rect in a box: scaled down to fit (never up) and
    /// centred.
    public static func fittedRect(imageSize: NSSize, in box: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(1, box.width / imageSize.width, box.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// A flat filled button with no border (#ECECEC in light).
    @MainActor
    static func stylePreviewButton(_ b: NSButton) {
        b.bezelStyle = .push
        b.isBordered = false
        b.wantsLayer = true
        b.font = .systemFont(ofSize: 12)
        b.contentTintColor = .labelColor
        b.layer?.cornerRadius = 5
        b.layer?.backgroundColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0xEC / 255.0, alpha: 1)
        }.cgColor
        b.setContentHuggingPriority(.required, for: .horizontal)
        // The title's own width plus 10 on each side.
        let w = (b.title as NSString).size(withAttributes: [.font: b.font as Any]).width + 20
        b.widthAnchor.constraint(equalToConstant: ceil(w)).isActive = true
    }
}

/// An image drawn scaled down to fit its bounds and centred.
public final class FittedImageView: NSView {
    public var image: NSImage? { didSet { needsDisplay = true } }
    /// Where the image is drawn, in this view's coordinates.
    public var imageRect: NSRect { image.map { ImageViewerLayout.fittedRect(imageSize: $0.size, in: bounds) } ?? .zero }
    public override var isFlipped: Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }
}

/// The editor's background behind the image viewer.
final class ImageViewerBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.backgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

/// What the File inspector's Image Properties section shows.
public struct ImageFileProperties: Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var dpi: Double
    public var colorSpace: String
    public var hasAlpha: Bool
    /// Whether the file records a resolution (`editor-area.md` §D.8:
    /// "--" when it records none).
    public var recordsResolution = true

    /// The size in points: pixels at the file's resolution (72 dpi is 1:1).
    public var pointSize: NSSize {
        let scale = dpi > 0 ? 72 / dpi : 1
        return NSSize(width: Double(pixelWidth) * scale, height: Double(pixelHeight) * scale)
    }

    /// The inspector rows: Dimensions, Resolution, Color Space, Alpha Channel.
    public var rows: [(String, String)] {
        [("Dimensions", "\(pixelWidth) × \(pixelHeight) pixels"),
         ("Resolution", recordsResolution ? "\(Int(dpi.rounded())) × \(Int(dpi.rounded())) DPI" : "--"),
         ("Color Space", colorSpace),
         ("Alpha Channel", hasAlpha ? "Yes" : "No")]
    }

    /// The rows before the image has decoded.
    public static let placeholderRows: [(String, String)] = ["Dimensions", "Resolution", "Color Space", "Alpha Channel"].map { ($0, "--") }

    struct Decoded: @unchecked Sendable {
        let image: CGImage
        let properties: ImageFileProperties
    }

    static func decode(_ url: URL) -> Decoded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let model = (props[kCGImagePropertyColorModel] as? String) ?? "RGB"
        let alpha: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        var properties = ImageFileProperties(pixelWidth: image.width, pixelHeight: image.height, dpi: dpi, colorSpace: model, hasAlpha: alpha)
        properties.recordsResolution = props[kCGImagePropertyDPIWidth] != nil
        return Decoded(image: image, properties: properties)
    }
}
