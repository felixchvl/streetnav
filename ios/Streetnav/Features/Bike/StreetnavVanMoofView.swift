import SwiftUI

/// Réglages › VanMoof S6: the VanMoof account that issues the bike's certificate, then the bike itself over Bluetooth.
struct StreetnavVanMoofView: View {
    @ObservedObject private var account = StreetnavVanMoofAccount.shared
    @ObservedObject private var bike = StreetnavVanMoofBike.shared
    @State private var email = ""
    @State private var password = ""
    @State private var unlockText: String?
    @State private var isUnlocking = false

    var body: some View {
        Form {
            accountSection
            if account.isSignedIn { bikeSection }
        }
        .navigationTitle(account.bike?.name ?? "VanMoof S6")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if account.isSignedIn {
                LabeledContent("Vélo", value: account.bike?.name ?? "—")
                LabeledContent("Certificat", value: certificateText)
                Button("Se déconnecter", role: .destructive) {
                    bike.disconnect()
                    account.signOut()
                }
            } else {
                TextField("E-mail", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
                Button(account.isWorking ? "Connexion…" : "Se connecter") {
                    Task {
                        await account.signIn(email: email, password: password)
                        password = ""
                    }
                }
                .disabled(account.isWorking || email.isEmpty || password.isEmpty)
            }
            if let error = account.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            header("Compte VanMoof")
        } footer: {
            Text("Le mot de passe ne sert qu'à te connecter chez VanMoof et n'est pas gardé. Streetnav demande ensuite à VanMoof un certificat pour ton vélo, valable une semaine et renouvelé tout seul.")
        }
    }

    @ViewBuilder
    private var bikeSection: some View {
        Section {
            LabeledContent("État", value: stateText)
            if bike.state == .ready {
                LabeledContent("Batterie", value: bike.battery.map { "\($0) %" } ?? "—")
                LabeledContent("Verrou", value: bike.isLocked.map { $0 ? "Verrouillé" : "Déverrouillé" } ?? "—")
                LabeledContent("Compteur", value: bike.odometerMeters.map { "\(($0 / 1000).formatted()) km" } ?? "—")
                if let firmware = bike.firmware { LabeledContent("Logiciel", value: firmware) }
                Button("Actualiser") { bike.refresh() }
            } else if bike.state == .idle || bike.state.isFailure {
                Button("Se connecter au vélo") { Task { await bike.connect() } }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(stateText).foregroundStyle(.secondary)
                }
            }
        } header: {
            header("Vélo")
        }

        Section {
            Button {
                Task {
                    isUnlocking = true
                    unlockText = await bike.unlock() ? "Vélo déverrouillé." : "Le vélo n'a pas confirmé le déverrouillage."
                    isUnlocking = false
                }
            } label: {
                Label(isUnlocking ? "Déverrouillage…" : "Déverrouiller", systemImage: "lock.open.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isUnlocking)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if let unlockText {
                Text(unlockText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Streetnav ne fait que déverrouiller : le vélo se verrouille sur lui-même, avec la béquille. Ferme l'app VanMoof avant, le vélo n'accepte qu'une connexion à la fois.")
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private var certificateText: String {
        guard let expiry = account.certificateExpiry else { return "—" }
        return expiry > .now ? "Jusqu'au \(expiry.formatted(date: .abbreviated, time: .shortened))" : "Expiré"
    }

    private var stateText: String {
        switch bike.state {
        case .idle: "Non connecté"
        case .searching: "Recherche du vélo…"
        case .connecting: "Connexion…"
        case .authenticating: "Authentification…"
        case .ready: "Connecté"
        case .failed(let reason): reason
        }
    }
}
