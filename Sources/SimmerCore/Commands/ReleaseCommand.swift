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

        /// A release that did not reach the disk may not be announced. The
        /// claim file outliving `down` is the one shape where the Mac is held
        /// awake against an explicit instruction to let go, and the sentence
        /// saying otherwise is what stops anyone looking.
        ///
        /// `released` is not decoration: `down --all` retires every claim and
        /// then collects the failures, so partial success is the ordinary
        /// shape of this path rather than a race. Saying "nothing was
        /// released" there contradicted the `retire` events and the log lines
        /// the same command had just written, and told a reader to go looking
        /// for claims that were already gone.
        func couldNotRelease(_ stuck: [Claim], released: [Claim] = []) -> Outcome {
            var failed = outcome
            failed.stderr.append("simmer: \(stuck.count) claim(s) could not be removed from \(ctx.ledger.claimsDir.path):")
            for claim in stuck { failed.stderr.append("   \(claim.id) · \(claim.owner)") }
            failed.merge(.failure(
                released.isEmpty
                    ? "nothing was released and the Mac is still awake. Run 'simmer doctor'"
                    : "released \(released.count) of \(released.count + stuck.count) · the Mac is still awake. Run 'simmer doctor'",
                json: json))
            return failed
        }

        if all {
            var released: [Claim] = [], stuck: [Claim] = []
            for claim in claims {
                if ctx.ledger.retire(claim, why: "released by hand (all)", now: ctx.now) {
                    released.append(claim)
                } else {
                    stuck.append(claim)
                }
            }
            guard stuck.isEmpty else { return couldNotRelease(stuck, released: released) }
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
            guard ctx.ledger.retire(mine, why: "released by hand", now: ctx.now) else {
                return couldNotRelease([mine])
            }
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
