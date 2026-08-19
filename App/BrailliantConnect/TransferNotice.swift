import Foundation
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

    /// Asks once for permission to notify.
    ///
    /// Requested at startup rather than at the first transfer: asking in the
    /// middle of one means the answer arrives too late to announce it. The
    /// system only ever shows the dialog once, whatever the answer.
    static func requestPermission(report: @escaping (String) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // Logged because it is otherwise invisible: a refused permission
            // and a working one look exactly alike until a transfer ends and
            // nothing happens.
            center.getNotificationSettings { settings in
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
