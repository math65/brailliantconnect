import FileProvider
import Foundation

// BrailliantConnect agent — headless.
//
// Launched without arguments, it stays in the background and follows the state
// of the display: connected, the location shows up in the Finder; disconnected,
// it goes away along with its shortcut. The user has nothing to do.
//
// It also accepts one-off commands, used by `brailliant`:
//   --publish     publishes the location
//   --unpublish   removes it
//   --status      reports whether it is published
//   --watch       stays in the background (default behaviour)

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

func createShortcut() {
    let fm = FileManager.default
    for _ in 0..<20 {
        if fm.fileExists(atPath: domainLocation.path) { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    guard fm.fileExists(atPath: domainLocation.path) else { return }
    try? fm.removeItem(at: shortcut)
    try? fm.createSymbolicLink(at: shortcut, withDestinationURL: domainLocation)
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

func publish(_ completion: @escaping (Error?) -> Void) {
    let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
    NSFileProviderManager.add(domain) { error in
        if error == nil { createShortcut() }
        completion(error)
    }
}

func unpublish(_ completion: @escaping (Error?) -> Void) {
    let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
    NSFileProviderManager.remove(domain) { error in
        // The shortcut goes with the domain: leaving it would point nowhere.
        removeShortcut()
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
    // "Available" means reachable over MTP, not merely plugged in: a sleeping
    // display stays enumerated but answers nothing.
    let available = USBWatcher.connectedDisplayCount() > 0
    let pluggedIn = USBWatcher.pluggedDisplayCount() > 0
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
                        ? L.t("display connected — location published in ~/%@", displayName)
                        : L.t(
                            "display connected but publishing failed: %@",
                            error!.localizedDescription)
                )
            }
        case .unpublish:
            unpublish { error in
                guard worthLogging || error != nil else { return }
                log(
                    error == nil
                        ? (pluggedIn
                            ? L.t("display asleep — location removed until it wakes up")
                            : L.t("display disconnected — location removed"))
                        : L.t(
                            "display disconnected but removal failed: %@",
                            error!.localizedDescription)
                )
            }
        case .nothing:
            break
        }
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
let waiter = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
var finalMessage = ""

switch arguments.first ?? "--watch" {

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

case "--watch":
    log(L.t("agent started"))
    // Align the state as soon as we start: the display may already be
    // connected, or a location may be left over from a previous session.
    syncWithHardware()

    let watcher = USBWatcher { syncWithHardware() }
    watcher.start()
    // The agent lives in its run loop: IOKit wakes it up on connections and
    // disconnections, and it consumes nothing in between.
    CFRunLoopRun()

default:
    finish(
        L.t(
            """
            BrailliantConnect — Finder location agent (headless).

              (no argument)     watch the display and publish or remove the location
              --publish         publish the location
              --unpublish       remove it
              --status          report the current state

            This agent is normally driven by the "brailliant" command.
            """), code: 2)
}
