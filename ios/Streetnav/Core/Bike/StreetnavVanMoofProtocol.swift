import Foundation

/// The VanMoof S6's Bluetooth protocol, as documented by Nefilim78/vanmoof-s6-ble-protocol (captures of the official
/// app) and cross-checked with Knight1/vanmoof-ble. Pure encoding, no Bluetooth: see `StreetnavVanMoofBike`.
///
/// Everything goes through one characteristic. A message is
/// `[id][type | qos << 3][topic LE][length LE][CBOR payload][CRC-16/MODBUS LE]`, cut into fragments of one write each:
/// `[0x80 if first else 0 | fragment id][bytes left, this chunk included, BE][chunk]`.
enum StreetnavVanMoofProtocol {
    /// Two UUID bases are published for the same service; the bike advertises one of them.
    static let serviceUUIDs = ["DF286100-6003-11E5-9260-0002A5D5C51B", "DF286100-1440-48A1-88F1-247D7F7D274D"]
    static let characteristicPrefix = "DF286101-"

    enum MessageType: UInt8 {
        case ack = 0, publish, subscribe, unsubscribe, get, set, own, sync
    }

    /// Topics are ids in the bike's object dictionary, with their values as both community references give them
    /// (captured from the official app or read in its S6 code). Streetnav writes only those whose values are known.
    enum Topic: UInt16 {
        case wake = 0x010C              // write [1]: wakes the bike, which unlocks it
        case assistLevel = 0x0110       // [level]: 0 off, 1 eco, 2 normal, 3 sport, 4 turbo
        case lockState = 0x0112         // 0 unlocked, 1 locked
        case distance = 0x0113          // odometer, metres
        case errors = 0x011F            // diagnostic trouble codes: (device class << 8) | subcode
        case lightMode = 0x0131         // [mode, 1]: 0 off, 2 on, 3 auto (1 is not on)
        case bell = 0x0142              // write [1]: rings the bell (it does not unlock)
        case wakeState = 0x0160         // read only, meaning undocumented
        case notifyInterval = 0x0163    // read only here, unit undocumented
        case speed = 0x0164             // unit undocumented
        case alarmSensitivity = 0x0171  // [level]: 1 high, 2 medium, 4 low
        case alarm = 0x0172             // [state]: 0 off, 1 on
        case firmware = 0x01B1
        case batteryLevel = 0x022A      // %
        case chargeLimit = 0x022D       // [percent]: 80, 85, 90, 95 or 100
        case motorState = 0x0260        // read only, meaning undocumented
        case bellMode = 0x0281          // read only here, values undocumented
        case auth = 0xFF00              // certificate and challenge
        /// Published right after authentication, and again when it changes. 7 · 7 while the bike is awake and answers
        /// everything; 1 · 7 while it sleeps and only its Bluetooth answers: no reply then, the unlock ignored, a new
        /// connection no better (journals of 6 and 7 Nov 2026). The same certificate got both a minute apart, so it is
        /// read as the bike's state, not as the access it grants. Undocumented.
        case access = 0xFF02
    }

    /// The device classes of the S6's trouble codes (the high byte), as Knight1/vanmoof-ble read them in the firmware.
    static let errorDevices: [Int: String] = [
        0x08: "Bluetooth", 0x8D: "gestion de la batterie", 0x90: "alimentation", 0xA1: "capteur du moteur",
        0xA2: "commande de puissance", 0xA3: "chargeur", 0xA4: "batterie", 0xA7: "chargeur", 0xC0: "guidon",
        0xC1: "verrou", 0xC3: "porte-bagages", 0xC4: "phare",
    ]

    struct Message: Equatable {
        var type: MessageType
        var topic: UInt16
        var payload: Data = Data()
        var id: UInt8 = 0
        var qos: UInt8 = 1  // "at most once", the app's default
    }

    static func encode(_ message: Message) -> Data {
        var body: Data
        if message.type == .ack {
            // Only its id and type, as the bike's own: the bike ignored the longer form, with a topic and a length, and
            // kept sending its message again (journal of 6 Nov 2026).
            body = Data([message.id, MessageType.ack.rawValue])
        } else {
            body = Data([message.id, message.type.rawValue | (message.qos & 1) << 3])
            body.append(contentsOf: [UInt8(message.topic & 0xFF), UInt8(message.topic >> 8)])
            body.append(contentsOf: [UInt8(message.payload.count & 0xFF), UInt8(message.payload.count >> 8)])
            body.append(message.payload)
        }
        let crc = crc16Modbus(body)
        body.append(contentsOf: [UInt8(crc & 0xFF), UInt8(crc >> 8)])
        return body
    }

    /// Nil when the message is truncated or its CRC is wrong.
    static func decode(_ data: Data) -> Message? {
        let bytes = [UInt8](data)
        // The bike's acknowledgements of the messages sent "at least once" (QoS 0): id, type and CRC, nothing else.
        if bytes.count == 4, bytes[1] & 0x07 == MessageType.ack.rawValue {
            guard crc16Modbus(Data(bytes[0..<2])) == UInt16(bytes[2]) | UInt16(bytes[3]) << 8 else { return nil }
            return Message(type: .ack, topic: 0, id: bytes[0], qos: (bytes[1] >> 3) & 1)
        }
        guard bytes.count >= 8 else { return nil }
        let length = Int(bytes[4]) | Int(bytes[5]) << 8
        guard bytes.count >= 8 + length else { return nil }
        let crc = UInt16(bytes[6 + length]) | UInt16(bytes[7 + length]) << 8
        guard crc16Modbus(Data(bytes[0..<6 + length])) == crc, let type = MessageType(rawValue: bytes[1] & 0x07) else { return nil }
        return Message(type: type, topic: UInt16(bytes[2]) | UInt16(bytes[3]) << 8, payload: Data(bytes[6..<6 + length]),
                       id: bytes[0], qos: (bytes[1] >> 3) & 1)
    }

    static func crc16Modbus(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    /// Cuts a message into writes of at most `maxWrite` bytes (the ATT MTU minus 3).
    static func fragments(of message: Data, maxWrite: Int, fragmentID: UInt8) -> [Data] {
        let chunkSize = max(1, maxWrite - 3)
        return stride(from: 0, to: message.count, by: chunkSize).map { start in
            let left = message.count - start
            var fragment = Data([(start == 0 ? 0x80 : 0x00) | (fragmentID & 0x7F), UInt8(left >> 8 & 0xFF), UInt8(left & 0xFF)])
            fragment.append(message[message.startIndex + start..<message.startIndex + min(message.count, start + chunkSize)])
            return fragment
        }
    }

    /// Puts the bike's notifications back together into messages.
    struct Reassembler {
        private var buffer = Data()
        private var total = 0

        mutating func feed(_ notification: Data) -> Data? {
            let bytes = [UInt8](notification)
            guard bytes.count >= 3 else { return nil }
            let left = Int(bytes[1]) << 8 | Int(bytes[2])
            let chunk = Data(bytes[3...])
            if buffer.isEmpty == false, left == total - buffer.count {
                buffer.append(chunk)
            } else if bytes[0] & 0x80 != 0 {
                buffer = chunk
                total = left
            } else {
                buffer = Data()
                return nil
            }
            guard buffer.count >= total else { return nil }
            defer { buffer = Data() }
            return buffer.prefix(total)
        }
    }

    // MARK: Payloads

    /// A request payload: a one-element array holding the value's CBOR encoding as bytes.
    static func wrap(_ inner: Data) -> Data {
        var payload = Data([0x81])
        payload.append(CBOR.bytes(inner).encoded)
        return payload
    }

    static func certificatePayload(_ certificate: Data) -> Data { wrap(CBOR.bytes(certificate).encoded) }
    static func signaturePayload(_ signature: Data) -> Data { wrap(CBOR.bytes(signature).encoded) }
    /// A SET of a value made of integer fields, such as `[1]` for wake.
    static func valuePayload(_ fields: [Int]) -> Data { wrap(CBOR.array(fields.map(CBOR.int)).encoded) }

    /// A value as the bike sent it, for registers whose meaning is undocumented: its numbers, text or bytes.
    static func raw(_ payload: Data) -> String {
        guard let fields = fields(of: payload), fields.isEmpty == false else { return "—" }
        return fields.map { field -> String in
            switch field {
            case .int(let value): String(value)
            case .double(let value): value.formatted(.number.precision(.fractionLength(0...2)))
            case .text(let text): text
            case .bytes(let data): data.map { String(format: "%02X", $0) }.joined()
            case .array(let items): "[" + items.map { $0.encoded.map { String(format: "%02X", $0) }.joined() }.joined(separator: " ") + "]"
            default: field.encoded.map { String(format: "%02X", $0) }.joined()
            }
        }.joined(separator: " · ")
    }

    /// The fields of a value from the bike, which wraps them like a request.
    static func fields(of payload: Data) -> [CBOR]? {
        guard let outer = CBOR.decode(payload) else { return nil }
        if case .array(let items) = outer, items.count == 1, case .bytes(let inner) = items[0] {
            guard let value = CBOR.decode(inner) else { return nil }
            if case .array(let fields) = value { return fields }
            return [value]
        }
        if case .array(let fields) = outer { return fields }
        return [outer]
    }

    enum AuthReply: Equatable {
        case challenge(Data)
        case accepted
        case rejected
    }

    /// `[status, 16-byte challenge]` after the certificate, `[status ≥ 0]` once accepted, `[-1]` when refused.
    static func authReply(_ payload: Data) -> AuthReply? {
        guard let fields = fields(of: payload), case .int(let status)? = fields.first else { return nil }
        if status < 0 { return .rejected }
        if fields.count > 1, case .bytes(let challenge) = fields[1], challenge.count == 16 { return .challenge(challenge) }
        return .accepted
    }
}

/// The few CBOR shapes the bike and VanMoof's certificates use.
indirect enum CBOR: Equatable {
    case int(Int)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case simple(UInt8)
    case double(Double)

    static func == (lhs: CBOR, rhs: CBOR) -> Bool { lhs.encoded == rhs.encoded }

    var encoded: Data {
        switch self {
        case .int(let value): value >= 0 ? Self.head(0, UInt64(value)) : Self.head(1, UInt64(-1 - value))
        case .bytes(let data): Self.head(2, UInt64(data.count)) + data
        case .text(let string): Self.head(3, UInt64(string.utf8.count)) + Data(string.utf8)
        case .array(let items): items.reduce(Self.head(4, UInt64(items.count))) { $0 + $1.encoded }
        case .map(let pairs): pairs.reduce(Self.head(5, UInt64(pairs.count))) { $0 + $1.0.encoded + $1.1.encoded }
        case .simple(let value): Data([0xE0 | value])
        case .double(let value): Data([0xFB] + (0..<8).reversed().map { UInt8(value.bitPattern >> ($0 * 8) & 0xFF) })
        }
    }

    subscript(key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.0 == .text(key) }?.1
    }

    private static func head(_ major: UInt8, _ value: UInt64) -> Data {
        let type = major << 5
        switch value {
        case ..<24: return Data([type | UInt8(value)])
        case ..<0x100: return Data([type | 24, UInt8(value)])
        case ..<0x10000: return Data([type | 25, UInt8(value >> 8), UInt8(value & 0xFF)])
        case ..<0x1_0000_0000: return Data([type | 26] + (0..<4).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) })
        default: return Data([type | 27] + (0..<8).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) })
        }
    }

    /// Decodes one item and ignores what follows; nil on anything malformed.
    static func decode(_ data: Data) -> CBOR? {
        var reader = Reader(bytes: [UInt8](data))
        return reader.item()
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func item() -> CBOR? {
            guard index < bytes.count else { return nil }
            let initial = bytes[index]
            index += 1
            let major = initial >> 5, info = initial & 0x1F
            if info == 31 {  // indefinite length, closed by 0xFF
                switch major {
                case 2:
                    var data = Data()
                    while index < bytes.count, bytes[index] != 0xFF {
                        guard case .bytes(let chunk)? = item() else { return nil }
                        data.append(chunk)
                    }
                    index += 1
                    return .bytes(data)
                case 4:
                    var items: [CBOR] = []
                    while index < bytes.count, bytes[index] != 0xFF {
                        guard let next = item() else { return nil }
                        items.append(next)
                    }
                    index += 1
                    return .array(items)
                case 5:
                    var pairs: [(CBOR, CBOR)] = []
                    while index < bytes.count, bytes[index] != 0xFF {
                        guard let key = item(), let value = item() else { return nil }
                        pairs.append((key, value))
                    }
                    index += 1
                    return .map(pairs)
                default: return nil
                }
            }
            guard let value = argument(info) else { return nil }
            switch major {
            case 0: return .int(Int(clamping: value))
            case 1: return .int(-1 - Int(clamping: value))
            case 2, 3:
                guard index + Int(value) <= bytes.count else { return nil }
                let data = Data(bytes[index..<index + Int(value)])
                index += Int(value)
                return major == 2 ? .bytes(data) : String(data: data, encoding: .utf8).map(CBOR.text)
            case 4:
                var items: [CBOR] = []
                for _ in 0..<value {
                    guard let next = item() else { return nil }
                    items.append(next)
                }
                return .array(items)
            case 5:
                var pairs: [(CBOR, CBOR)] = []
                for _ in 0..<value {
                    guard let key = item(), let value = item() else { return nil }
                    pairs.append((key, value))
                }
                return .map(pairs)
            case 6: return item()  // a tag: keep the tagged item
            case 7 where info == 25: return .double(Double(Float16(bitPattern: UInt16(value))))
            case 7 where info == 26: return .double(Double(Float(bitPattern: UInt32(value))))
            case 7 where info == 27: return .double(Double(bitPattern: value))
            default: return .simple(UInt8(clamping: value))
            }
        }

        private mutating func argument(_ info: UInt8) -> UInt64? {
            switch info {
            case ..<24: return UInt64(info)
            case 24...27:
                let count = 1 << Int(info - 24)
                guard index + count <= bytes.count else { return nil }
                defer { index += count }
                return bytes[index..<index + count].reduce(0) { $0 << 8 | UInt64($1) }
            default: return nil
            }
        }
    }
}
