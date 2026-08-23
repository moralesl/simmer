import Foundation

/// Shared presentation helpers. Human-facing sentences may be reworded at any
/// time (contract guarantee 5) — nothing here is API except through --json
/// and --machine, which live in their commands.
enum Present {
    static func ownerGlyph(_ owner: String) -> String {
        if owner == "run" || owner.hasPrefix("run:") { return "⚙" }
        if SimmerEnvironment.isHumanOwnerName(owner) { return "👤" }
        return "🤖"
    }

    static func batteryLine(_ power: PowerSystem) -> String {
        let percent = power.batteryPercent().map(String.init) ?? "?"
        return power.onBattery() ? "battery \(percent)%" : "on AC, battery \(percent)%"
    }

    /// One indented row per live claim, stable order.
    static func claimRows(ctx: Context) -> [String] {
        ctx.aggregate().live.map { entry in
            let reasonPart = entry.claim.reason.isEmpty ? "" : " · \(entry.claim.reason)"
            let deadline = entry.effectiveUntil == 0
                ? "no deadline" : "until \(Formats.hhmm(entry.effectiveUntil))"
            return "   \(ownerGlyph(entry.claim.owner)) \(entry.claim.owner)\(reasonPart) · \(deadline)"
        }
    }

    static func capNote(ctx: Context) -> [String] {
        guard let cap = ctx.ledger.readCap() else { return [] }
        if cap.until <= ctx.now {
            return ["   ⛔ cap \(Formats.hhmm(cap.until)) has passed — nothing new can be claimed ('simmer cap off')"]
        }
        let setBy = cap.setBy.isEmpty ? "" : " · set by \(cap.setBy)"
        return ["   ⛔ nothing past \(Formats.hhmm(cap.until))\(setBy)"]
    }

    /// The per-claim JSON object — same shape in `status --json` `.claims[]`
    /// and in every mutating command's `claim` field.
    static func claimJSON(_ claim: Claim, effectiveUntil: Int, now: Int) -> JSONValue {
        let left = effectiveUntil == 0 ? -1 : effectiveUntil - now
        return .object([
            ("id", .string(claim.id)),
            ("owner", .string(claim.owner)),
            ("until", .int(effectiveUntil)),
            ("left", .int(left)),
            ("reason", .string(claim.reason)),
            ("min_battery", .int(claim.minBattery)),
            ("require_ac", .int(claim.requireAC ? 1 : 0)),
            ("since", .int(claim.started)),
            ("human", .bool(SimmerEnvironment.isHumanOwnerName(claim.owner))),
        ])
    }

    /// The aggregate tail every mutating command's --json carries, so one call
    /// answers "what changed AND what will the machine do now" — no second
    /// round-trip (DESIGN-NOTES, adopted).
    static func aggregateJSON(_ aggregate: Aggregate) -> [(String, JSONValue)] {
        [
            ("state", .string(aggregate.state.rawValue)),
            ("until", .int(aggregate.until)),
            ("left", .int(aggregate.left)),
            ("claim_count", .int(aggregate.count)),
            ("cap", .int(aggregate.cap)),
            ("capped", .bool(aggregate.capped)),
        ]
    }
}
