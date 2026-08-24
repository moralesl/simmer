import Foundation
import SimmerCore
import SimmerNotifyKit
import UserNotifications

/// The app IS the notification identity, and the app is the ONLY poster —
/// its executable holds the grant (PLATFORM-FACTS.md). Its own outcomes post
/// directly; everything the CLI and the guard want said arrives through the
/// ledger's spool and is posted here, buttons included.
///
/// This is also the only place in the whole tool that may call
/// requestAuthorization: the app is LaunchServices-launched, so the request
/// arrives as a real banner with the pot icon.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var spoolTimer: Timer?

    func setUp() {
        guard BundleNotifier.available else { return }
        UNUserNotificationCenter.current().delegate = self
        BundleNotifier.registerCategories()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                Notifier.shared.publishStatus()
            }
        publishStatus()
        // Drain what the CLI and the guard queued — every few seconds, and
        // the heartbeat doctor reads rides along.
        spoolTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Notifier.shared.drainSpool()
            Notifier.shared.publishStatus()
        }
    }

    func post(_ notifications: [NotificationRequest]) {
        guard AppState.shared.environment.notifyTransport != "none" else { return }
        for request in notifications { BundleNotifier.post(request) }
    }

    func drainSpool() {
        let ctx = AppState.shared.context()
        post(ctx.ledger.drainNotifications(now: ctx.now))
    }

    /// The heartbeat: pid + authorization state, for doctor and notify-test.
    /// They must never ask UN themselves — they would be told about their own
    /// executable's never-granted state.
    func publishStatus() {
        let ctx = AppState.shared.context()
        ctx.ledger.writeAppStatus(notifyStatus: BundleNotifier.authorizationStatus(),
                                  loginStatus: LoginItem.statusWord,
                                  now: ctx.now)
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
                // Add to the menu bar's own claim, or take one if it holds
                // none. Always a fresh claim would SET the deadline to 30
                // minutes from now, which shortens a longer claim of its own —
                // the same trap the menu items had. Either way nobody else's
                // claim is touched, and either way there are at least 30 more
                // minutes than there were.
                AppState.shared.perform { ctx in
                    ctx.ledger.claim(owner: ctx.owner) != nil
                        ? Commands.extend("30m", json: false, ctx: ctx)
                        : Commands.claim(ClaimInput(durationText: "30m",
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
