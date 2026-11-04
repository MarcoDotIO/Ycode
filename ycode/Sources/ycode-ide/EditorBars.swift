import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell

/// Find and Replace in the open file (`specs/ide/source-editor.md` §Find bar):
/// options, the query, "N of M", previous and next, Done; with Replace, a
/// second row.
struct EditorFindBarView: View {
    @Bindable var bar: EditorFindBar
    var model: WorkspaceShellModel
    @FocusState private var queryFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { bar.showsReplace }, set: { bar.showsReplace = $0 })) {
                    Text("Find").tag(false)
                    Text("Replace").tag(true)
                }
                .labelsHidden()
                .frame(width: 88)
                .shellTarget("find mode")
                TextField("Find", text: $bar.query)
                    .textFieldStyle(.roundedBorder)
                    .font(ShellFonts.row)
                    .focused($queryFocused)
                    .onSubmit { bar.step(forward: true); queryFocused = true }
                    .shellTarget("find field")
                Text(verbatim: bar.countText).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                    .shellTarget("find count")
                Button { bar.step(forward: false) } label: { Image(systemName: "chevron.left").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("Find Previous").shellTarget("find previous")
                Button { bar.step(forward: true) } label: { Image(systemName: "chevron.right").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("Find Next").shellTarget("find next")
                Toggle("Case", isOn: Binding(get: { !bar.options.ignoreCase }, set: { bar.options.ignoreCase = !$0 }))
                    .font(ShellFonts.small).help("Match Case").shellTarget("find case")
                Toggle("Word", isOn: $bar.options.wholeWord)
                    .font(ShellFonts.small).help("Matching Word").shellTarget("find word")
                Toggle("Regex", isOn: $bar.options.regularExpression)
                    .font(ShellFonts.small).help("Regular Expression").shellTarget("find regex")
                Button("Done") { bar.isShown = false }.font(ShellFonts.small).shellTarget("find done")
            }
            if bar.showsReplace {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 88, height: 1)
                    TextField("Replace", text: $bar.replacement)
                        .textFieldStyle(.roundedBorder)
                        .font(ShellFonts.row)
                        .onSubmit { bar.replaceCurrent() }
                        .shellTarget("replace field")
                    Button("Replace") { bar.replaceCurrent() }.font(ShellFonts.small).shellTarget("replace one")
                    Button("All") { bar.replaceAll() }.font(ShellFonts.small).shellTarget("replace all")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(c.content)
        .onChange(of: bar.query) { _, _ in bar.refresh() }
        .onChange(of: bar.options) { _, _ in bar.refresh() }
        // After the bar is in the window (a focus request made while it is
        // being built finds no field yet).
        .task(id: bar.focusCount) { queryFocused = true }
        .onDisappear { model.focusEditor() }
        .onKeyPress(.escape) {
            bar.isShown = false
            return .handled
        }
        .shellTarget("find bar")
    }
}

/// A file that changed on disk, was deleted there, or can't be edited.
struct EditorBanner: View {
    var model: WorkspaceShellModel
    let document: EditorDocument
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        if let reason = document.readOnlyReason {
            bar(c, Text(verbatim: reason)) {}
        } else if model.recoveredPaths.contains(document.path) {
            bar(c, Text(verbatim: "Unsaved changes to “\(document.name)” were recovered from an earlier session.")) {
                Button("Discard") { model.discardRecoveredText() }.font(ShellFonts.small).shellTarget("banner discard")
            }
        } else if let change = document.diskChange {
            switch change {
            case .modified:
                bar(c, Text(verbatim: "“\(document.name)” changed on disk, and you have unsaved changes.")) {
                    Button("Reload from Disk") { model.reloadFromDisk() }.font(ShellFonts.small).shellTarget("banner reload")
                    Button("Keep My Version") { model.keepEditorVersion() }.font(ShellFonts.small).shellTarget("banner keep")
                }
            case .deleted:
                bar(c, Text(verbatim: "“\(document.name)” no longer exists on disk.")) {
                    Button("Keep and Save Again") {
                        model.keepEditorVersion()
                        model.saveCurrent()
                    }
                    .font(ShellFonts.small).shellTarget("banner save again")
                    Button("Close") { model.closeCurrentDocument() }.font(ShellFonts.small).shellTarget("banner close")
                }
            }
        }
    }

    private func bar<A: View>(_ c: ShellColors, _ text: Text, @ViewBuilder actions: () -> A) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.yellow)
                text.font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                Spacer(minLength: 8)
                actions()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(c.content)
            Hairline(color: c.separator)
        }
        .shellTarget("editor banner")
    }
}

/// Navigate ▸ Jump to Line….
struct JumpToLineSheet: View {
    var model: WorkspaceShellModel
    @State private var text = ""
    @State private var isInvalid = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jump to Line").font(ShellFonts.rowBold)
            if let b = model.editor?.buffer {
                Text(verbatim: "Line number, or line:column. The file has \(b.lineCount) lines.").font(ShellFonts.small)
            }
            TextField("Line", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(go)
                .shellTarget("jump field")
            if isInvalid {
                Text("Enter a line number.").font(ShellFonts.small).foregroundStyle(Color.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.isJumpToLineShown = false
                    model.focusEditor()
                }.keyboardShortcut(.cancelAction).shellTarget("jump cancel")
                Button("Jump", action: go).keyboardShortcut(.defaultAction).shellTarget("jump go")
            }
        }
        .padding(16)
        .frame(width: 320)
        .task { fieldFocused = true }
    }

    private func go() {
        isInvalid = !model.jumpToLine(text)
    }
}
