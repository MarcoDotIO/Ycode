import Foundation
import Testing
@testable import YcodeDarwinABI

/// `GuestPath` matches the `NSString` path helpers it replaces in the kernel.
@Suite struct GuestPathTests {
    static let samples = ["/a/b", "/a/b/", "/a", "/", "", "a", "a/b", "/a//b", "//a", "/usr/lib/system/libsystem_kernel.dylib",
                          "/private/var/mobile/", "x/", "/a/b//"]

    @Test(arguments: samples) func lastComponent(_ p: String) {
        #expect(GuestPath.lastComponent(p) == (p as NSString).lastPathComponent)
    }

    @Test(arguments: samples) func deletingLastComponent(_ p: String) {
        #expect(GuestPath.deletingLastComponent(p) == (p as NSString).deletingLastPathComponent)
    }

    @Test func hostDirectoryNames() throws {
        let tree = try TempTree()
        try tree.mkdir("d/sub")
        try tree.writeFile("d/f", [1])
        #expect(GuestPath.hostDirectoryNames(tree.host("d"))?.sorted() == ["f", "sub"])
        #expect(GuestPath.hostDirectoryNames(tree.host("missing")) == nil)
    }
}
