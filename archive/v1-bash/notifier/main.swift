// simmer's notifier: the app bundle whose only job is to own a notification
// identity, so banners carry simmer's name and icon.
//
// Why this exists at all: macOS attributes a notification to the BUNDLE that
// posts it, and silently drops banners from identities it does not recognise.
// A bare binary (this file compiled without the bundle) is such an identity.
// An installed, LaunchServices-registered, ad-hoc-signed bundle is not: macOS
// shows a one-time permission banner -- with this bundle's own icon -- and after
// one click on Allow, posts display normally. No certificate, no Apple account.
// The full recipe and its traps: docs/V2-BRIEF.md in the simmer repo.
//
// Usage:
//   simmer-notify <title> [subtitle] [body]     post one notification
//   simmer-notify --status                      print authorization state
//
// Exit codes (bin/simmer falls back to osascript on anything non-zero):
//   0  posted, or --status printed
//   2  permission not decided yet -- the request banner was just triggered
//   3  denied by the user

import Foundation
import UserNotifications

let args = CommandLine.arguments
let centre = UNUserNotificationCenter.current()
let done = DispatchSemaphore(value: 0)

func settingsStatus() -> UNAuthorizationStatus {
    var status: UNAuthorizationStatus = .notDetermined
    let sem = DispatchSemaphore(value: 0)
    centre.getNotificationSettings { s in status = s.authorizationStatus; sem.signal() }
    _ = sem.wait(timeout: .now() + 5)
    return status
}

if args.count > 1 && args[1] == "--status" {
    switch settingsStatus() {
    case .authorized, .provisional: print("authorized"); exit(0)
    case .denied:                   print("denied"); exit(3)
    default:                        print("notDetermined"); exit(2)
    }
}

let title    = args.count > 1 ? args[1] : "simmer"
let subtitle = args.count > 2 ? args[2] : ""
let body     = args.count > 3 ? args[3] : ""

switch settingsStatus() {
case .denied:
    FileHandle.standardError.write("denied -- System Settings > Notifications > Simmer\n".data(using: .utf8)!)
    exit(3)
case .authorized, .provisional:
    let content = UNMutableNotificationContent()
    content.title = title
    if !subtitle.isEmpty { content.subtitle = subtitle }
    if !body.isEmpty { content.body = body }
    centre.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { err in
        if let err = err { FileHandle.standardError.write("\(err)\n".data(using: .utf8)!) }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 5)
    exit(0)
default:
    // Not decided yet. Ask -- macOS renders the request as a banner carrying our
    // icon -- and stay alive long enough for the flow to complete. Report 2 so
    // the caller can fall back for THIS message; the next one will find
    // .authorized if the user clicked Allow.
    centre.requestAuthorization(options: [.alert, .sound]) { _, _ in done.signal() }
    _ = done.wait(timeout: .now() + 25)
    exit(2)
}
