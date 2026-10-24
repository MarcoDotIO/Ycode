// The device-capabilities plist named by SIMULATOR_CAPABILITIES
// (specs/simulator/device-capabilities.md). The runtime's MobileGestalt
// answers device questions from its `capabilities` dictionary; with no file
// it logs "can't load simulator capabilities dictionary" and many answers
// are missing (CoreUI then cannot pick artwork: "couldn't get
// 'kMGArtworkDeviceIdiom' from MGCopyAnswer", and app icons stay grey).
// The values come from the device type's record (DeviceTypes.swift;
// specs/simulator/ipad.md §4.2 for the iPads).

import Foundation

enum DeviceCapabilities {
    /// The plist: {capabilities: {...}} for `type`.
    static func plist(for type: DeviceType) -> [String: Any] { type.capabilitiesPlist }
}
