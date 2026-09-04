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
        var env = ProcessInfo.processInfo.environment
        // Launched from the Dock, an app inherits none of the shell's
        // environment — so `make install` bakes the ledger's location into the
        // bundle, the way it bakes it into the LaunchAgent. An explicit
        // XDG_STATE_HOME still wins, which is what keeps the seam working.
        if env["XDG_STATE_HOME"] == nil,
           let baked = Bundle.main.object(forInfoDictionaryKey: "SimmerStateHome") as? String,
           !baked.isEmpty, !baked.hasPrefix("@") {
            env["XDG_STATE_HOME"] = baked
        }
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
        ledger.migrateClaimIds(now: now)
        return Context(now: now,
                       power: SeamPowerSystem(env: environment.env, allowInteractiveSudo: false),
                       ledger: ledger,
                       owner: "menubar", ownerExplicit: true,
                       isHuman: true, isTTY: false,
                       version: AppState.version,
                       binPath: environment.binPath, isSeamed: environment.isSeamed)
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

    // MARK: is there a newer release
    //
    // The app is the only surface that can ask without a person asking, so it
    // is the one that keeps the cache warm — once a day, off the main thread,
    // and never while a SIMMER_FAKE_* is in force. `doctor`, the menu and a
    // launcher row all read what it wrote, so nothing else has to wait on the
    // network to know whether there is an update.

    /// What the last check found. A file read; safe to call per menu open.
    func cachedUpdateReport() -> UpdateCommand.Report {
        let install = Install.detect(executablePath: environment.binPath)
        return UpdateCommand.check(
            now: environment.now(), installed: AppState.version, install: install,
            appVersion: install.bundleVersion(), ledger: context().ledger,
            source: environment.makeReleaseSource(), cached: true,
            seamed: environment.isSeamed)
    }

    /// One outbound request, at most once a day.
    ///
    /// Three separate ways to say no, because this is the only thing simmer
    /// sends anywhere: the seam, the environment (`SIMMER_NO_UPDATE_CHECK=1`)
    /// and the person's own switch in the setup window. `force` is the menu
    /// item — someone asking is not the background check and is not gated by
    /// its schedule, only by the seam.
    func refreshUpdateCheck(force: Bool = false,
                            then finished: ((UpdateCommand.Report) -> Void)? = nil) {
        guard !seamActive else { return }
        let ledger = Ledger(stateDir: environment.stateDir)
        if !force {
            guard !environment.backgroundUpdateCheckDisabled,
                  ledger.backgroundUpdateChecksEnabled else { return }
            if let record = ledger.readUpdateRecord(), record.isFresh(now: environment.now()) {
                return
            }
        }
        let install = Install.detect(executablePath: environment.binPath)
        let source = environment.makeReleaseSource()
        let now = environment.now()
        let version = AppState.version
        let seamed = environment.isSeamed
        // Off the main thread: three seconds of network with the menu open
        // would be three seconds of a beachball on a menu bar item.
        DispatchQueue.global(qos: .utility).async {
            let report = UpdateCommand.check(
                now: now, installed: version, install: install,
                appVersion: install.bundleVersion(), ledger: ledger,
                source: source, cached: false, seamed: seamed)
            DispatchQueue.main.async {
                finished?(report)
                NotificationCenter.default.post(name: .simmerStateChanged, object: nil)
            }
        }
    }

    /// Is there a plan for this install, or only a command to copy.
    func canApplyUpdate(_ report: UpdateCommand.Report) -> Bool {
        if case .run = UpdateCommand.applyPlan(
            for: report, home: environment.homeDirectory,
            exists: { FileManager.default.fileExists(atPath: $0) }) { return true }
        return false
    }

    /// Hand the update to the CLI and get out of its way.
    ///
    /// The work belongs in `simmer update --apply` — one implementation, one
    /// set of tests, the same thing a terminal runs. This process cannot do it
    /// itself for a more basic reason: `make install` quits Simmer.app before
    /// replacing the bundle, so whatever is driving the update has to outlive
    /// being quit. A child process does; this one does not.
    ///
    /// Nothing is waited for. The child posts its own banner through the spool
    /// when it finishes, and because the spool is a file rather than a
    /// connection, that banner survives the app being replaced and relaunched
    /// in between — which is the whole reason the spool exists.
    func applyUpdate() {
        guard !seamActive else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: environment.binPath)
        child.arguments = ["update", "--apply", "--owner", "menubar"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            Notifier.shared.post([NotificationRequest(
                title: "Could not start the update",
                subtitle: "", body: error.localizedDescription, sound: false)])
            return
        }
        // Said now, because a compile takes a minute or two and the next thing
        // that visibly happens is the menu bar disappearing as the bundle is
        // replaced. Without this line that reads as a crash.
        Notifier.shared.post([NotificationRequest(
            title: "Updating simmer…",
            subtitle: "Simmer.app will quit and come back",
            body: "", sound: false)])
    }

    // MARK: the in-process assertion — belt and braces for idle sleep    // MARK: the in-process assertion — belt and braces for idle sleep
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
    /// Something a setup row reports has changed — the notification grant, or
    /// the login-item registration. Posted on transitions only (Notifier), so
    /// an observer may do real work per event.
    static let simmerSetupChanged = Notification.Name("simmerSetupChanged")
}
