import HealthKit
import HealthKitUI
import SwiftUI

/// Apple Health access and the state of the workout sync (Réglages › Apple Santé); the server has its own screen.
struct StreetnavHealthSyncView: View {
    @ObservedObject private var sync = StreetnavHealthSync.shared
    @State private var showsResendConfirmation = false
    @State private var asksHealthAccess = false

    var body: some View {
        Form {
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
}
