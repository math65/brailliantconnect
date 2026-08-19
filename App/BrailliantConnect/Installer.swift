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

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

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
            home.appendingPathComponent(
                "Library/Preferences/com.mathieumartin.BrailliantConnect.plist"),
            home.appendingPathComponent(
                "Library/Application Scripts/com.mathieumartin.BrailliantConnect"),
            home.appendingPathComponent(
                "Library/Application Scripts/com.mathieumartin.BrailliantConnect.FileProvider"),
            home.appendingPathComponent("Library/Caches/com.mathieumartin.BrailliantConnect"),
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

    /// Registers the agent so it starts again at every login.
    ///
    /// Called on first launch, which is what makes a double-click the whole
    /// installation procedure. Failing is not fatal: the app keeps watching the
    /// display for this session, it simply will not come back by itself.
    @discardableResult
    static func register() -> Bool {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/BrailliantConnect").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }

        try? FileManager.default.createDirectory(
            at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable, "--watch"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "ProcessType": "Background",
        ]
        guard
            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0),
            (try? data.write(to: agentPlist)) != nil
        else { return false }

        // "bootout" before "bootstrap": bootstrapping over an existing
        // registration fails, which would leave a stale copy in charge.
        _ = run("/bin/launchctl", ["bootout", jobTarget])
        return run("/bin/launchctl", ["bootstrap", domainTarget, agentPlist.path]).code == 0
    }

    /// Stops the agent from coming back at login, without touching anything else.
    ///
    /// Booting the job out would kill the very process running this code, so the
    /// registration is only removed from disk; the current session keeps going
    /// until the user quits or logs out.
    static func unregister() {
        try? FileManager.default.removeItem(at: agentPlist)
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
    ///   - completion: called on an unspecified queue once everything is done,
    ///     with whether the bundle itself was binned. Everything else is best
    ///     effort by design: a preference file that was never written is not a
    ///     failure, and neither is a domain that was not published.
    static func uninstall(removeApp: Bool, completion: @escaping (Bool) -> Void) {
        // The location goes first: a domain left behind would keep an entry in
        // the Finder pointing at an extension that no longer exists.
        unpublish { _ in
            // `unpublish` has already removed the shortcut, and only if it was
            // really ours — never a folder the user happens to have named the
            // same way.
            removeDomainFolder()

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
            _ = run("/bin/launchctl", ["bootout", jobTarget])
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

    /// Deregisters every copy of the extension the system knows about.
    ///
    /// `pluginkit -r` takes a path and removes that one path, which is rarely
    /// enough. An app that was moved, or a build left behind in DerivedData,
    /// leaves the system serving an extension from somewhere nobody remembers —
    /// found here by listing the registrations first and removing each by its
    /// own path, rather than assuming there is only ours.
    private static func deregisterExtension() {
        let identifier = "com.mathieumartin.BrailliantConnect.FileProvider"
        let listing = run("/usr/bin/pluginkit", ["-m", "-v", "-i", identifier]).output
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
