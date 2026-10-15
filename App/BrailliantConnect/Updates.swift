import AppKit
import Darwin
import MachO
import Sparkle
import UserNotifications

// Automatic updates, through Sparkle 2.
//
// Four parts, each explained where it lives; the sequence as a whole, and why
// it is this one, is under "Updates" in CLAUDE.md:
//
//   Updates                   Sparkle's updater and the decisions it delegates
//                             to us: when to check, when to install.
//   AgentApplicationDelegate  how the agent quits when Sparkle asks it to.
//   AgentHandover             what the agent launchd restarts does while the
//                             bundle is being replaced.
//   UpdateNotice              saying, once the new version runs, that it does.
//
// Only the agent links Sparkle. The extension parses what the USB device sends
// and is sandboxed for it; a network client and an installer inside it would
// widen the one surface this project keeps narrow.

/// Sparkle's updater, with the agent's two constraints on it: never check or
/// install while a transfer is running, and install scheduled updates without
/// asking anyone.
///
/// Main queue only. Sparkle calls its delegates on the main thread — the
/// protocols are marked for the main actor — and `TransferMonitor.isIdle`
/// insists on it, so every entry point below checks rather than assumes.
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    /// Retained for the lifetime of the agent. Nil when Sparkle refused to
    /// start — a Debug build without the real public key, typically.
    private(set) static var shared: Updates?

    private var updater: SPUUpdater?

    /// An installation Sparkle is ready to run, held until no transfer is in
    /// flight. Installing means quitting, and quitting removes the location:
    /// a file still on its way would arrive truncated.
    private var pendingInstallation: (version: String, install: () -> Void)?

    /// The last way Sparkle gave us to go ahead, kept in case a transfer
    /// starts between that go-ahead and the quit event that follows it — the
    /// quit is then refused, and this is how it is asked for again.
    private var lastInstallation: (version: String, install: () -> Void)?

    /// Checks every few seconds whether the transfer is over, but only while
    /// an installation is waiting for it.
    private var idlePoll: Timer?

    /// Starts the updater. Must be called once `NSApplication.shared` exists:
    /// Sparkle's windows need it.
    static func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        let updates = Updates()
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: updates)
        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: updates)
        do {
            try updater.start()
        } catch {
            // Logged, never shown: an alert at every start of a build that
            // cannot update would be worse than no update at all. The menu
            // item is simply absent, as with "Report a Problem…".
            log(L.t("updates disabled: %@", error.localizedDescription))
            return
        }
        updates.updater = updater
        shared = updates
    }

    /// Whether "Check for Updates…" has anything to offer.
    static var isAvailable: Bool { shared != nil }

    /// The manual path: Sparkle's own window, with the release notes and
    /// Install / Later.
    func checkForUpdates() {
        // An accessory app never comes forward on its own; without this the
        // window would open behind whatever has the focus, where VoiceOver
        // does not go looking.
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
    }

    // MARK: When to check

    /// Scheduled checks only while nothing is moving. A check that finds an
    /// update downloads it at once, and the download competes with nothing
    /// worth protecting — but the installation that follows quits the agent,
    /// so it is simpler to keep the whole cycle out of a transfer's way.
    /// Refused, the cycle is simply tried again at the next interval.
    ///
    /// A check the user asked for always goes ahead; its installation is
    /// still held until the transfer ends (see `shouldPostponeRelaunch`).
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }
        guard Thread.isMainThread, transfers.isIdle, !shuttingDown else {
            log(L.t("updates: scheduled check skipped — a transfer is running"))
            throw NSError(
                domain: "BrailliantConnect.Updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "A transfer is running."])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log(L.t("updates: version %@ found", item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        // "No update" is the answer nearly every day, not an error.
        guard
            !(error.domain == SUSparkleErrorDomain
                && error.code == Int(SUError.noUpdateError.rawValue))
        else { return }
        log(L.t("updates: %@", error.localizedDescription))
    }

    // MARK: When to install

    /// A scheduled update has been downloaded and prepared, and Sparkle offers
    /// to install it the next time the agent quits — which, for an agent that
    /// never quits, is never. Taking control of it (returning true) and
    /// running the installation as soon as no transfer is in flight is what
    /// "install automatically" means here.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        log(L.t("updates: version %@ downloaded", item.displayVersionString))
        installWhenIdle(version: item.displayVersionString, immediateInstallHandler)
        return true
    }

    /// Asked once per installation, on both paths — the automatic one above,
    /// and "Install" in Sparkle's window. Postponed while a transfer runs;
    /// otherwise the handler is kept all the same, in case the quit that
    /// follows has to be refused (see `AgentApplicationDelegate`).
    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        lastInstallation = (item.displayVersionString, installHandler)
        if Thread.isMainThread, transfers.isIdle, !shuttingDown { return false }
        log(L.t("updates: installing %@ once the transfer is over", item.displayVersionString))
        installWhenIdle(version: item.displayVersionString, installHandler)
        return true
    }

    /// Called just before Sparkle tells its installer to go ahead, which asks
    /// the agent to quit a moment later. The marker written here is what the
    /// agent launchd restarts, and Sparkle's relaunch, read to know what is
    /// going on.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        AgentHandover.record(toVersion: item.displayVersionString)
        log(L.t("updates: installing %@ — the agent restarts", item.displayVersionString))
    }

    private func installWhenIdle(version: String, _ install: @escaping () -> Void) {
        pendingInstallation = (version, install)
        installIfIdle()
        guard pendingInstallation != nil, idlePoll == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.installIfIdle()
        }
        // Common modes, so an open menu or alert does not hold it back.
        RunLoop.main.add(timer, forMode: .common)
        idlePoll = timer
    }

    private func installIfIdle() {
        guard let pending = pendingInstallation, Thread.isMainThread, transfers.isIdle,
            !shuttingDown
        else { return }
        pendingInstallation = nil
        idlePoll?.invalidate()
        idlePoll = nil
        // On a second attempt Sparkle does not call `willInstallUpdate` again,
        // and the first marker was cleared when the quit was refused.
        if markerNeeded {
            markerNeeded = false
            AgentHandover.record(toVersion: pending.version)
        }
        pending.install()
    }

    /// Set once a quit has been refused: the next attempt writes the marker
    /// itself. Not on a first attempt, where `willInstallUpdate` writes it —
    /// only once Sparkle has really decided to go ahead.
    private var markerNeeded = false

    /// The quit that installs the update was refused because a transfer had
    /// started in the meantime: ask again once it is over.
    func quitRefusedForTransfer() {
        AgentHandover.clear()
        guard let last = lastInstallation else { return }
        markerNeeded = true
        log(L.t("updates: a transfer started — installing %@ once it is over", last.version))
        installWhenIdle(version: last.version, last.install)
    }

    // MARK: Updates that need someone

    /// Sparkle's alert for a background app would otherwise open behind
    /// everything, unannounced — "gentle reminders" are its answer to that.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update reaches the user only when Sparkle cannot install
    /// it alone: an app that needs an administrator to replace it, an update
    /// marked as major or informational. Sparkle shows its window, and the
    /// notification says it is there — a window appearing on its own is not
    /// something a screen reader announces.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        log(L.t("updates: version %@ needs to be confirmed", update.displayVersionString))
        UpdateNotice.announceAvailable(version: update.displayVersionString)
    }
}

// MARK: - Quitting for an installation

/// The application's delegate, for one decision: what to do when asked to quit.
///
/// Sparkle's installer asks with an ordinary quit event once it is ready to
/// replace the bundle. Anything else that asks — logging out, mostly — gets the
/// answer it always had. The difference is only made while a handover marker
/// is fresh, which `Updates` writes a moment before the event.
final class AgentApplicationDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AgentHandover.isUnderWay else { return .terminateNow }

        // A transfer may have started between Sparkle's go-ahead and this
        // event. Refusing is allowed — Sparkle sends a quit event precisely
        // so that it can be refused — and the installation is asked for again
        // once the transfer ends.
        guard transfers.isIdle else {
            log(L.t("updates: quit refused — a transfer is running"))
            Updates.shared?.quitRefusedForTransfer()
            return .terminateCancel
        }

        // As "Quit" does, minus the bootout: the location goes with the agent,
        // so that no Finder folder is left pointing at an extension about to
        // be replaced. launchd restarts the job as soon as this process exits
        // — that is what brings the new version up (see AgentHandover).
        shuttingDown = true
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        unpublish { _ in DispatchQueue.main.async(execute: reply) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: reply)
        return .terminateLater
    }
}

// MARK: - The restart in the middle

/// What happens between the agent quitting for an update and the new version
/// running. Launchd stays the only thing that starts the resident agent:
///
/// 1. the agent quits (exit 0); KeepAlive restarts the job at once, from the
///    same path — the old binary if the installer has not swapped the bundle
///    yet, the new one otherwise;
/// 2. an old binary finds the marker, holds back — no lock, no menu, no
///    location — until the bundle on disk is another file, then `execv`s it:
///    same process, same launchd job, new code;
/// 3. Sparkle's relaunch, a launch without arguments, finds the marker and
///    exits without touching launchd.
enum AgentHandover {

    private static let markerKey = "UpdateHandover"

    /// The build this process runs, captured once the handover has settled
    /// which binary this is. Before that, `Bundle.main` may already be
    /// reading the new bundle's Info.plist from under the old binary.
    private(set) static var runningBuild: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    static var marker: UpdateHandover.Marker? {
        UpdateHandover.Marker(
            dictionary: UserDefaults.standard.dictionary(forKey: markerKey))
    }

    /// Whether this agent is the one quitting for an installation.
    static var isUnderWay: Bool {
        guard let marker else { return false }
        return UpdateHandover.isFresh(marker, now: Date()) && marker.fromBuild == runningBuild
    }

    static func record(toVersion version: String) {
        let marker = UpdateHandover.Marker(
            fromBuild: runningBuild, toVersion: version, date: Date())
        // cfprefsd holds the value as soon as `set` returns: it survives the
        // process exiting a moment later.
        UserDefaults.standard.set(marker.dictionary, forKey: markerKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: markerKey)
    }

    /// For a launch without arguments: whether it is Sparkle relaunching the
    /// app in the middle of a handover. `register()` would boot the new agent
    /// out, and rewrite the launchd plist even for someone who had turned
    /// *Open at Login* off.
    static var isRelaunchAfterUpdate: Bool {
        UpdateHandover.isRelaunchAfterUpdate(marker: marker, now: Date())
    }

    /// Called first thing in `--watch`. Returns once this process should run
    /// as the resident agent; never returns if it starts the new version.
    static func awaitNewVersionIfInstalling() {
        guard let marker, UpdateHandover.isFresh(marker, now: Date()) else { return }
        let deadline = Date().addingTimeInterval(UpdateHandover.patience)
        var announced = false
        while true {
            switch UpdateHandover.step(
                marker: marker, now: Date(), diskBuild: diskBuild(),
                runningIsOnDisk: runningIsOnDisk())
            {
            case .proceed:
                runningBuild = diskBuild() ?? runningBuild
                return
            case .startNewVersion:
                log(L.t("update: version %@ in place — starting it", marker.toVersion))
                startNewVersion()
                return
            case .wait:
                if !announced {
                    announced = true
                    log(
                        L.t(
                            "update: waiting for version %@ to be put in place",
                            marker.toVersion))
                }
                guard Date() < deadline else {
                    // Sparkle does not relaunch after a failed installation,
                    // so carrying on is the only way the old version returns.
                    log(L.t("update: version %@ never arrived — carrying on", marker.toVersion))
                    clear()
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    /// `CFBundleVersion` of the bundle on disk now — read from the file, never
    /// from `Bundle.main`, which keeps whatever it read first.
    private static func diskBuild() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    /// Whether the executable at the bundle's path is the very file this
    /// process was started from.
    ///
    /// The kernel keeps the file a process was started from mapped, whatever
    /// happens to its path afterwards, and says which file it is: the region
    /// holding the main image is backed by that file's vnode. Compared with
    /// what `stat` finds at the path now, it tells an old binary from the new
    /// one without trusting anything read from the bundle — which, after the
    /// swap, describes the new version whichever binary reads it.
    ///
    /// Measured with a throwaway executable replaced by `cp` + `mv` while it
    /// ran: the region kept the original inode, the path changed.
    ///
    /// When either side cannot be read, the answer is "yes": the build then
    /// decides, and the worst case is a wait that times out.
    private static func runningIsOnDisk() -> Bool {
        guard let header = _dyld_get_image_header(0),
            let path = Bundle.main.executablePath
        else { return true }
        var region = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        let read = proc_pidinfo(
            getpid(), PROC_PIDREGIONPATHINFO, UInt64(UInt(bitPattern: header)), &region, size)
        guard read == size else { return true }
        var disk = stat()
        guard stat(path, &disk) == 0 else { return true }
        let running = region.prp_vip.vip_vi.vi_stat
        return disk.st_ino == running.vst_ino
            && UInt32(bitPattern: disk.st_dev) == running.vst_dev
    }

    /// Replaces this process with the executable now at the bundle's path,
    /// keeping the launchd job and its process.
    ///
    /// Exiting instead would work too — KeepAlive would start the new binary —
    /// but launchd throttles a job that ran for less than ten seconds, and
    /// the menu bar item would be missing for that long.
    private static func startNewVersion() {
        guard let path = Bundle.main.executablePath else { exit(0) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("--watch"), nil]
        execv(path, &arguments)
        // Only reached when exec failed. Exiting hands the job back to
        // launchd, which starts whatever is at the path ten seconds later.
        log(
            L.t(
                "update: could not start the new version (%@) — exiting",
                String(cString: strerror(errno))))
        exit(0)
    }
}

// MARK: - Saying it

/// Tells the user that the version changed — once, three ways, because each one
/// can be missed: a notification (which may be turned off), a line in the log
/// (which nobody reads unless something went wrong), and a line in the menu,
/// kept until the menu has been opened once.
enum UpdateNotice {

    private static let lastBuildKey = "LastRunBuild"
    private static let noticeKey = "UpdateNotice"

    /// The version this start updated to, when it is one. Main queue only.
    private static var justUpdatedTo: String?

    /// Called once per `--watch` start, after the handover. Returns whether
    /// this is the first start of a new build.
    ///
    /// Compared with what last ran, not with the handover marker: the marker
    /// only exists when Sparkle installed while the agent was running, and an
    /// update installed at logout, or by hand, is just as much news.
    @discardableResult
    static func recordStart() -> Bool {
        let defaults = UserDefaults.standard
        let build = AgentHandover.runningBuild
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? build
        let previous = defaults.string(forKey: lastBuildKey)
        defaults.set(build, forKey: lastBuildKey)
        // The handover marker is deliberately left to expire rather than
        // cleared here: Sparkle's relaunch may still arrive after this point,
        // and it is the marker that keeps it away from launchd.
        guard UpdateHandover.wasUpdated(previousBuild: previous, currentBuild: build) else {
            return false
        }
        justUpdatedTo = version
        defaults.set(["version": version, "date": Date()], forKey: noticeKey)
        log(L.t("updated to version %@ (build %@, previously %@)", version, build, previous ?? "?"))
        return true
    }

    /// Posts the notification for an update this start detected. Called once
    /// the permission is known, since asking for it is what makes delivery
    /// possible on a first run.
    static func announceIfUpdated() {
        guard let version = justUpdatedTo else { return }
        justUpdatedTo = nil
        post(
            identifier: "update-installed",
            title: L.t("BrailliantConnect %@ installed", version),
            body: L.t("The update is in place and BrailliantConnect is running again."))
    }

    /// Says that an update is waiting in Sparkle's window.
    static func announceAvailable(version: String) {
        post(
            identifier: "update-available",
            title: L.t("BrailliantConnect %@ is available", version),
            body: L.t("Choose Check for Updates… in the BrailliantConnect menu to install it."))
    }

    private static func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log("notification refused: \(error.localizedDescription)") }
        }
    }

    /// The menu line, until the menu has been opened once.
    static var menuLine: String? {
        guard let notice = UserDefaults.standard.dictionary(forKey: noticeKey),
            let version = notice["version"] as? String,
            let date = notice["date"] as? Date
        else { return nil }
        let formatter = DateFormatter()
        // Explicit, for the same reason as `humanBytes`: an agent started by
        // launchd inherits no locale, and an English date inside a French
        // sentence reads as a mistake.
        formatter.locale = Locale(identifier: L.isFrench ? "fr_FR" : "en_US")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return L.t("Updated to %@ on %@", version, formatter.string(from: date))
    }

    /// Called when the menu actually opens — not when it is merely rebuilt,
    /// which AppKit also does to look up key equivalents.
    static func menuWasSeen() {
        UserDefaults.standard.removeObject(forKey: noticeKey)
    }
}
