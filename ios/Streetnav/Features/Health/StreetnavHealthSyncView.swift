import HealthKit
import HealthKitUI
import SwiftUI

/// Server address and token, Apple Health access and the state of the workout sync (Réglages › Apple Santé).
struct StreetnavHealthSyncView: View {
    @ObservedObject private var sync = StreetnavHealthSync.shared
    @State private var serverAddress = StreetnavHealthSyncView.displayed(StreetnavServerSettings.baseURL)
    @State private var token = StreetnavServerSettings.token ?? ""
    @State private var connectionText: String?
    @State private var isTesting = false
    @State private var showsResendConfirmation = false
    @State private var asksHealthAccess = false

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
                if HKHealthStore.isHealthDataAvailable() == false {
                    LabeledContent("Accès à Santé", value: "Indisponible ici")
                } else if sync.needsAuthorization {
                    Button("Autoriser la lecture de Santé") { asksHealthAccess.toggle() }
                } else {
                    LabeledContent("Accès à Santé", value: "Lecture seule")
                }
                LabeledContent("Dernière synchronisation", value: lastSyncText)
                LabeledContent("Entraînements envoyés", value: sync.sentCount.formatted())
                LabeledContent("Suppressions transmises", value: sync.deletedCount.formatted())
                if sync.refusedCount > 0 {
                    LabeledContent("Refusés par le serveur", value: sync.refusedCount.formatted())
                }
                if sync.isSyncing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(sync.progress.isEmpty ? "Synchronisation…" : sync.progress)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Synchroniser maintenant") {
                        Task { await sync.sync() }
                    }
                    .disabled(sync.needsAuthorization)
                }
                if let error = sync.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                header("Apple Santé")
            } footer: {
                Text("Streetnav lit tes entraînements, leurs tracés et ta fréquence cardiaque, sans jamais rien écrire dans Santé.")
            }

            Section {
                Button("Tout renvoyer au serveur") { showsResendConfirmation = true }
                    .disabled(sync.isSyncing || sync.needsAuthorization)
            } footer: {
                Text("Utile si la base du serveur a été reconstruite. Rien n'est supprimé.")
            }

            #if targetEnvironment(simulator)
            StreetnavHealthSeederSection()
            #endif
        }
        .navigationTitle("Apple Santé")
        .navigationBarTitleDisplayMode(.inline)
        .task { await sync.refreshAuthorizationState() }
        .healthDataAccessRequest(store: sync.store, readTypes: StreetnavHealthSync.readTypes, trigger: asksHealthAccess) { result in
            Task { @MainActor in await StreetnavHealthSync.shared.authorizationAnswered(result) }
        }
        .confirmationDialog("Renvoyer tous les entraînements ?", isPresented: $showsResendConfirmation, titleVisibility: .visible) {
            Button("Tout renvoyer") { Task { await sync.resendEverything() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le serveur les rattachera aux activités qu'il connaît déjà, sans doublon.")
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private var lastSyncText: String {
        guard let date = sync.lastSync else { return "Jamais" }
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    /// The address without its scheme, the way it is typed.
    private static func displayed(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return "" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private func saveAndTest() async {
        var address = serverAddress.trimmingCharacters(in: .whitespaces)
        if address.contains("://") == false { address = "http://" + address }
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
