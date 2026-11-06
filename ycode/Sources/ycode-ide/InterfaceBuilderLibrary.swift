import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// MARK: Library

/// The Library over the Interface Builder editor (`library.md` §Reference
/// Objects library ▸ Panel), at the measured sizes: 681 × 504 with the
/// details shown, 272 × 504 without; the filter icon and search field, the
/// icon/list and details toggles; the Objects, Image, Color and Symbols
/// tabs; the flat list (48-point rows, or four 34-point icons to a row);
/// and the detail area (name, `Class: summary`, description). Double-click
/// or Return inserts the selected object; Escape closes the panel.
struct IBLibraryPanel: View {
    var model: InterfaceBuilderShellModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var hasKeyboard: Bool

    static let size = CGSize(width: 681, height: 504)
    static let narrowWidth: CGFloat = 272
    static let listWidth: CGFloat = 272
    static let listTop: CGFloat = 94

    var width: CGFloat { model.libraryShowsDetails ? Self.size.width : Self.narrowWidth }

    var body: some View {
        let c = ShellColors(scheme)
        ZStack(alignment: .topLeading) {
            header(c)
            tabs(c).padding(.top, 61).frame(width: width)
            list(c).frame(width: Self.listWidth, height: Self.size.height - Self.listTop).padding(.top, Self.listTop)
            if model.libraryShowsDetails {
                Hairline(color: c.separator, vertical: true).frame(height: Self.size.height - Self.listTop).padding(.top, Self.listTop).padding(.leading, Self.listWidth)
                detail(c).padding(.leading, 278).padding(.top, 103)
            }
        }
        .frame(width: width, height: Self.size.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.content)
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .onAppear { hasKeyboard = true }
        .shellTarget("ib library")
    }

    func header(_ c: ShellColors) -> some View {
        let field: CGFloat = model.libraryShowsDetails ? 557 : 148
        let toggles = model.libraryShowsDetails ? CGFloat(616) : Self.narrowWidth - 65
        return ZStack(alignment: .topLeading) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 18)).foregroundStyle(c.secondaryLabel)
                .frame(width: 34, height: 34).padding(.leading, 15).padding(.top, 11)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                InlineField(text: model.libraryFilter, placeholder: "Filter") { model.libraryFilter = $0 }
                    .shellTarget("ib library filter")
            }
            .padding(.horizontal, 8)
            .frame(width: field, height: 36)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.fieldFill)
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
            }
            .padding(.leading, 61).padding(.top, 10)
            HStack(spacing: 10) {
                toggle(model.libraryIsIconView ? "list.bullet" : "square.grid.2x2",
                       model.libraryIsIconView ? "Switch to List View" : "Switch to Icon View", c) { model.libraryIsIconView.toggle() }
                toggle("sidebar.right", model.libraryShowsDetails ? "Hide Details" : "Show Details", c) { model.libraryShowsDetails.toggle() }
            }
            .padding(.leading, toggles).padding(.top, 19)
        }
    }

    func toggle(_ symbol: String, _ help: String, _ c: ShellColors, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(c.toolbarIcon).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .shellTarget("ib library \(help)")
    }

    func tabs(_ c: ShellColors) -> some View {
        HStack(spacing: 4) {
            ForEach(IBLibraryTab.allCases, id: \.self) { t in
                Button { model.libraryTab = t } label: {
                    Image(systemName: t.symbol).font(.system(size: 13)).foregroundStyle(model.libraryTab == t ? c.accent : c.toolbarIcon)
                        .frame(width: 42, height: 25)
                        .background { if model.libraryTab == t { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.selectorPill) } }
                }
                .buttonStyle(.plain)
                .help(t.title)
                .accessibilityLabel(t.title)
                .shellTarget("ib library tab \(t.title)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func list(_ c: ShellColors) -> some View {
        switch model.libraryTab {
        case .objects: objects(c)
        case .color:
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(IBDocument.colorChoices.dropFirst().map(\.title), id: \.self) { name in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Self.swatch(name)).frame(width: 34, height: 34)
                                .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                            Text(verbatim: name).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 17).frame(height: 48)
                    }
                }
            }
        case .symbols:
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(LibraryContent.symbolNames.filter { model.libraryFilter.isEmpty || $0.contains(model.libraryFilter.lowercased()) }, id: \.self) { name in
                        HStack(spacing: 8) {
                            Image(systemName: name).font(.system(size: 16)).foregroundStyle(c.label).frame(width: 34, height: 34)
                            Text(verbatim: name).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 17).frame(height: 36)
                    }
                }
            }
        case .image:
            Text(verbatim: "No Images").font(ShellFonts.small).foregroundStyle(c.secondaryLabel).frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    /// The colour a Library colour row shows (light appearance).
    static func swatch(_ title: String) -> Color {
        switch title {
        case "System Blue Color": Color(red: 0, green: 0.48, blue: 1)
        case "System Red Color": Color(red: 1, green: 0.23, blue: 0.19)
        case "System Green Color": Color(red: 0.2, green: 0.78, blue: 0.35)
        case "System Orange Color": Color(red: 1, green: 0.58, blue: 0)
        case "System Yellow Color": Color(red: 1, green: 0.8, blue: 0)
        case "System Gray Color": Color(red: 0.56, green: 0.56, blue: 0.58)
        case "Label Color", "Black Color": Color(white: 0)
        case "Secondary Label Color": Color(red: 0.24, green: 0.24, blue: 0.26).opacity(0.6)
        case "System Grouped Background Color": Color(red: 0.95, green: 0.95, blue: 0.97)
        case "Clear Color": Color.clear
        default: Color(white: 1)
        }
    }

    func objects(_ c: ShellColors) -> some View {
        let list = model.libraryObjects
        return ScrollView {
            if model.libraryIsIconView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stride(from: 0, to: list.count, by: 4)), id: \.self) { start in
                        HStack(spacing: 0) {
                            ForEach(list[start..<min(start + 4, list.count)], id: \.self) { o in cell(o, c) }
                        }
                    }
                }
                .padding(.leading, 0)
            } else {
                VStack(spacing: 0) {
                    ForEach(list, id: \.self) { o in row(o, c) }
                }
            }
        }
        .focusable()
        .focused($hasKeyboard)
        .onKeyPress(.downArrow) { model.moveLibrarySelection(model.libraryIsIconView ? 4 : 1); return .handled }
        .onKeyPress(.upArrow) { model.moveLibrarySelection(model.libraryIsIconView ? -4 : -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveLibrarySelection(1); return .handled }
        .onKeyPress(.leftArrow) { model.moveLibrarySelection(-1); return .handled }
        .onKeyPress(.return) { model.insertFromLibrary(); return .handled }
        .onKeyPress(.escape) { model.isLibraryShown = false; return .handled }
    }

    func row(_ o: IBDocument.NewObject, _ c: ShellColors) -> some View {
        let on = model.librarySelection == o
        return ZStack(alignment: .topLeading) {
            IBIconView(icon: o.icon).frame(width: 34, height: 34).padding(.leading, 17).padding(.top, 7)
            Text(verbatim: o.rawValue).font(Font.system(size: 13)).foregroundStyle(on ? Color.white : c.label).lineLimit(1)
                .frame(width: 180, height: 18, alignment: .leading).padding(.leading, 59).padding(.top, 15)
        }
        .frame(width: 255, height: 48, alignment: .topLeading)
        .background { if on { Rectangle().fill(c.accent) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.insertFromLibrary(o) }
        .onTapGesture { model.librarySelection = o; hasKeyboard = true }
        .accessibilityLabel(o.rawValue)
        .shellTarget("ib library \(o.rawValue)")
    }

    func cell(_ o: IBDocument.NewObject, _ c: ShellColors) -> some View {
        let on = model.librarySelection == o
        return IBIconView(icon: o.icon).frame(width: 34, height: 34).padding(.top, 7)
            .frame(width: 64, height: 48, alignment: .top)
            .background { if on { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.rowSelection) } }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.insertFromLibrary(o) }
            .onTapGesture { model.librarySelection = o; hasKeyboard = true }
            .help(o.rawValue)
            .accessibilityLabel(o.rawValue)
            .shellTarget("ib library \(o.rawValue)")
    }

    func detail(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let p = model.libraryDetailParts {
                Text(verbatim: p.name).font(Font.system(size: 15, weight: .semibold)).foregroundStyle(c.label).lineLimit(1)
                    .frame(width: 390, height: 21, alignment: .leading).padding(.leading, 4)
                Text(verbatim: p.subtitle).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                    .frame(width: 390, height: 16, alignment: .leading).padding(.leading, 4).padding(.top, -1)
                ScrollView {
                    Text(verbatim: p.description).font(Font.system(size: 12)).foregroundStyle(c.label)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: 381, height: 339)
                .padding(.top, 13)
                .shellTarget("ib library detail")
            }
        }
    }
}

/// An `IBIcon` (shapes in a 16 × 16 box, `IBLibraryObjects.swift`) drawn
/// at any size: the Library's 34-point icons and the outline's 16-point ones.
struct IBIconView: View {
    var icon: IBIcon

    static func color(_ p: IBIcon.Paint) -> Color { Color(red: p.r, green: p.g, blue: p.b).opacity(p.a) }

    var body: some View {
        let shapes = icon.shapes
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 16, y: size.height / 16)
            for s in shapes {
                switch s {
                case .rect(let r, let radius, let fill, let stroke, let width, let dashed):
                    let path = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
                    if let f = fill { ctx.fill(path, with: .color(Self.color(f))) }
                    if let st = stroke {
                        ctx.stroke(path, with: .color(Self.color(st)), style: StrokeStyle(lineWidth: width, dash: dashed ? [2, 1.5] : []))
                    }
                case .oval(let r, let fill, let stroke, let width):
                    let path = Path(ellipseIn: r)
                    if let f = fill { ctx.fill(path, with: .color(Self.color(f))) }
                    if let st = stroke { ctx.stroke(path, with: .color(Self.color(st)), lineWidth: width) }
                case .lines(let pts, let stroke, let width, let closed):
                    var p = Path()
                    p.addLines(pts)
                    if closed { p.closeSubpath() }
                    ctx.stroke(p, with: .color(Self.color(stroke)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                case .polygon(let pts, let fill):
                    var p = Path()
                    p.addLines(pts)
                    p.closeSubpath()
                    ctx.fill(p, with: .color(Self.color(fill)))
                case .arc(let center, let radius, let from, let to, let stroke, let width):
                    var p = Path()
                    p.addArc(center: center, radius: radius, startAngle: .degrees(Double(from)), endAngle: .degrees(Double(to)), clockwise: false)
                    ctx.stroke(p, with: .color(Self.color(stroke)), style: StrokeStyle(lineWidth: width, lineCap: .butt))
                case .text(let t, let center, let size, let bold, let color):
                    ctx.draw(Text(verbatim: t).font(.system(size: size, weight: bold ? .bold : .regular)).foregroundStyle(Self.color(color)), at: center, anchor: .center)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
