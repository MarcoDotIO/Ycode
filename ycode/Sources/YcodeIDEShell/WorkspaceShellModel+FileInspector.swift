import Foundation
import YcodeIDECore

/// The File inspector (`reference-ui.md` §6) for the open file, with the
/// sections and rows the macOS IDE's inspector shows
/// (`InspectorAreaController.fileInspector`; `cross-platform-parity.md` §5):
/// Identity and Type with Working Copy and Relative Path, On Demand Resource
/// Tags, Image Properties and Localization for an image, Target Membership,
/// and Text Settings for text. A package's files show only Identity and
/// Type and Text Settings (reference-ui-6.md §6, I1).
extension WorkspaceShellModel {
    public var fileInspector: [InspectorSection] {
        guard let d = document else { return [] }
        let url = URL(fileURLWithPath: d.path)
        let root = sourceControl.repository?.root
        let info = FileInspectorInfo.make(for: url, in: session.model, repositoryRoot: Preferences.shared.sourceControlEnabled ? root : nil)
        let isProject = url.pathExtension == "xcodeproj"
        let isImage = ImageHeaderInfo.isImage(url)
        var identity = [
            InspectorRow(key: "Name", value: .field(url.lastPathComponent)),
            InspectorRow(key: "Type", value: .popUp("Default - " + WorkspaceChrome.fileTypeName(for: url)), ruleAfter: true),
            // metrics.md §12.4: "Relative to Group", also in a synchronized
            // folder (where the pop-up is disabled and the button hidden).
            InspectorRow(key: "Location", value: .popUp(isProject ? "Absolute" : "Relative to Group",
                                                        button: info.inSynchronizedFolder ? nil : "folder",
                                                        enabled: !isProject && !info.inSynchronizedFolder)),
            InspectorRow(key: "", value: .label(url.lastPathComponent, bold: false)),
            InspectorRow(key: "Full Path", value: .path(url.path, button: "arrow.right.circle.fill"), ruleAfter: true),
        ]
        if let wc = info.workingCopy, let rel = info.relativePath {
            identity.append(InspectorRow(key: "Working Copy", value: .text(wc)))
            identity.append(InspectorRow(key: "Relative Path", value: .text(rel)))
        }
        var sections = [InspectorSection(title: "Identity and Type", rows: identity)]
        if !isProject && !info.isPackageFile {
            // An image is a resource: a "Tags" field (editor-area.md §D.8).
            sections.append(InspectorSection(title: "On Demand Resource Tags",
                                             rows: [InspectorRow(key: "", value: .tags(placeholder: isImage ? "Tags" : "Only resources are taggable",
                                                                                       enabled: isImage))]))
            if isImage {
                let rows = (ImageHeaderInfo.read(url)?.rows ?? ImageHeaderInfo.placeholderRows).map { InspectorRow(key: $0.0, value: .text($0.1)) }
                sections.append(InspectorSection(title: "Image Properties", rows: rows))
                sections.append(InspectorSection(title: "Localization", rows: [InspectorRow(key: "", value: .button("Localize…"))]))
            }
            if !info.memberships.isEmpty {
                sections.append(InspectorSection(title: "Target Membership",
                                                 rows: [InspectorRow(key: "", value: .membership(info.memberships.map { ($0.name, $0.isMember) }))]))
            }
        }
        // An image has no Text Settings (§C.6).
        if !isImage {
            let p = Preferences.shared
            let config = EditorConfig.settings(for: url)
            let tabs = config.indentStyle.map { $0 == .tab } ?? p.indentWithTabs
            var text = [
                InspectorRow(key: "Text Encoding", value: .popUp(WorkspaceChrome.textEncodingItems[0], dimmed: true)),
                InspectorRow(key: "Line Endings", value: .popUp(WorkspaceChrome.lineEndingItems[0], dimmed: true), ruleAfter: true),
                InspectorRow(key: "Indent Using", value: .popUp(tabs ? "Tabs" : "Spaces", enabled: !config.providesIndentation)),
                InspectorRow(key: "Widths", value: .steppers([("Tab", config.tabWidth ?? p.tabWidth), ("Indent", config.indentSize ?? p.indentWidth)],
                                                             enabled: !config.providesIndentation)),
            ]
            if config.providesIndentation { text.append(InspectorRow(key: "", value: .text(EditorConfig.indentationNote))) }
            sections.append(InspectorSection(title: "Text Settings", rows: text))
        }
        return sections
    }
}

/// A section of an inspector: a heading over rows.
public struct InspectorSection: Equatable, Sendable {
    public var title: String
    public var rows: [InspectorRow]
}

/// A row of an inspector: a right-aligned key and a value control, and
/// whether a rule follows it inside its section (after Type, Full Path and
/// Line Endings, `metrics.md` §13.3).
public struct InspectorRow: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        /// The filled Name field.
        case field(String)
        /// A borderless pop-up: its title then the up-down chevron; an
        /// optional button after it; a grey title ("No Explicit …").
        case popUp(String, button: String? = nil, enabled: Bool = true, dimmed: Bool = false)
        case label(String, bold: Bool)
        /// A path that breaks after "/" and "-", with a button after it.
        case path(String, button: String)
        /// Plain text that wraps the same way (Working Copy, Relative Path,
        /// image properties, notes).
        case text(String)
        case steppers([Stepper], enabled: Bool = true)
        /// The On Demand Resource Tags field across the content.
        case tags(placeholder: String, enabled: Bool)
        /// A filled button across the value area (Localize…).
        case button(String)
        /// Target Membership's bordered box: each target and whether the
        /// file is in it.
        case membership([Member])

        public static func == (a: Value, b: Value) -> Bool { String(describing: a) == String(describing: b) }
    }

    public typealias Stepper = (title: String, value: Int)
    public typealias Member = (name: String, isMember: Bool)
    public var key: String
    public var value: Value
    public var ruleAfter = false
}
