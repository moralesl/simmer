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
        if let cap = ctx.ledger.readCap(now: ctx.now) {
            capUntil = cap.until
            if cap.until <= ctx.now {
                outcome.merge(.failure(
                    "the cap is \(Formats.hhmm(cap.until)), which has passed. Nothing new until \(Formats.hhmm(cap.expires)), when it lifts itself — 'simmer cap off' is sooner.",
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
            Ledger.endLegacyCaffeinate(existing)
            started = existing.started

            // A replacement that ENDS SOONER costs whoever held it the
            // difference, and said nothing about it.
            //
            // Under an explicit --owner that is a caller shortening its own
            // deadline, which is allowed and worth one line. Under the
            // anonymous default it is usually not the same caller at all: two
            // agents that both forgot --owner are both "script", so a one-
            // minute claim replaced a four-hour one and the only sign was a
            // nudge about slots that gave no hint anything had been lost.
            //
            // AGENTS.md states the rule this broke — "no surface may cost a
            // caller awake time it already holds" — and it broke it through
            // the DOCUMENTED default rather than any unusual input.
            let shortens = existing.until == 0
                ? untilEpoch != 0
                : (untilEpoch == 0 ? false : untilEpoch < existing.until)
            if shortens {
                let had = existing.until == 0
                    ? "no deadline" : "until \(Formats.hhmm(existing.until))"
                let reasonPart = existing.reason.isEmpty ? "" : " · \(existing.reason)"
                if ctx.ownerExplicit {
                    outcome.stderr.append(
                        "simmer: this replaces your earlier claim (\(had)\(reasonPart)) with a shorter one.")
                } else {
                    outcome.stderr.append(
                        "simmer: \"\(ctx.owner)\" already held a claim \(had)\(reasonPart) — this replaces it,")
                    outcome.stderr.append(
                        "        and ends sooner. If that was somebody else's work, both of you need --owner.")
                }
            }
        }

        let before = ctx.aggregate()

        // A deadline set from INSIDE the warning window needs no warning: the
        // act of asking for two minutes is the notification that two minutes
        // is all there is. Otherwise `simmer 1m` answers itself seconds later
        // with "under 1 min left · simmer +30m extends it".
        let bornWarned = untilEpoch != 0 && untilEpoch - ctx.now <= Tick.warnSeconds

        let claim = Claim(owner: ctx.owner, until: untilEpoch, started: started,
                          reason: input.reason, minBattery: input.minBattery,
                          requireAC: input.requireAC, displayOn: input.displayOn,
                          warned: bornWarned,
                          reminded: ctx.now)

        // **The claim lands BEFORE the switch flips**, and the ordering is the
        // whole point.
        //
        // The other way round leaves a window where the switch is on and the
        // ledger is empty — which is exactly the orphan a tick is built to
        // heal, so a guard running in that gap turned the switch back off
        // under a caller who had just been told "lid may close" at exit 0. In
        // production the restore is the next tick, up to thirty seconds away,
        // and a lid closed inside that window sleeps the Mac with no guard
        // running to notice.
        //
        // This order's window is the mirror: a claim on disk with the switch
        // not yet on. A tick landing THERE turns the switch on, which is what
        // was going to happen anyway. Both orders have a race; only one of
        // them races toward the answer.
        guard ctx.ledger.write(claim) else {
            ctx.ledger.log("ERROR: could not record the claim for \(ctx.owner)", now: ctx.now)
            Engine.settle(ctx: ctx, why: "the claim could not be recorded")
            // What settle actually left behind, not what it leaves behind when
            // this is the only claim. Somebody else's claim keeps the switch
            // on — correctly — and "nothing is holding the Mac awake" told a
            // caller who then closed the lid the exact opposite of the truth.
            let after = ctx.aggregate()
            let machine = after.count > 0
                ? "\(after.count) other claim(s) still hold it awake"
                : "nothing is holding the Mac awake"
            outcome.merge(.failure(
                "could not record the claim in \(ctx.ledger.claimsDir.path) — \(machine). Run 'simmer doctor'",
                json: input.json))
            return outcome
        }

        let switchWasOn = ctx.power.sleepDisabled()
        guard ctx.power.setDisableSleep(true) else {
            // The claim is on disk and the switch would not move. Take the
            // claim back rather than leave a promise nothing is keeping.
            _ = ctx.ledger.removeClaim(id: claim.id, ifStillMatching: claim)
            outcome.merge(.failure("could not set disablesleep (sudo?). Run 'simmer doctor'",
                                   json: input.json))
            return outcome
        }
        if !switchWasOn {
            ctx.ledger.event("switch_on", now: ctx.now,
                             [("why", .string("claim by \(ctx.owner)"))])
        }

        ctx.ledger.event("claim", now: ctx.now, [
            ("owner", .string(ctx.owner)),
            ("reason", .string(claim.reason)),
            ("until", .int(untilEpoch)),
            ("min_battery", .int(input.minBattery)),
            ("require_ac", .bool(input.requireAC)),
            ("clipped_by_cap", .bool(clippedByCap)),
        ])

        let after = ctx.aggregate()
        let reasonPart = claim.reason.isEmpty ? "" : " · \(claim.reason)"

        if untilEpoch == 0 {
            ctx.ledger.log("claim \(ctx.owner): no deadline\(claim.reason.isEmpty ? "" : " (\(claim.reason))"), battery floor \(input.minBattery)%", now: ctx.now)
            outcome.stdout.append("☕ simmering, no deadline\(reasonPart)")
            outcome.stdout.append("   reminder every 30 min · releases below \(input.minBattery)% battery · 'simmer down' ends it")
        } else {
            ctx.ledger.log("claim \(ctx.owner): until \(Formats.hhmm(untilEpoch))\(claim.reason.isEmpty ? "" : " (\(claim.reason))"), battery floor \(input.minBattery)%", now: ctx.now)
            outcome.stdout.append("☕ simmering until \(Formats.hhmmDated(untilEpoch, now: ctx.now)) (\(Durations.human(untilEpoch - ctx.now)))\(reasonPart)")
            outcome.stdout.append("   lid may close · \(Present.batteryLine(ctx.power)) · releases below \(input.minBattery)%")
            if clippedByCap {
                outcome.stdout.append("   clipped by the cap at \(Formats.hhmm(capUntil))")
            }
            if input.requireAC {
                outcome.stdout.append("   ends if the charger is unplugged")
            }
            // Half a day or more from a bare duration. The founding story of
            // this tool is a switch set before a flight and found as a flat
            // battery, so a window this long gets a sentence — and `simmer
            // 2000`, which is 33 h 20 min, is a far more likely typo for
            // `--until 20:00` than a real intention.
            //
            // Never a refusal: overnight is a first-class case. And the
            // sentence differs by power source, because the useful advice
            // does. Recommending `--require-ac` to someone already on battery
            // would be advice they cannot take — the claim above refuses that
            // combination outright.
            if untilEpoch - ctx.now >= Claim.longHaulSeconds {
                if ctx.power.onBattery() {
                    outcome.stdout.append("   note: on battery the \(input.minBattery)% floor ends this well before \(Formats.hhmmDated(untilEpoch, now: ctx.now)) — plug in for the whole window")
                } else if !input.requireAC {
                    outcome.stdout.append("   note: over \(Durations.human(Claim.longHaulSeconds)) — with --require-ac it ends when the charger goes, instead of draining to the floor")
                }
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
                    body: claim.reason.isEmpty ? "Ends with simmer down." : claim.reason,
                    actionable: true))
            } else {
                outcome.notifications.append(NotificationRequest(
                    title: "☕ Simmering until \(Formats.hhmm(after.until))",
                    subtitle: "\(Durations.human(after.until - ctx.now)) · lid may close",
                    body: claim.reason, actionable: true))
            }
        }

        if input.json {
            let effective = cappedUntil(claim.until, cap: ctx.ledger.readCap(now: ctx.now))
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

    /// `simmer extend 20m` / `simmer +20m`. **Added to the existing deadline**:
    /// a claim due at 23:00 plus `+20m` is due at 23:20.
    ///
    /// This read from-now until v1.0, on the argument that after "+20m" twenty
    /// minutes should be left. It is the wrong trade: `+` and the word
    /// "extend" both mean addition to every reader, and the from-now reading
    /// silently discarded the difference — a 4-hour claim plus `+15m` left
    /// fifteen minutes and still reported `{"action":"extended"}`. Losing
    /// awake time is the failure this whole tool exists to prevent, and
    /// `simmer <duration>` was always the spelling for setting a deadline from
    /// now, so nothing was lost by making the two mean different things
    /// (CONTRACTS.md § Surface guarantees).
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

        // Added to the deadline the claim already has — but never to one that
        // has already passed. A claim whose time is up but which the guard has
        // not retired yet would otherwise have the addition land in the past,
        // producing a claim that is *still* expired and an "extended" that
        // extended nothing.
        let base = max(claim.until, ctx.now)
        var target = base + seconds
        // The ledger re-checks the ranges and would fold an over-max deadline
        // to expired — correctly, and silently. Refused here so the sentence
        // the caller reads is the one the ledger holds: walking a claim past
        // 2100 one extension at a time used to print "extended until …" at
        // exit 0 and move the deadline BACKWARDS.
        guard target <= Claim.maxEpoch else {
            outcome.merge(.failure(
                "that would extend past the year 2100, which is further than this tool will hold a deadline",
                json: json))
            return outcome
        }
        var clippedByCap = false
        var capUntil = 0
        if let cap = ctx.ledger.readCap(now: ctx.now) {
            capUntil = cap.until
            if cap.until <= ctx.now {
                outcome.merge(.failure(
                    "the cap is \(Formats.hhmm(cap.until)), which has passed. Nothing new until \(Formats.hhmm(cap.expires)), when it lifts itself — 'simmer cap off' is sooner.",
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
        // Re-arm the warning for the new deadline — unless the new deadline is
        // itself inside the warning window, which the extending caller just
        // chose knowingly.
        claim.warned = target - ctx.now <= Tick.warnSeconds
        // Same rule as claiming: an extension that did not reach disk must not
        // be announced. Here the old deadline still stands, so there is
        // nothing to settle — only something to admit.
        guard ctx.ledger.write(claim) else {
            ctx.ledger.log("ERROR: could not record the extension for \(ctx.owner)", now: ctx.now)
            outcome.merge(.failure(
                "could not record the extension — your claim still ends at \(Formats.hhmmDated(before.until, now: ctx.now)). Run 'simmer doctor'",
                json: json))
            return outcome
        }
        ctx.ledger.event("extend", now: ctx.now, [
            ("owner", .string(ctx.owner)),
            ("until", .int(target)),
            ("clipped_by_cap", .bool(clippedByCap)),
        ])
        let after = ctx.aggregate()

        ctx.ledger.log("extended \(ctx.owner) until \(Formats.hhmm(target))", now: ctx.now)
        // Name the amount added, not only the resulting deadline: "until 23:20"
        // alone cannot tell you whether the addition was applied to the old
        // deadline or to the clock, which is the exact confusion this change
        // removes.
        // The cap can absorb part of the addition, so report what actually
        // landed rather than what was asked for.
        outcome.stdout.append("☕ simmering until \(Formats.hhmmDated(target, now: ctx.now)) (\(Durations.human(target - ctx.now))) · \(Durations.human(target - base)) added")
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
            let effective = cappedUntil(claim.until, cap: ctx.ledger.readCap(now: ctx.now))
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
