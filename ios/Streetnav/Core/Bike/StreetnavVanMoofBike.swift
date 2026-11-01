import CoreBluetooth
import CryptoKit
import Foundation

/// The VanMoof S6 over Bluetooth: finds it, proves who we are with the account's certificate, reads its state and
/// unlocks it. Streetnav only ever writes the certificate exchange and the wake command (which unlocks); everything
/// else is read, so that nothing can change the bike's settings, alarm or firmware.
@MainActor
final class StreetnavVanMoofBike: NSObject, ObservableObject {
    static let shared = StreetnavVanMoofBike()

    enum State: Equatable {
        case idle, searching, connecting, authenticating, ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var battery: Int?
    @Published private(set) var isLocked: Bool?
    @Published private(set) var odometerMeters: Int?
    @Published private(set) var firmware: String?

    private typealias P = StreetnavVanMoofProtocol

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var key: Curve25519.Signing.PrivateKey?
    private var certificate: Data?
    private var pendingWrites: [Data] = []
    private var isWriting = false
    private var reassembler = P.Reassembler()
    private var messageID: UInt8 = 0
    private var fragmentID: UInt8 = 0
    private var deadline: Task<Void, Never>?
    private var lockWaiters: [CheckedContinuation<Bool?, Never>] = []

    /// Connects and authenticates; `ready` once the bike accepted the certificate.
    func connect() async {
        guard state == .idle || state.isFailure else { return }
        do {
            (certificate, key) = try await StreetnavVanMoofAccount.shared.credentials()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .searching
        if let central, central.state == .poweredOn {
            scan()
        } else if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        expire(after: 20, "Vélo introuvable : est-il réveillé et à portée, et l'app VanMoof fermée ?")
    }

    func disconnect() {
        deadline?.cancel()
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(to: .idle)
    }

    /// Wakes the bike, which unlocks it. True once the bike reports its lock open.
    @discardableResult
    func unlock() async -> Bool {
        if state != .ready { await connect() }
        guard await waitUntilReady() else { return false }
        send(.set, .wake, P.valuePayload([1]))
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard Task.isCancelled == false, let self else { return }
            self.lockWaiters.forEach { $0.resume(returning: nil) }
            self.lockWaiters.removeAll()
        }
        let locked = await withCheckedContinuation { lockWaiters.append($0) }
        timeout.cancel()
        if locked == nil {
            // No news from the bike: ask it.
            request(.lockState)
            try? await Task.sleep(for: .seconds(2))
        }
        return (locked ?? isLocked) == false
    }

    /// Asks the bike for the values Streetnav shows.
    func refresh() {
        guard state == .ready else { return }
        for topic in [P.Topic.batteryLevel, .lockState, .distance, .firmware] { request(topic) }
    }

    // MARK: Flow

    private func scan() {
        // Unfiltered: the S6 may not advertise its service, so match its name or its service below.
        central?.scanForPeripherals(withServices: nil)
    }

    private func found(_ peripheral: CBPeripheral) {
        central?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central?.connect(peripheral)
    }

    private func ready(_ characteristic: CBCharacteristic) {
        self.characteristic = characteristic
        state = .authenticating
        guard let certificate else { return }
        send(.set, .auth, P.certificatePayload(certificate))
    }

    private func received(_ message: P.Message) {
        guard message.type == .publish else { return }
        switch P.Topic(rawValue: message.topic) {
        case .auth:
            switch P.authReply(message.payload) {
            case .challenge(let challenge)?:
                guard let key, let signature = try? key.signature(for: challenge) else { return fail("Signature impossible.") }
                send(.set, .auth, P.signaturePayload(signature))
            case .accepted?:
                deadline?.cancel()
                state = .ready
                refresh()
            case .rejected?:
                fail("Le vélo a refusé le certificat : reconnecte ton compte VanMoof.")
            case nil:
                break
            }
        case .lockState:
            let locked = firstInt(message.payload).map { $0 != 0 }
            isLocked = locked
            lockWaiters.forEach { $0.resume(returning: locked) }
            lockWaiters.removeAll()
        case .batteryLevel: battery = firstInt(message.payload)
        case .distance: odometerMeters = firstInt(message.payload)
        case .firmware:
            if case .text(let version)? = P.fields(of: message.payload)?.first { firmware = version }
        default: break
        }
    }

    private func request(_ topic: P.Topic) { send(.get, topic, Data()) }

    private func send(_ type: P.MessageType, _ topic: P.Topic, _ payload: Data) {
        guard let peripheral else { return }
        let message = P.encode(.init(type: type, topic: topic.rawValue, payload: payload, id: messageID))
        messageID &+= 1
        pendingWrites += P.fragments(of: message, maxWrite: peripheral.maximumWriteValueLength(for: .withoutResponse),
                                     fragmentID: fragmentID)
        fragmentID = fragmentID >= 127 ? 1 : fragmentID + 1
        writeNext()
    }

    /// One fragment at a time, each acknowledged, as the official app does.
    private func writeNext() {
        guard isWriting == false, let peripheral, let characteristic, pendingWrites.isEmpty == false else { return }
        let fragment = pendingWrites.removeFirst()
        if characteristic.properties.contains(.write) {
            isWriting = true
            peripheral.writeValue(fragment, for: characteristic, type: .withResponse)
        } else {
            peripheral.writeValue(fragment, for: characteristic, type: .withoutResponse)
            writeNext()
        }
    }

    private func firstInt(_ payload: Data) -> Int? {
        if case .int(let value)? = P.fields(of: payload)?.first { return value }
        return nil
    }

    private func waitUntilReady() async -> Bool {
        for _ in 0..<60 where state != .ready {
            if state.isFailure || state == .idle { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return state == .ready
    }

    private func expire(after seconds: Double, _ reason: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard Task.isCancelled == false, let self, self.state != .ready, self.state.isFailure == false else { return }
            self.fail(reason)
        }
    }

    private func fail(_ reason: String) {
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(to: .failed(reason))
    }

    private func reset(to state: State) {
        peripheral = nil
        characteristic = nil
        pendingWrites.removeAll()
        isWriting = false
        reassembler = P.Reassembler()
        messageID = 0
        lockWaiters.forEach { $0.resume(returning: nil) }
        lockWaiters.removeAll()
        self.state = state
    }
}

extension StreetnavVanMoofBike.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// Core Bluetooth calls back on the main queue (the manager has no queue of its own).
extension StreetnavVanMoofBike: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: if state == .searching { scan() }
            case .unauthorized: fail("Autorise Streetnav à utiliser le Bluetooth dans Réglages.")
            case .poweredOff: fail("Active le Bluetooth.")
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "").uppercased()
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let isVanMoof = name.contains("VANMOOF") || services.contains { $0.hasPrefix("DF2861") }
        MainActor.assumeIsolated {
            if isVanMoof, state == .searching { found(peripheral) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(StreetnavVanMoofProtocol.serviceUUIDs.map { CBUUID(string: $0) })
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { fail("Connexion au vélo impossible.") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if state == .ready || state == .authenticating { reset(to: error == nil ? .idle : .failed("Le vélo s'est déconnecté.")) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
        if peripheral.services?.isEmpty ?? true {
            MainActor.assumeIsolated { fail("Ce vélo ne présente pas le service VanMoof S6.") }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: {
            $0.uuid.uuidString.hasPrefix(StreetnavVanMoofProtocol.characteristicPrefix)
        }) else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if error != nil || characteristic.isNotifying == false { return fail("Le vélo refuse les notifications.") }
            ready(characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        MainActor.assumeIsolated {
            if let data = reassembler.feed(value), let message = StreetnavVanMoofProtocol.decode(data) { received(message) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            isWriting = false
            if error != nil { return fail("Écriture refusée par le vélo.") }
            writeNext()
        }
    }
}
