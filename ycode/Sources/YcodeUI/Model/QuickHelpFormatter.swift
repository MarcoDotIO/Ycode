import Foundation

/// Turns hover Markdown into readable plain text for Quick Help: code
/// fences are dropped (their contents kept), `---` rules become blank
/// lines, and inline backticks are removed.
public enum QuickHelpFormatter {
    public static func plain(_ markdown: String) -> String {
        var out: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { continue }
            if t == "---" || t == "***" { out.append(""); continue }
            out.append(line.replacingOccurrences(of: "`", with: ""))
        }
        // Collapse runs of blank lines.
        var result: [String] = []
        for l in out where !(l.isEmpty && (result.last?.isEmpty ?? true)) { result.append(l) }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }
}
