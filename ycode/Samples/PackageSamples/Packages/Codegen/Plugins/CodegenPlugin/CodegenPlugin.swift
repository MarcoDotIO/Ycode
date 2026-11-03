import Foundation
import PackagePlugin

/// Runs `codegen-tool` on each `.codegen` file of the target.
@main
struct CodegenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let tool = try context.tool(named: "codegen-tool")
        return target.sourceFiles.map(\.url).filter { $0.pathExtension == "codegen" }.map {
            Self.command(tool: tool.url, input: $0, outputDirectory: context.pluginWorkDirectoryURL)
        }
    }

    static func command(tool: URL, input: URL, outputDirectory: URL) -> Command {
        let output = outputDirectory.appending(path: input.deletingPathExtension().lastPathComponent + ".swift")
        return .buildCommand(displayName: "Generating \(output.lastPathComponent) from \(input.lastPathComponent)",
                             executable: tool, arguments: [input.path, output.path],
                             inputFiles: [input], outputFiles: [output])
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension CodegenPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let tool = try context.tool(named: "codegen-tool")
        return target.inputFiles.map(\.url).filter { $0.pathExtension == "codegen" }.map {
            Self.command(tool: tool.url, input: $0, outputDirectory: context.pluginWorkDirectoryURL)
        }
    }
}
#endif
