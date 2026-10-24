// CNContactStore (interface.md §3–§6): authorization (recorded answers),
// fetching, enumeration, groups and containers, atomic save requests,
// change notifications and change history.

import Foundation

/// Ycode-specific store settings. `CNContactStore()` uses
/// `CNContactStore.ycodeDefaultConfiguration`; tests and tools create
/// stores with their own configuration through `init(ycodeConfiguration:)`.
public struct YcodeContactStoreConfiguration: Sendable {
    /// The contacts database file (created with the fresh-device content on first use).
    public var databaseURL: URL
    /// The app's access (the authorization broker of round R6 is not
    /// implemented; this is the recorded answer).
    public var authorizationStatus: CNAuthorizationStatus
    /// With `.limited`: the contacts the user shared with the app.
    public var limitedContactIdentifiers: Set<String>
    /// Identifies the app; contacts it creates stay visible with limited access.
    public var bundleIdentifier: String
    /// The region used for phone matching and postal layouts ("us").
    public var countryCode: String

    public init(databaseURL: URL = YcodeContactStoreConfiguration.standardDatabaseURL,
                authorizationStatus: CNAuthorizationStatus = .authorized,
                limitedContactIdentifiers: Set<String> = [],
                bundleIdentifier: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
                countryCode: String = "us") {
        self.databaseURL = databaseURL
        self.authorizationStatus = authorizationStatus
        self.limitedContactIdentifiers = limitedContactIdentifiers
        self.bundleIdentifier = bundleIdentifier
        self.countryCode = countryCode
    }

    /// `$YCODE_CONTACTS_DATABASE`, else `<data home>/ycode-contacts/AddressBook.sqlite`
    /// (`$XDG_DATA_HOME` or `~/.local/share` on Linux, Application Support on macOS).
    public static var standardDatabaseURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["YCODE_CONTACTS_DATABASE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        #if canImport(Darwin)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        #else
        let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        #endif
        return base.appendingPathComponent("ycode-contacts/AddressBook.sqlite")
    }
}

/// Undeclared user-info keys of the change notification (interface.md §6.1).
let notificationSaveIdentifiersKey = "CNNotificationSaveIdentifiersKey"
let notificationSourcesKey = "CNNotificationSourcesKey"
let notificationOriginationExternallyKey = "CNNotificationOriginationExternally"

public class CNContactStore: NSObject, @unchecked Sendable {
    private static let defaultsLock = NSLock()
    nonisolated(unsafe) private static var _default = YcodeContactStoreConfiguration()

    /// The configuration used by `CNContactStore()` and `authorizationStatus(for:)`.
    public static var ycodeDefaultConfiguration: YcodeContactStoreConfiguration {
        get { defaultsLock.lock(); defer { defaultsLock.unlock() }; return _default }
        set { defaultsLock.lock(); _default = newValue; defaultsLock.unlock() }
    }

    let configuration: YcodeContactStoreConfiguration
    let db: ContactsDatabase?
    let lock = NSRecursiveLock()
    let storeIdentifier = UUID().uuidString
    private let accessQueue = DispatchQueue.global()

    public init(ycodeConfiguration: YcodeContactStoreConfiguration) {
        configuration = ycodeConfiguration
        db = try? ContactsDatabase(path: ycodeConfiguration.databaseURL.path)
        super.init()
        if let db { ChangeWatcher.shared.register(path: db.path, currentSeq: db.maxSeq()) }
    }

    public override convenience init() {
        self.init(ycodeConfiguration: CNContactStore.ycodeDefaultConfiguration)
    }

    deinit {
        if let db { ChangeWatcher.shared.unregister(path: db.path) }
    }

    // MARK: Authorization (recorded answers; the R6 broker is deferred)

    public class func authorizationStatus(for entityType: CNEntityType) -> CNAuthorizationStatus {
        ycodeDefaultConfiguration.authorizationStatus
    }

    var granted: Bool { configuration.authorizationStatus == .authorized || configuration.authorizationStatus == .limited }

    /// Answers from the recorded status on a global queue (authorization.md §3):
    /// granted for full and for limited access.
    public func requestAccess(for entityType: CNEntityType, completionHandler: @escaping (Bool, (any Error)?) -> Void) {
        let ok = granted
        nonisolated(unsafe) let handler = completionHandler
        accessQueue.async {
            handler(ok, ok ? nil : CNError(.authorizationDenied))
        }
    }

    public func requestAccess(for entityType: CNEntityType) async throws -> Bool {
        guard granted else { throw CNError(.authorizationDenied) }
        return true
    }

    func checkAccess() throws -> ContactsDatabase {
        guard granted else { throw CNError(.authorizationDenied) }
        guard let db else { throw CNError(.dataAccessError) }
        return db
    }

    func isVisible(_ c: StoredContact) -> Bool {
        configuration.authorizationStatus != .limited
            || configuration.limitedContactIdentifiers.contains(c.identifier)
            || c.creator == configuration.bundleIdentifier
    }

    func visibleContacts(_ db: ContactsDatabase) -> [StoredContact] {
        db.allContacts().filter(isVisible)
    }

    // MARK: Identity

    /// The local container; available without access (interface.md §3).
    public func defaultContainerIdentifier() -> String { localContainerIdentifier }

    /// Opaque; available before authorization (interface.md §6.2).
    public var currentHistoryToken: Data? {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return nil }
        return HistoryToken.make(databaseID: db.meta("unique_id") ?? "", seq: db.maxSeq())
    }

    // MARK: Building contacts

    func checkKeys(_ keys: Set<String>) throws {
        if keys.contains(CNContactNoteKey) && !YcodeContactsEnvironment.notesEntitlement {
            throw CNError(.unauthorizedKeys, userInfo: [
                CNErrorUserInfoAffectedRecordsKey: [AnyObject](),
                CNErrorUserInfoKeyPathsKey: [CNContactNoteKey],
            ])
        }
    }

    func makeContact(_ s: StoredContact, keys: Set<String>, mutable: Bool) -> CNContact {
        let data = s.data.restricted(to: keys)
        return mutable
            ? CNMutableContact(identifier: s.identifier, data: data, available: keys)
            : CNContact(identifier: s.identifier, data: data, available: keys)
    }

    // MARK: Fetching

    func fetch(predicate: NSPredicate?, keys descriptors: [CNKeyDescriptor], sortOrder: CNContactSortOrder,
               mutable: Bool) throws -> [CNContact] {
        lock.lock(); defer { lock.unlock() }
        let db = try checkAccess()
        let keys = keySet(descriptors).union([CNContactIdentifierKey])
        try checkKeys(keys)
        var rows = visibleContacts(db)
        if let predicate {
            if let p = predicate as? CNStorePredicate {
                switch p.kind {
                case .name, .email, .phone, .contactIdentifiers:
                    rows = rows.filter { Matching.matches(p.kind, identifier: $0.identifier, data: $0.data, countryCode: configuration.countryCode) }
                case .contactsInGroup(let g):
                    let members = Set(db.members(of: g))
                    rows = rows.filter { members.contains($0.identifier) }
                case .contactsInContainer(let c):
                    rows = rows.filter { $0.containerID == c }
                default:
                    throw CNError(.predicateInvalid)
                }
            } else {
                rows = rows.filter {
                    predicate.evaluate(with: CNContact(identifier: $0.identifier, data: $0.data, available: allContactKeys))
                }
            }
        }
        let order = sortOrder == .userDefault ? CNContactsUserDefaults.shared().sortOrder : sortOrder
        if order != .none {
            rows = rows.enumerated().sorted { a, b in
                let r = NameSorting.compare(keys: NameSorting.key(a.element.data, order: order),
                                            NameSorting.key(b.element.data, order: order))
                return r == .orderedSame ? a.offset < b.offset : r == .orderedAscending
            }.map(\.element)
        }
        return rows.map { makeContact($0, keys: keys, mutable: mutable) }
    }

    /// The contacts matching a predicate (nil: all), in storage order.
    public func unifiedContacts(matching predicate: NSPredicate?, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact] {
        try fetch(predicate: predicate, keys: keys, sortOrder: .none, mutable: false)
    }

    /// Throws code 200 for an unknown or deleted identifier (interface.md §4.1).
    public func unifiedContact(withIdentifier identifier: String, keysToFetch keys: [CNKeyDescriptor]) throws -> CNContact {
        let found = try fetch(predicate: CNStorePredicate(.contactIdentifiers([identifier])), keys: keys, sortOrder: .none, mutable: false)
        guard let c = found.first else { throw CNError(.recordDoesNotExist) }
        return c
    }

    @available(*, unavailable, message: "The me contact is not available on iOS")
    public func unifiedMeContactWithKeys(toFetch keys: [CNKeyDescriptor]) throws -> CNContact {
        throw CNError(.featureNotAvailable)
    }

    /// Synchronous enumeration; set `stop.pointee` to true to end early.
    public func enumerateContacts(with fetchRequest: CNContactFetchRequest,
                                  usingBlock block: (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void) throws {
        let contacts = try fetch(predicate: fetchRequest.predicate, keys: fetchRequest.keysToFetch,
                                 sortOrder: fetchRequest.sortOrder, mutable: fetchRequest.mutableObjects)
        var stop = ObjCBool(false)
        for c in contacts {
            block(c, &stop)
            if stop.boolValue { break }
        }
    }

    /// The contacts as an enumerator, with the history token of the fetch.
    public func enumerator(for request: CNContactFetchRequest) throws -> CNFetchResult<NSEnumerator> {
        lock.lock(); defer { lock.unlock() }
        let token = currentHistoryToken ?? Data()
        let contacts = try fetch(predicate: request.predicate, keys: request.keysToFetch,
                                 sortOrder: request.sortOrder, mutable: request.mutableObjects)
        return CNFetchResult(value: ArrayEnumerator(contacts), currentHistoryToken: token)
    }

    // MARK: Groups and containers

    func makeGroup(_ g: StoredGroup) -> CNGroup { CNGroup(identifier: g.identifier, name: g.name) }

    /// Groups are visible with limited access too (interface.md §3).
    public func groups(matching predicate: NSPredicate?) throws -> [CNGroup] {
        lock.lock(); defer { lock.unlock() }
        let db = try checkAccess()
        var rows = db.groups()
        if let predicate {
            guard let p = predicate as? CNStorePredicate else {
                return rows.map(makeGroup).filter { predicate.evaluate(with: $0) }
            }
            switch p.kind {
            case .groupIdentifiers(let ids): rows = rows.filter { ids.contains($0.identifier) }
            case .groupsInContainer(let c): rows = rows.filter { $0.containerID == c }
            default: throw CNError(.predicateInvalid)
            }
        }
        return rows.map(makeGroup)
    }

    public func containers(matching predicate: NSPredicate?) throws -> [CNContainer] {
        lock.lock(); defer { lock.unlock() }
        let db = try checkAccess()
        let all = db.containers()
        guard let predicate else { return all }
        guard let p = predicate as? CNStorePredicate else { return all.filter { predicate.evaluate(with: $0) } }
        switch p.kind {
        case .containerIdentifiers(let ids):
            return all.filter { ids.contains($0.identifier) }
        case .containerOfContact(let id):
            guard let c = db.contact(id), isVisible(c) else { return [] }
            return all.filter { $0.identifier == c.containerID }
        case .containerOfGroup(let id):
            guard let g = db.group(id) else { return [] }
            return all.filter { $0.identifier == g.containerID }
        default:
            throw CNError(.predicateInvalid)
        }
    }

    // MARK: Saving

    /// Executes the request atomically: any failure rolls everything back
    /// (interface.md §5).
    public func execute(_ saveRequest: CNSaveRequest) throws {
        lock.lock()
        do {
            let db = try checkAccess()
            _ = try apply(saveRequest, db)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        postNotifications(saveRequest)
    }

    private func apply(_ request: CNSaveRequest, _ db: ContactsDatabase) throws -> [String] {
        // Membership changes refer to records as they were before the request.
        let existingGroups = Set(db.groups().map(\.identifier))
        let existingContacts = Set(db.allContacts().filter(isVisible).map(\.identifier))
        let author = request.transactionAuthor
        let writer = ChangeWatcher.processToken
        var saved: [CNMutableContact] = []
        var changed: [String] = []
        let notes = YcodeContactsEnvironment.notesEntitlement
        try db.transaction {
            let txn = db.nextTransactionNumber()
            func fail(_ code: CNError.Code, records: [AnyObject] = [], identifiers: [String]? = nil) -> CNError {
                var info: [String: Any] = [:]
                if !records.isEmpty { info[CNErrorUserInfoAffectedRecordsKey] = records }
                if let identifiers { info[CNErrorUserInfoAffectedRecordIdentifiersKey] = identifiers }
                return CNError(code, userInfo: info)
            }
            func visibleExists(_ id: String) -> Bool {
                guard let c = db.contact(id) else { return false }
                return isVisible(c)
            }
            for op in request.operations {
                switch op {
                case .addContact(let c, let container):
                    let cid = container ?? localContainerIdentifier
                    guard db.containerExists(cid) else { throw fail(.recordDoesNotExist, identifiers: [cid]) }
                    guard !db.contactExists(c.identifier) else { throw fail(.insertedRecordAlreadyExists, records: [c]) }
                    var keys = c.available
                    if !notes { keys.remove(CNContactNoteKey) }
                    try db.insertContact(id: c.identifier, containerID: cid, creator: configuration.bundleIdentifier,
                                         data: c.data.restricted(to: keys))
                    try db.journal(txn: txn, author: author, writer: writer, kind: "contact", op: "add", record: c.identifier, container: cid)
                    saved.append(c)
                    changed.append(c.identifier)
                case .updateContact(let c):
                    guard visibleExists(c.identifier) else { throw fail(.recordDoesNotExist, records: [c]) }
                    var keys = c.changedKeys.intersection(c.available)
                    if !notes { keys.remove(CNContactNoteKey) }
                    try db.updateContact(id: c.identifier, keys: keys, data: c.data)
                    try db.journal(txn: txn, author: author, writer: writer, kind: "contact", op: "update", record: c.identifier)
                    saved.append(c)
                    changed.append(c.identifier)
                case .deleteContact(let c):
                    // Deleting a missing record is not an error.
                    guard visibleExists(c.identifier) else { continue }
                    try db.deleteContact(c.identifier)
                    try db.journal(txn: txn, author: author, writer: writer, kind: "contact", op: "delete", record: c.identifier)
                    changed.append(c.identifier)
                case .addGroup(let g, let container):
                    let cid = container ?? localContainerIdentifier
                    guard db.containerExists(cid) else { throw fail(.recordDoesNotExist, identifiers: [cid]) }
                    guard db.group(g.identifier) == nil else { throw fail(.insertedRecordAlreadyExists, records: [g]) }
                    try db.insertGroup(StoredGroup(identifier: g.identifier, containerID: cid, name: g.name))
                    try db.journal(txn: txn, author: author, writer: writer, kind: "group", op: "add", record: g.identifier, container: cid)
                    changed.append(g.identifier)
                case .updateGroup(let g):
                    guard db.group(g.identifier) != nil else { throw fail(.recordDoesNotExist, records: [g]) }
                    try db.renameGroup(g.identifier, g.name)
                    try db.journal(txn: txn, author: author, writer: writer, kind: "group", op: "update", record: g.identifier)
                    changed.append(g.identifier)
                case .deleteGroup(let g):
                    guard db.group(g.identifier) != nil else { continue }
                    try db.deleteGroup(g.identifier)
                    try db.journal(txn: txn, author: author, writer: writer, kind: "group", op: "delete", record: g.identifier)
                    changed.append(g.identifier)
                case .addMember(let c, let g):
                    guard existingGroups.contains(g.identifier), db.group(g.identifier) != nil else { throw fail(.recordDoesNotExist, records: [g]) }
                    guard existingContacts.contains(c.identifier), db.contactExists(c.identifier) else { throw fail(.recordDoesNotExist, records: [c]) }
                    if db.isMember(group: g.identifier, contact: c.identifier) { continue }
                    try db.addMember(group: g.identifier, contact: c.identifier)
                    try db.journal(txn: txn, author: author, writer: writer, kind: "member", op: "add", record: c.identifier, group: g.identifier)
                    changed.append(g.identifier)
                case .removeMember(let c, let g):
                    guard existingGroups.contains(g.identifier), db.group(g.identifier) != nil else { throw fail(.recordDoesNotExist, records: [g]) }
                    guard existingContacts.contains(c.identifier), db.contactExists(c.identifier) else { throw fail(.recordDoesNotExist, records: [c]) }
                    guard db.isMember(group: g.identifier, contact: c.identifier) else { continue }
                    try db.removeMember(group: g.identifier, contact: c.identifier)
                    try db.journal(txn: txn, author: author, writer: writer, kind: "member", op: "remove", record: c.identifier, group: g.identifier)
                    changed.append(g.identifier)
                }
            }
        }
        for c in saved { c.changedKeys = [] }
        return changed
    }

    // MARK: Notifications (interface.md §6.1)

    private func postNotifications(_ request: CNSaveRequest) {
        // First on the thread that executed the save …
        NotificationCenter.default.post(name: .CNContactStoreDidChange, object: nil, userInfo: [
            notificationSaveIdentifiersKey: [request.saveIdentifier, storeIdentifier],
            notificationSourcesKey: [configuration.bundleIdentifier, ProcessInfo.processInfo.processName],
        ])
        // … then on the main queue, marked as originating externally.
        ChangeWatcher.postExternal()
    }

    // MARK: Change history (interface.md §6.2)

    public func enumerator(for request: CNChangeHistoryFetchRequest) throws -> CNFetchResult<NSEnumerator> {
        lock.lock(); defer { lock.unlock() }
        let db = try checkAccess()
        let keys = keySet(request.additionalContactKeyDescriptors ?? []).union([CNContactIdentifierKey])
        try checkKeys(keys)
        let dbID = db.meta("unique_id") ?? ""
        let now = db.maxSeq()
        let token = HistoryToken.make(databaseID: dbID, seq: now)
        var events: [CNChangeHistoryEvent] = []
        let mutable = request.mutableObjects

        func everything() {
            events.append(CNChangeHistoryDropEverythingEvent())
            for c in visibleContacts(db) {
                events.append(CNChangeHistoryAddContactEvent(contact: makeContact(c, keys: keys, mutable: mutable),
                                                             containerIdentifier: c.containerID))
            }
            if request.includeGroupChanges {
                for g in db.groups() {
                    events.append(CNChangeHistoryAddGroupEvent(group: makeGroup(g), containerIdentifier: g.containerID))
                }
            }
        }

        if let start = request.startingToken {
            if let seq = HistoryToken.parse(start, databaseID: dbID), seq <= now {
                let excluded = Set(request.excludedTransactionAuthors ?? [])
                let rows = db.journalRows(after: seq).filter { $0.author.map { !excluded.contains($0) } ?? true }
                events = coalesce(rows, db: db, keys: keys, mutable: mutable, groups: request.includeGroupChanges)
            } else if configuration.authorizationStatus == .limited {
                everything()
            }
        } else {
            everything()
        }
        return CNFetchResult(value: ArrayEnumerator(events), currentHistoryToken: token)
    }

    /// One event per changed record (its net change since the token), in
    /// the order the records first changed; membership changes as recorded.
    private func coalesce(_ rows: [JournalRow], db: ContactsDatabase, keys: Set<String>, mutable: Bool,
                          groups: Bool) -> [CNChangeHistoryEvent] {
        var order: [String] = []
        var firstOp: [String: String] = [:]
        var container: [String: String] = [:]
        var memberRows: [String: JournalRow] = [:]
        for r in rows {
            if r.kind == "member" {
                let key = "m:\(r.seq)"
                order.append(key)
                memberRows[key] = r
                continue
            }
            let key = (r.kind == "group" ? "g:" : "c:") + r.recordID
            if firstOp[key] == nil {
                firstOp[key] = r.op
                order.append(key)
            }
            if let c = r.containerID { container[key] = c }
        }
        var out: [CNChangeHistoryEvent] = []
        for key in order {
            if key.hasPrefix("m:") {
                guard groups, let r = memberRows[key], let gid = r.groupID else { continue }
                let member = db.contact(r.recordID).flatMap { isVisible($0) ? makeContact($0, keys: keys, mutable: mutable) : nil }
                    ?? CNContact(identifier: r.recordID, data: ContactData(), available: [])
                let group = db.group(gid).map(makeGroup) ?? CNGroup(identifier: gid, name: "")
                out.append(r.op == "add" ? CNChangeHistoryAddMemberToGroupEvent(member: member, group: group)
                                         : CNChangeHistoryRemoveMemberFromGroupEvent(member: member, group: group))
                continue
            }
            let id = String(key.dropFirst(2))
            let added = firstOp[key] == "add"
            if key.hasPrefix("c:") {
                let current = db.contact(id).flatMap { isVisible($0) ? $0 : nil }
                switch (added, current) {
                case (true, let c?):
                    out.append(CNChangeHistoryAddContactEvent(contact: makeContact(c, keys: keys, mutable: mutable),
                                                              containerIdentifier: container[key] ?? c.containerID))
                case (true, nil): break
                case (false, let c?):
                    out.append(CNChangeHistoryUpdateContactEvent(contact: makeContact(c, keys: keys, mutable: mutable)))
                case (false, nil):
                    out.append(CNChangeHistoryDeleteContactEvent(contactIdentifier: id))
                }
            } else if groups {
                switch (added, db.group(id)) {
                case (true, let g?):
                    out.append(CNChangeHistoryAddGroupEvent(group: makeGroup(g), containerIdentifier: container[key] ?? g.containerID))
                case (true, nil): break
                case (false, let g?): out.append(CNChangeHistoryUpdateGroupEvent(group: makeGroup(g)))
                case (false, nil): out.append(CNChangeHistoryDeleteGroupEvent(groupIdentifier: id))
                }
            }
        }
        return out
    }
}

// MARK: - Change watcher

/// Posts the main-queue change notification, and watches each open
/// database's journal for commits by other processes (polling every 200 ms;
/// one main-queue notification per foreign transaction).
final class ChangeWatcher: @unchecked Sendable {
    static let shared = ChangeWatcher()
    /// Identifies this process's journal rows.
    static let processToken = UUID().uuidString
    static let pollInterval: DispatchTimeInterval = .milliseconds(200)

    private final class Entry {
        var count = 0
        var lastSeq: Int64 = 0
        var timer: DispatchSourceTimer?
        var reader: SQLiteConnection?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let pollQueue = DispatchQueue(label: "org.ycode.contacts.change-poll")

    static func postExternal() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .CNContactStoreDidChange, object: nil, userInfo: [
                notificationSaveIdentifiersKey: [String](),
                notificationSourcesKey: [String](),
                notificationOriginationExternallyKey: 1,
            ])
        }
    }

    func register(path: String, currentSeq: Int64) {
        lock.lock(); defer { lock.unlock() }
        let e = entries[path] ?? Entry()
        if entries[path] == nil {
            e.lastSeq = currentSeq
            entries[path] = e
        }
        e.count += 1
        if e.timer == nil {
            let t = DispatchSource.makeTimerSource(queue: pollQueue)
            t.schedule(deadline: .now() + ChangeWatcher.pollInterval, repeating: ChangeWatcher.pollInterval)
            t.setEventHandler { [weak self] in self?.poll(path) }
            e.timer = t
            t.resume()
        }
    }

    func unregister(path: String) {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[path] else { return }
        e.count -= 1
        if e.count <= 0 {
            e.timer?.cancel()
            entries[path] = nil
        }
    }

    private func poll(_ path: String) {
        lock.lock()
        guard let e = entries[path] else { lock.unlock(); return }
        if e.reader == nil { e.reader = try? SQLiteConnection(path: path, readOnly: true) }
        let reader = e.reader
        let since = e.lastSeq
        lock.unlock()
        guard let reader,
              let rows = try? reader.run("SELECT seq, txn, writer FROM journal WHERE seq > ? ORDER BY seq", [.int(since)]),
              !rows.isEmpty else { return }
        lock.lock()
        var foreign = Set<Int64>()
        for r in rows {
            let seq = Int64(r[0].int ?? 0)
            e.lastSeq = max(e.lastSeq, seq)
            if r[2].text != ChangeWatcher.processToken { foreign.insert(Int64(r[1].int ?? 0)) }
        }
        lock.unlock()
        for _ in foreign { ChangeWatcher.postExternal() }
    }
}
