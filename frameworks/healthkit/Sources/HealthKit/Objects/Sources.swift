import Foundation

/// Identity of the app (client) that talks to the health store. On Apple's
/// platforms this comes from the app's entitlements and bundle; in Ycode's open
/// HealthKit it is configured explicitly (see README "Client identity").
public struct YcodeHealthClient: Hashable, Sendable {
    public var bundleIdentifier: String
    public var name: String
    public var version: String?
    public var productType: String?
    public var operatingSystemVersion: (major: Int, minor: Int, patch: Int)

    public init(bundleIdentifier: String, name: String? = nil, version: String? = "1",
                productType: String? = YcodeHealthClient.hostProductType,
                operatingSystemVersion: (major: Int, minor: Int, patch: Int)? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name ?? bundleIdentifier
        self.version = version
        self.productType = productType
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.operatingSystemVersion = operatingSystemVersion ?? (os.majorVersion, os.minorVersion, os.patchVersion)
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.bundleIdentifier == b.bundleIdentifier && a.name == b.name && a.version == b.version
            && a.productType == b.productType && a.operatingSystemVersion == b.operatingSystemVersion
    }
    public func hash(into h: inout Hasher) { h.combine(bundleIdentifier) }

    #if os(Linux)
    public static let hostProductType: String? = "Linux"
    #else
    public static let hostProductType: String? = "Mac"
    #endif

    /// The process's own identity: `YCODE_HEALTHKIT_BUNDLE_IDENTIFIER`, else the main
    /// bundle's identifier, else `local.<process name>`.
    public static let processDefault: YcodeHealthClient = {
        let env = ProcessInfo.processInfo.environment
        let id = env["YCODE_HEALTHKIT_BUNDLE_IDENTIFIER"] ?? Bundle.main.bundleIdentifier
            ?? "local.\(ProcessInfo.processInfo.processName)"
        let name = env["YCODE_HEALTHKIT_APP_NAME"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return YcodeHealthClient(bundleIdentifier: id, name: name, version: version)
    }()

    var sourceRecord: SourceRecord { SourceRecord(bundleIdentifier: bundleIdentifier, name: name) }
    var revisionRecord: SourceRevisionRecord {
        SourceRevisionRecord(source: sourceRecord, version: version, productType: productType,
                             osMajor: operatingSystemVersion.major, osMinor: operatingSystemVersion.minor,
                             osPatch: operatingSystemVersion.patch)
    }
    /// The `HKSource` objects saved by this client carry.
    public var source: HKSource { HKSource(record: sourceRecord) }
}

/// The app or device that created objects (`interface.md` §4). Compared by bundle identifier.
public final class HKSource: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let record: SourceRecord
    public var name: String { record.name }
    public var bundleIdentifier: String { record.bundleIdentifier }

    init(record: SourceRecord) {
        self.record = record
        super.init()
    }

    /// The calling app's source.
    public class func `default`() -> HKSource { YcodeHealthClient.processDefault.source }

    public override func isEqual(_ object: Any?) -> Bool {
        (object as? HKSource)?.bundleIdentifier == bundleIdentifier
    }
    public override var hash: Int { bundleIdentifier.hashValue }
    public override var description: String { "\(name) (\(bundleIdentifier))" }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode(name as NSString, forKey: "name")
        coder.encode(bundleIdentifier as NSString, forKey: "bundleIdentifier")
    }
    public required init?(coder: NSCoder) {
        guard let n = coder.decodeObject(of: NSString.self, forKey: "name") as String?,
              let b = coder.decodeObject(of: NSString.self, forKey: "bundleIdentifier") as String? else { return nil }
        record = SourceRecord(bundleIdentifier: b, name: n)
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

/// A source plus the app version and system it ran on when it saved an object.
public final class HKSourceRevision: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let record: SourceRevisionRecord
    public var source: HKSource { HKSource(record: record.source) }
    public var version: String? { record.version }
    public var productType: String? { record.productType }
    public var operatingSystemVersion: OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: record.osMajor, minorVersion: record.osMinor, patchVersion: record.osPatch)
    }

    init(record: SourceRevisionRecord) {
        self.record = record
        super.init()
    }

    public convenience init(source: HKSource, version: String?, productType: String?,
                            operatingSystemVersion: OperatingSystemVersion) {
        self.init(record: SourceRevisionRecord(source: source.record, version: version, productType: productType,
                                               osMajor: operatingSystemVersion.majorVersion,
                                               osMinor: operatingSystemVersion.minorVersion,
                                               osPatch: operatingSystemVersion.patchVersion))
    }
    public convenience init(source: HKSource, version: String?) {
        self.init(record: SourceRevisionRecord(source: source.record, version: version, productType: nil,
                                               osMajor: 0, osMinor: 0, osPatch: 0))
    }

    public override func isEqual(_ object: Any?) -> Bool { (object as? HKSourceRevision)?.record == record }
    public override var hash: Int { record.hashValue }
    public override var description: String {
        "\(source) version \(version ?? "-") \(productType ?? "-") \(record.osMajor).\(record.osMinor).\(record.osPatch)"
    }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode((try? JSONEncoder().encode(record)) ?? Data(), forKey: "record")
    }
    public required init?(coder: NSCoder) {
        guard let d = coder.decodeObject(of: NSData.self, forKey: "record") as Data?,
              let r = try? JSONDecoder().decode(SourceRevisionRecord.self, from: d) else { return nil }
        record = r
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

/// Hardware that produced a sample (`interface.md` §4). Compared on every field.
public final class HKDevice: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let record: DeviceRecord
    public var name: String? { record.name }
    public var manufacturer: String? { record.manufacturer }
    public var model: String? { record.model }
    public var hardwareVersion: String? { record.hardwareVersion }
    public var firmwareVersion: String? { record.firmwareVersion }
    public var softwareVersion: String? { record.softwareVersion }
    public var localIdentifier: String? { record.localIdentifier }
    public var udiDeviceIdentifier: String? { record.udiDeviceIdentifier }

    init(record: DeviceRecord) {
        self.record = record
        super.init()
    }

    public convenience init(name: String?, manufacturer: String?, model: String?, hardwareVersion: String?,
                            firmwareVersion: String?, softwareVersion: String?, localIdentifier: String?,
                            udiDeviceIdentifier: String?) {
        self.init(record: DeviceRecord(name: name, manufacturer: manufacturer, model: model,
                                       hardwareVersion: hardwareVersion, firmwareVersion: firmwareVersion,
                                       softwareVersion: softwareVersion, localIdentifier: localIdentifier,
                                       udiDeviceIdentifier: udiDeviceIdentifier))
    }

    /// The machine this process runs on (Ycode's own description of the host).
    public class func local() -> HKDevice {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let model = YcodeHealthClient.hostProductType
        return HKDevice(name: model, manufacturer: "Ycode", model: model, hardwareVersion: model,
                        firmwareVersion: nil,
                        softwareVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                        localIdentifier: nil, udiDeviceIdentifier: nil)
    }

    func value(forProperty key: String) -> String? {
        switch key {
        case HKDevicePropertyKeyName: return name
        case HKDevicePropertyKeyManufacturer: return manufacturer
        case HKDevicePropertyKeyModel: return model
        case HKDevicePropertyKeyHardwareVersion: return hardwareVersion
        case HKDevicePropertyKeyFirmwareVersion: return firmwareVersion
        case HKDevicePropertyKeySoftwareVersion: return softwareVersion
        case HKDevicePropertyKeyLocalIdentifier: return localIdentifier
        case HKDevicePropertyKeyUDIDeviceIdentifier: return udiDeviceIdentifier
        default: return nil
        }
    }

    public override func isEqual(_ object: Any?) -> Bool { (object as? HKDevice)?.record == record }
    public override var hash: Int { record.hashValue }
    public override var description: String {
        "<HKDevice name:\(name ?? "-"), manufacturer:\(manufacturer ?? "-"), model:\(model ?? "-")>"
    }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode((try? JSONEncoder().encode(record)) ?? Data(), forKey: "record")
    }
    public required init?(coder: NSCoder) {
        guard let d = coder.decodeObject(of: NSData.self, forKey: "record") as Data?,
              let r = try? JSONDecoder().decode(DeviceRecord.self, from: d) else { return nil }
        record = r
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}
