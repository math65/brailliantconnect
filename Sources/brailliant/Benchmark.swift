import BrailliantKit
import Foundation

/// Mesures de latence du protocole MTP.
///
/// Objectif : savoir si une intégration au Finder est jouable, et avec quelle
/// stratégie de cache. Le Finder énumère un dossier à chaque ouverture et
/// demande les attributs de chaque élément ; si une énumération coûte plusieurs
/// secondes, aucun habillage ne rendra l'expérience acceptable.
enum Benchmark {

    /// Chronomètre monotone, insensible aux changements d'heure système.
    private static func duration(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000  // ms
    }

    private static func ms(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    static func run(_ plage: Brailliant, _ options: Options, path: String) throws {
        say("Mesures de latence MTP — \(plage.model)")
        say("Chaque chiffre indique ce que coûterait l'opération équivalente")
        say("au Finder. Plage branchée en USB, aucune autre application connectée.")
        say()

        // --- Énumération : l'opération que le Finder déclenche le plus ---
        say("ÉNUMÉRATION D'UN DOSSIER")
        say("(le Finder la relance à chaque ouverture de dossier)")
        say()

        var dossiers: [(String, Int)] = []
        for entry in try plage.listDirectory(path) where entry.isDirectory {
            let count = (try? plage.listDirectory(entry.path).count) ?? 0
            dossiers.append((entry.path, count))
        }
        dossiers.insert((RemotePath.normalize(path), try plage.listDirectory(path).count), at: 0)

        for (chemin, nombre) in dossiers {
            var premier = 0.0
            var second = 0.0
            premier = try duration { _ = try plage.listDirectory(chemin) }
            second = try duration { _ = try plage.listDirectory(chemin) }
            let parElement = nombre > 0 ? premier / Double(nombre) : 0
            say("  \(chemin)")
            say("    \(nombre) élément(s) — premier passage \(ms(premier)), "
                + "second \(ms(second))")
            if nombre > 0 {
                say("    soit \(ms(parElement)) par élément")
            }
            // Un second passage nettement plus rapide révélerait un cache
            // interne ; sinon chaque ouverture de dossier paiera le prix fort.
            if premier > 0, second < premier * 0.5 {
                say("    → mise en cache détectée")
            } else {
                say("    → aucune mise en cache : chaque passage recoûte le même prix")
            }
        }
        say()

        // --- Résolution de chemin : coût caché de chaque opération ---
        say("RÉSOLUTION D'UN CHEMIN")
        say("(exécutée avant chaque lecture, écriture ou suppression)")
        say()

        let fichiers = try plage.walk(path).filter { !$0.isDirectory && !MacJunk.matches($0.name) }
        if let cible = fichiers.first {
            let profondeur = RemotePath.components(cible.path).count
            let coût = try duration { _ = try plage.resolve(cible.path) }
            say("  \(cible.displayPath)")
            say("    profondeur \(profondeur) — \(ms(coût))")
            say("    → resolve() ré-énumère un niveau par segment de chemin")
        }
        say()

        // --- Parcours complet : ce que coûte une copie de dossier ---
        say("PARCOURS RÉCURSIF COMPLET")
        say()
        var total = 0
        let parcours = try duration { total = try plage.walk(path).count }
        say("  \(total) élément(s) parcourus en \(ms(parcours))")
        say()

        // --- Lecture : latence avant le premier octet, puis débit ---
        say("LECTURE D'UN FICHIER")
        say()
        if let petit = fichiers.min(by: { $0.size < $1.size }) {
            try mesurerLecture(plage, petit, étiquette: "le plus petit")
        }
        if let gros = fichiers.max(by: { $0.size < $1.size }), gros.size > 1_000_000 {
            try mesurerLecture(plage, gros, étiquette: "le plus gros")
        }

        say()
        say("VERDICT")
        say()
        let pire = dossiers.map { $0.0 }.compactMap { chemin -> Double? in
            try? duration { _ = try plage.listDirectory(chemin) }
        }.max() ?? 0
        say("  Énumération la plus lente : \(ms(pire))")
        if pire < 200 {
            say("  → Le Finder resterait fluide même sans cache.")
        } else if pire < 1000 {
            say("  → Perceptible mais acceptable ; un cache d'énumération suffirait.")
        } else {
            say("  → Trop lent pour une énumération à la demande.")
            say("    Il faudra construire l'arborescence en tâche de fond et la")
            say("    servir depuis le cache, en rafraîchissant après coup.")
        }
    }

    /// Mesure comment le coût d'énumération évolue avec le nombre d'éléments.
    ///
    /// Les dossiers d'une plage neuve sont petits ; ceux d'un utilisateur qui y
    /// range des centaines de livres ne le sont pas. C'est cette courbe, et non
    /// la latence sur un dossier vide, qui décide si le Finder tiendra.
    ///
    /// Les fichiers de test sont créés dans un dossier dédié et supprimés à la
    /// fin, y compris si la mesure échoue en cours de route.
    static func scale(_ plage: Brailliant, _ options: Options, maximum: Int) throws {
        let dossier = "/documents/.bench-\(UUID().uuidString.prefix(8))"
        let source = NSTemporaryDirectory() + "brailliant-bench-source.txt"
        try "mesure de montée en charge\n".write(toFile: source, atomically: true,
                                                 encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: source)
            // Nettoyage impératif : ne rien laisser sur la plage de l'utilisateur.
            say()
            say("Nettoyage…")
            do {
                try plage.remove(dossier, recursive: true)
                say("  dossier de test supprimé")
            } catch {
                complain("  ATTENTION : « \(dossier) » n'a pas pu être supprimé. "
                         + "Retirez-le avec : brailliant rm -r \(dossier)")
            }
        }

        try plage.createDirectory(dossier)
        say("MONTÉE EN CHARGE")
        say("(création de fichiers de test dans \(dossier))")
        say()

        let paliers = [10, 25, 50, 100, 200, 400].filter { $0 <= maximum }
        var créés = 0

        for palier in paliers {
            while créés < palier {
                créés += 1
                _ = try plage.upload(source, to: "\(dossier)/fichier-\(créés).txt")
            }
            var mesures: [Double] = []
            for _ in 0..<3 {
                mesures.append(try duration { _ = try plage.listDirectory(dossier) })
            }
            let médiane = mesures.sorted()[1]
            let parElement = médiane / Double(palier)
            say("  \(palier) fichiers : énumération \(ms(médiane)) "
                + "— \(ms(parElement)) par élément")
        }

        say()
        say("Lecture de la courbe : si le temps par élément reste stable, le coût")
        say("est linéaire et prévisible. S'il augmente, l'énumération dégénère et")
        say("un cache devient indispensable au-delà d'une certaine taille.")
    }

    private static func mesurerLecture(_ plage: Brailliant, _ entry: Entry,
                                       étiquette: String) throws {
        let cible = NSTemporaryDirectory() + "brailliant-bench-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: cible) }

        var premierOctet: Double?
        let début = DispatchTime.now().uptimeNanoseconds
        let total = try duration {
            _ = try plage.download(entry.path, to: cible) { transféré, _ in
                if premierOctet == nil, transféré > 0 {
                    premierOctet = Double(DispatchTime.now().uptimeNanoseconds - début) / 1_000_000
                }
            }
        }
        say("  \(entry.displayName) (\(étiquette), \(entry.humanSize))")
        if let premierOctet {
            say("    premier octet après \(ms(premierOctet))")
        }
        say("    transfert complet \(ms(total))")
        if total > 0, entry.size > 100_000 {
            let débit = Double(entry.size) / 1_000_000 / (total / 1000)
            say(String(format: "    débit %.1f Mo/s", débit).replacingOccurrences(of: ".", with: ","))
        }
    }
}
