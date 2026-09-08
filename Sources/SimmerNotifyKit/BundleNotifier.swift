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

    /// Why a banner did not reach UN, when it did not.
    ///
    /// Three answers rather than a `Bool`, because the two failures are not
    /// the same event: being unbundled is a steady state of the process (the
    /// CLI, a unit test) and says nothing about the banner, while a request
    /// with no informative text is a defect in whatever composed it and is
    /// worth a line in the log. One `false` for both would hand the caller a
    /// fallback and make the second invisible again.
    public enum PostResult: Sendable, Equatable {
        case posted
        /// Not running from inside a bundle, so posting would throw.
        case unbundled
        /// Neither subtitle nor body — accepted by `add`, never presented.
        case noInformativeText
    }

    /// Fire-and-forget from the app's main flow; UN handles delivery.
    ///
    /// The text refusal is checked BEFORE `available`, deliberately. A
    /// request with no informative text is a defect in whatever composed it —
    /// a fact about the request, true whether or not this process happens to
    /// be running from a bundle — and answering `.unbundled` about it would
    /// hide it behind a property of the process. It also means this decision
    /// is reachable the moment any test target can see this type: `available`
    /// is `Bundle.main.bundleIdentifier != nil`, which is nil in a `swift
    /// test` binary, so a refusal ordered after it could never be driven.
    @discardableResult
    public static func post(_ request: NotificationRequest) -> PostResult {
        // The last gate before UN, and the reason it is a gate: `add` accepts
        // a title-only content, reports no error, and never presents it. The
        // spool drops these already and says so in the log
        // (Ledger.drainNotifications); this is the app's own direct posts,
        // which do not pass through it — and the caller writes the line,
        // because this module has no ledger and should not grow one.
        guard request.hasInformativeText else { return .noInformativeText }
        guard available else { return .unbundled }
        let content = UNMutableNotificationContent()
        content.title = request.title
        if !request.subtitle.isEmpty { content.subtitle = request.subtitle }
        if !request.body.isEmpty { content.body = request.body }
        if request.sound { content.sound = .default }
        if request.actionable { content.categoryIdentifier = aggregateCategory }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
        return .posted
    }
}
