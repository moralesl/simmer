import Foundation

extension Commands {
    /// The agent-facing question: not "what is the state" but "is there room
    /// to START something". The decision lives in the exit code:
    ///
    ///   0  there is room (or no deadline at all)
    ///   1  not enough time left — wind down
    ///   3  nothing claimed: sleep is allowed, the lid can interrupt any moment
    ///
    /// 3-vs-1 is load-bearing: 1 is a small budget, 3 is an ABSENT guarantee.
    /// A caller that conflates them keeps working while the machine sleeps.
    /// It answers over the AGGREGATE — whose claim provides the guarantee does
    /// not change how long the work has, which is why --owner is accepted and
    /// ignored rather than an error.
    public static func budget(needSeconds: Int, bareSeconds: Bool, json: Bool,
                              ctx: Context) -> Outcome {
        var outcome = Outcome()
        let aggregate = ctx.aggregate()

        // The whole point of this command is a guarantee to act on. Under a
        // seam there is none, whatever the exit code says, so say it first —
        // `--bare-seconds` excepted, which is one number by contract.
        if ctx.isSeamed && !bareSeconds && !json {
            outcome.stderr.append("simmer: SIMMER_FAKE_* is set — this answer is about a test seam, not this Mac.")
        }


        // A deadline is not the only way the time runs out, and on battery it
        // is rarely the first. `fits` answers the question this command was
        // asked — is the DEADLINE far enough away — and answered `true` with
        // four hours left while the battery sat one point above the floor that
        // ends the claim. The exit code is deliberately unchanged (the caller
        // is told to re-check between units of work), but the inputs that
        // decide the other ending are on the surface now instead of only in
        // `status`, so a caller can see the risk without a second call.
        let battery = ctx.power.batteryPercent()
        let onBattery = ctx.power.onBattery()
        // Said out loud on the human surface for the same reason it is a field
        // on the machine one: the deadline is not what is about to end this.
        if !bareSeconds && !json, aggregate.count > 0, onBattery,
           let percent = battery, percent <= aggregate.minBattery + Tick.prefloorMargin {
            outcome.stderr.append(
                "simmer: on battery at \(percent)% with a floor of \(aggregate.minBattery)% — the claim ends there, whatever the deadline says.")
        }

        func emitJSON(fits: JSONValue, secondsLeft: JSONValue, state: String) {
            outcome.stdout = [JSONValue.object([
                ("fits", fits),
                ("seconds_left", secondsLeft),
                ("state", .string(state)),
                ("need_seconds", .int(needSeconds)),
                ("battery", battery.map { JSONValue.int($0) } ?? .null),
                ("on_battery", .int(onBattery ? 1 : 0)),
                ("min_battery", .int(aggregate.minBattery)),
                ("claim_count", .int(aggregate.count)),
                ("cap", .int(aggregate.cap)),
                ("capped", .bool(aggregate.capped)),
                // The answer this command exists to give is worthless if the
                // power system underneath it is a file in /tmp. Said on the
                // surface an agent reads, not only in `doctor`.
                ("seamed", .bool(ctx.isSeamed)),
            ]).serialized()]
        }

        if aggregate.count == 0 {
            if json {
                // No clock at all: with --need nothing fits; without one there
                // is no question. seconds_left is null — an absent clock is not
                // zero seconds on one.
                emitJSON(fits: needSeconds > 0 ? .bool(false) : .null,
                         secondsLeft: .null, state: aggregate.state.rawValue)
            } else if !bareSeconds {
                if aggregate.state == .orphan {
                    outcome.stdout.append("sleep disabled with nothing claiming it — nobody will hand it back")
                } else {
                    outcome.stdout.append("nothing claimed — sleep is allowed, the lid can interrupt at any time")
                }
            }
            outcome.exit = 3
            return outcome
        }

        if aggregate.until == 0 {
            if json {
                emitJSON(fits: needSeconds > 0 ? .bool(true) : .null,
                         secondsLeft: .int(-1), state: "forever")
            } else if bareSeconds {
                outcome.stdout.append("-1")
            } else {
                let reasonPart = aggregate.reason.isEmpty ? "" : " · \(aggregate.reason)"
                outcome.stdout.append("no deadline — running for \(Durations.human(ctx.now - aggregate.since))\(reasonPart)")
            }
            return outcome
        }

        let left = aggregate.left
        let fits: Bool? = needSeconds > 0 ? left >= needSeconds : nil
        if json {
            emitJSON(fits: fits.map { JSONValue.bool($0) } ?? .null,
                     secondsLeft: .int(left), state: "active")
        } else if bareSeconds {
            outcome.stdout.append(String(left))
        } else {
            let reasonPart = aggregate.reason.isEmpty ? "" : " · \(aggregate.reason)"
            outcome.stdout.append("\(Durations.human(left)) left of \(Durations.human(aggregate.until - aggregate.since)) · until \(Formats.hhmmDated(aggregate.until, now: ctx.now))\(reasonPart)")
            // The verdict, in words. The exit code carries it for scripts, but
            // a person at a terminal cannot see an exit code: fit and no-fit
            // printed the identical line, which made --need look broken.
            if let fits {
                outcome.stdout.append(fits
                    ? "✅ \(Durations.human(needSeconds)) fits"
                    : "❌ \(Durations.human(needSeconds)) does not fit — \(Durations.human(needSeconds - left)) short")
            }
            // The truthful answer to "why can I not have more", so an agent at
            // the ceiling reports it instead of retrying with a bigger number.
            if aggregate.capped {
                outcome.stdout.append("that is the cap a human set — asking for longer will not move it")
            }
        }
        if fits == false { outcome.exit = 1 }
        return outcome
    }
}
