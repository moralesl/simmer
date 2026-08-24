import AppKit
import SimmerCore

// Simmer.app: the menu bar, the event-driven half of the guard, and the
// notification identity — merged into one bundle. LSUIElement in
// Info.plist keeps it out of the Dock; the LaunchAgent backstop keeps the
// contract honest when this process is not running.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setUp()
        PowerEvents.shared.setUp()
        statusItem.setUp()
        AppState.shared.updateAssertions()
        // One tick on launch: heals anything a crash or a by-hand pmset left
        // behind, exactly like the LaunchAgent's RunAtLoad.
        AppState.shared.tick()
        // Before showIfNeeded, so the window's login row reflects what just
        // happened rather than the state a second ago.
        //
        // Never under the seam: a sandbox or a throwaway-bundle-id run would
        // otherwise leave a real, persistent login item pointing at a build in
        // a temporary directory — the same reason `updateAssertions` refuses to
        // touch real power state there.
        if !AppState.shared.seamActive {
            LoginItem.registerOnceIfNeeded(stateDir: AppState.shared.environment.stateDir)
        }
        SetupWindow.shared.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Assertions die with the process — the correct lifetime. The switch
        // stays governed by the ledger via the LaunchAgent.
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
