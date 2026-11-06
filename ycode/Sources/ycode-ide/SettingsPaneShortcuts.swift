import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// Settings ▸ Shortcuts (key bindings): every menu command with its
/// shortcut and menu, filtered by a search field. Selecting a command
/// edits its shortcut: a shortcut another command has is refused, naming
/// that command; an empty one removes it; Default restores it. Customized
/// rows are bold. Overrides are `Preferences.keyBindingOverrides`, shared
/// with the macOS IDE; the menu bar takes them at once (`ShellMenus`).
/// Shortcuts are written as the host's menus show them (on Linux
/// "Ctrl+Shift+K"; `ShortcutNotation`).
struct ShortcutsSettingsPane: View {
    @State private var query = ""
    @State private var selected: String?
    @State private var text = ""
    @State private var message = ""
    @State private var refused = false
    @Environment(\.colorScheme) private var scheme

    static let keyWidth: CGFloat = 150
    static let menuWidth: CGFloat = 210
    static let rowHeight: CGFloat = 24

    #if os(Linux)
    static let example = "Ctrl+Shift+K"
    #else
    static let example = "⇧⌘K"
    #endif

    /// A row: its key in the list (a command can be in two menus).
    struct Row: Identifiable {
        var entry: KeyBindings.Entry
        var id: String { entry.menu + "/" + entry.id }
        var shortcut: String { ShortcutNotation.host.text(entry.command) }
    }

    /// The rows whose title, menu or shortcut contain the query.
    static func rows(_ query: String) -> [Row] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return KeyBindings.entries().map(Row.init).filter {
            q.isEmpty || $0.entry.title.lowercased().contains(q) || $0.entry.menu.lowercased().contains(q) || $0.shortcut.lowercased().contains(q)
        }
    }

    var body: some View {
        let _ = ShellPreferences.shared.revision
        let c = ShellColors(scheme)
        let rows = Self.rows(query)
        let current = rows.first { $0.id == selected }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                    TextField("Filter", text: $query, prompt: Text("Filter"))
                        .textFieldStyle(.plain)
                        .shellTarget("settings shortcuts filter")
                }
                .padding(.horizontal, 8)
                .frame(width: 300, height: 26)
                .background { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.fieldFill) }
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                Spacer(minLength: 0)
                Text(verbatim: "\(rows.count) commands").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
            }
            VStack(spacing: 0) {
                header(c)
                Hairline(color: c.separator)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { pair in
                            row(pair.element, odd: pair.offset % 2 == 1, c)
                        }
                    }
                }
                .shellTarget("settings shortcuts list")
            }
            // A card (settings.md R3.3).
            .background { RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous).fill(SettingsPalette(scheme).card) }
            .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
            editor(current, c)
        }
        .padding(.horizontal, SettingsLayout.cardInset)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(SettingsPalette(scheme).detail)
    }

    func header(_ c: ShellColors) -> some View {
        HStack(spacing: 0) {
            Text("Command").frame(maxWidth: .infinity, alignment: .leading)
            Text("Key").frame(width: Self.keyWidth, alignment: .leading)
            Text("Menu").frame(width: Self.menuWidth, alignment: .leading)
        }
        .font(ShellFonts.smallBold)
        .foregroundStyle(c.secondaryLabel)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    func row(_ r: Row, odd: Bool, _ c: ShellColors) -> some View {
        let on = r.id == selected
        let font = r.entry.customized ? ShellFonts.rowBold : ShellFonts.row
        return Button { choose(r) } label: {
            HStack(spacing: 0) {
                Text(verbatim: r.entry.title).font(font).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: r.shortcut).font(font).lineLimit(1).frame(width: Self.keyWidth, alignment: .leading)
                Text(verbatim: r.entry.menu).font(ShellFonts.small).foregroundStyle(on ? c.label : c.secondaryLabel).lineLimit(1)
                    .frame(width: Self.menuWidth, alignment: .leading)
            }
            .foregroundStyle(c.label)
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(on ? c.rowSelection : (odd ? SettingsPalette(scheme).separator.opacity(0.5) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shellTarget("settings shortcut \(r.entry.title)")
    }

    /// The selected command's shortcut field and buttons.
    @ViewBuilder func editor(_ current: Row?, _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = current {
                HStack(spacing: 8) {
                    Text(verbatim: "\(r.entry.title):").font(ShellFonts.rowBold).foregroundStyle(c.label).lineLimit(1)
                    TextField("Shortcut", text: $text, prompt: Text(verbatim: Self.example))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .onSubmit { apply(r) }
                        .shellTarget("settings shortcut field")
                    Button("Set") { apply(r) }.keyboardShortcut(.defaultAction).shellTarget("settings shortcut set")
                    Button("Remove") {
                        text = ""
                        apply(r)
                    }
                    .disabled(r.entry.command.key.isEmpty)
                    .shellTarget("settings shortcut remove")
                    Button("Default") {
                        KeyBindings.reset(r.entry.id)
                        message = "Restored the default shortcut."
                        refused = false
                        text = Self.rows("").first { $0.id == r.id }?.shortcut ?? ""
                    }
                    .disabled(!r.entry.customized)
                    .shellTarget("settings shortcut default")
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered)
            } else {
                HStack {
                    Text("Select a command to change its shortcut.").font(ShellFonts.row).foregroundStyle(c.secondaryLabel)
                    Spacer(minLength: 0)
                    Button("Restore All Defaults") {
                        Preferences.shared.keyBindingOverrides = [:]
                        message = "Every shortcut is back to its default."
                        refused = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(Preferences.shared.keyBindingOverrides.isEmpty)
                    .shellTarget("settings shortcuts restore all")
                }
            }
            Text(verbatim: message.isEmpty ? "Type modifiers and a key (\(Self.example)); an empty shortcut removes it." : message)
                .font(ShellFonts.small)
                .foregroundStyle(refused ? c.error : c.secondaryLabel)
                .lineLimit(2)
                .shellTarget("settings shortcut message")
        }
        .frame(minHeight: 50, alignment: .top)
    }

    func choose(_ r: Row) {
        selected = r.id
        text = r.shortcut
        message = ""
        refused = false
    }

    /// Saves the field's shortcut for the command, or says why not.
    func apply(_ r: Row) {
        guard let (key, modifiers) = KeyBindings.parse(text) else {
            message = "\u{201C}\(text)\u{201D} is not a shortcut. Type modifiers and one key, such as \(Self.example)."
            refused = true
            return
        }
        // Function and arrow keys (private-use characters) may stand alone.
        let special = key.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } ?? false
        if !key.isEmpty && modifiers.isEmpty && !special {
            message = "A shortcut needs a modifier key (\(Self.example))."
            refused = true
            return
        }
        let conflicts = KeyBindings.set(r.entry.id, key: key, modifiers: modifiers, in: .host)
        refused = !conflicts.isEmpty
        if refused {
            message = "\(ShortcutNotation.host.text(key: key, modifiers: modifiers)) is not set. " + KeyBindings.conflictMessage(conflicts) + "."
        } else {
            message = key.isEmpty ? "Removed the shortcut of \(r.entry.title)." : "\(r.entry.title) is now \(ShortcutNotation.host.text(key: key, modifiers: modifiers))."
            text = ShortcutNotation.host.text(key: key, modifiers: modifiers)
        }
    }
}
