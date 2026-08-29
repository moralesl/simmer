import Foundation

extension Commands {
    /// One renderer per surface, all in the core, all reading the ledger the
    /// same way. The launcher shims are deferred until after the first release
    /// (the CLI is a renderer over the core), but the renderers stay here and
    /// stay tested — a fourth
    /// surface costs a case branch here and a one-line shim there.
    public static func render(surface: String, ctx: Context) -> Outcome {
        var outcome = Outcome()
        switch surface {
        case "swiftbar": outcome.stdout = renderSwiftBar(ctx: ctx)
        case "raycast": outcome.stdout = [renderRaycast(ctx: ctx)]
        default:
            return .failure("usage: simmer render swiftbar|raycast")
        }
        return outcome
    }

    // MARK: SwiftBar

    private static func renderSwiftBar(ctx: Context) -> [String] {
        let aggregate = ctx.aggregate()
        let me = ctx.binPath
        func act(_ label: String, _ args: String...) -> String {
            var line = "\(label) | bash=\"\(me)\" terminal=false refresh=true"
            for (i, arg) in args.enumerated() { line += " param\(i + 1)=\"\(arg)\"" }
            return line
        }
        let percent = ctx.power.batteryPercent().map(String.init) ?? "?"
        let power = "battery \(percent)%\(ctx.power.onBattery() ? ", on battery" : ", on AC")"
        var lines: [String] = []

        switch aggregate.state {
        case .active:
            if aggregate.left <= 300 {
                lines.append("\(aggregate.leftShort) | sfimage=cup.and.saucer.fill color=orange")
            } else {
                lines.append("\(aggregate.leftShort) | sfimage=cup.and.saucer.fill")
            }
            lines.append("---")
            lines.append("Simmering until \(Formats.hhmm(aggregate.until)) | sfimage=clock")
            if aggregate.capped { lines.append("— that is your cap | sfimage=hand.raised.fill") }
            if !aggregate.reason.isEmpty { lines.append("\(swiftBarText(aggregate.reason)) | sfimage=text.quote") }
            lines.append("\(power) · floor \(aggregate.minBattery)% | sfimage=battery.50")
            if !ctx.power.sleepDisabled() {
                lines.append("⚠️ disablesleep is off — the lid will not hold | color=red")
            }
            lines.append(contentsOf: claimRowsSwiftBar(aggregate))
            lines.append("---")
            // "15 more minutes", not "Extend 15 minutes": the second reads as
            // "make it fifteen", which is what these items used to do.
            lines.append(act("15 more minutes", "+15m", "--owner", "menubar"))
            lines.append(act("1 more hour", "+1h", "--owner", "menubar"))
            lines.append(act("3 more hours", "+3h", "--owner", "menubar"))
            lines.append("---")
            lines.append(act("Release mine", "down", "--owner", "menubar"))
            lines.append(act("Release everything", "down", "--all", "--owner", "menubar"))
        case .forever:
            lines.append("∞ | sfimage=cup.and.saucer.fill color=orange")
            lines.append("---")
            lines.append("Simmering with no deadline | sfimage=infinity")
            if aggregate.since != 0 { lines.append("since \(Formats.hhmm(aggregate.since)) | sfimage=clock") }
            if !aggregate.reason.isEmpty { lines.append("\(swiftBarText(aggregate.reason)) | sfimage=text.quote") }
            lines.append("\(power) · floor \(aggregate.minBattery)% | sfimage=battery.50")
            lines.append(contentsOf: claimRowsSwiftBar(aggregate))
            lines.append("---")
            lines.append("Convert to a deadline")
            lines.append(act("-- 1 hour from now", "1h", "--owner", "menubar"))
            lines.append(act("-- 3 hours from now", "3h", "--owner", "menubar"))
            lines.append("---")
            lines.append(act("Release mine", "down", "--owner", "menubar"))
            lines.append(act("Release everything", "down", "--all", "--owner", "menubar"))
        case .orphan:
            lines.append(" | sfimage=exclamationmark.triangle.fill color=red")
            lines.append("---")
            lines.append("Sleep is disabled with nothing claiming it | color=red")
            lines.append("Nobody is scheduled to hand it back. Is the guard running?")
            lines.append("\(power) | sfimage=battery.50")
            lines.append("---")
            lines.append(act("Revert now", "down", "--owner", "menubar"))
            lines.append(act("Turn it into a 1 hour claim", "1h", "--owner", "menubar"))
            lines.append("Run simmer doctor | bash=\"\(me)\" param1=doctor terminal=true")
        case .idle:
            lines.append(" | sfimage=moon.zzz")
            lines.append("---")
            lines.append("Sleep allowed | sfimage=moon.zzz")
            lines.append("\(power) | sfimage=battery.50")
            lines.append("---")
            lines.append("Stay awake for…")
            lines.append(act("-- 30 minutes", "30m", "--owner", "menubar"))
            lines.append(act("-- 1 hour", "1h", "--owner", "menubar"))
            lines.append(act("-- 2 hours", "2h", "--owner", "menubar"))
            lines.append(act("-- 4 hours", "4h", "--owner", "menubar"))
            lines.append(act("-- until further notice", "forever", "--owner", "menubar"))
        }

        // The cap lives at the bottom in every state: it is the human's own
        // control, not a property of whatever happens to be claimed right now.
        lines.append("---")
        if aggregate.cap != 0 {
            lines.append("Nothing past \(Formats.hhmm(aggregate.cap)) | sfimage=hand.raised.fill")
            lines.append(act("-- lift it", "cap", "off", "--owner", "menubar"))
        } else {
            lines.append("Nothing past…")
            lines.append(act("-- 22:00", "cap", "22:00", "--owner", "menubar"))
            lines.append(act("-- 23:00", "cap", "23:00", "--owner", "menubar"))
            lines.append(act("-- 01:00", "cap", "01:00", "--owner", "menubar"))
        }
        lines.append("---")
        lines.append("Log | bash=\"\(me)\" param1=log param2=40 terminal=true")
        lines.append("Refresh | refresh=true")
        return lines
    }

    /// SwiftBar splits a row at the first `|`: everything after it is
    /// parameters, and `bash=` is one of them. So a reason or an owner
    /// containing a pipe does not decorate the row — it REPLACES the row's
    /// behaviour, turning a line that only reports something into a menu item
    /// that runs a command when the person clicks it.
    ///
    /// That is reachable without anybody meaning harm: `simmer run` records
    /// the command it is wrapping as the reason, so `simmer run -- sh -c 'a |
    /// b'` corrupts the menu on its own. And it inverts the one thing this
    /// tool is built around — the human blessing what an agent proposed —
    /// because the label they click says one thing and the parameters say
    /// another.
    ///
    /// A broken bar reads the same at menu size and cannot open a parameter
    /// list. This is the only surface that hand-assembles its own syntax —
    /// Raycast emits one plain line — and so the only one that has to think
    /// about it.
    static func swiftBarText(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\u{00A6}")
    }

    private static func claimRowsSwiftBar(_ aggregate: Aggregate) -> [String] {
        guard aggregate.count > 1 else { return [] }
        var lines = ["---", "\(aggregate.count) claims"]
        for entry in aggregate.live {
            let reasonPart = entry.claim.reason.isEmpty
                ? "" : " · \(swiftBarText(entry.claim.reason))"
            let deadline = entry.effectiveUntil == 0
                ? "no deadline" : "until \(Formats.hhmm(entry.effectiveUntil))"
            lines.append("\(Present.ownerGlyph(entry.claim.owner)) \(swiftBarText(entry.claim.owner))\(reasonPart) · \(deadline)")
        }
        return lines
    }

    // MARK: Raycast — one line, inline mode

    private static func renderRaycast(ctx: Context) -> String {
        let aggregate = ctx.aggregate()
        let percent = ctx.power.batteryPercent().map(String.init) ?? "?"
        let source = ctx.power.onBattery() ? " batt" : " AC"
        let extra = aggregate.count > 1 ? " · \(aggregate.count) claims" : ""
        switch aggregate.state {
        case .active:
            let reason = aggregate.reason.isEmpty ? "no reason" : aggregate.reason
            return "☕ \(aggregate.leftShort) left · until \(Formats.hhmm(aggregate.until)) · \(reason) · \(percent)%\(source)\(extra)"
        case .forever:
            let reason = aggregate.reason.isEmpty ? "no reason" : aggregate.reason
            return "☕ no deadline · \(reason) · \(percent)% · floor \(aggregate.minBattery)%\(extra)"
        case .orphan:
            return "⚠️ sleep disabled with nothing claiming it — run: simmer down"
        case .idle:
            return "⏾ sleep allowed · \(percent)%\(source)"
        }
    }
}
