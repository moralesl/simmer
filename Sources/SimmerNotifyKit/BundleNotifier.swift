import Foundation
import SimmerCore
import UserNotifications

/// The one UNUserNotificationCenter implementation. Only the APP links this:
/// macOS binds the notification grant to the executable that requested it, so
/// a second executable in the same bundle reads its own never-granted state —
/// the misread this design exists to prevent. The CLI therefore
/// never touches UN at all; it enqueues into the ledger's spool and the app
/// posts from here.
///
/// requestAuthorization still lives in the app's Notifier, not here: asking
/// is a UI moment, posting is not.
public enum BundleNotifier {
    public static let aggregateCategory = "simmer.aggregate"

    /// nil bundle id = not running from inside a bundle; posting would throw.
    public static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// The Extend/Release buttons every actionable banner carries.
    /// Idempotent; the app calls it once at launch.
    public static func registerCategories() {
        guard available else { return }
        let extend = UNNotificationAction(identifier: "simmer.extend30",
                                          title: "Extend 30 min")
        let release = UNNotificationAction(identifier: "simmer.release",
                                           title: "Release",
                                           options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: aggregateCategory,
                                   actions: [extend, release],
                                   intentIdentifiers: []),
        ])
    }

    public static func authorizationStatus() -> String {
        guard available else { return "unbundled" }
        let semaphore = DispatchSemaphore(value: 0)
        var status = "unknown"
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = "authorized"
            case .denied: status = "denied"
            case .notDetermined: status = "notDetermined"
            default: status = "unknown"
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return status
    }

    /// Fire-and-forget from the app's main flow; UN handles delivery.
    public static func post(_ request: NotificationRequest) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = request.title
        if !request.subtitle.isEmpty { content.subtitle = request.subtitle }
        if !request.body.isEmpty { content.body = request.body }
        if request.sound { content.sound = .default }
        if request.actionable { content.categoryIdentifier = aggregateCategory }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }
}
