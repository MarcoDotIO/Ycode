import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
import YcodePreviews

// The preview canvas (`specs/ide/previews.md` §Canvas, §Linux "The Linux
// canvas"; `PreviewCanvasShellModel` holds its state): a header with one
// tab per preview, the pictures (the selected preview in a device frame,
// every preview in Grid, its variants side by side), errors in place, and
// the bottom bar (device, Live, Selectable, Grid, Variants; zoom; canvas
// settings). Ycode's own drawing.

/// The source editor with the canvas beside it, or below it when the
/// editor area is narrow (Editor ▸ Layout).
struct PreviewEditorSplit<Content: View>: View {
    var canvas: PreviewCanvasShellModel
    @ViewBuilder var content: Content

    var body: some View {
        if canvas.isShown {
            GeometryReader { geo in
                if canvas.placement(forWidth: geo.size.width) == .below {
                    VSplitView {
                        content.frame(minHeight: 120, maxHeight: .infinity)
                        PreviewCanvasView(canvas: canvas).frame(minHeight: 200, idealHeight: geo.size.height / 2, maxHeight: .infinity)
                    }
                } else {
                    HSplitView {
                        content.frame(minWidth: 240, maxWidth: .infinity)
                        PreviewCanvasView(canvas: canvas).frame(minWidth: 260, idealWidth: max(260, geo.size.width * 0.45), maxWidth: .infinity)
                    }
                }
            }
        } else {
            content
        }
    }
}

struct PreviewCanvasView: View {
    var canvas: PreviewCanvasShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            PreviewCanvasHeader(canvas: canvas)
            Hairline(color: c.separator)
            PreviewCanvasBody(canvas: canvas)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline(color: c.separator)
            PreviewCanvasBottomBar(canvas: canvas)
        }
        .background(Self.background(scheme))
        .shellTarget("canvas")
    }

    /// The canvas's backdrop: a little darker than the editor.
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(.sRGB, red: 0.13, green: 0.13, blue: 0.14) : Color(.sRGB, red: 0.95, green: 0.95, blue: 0.96)
    }
}

/// One tab per preview: a spinner while updating, then an eye; the status at the end.
struct PreviewCanvasHeader: View {
    var canvas: PreviewCanvasShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 2) {
            if !canvas.isPaused {
                ForEach(Array(canvas.tabTitles.enumerated()), id: \.offset) { pair in
                    let selected = pair.offset == canvas.selectedIndex && !canvas.isGrid
                    Button { canvas.select(pair.offset) } label: {
                        HStack(spacing: 4) {
                            if canvas.isUpdating {
                                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                            } else if case .rendered = canvas.state {
                                Image(systemName: "eye").font(.system(size: 10)).foregroundStyle(c.secondaryLabel)
                            }
                            Text(verbatim: pair.element).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background { if selected { RoundedRectangle(cornerRadius: 5).fill(c.rowSelection) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(pair.element)
                    .shellTarget("canvas tab \(pair.offset)")
                }
            }
            Spacer(minLength: 8)
            if !canvas.statusText.isEmpty {
                Text(verbatim: canvas.statusText).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                    .shellTarget("canvas status")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
    }
}

/// The canvas's middle: paused, starting, the pictures, an error or the
/// needs-a-simulator card.
struct PreviewCanvasBody: View {
    var canvas: PreviewCanvasShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        if canvas.isPaused {
            VStack {
                HStack(spacing: 8) {
                    Text("Canvas paused").font(.system(size: 12, weight: .medium)).foregroundStyle(c.label)
                    Button { canvas.resume() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(c.label)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Resume")
                    .accessibilityLabel("Resume")
                    .shellTarget("canvas resume")
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: 30)
                .background { Capsule().fill(c.content) }
                .overlay { Capsule().stroke(c.capsuleStroke, lineWidth: 1) }
                .padding(.top, 12)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch canvas.state {
            case .empty(let message):
                Text(verbatim: message).font(.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .starting(let text):
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: text).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shellTarget("canvas starting")
            case .failed(let title, let message, let issues):
                PreviewErrorCard(canvas: canvas, title: title, message: message, issues: issues)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsSimulator(let title, let message):
                PreviewNeedsSimulatorCard(canvas: canvas, title: title, message: message)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .rendered:
                PreviewTilesView(canvas: canvas)
            }
        }
    }
}

/// The pictures, arranged in rows (Fit: every tile at the largest zoom up
/// to 100 %), with the update's banner over them when it failed.
struct PreviewTilesView: View {
    var canvas: PreviewCanvasShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        GeometryReader { geo in
            let layout = canvas.frames(area: geo.size)
            let width = max(layout.size.width, geo.size.width), height = max(layout.size.height, geo.size.height)
            let dx = max(0, (geo.size.width - layout.size.width) / 2), dy = max(0, (geo.size.height - layout.size.height) / 2)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: width, height: height)
                    ForEach(Array(canvas.tiles.enumerated()), id: \.element.id) { pair in
                        if pair.offset < layout.frames.count {
                            let f = layout.frames[pair.offset]
                            PreviewTileView(canvas: canvas, tile: pair.element, zoom: layout.zoom)
                                .frame(width: f.width, height: f.height + PreviewCanvasShellModel.captionHeight)
                                .offset(x: dx + f.minX, y: dy + f.minY - PreviewCanvasShellModel.captionHeight)
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }
            .overlay(alignment: .top) {
                if let b = canvas.banner { PreviewBanner(canvas: canvas, banner: b).padding(10) }
            }
        }
        .background(PreviewCanvasView.background(scheme))
        .foregroundStyle(c.label)
    }
}

/// One tile: its caption, then the picture (in the device's frame for a
/// preview without a layout trait).
struct PreviewTileView: View {
    /// The device bezel's width at 100 %.
    static let bezel: CGFloat = 9
    var canvas: PreviewCanvasShellModel
    var tile: PreviewCanvasShellModel.Tile
    var zoom: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let caption = tile.caption.isEmpty ? tile.title : tile.title + " — " + tile.caption
        let selected = canvas.isGrid && tile.preview == canvas.selectedIndex
        VStack(spacing: 0) {
            Text(verbatim: caption).font(ShellFonts.mini).foregroundStyle(c.secondaryLabel).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: PreviewCanvasShellModel.captionHeight)
            ZStack {
                if tile.isDevice {
                    // Ycode's own bezel: a dark band around the screen, its
                    // corners the device's screen corners plus the band.
                    let radius = CGFloat(canvas.device.panels[0].uprightCornerRadii.largest) * zoom
                    let bezel = max(3, Self.bezel * zoom)
                    RoundedRectangle(cornerRadius: radius + bezel).fill(Color(.sRGB, white: 0.08, opacity: 1))
                        .overlay { RoundedRectangle(cornerRadius: radius + bezel).stroke(Color(.sRGB, white: 0.32, opacity: 1), lineWidth: 1) }
                        .padding(-bezel)
                    picture.clipShape(RoundedRectangle(cornerRadius: radius))
                } else {
                    picture
                        .overlay { Rectangle().stroke(c.separator, lineWidth: 1) }
                }
                if selected {
                    RoundedRectangle(cornerRadius: tile.isDevice ? 8 : 3).stroke(c.accent, lineWidth: 2)
                        .padding(tile.isDevice ? -(max(3, Self.bezel * zoom) + 3) : -3)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { canvas.tileClicked(tile) }
        .help(canvas.mode == .selectable ? "Reveal \(tile.title) in the editor" : tile.title)
        .shellTarget("canvas tile \(tile.id)")
    }

    @ViewBuilder var picture: some View {
        if let url = tile.image, let crop = tile.crop, let screen = tile.screen, crop.width > 0 {
            // A picture of the whole device screen (UIKit previews): the tile's region of it.
            GeometryReader { geo in
                let k = geo.size.width / crop.width
                ZStack(alignment: .topLeading) {
                    FileImage(url: url)
                        .frame(width: screen.width * k, height: screen.height * k)
                        .offset(x: -crop.minX * k, y: -crop.minY * k)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
        } else if let url = tile.image {
            FileImage(url: url)   // AssetCatalogEditorView.swift
        } else {
            Rectangle().fill(tile.variant.colorScheme == "dark" ? Color.black : Color.white)
        }
    }
}

/// A failed update over the last picture: one line per error (a link
/// that opens the file at the line) or the host's message.
struct PreviewBanner: View {
    var canvas: PreviewCanvasShellModel
    var banner: PreviewCanvasShellModel.Banner
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
                Text(verbatim: banner.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
            }
            ForEach(Array(banner.issues.enumerated()), id: \.offset) { pair in
                Button { canvas.open(pair.element) } label: {
                    Text(verbatim: pair.element.description).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.white)
                        .underline(pair.element.file != nil).lineLimit(2).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(pair.element.file == nil)
                .help(pair.element.file == nil ? "" : "Open \(pair.element.file!.lastPathComponent) at line \(pair.element.line)")
                .shellTarget("canvas banner issue \(pair.offset)")
            }
            if let m = banner.message {
                Text(verbatim: m).font(.system(size: 11)).foregroundStyle(Color.white).lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 8).fill(c.error.opacity(0.92)) }
        .shellTarget("canvas banner")
    }
}

/// No picture yet and the update failed.
struct PreviewErrorCard: View {
    var canvas: PreviewCanvasShellModel
    var title: String
    var message: String
    var issues: [PreviewIssue]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.error)
                Text(verbatim: title).font(.system(size: 12, weight: .bold)).foregroundStyle(c.label)
            }
            if issues.isEmpty {
                Text(verbatim: message).font(.system(size: 11, design: .monospaced)).foregroundStyle(c.label).lineLimit(8)
            } else {
                ForEach(Array(issues.enumerated()), id: \.offset) { pair in
                    Button { canvas.open(pair.element) } label: {
                        Text(verbatim: pair.element.description).font(.system(size: 11, design: .monospaced)).foregroundStyle(c.label)
                            .underline(pair.element.file != nil).lineLimit(3).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(pair.element.file == nil)
                    .shellTarget("canvas error issue \(pair.offset)")
                }
            }
            HStack {
                Spacer()
                Button("Try Again") { canvas.update(reason: "retry") }.controlSize(.small).shellTarget("canvas try again")
            }
        }
        .padding(12)
        .frame(maxWidth: 380, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 8).fill(c.error.opacity(0.08)) }
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(c.error, lineWidth: 1) }
        .shellTarget("canvas error")
    }
}

/// UIKit previews without a simulator host: what to set up (not an error).
struct PreviewNeedsSimulatorCard: View {
    var canvas: PreviewCanvasShellModel
    var title: String
    var message: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 10) {
            Image(systemName: "iphone").font(.system(size: 30)).foregroundStyle(c.secondaryLabel)
            Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.label)
            Text(verbatim: message).font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Button("Check Again") { canvas.update(reason: "retry") }.controlSize(.small).shellTarget("canvas check again")
        }
        .padding(18)
        .shellTarget("canvas needs simulator")
    }
}

/// The bottom bar: device pop-up and the mode buttons at the left, the
/// zoom pop-up in the middle, Capture and Canvas Settings at the right.
struct PreviewCanvasBottomBar: View {
    var canvas: PreviewCanvasShellModel
    @State private var settingsShown = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Menu {
                    Button("Automatic – \(PreviewCanvasShellModel.automaticDevice.name)") { canvas.chooseDevice(nil) }
                    Divider()
                    ForEach(PreviewCanvasShellModel.devices, id: \.typeID) { d in Button(d.name) { canvas.chooseDevice(d.typeID) } }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "iphone").font(.system(size: 11))
                        Text(verbatim: canvas.deviceTitle).font(ShellFonts.small).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(c.label)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Preview Device")
                .shellTarget("canvas device")
                modeButton(.live, symbol: "play.circle", on: canvas.mode == .live, c)
                modeButton(.selectable, symbol: "text.magnifyingglass", on: canvas.mode == .selectable, c)
                modeButton(.grid, symbol: "square.grid.2x2", on: canvas.isGrid, c)
                Menu {
                    Button("Off") { canvas.setVariants(nil) }
                    ForEach(PreviewVariantKind.allCases, id: \.self) { k in Button(k.rawValue) { canvas.setVariants(k) } }
                } label: {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 12))
                        .foregroundStyle(canvas.variantKind != nil ? c.accent : c.secondaryLabel)
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(canvas.variantKind?.rawValue ?? "Variants")
                .shellTarget("canvas variants")
            }
            Spacer(minLength: 8)
            Menu {
                Button("Fit") { canvas.setZoom(nil) }
                ForEach(PreviewCanvasShellModel.zoomSteps, id: \.self) { z in Button("\(Int(z * 100))%") { canvas.setZoom(z) } }
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: canvas.zoomTitle).font(ShellFonts.small)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(c.label)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Zoom")
            .shellTarget("canvas zoom")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "camera.viewfinder").font(.system(size: 12)).foregroundStyle(c.secondaryLabel).opacity(0.35)
                    .frame(width: 22, height: 22)
                    .help(ShellText.notInBeta("Capture"))
                Button { settingsShown.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                        .foregroundStyle(canvas.settings.on.isEmpty ? c.secondaryLabel : c.accent)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Canvas Settings")
                .shellTarget("canvas settings")
                .popover(isPresented: $settingsShown, arrowEdge: .top) { PreviewCanvasSettingsView(canvas: canvas) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    func modeButton(_ m: PreviewCanvasMode, symbol: String, on: Bool, _ c: ShellColors) -> some View {
        Button { canvas.setMode(m) } label: {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(on ? c.accent : c.secondaryLabel)
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.title)
        .accessibilityLabel(m.title)
        .shellTarget("canvas mode \(m.title)")
    }
}

/// Canvas Settings: the switches, all off by default.
struct PreviewCanvasSettingsView: View {
    var canvas: PreviewCanvasShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(PreviewCanvasSettings.names, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { canvas.settings.on.contains(name) }, set: { canvas.setSetting(name, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .shellTarget("canvas setting \(name)")
            }
        }
        .padding(12)
    }
}
