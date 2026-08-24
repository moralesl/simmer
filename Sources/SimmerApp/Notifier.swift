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

    /// The last pair published, so a transition can be told from a heartbeat.
    private var lastPublished: (notify: String, login: String)?

    /// The heartbeat: pid + authorization state, for doctor and notify-test.
    /// They must never ask UN themselves — they would be told about their own
    /// executable's never-granted state.
    ///
    /// This already re-reads both values every three seconds, which makes it
    /// the one place that knows when either actually moved. It now says so.
    /// Announcing on CHANGE rather than on every beat is what lets an observer
    /// do real work per event: the setup window shells out to `sudo -nl` to
    /// draw its first row, and that must not run five times a minute forever.
    func publishStatus() {
        let ctx = AppState.shared.context()
        let notify = BundleNotifier.authorizationStatus()
        let login = LoginItem.statusWord
        ctx.ledger.writeAppStatus(notifyStatus: notify, loginStatus: login, now: ctx.now)

        // The compare-and-post happens on main, and so does the only mutation
        // of `lastPublished`. This method has two callers on two queues — the
        // three-second timer on main, and `requestAuthorization`'s completion
        // handler on a background one — so reading and writing the field
        // wherever the call happened to land would be a race on it.
        DispatchQueue.main.async { [self] in
            let current = (notify: notify, login: login)
            guard lastPublished == nil || lastPublished! != current else { return }
            lastPublished = current
            NotificationCenter.default.post(name: .simmerSetupChanged, object: nil)
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
