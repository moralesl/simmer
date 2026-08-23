import Foundation

extension Commands {
    /// One renderer per surface, all in the core, all reading the ledger the
    /// same way. The launcher shims are deferred until after the first release
    /// (the CLI is a renderer over the core), but the renderers stay here and
    /// stay tested — a fourth
    /// surface costs a case branch here and a one-line shim there.
    public static func render(surface: String, query: String, ctx: Context) -> Outcome {
        var outcome = Outcome()
        switch surface {
        case "swiftbar": outcome.stdout = renderSwiftBar(ctx: ctx)
        case "raycast": outcome.stdout = [renderRaycast(ctx: ctx)]
        case "alfred": outcome.stdout = [renderAlfred(query: query, ctx: ctx)]
        default:
            return .failure("usage: simmer render swiftbar|raycast|alfred [query]")
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
            if !aggregate.reason.isEmpty { lines.append("\(aggregate.reason) | sfimage=text.quote") }
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
            if !aggregate.reason.isEmpty { lines.append("\(aggregate.reason) | sfimage=text.quote") }
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

    private static func claimRowsSwiftBar(_ aggregate: Aggregate) -> [String] {
        guard aggregate.count > 1 else { return [] }
        var lines = ["---", "\(aggregate.count) claims"]
        for entry in aggregate.live {
            let reasonPart = entry.claim.reason.isEmpty ? "" : " · \(entry.claim.reason)"
            let deadline = entry.effectiveUntil == 0
                ? "no deadline" : "until \(Formats.hhmm(entry.effectiveUntil))"
            lines.append("\(Present.ownerGlyph(entry.claim.owner)) \(entry.claim.owner)\(reasonPart) · \(deadline)")
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

    // MARK: Alfred — a script filter's JSON

    private static func renderAlfred(query: String, ctx: Context) -> String {
        let aggregate = ctx.aggregate()
        let percent = ctx.power.batteryPercent().map(String.init) ?? "?"
        let power = "battery \(percent)%\(ctx.power.onBattery() ? ", on battery" : ", on AC")"
        let iconOn = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns"
        let iconOff = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SleepFolderIcon.icns"
        let iconWarn = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertCautionIcon.icns"

        var items: [JSONValue] = []
        func item(_ title: String, _ subtitle: String, _ arg: String, _ icon: String) {
            items.append(.object([
                ("title", .string(title)),
                ("subtitle", .string(subtitle)),
                ("arg", .string(arg)),
                ("valid", .bool(!arg.isEmpty)),
                ("icon", .object([("path", .string(icon))])),
            ]))
        }

        // Does the query look like a duration or a time?
        let durationQuery: String?
        if query.range(of: #"^\+?[0-9]+[hms]?[a-z0-9]*$"#, options: .regularExpression) != nil
            || query.range(of: #"^[0-9]{1,2}:[0-9]{2}$"#, options: .regularExpression) != nil {
            durationQuery = query
        } else {
            durationQuery = nil
        }

        switch aggregate.state {
        case .active:
            let reason = aggregate.reason.isEmpty ? "no reason given" : aggregate.reason
            let claims = aggregate.count > 1 ? ", \(aggregate.count) claims" : ""
            item("Simmering until \(Formats.hhmm(aggregate.until)) · \(aggregate.leftShort) left",
                 "\(reason) — \(power), floor \(aggregate.minBattery)%\(claims)", "", iconOn)
            if !ctx.power.sleepDisabled() {
                item("Warning: disablesleep is off", "The lid will not hold. Run simmer doctor.", "", iconWarn)
            }
            if let q = durationQuery {
                if q.contains(":") {
                    item("Move your deadline to \(q)", "Replaces your own claim", "--until \(q)", iconOn)
                } else if q.hasPrefix("+") {
                    item("Add \(q.dropFirst())", "Added to your current deadline", q, iconOn)
                } else {
                    item("Replace yours with \(q)", "Counted from now", q, iconOn)
                }
            }
            item("Release mine", "Hand your own claim back", "down", iconOff)
            item("Release everything", "Ends every claim — humans only", "down --all", iconOff)
            item("15 more minutes", "Adds 15 minutes to your deadline", "+15m", iconOn)
            item("1 more hour", "Adds 1 hour to your deadline", "+1h", iconOn)
        case .forever:
            let reason = aggregate.reason.isEmpty ? "no reason given" : aggregate.reason
            item("Simmering with no deadline · since \(Formats.hhmm(aggregate.since))",
                 "\(reason) — \(power), floor \(aggregate.minBattery)%", "", iconOn)
            if let q = durationQuery {
                item("Give it a deadline: \(q)", "Turns the open-ended claim into a timebox",
                     String(q.drop(while: { $0 == "+" })), iconOn)
            }
            item("Release mine", "Hand your own claim back", "down", iconOff)
            item("Release everything", "Ends every claim — humans only", "down --all", iconOff)
        case .orphan:
            item("Sleep is disabled with nothing claiming it",
                 "Nobody is scheduled to hand it back — is the guard running?", "", iconWarn)
            item("Revert now", "Allow sleep again immediately", "down", iconOff)
            item("Turn it into a 1 hour claim", "Keeps it awake, with a deadline", "1h", iconOn)
        case .idle:
            item("Sleep allowed", "\(power) — nothing is holding this Mac awake", "", iconOff)
            if let q = durationQuery {
                if q.contains(":") {
                    item("Stay awake until \(q)", "Lid may close until then", "--until \(q)", iconOn)
                } else {
                    item("Stay awake for \(q.drop(while: { $0 == "+" }))", "Lid may close until then",
                         String(q.drop(while: { $0 == "+" })), iconOn)
                }
            }
            item("30 minutes", "Lid may close until then", "30m", iconOn)
            item("1 hour", "Lid may close until then", "1h", iconOn)
            item("2 hours", "Lid may close until then", "2h", iconOn)
            item("Until further notice", "No deadline — reminds every 30 minutes", "forever", iconOn)
        }
        if aggregate.cap != 0 {
            item("Nothing past \(Formats.hhmm(aggregate.cap))",
                 "The cap a human set — 'cap off' lifts it", "cap off", iconWarn)
        }
        return JSONValue.object([("items", .array(items))]).serialized()
    }
}
