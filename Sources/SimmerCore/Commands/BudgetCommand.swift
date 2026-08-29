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

        /// **How long THIS claim survives the conditions the machine is in.**
        /// nil means nothing bounds it.
        ///
        /// Per claim, because that is how `Tick` retires: its own floor, its
        /// own `--require-ac`. Each clock used to be measured against a
        /// different set — the battery against `aggregate.minBattery`, which
        /// is the DEFINING claim's floor, and require-ac against the
        /// survivors' deadlines while ignoring the survivors' own floors. Two
        /// claims were enough that no clock saw the binding one: `--need 2h`
        /// answered `fits: true` at exit 0 quoting six hours of battery, and
        /// one tick later the machine was idle with the switch handed back.
        ///
        /// Overflow-checked: the estimate comes in from outside — the seam
        /// directly, `pmset` in production — and an unchecked multiply traps
        /// the process with exit 133.
        /// nil seconds = nothing bounds it. `why` is nil when the bound is the
        /// claim's own deadline, which gets the ordinary shortfall sentence.
        typealias Survival = (seconds: Int?, why: String?)

        /// Whether there is one claim or several changes how to name it, and
        /// naming it wrongly is the failure this whole surface keeps having.
        let subject = aggregate.count > 1 ? "the last claim still standing" : "this claim"

        func survives(_ entry: (claim: Claim, effectiveUntil: Int)) -> Survival {
            if ctx.power.thermalPressure() {
                return (0, "heat ends every claim on the next tick")
            }
            var bounds: [Survival] = []
            if onBattery {
                if entry.claim.requireAC {
                    return (0, "\(subject) needs the charger, and it is out")
                }
                if let percent = battery {
                    // At or below ITS floor, decided from the percentage alone
                    // and before any estimate — `Tick` consults no clock to do
                    // it either, and 0% is a floor case, not a division one.
                    guard percent > entry.claim.minBattery else {
                        return (0, "\(subject) is already at its floor")
                    }
                    if percent > 0, let toEmpty = ctx.power.batterySecondsRemaining(),
                       toEmpty >= 0 {
                        let (scaled, over) = toEmpty.multipliedReportingOverflow(
                            by: percent - entry.claim.minBattery)
                        if !over {
                            let left = scaled / percent
                            bounds.append((left,
                                "the battery reaches its floor in about \(Durations.human(left))"))
                        }
                    }
                }
            }
            if entry.effectiveUntil != 0 {
                bounds.append((max(entry.effectiveUntil - ctx.now, 0), nil))
            }
            guard let earliest = bounds.min(by: { ($0.seconds ?? 0) < ($1.seconds ?? 0) })
            else { return (nil, nil) }
            return earliest
        }

        /// The guarantee: the machine stays awake while ANY claim survives, so
        /// it is the longest of them. nil when one of them is unbounded.
        /// The machine stays awake while ANY claim survives, so the guarantee
        /// is the longest of them — and the reason is that claim's reason.
        let guarantee: Survival = {
            guard aggregate.count > 0 else { return (nil, nil) }
            let each = aggregate.live.map(survives)
            if each.contains(where: { $0.seconds == nil }) { return (nil, nil) }
            return each.max(by: { ($0.seconds ?? 0) < ($1.seconds ?? 0) }) ?? (nil, nil)
        }()
        let guaranteeSeconds = guarantee.seconds

        /// What the battery alone says, for the machine surface: the longest
        /// any claim survives on battery, deadlines set aside.
        let floorSeconds: Int? = {
            guard aggregate.count > 0, onBattery, let percent = battery else { return nil }
            var each: [Int] = []
            for entry in aggregate.live {
                if entry.claim.requireAC || percent <= entry.claim.minBattery {
                    each.append(0); continue
                }
                guard percent > 0, let toEmpty = ctx.power.batterySecondsRemaining(),
                      toEmpty >= 0 else { return nil }
                let (scaled, over) = toEmpty.multipliedReportingOverflow(
                    by: percent - entry.claim.minBattery)
                guard !over else { return nil }
                each.append(scaled / percent)
            }
            return each.max()
        }()

        let thermalSeconds: Int? = ctx.power.thermalPressure() ? 0 : nil
        /// Every live claim needs a charger that is out.
        let requireACSeconds: Int? = {
            guard onBattery, aggregate.count > 0 else { return nil }
            return aggregate.live.allSatisfy(\.claim.requireAC) ? 0 : nil
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
        /// The guarantee, with the words for whatever bounds it. Four times a
        /// refusal has reported a shortfall against the deadline while
        /// something else was the thing running out, so the sentence comes
        /// from the same computation as the verdict.
        func clocks(_ deadlineLeft: Int?) -> [(seconds: Int, why: String?)] {
            guard let guaranteeSeconds else {
                return deadlineLeft.map { [($0, nil)] } ?? []
            }
            // The deadline being the binding component is the ordinary case
            // and gets the ordinary "N short" sentence; otherwise the reason
            // comes from the same computation as the verdict, so the two
            // cannot describe different things.
            if let deadlineLeft, deadlineLeft <= guaranteeSeconds {
                return [(guaranteeSeconds, nil)]
            }
            // A nil `why` here means the bound is a deadline — but NOT the one
            // the aggregate reports, or we would not be past the branch above.
            // Saying "N short" then subtracts against a number that was never
            // the guarantee, which is the mistake this surface has now made
            // five times.
            guard let why = guarantee.why else {
                return [(guaranteeSeconds,
                         "\(subject) ends in about \(Durations.human(guaranteeSeconds))")]
            }
            return [(guaranteeSeconds, why)]
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
