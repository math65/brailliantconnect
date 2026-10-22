import Foundation

/// Installing and uninstalling the background agent.
///
/// The agent has to survive a logout, which means a LaunchAgent — but nobody
/// should have to know that. Dropping the app into Applications and opening it
/// once is the whole procedure; everything below happens on its own.
///
/// Uninstalling matters just as much. A tool that scatters files across
/// ~/Library and leaves an agent running behind it is a tool people cannot get
/// rid of. Everything this app creates is listed in `ownedPaths`, and
/// `uninstall` removes all of it.
enum Installer {

    static let agentLabel = "com.mathieumartin.BrailliantConnect.agent"

    /// Bundle identifier of the File Provider extension we ship.
    static let extensionIdentifier = "com.mathieumartin.BrailliantConnect.FileProvider"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The app's own identifier, which names its preferences domain. Spelled
    /// out as a fallback only: the CLI reaches `--uninstall` through the app's
    /// executable, so the bundle is always ours.
    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.mathieumartin.BrailliantConnect"
    }

    static var agentPlist: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private static var logFile: URL {
        home.appendingPathComponent("Library/Logs/BrailliantConnect.log")
    }

    /// Everything this app ever writes outside its own bundle.
    ///
    /// Kept as a single list so uninstalling cannot drift out of step with
    /// installing: whatever is added here is also cleaned up.
    private static var ownedPaths: [URL] {
        [
            agentPlist,
            logFile,
            home.appendingPathComponent("Library/Preferences/\(bundleIdentifier).plist"),
            home.appendingPathComponent(
                "Library/Application Scripts/com.mathieumartin.BrailliantConnect"),
            home.appendingPathComponent(
                "Library/Application Scripts/com.mathieumartin.BrailliantConnect.FileProvider"),
            // Also where Sparkle keeps its downloads and installations
            // (`org.sparkle-project.Sparkle` inside it) and the URL cache of
            // its feed requests: one folder covers the three.
            home.appendingPathComponent("Library/Caches/com.mathieumartin.BrailliantConnect"),
            // Cookies and HSTS state of Sparkle's URLSession, which uses the
            // default configuration — the backend client's is ephemeral and
            // writes none. Both names, as with the group containers: the
            // folder on recent systems, the single file on older ones.
            home.appendingPathComponent("Library/HTTPStorages/com.mathieumartin.BrailliantConnect"),
            home.appendingPathComponent(
                "Library/HTTPStorages/com.mathieumartin.BrailliantConnect.binarycookies"),
            home.appendingPathComponent("Library/Containers/com.mathieumartin.BrailliantConnect"),
            home.appendingPathComponent(
                "Library/Containers/com.mathieumartin.BrailliantConnect.FileProvider"),
            // Written by the web view in the welcome window — 200 KB of website
            // data for a page that never touches the network.
            home.appendingPathComponent("Library/WebKit/com.mathieumartin.BrailliantConnect"),
            // The app group, under both the names the system files it by.
            home.appendingPathComponent(
                "Library/Group Containers/633EG76YX5.group.com.mathieumartin.brailliantconnect"),
            home.appendingPathComponent(
                "Library/Group Containers/group.com.mathieumartin.brailliantconnect"),
        ]
    }

    // MARK: - Installing

    /// Whether the agent is registered to come back at login.
    static var isRegistered: Bool {
        FileManager.default.fileExists(atPath: agentPlist.path)
    }

    /// Whether the app runs from `/Applications` or `~/Applications`.
    ///
    /// Anywhere else is refused before registering, because the path written
    /// into the launchd job would not last. The trap is App Translocation: an
    /// app still in quarantine and opened where it was unzipped runs from a
    /// random copy under `/private/var/folders/…/AppTranslocation/`. It works,
    /// the agent starts, and after the next restart the job points at a folder
    /// that no longer exists — no menu bar item, no message. Measured on
    /// macOS 27 with the published 1.1.0, 29 Sep 2026.
    static var isInApplicationsFolder: Bool {
        let parent = Bundle.main.bundleURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().path
        let allowed = [
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications").resolvingSymlinksInPath().path,
        ]
        return allowed.contains(parent)
    }

    /// Why registering failed, in words a person can act on.
    ///
    /// The reason used to be dropped, and the message shown in its place told
    /// people to check the Applications folder — which had already been checked
    /// by then. Someone on macOS 27 could not start 1.1.0, 1.1.1 or 1.2.0,
    /// with no log to read, until running the app from Terminal showed which
    /// step failed (16 Oct 2026).
    enum RegistrationFailure: Error {
        case executableMissing(path: String)
        case agentFolderNotOwned(path: String, owner: String, detail: String?)
        case plistNotWritten(path: String, reason: String)
        case bootstrapRefused(code: Int32, output: String)

        var explanation: String {
            switch self {
            case .executableMissing(let path):
                return L.t("The app's executable was not found at %@.", path)
            case .agentFolderNotOwned(let path, let owner, let detail):
                // The commands are spelled out with the real path and names:
                // whoever reads this declined a password prompt, or saw it
                // fail, and the Terminal is what is left.
                let user = NSUserName()
                let group =
                    getgrgid(getgid()).flatMap { String(cString: $0.pointee.gr_name) }
                    ?? "staff"
                return L.t(
                    "The LaunchAgents folder in your Library belongs to “%@”, not to "
                        + "you, so nothing can register itself to start at login. "
                        + "Another app's installer probably created it that way.", owner)
                    + (detail.map { "\n\n" + $0 } ?? "") + "\n\n"
                    + L.t(
                        "Repairing it takes an administrator's password. To repair it "
                            + "in Terminal instead, type these two commands, then open "
                            + "BrailliantConnect again:")
                    + "\n\nsudo chown \(user):\(group) '\(path)'\nchmod u+rwx '\(path)'"
            case .plistNotWritten(let path, let reason):
                return L.t(
                    "The file that starts BrailliantConnect at login could not be "
                        + "written (%@): %@", path, reason)
            case .bootstrapRefused(let code, let output):
                // Error 5 is what launchd answers for a job it holds as
                // disabled, and for much else: the hint is a condition, not a
                // diagnosis. "App Background Activity" is the section's title
                // in System Settings on macOS 27, and searchable by that name
                // whatever the pane around it is called.
                return L.t("macOS refused to start the background agent.") + "\n"
                    + "launchctl: \(code)"
                    + (output.isEmpty ? "" : " — " + output) + "\n\n"
                    + L.t(
                        "If BrailliantConnect is turned off in System Settings "
                            + "(search for “App Background Activity”), turn it on, "
                            + "then open the app again.")
            }
        }
    }

    /// Registers the agent so it starts again at every login.
    ///
    /// Called on first launch, which is what makes a double-click the whole
    /// installation procedure. Failing is not fatal: the app keeps watching the
    /// display for this session, it simply will not come back by itself.
    ///
    /// - Parameter loadNow: whether to hand the job to launchd straight away.
    ///   The resident agent has to pass `false`, and this is the trap: loading
    ///   means booting the job out first, and the process `bootout` terminates
    ///   is the one running this line. The `bootstrap` below would never
    ///   happen, and turning "Open at Login" back on would take the menu bar
    ///   item away until the next login. Writing the registration is all the
    ///   agent needs there anyway, since it is already running.
    static func register(loadNow: Bool = true) throws {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/BrailliantConnect").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw RegistrationFailure.executableMissing(path: executable)
        }

        try prepareAgentFolder()

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable, "--watch"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "ProcessType": "Background",
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPlist)
        } catch {
            throw RegistrationFailure.plistNotWritten(
                path: agentPlist.path, reason: error.localizedDescription)
        }

        guard loadNow else { return }

        // A job launchd holds as disabled is refused by `bootstrap`, with an
        // error that does not say so. Opening the app is asking for it to
        // run, so the override is lifted — and said, since it was someone's
        // setting.
        if isDisabled {
            let enabled = run("/bin/launchctl", ["enable", jobTarget]).code == 0
            appendToLog(
                enabled
                    ? L.t("the background agent was disabled in launchd — enabled again")
                    : L.t("the background agent is disabled in launchd and could not be enabled"))
        }

        // "bootout" before "bootstrap": bootstrapping over an existing
        // registration fails, which would leave a stale copy in charge.
        _ = run("/bin/launchctl", ["bootout", jobTarget])
        let bootstrap = run("/bin/launchctl", ["bootstrap", domainTarget, agentPlist.path])
        guard bootstrap.code == 0 else {
            // The first line only: the second is launchctl's advice to
            // re-run as root, which would send whoever reads the alert the
            // wrong way.
            let firstLine = bootstrap.output.split(separator: "\n").first.map(String.init) ?? ""
            throw RegistrationFailure.bootstrapRefused(
                code: bootstrap.code,
                output: firstLine.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Makes sure the registration can be written, giving `~/Library/LaunchAgents`
    /// back to the user when another installer left it belonging to root.
    ///
    /// HumanWare's own Mac transfer package (0.1.3, the one on its support
    /// pages) creates that folder with `mkdir -p` from a postinstall script
    /// that runs as root. On a Mac where it did not exist yet — any new one —
    /// root then owns it, and no app can register to start at login any more.
    /// Found on a user's Mac on 21 Oct 2026, where two commands in Terminal
    /// fixed it; this runs the same two with an administrator's password.
    ///
    /// Only the folder changes hands, never what is inside: the other
    /// installer's file stays exactly as it was. And only a real folder: a
    /// link in its place is somebody's deliberate arrangement, and the write
    /// below reports it if it fails.
    private static func prepareAgentFolder() throws {
        let folder = agentPlist.deletingLastPathComponent()
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: folder.path) else {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            return
        }
        guard !manager.isWritableFile(atPath: folder.path),
            attributes[.type] as? FileAttributeType == .typeDirectory,
            let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        else { return }

        if ownerID == getuid() {
            // Ours, with the write bit missing: the mode alone, no password.
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
            try? manager.setAttributes(
                [.posixPermissions: mode | 0o700], ofItemAtPath: folder.path)
            return
        }

        let owner =
            getpwuid(ownerID).flatMap { String(cString: $0.pointee.pw_name) }
            ?? String(ownerID)
        let detail: String?
        switch takeOwnership(of: folder) {
        case .done where manager.isWritableFile(atPath: folder.path):
            appendToLog(
                L.t(
                    "the LaunchAgents folder belonged to “%@” — given back to “%@” "
                        + "with an administrator's password", owner, NSUserName()))
            return
        case .done:
            detail = nil
        case .declined:
            appendToLog(L.t("the administrator's password was not given"))
            detail = nil
        case .failed(let reason):
            detail = reason
        }
        throw RegistrationFailure.agentFolderNotOwned(
            path: folder.path, owner: owner, detail: detail)
    }

    private enum OwnershipRepair {
        case done
        case declined
        case failed(String)
    }

    /// Gives a folder back to the current user, after the system has asked for
    /// an administrator's password.
    ///
    /// `do shell script … with administrator privileges` rather than anything
    /// lower: the password dialog is the system's own, which VoiceOver reads,
    /// and it names this app as the one asking. The privileged part is two
    /// commands and nothing else, the path passed through `quoted form of`.
    private static func takeOwnership(of folder: URL) -> OwnershipRepair {
        func literal(_ text: String) -> String {
            "\""
                + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let path = literal(folder.path)
        let prompt = L.t(
            "BrailliantConnect needs to give the LaunchAgents folder in your Library "
                + "back to your account, so that it can start at login. Another "
                + "installer left it belonging to the system.")
        let source =
            "do shell script \"/usr/sbin/chown \(getuid()):\(getgid()) \" & quoted form of "
            + path + " & \" && /bin/chmod u+rwx \" & quoted form of " + path
            + " with prompt " + literal(prompt) + " with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            return .failed("NSAppleScript")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .done }
        // -128 is "User canceled", whatever the language of the dialog.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .declined }
        return .failed(
            (error[NSAppleScript.errorMessage] as? String)
                ?? "AppleScript \(error[NSAppleScript.errorNumber] ?? "?")")
    }

    /// Whether launchd holds an override that keeps the agent from loading.
    ///
    /// `print-disabled` lists every label with an override, one per line, as
    /// `"label" => disabled` (older systems wrote `=> true`).
    private static var isDisabled: Bool {
        run("/bin/launchctl", ["print-disabled", domainTarget]).output
            .split(separator: "\n")
            .contains { line in
                let sides = line.components(separatedBy: "=>")
                guard sides.count == 2 else { return false }
                let label = sides[0].trimmingCharacters(
                    in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
                let state = sides[1].trimmingCharacters(in: .whitespaces)
                return label == agentLabel && (state == "disabled" || state == "true")
            }
    }

    /// Adds a line to the agent's log from a process launchd did not start.
    ///
    /// The agent's own lines reach the file through launchd's redirection of
    /// its standard output. A launch that fails before there is an agent has
    /// no such redirection, and that is precisely the case where the log is
    /// the only thing a report can carry.
    static func appendToLog(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// Stops the agent from coming back at login, without touching anything else.
    ///
    /// Booting the job out would kill the very process running this code, so the
    /// registration is only removed from disk; the current session keeps going
    /// until the user quits or logs out.
    static func unregister() {
        try? FileManager.default.removeItem(at: agentPlist)
    }

    /// Stops the resident agent for this session.
    ///
    /// Terminating the process is not the same thing: the job is registered
    /// with `KeepAlive`, so a copy that exits on its own is brought back ten
    /// seconds later — long enough for whoever chose "Quit" to have believed
    /// it. Booting the job out is what makes quitting mean anything.
    ///
    /// The plist is deliberately left in place: whether the agent returns at
    /// the next login stays the business of "Open at Login", and quitting is
    /// not a way of answering that question.
    ///
    /// This terminates the calling process when launchd is the one that started
    /// it, so nothing queued after it is guaranteed to run. Started by hand
    /// there is no job to boot out, the command fails harmlessly, and the
    /// caller carries on.
    static func stopAgent() {
        _ = run("/bin/launchctl", ["bootout", jobTarget])
    }

    // MARK: - Uninstalling

    /// Removes every trace: published location, shortcut, registration,
    /// preferences, containers, logs — then moves the app to the Trash.
    ///
    /// The order is not arbitrary. Booting the job out terminates *this*
    /// process, so it comes last, once there is nothing left to do; and
    /// deregistering the extension needs the bundle to still be where it was,
    /// so it comes before the app is binned.
    ///
    /// - Parameters:
    ///   - removeApp: whether to move the bundle to the Trash as well.
    ///   - stopAgentWhenDone: whether to boot the agent out before calling
    ///     back. The command line wants it: it runs in a process of its own,
    ///     and the resident agent is the one being stopped. The menu must pass
    ///     `false` and call `stopAgent()` itself once it is done: there the
    ///     resident agent *is* the caller, `bootout` kills it on the spot, and
    ///     `completion` — with the alert saying the bundle could not be binned
    ///     — would never run.
    ///   - completion: called on an unspecified queue once everything is done,
    ///     with whether the bundle itself was binned. Everything else is best
    ///     effort by design: a preference file that was never written is not a
    ///     failure, and neither is a domain that was not published.
    static func uninstall(
        removeApp: Bool, stopAgentWhenDone: Bool = true, completion: @escaping (Bool) -> Void
    ) {
        // The location goes first: a domain left behind would keep an entry in
        // the Finder pointing at an extension that no longer exists.
        unpublish { _ in
            // `unpublish` has already removed the shortcut, and only if it was
            // really ours — never a folder the user happens to have named the
            // same way.
            removeDomainFolder()

            // Before the file goes: `cfprefsd` keeps the domain in memory and
            // writes it back whenever it likes, so a plist deleted from under
            // it can reappear — the install identifier and "welcome shown"
            // with it, which a reinstall would then inherit.
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)

            for path in ownedPaths {
                remove(path)
            }

            // Before the bundle moves: deregistering it once it is in the Trash
            // would leave the system serving an extension from a path that is
            // no longer there.
            deregisterExtension()

            // The Trash rather than a deletion: it needs no privileges, and it
            // leaves a way back for anyone who changes their mind. `trashItem`
            // rather than `NSWorkspace.recycle` because this also runs from the
            // command line, where there is no run loop for an asynchronous call
            // to come back to.
            var binned = false
            if removeApp {
                binned =
                    (try? FileManager.default.trashItem(
                        at: Bundle.main.bundleURL, resultingItemURL: nil)) != nil
            }

            // Last, because it terminates us. Launched by hand rather than by
            // launchd there is no job to boot out, the command fails
            // harmlessly, and `completion` runs as normal.
            if stopAgentWhenDone { stopAgent() }
            completion(binned)
        }
    }

    /// Removes a path, falling back to the Trash when deleting is refused.
    ///
    /// The container folders answer "Operation not permitted" to `removeItem`,
    /// even as root — but the Finder moves them to the Trash without
    /// complaint, and `trashItem` goes through the same privileged path. Being
    /// told this was impossible was wrong; it only needed asking differently.
    private static func remove(_ path: URL) {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        if (try? FileManager.default.removeItem(at: path)) != nil { return }
        _ = try? FileManager.default.trashItem(at: path, resultingItemURL: nil)
    }

    /// Tells the system about the extension inside our own bundle.
    ///
    /// `NSFileProviderManager.add` answers `providerNotFound` — the system
    /// renders it as "The application cannot be used right now" — when it holds
    /// no record of the extension. Nothing in that is about a braille display
    /// or the Finder: the plug-in was simply never registered, and the location
    /// has nobody to be handed to.
    ///
    /// Measured on a user's machine on 8 Sep 2026: display reachable over MTP,
    /// extension never run, no snapshot, and every publication since the
    /// install refused with that one error. `pluginkit -a` registers it and
    /// `-e use` marks it enabled — the pair the `/extension` loop has always
    /// run by hand.
    ///
    /// The agent is not sandboxed, so it can run them. The alternative was a
    /// Terminal command handed to somebody who installed an app precisely so as
    /// not to open one.
    @discardableResult
    static func registerExtension() -> Bool {
        let appex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/FileProviderExtension.appex")
        guard FileManager.default.fileExists(atPath: appex.path) else { return false }
        guard run("/usr/bin/pluginkit", ["-a", appex.path]).code == 0 else { return false }
        // Registered and disabled is a state the system can be left in, and it
        // publishes exactly as much as no registration at all.
        _ = run("/usr/bin/pluginkit", ["-e", "use", "-i", extensionIdentifier])
        return true
    }

    /// Deregisters every copy of the extension the system knows about.
    ///
    /// `pluginkit -r` takes a path and removes that one path, which is rarely
    /// enough. An app that was moved, or a build left behind in DerivedData,
    /// leaves the system serving an extension from somewhere nobody remembers —
    /// found here by listing the registrations first and removing each by its
    /// own path, rather than assuming there is only ours.
    private static func deregisterExtension() {
        let listing = run("/usr/bin/pluginkit", ["-m", "-v", "-i", extensionIdentifier]).output
        var paths = listing.split(separator: "\n").compactMap { line -> String? in
            // Tab-separated, the path last; the trailing "(1 plug-in)" line has
            // no tab and no leading slash, and drops out on its own.
            guard let path = line.split(separator: "\t").last else { return nil }
            let trimmed = String(path).trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("/") ? trimmed : nil
        }
        // Nothing listed still deserves an attempt on our own bundle: an
        // enumeration that comes back empty is not proof of an empty registry.
        let own = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/FileProviderExtension.appex").path
        if !paths.contains(own) { paths.append(own) }

        for path in paths {
            _ = run("/usr/bin/pluginkit", ["-r", path])
        }
    }

    /// Removes the folder the system created for our domain, if it survived the
    /// domain itself.
    ///
    /// Guarded by the prefix: this path is built from a constant, but it sits in
    /// a folder full of other services' data, and a stray deletion there would
    /// take someone's cloud storage with it.
    private static func removeDomainFolder() {
        let folder = FinderLocation.domainLocation(home: home)
        guard FinderLocation.isOurShortcut(pointingAt: folder.path) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Helpers

    private static var domainTarget: String { "gui/\(getuid())" }
    private static var jobTarget: String { "\(domainTarget)/\(agentLabel)" }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> (output: String, code: Int32)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
