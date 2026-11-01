import Foundation
import Security

/// Reaching the Streetnav server from anywhere: https://streetnav.felixchevalier.fr, where the home Caddy only lets
/// in a device that presents a certificate signed by the Streetnav client CA (server/deploy/make-client-cert.sh).
///
/// The certificate comes as a .p12 file, imported once into the app's own keychain (a profile installed in iOS
/// Settings is not readable by apps). Every request to the server goes through `session`, which answers Caddy's
/// client-certificate challenge with it.
enum StreetnavServerAccess {
    static let remoteURL = URL(string: "https://streetnav.felixchevalier.fr")!
    private static let label = "com.felixchevalier.streetnav.client-certificate"

    static let session = URLSession(configuration: .default, delegate: ChallengeAnswer(), delegateQueue: nil)

    enum Failure: LocalizedError {
        case wrongPassword, unreadable, keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .wrongPassword: "Mot de passe du certificat incorrect."
            case .unreadable: "Ce fichier n'est pas un certificat .p12 lisible."
            case .keychain(let status): "Le trousseau a refusé le certificat (\(status))."
            }
        }
    }

    /// The imported certificate's name, if any.
    static var certificateName: String? {
        guard let identity else { return nil }
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        return certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
    }

    static func importCertificate(_ data: Data, password: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed { throw Failure.wrongPassword }
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let found = first[kSecImportItemIdentity as String] else { throw Failure.unreadable }
        let identity = found as! SecIdentity
        removeCertificate()
        let added = SecItemAdd([kSecValueRef as String: identity, kSecAttrLabel as String: label,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(added) }
    }

    static func removeCertificate() {
        SecItemDelete([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrLabel as String: label] as CFDictionary)
    }

    static var identity: SecIdentity? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label,
                                          kSecReturnRef as String: true] as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        return (item as! SecIdentity)
    }

    private final class ChallengeAnswer: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
                return (.performDefaultHandling, nil)
            }
            guard let identity = StreetnavServerAccess.identity else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        }
    }
}
