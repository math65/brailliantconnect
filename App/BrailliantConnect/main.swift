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

/// Path of the shortcut currently in place, if there is one.
///
/// Not always `~/Brailliant`: that name may be taken by something the user
/// created, in which case the shortcut steps aside to "Brailliant 2". The guide
/// and the log both name the one that actually exists.
var shortcutInPlace: URL?

/// Serialises every change to the shortcut.
///
/// Two callers can reach `createShortcut` at once — a reconciliation and
/// "Open in Finder" publishing again, each from a queue of the system's
/// choosing. Interleaved, both remove ours, both find "Brailliant" free, one
/// link fails and the next attempt settles on "Brailliant 2". Taken in turn,
/// the second simply replaces the first.
let shortcutLock = NSLock()

@discardableResult
func createShortcut() -> Bool {
    shortcutLock.lock()
    defer { shortcutLock.unlock() }
    let fm = FileManager.default
    for _ in 0..<20 {
        if fm.fileExists(atPath: domainLocation.path) { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    guard fm.fileExists(atPath: domainLocation.path) else { return false }

    let home = fm.homeDirectoryForCurrentUser
    // Reuse ours if one is already there — under whatever name it took.
    if let existing = FinderLocation.existingShortcuts(home: home).first {
        try? fm.removeItem(at: existing)
    }
    // Never overwrite anything else: a real folder called "Brailliant" belongs
    // to the user, and removing it here would delete it outright.
    guard
        let destination = FinderLocation.availableShortcut(
            home: home,
            exists: {
                fm.fileExists(atPath: $0.path)
                    || (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil
            })
    else {
        log(L.t("no free name for the shortcut in the home folder"))
        shortcutInPlace = nil
        return false
    }
    guard (try? fm.createSymbolicLink(at: destination, withDestinationURL: domainLocation)) != nil
    else {
        shortcutInPlace = nil
        return false
    }
    shortcutInPlace = destination
    return true
}

func removeShortcut() {
    shortcutLock.lock()
    defer { shortcutLock.unlock() }
    // Only ever remove our own links: never a real folder the user may have
    // created under the same name.
    for shortcut in FinderLocation.existingShortcuts(
        home: FileManager.default.homeDirectoryForCurrentUser)
    {
        try? FileManager.default.removeItem(at: shortcut)
    }
    shortcutInPlace = nil
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

/// Whether the extension has already been registered again in this session.
///
/// One attempt per agent. A single plug fires several IOKit notifications, and
/// a registration that did not take the first time will not take four times in
/// a row either — it would only fill the log at the moment it is being read.
var registrationRepaired = false

/// True when the system says it holds no record of our extension.
///
/// It renders this one as "The application cannot be used right now", which
/// names neither the extension nor the registry and sent the first report that
/// carried it looking at the braille display instead.
func isProviderNotRegistered(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == NSFileProviderErrorDomain
        && error.code == NSFileProviderError.providerNotFound.rawValue
}

func addDomain(_ completion: @escaping (Error?) -> Void) {
    let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
    NSFileProviderManager.add(domain, completionHandler: completion)
}

func publish(_ completion: @escaping (Error?) -> Void) {
    addDomain { error in
        // Not a refusal: the system does not know whom to hand the location
        // to. Registering the extension is the whole remedy, and it is ours to
        // apply — the agent is not sandboxed. Asking the user to type
        // `pluginkit` would undo the one promise this app makes.
        if let error, isProviderNotRegistered(error), !registrationRepaired {
            registrationRepaired = true
            log(L.t("the system holds no record of the Finder extension — registering it"))
            if Installer.registerExtension() {
                addDomain { retry in
                    log(
                        retry == nil
                            ? L.t("Finder extension registered — location published")
                            : L.t(
                                "Finder extension registered, but publishing still failed: %@",
                                retry!.localizedDescription))
                    settle(retry, completion)
                }
                return
            }
            log(L.t("the Finder extension could not be registered"))
        }
        settle(error, completion)
    }
}

/// What a successful publication owes the rest of the agent.
func settle(_ error: Error?, _ completion: @escaping (Error?) -> Void) {
    if error == nil {
        createShortcut()
        // A domain removed and re-added is a new one, so its progress has to be
        // picked up again rather than kept from last time.
        transfers.follow(domain: domainIdentifier)
        // Published is not yet served: the user's click may still be missing.
        publishedState { _, userEnabled in trackApproval(userEnabled: userEnabled) }
    }
    completion(error)
}

func unpublish(_ completion: @escaping (Error?) -> Void) {
    let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: displayName)
    NSFileProviderManager.remove(domain) { error in
        // The shortcut goes with the domain: leaving it would point nowhere.
        removeShortcut()
        transfers.stop()
        // Nothing left to wait for. The consent itself is kept by the system,
        // so the next publication comes back enabled.
        DispatchQueue.main.async {
            locationAwaitingApproval = false
            stopApprovalPoll()
        }
        completion(error)
    }
}

/// Reads whether our domain is published, and whether the user has enabled it.
///
/// `userEnabled` is the second half of a publication on macOS 13: the system
/// creates a third-party location disabled, the Finder asks for a click on
/// "Enable" the first time, and until then every read answers -2011 and the
/// extension is never started. Nothing public can flip it — it is the user's
/// consent — but it can be read, and said.
func publishedState(_ completion: @escaping (_ published: Bool, _ userEnabled: Bool?) -> Void) {
    NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
        let ours = domains.first { $0.identifier == domainIdentifier }
        completion(ours != nil, ours?.userEnabled)
    }
}

func isPublished(_ completion: @escaping (Bool) -> Void) {
    publishedState { published, _ in completion(published) }
}

// MARK: - The user's consent

/// Whether the published location is still waiting for the user to enable it.
///
/// Read by the menu, which says so for as long as it lasts. Measured on
/// 13.2.1: the click is asked once per Mac — the choice survives the domain
/// being removed and published again, which is what every unplug and plug
/// does — and never on the author's macOS 26. Main queue only.
var locationAwaitingApproval = false

/// The first time is announced — a log line and a notification — and the
/// menu carries it from then on. Once per agent: a notification at every plug
/// would teach the reader to dismiss it.
var approvalAnnounced = false

/// Polls the consent while it is awaited, so the agent notices the click
/// without being told: the system sends no notification for it.
var approvalPoll: Timer?

func trackApproval(userEnabled: Bool?) {
    DispatchQueue.main.async {
        let waiting = userEnabled == false
        let changed = waiting != locationAwaitingApproval
        locationAwaitingApproval = waiting
        if waiting {
            if !approvalAnnounced {
                approvalAnnounced = true
                log(
                    L.t(
                        "location published, but macOS is waiting for it to be enabled in the Finder"
                    ))
                TransferNotice.announceApprovalNeeded()
            }
            startApprovalPoll()
        } else {
            if changed { log(L.t("location enabled in the Finder")) }
            stopApprovalPoll()
        }
    }
}

/// Main queue only: a timer belongs to the run loop of the thread that makes
/// it, and only the main one runs.
func startApprovalPoll() {
    guard approvalPoll == nil else { return }
    approvalPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
        publishedState { published, userEnabled in
            DispatchQueue.main.async {
                guard published else {
                    locationAwaitingApproval = false
                    stopApprovalPoll()
                    return
                }
                trackApproval(userEnabled: userEnabled)
            }
        }
    }
}

func stopApprovalPoll() {
    approvalPoll?.invalidate()
    approvalPoll = nil
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

/// Whether a reconciliation is under way, and whether another was asked for
/// meanwhile. Main queue only.
///
/// A reconciliation spans several asynchronous calls into the system, and two
/// of them overlapping each read "not published", each publish, and each create
/// a shortcut. One at a time, then, and a request that arrives during a pass
/// is not dropped: it runs once that pass is over, since the display may have
/// changed in between.
var reconciling = false
var reconcileAgain = false
/// Identifies the pass under way, so the watchdog below only ever releases
/// the one it was armed for.
var reconciliationPass = 0

/// Set once the agent is quitting or uninstalling. Main queue only.
///
/// Both take the location down and then wait — on the system, or on an alert —
/// before the process ends, and a plug in that window would publish it again
/// behind them: a Finder location with no agent left to remove it.
var shuttingDown = false

/// Must be called on the main queue: the initial pass, the USB watcher and the
/// menu all do.
func syncWithHardware() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !shuttingDown else { return }
    guard !reconciling else {
        reconcileAgain = true
        return
    }
    reconciling = true
    reconciliationPass += 1
    let pass = reconciliationPass

    var finished = false
    let finish = {
        DispatchQueue.main.async {
            guard !finished, pass == reconciliationPass else { return }
            finished = true
            reconciling = false
            if reconcileAgain {
                reconcileAgain = false
                syncWithHardware()
            }
        }
    }
    // The system is not known to drop a completion handler, but an agent that
    // waited on one forever would never react to the display again — a far
    // worse failure than two passes overlapping once.
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        guard !finished, pass == reconciliationPass else { return }
        log(L.t("reconciliation still unanswered after 60 seconds — moving on"))
        finish()
    }
    reconcile(then: finish)
}

private func reconcile(then finish: @escaping () -> Void) {
    // "Available" means reachable over MTP, not merely plugged in: a display
    // that is asleep, or in braille terminal mode, stays enumerated and answers
    // nothing.
    let state = USBWatcher.availability()
    let available = state == .ready
    let connected = available
    publishedState { published, userEnabled in
        let action = FinderLocation.action(
            displayConnected: connected, locationPublished: published)
        // Report a transition once, not once per notification.
        let worthLogging = lastKnownAvailability != available
        lastKnownAvailability = available

        switch action {
        case .publish:
            publish { error in
                defer { finish() }
                guard worthLogging || error != nil else { return }
                log(
                    error == nil
                        ? (shortcutInPlace.map {
                            L.t(
                                "display connected — location published in ~/%@",
                                $0.lastPathComponent)
                        } ?? L.t("display connected — location published, in the Finder sidebar"))
                        : L.t(
                            "display connected but publishing failed: %@",
                            error!.localizedDescription)
                )
            }
        case .unpublish:
            unpublish { error in
                defer { finish() }
                guard worthLogging || error != nil else { return }
                let reason: String
                switch state {
                case .asleep:
                    reason = L.t("display asleep — location removed until it wakes up")
                case .brailleTerminal:
                    reason = L.t("MTP turned off on the display — location removed")
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
            // progress still has to be picked up — as does the consent, which
            // may have been given, or not, while no agent was watching.
            if published {
                transfers.follow(domain: domainIdentifier)
                trackApproval(userEnabled: userEnabled)
            }
            finish()
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

/// Retained for the same reason: `NSApplication.delegate` is weak too.
let agentDelegate = AgentApplicationDelegate()

let arguments = Array(CommandLine.arguments.dropFirst())
let waiter = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
var finalMessage = ""

switch arguments.first ?? "--install" {

case "--publish":
    publish { error in
        guard error == nil else {
            finalMessage = L.t("Publishing failed: %@", error!.localizedDescription)
            exitCode = 1
            waiter.signal()
            return
        }
        finalMessage = L.t("Location published. Reachable in \"~/Brailliant\".")
        // Published is one thing; served is another, and the command that
        // said "published" on macOS 13 while the Finder waited for a click
        // would have been telling half the truth.
        publishedState { _, userEnabled in
            if userEnabled == false {
                finalMessage +=
                    "\n"
                    + L.t(
                        "macOS is waiting for it to be enabled: in the Finder sidebar, "
                            + "under Locations, choose BrailliantConnect, then Enable.")
            }
            waiter.signal()
        }
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
    //
    // Only worth reporting when it fails, and worth reporting visibly: whoever
    // just double-clicked an app has no terminal to read.
    func refuse(_ title: String, _ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        let reporter = NSApplication.shared
        reporter.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        reporter.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(1)
    }

    // Sparkle relaunches an updated app by opening it, which lands here. The
    // launchd job is already bringing the new version up (see AgentHandover),
    // and registering now would boot it out — and rewrite the plist for
    // someone who had turned "Open at Login" off.
    if AgentHandover.isRelaunchAfterUpdate { exit(0) }

    guard Installer.isInApplicationsFolder else {
        refuse(
            L.t("Move BrailliantConnect to Applications"),
            L.t(
                "BrailliantConnect only works from the Applications folder. "
                    + "Drag it there with the Finder, then open it again from there."))
    }
    if Installer.register() { exit(0) }

    refuse(
        L.t("Installation failed"),
        L.t(
            "BrailliantConnect could not register itself to start automatically. "
                + "Make sure the app is in the Applications folder, then open it again."))

case "--watch":
    // Before anything else, the lock included: during an update launchd may
    // have restarted the old binary while the bundle was being replaced, and
    // this is where it waits for the new one and hands over to it. See
    // AgentHandover, and "Updates" in CLAUDE.md.
    AgentHandover.awaitNewVersionIfInstalling()

    // launchd already runs a single copy of the job; this guards against a
    // second one started by hand.
    // Logged before leaving: launchd restarts a job that exits, so a copy
    // that keeps finding the lock taken shows up here as one line every ten
    // seconds — and otherwise as nothing at all.
    guard SingleInstance.claim() else {
        log(L.t("another agent already holds the lock — this copy exits"))
        exit(0)
    }

    log(L.t("agent started"))

    // A new build: the Finder extension inside it is registered again before
    // the location is published, so that the system serves this one rather
    // than what it remembers of the bundle that was at this path before.
    if UpdateNotice.recordStart() {
        log(
            Installer.registerExtension()
                ? L.t("Finder extension registered again for the new version")
                : L.t("the Finder extension could not be registered"))
    }

    transfers.onCompletion = { total in
        // The progress ends the same way whether the files landed or the
        // display was pulled out mid-way, and "you can unplug" said after the
        // latter is the one message this app must never get wrong. A display
        // still reachable is the evidence available here that the run was not
        // cut short; anything else is logged, and announced to no one.
        guard USBWatcher.availability() == .ready else {
            log(
                L.t(
                    "transfer interrupted — %@ not confirmed, display no longer reachable",
                    humanBytes(total)))
            return
        }
        TransferNotice.announceCompletion(of: total)
        log(L.t("transfer finished — %@", humanBytes(total)))
    }

    let application = NSApplication.shared
    // .accessory: an item in the menu bar, no Dock icon and no window.
    application.setActivationPolicy(.accessory)
    application.mainMenu = KeyboardMenu.make()
    // NSApplication holds its delegate weakly.
    application.delegate = agentDelegate
    menuBar = MenuBarController(onChange: { syncWithHardware() })

    // After NSApplication exists, which Sparkle's windows need. Scheduled
    // checks run about once a day, never during a transfer.
    Updates.start()

    // Only once the app is a running application does the notification centre
    // have anything to attach a permission dialog to. Asked for before that,
    // the request is dropped and the status stays "not determined" — silently,
    // which is how it went unnoticed the first time.
    // Shown once, on first launch. Delayed only enough for the shortcut to
    // exist, since the window names it. Three seconds was the first guess and
    // put the window on screen a full six seconds after the double-click — long
    // enough for someone to have moved on and miss it entirely.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Welcome.showIfFirstLaunch(shortcut: shortcutInPlace)
    }

    // A channel back to the people who installed this, for what an update
    // cannot say — and the only one reaching versions before Sparkle (1.1.1
    // and older). It waits for the welcome window to be gone before saying
    // anything.
    Announcements.checkAtLaunch()

    TransferNotice.delivery = { log($0) }
    DispatchQueue.main.async {
        TransferNotice.requestPermission(
            report: { log($0) },
            // Once the permission is known: on a first run, asking for it is
            // what makes delivery possible at all.
            then: { UpdateNotice.announceIfUpdated() })
    }

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
