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

        switch UpdateCommand.applyPlan(for: report, home: env.homeDirectory, exists: exists) {
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
                for line in UpdateCommand.applyPreamble(plan, installed: report.installed) {
                    print(line)
                }
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
}
