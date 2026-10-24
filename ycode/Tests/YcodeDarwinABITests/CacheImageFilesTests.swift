import Foundation
import Testing
@testable import YcodeDarwinABI

/// Cache-only image files (app-launch.md §3.5).
@Suite struct CacheImageFilesTests {
    static let images = [
        "/System/Library/Frameworks/UIKit.framework/UIKit",
        "/System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/WebKit",
        "/usr/lib/system/libsystem_kernel.dylib",
        "/usr/lib/libobjc.A.dylib",
    ]

    /// A runtime root with framework directories that hold no executable,
    /// WebKit linked from the cryptex directory (as in the 27.1 runtime).
    func makeTree() throws -> (TempTree, DarwinFileSystem) {
        let t = try TempTree()
        try t.writeFile("rr/System/Library/Frameworks/UIKit.framework/Info.plist", [1])
        try t.writeFile("rr/System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Info.plist", [1])
        try t.symlink("rr/System/Library/Frameworks/WebKit.framework",
                      to: "../../../System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework")
        try t.writeFile("rr/usr/lib/libz.1.dylib", [0xCF, 0xFA, 0xED, 0xFE])
        try t.mkdir("rr/usr/lib/system")
        let rr = t.host("rr")
        let fs = DarwinFileSystem(prefixes: [.init(guestPath: rr, hostPath: rr, writable: false)], console: { _, _ in })
        fs.cacheImageFiles = CacheImageFiles(runtimeRoot: rr + "/", imagePaths: { Self.images })
        return (t, fs)
    }

    @Test func frameworkExecutableIsARegularFile() throws {
        let (t, fs) = try makeTree()
        let st = try fs.stat(t.host("rr/System/Library/Frameworks/UIKit.framework/UIKit"), followSymlinks: true)
        #expect(st.isRegularFile)
        #expect(st.mode & 0o777 == 0o555)
        #expect(st.dev != 0)
        // lstat too, and the inode is stable.
        let l = try fs.stat(t.host("rr/System/Library/Frameworks/UIKit.framework/UIKit"), followSymlinks: false)
        #expect(l.ino == st.ino)
    }

    @Test func cryptexFrameworkThroughItsLink() throws {
        let (t, fs) = try makeTree()
        // The link's spelling and the cryptex spelling both answer.
        let a = try fs.stat(t.host("rr/System/Library/Frameworks/WebKit.framework/WebKit"), followSymlinks: true)
        let b = try fs.stat(t.host("rr/System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/WebKit"),
                            followSymlinks: true)
        #expect(a.isRegularFile && b.isRegularFile)
        #expect(a.ino == b.ino)
    }

    @Test func onlyMetadataOpenStillFails() throws {
        let (t, fs) = try makeTree()
        #expect(throws: DarwinErrnoError.self) {
            _ = try fs.open(t.host("rr/System/Library/Frameworks/UIKit.framework/UIKit"), flags: DarwinOpen.O_RDONLY, mode: 0)
        }
    }

    @Test func excludedAndUnknownPathsStayMissing() throws {
        let (t, fs) = try makeTree()
        for p in ["rr/usr/lib/system/libsystem_kernel.dylib",           // host-library directory
                  "rr/System/Library/Frameworks/UIKit.framework/Other", // not an image
                  "rr/usr/lib/libobjc.B.dylib"] {
            #expect(throws: DarwinErrnoError.self) { _ = try fs.stat(t.host(p), followSymlinks: true) }
        }
        // A path outside the runtime root is never an image.
        #expect(fs.cacheImageFiles?.imagePath(forGuestPath: "/usr/lib/libobjc.A.dylib") == nil)
        // A missing directory component stays ENOENT.
        #expect(throws: DarwinErrnoError.self) {
            _ = try fs.stat(t.host("rr/System/Library/Frameworks/Nope.framework/Nope"), followSymlinks: true)
        }
    }

    @Test func realFilesWin() throws {
        let (t, fs) = try makeTree()
        let st = try fs.stat(t.host("rr/usr/lib/libz.1.dylib"), followSymlinks: true)
        #expect(st.size == 4)
        // The library image is answered when no file exists.
        #expect(try fs.stat(t.host("rr/usr/lib/libobjc.A.dylib"), followSymlinks: true).isRegularFile)
    }

    @Test func childCopiesInheritAndNilTurnsItOff() throws {
        let (t, fs) = try makeTree()
        let child = fs.makeChildCopy()
        #expect(try child.stat(t.host("rr/System/Library/Frameworks/UIKit.framework/UIKit"), followSymlinks: true).isRegularFile)
        fs.cacheImageFiles = nil
        #expect(throws: DarwinErrnoError.self) {
            _ = try fs.stat(t.host("rr/System/Library/Frameworks/UIKit.framework/UIKit"), followSymlinks: true)
        }
    }

    @Test func imagePathsAreLoadedOnce() throws {
        var calls = 0
        let c = CacheImageFiles(runtimeRoot: "/rr", imagePaths: { calls += 1; return Self.images })
        #expect(c.imagePath(forGuestPath: "/rr/usr/lib/libobjc.A.dylib") == "/usr/lib/libobjc.A.dylib")
        #expect(c.imagePath(forGuestPath: "/rr/System/Library/Frameworks/WebKit.framework/WebKit")
                == "/System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/WebKit")
        #expect(c.imagePath(forGuestPath: "/rr/System/Cryptexes/OS/System/Library/Frameworks/UIKit.framework/UIKit")
                == "/System/Library/Frameworks/UIKit.framework/UIKit")
        #expect(c.imagePath(forGuestPath: "/rrx/usr/lib/libobjc.A.dylib") == nil)
        #expect(calls == 1)
    }
}
