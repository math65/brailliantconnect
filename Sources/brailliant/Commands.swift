import BrailliantKit
import Foundation

/// Options shared by every command.
struct Options {
    var debug = false
    var showProgress = Console.shared.isInteractive
    var showAll = false  // include the macOS junk files
    var long = false  // show sizes
    var recursive = false
    var dryRun = false
    var noOverwrite = false
    var force = false  // skips the confirmations
    var anyDevice = false  // accept a non-HumanWare MTP device
    var storage: String?  // target storage (number or name)
    var scale = 0  // maximum size for bench --scale
    var depth = 0
}

/// Progress reported in steps of 10 %.
///
/// A continuously refreshing display would be painful to follow with a screen
/// reader, and unreadable once the output is redirected: nothing at all is
/// printed outside an interactive terminal.
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

/// Renders an entry for display.
///
/// The name goes through `displayName`: coming from the braille display, it
/// could contain escape sequences able to drive the terminal.
func describe(_ entry: Entry, long: Bool) -> String {
    var name = entry.displayName + (entry.isDirectory ? "/" : "")
    // A name that cannot be used as a local path is flagged: the user has to
    // know that the item exists, and why it cannot be copied.
    if !entry.hasSafeName { name += "   [nom inutilisable — non copiable]" }
    guard long else { return name }
    let size = entry.isDirectory ? "dossier" : entry.humanSize
    return String(repeating: " ", count: max(0, 10 - size.count)) + size + "  " + name
}

enum Commands {

    // MARK: info

    static func info(_ display: Brailliant, _ options: Options) throws {
        say("Appareil : \(display.model)")
        if !display.friendlyName.isEmpty && display.friendlyName != display.model {
            say("Nom      : \(display.friendlyName)")
        }
        say("Série    : \(display.serialNumber)")
        say(
            String(
                format: "USB      : fabricant 0x%04x, produit 0x%04x",
                display.vendorID, display.productID))
        say()
        let storages = try display.storages()
        let current = try display.defaultStorage()
        for (index, storage) in storages.enumerated() {
            // The number shown is the one to pass to -s.
            let active = storage.id == current.id ? "   [actif]" : ""
            say("Stockage \(index + 1) « \(storage.description.sanitizedForDisplay) »\(active)")
            say("  capacité   : \(humanSize(storage.capacity))")
            say("  utilisé    : \(humanSize(storage.used)) (\(storage.usedPercent) %)")
            say("  disponible : \(humanSize(storage.free))")
        }
        if storages.count > 1 {
            say()
            say("Pour travailler sur un autre stockage : brailliant -s <numéro ou nom> …")
        }
    }

    // MARK: ls

    static func list(_ display: Brailliant, _ options: Options, path: String) throws {
        var entries = try display.listDirectory(path)
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

        // At the root, point out the storages that are not being shown:
        // without this, an SD card or a USB key would go unnoticed.
        if RemotePath.normalize(path) == "/", options.storage == nil {
            let storages = try display.storages()
            if storages.count > 1 {
                let current = try display.defaultStorage()
                let others = storages.enumerated()
                    .filter { $0.element.id != current.id }
                    .map { "\($0.offset + 1) « \($0.element.description.sanitizedForDisplay) »" }
                say()
                say(
                    "Contenu de « \(current.description.sanitizedForDisplay) ». "
                        + "Autre(s) stockage(s) : \(others.joined(separator: ", ")) — "
                        + "utilisez -s pour y accéder.")
            }
        }
    }

    // MARK: tree

    static func tree(_ display: Brailliant, _ options: Options, path: String) throws {
        func walk(_ current: String, _ level: Int) throws {
            if options.depth > 0 && level >= options.depth { return }
            for entry in try display.listDirectory(current) {
                if !options.showAll && MacJunk.matches(entry.name) { continue }
                say(String(repeating: "  ", count: level) + describe(entry, long: false))
                if entry.isDirectory { try walk(entry.path, level + 1) }
            }
        }
        try walk(path, 0)
    }

    // MARK: get

    static func get(
        _ display: Brailliant, _ options: Options,
        remote: String, local: String?
    ) throws {
        guard let entry = try display.resolve(remote) else {
            throw MTPError.notFound(path: remote)
        }
        let destination = local ?? "."

        if entry.isDirectory {
            let root = (destination as NSString).expandingTildeInPath
            // The folder name comes from the braille display as well.
            let base = try LocalPath.confine(root: root, relative: entry.name)
            var count = 0
            var total: UInt64 = 0
            var refused = 0

            for item in try display.walk(entry.path) {
                if !options.showAll && MacJunk.matches(item.name) { continue }
                let relative = String(item.path.dropFirst(entry.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                // Every segment comes from the device: the target is built
                // under control, and the item is skipped — with a warning —
                // rather than aborting the whole copy.
                let target: String
                do {
                    target = try LocalPath.confine(root: base, relative: relative)
                } catch {
                    refused += 1
                    complain("  IGNORÉ (nom dangereux) : \(item.displayName)")
                    continue
                }

                if item.isDirectory {
                    try FileManager.default.createDirectory(
                        atPath: target,
                        withIntermediateDirectories: true)
                    continue
                }
                try display.download(
                    item.path, to: target,
                    progress: makeProgress(
                        label: item.displayName,
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

        let written = try display.download(
            remote, to: destination,
            progress: makeProgress(
                label: "Téléchargement de \(entry.displayName)",
                options: options))
        say("Reçu : \(written) (\(entry.humanSize))")
    }

    // MARK: put

    static func put(
        _ display: Brailliant, _ options: Options,
        local: String, remote: String?
    ) throws {
        let source = (local as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
            throw MTPError.localFileMissing(path: source)
        }

        if isDirectory.boolValue {
            try putDirectory(display, options, source: source, remote: remote)
            return
        }

        var target = remote ?? "/documents"
        // If the target names an existing folder, the file is dropped inside it.
        let existing = try display.resolve(target)
        if target.hasSuffix("/") || (existing?.isDirectory ?? false) {
            let name = (source as NSString).lastPathComponent
            target = RemotePath.join(RemotePath.normalize(target), name)
        }

        let name = (source as NSString).lastPathComponent
        let entry = try display.upload(
            source, to: target,
            progress: makeProgress(
                label: "Envoi de \(name)",
                options: options),
            overwrite: !options.noOverwrite)
        say("Envoyé : \(entry.displayPath) (\(entry.humanSize))")
    }

    private static func putDirectory(
        _ display: Brailliant, _ options: Options,
        source: String, remote: String?
    ) throws {
        let folderName = (source as NSString).lastPathComponent
        let base = RemotePath.join(RemotePath.normalize(remote ?? "/documents"), folderName)
        var count = 0
        var total: UInt64 = 0

        guard let walker = FileManager.default.enumerator(atPath: source) else {
            throw MTPError.localFileMissing(path: source)
        }
        try display.createDirectory(base)

        for case let relative as String in walker {
            let fullPath = (source as NSString).appendingPathComponent(relative)
            let name = (relative as NSString).lastPathComponent
            if MacJunk.matches(name) { continue }

            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory)
            let remotePath = RemotePath.join(
                base, relative.replacingOccurrences(of: "\\", with: "/"))

            if isDirectory.boolValue {
                try display.createDirectory(remotePath)
                continue
            }
            let entry = try display.upload(
                fullPath, to: remotePath,
                progress: makeProgress(label: name, options: options),
                overwrite: !options.noOverwrite)
            count += 1
            total += entry.size
            say("  envoyé : \(entry.displayPath) (\(entry.humanSize))")
        }
        say("\(count) fichier(s) envoyés vers \(base) (\(humanSize(total)))")
    }

    // MARK: rm / mkdir

    static func remove(_ display: Brailliant, _ options: Options, paths: [String]) throws {
        for path in paths {
            guard let entry = try display.resolve(path) else {
                complain("Ignoré (introuvable) : \(path.sanitizedForDisplay)")
                continue
            }

            // A recursive delete is irreversible and can take a lot of files
            // with it: the exact volume is announced before anything happens.
            // Outside an interactive terminal no question is asked, so the tool
            // stays usable from a script; -f skips the question.
            if entry.isDirectory && options.recursive && !options.force
                && Console.shared.isInteractive
            {
                let contents = try display.walk(entry.path)
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

            try display.remove(path, recursive: options.recursive)
            say("Supprimé : \(entry.displayPath)")
        }
    }

    static func makeDirectory(_ display: Brailliant, _ options: Options, paths: [String]) throws {
        for path in paths {
            let entry = try display.createDirectory(path)
            say("Dossier prêt : \(entry.displayPath)")
        }
    }

    // MARK: clean

    static func clean(_ display: Brailliant, _ options: Options) throws {
        let victims = try display.walk("/").filter { !$0.isDirectory && MacJunk.matches($0.name) }
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
        for entry in victims { try display.remove(entry.path) }
        say()
        say("\(victims.count) fichier(s) supprimé(s).")
    }

    // MARK: doctor

    static func doctor(_ display: Brailliant, _ options: Options) throws {
        say("Connexion  : OK")
        say("Appareil   : \(display.model) (série \(display.serialNumber))")
        let storages = try display.storages()
        let current = try display.defaultStorage()
        say(
            "Stockages  : \(storages.count) détecté(s), "
                + "actif : « \(current.description.sanitizedForDisplay) »")

        let root = try display.listDirectory("/")
        say("Racine     : \(root.count) élément(s) lisibles")

        // "Embedded" means: shipped with the program — either next to the
        // binary (distributed package), or in Vendor/ (development tree).
        let path = display.libraryPath
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
            say(
                "Parasites  : \(junk.count) fichier(s) macOS à la racine "
                    + "(commande « brailliant clean » pour les retirer)")
        }
        say()
        say("Tout fonctionne. Aucun macFUSE ni extension noyau n'est utilisé.")
    }
}
