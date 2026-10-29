import AppKit

/// A source or resource file opened from outside Ycode (Finder, `open`, a
/// Dock drop) that no open workspace contains: it gets a window of its own
/// with the editor only (`specs/ide/reference-ui-6.md` §1.2.2, W3). A file
/// that an open workspace contains opens in that workspace's window
/// instead (`YcodeDocumentController`).
@MainActor
public final class SourceFileDocument: NSDocument {
    public static let typeName = "org.ycode.source-file"

    public override class var autosavesInPlace: Bool { false }

    /// The window controller, once made.
    public var fileWindowController: SingleFileWindowController? { windowControllers.first as? SingleFileWindowController }

    nonisolated public override func read(from url: URL, ofType typeName: String) throws {
        // The editor reads the file itself; this only checks that it is
        // text the editor can show, so a binary file fails here with the
        // document machinery's own error instead of an empty window.
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    public override func makeWindowControllers() {
        guard let url = fileURL else { return }
        let wc = SingleFileWindowController(url: url)
        addWindowController(wc)
        wc.window?.center()
    }

    /// ⌘S writes the editor's text (the editor owns the file's contents).
    public override func save(_ sender: Any?) { try? fileWindowController?.editor.save() }

    /// Edits are written when the window closes, as in a workspace window,
    /// so closing never asks.
    public override var isDocumentEdited: Bool { false }
}

/// The single-file window: one source editor (jump bar, gutter, text).
@MainActor
public final class SingleFileWindowController: NSWindowController, NSWindowDelegate {
    public static let defaultSize = NSSize(width: 900, height: 700)
    public let editor = SourceEditorController()
    public let url: URL

    public init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.minSize = NSSize(width: 400, height: 300)
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = editor
        window.setContentSize(Self.defaultSize)
        try? editor.open(url)
        // The name as the navigator shows it (Settings ▸ General ▸ File Extensions).
        let name = url.lastPathComponent, bare = (name as NSString).deletingPathExtension
        editor.pathComponents = [(Preferences.shared.fileExtensions == .hide && !bare.isEmpty ? bare : name, "doc.text")]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The title is the file's name (there is no workspace).
    public override func windowTitle(forDocumentDisplayName displayName: String) -> String { url.lastPathComponent }

    public func windowWillClose(_ notification: Notification) { try? editor.save() }
}
