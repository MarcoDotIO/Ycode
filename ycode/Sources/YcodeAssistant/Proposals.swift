import Foundation

/// A response split into prose and fenced code blocks (CommonMark fences
/// of three or more backticks or tildes). An unterminated fence, as while a
/// response streams, is a code block to the end.
public enum MarkdownBlocks {
    public enum Block: Sendable, Equatable {
        case prose(String)
        /// `info` is the fence's info string ("swift file=Sources/A.swift").
        case code(info: String, text: String, closed: Bool)
    }

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var fence: (char: Character, count: Int, info: String)?
        func flushProse() {
            let p = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !p.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.prose(p)) }
            prose = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.drop { $0 == " " }
            let indent = line.count - trimmed.count
            if let f = fence {
                let run = trimmed.prefix { $0 == f.char }.count
                if indent < 4, run >= f.count, trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    blocks.append(.code(info: f.info, text: code.joined(separator: "\n"), closed: true))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if indent < 4, let c = trimmed.first, c == "`" || c == "~" {
                let run = trimmed.prefix { $0 == c }.count
                let info = trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces)
                if run >= 3, !(c == "`" && info.contains("`")) {
                    flushProse()
                    fence = (c, run, info)
                    continue
                }
            }
            prose.append(line)
        }
        if let f = fence { blocks.append(.code(info: f.info, text: code.joined(separator: "\n"), closed: false)) }
        flushProse()
        return blocks
    }
}

/// A change the assistant proposes. Ycode's response format (the
/// instructions in `PromptBuilder`): a fenced block whose info string
/// carries `file=<path>` holds a file's complete new contents; `selection`
/// replaces the selection the request was made from; `append` adds to the
/// end of the request's file. Nothing is written until the user accepts it
/// in the review sheet.
public struct ChangeProposal: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case wholeFile
        case replaceSelection
        case append
    }
    public var kind: Kind
    /// Workspace-relative path.
    public var path: String
    public var language: String?
    public var text: String
    /// The block's position among the response's code blocks.
    public var blockIndex: Int

    public init(kind: Kind, path: String, language: String?, text: String, blockIndex: Int) {
        self.kind = kind
        self.path = path
        self.language = language
        self.text = text
        self.blockIndex = blockIndex
    }

    /// The proposals in a response (complete blocks only).
    public static func parse(_ response: String, target: ProposalTarget?) -> [ChangeProposal] {
        var out: [ChangeProposal] = []
        var index = 0
        for block in MarkdownBlocks.parse(response) {
            guard case .code(let info, let text, let closed) = block else { continue }
            defer { index += 1 }
            guard closed, let p = proposal(info: info, text: text, target: target, index: index) else { continue }
            out.append(p)
        }
        return out
    }

    /// The proposal a code block's info string describes, if any.
    public static func proposal(info: String, text: String, target: ProposalTarget?, index: Int) -> ChangeProposal? {
        let tokens = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var language: String?
        var path: String?
        var kind: Kind?
        for (i, t) in tokens.enumerated() {
            if let eq = t.firstIndex(of: "=") {
                let key = t[..<eq].lowercased(), value = String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if key == "file" || key == "path" { path = value; kind = kind ?? .wholeFile }
            } else if t == "selection" || t == "replace-selection" {
                kind = .replaceSelection
            } else if t == "append" {
                kind = .append
            } else if i == 0 {
                language = t
            }
        }
        guard let k = kind else { return nil }
        switch k {
        case .wholeFile:
            guard let path, !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
            return ChangeProposal(kind: .wholeFile, path: path, language: language, text: text, blockIndex: index)
        case .replaceSelection:
            guard let target, target.selectionText != nil else { return nil }
            return ChangeProposal(kind: .replaceSelection, path: path ?? target.path, language: language, text: text, blockIndex: index)
        case .append:
            guard let p = path ?? target?.path else { return nil }
            return ChangeProposal(kind: .append, path: p, language: language, text: text, blockIndex: index)
        }
    }

    public enum ApplyError: Error, Equatable, LocalizedError {
        case selectionChanged
        public var errorDescription: String? { "The selected code changed since the request; the proposal no longer applies." }
    }

    /// The file's new text when the proposal is applied to `original` (nil
    /// for a file that does not exist yet).
    public func apply(to original: String?, target: ProposalTarget?) throws -> String {
        func withNewline(_ s: String) -> String { s.hasSuffix("\n") ? s : s + "\n" }
        switch kind {
        case .wholeFile:
            return withNewline(text)
        case .append:
            let base = original ?? ""
            return (base.isEmpty || base.hasSuffix("\n\n") ? base : withNewline(base) + "\n") + withNewline(text)
        case .replaceSelection:
            guard let original, let target, let sel = target.selectionText else { throw ApplyError.selectionChanged }
            let ns = original as NSString
            var range: NSRange?
            if let loc = target.selectionLocation, let len = target.selectionLength, loc + len <= ns.length,
               ns.substring(with: NSRange(location: loc, length: len)) == sel {
                range = NSRange(location: loc, length: len)
            } else {
                // Moved: accept a single exact occurrence.
                let first = ns.range(of: sel)
                if first.location != NSNotFound,
                   ns.range(of: sel, range: NSRange(location: first.location + 1, length: ns.length - first.location - 1)).location == NSNotFound {
                    range = first
                }
            }
            guard let r = range, !sel.isEmpty else { throw ApplyError.selectionChanged }
            var replacement = text
            // Keep the selection's trailing newline if it had one.
            if sel.hasSuffix("\n") && !replacement.hasSuffix("\n") { replacement += "\n" }
            return ns.replacingCharacters(in: r, with: replacement)
        }
    }
}
