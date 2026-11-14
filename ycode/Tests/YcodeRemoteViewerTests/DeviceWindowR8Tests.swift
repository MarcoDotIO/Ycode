import Foundation
import Testing
import YcodeDeviceModel
import YcodeDisplayStream
@testable import YcodeRemoteViewer

/// Council round 8, row 196, in the Linux device window: an iPad of a type
/// Ycode has no frame for (the type and model name it; the user's device
/// name says nothing) is drawn with the tablet outline at Zoom to Fit in
/// both window sizes, and its subtitle says iPadOS, one to one with the
/// macOS hub (`DeviceHubR8Tests`).
struct DeviceWindowR8Tests {
    let r7 = DeviceWindowR7Tests()

    /// A connected session for a device whose hello names a type Ycode has
    /// no frame for.
    func unknown(type: String, model: String, _ w: Int, _ h: Int, window: (Double, Double)) -> RemoteDeviceSession {
        let s = RemoteDeviceSession(client: DisplayStreamClient(settings: DisplayClientHello(client: "t"), connect: { throw WindowFitTests.Refused() }))
        var hello = DisplayServerHello(deviceName: "ycode-test-council-ipad", model: model, pixelWidth: w, pixelHeight: h, scale: 2,
                                       encodings: ["jpeg"], touch: true, keyboard: true, buttons: ["home", "lock"], rotation: false)
        hello.deviceType = type
        hello.osVersion = "iOS 27.2"
        s.post(.hello(hello))
        s.drain()
        s.hubFit = true
        s.windowWidth = window.0
        s.windowHeight = window.1 - DeviceWindowFrame.toolbarHeight
        return s
    }

    @Test func anIPadOfAnUnknownTypeIsDrawnAsATabletWithIPadOS() {
        let type = "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"
        for (w, h, bw, bh) in [(1100.0, 800.0, 485.5, 671.0), (1400, 900, 556, 769)] {
            let s = unknown(type: type, model: "iPad16,8", 1640, 2360, window: (w, h))
            #expect(s.spec.family == .pad && s.osTitle == "iPadOS 27.2")
            let g = s.geometry
            #expect(g.body.size == CGSize(width: 940, height: 1300) && g.screenRadii == CornerRadii(all: 19))
            #expect(g.bandRingRects.map(\.color) == [DeviceFrameGeometry.Palette.edge, DeviceFrameGeometry.Palette.greyBand, DeviceFrameGeometry.Palette.inner])
            let b = r7.body(s)
            #expect(abs(b.width - bw) <= 1 && abs(b.height - bh) <= 1, "\(w): \(b.width) × \(b.height)")
        }
        // A screen size Ycode has no type for either (an iPad mini's): the
        // type names the family; the tablet outline round that screen.
        let mini = unknown(type: "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro", model: "iPad16,1", 1488, 2266, window: (1100, 800))
        #expect(mini.spec.typeID == "unknown" && mini.spec.family == .pad && mini.osTitle == "iPadOS 27.2")
        #expect(mini.geometry.bodyRadii == CornerRadii(all: 83))
        // The type's word wins over the size: a phone type stays a phone.
        let phone = unknown(type: "com.apple.CoreSimulator.SimDeviceType.iPhone-Fold", model: "iPhone99,1", 1640, 2360, window: (1100, 800))
        #expect(phone.spec.family == .phone && phone.osTitle == "iOS 27.2")
    }

    @Test func matchingTakesTheFamilyTheTypeNames() {
        let s = DeviceFrameSpec.matching(typeID: "COM.APPLE.CORESIMULATOR.SIMDEVICETYPE.IPAD-PRO-11", model: nil, pixelWidth: 1000, pixelHeight: 1400, scale: 2)
        #expect(s.family == .pad)
        #expect(DeviceFrameSpec.matching(typeID: nil, model: "Watch8,3", pixelWidth: 500, pixelHeight: 600, scale: 2).family == .watch)
        #expect(DeviceFrameSpec.matching(typeID: nil, model: nil, pixelWidth: 1500, pixelHeight: 2200, scale: 2).family == .pad)
        #expect(DeviceFrameSpec.matching(typeID: nil, model: nil, pixelWidth: 1179, pixelHeight: 2556, scale: 3).family == .phone)
    }
}
