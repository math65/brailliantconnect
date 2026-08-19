import AppKit
import FileProvider
import Foundation

// BrailliantConnect agent — headless.
//
// Launched without arguments, it stays in the background and follows the state
// of the display: connected, the location shows up in the Finder; disconnected,
// it goes away along with its shortcut. The user has nothing to do.
//
// Two roles, deliberately kept apart:
//
//   (no argument)  what a double-click runs. It registers the agent with
//                  launchd and exits at once.
//   --watch        what launchd then runs, and keeps running: the resident
//                  process that watches USB and holds the menu bar item.
//
// Splitting them is what keeps a single copy alive. Were the double-clicked
// process to stay resident, the one launchd starts would find it there and
// exit — and KeepAlive would restart it, forever.
//
// It also accepts one-off commands, used by `brailliant`:
//   --publish     publishes the location
//   --unpublish   removes it
//   --status      reports whether it is published
//   --uninstall   removes every trace of the app

let domainIdentifier = NSFileProviderDomainIdentifier(FinderLocation.domainIdentifier)
let displayName = FinderLocation.displayName

var domainLocation: URL {
    FinderLocation.domainLocation(home: FileManager.default.homeDirectoryForCurrentUser)
}

/// Shortcut visible directly in the home folder.
///
/// Without it, access would depend on the Finder sidebar — which can be
/// hidden — or on a path under ~/Library, a folder hidden by default.
var shortcut: URL {
    FinderLocation.shortcut(home: FileManager.default.homeDirectoryForCurrentUser)
}

@discardableResult
func createShortcut() -> Bool {
    let fm = FileManager.default
    for _ in 0..<20 {
        if fm.fileExists(atPath: domainLocation.path) { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    guard fm.fileExists(atPath: domainLocation.path) else { return false }

    // Never overwrite what is already there unless it is our own link. Somebody
    // who owns a braille display may well keep a folder called "Brailliant" in
    // their home directory, and removing it here would delete it outright —
    // recursively, with no trip through the Trash. The location stays reachable
    // from the Finder sidebar; the shortcut is a convenience, not worth data.
    let existing = URL(fileURLWithPath: shortcut.path)
    if let target = try? fm.destinationOfSymbolicLink(atPath: existing.path) {
        guard FinderLocation.isOurShortcut(pointingAt: target) else {
            log(L.t("~/%@ is a link to something else — shortcut not created", displayName))
            return false
        }
        try? fm.removeItem(at: shortcut)
    } else if fm.fileExists(atPath: shortcut.path) {
        log(L.t("~/%@ already exists — shortcut not created", displayName))
        return false
    }
    return (try? fm.createSymbolicLink(at: shortcut, withDestinationURL: domainLocation)) != nil
}

func removeShortcut() {
    // Only remove it if it really is our link: never a real folder the user
    // may have created under the same name.
    let fm = FileManager.default
    guard let target = try? fm.destinationOfSymbolicLink(atPath: shortcut.path),
        FinderLocation.isOurShortcut(pointingAt: target)
    else { return }
    try? fm.removeItem(at: shortcut)
}

func log(_ message: String) {
    // Standard output goes to the LaunchAgent log: that is where we read back
    // what happened while the agent was running without a terminal.
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardOutput.write(Data("[\(timestamp)] \(message)\n".utf8))
}

// MARK: - Domain actions

/// Reads how much is still on its way to the display, for the menu bar.
let transfers = TransferMonitor()

/// Whether the home-folder shortcut is in place. It is not, when something else
/// already occupies that name — and the log must not then claim otherwise.
var shortcutExists = false

func publish(_ completion: @escaping (Error?) -> Void) {
    let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
    NSFileProviderManager.add(domain) { error in
        if error == nil {
            shortcutExists = createShortcut()
            // A domain removed and re-added is a new one, so its progress has
            // to be picked up again rather than kept from last time.
            transfers.follow(domain: domainIdentifier)
        }
        completion(error)
    }
}

func unpublish(_ completion: @escaping (Error?) -> Void) {
    let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
    NSFileProviderManager.remove(domain) { error in
        // The shortcut goes with the domain: leaving it would point nowhere.
        removeShortcut()
        transfers.stop()
        completion(error)
    }
}

func isPublished(_ completion: @escaping (Bool) -> Void) {
    NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
        completion(domains.contains { $0.identifier == domainIdentifier })
    }
}

func finish(_ message: String, code: Int32 = 0) -> Never {
    let stream = code == 0 ? FileHandle.standardOutput : FileHandle.standardError
    stream.write(Data((message + "\n").utf8))
    exit(code)
}

/// Brings the published state in line with the physical presence of the display.
/// Last state acted upon, so an unchanged one is not logged again.
///
/// A single unplug fires several IOKit notifications — one per interface, plus
/// the device itself — and each one triggers a reconciliation. Acting is
/// idempotent, but writing the same line three times makes the log unreadable
/// exactly when it is being consulted.
var lastKnownAvailability: Bool?

func syncWithHardware() {
    // "Available" means reachable over MTP, not merely plugged in: a display
    // that is asleep, or in braille terminal mode, stays enumerated and answers
    // nothing.
    let state = USBWatcher.availability()
    let available = state == .ready
    let connected = available
    isPublished { published in
        let action = FinderLocation.action(
            displayConnected: connected, locationPublished: published)
        // Report a transition once, not once per notification.
        let worthLogging = lastKnownAvailability != available
        lastKnownAvailability = available

        switch action {
        case .publish:
            publish { error in
                guard worthLogging || error != nil else { return }
                log(
                    error == nil
                        ? (shortcutExists
                            ? L.t("display connected — location published in ~/%@", displayName)
                            : L.t(
                                "display connected — location published, in the Finder sidebar"))
                        : L.t(
                            "display connected but publishing failed: %@",
                            error!.localizedDescription)
                )
            }
        case .unpublish:
            unpublish { error in
                guard worthLogging || error != nil else { return }
                let reason: String
                switch state {
                case .asleep:
                    reason = L.t("display asleep — location removed until it wakes up")
                case .brailleTerminal:
                    reason = L.t(
                        "display in braille terminal mode — location removed until it "
                            + "is switched to file transfer")
                default:
                    reason = L.t("display disconnected — location removed")
                }
                log(
                    error == nil
                        ? reason
                        : L.t(
                            "display disconnected but removal failed: %@",
                            error!.localizedDescription)
                )
            }
        case .nothing:
            // Already in the right state — but if that state is "published",
            // this may be the first pass after a restart, and the transfer
            // progress still has to be picked up.
            if published { transfers.follow(domain: domainIdentifier) }
        }
    }
}

// MARK: - Entry point

/// Takes an exclusive lock held for as long as the process lives, so that only
/// one resident agent can exist.
///
/// `NSRunningApplication` looked like the obvious way, and was wrong: it counts
/// the short-lived process that a double-click runs to install the agent. The
/// agent launchd starts a moment later would then find itself "already
/// running", exit, and come back only after KeepAlive's ten-second delay —
/// exactly when the user is watching to see whether anything happened.
///
/// The kernel releases the lock when the process dies, however it dies, which a
/// pid file would not.
enum SingleInstance {
    private static var descriptor: Int32 = -1

    static var lockFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.mathieumartin.BrailliantConnect")
    }

    static func claim() -> Bool {
        try? FileManager.default.createDirectory(
            at: lockFolder, withIntermediateDirectories: true)
        // O_NOFOLLOW: the path is predictable, so a symlink planted there must
        // not redirect this open elsewhere. Nothing is ever written to the file
        // — only locked — but following a link is worth refusing regardless.
        descriptor = open(
            lockFolder.appendingPathComponent("agent.lock").path,
            O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)
        // Unable to take a lock at all: better a possible duplicate than no
        // agent, since a duplicate is visible and an absence is not.
        guard descriptor >= 0 else { return true }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

/// Retained for the lifetime of the process: `NSMenu` holds its delegate
/// weakly, and a released controller would leave an icon with an empty menu.
var menuBar: MenuBarController?

let arguments = Array(CommandLine.arguments.dropFirst())
let waiter = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
var finalMessage = ""

switch arguments.first ?? "--install" {

case "--publish":
    publish { error in
        finalMessage =
            error == nil
            ? L.t("Location published. Reachable in \"~/Brailliant\".")
            : L.t("Publishing failed: %@", error!.localizedDescription)
        exitCode = error == nil ? 0 : 1
        waiter.signal()
    }
    if waiter.wait(timeout: .now() + 60) == .timedOut {
        finish(L.t("The system did not answer within the allotted time."), code: 1)
    }
    finish(finalMessage, code: exitCode)

case "--unpublish":
    unpublish { error in
        finalMessage =
            error == nil
            ? L.t("Location removed from the Finder.")
            : L.t("Removal failed: %@", error!.localizedDescription)
        exitCode = error == nil ? 0 : 1
        waiter.signal()
    }
    if waiter.wait(timeout: .now() + 60) == .timedOut {
        finish(L.t("The system did not answer within the allotted time."), code: 1)
    }
    finish(finalMessage, code: exitCode)

case "--status":
    let connected = USBWatcher.connectedDisplayCount() > 0
    isPublished { published in
        finalMessage =
            (published ? L.t("published") + " — ~/\(displayName)" : L.t("not published"))
            + " · " + L.t(connected ? "display connected" : "no display connected")
        exitCode = published ? 0 : 2
        waiter.signal()
    }
    if waiter.wait(timeout: .now() + 30) == .timedOut {
        finish(L.t("The system did not answer."), code: 1)
    }
    finish(finalMessage, code: exitCode)

case "--uninstall":
    // The headless path to the same thing the menu bar offers. There is one
    // implementation of the removal, so the two cannot fall out of step.
    Installer.uninstall(removeApp: true) { binned in
        finalMessage =
            binned
            ? L.t("BrailliantConnect has been removed. The app is in the Trash.")
            : L.t(
                "BrailliantConnect has been removed, but the app itself could not "
                    + "be moved to the Trash. Drag it there by hand:") + "\n  "
                + Bundle.main.bundleURL.path
        waiter.signal()
    }
    if waiter.wait(timeout: .now() + 60) == .timedOut {
        finish(L.t("The system did not answer within the allotted time."), code: 1)
    }
    finish(finalMessage)

case "--install":
    // A double-click lands here, and this is the whole installation: register
    // the agent, then hand over. Nothing is left running from this process.
    //
    // Without it, the display would come back only until the next logout, and
    // making it permanent would mean typing a command into a path nobody would
    // guess — which is precisely what this project exists not to require.
    if Installer.register() { exit(0) }

    // Only worth reporting when it fails, and worth reporting visibly: whoever
    // just double-clicked an app has no terminal to read.
    let message = L.t(
        "BrailliantConnect could not register itself to start automatically. "
            + "Make sure the app is in the Applications folder, then open it again.")
    FileHandle.standardError.write(Data((message + "\n").utf8))
    let reporter = NSApplication.shared
    reporter.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = L.t("Installation failed")
    alert.informativeText = message
    alert.alertStyle = .warning
    reporter.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(1)

case "--watch":
    // launchd already runs a single copy of the job; this guards against a
    // second one started by hand.
    guard SingleInstance.claim() else { exit(0) }

    log(L.t("agent started"))

    transfers.onCompletion = { total in
        TransferNotice.announceCompletion(of: total)
        log(L.t("transfer finished — %@", humanBytes(total)))
    }

    let application = NSApplication.shared
    // .accessory: an item in the menu bar, no Dock icon and no window.
    application.setActivationPolicy(.accessory)
    menuBar = MenuBarController(onChange: { syncWithHardware() })

    // Only once the app is a running application does the notification centre
    // have anything to attach a permission dialog to. Asked for before that,
    // the request is dropped and the status stays "not determined" — silently,
    // which is how it went unnoticed the first time.
    TransferNotice.delivery = { log($0) }
    DispatchQueue.main.async { TransferNotice.requestPermission(report: { log($0) }) }

    // Align the state as soon as we start: the display may already be
    // connected, or a location may be left over from a previous session.
    syncWithHardware()

    let watcher = USBWatcher { syncWithHardware() }
    watcher.start()

    // AppKit's run loop rather than CFRunLoopRun: the menu needs it, and IOKit
    // delivers its notifications to the same run loop either way. The agent
    // consumes nothing between two events.
    application.run()

default:
    finish(
        L.t(
            """
            BrailliantConnect — Finder location agent.

              (no argument)     register the agent to start at login, then exit
              --watch           watch the display, publish or remove the location,
                                and hold the menu bar item
              --publish         publish the location
              --unpublish       remove it
              --status          report the current state
              --uninstall       remove every trace of the app

            This agent is normally driven by the "brailliant" command.
            """), code: 2)
}
