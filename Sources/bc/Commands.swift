import BrailliantKit
import Foundation

/// Options communes à toutes les commandes.
struct Options {
    var debug = false
    var showProgress = Console.shared.isInteractive
    var showAll = false      // inclure les fichiers parasites macOS
    var long = false         // afficher les tailles
    var recursive = false
    var dryRun = false
    var noOverwrite = false
    var force = false    // saute les confirmations
    var anyDevice = false    // accepte un appareil MTP non-HumanWare
    var storage: String?     // stockage ciblé (numéro ou nom)
    var depth = 0
}

/// Progression affichée par paliers de 10 %.
///
/// Un rafraîchissement continu serait pénible à suivre au lecteur d'écran, et
/// illisible une fois la sortie redirigée : on n'affiche donc rien hors
/// terminal interactif.
func makeProgress(label: String, options: Options) -> ProgressHandler? {
    guard options.showProgress else { return nil }
    var lastStep = -1
    return { sent, total in
        guard total > 0 else { return }
        let step = Int(sent * 10 / total)
        guard step != lastStep else { return }
        lastStep = step
        let percent = min(100, step * 10)
        let terminator = sent >= total ? "\n" : "\r"
        Console.shared.partial("  \(label) : \(percent) %   \(terminator)")
    }
}

/// Rend une entrée affichable.
///
/// Le nom passe par `displayName` : venant de la plage, il pourrait contenir
/// des séquences d'échappement capables de manipuler le terminal.
func describe(_ entry: Entry, long: Bool) -> String {
    var name = entry.displayName + (entry.isDirectory ? "/" : "")
    // Un nom inutilisable comme chemin local est signalé : l'utilisateur doit
    // savoir que l'élément existe, et pourquoi il ne peut pas être copié.
    if !entry.hasSafeName { name += "   [nom inutilisable — non copiable]" }
    guard long else { return name }
    let size = entry.isDirectory ? "dossier" : entry.humanSize
    return String(repeating: " ", count: max(0, 10 - size.count)) + size + "  " + name
}

enum Commands {

    // MARK: info

    static func info(_ plage: Brailliant, _ options: Options) throws {
        say("Appareil : \(plage.model)")
        if !plage.friendlyName.isEmpty && plage.friendlyName != plage.model {
            say("Nom      : \(plage.friendlyName)")
        }
        say("Série    : \(plage.serialNumber)")
        say(String(format: "USB      : fabricant 0x%04x, produit 0x%04x",
                   plage.vendorID, plage.productID))
        say()
        let storages = try plage.storages()
        let current = try plage.defaultStorage()
        for (index, storage) in storages.enumerated() {
            // Le numéro affiché est celui à passer à -s.
            let actif = storage.id == current.id ? "   [actif]" : ""
            say("Stockage \(index + 1) « \(storage.description.sanitizedForDisplay) »\(actif)")
            say("  capacité   : \(humanSize(storage.capacity))")
            say("  utilisé    : \(humanSize(storage.used)) (\(storage.usedPercent) %)")
            say("  disponible : \(humanSize(storage.free))")
        }
        if storages.count > 1 {
            say()
            say("Pour travailler sur un autre stockage : bc -s <numéro ou nom> …")
        }
    }

    // MARK: ls

    static func list(_ plage: Brailliant, _ options: Options, path: String) throws {
        var entries = try plage.listDirectory(path)
        if !options.showAll { entries.removeAll { MacJunk.matches($0.name) } }

        guard !entries.isEmpty else {
            say("(dossier vide : \(RemotePath.normalize(path)))")
            return
        }
        for entry in entries { say(describe(entry, long: options.long)) }

        if options.long {
            let files = entries.filter { !$0.isDirectory }
            let total = files.reduce(UInt64(0)) { $0 + $1.size }
            say()
            say("\(entries.count) élément(s), \(files.count) fichier(s), \(humanSize(total))")
        }

        // À la racine, signaler les stockages non affichés : sans cela, une
        // carte SD ou une clé passerait inaperçue.
        if RemotePath.normalize(path) == "/", options.storage == nil {
            let storages = try plage.storages()
            if storages.count > 1 {
                let current = try plage.defaultStorage()
                let autres = storages.enumerated()
                    .filter { $0.element.id != current.id }
                    .map { "\($0.offset + 1) « \($0.element.description.sanitizedForDisplay) »" }
                say()
                say("Contenu de « \(current.description.sanitizedForDisplay) ». "
                    + "Autre(s) stockage(s) : \(autres.joined(separator: ", ")) — "
                    + "utilisez -s pour y accéder.")
            }
        }
    }

    // MARK: tree

    static func tree(_ plage: Brailliant, _ options: Options, path: String) throws {
        func walk(_ current: String, _ level: Int) throws {
            if options.depth > 0 && level >= options.depth { return }
            for entry in try plage.listDirectory(current) {
                if !options.showAll && MacJunk.matches(entry.name) { continue }
                say(String(repeating: "  ", count: level) + describe(entry, long: false))
                if entry.isDirectory { try walk(entry.path, level + 1) }
            }
        }
        try walk(path, 0)
    }

    // MARK: get

    static func get(_ plage: Brailliant, _ options: Options,
                    remote: String, local: String?) throws {
        guard let entry = try plage.resolve(remote) else {
            throw MTPError.notFound(path: remote)
        }
        let destination = local ?? "."

        if entry.isDirectory {
            let root = (destination as NSString).expandingTildeInPath
            // Le nom du dossier vient lui aussi de la plage.
            let base = try LocalPath.confine(root: root, relative: entry.name)
            var count = 0
            var total: UInt64 = 0
            var refused = 0

            for item in try plage.walk(entry.path) {
                if !options.showAll && MacJunk.matches(item.name) { continue }
                let relative = String(item.path.dropFirst(entry.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                // Chaque segment provient du périphérique : la cible est
                // construite sous contrôle, et l'élément est ignoré — avec un
                // avertissement — plutôt que d'interrompre toute la copie.
                let target: String
                do {
                    target = try LocalPath.confine(root: base, relative: relative)
                } catch {
                    refused += 1
                    complain("  IGNORÉ (nom dangereux) : \(item.displayName)")
                    continue
                }

                if item.isDirectory {
                    try FileManager.default.createDirectory(atPath: target,
                                                            withIntermediateDirectories: true)
                    continue
                }
                try plage.download(item.path, to: target,
                                   progress: makeProgress(label: item.displayName,
                                                          options: options))
                count += 1
                total += item.size
                say("  reçu : \(relative.sanitizedForDisplay) (\(item.humanSize))")
            }
            say("\(count) fichier(s) reçus dans \(base) (\(humanSize(total)))")
            if refused > 0 {
                complain("\(refused) élément(s) ignoré(s) : nom incompatible avec le disque.")
            }
            return
        }

        let written = try plage.download(remote, to: destination,
                                         progress: makeProgress(
                                            label: "Téléchargement de \(entry.displayName)",
                                            options: options))
        say("Reçu : \(written) (\(entry.humanSize))")
    }

    // MARK: put

    static func put(_ plage: Brailliant, _ options: Options,
                    local: String, remote: String?) throws {
        let source = (local as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
            throw MTPError.localFileMissing(path: source)
        }

        if isDirectory.boolValue {
            try putDirectory(plage, options, source: source, remote: remote)
            return
        }

        var target = remote ?? "/documents"
        // Si la cible désigne un dossier existant, on y dépose le fichier.
        let existing = try plage.resolve(target)
        if target.hasSuffix("/") || (existing?.isDirectory ?? false) {
            let name = (source as NSString).lastPathComponent
            target = RemotePath.join(RemotePath.normalize(target), name)
        }

        let name = (source as NSString).lastPathComponent
        let entry = try plage.upload(source, to: target,
                                     progress: makeProgress(label: "Envoi de \(name)",
                                                            options: options),
                                     overwrite: !options.noOverwrite)
        say("Envoyé : \(entry.displayPath) (\(entry.humanSize))")
    }

    private static func putDirectory(_ plage: Brailliant, _ options: Options,
                                     source: String, remote: String?) throws {
        let folderName = (source as NSString).lastPathComponent
        let base = RemotePath.join(RemotePath.normalize(remote ?? "/documents"), folderName)
        var count = 0
        var total: UInt64 = 0

        guard let walker = FileManager.default.enumerator(atPath: source) else {
            throw MTPError.localFileMissing(path: source)
        }
        try plage.createDirectory(base)

        for case let relative as String in walker {
            let fullPath = (source as NSString).appendingPathComponent(relative)
            let name = (relative as NSString).lastPathComponent
            if MacJunk.matches(name) { continue }

            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory)
            let remotePath = RemotePath.join(base, relative.replacingOccurrences(of: "\\", with: "/"))

            if isDirectory.boolValue {
                try plage.createDirectory(remotePath)
                continue
            }
            let entry = try plage.upload(fullPath, to: remotePath,
                                         progress: makeProgress(label: name, options: options),
                                         overwrite: !options.noOverwrite)
            count += 1
            total += entry.size
            say("  envoyé : \(entry.displayPath) (\(entry.humanSize))")
        }
        say("\(count) fichier(s) envoyés vers \(base) (\(humanSize(total)))")
    }

    // MARK: rm / mkdir

    static func remove(_ plage: Brailliant, _ options: Options, paths: [String]) throws {
        for path in paths {
            guard let entry = try plage.resolve(path) else {
                complain("Ignoré (introuvable) : \(path.sanitizedForDisplay)")
                continue
            }

            // Une suppression récursive est irréversible et peut emporter
            // beaucoup de fichiers : on annonce le volume exact avant d'agir.
            // Hors terminal interactif on n'interroge pas, pour rester
            // utilisable dans un script ; -f permet de sauter la question.
            if entry.isDirectory && options.recursive && !options.force
                && Console.shared.isInteractive {
                let contents = try plage.walk(entry.path)
                if !contents.isEmpty {
                    let files = contents.filter { !$0.isDirectory }.count
                    Console.shared.partial(
                        "Supprimer « \(entry.displayPath) » et son contenu "
                        + "(\(contents.count) élément(s), dont \(files) fichier(s)) ? [o/N] ")
                    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    guard answer == "o" || answer == "oui" else {
                        say("Abandon : rien n'a été supprimé.")
                        continue
                    }
                }
            }

            try plage.remove(path, recursive: options.recursive)
            say("Supprimé : \(entry.displayPath)")
        }
    }

    static func makeDirectory(_ plage: Brailliant, _ options: Options, paths: [String]) throws {
        for path in paths {
            let entry = try plage.createDirectory(path)
            say("Dossier prêt : \(entry.displayPath)")
        }
    }

    // MARK: clean

    static func clean(_ plage: Brailliant, _ options: Options) throws {
        let victims = try plage.walk("/").filter { !$0.isDirectory && MacJunk.matches($0.name) }
        guard !victims.isEmpty else {
            say("Aucun fichier parasite macOS trouvé.")
            return
        }
        say("\(victims.count) fichier(s) parasite(s) trouvé(s) :")
        for entry in victims { say("  \(entry.displayPath) (\(entry.humanSize))") }

        if options.dryRun {
            say()
            say("(simulation : rien n'a été supprimé — relancez sans -n)")
            return
        }
        for entry in victims { try plage.remove(entry.path) }
        say()
        say("\(victims.count) fichier(s) supprimé(s).")
    }

    // MARK: doctor

    static func doctor(_ plage: Brailliant, _ options: Options) throws {
        say("Connexion  : OK")
        say("Appareil   : \(plage.model) (série \(plage.serialNumber))")
        let storages = try plage.storages()
        let current = try plage.defaultStorage()
        say("Stockages  : \(storages.count) détecté(s), "
            + "actif : « \(current.description.sanitizedForDisplay) »")

        let root = try plage.listDirectory("/")
        say("Racine     : \(root.count) élément(s) lisibles")

        // « Embarquée » signifie : livrée avec le programme — soit à côté du
        // binaire (paquet distribué), soit dans Vendor/ (arbre de développement).
        let path = plage.libraryPath
        let libraryDirectory = (path as NSString).deletingLastPathComponent
        let executableDirectory = (Bundle.main.executablePath as NSString?)?
            .deletingLastPathComponent
        let embedded = libraryDirectory == executableDirectory || path.contains("/Vendor/")
        say("libmtp     : \(embedded ? "copie embarquée" : "installation système")")
        say("             \(path)")

        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        say("Machine    : \(architecture), macOS \(version.majorVersion).\(version.minorVersion)")

        let junk = root.filter { MacJunk.matches($0.name) }
        if !junk.isEmpty {
            say("Parasites  : \(junk.count) fichier(s) macOS à la racine "
                + "(commande « bc clean » pour les retirer)")
        }
        say()
        say("Tout fonctionne. Aucun macFUSE ni extension noyau n'est utilisé.")
    }
}
