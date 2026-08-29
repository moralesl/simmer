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

        /// Seconds until the battery reaches THIS aggregate's floor, from
        /// macOS's own time-to-empty estimate — the number the menu bar shows,
        /// scaled by how much of the charge sits above the floor.
        ///
        /// Linear, which is the same assumption the system's own estimate
        /// already embodies; refining it would be a second discharge model
        /// disagreeing with the first. nil whenever there is nothing to be
        /// honest with: on AC, while pmset is still calibrating, or when the
        /// battery is already at or under the floor.
        func secondsToFloor() -> Int? {
            guard onBattery, let percent = battery, let toEmpty = ctx.power.batterySecondsRemaining(),
                  percent > aggregate.minBattery, percent > 0 else { return nil }
            return toEmpty * (percent - aggregate.minBattery) / percent
        }
        let floorSeconds = secondsToFloor()
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
                // The second clock, spelled out beside the first so a caller
                // can see WHICH one `seconds_left` came from. null on AC and
                // whenever macOS has no estimate to scale.
                ("battery_seconds_left", floorSeconds.map { JSONValue.int($0) } ?? .null),
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

        // The guarantee is the EARLIEST of the clocks, and a deadline is only
        // one of them. `fits` and the exit code answer about the guarantee;
        // `seconds_left` keeps its contracted meaning — the deadline clock,
        // -1 for no deadline — and `battery_seconds_left` carries the other,
        // so no existing field changed what it means.
        func fitsWithin(_ deadlineLeft: Int?) -> Bool? {
            guard needSeconds > 0 else { return nil }
            let clocks = [deadlineLeft, floorSeconds].compactMap { $0 }
            guard let earliest = clocks.min() else { return true }  // no clock at all
            return earliest >= needSeconds
        }

        if aggregate.until == 0 {
            if json {
                emitJSON(fits: fitsWithin(nil).map { JSONValue.bool($0) } ?? .null,
                         secondsLeft: .int(-1), state: "forever")
            } else if bareSeconds {
                outcome.stdout.append("-1")
            } else {
                let reasonPart = aggregate.reason.isEmpty ? "" : " · \(aggregate.reason)"
                outcome.stdout.append("no deadline — running for \(Durations.human(ctx.now - aggregate.since))\(reasonPart)")
                if let floorSeconds, needSeconds > 0, floorSeconds < needSeconds {
                    outcome.stdout.append("❌ \(Durations.human(needSeconds)) does not fit — the battery reaches its floor in about \(Durations.human(floorSeconds))")
                }
            }
            if fitsWithin(nil) == false { outcome.exit = 1 }
            return outcome
        }

        let left = aggregate.left
        let fits = fitsWithin(left)
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
                if fits {
                    outcome.stdout.append("✅ \(Durations.human(needSeconds)) fits")
                } else if let floorSeconds, floorSeconds < left {
                    // Name the clock that actually runs out first, or the
                    // reader is told they are short on time they do have.
                    outcome.stdout.append("❌ \(Durations.human(needSeconds)) does not fit — the battery reaches its floor in about \(Durations.human(floorSeconds)), before the deadline")
                } else {
                    outcome.stdout.append("❌ \(Durations.human(needSeconds)) does not fit — \(Durations.human(needSeconds - left)) short")
                }
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
