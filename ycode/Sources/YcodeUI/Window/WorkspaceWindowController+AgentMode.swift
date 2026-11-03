import AppKit
import YcodeAssistant
import YcodeIDECore
import YcodeMCP

/// The window's agent mode (specs/ide/coding-assistant.md, "Ycode
/// implementation"): Ycode's MCP tools over this window's session, served
/// to each agent request on its own loopback endpoint with its own token;
/// the agent's changes become proposals in its conversation, and its
/// permission requests are asked in a sheet.
@MainActor
final class AgentModeHolder {
    var host: YcodeMCPHost?
    /// Answers permission requests instead of a sheet (tests): the chosen
    /// option's id.
    var permissionResponder: ((String, [AgentAttachment.PermissionOption]) -> String?)?
    /// Endpoints of requests still running (tests).
    var endpoints: [UUID: MCPHTTPTransport] = [:]
}

extension WorkspaceWindowController: YcodeMCPHostDelegate {
    /// The MCP tools over this window's session (made on first use).
    public var mcpHost: YcodeMCPHost {
        if let h = agentModeHolder.host { return h }
        let h = YcodeMCPHost(server: MCPServer(name: "ycode", version: MCPCommand.ycodeVersion, title: "Ycode"), session: session)
        h.delegate = self
        agentModeHolder.host = h
        return h
    }

    /// Answers permission requests in tests.
    public var agentPermissionResponder: ((String, [AgentAttachment.PermissionOption]) -> String?)? {
        get { agentModeHolder.permissionResponder }
        set { agentModeHolder.permissionResponder = newValue }
    }

    /// The running requests' MCP endpoints (tests).
    public var agentEndpoints: [UUID: String] { agentModeHolder.endpoints.mapValues(\.endpoint) }

    /// Wires agent mode into the window's coding assistant.
    func installAgentMode(_ model: CodingAssistantModel) {
        model.agentAttachment = { [weak self, weak model] id in
            guard let self, let model else { return nil }
            return self.agentAttachment(for: id, model: model)
        }
    }

    /// One request's attachment: a server over the shared tools whose
    /// writes are proposals in conversation `id`, on a new endpoint.
    func agentAttachment(for id: UUID, model: CodingAssistantModel) -> (AgentAttachment, () -> Void)? {
        let host = mcpHost
        host.remoteSimulator = RemoteSimulatorSettings.load(Preferences.shared.defaults)
        let base = host.server
        let server = MCPServer(name: base.name, version: base.version, title: base.title, instructions: base.instructions)
        server.tools = base.tools
        server.resources = base.resources
        server.prompts = base.prompts
        let propose: @Sendable (String, String?, String, String) async -> Bool = { [weak model] path, _, proposed, _ in
            await model?.proposeAgentChange(in: id, path: path, proposed: proposed) ?? false
        }
        server.writePolicy = .review { change in await propose(change.path, change.original, change.proposed, change.summary) }
        guard let transport = try? MCPHTTPTransport(server: server) else { return nil }
        agentModeHolder.endpoints[id] = transport
        let attachment = AgentAttachment(
            mcp: .init(url: transport.endpoint, token: transport.token),
            proposeChange: propose,
            requestPermission: { [weak self] title, options in await self?.askAgentPermission(title, options) },
            readFile: { [weak self] path in await self?.agentReadFile(path) })
        return (attachment, { [weak self] in
            transport.stop()
            self?.agentModeHolder.endpoints[id] = nil
        })
    }

    func agentReadFile(_ path: String) -> String? {
        mcpHostText(ofOpenFile: path) ?? (try? String(contentsOfFile: path, encoding: .utf8))
    }

    /// An agent's permission request: a sheet with its options (allow
    /// first); closing it cancels.
    func askAgentPermission(_ title: String, _ options: [AgentAttachment.PermissionOption]) async -> String? {
        if let r = agentModeHolder.permissionResponder { return r(title, options) }
        guard let w = window, w.isVisible, !options.isEmpty else { return options.first { !$0.allows }?.id }
        let alert = NSAlert()
        alert.messageText = "The agent asks for permission"
        alert.informativeText = title
        let shown = Array(options.prefix(4))
        for o in shown { alert.addButton(withTitle: o.name) }
        let response = await alert.beginSheetModal(for: w)
        let i = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return shown.indices.contains(i) ? shown[i].id : nil
    }

    // MARK: YcodeMCPHostDelegate

    public func mcpHostText(ofOpenFile path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return editorArea.allEditors.first { $0.fileURL?.standardizedFileURL == url }?.text
    }

    /// Edited documents are saved before an agent builds or tests.
    public func mcpHostSaveAll() {
        for e in editorArea.allEditors where e.isDirty { try? e.save() }
        try? session.model.saveProjects()
    }

    /// A tool wrote a file: an open editor without unsaved edits shows it.
    public func mcpHostDidWrite(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let disk = try? String(contentsOf: url, encoding: .utf8) else { return }
        for e in editorArea.allEditors where e.fileURL?.standardizedFileURL == url && !e.isDirty && e.text != disk {
            _ = e.replaceText(with: disk, actionName: "Agent Change")
            try? e.save()
        }
    }

    // MARK: The Ycode skill

    /// Settings ▸ Coding Assistant ▸ Ycode skill: asks, then writes the
    /// skill into the workspace folder.
    @objc public func installYcodeSkill(_ sender: Any?) {
        let folder = workspaceFolder
        let paths = AgentSkill.paths.map { folder.appendingPathComponent($0).path }
        let write = { [weak self] in
            guard let self else { return }
            do {
                try AgentSkill.install(into: folder, tools: mcpHost.server.tools)
            } catch {
                presentAssistantAlert("Ycode could not write the skill: \(error.localizedDescription)")
            }
        }
        guard let w = window, w.isVisible else { write(); return }
        let alert = NSAlert()
        alert.messageText = "Install the Ycode skill in “\(session.model.displayName)”?"
        alert.informativeText = "Agents that read skills learn Ycode's tools and the build-and-run workflow from it. Ycode writes:\n" + paths.joined(separator: "\n")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { write() } }
    }
}
