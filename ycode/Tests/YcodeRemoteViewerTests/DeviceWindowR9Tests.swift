import Foundation
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeRemoteViewer

/// Council round 9, group D, in the Linux device window (rows 231, 232,
/// 234), one to one with the macOS hub: Zoom to Fit fits the watch, crown
/// included, in the stage (638 tall at 1100 × 800 with the inspector, 732
/// at 1400 × 900 without), a watch opens at the third zoom segment unless
/// a scale was chosen, and its capsule holds the side button, the Digital
/// Crown, Screenshot and Record.
struct DeviceWindowR9Tests {
    let r7 = DeviceWindowR7Tests()

    /// The silhouette (body, crown, side button) in window points.
    func silhouette(_ s: RemoteDeviceSession) -> ViewerRect {
        var b = s.layout.window(s.layout.geometry.outerBox)
        b.y += DeviceWindowFrame.toolbarHeight
        return b
    }

    @Test func zoomToFitFitsTheWatchCrownIncluded() {
        for (w, h, inspector, ref) in [(1100.0, 800.0, true, 638.0), (1400, 900, false, 732)] {
            let s = r7.framed(.appleWatchSeries12_46mm, w - (inspector ? DeviceWindowFrame.inspectorWidth : 0), h, osVersion: "watchOS 27.2")
            #expect(s.scaleMode == .fit && s.isWatch)
            let b = silhouette(s)
            #expect(abs(b.height - ref) <= 1, "\(w): \(b.width) × \(b.height)")
            #expect(b.y >= 52 + 8 && b.y + b.height <= h - 44.5 - 8, "\(w): y \(b.y)–\(b.y + b.height)")
            // The whole drawing fits the canvas: nothing is cut off.
            let all = s.layout.window(CGRect(origin: .zero, size: s.layout.geometry.size))
            #expect(all.y >= 0 && all.y + all.height <= s.windowHeight - ViewerLayout.controlBar + 0.5, "\(all)")
            print("R9D linux row 231 \(Int(w))x\(Int(h)): silhouette \(b.width) × \(b.height) at y \(b.y)")
        }
    }

    @Test func aWatchOpensAtActualSizeUnlessAScaleWasChosen() throws {
        let s = r7.framed(.appleWatchSeries12_46mm, 1100 - DeviceWindowFrame.inspectorWidth, 800, osVersion: "watchOS 27.2")
        let size = try #require(s.windowFitIfNeeded())
        let hub = RemoteDeviceSession.hubCanvas
        #expect(size.width == hub.width && size.height == hub.height, "the hub's window round it")
        #expect(s.scaleMode == .point && s.layout.scale == 1)
        // The third segment (Zoom To Actual Size) is drawn selected.
        let state = DeviceChromeRequest(frame: DeviceWindowFrame(width: 1100, height: 800), title: "t", subtitle: s.osTitle, dark: true,
                                        scaleMode: s.scaleMode, capturesKeyboard: false, inspectorTab: .settingsTab,
                                        inspector: .standard(note: nil), pixelDensity: 1)
        #expect(state.selectedItems.contains(.zoomActual) && !state.selectedItems.contains(.zoomFit))
        // A chosen scale is kept; a phone opens at Zoom to Fit.
        let chosen = r7.framed(.appleWatchSeries12_46mm, 820, 800)
        chosen.scaleChosen = true
        _ = chosen.windowFitIfNeeded()
        #expect(chosen.scaleMode == .fit)
        let phone = r7.framed(.iPhone18Pro, 820, 800)
        _ = phone.windowFitIfNeeded()
        #expect(phone.scaleMode == .fit)
    }

    @Test func theWatchsCapsuleHoldsFourButtons() {
        let s = r7.framed(.appleWatchSeries12_46mm, 1400, 900, osVersion: "watchOS 27.2")
        // Round 10 (row 252): the Digital Crown first.
        #expect(s.controlGroups == [[.digitalCrown, .sideButton, .screenshot, .recordScreen]])
        let caps = s.controlCapsules
        #expect(caps.count == 1 && caps[0].width == 142 && caps[0].height == 36.5)
        #expect(abs(caps[0].x + caps[0].width / 2 - 700) < 0.01)
        let controls = s.controls
        #expect(controls.map(\.command) == DeviceControlsLayout.watchGroup)
        let actionable = controls.filter { $0.command != .recordScreen }
        #expect(actionable.count == 3 && actionable.allSatisfy { $0.enabled })
        #expect(controls.first?.help.hasPrefix("Digital Crown") == true && controls[1].help.hasPrefix("Side Button"))
    }
}
