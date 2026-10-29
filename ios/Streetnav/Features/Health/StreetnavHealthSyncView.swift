import HealthKit
import HealthKitUI
import SwiftUI

/// Server address and token, Apple Health access and the state of the workout sync.
struct StreetnavHealthSyncView: View {
    @ObservedObject private var sync = StreetnavHealthSync.shared
    @State private var serverAddress = StreetnavServerSettings.baseURL?.absoluteString ?? ""
    @State private var token = StreetnavServerSettings.token ?? ""
    @State private var connectionText: String?
    @State private var isTesting = false
    @State private var showsResendConfirmation = false
    @State private var asksHealthAccess = false

    var body: some View {
        List {
            Section {
                TextField("Adresse du serveur", text: $serverAddress, prompt: Text(verbatim: "http://192.168.1.62:8080"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Jeton de l'API", text: $token)
                Button(isTesting ? "Test en cours..." : "Enregistrer et tester") {
                    Task { await saveAndTest() }
                }
                .disabled(isTesting)
                if let connectionText {
                    Text(connectionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Serveur Streetnav")
            } footer: {
                Text("Le jeton reste dans le trousseau de l'iPhone.")
            }

            Section {
                if HKHealthStore.isHealthDataAvailable() == false {
                    row("Acces a Sante", detail: "indisponible ici", symbol: "heart.slash")
                } else if sync.needsAuthorization {
                    Button("Autoriser la lecture de Sante") { asksHealthAccess.toggle() }
                } else {
                    row("Acces a Sante", detail: "lecture seule", symbol: "heart.text.square")
                }
                row("Derniere synchronisation", detail: lastSyncText, symbol: "clock")
                row("Entrainements envoyes", detail: "\(sync.sentCount)", symbol: "arrow.up.circle")
                row("Suppressions transmises", detail: "\(sync.deletedCount)", symbol: "minus.circle")
                if sync.refusedCount > 0 {
                    row("Refuses par le serveur", detail: "\(sync.refusedCount)", symbol: "exclamationmark.triangle")
                }
                if sync.isSyncing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(sync.progress.isEmpty ? "Synchronisation..." : sync.progress)
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
                Text("Apple Sante")
            } footer: {
                Text("Streetnav lit tes entrainements, leurs traces et ta frequence cardiaque, sans jamais rien ecrire dans Sante. La premiere synchronisation envoie tout l'historique ; ensuite iOS reveille l'app a chaque nouvel entrainement. Strava reste la source prioritaire sur le serveur.")
            }

            Section {
                Button("Tout renvoyer au serveur") { showsResendConfirmation = true }
                    .disabled(sync.isSyncing || sync.needsAuthorization)
            } footer: {
                Text("Utile si la base du serveur a ete reconstruite. Rien n'est supprime, ni dans Sante ni sur le serveur.")
            }

            #if targetEnvironment(simulator)
            StreetnavHealthSeederSection()
            #endif
        }
        .navigationTitle("Apple Sante")
        .navigationBarTitleDisplayMode(.inline)
        .task { await sync.refreshAuthorizationState() }
        .healthDataAccessRequest(store: sync.store, readTypes: StreetnavHealthSync.readTypes, trigger: asksHealthAccess) { result in
            Task { @MainActor in await StreetnavHealthSync.shared.authorizationAnswered(result) }
        }
        .confirmationDialog("Renvoyer tous les entrainements ?", isPresented: $showsResendConfirmation, titleVisibility: .visible) {
            Button("Tout renvoyer") { Task { await sync.resendEverything() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le serveur les rattachera aux activites qu'il connait deja, sans doublon.")
        }
    }

    private var lastSyncText: String {
        sync.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "jamais"
    }

    private func saveAndTest() async {
        let address = serverAddress.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address), url.scheme == "http" || url.scheme == "https", url.host() != nil else {
            connectionText = "Adresse invalide, par exemple http://192.168.1.62:8080"
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
            connectionText = "Connecte : \(try await client.activityCount()) activites sur le serveur."
            sync.serverReachable()
            sync.startObserving()
        } catch {
            connectionText = error.localizedDescription
        }
    }

    private func row(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }
}
