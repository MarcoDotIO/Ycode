// A watch app's HealthKit grants belong to its companion (health-simulation.md
// §12.1): the watch's healthd records the request under the companion's
// bundle id (WKCompanionAppBundleIdentifier in the watch app's Info.plist), on
// a local source of the watch. `health grant <watch app id>` therefore
// answers the companion's rows; this finds the companion of an app installed
// on a device.

import Foundation

public enum HealthWatchApps {
    /// The companion bundle id of the app `bundleID` installed on the device
    /// whose data directory is `data` (`<dev>/data`): the app bundles under
    /// `Containers/Bundle/Application/<uuid>/<name>.app`. Nil when no
    /// installed app has that id or it names no companion.
    public static func companion(of bundleID: String, deviceData data: String) -> String? {
        let fm = FileManager.default
        let root = data + "/Containers/Bundle/Application"
        for container in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + container
            for app in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where app.hasSuffix(".app") {
                guard let bytes = fm.contents(atPath: dir + "/" + app + "/Info.plist"),
                      let info = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                      info["CFBundleIdentifier"] as? String == bundleID else { continue }
                if let c = info["WKCompanionAppBundleIdentifier"] as? String, !c.isEmpty, c != bundleID { return c }
                return nil
            }
        }
        return nil
    }
}
