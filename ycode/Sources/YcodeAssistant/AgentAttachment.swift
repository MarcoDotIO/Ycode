import Foundation

/// What the IDE gives an agent back end for one request in agent mode
/// (specs/ide/coding-assistant.md, "Ycode implementation"): Ycode's MCP
/// server for the agent to call, and hooks that turn the agent's file
/// writes and permission requests into the IDE's proposals and questions.
public struct AgentAttachment: Sendable {
    /// A Streamable HTTP MCP endpoint on 127.0.0.1 and its bearer token.
    public struct MCPEndpoint: Sendable, Equatable {
        public var name: String
        public var url: String
        public var token: String
        public init(name: String = "ycode", url: String, token: String) {
            self.name = name
            self.url = url
            self.token = token
        }
    }

    /// One choice of a permission request (ACP `PermissionOption`).
    public struct PermissionOption: Sendable, Equatable {
        public var id: String
        public var name: String
        /// `allow_once`, `allow_always`, `reject_once`, `reject_always`.
        public var kind: String
        public init(id: String, name: String, kind: String) {
            self.id = id
            self.name = name
            self.kind = kind
        }
        public var allows: Bool { kind.hasPrefix("allow") }
    }

    public var mcp: MCPEndpoint?
    /// Shows a change as a proposal; true once the user accepted it (and it
    /// is on disk). `path` is absolute; `original` nil for a new file.
    public var proposeChange: @Sendable (_ path: String, _ original: String?, _ proposed: String, _ summary: String) async -> Bool
    /// Asks the user; the chosen option's id, or nil (cancelled).
    public var requestPermission: @Sendable (_ title: String, _ options: [PermissionOption]) async -> String?
    /// A file's text as the user sees it (an open editor's unsaved edits).
    public var readFile: @Sendable (_ path: String) async -> String?

    public init(mcp: MCPEndpoint? = nil,
                proposeChange: @escaping @Sendable (String, String?, String, String) async -> Bool = { _, _, _, _ in false },
                requestPermission: @escaping @Sendable (String, [PermissionOption]) async -> String? = { _, _ in nil },
                readFile: @escaping @Sendable (String) async -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) {
        self.mcp = mcp
        self.proposeChange = proposeChange
        self.requestPermission = requestPermission
        self.readFile = readFile
    }
}

/// A back end that can work in agent mode.
public protocol AgentAttachable: AssistantProvider {
    /// The provider for one request with the attachment (itself,
    /// unchanged, when it cannot take one).
    func attaching(_ attachment: AgentAttachment) -> AssistantProvider
    /// Whether this provider carries an attachment.
    var isAttached: Bool { get }
}
