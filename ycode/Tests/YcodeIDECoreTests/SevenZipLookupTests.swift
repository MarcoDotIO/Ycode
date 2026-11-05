import Foundation
import Testing
@testable import YcodeIDECore

/// Finding 7-Zip for a runtime download on Linux (`docs/SIMULATOR-LINUX.md`
/// §5.1): the Flatpak ships `/app/bin/7zz`, and its `PATH` has the host-tool
/// wrappers, then `/app/bin`, then the runtime's `/usr/bin`.
@Suite struct SevenZipLookupTests {
    /// A folder per `PATH` entry, holding the named programs.
    func folders(_ layout: [[String]]) throws -> (root: URL, path: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-7z-\(UUID().uuidString)")
        var dirs: [String] = []
        for (i, tools) in layout.enumerated() {
            let dir = root.appendingPathComponent("p\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for t in tools {
                let file = dir.appendingPathComponent(t).path
                FileManager.default.createFile(atPath: file, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            }
            dirs.append(dir.path)
        }
        return (root, dirs.joined(separator: ":"))
    }

    @Test func thePackagedSevenZipIsFoundOnTheFlatpaksPath() throws {
        // wrappers (no 7-Zip) : /app/bin (7zz) : /usr/bin (an older 7z)
        let f = try folders([["swift", "git"], ["7zz", "ycode"], ["7z"]])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let found = SevenZipImageReader.find(environment: ["PATH": f.path])
        #expect(found == f.root.appendingPathComponent("p1/7zz").path)
    }

    @Test func sevenZipEnvironmentVariableWinsAndPlainSevenZIsTheFallback() throws {
        let f = try folders([[], ["7z"]])
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(SevenZipImageReader.find(environment: ["PATH": f.path]) == f.root.appendingPathComponent("p1/7z").path)
        #expect(SevenZipImageReader.find(environment: ["PATH": f.path, "YCODE_7Z": "/opt/7zz"]) == "/opt/7zz")
        #expect(SevenZipImageReader.find(environment: ["PATH": f.root.appendingPathComponent("p0").path]) == nil)
    }
}
