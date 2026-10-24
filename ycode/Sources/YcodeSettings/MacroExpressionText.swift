import Foundation

extension MacroExpression {
    /// The expression written back as setting text (`$(NAME:op=arg)` for
    /// references), for display in the Levels view.
    public var text: String {
        segments.map { seg -> String in
            switch seg {
            case .literal(let s): return s
            case .reference(let name, let ops):
                let o = ops.map { op in ":" + op.name + (op.argument.map { "=" + $0.text } ?? "") }.joined()
                return "$(" + name.text + o + ")"
            }
        }.joined()
    }
}

extension BuildSettings {
    /// The raw text assigned to `name` in the level called `levelName`
    /// (the last applicable assignment there), or nil.
    public func assignedText(_ name: String, inLevel levelName: String) -> String? {
        guard let level = levels.first(where: { $0.name == levelName }) else { return nil }
        return level.assignments.last { $0.name == name && $0.conditions.isEmpty }?.value.text
            ?? level.assignments.last { $0.name == name }?.value.text
    }
}
