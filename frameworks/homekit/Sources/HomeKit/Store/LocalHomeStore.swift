// The in-process home store (plan.md R3 "in-memory daemon stub"): owns the
// truth for homes and everything in them, authorization answers, published
// accessory endpoints and per-session notification subscriptions. It runs on
// one serial queue; every entry point takes a session, so R4 can move it
// behind IPC unchanged. Optional persistence: a JSON snapshot file.

import Foundation

/// Settings of a `YcodeLocalHomeStore`.
public struct YcodeLocalHomeStoreConfiguration: Sendable {
    /// JSON snapshot written after every change (nil: memory only).
    public var persistenceURL: URL?
    /// Parity mode for Apple's simulator without an Apple Account:
    /// `addHome` fails with 2040 before any name check (simulator-baseline.md §5, T-O4).
    public var simulateNoAccount: Bool
    /// The hub state homes report. The store plays the home hub, so the
    /// default is `.connected` (open-design.md §2 "Scheduler").
    public var hubState: HMHomeHubState
    /// Name of the local home owner (`currentUser`).
    public var ownerName: String
    /// Answers the permission prompt (simulator-baseline.md §3). Default: allow.
    public var consent: @Sendable (YcodeHomeClient) -> Bool

    public init(persistenceURL: URL? = nil, simulateNoAccount: Bool = false, hubState: HMHomeHubState = .connected,
                ownerName: String = "Home Owner", consent: @escaping @Sendable (YcodeHomeClient) -> Bool = { _ in true }) {
        self.persistenceURL = persistenceURL
        self.simulateNoAccount = simulateNoAccount
        self.hubState = hubState
        self.ownerName = ownerName
        self.consent = consent
    }
}

public final class YcodeLocalHomeStore: YcodeHomeStore, YcodeAccessoryEndpointDelegate, @unchecked Sendable {
    /// The store behind `HMHomeManager()`: in memory, or the JSON file named by
    /// `YCODE_HOMEKIT_STORE`.
    public static let shared: YcodeLocalHomeStore = {
        let path = ProcessInfo.processInfo.environment["YCODE_HOMEKIT_STORE"]
        return YcodeLocalHomeStore(configuration: .init(persistenceURL: path.map { URL(fileURLWithPath: $0) }))
    }()

    struct Persisted: Codable {
        var homes: [YcodeHomeRecord] = []
        /// Recorded prompt answers by bundle identifier.
        var answers: [String: Bool] = [:]
    }

    final class Session: @unchecked Sendable {
        let id: UUID
        let client: YcodeHomeClient
        let send: @Sendable (YcodeHomeEvent) -> Void
        var dropped = false
        var browsing = false
        var notifications: Set<UUID> = []
        init(id: UUID, client: YcodeHomeClient, send: @escaping @Sendable (YcodeHomeEvent) -> Void) {
            self.id = id
            self.client = client
            self.send = send
        }
    }

    public let configuration: YcodeLocalHomeStoreConfiguration
    let queue = DispatchQueue(label: "ycode.homekit.store")
    var state = Persisted()
    var sessions: [UUID: Session] = [:]
    var sessionOrder: [UUID] = []
    /// Published endpoints by endpoint ID.
    var endpoints: [String: YcodeAccessoryEndpoint] = [:]
    /// Published, unpaired endpoints (what browsers see), by endpoint ID.
    var discovered: [String: YcodeDiscoveredAccessoryRecord] = [:]
    /// Opaque authorization data per characteristic (not persisted).
    var authorizationData: [UUID: Data] = [:]

    public init(configuration: YcodeLocalHomeStoreConfiguration = .init()) {
        self.configuration = configuration
        if let url = configuration.persistenceURL, let data = try? Data(contentsOf: url),
           var loaded = try? JSONDecoder().decode(Persisted.self, from: data) {
            // Nothing is reachable until its endpoint is published again.
            for h in loaded.homes.indices {
                for a in loaded.homes[h].accessories.indices { loaded.homes[h].accessories[a].isReachable = false }
                for t in loaded.homes[h].actionSets.indices { loaded.homes[h].actionSets[t].isExecuting = false }
            }
            state = loaded
        }
    }

    // MARK: - Ycode API (tests, tools)

    /// Makes an accessory server available: browsers see it until it is
    /// added to a home; if it is already paired, its accessories become reachable.
    public func publish(_ endpoint: YcodeAccessoryEndpoint) {
        queue.async { self._publish(endpoint) }
    }

    /// Withdraws an accessory server: browsers lose it, paired accessories become unreachable.
    public func unpublish(endpointID: String) {
        queue.async {
            self.endpoints[endpointID] = nil
            if let d = self.discovered.removeValue(forKey: endpointID) {
                self.sendToBrowsers(.accessoryDiscoveryRemoved(d.id))
            }
            self.setReachability(endpointID: endpointID, reachable: false)
        }
    }

    /// Runs `body` on the store queue after all work queued so far (tests).
    public func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    /// Current records (tests, tools).
    public var homeRecords: [YcodeHomeRecord] { queue.sync { state.homes } }

    /// Forgets the recorded prompt answer of a bundle (`simctl privacy reset` analogue).
    public func resetAuthorization(bundleIdentifier: String) {
        queue.sync { state.answers[bundleIdentifier] = nil; save() }
    }

    // MARK: - YcodeHomeStore

    public func connect(client: YcodeHomeClient, events: @escaping @Sendable (YcodeHomeEvent) -> Void) -> YcodeHomeSession {
        queue.sync {
            let session = Session(id: UUID(), client: client, send: events)
            sessions[session.id] = session
            sessionOrder.append(session.id)
            let entitled = client.hasHomeKitEntitlement || !client.enforcesRequirements
            var status: HMHomeManagerAuthorizationStatus = []
            if let answer = state.answers[client.bundleIdentifier] {
                if !entitled {
                    // The daemon refuses the connection; the app reads 0 (HK-B08).
                    session.dropped = true
                } else {
                    status = answer ? [.determined, .authorized] : [.determined]
                    if answer { queue.async { self.sendInitialHomes(session) } }
                }
            } else {
                // Prompt: the answer arrives after `connect` returns (HK-B01–B03, B07).
                queue.async {
                    guard self.sessions[session.id] != nil else { return }
                    let answer = self.configuration.consent(client)
                    self.state.answers[client.bundleIdentifier] = answer
                    self.save()
                    let raw: HMHomeManagerAuthorizationStatus = answer ? [.determined, .authorized] : [.determined]
                    session.send(.authorizationStatus(raw.rawValue))
                    if answer {
                        if entitled {
                            self.sendInitialHomes(session)
                        } else {
                            session.dropped = true
                            session.send(.disconnected)
                        }
                    }
                }
            }
            return YcodeHomeSession(id: session.id, authorizationStatus: status.rawValue)
        }
    }

    public func disconnect(_ id: UUID) {
        queue.async {
            guard let s = self.sessions.removeValue(forKey: id) else { return }
            self.sessionOrder.removeAll { $0 == id }
            for c in s.notifications { self.updateEndpointSubscription(characteristic: c) }
        }
    }

    public func perform(_ request: YcodeHomeRequest, session id: UUID,
                        completion: @escaping @Sendable (Result<YcodeHomeResponse, YcodeHomeStoreError>) -> Void) {
        queue.async {
            guard let session = self.sessions[id], self.isAuthorized(session) else {
                completion(.failure(YcodeHomeStoreError(.homeAccessNotAuthorized)))
                return
            }
            self.handle(request, session: session, reply: completion)
        }
    }

    // MARK: - Sessions and events

    func isAuthorized(_ s: Session) -> Bool {
        !s.dropped && state.answers[s.client.bundleIdentifier] == true
    }

    var liveSessions: [Session] {
        sessionOrder.compactMap { sessions[$0] }.filter(isAuthorized)
    }

    func sendInitialHomes(_ s: Session) {
        guard sessions[s.id] != nil, isAuthorized(s) else { return }
        s.send(.homesLoaded(state.homes))
    }

    func broadcast(_ event: YcodeHomeEvent) {
        for s in liveSessions { s.send(event) }
    }

    func sendToBrowsers(_ event: YcodeHomeEvent) {
        for s in liveSessions where s.browsing { s.send(event) }
    }

    func save() {
        guard let url = configuration.persistenceURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Request dispatch

    typealias Reply = @Sendable (Result<YcodeHomeResponse, YcodeHomeStoreError>) -> Void

    func handle(_ request: YcodeHomeRequest, session: Session, reply: @escaping Reply) {
        switch request {
        case .addHome(let name): addHome(name, session, reply)
        case .removeHome(let h): removeHome(h, session, reply)
        case .renameHome(let h, let name):
            mutate(h, session, reply) { home in
                let n = try self.checkedName(name)
                if self.state.homes.contains(where: { $0.id != h && YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.renameWithSimilarName)
                }
                home.name = n
                return .homeName
            }
        case .updatePrimaryHome:
            reply(.failure(YcodeHomeStoreError(.operationNotSupported)))

        case .addRoom(let h, let name):
            mutateReturning(h, session, reply) { home in
                let n = try self.checkedName(name)
                if home.rooms.contains(where: { YcodeNameRules.similar($0.name, n) })
                    || YcodeNameRules.similar(home.defaultRoom.name, n) {
                    throw HMError(.objectWithSimilarNameExistsInHome)
                }
                let room = YcodeRoomRecord(id: UUID(), name: n)
                home.rooms.append(room)
                return (.roomAdded(room.id), .object(room.id))
            }
        case .removeRoom(let h, let r):
            mutate(h, session, reply) { home in
                if r == home.defaultRoom.id { throw HMError(.roomForHomeCannotBeUpdated) }
                guard let i = home.rooms.firstIndex(where: { $0.id == r }) else { throw HMError(.notFound) }
                home.rooms.remove(at: i)
                for a in home.accessories.indices where home.accessories[a].roomID == r {
                    home.accessories[a].roomID = home.defaultRoom.id
                }
                for z in home.zones.indices { home.zones[z].roomIDs.removeAll { $0 == r } }
                return .roomRemoved(r)
            }
        case .renameRoom(let h, let r, let name):
            mutate(h, session, reply) { home in
                if r == home.defaultRoom.id { throw HMError(.roomForHomeCannotBeUpdated) }
                guard let i = home.rooms.firstIndex(where: { $0.id == r }) else { throw HMError(.notFound) }
                let n = try self.checkedName(name)
                if home.rooms.contains(where: { $0.id != r && YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.renameWithSimilarName)
                }
                home.rooms[i].name = n
                return .roomName(r)
            }

        case .addZone(let h, let name):
            mutateReturning(h, session, reply) { home in
                let n = try self.checkedName(name)
                if home.zones.contains(where: { YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.objectWithSimilarNameExistsInHome)
                }
                let zone = YcodeZoneRecord(id: UUID(), name: n, roomIDs: [])
                home.zones.append(zone)
                return (.zoneAdded(zone.id), .object(zone.id))
            }
        case .removeZone(let h, let z):
            mutate(h, session, reply) { home in
                guard let i = home.zones.firstIndex(where: { $0.id == z }) else { throw HMError(.notFound) }
                home.zones.remove(at: i)
                return .zoneRemoved(z)
            }
        case .renameZone(let h, let z, let name):
            mutate(h, session, reply) { home in
                guard let i = home.zones.firstIndex(where: { $0.id == z }) else { throw HMError(.notFound) }
                let n = try self.checkedName(name)
                if home.zones.contains(where: { $0.id != z && YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.renameWithSimilarName)
                }
                home.zones[i].name = n
                return .zoneName(z)
            }
        case .addRoomToZone(let h, let z, let r):
            mutate(h, session, reply) { home in
                guard let i = home.zones.firstIndex(where: { $0.id == z }) else { throw HMError(.notFound) }
                if r == home.defaultRoom.id { throw HMError(.roomForHomeCannotBeInZone) }
                guard home.rooms.contains(where: { $0.id == r }) else { throw HMError(.notFound) }
                if home.zones[i].roomIDs.contains(r) { throw HMError(.alreadyExists) }
                home.zones[i].roomIDs.append(r)
                return .roomAddedToZone(room: r, zone: z)
            }
        case .removeRoomFromZone(let h, let z, let r):
            mutate(h, session, reply) { home in
                guard let i = home.zones.firstIndex(where: { $0.id == z }),
                      home.zones[i].roomIDs.contains(r) else { throw HMError(.notFound) }
                home.zones[i].roomIDs.removeAll { $0 == r }
                return .roomRemovedFromZone(room: r, zone: z)
            }

        case .addServiceGroup(let h, let name):
            mutateReturning(h, session, reply) { home in
                let n = try self.checkedName(name)
                if home.serviceGroups.contains(where: { YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.objectWithSimilarNameExistsInHome)
                }
                let g = YcodeServiceGroupRecord(id: UUID(), name: n, serviceIDs: [])
                home.serviceGroups.append(g)
                return (.serviceGroupAdded(g.id), .object(g.id))
            }
        case .removeServiceGroup(let h, let g):
            mutate(h, session, reply) { home in
                guard let i = home.serviceGroups.firstIndex(where: { $0.id == g }) else { throw HMError(.notFound) }
                home.serviceGroups.remove(at: i)
                return .serviceGroupRemoved(g)
            }
        case .renameServiceGroup(let h, let g, let name):
            mutate(h, session, reply) { home in
                guard let i = home.serviceGroups.firstIndex(where: { $0.id == g }) else { throw HMError(.notFound) }
                let n = try self.checkedName(name)
                if home.serviceGroups.contains(where: { $0.id != g && YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.renameWithSimilarName)
                }
                home.serviceGroups[i].name = n
                return .serviceGroupName(g)
            }
        case .addServiceToGroup(let h, let g, let s):
            mutate(h, session, reply) { home in
                guard let i = home.serviceGroups.firstIndex(where: { $0.id == g }),
                      home.servicePath(s) != nil else { throw HMError(.notFound) }
                if home.serviceGroups[i].serviceIDs.contains(s) { throw HMError(.alreadyExists) }
                home.serviceGroups[i].serviceIDs.append(s)
                return .serviceAddedToGroup(service: s, group: g)
            }
        case .removeServiceFromGroup(let h, let g, let s):
            mutate(h, session, reply) { home in
                guard let i = home.serviceGroups.firstIndex(where: { $0.id == g }),
                      home.serviceGroups[i].serviceIDs.contains(s) else { throw HMError(.notFound) }
                home.serviceGroups[i].serviceIDs.removeAll { $0 == s }
                return .serviceRemovedFromGroup(service: s, group: g)
            }

        case .setBrowsing(let on):
            session.browsing = on
            reply(.success(.discovered(on ? discovered.values.sorted { $0.name < $1.name } : [])))
        case .addAccessory(let h, let d): addAccessory(h, discovered: d, session, reply)
        case .removeAccessory(let h, let a): removeAccessory(h, a, session, reply)
        case .assignAccessory(let h, let a, let r):
            mutate(h, session, reply) { home in
                guard let i = home.accessoryIndex(a) else { throw HMError(.notFound) }
                guard r == home.defaultRoom.id || home.rooms.contains(where: { $0.id == r }) else {
                    throw HMError(.notFound)
                }
                home.accessories[i].roomID = r
                return .accessoryRoom(accessory: a, room: r)
            }
        case .renameAccessory(let h, let a, let name):
            mutate(h, session, reply) { home in
                guard let i = home.accessoryIndex(a) else { throw HMError(.notFound) }
                home.accessories[i].name = try self.checkedName(name)
                return .accessoryName(a)
            }
        case .identifyAccessory(let h, let a): identify(h, a, reply)
        case .unblockAccessory(let h, let a):
            mutate(h, session, reply) { home in
                guard let i = home.accessoryIndex(a) else { throw HMError(.notFound) }
                if home.accessories[i].isBridged { throw HMError(.cannotUnblockNonBridgeAccessory) }
                home.accessories[i].isBlocked = false
                return .accessoryUnblocked(a)
            }
        case .renameService(let h, let s, let name):
            mutate(h, session, reply) { home in
                guard let (a, i) = home.servicePath(s) else { throw HMError(.notFound) }
                home.accessories[a].services[i].name = try self.checkedName(name)
                return .serviceName(accessory: home.accessories[a].id, service: s)
            }
        case .updateAssociatedServiceType(let h, let s, let type):
            mutate(h, session, reply) { home in
                guard let (a, i) = home.servicePath(s) else { throw HMError(.notFound) }
                var normalized: String?
                if let type {
                    guard let entry = YcodeHomeCatalog.serviceType(type) else { throw HMError(.invalidAssociatedServiceType) }
                    normalized = entry.identifier
                }
                home.accessories[a].services[i].associatedType = normalized
                return .associatedServiceType(accessory: home.accessories[a].id, service: s)
            }

        case .readCharacteristic(let h, let c): readCharacteristic(h, c, reply)
        case .writeCharacteristic(let h, let c, let v): writeCharacteristic(h, c, v, session, reply)
        case .enableNotification(let h, let c, let on): enableNotification(h, c, on, session, reply)
        case .updateAuthorizationData(let h, let c, let data):
            guard let home = state.homes.first(where: { $0.id == h }), home.characteristicPath(c) != nil else {
                reply(.failure(YcodeHomeStoreError(.notFound))); return
            }
            authorizationData[c] = data
            reply(.success(.done))

        case .addActionSet, .removeActionSet, .renameActionSet, .addAction, .removeAction,
             .updateActionTarget, .executeActionSet, .addTrigger, .removeTrigger, .renameTrigger,
             .enableTrigger, .addActionSetToTrigger, .removeActionSetFromTrigger, .updateTrigger:
            handleAutomation(request, session: session, reply: reply)
        }
    }

    // MARK: - Mutation helper

    func checkedName(_ name: String) throws -> String {
        switch YcodeNameRules.validate(name) {
        case .success(let n): return n
        case .failure(let e): throw e
        }
    }

    /// Runs `body` on a copy of home `id`; on success stores it, broadcasts the
    /// change (originator tagged) and replies.
    func mutateReturning(_ id: UUID, _ session: Session, _ reply: Reply,
                         _ body: (inout YcodeHomeRecord) throws -> (YcodeHomeChange, YcodeHomeResponse)) {
        guard let i = state.homes.firstIndex(where: { $0.id == id }) else {
            reply(.failure(YcodeHomeStoreError(.notFound))); return
        }
        var home = state.homes[i]
        do {
            let (change, response) = try body(&home)
            state.homes[i] = home
            save()
            broadcast(.homeUpdated(home, change: change, origin: session.id))
            reply(.success(response))
        } catch let e as HMError {
            reply(.failure(YcodeHomeStoreError(e.code, userInfo: e.userInfo)))
        } catch {
            reply(.failure(YcodeHomeStoreError(.unexpectedError)))
        }
    }

    func mutate(_ id: UUID, _ session: Session, _ reply: Reply,
                _ body: (inout YcodeHomeRecord) throws -> YcodeHomeChange) {
        mutateReturning(id, session, reply) { (home: inout YcodeHomeRecord) -> (YcodeHomeChange, YcodeHomeResponse) in
            (try body(&home), .done)
        }
    }

    /// Applies a store-internal change (no originator: every session gets the delegate callback).
    func update(_ id: UUID, change: YcodeHomeChange, _ body: (inout YcodeHomeRecord) -> Void) {
        guard let i = state.homes.firstIndex(where: { $0.id == id }) else { return }
        body(&state.homes[i])
        save()
        broadcast(.homeUpdated(state.homes[i], change: change, origin: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))))
    }

    // MARK: - Homes

    /// Ycode's names for the four built-in scenes (own wording).
    static let builtinActionSets: [(String, String)] = [
        (HMActionSetTypeWakeUp, "Wake Up"),
        (HMActionSetTypeSleep, "Bedtime"),
        (HMActionSetTypeHomeDeparture, "Leaving Home"),
        (HMActionSetTypeHomeArrival, "Arriving Home"),
    ]

    func addHome(_ name: String, _ session: Session, _ reply: Reply) {
        // No account: refused before any name check (simulator-baseline.md §5).
        if configuration.simulateNoAccount { reply(.failure(.noAccount)); return }
        let n: String
        do { n = try checkedName(name) } catch let e as HMError {
            reply(.failure(YcodeHomeStoreError(e.code))); return
        } catch { return }
        if state.homes.contains(where: { YcodeNameRules.similar($0.name, n) }) {
            reply(.failure(YcodeHomeStoreError(.homeWithSimilarNameExists))); return
        }
        let owner = YcodeUserRecord(id: UUID(), name: configuration.ownerName, isAdministrator: true)
        let home = YcodeHomeRecord(
            id: UUID(), name: n, isPrimary: state.homes.isEmpty,
            defaultRoom: YcodeRoomRecord(id: UUID(), name: "Default Room"),
            rooms: [], zones: [], serviceGroups: [], accessories: [],
            actionSets: Self.builtinActionSets.map {
                YcodeActionSetRecord(id: UUID(), name: $0.1, type: $0.0, actions: [], lastExecutionDate: nil, isExecuting: false)
            },
            triggers: [], users: [owner], currentUserID: owner.id, hubState: configuration.hubState.rawValue)
        state.homes.append(home)
        save()
        broadcast(.homeAdded(home, origin: session.id))
        reply(.success(.home(home)))
    }

    func removeHome(_ id: UUID, _ session: Session, _ reply: Reply) {
        guard let i = state.homes.firstIndex(where: { $0.id == id }) else {
            reply(.failure(YcodeHomeStoreError(.notFound))); return
        }
        let home = state.homes.remove(at: i)
        if home.isPrimary, !state.homes.isEmpty { state.homes[0].isPrimary = true }
        for s in sessions.values {
            for a in home.accessories { for svc in a.services { for c in svc.characteristics { s.notifications.remove(c.id) } } }
        }
        save()
        broadcast(.homeRemoved(id, origin: session.id))
        for endpointID in Set(home.accessories.map(\.endpointID)) { releaseEndpoint(endpointID) }
        reply(.success(.done))
    }
}
