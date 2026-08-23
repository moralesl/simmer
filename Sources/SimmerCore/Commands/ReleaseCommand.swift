import Foundation

extension Commands {
    /// `simmer release` / `simmer down`: hand YOUR claim back. A human holding
    /// no claim releases everything and is told whose it was (human primacy +
    /// honesty); an agent in the same position is refused and shown the list,
    /// because ending someone else's work is not an agent's call.
    public static func release(all: Bool, json: Bool, ctx: Context) -> Outcome {
        var outcome = Outcome()
        let claims = ctx.ledger.claims()

        func settleAndReport(_ why: String) {
            let (ok, settleOutcome) = Engine.settle(ctx: ctx, why: why)
            outcome.merge(settleOutcome)
            if !ok { outcome.exit = 1 }
        }

        func releasedJSON(_ owners: [String]) {
            guard json else { return }
            var pairs: [(String, JSONValue)] = [
                ("action", .string("released")),
                ("released", .array(owners.map { .string($0) })),
            ]
            pairs.append(contentsOf: Present.aggregateJSON(ctx.aggregate()))
            outcome.stdout = [JSONValue.object(pairs).serialized()]
        }

        // Nothing claimed, switch on: the orphan. Reverting it is always
        // allowed, by anyone — stopping is never the thing simmer stands in
        // the way of (contract guarantee 6).
        if claims.isEmpty {
            if ctx.power.sleepDisabled() {
                settleAndReport("reverted by hand")
                if outcome.exit == 0 { outcome.stdout.append("⏾ sleep allowed again") }
            } else {
                outcome.stdout.append("⏾ nothing to release · sleep is already allowed")
            }
            releasedJSON([])
            return outcome
        }

        if all && !ctx.isHuman {
            outcome.stderr.append("simmer: 'down --all' ends claims that are not yours — only a person may do that.")
            outcome.stderr.append(contentsOf: Present.claimRows(ctx: ctx))
            outcome.merge(.failure("release your own with 'simmer down', or ask the human", json: json))
            return outcome
        }

        if all {
            for claim in claims { ctx.ledger.retire(claim, why: "released by hand (all)", now: ctx.now) }
            ctx.ledger.event("release_all", now: ctx.now, [
                ("by", .string(ctx.owner)),
                ("released", .array(claims.map { .string($0.owner) })),
            ])
            outcome.stdout.append("⏾ released all \(claims.count) claim(s)")
            settleAndReport("released by hand")
            releasedJSON(claims.map(\.owner))
            return outcome
        }

        if let mine = ctx.ledger.claim(owner: ctx.owner) {
            ctx.ledger.retire(mine, why: "released by hand", now: ctx.now)
            ctx.ledger.event("release", now: ctx.now, [("owner", .string(ctx.owner))])
            let after = ctx.aggregate()
            if after.count == 0 {
                outcome.stdout.append("⏾ released")
            } else {
                let untilText = after.until == 0 ? "further notice" : Formats.hhmm(after.until)
                outcome.stdout.append("⏾ your claim is released · \(after.count) still live, awake until \(untilText)")
            }
            settleAndReport("released by hand")
            releasedJSON([mine.owner])
            return outcome
        }

        // No claim of ours, but somebody has one.
        if ctx.isHuman {
            // "simmer down" from a human means "let my Mac sleep", and always has.
            outcome.stdout.append("⏾ you hold no claim; releasing all \(claims.count):")
            outcome.stdout.append(contentsOf: Present.claimRows(ctx: ctx))
            for claim in claims {
                ctx.ledger.retire(claim, why: "released by a human holding no claim", now: ctx.now)
            }
            ctx.ledger.event("release_all", now: ctx.now, [
                ("by", .string(ctx.owner)),
                ("released", .array(claims.map { .string($0.owner) })),
            ])
            settleAndReport("released by hand")
            releasedJSON(claims.map(\.owner))
            return outcome
        }

        outcome.stderr.append("simmer: you hold no claim, and these are not yours to end:")
        outcome.stderr.append(contentsOf: Present.claimRows(ctx: ctx))
        outcome.merge(.failure("nothing released. Ask the human, or wait for the deadline", json: json))
        return outcome
    }
}
