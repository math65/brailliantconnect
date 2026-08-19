import BrailliantKit
import Foundation

/// Latency measurements for the MTP protocol.
///
/// The point is to find out whether a Finder integration is viable at all, and
/// with which caching strategy. The Finder enumerates a folder every time it is
/// opened and asks for the attributes of each item; if a single enumeration
/// costs several seconds, no amount of polish will make the experience
/// acceptable.
enum Benchmark {

    /// Monotonic stopwatch, immune to system clock changes.
    private static func duration(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000  // ms
    }

    private static func ms(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    static func run(_ display: Brailliant, _ options: Options, path: String) throws {
        say("Mesures de latence MTP — \(display.model)")
        say("Chaque chiffre indique ce que coûterait l'opération équivalente")
        say("au Finder. Plage branchée en USB, aucune autre application connectée.")
        say()

        // --- Enumeration: the operation the Finder triggers most often ---
        say("ÉNUMÉRATION D'UN DOSSIER")
        say("(le Finder la relance à chaque ouverture de dossier)")
        say()

        var folders: [(String, Int)] = []
        for entry in try display.listDirectory(path) where entry.isDirectory {
            let count = (try? display.listDirectory(entry.path).count) ?? 0
            folders.append((entry.path, count))
        }
        folders.insert((RemotePath.normalize(path), try display.listDirectory(path).count), at: 0)

        for (folder, count) in folders {
            var firstPass = 0.0
            var secondPass = 0.0
            firstPass = try duration { _ = try display.listDirectory(folder) }
            secondPass = try duration { _ = try display.listDirectory(folder) }
            let perItem = count > 0 ? firstPass / Double(count) : 0
            say("  \(folder)")
            say(
                "    \(count) élément(s) — premier passage \(ms(firstPass)), "
                    + "second \(ms(secondPass))")
            if count > 0 {
                say("    soit \(ms(perItem)) par élément")
            }
            // A markedly faster second pass would reveal an internal cache;
            // without one, every folder opening pays the full price again.
            if firstPass > 0, secondPass < firstPass * 0.5 {
                say("    → mise en cache détectée")
            } else {
                say("    → aucune mise en cache : chaque passage recoûte le même prix")
            }
        }
        say()

        // --- Path resolution: the hidden cost behind every operation ---
        say("RÉSOLUTION D'UN CHEMIN")
        say("(exécutée avant chaque lecture, écriture ou suppression)")
        say()

        let files = try display.walk(path).filter { !$0.isDirectory && !MacJunk.matches($0.name) }
        if let target = files.first {
            let depth = RemotePath.components(target.path).count
            let cost = try duration { _ = try display.resolve(target.path) }
            say("  \(target.displayPath)")
            say("    profondeur \(depth) — \(ms(cost))")
            say("    → resolve() ré-énumère un niveau par segment de chemin")
        }
        say()

        // --- Full traversal: what copying a folder costs ---
        say("PARCOURS RÉCURSIF COMPLET")
        say()
        var total = 0
        let walkTime = try duration { total = try display.walk(path).count }
        say("  \(total) élément(s) parcourus en \(ms(walkTime))")
        say()

        // --- Reading: latency before the first byte, then throughput ---
        say("LECTURE D'UN FICHIER")
        say()
        if let smallest = files.min(by: { $0.size < $1.size }) {
            try measureRead(display, smallest, label: "le plus petit")
        }
        if let largest = files.max(by: { $0.size < $1.size }), largest.size > 1_000_000 {
            try measureRead(display, largest, label: "le plus gros")
        }

        say()
        say("VERDICT")
        say()
        let worst =
            folders.map { $0.0 }.compactMap { folder -> Double? in
                try? duration { _ = try display.listDirectory(folder) }
            }.max() ?? 0
        say("  Énumération la plus lente : \(ms(worst))")
        if worst < 200 {
            say("  → Le Finder resterait fluide même sans cache.")
        } else if worst < 1000 {
            say("  → Perceptible mais acceptable ; un cache d'énumération suffirait.")
        } else {
            say("  → Trop lent pour une énumération à la demande.")
            say("    Il faudra construire l'arborescence en tâche de fond et la")
            say("    servir depuis le cache, en rafraîchissant après coup.")
        }
    }

    /// Measures how the cost of an enumeration evolves with the number of items.
    ///
    /// The folders of a brand-new display are small; those of a user who keeps
    /// hundreds of books on it are not. It is this curve, and not the latency
    /// on an empty folder, that decides whether the Finder will hold up.
    ///
    /// The test files are created in a dedicated folder and removed at the end,
    /// including when the measurement fails halfway through.
    static func scale(_ display: Brailliant, _ options: Options, maximum: Int) throws {
        let folder = "/documents/.bench-\(UUID().uuidString.prefix(8))"
        let source = NSTemporaryDirectory() + "brailliant-bench-source.txt"
        try "mesure de montée en charge\n".write(
            toFile: source, atomically: true,
            encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: source)
            // Cleaning up is mandatory: leave nothing behind on the user's display.
            say()
            say("Nettoyage…")
            do {
                try display.remove(folder, recursive: true)
                say("  dossier de test supprimé")
            } catch {
                complain(
                    "  ATTENTION : « \(folder) » n'a pas pu être supprimé. "
                        + "Retirez-le avec : brailliant rm -r \(folder)")
            }
        }

        try display.createDirectory(folder)
        say("MONTÉE EN CHARGE")
        say("(création de fichiers de test dans \(folder))")
        say()

        let steps = [10, 25, 50, 100, 200, 400].filter { $0 <= maximum }
        var created = 0

        for step in steps {
            while created < step {
                created += 1
                _ = try display.upload(source, to: "\(folder)/fichier-\(created).txt")
            }
            var samples: [Double] = []
            for _ in 0..<3 {
                samples.append(try duration { _ = try display.listDirectory(folder) })
            }
            let median = samples.sorted()[1]
            let perItem = median / Double(step)
            say(
                "  \(step) fichiers : énumération \(ms(median)) "
                    + "— \(ms(perItem)) par élément")
        }

        say()
        say("Lecture de la courbe : si le temps par élément reste stable, le coût")
        say("est linéaire et prévisible. S'il augmente, l'énumération dégénère et")
        say("un cache devient indispensable au-delà d'une certaine taille.")
    }

    private static func measureRead(
        _ display: Brailliant, _ entry: Entry,
        label: String
    ) throws {
        let target = NSTemporaryDirectory() + "brailliant-bench-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: target) }

        var firstByte: Double?
        let start = DispatchTime.now().uptimeNanoseconds
        let total = try duration {
            _ = try display.download(entry.path, to: target) { transferred, _ in
                if firstByte == nil, transferred > 0 {
                    firstByte = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                }
            }
        }
        say("  \(entry.displayName) (\(label), \(entry.humanSize))")
        if let firstByte {
            say("    premier octet après \(ms(firstByte))")
        }
        say("    transfert complet \(ms(total))")
        if total > 0, entry.size > 100_000 {
            let throughput = Double(entry.size) / 1_000_000 / (total / 1000)
            say(
                String(format: "    débit %.1f Mo/s", throughput).replacingOccurrences(
                    of: ".", with: ","))
        }
    }
}
