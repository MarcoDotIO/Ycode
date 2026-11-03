import Foundation
import YcodePreviews
import YcodeSubprocess

// Remote previews' commands on the remote simulator: the model half (YcodeUI: RemotePreviewSession.swift).

/// The preview device: a Ycode simulator of its own per run destination
/// (`<device directory>-previews`), so previews never disturb the device an
/// app runs on (`specs/ide/previews.md` §Preview device). It keeps the
/// destination's runtime and type.
extension RemoteSimulator {
    public static let previewDeviceSuffix = "-previews"

    /// This simulator's preview device. Its display socket has a short
    /// name, `pv-<hash of the device directory>.sock`: ssh refuses a
    /// forward whose socket path is longer than the Mac's limit (104
    /// bytes), which a data directory plus a long device name passes.
    public var previewDevice: RemoteSimulator {
        var r = self
        if var t = r.target {
            t.deviceDirectoryName += Self.previewDeviceSuffix
            r.target = t
        } else {
            r.settings.deviceName += Self.previewDeviceSuffix
        }
        let name = r.target?.deviceDirectoryName ?? r.settings.deviceName
        r.displaySocketName = "pv-" + String(UInt64(bitPattern: Int64(PreviewInputs.hash(name))) % 0xffff_ffff, radix: 16) + ".sock"
        return r
    }

    /// The host directory the preview host polls (the device's `/tmp/ycode-previews`).
    public var previewDirectory: String { "\(remoteDevicePath)/\(PreviewHost.deviceRelativeDirectory)" }

    /// The preview host's bundle on the simulator host (one per platform).
    public func remotePreviewHostPath(platform: PreviewPlatform) -> String {
        "\(settings.dataDirectory)/apps/previews-\(platform.rawValue)/\(PreviewHost.appName)"
    }

    /// Starts the preview device with the host installed and launched, its
    /// display server on, and warm boot always on (Ycode decision: the preview
    /// device exists to start fast). Prints the shell's pid first.
    public func previewCommand(platform: PreviewPlatform) -> String {
        let q = Self.quote
        let lean = leanBootVariables
        return "mkdir -p \(q("\(settings.dataDirectory)/display")) \(q(previewDirectory)); rm -f \(q(previewDirectory))/payload-*.dylib \(q(previewDirectory))/plan.json; "
            + ": > \(q(previewDirectory + "/host.log")); echo YCODE-REMOTE-PID $$; exec env YCODE_WARM_BOOT=1 \(lean)\(q(settings.simdPath))"
            + " --device \(q(remoteDevicePath)) --runtime-root \(q(runtimeRoot))"
            + (target?.deviceTypeArguments ?? []).map { " " + q($0) }.joined()
            + " --install-app \(q(remotePreviewHostPath(platform: platform))) --launch \(q(PreviewHost.bundleIdentifier))"
            + displayServerArguments.map { " " + q($0) }.joined()
            + Self.words(settings.additionalArguments).map { " " + q($0) }.joined()
            + cameraArguments.map { " " + q($0) }.joined()
    }

    /// Follows the host's report file (`tail -F`): one line per report.
    public var previewReportCommand: String {
        let f = Self.quote(previewDirectory + "/host.log")
        return "mkdir -p \(Self.quote(previewDirectory)) && touch \(f) && exec tail -n 0 -F \(f)"
    }

    /// Writes a payload (standard input) and then the plan, each by rename,
    /// so the host never reads a partial file; keeps the newest payloads.
    public func previewDeliverCommand(payloadName: String?, plan: Data, keep: Int) -> String {
        let q = Self.quote
        let d = q(previewDirectory)
        var c = "mkdir -p \(d) && cd \(d) && "
        if let p = payloadName { c += "cat > \(q(p + ".part")) && mv \(q(p + ".part")) \(q(p)) && " }
        c += "printf '%s' \(q(String(decoding: plan, as: UTF8.self))) > plan.json.part && mv plan.json.part plan.json"
        c += " && (ls -t payload-*.dylib 2>/dev/null | tail -n +\(keep + 1) | xargs -r rm -f)"
        return c
    }
}
