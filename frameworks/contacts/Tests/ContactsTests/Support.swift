// Shared helpers. All data here is made up; no real address book is read.

import Foundation
import Testing
@testable import Contacts

/// A store on a fresh database in its own temporary directory.
final class TestStore: @unchecked Sendable {
    let dir: URL
    let url: URL
    let store: CNContactStore

    init(status: CNAuthorizationStatus = .authorized, limited: Set<String> = [], bundle: String = "org.ycode.tests") {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-cn-\(UUID().uuidString)")
        url = dir.appendingPathComponent("AddressBook.sqlite")
        store = CNContactStore(ycodeConfiguration: YcodeContactStoreConfiguration(
            databaseURL: url, authorizationStatus: status, limitedContactIdentifiers: limited, bundleIdentifier: bundle))
    }

    /// Another store on the same database.
    func another(status: CNAuthorizationStatus = .authorized, limited: Set<String> = [],
                 bundle: String = "org.ycode.tests") -> CNContactStore {
        CNContactStore(ycodeConfiguration: YcodeContactStoreConfiguration(
            databaseURL: url, authorizationStatus: status, limitedContactIdentifiers: limited, bundleIdentifier: bundle))
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

func keys(_ k: String...) -> [CNKeyDescriptor] { k.map { $0 as CNKeyDescriptor } }

let nameKeys = keys(CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey)

func ns(_ s: String) -> NSString { NSString(string: s) }

func person(_ given: String, _ family: String, org: String = "") -> CNMutableContact {
    let c = CNMutableContact()
    c.givenName = given
    c.familyName = family
    c.organizationName = org
    return c
}

func phone(_ s: String, _ label: String? = CNLabelPhoneNumberMobile) -> CNLabeledValue<CNPhoneNumber> {
    CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: s))
}

func email(_ s: String, _ label: String? = CNLabelHome) -> CNLabeledValue<NSString> {
    CNLabeledValue(label: label, value: ns(s))
}

func gregorian(_ year: Int?, _ month: Int, _ day: Int) -> DateComponents {
    var c = DateComponents()
    c.calendar = Calendar(identifier: .gregorian)
    c.year = year
    c.month = month
    c.day = day
    return c
}

func save(_ store: CNContactStore, author: String? = nil, _ build: (CNSaveRequest) -> Void) throws {
    let r = CNSaveRequest()
    r.transactionAuthor = author
    build(r)
    try store.execute(r)
}

/// Runs `body` and checks that it fails with the code.
@discardableResult
func expectCode(_ code: CNError.Code, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) -> CNError? {
    do {
        try body()
        Issue.record("expected CNError \(code.rawValue), got success", sourceLocation: sourceLocation)
    } catch let e as CNError {
        #expect(e.code == code, sourceLocation: sourceLocation)
        let n = e as NSError
        #expect(n.domain == "CNErrorDomain", sourceLocation: sourceLocation)
        #expect(n.code == code.rawValue, sourceLocation: sourceLocation)
        #expect(n.userInfo[NSLocalizedFailureReasonErrorKey] != nil, sourceLocation: sourceLocation)
        return e
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
    return nil
}

/// The exception raised by `body`, if any.
func raised<T>(_ body: () -> T) -> CNException? {
    do {
        _ = try CNException.catching(body)
        return nil
    } catch let e as CNException {
        return e
    } catch {
        return nil
    }
}

func formatted(_ c: CNContact, _ style: CNContactFormatterStyle = .fullName) -> String? {
    CNContactFormatter.string(from: c, style: style)
}

/// Text of a CRLF vCard as lines (without the line ends).
func vcardLines(_ data: Data) -> [String] {
    let s = String(decoding: data, as: UTF8.self)
    var lines = s.components(separatedBy: "\r\n")
    if lines.last == "" { lines.removeLast() }
    return lines
}

func vcard(_ lines: [String], ending: String = "\r\n") -> Data {
    Data((lines.joined(separator: ending) + ending).utf8)
}

private let mainKey = DispatchSpecificKey<Bool>()
private let mainKeyOnce: Void = { DispatchQueue.main.setSpecific(key: mainKey, value: true) }()

func onMainQueue() -> Bool {
    _ = mainKeyOnce
    return DispatchQueue.getSpecific(key: mainKey) == true
}

/// Lets queued main-queue work run.
func drainMain() async {
    _ = mainKeyOnce
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { c.resume() }
    }
}
