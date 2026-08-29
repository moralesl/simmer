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

        /// The battery's own ceiling on this claim, in seconds, or nil when
        /// there is none to give.
        ///
        /// **Zero is an answer and nil is not.** At or below the floor `Tick`
        /// retires the claim on its next tick, so the ceiling is zero — but
        /// that verdict used to be reached only after an estimate had been
        /// read, and `pmset` has none for minutes after every wake. Below the
        /// floor with no estimate therefore fell out as nil, nil meant "no
        /// constraint", and `budget --need 30m` answered `fits: true` at exit 0
        /// about a claim the next guard tick ends. That is the exit code an
        /// agent bets hours of unattended work on, so the floor is decided
        /// first, from the percentage alone.
        ///
        /// Overflow-checked, because this is a multiply on a number that comes
        /// in from outside — the seam directly, `pmset` in production — and an
        /// unchecked one traps the process with exit 133.
        func secondsToFloor() -> Int? {
            // With nothing claimed there is no floor: `aggregate.minBattery`
            // is the struct's default, not any claim's choice, so a number
            // here would describe a guarantee nobody asked for.
            guard aggregate.count > 0 else { return nil }
            guard onBattery, let percent = battery else { return nil }
            // Decided before the estimate is consulted, and before the guard
            // that keeps the division below safe. `Tick` retires on
            // `percent <= minBattery` while on battery and reads no clock to
            // do it, so neither does this — and 0% is a floor case, not a
            // division problem, which is why `percent > 0` sits below rather
            // than here.
            guard percent > aggregate.minBattery else { return 0 }
            guard percent > 0,
                  let toEmpty = ctx.power.batterySecondsRemaining(), toEmpty >= 0 else { return nil }
            let (scaled, overflowed) = toEmpty.multipliedReportingOverflow(
                by: percent - aggregate.minBattery)
            guard !overflowed else { return nil }
            return scaled / percent
        }
        let floorSeconds = secondsToFloor()

        /// Heat ends everything, unconditionally — CONTRACTS.md guarantee 1,
        /// and `Tick` releases every claim on the next tick without consulting
        /// a deadline. So under pressure the guarantee is zero however far away
        /// the deadline is.
        let thermalSeconds: Int? = ctx.power.thermalPressure() ? 0 : nil

        /// The deadline that survives the charger being out.
        ///
        /// `Tick` retires a `--require-ac` claim the moment the machine goes on
        /// battery, so a deadline provided by one of those is already over —
        /// and `budget` went on quoting it. Not a global zero like heat: a
        /// claim that did not ask for AC keeps holding the machine, so the
        /// honest number is the furthest deadline among the ones that survive.
        let requireACSeconds: Int? = {
            guard onBattery, aggregate.count > 0 else { return nil }
            let survivors = aggregate.live.filter { !$0.claim.requireAC }
            guard !survivors.isEmpty else { return 0 }
            // An open-ended survivor outlasts every epoch, so there is no
            // ceiling to add here.
            guard !survivors.contains(where: { $0.effectiveUntil == 0 }) else { return nil }
            return max((survivors.map(\.effectiveUntil).max() ?? ctx.now) - ctx.now, 0)
        }()
        // Said out loud on the human surface for the same reason it is a field
        // on the machine one: the deadline is not what is about to end this.
        if !bareSeconds && !json, aggregate.count > 0, thermalSeconds == 0 {
            outcome.stderr.append(
                "simmer: this Mac is under thermal pressure — the next guard tick releases every claim, whatever the deadlines say.")
        }
        if !bareSeconds && !json, requireACSeconds == 0 {
            outcome.stderr.append(
                "simmer: every live claim asked for --require-ac and the charger is out — the next guard tick ends them.")
        }
        if !bareSeconds && !json, aggregate.count > 0, onBattery, let percent = battery {
            if percent <= aggregate.minBattery {
                outcome.stderr.append(
                    "simmer: on battery at \(percent)%, at or under the floor of \(aggregate.minBattery)% — this claim ends on the next guard tick.")
            } else if percent <= aggregate.minBattery + Tick.prefloorMargin {
                outcome.stderr.append(
                    "simmer: on battery at \(percent)% with a floor of \(aggregate.minBattery)% — the claim ends there, whatever the deadline says.")
            }
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
        /// Every clock that can end this claim, with the words for it. The
        /// guarantee is the earliest of them, and the verdict has to name
        /// WHICH — four times now a refusal has reported a shortfall against
        /// the deadline while something else was the thing running out.
        func clocks(_ deadlineLeft: Int?) -> [(seconds: Int, why: String?)] {
            var found: [(Int, String?)] = []
            if let deadlineLeft { found.append((deadlineLeft, nil)) }   // nil = the deadline
            if let floorSeconds {
                found.append((floorSeconds, floorSeconds == 0
                    ? "the battery is already at its floor"
                    : "the battery reaches its floor in about \(Durations.human(floorSeconds))"))
            }
            if thermalSeconds != nil {
                found.append((0, "heat ends every claim on the next tick"))
            }
            if let requireACSeconds {
                found.append((requireACSeconds, requireACSeconds == 0
                    ? "every claim needs the charger, and it is out"
                    : "the claims that survive the charger being out end in about \(Durations.human(requireACSeconds))"))
            }
            return found
        }

        func fitsWithin(_ deadlineLeft: Int?) -> Bool? {
            guard needSeconds > 0 else { return nil }
            guard let earliest = clocks(deadlineLeft).map(\.seconds).min() else { return true }
            return earliest >= needSeconds
        }

        /// The words for whichever clock runs out first, or nil when that is
        /// the deadline and the ordinary shortfall sentence is right.
        func bindingReason(_ deadlineLeft: Int?) -> String? {
            clocks(deadlineLeft).min { $0.seconds < $1.seconds }?.why
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
                if needSeconds > 0, let why = bindingReason(nil) {
                    outcome.stdout.append("❌ \(Durations.human(needSeconds)) does not fit — \(why)")
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
                } else if let why = bindingReason(left) {
                    outcome.stdout.append("❌ \(Durations.human(needSeconds)) does not fit — \(why)")
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
