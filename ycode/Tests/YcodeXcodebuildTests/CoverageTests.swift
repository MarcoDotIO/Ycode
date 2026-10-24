import Foundation
import Testing
@testable import YcodeXcodebuild

@Suite struct CoverageFormatTests {
    typealias S = Coverage.Segment
    func seg(_ l: Int, _ c: Int, _ n: Int, _ has: Bool = true, _ entry: Bool = true) -> S {
        S(line: l, column: c, count: n, hasCount: has, isRegionEntry: entry, isGap: false)
    }

    /// A function on lines 2–5 with an if/else: the line counts and the
    /// column ranges whose count differs from the line's.
    @Test func linesAndSubranges() {
        let segments = [seg(2, 40, 2), seg(3, 12, 2), seg(3, 18, 1), seg(4, 10, 2, true, false), seg(4, 26, 0),
                        seg(5, 10, 1), seg(6, 6, 0, false, false)]
        let lines = Coverage.lineCoverage(segments)
        #expect(lines.count == 6)
        #expect(lines[0] == .init(executable: false, count: 0, subranges: []))
        #expect(lines[1].executable && lines[1].count == 2 && lines[1].subranges.isEmpty)
        #expect(lines[2].count == 2 && lines[2].subranges == [.init(column: 18, length: 0, count: 1)])
        // The count is the largest of the wrapped count (1) and the counts of regions starting on the line.
        #expect(lines[3].count == 1 && lines[3].subranges == [.init(column: 10, length: 16, count: 2), .init(column: 26, length: 0, count: 0)])
        #expect(lines[4].count == 1 && lines[4].subranges == [.init(column: 1, length: 9, count: 0)])
        #expect(lines[5].executable && lines[5].count == 1)
    }

    @Test func notExecutableAfterTheEnd() {
        let lines = Coverage.lineCoverage([seg(1, 10, 3), seg(1, 20, 0, false, false), seg(3, 1, 0, false, true)])
        // Line 3 starts a skipped region: not executable, and trailing non-executable lines are dropped.
        #expect(lines.count == 1 && lines[0].count == 3)
    }

    @Test func functionReportParsing() {
        let text = """
        File '/src/A.swift':
        Name                                Regions    Miss   Cover     Lines    Miss   Cover  Branches    Miss   Cover
        ---------------------------------------------------------------------------------------------------------------
        $s1A3fooyyF                               3       1  66.67%         9       1  88.89%         0       0   0.00%
        ---------------------------------------------------------------------------------------------------------------
        TOTAL                                     3       1  66.67%         9       1  88.89%         0       0   0.00%
        """
        let rows = Coverage.parseFunctionReport(text)
        #expect(rows["/src/A.swift"]?.count == 1)
        #expect(rows["/src/A.swift"]?.first?.name == "$s1A3fooyyF" && rows["/src/A.swift"]?.first?.lines == 9 && rows["/src/A.swift"]?.first?.missed == 1)
    }

    func sample() -> CoverageData {
        let f = CoverageData.File(path: "/src/A.swift", functions: [
            .init(name: "static A.add(_:_:)", lineNumber: 2, executionCount: 4, executableLines: 1, coveredLines: 1),
            .init(name: "A.unused()", lineNumber: 4, executionCount: 0, executableLines: 3, coveredLines: 0),
        ], lines: [
            .init(executable: false, count: 0, subranges: []), .init(executable: true, count: 4, subranges: []),
            .init(executable: false, count: 0, subranges: []), .init(executable: true, count: 0, subranges: []),
            .init(executable: true, count: 0, subranges: [.init(column: 5, length: 3, count: 2)]), .init(executable: true, count: 0, subranges: []),
        ])
        return CoverageData(targets: [.init(name: "A.xctest", buildableIdentifier: "T1:primary", productPath: "/p/A", files: [f])])
    }

    @Test func functionTableLayout() {
        let d = [UInt8](Coverage.functionTable(sample().targets[0].files[0].functions))
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        #expect(u32(0) == 2)
        #expect((0..<6).map { u32(4 + 4 * $0) } == [1, 1, 2, 1, 4, 0])
        #expect((0..<6).map { u32(28 + 4 * $0) } == [0, 3, 4, 3, 0, 0])
        #expect(String(decoding: d[52...], as: UTF8.self) == "static A.add(_:_:)\0A.unused()\0")
    }

    @Test func archiveLayout() {
        let files = Coverage.archiveFiles(sample())
        #expect(files.map(\.name) == ["Coverage", "Index", "Metadata.plist"])
        let c = files[0].bytes
        func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        // Runs: line 1 not executable; line 2 count 4; line 3 not executable; lines 4–6 count 0.
        #expect(u32(c, 0) == 4)
        #expect([u32(c, 4), u32(c, 8)] == [Int](arrayLiteral: 0, 0))
        #expect([u32(c, 12), u32(c, 16)] == [Int](arrayLiteral: 4, 0x8000_0000))
        #expect([u32(c, 28), u32(c, 32)] == [Int](arrayLiteral: 0, 0x8002_0000))
        // One subrange: line 5, column 5, length 3, count 2, 0.
        #expect(u32(c, 36) == 1 && (0..<5).map { u32(c, 40 + 4 * $0) } == [5, 5, 3, 2, 0])
        let i = files[1].bytes
        #expect(u32(i, 0) == 1 && u32(i, 4) == 20 && u32(i, 12) == 0)
        #expect(Int(i[20]) | Int(i[21]) << 8 == 12 && String(decoding: i[22...], as: UTF8.self) == "/src/A.swift")
    }

    @Test func reportArchiveClasses() throws {
        let bytes = try #require(Coverage.reportArchive(sample()))
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any])
        #expect(plist["$archiver"] as? String == "NSKeyedArchiver")
        let names = (plist["$objects"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["$classname"] as? String }
        #expect(Set(names).isSuperset(of: ["XCTHCodeCoverage", "XCTHCodeCoverageTarget", "XCTHCodeCoverageFile"]))
        let chains = (plist["$objects"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["$classes"] as? [String] }
        #expect(chains.contains(["XCTHCodeCoverage", "XCTHCoverageDataContainer", "NSObject"]))
        // Written by hand: the same bytes on every platform.
        let fixed = try #require(Coverage.reportArchive(sample(), name: "report"))
        #expect(SHA256.hex(fixed) == "715777bf9c15d2590c68814f9fc84cdce68ee34cba5b2dbcd04623f94077b7a6")
    }

    @Test func binaryPlists() throws {
        let long = (0..<20).map { BPlist.int($0 * 1000) }
        let value = BPlist.dict([("z", .array(long)), ("a", .string("caf\u{E9}")), ("n", .int(-2)),
                                 ("big", .int(1 << 40)), ("d", .data([1, 2, 3])), ("s", .string(String(repeating: "x", count: 300)))])
        let bytes = BinaryPlist.encode(value)
        #expect(Array(bytes.prefix(8)) == Array("bplist00".utf8))
        let p = try #require(try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any])
        #expect(p["a"] as? String == "caf\u{E9}" && p["n"] as? Int == -2 && p["big"] as? Int == 1 << 40)
        #expect(p["d"] as? Data == Data([1, 2, 3]) && (p["s"] as? String)?.count == 300)
        #expect((p["z"] as? [Int]) == (0..<20).map { $0 * 1000 })
        // Keys sorted by bytes; a dictionary's key references come first.
        #expect(BinaryPlist.encode(.dict([("b", .int(1)), ("a", .int(2))])) == BinaryPlist.encode(.dict([("a", .int(2)), ("b", .int(1))])))
    }

    @Test func directoriesInTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycb-dir-\(UUID().uuidString).xcresult")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try XCResultStore(creating: dir)
        let a = try store.putFile(Array("a".utf8)), b = try store.putFile(Array("b".utf8))
        let d = try store.putDirectory([("Zed", false, a), ("Alpha", true, b)])
        let refs = [UInt8](try Data(contentsOf: dir.appendingPathComponent("Data/refs." + d)))
        // Listing sorted by name; references in listing order (not by id).
        #expect(refs == [2, 65] + XCResultStore.rawID(b)! + [65] + XCResultStore.rawID(a)!)
        let stored = [UInt8](try Data(contentsOf: dir.appendingPathComponent("Data/data." + d)))
        let text = String(decoding: stored[12...], as: UTF8.self)
        #expect(text == #"[{"name":"Alpha","type":2},{"name":"Zed","type":1}]"#)
    }
}

@Suite struct CoverageSummaryTests {
    /// The summary ycodebuild writes for the IDE's Coverage page.
    @Test func summaryJSON() throws {
        let f = CoverageData.Function(name: "add", lineNumber: 1, executionCount: 1, executableLines: 4, coveredLines: 3)
        let file = CoverageData.File(path: "/p/Sources/Calc/Calc.swift", functions: [f], lines: [])
        let c = CoverageData(targets: [.init(name: "Calc", buildableIdentifier: "X:primary", productPath: "/b/Calc", files: [file])])
        let root = try #require(JSONSerialization.jsonObject(with: Coverage.summaryJSON(c)) as? [String: Any])
        let t = try #require((root["targets"] as? [[String: Any]])?.first)
        #expect(t["name"] as? String == "Calc" && t["coveredLines"] as? Int == 3 && t["executableLines"] as? Int == 4)
        #expect(((t["files"] as? [[String: Any]])?.first?["path"]) as? String == "/p/Sources/Calc/Calc.swift")
    }
}
