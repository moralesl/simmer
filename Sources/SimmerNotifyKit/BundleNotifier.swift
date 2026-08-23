import Foundation
import SimmerCore
import UserNotifications

/// The one UNUserNotificationCenter implementation, shared by the CLI's
/// `notify-post` and the app. Two hand-kept copies of this glue is how the
/// CLI once requested authorization from the wrong context and burned a
/// bundle id (LEARNINGS.md).
///
/// Deliberately does NOT expose requestAuthorization: the permission request
/// belongs to the app alone, launched via LaunchServices, where macOS shows
/// it as a real banner. Everything here only reads the verdict and posts
/// under it.
public enum BundleNotifier {
    /// nil bundle id = not running from inside a bundle; posting would throw.
    public static var available: Bool { Bundle.main.bundleIdentifier != nil }

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

    public static func content(for request: NotificationRequest,
                               category: String? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.title
        if !request.subtitle.isEmpty { content.subtitle = request.subtitle }
        if !request.body.isEmpty { content.body = request.body }
        if request.sound { content.sound = .default }
        if let category { content.categoryIdentifier = category }
        return content
    }

    /// Post synchronously, returning 0 only when the banner was accepted.
    /// Non-zero = not (or not yet) authorized — callers drop the message;
    /// the menu bar is the channel that cannot be suppressed.
    public static func post(_ request: NotificationRequest,
                            category: String? = nil) -> Int32 {
        guard available, authorizationStatus() == "authorized" else { return 1 }
        let semaphore = DispatchSemaphore(value: 0)
        var failed = false
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content(for: request, category: category),
                                  trigger: nil)) { error in
            failed = error != nil
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return failed ? 1 : 0
    }
}
