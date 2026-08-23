import Foundation
import SimmerCore
import UserNotifications

/// Notification routing for the CLI. The preferred channel is simmer's own
/// bundle — the banner carries simmer's name and the pot icon — reached by
/// exec'ing the bundle's own copy of this binary (`notify-post`), which is the
/// spike-verified way to post with the bundle's identity. Waited on, never
/// detached: v1 spawns no children it does not collect.
///
///   SIMMER_NOTIFY=auto       bundle if installed, else osascript
///   SIMMER_NOTIFY=bundle     simmer's own app identity
///   SIMMER_NOTIFY=osascript  posts as Script Editor — always available
///   SIMMER_NOTIFY=say        spoken aloud; no notification system at all
///   SIMMER_NOTIFY=none       silence; the menu bar cannot be suppressed
enum Notify {
    static func post(_ notification: NotificationRequest, env: SimmerEnvironment) {
        switch resolveTransport(env) {
        case .none:
            return
        case .bundle(let binary):
            if postViaBundle(binary, notification) { return }
            postViaOsascript(notification)
        case .osascript:
            postViaOsascript(notification)
        case .say:
            let speakable = notification.title.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : " " }
            _ = Shell.run("/usr/bin/say", ["-v", "Daniel", String(speakable)])
        }
    }

    enum Transport {
        case bundle(String)
        case osascript
        case say
        case none
    }

    static func bundleBinary(env: SimmerEnvironment) -> String {
        env.notifierAppPath + "/Contents/MacOS/simmer"
    }

    static func resolveTransport(_ env: SimmerEnvironment) -> Transport {
        let binary = bundleBinary(env: env)
        switch env.notifyTransport {
        case "none": return .none
        case "bundle": return .bundle(binary)
        case "osascript": return .osascript
        case "say": return .say
        default: // auto
            return FileManager.default.isExecutableFile(atPath: binary)
                ? .bundle(binary) : .osascript
        }
    }

    private static func postViaBundle(_ binary: String, _ n: NotificationRequest) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary) else { return false }
        var args = ["notify-post", n.title, n.subtitle, n.body]
        if !n.sound { args.append("--silent") }
        return Shell.run(binary, args).status == 0
    }

    private static func postViaOsascript(_ n: NotificationRequest) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        var script = "display notification \"\(esc(n.body))\" with title \"\(esc(n.title))\""
        if !n.subtitle.isEmpty { script += " subtitle \"\(esc(n.subtitle))\"" }
        _ = Shell.run("/usr/bin/osascript", ["-e", script])
    }

    // MARK: posting AS the bundle — only meaningful when this binary lives in
    // Contents/MacOS/ of an installed, registered, ad-hoc-signed Simmer.app.

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

    /// Returns 0 on success, non-zero when not (or not yet) authorized — the
    /// caller falls back so the message still lands somewhere. UNErrorDomain
    /// Code=1 while the permission banner is pending means "not YET
    /// authorized" (PLATFORM-FACTS.md), which is also non-zero here.
    static func postAsBundle(title: String, subtitle: String, body: String, sound: Bool) -> Int32 {
        guard Bundle.main.bundleIdentifier != nil else {
            FileHandle.standardError.write(Data("simmer: notify-post needs to run from inside Simmer.app\n".utf8))
            return 1
        }
        let center = UNUserNotificationCenter.current()
        let authSemaphore = DispatchSemaphore(value: 0)
        var granted = false
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            granted = ok
            authSemaphore.signal()
        }
        // Generous: the first-ever call shows the permission banner and waits
        // for the human to click Allow.
        _ = authSemaphore.wait(timeout: .now() + 25)
        guard granted else { return 1 }

        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        if !body.isEmpty { content.body = body }
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        let postSemaphore = DispatchSemaphore(value: 0)
        var failed = false
        center.add(request) { error in
            failed = error != nil
            postSemaphore.signal()
        }
        _ = postSemaphore.wait(timeout: .now() + 10)
        return failed ? 1 : 0
    }
}
