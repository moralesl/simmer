import Foundation

extension Commands {
    /// The one command claims cannot argue with. `simmer cap 23:00` means
    /// nothing runs past 23:00 whoever asks; `cap off` lifts it; bare `cap`
    /// reports it. A human instrument: an agent may read it — and `budget`
    /// tells it the truth about the room left — but moving it is not an
    /// agent's decision to make.
    public static func cap(_ argument: String?, json: Bool, ctx: Context) -> Outcome {
        var outcome = Outcome()

        switch argument {
        case nil:
            if let cap = ctx.ledger.readCap() {
                if json {
                    outcome.stdout = [JSONValue.object([
                        ("cap", .int(cap.until)),
                        ("passed", .bool(cap.until <= ctx.now)),
                        ("set_by", .string(cap.setBy)),
                        ("set_at", .int(cap.setAt)),
                    ]).serialized()]
                } else if cap.until <= ctx.now {
                    outcome.stdout.append("⛔ cap \(Formats.hhmm(cap.until)) — passed, so nothing new can be claimed.")
                    outcome.stdout.append("   'simmer cap off' lifts it, 'simmer cap <HH:MM>' moves it.")
                } else {
                    let setBy = cap.setBy.isEmpty ? "" : " · set by \(cap.setBy)"
                    outcome.stdout.append("⛔ nothing past \(Formats.hhmm(cap.until)) (\(Durations.human(cap.until - ctx.now)) from now)\(setBy)")
                }
            } else if json {
                outcome.stdout = [JSONValue.object([("cap", .int(0))]).serialized()]
            } else {
                outcome.stdout.append("no cap · claims are bounded only by their own deadlines")
            }
            return outcome

        case "off", "none", "clear", "lift":
            guard ctx.isHuman else {
                outcome.merge(.failure("only a person can lift the cap", json: json))
                return outcome
            }
            if ctx.ledger.readCap() != nil {
                ctx.ledger.clearCap()
                ctx.ledger.log("cap lifted by \(ctx.owner)", now: ctx.now)
                ctx.ledger.event("cap_lifted", now: ctx.now, [("by", .string(ctx.owner))])
                outcome.stdout.append(json
                    ? JSONValue.object([("action", .string("cap_lifted"))]).serialized()
                    : "cap lifted")
            } else {
                outcome.stdout.append(json
                    ? JSONValue.object([("action", .string("cap_lifted")), ("was_set", .bool(false))]).serialized()
                    : "no cap was set")
            }
            return outcome

        case .some(let argument):
            guard ctx.isHuman else {
                outcome.merge(.failure("only a person can set the cap", json: json))
                return outcome
            }
            let target: Int
            if let parsed = Durations.parseUntil(argument, now: ctx.now) {
                target = parsed
            } else if let seconds = Durations.parse(argument) {
                target = ctx.now + seconds
            } else {
                outcome.merge(.failure(
                    "did not understand the cap: \(argument) (expected HH:MM, a duration, or 'off')",
                    json: json))
                return outcome
            }

            // An announced ceiling that did not reach disk is not a ceiling.
            guard ctx.ledger.writeCap(until: target, setBy: ctx.owner, now: ctx.now) else {
                ctx.ledger.log("ERROR: could not record the cap", now: ctx.now)
                outcome.merge(.failure(
                    "could not record the cap in \(ctx.ledger.capFile.path) — no ceiling is in force. Run 'simmer doctor'",
                    json: json))
                return outcome
            }
            ctx.ledger.log("cap set to \(Formats.hhmm(target)) by \(ctx.owner)", now: ctx.now)

            // Clipping is immediate, not merely a promise about future claims.
            // A claim already reaching past the new cap comes down now, or the
            // ceiling would not be one.
            var clipped = 0
            for var claim in ctx.ledger.claims() where claim.until == 0 || claim.until > target {
                claim.until = target
                claim.warned = false
                ctx.ledger.write(claim)
                clipped += 1
            }
            ctx.ledger.event("cap_set", now: ctx.now, [
                ("by", .string(ctx.owner)),
                ("until", .int(target)),
                ("clipped", .int(clipped)),
            ])

            if json {
                var pairs: [(String, JSONValue)] = [
                    ("action", .string("cap_set")),
                    ("clipped", .int(clipped)),
                ]
                pairs.append(contentsOf: Present.aggregateJSON(ctx.aggregate()))
                outcome.stdout = [JSONValue.object(pairs).serialized()]
            } else {
                outcome.stdout.append("⛔ nothing past \(Formats.hhmm(target)) (\(Durations.human(target - ctx.now)) from now)")
                if clipped > 0 {
                    outcome.stdout.append("   clipped \(clipped) claim(s) back to it")
                }
            }
            let (ok, settleOutcome) = Engine.settle(ctx: ctx, why: "cap set to \(Formats.hhmm(target))")
            outcome.merge(settleOutcome)
            if !ok { outcome.exit = 1 }
            return outcome
        }
    }
}
