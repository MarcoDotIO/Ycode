import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Unsaved text kept outside the document, so a crash or a killed process does
/// not lose it. One private file per document under the user's state folder;
/// it goes when the text is saved or the user gives it up. Only ever read
/// back into a buffer, as an edit the user can undo.
public struct EditorRecovery: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        /// The hash of what was on disk when the text was edited.
        public var baseHash: UInt64
        public var text: String
    }

    public let directory: String

    public init(directory: String) { self.directory = directory }

    /// `$XDG_STATE_HOME/ycode/recovery`, by default under `~/.local/state`;
    /// on macOS under Application Support.
    public static var standard: EditorRecovery {
        let env = ProcessInfo.processInfo.environment
        #if os(macOS)
        let base = NSHomeDirectory() + "/Library/Application Support/Ycode"
        #else
        let base = (env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/state") + "/ycode"
        #endif
        return EditorRecovery(directory: base + "/recovery")
    }

    private func file(for path: String) -> String {
        directory + "/" + String(EditorFile.hash(Data(path.utf8)), radix: 16) + ".json"
    }

    /// Keeps `text` for `path`. Failing is not an error the user can act on:
    /// the buffer still holds the text, so it returns false and that is all.
    @discardableResult
    public func keep(path: String, baseHash: UInt64, text: String) -> Bool {
        guard let data = try? JSONEncoder().encode(Entry(path: path, baseHash: baseHash, text: text)) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let target = file(for: path)
            if !FileManager.default.fileExists(atPath: target) {
                guard FileManager.default.createFile(atPath: target, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            }
            try EditorFile.writeAtomically(data, to: target)
            return true
        } catch {
            return false
        }
    }

    /// What is kept for `path`.
    public func entry(for path: String) -> Entry? {
        guard let data = FileManager.default.contents(atPath: file(for: path)),
              let e = try? JSONDecoder().decode(Entry.self, from: data), e.path == path else { return nil }
        return e
    }

    public func discard(path: String) { try? FileManager.default.removeItem(atPath: file(for: path)) }
}
