import FileProvider
import Foundation

// Agent BrailliantConnect — sans interface.
//
// Lancé sans argument, il reste en tâche de fond et suit l'état de la plage :
// branchée, l'emplacement apparaît dans le Finder ; débranchée, il disparaît
// avec son raccourci. L'utilisateur n'a rien à faire.
//
// Il accepte aussi des commandes ponctuelles, utilisées par « brailliant » :
//   --publish     publie l'emplacement
//   --unpublish   le retire
//   --status      indique s'il est publié
//   --watch       reste en tâche de fond (comportement par défaut)

let identifiantDomaine = NSFileProviderDomainIdentifier("brailliant-principal")
let nomAffiché = "Brailliant"

var emplacementDomaine: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage")
        .appendingPathComponent("BrailliantConnect-\(nomAffiché)")
}

/// Raccourci visible directement dans le dossier maison.
///
/// Sans lui, l'accès dépendrait de la barre latérale du Finder — que l'on peut
/// masquer — ou d'un chemin situé sous ~/Library, dossier caché par défaut.
var raccourci: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(nomAffiché)
}

func créerRaccourci() {
    let fm = FileManager.default
    for _ in 0..<20 {
        if fm.fileExists(atPath: emplacementDomaine.path) { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    guard fm.fileExists(atPath: emplacementDomaine.path) else { return }
    try? fm.removeItem(at: raccourci)
    try? fm.createSymbolicLink(at: raccourci, withDestinationURL: emplacementDomaine)
}

func retirerRaccourci() {
    // Ne retirer que s'il s'agit bien de notre lien : jamais un vrai dossier
    // que l'utilisateur aurait créé sous le même nom.
    let fm = FileManager.default
    guard let cible = try? fm.destinationOfSymbolicLink(atPath: raccourci.path),
          cible.contains("BrailliantConnect-") else { return }
    try? fm.removeItem(at: raccourci)
}

func journal(_ message: String) {
    // La sortie standard part dans le journal du LaunchAgent : c'est là qu'on
    // relit ce qui s'est passé quand l'agent tourne sans terminal.
    let horodatage = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardOutput.write(Data("[\(horodatage)] \(message)\n".utf8))
}

// MARK: - Actions sur le domaine

func publier(_ terminé: @escaping (Error?) -> Void) {
    let domaine = NSFileProviderDomain(identifier: identifiantDomaine, displayName: nomAffiché)
    NSFileProviderManager.add(domaine) { erreur in
        if erreur == nil { créerRaccourci() }
        terminé(erreur)
    }
}

func retirer(_ terminé: @escaping (Error?) -> Void) {
    let domaine = NSFileProviderDomain(identifier: identifiantDomaine, displayName: nomAffiché)
    NSFileProviderManager.remove(domaine) { erreur in
        // Le raccourci part avec le domaine : le laisser pointerait dans le vide.
        retirerRaccourci()
        terminé(erreur)
    }
}

func estPublié(_ terminé: @escaping (Bool) -> Void) {
    NSFileProviderManager.getDomainsWithCompletionHandler { domaines, _ in
        terminé(domaines.contains { $0.identifier == identifiantDomaine })
    }
}

func terminer(_ message: String, code: Int32 = 0) -> Never {
    let flux = code == 0 ? FileHandle.standardOutput : FileHandle.standardError
    flux.write(Data((message + "\n").utf8))
    exit(code)
}

/// Aligne l'état publié sur la présence physique de la plage.
func synchroniserAvecLeMatériel() {
    let branchée = USBWatcher.nombreDePlagesBranchées() > 0
    estPublié { publié in
        switch (branchée, publié) {
        case (true, false):
            publier { erreur in
                journal(erreur == nil
                        ? "plage branchée — emplacement publié dans ~/\(nomAffiché)"
                        : "plage branchée mais publication impossible : \(erreur!.localizedDescription)")
            }
        case (false, true):
            retirer { erreur in
                journal(erreur == nil
                        ? "plage débranchée — emplacement retiré"
                        : "plage débranchée mais retrait impossible : \(erreur!.localizedDescription)")
            }
        default:
            break  // déjà dans l'état voulu
        }
    }
}

// MARK: - Point d'entrée

let arguments = Array(CommandLine.arguments.dropFirst())
let attente = DispatchSemaphore(value: 0)
var codeSortie: Int32 = 0
var messageFinal = ""

switch arguments.first ?? "--watch" {

case "--publish":
    publier { erreur in
        messageFinal = erreur == nil
            ? "Emplacement publié. Accessible dans « ~/\(nomAffiché) »."
            : "Échec de la publication : \(erreur!.localizedDescription)"
        codeSortie = erreur == nil ? 0 : 1
        attente.signal()
    }
    if attente.wait(timeout: .now() + 60) == .timedOut {
        terminer("Le système n'a pas répondu dans le délai imparti.", code: 1)
    }
    terminer(messageFinal, code: codeSortie)

case "--unpublish":
    retirer { erreur in
        messageFinal = erreur == nil
            ? "Emplacement retiré du Finder."
            : "Échec du retrait : \(erreur!.localizedDescription)"
        codeSortie = erreur == nil ? 0 : 1
        attente.signal()
    }
    if attente.wait(timeout: .now() + 60) == .timedOut {
        terminer("Le système n'a pas répondu dans le délai imparti.", code: 1)
    }
    terminer(messageFinal, code: codeSortie)

case "--status":
    let branchée = USBWatcher.nombreDePlagesBranchées() > 0
    estPublié { publié in
        messageFinal = (publié ? "publié — ~/\(nomAffiché)" : "non publié")
            + (branchée ? " · plage branchée" : " · aucune plage branchée")
        codeSortie = publié ? 0 : 2
        attente.signal()
    }
    if attente.wait(timeout: .now() + 30) == .timedOut {
        terminer("Le système n'a pas répondu.", code: 1)
    }
    terminer(messageFinal, code: codeSortie)

case "--watch":
    journal("agent démarré")
    // Aligner l'état dès le lancement : la plage peut déjà être branchée, ou
    // un emplacement peut subsister d'une session précédente.
    synchroniserAvecLeMatériel()

    let observateur = USBWatcher { synchroniserAvecLeMatériel() }
    observateur.démarrer()
    // L'agent vit dans sa boucle d'exécution : IOKit le réveille aux
    // branchements et débranchements, et il ne consomme rien entre-temps.
    CFRunLoopRun()

default:
    terminer("""
        BrailliantConnect — agent de l'emplacement Finder (sans interface).

          (sans argument)   surveille la plage et publie ou retire l'emplacement
          --publish         publie l'emplacement
          --unpublish       le retire
          --status          indique l'état

        Cet agent est normalement piloté par la commande « brailliant ».
        """, code: 2)
}
