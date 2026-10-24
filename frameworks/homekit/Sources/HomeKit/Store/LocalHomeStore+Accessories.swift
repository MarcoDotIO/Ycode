// Accessories in the in-memory store: publishing endpoints, discovery,
// pairing into a home (building records from the attribute database),
// characteristic reads, writes and notifications, reachability.

import Foundation

extension YcodeLocalHomeStore {
    // MARK: Endpoints and discovery

    func pairedHomes(of endpointID: String) -> [Int] {
        state.homes.indices.filter { h in state.homes[h].accessories.contains { $0.endpointID == endpointID } }
    }

    func _publish(_ endpoint: YcodeAccessoryEndpoint) {
        let id = endpoint.endpointID
        endpoints[id] = endpoint
        if pairedHomes(of: id).isEmpty {
            guard discovered[id] == nil else { return }
            let record = YcodeDiscoveredAccessoryRecord(
                id: UUID(), endpointID: id, name: endpoint.name,
                categoryType: YcodeHomeCatalog.categoryType(forHAPCategory: endpoint.categoryNumber))
            discovered[id] = record
            sendToBrowsers(.accessoryDiscovered(record))
        } else {
            endpoint.delegate = self
            setReachability(endpointID: id, reachable: endpoint.isReachable)
        }
    }

    /// After an endpoint's accessories left every home: unpaired again, so
    /// browsers see it (if it is still published).
    func releaseEndpoint(_ endpointID: String) {
        guard pairedHomes(of: endpointID).isEmpty, let endpoint = endpoints[endpointID] else { return }
        endpoint.delegate = nil
        guard discovered[endpointID] == nil else { return }
        let record = YcodeDiscoveredAccessoryRecord(
            id: UUID(), endpointID: endpointID, name: endpoint.name,
            categoryType: YcodeHomeCatalog.categoryType(forHAPCategory: endpoint.categoryNumber))
        discovered[endpointID] = record
        sendToBrowsers(.accessoryDiscovered(record))
    }

    func setReachability(endpointID: String, reachable: Bool) {
        for h in pairedHomes(of: endpointID) {
            let homeID = state.homes[h].id
            for acc in state.homes[h].accessories where acc.endpointID == endpointID && acc.isReachable != reachable {
                update(homeID, change: .accessoryReachability(acc.id)) { home in
                    if let i = home.accessoryIndex(acc.id) { home.accessories[i].isReachable = reachable }
                }
            }
        }
    }

    // MARK: YcodeAccessoryEndpointDelegate

    public func endpoint(_ endpointID: String, didUpdateValues values: [YcodeCharacteristicAddress: YcodeHomeValue]) {
        queue.async {
            for h in self.pairedHomes(of: endpointID) {
                for (address, value) in values {
                    guard let a = self.state.homes[h].accessories.firstIndex(where: {
                        $0.endpointID == endpointID && $0.aid == address.aid
                    }) else { continue }
                    let acc = self.state.homes[h].accessories[a]
                    for (s, svc) in acc.services.enumerated() {
                        guard let c = svc.characteristics.firstIndex(where: { $0.iid == address.iid }) else { continue }
                        self.state.homes[h].accessories[a].services[s].characteristics[c].value = value
                        let cid = svc.characteristics[c].id
                        let event = YcodeHomeEvent.characteristicValue(
                            home: self.state.homes[h].id, accessory: acc.id, service: svc.id, characteristic: cid, value: value)
                        for session in self.liveSessions where session.notifications.contains(cid) { session.send(event) }
                    }
                }
            }
            self.save()
        }
    }

    public func endpoint(_ endpointID: String, didChangeReachability reachable: Bool) {
        queue.async { self.setReachability(endpointID: endpointID, reachable: reachable) }
    }

    // MARK: Pairing

    /// Category of a bridged accessory from its primary service (Ycode table).
    static func category(forPrimaryService type: String?) -> String {
        switch type {
        case HMServiceTypeLightbulb: return HMAccessoryCategoryTypeLightbulb
        case HMServiceTypeOutlet: return HMAccessoryCategoryTypeOutlet
        case HMServiceTypeSwitch: return HMAccessoryCategoryTypeSwitch
        case HMServiceTypeThermostat: return HMAccessoryCategoryTypeThermostat
        case HMServiceTypeLockMechanism: return HMAccessoryCategoryTypeDoorLock
        case HMServiceTypeGarageDoorOpener: return HMAccessoryCategoryTypeGarageDoorOpener
        case HMServiceTypeFan, HMServiceTypeVentilationFan: return HMAccessoryCategoryTypeFan
        case HMServiceTypeWindowCovering: return HMAccessoryCategoryTypeWindowCovering
        case HMServiceTypeDoor: return HMAccessoryCategoryTypeDoor
        case HMServiceTypeWindow: return HMAccessoryCategoryTypeWindow
        case HMServiceTypeSecuritySystem: return HMAccessoryCategoryTypeSecuritySystem
        case HMServiceTypeAirPurifier: return HMAccessoryCategoryTypeAirPurifier
        case HMServiceTypeTemperatureSensor, HMServiceTypeHumiditySensor, HMServiceTypeMotionSensor,
             HMServiceTypeContactSensor, HMServiceTypeLeakSensor, HMServiceTypeLightSensor,
             HMServiceTypeOccupancySensor, HMServiceTypeSmokeSensor, HMServiceTypeCarbonMonoxideSensor,
             HMServiceTypeCarbonDioxideSensor, HMServiceTypeAirQualitySensor:
            return HMAccessoryCategoryTypeSensor
        default: return HMAccessoryCategoryTypeOther
        }
    }

    /// HomeKit records for an attribute database (one per `aid`).
    func records(from db: YcodeAccessoryDatabase, endpoint: YcodeAccessoryEndpoint, room: UUID,
                 primaryID: UUID) -> [YcodeAccessoryRecord] {
        let isBridge = db.accessories.count > 1
        var out: [YcodeAccessoryRecord] = []
        for acc in db.accessories {
            func infoString(_ type: String) -> String? {
                for s in acc.services where s.type == HMServiceTypeAccessoryInformation {
                    if case .string(let v)? = s.characteristics.first(where: { $0.type == type })?.value { return v }
                }
                return nil
            }
            let name = infoString(HMCharacteristicTypeName) ?? endpoint.name
            var serviceIDs: [Int: UUID] = [:]
            for s in acc.services { serviceIDs[s.iid] = UUID() }
            let services = acc.services.map { s -> YcodeServiceRecord in
                var serviceName: String
                if case .string(let v)? = s.characteristics.first(where: { $0.type == HMCharacteristicTypeName })?.value {
                    serviceName = v
                } else {
                    serviceName = name
                }
                if s.type == HMServiceTypeAccessoryInformation { serviceName = name }
                return YcodeServiceRecord(
                    id: serviceIDs[s.iid]!, iid: s.iid, type: s.type, name: serviceName, associatedType: nil,
                    isPrimary: s.isPrimary,
                    isUserInteractive: !s.isHidden && s.type != HMServiceTypeAccessoryInformation,
                    linkedServiceIDs: s.linkedIIDs.compactMap { serviceIDs[$0] },
                    characteristics: s.characteristics.map {
                        YcodeCharacteristicRecord(iid: $0.iid, type: $0.type,
                                                  properties: YcodeHAPPermission.properties($0.permissions),
                                                  metadata: $0.metadata, value: $0.value)
                    })
            }
            let category = acc.aid == 1
                ? YcodeHomeCatalog.categoryType(forHAPCategory: endpoint.categoryNumber)
                : Self.category(forPrimaryService: acc.services.first(where: \.isPrimary)?.type
                    ?? acc.services.first(where: { $0.type != HMServiceTypeAccessoryInformation })?.type)
            let hasIdentify = acc.services.contains { s in
                s.type == HMServiceTypeAccessoryInformation && s.characteristics.contains { $0.type == HMCharacteristicTypeIdentify }
            }
            out.append(YcodeAccessoryRecord(
                id: acc.aid == 1 ? primaryID : UUID(), name: name, categoryType: category,
                manufacturer: infoString(HMCharacteristicTypeManufacturer), model: infoString(HMCharacteristicTypeModel),
                firmwareVersion: infoString(HMCharacteristicTypeFirmwareVersion), roomID: room, services: services,
                isReachable: endpoint.isReachable, isBlocked: false, isBridged: isBridge && acc.aid != 1,
                bridgedAccessoryIDs: [], supportsIdentify: hasIdentify, endpointID: endpoint.endpointID,
                aid: acc.aid, matterNodeID: nil))
        }
        if isBridge, let bridge = out.firstIndex(where: { $0.aid == 1 }) {
            out[bridge].bridgedAccessoryIDs = out.filter { $0.aid != 1 }.map(\.id)
        }
        return out
    }

    func addAccessory(_ homeID: UUID, discovered id: UUID, _ session: Session, _ reply: @escaping Reply) {
        guard state.homes.contains(where: { $0.id == homeID }) else {
            reply(.failure(YcodeHomeStoreError(.notFound))); return
        }
        guard let record = discovered.values.first(where: { $0.id == id }), let endpoint = endpoints[record.endpointID] else {
            // Already paired somewhere, or gone.
            reply(.failure(YcodeHomeStoreError(.notFound))); return
        }
        discovered[record.endpointID] = nil
        endpoint.fetchDatabase { result in
            self.queue.async {
                switch result {
                case .failure(let f):
                    if self.endpoints[record.endpointID] != nil { self.discovered[record.endpointID] = record }
                    reply(.failure(YcodeHomeStoreError(f.errorCode)))
                case .success(let db):
                    guard let h = self.state.homes.firstIndex(where: { $0.id == homeID }) else {
                        self.discovered[record.endpointID] = record
                        reply(.failure(YcodeHomeStoreError(.notFound))); return
                    }
                    let new = self.records(from: db, endpoint: endpoint, room: self.state.homes[h].defaultRoom.id,
                                           primaryID: record.id)
                    endpoint.delegate = self
                    self.sendToBrowsers(.accessoryDiscoveryRemoved(record.id))
                    for acc in new {
                        self.state.homes[h].accessories.append(acc)
                        self.save()
                        self.broadcast(.homeUpdated(self.state.homes[h], change: .accessoryAdded(acc.id), origin: session.id))
                    }
                    reply(.success(.object(record.id)))
                }
            }
        }
    }

    func removeAccessory(_ homeID: UUID, _ accessoryID: UUID, _ session: Session, _ reply: Reply) {
        var endpointID = ""
        mutate(homeID, session, reply) { home in
            guard let i = home.accessoryIndex(accessoryID) else { throw HMError(.notFound) }
            let acc = home.accessories[i]
            if acc.isBridged { throw HMError(.cannotRemoveNonBridgeAccessory) }
            endpointID = acc.endpointID
            let removed = Set([accessoryID] + acc.bridgedAccessoryIDs)
            let gone = home.accessories.filter { removed.contains($0.id) }
            let serviceIDs = Set(gone.flatMap { $0.services.map(\.id) })
            let characteristicIDs = Set(gone.flatMap { $0.services.flatMap { $0.characteristics.map(\.id) } })
            home.accessories.removeAll { removed.contains($0.id) }
            for g in home.serviceGroups.indices { home.serviceGroups[g].serviceIDs.removeAll { serviceIDs.contains($0) } }
            for s in home.actionSets.indices {
                home.actionSets[s].actions.removeAll { characteristicIDs.contains($0.characteristicID) }
            }
            for s in self.sessions.values { s.notifications.subtract(characteristicIDs) }
            return .accessoryRemoved(accessoryID, bridged: acc.bridgedAccessoryIDs)
        }
        if !endpointID.isEmpty { releaseEndpoint(endpointID) }
    }

    func identify(_ homeID: UUID, _ accessoryID: UUID, _ reply: @escaping Reply) {
        guard let home = state.homes.first(where: { $0.id == homeID }), let i = home.accessoryIndex(accessoryID) else {
            reply(.failure(YcodeHomeStoreError(.notFound))); return
        }
        let acc = home.accessories[i]
        guard acc.supportsIdentify else { reply(.failure(YcodeHomeStoreError(.operationNotSupported))); return }
        guard let endpoint = endpoints[acc.endpointID], acc.isReachable else {
            reply(.failure(YcodeHomeStoreError(.accessoryNotReachable))); return
        }
        endpoint.identify { result in
            self.queue.async {
                switch result {
                case .success: reply(.success(.done))
                case .failure(let f): reply(.failure(YcodeHomeStoreError(f.errorCode)))
                }
            }
        }
    }

    // MARK: Characteristic I/O

    struct Located {
        var home: Int
        var accessory: YcodeAccessoryRecord
        var service: YcodeServiceRecord
        var characteristic: YcodeCharacteristicRecord
        var address: YcodeCharacteristicAddress { .init(aid: accessory.aid, iid: characteristic.iid) }
    }

    func locate(_ homeID: UUID, _ characteristicID: UUID) -> Located? {
        guard let h = state.homes.firstIndex(where: { $0.id == homeID }),
              let (a, s, c) = state.homes[h].characteristicPath(characteristicID) else { return nil }
        let acc = state.homes[h].accessories[a]
        return Located(home: h, accessory: acc, service: acc.services[s], characteristic: acc.services[s].characteristics[c])
    }

    func setCachedValue(_ homeID: UUID, _ characteristicID: UUID, _ value: YcodeHomeValue?) {
        guard let h = state.homes.firstIndex(where: { $0.id == homeID }),
              let (a, s, c) = state.homes[h].characteristicPath(characteristicID) else { return }
        state.homes[h].accessories[a].services[s].characteristics[c].value = value
        save()
    }

    /// The endpoint for an accessory, or the failure to report (4 when unreachable).
    func endpoint(for acc: YcodeAccessoryRecord) -> YcodeAccessoryEndpoint? {
        guard acc.isReachable, let e = endpoints[acc.endpointID] else { return nil }
        return e
    }

    func readCharacteristic(_ homeID: UUID, _ cid: UUID, _ reply: @escaping Reply) {
        guard let loc = locate(homeID, cid) else { reply(.failure(YcodeHomeStoreError(.notFound))); return }
        guard loc.characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            reply(.failure(YcodeHomeStoreError(.writeOnlyCharacteristic))); return
        }
        guard let endpoint = endpoint(for: loc.accessory) else {
            reply(.failure(YcodeHomeStoreError(.accessoryNotReachable))); return
        }
        endpoint.read(loc.address) { result in
            self.queue.async {
                switch result {
                case .success(let v):
                    self.setCachedValue(homeID, cid, v)
                    reply(.success(.value(v)))
                case .failure(let f):
                    reply(.failure(YcodeHomeStoreError(f.errorCode)))
                }
            }
        }
    }

    func writeCharacteristic(_ homeID: UUID, _ cid: UUID, _ value: YcodeHomeValue, _ session: Session, _ reply: @escaping Reply) {
        guard let loc = locate(homeID, cid) else { reply(.failure(YcodeHomeStoreError(.notFound))); return }
        guard loc.characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            reply(.failure(YcodeHomeStoreError(.readOnlyCharacteristic))); return
        }
        let checked: YcodeHomeValue
        switch YcodeValueValidation.validate(value.apiValue, metadata: loc.characteristic.metadata) {
        case .success(let v): checked = v
        case .failure(let e): reply(.failure(YcodeHomeStoreError(e.code))); return
        }
        guard let endpoint = endpoint(for: loc.accessory) else {
            reply(.failure(YcodeHomeStoreError(.accessoryNotReachable))); return
        }
        endpoint.write(loc.address, value: checked, authorizationData: authorizationData[cid]) { result in
            self.queue.async {
                switch result {
                case .success:
                    self.didWrite(homeID, loc, checked, origin: session.id)
                    reply(.success(.done))
                case .failure(let f):
                    reply(.failure(YcodeHomeStoreError(f.errorCode)))
                }
            }
        }
    }

    /// After a successful write: cache it and notify the other subscribed sessions.
    func didWrite(_ homeID: UUID, _ loc: Located, _ value: YcodeHomeValue, origin: UUID?) {
        let readable = loc.characteristic.properties.contains(HMCharacteristicPropertyReadable)
        if readable { setCachedValue(homeID, loc.characteristic.id, value) }
        let event = YcodeHomeEvent.characteristicValue(home: homeID, accessory: loc.accessory.id, service: loc.service.id,
                                                       characteristic: loc.characteristic.id, value: value)
        for s in liveSessions where s.id != origin && s.notifications.contains(loc.characteristic.id) { s.send(event) }
    }

    func enableNotification(_ homeID: UUID, _ cid: UUID, _ on: Bool, _ session: Session, _ reply: @escaping Reply) {
        guard let loc = locate(homeID, cid) else { reply(.failure(YcodeHomeStoreError(.notFound))); return }
        guard loc.characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) else {
            reply(.failure(YcodeHomeStoreError(.notificationNotSupported))); return
        }
        if !on {
            session.notifications.remove(cid)
            updateEndpointSubscription(characteristic: cid)
            reply(.success(.done)); return
        }
        guard let endpoint = endpoint(for: loc.accessory) else {
            reply(.failure(YcodeHomeStoreError(.accessoryNotReachable))); return
        }
        endpoint.setEventsEnabled(true, for: loc.address) { result in
            self.queue.async {
                switch result {
                case .success:
                    session.notifications.insert(cid)
                    reply(.success(.done))
                case .failure(let f):
                    reply(.failure(YcodeHomeStoreError(f.errorCode)))
                }
            }
        }
    }

    /// Turns the endpoint's events off when no session wants them any more.
    func updateEndpointSubscription(characteristic cid: UUID) {
        guard !sessions.values.contains(where: { $0.notifications.contains(cid) }) else { return }
        for h in state.homes {
            guard let loc = locate(h.id, cid), let e = endpoints[loc.accessory.endpointID] else { continue }
            e.setEventsEnabled(false, for: loc.address) { _ in }
        }
    }
}
