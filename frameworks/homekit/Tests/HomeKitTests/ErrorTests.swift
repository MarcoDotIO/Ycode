// errors.md §1–§3 and the HAP status mapping (T-H8 status mapping part).

import Foundation
import Testing
@testable import HomeKit

@Suite("Errors (errors.md)")
struct ErrorTests {
    @Test("§1: HMErrorCode values −1, 1–93, 95–105 (94 unused)")
    func codeTable() {
        let raw = Set(HMError.Code.allCases.map(\.rawValue))
        #expect(raw.count == 105)
        #expect(raw == Set([-1] + Array(1...93) + Array(95...105)))
        #expect(!raw.contains(94))
        #expect(HMError.Code.homeAccessNotAuthorized.rawValue == 47)
        #expect(HMError.Code.operationCancelled.rawValue == 23)
        #expect(HMError.Code.roomForHomeCannotBeInZone.rawValue == 24)
        #expect(HMError.Code.nameDoesNotEndWithValidCharacters.rawValue == 60)
        #expect(HMError.Code.cannotRemoveBuiltinActionSet.rawValue == 83)
        #expect(HMError.Code.incompatibleHomeHub == .noCompatibleHomeHub)
        #expect(HMError.Code.objectWithSimilarNameExists.rawValue == 95)
        #expect(HMError.Code.homeUpgradeRequired.rawValue == 105)
    }

    @Test("§1: errors are NSErrors in HMErrorDomain")
    func bridging() {
        let e: Error = HMError(.valueHigherThanMaximum)
        let ns = e as NSError
        #expect(ns.domain == "HMErrorDomain")
        #expect(ns.code == 45)
        #expect(ns.userInfo[NSLocalizedDescriptionKey] as? String == "Value higher than maximum.")
        do { throw e } catch HMError.valueHigherThanMaximum {
            // pattern matching on codes
        } catch { Issue.record("no match") }
    }

    @Test("§2: 2040 is a plain NSError with only a localized description")
    func noAccountShape() {
        let e = HMError.ycodeNoAccountError()
        #expect(e.domain == "HMErrorDomain")
        #expect(e.code == 2040)
        #expect(Array(e.userInfo.keys) == [NSLocalizedDescriptionKey])
        #expect((e.userInfo[NSLocalizedDescriptionKey] as? String)?.contains("2040") == true)
        #expect(HMError.Code(rawValue: 2040) == nil, "not a public code")
        #expect(YcodeHomeStoreError.noAccount.publicError as? HMError == nil)
        #expect((YcodeHomeStoreError.noAccount.publicError as NSError).code == 2040)
    }

    @Test("§2: setup cancellation 23 carries an empty userInfo")
    func cancelledShape() {
        let ns = HMError.cancelledWithoutInfo as NSError
        #expect(ns.code == 23)
        #expect(ns.userInfo.isEmpty)
    }

    @Test("§3: HAP status → HMErrorCode mapping")
    func hapStatusMapping() {
        let expected: [(Int, HMError.Code?)] = [
            (0, nil), (-70401, .insufficientPrivileges), (-70402, .communicationFailure), (-70403, .accessoryIsBusy),
            (-70404, .readOnlyCharacteristic), (-70405, .writeOnlyCharacteristic), (-70406, .notificationNotSupported),
            (-70407, .accessoryOutOfResources), (-70408, .operationTimedOut), (-70409, .notFound),
            (-70410, .invalidParameter), (-70411, .invalidOrMissingAuthorizationData),
        ]
        #expect(YcodeHAPStatus.allCases.count == expected.count)
        for (status, code) in expected {
            #expect(YcodeHAPStatus(rawValue: status)?.errorCode == code, "status \(status)")
        }
        #expect(YcodeAccessoryFailure.unreachable.errorCode == .accessoryNotReachable, "connection lost → 4")
    }

    @Test("Wire errors round-trip through Codable")
    func wireForm() throws {
        let e = YcodeHomeStoreError(.fireDateInPast)
        let back = try JSONDecoder().decode(YcodeHomeStoreError.self, from: JSONEncoder().encode(e))
        #expect(back == e)
        #expect((back.publicError as? HMError)?.code == .fireDateInPast)
    }
}
