import Foundation
import ServiceManagement

/// Opening at login, arranged once at install time rather than left as a
/// button to find.
///
/// Without it a fresh install does not survive a restart: `bootstrap.sh` runs
/// `open Simmer.app`, so the menu bar is there for that session and gone after
/// the next reboot — and with it every banner, because the app is the only
/// poster and spooled entries older than two minutes are dropped as stale
/// (`Ledger.drainNotifications`). The launchd guard still hands the switch
/// back, so nothing dangerous happened; what broke was the README's promise of
/// "a notification five minutes before the end", silently, on a machine whose
/// owner had no reason to suspect it. A silent promise downgrade is the worst
/// kind to ship.
///
/// The setup window's Enable button stays, and stays honest — this only means
/// most people never need to press it.
enum LoginItem {
    /// Registered at most once, ever. `SMAppService` reports `.notRegistered`
    /// both for "never asked" and for "the person turned it off in System
    /// Settings", and those must not be treated alike: re-registering on every
    /// launch would quietly overrule a deliberate opt-out, every launch,
    /// forever. The stamp is what tells the two apart.
    static func registerOnceIfNeeded(stateDir: URL) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard SMAppService.mainApp.status == .notRegistered else { return }

        let stamp = stateDir.appendingPathComponent("login-item.offered")
        guard !FileManager.default.fileExists(atPath: stamp.path) else { return }

        // Stamp BEFORE registering, not after. If registration throws, or the
        // process dies between the two, the failure mode has to be "asked
        // once and it did not take" — which the setup window's row reports and
        // its button fixes. The other order retries on every launch, which is
        // the behaviour this exists to avoid.
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? Data().write(to: stamp)
        try? SMAppService.mainApp.register()
    }

    /// The word `doctor` reports. Spelled out rather than a bool: "off because
    /// nobody asked" and "off because macOS wants the person to approve it in
    /// System Settings" need different advice.
    static var statusWord: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
