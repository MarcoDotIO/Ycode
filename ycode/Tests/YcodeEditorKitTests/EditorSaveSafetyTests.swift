import Foundation
import Testing
import YcodeSyntax
@testable import YcodeEditorKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A file in its own temporary folder.
final class TempFile {
    let dir: String
    let path: String
    init(_ bytes: [UInt8], name: String = "file.swift") throws {
        dir = NSTemporaryDirectory() + "/ycode-editorkit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/" + name
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }
    convenience init(_ text: String, name: String = "file.swift") throws { try self.init(Array(text.utf8), name: name) }
    var bytes: [UInt8] { [UInt8](FileManager.default.contents(atPath: path) ?? Data()) }
    var text: String { String(decoding: bytes, as: UTF8.self) }
    var dirListing: [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] }
    deinit { try? FileManager.default.removeItem(atPath: dir) }
}

func open(_ path: String) throws -> EditorDocument {
    let (d, m) = EditorDocument.open(path: path, typingOptions: TypingOptions(autoIndent: false, autoClose: false, encloseSelection: false))
    guard let d else { throw EditorSaveError.cannotWrite(path: path, reason: m ?? "?") }
    return d
}

@Suite struct EditorSaveSafetyTests {
    // MARK: Round trips

    @Test(arguments: [
        "plain\ntext\n", "no final newline", "", "\n\n\n", "crlf\r\nonly\r\n", "mixed\r\nlines\nhere\r", "tabs\t\t\n  spaces  \n",
        "unicode é 日本語 😀\n",
    ])
    func openEditUndoSaveKeepsEveryByte(text: String) throws {
        let f = try TempFile(text)
        let d = try open(f.path)
        d.buffer.setCaret(0)
        d.buffer.insertText("x")
        d.buffer.undo()
        #expect(d.save() == .saved)
        #expect(f.bytes == Array(text.utf8))
    }

    @Test func aCRLFFileEditsWithLFAndSavesCRLF() throws {
        let f = try TempFile("one\r\ntwo\r\n")
        let d = try open(f.path)
        #expect(d.format.crlf && d.buffer.text == "one\ntwo\n")
        d.buffer.setCaret(3)
        d.buffer.newline()
        d.buffer.insertText("x")
        #expect(d.save() == .saved)
        #expect(f.text == "one\r\nx\r\ntwo\r\n")
    }

    @Test func aMixedFileKeepsItsLineEndingsAndHidesTheCR() throws {
        let f = try TempFile("one\r\ntwo\nthree")
        let d = try open(f.path)
        #expect(!d.format.crlf && d.buffer.length == 14)
        let b = d.buffer
        b.setCaret(0)
        b.move(.hardLine, forward: true)
        #expect(b.caret == 3)                   // Before the \r.
        b.move(.character, forward: true)
        #expect(b.caret == 5)                   // Over \r\n at once.
        b.move(.character, forward: false)
        #expect(b.caret == 3)
        b.setCaret(4)
        #expect(b.caret == 3)                   // Never between them.
        b.setCaret(5)
        b.insertText("x")
        #expect(d.save() == .saved)
        #expect(f.text == "one\r\nxtwo\nthree")
    }

    @Test(arguments: [[0xEF, 0xBB, 0xBF] + Array("bom\n".utf8),
                      [0xFF, 0xFE] + Array("u16".utf8).flatMap { [$0, 0] },
                      [0xFE, 0xFF] + Array("u16".utf8).flatMap { [0, $0] }] as [[UInt8]])
    func byteOrderMarksSurvive(bytes: [UInt8]) throws {
        let f = try TempFile(bytes)
        let d = try open(f.path)
        #expect(!d.buffer.text.contains("\u{FEFF}"))
        d.buffer.setCaret(0)
        d.buffer.insertText("x")
        d.buffer.undo()
        #expect(d.save() == .saved)
        #expect(f.bytes == bytes)
    }

    @Test func invalidUTF8IsReadOnlyAndItsBytesAreSafe() throws {
        let bytes: [UInt8] = Array("caf".utf8) + [0xE9] + Array(" latin1\n".utf8)
        let f = try TempFile(bytes)
        let d = try open(f.path)
        #expect(d.readOnlyReason != nil && d.buffer.isReadOnly)
        d.buffer.insertText("x")
        #expect(!d.isDirty)
        if case .failed = d.save() {} else { Issue.record("a read-only document must not save") }
        #expect(f.bytes == bytes)
    }

    @Test func binaryAndMissingFilesDoNotOpen() throws {
        let f = try TempFile([1, 2, 0, 3])
        #expect(EditorDocument.open(path: f.path).document == nil)
        #expect(EditorDocument.open(path: f.path).message == "Binary file")
        #expect(EditorDocument.open(path: f.path + ".missing").message == "Cannot read file.swift.missing")
    }

    // MARK: The atomic write

    @Test func saveLeavesNoTemporaryFilesAndClearsDirty() throws {
        let f = try TempFile("a")
        let d = try open(f.path)
        d.buffer.setCaret(1)
        d.buffer.insertText("b")
        #expect(d.isDirty)
        #expect(d.save() == .saved)
        #expect(!d.isDirty && f.text == "ab" && f.dirListing == ["file.swift"])
    }

    @Test func saveKeepsTheModeAndReplacesTheInode() throws {
        let f = try TempFile("#!/bin/sh\n")
        chmod(f.path, 0o751)
        let ino = FileManager.default.attributes(f.path)
        let d = try open(f.path)
        d.buffer.setCaret(0)
        d.buffer.insertText("#")
        #expect(d.save() == .saved)
        #expect(FileManager.default.attributes(f.path).mode == 0o751)
        // A new inode: the old file was never truncated, a reader keeps a whole one.
        #expect(FileManager.default.attributes(f.path).ino != ino.ino)
    }

    @Test func aSymlinkStaysALink() throws {
        let f = try TempFile("target")
        let link = f.dir + "/link.swift"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: f.path)
        let d = try open(link)
        d.buffer.setCaret(0)
        d.buffer.insertText("x")
        #expect(d.save() == .saved)
        #expect(f.text == "xtarget")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == f.path)
    }

    @Test func aReaderDuringManySavesSeesOnlyWholeFiles() async throws {
        let a = String(repeating: "a", count: 1 << 20), b = String(repeating: "b", count: 1 << 20)
        let f = try TempFile(a)
        let path = f.path
        let stop = Atomic()
        let reader = Task.detached { () -> Int in
            var mixed = 0
            while !stop.isSet {
                guard let d = FileManager.default.contents(atPath: path) else { continue }
                if d.count != 1 << 20 || d.first != d.last { mixed += 1 }
            }
            return mixed
        }
        for i in 0..<60 { try EditorFile.writeAtomically(Data((i % 2 == 0 ? b : a).utf8), to: path) }
        stop.set()
        #expect(await reader.value == 0)
    }

    @Test func aFailedSaveKeepsTheBufferAndTheFile() throws {
        // A directory where the file was: rename can't replace it.
        let f = try TempFile("old")
        let d = try open(f.path)
        d.buffer.setCaret(0)
        d.buffer.insertText("new ")
        try FileManager.default.removeItem(atPath: f.path)
        try FileManager.default.createDirectory(atPath: f.path, withIntermediateDirectories: true)
        d.keepBufferOverDisk()
        guard case .failed = d.save(overwrite: true) else {
            Issue.record("the save should fail")
            return
        }
        #expect(d.isDirty && d.buffer.text == "new old")
        #expect(f.dirListing == ["file.swift"])
    }

    @Test func aMissingFolderFailsCleanly() throws {
        let f = try TempFile("x")
        #expect(throws: EditorSaveError.self) {
            try EditorFile.writeAtomically(Data("y".utf8), to: f.dir + "/no/such/folder/file")
        }
    }

    @Test func aReadOnlyFolderOrFileNeverLosesTheBuffer() throws {
        guard getuid() != 0 else { return }
        let f = try TempFile("old")
        let d = try open(f.path)
        d.buffer.setCaret(0)
        d.buffer.insertText("new ")
        // A file that isn't writable in a folder that isn't writable.
        chmod(f.path, 0o444)
        chmod(f.dir, 0o555)
        defer { chmod(f.dir, 0o755) }
        guard case .failed(let m) = d.save() else {
            Issue.record("the save should fail")
            return
        }
        #expect(m.contains("file.swift"))
        #expect(d.isDirty && d.buffer.text == "new old" && f.text == "old")
    }

    @Test func aWritableFileInAReadOnlyFolderIsWrittenInPlace() throws {
        guard getuid() != 0 else { return }
        let f = try TempFile("old")
        let d = try open(f.path)
        d.buffer.setCaret(0)
        d.buffer.insertText("new ")
        chmod(f.dir, 0o555)
        defer { chmod(f.dir, 0o755) }
        #expect(d.save() == .saved)
        #expect(f.text == "new old" && !d.isDirty)
    }

    // MARK: Changes on disk

    @Test func aChangedFileIsNoticedAndNotOverwritten() throws {
        let f = try TempFile("disk 1\n")
        let d = try open(f.path)
        d.buffer.setCaret(0)
        d.buffer.insertText("mine ")
        try Data("disk 2 is longer\n".utf8).write(to: URL(fileURLWithPath: f.path))
        #expect(d.save() == .conflict(.modified))
        #expect(f.text == "disk 2 is longer\n" && d.isDirty && d.diskChange == .modified)
        #expect(d.save(overwrite: true) == .saved)
        #expect(f.text == "mine disk 1\n" && d.diskChange == nil)
    }

    @Test func touchingAFileIsNoChange() throws {
        let f = try TempFile("same\n")
        let d = try open(f.path)
        try Data("same\n".utf8).write(to: URL(fileURLWithPath: f.path))
        #expect(d.checkDisk() == nil)
    }

    @Test func aDeletedFileIsNoticedAndSavingBringsItBack() throws {
        let f = try TempFile("text\n")
        let d = try open(f.path)
        try FileManager.default.removeItem(atPath: f.path)
        #expect(d.checkDisk() == .deleted)
        #expect(d.save() == .conflict(.deleted))
        #expect(d.save(overwrite: true) == .saved)
        #expect(f.text == "text\n")
    }

    @Test func reloadIsUndoableAndKeepsTheCaretNearby() throws {
        let f = try TempFile("one\ntwo\nthree\n")
        let d = try open(f.path)
        d.buffer.setCaret(10)    // In "three".
        try Data("one\nTWO!\nthree\n".utf8).write(to: URL(fileURLWithPath: f.path))
        #expect(d.checkDisk() == .modified)
        #expect(d.reloadFromDisk())
        #expect(d.buffer.text == "one\nTWO!\nthree\n" && !d.isDirty && d.diskChange == nil)
        #expect(d.buffer.caret == 11 && d.buffer.string(9..<11) == "th")
        d.buffer.undo()
        #expect(d.buffer.text == "one\ntwo\nthree\n" && d.isDirty)
    }

    @Test func keepingTheBufferMakesTheNextSaveOverwrite() throws {
        let f = try TempFile("a\n")
        let d = try open(f.path)
        d.buffer.setCaret(0)
        d.buffer.insertText("mine")
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: f.path))
        d.checkDisk()
        d.keepBufferOverDisk()
        #expect(d.diskChange == nil && d.isDirty)
        #expect(d.save() == .saved)
        #expect(f.text == "minea\n")
    }

    @Test func savingADocumentWhoseFileAppearsInTheMeantimeAsks() throws {
        let f = try TempFile("a")
        let d = try open(f.path)
        try FileManager.default.removeItem(atPath: f.path)
        d.keepBufferOverDisk()
        #expect(d.save() == .saved)
        #expect(f.text == "a")
    }
}

extension FileManager {
    func attributes(_ path: String) -> (mode: UInt32, ino: UInt64) {
        var st = stat()
        stat(path, &st)
        return (UInt32(st.st_mode) & 0o7777, UInt64(st.st_ino))
    }
}

final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

@Suite struct EditorRecoveryTests {
    @Test func keepsReadsAndDiscards() throws {
        let f = try TempFile("x")
        let r = EditorRecovery(directory: f.dir + "/state/recovery")
        #expect(r.entry(for: f.path) == nil)
        #expect(r.keep(path: f.path, baseHash: 7, text: "unsaved é"))
        #expect(r.entry(for: f.path) == EditorRecovery.Entry(path: f.path, baseHash: 7, text: "unsaved é"))
        #expect(r.keep(path: f.path, baseHash: 7, text: "newer"))
        #expect(r.entry(for: f.path)?.text == "newer")
        #expect(r.entry(for: f.path + "2") == nil)
        r.discard(path: f.path)
        #expect(r.entry(for: f.path) == nil)
    }

    @Test func itsFilesArePrivate() throws {
        let f = try TempFile("x")
        let r = EditorRecovery(directory: f.dir + "/recovery")
        r.keep(path: f.path, baseHash: 1, text: "secret")
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: r.directory).first)
        #expect(FileManager.default.attributes(r.directory + "/" + file).mode == 0o600)
        #expect(FileManager.default.attributes(r.directory).mode == 0o700)
    }
}
