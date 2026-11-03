import Codegen
import SwiftUI

/// Uses code a build-tool plug-in generated in a package (`Codegen.message`)
/// and in this app target itself (`AppMessages`, from AppMessages.codegen).
@main
struct PluginApp: App {
    static let report = "YCODE-PKG-SAMPLE plugin: \(Codegen.message); \(AppMessages.title)"
    init() { FileHandle.standardError.write(Data((Self.report + "\n").utf8)) }
    var body: some Scene {
        WindowGroup { Text(Self.report).padding() }
    }
}
