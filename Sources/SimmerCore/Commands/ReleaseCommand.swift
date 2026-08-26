import Foundation

extension Commands {
    /// `simmer release` / `simmer down`: hand YOUR claim back. Holding no
    /// claim, everyone is refused and shown the list — a human is pointed at
    /// `--all` (their authority, stated explicitly), an agent is not, because
    /// ending someone else's work is not an agent's call.
    public static func release(all: Bool, json: Bool, ctx: Context) -> Outcome {
        var outcome = Outcome()
        let claims = ctx.ledger.claims()

        func settleAndReport(_ why: String) {
            let (ok, settleOutcome) = Engine.settle(ctx: ctx, why: why)
            outcome.merge(settleOutcome)
            if !ok { outcome.exit = 1 }
        }

        /// A release ends claims and never the ceiling. "Release everything"
        /// is the most clearing-looking action simmer offers, so the surfaces
        /// that show text say what it did not touch.
        ///
        /// Only stdout here. The menu bar throws stdout away, but it also
        /// always lands in `Engine.settle` — which carries the same sentence
        /// in the banner it was already posting, instead of a second one
        /// competing with it.
        func noteTheCeiling() {
            outcome.stdout.append(contentsOf: Present.capNote(ctx: ctx, afterRelease: true))
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
            noteTheCeiling()
            settleAndReport("released by hand")
            releasedJSON(claims.map(\.owner))
            return outcome
        }

        if let mine = ctx.ledger.claim(owner: ctx.owner) {
            ctx.ledger.retire(mine, why: "released by hand", now: ctx.now)
            ctx.ledger.event("release", now: ctx.now, [("owner", .string(ctx.owner))])
            let after = ctx.aggregate()
            if after.count == 0 {
                // Say what changed about the MACHINE, not only about the
                // claim: this is the moment the lid stops being held, and
                // every neighbouring path says so.
                outcome.stdout.append("⏾ released · sleep allowed again")
            } else {
                let untilText = after.until == 0 ? "further notice" : Formats.hhmm(after.until)
                outcome.stdout.append("⏾ your claim is released · \(after.count) still live, awake until \(untilText)")
            }
            noteTheCeiling()
            settleAndReport("released by hand")
            releasedJSON([mine.owner])
            return outcome
        }

        // No claim of ours, but somebody has one. Ending work you did not
        // start deserves an explicit flag, even from a human — so name the
        // blast radius and the fix instead of acting.
        if ctx.isHuman {
            outcome.stderr.append("simmer: you hold no claim; these are live:")
            outcome.stderr.append(contentsOf: Present.claimRows(ctx: ctx))
            outcome.merge(.failure("to end them all: simmer down --all", json: json))
            return outcome
        }

        outcome.stderr.append("simmer: you hold no claim, and these are not yours to end:")
        outcome.stderr.append(contentsOf: Present.claimRows(ctx: ctx))
        outcome.merge(.failure("nothing released. Ask the human, or wait for the deadline", json: json))
        return outcome
    }
}
