import Foundation
import UserNotifications
import os.log

/// Tells the user why a file put at the root did not stay there.
///
/// The refusal itself is silent by design: the system's way of declining an
/// import is to complete with no item and no error, and it then deletes the
/// local copy. Nothing in the Finder explains the disappearance, and a file
/// that vanishes without a word is worse than one that is merely refused.
///
/// A notification is the only channel available here — the extension has no
/// window, and the menu bar belongs to the agent, another process entirely.
enum RootRefusal {

    /// One identifier for all of them: pasting forty files must not produce
    /// forty notifications, so each replaces the last.
    private static let throttle = RefusalThrottle(identifier: "brailliant.root-refused")

    static func announce(storages: [String]) {
        let content = UNMutableNotificationContent()
        content.title = L.t("Put the file in a storage")
        // The storages are named as the display names them, quoted and joined
        // in a readable list rather than dumped as an array.
        let named =
            storages.isEmpty
            ? L.t("a storage")
            : storages.map { "« \($0) »" }.joined(separator: L.t(" or "))
        content.body = L.t(
            "The top level of the display holds its storages and nothing else. "
                + "Open %@ and drop the file in there.", named)
        throttle.post(content)
    }
}

/// Tells the user why a file or a new name did not reach the display.
///
/// MTP itself would take a name with a slash in it, and that is the problem:
/// such a name, read back by any program, walks out of the folder it is in. So
/// the extension never writes one. A copy declined for that reason disappears
/// from the Finder the same silent way as one dropped at the root, and a
/// rename is undone just as quietly — hence the same kind of notification.
enum NameRefusal {

    private static let throttle = RefusalThrottle(identifier: "brailliant.name-refused")

    static func announce(name: String) {
        let content = UNMutableNotificationContent()
        content.title = L.t("This name cannot be written to the display")
        // Shown on this Mac only, so the name can be quoted: it is how the
        // user recognises which file this is about.
        content.body = L.t(
            "The display does not accept a slash or a backslash in a file name. "
                + "Rename \"%@\" and try again.", name.sanitizedForDisplay)
        throttle.post(content)
    }
}

/// Posts one kind of refusal, at most once every few seconds.
///
/// Pasting forty files must not produce forty notifications: each replaces the
/// last under the same identifier, and a burst produces only the first.
final class RefusalThrottle {

    private let identifier: String
    private let lock = NSLock()
    private var lastAnnounced: Date?

    /// Not more than one notification every few seconds.
    private static let quiet: TimeInterval = 5

    init(identifier: String) {
        self.identifier = identifier
    }

    func post(_ content: UNMutableNotificationContent) {
        lock.lock()
        let now = Date()
        if let last = lastAnnounced, now.timeIntervalSince(last) < Self.quiet {
            lock.unlock()
            return
        }
        lastAnnounced = now
        lock.unlock()

        content.sound = .default
        // Posting from the extension works: it inherits the permission granted
        // to the host app, verified on the device rather than assumed — the
        // extension has its own bundle identifier, which gave every reason to
        // doubt it.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
