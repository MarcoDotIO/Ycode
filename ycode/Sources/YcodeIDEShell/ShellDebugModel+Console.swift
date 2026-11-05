import Foundation
import YcodeIDECore

/// Where the shell's Copy commands put text. The toolkit sets `writer`
/// (OpenViews' clipboard on Linux, the general pasteboard on macOS); tests
/// read `lastCopied`.
@MainActor
public enum ShellPasteboard {
    public static var writer: ((String) -> Void)?
    public private(set) static var lastCopied: String?

    public static func copy(_ text: String) {
        lastCopied = text
        writer?(text)
    }
}

/// The console's rows and Debug ▸ Console ▸ Copy Row (`debug.md`, the
/// macOS IDE's `copyConsoleRow…` commands): a click selects a row of the
/// console; the three Copy Row commands copy it with the visible metadata,
/// with every column Ycode has data for, or bare. The Linux console shows
/// no metadata columns, so "visible" copies the bare row there.
extension ShellDebugModel {
    /// What a Copy Row command puts in front of the row.
    public enum ConsoleRowCopy: Sendable {
        case visibleMetadata, allMetadata, withoutMetadata
    }

    /// The console's rows for the filter, one per line, in order (the rows
    /// the console view shows while it shows the run's output).
    public var consoleRows: [ConsoleRow] {
        ConsoleRows.rows(session.consoleEntries.filter { consoleFilter.includes($0.kind) })
    }

    /// The selected row, if it is still there.
    public var selectedConsoleRowValue: ConsoleRow? {
        guard let i = selectedConsoleRow else { return nil }
        let rows = consoleRows
        return rows.indices.contains(i) ? rows[i] : nil
    }

    /// The text a Copy Row command copies for the selected row (nil when
    /// none is selected).
    public func consoleRowCopyText(_ kind: ConsoleRowCopy) -> String? {
        guard let row = selectedConsoleRowValue else { return nil }
        switch kind {
        case .visibleMetadata, .withoutMetadata: return ConsoleRows.copyText(row, metadata: nil)
        case .allMetadata: return ConsoleRows.copyText(row, metadata: ConsoleRows.allMetadata)
        }
    }

    /// Copies the selected row; false when no row is selected.
    @discardableResult
    public func copyConsoleRow(_ kind: ConsoleRowCopy) -> Bool {
        guard let text = consoleRowCopyText(kind) else { return false }
        ShellPasteboard.copy(text)
        return true
    }

    /// The Copy Row command's kind.
    static func copyKind(_ c: ShellCommand) -> ConsoleRowCopy? {
        switch c {
        case .copyConsoleRowWithVisibleMetadata: .visibleMetadata
        case .copyConsoleRowWithAllMetadata: .allMetadata
        case .copyConsoleRowWithoutMetadata: .withoutMetadata
        default: nil
        }
    }
}
