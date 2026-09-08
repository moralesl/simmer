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

    /// Whether the checkout a bundle was installed from is in a state simmer
    /// may pull. Behind the same seam the CLI uses, so the menu's "Install
    /// update" item and `simmer update --apply` cannot disagree about which
    /// installs they can do.
    private func checkoutState(_ path: String) -> UpdateCommand.CheckoutState? {
        environment.makeCheckoutProbe().state(of: path)
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
        let install = Install.detect(executablePath: environment.binPath,
                                     home: environment.homeDirectory)
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
            // `writtenBy:` and not just freshness: a record the previous
            // version left behind is a day's silence on a Mac that has just
            // been updated, and the first thing the new binary should do is
            // ask the question again under its own version.
            if let record = ledger.readUpdateRecord(writtenBy: AppState.version),
               record.isFresh(now: environment.now()) {
                return
            }
        }
        let install = Install.detect(executablePath: environment.binPath,
                                     home: environment.homeDirectory)
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
                // One banner per new version, whoever's check found it. A
                // check somebody asked for answers through its own banner
                // (`finished`), so this records the version and posts nothing:
                // tomorrow's background check must not repeat what they read
                // just now. That is also why the recording happens on both
                // paths and the posting on only one.
                let banner = self.recordUpdateAnnouncement(report, ledger: ledger)

                // Only the BACKGROUND pass may install unattended. `force` is
                // a person who just clicked "Check for Updates…", and they get
                // the report and the button — installing under a click that
                // asked a question would be the surprise this whole feature is
                // built to avoid.
                let installing = !force && self.considerUnattendedUpdate(report)

                // "One banner per new version" is why the availability banner
                // is dropped when the install is already starting: the update
                // path posts its own two about that same version ("Updating
                // simmer…", then the completion banner through the spool), and
                // a third saying it is available would be the repetition that
                // rule exists to prevent. The announcement is still RECORDED
                // above, so nothing announces it again tomorrow either.
                if !force, !installing, let banner { Notifier.shared.post([banner]) }
                finished?(report)
                NotificationCenter.default.post(name: .simmerStateChanged, object: nil)
            }
        }
    }

    /// Marks this check's version as announced and hands back the banner for
    /// it, or nil when it is not news. The decision is
    /// `UpdateCommand.announcement`; all this adds is the disk.
    private func recordUpdateAnnouncement(_ report: UpdateCommand.Report,
                                          ledger: Ledger) -> NotificationRequest? {
        guard let announcement = UpdateCommand.announcement(
            report, lastAnnounced: ledger.readAnnouncedUpdate(),
            seamed: environment.isSeamed) else { return nil }
        ledger.writeAnnouncedUpdate(announcement.announced, now: environment.now())
        return announcement.notification
    }

    /// The unattended half: the daily check found something — may it install it?
    ///
    /// Every part of that question is answered in the core by
    /// `AutoUpdate.decide`, and this obeys the answer. `Aggregate.compute` is
    /// what says whether a claim is live, via `context()` — never the claims
    /// directory, because a surface that reads the ledger itself becomes a
    /// second implementation of the aggregate and the two disagree the first
    /// time cap clipping changes (AGENTS.md, iron rules).
    ///
    /// A release skipped because a claim was live is picked up by the NEXT
    /// daily check, not by the claim ending. That is deliberately simple: an
    /// update that starts compiling the moment someone's overnight job hands
    /// the lid back is an update nobody is expecting, and a day's delay on a
    /// feature that exists for a Mac nobody opens costs nothing.
    ///
    /// Returns whether an install was started, because the caller has a banner
    /// to suppress when one was.
    @discardableResult
    private func considerUnattendedUpdate(_ report: UpdateCommand.Report) -> Bool {
        let ctx = context()
        let decision = AutoUpdate.decide(
            enabled: ctx.ledger.autoUpdateEnabled,
            report: report,
            aggregate: ctx.aggregate(),
            plan: UpdateCommand.applyPlan(
                for: report, exists: { FileManager.default.fileExists(atPath: $0) },
                checkoutState: checkoutState),
            alreadyTried: ctx.ledger.readAttemptedUpdate())
        switch decision {
        case .apply:
            // Recorded BEFORE the hand-off, because the hand-off ends this
            // process: `make install` quits Simmer.app, so there is nothing
            // here afterwards to write down what was attempted. Still seeing
            // this release tomorrow is what tells the next check the attempt
            // did not land.
            ctx.ledger.writeAttemptedUpdate(report.latest, now: ctx.now)
            // The same hand-off a person's click makes — `simmer update
            // --apply`, one implementation, one set of tests. It posts its own
            // completion banner through the spool, which is what makes the
            // banner survive this app being replaced and relaunched in the
            // middle of it.
            applyUpdate()
            return true
        case .notNow(let why, let sentence):
            // Recorded only where the reason is worth reading later. "It is
            // off" and "nothing is newer" are the ordinary daily answers, and
            // a line a day for each would bury the ones that mean something —
            // which is why a check that could not be made has its own reason
            // rather than being filed under "nothing newer" and never logged.
            switch why {
            case .cannotTell, .alreadyTried, .claimIsLive, .planRefused:
                ctx.ledger.log("unattended update deferred (\(why.rawValue)): \(sentence)",
                               now: ctx.now)
            case .off, .nothingNewer:
                break
            }
            return false
        }
    }

    /// Is there a plan for this install, or only a command to copy.
    func canApplyUpdate(_ report: UpdateCommand.Report) -> Bool {
        if case .run = UpdateCommand.applyPlan(
            for: report, exists: { FileManager.default.fileExists(atPath: $0) },
            checkoutState: checkoutState) { return true }
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
    /// Nothing is waited for. Every banner about this comes from the child
    /// through the spool, and because the spool is a file rather than a
    /// connection, those banners survive the app being replaced and relaunched
    /// in between — which is the whole reason the spool exists.
    ///
    /// What this method says itself is the *record*: one file, written before
    /// the child has done anything, so that the menu tells the truth from the
    /// first time it is opened after the click. That is the channel that
    /// cannot be suppressed (PLATFORM-FACTS.md § Notifications), and it is
    /// re-readable, which a banner is not.
    func applyUpdate() {
        guard !seamActive else { return }
        // What the child is about to install, decided from the same cached
        // report and the same `applyPlan` the menu item's presence was decided
        // from — so the row names the release rather than guessing at one.
        // No plan means the child will refuse, and then nothing is installing:
        // the record is not written at all rather than written and retracted
        // (the refusal reaches the person as the child's own banner).
        let report = cachedUpdateReport()
        var target: String?
        if case .run(let plan) = UpdateCommand.applyPlan(
            for: report, exists: { FileManager.default.fileExists(atPath: $0) },
            checkoutState: checkoutState) { target = plan.target }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: environment.binPath)
        child.arguments = ["update", "--apply", "--owner", "menubar"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice

        let ledger = Ledger(stateDir: environment.stateDir)
        let startedAt = environment.now()
        if let target {
            ledger.writeInstallInProgress(target: target, now: startedAt,
                                         installed: AppState.version)
            NotificationCenter.default.post(name: .simmerStateChanged, object: nil)
        }
        // The child exiting while THIS app is still alive means the update did
        // not get as far as replacing the bundle — a build error, most of all.
        // The child says what went wrong through the spool; this ends the
        // "Installing…" row, which would otherwise sit there claiming an
        // install that stopped minutes ago. On the success path the app is
        // quit before the child exits, so this never runs and the version
        // change is what ends the record instead.
        child.terminationHandler = { _ in
            let ledger = Ledger(stateDir: self.environment.stateDir)
            guard let record = ledger.readInstallInProgress(
                writtenBy: AppState.version, now: self.environment.now()),
                record.startedAt == startedAt else { return }
            ledger.clearInstallInProgress()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .simmerStateChanged, object: nil)
            }
        }

        do {
            try child.run()
        } catch {
            // Nothing was started, so nothing is installing: the record goes
            // before the banner, or the menu keeps a promise the failure has
            // already broken.
            ledger.clearInstallInProgress()
            NotificationCenter.default.post(name: .simmerStateChanged, object: nil)
            Notifier.shared.post([NotificationRequest(
                title: "Could not start the update",
                subtitle: "", body: error.localizedDescription, sound: false)])
            return
        }
    }

    /// The install this Mac has started and not yet seen the end of, for the
    /// menu. Nil unless THIS version wrote it and it is recent enough to be
    /// plausible — `Ledger.readInstallInProgress` decides both.
    func installInProgress() -> String? {
        Ledger(stateDir: environment.stateDir)
            .readInstallInProgress(writtenBy: AppState.version, now: environment.now())?
            .target
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
    /// Something a setup row reports has changed — the notification grant, or
    /// the login-item registration. Posted on transitions only (Notifier), so
    /// an observer may do real work per event.
    static let simmerSetupChanged = Notification.Name("simmerSetupChanged")
}
