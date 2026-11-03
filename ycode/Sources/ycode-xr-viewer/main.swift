// ycode-xr-viewer: a visionOS device of a simulator host in an OpenXR
// headset (specs/simulator/xr-viewer.md). Connects over Ycode's link
// (`--link`, sim-link.md) or to a display socket (`--connect`).

import Foundation
import YcodeDisplayStream
import YcodeRelease
import YcodeSimLink
import YcodeXRViewer

YcodeRelease.handleVersionFlag(tool: "ycode-xr-viewer")
let args = Array(CommandLine.arguments.dropFirst())
var connect: (@Sendable () throws -> DisplayTransport)?
if case .run(let o) = XRViewerOptions.parse(args), !o.probe {
    if let device = o.linkDevice {
        do {
            let link = try LinkClient()
            let host = try link.host(named: o.linkHost)
            let media = o.media
            connect = { try link.display(host, device: device, media: media) }
            FileHandle.standardError.write(Data("ycode-xr-viewer: \(device) on \(host.name) (\(host.host):\(host.controlPort)) over the link\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("ycode-xr-viewer: \(error)\n".utf8))
            exit(69)
        }
    } else if let a = o.connect {
        guard let address = DisplayAddress(a) else {
            FileHandle.standardError.write(Data("ycode-xr-viewer: bad address \(a)\n".utf8))
            exit(64)
        }
        connect = { try DisplayConnection.connect(to: address) }
    }
}
exit(XRViewerMain.main(args, connect: connect))
