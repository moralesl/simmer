import Foundation
import SimmerCore
import SimmerNotifyKit
import UserNotifications

/// The app IS the notification identity — an installed, LaunchServices-
/// registered, ad-hoc-signed bundle owns its banners (PLATFORM-FACTS.md).
/// Banners carry buttons because the app owns the bundle: Extend from a
/// banner is the exact moment someone wants it.
///
/// This is also the ONLY place in the whole tool that may call
/// requestAuthorization: the app is LaunchServices-launched, so the request
/// arrives as a real banner. The posting glue is SimmerNotifyKit, shared
/// with the CLI's notify-post.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let aggregateCategory = "simmer.aggregate"

    func setUp() {
        guard BundleNotifier.available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let extend = UNNotificationAction(identifier: "simmer.extend30",
                                          title: "Extend 30 min")
        let release = UNNotificationAction(identifier: "simmer.release",
                                           title: "Release",
                                           options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.aggregateCategory,
                                   actions: [extend, release],
                                   intentIdentifiers: []),
        ])
        // First launch (via LaunchServices) is what makes macOS show the
        // permission request as a banner with simmer's own icon.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notifications: [NotificationRequest]) {
        guard !notifications.isEmpty,
              AppState.shared.environment.notifyTransport != "none" else { return }
        for request in notifications {
            _ = BundleNotifier.post(request, category: Self.aggregateCategory)
        }
    }

    func authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        guard BundleNotifier.available else { return completion(.denied) }
        UNUserNotificationCenter.current().getNotificationSettings {
            completion($0.authorizationStatus)
        }
    }

    // Show banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case "simmer.extend30":
                // A fresh menubar claim: guarantees 30 more minutes through
                // the aggregate without touching anyone else's claim.
                AppState.shared.perform { ctx in
                    Commands.claim(ClaimInput(durationText: "30m",
                                              reason: "extended from a banner"), ctx: ctx)
                }
            case "simmer.release":
                AppState.shared.perform { ctx in
                    Commands.release(all: false, json: false, ctx: ctx)
                }
            default:
                break
            }
            completionHandler()
        }
    }
}
