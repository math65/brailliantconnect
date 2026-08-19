import FileProvider
import SwiftUI

@main
struct BrailliantConnectApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 460, minHeight: 300)
        }
    }
}

/// Pilotage du domaine File Provider.
///
/// Une extension ne s'active pas toute seule : l'application doit déclarer un
/// « domaine », qui devient l'emplacement visible dans le Finder. C'est aussi
/// le seul endroit d'où on peut le retirer.
@MainActor
final class DomainController: ObservableObject {

    /// Identifiant stable : le réutiliser permet de retrouver le domaine
    /// existant au lieu d'en empiler de nouveaux à chaque lancement.
    static let identifier = NSFileProviderDomainIdentifier("brailliant-principal")

    @Published var statut = "Vérification…"
    @Published var actif = false
    @Published var occupé = false

    func rafraîchir() async {
        do {
            let domaines = try await NSFileProviderManager.domains()
            actif = domaines.contains { $0.identifier == Self.identifier }
            statut = actif
                ? "Actif — la plage apparaît dans la barre latérale du Finder."
                : "Inactif — aucun emplacement n'est publié dans le Finder."
        } catch {
            // Lister les domaines exige que le système résolve d'abord quel
            // provider correspond à cette application, ce qui échoue tant
            // qu'aucun domaine n'existe. Publier emprunte un autre chemin :
            // l'échec de lecture ne doit donc pas empêcher d'essayer.
            actif = false
            statut = "État indéterminé (\(Self.codeErreur(error))). "
                + "La publication reste possible : essayez le bouton."
        }
    }

    /// Extrait le code d'erreur brut, plus parlant que le message localisé.
    static func codeErreur(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    func activer() async {
        occupé = true
        defer { occupé = false }
        let domaine = NSFileProviderDomain(identifier: Self.identifier,
                                           displayName: "Brailliant")
        do {
            try await NSFileProviderManager.add(domaine)
            statut = "Emplacement publié. Ouvrez le Finder pour le voir."
            actif = true
        } catch {
            statut = "Échec de la publication : \(error.localizedDescription) "
                + "[\(Self.codeErreur(error))]"
        }
    }

    func désactiver() async {
        occupé = true
        defer { occupé = false }
        let domaine = NSFileProviderDomain(identifier: Self.identifier,
                                           displayName: "Brailliant")
        do {
            try await NSFileProviderManager.remove(domaine)
            statut = "Emplacement retiré du Finder."
            actif = false
        } catch {
            statut = "Échec du retrait : \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var contrôleur = DomainController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BrailliantConnect")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)

            Text("Rend la plage braille accessible depuis le Finder, "
                 + "sans macFUSE ni extension noyau.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Le statut est le premier élément que doit rencontrer un lecteur
            // d'écran : il énonce l'état, pas seulement l'apparence d'un voyant.
            Text(contrôleur.statut)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("État : \(contrôleur.statut)")

            HStack(spacing: 12) {
                Button(contrôleur.actif ? "Retirer du Finder" : "Publier dans le Finder") {
                    Task {
                        if contrôleur.actif { await contrôleur.désactiver() }
                        else { await contrôleur.activer() }
                    }
                }
                .disabled(contrôleur.occupé)
                .keyboardShortcut(.defaultAction)

                Button("Actualiser") {
                    Task { await contrôleur.rafraîchir() }
                }
                .disabled(contrôleur.occupé)
            }

            Spacer()

            Text("Étape de validation : l'emplacement affiche un contenu de "
                 + "démonstration, pas encore celui de la plage.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .onAppear { Task { await contrôleur.rafraîchir() } }
    }
}
