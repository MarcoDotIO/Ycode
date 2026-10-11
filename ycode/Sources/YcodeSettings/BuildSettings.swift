import Foundation

/// One `NAME[cond=pattern]... = value` assignment.
public struct SettingAssignment: Equatable, Sendable {
    public var name: String
    public var conditions: [(parameter: String, pattern: String)]
    public var value: MacroExpression
    /// Where it came from, for diagnostics (`file:line` or a level name).
    public var origin: String

    public init(name: String, conditions: [(String, String)] = [], value: String, origin: String = "") {
        self.name = name
        self.conditions = conditions.map { (parameter: $0.0, pattern: $0.1) }
        self.value = MacroExpression(value)
        self.origin = origin
    }

    /// Parses a pbxproj/xcconfig key such as `OTHER_LDFLAGS[sdk=iphoneos*][arch=arm64]`.
    /// Bracket groups may also hold comma-separated conditions.
    public static func splitKey(_ key: String) -> (name: String, conditions: [(String, String)])? {
        guard let open = key.firstIndex(of: "[") else { return (key, []) }
        let name = String(key[..<open])
        var conds: [(String, String)] = []
        var rest = key[open...]
        while rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            for part in rest[rest.index(after: rest.startIndex)..<close].split(separator: ",") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { return nil }
                conds.append((kv[0], kv[1]))
            }
            rest = rest[rest.index(after: close)...]
        }
        return rest.isEmpty ? (name, conds) : nil
    }

    public static func == (a: SettingAssignment, b: SettingAssignment) -> Bool {
        a.name == b.name && a.value == b.value && a.origin == b.origin
            && a.conditions.map { "\($0.parameter)=\($0.pattern)" } == b.conditions.map { "\($0.parameter)=\($0.pattern)" }
    }
}

/// A level in the settings stack (defaults, project xcconfig, project, …).
/// Within a level, later assignments take precedence.
public struct SettingsLevel: Sendable {
    public var name: String
    public var assignments: [SettingAssignment]

    public init(name: String, assignments: [SettingAssignment] = []) {
        self.name = name
        self.assignments = assignments
    }

    /// A level from a pbxproj `buildSettings` dictionary. Unconditional
    /// assignments come first so that matching conditional ones win.
    public init(name: String, buildSettings: [(key: String, value: String)]) {
        self.name = name
        var plain: [SettingAssignment] = []
        var conditional: [SettingAssignment] = []
        for (key, value) in buildSettings.sorted(by: { $0.key < $1.key }) {
            guard let (n, c) = SettingAssignment.splitKey(key) else { continue }
            let a = SettingAssignment(name: n, conditions: c, value: value, origin: name)
            if c.isEmpty { plain.append(a) } else { conditional.append(a) }
        }
        assignments = plain + conditional
    }

    /// A level of literal values (no macro parsing of `$`).
    public init(name: String, literals: [String: String]) {
        self.name = name
        assignments = literals.keys.sorted().map {
            var a = SettingAssignment(name: $0, value: "", origin: name)
            a.value = MacroExpression(segments: [.literal(literals[$0]!)])
            return a
        }
    }
}

/// Values for condition parameters (`config`, `sdk`, `arch`, `variant`, …).
public typealias ConditionContext = [String: String]

/// Resolves settings over a stack of levels, lowest first.
/// See `specs/build-settings.md` §3.
public final class BuildSettings {
    public let levels: [SettingsLevel]
    public let context: ConditionContext
    /// Assignment chain per name, highest precedence first.
    private var chains: [String: [SettingAssignment]] = [:]
    private var cache: [String: String] = [:]
    private var inProgress: Set<String> = []
    public private(set) var diagnostics: [String] = []

    public init(levels: [SettingsLevel], context: ConditionContext) {
        self.levels = levels
        self.context = context
        for level in levels {
            for a in level.assignments where Self.matches(a, context) {
                chains[a.name, default: []].insert(a, at: 0)
            }
        }
    }

    /// Every setting name that has at least one applicable assignment.
    public var names: [String] { chains.keys.sorted() }

    /// True if any applicable assignment to `name` is in one of `levelNames`.
    public func isAssigned(_ name: String, inLevels levelNames: Set<String>) -> Bool {
        levels.contains { levelNames.contains($0.name) && $0.assignments.contains { $0.name == name && Self.matches($0, context) } }
    }

    /// The fully evaluated value of `name` ("" if unset).
    public func value(_ name: String) -> String {
        if let v = cache[name] { return v }
        let v = evaluate(name, depth: 0)
        cache[name] = v
        return v
    }

    public subscript(name: String) -> String { value(name) }

    /// All settings, evaluated.
    public func all() -> [String: String] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, value($0)) })
    }

    // MARK: - Evaluation

    /// Evaluates the assignment at `depth` in `name`'s chain. `depth` is the
    /// position below the top that `$(inherited)` has reached.
    private func evaluate(_ name: String, depth: Int) -> String {
        guard let chain = chains[name], depth < chain.count else { return "" }
        let key = "\(name)#\(depth)"
        if inProgress.contains(key) {
            diagnostics.append("cycle while evaluating \(name)")
            return ""
        }
        inProgress.insert(key)
        defer { inProgress.remove(key) }
        return expand(chain[depth].value, owner: name, depth: depth)
    }

    private func expand(_ expr: MacroExpression, owner: String, depth: Int) -> String {
        var out = ""
        for seg in expr.segments {
            switch seg {
            case .literal(let s):
                out += s
            case .reference(let nameExpr, let ops):
                let refName = expand(nameExpr, owner: owner, depth: depth)
                var v: String
                if refName == "inherited" || refName == owner {
                    v = evaluate(owner, depth: depth + 1)
                } else {
                    v = value(refName)
                }
                for op in ops {
                    let arg = op.argument.map { expand($0, owner: owner, depth: depth) }
                    v = MacroOperators.apply(op.name, argument: arg, to: v)
                }
                out += v
            }
        }
        return out
    }

    static func matches(_ a: SettingAssignment, _ context: ConditionContext) -> Bool {
        a.conditions.allSatisfy { cond in
            guard let actual = context[cond.parameter] else { return cond.pattern == "*" }
            return glob(cond.pattern, actual)
        }
    }

    /// `*` matches any run of characters; everything else is literal.
    static func glob(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern), t = Array(s)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] != "*", p[pi] == t[ti] { pi += 1; ti += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
