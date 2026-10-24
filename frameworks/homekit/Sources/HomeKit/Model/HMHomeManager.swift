// HMHomeManager (object-model.md §2, simulator-baseline.md §2–§5).

import Foundation

/// object-model.md §2 delegate; every method is optional.
public protocol HMHomeManagerDelegate: AnyObject {
    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus)
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager)
    func homeManagerDidUpdatePrimaryHome(_ manager: HMHomeManager)
    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome)
    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome)
}

public extension HMHomeManagerDelegate {
    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {}
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {}
    func homeManagerDidUpdatePrimaryHome(_ manager: HMHomeManager) {}
    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {}
    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {}
}

open class HMHomeManager: NSObject, @unchecked Sendable {
    public weak var delegate: HMHomeManagerDelegate?
    public private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus = []
    /// Empty until the first `homeManagerDidUpdateHomes`.
    public private(set) var homes: [HMHome] = []

    let connection: YcodeConnection
    /// The client identity this manager connected as.
    public let ycodeClient: YcodeHomeClient

    /// A manager on `YcodeLocalHomeStore.shared` as the current process.
    public override convenience init() {
        self.init(ycodeStore: YcodeLocalHomeStore.shared, client: .processDefault)
    }

    /// A manager on a given store, acting as `client` (tests, tools,
    /// multi-app simulations). A client without a usage string stops the
    /// process, as HomeKit does (simulator-baseline.md §2, HK-B06).
    public init(ycodeStore store: YcodeHomeStore, client: YcodeHomeClient) {
        if client.enforcesRequirements && client.usageDescription == nil {
            fatalError("HomeKit: this app must have an NSHomeKitUsageDescription key in its Info.plist "
                + "explaining how it uses home data. The app was stopped before it could access home data.")
        }
        connection = YcodeConnection(store: store)
        ycodeClient = client
        super.init()
        connection.manager = self
        let session = store.connect(client: client) { [weak self] event in
            onMain { self?.handle(event) }
        }
        connection.sessionID = session.id
        authorizationStatus = HMHomeManagerAuthorizationStatus(rawValue: session.authorizationStatus)
    }

    deinit {
        connection.store.disconnect(connection.sessionID)
    }

    @available(iOS, deprecated: 16.1, message: "No longer supported.")
    public var primaryHome: HMHome? { nil }

    // MARK: Mutations

    public func addHome(withName name: String, completionHandler completion: @escaping (HMHome?, Error?) -> Void) {
        connection.request(.addHome(name: name)) { [weak self] result in
            switch result {
            case .success(.home(let record)): completion(self?.home(record.id), nil)
            case .success: completion(nil, HMError(.unexpectedError))
            case .failure(let e): completion(nil, e)
            }
        }
    }

    public func removeHome(_ home: HMHome, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.removeHome(home.uniqueIdentifier), completion)
    }

    @available(iOS, deprecated: 16.1, message: "No longer supported.")
    public func updatePrimaryHome(_ home: HMHome, completionHandler completion: @escaping (Error?) -> Void) {
        connection.simple(.updatePrimaryHome(home.uniqueIdentifier), completion)
    }

    public func addHome(named name: String) async throws -> HMHome {
        try await asyncCall { addHome(withName: name, completionHandler: $0) }
    }

    public func removeHome(_ home: HMHome) async throws {
        try await asyncCall { removeHome(home, completionHandler: $0) }
    }

    // MARK: Mirror

    func home(_ id: UUID) -> HMHome? { homes.first { $0.uniqueIdentifier == id } }

    func handle(_ event: YcodeHomeEvent) {
        let me = connection.sessionID
        switch event {
        case .authorizationStatus(let raw):
            authorizationStatus = HMHomeManagerAuthorizationStatus(rawValue: raw)
            delegate?.homeManager(self, didUpdate: authorizationStatus)
        case .homesLoaded(let records):
            homes = records.map { r in
                let h = home(r.id) ?? HMHome(id: r.id, connection: connection)
                h.apply(r)
                return h
            }
            delegate?.homeManagerDidUpdateHomes(self)
        case .homeAdded(let record, let origin):
            let h = home(record.id) ?? HMHome(id: record.id, connection: connection)
            h.apply(record)
            if !homes.contains(h) { homes.append(h) }
            if origin != me { delegate?.homeManager(self, didAdd: h) }
        case .homeRemoved(let id, let origin):
            guard let h = home(id) else { return }
            homes.removeAll { $0 === h }
            if let first = homes.first, !homes.contains(where: \.isPrimary) { first.isPrimary = true }
            if origin != me { delegate?.homeManager(self, didRemove: h) }
        case .homeUpdated(let record, let change, let origin):
            guard let h = home(record.id) else { return }
            h.update(record, change: change, notify: origin != me)
        case .characteristicValue(let homeID, _, _, let cid, let value):
            home(homeID)?.receiveValue(characteristic: cid, value: value)
        case .accessoryDiscovered, .accessoryDiscoveryRemoved, .disconnected:
            break
        }
    }
}
