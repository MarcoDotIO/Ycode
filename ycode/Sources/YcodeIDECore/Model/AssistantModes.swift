import Foundation

/// What the assistant editor shows. See `specs/ide/editor-area.md`
/// §Assistant modes.
public enum AssistantMode: String, CaseIterable, Sendable {
    case counterparts = "Counterparts"
    /// The assistant keeps what the user opened in it.
    case manual = "Manual"
    /// Interface Builder documents: class files of top-level custom objects.
    case topLevelObjects = "Top Level Objects"
    /// C-family files: the workspace files named by `#include` / `#import "…"`.
    case includes = "Includes"
    /// Test files that mention the file's first declared type.
    case tests = "Tests"

    /// Modes offered for a file (Counterparts and Manual always).
    public static func available(for path: String) -> [AssistantMode] {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        var out: [AssistantMode] = [.counterparts, .manual]
        if ["storyboard", "xib"].contains(ext) { out.append(.topLevelObjects) }
        if ["h", "hpp", "hh", "m", "mm", "c", "cpp", "cc", "cxx"].contains(ext) { out.append(.includes) }
        if ["swift", "m", "mm", "h", "c", "cpp"].contains(ext) { out.append(.tests) }
        return out
    }

    /// The files the mode lists for `path` (empty for Manual).
    public func files(for path: String, in files: [String], readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [String] {
        switch self {
        case .counterparts: return Counterparts.of(path, in: files, readFile: readFile)
        case .manual: return []
        case .topLevelObjects:
            guard let text = readFile(path) else { return [] }
            var out: [String] = []
            for cls in Self.topLevelClasses(in: text) {
                for f in files where ["swift", "h", "m"].contains(URL(fileURLWithPath: f).pathExtension)
                    && URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent == cls && !out.contains(f) { out.append(f) }
            }
            return out
        case .includes:
            guard let text = readFile(path) else { return [] }
            var out: [String] = []
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("#include") || t.hasPrefix("#import"), let q = t.firstIndex(of: "\""),
                      let e = t[t.index(after: q)...].firstIndex(of: "\"") else { continue }
                let name = URL(fileURLWithPath: String(t[t.index(after: q)..<e])).lastPathComponent
                for f in files where URL(fileURLWithPath: f).lastPathComponent == name && f != path && !out.contains(f) { out.append(f) }
            }
            return out
        case .tests:
            let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let type = readFile(path).flatMap(Self.firstDeclaredType) ?? base
            return files.filter { f in
                let n = URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent
                guard f != path, n.hasSuffix("Tests") || n.hasSuffix("Test") else { return false }
                return n == base + "Tests" || (readFile(f)?.contains(type) ?? false)
            }.sorted()
        }
    }

    /// Custom classes of objects directly inside an `objects` element.
    static func topLevelClasses(in text: String) -> [String] {
        guard let root = try? XMLSource.parse(Array(text.utf8)) else { return [] }
        var out: [String] = []
        root.walk { n in
            guard n.name == "objects" else { return }
            for c in n.children { if let cls = c["customClass"], !out.contains(cls) { out.append(cls) } }
        }
        return out
    }

    /// The first `class` / `struct` / `enum` / `actor` / `@interface` name.
    static func firstDeclaredType(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: { " \t:{(<".contains($0) }).map(String.init)
            for (i, w) in words.enumerated() where ["class", "struct", "enum", "actor", "@interface", "@implementation"].contains(w) && i + 1 < words.count {
                return words[i + 1]
            }
        }
        return nil
    }
}
