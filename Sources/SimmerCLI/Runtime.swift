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
    /// The bundle id `make install` stamps into Info.plist. The guard label is
    /// this plus `.guard`, and the two must not drift — a quit sent to the
    /// wrong id is a quit that silently does nothing.
    static let bundleIdentifier = "io.github.moralesl.simmer"

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

    /// Run one step of an update plan, or record it.
    ///
    /// The only place this binary spawns anything other than `pmset` and a
    /// `run` command, and it is behind `SIMMER_FAKE_APPLY` for the reason
    /// CONTRACTS.md gives: every side effect outside the process has a seam,
    /// not merely the ones that are awkward to test.
    ///
    /// Output is captured rather than inherited. `make install` prints a
    /// dozen lines nobody asked for here, and the part worth showing when it
    /// fails is the tail of stderr, which is what the failure sentence carries.
    static func execute(_ step: SimmerCore.UpdateCommand.ApplyStep,
                        recordTo file: String?) -> (ok: Bool, detail: String) {
        if let file {
            let line = step.described + "\n"
            if let handle = FileHandle(forWritingAtPath: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: file, atomically: true, encoding: .utf8)
            }
            return (true, "recorded")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = step.arguments
        if let cwd = step.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errData, as: UTF8.self)
                .split(separator: "\n").suffix(3).joined(separator: " · ")
            return (false, text.isEmpty ? "exited \(process.terminationStatus)" : text)
        }
        return (true, "")
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

    /// Every line this binary is asked to emit, written straight to a
    /// descriptor — no `print`, no stdio buffer between the string and the
    /// kernel.
    ///
    /// `print` lost a whole line here. On macOS 15 with Swift 6.2.4, the
    /// release build of `update --apply --json` recorded all three plan steps,
    /// exited 0, and produced ZERO bytes on stdout — not even the newline
    /// `print("")` would leave — while the debug build of the same source
    /// printed the object, the human form of the same command printed, and
    /// `update --json` printed. Nine probes cleared every side effect in the
    /// path: the record file, the `FileHandle`, the fd numbers, the plan
    /// itself (the nothing-to-do case, which runs no steps at all, was empty
    /// too), and `status --json`, which carries a `JSONValue.array` like the
    /// object that vanished, was fine. What was left was the two lines below,
    /// and adding *instrumentation* to them made the defect disappear — so
    /// what the compiler did to `emit` is not pinned, and does not need to be.
    ///
    /// What is pinned is the rule: `--json` and the exit codes are API
    /// (AGENTS.md, iron rules), and a contracted surface must not depend on
    /// stdio buffering surviving `exit`, or on an optimiser's view of the
    /// stdlib. `write(2)` in a loop is the shortest path there is between a
    /// String and fd 1, and it is what stderr already used.
    static func emit(_ outcome: Outcome, human: HumanStream = .stdout) {
        for line in outcome.stdout {
            switch human {
            case .stdout: writeLine(line, to: 1)
            case .stderr: writeLine(line, to: 2)
            }
        }
        for line in outcome.stderr {
            writeLine(line, to: 2)
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

    /// One line and its newline, to one descriptor, whatever it takes.
    ///
    /// A short write is legal on any descriptor and routine on a pipe, so the
    /// loop keeps going until every byte is gone; `EINTR` is a retry and not a
    /// failure. If the descriptor is genuinely dead there is nowhere left to
    /// report it, and the exit code the caller chose still stands.
    private static func writeLine(_ line: String, to descriptor: Int32) {
        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes[sent...].withUnsafeBufferPointer {
                write(descriptor, $0.baseAddress, $0.count)
            }
            if written > 0 {
                sent += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
