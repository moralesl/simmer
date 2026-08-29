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
/// how it leaked 222 orphans (PLATFORM-FACTS.md).
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
        // `run` is the one verb whose stdout is not its own, so it has no
        // machine answer it could deliver: a JSON object on stdout would land
        // in the middle of the wrapped command's output, which is the thing
        // this file exists to keep clean. Refused with the alternative named,
        // exactly as `notify-test` and `render` are — CONTRACTS.md's --json
        // list never included `run`; the flag was being accepted and dropped
        // anyway, which a caller cannot tell from one that worked.
        common.refuseJSON("run", insteadUse: "simmer status --json in another shell")
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
        let reason = common.reason ?? Self.describe(command)

        // Through Commands.claim, not a private path: the battery floor and
        // the cap apply unchanged.
        let ctx = Runtime.context(ownerFlag: owner)
        let takeOutcome = Commands.claim(
            ClaimInput(durationText: "\(first)s", reason: reason, force: force),
            ctx: ctx)
        // stderr, not stdout. `simmer run -- ./gen.sh > out.json` and
        // `X=$(simmer run -- ./build)` must see exactly what the command
        // wrote and nothing else — `caffeinate`, which this replaces, adds
        // nothing to either stream. Everything simmer says about its own claim
        // is commentary on the run, which is what stderr is for.
        Runtime.emit(takeOutcome, human: .stderr)
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

    /// The whole command, not just the program.
    ///
    /// This was `command[0]`'s last path component, so `simmer run -- npm test`
    /// and `simmer run -- npm run build` both recorded "npm" — and two live
    /// runs showed up in `simmer status` as two identical rows, which is
    /// exactly when the reason is the thing you need. The program name alone is
    /// the least distinguishing part of a command line.
    ///
    /// Bounded, because a reason goes in the menu bar and a claim file: enough
    /// to tell two runs apart, and an ellipsis rather than a wrapped paragraph
    /// when the command is a shell one-liner.
    static func describe(_ command: [String], limit: Int = 60) -> String {
        var parts = command
        parts[0] = URL(fileURLWithPath: parts[0]).lastPathComponent
        let joined = parts.joined(separator: " ")
        guard joined.count > limit else { return joined }
        return joined.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
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
                    var lapsed = Outcome()
                    lapsed.notifications.append(NotificationRequest(
                        title: "☕ run budget exhausted",
                        subtitle: "sleep re-allowed, command still running",
                        body: claim.reason))
                    Runtime.emit(lapsed, human: .stderr)
                    return
                }
                var target = ctx.now + chunk
                if budgetEpoch != 0 && target > budgetEpoch { target = budgetEpoch }
                // The human cap outranks a renewal just as it outranks a claim.
                if let cap = ctx.ledger.readCap(now: ctx.now), target > cap.until { target = cap.until }
                if target > claim.until {
                    claim.until = target
                    // A renewal inside the warning window means --max or the
                    // cap is about to end the claim while the command runs.
                    // That warning is worth having: nobody chose this deadline
                    // just now, it arrived.
                    claim.warned = false
                    // Under the lock, and re-checked inside it. `finished` was
                    // read at the top of this loop, and everything since —
                    // building a context, reading the claim, consulting the
                    // cap — is time for `cleanup()` to run and retire us. The
                    // write then put the claim back, and the guard held the
                    // switch on for a dead process until the chunk ran out.
                    //
                    // `cleanup` sets `finished` under this same lock before it
                    // retires anything, so holding it across the write makes
                    // the two orders the only two possible.
                    done.lock()
                    let stillRunning = !finished
                    if stillRunning {
                        ctx.ledger.write(claim)
                        ctx.ledger.log("run: renewed until \(Formats.hhmm(target))", now: ctx.now)
                    }
                    done.unlock()
                    if !stillRunning { return }
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
            // The guard's exemption from "a removal that did not happen may
            // not be announced" does not reach here. `run` is a one-shot,
            // user-facing command that AGENTS.md sells as "released on any
            // exit — even SIGKILL", and it already uses stderr for exactly
            // this kind of commentary. Swallowing the failure meant `simmer
            // run` finished at exit 0 with empty stderr, the claim still on
            // disk and the Mac still awake — the wrapped command's own exit
            // code passed through, saying nothing about the machine.
            var outcome = Outcome()
            if !ctx.ledger.retire(claim, why: "run finished", now: ctx.now) {
                // Epoch 0 must never be formatted as a time — it reads 01:00.
                // A run claim always carries a deadline, so this is belt and
                // braces rather than a live case.
                let held = claim.until == 0 ? "" : " until \(Formats.hhmm(claim.until))"
                outcome.stderr.append(
                    "simmer: could not release \(claim.id) — the Mac is STILL being held awake\(held). Run 'simmer doctor'")
            }
            let (_, settled) = Engine.settle(ctx: ctx, why: "run finished")
            outcome.merge(settled)
            Runtime.emit(outcome, human: .stderr)
        }
    }
}
