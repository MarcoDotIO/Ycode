import Foundation
import YcodeAssistant

/// The Ycode skill: a short Markdown file for agents that load skills
/// (Claude Code reads `.claude/skills/<name>/SKILL.md`; other agents the
/// same file under `.agents/skills/`), describing Ycode's MCP tools and
/// the build-and-run workflow. Written into a project only when the user
/// asks (the IDE's Install Ycode Skill, `ycode mcp install-skill`).
public enum AgentSkill {
    /// Where the skill goes, relative to the workspace folder.
    public static let paths = [".claude/skills/ycode/SKILL.md", ".agents/skills/ycode/SKILL.md"]

    /// The skill's text for a tool list.
    public static func markdown(tools: [MCPTool]) -> String {
        func firstSentence(_ s: String) -> String {
            guard let r = s.range(of: ". ") else { return s }
            return String(s[..<r.lowerBound]) + "."
        }
        let rows = tools.map { "- `\($0.name)`\($0.writes ? " (writes)" : ""): \(firstSentence($0.description))" }.joined(separator: "\n")
        return """
        ---
        name: ycode
        description: Build, test, run and inspect this Swift / Apple-platform project through Ycode's MCP tools (the "ycode" MCP server): builds with structured issues, tests, runs on this computer or the Ycode Simulator with screenshots, SwiftUI preview images, String Catalog translations. Use it whenever you change or check code in this workspace.
        ---

        # Ycode

        Ycode is an IDE for Apple platforms that runs on macOS and Linux. Its MCP server gives you the IDE's
        build system, tests, run destinations and project model. Start it with `ycode mcp` (stdio), or let the
        Ycode IDE attach it to you in agent mode.

        ## Workflow

        1. `workspace_describe` (or `workspace_open` with the project's path): schemes, targets, destinations.
        2. Read with `file_read` / `search` / `symbol_search`; change with `file_edit` (exact text) or `file_write`.
        3. `build`, then `issues` for every error with its file and line; fix and build again until it succeeds.
        4. `test` (all, or `tests: ["Suite/name"]`); read failures and fix.
        5. `run` (on this computer: its output; on a Ycode Simulator destination: the app launches on the
           remote device), then `simulator_screenshot` to see the screen and `simulator_logs` for its console.
        6. For SwiftUI views, `preview_render` returns the preview as an image.

        Paths are relative to the workspace folder. Writes are refused when the server is read-only
        (`ycode mcp --allow-writes` allows them); in the Ycode IDE each change is shown to the user as a
        proposal and the tool answers once they accept or reject it, so wait for the answer and do not
        retry a rejected change unchanged.

        ## Tools

        \(rows)

        """
    }

    /// Writes the skill into `folder` (both locations); the files written.
    @discardableResult
    public static func install(into folder: URL, tools: [MCPTool]) throws -> [URL] {
        let text = markdown(tools: tools)
        var written: [URL] = []
        for p in paths {
            let url = folder.appendingPathComponent(p)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }
        return written
    }
}
