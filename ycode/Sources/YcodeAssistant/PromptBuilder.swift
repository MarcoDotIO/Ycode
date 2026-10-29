import Foundation

/// What the workspace offers as context for a request.
public struct WorkspaceContext: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        /// Workspace-relative path.
        public var path: String
        public var text: String
        public init(path: String, text: String) {
            self.path = path
            self.text = text
        }
    }
    public struct Selection: Sendable, Equatable {
        public var path: String
        /// 1-based, inclusive.
        public var startLine: Int
        public var endLine: Int
        public var text: String
        /// UTF-16 offset and length in the file (where a proposal applies).
        public var location: Int
        public var length: Int
        public init(path: String, startLine: Int, endLine: Int, text: String, location: Int, length: Int) {
            self.path = path
            self.startLine = startLine
            self.endLine = endLine
            self.text = text
            self.location = location
            self.length = length
        }
    }
    public struct Issue: Sendable, Equatable {
        public var severity: String
        public var message: String
        public var path: String?
        public var line: Int?
        public init(severity: String, message: String, path: String? = nil, line: Int? = nil) {
            self.severity = severity
            self.message = message
            self.path = path
            self.line = line
        }
    }

    public var workspaceName: String
    public var currentFile: File?
    /// 1-based caret line in the current file.
    public var caretLine: Int?
    public var selection: Selection?
    public var openFiles: [File]
    public var issues: [Issue]

    public init(workspaceName: String = "", currentFile: File? = nil, caretLine: Int? = nil, selection: Selection? = nil,
                openFiles: [File] = [], issues: [Issue] = []) {
        self.workspaceName = workspaceName
        self.currentFile = currentFile
        self.caretLine = caretLine
        self.selection = selection
        self.openFiles = openFiles
        self.issues = issues
    }

    /// Where file-less proposals from a request made here apply.
    public var proposalTarget: ProposalTarget? {
        if let s = selection, !s.text.isEmpty {
            return ProposalTarget(path: s.path, selectionLocation: s.location, selectionLength: s.length, selectionText: s.text)
        }
        return currentFile.map { ProposalTarget(path: $0.path) }
    }
}

/// Which context goes with a request (Settings ▸ Coding Assistant).
public struct ContextOptions: Sendable, Equatable, Codable {
    /// The current file (or a window of it around the caret).
    public var includeCurrentFile = true
    public var includeOpenFiles = true
    public var includeIssues = true
    public init() {}
}

/// Rough token counts: about four UTF-8 bytes per token for code and
/// English, rounded up. Good enough to keep a prompt under a limit with a
/// margin; providers count exactly.
public enum TokenEstimator {
    public static func estimate(_ s: String) -> Int { (s.utf8.count + 3) / 4 }
}

/// The prompt for one request, within a token budget.
public struct BuiltPrompt: Sendable, Equatable {
    public var instructions: String
    public var messages: [ChatMessage]
    public var estimatedTokens: Int
    /// What went in ("Selection App.swift:3–9", "File App.swift", …) and
    /// what did not fit; shown in the transcript's details.
    public var included: [String]
    public var omitted: [String]
}

public enum PromptBuilder {
    /// Ycode's instructions: the role and the change format that
    /// `ChangeProposal` reads.
    public static let instructions = """
    You are the coding assistant in Ycode, an IDE for Apple platforms. Answer questions about the user's code and \
    propose changes. Be concise; use Markdown.

    You cannot edit files. When you propose a change, put it in a fenced code block whose info string names the \
    language and the file, and give the file's complete new contents, for example:
    ```swift file=Sources/App/Model.swift
    <the whole file>
    ```
    Use the workspace-relative path shown in the context. To replace only the code the user selected, use the info \
    string `<language> selection` and give just the replacement for the selection. To add code at the end of the \
    current file, use `<language> append` and give only the new code. Code blocks without these markers are shown \
    as examples and are not applied. The user reviews every proposed change before it is applied.
    """

    /// Builds the request. Always included: the instructions and the new
    /// message. Then, while the budget lasts and in this order: the
    /// attachments, the selection, the current file (whole, or a window
    /// around the caret or selection), earlier turns (newest first), the
    /// issues, the other open files.
    ///
    /// - Parameters:
    ///   - contextTokens: the model's context window (or the configured
    ///     limit, whichever is smaller).
    ///   - reservedOutput: tokens left free for the answer.
    public static func build(history: [ChatMessage], prompt: String, attachments: [Attachment], context: WorkspaceContext,
                             options: ContextOptions = .init(), contextTokens: Int, reservedOutput: Int? = nil,
                             instructions: String = Self.instructions) -> BuiltPrompt {
        let reserve = reservedOutput ?? min(4096, max(256, contextTokens / 4))
        var budget = contextTokens - reserve - TokenEstimator.estimate(instructions) - 16
        var included: [String] = []
        var omitted: [String] = []

        var request = prompt
        let promptCost = TokenEstimator.estimate(prompt) + 8
        if promptCost > budget {
            // The message alone is too long: keep its start.
            let keep = max(0, budget - 16) * 4
            request = String(prompt.prefix(keep))
            request += "\n[…message shortened to fit the model's context…]"
            omitted.append("End of the message")
        }
        budget -= TokenEstimator.estimate(request) + 8

        var sections: [String] = []
        func take(_ label: String, _ text: String) -> Bool {
            let cost = TokenEstimator.estimate(text) + 4
            guard cost <= budget else { omitted.append(label); return false }
            budget -= cost
            sections.append(text)
            included.append(label)
            return true
        }
        func fence(_ path: String, _ text: String, _ info: String = "") -> String {
            let lang = language(for: path)
            let ticks = text.contains("```") ? "````" : "```"
            return "\(ticks)\(lang)\(info)\n\(text)\(text.hasSuffix("\n") ? "" : "\n")\(ticks)"
        }

        if !context.workspaceName.isEmpty { _ = take("Workspace", "Workspace: \(context.workspaceName)") }
        var sent = Set<String>()
        for a in attachments {
            switch a.kind {
            case .file:
                if take("File \(a.label)", "Attached file \(a.path):\n" + fence(a.path, a.text)) { sent.insert(a.path) }
            case .selection:
                _ = take("Selection \(a.label)", "Attached selection, lines \(a.startLine ?? 0)–\(a.endLine ?? 0) of \(a.path):\n" + fence(a.path, a.text))
            }
        }
        if let s = context.selection, !s.text.isEmpty, !attachments.contains(where: { $0.kind == .selection && $0.path == s.path && $0.text == s.text }) {
            _ = take("Selection \((s.path as NSString).lastPathComponent):\(s.startLine)–\(s.endLine)",
                     "Selected code, lines \(s.startLine)–\(s.endLine) of \(s.path):\n" + fence(s.path, s.text))
        }
        if options.includeCurrentFile, let f = context.currentFile, !sent.contains(f.path) {
            let name = (f.path as NSString).lastPathComponent
            let whole = "Current file \(f.path):\n" + fence(f.path, f.text)
            if TokenEstimator.estimate(whole) + 4 <= budget {
                _ = take("File \(name)", whole)
                sent.insert(f.path)
            } else if let w = window(f.text, around: context.selection.map { ($0.startLine, $0.endLine) } ?? context.caretLine.map { ($0, $0) },
                                     tokens: max(0, budget * 2 / 3)) {
                _ = take("Part of \(name) (lines \(w.first)–\(w.last))",
                         "Part of the current file \(f.path), lines \(w.first)–\(w.last) (the file is longer):\n" + fence(f.path, w.text))
            } else {
                omitted.append("File \(name)")
            }
        }

        // Earlier turns, newest first, while they fit.
        var keptHistory: [ChatMessage] = []
        var dropped = 0
        for m in history.reversed() {
            let cost = TokenEstimator.estimate(m.content) + 8
            if cost <= budget && dropped == 0 {
                budget -= cost
                keptHistory.insert(m, at: 0)
            } else {
                dropped += 1
            }
        }
        if dropped > 0 { omitted.append("\(dropped) earlier message\(dropped == 1 ? "" : "s")") }
        if !keptHistory.isEmpty { included.append("\(keptHistory.count) earlier message\(keptHistory.count == 1 ? "" : "s")") }

        if options.includeIssues, !context.issues.isEmpty {
            let ordered = context.issues.sorted { ($0.severity == "error" ? 0 : 1) < ($1.severity == "error" ? 0 : 1) }.prefix(50)
            let lines = ordered.map { i -> String in
                let loc = i.path.map { p in i.line.map { "\(p):\($0)" } ?? p }
                return "- \(i.severity)\(loc.map { " \($0)" } ?? ""): \(i.message)"
            }
            _ = take("\(ordered.count) issue\(ordered.count == 1 ? "" : "s")", "Current issues:\n" + lines.joined(separator: "\n"))
        }
        if options.includeOpenFiles {
            for f in context.openFiles where !sent.contains(f.path) {
                if take("Open file \((f.path as NSString).lastPathComponent)", "Open file \(f.path):\n" + fence(f.path, f.text)) { sent.insert(f.path) }
            }
        }

        let content = sections.isEmpty ? request : "<context>\n" + sections.joined(separator: "\n\n") + "\n</context>\n\n" + request
        let messages = keptHistory + [ChatMessage(.user, content)]
        let total = TokenEstimator.estimate(instructions) + messages.reduce(0) { $0 + TokenEstimator.estimate($1.content) + 8 }
        return BuiltPrompt(instructions: instructions, messages: messages, estimatedTokens: total, included: included, omitted: omitted)
    }

    /// Lines around `center` (1-based, inclusive range) that fit `tokens`.
    static func window(_ text: String, around center: (Int, Int)?, tokens: Int) -> (first: Int, last: Int, text: String)? {
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty, tokens > 16 else { return nil }
        let (s, e) = center ?? (1, 1)
        var first = max(1, min(s, lines.count)), last = max(first, min(e, lines.count))
        var cost = lines[(first - 1)...(last - 1)].reduce(0) { $0 + TokenEstimator.estimate($1) + 1 }
        guard cost <= tokens else { return nil }
        var grew = true
        while grew {
            grew = false
            if first > 1 {
                let c = TokenEstimator.estimate(lines[first - 2]) + 1
                if cost + c <= tokens { first -= 1; cost += c; grew = true }
            }
            if last < lines.count {
                let c = TokenEstimator.estimate(lines[last]) + 1
                if cost + c <= tokens { last += 1; cost += c; grew = true }
            }
        }
        return (first, last, lines[(first - 1)...(last - 1)].joined(separator: "\n"))
    }

    /// A fence language for a file name.
    public static func language(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "m", "h": "objc"
        case "mm": "objective-cpp"
        case "c": "c"
        case "cpp", "cc", "hpp": "cpp"
        case "metal": "metal"
        case "json": "json"
        case "plist", "xml", "storyboard", "xib": "xml"
        case "md": "markdown"
        case "sh": "sh"
        case "py": "python"
        case "js": "javascript"
        case "yml", "yaml": "yaml"
        default: ""
        }
    }
}

/// Editor ▸ Show Coding Tools (reference-ui-5.md §2.7 item 8), behavior
/// after Apple's public "Using coding intelligence in the source editor".
public enum CodingTool: String, CaseIterable, Sendable {
    case explain, document, generatePlayground, generatePreview

    public var title: String {
        switch self {
        case .explain: "Explain"
        case .document: "Document"
        case .generatePlayground: "Generate a Playground"
        case .generatePreview: "Generate a Preview"
        }
    }

    /// The message sent; the selection (or the file) goes with it as
    /// context.
    public func prompt(path: String, hasSelection: Bool) -> String {
        let what = hasSelection ? "the selected code" : "the current file (\((path as NSString).lastPathComponent))"
        let lang = PromptBuilder.language(for: path)
        switch self {
        case .explain:
            return "Explain \(what): what it does, how it works, and anything surprising. Do not propose changes."
        case .document:
            return hasSelection
                ? "Add Swift-DocC style documentation comments (///) to the selected code: the type or function, its properties and methods, parameters, return values and thrown errors. Return the selected code with the comments added, unchanged otherwise, in one ```\(lang) selection``` block."
                : "Add Swift-DocC style documentation comments (///) to the declarations in \(what) that lack them. Return the complete updated file in one ```\(lang) file=\(path)``` block, unchanged otherwise."
        case .generatePlayground:
            return "Write a #Playground block (from `import Playgrounds`) that exercises \(what) with sample data, to run in the canvas. Return only the new code, including any import it needs, in one ```\(lang) append``` block."
        case .generatePreview:
            return "Write a SwiftUI #Preview for the view in \(what), with sample data if it needs any. Return only the new code in one ```\(lang) append``` block."
        }
    }

    /// The command applies to this file (Generate a Preview needs a Swift
    /// file that uses SwiftUI).
    public func applies(toPath path: String, text: String) -> Bool {
        let swift = (path as NSString).pathExtension.lowercased() == "swift"
        switch self {
        case .explain: return true
        case .document, .generatePlayground: return swift
        case .generatePreview: return swift && text.contains("SwiftUI")
        }
    }
}
