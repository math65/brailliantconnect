import AppKit
import UserNotifications

/// Announces the end of a transfer.
///
/// The menu bar tells you a transfer is running, but only if you go and look.
/// Someone who has just dropped three gigabytes onto the display has no reason
/// to keep opening a menu, and every reason to walk away — and then unplug.
/// A notification is the only thing that reaches them without being asked, and
/// the only part of this app a screen reader announces on its own.
enum TransferNotice {

    /// Where to report a delivery that failed. Set by the agent so the reason
    /// lands in its log rather than nowhere.
    static var delivery: ((String) -> Void)?

    /// The permission as last read from the system, nil until it has been.
    /// Main queue only.
    ///
    /// Kept so the menu can say when notifications are off. Logging it was the
    /// first answer, and it only told the author: the person whose transfer
    /// ended in silence had no way to learn why, nor where to turn it back on.
    private(set) static var authorization: UNAuthorizationStatus?

    /// True when the user has refused notifications, in the dialog or later in
    /// System Settings. Main queue only.
    static var isDenied: Bool { authorization == .denied }

    /// Reads the permission again, then calls back on the main queue.
    ///
    /// The menu calls this every time it opens: the setting lives in System
    /// Settings, which says nothing when it changes.
    static func refreshAuthorization(then done: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                authorization = settings.authorizationStatus
                done?()
            }
        }
    }

    /// Opens our own page of the Notifications settings.
    ///
    /// The identifier narrows it to this app; should a future macOS ignore it,
    /// the Notifications pane itself is still the right place to land.
    static func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let identifier = Bundle.main.bundleIdentifier ?? "com.mathieumartin.BrailliantConnect"
        for address in [pane + "?id=" + identifier, pane] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Asks once for permission to notify.
    ///
    /// Requested at startup rather than at the first transfer: asking in the
    /// middle of one means the answer arrives too late to announce it. The
    /// system only ever shows the dialog once, whatever the answer.
    ///
    /// - Parameter then: called on the main queue once the answer is known.
    static func requestPermission(
        report: @escaping (String) -> Void, then: (() -> Void)? = nil
    ) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // Logged because it is otherwise invisible: a refused permission
            // and a working one look exactly alike until a transfer ends and
            // nothing happens.
            center.getNotificationSettings { settings in
                DispatchQueue.main.async {
                    authorization = settings.authorizationStatus
                    then?()
                }
                let state: String
                switch settings.authorizationStatus {
                case .authorized, .provisional: state = "authorized"
                case .denied: state = "denied"
                default: state = "not determined"
                }
                report(
                    "notifications: \(state)"
                        + (granted ? "" : (error.map { " (\($0.localizedDescription))" } ?? "")))
            }
        }
    }

    /// Says that the Finder is waiting for the location to be enabled.
    ///
    /// Once per agent, from `trackApproval`: on macOS 13 a new location is
    /// created disabled, and the only sign of it is a banner in a Finder
    /// window nobody has a reason to open.
    static func announceApprovalNeeded() {
        let content = UNMutableNotificationContent()
        content.title = L.t("Enable the Brailliant location")
        content.body = L.t(
            "In the Finder sidebar, under Locations, select BrailliantConnect, then "
                + "activate Enable. Once is enough.")
        let request = UNNotificationRequest(
            identifier: "location-approval", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { delivery?("notification refused: \(error.localizedDescription)") }
        }
    }

    /// Says the display is safe to unplug.
    static func announceCompletion(of total: Int64) {
        let content = UNMutableNotificationContent()
        content.title = L.t("Transfer complete")
        content.body = L.t("%@ sent. You can unplug the display.", humanBytes(total))
        // Sound as well as text: the point is to reach someone who has stopped
        // watching the screen.
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { delivery?("notification refused: \(error.localizedDescription)") }
        }
    }
}
