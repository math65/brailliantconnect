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
/// bundled `brailliant doctor` is the fallback for the case where there is no
/// such snapshot — no location published, extension never run — and there its
/// failure is attached as-is rather than dropped, since the error it prints is
/// itself the answer to a good half of the reports that will arrive.
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
        isPublished { published in
            DispatchQueue.global(qos: .userInitiated).async {
                var sections = [
                    application(symptom: symptom), system(), display(published: published),
                ]

                // The extension's snapshot first, and when it is there, no
                // doctor at all: it would only fail. Running it anyway would
                // cost the user seconds of waiting to attach an error that
                // says nothing this report does not already say.
                var log: Data?
                if let hardware = hardwareFromExtension() {
                    sections.append(hardware)
                } else {
                    log = Data(runDoctor().utf8)
                }

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

    private static func system() -> AppBackendClient.ReportSection {
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
            ])
    }

    /// The half a report from an untested model turns on: what the USB tree
    /// says, and whether the Finder side of it actually came up.
    private static func display(published: Bool) -> AppBackendClient.ReportSection {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shortcuts = FinderLocation.existingShortcuts(home: home)
        let shortcut =
            shortcuts.first.map { url -> String in
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                return "~/\(url.lastPathComponent) → \(target ?? "cible illisible")"
            } ?? "aucun"

        return AppBackendClient.ReportSection(
            title: "Plage et Finder",
            rows: [
                ("État USB", label(for: USBWatcher.availability())),
                ("Appareils HumanWare branchés", String(USBWatcher.pluggedDisplayCount())),
                ("Dont joignables en MTP", String(USBWatcher.connectedDisplayCount())),
                ("Emplacement publié", published ? "oui" : "non"),
                ("Raccourci", shortcut),
            ])
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
        let appex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/FileProviderExtension.appex")
        guard let identifier = Bundle(url: appex)?.bundleIdentifier else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(identifier)/Data")
            .appendingPathComponent("Library/Application Support/BrailliantConnect")
            .appendingPathComponent("last-device.json")
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
