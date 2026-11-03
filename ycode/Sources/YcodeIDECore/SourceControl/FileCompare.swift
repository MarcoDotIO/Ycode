import Foundation

/// Compare Files without a window: `ycode compare` (`specs/ide/comparison.md`,
/// "Ycode implementation"). Two files give a unified diff (the format of
/// POSIX `diff -u`, which `UnifiedDiffLines` reads back); three files (with
/// an ancestor) give the merged text, conflicts marked as git marks them.
public enum FileCompare {
    /// A unified diff of two texts: `---`/`+++` headers, then hunks with
    /// `@@ -a,b +c,d @@` and `context` lines around each change. Empty
    /// when the texts have the same lines.
    public static func unifiedDiff(old: String, new: String, oldName: String, newName: String, context: Int = 3) -> String {
        let a = LineDiff.lines(old), b = LineDiff.lines(new)
        let ops = LineDiff.diff(a, b)
        // Old and new line numbers (1-based) before each op.
        var positions: [(Int, Int)] = []
        var o = 1, n = 1
        for op in ops {
            positions.append((o, n))
            switch op {
            case .same: o += 1; n += 1
            case .removed: o += 1
            case .added: n += 1
            }
        }
        let changed = ops.indices.filter { if case .same = ops[$0] { false } else { true } }
        guard !changed.isEmpty else { return "" }
        // Group changes whose context windows touch.
        var groups: [ClosedRange<Int>] = []
        for c in changed {
            let lo = max(0, c - context), hi = min(ops.count - 1, c + context)
            if let last = groups.last, lo <= last.upperBound + 1 { groups[groups.count - 1] = last.lowerBound...max(last.upperBound, hi) }
            else { groups.append(lo...hi) }
        }
        var out = ["--- \(oldName)", "+++ \(newName)"]
        for g in groups {
            var oldCount = 0, newCount = 0, body: [String] = []
            for k in g {
                switch ops[k] {
                case .same(let s): body.append(" " + s); oldCount += 1; newCount += 1
                case .removed(let s): body.append("-" + s); oldCount += 1
                case .added(let s): body.append("+" + s); newCount += 1
                }
            }
            let (os, ns) = positions[g.lowerBound]
            // An empty side starts at the line before (diff -u's convention).
            func range(_ start: Int, _ count: Int) -> String { count == 0 ? "\(start - 1),0" : (count == 1 ? "\(start)" : "\(start),\(count)") }
            out.append("@@ -\(range(os, oldCount)) +\(range(ns, newCount)) @@")
            out += body
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Runs `ycode compare <left> <right> [--ancestor <base>] [--merge <out>]`.
    /// Exit status: 0 same (two files) or merged cleanly (three), 1
    /// different or conflicts, 2 bad arguments or unreadable files.
    public static func run(_ args: [String], print: (String) -> Void = { Swift.print($0, terminator: "") },
                           error report: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) -> Int32 {
        var files: [String] = [], ancestor: String?, mergeOut: String?
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--ancestor": ancestor = it.next()
            case "--merge": mergeOut = it.next()
            default: files.append(a)
            }
        }
        guard files.count == 2, mergeOut == nil || ancestor != nil else {
            report("usage: ycode compare <left> <right> [--ancestor <base> [--merge <output>]]\n")
            return 2
        }
        func read(_ p: String) -> String? {
            guard let t = try? String(contentsOfFile: p, encoding: .utf8) else { report("ycode: cannot read \(p)\n"); return nil }
            return t
        }
        guard let left = read(files[0]), let right = read(files[1]) else { return 2 }
        guard let ancestor else {
            let d = unifiedDiff(old: left, new: right, oldName: files[0], newName: files[1])
            print(d)
            return d.isEmpty ? 0 : 1
        }
        guard let base = read(ancestor) else { return 2 }
        let doc = MergeDocument(base: base, ours: left, theirs: right, oursLabel: files[0], theirsLabel: files[1], baseLabel: ancestor)
        if let mergeOut {
            do { try doc.result.write(toFile: mergeOut, atomically: true, encoding: .utf8) } catch {
                report("ycode: cannot write \(mergeOut)\n")
                return 2
            }
        } else {
            print(doc.result)
        }
        if doc.unresolvedCount > 0 { report("\(doc.unresolvedCount) conflict\(doc.unresolvedCount == 1 ? "" : "s")\n") }
        return doc.unresolvedCount == 0 ? 0 : 1
    }
}
