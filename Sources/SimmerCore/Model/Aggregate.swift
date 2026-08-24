import Foundation

/// What the machine will actually do — every surface answers from this, never
/// from a single claim. The descriptive fields (reason, owner, floor, since)
/// come from the claim that DEFINES the aggregate deadline: one coherent rule,
/// identical to the single-lease answer whenever there is one claim.
public struct Aggregate: Sendable {
    public enum State: String, Sendable {
        case idle, active, forever, orphan
    }

    public var state: State = .idle
    /// Epoch; 0 = none (idle, orphan, or genuinely open-ended).
    public var until: Int = 0
    public var left: Int = 0
    public var leftShort: String = ""
    public var reason: String = ""
    public var owner: String = ""
    public var minBattery: Int = Claim.defaultMinBattery
    public var since: Int = 0
    /// Epoch of the human cap; 0 = none.
    public var cap: Int = 0
    /// True when the deadline reported IS the cap.
    public var capped: Bool = false
    public var count: Int = 0
    /// The id of the defining claim — warn-once bookkeeping lives on it.
    public var definingId: String?
    /// Live claims with their effective (capped) deadlines, in stable id order.
    public var live: [(claim: Claim, effectiveUntil: Int)] = []

    /// Pure: claims + cap + now + the switch reading in, one answer out.
    public static func compute(claims: [Claim], cap: CapRecord?, now: Int,
                               sleepDisabled: Bool) -> Aggregate {
        var aggregate = Aggregate()
        aggregate.cap = cap?.until ?? 0

        var bestUntil = 0
        var bestClaim: Claim?
        var foreverClaim: Claim?
        for claim in claims {
            let effective = cappedUntil(claim.until, cap: cap)
            // Already over: the guard retires it on its next tick. Counting it
            // meanwhile would promise time that has gone.
            if effective != 0 && effective <= now { continue }
            aggregate.count += 1
            aggregate.live.append((claim, effective))
            if effective == 0 {
                if foreverClaim == nil { foreverClaim = claim }
            } else if effective > bestUntil {
                bestUntil = effective
                bestClaim = claim
            }
        }

        if aggregate.count == 0 {
            aggregate.state = sleepDisabled ? .orphan : .idle
            return aggregate
        }

        // An open-ended claim wins only if nothing caps it — with a cap in
        // force the machine has a real deadline, and "forever" would be a lie.
        let defining: Claim
        if let foreverClaim {
            aggregate.state = .forever
            aggregate.until = 0
            aggregate.left = 0
            aggregate.leftShort = "∞"
            defining = foreverClaim
        } else {
            aggregate.state = .active
            aggregate.until = bestUntil
            aggregate.left = bestUntil - now
            aggregate.leftShort = Durations.short(aggregate.left)
            defining = bestClaim!
        }
        aggregate.definingId = defining.id
        aggregate.reason = defining.reason
        aggregate.owner = defining.owner
        aggregate.minBattery = defining.minBattery
        aggregate.since = defining.started
        aggregate.capped = aggregate.cap != 0 && aggregate.until == aggregate.cap
        return aggregate
    }
}
