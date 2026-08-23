import Foundation

/// Who is speaking in menus and titles.
public enum Owners {
    public static func glyph(_ owner: String) -> String {
        if owner == "run" || owner.hasPrefix("run:") { return "⚙" }
        if SimmerEnvironment.isHumanOwnerName(owner) { return "👤" }
        return "🤖"
    }
}

/// The menu bar title: who, not only how long (DESIGN-NOTES). Pure model so
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

    public static func render(_ aggregate: Aggregate) -> StatusTitle {
        switch aggregate.state {
        case .idle:
            return StatusTitle(glyph: "🍲", detail: "", urgent: false)
        case .orphan:
            return StatusTitle(glyph: "⚠️", detail: "", urgent: false)
        case .forever, .active:
            var detail = aggregate.state == .forever ? "∞" : aggregate.leftShort
            if aggregate.count > 1 { detail += "·\(aggregate.count)" }
            let urgent = aggregate.state == .active && aggregate.left <= 300
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
