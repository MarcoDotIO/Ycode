import Foundation
import Testing
@testable import YcodeIDECore

/// A fresh folder outside any repository (the ignore rules read the
/// enclosing repository's `.gitignore`, and this worktree ignores its
/// build folders).
func findScratch(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-find-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func put(_ dir: URL, _ rel: String, _ text: String) throws {
    let url = dir.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// specs/ide/navigators.md §Find navigator, "Ycode implementation": the
/// query kinds, match styles and case, regular expressions, the engine.
@Suite struct FindQueryTests {
    static let text = "greet Greet greeting regreet\nx_greet greet_x GREET\n"

    /// Every Text / Regular Expression / Multiple Words × match style ×
    /// case combination on one text.
    @Test(arguments: [FindQuery.Kind.text, .regularExpression, .multipleWords])
    func everyOptionCombination(kind: FindQuery.Kind) throws {
        let query = switch kind {
        case .regularExpression: "gr[e]+t"
        case .multipleWords: "greet regreet"
        default: "greet"
        }
        // (match, ignoreCase) → match count.
        let single: [FindQuery.Match: (Int, Int)] = [
            .containing: (7, 5), .matchingWord: (3, 1), .startingWith: (5, 3), .endingWith: (5, 3),
        ]
        let words: [FindQuery.Match: (Int, Int)] = [
            .containing: (5, 4), .matchingWord: (3, 2), .startingWith: (4, 3), .endingWith: (4, 3),
        ]
        for match in FindQuery.Match.allCases {
            for ignoreCase in [true, false] {
                let q = FindQuery(query, kind: kind, match: match, ignoreCase: ignoreCase)
                let found = try #require(q.matcher()).matches(in: Self.text)
                let expected = (kind == .multipleWords ? words : single)[match]!
                #expect(found.count == (ignoreCase ? expected.0 : expected.1), "\(kind) \(match) ignoreCase=\(ignoreCase): \(found.map(\.matchedText))")
                // Multiple Words: only the line holding every word.
                if kind == .multipleWords { #expect(Set(found.map(\.line)) == [1]) }
            }
        }
        // Words on different lines give nothing.
        #expect(FindQuery("greeting x_greet", kind: .multipleWords).matcher()?.matches(in: Self.text).isEmpty == true)
    }

    @Test func matchRowsCarryLineColumnAndHighlight() throws {
        let m = try #require(FindQuery("Greet", ignoreCase: false).matcher()).matches(in: "\n    let g = Greet()\n")
        #expect(m.count == 1)
        #expect(m[0].line == 2 && m[0].column == 13 && m[0].text == "let g = Greet()")
        #expect((m[0].text as NSString).substring(with: m[0].highlight) == "Greet" && m[0].matchedText == "Greet")
    }

    @Test func regularExpressionsCapturesAndLines() throws {
        let src = "struct A {\n    let x = 1\n}\nstruct Bee {\n  let y = 2\n}\nfunc f() {}\n"
        // `^` and `$` are line anchors; `.` stays in its line.
        let funcs = try #require(FindQuery("^func", kind: .regularExpression).matcher()).matches(in: src)
        #expect(funcs.map(\.line) == [7])
        #expect(try #require(FindQuery("A.*let", kind: .regularExpression).matcher()).matches(in: src).isEmpty)
        // Multi-line: `\n` crosses lines; the row is the first line, the span counts lines.
        let multi = try #require(FindQuery("struct (\\w+) \\{\\n\\s+let", kind: .regularExpression).matcher()).matches(in: src)
        #expect(multi.map(\.line) == [1, 4] && multi.map(\.lineSpan) == [2, 2])
        #expect(multi[0].text == "struct A {")
        // Capture groups feed the replacement template.
        let q = FindQuery("let (\\w+) = (\\d+)", kind: .regularExpression)
        let res = WorkspaceSearch.FileResult(path: "/x", matches: try #require(q.matcher()).matches(in: src))
        let plan = ReplacePlan(query: q, replacement: "var $1: Int = $2 * 10", results: [res])
        #expect(plan.newText(file: 0, text: src).text.contains("var x: Int = 1 * 10") && plan.newText(file: 0, text: src).replaced == 2)
        // Text mode: `$1` is literal.
        let lit = FindQuery("let", kind: .text)
        let litPlan = ReplacePlan(query: lit, replacement: "$1", results: [.init(path: "/x", matches: try #require(lit.matcher()).matches(in: src))])
        #expect(litPlan.newText(file: 0, text: src).text.contains("$1 x = 1"))
        // Invalid expressions and empty matches give nothing.
        #expect(FindQuery("(", kind: .regularExpression).matcher() == nil)
        #expect(try #require(FindQuery("x*", kind: .regularExpression).matcher()).matches(in: "abc").isEmpty)
        #expect(FindQuery("", kind: .text).matcher() == nil && FindQuery("x", kind: .symbols).matcher() == nil)
    }

    @Test func bytePrecheck() throws {
        let m = try #require(FindQuery("Greeter").matcher())
        #expect("let a = GREETER".utf8.withContiguousStorageIfAvailable { m.mayMatch(UnsafeRawBufferPointer($0)) } == true)
        #expect("let a = Greet".utf8.withContiguousStorageIfAvailable { m.mayMatch(UnsafeRawBufferPointer($0)) } == false)
        let cs = try #require(FindQuery("Greeter", ignoreCase: false).matcher())
        #expect("GREETER".utf8.withContiguousStorageIfAvailable { cs.mayMatch(UnsafeRawBufferPointer($0)) } == false)
        // Non-ASCII queries and regular expressions with metacharacters are not pre-checked.
        #expect(FindQuery("café").matcher()?.needles.isEmpty == true)
        #expect(FindQuery("a.b", kind: .regularExpression).matcher()?.needles.isEmpty == true)
        #expect(FindQuery("plain", kind: .regularExpression).matcher()?.needles.count == 1)
    }
}

@Suite struct FindEngineTests {
    @Test func binariesLargeFilesAndEncodingsAreHandled() throws {
        let dir = try findScratch("binary")
        defer { try? FileManager.default.removeItem(at: dir) }
        try put(dir, "a.swift", "let needle = 1\n")
        var bin = Data("needle".utf8)
        bin.append(contentsOf: [0, 1, 2, 0])
        try bin.write(to: dir.appendingPathComponent("blob.dat"))
        try Data("needle in a png".utf8).write(to: dir.appendingPathComponent("image.png"))
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("\"key\" = \"needle\";\n".data(using: .utf16LittleEndian)!)
        try utf16.write(to: dir.appendingPathComponent("Localizable.strings"))
        try put(dir, "big.txt", String(repeating: "needle ", count: 200))
        let files = ["a.swift", "blob.dat", "image.png", "Localizable.strings", "big.txt"].map { dir.appendingPathComponent($0).path }
        var r = FindEngine.Request(query: FindQuery("needle"), paths: files)
        r.maxFileSize = 1000
        let s = FindEngine.search(r)
        #expect(s.files.map { ($0.path as NSString).lastPathComponent } == ["a.swift", "Localizable.strings"])
        #expect(s.skippedBinary == 2 && s.skippedLarge == 1 && s.searchedFiles == 2)
    }

    @Test func unsavedBuffersAreSearchedInsteadOfTheDisk() throws {
        let dir = try findScratch("buffers")
        defer { try? FileManager.default.removeItem(at: dir) }
        try put(dir, "A.swift", "let old = 1\n")
        let path = dir.appendingPathComponent("A.swift").path
        let s = FindEngine.search(.init(query: FindQuery("fresh"), paths: [path], buffers: [path: "let fresh = 2\n"]))
        #expect(s.files.first?.matches.first?.line == 1)
        #expect(FindEngine.search(.init(query: FindQuery("old"), paths: [path], buffers: [path: "let fresh = 2\n"])).files.isEmpty)
    }

    @Test func parallelResultsKeepFileOrderAndStopAtTheLimit() throws {
        let dir = try findScratch("order")
        defer { try? FileManager.default.removeItem(at: dir) }
        var paths: [String] = []
        for i in 0..<300 {
            let name = String(format: "F%03d.swift", i)
            try put(dir, name, i % 3 == 0 ? "let hit\(i) = 1\nlet hit = 2\n" : "let miss = 0\n")
            paths.append(dir.appendingPathComponent(name).path)
        }
        final class Box: @unchecked Sendable { let lock = NSLock(); var order: [String] = [] }
        let box = Box()
        let all = FindEngine.search(FindEngine.Request(query: FindQuery("hit"), files: paths.map { FindCandidate($0) }, limit: 100_000, concurrency: 8)) { f in
            box.lock.withLock { box.order.append(f.path) }
        }
        let expected = paths.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        #expect(all.files.map(\.path) == expected && box.order == expected)
        #expect(all.matchCount == 200 && !all.truncated)
        let limited = FindEngine.search(FindEngine.Request(query: FindQuery("hit"), files: paths.map { FindCandidate($0) }, limit: 21, concurrency: 8))
        #expect(limited.truncated && limited.matchCount == 22 && limited.files.map(\.path) == Array(expected.prefix(11)))
    }

    @Test func cancellationAndStreaming() async throws {
        let dir = try findScratch("stream")
        defer { try? FileManager.default.removeItem(at: dir) }
        var paths: [String] = []
        for i in 0..<50 {
            try put(dir, "f\(i).txt", "token \(i)\n")
            paths.append(dir.appendingPathComponent("f\(i).txt").path)
        }
        let c = FindEngine.Cancellation()
        c.cancel()
        let none = FindEngine.search(.init(query: FindQuery("token"), paths: paths), cancellation: c)
        #expect(none.files.isEmpty && none.cancelled)
        var seen: [String] = []
        var finished: FindEngine.Summary?
        for await e in FindEngine.stream(.init(query: FindQuery("token"), paths: paths)) {
            switch e {
            case .file(let f): seen.append(f.path)
            case .finished(let s): finished = s
            }
        }
        #expect(seen == paths && finished?.matchCount == 50 && finished?.cancelled == false)
        // Leaving the stream early stops the search.
        var first: String?
        for await e in FindEngine.stream(.init(query: FindQuery("token"), paths: paths)) {
            if case .file(let f) = e { first = f.path; break }
        }
        #expect(first == paths[0])
    }

    /// The legacy entry point searches the workspace tree, folders included.
    @Test func workspaceSearchUsesTheEngine() throws {
        let dir = try findScratch("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        try put(dir, "Sources/A.swift", "let token = 1\n")
        try put(dir, "Sources/notes.unknownext", "token here\n")
        let root = NavigatorTree.package(at: dir)
        #expect(WorkspaceSearch.search("token", in: root).count == 2)
    }
}

/// Scopes, folder references and ignore rules.
@Suite struct FindScopeTests {
    /// project ▸ Sources (group: A, B) ▸ Synced (folder) ▸ Assets (folder
    /// reference); the repository ignores `*.log`, `build/`, `/Generated`
    /// (anchored: not `Assets/Generated`), but keeps `keep.log`; `Assets`
    /// ignores `docs/**/*.tmp` in its own `.gitignore`.
    func fixture() throws -> (URL, NavigatorNode) {
        let dir = try findScratch("scopes")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try put(dir, ".gitignore", "# comment\n*.log\nbuild/\n!keep.log\n/Generated\n")
        try put(dir, "Assets/.gitignore", "docs/**/*.tmp\n")
        try put(dir, "Sources/A.swift", "let token = 1\n")
        try put(dir, "Sources/B.m", "int token;\n")
        try put(dir, "Synced/C.swift", "token\n")
        try put(dir, "Synced/debug.log", "token\n")
        try put(dir, "Synced/keep.log", "token\n")
        try put(dir, "Synced/build/out.swift", "token\n")
        try put(dir, "Assets/Data/D.json", "{\"token\": 1}\n")
        try put(dir, "Assets/node_modules/x.js", "token\n")
        try put(dir, "Assets/Generated/G.swift", "token\n")
        try put(dir, "Assets/docs/a/b/t.tmp", "token\n")
        try put(dir, "Assets/Pictures.xcassets/Contents.json", "token\n")
        try put(dir, "Generated/H.swift", "token\n")
        try put(dir, "Generated.swift", "token\n")
        let p = { (rel: String) in dir.appendingPathComponent(rel).path }
        let sources = NavigatorNode(name: "Sources", kind: .group, path: p("Sources"), children: [
            NavigatorNode(name: "A.swift", kind: .file, path: p("Sources/A.swift")),
            NavigatorNode(name: "B.m", kind: .file, path: p("Sources/B.m")),
        ])
        let synced = NavigatorNode(name: "Synced", kind: .folder, path: p("Synced"), children: NavigatorTree.directory(p("Synced")))
        let assets = NavigatorNode(name: "Assets", kind: .file, path: p("Assets"))
        // Listed by reference: searched although the repository ignores /Generated.
        let generated = NavigatorNode(name: "H.swift", kind: .file, path: p("Generated/H.swift"))
        let root = NavigatorNode(name: "Demo", kind: .container, path: p("Demo.xcodeproj"), children: [sources, synced, assets, generated])
        return (dir, root)
    }

    func names(_ c: [FindCandidate], _ dir: URL) -> [String] { c.map { String($0.path.dropFirst(dir.path.count + 1)) } }

    @Test func workspaceFoldersReferencesAndIgnoreRules() throws {
        let (dir, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = FindScopeResolver(root: root)
        #expect(names(r.candidates(for: .workspace), dir) == [
            "Sources/A.swift", "Sources/B.m", "Synced/C.swift", "Synced/keep.log", "Assets/Data/D.json", "Assets/Generated/G.swift", "Generated/H.swift",
        ])
        // Without .gitignore only the fixed names are skipped.
        let plain = FindScopeResolver(root: root, ignore: FindIgnoreRules(readsGitIgnore: false))
        #expect(names(plain.candidates(for: .workspace), dir).contains("Synced/debug.log"))
        #expect(!names(plain.candidates(for: .workspace), dir).contains("Assets/node_modules/x.js"))
        #expect(!names(plain.candidates(for: .workspace), dir).contains { $0.contains("xcassets") })
    }

    @Test func groupProjectOpenFilesCurrentResultsAndCustomScopes() throws {
        let (dir, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = { (rel: String) in dir.appendingPathComponent(rel).path }
        var r = FindScopeResolver(root: root, openFiles: [p("Synced/C.swift"), p("Sources/B.m"), p("Synced/C.swift")],
                                  currentResults: [p("Sources/A.swift")])
        #expect(names(r.candidates(for: .group(p("Sources"))), dir) == ["Sources/A.swift", "Sources/B.m"])
        #expect(names(r.candidates(for: .group(p("Assets"))), dir) == ["Assets/Data/D.json", "Assets/Generated/G.swift"])
        #expect(names(r.candidates(for: .group(p("Sources/B.m"))), dir) == ["Sources/B.m"])
        #expect(names(r.candidates(for: .project(p("Demo.xcodeproj"))), dir).count == 7)
        #expect(names(r.candidates(for: .openFiles), dir) == ["Synced/C.swift", "Sources/B.m"])
        #expect(names(r.candidates(for: .currentResults), dir) == ["Sources/A.swift"])
        r.customScopes = [
            CustomFindScope(name: "Swift", rules: [.init(.extension, .is, "swift")]),
            CustomFindScope(name: "Open or JSON", matchAll: false, rules: [.init(.location, .is, CustomFindScope.openFilesValue), .init(.extension, .is, "json")]),
            CustomFindScope(name: "Sources ObjC", rules: [.init(.location, .is, p("Sources")), .init(.name, .endsWith, ".m")]),
            CustomFindScope(name: "Regex", rules: [.init(.path, .matches, "Assets/.*\\.swift$")]),
            CustomFindScope(name: "Empty", rules: []),
        ]
        #expect(names(r.candidates(for: .custom("Swift")), dir) == ["Sources/A.swift", "Synced/C.swift", "Assets/Generated/G.swift", "Generated/H.swift"])
        #expect(names(r.candidates(for: .custom("Open or JSON")), dir) == ["Sources/B.m", "Synced/C.swift", "Assets/Data/D.json"])
        #expect(names(r.candidates(for: .custom("Sources ObjC")), dir) == ["Sources/B.m"])
        #expect(names(r.candidates(for: .custom("Regex")), dir) == ["Assets/Generated/G.swift"])
        #expect(r.candidates(for: .custom("Empty")).isEmpty && r.candidates(for: .custom("Missing")).isEmpty)
        // Scopes and the engine together.
        let s = FindEngine.search(FindEngine.Request(query: FindQuery("token"), files: r.candidates(for: .group(p("Sources")))))
        #expect(s.files.count == 2)
    }

    @Test func gitIgnoreSyntax() {
        #expect(FindIgnoreRules.globToRegex("*.log") == "[^/]*\\.log")
        #expect(FindIgnoreRules.globToRegex("a/**/b") == "a/(?:.*/)?b")
        #expect(FindIgnoreRules.globToRegex("**/x") == "(?:.*/)?x")
        #expect(FindIgnoreRules.globToRegex("f?[!ab]") == "f[^/][^ab]")
        let ps = FindIgnoreRules.parse("# c\n\n*.o  \n!keep.o\nout/\n/top\n\\#hash\n", base: "/r")
        #expect(ps.map(\.negated) == [false, true, false, false, false] && ps.map(\.directoryOnly) == [false, false, true, false, false])
    }
}

/// Replace mode: inclusion, preview, Replace All, undo and redo across files.
@Suite struct FindReplaceTests {
    final class Memory: @unchecked Sendable {
        var files: [String: String]
        var failWrites: Set<String> = []
        init(_ f: [String: String]) { files = f }
        var io: ReplaceIO {
            ReplaceIO(read: { self.files[$0] }, write: { p, t in
                guard !self.failWrites.contains(p) else { return false }
                self.files[p] = t
                return true
            })
        }
    }

    func results(_ q: FindQuery, _ m: Memory) throws -> [WorkspaceSearch.FileResult] {
        try m.files.keys.sorted().compactMap { p in
            let found = try #require(q.matcher()).matches(in: m.files[p]!)
            return found.isEmpty ? nil : WorkspaceSearch.FileResult(path: p, matches: found)
        }
    }

    @Test func perMatchAndPerFileInclusionPreviewAndUndoAcrossFiles() throws {
        let mem = Memory(["/a.swift": "let old = old + 1\n", "/b.swift": "old()\nold()\n", "/c.swift": "print(old)\n"])
        let q = FindQuery("old", match: .matchingWord)
        var plan = ReplacePlan(query: q, replacement: "new", results: try results(q, mem))
        #expect(plan.includedCount == 5 && plan.includedFileCount == 3)
        plan.setIncluded(false, file: 0, match: 1)   // a.swift: keep the second "old"
        plan.setIncluded(false, file: 2)             // c.swift left alone
        #expect(plan.includedCount == 3 && plan.includedFileCount == 2)
        let pv = plan.preview(file: 0, match: 0, text: mem.files["/a.swift"]!)
        #expect(pv.before == "let old = old + 1" && pv.after == "let new = old + 1")
        let history = ReplaceHistory()
        let t = plan.apply(mem.io)
        history.record(t)
        #expect(t.replacedCount == 3 && t.changes.map(\.path) == ["/a.swift", "/b.swift"] && t.title == "Replace 3 Occurrences")
        #expect(mem.files == ["/a.swift": "let new = old + 1\n", "/b.swift": "new()\nnew()\n", "/c.swift": "print(old)\n"])
        // One undo restores every file; redo replays.
        #expect(history.undo(mem.io).restored == ["/a.swift", "/b.swift"])
        #expect(mem.files["/a.swift"] == "let old = old + 1\n" && mem.files["/b.swift"] == "old()\nold()\n")
        #expect(history.redo(mem.io).restored.count == 2 && mem.files["/b.swift"] == "new()\nnew()\n")
        // A file edited since is not overwritten.
        mem.files["/b.swift"] = "edited\n"
        let o = history.undo(mem.io)
        #expect(o.restored == ["/a.swift"] && o.conflicts == ["/b.swift"] && mem.files["/b.swift"] == "edited\n")
        #expect(!history.canUndo && history.canRedo)
    }

    @Test func staleMatchesFailedWritesAndOverlaps() throws {
        let mem = Memory(["/a.txt": "alpha beta\n", "/b.txt": "alpha\n"])
        let q = FindQuery("alpha")
        let plan = ReplacePlan(query: q, replacement: "omega", results: try results(q, mem))
        mem.files["/a.txt"] = "ALPHA beta\n"   // changed since the search
        mem.failWrites = ["/b.txt"]
        let t = plan.apply(mem.io)
        #expect(t.stale == ["/a.txt"] && t.failed == ["/b.txt"] && t.changes.isEmpty)
        // Multiple Words can overlap ("ab" and "b"): the first wins.
        let w = FindQuery("ab b", kind: .multipleWords)
        let wp = ReplacePlan(query: w, replacement: "X", results: [.init(path: "/w", matches: try #require(w.matcher()).matches(in: "ab b\n"))])
        #expect(wp.newText(file: 0, text: "ab b\n").text == "X X\n")
    }

    @Test func navigatorModelCountsStepsAndHistory() throws {
        var m = FindNavigatorModel()
        m.query = FindQuery("x")
        #expect(m.countText.isEmpty == false)
        m.begin()
        #expect(m.countText == "No results")
        var s = FindEngine.Summary()
        s.files = [.init(path: "/a", matches: [.init(line: 1, text: "x", range: NSRange(location: 0, length: 1)),
                                               .init(line: 2, text: "x", range: NSRange(location: 2, length: 1))]),
                   .init(path: "/b", matches: [.init(line: 5, text: "x", range: NSRange(location: 9, length: 1))])]
        m.finish(s)
        #expect(m.countText == "3 results in 2 files" && m.plan == nil)
        #expect(m.step(forward: true)?.match.line == 1 && m.step(forward: true)?.match.line == 2)
        #expect(m.step(forward: true)?.path == "/b" && m.step(forward: true)?.match.line == 1)
        #expect(m.step(forward: false)?.path == "/b")
        m.select(file: 0, match: 1)
        #expect(m.step(forward: false)?.match.line == 1)
        m.setMode(.replace)
        m.setReplacement("y")
        #expect(m.plan?.includedCount == 3 && m.plan?.replacement == "y")
        s.truncated = true
        m.finish(s)
        #expect(m.countText == "3 results in 2 files (stopped at the limit)")
        for q in ["a", "b", "a"] + (0..<12).map(String.init) { m.noteRecent(q) }
        #expect(m.recent.count == 10 && m.recent.first == "11" && !m.recent.dropFirst().contains("11"))
        m.query = FindQuery("x", kind: .symbols)
        m.setMode(.replace)
        #expect(m.plan == nil)
    }
}
