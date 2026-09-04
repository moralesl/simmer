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

        // `binPath` rather than the raw executable path, so the suite can
        // point provenance at a fixture — and it is seam-gated, so on a real
        // install it IS the running binary (SimmerEnvironment.binPath).
        let install = Install.detect(executablePath: env.binPath)
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
        switch UpdateCommand.applyPlan(for: report, home: env.homeDirectory, exists: exists) {
        case .nothingToDo(let sentence):
            var outcome = Outcome()
            outcome.stdout = common.json
                ? [UpdateCommand.applyJSON(report, seamed: env.isSeamed, applied: false,
                                           plan: nil, error: nil).serialized()]
                : ["✅ \(sentence)"]
            Runtime.deliver(outcome)

        case .refused(let why):
            Runtime.deliver(common.json
                ? {
                    var outcome = Outcome()
                    outcome.exit = 1
                    outcome.stdout = [UpdateCommand.applyJSON(
                        report, seamed: env.isSeamed, applied: false,
                        plan: nil, error: why).serialized()]
                    return outcome
                }()
                : Outcome.failure(why))

        case .run(let plan):
            // Whether to bring the app back afterwards is decided BEFORE the
            // first step: `make install` quits it, so asking later would
            // always answer no and the menu bar would silently not come back.
            let appWasRunning = ledger.readAppStatus()?.heartbeatIsFresh(now: env.now()) == true

            if !common.json {
                for line in UpdateCommand.applyPreamble(plan, installed: report.installed) {
                    print(line)
                }
            }
            for step in plan.steps {
                let result = Runtime.execute(step, recordTo: env.applyRecordFile)
                guard result.ok else {
                    let failure = UpdateCommand.applyFailed(step: step, detail: result.detail)
                    if common.json {
                        var outcome = failure
                        outcome.stdout = [UpdateCommand.applyJSON(
                            report, seamed: env.isSeamed, applied: false, plan: plan,
                            error: "\(step.described): \(result.detail)").serialized()]
                        outcome.stderr = []
                        Runtime.deliver(outcome)
                    }
                    Runtime.deliver(failure)
                }
            }

            var reopened = false
            if appWasRunning, let bundle = plan.reopenBundle {
                reopened = Runtime.execute(
                    .init(executable: "/usr/bin/open", arguments: [bundle]),
                    recordTo: env.applyRecordFile).ok
            }

            var outcome = UpdateCommand.applied(plan, reopened: reopened)
            if common.json {
                outcome.stdout = [UpdateCommand.applyJSON(
                    report, seamed: env.isSeamed, applied: true, plan: plan,
                    error: nil).serialized()]
            }
            Runtime.deliver(outcome)
        }
    }
}
