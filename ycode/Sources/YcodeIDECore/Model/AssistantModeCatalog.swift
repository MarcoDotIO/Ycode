import Foundation

/// The assistant editor's mode pop-up (`specs/ide/reference-ui-4.md` §16):
/// every mode in the reference order. Implemented: Counterparts,
/// Extensions, User Interfaces, Includes, Included By, Callers, Callees
/// (language server call hierarchy), Test Classes, Generated Interface and
/// Documentation Preview; the rest are listed disabled (no data). Manual
/// (Ycode's own) follows.
public enum AssistantModeCatalog {
    /// The pop-up's mode titles, in reference order.
    public static let titles = [
        "Counterparts",
        "Superclasses", "Subclasses", "Siblings", "Extensions", "Categories", "Protocols",
        "User Interfaces",
        "Includes", "Included By",
        "Callers", "Callees",
        "Test Classes", "Test Callers",
        "Preprocess", "Assembly",
        "Disassembly",
        "Generated Interface",
        "Documentation Preview",
        "Manual",
    ]

    /// Titles that map to the file-list modes of `AssistantMode`.
    public static func fileMode(_ title: String) -> AssistantMode? {
        switch title {
        case "Counterparts": .counterparts
        case "Manual": .manual
        case "Includes": .includes
        case "Test Classes": .tests
        default: nil
        }
    }

    /// The pop-up title of an `AssistantMode`.
    public static func title(of mode: AssistantMode) -> String {
        switch mode {
        case .counterparts: "Counterparts"
        case .manual: "Manual"
        case .includes: "Includes"
        case .tests: "Test Classes"
        case .topLevelObjects: "User Interfaces"
        }
    }

    static let cFamily: Set<String> = ["h", "hpp", "hh", "m", "mm", "c", "cpp", "cc", "cxx"]

    /// The modes that can have data for `path` (the others are disabled).
    public static func enabled(for path: String, hasLanguageService: Bool) -> Set<String> {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        var on: Set<String> = ["Counterparts", "Manual"]
        let ib = ["storyboard", "xib"].contains(ext)
        if ib || ext == "swift" || cFamily.contains(ext) { on.insert("User Interfaces") }
        if ext == "swift" { on.formUnion(["Extensions", "Generated Interface", "Documentation Preview"]) }
        if cFamily.contains(ext) { on.formUnion(["Includes", "Included By"]) }
        if ["swift", "m", "mm", "h", "c", "cpp"].contains(ext) {
            on.insert("Test Classes")
            if hasLanguageService { on.formUnion(["Callers", "Callees"]) }
        }
        return on
    }

    /// Files whose `#include`/`#import "…"` names `path`.
    public static func includedBy(_ path: String, in files: [String], readFile: (String) -> String?) -> [String] {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return files.filter { f in
            f != path && cFamily.contains(URL(fileURLWithPath: f).pathExtension.lowercased())
                && (readFile(f)?.split(separator: "\n").contains { l in
                    let t = l.trimmingCharacters(in: .whitespaces)
                    return (t.hasPrefix("#include") || t.hasPrefix("#import")) && (t.contains("\"\(name)\"") || t.contains("/\(name)\""))
                } ?? false)
        }.sorted()
    }

    /// Swift files with `extension <Type>` for the file's first declared type.
    public static func extensions(of path: String, in files: [String], readFile: (String) -> String?) -> [String] {
        guard let type = readFile(path).flatMap(AssistantMode.firstDeclaredType) else { return [] }
        return files.filter { f in
            f != path && f.hasSuffix(".swift") && (readFile(f)?.split(separator: "\n").contains { l in
                let words = l.split(whereSeparator: { " \t:{<".contains($0) })
                return words.contains("extension") && words.drop(while: { $0 != "extension" }).dropFirst().first.map(String.init) == type
            } ?? false)
        }.sorted()
    }

    /// For a source file: storyboards/xibs whose objects use its first type
    /// as `customClass`. For an IB document: the classes' files.
    public static func userInterfaces(of path: String, in files: [String], readFile: (String) -> String?) -> [String] {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "storyboard" || ext == "xib" { return AssistantMode.topLevelObjects.files(for: path, in: files, readFile: readFile) }
        guard let type = readFile(path).flatMap(AssistantMode.firstDeclaredType) else { return [] }
        return files.filter { f in
            ["storyboard", "xib"].contains(URL(fileURLWithPath: f).pathExtension.lowercased())
                && (readFile(f)?.contains("customClass=\"\(type)\"") ?? false)
        }.sorted()
    }

    /// A generated interface of Swift source: declarations with their doc
    /// comments, bodies and private members omitted (Ycode's own rendering).
    public static func generatedInterface(_ text: String) -> String {
        let modifiers: Set<String> = ["public", "internal", "open", "package", "static", "class", "final", "override", "mutating", "nonmutating",
                                      "nonisolated", "convenience", "required", "indirect", "lazy", "weak", "unowned", "dynamic", "async"]
        let keepers = ["func ", "var ", "let ", "init", "subscript", "case ", "typealias ", "associatedtype ", "struct ", "class ",
                       "enum ", "protocol ", "actor ", "extension ", "deinit", "macro ", "import ", "operator "]
        let containers = ["struct ", "class ", "enum ", "protocol ", "actor ", "extension "]
        var out: [String] = []
        var depth = 0
        var skipUntil: Int?
        var open: [Int] = []
        var doc: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let delta = t.filter { $0 == "{" }.count - t.filter { $0 == "}" }.count
            if let s = skipUntil {
                depth += delta
                if depth <= s { skipUntil = nil }
                continue
            }
            let indent = String(repeating: "    ", count: max(0, depth))
            if t.hasPrefix("///") { doc.append(indent + t); continue }
            if t.hasPrefix("}"), let last = open.last, last == depth - 1 {
                out.append(String(repeating: "    ", count: last) + "}")
                open.removeLast()
                depth += delta
                doc = []
                continue
            }
            let words = t.split(separator: " ").map(String.init)
            let isPrivate = words.prefix { !keepers.contains($0 + " ") }.contains { $0 == "private" || $0.hasPrefix("private(") || $0 == "fileprivate" }
            var i = 0
            while i < words.count {
                let w = words[i]
                if w.hasPrefix("@") || w.hasPrefix("private") || w == "fileprivate" { i += 1; continue }
                if w == "class" {
                    if i + 1 < words.count, ["func", "var", "let", "subscript", "override", "final"].contains(words[i + 1]) { i += 1; continue }
                    break
                }
                if modifiers.contains(w) { i += 1; continue }
                break
            }
            let decl = words[i...].joined(separator: " ")
            if !isPrivate, keepers.contains(where: { decl.hasPrefix($0) || decl == $0.trimmingCharacters(in: .whitespaces) }) {
                out += doc
                var head = t
                if let b = head.firstIndex(of: "{") { head = String(head[..<b]).trimmingCharacters(in: .whitespaces) }
                if decl.hasPrefix("var ") || decl.hasPrefix("let "), let eq = head.range(of: " = ") { head = String(head[..<eq.lowerBound]) }
                if containers.contains(where: { decl.hasPrefix($0) }) {
                    if delta > 0 { out.append(indent + head + " {"); open.append(depth) } else { out.append(indent + head + " {}") }
                } else {
                    out.append(indent + head)
                    if delta > 0 { skipUntil = depth }
                }
            } else if delta > 0 {
                skipUntil = depth
            }
            doc = []
            depth += delta
        }
        return out.joined(separator: "\n")
    }

    /// Documentation Preview: each documented declaration's Quick Help
    /// sections, as plain text.
    public static func documentationPreview(_ text: String) -> String {
        var blocks: [String] = []
        var doc: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("///") { doc.append(String(t.dropFirst(3).drop { $0 == " " })); continue }
            if !doc.isEmpty, !t.isEmpty {
                var decl = t
                if let b = decl.firstIndex(of: "{") { decl = String(decl[..<b]).trimmingCharacters(in: .whitespaces) }
                let d = QuickHelpDocument(hover: "```swift\n\(decl)\n```\n\n" + doc.joined(separator: "\n"))
                var lines = [d.title, String(repeating: "=", count: max(3, d.title.count))]
                if let s = d.summary { lines.append(s) }
                lines.append("")
                lines.append(d.declaration)
                if !d.parameters.isEmpty { lines.append("\nParameters"); lines += d.parameters.map { "  \($0.name): \($0.text)" } }
                if let r = d.returns { lines.append("\nReturn Value\n  \(r)") }
                if let r = d.throwsText { lines.append("\nThrows\n  \(r)") }
                if !d.discussion.isEmpty { lines.append("\nDiscussion"); lines += d.discussion.map { "  " + $0 } }
                for c in d.callouts { lines.append("\n[\(c.title)] \(c.text)") }
                blocks.append(lines.joined(separator: "\n"))
            }
            if !t.hasPrefix("@") { doc = [] }
        }
        return blocks.joined(separator: "\n\n")
    }
}
