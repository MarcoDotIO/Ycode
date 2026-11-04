import Foundation
import Observation
import YcodeSyntax

/// An open file: its buffer, how it maps to disk, and what is on disk now.
@Observable
public final class EditorDocument {
    public let path: String
    public let buffer: EditorBuffer
    @ObservationIgnored public private(set) var format: EditorFileFormat
    @ObservationIgnored public private(set) var stamp: EditorDiskStamp?
    /// Why the file is read-only, else nil.
    public private(set) var readOnlyReason: String?
    /// What differs on disk from what the buffer was loaded from or saved to.
    public private(set) var diskChange: DiskChange?
    /// What a view keeps with the document (its scroll position).
    @ObservationIgnored public var viewState: AnyObject?

    public enum DiskChange: Equatable, Sendable {
        case modified, deleted
    }

    public enum SaveResult: Equatable, Sendable {
        case saved
        /// The file changed on disk since it was loaded; nothing was written.
        case conflict(DiskChange)
        case failed(String)
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var isDirty: Bool { buffer.isDirty }

    public init(path: String, buffer: EditorBuffer, format: EditorFileFormat, stamp: EditorDiskStamp?, readOnlyReason: String? = nil) {
        self.path = path
        self.buffer = buffer
        self.format = format
        self.stamp = stamp
        self.readOnlyReason = readOnlyReason
        buffer.isReadOnly = readOnlyReason != nil
    }

    /// Opens `path`; nil and a message when it can't be shown as text.
    public static func open(path: String, typingOptions: TypingOptions = TypingOptions()) -> (document: EditorDocument?, message: String?) {
        let language = SyntaxLanguage(fileName: (path as NSString).lastPathComponent)
        switch EditorFile.load(path: path) {
        case .unavailable(let m):
            return (nil, m)
        case .text(let t, let f, let s):
            return (EditorDocument(path: path, buffer: EditorBuffer(text: t, language: language, typingOptions: typingOptions), format: f, stamp: s), nil)
        case .readOnly(let t, let reason, let s):
            return (EditorDocument(path: path, buffer: EditorBuffer(text: t, language: language, typingOptions: typingOptions),
                                   format: EditorFileFormat(), stamp: s, readOnlyReason: reason), nil)
        }
    }

    // MARK: Saving

    /// Writes the buffer to disk. With a change on disk it writes nothing
    /// and says so, unless `overwrite`. On any failure the buffer stays as
    /// it is, dirty.
    @discardableResult
    public func save(overwrite: Bool = false) -> SaveResult {
        guard readOnlyReason == nil else { return .failed(readOnlyReason ?? "Read-only") }
        if !overwrite {
            checkDisk()
            if let c = diskChange, c != .deleted || stamp != nil { return .conflict(c) }
        }
        do {
            stamp = try EditorFile.writeAtomically(EditorFile.encode(buffer.text, format: format), to: path)
            diskChange = nil
            buffer.breakUndoGroup()
            buffer.markSaved()
            return .saved
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: Changes on disk

    /// Compares the disk with what was last read or written; updates
    /// `diskChange`. A touched file with the same bytes is no change.
    @discardableResult
    public func checkDisk() -> DiskChange? {
        guard let stamp else {
            diskChange = nil
            return nil
        }
        if EditorFile.looksUnchanged(path: path, stamp: stamp) {
            if diskChange != nil { diskChange = nil }
            return nil
        }
        guard FileManager.default.fileExists(atPath: path) else {
            if diskChange != .deleted { diskChange = .deleted }
            return .deleted
        }
        guard let data = FileManager.default.contents(atPath: path) else { return diskChange }
        if EditorFile.hash(data) == stamp.contentHash {
            self.stamp = EditorFile.stamp(path: path, data: data)
            if diskChange != nil { diskChange = nil }
            return nil
        }
        if diskChange != .modified { diskChange = .modified }
        return .modified
    }

    /// Replaces the buffer with the file's bytes: an undoable edit of what
    /// differs, the caret kept in place. False if the file can't be read as
    /// text (the buffer is untouched).
    @discardableResult
    public func reloadFromDisk() -> Bool {
        guard let data = FileManager.default.contents(atPath: path), let d = EditorFile.decode(data) else { return false }
        apply(text: d.text)
        format = d.format
        stamp = EditorFile.stamp(path: path, data: data)
        if readOnlyReason != nil { readOnlyReason = nil }
        buffer.isReadOnly = false
        if diskChange != nil { diskChange = nil }
        buffer.markSaved()
        return true
    }

    /// Keep what is in the buffer: the disk's version is now the known one, so
    /// the next save overwrites it. The buffer counts as edited.
    public func keepBufferOverDisk() {
        let data = FileManager.default.contents(atPath: path)
        stamp = data.map { EditorFile.stamp(path: path, data: $0) } ?? stamp
        if data == nil { stamp = nil }
        diskChange = nil
    }

    /// Makes the buffer hold `text`, as one undoable edit of the part that differs.
    func apply(text: String) {
        let new = Array(text.utf16)
        let old = buffer.document.units
        var lo = 0
        while lo < old.count, lo < new.count, old[lo] == new[lo] { lo += 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > lo, newEnd > lo, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        guard lo < oldEnd || lo < newEnd else { return }
        let caret = buffer.selection
        func map(_ o: Int) -> Int {
            if o <= lo { return o }
            if o >= oldEnd { return o + (newEnd - oldEnd) }
            return min(o, newEnd)
        }
        buffer.replace(NSRange(location: lo, length: oldEnd - lo), with: String(decoding: new[lo..<newEnd], as: UTF16.self),
                       selection: EditorSelection(anchor: map(caret.anchor), head: map(caret.head)))
    }

    /// Restores recovered text over the buffer (an undoable edit; dirty).
    public func restore(text: String) { apply(text: text) }
}
