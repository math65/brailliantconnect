import AppKit

/// Asks the backend, once per agent start, whether there is something to tell
/// the user — a bad release to skip, a firmware that breaks MTP, a version that
/// has to be replaced by hand.
///
/// There is otherwise no way to reach the people who installed this: the app
/// has no update mechanism and no account, and a forum post reaches whoever
/// happens to read the forum.
///
/// `once` is enforced here, not by the server, which always returns the live
/// announcement: the IDs already shown are kept in UserDefaults. The server is
/// told when one is actually put on screen, so "sent" and "seen" stay
/// different numbers.
enum Announcements {

    private static let installIDKey = "AppBackendInstallID"
    private static let seenKey = "AppBackendSeenAnnouncements"

    private static let client = AppBackendClient()

    /// Called once, from the resident agent.
    ///
    /// Deferred rather than immediate, and deferred again while a window of
    /// ours is on screen: at a first launch the welcome window is up, and an
    /// alert landing on top of it would bury the one page that explains what
    /// just got installed.
    static func checkAtLaunch(after delay: TimeInterval = 5, attemptsLeft: Int = 6) {
        guard AppBackendClient.isConfigured else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if NSApp.windows.contains(where: { $0.isVisible }) {
                guard attemptsLeft > 1 else { return }
                checkAtLaunch(after: 10, attemptsLeft: attemptsLeft - 1)
                return
            }
            client.checkAnnouncement(installID: installID, language: L.isFrench ? "fr" : "en") {
                guard case .success(let announcement?) = $0 else { return }
                present(announcement)
            }
        }
    }

    private static func present(_ announcement: AppBackendClient.Announcement) {
        var seen = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
        if announcement.mode == "once", seen.contains(announcement.id) { return }

        let alert = NSAlert()
        alert.alertStyle = announcement.style == "warning" ? .warning : .informational
        alert.messageText = announcement.title
        alert.informativeText = announcement.body
        // Without a link, NSAlert shows its own single "OK". With one, "OK"
        // stays the default action and the link button comes second.
        if let link = announcement.link {
            alert.addButton(withTitle: L.t("OK"))
            alert.addButton(withTitle: link.label)
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if !seen.contains(announcement.id) {
            seen.append(announcement.id)
            UserDefaults.standard.set(seen, forKey: seenKey)
            // Written now rather than whenever the system feels like it: the
            // agent may be killed at logout without a chance to flush.
            UserDefaults.standard.synchronize()
        }
        client.acknowledgeAnnouncement(installID: installID, announcementID: announcement.id)

        if let link = announcement.link, response == .alertSecondButtonReturn,
            let url = URL(string: link.url)
        {
            NSWorkspace.shared.open(url)
            client.reportAnnouncementClick(installID: installID, announcementID: announcement.id)
        }
    }

    /// Stable per-install UUID. The server never stores it in the clear: it
    /// hashes it, to count one install once rather than every launch.
    private static var installID: String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: installIDKey)
        return fresh
    }
}
