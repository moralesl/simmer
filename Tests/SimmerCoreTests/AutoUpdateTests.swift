import Foundation
import Testing

@testable import SimmerCore

/// The apply-now decision: every one of its four reasons, and the state file
/// behind it.
///
/// This is the whole safety argument for unattended installs, so it is tested
/// where nothing can be installed — a pure function over a report, an
/// aggregate and a plan.
@Suite struct AutoUpdateDecisionTests {
    private func ledger() -> Ledger {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-auto-\(UUID().uuidString)")
        return Ledger(stateDir: dir)
    }

    /// A bundle install with the installer's checkout in place — the one
    /// provenance that has a runnable plan, and the case unattended installs
    /// exist for.
    private let bundle = Install.detect(
        executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
        exists: { _ in false })

    private func report(installed: String = "0.2.0", latest: String = "v0.3.0",
                        ledger: Ledger? = nil) -> UpdateCommand.Report {
        UpdateCommand.check(
            now: 1_800_000_000, installed: installed, install: bundle, appVersion: nil,
            ledger: ledger ?? self.ledger(), source: FakeReleaseSource(value: latest),
            cached: false, seamed: true)
    }

    private func plan(_ report: UpdateCommand.Report) -> UpdateCommand.ApplyDecision {
        // Everything under the installer checkout exists; nothing else does,
        // so this is the bundle path with something to build from.
        UpdateCommand.applyPlan(for: report, home: "/Users/nobody",
                                exists: { $0.contains(UpdateCommand.installerCheckout) })
    }

    private func idle() -> Aggregate {
        Aggregate.compute(claims: [], cap: nil, now: 1_800_000_000, sleepDisabled: false)
    }

    private func holding(owner: String = "agent:evals", until: Int = 1_800_003_600) -> Aggregate {
        Aggregate.compute(claims: [Claim(owner: owner, until: until,
                                         started: 1_800_000_000, reason: "eval batch")],
                          cap: nil, now: 1_800_000_000, sleepDisabled: false)
    }

    /// Off is the default, and the default is the answer with no state file at
    /// all — not a value written at install time that could be got wrong.
    @Test func offIsTheDefaultAndTheReasonIsNamed() {
        let led = ledger()
        #expect(!led.autoUpdateEnabled)

        let report = report(ledger: led)
        let decision = AutoUpdate.decide(enabled: led.autoUpdateEnabled, report: report,
                                         aggregate: idle(), plan: plan(report))
        #expect(decision == .notNow(.off, "unattended updates are off — turn them on with simmer update --auto on"))
    }

    @Test func theSwitchIsAFileAndItGoesBothWays() {
        let led = ledger()
        led.setAutoUpdate(enabled: true)
        #expect(led.autoUpdateEnabled)
        #expect(FileManager.default.fileExists(atPath: led.autoUpdateOnFile.path))

        led.setAutoUpdate(enabled: false)
        #expect(!led.autoUpdateEnabled)
        #expect(!FileManager.default.fileExists(atPath: led.autoUpdateOnFile.path))

        // Turning it off twice is not an error: `doctor` and the setup window
        // both write the state they were shown, not a delta.
        led.setAutoUpdate(enabled: false)
        #expect(!led.autoUpdateEnabled)
    }

    /// On, nothing held, a plan — the only combination that installs anything.
    @Test func onWithNothingHeldApplies() {
        let report = report()
        let decision = AutoUpdate.decide(enabled: true, report: report,
                                         aggregate: idle(), plan: plan(report))
        guard case .apply(let applied) = decision else {
            #expect(Bool(false), "did not apply: \(decision)")
            return
        }
        #expect(applied.target == "0.3.0")
        #expect(applied.steps.count == 3)
    }

    @Test func nothingNewerIsNotAnInstall() {
        for latest in ["v0.2.0", "v0.1.0"] {
            let report = report(latest: latest)
            let decision = AutoUpdate.decide(enabled: true, report: report,
                                             aggregate: idle(), plan: plan(report))
            guard case .notNow(.nothingNewer, _) = decision else {
                #expect(Bool(false), "\(latest) was treated as installable: \(decision)")
                continue
            }
        }
    }

    /// A check that could not be made is not a licence to install one — the
    /// same reading `--apply` already takes, arriving here as `nothingNewer`
    /// because there is nothing known to be newer.
    @Test func aFailedCheckInstallsNothing() {
        let report = report(latest: "error")
        let decision = AutoUpdate.decide(enabled: true, report: report,
                                         aggregate: idle(), plan: plan(report))
        guard case .notNow(.nothingNewer, let why) = decision else {
            #expect(Bool(false), "\(decision)")
            return
        }
        #expect(why.contains("cannot tell"))
    }

    /// The property the whole feature rests on: an update never starts while
    /// somebody is holding the lid open. It quits the app, replaces the
    /// guard's binary and compiles for a minute or two.
    @Test func aLiveClaimDefersIt() {
        let report = report()
        let decision = AutoUpdate.decide(enabled: true, report: report,
                                         aggregate: holding(), plan: plan(report))
        guard case .notNow(.claimIsLive, let why) = decision else {
            #expect(Bool(false), "an update was applied over a live claim: \(decision)")
            return
        }
        // Named and counted down, because "3 claims" tells a reader nothing
        // about whether to wait.
        #expect(why.contains("agent:evals"))
        #expect(why.contains("next daily check"))
    }

    /// An open-ended claim has no deadline and is still a claim. `count`, not
    /// `until`, is the question — the same distinction CONTRACTS.md draws for
    /// `budget`'s three readings.
    @Test func anOpenEndedClaimDefersItToo() {
        let report = report()
        let forever = Aggregate.compute(
            claims: [Claim(owner: "terminal", until: 0, started: 1_800_000_000, reason: "overnight")],
            cap: nil, now: 1_800_000_000, sleepDisabled: false)
        #expect(forever.state == .forever)

        let decision = AutoUpdate.decide(enabled: true, report: report,
                                         aggregate: forever, plan: plan(report))
        guard case .notNow(.claimIsLive, _) = decision else {
            #expect(Bool(false), "an open-ended claim did not defer the update: \(decision)")
            return
        }
    }

    /// An orphan — the switch on with nothing claiming it — is not a claim.
    /// The guard is about to hand it back, and nobody's work is behind it.
    @Test func anOrphanIsNotSomebodysWork() {
        let report = report()
        let orphan = Aggregate.compute(claims: [], cap: nil, now: 1_800_000_000,
                                       sleepDisabled: true)
        #expect(orphan.state == .orphan)

        let decision = AutoUpdate.decide(enabled: true, report: report,
                                         aggregate: orphan, plan: plan(report))
        guard case .apply = decision else {
            #expect(Bool(false), "\(decision)")
            return
        }
    }

    /// A developer's own checkout is refused by `applyPlan`, and the
    /// unattended path must carry that refusal rather than re-deciding it.
    @Test func aRefusedPlanIsARefusalHereToo() {
        let checkout = Install.detect(executablePath: "/Users/dev/simmer/.build/debug/simmer",
                                      exists: { $0.contains("/Users/dev/simmer/") })
        #expect(checkout.kind == .checkout)
        let report = UpdateCommand.check(
            now: 1_800_000_000, installed: "0.2.0", install: checkout, appVersion: nil,
            ledger: ledger(), source: FakeReleaseSource(value: "v0.3.0"),
            cached: false, seamed: true)

        let decision = AutoUpdate.decide(
            enabled: true, report: report, aggregate: idle(),
            plan: UpdateCommand.applyPlan(for: report, home: "/Users/dev",
                                          exists: { $0.contains("/Users/dev/simmer/") }))
        guard case .notNow(.planRefused, let why) = decision else {
            #expect(Bool(false), "\(decision)")
            return
        }
        #expect(why.contains("your own checkout"))
    }

    /// The order of the questions is part of the contract: a Mac whose owner
    /// said no is never asked what it is holding, so `off` outranks a live
    /// claim and a failed check alike.
    @Test func offOutranksEveryOtherReason() {
        let report = report(latest: "error")
        let decision = AutoUpdate.decide(enabled: false, report: report,
                                         aggregate: holding(), plan: plan(report))
        guard case .notNow(.off, _) = decision else {
            #expect(Bool(false), "\(decision)")
            return
        }
    }
}

/// What `--auto` says, in both renderings.
@Suite struct AutoUpdateSettingTests {
    @Test func theSwitchSaysWhichWayItIs() {
        let on = AutoUpdate.settingOutcome(enabled: true, changed: true,
                                           backgroundChecksEnabled: true)
        #expect(on.exit == 0)
        #expect(on.stdout.joined().contains("are on"))
        // The refusal condition, stated where the switch is set rather than
        // discovered later by a person wondering why nothing happened.
        #expect(on.stdout.joined().contains("never while a claim is live"))

        let off = AutoUpdate.settingOutcome(enabled: false, changed: true,
                                            backgroundChecksEnabled: true)
        #expect(off.stdout.joined().contains("are off"))
        #expect(!off.stdout.joined().contains("never while a claim is live"))
    }

    /// A setting that cannot fire has to say so. Unattended installs ride on
    /// the once-a-day check, and with that off this is a switch that does
    /// nothing — which is the shape of promise this tool does not make.
    @Test func onWithTheDailyCheckOffAdmitsItCannotFire() {
        let stranded = AutoUpdate.settingOutcome(enabled: true, changed: true,
                                                 backgroundChecksEnabled: false)
        #expect(stranded.stdout.joined().contains("once-a-day check is off"))
        #expect(stranded.exit == 0, "it is a warning about a setting, not a failed command")

        let fine = AutoUpdate.settingOutcome(enabled: true, changed: true,
                                             backgroundChecksEnabled: true)
        #expect(!fine.stdout.joined().contains("once-a-day check is off"))
    }

    /// Yes/no means a JSON boolean, asserted against the raw text:
    /// `JSONSerialization` bridges `0`/`1` to `Bool` and would miss it.
    @Test func theMachineAnswerIsBooleansAndADirection() {
        let on = AutoUpdate.settingJSON(enabled: true, changed: true,
                                        backgroundChecksEnabled: true, seamed: true).serialized()
        #expect(on.contains("\"action\":\"auto_update_on\""))
        #expect(on.contains("\"auto_update\":true"))
        #expect(on.contains("\"background_check\":true"))

        let off = AutoUpdate.settingJSON(enabled: false, changed: true,
                                         backgroundChecksEnabled: false, seamed: false).serialized()
        #expect(off.contains("\"action\":\"auto_update_off\""))
        #expect(off.contains("\"auto_update\":false"))
        #expect(off.contains("\"background_check\":false"))

        // `--auto status` changed nothing, so it reports rather than acts.
        let asked = AutoUpdate.settingJSON(enabled: true, changed: false,
                                           backgroundChecksEnabled: true, seamed: true).serialized()
        #expect(asked.contains("\"action\":\"checked\""))
        #expect(asked.contains("\"auto_update\":true"))
    }
}
