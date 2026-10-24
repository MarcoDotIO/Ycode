import Foundation

// MARK: - Identifier value types (string-valued, interop: `identifiers.md`)

public struct HKQuantityTypeIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
public struct HKCategoryTypeIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
public struct HKCharacteristicTypeIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
public struct HKCorrelationTypeIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
public struct HKDocumentTypeIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
public struct HKClinicalTypeIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
public struct HKScoredAssessmentTypeIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Registry data

enum TypeKind: String, Sendable {
    case quantity, category, characteristic, correlation, document, clinical, scoredAssessment
    case workout, series, activitySummary, audiogram, electrocardiogram, visionPrescription
    case stateOfMind, medicationDoseEvent, userAnnotatedMedication
}

/// The unit family a quantity type accepts (`identifiers.md` "dimension").
enum QuantityDimension: String, Sendable {
    case scalar, mass, length, volume, time, energy, temperature, pressure, speed, frequency, power
    case conductance, soundPressureLevel, effortScore, pharmacology, volumeFlow, energyRatePerMass
    case vo2Rate, massConcentration

    var dimension: Dimension {
        switch self {
        case .scalar: return .none
        case .mass: return Dimension([(0, 1)])
        case .length: return Dimension([(1, 1)])
        case .volume: return Dimension([(1, 3)])
        case .time: return Dimension([(2, 1)])
        case .energy: return Dimension([(0, 1), (1, 2), (2, -2)])
        case .temperature: return Dimension([(3, 1)])
        case .pressure: return Dimension([(0, 1), (1, -1), (2, -2)])
        case .speed: return Dimension([(1, 1), (2, -1)])
        case .frequency: return Dimension([(2, -1)])
        case .power: return Dimension([(0, 1), (1, 2), (2, -3)])
        case .conductance: return Dimension([(5, 1)])
        case .soundPressureLevel: return Dimension([(9, 1)])
        case .effortScore: return Dimension([(14, 1)])
        case .pharmacology: return Dimension([(11, 1)])
        case .volumeFlow: return Dimension([(1, 3), (2, -1)])
        case .energyRatePerMass: return Dimension([(1, 2), (2, -3)])
        case .vo2Rate: return Dimension([(0, -1), (1, 3), (2, -1)])
        case .massConcentration: return Dimension([(0, 1), (1, -3)])
        }
    }
}

struct QuantityTypeSpec: Sendable {
    let identifier: String
    let style: HKQuantityAggregationStyle
    let dimension: QuantityDimension
    let maximumDuration: Double?
    let minimumDuration: Double?
}

struct OtherTypeSpec: Sendable {
    let identifier: String
    let kind: TypeKind
    let maximumDuration: Double?
    let perObject: Bool
    let valueEnum: String?
}

struct TypeInfo: Sendable {
    let identifier: String
    let kind: TypeKind
    var perObject = false
    var maximumDuration: Double?
    var minimumDuration: Double?
    var style: HKQuantityAggregationStyle?
    var dimension: QuantityDimension?
    var allowedValues: Set<Int>?
    var shareable = true
    var readable = true
}

enum TypeRegistry {
    /// Allowed values of each category value enumeration (`identifiers.md`).
    static let categoryValueSets: [String: Set<Int>] = {
        func s<E: CaseIterable & RawRepresentable>(_: E.Type) -> Set<Int> where E.RawValue == Int {
            Set(E.allCases.map(\.rawValue))
        }
        return [
            "HKCategoryValue": s(HKCategoryValue.self),
            "HKCategoryValueSeverity": s(HKCategoryValueSeverity.self),
            "HKCategoryValueSleepAnalysis": s(HKCategoryValueSleepAnalysis.self),
            "HKCategoryValueAppleStandHour": s(HKCategoryValueAppleStandHour.self),
            "HKCategoryValueCervicalMucusQuality": s(HKCategoryValueCervicalMucusQuality.self),
            "HKCategoryValueOvulationTestResult": s(HKCategoryValueOvulationTestResult.self),
            "HKCategoryValuePregnancyTestResult": s(HKCategoryValuePregnancyTestResult.self),
            "HKCategoryValueProgesteroneTestResult": s(HKCategoryValueProgesteroneTestResult.self),
            "HKCategoryValueMenstrualFlow": s(HKCategoryValueMenstrualFlow.self),
            "HKCategoryValueContraceptive": s(HKCategoryValueContraceptive.self),
            "HKCategoryValueLowCardioFitnessEvent": s(HKCategoryValueLowCardioFitnessEvent.self),
            "HKCategoryValueAppleWalkingSteadinessEvent": s(HKCategoryValueAppleWalkingSteadinessEvent.self),
            "HKCategoryValueHeadphoneAudioExposureEvent": s(HKCategoryValueHeadphoneAudioExposureEvent.self),
            "HKCategoryValueEnvironmentalAudioExposureEvent": s(HKCategoryValueEnvironmentalAudioExposureEvent.self),
            "HKCategoryValueAppetiteChanges": s(HKCategoryValueAppetiteChanges.self),
            "HKCategoryValuePresence": s(HKCategoryValuePresence.self),
            "HKCategoryValueVaginalBleeding": s(HKCategoryValueVaginalBleeding.self),
            "HKCategoryValueMenopausalState": s(HKCategoryValueMenopausalState.self),
        ]
    }()

    /// Types the system computes; apps may read but not share them (level 1, partial list).
    static let systemComputed: Set<String> = [
        "HKCategoryTypeIdentifierAppleStandHour", "HKQuantityTypeIdentifierAppleStandTime",
        "HKQuantityTypeIdentifierAppleExerciseTime", "HKQuantityTypeIdentifierAppleMoveTime",
        "HKQuantityTypeIdentifierAppleWalkingSteadiness", "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent",
        "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances", "HKQuantityTypeIdentifierWalkingHeartRateAverage",
        "HKCategoryTypeIdentifierLowCardioFitnessEvent", "HKCategoryTypeIdentifierHighHeartRateEvent",
        "HKCategoryTypeIdentifierLowHeartRateEvent", "HKCategoryTypeIdentifierIrregularHeartRhythmEvent",
        "HKQuantityTypeIdentifierAtrialFibrillationBurden",
    ]

    static let singletons: [TypeInfo] = [
        TypeInfo(identifier: HKWorkoutTypeIdentifier, kind: .workout),
        TypeInfo(identifier: HKWorkoutRouteTypeIdentifier, kind: .series),
        TypeInfo(identifier: HKDataTypeIdentifierHeartbeatSeries, kind: .series),
        TypeInfo(identifier: "HKActivitySummaryTypeIdentifier", kind: .activitySummary, shareable: false),
        TypeInfo(identifier: "HKDataTypeIdentifierAudiogram", kind: .audiogram),
        TypeInfo(identifier: "HKDataTypeIdentifierElectrocardiogram", kind: .electrocardiogram),
        TypeInfo(identifier: HKVisionPrescriptionTypeIdentifier, kind: .visionPrescription, perObject: true),
        TypeInfo(identifier: HKDataTypeIdentifierStateOfMind, kind: .stateOfMind),
        TypeInfo(identifier: HKMedicationDoseEventTypeIdentifierMedicationDoseEvent, kind: .medicationDoseEvent),
        TypeInfo(identifier: HKDataTypeIdentifierUserAnnotatedMedicationConcept, kind: .userAnnotatedMedication, perObject: true),
    ]

    static let all: [String: HKObjectType] = {
        var out: [String: HKObjectType] = [:]
        for q in quantityTypeTable {
            let info = TypeInfo(identifier: q.identifier, kind: .quantity, maximumDuration: q.maximumDuration,
                                minimumDuration: q.minimumDuration, style: q.style, dimension: q.dimension,
                                shareable: !systemComputed.contains(q.identifier))
            out[q.identifier] = HKQuantityType(info: info)
        }
        for o in otherTypeTable {
            var info = TypeInfo(identifier: o.identifier, kind: o.kind, perObject: o.perObject,
                                maximumDuration: o.kind == .characteristic ? nil : o.maximumDuration)
            if let e = o.valueEnum { info.allowedValues = categoryValueSets[e] ?? [0] }
            switch o.kind {
            case .characteristic: info.shareable = false
            case .correlation: info.shareable = false; info.readable = false
            case .clinical: info.shareable = false
            default: info.shareable = !systemComputed.contains(o.identifier)
            }
            out[o.identifier] = make(info)
        }
        for s in singletons { out[s.identifier] = make(s) }
        return out
    }()

    static func make(_ info: TypeInfo) -> HKObjectType {
        switch info.kind {
        case .quantity: return HKQuantityType(info: info)
        case .category: return HKCategoryType(info: info)
        case .characteristic: return HKCharacteristicType(info: info)
        case .correlation: return HKCorrelationType(info: info)
        case .document: return HKDocumentType(info: info)
        case .clinical: return HKClinicalType(info: info)
        case .scoredAssessment: return HKScoredAssessmentType(info: info)
        case .workout: return HKWorkoutType(info: info)
        case .series: return HKSeriesType(info: info)
        case .activitySummary: return HKActivitySummaryType(info: info)
        case .audiogram: return HKAudiogramSampleType(info: info)
        case .electrocardiogram: return HKElectrocardiogramType(info: info)
        case .visionPrescription: return HKPrescriptionType(info: info)
        case .stateOfMind: return HKStateOfMindType(info: info)
        case .medicationDoseEvent: return HKMedicationDoseEventType(info: info)
        case .userAnnotatedMedication: return HKUserAnnotatedMedicationType(info: info)
        }
    }

    static func type(_ identifier: String) -> HKObjectType? { all[identifier] }
    static func sampleType(_ identifier: String) -> HKSampleType? { all[identifier] as? HKSampleType }
}

// MARK: - Classes (`interface.md` §2)

/// An interned, immutable data type. The same identifier always yields the same object.
public class HKObjectType: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let info: TypeInfo
    public var identifier: String { info.identifier }

    init(info: TypeInfo) {
        self.info = info
        super.init()
    }

    public class func quantityType(forIdentifier identifier: HKQuantityTypeIdentifier) -> HKQuantityType? {
        TypeRegistry.type(identifier.rawValue) as? HKQuantityType
    }
    public class func categoryType(forIdentifier identifier: HKCategoryTypeIdentifier) -> HKCategoryType? {
        TypeRegistry.type(identifier.rawValue) as? HKCategoryType
    }
    public class func characteristicType(forIdentifier identifier: HKCharacteristicTypeIdentifier) -> HKCharacteristicType? {
        TypeRegistry.type(identifier.rawValue) as? HKCharacteristicType
    }
    public class func correlationType(forIdentifier identifier: HKCorrelationTypeIdentifier) -> HKCorrelationType? {
        TypeRegistry.type(identifier.rawValue) as? HKCorrelationType
    }
    public class func documentType(forIdentifier identifier: HKDocumentTypeIdentifier) -> HKDocumentType? {
        TypeRegistry.type(identifier.rawValue) as? HKDocumentType
    }
    public class func clinicalType(forIdentifier identifier: HKClinicalTypeIdentifier) -> HKClinicalType? {
        TypeRegistry.type(identifier.rawValue) as? HKClinicalType
    }
    public class func scoredAssessmentType(forIdentifier identifier: HKScoredAssessmentTypeIdentifier) -> HKScoredAssessmentType? {
        TypeRegistry.type(identifier.rawValue) as? HKScoredAssessmentType
    }
    public class func seriesType(forIdentifier identifier: String) -> HKSeriesType? {
        TypeRegistry.type(identifier) as? HKSeriesType
    }
    public class func workoutType() -> HKWorkoutType { TypeRegistry.type(HKWorkoutTypeIdentifier) as! HKWorkoutType }
    public class func activitySummaryType() -> HKActivitySummaryType {
        TypeRegistry.type("HKActivitySummaryTypeIdentifier") as! HKActivitySummaryType
    }
    public class func audiogramSampleType() -> HKAudiogramSampleType {
        TypeRegistry.type("HKDataTypeIdentifierAudiogram") as! HKAudiogramSampleType
    }
    public class func electrocardiogramType() -> HKElectrocardiogramType {
        TypeRegistry.type("HKDataTypeIdentifierElectrocardiogram") as! HKElectrocardiogramType
    }
    public class func visionPrescriptionType() -> HKPrescriptionType {
        TypeRegistry.type(HKVisionPrescriptionTypeIdentifier) as! HKPrescriptionType
    }
    public class func stateOfMindType() -> HKStateOfMindType {
        TypeRegistry.type(HKDataTypeIdentifierStateOfMind) as! HKStateOfMindType
    }
    public class func medicationDoseEventType() -> HKMedicationDoseEventType {
        TypeRegistry.type(HKMedicationDoseEventTypeIdentifierMedicationDoseEvent) as! HKMedicationDoseEventType
    }
    public class func userAnnotatedMedicationType() -> HKUserAnnotatedMedicationType {
        TypeRegistry.type(HKDataTypeIdentifierUserAnnotatedMedicationConcept) as! HKUserAnnotatedMedicationType
    }

    public func requiresPerObjectAuthorization() -> Bool { info.perObject }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? HKObjectType else { return false }
        return other === self || (other.identifier == identifier && other.info.kind == info.kind)
    }
    public override var hash: Int { identifier.hashValue }
    public override var description: String { identifier }

    public class var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) { coder.encode(identifier as NSString, forKey: "identifier") }
    public required init?(coder: NSCoder) {
        guard let id = coder.decodeObject(of: NSString.self, forKey: "identifier") as String?,
              let registered = TypeRegistry.type(id) else { return nil }
        info = registered.info
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

public class HKSampleType: HKObjectType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    public var isMaximumDurationRestricted: Bool { info.maximumDuration != nil }
    /// Reading this on an unrestricted type does not raise (`interface.md` §2); it answers 0.
    public var maximumAllowedDuration: TimeInterval { info.maximumDuration ?? 0 }
    public var isMinimumDurationRestricted: Bool { info.minimumDuration != nil }
    public var minimumAllowedDuration: TimeInterval { info.minimumDuration ?? 0 }
    public var allowsRecalibrationForEstimates: Bool { false }
}

public final class HKQuantityType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    public var aggregationStyle: HKQuantityAggregationStyle { info.style ?? .cumulative }
    public func `is`(compatibleWith unit: HKUnit) -> Bool { unit.dimension == quantityDimension.dimension }
    var quantityDimension: QuantityDimension { info.dimension ?? .scalar }
}
public final class HKCategoryType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKCharacteristicType: HKObjectType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKCorrelationType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKWorkoutType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKSeriesType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    public class func workoutRoute() -> HKSeriesType { TypeRegistry.type(HKWorkoutRouteTypeIdentifier) as! HKSeriesType }
    public class func heartbeat() -> HKSeriesType { TypeRegistry.type(HKDataTypeIdentifierHeartbeatSeries) as! HKSeriesType }
}
public final class HKDocumentType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKClinicalType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKActivitySummaryType: HKObjectType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKAudiogramSampleType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKElectrocardiogramType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKPrescriptionType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKStateOfMindType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKScoredAssessmentType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKMedicationDoseEventType: HKSampleType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}
public final class HKUserAnnotatedMedicationType: HKObjectType, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
}

// MARK: - Swift refinements: non-optional initializers that return the interned type

public protocol _HKTypeInterning {}
extension HKObjectType: _HKTypeInterning {}
extension _HKTypeInterning where Self: HKQuantityType {
    public init(_ identifier: HKQuantityTypeIdentifier) {
        guard let t = HKObjectType.quantityType(forIdentifier: identifier) else {
            hkRaise(.invalidArgument("Unknown quantity type identifier \(identifier.rawValue)"))
        }
        self = t as! Self
    }
}
extension _HKTypeInterning where Self: HKCategoryType {
    public init(_ identifier: HKCategoryTypeIdentifier) {
        guard let t = HKObjectType.categoryType(forIdentifier: identifier) else {
            hkRaise(.invalidArgument("Unknown category type identifier \(identifier.rawValue)"))
        }
        self = t as! Self
    }
}
extension _HKTypeInterning where Self: HKCharacteristicType {
    public init(_ identifier: HKCharacteristicTypeIdentifier) {
        guard let t = HKObjectType.characteristicType(forIdentifier: identifier) else {
            hkRaise(.invalidArgument("Unknown characteristic type identifier \(identifier.rawValue)"))
        }
        self = t as! Self
    }
}
extension _HKTypeInterning where Self: HKCorrelationType {
    public init(_ identifier: HKCorrelationTypeIdentifier) {
        guard let t = HKObjectType.correlationType(forIdentifier: identifier) else {
            hkRaise(.invalidArgument("Unknown correlation type identifier \(identifier.rawValue)"))
        }
        self = t as! Self
    }
}
extension _HKTypeInterning where Self: HKDocumentType {
    public init(_ identifier: HKDocumentTypeIdentifier) {
        guard let t = HKObjectType.documentType(forIdentifier: identifier) else {
            hkRaise(.invalidArgument("Unknown document type identifier \(identifier.rawValue)"))
        }
        self = t as! Self
    }
}
extension _HKTypeInterning where Self: HKClinicalType {
    public init(_ identifier: HKClinicalTypeIdentifier) {
        guard let t = HKObjectType.clinicalType(forIdentifier: identifier) else {
            hkRaise(.invalidArgument("Unknown clinical type identifier \(identifier.rawValue)"))
        }
        self = t as! Self
    }
}
extension _HKTypeInterning where Self: HKScoredAssessmentType {
    public init(_ identifier: HKScoredAssessmentTypeIdentifier) {
        guard let t = HKObjectType.scoredAssessmentType(forIdentifier: identifier) else {
            hkRaise(.invalidArgument("Unknown scored assessment type identifier \(identifier.rawValue)"))
        }
        self = t as! Self
    }
}
extension _HKTypeInterning where Self: HKWorkoutType {
    public init() { self = HKObjectType.workoutType() as! Self }
}
