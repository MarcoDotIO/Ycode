import Foundation
import Testing
@testable import YcodeUI

private func nsr(_ a: Int, _ l: Int = 0) -> NSRange { NSRange(location: a, length: l) }
private func offset(_ text: String, line: Int, column: Int = 0) -> Int { LineIndex(text).range(ofLine: line)!.location + column }

/// The text commands of `reference-ui-5.md` §6.4, as functions of the text.
@Suite struct EditorTextCommandsTests {
    // MARK: Move Line Up / Down (M6)

    @Test func moveLines() throws {
        let t = "a\nbb\nccc\n"
        // Caret on "bb" (column 1): up swaps with "a"; the caret stays on "bb".
        let up = try #require(TextCommands.moveLines(in: t, selection: nsr(3), up: true))
        #expect(up.applied(to: t) == "bb\na\nccc\n" && up.selection == nsr(1))
        let down = try #require(TextCommands.moveLines(in: t, selection: nsr(3), up: false))
        #expect(down.applied(to: t) == "a\nccc\nbb\n" && down.selection == nsr(7))
        // Two selected lines move together, selection kept.
        let both = try #require(TextCommands.moveLines(in: t, selection: nsr(2, 6), up: true))
        #expect(both.applied(to: t) == "bb\nccc\na\n" && both.selection == nsr(0, 6))
        // The last line without a newline.
        let u = "x\ny"
        #expect(TextCommands.moveLines(in: u, selection: nsr(2), up: true)?.applied(to: u) == "y\nx")
        #expect(TextCommands.moveLines(in: u, selection: nsr(0), up: false)?.applied(to: u) == "y\nx")
        // Disabled at the first / last line.
        #expect(!TextCommands.canMoveLines(in: t, selection: nsr(0), up: true))
        #expect(TextCommands.canMoveLines(in: t, selection: nsr(0), up: false))
        #expect(!TextCommands.canMoveLines(in: u, selection: nsr(2), up: false))
        #expect(TextCommands.moveLines(in: u, selection: nsr(2), up: false) == nil)
    }

    // MARK: Shift and Re-Indent (M2, M6)

    @Test func shiftLeftAndRight() throws {
        let t = "a\n    b\n\n\tc\n"
        let all = nsr(0, (t as NSString).length)
        #expect(TextCommands.shift(in: t, selection: all, right: true, unit: "    ", indentWidth: 4)?.applied(to: t) == "    a\n        b\n\n    \tc\n")
        #expect(TextCommands.shift(in: t, selection: all, right: false, unit: "    ", indentWidth: 4)?.applied(to: t) == "a\nb\n\nc\n")
        // The caret follows its text.
        let r = try #require(TextCommands.shift(in: "  foo", selection: nsr(3), right: true, unit: "  ", indentWidth: 2))
        #expect(r.selection == nsr(5))
    }

    @Test func reindent() throws {
        let t = """
        struct A {
        func f(x: Int) {
        switch x {
        case 1:
        print("{")
        default:
        break
        }
        let y = [
        1,
        ]
        }
        /* keep
             this */
        }

        """
        let all = nsr(0, (t as NSString).length)
        let r = try #require(TextCommands.reindent(in: t, selection: all, language: .swift, unit: "    "))
        #expect(r.applied(to: t) == """
        struct A {
            func f(x: Int) {
                switch x {
                case 1:
                    print("{")
                default:
                    break
                }
                let y = [
                    1,
                ]
            }
            /* keep
             this */
        }

        """)
        // The caret's line only.
        let one = try #require(TextCommands.reindent(in: "if a {\nb\n}\n", selection: nsr(7), language: .swift, unit: "\t"))
        #expect(one.applied(to: "if a {\nb\n}\n") == "if a {\n\tb\n}\n")
    }

    // MARK: Add Documentation (M6)

    @Test func addDocumentation() throws {
        let t = """
        struct Counter {
            @discardableResult
            func increment(by amount: Int, _ times: Int) throws -> Int { 0 }
            func reset(to value: Int) {}
            var count = 0
        }
        """
        let doc = try #require(TextCommands.addDocumentation(in: t, caretLine: 3))
        let out = doc.applied(to: t)
        #expect(out.contains("""
            /// <#Description#>
            /// - Parameters:
            ///   - amount: <#amount description#>
            ///   - times: <#times description#>
            /// - Returns: <#description#>
            /// - Throws: <#description#>
            @discardableResult
            func increment
        """))
        // The summary placeholder is selected.
        #expect((out as NSString).substring(with: doc.selection) == "<#Description#>")
        let single = try #require(TextCommands.addDocumentation(in: t, caretLine: 4)).applied(to: t)
        #expect(single.contains("    /// <#Description#>\n    /// - Parameter value: <#value description#>\n    func reset"))
        let property = try #require(TextCommands.addDocumentation(in: t, caretLine: 5)).applied(to: t)
        #expect(property.contains("    /// <#Description#>\n    var count"))
        #expect(TextCommands.addDocumentation(in: "// nothing\n", caretLine: 1) == nil)
    }

    // MARK: Format to Multiple Lines, Reformat To Width

    @Test func formatToMultipleLines() throws {
        let t = "    let x = f(a, g(b, c), [1, 2])\n"
        let caret = (t as NSString).range(of: "a,").location
        let r = try #require(TextCommands.formatToMultipleLines(in: t, caret: caret, language: .swift, unit: "    "))
        #expect(r.applied(to: t) == "    let x = f(\n        a,\n        g(b, c),\n        [1, 2]\n    )\n")
        // Inside the inner list: only that list.
        let inner = (t as NSString).range(of: "c)").location
        #expect(TextCommands.formatToMultipleLines(in: t, caret: inner, language: .swift, unit: "  ")?.applied(to: t)
                == "    let x = f(a, g(\n      b,\n      c\n    ), [1, 2])\n")
        #expect(TextCommands.formatToMultipleLines(in: "let x = 1\n", caret: 4, language: .swift, unit: "  ") == nil)
    }

    @Test func reformatToWidth() throws {
        let t = "    // one two three four five six seven\n    // eight nine\n    //\n    // next paragraph\nlet x = 1\n"
        let r = try #require(TextCommands.reformatToWidth(in: t, selection: nsr(8), column: 24))
        #expect(r.applied(to: t) == "    // one two three\n    // four five six\n    // seven eight nine\n    //\n    // next paragraph\nlet x = 1\n")
        #expect(TextCommands.reformatToWidth(in: t, selection: nsr(offset(t, line: 5)), column: 24) == nil) // not a comment
    }

    // MARK: Selection (M14)

    @Test func balanceDelimiters() throws {
        let t = "f(a, [b, c], { d })"
        let caret = nsr((t as NSString).range(of: "b").location)
        let inner = try #require(TextCommands.balance(in: t, selection: caret, language: .swift))
        #expect((t as NSString).substring(with: inner) == "b, c")
        let outer = try #require(TextCommands.balance(in: t, selection: inner, language: .swift))
        #expect((t as NSString).substring(with: outer) == "[b, c]")
        let next = try #require(TextCommands.balance(in: t, selection: outer, language: .swift))
        #expect((t as NSString).substring(with: next) == "a, [b, c], { d }")
        // Delimiters in strings do not count.
        let s = "g(\"(\", x)"
        #expect(TextCommands.balance(in: s, selection: nsr(7), language: .swift).map { (s as NSString).substring(with: $0) } == "\"(\", x")
    }

    @Test func splitAndColumnSelections() {
        let t = "abc\n\nde\nfghij"
        #expect(TextCommands.splitByLines(in: t, selection: nsr(1, 9)) == [nsr(1, 2), nsr(4, 0), nsr(5, 2), nsr(8, 2)])
        // Same column, clamped to the line end.
        #expect(TextCommands.columnOffset(in: t, from: 2, up: false) == 4)
        #expect(TextCommands.columnOffset(in: t, from: 11, up: true) == 7)
        #expect(TextCommands.columnOffset(in: t, from: 1, up: true) == nil)
    }

    @Test func occurrencesInScope() {
        let t = """
        func a() {
            let n = 1
            print(n, "n") // n
        }
        func b() { print(n) }
        let n = 2
        """
        // A local: only inside its function, not in strings or comments.
        let local = TextCommands.occurrences(in: t, at: offset(t, line: 2, column: 8), language: .swift)
        #expect(local.map(\.location) == [offset(t, line: 2, column: 8), offset(t, line: 3, column: 10)])
        // A file-level name: the whole file.
        let global = TextCommands.occurrences(in: t, at: offset(t, line: 6, column: 4), language: .swift)
        #expect(global.count == 4)
    }

    @Test func symbolNames() {
        let t = """
        struct Counter {
            func increment(by amount: Int, _ x: Int) {}
        }
        """
        let at = offset(t, line: 2, column: 10)
        #expect(TextCommands.symbolName(in: t, at: at, language: .swift, qualified: false) == "increment(by:_:)")
        #expect(TextCommands.symbolName(in: t, at: at, language: .swift, qualified: true) == "Counter.increment(by:_:)")
        #expect(TextCommands.symbolName(in: t, at: offset(t, line: 1, column: 9), language: .swift, qualified: true) == "Counter")
        #expect(TextCommands.symbolName(in: t, at: offset(t, line: 3), language: .swift, qualified: false) == nil)
    }

    // MARK: Folding (M7)

    @Test func functionAndCommentRegions() {
        let t = """
        /// Doc
        /// more
        /// lines
        struct S {
            var x: Int {
                1
            }
            init(a: Int) {
                print(a)
            }
            func f(
                b: Int
            ) -> Int {
                if b > 0 {
                    return 1
                }
                return 0
            }
            /* a
               block */
        }
        """
        let fns = FoldRegions.functionRegions(in: t, language: .swift).map(\.startLine)
        #expect(fns == [5, 8, 13])
        let comments = FoldRegions.commentRegions(in: t, language: .swift)
        #expect(comments == [FoldRegion(startLine: 1, endLine: 3, depth: 0, kind: .comment), FoldRegion(startLine: 19, endLine: 20, depth: 0, kind: .comment)])
        #expect(comments[0].hiddenLines == 2...3)
        let c = "int add(int a, int b) {\n  if (a) {\n    return a;\n  }\n  return b;\n}\n"
        #expect(FoldRegions.functionRegions(in: c, language: .c).map(\.startLine) == [1])
    }

    // MARK: Change gutter (E3)

    @Test func sourceChangeRegions() throws {
        let head = "a\nb\nc\nd\ne\n"
        // Working copy: b modified, line added after d, e deleted.
        let text = "a\nB\nc\nd\nnew\n"
        let r = SourceChanges.regions(text: text, index: head, head: head)
        #expect(r.map(\.kind) == [.modified, .modified])
        #expect(r.map(\.firstLine) == [2, 5] && r.allSatisfy { !$0.staged })
        let added = SourceChanges.regions(text: "a\nb\nx\ny\nc\nd\ne\n", index: head, head: head)
        #expect(added == [SourceChangeRegion(kind: .added, firstLine: 3, lineCount: 2, staged: false)])
        #expect(added[0].accessibilityDescription == "Local modification on lines 3 through 4")
        let deleted = SourceChanges.regions(text: "a\nd\ne\n", index: head, head: head)
        #expect(deleted == [SourceChangeRegion(kind: .deleted, firstLine: 2, lineCount: 0, staged: false)])
        #expect(deleted[0].accessibilityDescription == "Local modification on line 2" && deleted[0].toolTip == "Unstaged change")
        // A staged change: the index has it, the text matches the index there.
        let index = "A\nb\nc\nd\ne\n"
        let staged = SourceChanges.regions(text: "A\nb\nc\nd\nE\n", index: index, head: head)
        #expect(staged.map(\.staged) == [true, false] && staged.map(\.firstLine) == [1, 5])
        #expect(staged[0].toolTip == "Staged change")
        // Not in git: nothing.
        #expect(SourceChanges.regions(text: text, index: nil, head: nil).isEmpty)
        // Stepping wraps.
        #expect(SourceChanges.step(from: 1, in: r, forward: true)?.firstLine == 2)
        #expect(SourceChanges.step(from: 2, in: r, forward: true)?.firstLine == 5)
        #expect(SourceChanges.step(from: 5, in: r, forward: true)?.firstLine == 2)
        #expect(SourceChanges.step(from: 2, in: r, forward: false)?.firstLine == 5)
        #expect(SourceChanges.step(from: 9, in: [], forward: true) == nil)
    }

    // MARK: Counterparts (Navigate, M12)

    @Test func counterpartRingWraps() throws {
        let files = ["/p/A.h", "/p/A.m", "/p/ATests.m", "/p/B.swift"]
        func cps(_ f: String) -> [String] { Counterparts.of(f, in: files, readFile: { _ in nil }) }
        let s1 = try #require(Counterparts.step(from: "/p/A.m", ring: nil, forward: true) { cps("/p/A.m") })
        #expect(s1.next == "/p/A.h" && s1.ring == ["/p/A.m", "/p/A.h"])
        let s2 = try #require(Counterparts.step(from: s1.next, ring: s1.ring, forward: true) { cps(s1.next) })
        #expect(s2.next == "/p/A.m")
        let back = try #require(Counterparts.step(from: "/p/A.m", ring: s2.ring, forward: false) { [] })
        #expect(back.next == "/p/A.h")
        #expect(Counterparts.step(from: "/p/B.swift", ring: s2.ring, forward: true) { cps("/p/B.swift") } == nil)
    }

    // MARK: Minimap (E5)

    @Test @MainActor func minimapWidth() {
        #expect(MinimapView.width(forEditorWidth: 962) == 128)
        #expect(MinimapView.width(forEditorWidth: 480) == 64)
        #expect(MinimapView.width(forEditorWidth: 300) == 60)
    }
}
