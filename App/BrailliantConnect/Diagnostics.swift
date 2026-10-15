import AppKit
import Foundation

/// The state of this machine, as a problem report carries it.
///
/// Section titles and values are in French on purpose: they end up in an email
/// nobody but the author reads, not in the interface.
///
/// It is split in two on a hardware boundary, and that split is the whole point
/// of the file. Everything the agent can answer on its own — the app, the
/// system, what the USB tree says, whether the location is published — is
/// **always** there, because none of it needs the display to answer.
///
/// The rest — model, serial, storages — only the display can tell, and the
/// agent cannot ask it: MTP allows a single session at a time, and the
/// extension holds it for as long as the location is published. Measured
/// rather than assumed: `brailliant doctor` run beside a published location
/// fails with `libusb_claim_interface = -3`, and still failed a minute later.
///
/// So that half is not asked for here, it is picked up: the extension writes
/// what it sees into its own container as it connects, and this reads it. The
/// bundled `brailliant doctor` runs instead whenever the location is not
/// published — the session is free then, and a snapshot may be weeks old — and
/// its failure is attached as-is rather than dropped, since the error it prints
/// is itself the answer to a good half of the reports that will arrive.
///
/// One text file goes with the report, and the agent's own log always leads it.
/// The sections say *that* the location is not published; only the log says
/// what the system answered when it was asked to publish it.
enum Diagnostics {

    /// Collects everything, then calls back on the main queue.
    ///
    /// Asynchronous because two of the answers are: the File Provider domain is
    /// read through the system, and the display is questioned by running a
    /// second process.
    /// - Parameter symptom: what the user said the report is about, which leads
    ///   the first section. Two reports carrying the same numbers mean
    ///   different things depending on it — a display reading as reachable is
    ///   unremarkable under "a file did not make it across" and is the whole
    ///   report under "the display is not detected".
    static func collect(
        symptom: String,
        completion: @escaping (_ sections: [AppBackendClient.ReportSection], _ log: Data?) -> Void
    ) {
        // Read on main, where the cached answer lives, before going off it.
        let notifications = notificationsLabel()
        publishedState { published, userEnabled in
            DispatchQueue.global(qos: .userInitiated).async {
                let events = extensionEvents()
                var sections = [
                    application(symptom: symptom), system(notifications: notifications),
                    display(
                        published: published, userEnabled: userEnabled,
                        lastExtensionFailure: events.map { lastFailure(in: $0) }),
                ]

                // The agent's own log travels with every report, snapshot or
                // not. It is the only place a failed publication leaves a
                // trace, and the first report to arrive without it said the
                // display was reachable, the location was not published, and
                // nothing whatsoever about why — the one question worth asking.
                var attachment = Data()
                func attach(_ title: String, _ body: Data) {
                    guard !body.isEmpty else { return }
                    if !attachment.isEmpty { attachment.append(0x0A) }
                    attachment.append(Data("=== \(title) ===\n".utf8))
                    attachment.append(body)
                    if attachment.last != 0x0A { attachment.append(0x0A) }
                }
                if let agent = agentLog() {
                    attach("~/Library/Logs/BrailliantConnect.log", agent)
                }
                // What the extension itself saw fail. Its own logs never reach
                // `log show`, so this file in its container is the only
                // account of a copy that went wrong on the display's side.
                if let events {
                    attach("extension", events)
                }

                // The extension's snapshot, and no doctor at all — but only
                // while the location is published. Then the extension holds
                // the MTP session, the doctor could only fail, and running it
                // would cost seconds of waiting for an error that says nothing.
                //
                // Unpublished, the snapshot is a memory of some earlier
                // session, possibly of another display, while the doctor can
                // now reach the one plugged in. It runs, and the snapshot goes
                // along beside it, dated.
                let hardware = hardwareFromExtension()
                if published, let hardware {
                    sections.append(hardware)
                } else {
                    attach("brailliant doctor", Data(runDoctor().utf8))
                    if let hardware { sections.append(hardware) }
                }

                let log = attachment.isEmpty ? nil : attachment
                DispatchQueue.main.async { completion(sections, log) }
            }
        }
    }

    // MARK: - What the agent knows on its own

    private static func application(symptom: String) -> AppBackendClient.ReportSection {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return AppBackendClient.ReportSection(
            title: "Application",
            rows: [
                ("Symptôme", symptom),
                ("Version", AppBackendClient.appVersion),
                ("Build", build),
                ("Langue", L.isFrench ? "français" : "anglais"),
                ("Lancement au login", Installer.isRegistered ? "oui" : "non"),
            ])
    }

    /// Whether the end of a transfer can be announced at all — the first
    /// thing to know about a report that says a copy "failed".
    private static func notificationsLabel() -> String {
        switch TransferNotice.authorization {
        case .authorized?, .provisional?: return "autorisées"
        case .denied?: return "refusées"
        case .notDetermined?: return "jamais demandées"
        default: return "inconnu"
        }
    }

    private static func system(notifications: String) -> AppBackendClient.ReportSection {
        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return AppBackendClient.ReportSection(
            title: "Système",
            rows: [
                ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
                ("Architecture", architecture),
                ("VoiceOver actif", NSWorkspace.shared.isVoiceOverEnabled ? "oui" : "non"),
                ("Notifications", notifications),
            ])
    }

    /// The half a report from an untested model turns on: what the USB tree
    /// says, and whether the Finder side of it actually came up.
    /// - Parameter lastExtensionFailure: nil when the extension has left no
    ///   ledger at all, in which case the row is left out rather than
    ///   claiming there was nothing to report.
    private static func display(
        published: Bool, userEnabled: Bool?, lastExtensionFailure: String?
    ) -> AppBackendClient.ReportSection {
        // A location can be published and still serve nothing: macOS 13 waits
        // for the user to enable it in the Finder. The first report from such
        // a Mac said "published" and nothing else, which was true and useless.
        let enabled: String
        switch (published, userEnabled) {
        case (false, _): enabled = "—"
        case (true, .some(true)): enabled = "oui"
        case (true, .some(false)): enabled = "non — en attente du clic Enable"
        case (true, .none): enabled = "inconnu"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shortcuts = FinderLocation.existingShortcuts(home: home)
        let shortcut =
            shortcuts.first.map { url -> String in
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                // Abbreviated: the absolute path carries the user's account
                // name, which the report has no use for.
                return "~/\(url.lastPathComponent) → "
                    + (target.map { abbreviatingHome($0, home: home) } ?? "cible illisible")
            } ?? "aucun"

        var rows: [(label: String, value: String)] = [
            ("État USB", label(for: USBWatcher.availability())),
            ("Appareils HumanWare branchés", String(USBWatcher.pluggedDisplayCount())),
            ("Dont joignables en MTP", String(USBWatcher.connectedDisplayCount())),
            ("Emplacement publié", published ? "oui" : "non"),
            ("Activé dans le Finder", enabled),
            ("Raccourci", shortcut),
        ]
        if let lastExtensionFailure {
            rows.append(("Dernier échec de l'extension", lastExtensionFailure))
        }
        return AppBackendClient.ReportSection(title: "Plage et Finder", rows: rows)
    }

    /// Replaces the home folder at the head of a path with "~".
    private static func abbreviatingHome(_ path: String, home: URL) -> String {
        let prefix = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        guard path == prefix || path.hasPrefix(prefix + "/") else { return path }
        return "~" + path.dropFirst(prefix.count)
    }

    private static func label(for availability: USBWatcher.Availability) -> String {
        switch availability {
        case .ready: return "joignable (interface MTP présente)"
        case .asleep: return "en veille (aucune interface publiée)"
        case .brailleTerminal: return "MTP désactivé (interfaces HID seules)"
        case .absent: return "aucune plage branchée"
        }
    }

    // MARK: - What only the display knows

    /// Reads what the extension left behind at its last MTP session.
    ///
    /// This is the normal path, and the only one that works once the location
    /// is published: the extension holds the single MTP session for good, so
    /// anything the agent asked the device directly would be refused. The
    /// extension writes this as it connects; here we only read it.
    ///
    /// The date it was written travels with it. A snapshot from last week may
    /// well describe a different display than the one plugged in now, and a
    /// report that hid that would be worse than one without it.
    private static func hardwareFromExtension() -> AppBackendClient.ReportSection? {
        guard let url = snapshotURL,
            let data = try? Data(contentsOf: url),
            let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var rows: [(label: String, value: String)] = [
            ("Modèle", snapshot["model"] as? String ?? "?"),
            ("Numéro de série", snapshot["serial"] as? String ?? "?"),
            ("Relevé le", snapshot["written"] as? String ?? "?"),
        ]
        if let storages = snapshot["storages"] as? [[String: Any]] {
            for (rank, storage) in storages.enumerated() {
                let name = storage["name"] as? String ?? "?"
                // JSONSerialization hands these back as NSNumber, and a direct
                // cast to a fixed-width type is not guaranteed to take.
                let capacity = (storage["capacity"] as? NSNumber)?.int64Value ?? 0
                let free = (storage["free"] as? NSNumber)?.int64Value ?? 0
                rows.append(
                    (
                        "Stockage \(rank + 1)",
                        "\(name) — \(humanBytes(free)) libres sur \(humanBytes(capacity))"
                    ))
            }
        }
        return AppBackendClient.ReportSection(
            title: "Matériel (relevé par l'extension)", rows: rows)
    }

    /// Where the extension leaves it: inside its own container, which it may
    /// write to and we may read. Its bundle identifier is read from the
    /// embedded extension rather than spelled out here, so renaming it cannot
    /// leave this pointing at a path that no longer exists.
    private static var snapshotURL: URL? {
        extensionFolder?.appendingPathComponent("last-device.json")
    }

    /// The extension's failure ledger, beside the snapshot: one line per
    /// operation, `<ISO 8601 date>\t<operation>\t<outcome>\t<detail>`.
    private static var eventsURL: URL? {
        extensionFolder?.appendingPathComponent("events.log")
    }

    private static var extensionFolder: URL? {
        let appex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/FileProviderExtension.appex")
        guard let identifier = Bundle(url: appex)?.bundleIdentifier else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(identifier)/Data")
            .appendingPathComponent("Library/Application Support/BrailliantConnect")
    }

    /// The tail of the extension's ledger, or nil when it has written none.
    private static func extensionEvents() -> Data? {
        eventsURL.flatMap { tail(of: $0) }
    }

    /// The last line whose outcome is not `ok`, as date, operation and
    /// outcome — or "aucun" when every line kept says `ok`.
    ///
    /// The detail is left to the attached ledger: it can run long, and a row
    /// is read at a glance.
    private static func lastFailure(in events: Data) -> String {
        let lines = String(decoding: events, as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[2] != "ok" else { continue }
            return "\(fields[0]) — \(fields[1]) — \(fields[2])"
        }
        return "aucun"
    }

    /// The tail of the agent's own log, or nil when there is none to read.
    ///
    /// Every publication attempt leaves its verdict there — including "display
    /// connected but publishing failed: …", which is the single line that says
    /// why nothing appeared in the Finder. A report that left it out asked its
    /// reader to guess, and the first one to arrive did exactly that.
    ///
    /// Only the end is kept. The file has no rotation and the agent writes to
    /// it at every login for as long as the app is installed, while what a
    /// report is about happened in the last few minutes.
    private static func agentLog() -> Data? {
        tail(
            of: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/BrailliantConnect.log"))
    }

    /// The last `limit` bytes of a file, starting on a whole line, or nil
    /// when there is no file or nothing in it.
    private static func tail(of url: URL, limit: Int = 64 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = Int((try? handle.seekToEnd()) ?? 0)
        let cut = size > limit
        try? handle.seek(toOffset: UInt64(cut ? size - limit : 0))
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // Resume at a line break rather than mid-line, which also guarantees
        // the first bytes are not the tail of a multi-byte character.
        if cut, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        return data.isEmpty ? nil : data
    }

    /// Runs the `brailliant` shipped next to us and returns whatever it said.
    ///
    /// Never throws and never blocks for long: a report that cannot be sent
    /// because the diagnosis hung would be worse than one without it. The
    /// timeout is generous — libmtp waits on the device — but it exists.
    private static func runDoctor() -> String {
        let tool = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("brailliant")
        guard let tool, FileManager.default.isExecutableFile(atPath: tool.path) else {
            return "brailliant doctor: outil introuvable dans le bundle"
        }

        let process = Process()
        process.executableURL = tool
        process.arguments = ["doctor"]
        // libmtp mangles accented names unless the process locale is UTF-8.
        var environment = ProcessInfo.processInfo.environment
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        process.environment = environment

        // One pipe for both streams: doctor reports its failures on stderr, and
        // a report that kept only stdout would arrive empty in exactly the case
        // worth reading.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return "brailliant doctor: \(error.localizedDescription)"
        }

        // Read before waiting: a pipe whose buffer fills up blocks the child,
        // which then never exits and the wait never returns.
        let deadline = DispatchTime.now() + .seconds(30)
        var output = Data()
        let reader = DispatchQueue(label: "doctor.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return "brailliant doctor: pas de réponse en 30 secondes, diagnostic interrompu"
        }
        process.waitUntilExit()

        let text = String(data: output, encoding: .utf8) ?? ""
        let status = process.terminationStatus
        return status == 0
            ? text
            : text + "\n(brailliant doctor s'est terminé avec le code \(status))"
    }
}
