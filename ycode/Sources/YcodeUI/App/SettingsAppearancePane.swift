import AppKit
import YcodeIDECore

/// Settings ▸ Appearance (`specs/ide/settings.md` §Appearance, R5.1): a
/// fixed top part (the Appearance card with the three window-on-wallpaper
/// thumbnails, the bordered preview with line numbers, and Theme / Fonts /
/// Editor centred between two full-width separators) over a list that
/// scrolls on its own: Theme (a Choose… push button) and Name, then one
/// 56-point colour row per element (a saturation slider and a colour well),
/// the theme file's buttons. Built-in themes are read-only.
@MainActor
public final class ThemesSettingsPane: SettingsPane {
    public init(prefs: Preferences = .shared) { super.init("Appearance", prefs: prefs) }
    public enum Segment: Int { case theme, fonts, editor }
    public var segment: Segment = .theme { didSet { if isViewLoaded { rebuild() } } }

    /// One font row per token kind, in Ycode's token set (reference-ui-5.md
    /// §9.4). Plain Text is the theme's text color and source font.
    public static let tokenRows: [(title: String, kind: SourceTokenizer.Kind)] = [
        ("Plain Text", .identifier), ("Comments", .comment), ("Documentation Comments", .docComment), ("Strings", .string),
        ("Numbers", .number), ("Keywords", .keyword), ("Preprocessor Statements", .preprocessor), ("Attributes", .attribute),
        ("Type Names", .typeName),
    ]

    /// The System / Light / Dark thumbnails.
    public private(set) var appearanceButtons: [NSButton] = []
    /// Their captions (the chosen one bold).
    public private(set) var captions: [NSTextField] = []
    /// The card around them, with its "Appearance" label.
    public private(set) var appearanceCard: SettingsCardView?
    public private(set) var appearanceLabel: NSTextField?
    /// The live code preview under the card.
    public let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 120))
    public private(set) var previewBox: NSView?
    /// Theme / Fonts / Editor, and the two separators around it.
    public private(set) var segments: NSControl?
    public private(set) var separators: [NSView] = []
    /// The colour rows of the Theme segment (for tests).
    public private(set) var colorRows: [(key: String, view: NSView)] = []
    public static let previewCode = """
    /// A greeting, said once.
    struct Greeter {
        let name = "Ycode" // who to greet
        #if DEBUG
        @MainActor func greet(times: Int = 1) { print("Hello, \\(name)") }
        #endif
    }
    """

    override var listTop: CGFloat { SettingsAppearanceLayout.listTop - SettingsMetrics.titleAreaHeight }
    override var firstCardInset: CGFloat { 0 }

    // MARK: The fixed part

    override func buildFixed(in root: NSView) {
        let L = SettingsAppearanceLayout.self
        let top = SettingsMetrics.titleAreaHeight, left = SettingsMetrics.detailX
        let card = SettingsCardView()
        let label = NSTextField(labelWithString: "Appearance")
        label.font = .systemFont(ofSize: SettingsMetrics.fontSize)
        label.textColor = SettingsColors.label
        appearanceCard = card
        appearanceLabel = label
        let thumbs = Preferences.Appearance.allCases.map { a in
            let b = AppearanceThumbnailButton(a)
            b.onChoose = { [weak self] in self?.chooseAppearance(a) }
            return b
        }
        appearanceButtons = thumbs
        captions = Preferences.Appearance.allCases.map { NSTextField(labelWithString: $0.rawValue) }
        let box = ThemePreviewBox(textView: preview)
        previewBox = box
        let seg = SettingsSegmentsControl(titles: L.segmentTitles, selected: segment.rawValue)
        seg.onChange = { [weak self] i in self?.segment = Segment(rawValue: i) ?? .theme }
        segments = seg
        let sep1 = SettingsPaneSeparator(lineHeight: L.separator1Height), sep2 = SettingsPaneSeparator(lineHeight: L.separator2Height)
        separators = [sep1, sep2]
        for v in [card, label, box, sep1, seg, sep2] + thumbs + captions as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let capLabel = NSFont.systemFont(ofSize: SettingsMetrics.fontSize).capHeight
        let capCaption = NSFont.systemFont(ofSize: L.captionFontSize).capHeight
        var cs: [NSLayoutConstraint] = [
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsMetrics.cardInset),
            card.widthAnchor.constraint(equalToConstant: SettingsMetrics.cardWidth),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: L.cardTop - top),
            card.heightAnchor.constraint(equalToConstant: L.cardHeight),
            // The label's ink at x 210.5 (its frame 1 before), cap top 85.5.
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 210.5 - left - 1),
            label.firstBaselineAnchor.constraint(equalTo: root.topAnchor, constant: L.labelCapTop + capLabel - top),
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsMetrics.cardInset),
            box.widthAnchor.constraint(equalToConstant: SettingsMetrics.cardWidth),
            box.topAnchor.constraint(equalTo: root.topAnchor, constant: L.previewTop - top),
            sep1.leadingAnchor.constraint(equalTo: root.leadingAnchor), sep1.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep1.topAnchor.constraint(equalTo: root.topAnchor, constant: L.separator1Y - top),
            sep1.heightAnchor.constraint(equalToConstant: L.separator1Height),
            seg.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            seg.topAnchor.constraint(equalTo: root.topAnchor, constant: L.segmentsTop - top),
            seg.widthAnchor.constraint(equalToConstant: L.segmentsSize.width), seg.heightAnchor.constraint(equalToConstant: L.segmentsSize.height),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor), sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep2.topAnchor.constraint(equalTo: root.topAnchor, constant: L.separator2Y - top),
            sep2.heightAnchor.constraint(equalToConstant: 1),
        ]
        let m = AppearanceThumbnailButton.margin
        for (i, (b, c)) in zip(thumbs, captions).enumerated() {
            c.font = .systemFont(ofSize: L.captionFontSize)
            c.alignment = .center
            cs += [
                b.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: L.thumbnailXs[i] - left - m),
                b.topAnchor.constraint(equalTo: root.topAnchor, constant: L.thumbnailTop - top - m),
                b.widthAnchor.constraint(equalToConstant: L.thumbnailSize.width + 2 * m),
                b.heightAnchor.constraint(equalToConstant: L.thumbnailSize.height + 2 * m),
                c.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                c.firstBaselineAnchor.constraint(equalTo: root.topAnchor, constant: L.captionCapTop + capCaption - top),
            ]
        }
        NSLayoutConstraint.activate(cs)
        updateAppearanceChoice()
        refreshPreview()
    }

    /// The chosen thumbnail's ring and bold, dark caption.
    func updateAppearanceChoice() {
        for (i, a) in Preferences.Appearance.allCases.enumerated() where i < appearanceButtons.count {
            let on = prefs.appearance == a
            appearanceButtons[i].state = on ? .on : .off
            captions[i].font = on ? .boldSystemFont(ofSize: SettingsAppearanceLayout.captionFontSize)
                : .systemFont(ofSize: SettingsAppearanceLayout.captionFontSize)
            captions[i].textColor = on ? SettingsR5Colors.captionSelected : SettingsR5Colors.caption
        }
    }

    /// The preview shows sample code in the selected theme.
    func refreshPreview() {
        (previewBox as? ThemePreviewBox)?.show(Self.previewCode, background: Theme.backgroundColor)
    }

    public func chooseAppearance(_ a: Preferences.Appearance) {
        prefs.appearance = a
        updateAppearanceChoice()
    }

    // MARK: The list

    override func build() {
        (segments as? SettingsSegmentsControl)?.selectedSegment = segment.rawValue
        colorRows = []
        refreshPreview()
        switch segment {
        case .theme: buildTheme()
        case .fonts: buildFonts()
        case .editor:
            row("Cursor style:", popUp(["Vertical Bar"], selected: "Vertical Bar") { _ in })
        }
    }

    /// Selects a theme (the "Choose…" menu).
    public func chooseTheme(_ name: String) {
        prefs.themeName = name
        if isViewLoaded { rebuild() }
    }

    /// Theme (Choose…) and Name; the colour rows; the theme file.
    func buildTheme() {
        let t = prefs.theme
        let builtIn = EditorTheme.builtIns.contains { $0.name == t.name }
        let choose = SettingsPushButton("Choose\u{2026}")
        choose.identifier = .init("settings-theme-choose")
        choose.onPress = { [weak self] b in self?.showThemeMenu(from: b) }
        cardRow(SettingsPlainRow(label: "Theme", control: choose, height: SettingsAppearanceLayout.themeRowHeight), title: "Theme")
        let name = NSTextField(labelWithString: t.name)
        name.font = .systemFont(ofSize: SettingsMetrics.fontSize)
        name.textColor = SettingsColors.label
        name.identifier = .init("settings-theme-name")
        cardRow(SettingsPlainRow(label: "Name", control: name, height: SettingsAppearanceLayout.nameRowHeight), title: "Name")
        endCard()
        for (title, key) in ThemeColorRows.all {
            let v = ThemeColorRowView(title: title, color: Self.themeColor(key), background: Self.themeColor("background"), hex: ThemeColorRows.value(key, in: t))
            v.slider.isEnabled = !builtIn
            v.well.isEnabled = !builtIn
            v.slider.onChange = { [weak self, weak v] _ in
                guard let v else { return }
                let c = v.slider.color
                let hex = ThemeColorRows.hex(c.r, c.g, c.b)
                v.well.hexValue = hex
                v.well.color = NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
                self?.setColor(hex: hex, key: key)
            }
            v.well.onCommit = { [weak self, weak v] hex in
                self?.setColor(hex: hex, key: key)
                // The typed colour (or the system's again) is the slider's full end.
                if let v {
                    if let hex, let c = ThemeColorRows.components(hex) {
                        v.dynamicColor = NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
                    } else {
                        v.dynamicColor = ThemesSettingsPane.themeColor(key)
                    }
                    v.resolve()
                    v.slider.value = 1
                }
            }
            cardRow(v, title: title)
            colorRows.append((key, v))
        }
        if builtIn { footnote("Built-in themes cannot be changed; duplicate one to edit it.") }
        heading("Theme File")
        let dup = SettingsPushButton("Duplicate"), del = SettingsPushButton("Delete")
        let imp = SettingsPushButton("Import\u{2026}"), exp = SettingsPushButton("Export\u{2026}")
        dup.onPress = { [weak self] _ in self?.duplicateClicked() }
        del.onPress = { [weak self] _ in self?.deleteClicked() }
        imp.onPress = { [weak self] _ in self?.importClicked() }
        exp.onPress = { [weak self] _ in self?.exportClicked() }
        del.isEnabled = !builtIn
        row("", NSStackView(views: [dup, del, imp, exp]))
    }

    /// The colour a row shows: the theme's, else the editor's (dynamic for
    /// system colours; the row resolves it in its appearance).
    static func themeColor(_ key: String) -> NSColor {
        switch key {
        case "foreground": Theme.textColor
        case "background": Theme.backgroundColor
        case "selection": Theme.selectionColor
        case "currentLine": Theme.currentLineColor
        default: SourceTokenizer.Kind(rawValue: key).map { Theme.color(for: $0) } ?? Theme.textColor
        }
    }

    func showThemeMenu(from b: NSView) {
        guard let w = b.window, w.isVisible else { return }
        let menu = NSMenu()
        for t in prefs.themes {
            let item = NSMenuItem(title: t.name, action: #selector(themeMenuChosen(_:)), keyEquivalent: "")
            item.target = self
            item.state = t.name == prefs.themeName ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }

    @objc func themeMenuChosen(_ item: NSMenuItem) { chooseTheme(item.title) }

    /// One font row per token kind: the font's name and an editable size.
    func buildFonts() {
        let t = prefs.theme
        for (title, kind) in Self.tokenRows {
            let f = font(for: kind)
            let name = NSTextField(labelWithString: f.name.isEmpty ? (t.font.displayName ?? "System Monospaced") : f.name)
            let size = number(Int(f.size)) { [weak self] n in
                guard let self else { return }
                var spec = self.font(for: kind)
                spec.size = Double(max(6, min(48, n)))
                self.setFont(spec, for: kind)
            }
            row(title + ":", NSStackView(views: [name, size]))
        }
        heading("Console")
        row("Font size:", number(Int(t.consoleFontSize)) { [weak self] n in self?.edit { $0.consoleFontSize = Double(max(6, min(48, n))) } })
    }

    /// A token kind's font as the Fonts rows show it.
    public func font(for kind: SourceTokenizer.Kind) -> EditorTheme.FontSpec {
        let t = prefs.theme
        if kind != .identifier, let f = t.tokenFonts?[kind.rawValue] { return f }
        return EditorTheme.FontSpec(name: t.fontName, size: t.fontSize)
    }

    /// Sets a token kind's font (Plain Text: the source font) in the
    /// selected user theme.
    public func setFont(_ f: EditorTheme.FontSpec, for kind: SourceTokenizer.Kind) {
        edit { t in
            if kind == .identifier { t.fontName = f.name; t.fontSize = f.size } else { t.tokenFonts = (t.tokenFonts ?? [:]).merging([kind.rawValue: f]) { $1 } }
        }
    }

    /// Sets a token kind's color (Plain Text: the text color).
    public func setColor(_ c: NSColor, for kind: SourceTokenizer.Kind) {
        setColor(hex: EditorTheme.hex(c), key: kind == .identifier ? "foreground" : kind.rawValue)
    }

    /// Sets a colour row's value (nil: the system colour) in the user theme.
    public func setColor(hex: String?, key: String) {
        edit { ThemeColorRows.set(key, hex, in: &$0) }
        refreshPreview()
    }

    /// Edits the selected user theme (built-ins are left alone).
    public func edit(_ f: (inout EditorTheme) -> Void) { prefs.editSelectedTheme(f) }

    @objc public func duplicateClicked() {
        _ = try? prefs.duplicate(prefs.theme)
        if isViewLoaded { rebuild() }
    }

    @objc func deleteClicked() {
        prefs.deleteTheme(named: prefs.themeName)
        rebuild()
    }

    @objc func importClicked() {
        guard let w = view.window, w.isVisible else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = []
        p.allowsOtherFileTypes = true
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url { _ = try? self?.prefs.importTheme(from: u); self?.rebuild() }
        }
    }

    @objc func exportClicked() {
        guard let w = view.window, w.isVisible else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = prefs.theme.fileName
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url, let t = self?.prefs.theme { try? self?.prefs.exportTheme(t, to: u) }
        }
    }
}

/// A card row of a given height: the label at the left, one control at the
/// right (10 inside), both centred in the row.
final class SettingsPlainRow: NSView {
    let label: NSTextField
    let control: NSView

    init(label title: String, control: NSView, height: CGFloat) {
        label = NSTextField(labelWithString: title)
        self.control = control
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: SettingsMetrics.fontSize)
        label.textColor = SettingsColors.label
        for v in [label, control] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.labelInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.controlInset),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
}
