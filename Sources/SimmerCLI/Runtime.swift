import Foundation
import SimmerCore

/// The CLI boundary: resolves the environment once, builds a Context, and
/// renders an Outcome — print, post, exit. Thin on purpose (BRIEF.md):
/// everything it can do, SimmerCore does, so the app and the CLI cannot
/// disagree.
enum Runtime {
    static let version = SimmerVersion.string
    static let guardLabel = "io.github.moralesl.simmer.guard"

    static func environment() -> SimmerEnvironment {
        let argv0 = CommandLine.arguments.first ?? "simmer"
        let executable = URL(fileURLWithPath: argv0,
                             relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
        return SimmerEnvironment(env: ProcessInfo.processInfo.environment,
                                 isTTY: isatty(0) != 0,
                                 executablePath: executable)
    }

    /// One context per invocation. Migration from the format=1 lease happens
    /// here, at the entry point, exactly once per run (CONTRACTS.md § State).
    static func context(ownerFlag: String?, interactive: Bool = true) -> Context {
        let env = environment()
        let (owner, explicit) = env.resolveOwner(flag: ownerFlag)
        let ledger = Ledger(stateDir: env.stateDir)
        let now = env.now()
        ledger.migrateLease(now: now)
        let power: PowerSystem = interactive
            ? env.makePowerSystem()
            : SeamPowerSystem(env: env.env, allowInteractiveSudo: false)
        return Context(now: now, power: power, ledger: ledger,
                       owner: owner, ownerExplicit: explicit,
                       isHuman: env.callerIsHuman(owner: owner), isTTY: env.isTTY,
                       version: version, binPath: env.binPath)
    }

    /// Print, post, exit. The single exit path for every subcommand.
    static func deliver(_ outcome: Outcome) -> Never {
        emit(outcome)
        exit(outcome.exit)
    }

    static func emit(_ outcome: Outcome) {
        for line in outcome.stdout { print(line) }
        for line in outcome.stderr {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        for notification in outcome.notifications {
            Notify.post(notification, env: environment())
        }
    }
}
