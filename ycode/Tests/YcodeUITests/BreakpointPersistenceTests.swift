import Foundation
import Testing
@testable import YcodeDebug
@testable import YcodeUI

/// `Breakpoints_v2.xcbkptlist` and `ycode-breakpoints.json`
/// (specs/ide/reference-ui-5.md §10.1, L6).
@MainActor
@Suite struct BreakpointPersistenceTests {
    /// A file in the format §10.1 describes, written for this test: one
    /// line breakpoint Ycode understands (with an attribute and a child
    /// element it does not), one breakpoint kind it does not know, and a
    /// column breakpoint.
    static let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Bucket
       uuid = "0A1B2C3D-0000-4000-8000-000000000001"
       type = "1"
       version = "2.0">
       <Breakpoints>
          <BreakpointProxy
             BreakpointExtensionID = "Xcode.Breakpoint.FileBreakpoint">
             <BreakpointContent
                uuid = "0A1B2C3D-0000-4000-8000-000000000002"
                shouldBeEnabled = "Yes"
                ignoreCount = "2"
                continueAfterRunningActions = "No"
                filePath = "Sources/Shapes/Shapes.swift"
                startingColumnNumber = "9223372036854775807"
                endingColumnNumber = "9223372036854775807"
                startingLineNumber = "12"
                endingLineNumber = "12"
                landmarkName = "area()"
                landmarkType = "7"
                futureAttribute = "kept &amp; unchanged">
                <FutureChild
                   value = "1">
                </FutureChild>
             </BreakpointContent>
          </BreakpointProxy>
          <BreakpointProxy
             BreakpointExtensionID = "Example.Breakpoint.UnknownKind">
             <BreakpointContent
                uuid = "0A1B2C3D-0000-4000-8000-000000000003"
                shouldBeEnabled = "No"
                symbolName = "main">
             </BreakpointContent>
          </BreakpointProxy>
          <BreakpointProxy
             BreakpointExtensionID = "Xcode.Breakpoint.FileBreakpoint">
             <BreakpointContent
                uuid = "0A1B2C3D-0000-4000-8000-000000000004"
                shouldBeEnabled = "No"
                ignoreCount = "0"
                continueAfterRunningActions = "Yes"
                filePath = "Sources/Shapes/Shapes.swift"
                startingColumnNumber = "17"
                endingColumnNumber = "17"
                startingLineNumber = "20"
                endingLineNumber = "20">
             </BreakpointContent>
          </BreakpointProxy>
       </Breakpoints>
    </Bucket>

    """

    func tempPackage() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-bkpt-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Shapes"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Shapes\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        var src = (1...30).map { _ in "" }
        src[9] = "struct Square {"
        src[10] = "    func area() -> Int {"
        src[11] = "        return 4"
        src[12] = "    }"
        src[13] = "}"
        try src.joined(separator: "\n").write(to: dir.appendingPathComponent("Sources/Shapes/Shapes.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func parsesAndRewritesTheFileUnchanged() throws {
        let list = try BreakpointList(text: Self.sample)
        #expect(list.text == Self.sample)
        let base = URL(fileURLWithPath: "/w")
        let entries = list.entries(base: base)
        #expect(entries.map(\.uuid) == ["0A1B2C3D-0000-4000-8000-000000000002", "0A1B2C3D-0000-4000-8000-000000000004"])
        #expect(entries[0].breakpoint == BreakpointStore.Breakpoint(file: "/w/Sources/Shapes/Shapes.swift", line: 12, isEnabled: true, ignoreCount: 2))
        #expect(entries[1].breakpoint == BreakpointStore.Breakpoint(file: "/w/Sources/Shapes/Shapes.swift", line: 20, isEnabled: false, column: 17, autoContinue: true))

        // Writing back the same breakpoints leaves the text as it was.
        var same = list
        var uuids = Dictionary(uniqueKeysWithValues: entries.map { (BreakpointList.key($0.breakpoint), $0.uuid) })
        same.update(entries.map(\.breakpoint), base: base, uuids: &uuids, landmark: { _, _ in nil })
        #expect(same.text == Self.sample)
    }

    @Test func updatesKeepUnknownContent() throws {
        var list = try BreakpointList(text: Self.sample)
        let base = URL(fileURLWithPath: "/w")
        let entries = list.entries(base: base)
        var uuids = Dictionary(uniqueKeysWithValues: entries.map { (BreakpointList.key($0.breakpoint), $0.uuid) })
        // Disable the first, drop the column breakpoint, add a new line.
        var first = entries[0].breakpoint
        first.isEnabled = false
        let added = BreakpointStore.Breakpoint(file: "/w/Sources/Shapes/Other.swift", line: 3, isEnabled: true)
        list.update([first, added], base: base, uuids: &uuids, landmark: { _, line in line == 3 ? "run()" : nil })
        let text = list.text
        #expect(text.contains("shouldBeEnabled = \"No\"\n            ignoreCount = \"2\""))
        #expect(text.contains("futureAttribute = \"kept &amp; unchanged\""))
        #expect(text.contains("<FutureChild"))
        #expect(text.contains("landmarkName = \"area()\""))  // kept: no landmark found now
        #expect(text.contains("BreakpointExtensionID = \"Example.Breakpoint.UnknownKind\""))
        #expect(!text.contains("0A1B2C3D-0000-4000-8000-000000000004"))
        // The new one is last, with the attributes in §10.1's order.
        let reread = try BreakpointList(text: text)
        let again = reread.entries(base: base)
        #expect(again.map(\.breakpoint.line) == [12, 3])
        let newUUID = try #require(uuids[BreakpointList.key(added)])
        #expect(newUUID == newUUID.uppercased() && UUID(uuidString: newUUID) != nil)
        let tail = String(text[text.range(of: "uuid = \"\(newUUID)\"")!.lowerBound...])
        let names = tail.split(separator: "\n").prefix(11).map { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "" }
        #expect(names == ["uuid", "shouldBeEnabled", "ignoreCount", "continueAfterRunningActions", "filePath", "startingColumnNumber",
                          "endingColumnNumber", "startingLineNumber", "endingLineNumber", "landmarkName", "landmarkType"])
        #expect(tail.contains("filePath = \"Sources/Shapes/Other.swift\""))
        #expect(tail.contains("startingColumnNumber = \"9223372036854775807\""))
        #expect(tail.contains("landmarkName = \"run()\"\n            landmarkType = \"7\">"))
    }

    @Test func locationsFollowTheContainerKind() {
        let proj = URL(fileURLWithPath: "/w/App.xcodeproj")
        #expect(BreakpointList.fileURL(container: proj, isPackage: false, user: "u").path
            == "/w/App.xcodeproj/xcuserdata/u.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist")
        #expect(BreakpointList.fileURL(container: URL(fileURLWithPath: "/w/All.xcworkspace"), isPackage: false, user: "u").path
            == "/w/All.xcworkspace/xcuserdata/u.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist")
        #expect(BreakpointList.fileURL(container: URL(fileURLWithPath: "/w/Pkg"), isPackage: true, user: "u").path
            == "/w/Pkg/.swiftpm/xcode/xcuserdata/u.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist")
        #expect(BreakpointList.extrasURL(container: proj, isPackage: false, user: "u").path == "/w/App.xcodeproj/xcuserdata/u.xcuserdatad/ycode-breakpoints.json")
        #expect(BreakpointList.baseFolder(container: proj, isPackage: false).path == "/w")
        #expect(BreakpointList.relative("/w/a/b.swift", base: URL(fileURLWithPath: "/w")) == "a/b.swift")
        #expect(BreakpointList.relative("/w/x/b.swift", base: URL(fileURLWithPath: "/w/y")) == "../x/b.swift")
        #expect(BreakpointList.absolute("../x/b.swift", base: URL(fileURLWithPath: "/w/y")) == "/w/x/b.swift")
    }

    /// Set breakpoints, "quit" (drop the session), reopen: they are there.
    @Test func breakpointsSurviveReopening() throws {
        let dir = try tempPackage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Sources/Shapes/Shapes.swift").path
        do {
            let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
            session.attachBreakpointFile(user: "tester")
            #expect(session.breakpoints.isEmpty)
            let url = try #require(session.breakpointFile?.fileURL)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            session.breakpoints.click(file: file, line: 12)
            session.breakpoints.edit(file: file, line: 12) { $0.condition = "x > 1"; $0.actions = [.log("hit {x}")]; $0.ignoreCount = 1 }
            session.breakpoints.addColumn(file: file, line: 12, column: 16)
            session.breakpoints.click(file: file, line: 20)
            session.breakpoints.click(file: file, line: 20)  // disabled
            session.breakpoints.symbolic = [.init(name: "malloc", condition: "size > 4")]
            session.breakpoints.exceptionFilters = ["swift_throw"]
            session.breakpoints.isActive = false
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Bucket\n   uuid = \""))
            #expect(text.contains("filePath = \"Sources/Shapes/Shapes.swift\""))
            #expect(text.contains("landmarkName = \"area()\""))
            #expect(text.contains("startingColumnNumber = \"16\""))
            #expect(url.path == dir.appendingPathComponent(".swiftpm/xcode/xcuserdata/tester.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist").path)
        }
        let reopened = WorkspaceSession(model: try WorkspaceModel(url: dir))
        reopened.attachBreakpointFile(user: "tester")
        let s = reopened.breakpoints
        #expect(s.all.count == 3)
        let line = try #require(s.breakpoint(file: file, line: 12))
        #expect(line.column == nil && line.condition == "x > 1" && line.actions == [.log("hit {x}")] && line.ignoreCount == 1 && line.isEnabled)
        #expect(s.breakpoints(file: file, line: 12).compactMap(\.column) == [16])
        #expect(s.breakpoint(file: file, line: 20)?.isEnabled == false)
        #expect(s.symbolic == [.init(name: "malloc", condition: "size > 4")])
        #expect(s.exceptionFilters == ["swift_throw"])
        #expect(!s.isActive)
    }

    /// The file is rewritten only when the breakpoint set changes; an
    /// unknown proxy in it survives Ycode's edits.
    @Test func rewritesOnlyOnChange() throws {
        let dir = try tempPackage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = BreakpointList.fileURL(container: dir, isPackage: true, user: "tester")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.sample.write(to: url, atomically: true, encoding: .utf8)
        let p = BreakpointPersistence(container: dir, isPackage: true, user: "tester")
        let loaded = p.load()
        #expect(loaded.all.count == 2)
        #expect(!p.save(loaded))
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.sample)
        var changed = loaded
        changed.click(file: dir.appendingPathComponent("Sources/Shapes/Shapes.swift").path, line: 12)  // disable
        #expect(p.save(changed))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Example.Breakpoint.UnknownKind") && text.contains("futureAttribute"))
        #expect(!p.save(changed))
        // No extras file while there is nothing of Ycode's own to keep.
        #expect(!FileManager.default.fileExists(atPath: BreakpointList.extrasURL(container: dir, isPackage: true, user: "tester").path))
    }

    @Test func storeLineAndColumnCommands() {
        var s = BreakpointStore()
        s.click(file: "/a.c", line: 3)
        s.addColumn(file: "/a.c", line: 3, column: 9)
        s.addColumn(file: "/a.c", line: 3, column: 9)
        #expect(s.breakpoints(file: "/a.c", line: 3).count == 2)
        #expect(s.lineIsEnabled(file: "/a.c", line: 3) == true)
        s.toggleEnabled(file: "/a.c", line: 3)
        #expect(s.lineIsEnabled(file: "/a.c", line: 3) == false)
        s.toggleEnabled(file: "/a.c", line: 3)
        #expect(s.lineIsEnabled(file: "/a.c", line: 3) == true)
        #expect(s.effectiveBreakpoints["/a.c"] == [SourceBreakpoint(line: 3), SourceBreakpoint(line: 3, column: 9)])
        #expect(SourceBreakpoint(line: 3, column: 9).json == ["line": 3, "column": 9])
        s.removeColumns(file: "/a.c", line: 3)
        #expect(!s.hasColumnBreakpoints(file: "/a.c", line: 3) && s.breakpoint(file: "/a.c", line: 3) != nil)
        s.addColumn(file: "/a.c", line: 5, column: 2)
        s.toggleExistence(file: "/a.c", line: 5)  // ⌘\ removes the line's breakpoints
        #expect(s.breakpoints(file: "/a.c", line: 5).isEmpty)
        s.symbolic = [.init(name: "f")]
        s.exceptionFilters = ["cpp_throw"]
        #expect(!s.isEmpty)
        s.removeAll()
        #expect(s.isEmpty && s.isActive)
        #expect(s.lineIsEnabled(file: "/a.c", line: 3) == nil)
    }
}
