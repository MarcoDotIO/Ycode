import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

/// Settings ▸ Source Control: the switch, and git's author read from its
/// global configuration (read-only, off the main thread).
struct SourceControlSettingsPane: View {
    @State private var author: (name: String?, email: String?)?

    var body: some View {
        let _ = ShellPreferences.shared.revision
        SettingsForm {
            SettingsSection {
                CheckRow(title: "Enable source control", isOn: setting(\.sourceControlEnabled), target: "settings source control")
            }
            SettingsSection("Git", content: {
                ValueRow(title: "Author Name", value: value(\.name), target: "settings git name")
                ValueRow(title: "Author Email", value: value(\.email), target: "settings git email")
            }, footer: {
                FootNote(text: "From git\u{2019}s global configuration (git config --global user.name and user.email); Ycode only reads it.")
            })
        }
        .task {
            guard author == nil else { return }
            let read = await Task.detached { (name: GitGlobalConfig.value("user.name"), email: GitGlobalConfig.value("user.email")) }.value
            author = read
        }
    }

    func value(_ key: KeyPath<(name: String?, email: String?), String?>) -> String {
        guard let author else { return "Reading\u{2026}" }
        return author[keyPath: key] ?? "Not set"
    }
}

/// Settings ▸ Locations: where Ycode keeps its files and which tools it
/// builds and reads code with. On macOS the Build System pop-up
/// (`BuildSystemPreference`); on Linux the engine is fixed (SwiftPM for
/// packages, ycodebuild for projects), so the pane names the tools found.
struct LocationsSettingsPane: View {
    @State private var tools: [(title: String, path: String?)]?

    var body: some View {
        let _ = ShellPreferences.shared.revision
        SettingsForm {
            #if !os(Linux)
            SettingsSection("Build") {
                PickerRow(title: "Build System", selection: Binding(get: { BuildSystemPreference.current() }, set: { p in
                    p.save()
                    ShellPreferences.shared.touch()
                }), options: BuildSystemPreference.allCases.map { ($0, $0 == BuildSystemPreference.defaultValue ? "\($0.title) (Default)" : $0.title) },
                          target: "settings build system",
                          help: BuildSystemPreference.current() == .xcodebuild ? "Builds use xcodebuild."
                              : (SwiftBuildEngine.locate().map { "swbuild: \($0)" } ?? "The swift-build helper was not found; builds use xcodebuild."))
            }
            #endif
            SettingsSection("Build and Code Tools", content: {
                ForEach(tools ?? [], id: \.title) { t in
                    SettingsRow(t.title) { PathText(path: t.path) }
                }
                if tools == nil { ValueRow(title: "Tools", value: "Looking\u{2026}") }
            }, footer: {
                FootNote(text: Self.engineNote)
            })
            SettingsSection("Files") {
                SettingsRow("Themes") { PathText(path: Preferences.shared.themesDirectory.path) }
                SettingsRow("Package build products") { PathText(path: ".build inside each package") }
            }
        }
        .task {
            guard tools == nil else { return }
            tools = await Task.detached { Self.locateTools() }.value
        }
    }

    #if os(Linux)
    static let engineNote = "Packages build with SwiftPM (swift build); projects and workspaces with ycodebuild. Tools are found on the PATH."
    #else
    static let engineNote = "Tools are found on the PATH; ycodebuild also next to Ycode."
    #endif

    /// The tools Ycode runs and where they are (nil: not found).
    nonisolated static func locateTools() -> [(title: String, path: String?)] {
        [("Swift", ShellToolchain.locate("swift")), ("Language server", ShellToolchain.locate("sourcekit-lsp")),
         ("Project builds", TestRunnerSelection.locateYcodebuild()), ("Git", ShellToolchain.locate("git"))]
    }
}

/// A path in the small monospaced style, or "Not found".
struct PathText: View {
    var path: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Text(verbatim: path.map(Self.tilde) ?? "Not found")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(path == nil ? c.error : c.secondaryLabel)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// The path with the home folder as "~".
    static func tilde(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
}
