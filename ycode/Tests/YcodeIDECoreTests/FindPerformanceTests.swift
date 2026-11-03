import Foundation
import Testing
@testable import YcodeIDECore

/// Workspace search on a large tree (specs/ide/navigators.md §Find
/// navigator, "Ycode implementation", Performance): 5,000 generated
/// source files in 50 folders, searched through a folder reference.
/// `YCODE_FIND_PERF_TREE=<folder>` searches that folder too and prints
/// the times.
@Suite(.serialized) struct FindPerformanceTests {
    static func source(_ i: Int) -> String {
        var s = "import Foundation\n\n/// Model \(i).\npublic struct Model\(i): Codable, Equatable {\n"
        for f in 0..<12 { s += "    public var field\(f): Int = \(f * i)\n" }
        s += "\n    public init() {}\n\n"
        for m in 0..<8 {
            s += "    public func compute\(m)(_ x: Int) -> Int {\n        let y = x * \(m + 1) + field\(m)\n        return y &+ \(i)\n    }\n\n"
        }
        if i % 100 == 7 { s += "    // RARE_NEEDLE_\(i)\n" }
        return s + "}\n"
    }

    func measure(_ label: String, _ files: [FindCandidate], _ q: FindQuery) -> FindEngine.Summary {
        let s = FindEngine.search(FindEngine.Request(query: q, files: files, limit: 10_000_000))
        print("FIND-PERF \(label): \(String(format: "%.3f", s.elapsed)) s, \(s.searchedFiles) files, \(s.matchCount) matches, \(s.skippedBinary) binary")
        return s
    }

    @Test func fiveThousandFiles() throws {
        let dir = try findScratch("perf")
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in 0..<50 {
            let folder = dir.appendingPathComponent("Module\(d)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for f in 0..<100 {
                let i = d * 100 + f
                try Self.source(i).write(to: folder.appendingPathComponent("Model\(i).swift"), atomically: false, encoding: .utf8)
            }
        }
        let root = NavigatorNode(name: "Perf", kind: .container, path: dir.appendingPathComponent("Perf.xcodeproj").path, children: [
            NavigatorNode(name: "Tree", kind: .file, path: dir.path),
        ])
        let start = Date()
        let files = FindScopeResolver(root: root).candidates(for: .workspace)
        print("FIND-PERF list: \(String(format: "%.3f", Date().timeIntervalSince(start))) s, \(files.count) files")
        #expect(files.count == 5000)
        let rare = measure("rare literal", files, FindQuery("rare_needle"))
        #expect(rare.matchCount == 50 && rare.searchedFiles == 5000)
        let common = measure("common literal", files, FindQuery("compute"))
        #expect(common.matchCount == 40_000)
        let word = measure("whole word, case", files, FindQuery("field3", match: .matchingWord, ignoreCase: false))
        #expect(word.matchCount == 10_000)
        let regex = measure("regex", files, FindQuery("func compute[0-7]\\(_ (\\w+): Int\\)", kind: .regularExpression))
        #expect(regex.matchCount == 40_000)
        // Generous bounds: shared machines vary; the report quotes the printed times.
        #expect(rare.elapsed < 20 && regex.elapsed < 60)

        if let tree = ProcessInfo.processInfo.environment["YCODE_FIND_PERF_TREE"] {
            let t0 = Date()
            let external = FindScopeResolver(root: NavigatorNode(name: "Tree", kind: .container, path: tree, children: [
                NavigatorNode(name: "Tree", kind: .file, path: tree),
            ])).candidates(for: .workspace)
            print("FIND-PERF external list: \(String(format: "%.3f", Date().timeIntervalSince(t0))) s, \(external.count) files")
            _ = measure("external rare literal", external, FindQuery("zqxjv_not_there"))
            _ = measure("external common literal", external, FindQuery("return"))
            _ = measure("external regex", external, FindQuery("func \\w+\\(", kind: .regularExpression))
        }
    }
}
