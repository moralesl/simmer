import ArgumentParser
import Foundation
import SimmerCore

/// `simmer update` — reports, and prints the command. It never runs it.
///
/// Exit 0 whenever the check completed, whether or not there is something
/// newer; 1 only when it could not tell. A newer release existing is an
/// answer, not a failure, and a caller that wants to branch on it reads
/// `update_available` from `--json` rather than a second exit code — the same
/// reading that keeps "out of date" out of `doctor`'s red rows.
struct UpdateCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Is there a newer simmer? Prints the command that installs it — never runs it.")

    @Flag(name: .customLong("cached"),
          help: "Report the last check instead of making a new one. Never touches the network.")
    var cached = false

    @OptionGroup var common: CommonOptions

    func run() throws {
        let env = Runtime.environment()
        // `binPath` rather than the raw executable path, so the suite can
        // point provenance at a fixture — and it is seam-gated, so on a real
        // install it IS the running binary (SimmerEnvironment.binPath).
        let install = Install.detect(executablePath: env.binPath)
        let report = UpdateCommand.check(
            now: env.now(),
            installed: Runtime.version,
            install: install,
            appVersion: install.bundleVersion(),
            ledger: Ledger(stateDir: env.stateDir),
            source: env.makeReleaseSource(),
            cached: cached,
            seamed: env.isSeamed)

        Runtime.deliver(common.json
            ? UpdateCommand.jsonOutcome(report, seamed: env.isSeamed)
            : UpdateCommand.humanOutcome(report))
    }
}
