import Foundation
import SimmerCore

/// The CLI boundary: resolves the environment once, builds a Context, and
/// renders an Outcome — print, post, exit. Thin on purpose (AGENTS.md,
/// iron rules — SimmerCore stays pure and the CLI is a renderer over it):
/// everything it can do, SimmerCore does, so the app and the CLI cannot
/// disagree.
enum Runtime {
    static let version = SimmerVersion.string
    static let guardLabel = "io.github.moralesl.simmer.guard"

    static func environment() -> SimmerEnvironment {
        return SimmerEnvironment(env: ProcessInfo.processInfo.environment,
                                 isTTY: isatty(0) != 0,
                                 executablePath: executablePath())
    }

    /// Where this process's binary actually is — the path a launcher can exec.
    ///
    /// Ask the kernel, not `argv[0]`. Resolving `argv[0]` against the working
    /// directory is right only when it contains a slash; invoked through PATH
    /// — which is how every installed copy is invoked — `argv[0]` is the bare
    /// word "simmer", and joining that to the cwd produced a path that does
    /// not exist. `simmer render swiftbar` then embedded it in every action it
    /// emitted, so a launcher surface built on it would have had a dead button
    /// for every row.
    ///
    /// `_NSGetExecutablePath` reports the path as exec'd, symlink unresolved,
    /// which is the one to embed: `~/.local/bin/simmer` is stable across
    /// reinstalls where the bundle-internal target it points at is not.
    private static func executablePath() -> String {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            return String(cString: buffer)
        }
        // Only reachable if PATH_MAX was not enough; it says how much it needs.
        buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            return String(cString: buffer)
        }
        // Belt and braces. A wrong answer here is silent — a dead launcher
        // button, not an error — so the fallback resolves argv[0] the only way
        // that can be correct for each of its two shapes rather than assuming
        // one of them.
        let argv0 = CommandLine.arguments.first ?? "simmer"
        if argv0.contains("/") {
            return URL(fileURLWithPath: argv0,
                       relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL.path
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(argv0).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return argv0
    }

    /// One context per invocation. Migration from the format=1 lease happens
    /// here, at the entry point, exactly once per run (CONTRACTS.md § State).
    static func context(ownerFlag: String?, interactive: Bool = true) -> Context {
        let env = environment()
        let (owner, explicit) = env.resolveOwner(flag: ownerFlag)
        let ledger = Ledger(stateDir: env.stateDir)
        let now = env.now()
        ledger.migrateLease(now: now)
        ledger.migrateClaimIds(now: now)
        let power: PowerSystem = interactive
            ? env.makePowerSystem()
            : SeamPowerSystem(env: env.env, allowInteractiveSudo: false)
        return Context(now: now, power: power, ledger: ledger,
                       owner: owner, ownerExplicit: explicit,
                       isHuman: env.callerIsHuman(owner: owner), isTTY: env.isTTY,
                       version: version, binPath: env.binPath, isSeamed: env.isSeamed)
    }

    /// Where a command's human lines go. `stdout` for every subcommand except
    /// `run`, whose stdout belongs to the command it wraps — see RunCLI.
    enum HumanStream { case stdout, stderr }

    /// Print, post, exit. The single exit path for every subcommand.
    static func deliver(_ outcome: Outcome, human: HumanStream = .stdout) -> Never {
        emit(outcome, human: human)
        exit(outcome.exit)
    }

    static func emit(_ outcome: Outcome, human: HumanStream = .stdout) {
        for line in outcome.stdout {
            switch human {
            case .stdout: print(line)
            case .stderr: FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        }
        for line in outcome.stderr {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        // The app is the only poster — macOS binds the notification grant to
        // the executable that asked, and this executable never asks
        // (PLATFORM-FACTS.md). Banners go through the spool; the app drains it
        // within seconds. App not running = no banners, honestly: the menu
        // bar is gone then too.
        guard !outcome.notifications.isEmpty else { return }
        let env = environment()
        guard env.notifyTransport != "none" else { return }
        let ledger = Ledger(stateDir: env.stateDir)
        for notification in outcome.notifications {
            ledger.enqueueNotification(notification, now: env.now())
        }
    }
}
