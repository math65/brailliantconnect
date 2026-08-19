import BrailliantKit
import Foundation

/// Pilotage de l'emplacement Finder depuis la ligne de commande.
///
/// Le travail réel est fait par un agent : un processus discret qui surveille
/// le port USB et publie ou retire l'emplacement selon que la plage est
/// branchée. Seul le bundle d'application qui héberge l'extension peut
/// déclarer un domaine File Provider, d'où ce détour.
enum Finder {

    private static let étiquette = "com.mathieumartin.BrailliantConnect.agent"

    /// Emplacements où chercher l'application hôte, du plus probable au moins.
    private static let emplacements = [
        "/Applications/BrailliantConnect.app",
        NSHomeDirectory() + "/Applications/BrailliantConnect.app",
    ]

    private static var fichierAgent: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(étiquette).plist")
    }

    private static var journal: String {
        NSHomeDirectory() + "/Library/Logs/BrailliantConnect.log"
    }

    private static func exécutableHôte() throws -> String {
        for base in emplacements {
            let binaire = base + "/Contents/MacOS/BrailliantConnect"
            if FileManager.default.isExecutableFile(atPath: binaire) { return binaire }
        }
        throw MTPError.applicationHôteIntrouvable(cherchée: emplacements)
    }

    @discardableResult
    private static func lancer(_ outil: String, _ arguments: [String]) -> (String, Int32) {
        let processus = Process()
        processus.executableURL = URL(fileURLWithPath: outil)
        processus.arguments = arguments
        let tube = Pipe()
        processus.standardOutput = tube
        processus.standardError = tube
        do { try processus.run() } catch { return ("", -1) }
        let données = tube.fileHandleForReading.readDataToEndOfFile()
        processus.waitUntilExit()
        let texte = String(data: données, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (texte, processus.terminationStatus)
    }

    // MARK: - Installation de l'agent

    /// Installe l'agent et le démarre.
    ///
    /// Une fois en place, il se relance à chaque ouverture de session : plus
    /// aucune commande à taper, la plage apparaît et disparaît toute seule.
    static func activer() throws {
        let binaire = try exécutableHôte()
        let dossier = fichierAgent.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": étiquette,
            "ProgramArguments": [binaire, "--watch"],
            // Démarrer à l'ouverture de session, et repartir en cas d'arrêt.
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": journal,
            "StandardErrorPath": journal,
            "ProcessType": "Background",
        ]
        let données = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
        try données.write(to: fichierAgent)

        // Recharger : « bootout » puis « bootstrap » remplace une éventuelle
        // version précédente, là où un simple chargement échouerait.
        let cible = "gui/\(getuid())"
        lancer("/bin/launchctl", ["bootout", "\(cible)/\(étiquette)"])
        let (sortie, code) = lancer("/bin/launchctl",
                                    ["bootstrap", cible, fichierAgent.path])
        guard code == 0 else {
            throw MTPError.agentNonDémarré(détail: sortie.isEmpty ? "code \(code)" : sortie)
        }
        say("Surveillance activée.")
        say("La plage apparaît dans « ~/Brailliant » dès qu'elle est branchée, "
            + "et disparaît quand elle est retirée.")
        say("L'agent redémarrera tout seul à chaque ouverture de session.")
    }

    /// Arrête l'agent, le retire du démarrage et dépublie l'emplacement.
    static func désactiver() throws {
        lancer("/bin/launchctl", ["bootout", "gui/\(getuid())/\(étiquette)"])
        try? FileManager.default.removeItem(at: fichierAgent)

        // L'agent parti, l'emplacement resterait publié : on le retire.
        if let binaire = try? exécutableHôte() {
            let (sortie, _) = lancer(binaire, ["--unpublish"])
            if !sortie.isEmpty { say(sortie) }
        }
        say("Surveillance désactivée. L'agent ne redémarrera plus.")
    }

    static func état() throws {
        let binaire = try exécutableHôte()
        let (sortie, _) = lancer(binaire, ["--status"])
        let installé = FileManager.default.fileExists(atPath: fichierAgent.path)
        let (liste, _) = lancer("/bin/launchctl", ["print", "gui/\(getuid())/\(étiquette)"])
        let actif = !liste.isEmpty && !liste.contains("Could not find")

        say("Emplacement : \(sortie.isEmpty ? "état inconnu" : sortie)")
        say("Surveillance : " + (installé
            ? (actif ? "active, relancée à chaque session" : "installée mais arrêtée")
            : "non installée"))
        if !installé {
            say("Pour l'activer : brailliant finder on")
        }
    }
}
