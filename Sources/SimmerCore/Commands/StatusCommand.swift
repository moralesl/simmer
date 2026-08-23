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
            ]

        case .json:
            outcome.stdout = [statusObject(ctx: ctx).serialized()]

        case .human:
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
            if aggregate.until == 0 {
                outcome.stdout.append("☕ simmering, no deadline · for \(Durations.human(ctx.now - aggregate.since))\(reasonPart)")
            } else {
                outcome.stdout.append("☕ simmering until \(Formats.hhmmDated(aggregate.until, now: ctx.now)) · \(Durations.human(aggregate.left)) left\(reasonPart)")
            }
            // The parts, whenever there is more than one. With a single claim
            // the line above already said everything.
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
