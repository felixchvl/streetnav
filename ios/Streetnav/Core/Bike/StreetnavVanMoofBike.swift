import CoreBluetooth
import CryptoKit
import Foundation
import UIKit

/// The VanMoof S6 over Bluetooth: finds it, proves who we are with the account's certificate, reads its state and
/// settings, and changes them when asked: unlock, assistance, lights, bell, alarm and charge limit. Streetnav writes
/// only the registers whose values both community references agree on, and only on a tap of the rider; the others
/// (speed, motor and wake states, bell mode, notification interval) are read and shown as the bike sends them.
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
    /// True while only the bike's Bluetooth answers (`P.Topic.access` 1 · 7): it then ignores every request and the unlock
    /// until it wakes, from one of its buttons or, says VanMoof, for an iPhone paired with it in the Bluetooth settings.
    @Published private(set) var isAsleep: Bool?
    @Published private(set) var odometerMeters: Int?
    @Published private(set) var firmware: String?
    /// 0 off, 1 eco, 2 normal, 3 sport, 4 turbo.
    @Published private(set) var assistLevel: Int?
    /// 0 off, 2 on, 3 automatic.
    @Published private(set) var lightMode: Int?
    @Published private(set) var alarmOn: Bool?
    /// 1 high, 2 medium, 4 low.
    @Published private(set) var alarmSensitivity: Int?
    /// %: 80, 85, 90, 95 or 100.
    @Published private(set) var chargeLimit: Int?
    /// As the bike sends it: its unit is undocumented.
    @Published private(set) var speed: String?
    /// The speed in km/h, once its unit is known (`noteGPS`): nil until then, or when the bike has not sent it lately.
    @Published private(set) var speedKmh: Double?
    /// Diagnostic trouble codes: (device class << 8) | subcode.
    @Published private(set) var errorCodes: [Int]?
    /// What happened on the Bluetooth link, step by step and message by message, to see where it stops (Réglages ›
    /// VanMoof › Journal Bluetooth). The certificate and the signature are never written in it, only their size.
    @Published private(set) var log: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    /// Undocumented registers, as the bike sends them.
    @Published private(set) var motorState: String?
    @Published private(set) var bellMode: String?
    @Published private(set) var notifyInterval: String?

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
    /// When each value was last asked for and not yet answered, so that it is not asked again within a second.
    private var pendingReads: [UInt16: Date] = [:]
    /// The bike's first notifications of a connection go raw into the journal, to see what it sends as it sends it.
    private var rawNotes = 0
    /// A refused certificate is tried once more, on a new connection, before giving up.
    private var authRetried = false
    /// The bike's characteristics outside its message service, read once per connection to see what they hold.
    private var otherCharacteristics: [CBCharacteristic] = []
    /// Between the end of a connection and the next one, on such a retry: an unlock waits instead of giving up.
    private var retrying = false
    /// After the certificate is accepted, the access the bike grants is awaited a moment.
    private var accessWait: Task<Void, Never>?
    private var fragmentID: UInt8 = 0
    private var deadline: Task<Void, Never>?
    private var lockWaiters: [CheckedContinuation<Bool?, Never>] = []
    /// The GPS speed of the moment, km/h, to find the unit of the bike's own (`calibrate`).
    private var gpsSpeed: (kmh: Double, at: Date)?
    private var unitVotes: [Double: Int] = [:]
    private static let speedFactorKey = "streetnav.vanmoof.speedFactor"
    /// The bike's speed times this is km/h, once found; the units it could be in: km/h, tenths and hundredths of km/h,
    /// m/s, tenths and hundredths of m/s.
    private var speedFactor: Double? = UserDefaults.standard.object(forKey: speedFactorKey) as? Double
    private static let speedUnits = [1, 0.1, 0.01, 3.6, 0.36, 0.036]

    /// The journal of the last connections, read back from the file it is kept in: still there after a relaunch.
    override init() {
        super.init()
        log = Self.savedJournal()
    }

    /// Connects when the account is set up and the bike not yet connected: at launch and when guidance starts, so that
    /// the map and the navigation show the bike at once. The bike takes one connection at a time.
    func connectIfSignedIn() async {
        guard StreetnavVanMoofAccount.shared.isSignedIn, state == .idle || state.isFailure else { return }
        await connect()
    }

    /// Connects and authenticates; `ready` once the bike accepted the certificate.
    func connect() async {
        guard state == .idle || state.isFailure else { return }
        note("Connexion demandée")
        do {
            (certificate, key) = try await StreetnavVanMoofAccount.shared.credentials()
            note("Certificat VanMoof prêt (\(certificate?.count ?? 0) octets)")
        } catch {
            note("Certificat VanMoof indisponible : \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return
        }
        note("Recherche du vélo…")
        state = .searching
        if let central, central.state == .poweredOn {
            scan()
        } else if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        expire(after: 20, "Vélo introuvable : est-il réveillé et à portée, et l'app VanMoof fermée ?")
    }

    func disconnect() {
        if state != .idle { note("Déconnexion demandée") }
        authRetried = false
        retrying = false
        deadline?.cancel()
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(to: .idle)
    }

    /// Wakes the bike, which unlocks it. True once the bike reports its lock open (lock state or kick lock at 0). Sent as
    /// the official app sent it in a capture of 8 Nov 2026 (a SET with QoS 1 of the bare array [1]), then once more "at
    /// least once" (QoS 0), which the bike acknowledges: the journal then shows whether it got it. A sleeping bike gets more time, to be woken from a button,
    /// and the wake again as soon as it is up.
    @discardableResult
    func unlock() async -> Bool {
        #if DEBUG
        // Development: the sample bike opens after a moment (-sampleUnlockFails YES: it never answers; -sampleAsleep YES:
        // it sleeps through it).
        if UserDefaults.standard.bool(forKey: "sampleBike") {
            isAsleep = UserDefaults.standard.bool(forKey: "sampleAsleep") ? true : isAsleep
            try? await Task.sleep(for: .seconds(isAsleep == true ? 4 : 1.2))
            if UserDefaults.standard.bool(forKey: "sampleUnlockFails") || isAsleep == true { return false }
            isLocked = false
            return true
        }
        #endif
        if state != .ready { await connect() }
        guard await waitUntilReady() else { return false }
        sendWake()
        let again = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard Task.isCancelled == false, let self, self.state == .ready, self.lockWaiters.isEmpty == false else { return }
            self.sendWake(qos: 0)
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            // Asleep, the bike may yet be woken from one of its buttons: a while longer.
            if self?.isAsleep == true { try? await Task.sleep(for: .seconds(12)) }
            guard Task.isCancelled == false, let self else { return }
            self.lockWaiters.forEach { $0.resume(returning: nil) }
            self.lockWaiters.removeAll()
        }
        let locked = await withCheckedContinuation { lockWaiters.append($0) }
        again.cancel()
        timeout.cancel()
        if locked == nil {
            note(isAsleep == true ? "Pas d'ouverture : le vélo dort toujours" : "Pas d'ouverture annoncée par le vélo")
            // No news from the bike: ask it.
            request(.kickLock)
            try? await Task.sleep(for: .seconds(2))
        }
        return (locked ?? isLocked) == false
    }

    private func sendWake(qos: UInt8 = 1) {
        send(.set, .wake, P.wakePayload, qos: qos)
    }

    /// Asks the bike for the values Streetnav shows.
    func refresh() {
        guard state == .ready else { return }
        let topics: [P.Topic] = [.batteryLevel, .lockState, .distance, .firmware, .assistLevel, .lightMode, .alarm,
                                 .alarmSensitivity, .chargeLimit, .speed, .errors, .motorState, .kickLock, .bellMode,
                                 .notifyInterval]
        for topic in topics { request(topic) }
    }

    /// The speed again, while the rider watches it: the S6 sends nothing unasked, so twice a second, as the official
    /// app shows it.
    func refreshSpeed() {
        if state == .ready { request(.speed) }
    }

    #if DEBUG
    /// Development: -sampleBike YES shows the bike connected with sample values, to lay the screens out without it.
    func showSampleIfAsked() {
        guard UserDefaults.standard.bool(forKey: "sampleBike") else { return }
        state = .ready
        battery = Int(UserDefaults.standard.string(forKey: "sampleBattery") ?? "") ?? 78
        isLocked = UserDefaults.standard.bool(forKey: "sampleLocked")
        odometerMeters = 2_345_600
        assistLevel = 1
        lightMode = 3
        speedKmh = 18.4
        chargeLimit = 80
        alarmOn = false
        alarmSensitivity = 2
        for line in ["Exemple de journal (-sampleBike)", "Recherche du vélo…", "Vélo trouvé : « VANMOOF S6 », signal -58 dBm",
                     "Connecté, recherche du service VanMoof", "Notifications activées", "Envoi du certificat (169 octets)",
                     "Défi du vélo reçu, envoi de la signature", "Certificat accepté : vélo prêt",
                     "→ get batteryLevel (0x022A)", "← publish batteryLevel (0x022A) : 78"] {
            note(line)
        }
    }
    #endif

    /// What the map and the navigation show, now and then.
    func refreshStatus() {
        guard state == .ready else { return }
        for topic in [P.Topic.batteryLevel, .lockState, .assistLevel, .lightMode] { request(topic) }
    }

    /// The GPS speed, to find the unit the bike sends its own in: once eight readings above 9 km/h agree on one unit, it
    /// is kept for good.
    func noteGPS(speedKmh: Double) {
        gpsSpeed = (speedKmh, Date())
    }

    private func calibrate(raw: Double) {
        guard speedFactor == nil, raw > 0, let gps = gpsSpeed, Date().timeIntervalSince(gps.at) < 1.5, gps.kmh >= 9 else { return }
        guard let unit = Self.speedUnits.first(where: { abs(gps.kmh / (raw * $0) - 1) < 0.2 }) else { return }
        unitVotes[unit, default: 0] += 1
        let others = unitVotes.filter { $0.key != unit }.values.reduce(0, +)
        if unitVotes[unit, default: 0] >= 8, others <= 2 {
            speedFactor = unit
            UserDefaults.standard.set(unit, forKey: Self.speedFactorKey)
        }
    }

    func setAssistLevel(_ level: Int) { set(.assistLevel, [level], allowed: 0...4) }
    func setLightMode(_ mode: Int) { set(.lightMode, [mode, 1], allowed: [0, 2, 3]) }
    func setAlarm(_ on: Bool) { set(.alarm, [on ? 1 : 0], allowed: 0...1) }
    func setAlarmSensitivity(_ level: Int) { set(.alarmSensitivity, [level], allowed: [1, 2, 4]) }
    func setChargeLimit(_ percent: Int) { set(.chargeLimit, [percent], allowed: [80, 85, 90, 95, 100]) }

    func ringBell() {
        if state == .ready { send(.set, .bell, P.valuePayload([1])) }
    }

    /// A documented value only, then the register read back so that the screen shows what the bike kept.
    private func set(_ topic: P.Topic, _ fields: [Int], allowed: some Collection<Int>) {
        guard state == .ready, let value = fields.first, allowed.contains(value) else { return }
        send(.set, topic, P.valuePayload(fields))
        request(topic)
    }

    // MARK: Flow

    private func scan() {
        // In the background (a ride started on the Watch), iOS runs no scan without a service, which the S6 may not
        // advertise: the bike met before is reached directly instead.
        if UIApplication.shared.applicationState == .background,
           let known = UserDefaults.standard.string(forKey: Self.knownBikeKey).flatMap(UUID.init(uuidString:)),
           let peripheral = central?.retrievePeripherals(withIdentifiers: [known]).first {
            note("Vélo déjà connu, connexion directe")
            found(peripheral, signal: 0)
            return
        }
        // Unfiltered: the S6 may not advertise its service, so match its name or its service below.
        central?.scanForPeripherals(withServices: nil)
    }

    /// The bike's Bluetooth identifier on this iPhone, kept from its last connection.
    private static let knownBikeKey = "streetnav.vanmoof.peripheral"

    private func found(_ peripheral: CBPeripheral, signal: Int) {
        note("Connexion au vélo…")
        expire(after: 15, signal < -85 ? "Signal trop faible (\(signal) dBm) : rapproche-toi du vélo."
                                       : "Le vélo ne répond pas à la connexion : réveille-le et réessaie.")
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
        note("Envoi du certificat (\(certificate.count) octets)")
        send(.set, .auth, P.certificatePayload(certificate))
    }

    private func received(_ message: P.Message) {
        if message.type == .ack {
            return note("← accusé de réception #\(message.id)")
        }
        let topic = P.Topic(rawValue: message.topic)
        if topic != .auth, quiet(topic) == false {
            note("← \(message.type) \(Self.name(message.topic)) #\(message.id) qos \(message.qos) : \(P.raw(message.payload))")
        }
        // QoS 0 is "at least once" in this protocol: the bike sends it again until it is acknowledged.
        if message.qos == 0 {
            write(.init(type: .ack, topic: message.topic, id: message.id), label: "ack \(Self.name(message.topic)) #\(message.id)")
        }
        guard message.type == .publish else { return }
        pendingReads[message.topic] = nil
        switch topic {
        case .auth:
            switch P.authReply(message.payload) {
            case .challenge(let challenge)?:
                note("Défi du vélo reçu, envoi de la signature")
                guard let key, let signature = try? key.signature(for: challenge) else { return fail("Signature impossible.") }
                send(.set, .auth, P.signaturePayload(signature))
            case .accepted?:
                note("Certificat accepté")
                authRetried = false
                deadline?.cancel()
                // Ready once the bike says what it grants (`access`), which follows at once; without it, after a second.
                accessWait?.cancel()
                accessWait = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard Task.isCancelled == false, let self, self.state == .authenticating else { return }
                    self.note("Pas d'accès annoncé par le vélo : vélo prêt")
                    self.becomeReady()
                }
            case .rejected?:
                note("Certificat refusé par le vélo")
                guard authRetried == false else {
                    return fail("Le vélo a refusé le certificat : reconnecte ton compte VanMoof.")
                }
                // It was refused once and taken on the next connection: try again before giving up.
                authRetried = true
                note("Nouvel essai sur une nouvelle connexion")
                retryOnNewConnection()
            case nil:
                note("Réponse d'authentification illisible (\(message.payload.count) octets)")
            }
        case .access:
            // [systems up, all of them]: 7 · 7 when the bike is awake and answers everything; 1 · 7 when only its
            // Bluetooth is, which then answers nothing, even on a new connection (journals of 6 and 7 Nov 2026).
            let fields = (P.fields(of: message.payload) ?? []).compactMap { field -> Int? in
                if case .int(let value) = field { value } else { nil }
            }
            guard fields.count >= 2 else { break }
            let asleep = fields[0] < fields[1]
            let woke = isAsleep == true && asleep == false
            if asleep != isAsleep {
                note(asleep ? "Vélo endormi (\(fields[0]) sur \(fields[1])) : seul son Bluetooth répond"
                            : "Vélo réveillé (\(fields[0]) sur \(fields[1]))")
            }
            isAsleep = asleep
            if state == .authenticating {
                accessWait?.cancel()
                becomeReady()
            } else if woke, state == .ready {
                refresh()
                // Woken during an unlock: the wake again, now that it is heard.
                if lockWaiters.isEmpty == false { sendWake() }
            }
        case .lockState, .kickLock:
            let locked = firstInt(message.payload).map { $0 != 0 }
            isLocked = locked
            lockWaiters.forEach { $0.resume(returning: locked) }
            lockWaiters.removeAll()
        case .batteryLevel: battery = firstInt(message.payload)
        case .distance: odometerMeters = firstInt(message.payload)
        case .firmware:
            if case .text(let version)? = P.fields(of: message.payload)?.first { firmware = version }
        case .assistLevel: assistLevel = firstInt(message.payload)
        case .lightMode: lightMode = firstInt(message.payload)
        case .alarm: alarmOn = firstInt(message.payload).map { $0 != 0 }
        case .alarmSensitivity: alarmSensitivity = firstInt(message.payload)
        case .chargeLimit: chargeLimit = firstInt(message.payload)
        case .speed:
            speed = P.raw(message.payload)
            let raw: Double? = switch P.fields(of: message.payload)?.first {
            case .int(let value)?: Double(value)
            case .double(let value)?: value
            default: nil
            }
            if let raw {
                calibrate(raw: raw)
                speedKmh = speedFactor.map { raw * $0 }
            }
        case .errors:
            errorCodes = (P.fields(of: message.payload) ?? []).flatMap { field -> [Int] in
                switch field {
                case .int(let code): code == 0 ? [] : [code]
                case .array(let items): items.compactMap { if case .int(let code) = $0, code != 0 { code } else { nil } }
                default: []
                }
            }
        case .motorState: motorState = P.raw(message.payload)
        case .bellMode: bellMode = P.raw(message.payload)
        case .notifyInterval: notifyInterval = P.raw(message.payload)
        default: break
        }
    }

    /// A GET, unless the same value was asked for less than a second ago and is still awaited.
    private func request(_ topic: P.Topic) {
        if let asked = pendingReads[topic.rawValue], Date().timeIntervalSince(asked) < 1 { return }
        pendingReads[topic.rawValue] = Date()
        send(.get, topic, Data())
    }

    private func send(_ type: P.MessageType, _ topic: P.Topic, _ payload: Data, qos: UInt8 = 1) {
        let label = topic == .auth || quiet(topic) ? nil
            : "\(type) \(Self.name(topic.rawValue))\(payload.isEmpty ? "" : " " + payload.map { String(format: "%02X", $0) }.joined())"
                + (qos == 0 ? " #\(messageID) qos 0" : "")
        write(.init(type: type, topic: topic.rawValue, payload: payload, id: messageID, qos: qos), label: label)
        messageID &+= 1
    }

    private func becomeReady() {
        state = .ready
        if isAsleep != true { refresh() }
        readOtherCharacteristics()
    }

    /// Once per connection, the bike's other characteristics are read and their size written in the journal. Should one
    /// of them need a paired iPhone, iOS asks to pair with the bike, as VanMoof asks for its auto-wake.
    private func readOtherCharacteristics() {
        guard let peripheral else { return }
        for characteristic in otherCharacteristics where characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
        otherCharacteristics.removeAll()
    }

    /// Ends this connection and starts another a second later; an unlock under way waits for it.
    private func retryOnNewConnection() {
        deadline?.cancel()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(to: .idle)
        retrying = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            await connect()
            retrying = false
        }
    }

    /// Encodes a message, cuts it into fragments and queues them; `label` goes in the journal.
    private func write(_ message: P.Message, label: String?) {
        guard let peripheral else { return }
        if let label { note("→ \(label)") }
        pendingWrites += P.fragments(of: P.encode(message), maxWrite: peripheral.maximumWriteValueLength(for: .withoutResponse),
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

    private func note(_ text: String) {
        let entry = LogEntry(date: Date(), text: text)
        log.append(entry)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        Self.save(entry)
    }

    func clearLog() {
        log.removeAll()
        try? FileManager.default.removeItem(at: Self.journalFile)
    }

    // MARK: Journal file

    /// In the app's documents, so that it outlives a relaunch or a reinstall and can be copied off the iPhone. Holds
    /// what the journal shows: steps and messages, never the certificate or the signature.
    private static let journalFile = URL.documentsDirectory.appending(path: "journal-velo.txt")

    /// One line per entry: the date (ISO 8601, milliseconds), a tab, the text.
    private static let journalDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func save(_ entry: LogEntry) {
        let line = Data("\(entry.date.formatted(journalDate))\t\(entry.text.replacingOccurrences(of: "\n", with: " "))\n".utf8)
        if let handle = try? FileHandle(forWritingTo: journalFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: journalFile, options: .atomic)
        }
    }

    /// The last 400 entries; the file is cut back to its last 1,000 lines once it passes 2,000.
    private static func savedJournal() -> [LogEntry] {
        guard let text = try? String(contentsOf: journalFile, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > 2000 {
            lines = Array(lines.suffix(1000))
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: journalFile, options: .atomic)
        }
        return lines.suffix(400).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let date = try? journalDate.parse(String(parts[0])) else { return nil }
            return LogEntry(date: date, text: String(parts[1]))
        }
    }

    /// The journal as text, to share.
    var logText: String {
        let format = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3))
        return log.map { "\($0.date.formatted(format))  \($0.text)" }.joined(separator: "\n")
    }

    /// The speed is asked for twice a second: only its first exchanges go in the journal.
    private var speedNotes = 0

    private func quiet(_ topic: P.Topic?) -> Bool {
        guard topic == .speed else { return false }
        speedNotes += 1
        return speedNotes > 6
    }

    private static func name(_ topic: UInt16) -> String {
        let hex = String(format: "0x%04X", topic)
        return P.Topic(rawValue: topic).map { "\($0) (\(hex))" } ?? hex
    }

    private func firstInt(_ payload: Data) -> Int? {
        if case .int(let value)? = P.fields(of: payload)?.first { return value }
        return nil
    }

    private func waitUntilReady() async -> Bool {
        for _ in 0..<60 where state != .ready {
            if state.isFailure || (state == .idle && retrying == false) { return false }
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
        note("Échec : \(reason)")
        authRetried = false
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
        pendingReads.removeAll()
        rawNotes = 0
        accessWait?.cancel()
        accessWait = nil
        isAsleep = nil
        otherCharacteristics.removeAll()
        lockWaiters.forEach { $0.resume(returning: nil) }
        lockWaiters.removeAll()
        self.state = state
    }
}

extension StreetnavVanMoofBike {
    /// A characteristic's properties, in the journal's words: whether it needs a paired iPhone shows here.
    nonisolated fileprivate static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "lecture"), (.write, "écriture"), (.writeWithoutResponse, "écriture sans réponse"),
            (.notify, "notification"), (.indicate, "indication"), (.notifyEncryptionRequired, "notification chiffrée"),
            (.indicateEncryptionRequired, "indication chiffrée"), (.authenticatedSignedWrites, "écriture signée"),
        ]
        let found = names.filter { properties.contains($0.0) }.map(\.1)
        return found.isEmpty ? "aucune" : found.joined(separator: ", ")
    }

    fileprivate static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "allumé"
        case .poweredOff: "éteint"
        case .unauthorized: "non autorisé pour Streetnav"
        case .unsupported: "indisponible sur cet appareil"
        case .resetting: "redémarrage"
        default: "état inconnu"
        }
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
            note("Bluetooth : \(Self.describe(central.state))")
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
            if isVanMoof, state == .searching {
                note("Vélo trouvé : « \(name.isEmpty ? "sans nom" : name) », signal \(RSSI) dBm")
                found(peripheral, signal: RSSI.intValue)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            note("Connecté, recherche du service VanMoof")
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownBikeKey)
        }
        // All of them, so that the journal shows what else the bike offers.
        peripheral.discoverServices(nil)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { fail("Connexion au vélo impossible\(error.map { " : \($0.localizedDescription)" } ?? ".")") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            note("Vélo déconnecté\(error.map { " : \($0.localizedDescription)" } ?? "")")
            if state == .ready || state == .authenticating { reset(to: error == nil ? .idle : .failed("Le vélo s'est déconnecté.")) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (peripheral.services ?? []).map(\.uuid.uuidString)
        MainActor.assumeIsolated { note("Services : \(services.isEmpty ? "aucun" : services.joined(separator: ", "))") }
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
        let messageService = services.contains { StreetnavVanMoofProtocol.serviceUUIDs.contains($0.uppercased()) }
        if messageService == false {
            MainActor.assumeIsolated { fail("Ce vélo ne présente pas le service VanMoof S6.") }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        let listed = characteristics.map { "\($0.uuid.uuidString) (\(Self.describe($0.properties)))" }.joined(separator: ", ")
        guard let characteristic = characteristics.first(where: {
            $0.uuid.uuidString.hasPrefix(StreetnavVanMoofProtocol.characteristicPrefix)
        }) else {
            MainActor.assumeIsolated {
                note("Service \(service.uuid.uuidString) : \(listed.isEmpty ? "aucune caractéristique" : listed)")
                otherCharacteristics += characteristics
            }
            return
        }
        MainActor.assumeIsolated {
            note("Caractéristique \(characteristic.uuid.uuidString) (\(Self.describe(characteristic.properties))), activation des notifications")
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if error != nil || characteristic.isNotifying == false {
                return fail("Le vélo refuse les notifications\(error.map { " : \($0.localizedDescription)" } ?? ".")")
            }
            note("Notifications activées")
            ready(characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid.uuidString.hasPrefix(StreetnavVanMoofProtocol.characteristicPrefix) else {
            // One of the bike's other characteristics, read once: only its size, or why it could not be read.
            let uuid = characteristic.uuid.uuidString, size = characteristic.value?.count
            MainActor.assumeIsolated {
                if let error { note("Lecture \(uuid) impossible : \(error.localizedDescription)") }
                else { note("Lecture \(uuid) : \(size ?? 0) octets") }
            }
            return
        }
        guard let value = characteristic.value else { return }
        MainActor.assumeIsolated {
            if rawNotes < 80 {
                rawNotes += 1
                note("⇠ \(value.prefix(32).map { String(format: "%02X", $0) }.joined())\(value.count > 32 ? "…" : "")")
            }
            guard let data = reassembler.feed(value) else { return }
            if let message = StreetnavVanMoofProtocol.decode(data) {
                received(message)
            } else {
                note("← message illisible (\(data.count) octets) : \(data.prefix(24).map { String(format: "%02X", $0) }.joined())")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            isWriting = false
            if let error { return fail("Écriture refusée par le vélo : \(error.localizedDescription)") }
            writeNext()
        }
    }
}
