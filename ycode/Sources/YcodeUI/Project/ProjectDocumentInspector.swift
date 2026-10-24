import AppKit
import YcodeProject

/// The file inspector's Project Document section for a `.xcodeproj`
/// (reference-ui-3.md §1.13): Compatibility, Encoding (Minimize Project
/// References), Decoding (Strictly Validate), Organization, Class Prefix.
@MainActor
enum ProjectDocumentInspector {
    static var compatibilityTitles: [String] { ProjectEditorModel.compatibilityVersions.map(\.title) }

    /// Applies an edit to the project file and writes it back.
    static func edit(_ xcodeproj: URL, _ change: (inout ProjectEditorModel) -> Void) throws {
        let file = xcodeproj.appendingPathComponent("project.pbxproj")
        let text = try String(contentsOf: file, encoding: .utf8)
        var model = ProjectEditorModel(proj: try PBXProj(parsing: text), xcodeprojURL: xcodeproj)
        change(&model)
        let out = model.proj.serialized(projectName: model.projectName)
        if out != text { try out.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Target of the section's controls; kept alive by the controls.
    @MainActor final class Writer: NSObject {
        let url: URL
        init(url: URL) { self.url = url }
        @objc func compatibilityChosen(_ p: NSPopUpButton) {
            guard let t = p.titleOfSelectedItem else { return }
            try? ProjectDocumentInspector.edit(url) { $0.setCompatibility(t) }
        }
        @objc func minimizeToggled(_ b: NSButton) {
            try? ProjectDocumentInspector.edit(url) { $0.setMinimizeProjectReferences(b.state == .on) }
        }
    }
    nonisolated(unsafe) static var writerKey: UInt8 = 0

    /// The section's values read from the project file, or nil.
    static func section(for xcodeproj: URL) -> ProjectEditorModel.ProjectDocumentSection? {
        guard let text = try? String(contentsOf: xcodeproj.appendingPathComponent("project.pbxproj"), encoding: .utf8),
              let proj = try? PBXProj(parsing: text) else { return nil }
        return ProjectEditorModel(proj: proj, xcodeprojURL: xcodeproj).projectDocumentSection
    }

    /// (label, control) rows; controls keyed by label in `controls`.
    static func rows(for xcodeproj: URL, controls: inout [String: NSView]) -> [(String, NSView)] {
        guard let s = section(for: xcodeproj) else { return [] }
        let writer = Writer(url: xcodeproj)
        let compat = NSPopUpButton(frame: .zero, pullsDown: false)
        compat.controlSize = .small
        compat.addItems(withTitles: compatibilityTitles)
        compat.selectItem(withTitle: s.compatibility)
        compat.target = writer
        compat.action = #selector(Writer.compatibilityChosen(_:))
        let minimize = NSButton(checkboxWithTitle: "Minimize Project References", target: writer, action: #selector(Writer.minimizeToggled(_:)))
        for c in [compat, minimize] as [NSView] { objc_setAssociatedObject(c, &writerKey, writer, .OBJC_ASSOCIATION_RETAIN) }
        minimize.state = s.minimizeProjectReferences ? .on : .off
        let strict = NSButton(checkboxWithTitle: "Strictly Validate", target: nil, action: nil)
        strict.state = s.strictlyValidate ? .on : .off
        let org = NSTextField(string: s.organization)
        let prefix = NSTextField(string: s.classPrefix)
        for c in [minimize, strict] { c.controlSize = .small; c.font = .systemFont(ofSize: 11) }
        for f in [org, prefix] { f.font = .systemFont(ofSize: 11); f.widthAnchor.constraint(equalToConstant: 140).isActive = true }
        let rows: [(String, NSView)] = [("Compatibility", compat), ("Encoding", minimize), ("Decoding", strict),
                                        ("Organization", org), ("Class Prefix", prefix)]
        for (k, v) in rows { controls[k] = v }
        return rows
    }
}
