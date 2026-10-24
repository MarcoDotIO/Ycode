import Foundation
import Testing
@testable import YcodeXcodebuild

@Suite struct ResultStoreFormatTests {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    @Test func digests() {
        // RFC 7693 appendix A, and the empty message.
        #expect(hex(BLAKE2b.digest512(Array("abc".utf8))) == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        #expect(hex(BLAKE2b.digest512([])) == "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        // More than one block.
        #expect(BLAKE2b.digest512([UInt8](repeating: 7, count: 300)).count == 64)
        #expect(SHA256.hex(Array("1".utf8)) == "6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b")
        #expect(SHA256.hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func objectEncoding() {
        let v = XCRValue.reference("x", XCRType("Child", "Parent"))
        let text = String(decoding: XCRValue.encode(v), as: UTF8.self)
        #expect(text == "[T[K2:_nV9:Reference]K2:id[T[K2:_nV6:String]K2:_vV1:x]K10:targetType[T[K2:_nV14:TypeDefinition]K4:name[S6:StringK2:_vV5:Child]K9:supertype[S14:TypeDefinitionK4:name[S6:StringK2:_vV6:Parent]]]]")
        // A type with supertypes is spelled out with its chain; arrays; UTF-8 byte lengths.
        let g = XCRValue.obj(XCRType("Group", "Base"), ["b": .array([.int(1), .bool(true)]), "a": .string("é")])
        #expect(String(decoding: XCRValue.encode(g), as: UTF8.self)
            == "[T[K2:_nV5:GroupK2:_s[K2:_nV4:Base]]K1:a[T[K2:_nV6:String]K2:_vV2:é]K1:b[T[K2:_nV5:Array][T[K2:_nV3:Int]K2:_vV1:1][T[K2:_nV4:Bool]K2:_vV4:true]]]")
        #expect(v.referencedIDs == ["x"])
    }

    @Test func framesAndCounts() {
        #expect(Zstd.rawFrame(Array("hello".utf8)) == [0x28, 0xB5, 0x2F, 0xFD, 0xA0, 5, 0, 0, 0, 0x29, 0, 0] + Array("hello".utf8))
        #expect(Zstd.rawFrame([]) == [0x28, 0xB5, 0x2F, 0xFD, 0xA0, 0, 0, 0, 0, 0x01, 0, 0])
        // Two blocks for 128 KiB + 1 byte, the first not last.
        let big = Zstd.rawFrame([UInt8](repeating: 1, count: 128 * 1024 + 1))
        #expect(big.count == 9 + 3 + 128 * 1024 + 3 + 1)
        #expect(big[9] == 0x00 && big[10] == 0x00 && big[11] == 0x10)
        #expect(XCResultStore.length(5) == [5])
        #expect(XCResultStore.length(247) == [0x81, 0xF7])
        #expect(XCResultStore.length(300) == [0x82, 0x01, 0x2C])
    }

    @Test func storeIdentifiers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycb-store-\(UUID().uuidString).xcresult")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try XCResultStore(creating: dir)
        let leaf = try store.put(.string("leaf"))
        let leafData = try Data(contentsOf: dir.appendingPathComponent("Data/data." + leaf))
        // Without references: the digest of the stored bytes.
        #expect(leaf == "0~" + XCResultStore.base64url(BLAKE2b.digest512([UInt8](leafData))))
        #expect(try Data(contentsOf: dir.appendingPathComponent("Data/refs." + leaf)) == Data([0]))
        let root = try store.put(.obj(XCRType("Holder"), ["r": .reference(leaf, XCRType("String"))]))
        let refs = [UInt8](try Data(contentsOf: dir.appendingPathComponent("Data/refs." + root)))
        let raw = try #require(XCResultStore.rawID(leaf))
        #expect(refs == [1, 65] + raw)
        let rootData = [UInt8](try Data(contentsOf: dir.appendingPathComponent("Data/data." + root)))
        #expect(root == "0~" + XCResultStore.base64url(BLAKE2b.digest512(raw + rootData)))
        try store.finish(root: root)
        let info = try #require(NSDictionary(contentsOf: dir.appendingPathComponent("Info.plist")) as? [String: Any])
        #expect((info["rootId"] as? [String: Any])?["hash"] as? String == root)
        #expect((info["version"] as? [String: Any])?["major"] as? Int == 3)
    }

    @Test func paths() {
        #if os(macOS)
        // /tmp is a link to /private/tmp only on macOS.
        #expect(PathText.withoutPrivatePrefix("/private/tmp/x/y.xcresult") == "/tmp/x/y.xcresult")
        #endif
        #expect(PathText.withoutPrivatePrefix("/private/nonexistent/x") == "/private/nonexistent/x")
        #expect(PathText.withoutPrivatePrefix("/Users/x") == "/Users/x")
        let arena = Arena(derivedDataPath: "/d", buildProductsPath: "/d/Build/Products", buildIntermediatesPath: "/d/Build/Intermediates.noindex")
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, 13, 23, 46, 27)
        c.timeZone = TimeZone.current
        let date = Calendar(identifier: .gregorian).date(from: c)!
        let p = ResultBundleSession.defaultTestPath(arena: arena, scheme: "CalcTests", date: date)
        #expect(p.hasPrefix("/d/Logs/Test/Test-CalcTests-2026.10.13_23-46-27-") && p.hasSuffix(".xcresult"))
    }
}

@Suite struct TestConsoleParserTests {
    @Test func parameterizedCasesDetailsAndOrder() {
        let records = [
            SwiftTestingBridge.TestRecord(id: "M.S/doubles(n:)/F.swift:5:6", name: "doubles(n:)", isSuite: false, file: "/src/F.swift", line: 5),
            SwiftTestingBridge.TestRecord(id: "M.T/wrong()/F.swift:9:6", name: "wrong()", isSuite: false, file: "/src/F.swift", line: 9),
        ]
        var p = TestConsoleParser(module: "M", swiftTests: records)
        for l in [
            "◇ Test doubles(n:) started.", "◇ Test wrong() started.",
            "◇ Test case passing 1 argument n → 1 to doubles(n:) started.",
            "◇ Test case passing 1 argument n → 2 to doubles(n:) started.",
            "✘ Test wrong() recorded an issue at F.swift:10:3: Expectation failed: f() == 5",
            "↳ f() == 5 → false", "↳   f() → 4",
            "✔ Test doubles(n:) with 2 test cases passed after 0.002 seconds.",
            "✘ Test wrong() failed after 0.001 seconds with 1 issue.",
        ] { p.feed(l) }
        #expect(p.results.count == 3)
        #expect(p.results.filter { $0.name == "doubles(n:)" }.map { $0.arguments.map(\.value) } == [["1"], ["2"]])
        let wrong = p.results.first { $0.name == "wrong()" }
        #expect(wrong?.status == .failed && wrong?.suite == "T")
        #expect(wrong?.issues.first?.message == "Expectation failed: f() == 5\nf() → 4")
        #expect(wrong?.issues.first?.file == "/src/F.swift")
        // A parameterized test starts when its first case does.
        #expect(p.startIndex(of: "wrong()") < p.startIndex(of: "doubles(n:)"))
    }

    @Test func xctestSkipLocation() {
        var p = TestConsoleParser(module: "M", swiftTests: [])
        p.feed("/src/A.swift:11: -[M.MulTests testSkipped] : Test skipped - not today")
        p.feed("Test Case '-[M.MulTests testSkipped]' skipped (0.001 seconds).")
        #expect(p.results.first?.skipMessage == "not today" && p.results.first?.skipLine == 11 && p.results.first?.skipFile == "/src/A.swift")
    }
}

@Suite struct ArchiveFormatTests {
    @Test func defaultArchivePath() throws {
        let inv = try ArgumentParser.parse(["archive"])
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 16, 21, 58)
        let date = Calendar(identifier: .gregorian).date(from: c)!
        #expect(Archives.archivePath(inv, scheme: "Hello", home: "/Users/me", cwd: "/w", date: date)
            == "/Users/me/Library/Developer/Xcode/Archives/2026-10-16/Hello 10-16-26, 9.58 PM.xcarchive")
        let given = try ArgumentParser.parse(["-archivePath", "out/My", "archive"])
        #expect(Archives.archivePath(given, scheme: "Hello", home: "/Users/me", cwd: "/w", date: date) == "/w/out/My.xcarchive")
    }

    @Test func exportCopiesApplications() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ycb-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let app = dir.appendingPathComponent("A.xcarchive/Products/Applications/A.app/Contents")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try (try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.A"], format: .xml, options: 0))
            .write(to: app.appendingPathComponent("Info.plist"))
        let info: [String: Any] = ["ArchiveVersion": 2, "Name": "A", "SchemeName": "A",
                                   "ApplicationProperties": ["ApplicationPath": "Applications/A.app", "Team": ""]]
        try (try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)).write(to: dir.appendingPathComponent("A.xcarchive/Info.plist"))
        func options(_ d: [String: Any]) throws -> String {
            let p = dir.appendingPathComponent("o-\(UUID().uuidString).plist")
            try (try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)).write(to: p)
            return p.path
        }
        var r = runTool(["-exportArchive", "-archivePath", "A.xcarchive", "-exportPath", "out", "-exportOptionsPlist", try options(["method": "mac-application"])], cwd: dir.path)
        #expect(r.code == 0 && r.out == "Exported A to: \(dir.path)/out\n** EXPORT SUCCEEDED **\n\n")
        #expect(fm.fileExists(atPath: dir.path + "/out/A.app/Contents/Info.plist"))
        r = runTool(["-exportArchive", "-archivePath", "A.xcarchive", "-exportPath", "out", "-exportOptionsPlist", try options(["method": "debugging"])], cwd: dir.path)
        #expect(r.code == 70 && r.out == "** EXPORT FAILED **\n\n" && r.err.hasPrefix("error: exportArchive No Team Found in Archive"))
        r = runTool(["-exportArchive", "-archivePath", "Nope.xcarchive", "-exportPath", "out", "-exportOptionsPlist", "x.plist"], cwd: dir.path)
        #expect(r.code == 65 && r.err.hasPrefix("error: error: archive not found at path '"))
        r = runTool(["-exportArchive", "-archivePath", "A.xcarchive", "-exportOptionsPlist", try options(["method": "mac-application"])], cwd: dir.path)
        #expect(r.code == 64 && r.err.hasPrefix("error: The flag -exportPath is required"))
    }
}
