import Foundation
import Testing
@testable import YcodeDarwinKernel

/// The object-id walk behind fsgetpath/openbyid_np (`ObjectPaths.swift`,
/// `boot-profile.md` §2): one readdir pass per directory, inode from d_ino.
@Suite struct ObjectPathWalkTests {
    @Test func findsNestedFileAndNotesEveryEntry() throws {
        let base = NSTemporaryDirectory() + "ycode-objwalk-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fm = FileManager.default
        try fm.createDirectory(atPath: base + "/a/b/c", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/d", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: base + "/a/b/c/target"))
        try Data("y".utf8).write(to: URL(fileURLWithPath: base + "/d/other"))
        // A symbolic link to a directory is noted but not followed.
        try fm.createSymbolicLink(atPath: base + "/loop", withDestinationPath: base)
        defer { try? fm.removeItem(atPath: base) }

        var st = stat()
        #expect(lstat(base + "/a/b/c/target", &st) == 0)
        var noted: [UInt64: String] = [:]
        let found = DarwinKernel.walkForObject(hostBase: base, guestBase: "/vol", objid: UInt64(st.st_ino)) { ino, path in
            noted[ino] = path
        }
        #expect(found == "/vol/a/b/c/target")
        #expect(noted[UInt64(st.st_ino)] == "/vol/a/b/c/target")

        // A missing object: every entry is noted once, nothing found, no
        // descent through the link.
        var all: [String] = []
        let none = DarwinKernel.walkForObject(hostBase: base, guestBase: "", objid: UInt64.max) { _, path in all.append(path) }
        #expect(none == nil)
        #expect(Set(all) == Set(["/a", "/a/b", "/a/b/c", "/a/b/c/target", "/d", "/d/other", "/loop"]))
        #expect(all.count == 7)
    }
}
