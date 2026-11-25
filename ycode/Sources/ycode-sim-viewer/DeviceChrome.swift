// The Linux device window's toolbar and Settings inspector
// (cross-platform-parity.md §13; device-hub.md §3, §6, §11.3): OpenViews
// views laid out by `DeviceWindowFrame` and `DeviceInspectorContent`, so the
// window matches the macOS device window, rendered to pixels for the SDL
// window (`RemoteDeviceWindow.chromeRenderer`). The SDL window keeps the
// device's live picture and the control capsules; OpenViews has no view for
// a live picture yet.

#if os(Linux) && canImport(SwiftUI) && canImport(OVRender)
import Foundation
import OVRender
import SwiftUI
import YcodeDeviceModel
import YcodeDeviceViews
import YcodeRemoteViewer

@MainActor
enum DeviceChromeRenderer {
    /// A part of the chrome as straight RGBA pixels at the window's density.
    static func render(_ r: DeviceChromeRequest, _ part: DeviceChromeRequest.Part) -> DeviceChromeImage? {
        let rect = part == .toolbar ? r.frame.toolbar : (r.frame.inspector ?? ViewerRect(x: 0, y: 0, width: 0, height: 0))
        guard rect.width > 0, rect.height > 0 else { return nil }
        let size = CGSize(width: rect.width, height: rect.height)
        let content = Group {
            if part == .toolbar { DeviceToolbarView(request: r) } else { DeviceInspectorView(request: r, size: size) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, r.dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = CGFloat(max(1, r.pixelDensity))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = true
        guard let png = renderer.pngData, let px = SoftwareRasterizer.decode(png, mime: "png") else { return nil }
        // The parts are opaque: premultiplied and straight pixels agree.
        return DeviceChromeImage(width: px.size.width, height: px.size.height, rgba: px.rgba)
    }
}

/// The toolbar band: the device's name and OS, then the capsules.
struct DeviceToolbarView: View {
    let request: DeviceChromeRequest
    typealias P = DeviceChromePalette

    var body: some View {
        let d = request.dark, f = request.frame
        ZStack(alignment: .topLeading) {
            Color(chromeHex: P.toolbar(dark: d))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: request.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(chromeHex: P.label(dark: d)))
                    .lineLimit(1)
                if !request.subtitle.isEmpty {
                    Text(verbatim: request.subtitle).font(.system(size: 11)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: d)))
                        .lineLimit(1)
                }
            }
            .frame(width: CGFloat(f.titleWidth), height: CGFloat(DeviceWindowFrame.toolbarHeight), alignment: .leading)
            .offset(x: CGFloat(DeviceWindowFrame.titleX))
            ForEach(Array(f.capsules.enumerated()), id: \.offset) { pair in
                capsule(pair.element.items, dark: d)
                    .frame(width: CGFloat(pair.element.rect.width), height: CGFloat(pair.element.rect.height))
                    .offset(x: CGFloat(pair.element.rect.x), y: CGFloat(pair.element.rect.y))
            }
            // Separators inside the segmented capsules (§15.5), as AppKit's
            // segmented toolbar groups draw them.
            ForEach(Array(f.separators(selected: request.selectedItems).enumerated()), id: \.offset) { pair in
                Rectangle().fill(Color(chromeHex: DeviceWindowFrame.separatorColor(dark: d)))
                    .frame(width: 1, height: CGFloat(DeviceWindowFrame.separatorHeight))
                    .offset(x: CGFloat(pair.element) - 0.5,
                            y: CGFloat((DeviceWindowFrame.toolbarHeight - DeviceWindowFrame.separatorHeight) / 2))
            }
        }
        .frame(width: CGFloat(f.width), height: CGFloat(DeviceWindowFrame.toolbarHeight), alignment: .topLeading)
    }

    func capsule(_ items: [DeviceWindowFrame.Item], dark d: Bool) -> some View {
        let selected = request.selectedItems
        return ZStack {
            Capsule(style: .continuous).fill(Color(chromeHex: P.capsule(dark: d)))
            Capsule(style: .continuous).strokeBorder(Color(chromeHex: P.capsuleRim(dark: d)), lineWidth: 0.5)
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    let item = pair.element
                    let on = selected.contains(item), disabled = DeviceChromeRequest.disabledItems.contains(item)
                    ZStack {
                        if on {
                            Capsule(style: .continuous).fill(Color(chromeHex: P.selected(dark: d)))
                                .padding(.vertical, 4)
                                .padding(.horizontal, 2)
                        }
                        if item == .infoTab {
                            // A plain "i" (§11.4).
                            Text(verbatim: "i").font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color(chromeHex: P.glyph(dark: d)))
                        } else {
                            ChromeGlyph(name: item.symbol, color: Color(chromeHex: P.glyph(dark: d)).opacity(disabled ? 0.35 : 1), size: 16)
                        }
                    }
                    .frame(width: CGFloat(DeviceWindowFrame.segmentWidth), height: CGFloat(DeviceWindowFrame.capsuleHeight))
                }
            }
        }
    }
}

/// The Settings inspector: the cards and the note under them.
struct DeviceInspectorView: View {
    let request: DeviceChromeRequest
    let size: CGSize
    typealias P = DeviceChromePalette
    typealias C = DeviceInspectorContent

    var body: some View {
        let d = request.dark, content = request.inspector
        let rects = content.cardRects(width: Double(size.width))
        ZStack(alignment: .topLeading) {
            Color(chromeHex: P.inspector(dark: d))
            ForEach(Array(zip(content.cards, rects).enumerated()), id: \.offset) { pair in
                card(pair.element.0, dark: d)
                    .frame(width: CGFloat(pair.element.1.width), height: CGFloat(pair.element.1.height))
                    .offset(x: CGFloat(pair.element.1.x), y: CGFloat(pair.element.1.y))
            }
            if let note = content.note {
                let top = (rects.last.map { $0.y + $0.height + C.cardGap } ?? C.cardTop + 4)
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(Color(chromeHex: P.secondaryLabel(dark: d)))
                    .multilineTextAlignment(rects.isEmpty ? .center : .leading)
                    .frame(width: size.width - CGFloat(2 * C.cardInset) - 8, alignment: rects.isEmpty ? .center : .leading)
                    .offset(x: CGFloat(C.cardInset) + 4, y: CGFloat(top))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    func card(_ rows: [C.Row], dark d: Bool) -> some View {
        let sep = P.separator(dark: d)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: CGFloat(C.cardRadius), style: .continuous).fill(Color(chromeHex: P.card(dark: d)))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 {
                        Rectangle().fill(Color(chromeHex: sep.hex, opacity: sep.alpha)).frame(height: CGFloat(C.separator))
                            .padding(.leading, CGFloat(C.labelX))
                    }
                    row(pair.element, dark: d)
                }
            }
        }
    }

    func row(_ r: C.Row, dark d: Bool) -> some View {
        let ink = Color(chromeHex: P.label(dark: d)).opacity(r.enabled ? 1 : 0.45)
        return ZStack(alignment: .leading) {
            ChromeGlyph(name: r.symbol, color: ink, size: 13)
                .offset(x: CGFloat(C.symbolX))
            Text(verbatim: r.label).font(.system(size: 13)).foregroundStyle(ink).lineLimit(1)
                .offset(x: CGFloat(C.labelX))
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                control(r.control, dark: d).opacity(r.enabled ? 1 : 0.45)
            }
            .padding(.trailing, CGFloat(C.trailing))
        }
        .frame(height: CGFloat(C.rowHeight))
    }

    @ViewBuilder
    func control(_ c: C.Control, dark d: Bool) -> some View {
        let ink = Color(chromeHex: P.label(dark: d)), secondary = Color(chromeHex: P.secondaryLabel(dark: d))
        switch c {
        case .popUp(let value):
            HStack(spacing: 5) {
                Text(verbatim: value).font(.system(size: 13)).foregroundStyle(secondary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(secondary)
            }
        case .slider(let v):
            ZStack(alignment: .leading) {
                Capsule().fill(secondary.opacity(0.35)).frame(width: 108, height: 4)
                Capsule().fill(Color(chromeHex: 0x007AFF)).frame(width: 108 * CGFloat(v), height: 4)
                Circle().fill(Color.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
                    .offset(x: 108 * CGFloat(v) - 8)
            }
            .frame(width: 108, height: 16)
        case .toggle(let on):
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Color(chromeHex: 0x34C759) : secondary.opacity(0.35)).frame(width: 32, height: 18)
                Circle().fill(Color.white).frame(width: 15, height: 15).padding(.horizontal, 1.5)
            }
            .frame(width: 32, height: 18)
            .foregroundStyle(ink)
        }
    }
}

#endif
