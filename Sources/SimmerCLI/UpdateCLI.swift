import ArgumentParser
import Foundation
import SimmerCore

/// `simmer update` — reports, and prints the command. `--apply` runs it.
///
/// Exit 0 whenever the check completed, whether or not there is something
/// newer; 1 only when it could not tell. A newer release existing is an
/// answer, not a failure, and a caller that wants to branch on it reads
/// `update_available` from `--json` rather than a second exit code — the same
/// reading that keeps "out of date" out of `doctor`'s red rows.
///
/// With `--apply` the same 0/1 split holds for a different question: 0 means
/// there is nothing left to do — it was installed, or it already was — and 1
/// means it could not be done, with the reason naming the way that works.
struct UpdateCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Is there a newer simmer? Prints the command that installs it; --apply runs it.")

    @Flag(name: .customLong("cached"),
          help: "Report the last check instead of making a new one. Never touches the network.")
    var cached = false

    @Flag(name: .customLong("apply"),
          help: "Install it, instead of printing the command. Needs no password.")
    var apply = false

    // Taken as text and validated below, like `--min-battery` and
    // `budget --need`: as an enum, ArgumentParser diagnoses a bad value in its
    // own voice, names the internal `simmer update` spelling in a usage block,
    // and writes nothing to stdout — so a `--json` caller gets an empty stream
    // instead of the contracted refusal object (AGENTS.md, iron rules).
    @Option(name: .customLong("auto"),
            help: "Unattended installs: on | off | status. Off by default.")
    var auto: String?

    @OptionGroup var common: CommonOptions

    func run() throws {
        let env = Runtime.environment()

        // Honoured or refused, never accepted and dropped. Applying what a
        // cached answer said could install a release that has since been
        // pulled, and the flag pair reads as though it would be fast rather
        // than stale — so it is refused instead of quietly resolved.
        if apply && cached {
            Runtime.deliver(.failure(
                "--apply always checks first, so it cannot be combined with --cached",
                json: common.json))
        }

        // `--auto` is a setting, not a question about a release: it makes no
        // request and installs nothing, so pairing it with either of the two
        // flags that do would leave one of them silently dropped.
        if let auto {
            if apply || cached {
                Runtime.deliver(.failure(
                    "--auto sets whether updates install themselves; it cannot be combined with "
                        + (apply ? "--apply" : "--cached"),
                    json: common.json))
            }
            deliverAuto(auto, env: env)
        }

        // `binPath` rather than the raw executable path, so the suite can
        // point provenance at a fixture — and it is seam-gated, so on a real
        // install it IS the running binary (SimmerEnvironment.binPath).
        let install = Install.detect(executablePath: env.binPath, home: env.homeDirectory)
        let ledger = Ledger(stateDir: env.stateDir)
        let report = UpdateCommand.check(
            now: env.now(),
            installed: Runtime.version,
            install: install,
            appVersion: install.bundleVersion(),
            ledger: ledger,
            source: env.makeReleaseSource(),
            cached: cached,
            seamed: env.isSeamed)

        guard apply else {
            Runtime.deliver(common.json
                ? UpdateCommand.jsonOutcome(report, seamed: env.isSeamed)
                : UpdateCommand.humanOutcome(report))
        }

        let exists = { FileManager.default.fileExists(atPath: $0) }
        let answer = { (result: SimmerCore.UpdateCommand.ApplyResult) -> Never in
            // Do not re-inline this. Assembling the Outcome here instead —
            // which is what these four endings used to do — is what the
            // RELEASE binary silently lost: one line where the CLI built it,
            // an empty array where `Runtime.emit` read it one call later,
            // exit code intact, on both supported macOS versions.
            // CHANGELOG.md, Unreleased → Fixed has the observation; why an
            // optimised build drops it is not pinned, so `make test-release`
            // is the lane that would catch it coming back.
            Runtime.deliver(UpdateCommand.applyOutcome(
                result, report: report, seamed: env.isSeamed, json: common.json))
        }

        let probe = env.makeCheckoutProbe()
        switch UpdateCommand.applyPlan(for: report, exists: exists,
                                       checkoutState: { probe.state(of: $0) }) {
        case .nothingToDo(let sentence):
            answer(.nothingToDo(sentence))

        case .refused(let why):
            answer(.refused(why))

        case .run(let plan):
            // Whether to bring the app back afterwards is decided BEFORE the
            // first step: `make install` quits it, so asking later would
            // always answer no and the menu bar would silently not come back.
            let appWasRunning = ledger.readAppStatus()?.heartbeatIsFresh(now: env.now()) == true

            if !common.json {
                // Said now, not carried in the Outcome: this is what is about
                // to happen, and `make install` takes a minute or two. Through
                // `Runtime.say`, which flushes — otherwise a failure sentence
                // written straight to stderr overtakes it in any redirect.
                Runtime.say(UpdateCommand.applyPreamble(plan, installed: report.installed))
            }
            for step in plan.steps {
                let result = Runtime.execute(step, recordTo: env.applyRecordFile,
                                             failing: env.applyFailurePhase)
                guard result.ok else {
                    answer(.failed(step: step, detail: result.detail, plan: plan))
                }
            }

            var reopened = false
            var relaunchFailure: String?
            if appWasRunning, let bundle = plan.reopenBundle {
                let result = Runtime.execute(UpdateCommand.reopenStep(bundle: bundle),
                                             recordTo: env.applyRecordFile,
                                             failing: env.applyFailurePhase)
                reopened = result.ok
                // Said, not swallowed. Without this the only sign is the
                // absence of "· Simmer.app relaunched" from a success line —
                // which nobody reads as "your menu bar is gone". The exit code
                // and `applied` stay as they are: the update landed.
                if !result.ok { relaunchFailure = result.detail }
            }
            answer(.installed(plan: plan, reopened: reopened,
                              relaunchFailure: relaunchFailure))
        }
    }

    /// `--auto on|off|status`. Reads and writes one marker file and answers;
    /// it never checks for a release, which is what keeps `--auto status`
    /// answerable on a train.
    ///
    /// The decision itself belongs to `AutoUpdate` in the core and is made by
    /// the app on its daily check — this only records the person's answer.
    private func deliverAuto(_ value: String, env: SimmerEnvironment) -> Never {
        let ledger = Ledger(stateDir: env.stateDir)
        var enabled = ledger.autoUpdateEnabled
        var changed = false
        switch value {
        case "on", "off":
            let wanted = value == "on"
            changed = wanted != enabled
            if changed { ledger.setAutoUpdate(enabled: wanted) }
            enabled = wanted
        case "status":
            break
        default:
            Runtime.deliver(.failure(
                "--auto takes on, off or status — not '\(value)'", json: common.json))
        }

        // Both halves, because unattended installs ride on the once-a-day
        // check: with the check off this switch is one that does nothing, and
        // a setting that silently cannot fire is the shape of promise this
        // tool does not make.
        let backgroundChecks = ledger.backgroundUpdateChecksEnabled
            && !env.backgroundUpdateCheckDisabled

        if common.json {
            var outcome = Outcome()
            outcome.stdout = [AutoUpdate.settingJSON(
                enabled: enabled, changed: changed,
                backgroundChecksEnabled: backgroundChecks,
                seamed: env.isSeamed).serialized()]
            Runtime.deliver(outcome)
        }
        Runtime.deliver(AutoUpdate.settingOutcome(
            enabled: enabled, changed: changed, backgroundChecksEnabled: backgroundChecks))
    }
}
