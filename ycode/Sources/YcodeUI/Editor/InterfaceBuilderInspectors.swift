import AppKit
import YcodeIDECore

/// The inspector sections (reference-ui-4.md §13, `interface-builder.md`
/// §Reference Attributes inspector) rendered as controls: a 77-point
/// right-aligned label, the control from x 83 about 171 points wide, check
/// boxes under their group's label, number fields with steppers, colour
/// pop-ups with a swatch, icon rows and combo boxes. Every edit writes the
/// attribute the row names (IBInspectorModel.swift, IBAttributesCatalog.swift)
/// through the session shared with the Linux IDE.
extension InterfaceBuilderController {
    public func inspectorSections(_ t: InspectorTab) -> [IBInspectorSection] { session.inspectorSections(t) }

    /// Writes an attribute (nil removes); `initialViewController` goes on
    /// the document element.
    public func setAttribute(_ name: String, _ value: String?, of id: String) {
        session.setAttribute(name, value, of: id)
        refresh()
    }

    /// A pop-up or icon row set to a value (or its title).
    public func setChoice(_ row: IBInspectorRow, _ value: String) {
        session.setChoice(row, value)
        refresh()
    }

    /// A colour pop-up set to a colour by title.
    public func setColor(_ row: IBInspectorRow, _ title: String) {
        session.setColor(row, title)
        refresh()
    }

    public func addRuntimeAttribute(keyPath: String, type: String = "string", value: String = "") {
        guard let id = selected?.id else { return }
        apply { try $0.addingRuntimeAttribute(.init(keyPath: keyPath, type: type, value: value), to: id) }
    }

    public func removeRuntimeAttribute(_ keyPath: String) {
        guard let id = selected?.id else { return }
        apply { try $0.removingRuntimeAttribute(keyPath, of: id) }
    }

    /// The × on a connected outlet's capsule.
    public func disconnect(_ connectionID: String) { apply { try $0.removingConnection(connectionID) } }

    static func key(_ target: String, _ attr: String) -> NSUserInterfaceItemIdentifier { .init("ib:\(target)|\(attr)") }
    static func parse(_ id: NSUserInterfaceItemIdentifier?) -> (String, String)? {
        guard let r = id?.rawValue, r.hasPrefix("ib:"), let bar = r.firstIndex(of: "|") else { return nil }
        return (String(r[r.index(r.startIndex, offsetBy: 3)..<bar]), String(r[r.index(after: bar)...]))
    }

    /// The row of the shown inspectors bound to a target and attribute.
    func row(target: String, attribute: String) -> IBInspectorRow? {
        for t in InspectorTab.allCases {
            for sec in inspectorSections(t) {
                if let r = sec.rows.first(where: { $0.binding.map { $0.target == target && $0.attribute == attribute } ?? false }) { return r }
            }
        }
        return nil
    }

    /// Inspector metrics (`interface-builder.md` §Layout of the inspector).
    static let labelWidth: CGFloat = 77
    static let controlWidth: CGFloat = 171

    static func swatch(_ title: String) -> NSImage {
        let color: NSColor = switch title {
        case "System Blue Color": .systemBlue
        case "System Red Color": .systemRed
        case "System Green Color": .systemGreen
        case "System Orange Color": .systemOrange
        case "System Yellow Color": .systemYellow
        case "System Gray Color": .systemGray
        case "Label Color": .labelColor
        case "Secondary Label Color": .secondaryLabelColor
        case "System Background Color": .white
        case "System Grouped Background Color": NSColor(white: 0.95, alpha: 1)
        case "Black Color": .black
        case "Clear Color": .clear
        default: .white
        }
        return NSImage(size: NSSize(width: 22, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).fill()
            if title == "Default" {
                // No colour set: a slash across the swatch.
                NSColor.systemRed.setStroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: r.minX + 2, y: r.minY + 1))
                slash.line(to: NSPoint(x: r.maxX - 2, y: r.maxY - 1))
                slash.stroke()
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            return true
        }
    }

    func addSections(_ sections: [IBInspectorSection], to stack: NSStackView, skipping: Set<String> = []) {
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            l.lineBreakMode = .byTruncatingTail
            l.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
            return l
        }
        func line(_ l: String, _ v: NSView) {
            let r = NSStackView(views: [label(l), v])
            r.spacing = 6
            r.alignment = .centerY
            stack.addArrangedSubview(r)
        }
        func small(_ f: NSControl) {
            f.font = .systemFont(ofSize: 11)
            f.controlSize = .small
        }
        func field(_ value: String, _ ph: String, _ target: String, _ attr: String, width: CGFloat) -> NSTextField {
            let f = IBInspectorField(string: value)
            f.placeholderString = ph
            small(f)
            f.identifier = Self.key(target, attr)
            f.target = self
            f.action = #selector(sectionFieldChanged(_:))
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
            return f
        }
        for (i, sec) in sections.enumerated() {
            if i > 0 {
                let rule = NSBox()
                rule.boxType = .separator
                stack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalToConstant: Self.labelWidth + 6 + Self.controlWidth).isActive = true
            }
            if !sec.title.isEmpty {
                let h = NSTextField(labelWithString: sec.title)
                h.font = .boldSystemFont(ofSize: 11)
                stack.addArrangedSubview(h)
            }
            for row in sec.rows where !skipping.contains(row.label) {
                switch row {
                case .text(let l, let target, let attr, let value, let ph):
                    line(l, field(value, ph, target, attr, width: Self.controlWidth))
                case .toggle(let l, let target, let attr, let on, _, _):
                    let b = NSButton(checkboxWithTitle: l, target: self, action: #selector(sectionToggled(_:)))
                    b.state = on ? .on : .off
                    b.font = .systemFont(ofSize: 11)
                    b.identifier = Self.key(target, attr)
                    line("", b)
                case .check(let key, let title, let target, let attr, let on, _, _):
                    let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(sectionToggled(_:)))
                    b.state = on ? .on : .off
                    b.font = .systemFont(ofSize: 11)
                    b.identifier = Self.key(target, attr)
                    line(key, b)
                case .choice(let l, let target, let attr, let opts, let value):
                    let p = NSPopUpButton(frame: .zero, pullsDown: false)
                    p.addItems(withTitles: opts)
                    p.selectItem(withTitle: value)
                    p.controlSize = .small
                    p.identifier = Self.key(target, attr)
                    p.target = self
                    p.action = #selector(sectionChosen(_:))
                    line(l, p)
                case .popUp(let key, let target, let attr, let values, let titles, let value):
                    let p = NSPopUpButton(frame: .zero, pullsDown: false)
                    p.addItems(withTitles: titles)
                    if let i = values.firstIndex(of: value) { p.selectItem(at: i) } else { p.addItem(withTitle: value); p.selectItem(withTitle: value) }
                    small(p)
                    p.identifier = Self.key(target, attr)
                    p.target = self
                    p.action = #selector(popUpChosen(_:))
                    p.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
                    line(key, p)
                case .number(let key, let target, let attr, let value, let ph):
                    let f = field(value, ph, target, attr, width: 153)
                    let stepper = NSStepper()
                    stepper.controlSize = .small
                    stepper.minValue = -1_000_000
                    stepper.maxValue = 1_000_000
                    stepper.increment = 1
                    stepper.doubleValue = Double(value) ?? Double(ph) ?? 0
                    stepper.identifier = Self.key(target, attr)
                    stepper.target = self
                    stepper.action = #selector(numberStepped(_:))
                    let h = NSStackView(views: [f, stepper])
                    h.spacing = 2
                    line(key, h)
                case .numbers(let key, let fields):
                    let width = (Self.controlWidth - CGFloat(fields.count - 1) * 4) / CGFloat(fields.count)
                    let cols = fields.map { nf -> NSView in
                        let caption = NSTextField(labelWithString: nf.caption)
                        caption.font = .systemFont(ofSize: 9)
                        caption.textColor = .secondaryLabelColor
                        let v = NSStackView(views: [field(nf.value, nf.placeholder, nf.target, nf.attribute, width: width), caption])
                        v.orientation = .vertical
                        v.spacing = 1
                        return v
                    }
                    let h = NSStackView(views: cols)
                    h.spacing = 4
                    h.alignment = .top
                    line(key, h)
                case .combo(let key, let target, let attr, let value, let ph):
                    let c = NSComboBox(string: value)
                    c.placeholderString = ph
                    small(c)
                    c.identifier = Self.key(target, attr)
                    c.target = self
                    c.action = #selector(sectionFieldChanged(_:))
                    c.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
                    line(key, c)
                case .color(let key, let target, let colorKey, let value):
                    let p = NSPopUpButton(frame: .zero, pullsDown: false)
                    for choice in IBDocument.colorChoices {
                        p.addItem(withTitle: choice.title)
                        p.lastItem?.image = Self.swatch(choice.title)
                    }
                    if p.item(withTitle: value) == nil { p.addItem(withTitle: value) }
                    p.selectItem(withTitle: value)
                    small(p)
                    p.identifier = Self.key(target, "color." + colorKey)
                    p.target = self
                    p.action = #selector(colorChosen(_:))
                    p.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
                    line(key, p)
                case .icons(let key, let target, let attr, let values, let titles, let value):
                    let seg = NSSegmentedControl(labels: titles.map { String($0.prefix(1)) }, trackingMode: .selectOne, target: self, action: #selector(iconsChosen(_:)))
                    for (i, t) in titles.enumerated() {
                        seg.setToolTip(t, forSegment: i)
                        // Ycode's own glyph for the choice (IBLibraryObjects.swift), as a template.
                        if let g = IBIcon.choiceGlyph(attribute: attr, value: values[i], ink: .init(0, 0, 0)) {
                            let image = IBIconDrawing.image(g, size: 16)
                            image.isTemplate = true
                            seg.setLabel("", forSegment: i)
                            seg.setImage(image, forSegment: i)
                        }
                    }
                    seg.selectedSegment = values.firstIndex(of: value) ?? -1
                    seg.controlSize = .small
                    seg.identifier = Self.key(target, attr)
                    line(key, seg)
                case .subheading(let t):
                    let h = NSTextField(labelWithString: t)
                    h.font = .boldSystemFont(ofSize: 10)
                    h.textColor = .secondaryLabelColor
                    stack.addArrangedSubview(h)
                case .list(let key, let items):
                    let rows = items.map { s -> NSView in
                        let t = NSTextField(labelWithString: s)
                        t.font = .systemFont(ofSize: 11)
                        return t
                    }
                    let buttons = NSSegmentedControl(labels: ["+", "−"], trackingMode: .momentary, target: nil, action: nil)
                    buttons.controlSize = .small
                    buttons.isEnabled = false
                    let v = NSStackView(views: rows + [buttons])
                    v.orientation = .vertical
                    v.alignment = .leading
                    v.spacing = 2
                    line(key, v)
                case .info(let l, let v):
                    let t = NSTextField(labelWithString: v)
                    t.font = .systemFont(ofSize: 11)
                    line(l, t)
                case .runtimeAttribute(let k, let ty, let v):
                    let t = NSTextField(labelWithString: "\(k) | \(ty) | \(v)")
                    t.font = .systemFont(ofSize: 11)
                    let minus = NSButton(title: "−", target: self, action: #selector(runtimeRemove(_:)))
                    minus.identifier = .init(k)
                    minus.controlSize = .small
                    stack.addArrangedSubview(NSStackView(views: [t, minus]))
                case .constraint(let text, _):
                    let t = NSTextField(labelWithString: text)
                    t.font = .systemFont(ofSize: 11)
                    stack.addArrangedSubview(NSStackView(views: [t, NSButton(title: "Edit", target: nil, action: nil)]))
                case .frameValue(let l, let target, let component, let value):
                    let f = IBInspectorField(string: value)
                    f.font = .systemFont(ofSize: 11)
                    f.controlSize = .small
                    f.identifier = Self.key(target, "frame." + component)
                    f.target = self
                    f.action = #selector(frameFieldChanged(_:))
                    f.widthAnchor.constraint(equalToConstant: 70).isActive = true
                    let stepper = NSStepper()
                    stepper.controlSize = .small
                    stepper.minValue = -100_000
                    stepper.maxValue = 100_000
                    stepper.doubleValue = Double(value) ?? 0
                    stepper.identifier = Self.key(target, "frame." + component)
                    stepper.target = self
                    stepper.action = #selector(frameStepped(_:))
                    line(l, NSStackView(views: [f, stepper]))
                case .edgeToggle(let l, let target, let edge, let on):
                    let b = NSButton(checkboxWithTitle: l, target: self, action: #selector(edgeToggled(_:)))
                    b.state = on ? .on : .off
                    b.font = .systemFont(ofSize: 11)
                    b.identifier = Self.key(target, "edge." + edge)
                    line(edge == "top" ? "Extend Edges" : "", b)
                case .connection(let name, let other, let id):
                    var views: [NSView] = [NSTextField(labelWithString: name)]
                    if !other.isEmpty {
                        let cap = NSButton(title: "\(other)  ×", target: self, action: #selector(disconnectClicked(_:)))
                        cap.bezelStyle = .inline
                        cap.controlSize = .small
                        cap.identifier = id.map { .init($0) }
                        views.append(cap)
                    }
                    views.append(NSView())
                    views.append(NSImageView(image: NSImage(systemSymbolName: other.isEmpty ? "circle" : "circle.inset.filled", accessibilityDescription: "Connection") ?? NSImage()))
                    stack.addArrangedSubview(NSStackView(views: views))
                }
            }
            if sec.title == "User Defined Runtime Attributes" {
                let plus = NSButton(title: "+", target: self, action: #selector(runtimeAdd(_:)))
                plus.controlSize = .small
                stack.addArrangedSubview(plus)
            }
        }
    }

    @objc func sectionFieldChanged(_ f: NSTextField) { if let (t, a) = Self.parse(f.identifier) { setAttribute(a, f.stringValue, of: t) } }
    @objc func sectionChosen(_ p: NSPopUpButton) {
        guard let (t, a) = Self.parse(p.identifier), let v = p.titleOfSelectedItem else { return }
        setAttribute(a, p.indexOfSelectedItem == 0 ? nil : v, of: t)
    }
    @objc func popUpChosen(_ p: NSPopUpButton) {
        guard let (t, a) = Self.parse(p.identifier), let r = row(target: t, attribute: a), let title = p.titleOfSelectedItem else { return }
        setChoice(r, title)
    }
    @objc func colorChosen(_ p: NSPopUpButton) {
        guard let (t, a) = Self.parse(p.identifier), let r = row(target: t, attribute: a), let title = p.titleOfSelectedItem else { return }
        setColor(r, title)
    }
    @objc func iconsChosen(_ s: NSSegmentedControl) {
        guard let (t, a) = Self.parse(s.identifier), let r = row(target: t, attribute: a),
              case .icons(_, _, _, let values, _, _) = r, s.selectedSegment >= 0, s.selectedSegment < values.count else { return }
        setChoice(r, values[s.selectedSegment])
    }
    @objc func numberStepped(_ s: NSStepper) {
        guard let (t, a) = Self.parse(s.identifier) else { return }
        let v = s.doubleValue
        setAttribute(a, v == v.rounded() ? String(Int(v)) : String(v), of: t)
    }
    @objc func sectionToggled(_ b: NSButton) {
        guard let (t, a) = Self.parse(b.identifier), let r = row(target: t, attribute: a) else { return }
        session.setToggle(r, on: b.state == .on)
        refresh()
    }
    /// Writes one frame component (X, Y, Width, Height).
    public func setFrameComponent(_ component: String, _ value: CGFloat, of id: String) {
        apply { try $0.settingFrameComponent(component, value, of: id) }
    }

    public func setExtendedEdge(_ edge: String, _ on: Bool, of id: String) {
        apply { try $0.settingExtendedEdge(edge, on, of: id) }
    }

    @objc func frameFieldChanged(_ f: NSTextField) {
        guard let (t, a) = Self.parse(f.identifier), let v = Double(f.stringValue) else { return }
        setFrameComponent(String(a.dropFirst("frame.".count)), CGFloat(v), of: t)
    }
    @objc func frameStepped(_ s: NSStepper) {
        guard let (t, a) = Self.parse(s.identifier) else { return }
        setFrameComponent(String(a.dropFirst("frame.".count)), CGFloat(s.doubleValue), of: t)
    }
    @objc func edgeToggled(_ b: NSButton) {
        guard let (t, a) = Self.parse(b.identifier) else { return }
        setExtendedEdge(String(a.dropFirst("edge.".count)), b.state == .on, of: t)
    }
    @objc func runtimeAdd(_ sender: Any?) {
        let n = document.runtimeAttributes(of: selected?.id ?? "").count
        addRuntimeAttribute(keyPath: n == 0 ? "keyPath" : "keyPath\(n + 1)")
    }
    @objc func runtimeRemove(_ b: NSButton) { if let k = b.identifier?.rawValue { removeRuntimeAttribute(k) } }
    @objc func disconnectClicked(_ b: NSButton) { if let id = b.identifier?.rawValue { disconnect(id) } }
}
