import BrailliantKit
import Foundation

/// Driving the Finder location from the command line.
///
/// The real work is done by an agent: a discreet process that watches the USB
/// port and publishes or withdraws the location depending on whether the
/// display is plugged in. Only the application bundle hosting the extension is
/// allowed to declare a File Provider domain, hence this detour.
enum Finder {

    private static let label = "com.mathieumartin.BrailliantConnect.agent"

    /// Where to look for the host application, from most likely to least.
    private static let locations = [
        "/Applications/BrailliantConnect.app",
        NSHomeDirectory() + "/Applications/BrailliantConnect.app",
    ]

    private static var agentFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    private static var logFile: String {
        NSHomeDirectory() + "/Library/Logs/BrailliantConnect.log"
    }

    private static func hostExecutable() throws -> String {
        for base in locations {
            let binary = base + "/Contents/MacOS/BrailliantConnect"
            if FileManager.default.isExecutableFile(atPath: binary) { return binary }
        }
        throw MTPError.hostApplicationNotFound(searched: locations)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text =
            String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (text, process.terminationStatus)
    }

    // MARK: - Installing the agent

    /// Installs the agent and starts it.
    ///
    /// Once it is in place it comes back at every login: no more commands to
    /// type, the display appears and disappears on its own.
    static func enable() throws {
        let binary = try hostExecutable()
        let directory = agentFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "--watch"],
            // Start at login, and come back up if it ever stops.
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logFile,
            "StandardErrorPath": logFile,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml, options: 0)
        try data.write(to: agentFile)

        // Reload: "bootout" followed by "bootstrap" replaces any previous
        // version, where a plain load would fail.
        let target = "gui/\(getuid())"
        run("/bin/launchctl", ["bootout", "\(target)/\(label)"])
        let (output, code) = run(
            "/bin/launchctl",
            ["bootstrap", target, agentFile.path])
        guard code == 0 else {
            throw MTPError.agentFailedToStart(detail: output.isEmpty ? "code \(code)" : output)
        }
        say(L.t("Watching enabled."))
        say(
            L.t(
                "The display appears in \"~/Brailliant\" as soon as it is connected, "
                    + "and disappears when it is unplugged."))
        say(L.t("The agent will restart on its own at every login."))
    }

    /// Stops the agent, removes it from startup and unpublishes the location.
    static func disable() throws {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: agentFile)

        // With the agent gone the location would stay published: withdraw it.
        if let binary = try? hostExecutable() {
            let (output, _) = run(binary, ["--unpublish"])
            if !output.isEmpty { say(output) }
        }
        say(L.t("Watching disabled. The agent will no longer restart."))
    }

    // MARK: - Removing everything

    /// Removes BrailliantConnect entirely.
    ///
    /// The removal itself lives in the application: it is the only side that
    /// knows every path it wrote, and duplicating that list here is how the two
    /// would end up disagreeing about what "everything" means.
    static func uninstall() throws {
        let binary = try hostExecutable()
        let (output, code) = run(binary, ["--uninstall"])
        if !output.isEmpty { say(output) }
        guard code == 0 else {
            throw MTPError.agentFailedToStart(detail: output.isEmpty ? "code \(code)" : output)
        }
        // A copy of this tool placed on the PATH by hand is outside the app and
        // outside its bookkeeping, so it can only be pointed out.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if !executable.path.contains("BrailliantConnect.app") {
            say(L.t("This copy of \"brailliant\" is not inside the app; remove it by hand:"))
            say("  " + executable.path)
        }
    }

    static func status() throws {
        let binary = try hostExecutable()
        let (output, _) = run(binary, ["--status"])
        let installed = FileManager.default.fileExists(atPath: agentFile.path)
        let (listing, _) = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        let active = !listing.isEmpty && !listing.contains("Could not find")

        say(L.t("Location: %@", output.isEmpty ? L.t("state unknown") : output))
        say(
            L.t(
                "Watching: %@",
                installed
                    ? L.t(active ? "active, restarted at every login" : "installed but stopped")
                    : L.t("not installed")))
        if !installed {
            say(L.t("To enable it: brailliant finder on"))
        }
    }
}
