import Foundation
import IOKit.pwr_mgt
import SimmerCore

/// The app's single source of truth: builds contexts the same way the CLI
/// does (same SimmerCore, same seam), runs ticks, and holds the in-process
/// idle-sleep assertion.
final class AppState {
    static let shared = AppState()
    static let version = SimmerVersion.string

    let environment: SimmerEnvironment
    /// True when any SIMMER_FAKE_* power variable is set — then the app must
    /// not touch real power state, including IOKit assertions.
    let seamActive: Bool

    private init() {
        let env = ProcessInfo.processInfo.environment
        // `binPath` is what a launcher would exec, and that is the CLI — never
        // this process. `Bundle.main.executablePath` reads CFBundleExecutable,
        // which is `simmer-app`: the one binary that cannot serve as the CLI.
        // Both ship in Contents/MacOS, so the sibling is the answer.
        let cli = (Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("simmer").path)
            ?? CommandLine.arguments[0]
        environment = SimmerEnvironment(env: env, isTTY: false, executablePath: cli)
        seamActive = env["SIMMER_FAKE_PMSET"] != nil
    }

    /// The menu bar is a human surface — that is the whole point of the owner.
    func context() -> Context {
        let ledger = Ledger(stateDir: environment.stateDir)
        let now = environment.now()
        ledger.migrateLease(now: now)
        return Context(now: now,
                       power: SeamPowerSystem(env: environment.env, allowInteractiveSudo: false),
                       ledger: ledger,
                       owner: "menubar", ownerExplicit: true,
                       isHuman: true, isTTY: false,
                       version: AppState.version,
                       binPath: environment.binPath)
    }

    func aggregate() -> Aggregate { context().aggregate() }

    /// The event-driven half of the guard: same idempotent tick the
    /// LaunchAgent runs, fired instantly on lid/power/thermal events.
    @discardableResult
    func tick() -> Outcome {
        let outcome = Tick.run(ctx: context())
        Notifier.shared.post(outcome.notifications)
        updateAssertions()
        return outcome
    }

    /// Run a core command, post whatever it wants said, refresh the assertion.
    func perform(_ command: (Context) -> Outcome) {
        let outcome = command(context())
        Notifier.shared.post(outcome.notifications)
        updateAssertions()
        NotificationCenter.default.post(name: .simmerStateChanged, object: nil)
    }

    // MARK: the in-process assertion — belt and braces for idle sleep
    //
    // An IOKit assertion cannot hold a closed lid (PLATFORM-FACTS.md closed
    // that negatively); pmset -a disablesleep is the mechanism. This is only
    // the idle-sleep courtesy the spike used a detached caffeinate for — held
    // in-process, it dies with the process, which is the correct lifetime.
    // An orphan is structurally impossible: there is no child to leak.

    private var idleAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    func updateAssertions() {
        guard !seamActive else { return }
        let aggregate = aggregate()
        let wantIdle = aggregate.count > 0
        let wantDisplay = aggregate.live.contains { $0.claim.displayOn }

        if wantIdle && idleAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "simmer: claims live" as CFString, &idleAssertion)
        } else if !wantIdle && idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = 0
        }

        if wantDisplay && displayAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "simmer: --display-on claim live" as CFString, &displayAssertion)
        } else if !wantDisplay && displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }
}

extension Notification.Name {
    static let simmerStateChanged = Notification.Name("simmerStateChanged")
}
