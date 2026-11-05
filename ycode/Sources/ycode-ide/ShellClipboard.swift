import Foundation
import SwiftUI
import YcodeIDEShell
#if !os(Linux)
import AppKit
#endif

/// The system clipboard for the shell's Copy buttons and Copy items: on
/// Linux OpenViews' clipboard (SDL's, the one text fields use), on macOS the
/// general pasteboard.
@MainActor
enum ShellClipboard {
    static func copy(_ s: String) {
        #if os(Linux)
        OpenViewsClipboard.copy(s)
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }

    /// The clipboard's text (driver checks).
    static var string: String? {
        #if os(Linux)
        OpenViewsClipboard.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

/// A small bordered Copy button that puts `text` on the clipboard; its
/// tooltip is the text (as the macOS wizards' Copy buttons).
struct CopyButton: View {
    var text: String
    var title = "Copy"
    var target: String

    var body: some View {
        Button(title) { ShellPasteboard.copy(text) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(text)
            .shellTarget(target)
    }
}
