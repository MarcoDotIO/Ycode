import Foundation
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeRemoteViewer

/// Council round 6 in the Linux device window (`specs/ide/device-hub.md`
/// §14, rows 154–156), one to one with the macOS hub: with its toolbar and
/// inspector the window opens at the hub's 1100 × 800 and Zoom to Fit draws
/// the Duo's cover at the hub's scale, centred between the toolbar and the
/// capsules; it keeps its size when the device turns; the bare window keeps
/// fitting the device; Zoom to Fit's glyph is Ycode's drawing.
struct DeviceWindowR6Tests {
    let fit = WindowFitTests()

    @Test func theFramedWindowOpensAtTheHubsSizeAndFitsLikeTheHub() throws {
        let s = fit.connected(.iPhoneDuo)
        s.hubFit = true
        let canvas = try #require(s.windowFitIfNeeded())
        #expect(canvas.width == 820 && canvas.height == 748)
        #expect(DeviceWindowFrame.windowSize(canvasWidth: canvas.width, canvasHeight: canvas.height) == (1100, 800))
        s.windowWidth = canvas.width
        s.windowHeight = canvas.height
        let l = s.layout
        // The macOS hub's rule in the canvas above the capsules.
        let free = CGSize(width: 820, height: 748 - ViewerLayout.controlBar)
        #expect(abs(l.scale - DeviceZoom.hubFit(frame: l.geometry.outerBox.size, in: free)) < 1e-9)
        #expect(abs(l.scale - 0.531) < 0.004, "\(l.scale)")
        // The screen about 248 × 360, the body centred on the canvas.
        #expect(abs(l.screen.width - 248) < 1.5 && abs(l.screen.height - 360) < 1.5, "\(l.screen)")
        let body = l.window(l.geometry.body.union(l.geometry.hingeStep!))
        #expect(abs(body.x + body.width / 2 - 410) < 1 && abs(body.y + body.height / 2 - free.height / 2) < 1, "\(body)")
        // Turning the device keeps the window (the hub's does not resize).
        #expect(s.windowFitIfNeeded() == nil)
    }

    @Test func theBareWindowStillFitsTheDevice() throws {
        let s = fit.connected(.iPhoneDuo)
        let size = try #require(s.windowFitIfNeeded())
        #expect(size.width < 460 || size.height < 900)
        s.windowWidth = size.width
        s.windowHeight = size.height
        // The drawing fills the window less its margins (no hub rule).
        #expect(abs(Double(s.geometry.size.width) * s.layout.scale + 2 * ViewerLayout.margin - size.width) < 1e-6)
    }

    @Test func aScriptCanShowADeviceTypeWithoutAServer() throws {
        let s = RemoteDeviceSession(client: DisplayStreamClient(settings: DisplayClientHello(client: "t"), connect: { throw WindowFitTests.Refused() }))
        s.hubFit = true
        #expect(s.windowFitIfNeeded() == nil)
        s.preview(spec: .iPhoneDuo)
        #expect(s.spec == .iPhoneDuo && s.geometry.hingeStep != nil)
        #expect(try #require(s.windowFitIfNeeded()) == RemoteDeviceSession.hubCanvas)
    }

    @Test func zoomToFitIsYcodesDrawing() {
        #expect(DeviceWindowFrame.Item.zoomFit.symbol == DeviceWindowFrame.zoomToFitSymbol)
        #expect(!DeviceWindowFrame.zoomToFitSymbol.contains("magnifyingglass"))
        #expect(DeviceWindowFrame.Item.zoomFit.title == "Zoom to Fit")
    }
}
