import AppKit

/// The §13 inspector sections (reference-ui-4.md) rendered as controls.
/// Every edit writes the named XML attribute (see IBInspectorModel.swift).
extension InterfaceBuilderController {
    public func inspectorSections(_ t: InspectorTab) -> [IBInspectorSection] {
        guard let o = selected else { return [] }
        switch t {
        case .identity: return document.identitySections(o.id)
        case .attributes: return document.attributesSections(o.id)
        case .size: return document.sizeSections(o.id)
        case .connections: return document.connectionsSections(o.id)
        }
    }

    /// Writes an attribute (nil removes); `initialViewController` goes on
    /// the document element.
    public func setAttribute(_ name: String, _ value: String?, of id: String) {
        if name == "initialViewController" { apply { try $0.settingInitial(value) }; return }
        apply { try $0.settingAttribute(name, value.flatMap { $0.isEmpty ? nil : $0 }, of: id) }
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

    func addSections(_ sections: [IBInspectorSection], to stack: NSStackView, skipping: Set<String> = []) {
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 90).isActive = true
            return l
        }
        func line(_ l: String, _ v: NSView) {
            let r = NSStackView(views: [label(l), v])
            r.alignment = .firstBaseline
            stack.addArrangedSubview(r)
        }
        for sec in sections {
            if !sec.title.isEmpty {
                let h = NSTextField(labelWithString: sec.title)
                h.font = .boldSystemFont(ofSize: 11)
                stack.addArrangedSubview(h)
            }
            for row in sec.rows where !skipping.contains(row.label) {
                switch row {
                case .text(let l, let target, let attr, let value, let ph):
                    let f = IBInspectorField(string: value)
                    f.placeholderString = ph
                    f.font = .systemFont(ofSize: 11)
                    f.controlSize = .small
                    f.identifier = Self.key(target, attr)
                    f.target = self
                    f.action = #selector(sectionFieldChanged(_:))
                    f.widthAnchor.constraint(equalToConstant: 140).isActive = true
                    line(l, f)
                case .toggle(let l, let target, let attr, let on, _, _):
                    let b = NSButton(checkboxWithTitle: l, target: self, action: #selector(sectionToggled(_:)))
                    b.state = on ? .on : .off
                    b.font = .systemFont(ofSize: 11)
                    b.identifier = Self.key(target, attr)
                    line("", b)
                case .choice(let l, let target, let attr, let opts, let value):
                    let p = NSPopUpButton(frame: .zero, pullsDown: false)
                    p.addItems(withTitles: opts)
                    p.selectItem(withTitle: value)
                    p.controlSize = .small
                    p.identifier = Self.key(target, attr)
                    p.target = self
                    p.action = #selector(sectionChosen(_:))
                    line(l, p)
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
                    line("", b)
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
    @objc func sectionToggled(_ b: NSButton) {
        guard let (t, a) = Self.parse(b.identifier) else { return }
        for sec in inspectorSections(.identity) + inspectorSections(.attributes) + inspectorSections(.size) {
            for case .toggle(_, let tt, let aa, _, let onV, let offV) in sec.rows where tt == t && aa == a {
                setAttribute(a, b.state == .on ? onV : offV, of: t)
                return
            }
        }
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
