#if os(Linux)
import Foundation
import SwiftUI
import YcodeDeviceModel
import YcodeDeviceViews
import YcodeIDEShell
import YcodeRemoteViewer

/// Device Hub's canvas on Linux (`device-hub.md` §4, §11.2, §15.2): the
/// selected device in Ycode's frame, centred above the control capsules
/// that float at the canvas's bottom; a running device's live screen
/// (`DeviceHubScreen`), touched with the pointer; a stopped one's picture
/// with Start in a glass capsule where the controls float; "No Selection"
/// and "No Devices" otherwise. The frame is drawn as the device window
/// draws it (`RemoteDeviceWindow`), from the shared geometry.
struct DeviceHubCanvas: View {
    var model: DeviceHubShellModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let dark = scheme == .dark
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(chromeHex: DeviceChromePalette.toolbar(dark: dark))
                content(size: geo.size, dark: dark)
                if let b = model.banner {
                    HStack { Spacer(minLength: 0); bannerView(b, dark: dark); Spacer(minLength: 0) }
                        .offset(y: 12)
                        .shellTarget("hub banner")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .shellTarget("hub canvas")
    }

    @ViewBuilder
    func content(size: CGSize, dark: Bool) -> some View {
        if let d = model.selected {
            if d.isRunning, let screen = model.screen(for: d) {
                DeviceHubLiveDevice(model: model, device: d, screen: screen, size: size, dark: dark, scale: Double(displayScale))
            } else {
                stopped(d, size: size, dark: dark)
            }
        } else {
            message(model.loaded && model.devices.isEmpty ? DeviceHubShellModel.noDevicesTitle : (model.loaded ? "No Selection" : "Loading…"),
                    detail: model.loaded && model.devices.isEmpty ? DeviceHubShellModel.noDevicesMessage : nil, size: size, dark: dark)
        }
    }

    func message(_ title: String, detail: String?, size: CGSize, dark: Bool) -> some View {
        VStack(spacing: 8) {
            Text(verbatim: title).font(.system(size: 15)).foregroundStyle(Color(chromeHex: DeviceChromePalette.secondaryLabel(dark: dark)))
            if let detail {
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(Color(chromeHex: DeviceChromePalette.secondaryLabel(dark: dark)))
                    .multilineTextAlignment(.center).frame(width: min(420, max(120, size.width - 48)))
            }
        }
        .frame(width: size.width, height: size.height)
        .shellTarget("hub canvas message")
    }

    /// A stopped device: its picture, and Start (or a spinner while it starts or stops).
    func stopped(_ d: DeviceHubDevice, size: CGSize, dark: Bool) -> some View {
        let geometry = DeviceFrameGeometry(spec: d.spec, bezels: true)
        let layout = ViewerLayout(geometry: geometry, mode: .fit, windowWidth: Double(size.width), windowHeight: Double(size.height),
                                  pixelDensity: Double(displayScale), hubFit: true, foldable: d.spec.isFoldable)
        let busy = model.busy.contains(d.id) || d.state == "booting" || d.state == "stopping"
        let capsuleWidth: CGFloat = busy ? 150 : 96
        let y = size.height - CGFloat(DeviceControlsLayout.bottomMargin + DeviceControlsLayout.height)
        return ZStack(alignment: .topLeading) {
            DeviceHubFrameDrawing(layout: layout, picture: nil, problem: busy ? nil : model.stopReasons[d.id])
                .frame(width: size.width, height: size.height)
            ZStack {
                Capsule(style: .continuous).fill(Color(chromeHex: DeviceChromePalette.capsule(dark: dark)))
                Capsule(style: .continuous).strokeBorder(Color(chromeHex: DeviceChromePalette.capsuleRim(dark: dark)), lineWidth: 0.5)
                if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: d.state == "stopping" ? "Shutting Down…" : "Starting…").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(chromeHex: DeviceChromePalette.secondaryLabel(dark: dark)))
                    }
                } else {
                    Button { model.start(d) } label: {
                        Text(verbatim: "Start").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(chromeHex: 0x007AFF))
                            .frame(width: capsuleWidth, height: CGFloat(DeviceControlsLayout.height))
                    }
                    .buttonStyle(.plain)
                    .shellTarget("hub start")
                }
            }
            .frame(width: capsuleWidth, height: CGFloat(DeviceControlsLayout.height))
            .offset(x: ((size.width - capsuleWidth) / 2).rounded(), y: y)
        }
    }

    func bannerView(_ text: String, dark: Bool) -> some View {
        Text(verbatim: text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            .foregroundStyle(Color(chromeHex: DeviceChromePalette.label(dark: dark)))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(Color(chromeHex: DeviceChromePalette.capsule(dark: dark))))
            .overlay(Capsule(style: .continuous).strokeBorder(Color(chromeHex: DeviceChromePalette.capsuleRim(dark: dark)), lineWidth: 0.5))
    }
}

/// A running device: the live screen in its frame, touched with the
/// pointer, and the control capsules under it.
struct DeviceHubLiveDevice: View {
    var model: DeviceHubShellModel
    var device: DeviceHubDevice
    var screen: DeviceHubScreen
    var size: CGSize
    var dark: Bool
    var scale: Double
    @State private var touching = false

    var body: some View {
        // Read here so a new picture redraws the canvas.
        let picture = screen.picture
        let layout = screen.layout
        ZStack(alignment: .topLeading) {
            DeviceHubFrameDrawing(layout: layout, picture: picture, problem: screen.picture == nil ? screen.problem : nil)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        if !touching {
                            touching = true
                            screen.pointerDown(x: Double(v.startLocation.x), y: Double(v.startLocation.y))
                        }
                        screen.pointerMoved(x: Double(v.location.x), y: Double(v.location.y))
                    }
                    .onEnded { v in
                        // A click without a change still touches down first.
                        if !touching { screen.pointerDown(x: Double(v.startLocation.x), y: Double(v.startLocation.y)) }
                        touching = false
                        screen.pointerUp(x: Double(v.location.x), y: Double(v.location.y))
                    })
                .shellTarget("hub screen")
            DeviceHubControls(model: model, device: device, live: screen.isLive, canRotate: screen.canRotate, size: size, dark: dark)
            if screen.isTakenOver {
                takenOver
                    .offset(x: ((size.width - 300) / 2).rounded(), y: (size.height / 2 - 20).rounded())
            }
        }
        .onAppear { screen.setCanvas(width: Double(size.width), height: Double(size.height), pixelDensity: scale) }
        .onChange(of: size) { _, s in screen.setCanvas(width: Double(s.width), height: Double(s.height), pixelDensity: scale) }
    }

    /// Another viewer (a run's device window) has the display.
    var takenOver: some View {
        HStack(spacing: 10) {
            Text(verbatim: "Another viewer has this device").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(chromeHex: DeviceChromePalette.label(dark: dark)))
            Button { screen.takeBack() } label: {
                Text(verbatim: "Take Back").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(chromeHex: 0x007AFF))
            }
            .buttonStyle(.plain)
            .shellTarget("hub take back")
        }
        .padding(.horizontal, 16)
        .frame(width: 300, height: 40)
        .background(Capsule(style: .continuous).fill(Color(chromeHex: DeviceChromePalette.capsule(dark: dark))))
    }
}

/// The control capsules (`DeviceControlsLayout`, shared with the macOS hub
/// and the device window): [Home · Screenshot · Record] [Rotate].
struct DeviceHubControls: View {
    var model: DeviceHubShellModel
    var device: DeviceHubDevice
    var live: Bool
    var canRotate: Bool
    var size: CGSize
    var dark: Bool

    var groups: [[DeviceCommand]] {
        let spec = device.spec
        // The poses of a foldable are the macOS hub's (fold over the stream: beta 9).
        return DeviceControlsLayout.groups(.init(showsHome: spec.family != .watch, rotates: spec.rotates, foldable: false,
                                                 spatial: spec.family == .vision, watch: spec.family == .watch))
    }

    var body: some View {
        let g = groups
        let capsules = DeviceControlsLayout.capsuleRects(g, canvasWidth: Double(size.width), canvasHeight: Double(size.height))
        let controls = DeviceControlsLayout.controlRects(g, canvasWidth: Double(size.width), canvasHeight: Double(size.height))
        ZStack(alignment: .topLeading) {
            ForEach(Array(capsules.enumerated()), id: \.offset) { pair in
                ZStack {
                    Capsule(style: .continuous).fill(Color(chromeHex: DeviceChromePalette.capsule(dark: dark)))
                    Capsule(style: .continuous).strokeBorder(Color(chromeHex: DeviceChromePalette.capsuleRim(dark: dark)), lineWidth: 0.5)
                }
                .frame(width: pair.element.width, height: pair.element.height)
                .offset(x: pair.element.minX, y: pair.element.minY)
            }
            ForEach(Array(controls.enumerated()), id: \.offset) { pair in
                let (c, r) = pair.element
                let enabled = isEnabled(c)
                Button { model.perform(c) } label: {
                    DeviceHubControlGlyph(command: c, color: Color(chromeHex: DeviceChromePalette.glyph(dark: dark)).opacity(enabled ? 1 : 0.35))
                        .frame(width: r.width, height: r.height)
                }
                .buttonStyle(.plain)
                .help(help(c))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .shellTarget("hub control \(c.rawValue)")
            }
        }
    }

    func isEnabled(_ c: DeviceCommand) -> Bool {
        switch c {
        case .recordScreen: false
        case .rotateLeft, .rotateRight: live && canRotate
        default: live
        }
    }

    func help(_ c: DeviceCommand) -> String {
        let name: String
        switch c {
        case .home: name = "Home"
        case .screenshot: name = "Screenshot"
        case .recordScreen: return DeviceControlsLayout.unavailableHelp("Record Screen", reason: DeviceHubShellModel.recordUnavailable)
        case .rotateLeft: name = "Rotate (Alt-click to rotate right)"
        default: name = c.title
        }
        if !live { return DeviceControlsLayout.unavailableHelp(name, reason: DeviceHubShellModel.startFirst) }
        if (c == .rotateLeft || c == .rotateRight) && !canRotate { return DeviceControlsLayout.unavailableHelp(name, reason: DeviceHubShellModel.noRotation) }
        return name
    }
}

/// A control's glyph: Ycode's drawings (Home, Rotate; DeviceControlGlyphs,
/// as the macOS hub), OpenViews' camera, a dot in a ring for Record.
struct DeviceHubControlGlyph: View {
    var command: DeviceCommand
    var color: Color

    var body: some View {
        switch command {
        case .screenshot:
            Image(systemName: "camera.viewfinder").font(.system(size: 14)).foregroundStyle(color)
        default:
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                switch command {
                case .home: ChromeGlyph.drawShared(DeviceControlGlyphs.home, in: &ctx, centre: c, scale: 1, color: color)
                case .rotateLeft, .rotateRight: ChromeGlyph.drawShared(DeviceControlGlyphs.rotate, in: &ctx, centre: c, scale: 1, color: color)
                case .recordScreen:
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(color), lineWidth: 1.4)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)), with: .color(color))
                case .digitalCrown, .sideButton:
                    ctx.stroke(Path(roundedRect: CGRect(x: c.x - 3, y: c.y - 7, width: 6, height: 14), cornerRadius: 2), with: .color(color), lineWidth: 1.4)
                default:
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(color), lineWidth: 1.4)
                }
            }
        }
    }
}

/// The device's frame and screen in the canvas, from the shared geometry
/// laid out by `ViewerLayout` (the device window's drawing, in OpenViews).
struct DeviceHubFrameDrawing: View {
    var layout: ViewerLayout
    var picture: DeviceScreenPicture?
    var problem: String?

    static func color(_ hex: UInt32) -> Color { Color(chromeHex: hex) }

    static func path(_ pts: [(Double, Double)]) -> Path {
        var p = Path()
        for (i, q) in pts.enumerated() {
            if i == 0 { p.move(to: CGPoint(x: q.0, y: q.1)) } else { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        }
        p.closeSubpath()
        return p
    }

    var body: some View {
        let image = picture.flatMap { Image(rgbaPixels: $0.rgba, width: $0.width, height: $0.height, scale: CGFloat(layout.pixelDensity)) }
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                let l = layout, g = l.geometry
                typealias P = DeviceFrameGeometry.Palette
                let poly = { (r: CGRect, radii: CornerRadii, steps: Int) in Self.path(ViewerLayout.roundedPolygon(l.window(r), radii: radii, scale: l.scale, steps: steps)) }
                if !g.bandRings.isEmpty {
                    if let step = g.hingeStep { ctx.fill(poly(step, g.hingeStepRadii, 10), with: .color(Self.color(P.step))) }
                    for b in g.buttons where !b.flush { ctx.fill(poly(b.rect, CornerRadii(all: 1.5), 3), with: .color(Self.color(P.button))) }
                    for ring in g.bandRingRects { ctx.fill(poly(ring.rect, ring.radii, 10), with: .color(Self.color(ring.color))) }
                    for b in g.buttons where b.flush {
                        let r = l.window(b.rect)
                        ctx.fill(Path(CGRect(x: r.x, y: r.y, width: r.width, height: r.height)), with: .color(Self.color(P.flushButton)))
                    }
                } else if g.body != g.screen {
                    for b in g.buttons {
                        let r = l.window(b.rect)
                        ctx.fill(Path(CGRect(x: r.x, y: r.y, width: r.width, height: r.height)), with: .color(Color(chromeHex: 0x45464B)))
                    }
                    ctx.fill(poly(g.body, g.bodyRadii, 10), with: .color(Color(chromeHex: 0x4C4C54)))
                    let body = l.window(g.body)
                    let inner = ViewerRect(x: body.x + 1.5, y: body.y + 1.5, width: body.width - 3, height: body.height - 3)
                    ctx.fill(Self.path(ViewerLayout.roundedPolygon(inner, radii: g.bodyRadii.grown(by: -1.5 / max(l.scale, 0.01)), scale: l.scale)),
                             with: .color(Color(chromeHex: 0x0F0F12)))
                }
                let screenPath = Self.path(ViewerLayout.roundedPolygon(l.screen, radii: g.screenRadii, scale: l.scale, steps: 12))
                ctx.fill(screenPath, with: .color(.black))
                if let image {
                    var inner = ctx
                    inner.clip(to: screenPath)
                    let s = l.screen
                    inner.draw(image, in: CGRect(x: s.x, y: s.y, width: s.width, height: s.height))
                }
                if let shade = g.shadedArea {
                    let r = l.window(shade)
                    ctx.fill(Path(CGRect(x: r.x, y: r.y, width: r.width, height: r.height)), with: .color(Color.black.opacity(0.35)))
                }
            }
            if let problem {
                let s = layout.screen
                Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(width: max(10, s.width - 24))
                    .offset(x: s.x + 12, y: s.y + s.height / 2 - 8)
                    .shellTarget("hub screen problem")
            }
        }
    }
}
#endif
