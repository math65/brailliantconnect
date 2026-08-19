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
    private static let identifier = "brailliant.root-refused"

    private static let lock = NSLock()
    private static var lastAnnounced: Date?

    /// Not more than one notification every few seconds, for the same reason.
    private static let quiet: TimeInterval = 5

    static func announce(storages: [String]) {
        lock.lock()
        let now = Date()
        if let last = lastAnnounced, now.timeIntervalSince(last) < quiet {
            lock.unlock()
            return
        }
        lastAnnounced = now
        lock.unlock()

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
        content.sound = .default

        // Posting from the extension works: it inherits the permission granted
        // to the host app, verified on the device rather than assumed — the
        // extension has its own bundle identifier, which gave every reason to
        // doubt it.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
