import ArgumentParser
import Foundation
import SimmerCore

/// `simmer run -- <cmd>`: awake exactly while the command runs, released on
/// ANY exit. Deliberately NOT one long claim: an initial chunk
/// (SIMMER_RUN_CHUNK, default 45m) that this process renews every
/// SIMMER_RUN_INTERVAL (default 20m) while the command is alive. If the runner
/// is SIGKILLed — the one exit nothing can catch — the claim still expires
/// within one chunk, self-revoking by construction.
///
/// The renewer is a thread INSIDE this process, which lives for the run
/// anyway. v1 spawns nothing detached — the spike's nohup'd second clock is
/// how it leaked 222 orphans (LEARNINGS.md).
struct RunCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Stay awake exactly as long as a command runs. Never kills the command.")

    @Option(name: .customLong("max"),
            help: "Hard cap on awake time. Reached: the claim lapses, the command keeps running.")
    var max: String?

    @Flag(name: [.customShort("f"), .customLong("force")], help: .hidden)
    var force = false

    @OptionGroup var common: CommonOptions

    @Argument(parsing: .postTerminator, help: "The command, after --.")
    var command: [String] = []

    func run() throws {
        let env = Runtime.environment()
        guard !command.isEmpty else {
            Runtime.deliver(.failure("run what? simmer run -- <command...>"))
        }
        guard let chunk = env.runChunkSeconds else {
            Runtime.deliver(.failure("SIMMER_RUN_CHUNK: did not understand the duration"))
        }
        guard let interval = env.runIntervalSeconds else {
            Runtime.deliver(.failure("SIMMER_RUN_INTERVAL: did not understand the duration"))
        }
        var maxSeconds = 0
        if let max {
            guard let parsed = Durations.parse(max) else {
                Runtime.deliver(.failure("did not understand the duration: \(max)"))
            }
            maxSeconds = parsed
        }

        // The owner is `run:<pid>` — the whole ownership story: two concurrent
        // runs are two claims that cannot see each other.
        let owner = "run:\(getpid())"
        let start = env.now()
        let budgetEpoch = maxSeconds > 0 ? start + maxSeconds : 0
        let first = (budgetEpoch != 0 && maxSeconds < chunk) ? maxSeconds : chunk
        let reason = common.reason ?? URL(fileURLWithPath: command[0]).lastPathComponent

        // Through Commands.claim, not a private path: the battery floor and
        // the cap apply unchanged.
        let ctx = Runtime.context(ownerFlag: owner)
        let takeOutcome = Commands.claim(
            ClaimInput(durationText: "\(first)s", reason: reason, force: force),
            ctx: ctx)
        Runtime.emit(takeOutcome)
        if takeOutcome.exit != 0 { throw ExitCode(takeOutcome.exit) }

        let coordinator = RunCoordinator(owner: owner, chunk: chunk,
                                         interval: interval, budgetEpoch: budgetEpoch)
        coordinator.startRenewer()
        coordinator.installSignalHandlers()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = command
        do {
            try child.run()
        } catch {
            coordinator.cleanup()
            Runtime.deliver(.failure("could not run \(command[0]): \(error.localizedDescription)", exit: 127))
        }
        child.waitUntilExit()
        coordinator.cleanup()

        // The command's exit code is our exit code, untouched.
        if child.terminationReason == .uncaughtSignal {
            throw ExitCode(128 + child.terminationStatus)
        }
        throw ExitCode(child.terminationStatus)
    }
}

/// Owns the renewer thread, the signal handlers and the one idempotent
/// cleanup. Cleanup releases only what is still ours: if the command outlived
/// the claim (--max reached, or the guard retired it) there is nothing of ours
/// to hand back — and the command is NEVER killed. Stopping work is not
/// simmer's decision.
final class RunCoordinator {
    private let owner: String
    private let chunk: Int
    private let interval: Int
    private let budgetEpoch: Int
    private let done = NSLock()
    private var finished = false
    private var signalSources: [DispatchSourceSignal] = []

    init(owner: String, chunk: Int, interval: Int, budgetEpoch: Int) {
        self.owner = owner
        self.chunk = chunk
        self.interval = interval
        self.budgetEpoch = budgetEpoch
    }

    func startRenewer() {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: TimeInterval(interval))
                done.lock()
                let stop = finished
                done.unlock()
                if stop { return }

                let ctx = Runtime.context(ownerFlag: owner)
                // The guard may have retired us — deadline, floor, charger,
                // heat. Writing again here would resurrect a claim the guard
                // deliberately ended.
                guard var claim = ctx.ledger.claim(owner: owner) else { return }
                if budgetEpoch != 0 && ctx.now >= budgetEpoch {
                    // --max reached: the claim lapses, the command does NOT.
                    ctx.ledger.log("run: --max budget exhausted, no longer renewing (\(claim.reason))",
                                   now: ctx.now)
                    Notify.post(NotificationRequest(
                        title: "☕ run budget exhausted",
                        subtitle: "sleep re-allowed, command still running",
                        body: claim.reason), env: Runtime.environment())
                    return
                }
                var target = ctx.now + chunk
                if budgetEpoch != 0 && target > budgetEpoch { target = budgetEpoch }
                // The human cap outranks a renewal just as it outranks a claim.
                if let cap = ctx.ledger.readCap(), target > cap.until { target = cap.until }
                if target > claim.until {
                    claim.until = target
                    claim.warned = false
                    ctx.ledger.write(claim)
                    ctx.ledger.log("run: renewed until \(Formats.hhmm(target))", now: ctx.now)
                }
            }
        }
        thread.name = "simmer-run-renewer"
        thread.start()
    }

    /// INT/TERM/HUP: release the claim and exit 128+sig. The child is left
    /// alone — a ctrl-C reaches it through the process group on its own terms,
    /// and a targeted kill of the runner must not become a kill of the work.
    func installSignalHandlers() {
        for (sig, code) in [(SIGHUP, 129), (SIGINT, 130), (SIGTERM, 143)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [self] in
                cleanup()
                exit(Int32(code))
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func cleanup() {
        done.lock()
        let already = finished
        finished = true
        done.unlock()
        guard !already else { return }
        let ctx = Runtime.context(ownerFlag: owner)
        if let claim = ctx.ledger.claim(owner: owner) {
            ctx.ledger.retire(claim, why: "run finished", now: ctx.now)
            let (_, outcome) = Engine.settle(ctx: ctx, why: "run finished")
            Runtime.emit(outcome)
        }
    }
}
