import CryptoKit
import Foundation
import Security

/// The VanMoof account side of unlocking: sign in once, then get a certificate for the bike, valid a week.
///
/// This is the official app's private API (api.vanmoof-api.com, bikeapi.production.vanmoof.cloud), as used by
/// Knight1/vanmoof-certificates; its key comes from the git-ignored `Config/Secrets.xcconfig`. The password is only sent
/// to sign in. The refresh token, the Ed25519 key pair and the certificate stay in the iPhone's keychain.
@MainActor
final class StreetnavVanMoofAccount: ObservableObject {
    static let shared = StreetnavVanMoofAccount()

    struct Bike: Codable, Equatable {
        let name: String
        let frameNumber: String
    }

    @Published private(set) var bike: Bike?
    @Published private(set) var certificateExpiry: Date?
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    @Published private(set) var isSignedIn = false

    private static let api = "https://api.vanmoof-api.com/v8"
    private static let bikeAPI = "https://bikeapi.production.vanmoof.cloud"
    private static let registryAPI = "https://vehicleregistry.production.vanmoof.cloud"
    private static let bikeKey = "streetnav.vanmoof.bike"

    private init() {
        bike = UserDefaults.standard.data(forKey: Self.bikeKey).flatMap { try? JSONDecoder().decode(Bike.self, from: $0) }
        isSignedIn = Keychain.read(.refreshToken) != nil
        certificateExpiry = Keychain.read(.certificate).flatMap(Self.expiry(of:))
    }

    func signIn(email: String, password: String) async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            var request = try Self.request("\(Self.api)/authenticate", method: "POST")
            request.setValue("Basic " + Data("\(email):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            let tokens: Tokens = try await Self.send(request)
            guard let refreshToken = tokens.refreshToken, refreshToken.isEmpty == false else { throw Failure.unreadable }
            Keychain.write(.refreshToken, Data(refreshToken.utf8))
            isSignedIn = true
            try await renew(authToken: tokens.token)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        for item in Keychain.Item.allCases { Keychain.write(item, nil) }
        UserDefaults.standard.removeObject(forKey: Self.bikeKey)
        bike = nil
        certificateExpiry = nil
        isSignedIn = false
    }

    /// The certificate and its key, renewed when less than a day is left (which needs the network).
    func credentials() async throws -> (certificate: Data, key: Curve25519.Signing.PrivateKey) {
        let fresh = certificateExpiry.map { $0.timeIntervalSinceNow > 86_400 } ?? false
        if fresh == false || Keychain.read(.certificate) == nil { try await renew(authToken: nil) }
        guard let certificate = Keychain.read(.certificate), let raw = Keychain.read(.privateKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { throw Failure.notSignedIn }
        return (certificate, key)
    }

    private func renew(authToken: String?) async throws {
        isWorking = true
        defer { isWorking = false }
        let auth: String
        if let authToken { auth = authToken } else { auth = try await refreshedAuthToken() }
        var appRequest = try Self.request("\(Self.api)/getApplicationToken", method: "GET")
        appRequest.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        let app: Token = try await Self.send(appRequest)

        var bikesRequest = try Self.request("\(Self.api)/getCustomerData?includeBikeDetails", method: "GET")
        bikesRequest.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        let customer: Customer = try await Self.send(bikesRequest)
        var bikes = customer.data.bikes ?? []
        // Bikes made since VanMoof's takeover, the S6 among them, are only listed by the vehicle registry.
        if let rider = customer.data.uuid.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) {
            var registryRequest = URLRequest(url: URL(string: "\(Self.registryAPI)/external/riders/\(rider)/vehicles")!)
            registryRequest.setValue("Bearer \(app.token)", forHTTPHeaderField: "Authorization")
            if let registry: Registry = try? await Self.send(registryRequest) {
                bikes += registry.vehicleAccess
                    .filter { vehicle in bikes.contains { $0.frameNumber == vehicle.vehicleID } == false }
                    .map { Customer.RemoteBike(name: $0.name, frameNumber: $0.vehicleID, bleProfile: $0.bleProfile) }
            }
        }
        // The S6 is the bike with the 2025 Bluetooth profile; otherwise take the first one.
        guard let found = bikes.first(where: { $0.bleProfile == "ELECTRIFIED_2025" }) ?? bikes.first else {
            throw Failure.noBike
        }

        let key = Keychain.read(.privateKey).flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
            ?? Curve25519.Signing.PrivateKey()
        Keychain.write(.privateKey, key.rawRepresentation)
        guard let frame = found.frameNumber.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw Failure.noBike }
        var certRequest = URLRequest(url: URL(string: "\(Self.bikeAPI)/bikes/\(frame)/create_certificate")!)
        certRequest.httpMethod = "POST"
        certRequest.setValue("Bearer \(app.token)", forHTTPHeaderField: "Authorization")
        certRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        certRequest.httpBody = try JSONEncoder().encode(["public_key": key.publicKey.rawRepresentation.base64EncodedString()])
        let response: CertificateResponse = try await Self.send(certRequest)
        guard let certificate = Data(base64Encoded: response.certificate), certificate.count > 64 else { throw Failure.badCertificate }

        Keychain.write(.certificate, certificate)
        certificateExpiry = Self.expiry(of: certificate)
        bike = Bike(name: found.name ?? "VanMoof", frameNumber: found.frameNumber)
        UserDefaults.standard.set(try? JSONEncoder().encode(bike), forKey: Self.bikeKey)
        lastError = nil
    }

    private func refreshedAuthToken() async throws -> String {
        guard let refresh = Keychain.read(.refreshToken).flatMap({ String(data: $0, encoding: .utf8) }) else { throw Failure.notSignedIn }
        var request = try Self.request("\(Self.api)/token", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refreshToken": refresh])
        let tokens: Tokens = try await Self.send(request)
        // The server may hand out a new refresh token; otherwise the old one stays valid.
        if let rotated = tokens.refreshToken, rotated.isEmpty == false { Keychain.write(.refreshToken, Data(rotated.utf8)) }
        return tokens.token
    }

    /// `[64-byte signature][CBOR map]`, whose `e` is the expiry in Unix seconds.
    private static func expiry(of certificate: Data) -> Date? {
        guard certificate.count > 64, case .int(let seconds)? = CBOR.decode(certificate.dropFirst(64))?["e"] else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: HTTP

    private static func request(_ url: String, method: String) throws -> URLRequest {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "VanMoofAPIKey") as? String, key.isEmpty == false,
              key.hasPrefix("$(") == false else { throw Failure.missingAPIKey }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        return request
    }

    private static func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw status == 401 || status == 403 ? Failure.refused : Failure.http(status) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.unreadable
        }
    }

    private struct Tokens: Decodable {
        let token: String
        let refreshToken: String?
    }

    private struct Token: Decodable { let token: String }

    private struct Customer: Decodable {
        struct Content: Decodable {
            let uuid: String
            let bikes: [RemoteBike]?
        }
        struct RemoteBike: Decodable {
            let name: String?
            let frameNumber: String
            let bleProfile: String?
        }
        let data: Content
    }

    private struct Registry: Decodable {
        struct Vehicle: Decodable {
            let vehicleID: String
            let name: String?
            let bleProfile: String?

            enum CodingKeys: String, CodingKey {
                case vehicleID = "vehicle_id", name, bleProfile = "ble_profile"
            }
        }
        let vehicleAccess: [Vehicle]

        enum CodingKeys: String, CodingKey { case vehicleAccess = "vehicle_access" }
    }

    private struct CertificateResponse: Decodable { let certificate: String }

    enum Failure: LocalizedError {
        case missingAPIKey, notSignedIn, refused, noBike, badCertificate, unreadable, http(Int)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "La clé d'API VanMoof manque (ios/Streetnav/Config/Secrets.xcconfig)."
            case .notSignedIn: "Connecte-toi à ton compte VanMoof."
            case .refused: "VanMoof a refusé l'identifiant ou le mot de passe."
            case .noBike: "Aucun vélo sur ce compte VanMoof."
            case .badCertificate: "VanMoof a renvoyé un certificat illisible."
            case .unreadable: "VanMoof a répondu dans un format inattendu."
            case .http(let code): "VanMoof a répondu \(code)."
            }
        }
    }

    /// Generic-password items, readable after the first unlock so a ride can start with the iPhone locked.
    enum Keychain {
        enum Item: String, CaseIterable {
            case refreshToken, privateKey, certificate
        }

        static func read(_ item: Item) -> Data? {
            var query = base(item)
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }

        static func write(_ item: Item, _ data: Data?) {
            SecItemDelete(base(item) as CFDictionary)
            guard let data else { return }
            var attributes = base(item)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(attributes as CFDictionary, nil)
        }

        private static func base(_ item: Item) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "streetnav.vanmoof.\(item.rawValue)"]
        }
    }
}
