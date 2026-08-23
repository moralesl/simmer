import Foundation
import SimmerCore
import SimmerNotifyKit

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
/// Waited on, never detached. The UN glue itself lives in SimmerNotifyKit,
/// shared with the app, and never requests authorization from here.
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

    // The notify-post subcommand's engine — this process IS inside the bundle
    // when these run, or BundleNotifier refuses.

    static func authorizationStatus() -> String {
        BundleNotifier.authorizationStatus()
    }

    static func postAsBundle(title: String, subtitle: String, body: String, sound: Bool) -> Int32 {
        guard BundleNotifier.available else {
            FileHandle.standardError.write(Data("simmer: notify-post needs to run from inside Simmer.app\n".utf8))
            return 1
        }
        return BundleNotifier.post(NotificationRequest(title: title, subtitle: subtitle,
                                                       body: body, sound: sound))
    }
}
