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

let domainIdentifier = NSFileProviderDomainIdentifier("brailliant-principal")
let displayName = "Brailliant"

var domainLocation: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage")
        .appendingPathComponent("BrailliantConnect-\(displayName)")
}

/// Shortcut visible directly in the home folder.
///
/// Without it, access would depend on the Finder sidebar — which can be
/// hidden — or on a path under ~/Library, a folder hidden by default.
var shortcut: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(displayName)
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
        target.contains("BrailliantConnect-")
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
func syncWithHardware() {
    let connected = USBWatcher.connectedDisplayCount() > 0
    isPublished { published in
        switch (connected, published) {
        case (true, false):
            publish { error in
                log(
                    error == nil
                        ? "plage branchée — emplacement publié dans ~/\(displayName)"
                        : "plage branchée mais publication impossible : \(error!.localizedDescription)"
                )
            }
        case (false, true):
            unpublish { error in
                log(
                    error == nil
                        ? "plage débranchée — emplacement retiré"
                        : "plage débranchée mais retrait impossible : \(error!.localizedDescription)"
                )
            }
        default:
            break  // already in the desired state
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
            ? "Emplacement publié. Accessible dans « ~/\(displayName) »."
            : "Échec de la publication : \(error!.localizedDescription)"
        exitCode = error == nil ? 0 : 1
        waiter.signal()
    }
    if waiter.wait(timeout: .now() + 60) == .timedOut {
        finish("Le système n'a pas répondu dans le délai imparti.", code: 1)
    }
    finish(finalMessage, code: exitCode)

case "--unpublish":
    unpublish { error in
        finalMessage =
            error == nil
            ? "Emplacement retiré du Finder."
            : "Échec du retrait : \(error!.localizedDescription)"
        exitCode = error == nil ? 0 : 1
        waiter.signal()
    }
    if waiter.wait(timeout: .now() + 60) == .timedOut {
        finish("Le système n'a pas répondu dans le délai imparti.", code: 1)
    }
    finish(finalMessage, code: exitCode)

case "--status":
    let connected = USBWatcher.connectedDisplayCount() > 0
    isPublished { published in
        finalMessage =
            (published ? "publié — ~/\(displayName)" : "non publié")
            + (connected ? " · plage branchée" : " · aucune plage branchée")
        exitCode = published ? 0 : 2
        waiter.signal()
    }
    if waiter.wait(timeout: .now() + 30) == .timedOut {
        finish("Le système n'a pas répondu.", code: 1)
    }
    finish(finalMessage, code: exitCode)

case "--watch":
    log("agent démarré")
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
        """
        BrailliantConnect — agent de l'emplacement Finder (sans interface).

          (sans argument)   surveille la plage et publie ou retire l'emplacement
          --publish         publie l'emplacement
          --unpublish       le retire
          --status          indique l'état

        Cet agent est normalement piloté par la commande « brailliant ».
        """, code: 2)
}
