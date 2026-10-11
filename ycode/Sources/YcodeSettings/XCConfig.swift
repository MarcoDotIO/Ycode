import Foundation

/// Reads `.xcconfig` files into an ordered list of assignments, expanding
/// `#include` directives in place. See `specs/build-settings.md` §1.
public struct XCConfig: Sendable {
    public var url: URL
    public var assignments: [SettingAssignment]
    public var diagnostics: [String]

    /// - Parameter developerDirectory: replaces a `<DEVELOPER_DIR>` prefix in include paths.
    public init(contentsOf url: URL, developerDirectory: String? = nil,
                read: @escaping (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }) throws {
        self.url = url
        var state = State(developerDirectory: developerDirectory, read: read)
        try state.load(url, optional: false, isRoot: true)
        assignments = state.assignments
        diagnostics = state.diagnostics
    }

    /// Parses text that is not backed by a file (includes resolve against `baseURL`).
    public init(text: String, baseURL: URL, developerDirectory: String? = nil,
                read: @escaping (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }) {
        url = baseURL
        var state = State(developerDirectory: developerDirectory, read: read)
        state.stack.append(baseURL.standardizedFileURL)
        state.parse(text, url: baseURL)
        assignments = state.assignments
        diagnostics = state.diagnostics
    }

    private struct State {
        let developerDirectory: String?
        let read: (URL) throws -> String
        var assignments: [SettingAssignment] = []
        var diagnostics: [String] = []
        var stack: [URL] = []

        init(developerDirectory: String?, read: @escaping (URL) throws -> String) {
            self.developerDirectory = developerDirectory
            self.read = read
        }

        mutating func load(_ url: URL, optional: Bool, isRoot: Bool = false) throws {
            let std = url.standardizedFileURL
            if stack.contains(std) {
                diagnostics.append("\(url.path): recursive #include ignored")
                return
            }
            let text: String
            do { text = try read(std) } catch {
                if optional { return }
                if isRoot { throw error }
                diagnostics.append("\(stack.last?.path ?? "?"): could not find included file '\(url.path)'")
                return
            }
            stack.append(std)
            defer { stack.removeLast() }
            parse(text, url: std)
        }

        mutating func parse(_ text: String, url: URL) {
            for (n, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                var line = Substring(rawLine)
                if line.hasSuffix("\r") { line = line.dropLast() }
                let origin = "\(url.lastPathComponent):\(n + 1)"
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#include") {
                    include(trimmed, from: url, origin: origin)
                    continue
                }
                // `//` starts a comment anywhere, including inside values.
                if let c = line.range(of: "//") { line = line[..<c.lowerBound] }
                var body = line.trimmingCharacters(in: .whitespaces)
                if body.isEmpty { continue }
                if body.hasSuffix(";") { body.removeLast() }
                guard let eq = Self.assignmentEquals(in: body) else {
                    diagnostics.append("\(origin): expected 'NAME = value'")
                    continue
                }
                let key = body[..<eq].trimmingCharacters(in: .whitespaces)
                let value = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                guard let (name, conds) = SettingAssignment.splitKey(key), Self.isValidName(name) else {
                    diagnostics.append("\(origin): invalid setting name '\(key)'")
                    continue
                }
                assignments.append(SettingAssignment(name: name, conditions: conds, value: value, origin: origin))
            }
        }

        mutating func include(_ line: String, from url: URL, origin: String) {
            let optional = line.hasPrefix("#include?")
            guard let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") else {
                diagnostics.append("\(origin): malformed #include")
                return
            }
            var path = String(line[line.index(after: q1)..<q2])
            if path.hasPrefix("<DEVELOPER_DIR>") {
                guard let dev = developerDirectory else {
                    if !optional { diagnostics.append("\(origin): <DEVELOPER_DIR> is not known") }
                    return
                }
                path = dev + path.dropFirst("<DEVELOPER_DIR>".count)
            }
            let target = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : url.deletingLastPathComponent().appendingPathComponent(path)
            try? load(target, optional: optional)
        }

        /// The `=` that separates name from value: the first one outside
        /// `[...]` condition brackets.
        static func assignmentEquals(in s: String) -> String.Index? {
            var depth = 0
            for i in s.indices {
                switch s[i] {
                case "[": depth += 1
                case "]": depth = max(0, depth - 1)
                case "=" where depth == 0: return i
                default: break
                }
            }
            return nil
        }

        static func isValidName(_ s: String) -> Bool {
            guard let f = s.unicodeScalars.first, f == "_" || (f.properties.isAlphabetic && f.isASCII) else { return false }
            return s.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || $0.properties.isAlphabetic || ("0"..."9").contains($0)) }
        }
    }
}
