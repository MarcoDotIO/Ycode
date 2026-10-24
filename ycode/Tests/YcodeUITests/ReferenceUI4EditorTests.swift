import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeUI

/// reference-ui-4.md §4 (inline issues) and §7 (Quick Help).
@Suite struct ReferenceUI4EditorTests {
    @Test func truncationAddsEllipsis() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) }
        #expect(InlineIssueLayout.truncate("short", toWidth: 10, measure: measure) == "short")
        let t = InlineIssueLayout.truncate("cannot find 'x' in scope", toWidth: 10, measure: measure)
        #expect(t.hasSuffix("…") && t.count <= 10)
        #expect(InlineIssueLayout.truncate("abc", toWidth: 0, measure: measure) == "")
        #expect(InlineIssueLayout.truncate("one\ntwo", toWidth: 10, measure: measure) == "one")
    }

    @Test func underlineCoversIdentifierAtColumn() {
        let text = "    let value = missing + 1\n" as NSString
        let line = NSRange(location: 0, length: text.length)
        let r = InlineIssueLayout.underlineRange(column: 17, lineRange: line, in: text)
        #expect(r.map { text.substring(with: $0) } == "missing")
        let none = InlineIssueLayout.underlineRange(column: 0, lineRange: line, in: text)
        #expect(none.map { text.substring(with: $0) } == "let")
    }

    @Test func primaryIsMostSevere() {
        let w = Diagnostic(severity: .warning, message: "w")
        let e = Diagnostic(severity: .error, message: "e")
        #expect(InlineIssueLayout.primary([w, e])?.message == "e")
        #expect(InlineIssueLayout.symbolName(.error) != InlineIssueLayout.symbolName(.warning))
    }

    @MainActor @Test func editMakesIssuesStaleUntilNextBuild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.swift")
        try "let a = b\n".write(to: f, atomically: true, encoding: .utf8)
        let e = SourceEditorController()
        try e.open(f)
        let d = Diagnostic(severity: .error, message: "cannot find 'b' in scope", location: .init(file: f.path, line: 1, column: 9))
        e.setIssues([d])
        #expect(!e.issuesAreStale)
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        e.textView.insertText("// x\n", replacementRange: e.textView.selectedRange())
        #expect(e.issuesAreStale)
        #expect(e.gutter.marks.issuesStale)
        e.setIssues([d])             // the same list (a breakpoint refresh) stays stale
        #expect(e.issuesAreStale)
        var moved = d
        moved.location?.line = 2
        e.setIssues([moved])          // a new build replaces them
        #expect(!e.issuesAreStale)
        // Draws without trapping (icon, message, underline).
        e.view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        e.view.layoutSubtreeIfNeeded()
        let rep = e.textView.bitmapImageRepForCachingDisplay(in: e.textView.bounds)!
        e.textView.cacheDisplay(in: e.textView.bounds, to: rep)
        try ReferenceUI4Shots.save(e.view, "inline-issues.png")
    }

    static let hover = """
    ```swift
    func area(of circle: Circle, scale: Double) throws -> Double
    ```

    ---

    Computes the area of a circle.

    The result is scaled.
    Second line of the discussion.

    - Parameters:
      - circle: The circle to measure.
      - scale: A factor applied to
        the result.
    - Returns: The scaled area.
    - Throws: `GeometryError` for a negative radius.
    - Note: Uses `Double.pi`.
    - Warning: Not for huge circles.
    """

    @Test func quickHelpParsesSwiftMarkup() {
        let d = QuickHelpDocument(hover: Self.hover, file: "/tmp/Geometry.swift")
        #expect(d.title == "area")
        #expect(d.summary == "Computes the area of a circle.")
        #expect(d.declaration.hasPrefix("func area(of circle"))
        #expect(d.parameters.map(\.name) == ["circle", "scale"])
        #expect(d.parameters[1].text == "A factor applied to the result.")
        #expect(d.returns == "The scaled area.")
        #expect(d.throwsText == "GeometryError for a negative radius.")
        #expect(d.discussion == ["The result is scaled. Second line of the discussion."])
        #expect(d.callouts.map(\.title) == ["Note", "Warning"])
        #expect(d.sectionOrder == ["Title", "Summary", "Declaration", "File", "Parameters", "Return Value", "Throws",
                                   "Discussion", "Note", "Warning", "Open in Developer Documentation"])
    }

    @Test func quickHelpSingleParameterAndUndocumented() {
        let one = QuickHelpDocument(hover: "```swift\nfunc f(x: Int)\n```\n\nDoes f.\n\n- Parameter x: The x.\n")
        #expect(one.parameters == [.init(name: "x", text: "The x.")])
        let bare = QuickHelpDocument(hover: "```swift\nstruct Circle\n```")
        #expect(bare.title == "Circle")
        #expect(bare.sectionOrder == ["Title", "Declaration", "Open in Developer Documentation"])
    }

    @MainActor @Test func quickHelpViewOrder() throws {
        let v = QuickHelpView.make(QuickHelpDocument(hover: Self.hover, file: "/tmp/Geometry.swift"))
        let ids = v.arrangedSubviews.map { $0.accessibilityIdentifier() }
        #expect(ids.first == "quickhelp.title")
        let decl = ids.firstIndex(of: "quickhelp.declaration")!, file = ids.firstIndex(of: "quickhelp.file")!
        let callout = ids.firstIndex(of: "quickhelp.callout")!
        #expect(decl < file && file < callout)
        #expect((v.arrangedSubviews.last as? NSButton)?.title == "Open in Developer Documentation")
        let sections = v.arrangedSubviews.compactMap { $0 as? NSTextField }.filter { $0.accessibilityIdentifier() == "quickhelp.section" }.map(\.stringValue)
        #expect(sections == ["Parameters", "Return Value", "Throws", "Discussion"])
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 520))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        v.frame = box.bounds.insetBy(dx: 12, dy: 12)
        box.addSubview(v)
        try ReferenceUI4Shots.save(box, "quick-help.png")
    }
}

/// reference-ui-4.md §9: the empty editor.
@MainActor
@Suite(.serialized) struct ReferenceUI4EmptyEditorTests {
    @Test func rowFormat() {
        let r = EmptyEditorView.row(path: "/w/App/Sources/App/main.swift", root: "/w")
        #expect(r.name == "main" && r.breadcrumb == "App › Sources › App")
    }

    @Test func emptyEditorShowsRecentFilesAndOpens() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("Sources/App/main.swift"), other = dir.appendingPathComponent("Sources/App/Other.swift")
        try "print(1)\n".write(to: main, atomically: true, encoding: .utf8)
        try "struct Other {}\n".write(to: other, atomically: true, encoding: .utf8)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)),
                                           loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.open(path: main.path, line: nil)
        #expect(wc.editor.emptyView == nil)
        wc.open(path: other.path, line: nil)
        wc.closeDocument(nil)
        await wc.workspaceCandidatesIdle()   // the index is read in the background
        let empty = try #require(wc.editor.emptyView)
        #expect(empty.heading.stringValue == "Recent Files")
        #expect(empty.field.placeholderString == "Open Quickly")
        #expect(empty.rows.map(\.name) == ["Other", "main"])
        #expect(empty.rows.first?.breadcrumb.hasSuffix("Sources › App") == true)
        // Typing behaves like Open Quickly.
        empty.search("mai")
        #expect(empty.rows.first?.name == "main")
        empty.search("")
        empty.open(row: 1)
        #expect(wc.editor.fileURL?.lastPathComponent == "main.swift")
        #expect(wc.editor.emptyView == nil)
        try ReferenceUI4Shots.save(empty, "empty-editor.png")
    }
}

/// Optional off-screen renders for review.
enum ReferenceUI4Shots {
    static let dir = ProcessInfo.processInfo.environment["YCODE_SHOTS_DIR"]
    @MainActor static func save(_ v: NSView, _ name: String) throws {
        guard let dir else { return }
        if v.frame.isEmpty { v.frame = NSRect(x: 0, y: 0, width: 700, height: 460) }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
