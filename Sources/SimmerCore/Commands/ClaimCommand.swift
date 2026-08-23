import Foundation

public struct ClaimInput {
    public var durationText: String?
    public var untilText: String?
    public var forever: Bool
    public var reason: String
    public var minBattery: Int
    public var requireAC: Bool
    public var displayOn: Bool
    public var force: Bool
    public var json: Bool

    public init(durationText: String? = nil, untilText: String? = nil, forever: Bool = false,
                reason: String = "", minBattery: Int = Claim.defaultMinBattery,
                requireAC: Bool = false, displayOn: Bool = false, force: Bool = false,
                json: Bool = false) {
        self.durationText = durationText
        self.untilText = untilText
        self.forever = forever
        self.reason = reason
        self.minBattery = minBattery
        self.requireAC = requireAC
        self.displayOn = displayOn
        self.force = force
        self.json = json
    }
}

public enum Commands {
    /// `simmer claim 2h` (canonically), `simmer 2h` (the everyday spelling).
    /// Replacing your OWN claim is ordinary and silent — that is what a second
    /// `simmer 2h` from the same terminal means. Nobody else's claim is even
    /// addressable from here.
    public static func claim(_ input: ClaimInput, ctx: Context) -> Outcome {
        var outcome = Outcome()
        if input.force {
            // Accepted and inert: launcher shims and other people's scripts
            // pass it, and the claims model removed the conflict it resolved.
            outcome.stderr.append("simmer: --force no longer does anything — claims cannot collide")
        }

        var untilEpoch = 0
        if input.forever {
            untilEpoch = 0
        } else if let untilText = input.untilText {
            guard let parsed = Durations.parseUntil(untilText, now: ctx.now) else {
                outcome.merge(.failure("did not understand the time: \(untilText) (expected HH:MM)",
                                       json: input.json))
                return outcome
            }
            untilEpoch = parsed
        } else if let durationText = input.durationText {
            guard let seconds = Durations.parse(durationText) else {
                outcome.merge(.failure(
                    "did not understand the duration: \(durationText) (e.g. 60m, 2h, 1h30m)",
                    json: input.json))
                return outcome
            }
            untilEpoch = ctx.now + seconds
        } else {
            outcome.merge(.failure(
                "no duration given. 'simmer 60m', 'simmer --until 23:00' or 'simmer forever'",
                json: input.json))
            return outcome
        }

        // Check the floor before flipping the switch: a claim the guard
        // reclaims on its very next tick is only confusing.
        let percent = ctx.power.batteryPercent()
        if ctx.power.onBattery(), let percent, percent <= input.minBattery {
            outcome.notifications.append(NotificationRequest(
                title: "⚠️ simmer refused",
                subtitle: "Battery \(percent)%, floor \(input.minBattery)%",
                body: "Plug in, or lower --min-battery."))
            outcome.merge(.failure(
                "battery \(percent)% <= floor \(input.minBattery)%. Plug in, or lower --min-battery.",
                json: input.json))
            return outcome
        }
        // Same argument for --require-ac: a claim that ends the moment it
        // starts is never what was meant.
        if input.requireAC && ctx.power.onBattery() {
            outcome.merge(.failure("--require-ac, and this Mac is on battery. Plug in first.",
                                   json: input.json))
            return outcome
        }

        // The cap clips from above — silently only when it makes the claim
        // shorter. A passed cap refuses outright, and names the fix: failing
        // toward sleep is simmer's bias, and the refusal is a visible gate.
        var clippedByCap = false
        var capUntil = 0
        if let cap = ctx.ledger.readCap() {
            capUntil = cap.until
            if cap.until <= ctx.now {
                outcome.merge(.failure(
                    "the cap is \(Formats.hhmm(cap.until)), which has passed. A human lifts it with 'simmer cap off'.",
                    json: input.json))
                return outcome
            }
            if untilEpoch == 0 || untilEpoch > cap.until {
                untilEpoch = cap.until
                clippedByCap = true
            }
        }

        // An agent that forgets --owner silently becomes "script", and then
        // its next step cannot find "its" claim. One stderr line converts a
        // silent misuse into a visible one; invisible to humans in a terminal.
        if !ctx.ownerExplicit && !ctx.isTTY {
            outcome.stderr.append(
                "simmer: claimed as \"\(ctx.owner)\" — pass --owner agent:<work> to get your own slot")
        }

        // Replacing our own claim keeps its start time; a spike-written
        // predecessor gets its recorded caffeinate child cleaned up.
        var started = ctx.now
        if let existing = ctx.ledger.claim(owner: ctx.owner) {
            if existing.legacyCaffeinatePid > 0 { kill(pid_t(existing.legacyCaffeinatePid), SIGTERM) }
            started = existing.started
        }

        let before = ctx.aggregate()

        let switchWasOn = ctx.power.sleepDisabled()
        guard ctx.power.setDisableSleep(true) else {
            outcome.merge(.failure("could not set disablesleep (sudo?). Run 'simmer doctor'",
                                   json: input.json))
            return outcome
        }
        if !switchWasOn {
            ctx.ledger.event("switch_on", now: ctx.now,
                             [("why", .string("claim by \(ctx.owner)"))])
        }

        let claim = Claim(owner: ctx.owner, until: untilEpoch, started: started,
                          reason: input.reason, minBattery: input.minBattery,
                          requireAC: input.requireAC, displayOn: input.displayOn,
                          reminded: ctx.now)
        ctx.ledger.write(claim)
        ctx.ledger.event("claim", now: ctx.now, [
            ("owner", .string(ctx.owner)),
            ("reason", .string(input.reason)),
            ("until", .int(untilEpoch)),
            ("min_battery", .int(input.minBattery)),
            ("require_ac", .bool(input.requireAC)),
            ("clipped_by_cap", .bool(clippedByCap)),
        ])

        let after = ctx.aggregate()
        let reasonPart = input.reason.isEmpty ? "" : " · \(input.reason)"

        if untilEpoch == 0 {
            ctx.ledger.log("claim \(ctx.owner): no deadline\(input.reason.isEmpty ? "" : " (\(input.reason))"), battery floor \(input.minBattery)%", now: ctx.now)
            outcome.stdout.append("☕ simmering, no deadline\(reasonPart)")
            outcome.stdout.append("   reminder every 30 min · releases below \(input.minBattery)% battery · 'simmer down' ends it")
        } else {
            ctx.ledger.log("claim \(ctx.owner): until \(Formats.hhmm(untilEpoch))\(input.reason.isEmpty ? "" : " (\(input.reason))"), battery floor \(input.minBattery)%", now: ctx.now)
            outcome.stdout.append("☕ simmering until \(Formats.hhmm(untilEpoch)) (\(Durations.human(untilEpoch - ctx.now)))\(reasonPart)")
            outcome.stdout.append("   lid may close · \(Present.batteryLine(ctx.power)) · releases below \(input.minBattery)%")
            if clippedByCap {
                outcome.stdout.append("   clipped by the cap at \(Formats.hhmm(capUntil))")
            }
            if input.requireAC {
                outcome.stdout.append("   ends if the charger is unplugged")
            }
            // simmer is the tool that turns a lax Lock Screen setting into a
            // running, unlocked laptop in a bag — so it says so.
            if let delay = ctx.power.lockDelaySeconds(), delay > 60 {
                outcome.stdout.append("   note: the screen stays UNLOCKED \(delay)s after the lid closes (System Settings > Lock Screen)")
            }
        }
        if after.count > 1 {
            let machineUntil = after.until == 0 ? "further notice" : Formats.hhmm(after.until)
            outcome.stdout.append("   \(after.count) claims live · the Mac stays awake until \(machineUntil) · 'simmer status' lists them")
        }

        // Notify only when the machine's promise changed MATERIALLY. A claim
        // inside a longer one changed nothing a human needs told — and neither
        // did a second click that moved the deadline by seconds.
        if promiseChangedMaterially(from: before, to: after) {
            if after.until == 0 {
                outcome.notifications.append(NotificationRequest(
                    title: "☕ Simmering, no deadline",
                    subtitle: "reminder every 30 min · floor \(input.minBattery)%",
                    body: input.reason.isEmpty ? "Ends with simmer down." : input.reason,
                    actionable: true))
            } else {
                outcome.notifications.append(NotificationRequest(
                    title: "☕ Simmering until \(Formats.hhmm(after.until))",
                    subtitle: "\(Durations.human(after.until - ctx.now)) · lid may close",
                    body: input.reason, actionable: true))
            }
        }

        if input.json {
            let effective = cappedUntil(claim.until, cap: ctx.ledger.readCap())
            var pairs: [(String, JSONValue)] = [
                ("action", .string("claimed")),
                ("claim", Present.claimJSON(claim, effectiveUntil: effective, now: ctx.now)),
                ("clipped_by_cap", .bool(clippedByCap)),
            ]
            pairs.append(contentsOf: Present.aggregateJSON(after))
            outcome.stdout = [JSONValue.object(pairs).serialized()]
        }
        return outcome
    }

    /// `simmer extend 20m` / `simmer +20m`. From NOW, not from the old
    /// deadline: after "+20m", twenty minutes should be left.
    public static func extend(_ durationText: String, json: Bool, ctx: Context) -> Outcome {
        var outcome = Outcome()
        let text = durationText.hasPrefix("+") ? String(durationText.dropFirst()) : durationText
        guard !text.isEmpty else {
            outcome.merge(.failure("extend by how much? 'simmer +20m'", json: json))
            return outcome
        }
        guard let seconds = Durations.parse(text) else {
            outcome.merge(.failure("did not understand the duration: \(text)", json: json))
            return outcome
        }
        guard var claim = ctx.ledger.claim(owner: ctx.owner) else {
            outcome.merge(.failure("no claim of yours to extend. 'simmer \(text)' takes one.",
                                   json: json))
            return outcome
        }
        if claim.until == 0 {
            outcome.merge(.failure("your claim has no deadline — there is nothing to extend.",
                                   json: json))
            return outcome
        }

        var target = ctx.now + seconds
        var clippedByCap = false
        var capUntil = 0
        if let cap = ctx.ledger.readCap() {
            capUntil = cap.until
            if cap.until <= ctx.now {
                outcome.merge(.failure(
                    "the cap is \(Formats.hhmm(cap.until)), which has passed. A human lifts it with 'simmer cap off'.",
                    json: json))
                return outcome
            }
            if target > cap.until {
                if claim.until >= cap.until {
                    outcome.merge(.failure(
                        "already at the cap (\(Formats.hhmm(cap.until))). Only a human can move it.",
                        json: json))
                    return outcome
                }
                target = cap.until
                clippedByCap = true
            }
        }

        let before = ctx.aggregate()
        claim.until = target
        claim.warned = false
        ctx.ledger.write(claim)
        ctx.ledger.event("extend", now: ctx.now, [
            ("owner", .string(ctx.owner)),
            ("until", .int(target)),
            ("clipped_by_cap", .bool(clippedByCap)),
        ])
        let after = ctx.aggregate()

        ctx.ledger.log("extended \(ctx.owner) until \(Formats.hhmm(target))", now: ctx.now)
        outcome.stdout.append("☕ simmering until \(Formats.hhmm(target)) (\(Durations.human(target - ctx.now)))")
        if clippedByCap {
            outcome.stdout.append("   clipped by the cap at \(Formats.hhmm(capUntil))")
        }
        // Your deadline moved; the machine's may not have. Saying so is the
        // difference between "30 more minutes" and "30 more minutes, and then
        // it still will not sleep because somebody else holds it open-ended".
        if after.until == 0 {
            outcome.stdout.append("   the machine stays awake until further notice — another claim has no deadline")
        } else if after.until != target {
            outcome.stdout.append("   the machine stays awake until \(Formats.hhmm(after.until)) — another claim reaches further")
        }

        if promiseChangedMaterially(from: before, to: after) {
            // The banner describes the AGGREGATE, which can be open-ended even
            // though the claim just extended is not. Epoch 0 must never be
            // formatted as a time — that reads "01:00".
            if after.until == 0 {
                outcome.notifications.append(NotificationRequest(
                    title: "☕ Extended", subtitle: "still no deadline overall",
                    body: claim.reason, actionable: true))
            } else {
                outcome.notifications.append(NotificationRequest(
                    title: "☕ Extended until \(Formats.hhmm(after.until))",
                    subtitle: "\(Durations.human(after.until - ctx.now)) left",
                    body: claim.reason, actionable: true))
            }
        }

        if json {
            let effective = cappedUntil(claim.until, cap: ctx.ledger.readCap())
            var pairs: [(String, JSONValue)] = [
                ("action", .string("extended")),
                ("claim", Present.claimJSON(claim, effectiveUntil: effective, now: ctx.now)),
                ("clipped_by_cap", .bool(clippedByCap)),
            ]
            pairs.append(contentsOf: Present.aggregateJSON(after))
            outcome.stdout = [JSONValue.object(pairs).serialized()]
        }
        return outcome
    }
}
