import Foundation

public enum StatusMode {
    case human
    /// Flat key=value, so a menu bar can read it without `jq`.
    case machine
    case json
}

extension Commands {
    /// The `status --json` object as a value rather than a string, so a caller
    /// can nest it. `doctor --json` does, which is what stops a second
    /// hand-kept copy of a contracted field list existing.
    public static func statusObject(ctx: Context) -> JSONValue {
        Present.statusJSON(ctx: ctx)
    }

    public static func status(mode: StatusMode, ctx: Context) -> Outcome {
        var outcome = Outcome()
        let aggregate = ctx.aggregate()
        let battery = ctx.power.batteryPercent()
        let onBattery = ctx.power.onBattery()
        let sleepDisabled = ctx.power.sleepDisabled()

        switch mode {
        case .machine:
            // Every field, every time — a reader must never have to guess
            // whether a key is absent or zero. Fields are append-only.
            outcome.stdout = [
                "state=\(aggregate.state.rawValue)",
                "until=\(aggregate.until)",
                "left=\(aggregate.left)",
                "left_short=\(aggregate.leftShort)",
                "reason=\(aggregate.reason)",
                "min_battery=\(aggregate.minBattery)",
                "battery=\(battery.map(String.init) ?? "")",
                "on_battery=\(onBattery ? 1 : 0)",
                "sleep_disabled=\(sleepDisabled ? 1 : 0)",
                "since=\(aggregate.since)",
                "owner=\(aggregate.owner)",
                "claim_count=\(aggregate.count)",
                "cap=\(aggregate.cap)",
                "cap_expires=\(aggregate.capExpires)",
                // Not a detail of the claim: a statement that everything above
                // it describes a seam rather than this Mac.
                "seamed=\(ctx.isSeamed ? 1 : 0)",
            ]

        case .json:
            outcome.stdout = [statusObject(ctx: ctx).serialized()]

        case .human:
            // Before anything about the claim, because it changes what all of
            // it means: under a seam these numbers describe a file, not this
            // Mac, and the lid will close on the work regardless.
            if ctx.isSeamed {
                outcome.stdout.append("⚠️  SIMMER_FAKE_* is set — this is a test seam, not this Mac.")
                outcome.stdout.append("   The sleep switch is a file and nothing below holds the lid open.")
            }
            if aggregate.count == 0 {
                if aggregate.state == .orphan {
                    // Either set by hand, or the guard is not running. Both
                    // deserve saying.
                    outcome.stdout.append("⚠️  disablesleep is on but nothing claims it — nobody will hand it back.")
                    outcome.stdout.append("   'simmer down' reverts it, 'simmer 60m' turns it into a proper claim.")
                } else {
                    outcome.stdout.append("⏾ sleep allowed · \(Present.batteryLine(ctx.power))")
                }
                outcome.stdout.append(contentsOf: Present.capNote(ctx: ctx))
                return outcome
            }

            let reasonPart = aggregate.reason.isEmpty ? "" : " · \(aggregate.reason)"
            // With one claim the summary line IS the whole answer, so it has to
            // name the holder when that is not the caller. It used to print the
            // reason alone — so a person typing `simmer` while an agent held
            // the only claim saw "39 min left · eval batch" and nothing saying
            // whose it was, while `simmer down` in the same state listed
            // "🤖 agent:evals" as it ended it. The informative surface was the
            // destructive one; you learned who held it by taking it away.
            //
            // Only when it is somebody else's: telling you that you hold your
            // own claim is noise, and with several claims the rows below
            // already answer it.
            var holder = ""
            if aggregate.count == 1, let only = aggregate.live.first,
               only.claim.owner != ctx.owner {
                holder = " · \(Present.ownerGlyph(only.claim.owner)) \(only.claim.owner)"
            }
            if aggregate.until == 0 {
                outcome.stdout.append("☕ simmering, no deadline · for \(Durations.human(ctx.now - aggregate.since))\(holder)\(reasonPart)")
            } else {
                outcome.stdout.append("☕ simmering until \(Formats.hhmmDated(aggregate.until, now: ctx.now)) · \(Durations.human(aggregate.left)) left\(holder)\(reasonPart)")
            }
            // The parts, whenever there is more than one.
            if aggregate.count > 1 {
                outcome.stdout.append(contentsOf: Present.claimRows(ctx: ctx))
            }
            outcome.stdout.append("   \(Present.batteryLine(ctx.power)) · floor \(aggregate.minBattery)%")
            outcome.stdout.append(contentsOf: Present.capNote(ctx: ctx))
            if !sleepDisabled {
                outcome.stdout.append("   ⚠️  disablesleep is off despite a live claim — the lid will not hold. 'simmer doctor'")
            }
        }
        return outcome
    }

    /// `simmer log [n]` — what the guard has actually done.
    public static func logTail(_ n: Int, json: Bool = false, ctx: Context) -> Outcome {
        var outcome = Outcome()
        let text = (try? String(contentsOf: ctx.ledger.logFile, encoding: .utf8)) ?? ""
        let tail = text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(max(n, 0)).map(String.init)
        if json {
            // An empty log is `[]`, not a sentence: "no log yet" is the human
            // answer to the same question and a parser should not have to
            // recognise prose to learn there is nothing there.
            outcome.stdout = [JSONValue.object([
                ("lines", .array(tail.map { .string($0) })),
                ("count", .int(tail.count)),
                ("path", .string(ctx.ledger.logFile.path)),
            ]).serialized()]
            return outcome
        }
        guard !tail.isEmpty else {
            outcome.stdout.append("no log yet")
            return outcome
        }
        outcome.stdout = tail
        return outcome
    }
}
