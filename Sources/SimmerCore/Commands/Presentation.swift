import Foundation

/// Shared presentation helpers. Human-facing sentences may be reworded at any
/// time (contract guarantee 5) — nothing here is API except through --json
/// and --machine, which live in their commands.
enum Present {
    static func ownerGlyph(_ owner: String) -> String {
        Owners.glyph(owner)
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
        guard let cap = ctx.ledger.readCap(now: ctx.now) else { return [] }
        if cap.until <= ctx.now {
            return ["   ⛔ cap \(Formats.hhmm(cap.until)) has passed — nothing new until \(Formats.hhmm(cap.expires))"]
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
            // A boolean, like every other yes/no field here and in
            // events.jsonl. It shipped as 0/1 before v1.0 froze the surface;
            // one field with two types across two machine surfaces of one
            // binary is exactly the drift the append-only rule exists to stop.
            ("require_ac", .bool(claim.requireAC)),
            ("since", .int(claim.started)),
            ("human", .bool(SimmerEnvironment.isHumanOwnerName(claim.owner))),
        ])
    }

    /// The whole `status --json` object, as a value rather than a string, so
    /// `doctor --json` can nest it instead of keeping a second copy of the
    /// field list. Two hand-kept copies of a contracted shape is how one of
    /// them acquires a field the other does not have.
    static func statusJSON(ctx: Context) -> JSONValue {
        let aggregate = ctx.aggregate()
        let battery = ctx.power.batteryPercent()
        let claims = aggregate.live.map {
            claimJSON($0.claim, effectiveUntil: $0.effectiveUntil, now: ctx.now)
        }
        return .object([
            ("state", .string(aggregate.state.rawValue)),
            ("until", .int(aggregate.until)),
            ("left", .int(aggregate.left)),
            ("left_short", .string(aggregate.leftShort)),
            ("reason", .string(aggregate.reason)),
            ("min_battery", .int(aggregate.minBattery)),
            ("battery", battery.map { JSONValue.int($0) } ?? .null),
            // 0/1 rather than booleans, alone in this object: these two mirror
            // `--machine` field for field, and that surface has no types
            // (CONTRACTS.md § Machine-readable output).
            ("on_battery", .int(ctx.power.onBattery() ? 1 : 0)),
            ("sleep_disabled", .int(ctx.power.sleepDisabled() ? 1 : 0)),
            ("since", .int(aggregate.since)),
            ("owner", .string(aggregate.owner)),
            ("claim_count", .int(aggregate.count)),
            ("cap", .int(aggregate.cap)),
            ("capped", .bool(aggregate.capped)),
            ("claims", .array(claims)),
            ("version", .string(ctx.version)),
        ])
    }

    /// The aggregate tail every mutating command's --json carries, so one call
    /// answers "what changed AND what will the machine do now" — no second
    /// round-trip (CONTRACTS.md § v1 surface additions).
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
