import Foundation
import YcodeDeviceModel

// Device Hub's side of Ycode's remote simulator: the model half (YcodeUI: DeviceHubRemote.swift).

/// Device Hub's side of Ycode's remote simulator (`specs/ide/device-hub.md`
/// "Ycode implementation"): the display socket every device run serves, the
/// ssh forward that brings it to the Mac, and devices started from the hub
/// (Start / Shut Down / Restart) without an app.
extension RemoteSimulator {
    /// The display server's socket on the host: one per device directory
    /// under `<data>/display` (Ycode decision; a short path, Unix sockets
    /// allow about 100 bytes).
    public var displaySocketPath: String {
        let dir = "\(settings.dataDirectory)/display/"
        if let displaySocketName { return dir + displaySocketName }
        let name = target?.deviceDirectoryName ?? settings.deviceName
        let path = dir + name + ".sock"
        // A Unix socket path holds about 104 bytes (sun_path): a long device
        // directory name (a watch type, a created device) gets a short,
        // stable name instead when that is shorter (PAIR-IDE: a watch's
        // display never connected).
        let short = "d-" + Self.shortHash(name) + ".sock"
        return path.utf8.count <= Self.socketPathLimit || short.utf8.count >= name.utf8.count + 5 ? path : dir + short
    }

    /// The longest display socket path used as it is (sun_path is 104 bytes on macOS, 108 on Linux).
    static let socketPathLimit = 100

    /// FNV-1a of a name, 8 hex digits (stable across launches).
    static func shortHash(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(format: "%08x", h)
    }

    /// `--display-server unix:<socket>` for ycode-simd (`display-stream.md` §1).
    public var displayServerArguments: [String] { ["--display-server", "unix:" + displaySocketPath] }

    /// Start (the hub's status view, Device ▸ Start): the launcher boots the
    /// device with its display server and no app (as `ycode-sim-serve`
    /// does), printing the shell's pid first so Shut Down can signal it.
    public var startCommand: String {
        let q = Self.quote
        return "mkdir -p \(q("\(settings.dataDirectory)/display")); echo YCODE-REMOTE-PID $$; exec \(environmentPrefix)\(q(settings.simdPath))"
            + " --device \(q(remoteDevicePath)) --runtime-root \(q(runtimeRoot))"
            + (target?.deviceTypeArguments ?? []).map { " " + q($0) }.joined()
            + displayServerArguments.map { " " + q($0) }.joined()
            + Self.words(settings.additionalArguments).map { " " + q($0) }.joined()
            + cameraArguments.map { " " + q($0) }.joined()
            + visionDisplayArguments.map { " " + q($0) }.joined()
    }

    /// `ssh -N -L <local socket>:<host socket> <destination>`: the display
    /// socket on the Mac (keys only; the forward fails rather than prompts).
    public func displayForwardArguments(localSocket: String) -> [String] {
        sshOptions + ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes", "-o", "ServerAliveInterval=15",
                      "-L", "\(localSocket):\(displaySocketPath)", settings.destination]
    }

    /// The device type's frame data (the viewer's table).
    public var frameSpec: DeviceFrameSpec {
        target.flatMap { DeviceFrameSpec.named(typeID: $0.deviceType.id) } ?? .iPhoneDuo
    }
}
