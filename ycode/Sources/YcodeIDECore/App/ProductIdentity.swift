import Foundation
import YcodeRelease

/// What the app says about itself: the Welcome screen, the About window and
/// Help ▸ Report a Bug… on macOS and Linux read it from here.
public enum ProductIdentity {
    public static let name = "Ycode"
    public static let version = YcodeRelease.version
    public static let marketingVersion = YcodeRelease.marketingVersion

    /// The Welcome screen's line.
    public static var versionText: String { "Version \(marketingVersion)" }
    /// The About window's line.
    public static var fullVersionText: String { "Version \(marketingVersion) (\(version))" }

    public static let copyright = "Copyright © 2026 MarcoDotIO and the Ycode contributors"
    public static let license = "MIT License"
    /// Independent of the platform vendor: a factual statement, on every About.
    public static let notAffiliated = "Ycode is an independent project. It is not affiliated with or endorsed by Apple Inc."

    // swiftlint:disable force_unwrapping - literal URLs
    public static let repositoryURL = URL(string: "https://github.com/MarcoDotIO/Ycode")!
    public static let licenseURL = URL(string: "https://github.com/MarcoDotIO/Ycode/blob/main/LICENSE")!
    public static let noticesURL = URL(string: "https://github.com/MarcoDotIO/Ycode/blob/main/THIRD_PARTY_NOTICES.md")!
    public static let releasesURL = URL(string: "https://github.com/MarcoDotIO/Ycode/releases")!
    public static let helpURL = URL(string: "https://github.com/MarcoDotIO/Ycode#readme")!
    // swiftlint:enable force_unwrapping

    /// The bug report form's Platform choice (`.github/ISSUE_TEMPLATE/bug_report.yml`).
    public static var platformOption: String {
        #if os(macOS)
        #if arch(arm64)
        return "macOS (arm64)"
        #else
        return "macOS (x86_64)"
        #endif
        #else
        #if arch(arm64)
        return "Linux arm64"
        #else
        return "Linux x86-64"
        #endif
        #endif
    }

    /// "macOS 27.2", "Ubuntu 26.04 LTS": the system's name and version,
    /// nothing that names the machine or its user.
    public static var systemVersion: String {
        #if os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
        #else
        let release = (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? ""
        for line in release.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            return line.dropFirst("PRETTY_NAME=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return "Linux"
        #endif
    }

    /// The repository's bug report form with the version and platform filled
    /// in (the form's field ids are the query's names). Nothing else goes in:
    /// no paths, project names or account names.
    public static func bugReportURL(version: String = version, platform: String = platformOption, system: String = systemVersion) -> URL {
        var c = URLComponents(url: repositoryURL.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "template", value: "bug_report.yml"), URLQueryItem(name: "version", value: version),
                         URLQueryItem(name: "platform", value: platform), URLQueryItem(name: "os", value: system)]
        return c?.url ?? repositoryURL
    }
}

/// What the user is told about features that are unfinished: the same label
/// and reasons wherever they meet one.
public enum ExperimentalNotice {
    public static let label = "Experimental"
    /// The simulator and everything that runs on it.
    public static let simulator = "The Ycode simulator is experimental. It needs a Linux arm64 host with KVM and a simulator runtime you obtain yourself; "
        + "Ycode does not include one."
    public static let simulatorSetup = "Add a host in Settings ▸ Simulators, or pair one with `ycode sim remote pair`."
    /// The runtime wizard (`runtime-onboarding.md` §11.6, #55).
    public static let runtimes = "Simulator runtimes are Apple software. Ycode includes none and shares none; it gets one from Apple for you only when you ask, or uses one you have."
    public static let headset = "Viewing a device in a headset is experimental. It needs a Linux PC running the viewer and an OpenXR headset."
    public static let profiler = "Gauge, the profiler, is experimental. It records CPU samples and a few other tracks, and only apps on the Ycode simulator."
    public static let interfaceBuilder = "This editor is experimental: it shows and edits common properties, and may not show every object in the file."
}

/// The app icon's geometry and colours, in the 1024-point space of its source
/// `packaging/icon/ycode-icon.svg`, for views that draw it (a test keeps them
/// and the SVG in agreement): a plum field, a cream chevron over a coral caret.
public enum ProductIconGeometry {
    public static let side = 1024.0
    public static let fieldTop = "#3A2157", fieldBottom = "#1F1033", chevronColor = "#FFF3DC", caretColor = "#FF7A59"
    /// The field: x and y from `fieldMin` to `fieldMax`, each corner one cubic
    /// from `cornerStart` along the edge, with the control point `cornerControl`
    /// from the corner along that edge.
    public static let fieldMin = 100.0, fieldMax = 924.0, cornerStart = 219.0, cornerControl = 92.0
    public static let strokeWidth = 98.0
    public static let chevron = [(322.0, 290.0), (512.0, 486.0), (702.0, 290.0)]
    public static let caret = [(512.0, 616.0), (512.0, 752.0)]
}
