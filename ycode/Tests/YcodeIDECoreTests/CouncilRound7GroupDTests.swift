import Foundation
import Testing
import YcodeBuild
import YcodeDebug
@testable import YcodeIDECore

/// Council round 7, group D (`fidelity-council.md` rows 188 and 190):
/// an unresolved merge is a workspace issue, and the inspector slide's
/// clock plays the whole slide after a late first frame.
@MainActor
@Suite struct CouncilRound7GroupDTests {
    // MARK: Row 188

    @Test func conflictedFilesAreErrorsAtTheirFirstMarker() {
        let texts = ["/r/A.swift": "let a = 1\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n", "/r/B.swift": "clean\n"]
        let list = ConflictIssues.diagnostics(conflicted: ["/r/B.swift", "/r/A.swift"]) { texts[$0] }
        #expect(list.map { $0.location?.file } == ["/r/A.swift", "/r/B.swift"])
        #expect(list.map { $0.location?.line } == [2, 1])
        #expect(list.allSatisfy { $0.severity == .error && $0.message == ConflictIssues.message })
    }

    @Test func aConflictCountsInTheWorkspacesIssues() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-r7-conflict-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Demo"), withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> f\n".write(to: dir.appendingPathComponent("Sources/Demo/Greeting.swift"), atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "init", "-q", dir.path]
        try git.run()
        git.waitUntilExit()
        let repo = try #require(GitRepository(containing: dir))
        var snapshot = SourceControlSnapshot(repository: repo)
        snapshot.changes = [GitRepository.Change(path: "Sources/Demo/Greeting.swift", index: "U", worktree: "U", status: .conflicted),
                            GitRepository.Change(path: "Package.swift", index: "M", worktree: " ", status: .modified)]
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        session.noteConflicts(snapshot)
        let shown = session.displayedIssues.filter { $0.message == ConflictIssues.message }
        #expect(shown.count == 1 && shown.first?.location?.line == 1)
        #expect(shown.first?.location?.file.hasSuffix("Sources/Demo/Greeting.swift") == true)
        // The merge done: the issue goes.
        session.noteConflicts(SourceControlSnapshot(repository: repo))
        #expect(!session.displayedIssues.contains { $0.message == ConflictIssues.message })
    }

    // MARK: Row 190

    @Test func aLateFirstFrameStillPlaysTheWholeHide() {
        // Round 7: the first frame 720 ms after the press.
        var c = InspectorSlideClock(show: false, press: 0)
        var frames: [Double] = []
        var t = 0.720
        while frames.last != 1, frames.count < 100 {
            frames.append(c.progress(at: t))
            t += 1.0 / 60
        }
        #expect(frames.first == 0)
        // Every position on the way: at least 7 frames between 0 and 1, none jumping more than 25 %.
        let moving = frames.filter { $0 > 0 && $0 < 1 }
        #expect(moving.count >= 7, "\(frames)")
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1 - $0 <= 0.25 })
        // About the hide's 200 ms of motion after the first frame (round 10, row 248).
        let ms = Double(frames.count - 1) / 60 * 1000
        #expect(ms > 185 && ms < 235, "\(ms)")
    }

    @Test func onTimeFramesFollowThePressClock() {
        var c = InspectorSlideClock(show: false, press: 10)
        #expect(c.progress(at: 10.016) == EditorMetrics.inspectorSlideProgress(elapsed: 0.016, show: false))
        let p = c.progress(at: 10.150)   // a 134 ms stall advances only 1/30 s
        #expect(abs(p - EditorMetrics.inspectorSlideProgress(elapsed: 0.016 + 1.0 / 30, show: false)) < 1e-9)
        var s = InspectorSlideClock(show: true, press: 0)
        var last = 0.0, t = 0.0
        while last < 1, t < 2 { t += 1.0 / 120; last = s.progress(at: t) }
        #expect(abs(t - EditorMetrics.inspectorSlideTotal(show: true)) < 0.02)
    }
}

/// Row 192, the owner's decision of 2026-11-08, as revised by round 9's
/// rule 1 (rows 208–213): language files show their official logos as
/// single-colour line art (devicon v2.18.0's plain or line variants), JSON
/// Ycode's own glyph, other files Ycode's glyphs, and the project's row the
/// Ycode mark. Round 9's own tests are `CouncilRound9GlyphTests`.
@Suite struct CouncilRound7NavigatorIconTests {
    @Test func extensionsMapToTheirLogos() {
        let expected: [String: String] = [
            "a.swift": "swift", "a.py": "python", "a.cpp": "cplusplus", "a.cc": "cplusplus", "a.cxx": "cplusplus", "a.hpp": "cplusplus",
            "a.hh": "cplusplus", "a.c": "c", "a.h": "c", "a.js": "javascript", "a.mjs": "javascript", "a.cjs": "javascript",
            "a.ts": "typescript", "a.tsx": "typescript", "a.rs": "rust", "a.go": "go", "a.rb": "ruby", "a.java": "java",
            "a.kt": "kotlin", "a.kts": "kotlin", "a.html": "html5", "a.htm": "html5", "a.css": "css3",
            "a.sh": "bash", "a.bash": "bash", "a.zsh": "bash", "Main.SWIFT": "swift",
        ]
        for (file, logo) in expected { #expect(LanguageLogos.logo(forFileName: file) == logo, "\(file)") }
        // JSON and Markdown: Ycode's own glyphs (the owner's rules of round 9), not logos.
        #expect(LanguageLogos.logo(forFileName: "palette.json") == nil && NavigatorRowIcon.ofFile("palette.json") == .json)
        #expect(LanguageLogos.logo(forFileName: "NOTES.md") == nil && NavigatorRowIcon.ofFile("NOTES.md") == .markdown)
        // No official logo: Ycode's own glyphs (Objective-C, Metal, plists, …).
        for file in ["a.m", "a.mm", "a.metal", "Info.plist", "a.xcconfig", "a.entitlements", "Main.storyboard", "A.xcassets", "README"] {
            #expect(LanguageLogos.logo(forFileName: file) == nil, "\(file)")
            #expect(NavigatorRowIcon.of(kind: .file, name: file, path: nil) == .symbol(WorkspaceChrome.fileSymbol(file)))
        }
        // An image: Ycode's own picture glyph (round 10, row 243).
        #expect(LanguageLogos.logo(forFileName: "a.png") == nil && NavigatorRowIcon.of(kind: .file, name: "a.png", path: nil) == .image)
    }

    /// Every logo is converted from its single-colour SVG in the resources
    /// (a plain variant, or the line variant where devicon has no plain
    /// one), and no full-colour original is left (Markdown is Ycode's own
    /// book since round 9).
    @Test func everyLogoHasItsSingleColourSVG() throws {
        #expect(Set(LanguageLogos.extensions.values) == Set(LanguageLogos.names) && LanguageLogos.names.count == 14)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/language-logos")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("LICENSE").path))
        for name in LanguageLogos.names {
            let source = try #require(LanguageLogos.source(name))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(source).path), "\(name)")
            let expected = ["c", "rust"].contains(name) ? "\(name)-line.svg" : "\(name)-plain.svg"
            #expect(source == expected)
            let o = try #require(LanguageLogos.outline(name))
            #expect(o.width > 50 && o.height > 50 && !o.paths.isEmpty, "\(name)")
        }
        let svgs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".svg") }
        #expect(svgs.count == 14 && !svgs.contains { $0.hasSuffix("-original.svg") })
    }

    @Test func theProjectRowShowsTheYcodeMark() {
        let root = CouncilRound7RestoreTests.councilTree()
        #expect(NavigatorRowIcon.of(root) == .ycodeMark)
        #expect(NavigatorRowIcon.of(root.children[0]) == .folder)
        #expect(NavigatorRowIcon.of(root.children[0].children[0].children[0]) == .logo("swift"))
        // The mark is the small master of the app icon.
        #expect(ProductIconSmallGeometry.fieldMin == 40 && ProductIconSmallGeometry.strokeWidth == 150)
    }
}

/// Row 189: the language server's work in progress is the indexing subtitle.
@MainActor
@Suite struct CouncilRound7SubtitleTests {
    @Test func progressBeginsAndEnds() {
        var p = LanguageProgress()
        let begin = p.apply(["token": "idx", "value": ["kind": "begin", "title": "Indexing"]])
        #expect(begin && p.isActive)
        let report = p.apply(["token": "idx", "value": ["kind": "report", "percentage": 40]])
        #expect(!report && p.isActive)
        let second = p.apply(["token": .number(3), "value": ["kind": "begin"]])
        let end1 = p.apply(["token": "idx", "value": ["kind": "end"]])
        #expect(second && end1 && p.isActive)
        let end2 = p.apply(["token": .number(3), "value": ["kind": "end"]])
        #expect(end2 && !p.isActive)
        let gone = p.apply(["token": "gone", "value": ["kind": "end"]])
        #expect(!gone)
    }

    @Test func subtitleNamesTheActivity() {
        #expect(WorkspaceChrome.idleActivityText(preparingEditorServices: false, indexing: true) == "Indexing files")
        #expect(WorkspaceChrome.idleActivityText(preparingEditorServices: true, indexing: true) == WorkspaceChrome.preparingEditorServicesText)
        #expect(WorkspaceChrome.idleActivityText(preparingEditorServices: false, indexing: false).isEmpty)
    }
}

/// Row 192: the selector's four own glyphs stay inside their box.
@Suite struct CouncilRound7SelectorGlyphTests {
    @Test func fourGlyphsReplaceTheirSymbols() {
        #expect(WorkspaceChrome.navigatorSymbols.filter { SelectorGlyphs.parts(forSymbol: $0) != nil }
                == ["arrow.triangle.branch", "gauge.with.dots.needle.33percent", "tag", "list.bullet.rectangle"])
        for s in SelectorGlyphs.replaced {
            for part in SelectorGlyphs.parts(forSymbol: s) ?? [] {
                switch part {
                case let .roundedRect(x, y, w, h, _): #expect(x >= 0 && y >= 0 && x + w <= SelectorGlyphs.width && y + h <= SelectorGlyphs.height)
                case let .lines(points, _): #expect(points.allSatisfy { $0.x >= 0 && $0.x <= SelectorGlyphs.width && $0.y >= 0 && $0.y <= SelectorGlyphs.height })
                case let .dot(x, y, r): #expect(x - r >= 0 && x + r <= SelectorGlyphs.width && y - r >= 0 && y + r <= SelectorGlyphs.height)
                }
            }
        }
        // The tag: pointed right end, no hole (one closed outline).
        #expect(SelectorGlyphs.parts(forSymbol: "tag")?.count == 1)
        #expect(SelectorGlyphs.parts(forSymbol: "folder") == nil)
    }
}
