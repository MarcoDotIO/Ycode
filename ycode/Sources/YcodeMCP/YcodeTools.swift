import Foundation
import YcodeAssistant
import YcodeBuild
import YcodeIDECore

/// JSON Schema 2020-12 fragments for tool definitions.
enum Schema {
    static func object(_ properties: [String: AnyJSON], required: [String] = []) -> AnyJSON {
        ["type": "object", "properties": .object(properties), "required": .strings(required), "additionalProperties": false]
    }
    static func string(_ description: String, oneOf values: [String]? = nil) -> AnyJSON {
        var o: [String: AnyJSON] = ["type": "string", "description": .string(description)]
        if let values { o["enum"] = .strings(values) }
        return .object(o)
    }
    static func integer(_ description: String, minimum: Int? = nil) -> AnyJSON {
        var o: [String: AnyJSON] = ["type": "integer", "description": .string(description)]
        if let minimum { o["minimum"] = .int(minimum) }
        return .object(o)
    }
    static func boolean(_ description: String) -> AnyJSON { ["type": "boolean", "description": .string(description)] }
    static func array(_ items: AnyJSON, _ description: String) -> AnyJSON {
        ["type": "array", "items": items, "description": .string(description)]
    }
    /// An output schema: an object whose listed properties are required.
    static func output(_ properties: [String: AnyJSON]) -> AnyJSON {
        ["type": "object", "properties": .object(properties), "required": .strings(properties.keys.sorted())]
    }
    static let anyArray: AnyJSON = ["type": "array"]
    static let anyObject: AnyJSON = ["type": "object"]
    static let str: AnyJSON = ["type": "string"]
    static let int: AnyJSON = ["type": "integer"]
    static let bool: AnyJSON = ["type": "boolean"]
    static let workspace = string("Optional: the workspace to use (its path); opened when it is not the open one.")
}

extension YcodeMCPHost {
    /// The server's instructions (what an agent reads first).
    public static let instructions = """
    Ycode's tools for Apple-platform and Swift projects (Swift packages, .xcodeproj, .xcworkspace), on macOS and Linux. \
    Start with workspace_open (or workspace_describe when one is open). Typical loop: build → issues → file_read → \
    file_edit → build → test. Paths are relative to the workspace folder. Writes (file_write, file_edit, strings_set) \
    are refused when the server is read-only; in the Ycode IDE each change is shown to the user as a proposal, and \
    the tool answers only after they accept or reject it. The simulator_* tools drive the Ycode Simulator on its \
    remote Linux host (when one is set up); simulator_screenshot returns an image.
    """

    /// Every Ycode tool, in the order `tools/list` shows them.
    func installTools() {
        server.instructions = Self.instructions
        server.resources = YcodeResources(host: self)
        server.prompts = Self.prompts
        server.tools = workspaceTools + buildTools + runTools + contentTools + completionTools
    }

    /// A tool whose handler runs on the main actor.
    func tool(_ name: String, _ title: String, _ description: String, input: AnyJSON, output: AnyJSON? = nil,
              annotations: MCPToolAnnotations = .read, writes: Bool = false,
              _ body: @escaping @MainActor (YcodeMCPHost, MCPToolCall) async throws -> MCPToolResult) -> MCPTool {
        MCPTool(name: name, title: title, description: description, inputSchema: input, outputSchema: output, annotations: annotations,
                writes: writes) { [weak self] call in
            guard let host = self else { throw MCPToolError("the server is shutting down") }
            return try await body(host, call)
        }
    }

    static let prompts: [MCPPrompt] = [
        MCPPrompt(name: "build_and_fix", title: "Build and fix",
                  description: "Build the scheme, read the errors and fix them until the build succeeds.",
                  arguments: [.init("scheme", "The scheme to build (default: the workspace's first).")]) { args in
            "Build \(args["scheme"].map { "the scheme \($0)" } ?? "the workspace") with Ycode's build tool. For each error, read the file around the issue's line with file_read, fix it with file_edit, and build again until the build succeeds. Then run the tests with the test tool and report the result."
        },
        MCPPrompt(name: "run_tests", title: "Run tests",
                  description: "Run the tests and explain each failure.",
                  arguments: [.init("tests", "Optional test identifiers (Suite/name), comma-separated.")]) { args in
            "Run \(args["tests"].map { "the tests \($0)" } ?? "all tests") with Ycode's test tool. For each failure, read the test and the code it checks, and explain the cause."
        },
    ]
}
