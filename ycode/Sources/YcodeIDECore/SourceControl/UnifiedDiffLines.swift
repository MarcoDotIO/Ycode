import Foundation

/// Lines of a unified diff with their old and new line numbers.
public enum UnifiedDiffLines {
    public enum Kind: Equatable, Sendable { case context, added, removed, hunk }
    public struct Line: Equatable, Sendable {
        public var kind: Kind
        public var old: Int?
        public var new: Int?
        public var text: String
    }

    public static func parse(_ text: String) -> [Line] {
        var out: [Line] = []
        var old = 0, new = 0
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                let parts = raw.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                    if old == 0 { old = 1 }
                    if new == 0 { new = 1 }
                }
                out.append(Line(kind: .hunk, old: nil, new: nil, text: raw))
            } else if raw.hasPrefix("+") {
                out.append(Line(kind: .added, old: nil, new: new, text: String(raw.dropFirst())))
                new += 1
            } else if raw.hasPrefix("-") {
                out.append(Line(kind: .removed, old: old, new: nil, text: String(raw.dropFirst())))
                old += 1
            } else if raw.hasPrefix(" ") {
                out.append(Line(kind: .context, old: old, new: new, text: String(raw.dropFirst())))
                old += 1
                new += 1
            }
        }
        return out
    }
}
