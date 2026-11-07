import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The layer over the whole workspace window, toolbar bands included, that
/// holds the merge confirmation and the merge sheet
/// (`specs/ide/merge-sheet.md` §1.2, §2, §10), as the AppKit
/// `MergeOverlayView` does: the veil that darkens the window over 255 ms
/// (ease-out), the alert centred on it (fading out over 90 ms on Merge),
/// and the sheet under the toolbar, fading in over 90 ms while it slides
/// down 32 points over 200 ms (with Reduce Motion it fades only; closing
/// reverses it). While anything is up it takes every click.
struct MergeOverlayLayer: View {
    var scm: SourceControlShellModel
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The layer is up (it stays up while things fade out).
    @State private var isActive = false
    /// The veil's share of its full darkness.
    @State private var veil = 0.0
    /// The alert drawn (kept while it fades out).
    @State private var alert: MergeAlertState?
    @State private var alertOpacity = 1.0
    /// Merge turns accent once the alert is up (§1.2).
    @State private var alertReady = false
    /// The sheet drawn (kept while it goes away).
    @State private var sheet: ConflictEditorShellModel?
    @State private var sheetOpacity = 0.0
    @State private var sheetOffset = 0.0
    @State private var sheetClosing = false

    /// Stretches every duration (drivers photograph frames of the
    /// transitions with it; 1 otherwise).
    @MainActor static var timeScale = 1.0

    func d(_ seconds: Double) -> Double { seconds * Self.timeScale }

    /// Whether the model wants anything shown: the alert, a merge it
    /// started that is still running, or the sheet.
    var isWanted: Bool { scm.mergeAlert != nil || scm.isMerging || scm.conflictEditor != nil }

    var body: some View {
        let p = MergeSheetPalette.forDark(scheme == .dark)
        GeometryReader { geo in
            let size = (width: Double(geo.size.width), height: Double(geo.size.height))
            ZStack(alignment: .topLeading) {
                if isActive {
                    Color.black.opacity(p.veilOpacity * veil)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .shellTarget("merge veil")
                }
                if let e = sheet {
                    let f = MergeSheetMetrics.sheetFrame(window: size, toolbarBottom: WorkspaceChrome.toolbarHeight)
                    MergeSheetView(scm: scm, editor: e, isClosing: sheetClosing)
                        .frame(width: CGFloat(f.width), height: CGFloat(f.height))
                        .compositingGroup()
                        .opacity(sheetOpacity)
                        .offset(x: CGFloat(f.x), y: CGFloat(f.y + sheetOffset))
                }
                if let a = alert {
                    let f = a.frame(window: size)
                    MergeAlertCard(scm: scm, alert: a, isReady: alertReady, isLeaving: scm.mergeAlert == nil)
                        .frame(width: CGFloat(f.width), height: CGFloat(f.height))
                        .compositingGroup()
                        .opacity(alertOpacity)
                        .offset(x: CGFloat(f.x), y: CGFloat(f.y))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(isActive)
        .onAppear {
            scm.openExternally = { [weak app] url in app?.openExternally(url) }
            sync()
        }
        .onChange(of: scm.mergeAlert) { _, _ in sync() }
        .onChange(of: scm.isMerging) { _, _ in sync() }
        .onChange(of: scm.conflictEditor.map { ObjectIdentifier($0) }) { _, _ in sync() }
    }

    /// Brings what is drawn in line with the model, animating the change.
    func sync() {
        if isWanted, !isActive {
            isActive = true
            veil = 0
        }
        syncAlert()
        syncSheet()
        syncVeil()
    }

    func syncAlert() {
        if let a = scm.mergeAlert {
            let appearing = alert == nil || alertOpacity < 1
            alert = a
            alertOpacity = 1
            if appearing {
                alertReady = false
                after(d(MergeSheetMotion.veilIn)) { if scm.mergeAlert != nil { alertReady = true } }
            }
        } else if alert != nil, alertOpacity == 1 {
            // Clicking Merge (or Cancel): the alert fades out over 90 ms.
            withAnimation(.linear(duration: d(MergeSheetMotion.alertOut))) { alertOpacity = 0 }
            after(d(MergeSheetMotion.alertOut)) { if scm.mergeAlert == nil { alert = nil } }
        }
    }

    func syncSheet() {
        let c = MergeSheetMotion.slideCurve
        if let e = scm.conflictEditor {
            let appearing = sheet == nil || sheetClosing
            sheet = e
            sheetClosing = false
            guard appearing else { return }
            // Fade in over 90 ms while sliding down 32 points over 200 ms
            // (§10); with Reduce Motion it fades only.
            sheetOpacity = 0
            sheetOffset = reduceMotion ? 0 : -MergeSheetMotion.slideDistance
            after(0.016) {
                // Still the sheet coming in (several model changes may
                // arrive in one update; any of them may start this).
                guard sheet != nil, !sheetClosing, sheetOpacity == 0 else { return }
                withAnimation(.linear(duration: d(MergeSheetMotion.sheetFade))) { sheetOpacity = 1 }
                if !reduceMotion {
                    withAnimation(.timingCurve(c.x1, c.y1, c.x2, c.y2, duration: d(MergeSheetMotion.sheetSlide))) { sheetOffset = 0 }
                }
            }
        } else if sheet != nil, !sheetClosing {
            // Closing reverses the appearance (Ycode's choice, open question
            // 3): the slide back up, the fade in its last 90 ms.
            sheetClosing = true
            let slide = reduceMotion ? 0 : d(MergeSheetMotion.sheetOutSlide)
            withAnimation(.linear(duration: d(MergeSheetMotion.sheetOutFade)).delay(max(0, slide - d(MergeSheetMotion.sheetOutFade)))) { sheetOpacity = 0 }
            if !reduceMotion {
                // The reverse of the appearance's curve.
                withAnimation(.timingCurve(1 - c.x2, 1 - c.y2, 1 - c.x1, 1 - c.y1, duration: slide)) {
                    sheetOffset = -MergeSheetMotion.slideDistance
                }
            }
            after(max(slide, d(MergeSheetMotion.sheetOutFade)) + 0.02) {
                if sheetClosing, scm.conflictEditor == nil {
                    sheet = nil
                    sheetClosing = false
                }
            }
        }
    }

    func syncVeil() {
        // The veil: ease-out over 255 ms (§1.2), in and out.
        let curve = Animation.timingCurve(0.215, 0.61, 0.355, 1, duration: d(MergeSheetMotion.veilIn))
        if isWanted {
            if veil < 1 { after(0.016) { if isWanted, veil < 1 { withAnimation(curve) { veil = 1 } } } }
        } else if isActive {
            let wait = max(sheet != nil ? d(MergeSheetMotion.sheetOutSlide) : 0, alert != nil ? d(MergeSheetMotion.alertOut) : 0)
            withAnimation(curve) { veil = 0 }
            after(max(wait, d(MergeSheetMotion.veilIn)) + 0.03) {
                if !isWanted, isActive {
                    isActive = false
                    alert = nil
                    sheet = nil
                    sheetClosing = false
                }
            }
        }
    }

    func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            body()
        }
    }
}

extension Color {
    /// An sRGB colour from a hex value (0xRRGGBB) of `MergeSheetPalette`.
    init(mergeHex hex: UInt32, opacity: Double = 1) {
        let c = MergeSheetPalette.components(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
    }
}

/// The alert's and the sheet's push buttons (§1.2, §9): a rounded fill and
/// the centred label; the default one accent with white text, a disabled
/// one grey.
struct MergeButtonLabel: View {
    var title: String
    var isDefault: Bool
    var isEnabled = true
    var palette: MergeSheetPalette
    var width: CGFloat
    var height: CGFloat
    var fontSize: CGFloat = 13
    /// nil: a capsule (the alert); the sheet's buttons are rounded
    /// rectangles of radius 6 (§14.2).
    var cornerRadius: CGFloat?

    var body: some View {
        let p = palette
        let fill = !isEnabled ? p.disabledButton : isDefault ? p.accent : p.button
        let ink: Color = !isEnabled ? Color(mergeHex: p.disabledButtonLabel) : isDefault ? .white : Color(mergeHex: p.buttonLabel)
        Text(verbatim: title)
            .font(.system(size: fontSize, weight: isDefault && isEnabled ? .medium : .regular))
            .foregroundStyle(ink)
            .lineLimit(1)
            .frame(width: width, height: height)
            .background { RoundedRectangle(cornerRadius: cornerRadius ?? height / 2, style: .continuous).fill(Color(mergeHex: fill)) }
            .contentShape(Rectangle())
    }
}
