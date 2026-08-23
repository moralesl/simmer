import AppKit
import Foundation
import IOKit.ps
import SimmerCore

/// The event-driven half of the guard: lid (via sleep/wake), power source
/// changes, thermal state. Each one fires the same idempotent tick() the
/// LaunchAgent runs every 30 seconds — instant response, with the launchd
/// backstop for when this process is not running (BRIEF.md: both ways).
final class PowerEvents {
    static let shared = PowerEvents()
    private var powerSourceRunLoopSource: CFRunLoopSource?

    func setUp() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                PowerEvents.fireTick()
            }
        }

        // Thermal: the one condition that ends every claim at once.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { _ in
            PowerEvents.fireTick()
        }

        // Charger in/out and battery level — the floor, --require-ac and the
        // pre-floor warning all key off this.
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async { PowerEvents.fireTick() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, nil)?
            .takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = source
        }
    }

    static func fireTick() {
        AppState.shared.tick()
        NotificationCenter.default.post(name: .simmerStateChanged, object: nil)
    }
}
