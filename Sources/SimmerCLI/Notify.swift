import Foundation
import SimmerCore
import UserNotifications

/// v1 posts notifications AS SIMMER'S OWN BUNDLE, or not at all.
///
/// The spike's borrowed identities — osascript's Script Editor, SwiftBar,
/// Shortcuts — died with the spike: a banner wearing someone else's name is a
/// workaround, and v1 ships the real thing. When the bundle cannot post (not
/// installed, or not yet allowed), the notification is dropped; the menu bar
/// remains the channel that cannot be suppressed, and the log keeps the record.
///
///   SIMMER_NOTIFY=none    silence
///   anything else         the bundle (auto and bundle are the same thing now)
///
/// Posting happens by exec'ing the bundle's own copy of this binary
/// (`notify-post`) — the spike-verified way to carry the bundle's identity.
/// Waited on, never detached.
enum Notify {
    static func post(_ notification: NotificationRequest, env: SimmerEnvironment) {
        guard env.notifyTransport != "none" else { return }
        let binary = bundleBinary(env: env)
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        var args = ["notify-post", notification.title, notification.subtitle, notification.body]
        if !notification.sound { args.append("--silent") }
        // Non-zero = not (or not yet) authorized. Dropped on purpose.
        _ = Shell.run(binary, args)
    }

    static func bundleBinary(env: SimmerEnvironment) -> String {
        env.notifierAppPath + "/Contents/MacOS/simmer"
    }

    // MARK: posting AS the bundle — the notify-post subcommand's engine.

    static func authorizationStatus() -> String {
        guard Bundle.main.bundleIdentifier != nil else { return "unbundled" }
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

    /// Deliberately NEVER calls requestAuthorization: the permission request
    /// belongs to the app alone, launched via LaunchServices. A request from
    /// a bare-CLI context risks macOS caching a DENIAL for the bundle id —
    /// which is permanent (PLATFORM-FACTS.md, LEARNINGS.md). This only reads
    /// the verdict and posts under it.
    static func postAsBundle(title: String, subtitle: String, body: String, sound: Bool) -> Int32 {
        guard Bundle.main.bundleIdentifier != nil else {
            FileHandle.standardError.write(Data("simmer: notify-post needs to run from inside Simmer.app\n".utf8))
            return 1
        }
        guard authorizationStatus() == "authorized" else { return 1 }

        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        if !body.isEmpty { content.body = body }
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        let semaphore = DispatchSemaphore(value: 0)
        var failed = false
        UNUserNotificationCenter.current().add(request) { error in
            failed = error != nil
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return failed ? 1 : 0
    }
}
