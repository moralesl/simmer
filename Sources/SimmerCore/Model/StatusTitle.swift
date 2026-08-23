import Foundation

/// Who is speaking in menus and titles.
public enum Owners {
    public static func glyph(_ owner: String) -> String {
        if owner == "run" || owner.hasPrefix("run:") { return "⚙" }
        if SimmerEnvironment.isHumanOwnerName(owner) { return "👤" }
        return "🤖"
    }
}

/// The menu bar title: who, not only how long. Pure model so
/// it is testable; the app only draws it.
///
///   🍲          idle
///   🍲 42m      one claim
///   🍲 1h20·3   three claims — worth opening the menu
///   🍲 ∞·2      open-ended, plus one more
///   ⚠️           orphan: the switch is on and nothing claims it
public struct StatusTitle: Equatable, Sendable {
    /// The leading glyph ("🍲" or "⚠️").
    public var glyph: String
    /// The countdown/count portion after the glyph; empty when idle.
    public var detail: String
    /// Under five minutes — the app paints `detail` orange.
    public var urgent: Bool

    public var text: String { detail.isEmpty ? glyph : "\(glyph) \(detail)" }

    /// No redraw is due from the passage of time alone.
    public static let noScheduledChange = Int.max

    /// Seconds until this title would show something different, assuming the
    /// ledger does not change — which is what a menu bar should sleep for
    /// instead of polling on a round number.
    ///
    /// The title is minute-resolution, so a fixed interval is wrong in both
    /// directions at once: it redraws several times per minute while nothing
    /// changes, and still shows a stale minute for most of the interval that
    /// straddles the boundary. `∞`, idle and orphan never change on their own;
    /// the watcher covers the ledger changing under them.
    public static func secondsUntilChange(_ aggregate: Aggregate) -> Int {
        guard aggregate.state == .active else { return noScheduledChange }
        let left = aggregate.left
        // Past its deadline: the display flips as soon as anyone looks.
        guard left > 0 else { return 1 }
        // `leftShort` shows floor(left/60), so it changes one second after the
        // current minute is used up.
        var next = (left % 60) + 1
        // Crossing into the last five minutes repaints the countdown orange,
        // which is a change even mid-minute.
        if left > urgentSeconds { next = min(next, left - urgentSeconds) }
        return max(next, 1)
    }

    /// Under five minutes: the app paints the countdown orange.
    public static let urgentSeconds = 300

    public static func render(_ aggregate: Aggregate) -> StatusTitle {
        switch aggregate.state {
        case .idle:
            return StatusTitle(glyph: "🍲", detail: "", urgent: false)
        case .orphan:
            return StatusTitle(glyph: "⚠️", detail: "", urgent: false)
        case .forever, .active:
            var detail = aggregate.state == .forever ? "∞" : aggregate.leftShort
            if aggregate.count > 1 { detail += "·\(aggregate.count)" }
            let urgent = aggregate.state == .active && aggregate.left <= urgentSeconds
            return StatusTitle(glyph: "🍲", detail: detail, urgent: urgent)
        }
    }
}

/// Did the machine's promise change in a way a human needs told?
/// Three menu clicks in one minute moved a deadline by seconds and produced
/// three identical banners — a promise that moved by less than the minute a
/// banner can even display is not news. State changes always are.
public func promiseChangedMaterially(from before: Aggregate, to after: Aggregate) -> Bool {
    if before.state != after.state { return true }
    return before.until / 60 != after.until / 60
}
