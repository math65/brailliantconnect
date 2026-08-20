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
        let line = L.t("%@: %@%%", label, String(percent))
        Console.shared.partial("  \(line)   \(terminator)")
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
    if !entry.hasSafeName { name += "   " + L.t("[unusable name — cannot be copied]") }
    guard long else { return name }
    let size = entry.isDirectory ? L.t("folder") : entry.humanSize
    return String(repeating: " ", count: max(0, 10 - size.count)) + size + "  " + name
}

enum Commands {

    // MARK: info

    static func info(_ display: Brailliant, _ options: Options) throws {
        say(L.t("Device: %@", display.model))
        if !display.friendlyName.isEmpty && display.friendlyName != display.model {
            say(L.t("Name:   %@", display.friendlyName))
        }
        say(L.t("Serial: %@", display.serialNumber))
        say(
            L.t(
                "USB:    %@",
                L.t("vendor 0x%04x, product 0x%04x", display.vendorID, display.productID)))
        say()
        let storages = try display.storages()
        let current = try display.defaultStorage()
        for (index, storage) in storages.enumerated() {
            // The number shown is the one to pass to -s.
            let active = storage.id == current.id ? "   " + L.t("[active]") : ""
            say(
                L.t(
                    "Storage %@ \"%@\"",
                    String(index + 1), storage.description.sanitizedForDisplay) + active)
            say(L.t("  capacity: %@", humanSize(storage.capacity)))
            say(
                L.t(
                    "  used:     %@ (%@%%)",
                    humanSize(storage.used), String(storage.usedPercent)))
            say(L.t("  free:     %@", humanSize(storage.free)))
        }
        if storages.count > 1 {
            say()
            say(L.t("To work on another storage: brailliant -s <number or name> …"))
        }
    }

    // MARK: ls

    static func list(_ display: Brailliant, _ options: Options, path: String) throws {
        var entries = try display.listDirectory(path)
        if !options.showAll { entries.removeAll { MacJunk.matches($0.name) } }

        guard !entries.isEmpty else {
            say(L.t("(empty folder: %@)", RemotePath.normalize(path)))
            return
        }
        for entry in entries { say(describe(entry, long: options.long)) }

        if options.long {
            let files = entries.filter { !$0.isDirectory }
            let total = files.reduce(UInt64(0)) { $0 + $1.size }
            say()
            say(
                L.t(
                    "%@ item(s), %@ file(s), %@",
                    String(entries.count), String(files.count), humanSize(total)))
        }

        // At the root, point out the storages that are not being shown:
        // without this, an SD card or a USB key would go unnoticed.
        if RemotePath.normalize(path) == "/", options.storage == nil {
            let storages = try display.storages()
            if storages.count > 1 {
                let current = try display.defaultStorage()
                let others = storages.enumerated()
                    .filter { $0.element.id != current.id }
                    .map {
                        L.t(
                            "%@ \"%@\"",
                            String($0.offset + 1),
                            $0.element.description.sanitizedForDisplay)
                    }
                say()
                say(
                    L.t(
                        "Contents of \"%@\". Other storage(s): %@ — use -s to reach them.",
                        current.description.sanitizedForDisplay,
                        others.joined(separator: ", ")))
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
                    complain("  " + L.t("SKIPPED (unsafe name): %@", item.displayName))
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
                say(
                    "  "
                        + L.t(
                            "Received: %@ (%@)",
                            relative.sanitizedForDisplay, item.humanSize))
            }
            say(
                L.t(
                    "%@ file(s) received into %@ (%@)",
                    String(count), base, humanSize(total)))
            if refused > 0 {
                complain(
                    L.t(
                        "%@ item(s) skipped: name unusable on the disk.",
                        String(refused)))
            }
            return
        }

        let written = try display.download(
            remote, to: destination,
            progress: makeProgress(
                label: L.t("Downloading %@", entry.displayName),
                options: options))
        say(L.t("Received: %@ (%@)", written, entry.humanSize))
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
                label: L.t("Sending %@", name),
                options: options),
            overwrite: !options.noOverwrite)
        say(L.t("Sent: %@ (%@)", entry.displayPath, entry.humanSize))
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
            say("  " + L.t("Sent: %@ (%@)", entry.displayPath, entry.humanSize))
        }
        say(L.t("%@ file(s) sent to %@ (%@)", String(count), base, humanSize(total)))
    }

    // MARK: rm / mkdir

    static func remove(_ display: Brailliant, _ options: Options, paths: [String]) throws {
        for path in paths {
            guard let entry = try display.resolve(path) else {
                complain(L.t("Skipped (not found): %@", path.sanitizedForDisplay))
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
                        L.t(
                            "Delete \"%@\" and its contents "
                                + "(%@ item(s), of which %@ file(s))? [y/N] ",
                            entry.displayPath, String(contents.count), String(files)))
                    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    // The accepted answers are localized along with the prompt:
                    // whoever is asked "[o/N]" types "o", not "y".
                    guard answer == L.t("y") || answer == L.t("yes") else {
                        say(L.t("Cancelled: nothing was deleted."))
                        continue
                    }
                }
            }

            try display.remove(path, recursive: options.recursive)
            say(L.t("Deleted: %@", entry.displayPath))
        }
    }

    static func makeDirectory(_ display: Brailliant, _ options: Options, paths: [String]) throws {
        for path in paths {
            let entry = try display.createDirectory(path)
            say(L.t("Folder ready: %@", entry.displayPath))
        }
    }

    // MARK: mv

    /// Renames or moves an item on the display.
    ///
    /// MTP reparents an object rather than transferring it, so moving a large
    /// file within the display is immediate.
    static func move(
        _ display: Brailliant, _ options: Options, from source: String, to destination: String
    ) throws {
        guard let entry = try display.resolve(source) else {
            throw MTPError.notFound(path: source)
        }
        let target = RemotePath.normalize(destination)

        // A destination that is an existing folder means "move into it";
        // anything else is a rename, possibly combined with a move.
        let intoFolder = (try display.resolve(target))?.isDirectory ?? false
        let moved: Entry
        if intoFolder || target == "/" {
            moved = try display.move(entry.path, toFolder: target)
        } else {
            let (parent, name) = RemotePath.split(target)
            let afterMove =
                parent == RemotePath.split(entry.path).parent
                ? entry
                : try display.move(entry.path, toFolder: parent)
            moved = try display.rename(afterMove.path, to: name)
        }
        say(L.t("Moved: %@ → %@", entry.displayPath, moved.displayPath))
    }

    // MARK: clean

    static func clean(_ display: Brailliant, _ options: Options) throws {
        let victims = try display.walk("/").filter { !$0.isDirectory && MacJunk.matches($0.name) }
        guard !victims.isEmpty else {
            say(L.t("No macOS clutter files found."))
            return
        }
        say(L.t("%@ clutter file(s) found:", String(victims.count)))
        for entry in victims { say("  \(entry.displayPath) (\(entry.humanSize))") }

        if options.dryRun {
            say()
            say(L.t("(dry run: nothing was deleted — run again without -n)"))
            return
        }
        for entry in victims { try display.remove(entry.path) }
        say()
        say(L.t("%@ file(s) deleted.", String(victims.count)))
    }

    // MARK: doctor

    static func doctor(_ display: Brailliant, _ options: Options) throws {
        // First line: whoever reads a report needs to know which build produced
        // it before anything else in it means much.
        say(L.t("Version:    %@", Version.current))
        say(L.t("Connection: OK"))
        say(L.t("Device:     %@ (serial %@)", display.model, display.serialNumber))
        let storages = try display.storages()
        let current = try display.defaultStorage()
        say(
            L.t(
                "Storages:   %@ detected, active: \"%@\"",
                String(storages.count), current.description.sanitizedForDisplay))

        let root = try display.listDirectory("/")
        say(L.t("Root:       %@ readable item(s)", String(root.count)))

        // "Embedded" means: shipped with the program — either next to the
        // binary (distributed package), or in Vendor/ (development tree).
        let path = display.libraryPath
        let libraryDirectory = (path as NSString).deletingLastPathComponent
        let executableDirectory = (Bundle.main.executablePath as NSString?)?
            .deletingLastPathComponent
        let embedded = libraryDirectory == executableDirectory || path.contains("/Vendor/")
        say(
            L.t(
                "libmtp:     %@\n            %@",
                L.t(embedded ? "embedded copy" : "system installation"), path))

        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        say(
            L.t(
                "Machine:    %@, macOS %@",
                architecture, "\(version.majorVersion).\(version.minorVersion)"))

        let junk = root.filter { MacJunk.matches($0.name) }
        if !junk.isEmpty {
            say(
                L.t(
                    "Clutter:    %@ macOS file(s) at the root "
                        + "(run \"brailliant clean\" to remove them)",
                    String(junk.count)))
        }
        say()
        say(L.t("Everything works. No macFUSE and no kernel extension is involved."))
    }
}
