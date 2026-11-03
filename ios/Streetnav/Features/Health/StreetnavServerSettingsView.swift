import SwiftUI
import UniformTypeIdentifiers

/// The Streetnav server: its address and token, and the certificate that reaches it away from home (Réglages › Serveur
/// Streetnav).
struct StreetnavServerSettingsView: View {
    @ObservedObject private var sync = StreetnavHealthSync.shared
    @State private var serverAddress = StreetnavServerSettingsView.displayed(StreetnavServerSettings.baseURL)
    @State private var token = StreetnavServerSettings.token ?? ""
    @State private var connectionText: String?
    @State private var isTesting = false
    @State private var certificateName = StreetnavServerAccess.certificateName
    @State private var importsCertificate = false
    @State private var pendingCertificate: Data?
    @State private var certificatePassword = ""
    @State private var certificateText: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Adresse") {
                    TextField("Adresse", text: $serverAddress, prompt: Text(verbatim: "192.168.1.62:8080"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("Jeton") {
                    SecureField("Jeton", text: $token, prompt: Text("Jeton de l'API"))
                        .multilineTextAlignment(.trailing)
                }
                Button(isTesting ? "Test en cours…" : "Enregistrer et tester") {
                    Task { await saveAndTest() }
                }
                .disabled(isTesting)
                if let connectionText {
                    Text(connectionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                header("Serveur Streetnav")
            } footer: {
                Text("Le jeton reste dans le trousseau de l'iPhone.")
            }

            Section {
                LabeledContent("Certificat", value: certificateName ?? "Aucun")
                Button(certificateName == nil ? "Importer le certificat (.p12)" : "Remplacer le certificat") {
                    importsCertificate = true
                }
                if certificateName != nil {
                    Button("Utiliser l'adresse publique") {
                        serverAddress = StreetnavServerAccess.remoteURL.absoluteString
                        Task { await saveAndTest() }
                    }
                    Button("Retirer le certificat", role: .destructive) {
                        StreetnavServerAccess.removeCertificate()
                        certificateName = nil
                    }
                }
                if let certificateText {
                    Text(certificateText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                header("Hors de chez toi")
            } footer: {
                Text("Avec ce certificat, Streetnav joint ton serveur de partout par \(StreetnavServerAccess.remoteURL.host() ?? ""). Sans lui, le serveur refuse la connexion avant même le jeton.")
            }

        }
        .fileImporter(isPresented: $importsCertificate, allowedContentTypes: [.pkcs12, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingCertificate = try? Data(contentsOf: url)
            certificatePassword = ""
        }
        .alert("Mot de passe du certificat", isPresented: Binding(get: { pendingCertificate != nil }, set: { if $0 == false { pendingCertificate = nil } })) {
            SecureField("Mot de passe", text: $certificatePassword)
            Button("Importer") { importCertificate() }
            Button("Annuler", role: .cancel) { pendingCertificate = nil }
        } message: {
            Text("Celui donné à la création du fichier .p12.")
        }
        .navigationTitle("Serveur Streetnav")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    /// The address without its scheme, the way it is typed.
    private static func displayed(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return "" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// HTTP for the home address (an IP or a port), HTTPS for a name such as streetnav.felixchevalier.fr.
    static func withScheme(_ address: String) -> String {
        if address.contains("://") { return address }
        let host = address.split(separator: ":").first.map(String.init) ?? address
        let isHome = address.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        return (isHome ? "http://" : "https://") + address
    }

    private func importCertificate() {
        guard let data = pendingCertificate else { return }
        pendingCertificate = nil
        do {
            try StreetnavServerAccess.importCertificate(data, password: certificatePassword)
            certificateName = StreetnavServerAccess.certificateName
            certificateText = "Certificat importé."
        } catch {
            certificateText = error.localizedDescription
        }
        certificatePassword = ""
    }

    private func saveAndTest() async {
        var address = serverAddress.trimmingCharacters(in: .whitespaces)
        address = Self.withScheme(address)
        guard let url = URL(string: address), url.scheme == "http" || url.scheme == "https", url.host() != nil else {
            connectionText = "Adresse invalide, par exemple 192.168.1.62:8080"
            return
        }
        StreetnavServerSettings.baseURL = url
        StreetnavServerSettings.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = StreetnavServerSettings.client else {
            connectionText = StreetnavServerError.notConfigured.localizedDescription
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            connectionText = "Connecté : \(try await client.activityCount().formatted()) activités sur le serveur."
            sync.serverReachable()
            sync.startObserving()
        } catch {
            connectionText = error.localizedDescription
        }
    }
}
