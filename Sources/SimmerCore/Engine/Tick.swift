import Foundation

/// One guard pass — pure over the ledger and idempotent, so it is safe to call
/// from two places at once: the app's IOKit callbacks (instant) and the
/// LaunchAgent every 30 seconds (backstop). It reads the ledger and settles
/// the switch, never applies a delta.
public enum Tick {
    /// A single warning, 5 minutes before the aggregate deadline.
    public static let warnSeconds = 300
    /// With no deadline: remind every 30 minutes.
    public static let remindSeconds = 1800
    /// Warn this many points above a claim's floor — early enough that
    /// plugging in is still an option.
    public static let prefloorMargin = 10

    public static func run(ctx: Context) -> Outcome {
        var outcome = Outcome()
        let ledger = ctx.ledger

        // A cap is a decision about one night, and the night ends at the
        // rollover. `readCap(now:)` already reports an expired one as absent,
        // so this sweep is not what makes claims work again — it is what stops
        // a spent ceiling from sitting in the state directory looking live.
        // Before the empty-claims return, because an idle Mac is exactly where
        // yesterday's cap would otherwise wait.
        if let stale = ledger.storedCap(), ctx.now >= stale.expires, ledger.clearCap() {
            ledger.log("cap \(Formats.hhmm(stale.until)) expired at its \(Formats.hhmm(stale.expires)) rollover",
                       now: ctx.now)
            ledger.event("cap_expired", now: ctx.now, [
                ("until", .int(stale.until)),
                ("set_by", .string(stale.setBy)),
            ])
        }
        // Before anything reads the claims: a pre-0.2.0 crash left copies of
        // real records in `claims/`, and once they stopped being counted as
        // claims nothing could reach them but `down --all`. The guard is the
        // thing that runs on a Mac nobody is looking at.
        ledger.sweepWriteDebris(now: ctx.now)

        let cap = ledger.readCap(now: ctx.now)

        if ledger.claims().isEmpty {
            // Nothing claimed but the switch on: set by hand, or a crash
            // mid-release. Either way it goes back — the self-healing that
            // makes the forgotten switch structurally impossible.
            if ctx.power.sleepDisabled() {
                let (ok, settleOutcome) = Engine.settle(
                    ctx: ctx, why: "found disablesleep with nothing claiming it")
                outcome.merge(settleOutcome)
                // Only where the switch actually moved. `settle` has already
                // logged the failure and posted its banner; appending
                // `orphan_heal` beside it recorded a transition that did not
                // happen — and in the ordinary missing-sudo-rule state, which
                // is persistent rather than transient, that is one false event
                // every thirty seconds for as long as the Mac runs.
                if ok {
                    ledger.event("orphan_heal", now: ctx.now, [])
                } else {
                    outcome.exit = 1
                }
            }
            return outcome
        }

        // Heat: release everything and say so. Deliberately not a warning —
        // with the lid closed nobody sees a warning, and the machine cannot
        // vent on a duvet in a bag. A fact about the machine, not anyone's plan.
        // The guard is the one caller allowed to ignore a retire that failed:
        // it runs again in thirty seconds, `retire` has already logged why,
        // and it announces nothing to anybody. Every caller that speaks —
        // `down`, `cap off` — must check, because the speaking is the harm.
        if ctx.power.thermalPressure() {
            var stuck = 0
            for claim in ledger.claims() where !ledger.retire(claim, why: "thermal pressure", now: ctx.now) {
                stuck += 1
            }
            // The guard may ignore a retire that failed — it runs again in
            // thirty seconds. What it may not do is ANNOUNCE one. A claim
            // whose file will not unlink is still live, so `settle` correctly
            // leaves the switch on, and `thermal_release` on the contracted
            // stream beside it said the opposite: "Thermal ends everything,
            // unconditionally" (CONTRACTS.md) reported about a Mac still being
            // held awake under heat, indefinitely for an open-ended claim.
            //
            // `settle` cannot see it either — with a claim left standing it
            // takes the "switch already on, nothing to do" path and reports
            // ok — so the exit code has to come from the count, not from it.
            if stuck == 0 {
                ledger.event("thermal_release", now: ctx.now, [])
            } else {
                ledger.log("ERROR: thermal pressure could not end \(stuck) claim(s) — the Mac is still held awake",
                           now: ctx.now)
            }
            let (ok, settleOutcome) = Engine.settle(ctx: ctx, why: "thermal pressure — letting it cool")
            outcome.merge(settleOutcome)
            if !ok || stuck > 0 { outcome.exit = 1 }
            return outcome
        }

        let percent = ctx.power.batteryPercent()
        let onBattery = ctx.power.onBattery()

        for var claim in ledger.claims() {
            // What was on disk when this tick decided. Every write below
            // mutates `claim` first, so the comparison needs the copy taken
            // before any of that.
            let snapshot = claim
            let effective = cappedUntil(claim.until, cap: cap)

            // Deadline passed — the claim's own, or the cap clipping it.
            if effective != 0 && ctx.now >= effective {
                _ = ledger.retire(claim, why: "time is up", now: ctx.now)
                continue
            }

            // Battery below THIS claim's floor, on battery power only. Per
            // claim rather than all at once, so an actor asking --min-battery
            // 60 cannot drag anyone else's time down with it (CONTRACTS.md § the claims ledger).
            if onBattery, let percent, percent <= claim.minBattery {
                _ = ledger.retire(claim, why: "battery \(percent)% below floor \(claim.minBattery)%",
                                  now: ctx.now)
                continue
            }

            // The charger went away and this claim said it needed one. The
            // assumption behind the claim is gone, so it ends now, at 90%,
            // rather than at the floor hours later.
            if claim.requireAC && onBattery {
                _ = ledger.retire(claim, why: "charger unplugged (--require-ac)", now: ctx.now)
                continue
            }

            // Approaching the floor: warn once, re-arm when the battery climbs
            // back out of the window (plugging in and later unplugging warns again).
            if onBattery, let percent, percent <= claim.minBattery + prefloorMargin {
                if !claim.prewarned {
                    claim.prewarned = true
                    ledger.write(claim, ifStillMatching: snapshot)
                    outcome.notifications.append(NotificationRequest(
                        title: "🔌 Battery \(percent)%, floor \(claim.minBattery)%",
                        subtitle: "plug in, or simmer hands the switch back soon",
                        body: claim.reason.isEmpty ? claim.owner : claim.reason,
                        actionable: true))
                    ledger.log("pre-floor warning for \(claim.owner) at \(percent)% (floor \(claim.minBattery)%)",
                               now: ctx.now)
                    ledger.event("prefloor_warn", now: ctx.now, [
                        ("owner", .string(claim.owner)),
                        ("battery", .int(percent)),
                        ("floor", .int(claim.minBattery)),
                    ])
                }
            } else if claim.prewarned {
                claim.prewarned = false
                ledger.write(claim, ifStillMatching: snapshot)
            }
        }

        // The switch follows the ledger. If that loop retired the last claim,
        // this is where the machine is handed back.
        let (ok, settleOutcome) = Engine.settle(ctx: ctx, why: "guard tick")
        outcome.merge(settleOutcome)
        if !ok {
            outcome.exit = 1
            return outcome
        }

        let aggregate = ctx.aggregate()
        guard aggregate.count > 0, let definingId = aggregate.definingId,
              var defining = ledger.claims().first(where: { $0.id == definingId }) else {
            return outcome
        }
        // As above: the copy as it was read, before the flags below move it.
        let definingSnapshot = defining

        if aggregate.until != 0 {
            // One warning, exactly once — against the AGGREGATE deadline,
            // because that is when the machine actually sleeps. The flag lives
            // on the defining claim: when that claim goes and a shorter one
            // becomes the aggregate, the new deadline gets its own warning
            // instead of inheriting a spent one.
            let left = aggregate.until - ctx.now
            if left <= warnSeconds && !defining.warned {
                defining.warned = true
                ledger.write(defining, ifStillMatching: definingSnapshot)
                let reasonPart = aggregate.reason.isEmpty ? "" : " · \(aggregate.reason)"
                outcome.notifications.append(NotificationRequest(
                    title: "☕ \(Durations.human(left)) left",
                    subtitle: "then this Mac sleeps",
                    body: "simmer +30m extends it.\(reasonPart)",
                    actionable: true))
                ledger.event("warn", now: ctx.now, [
                    ("owner", .string(defining.owner)),
                    ("until", .int(aggregate.until)),
                    ("left", .int(left)),
                ])
            }
        } else if ctx.now - defining.reminded >= remindSeconds {
            // No deadline: remind regularly. An open-ended claim must be
            // impossible to forget — the condition under which it is allowed.
            defining.reminded = ctx.now
            ledger.write(defining, ifStillMatching: definingSnapshot)
            outcome.notifications.append(NotificationRequest(
                title: "☕ Still simmering, no deadline",
                subtitle: "running \(Durations.human(ctx.now - defining.started))",
                body: defining.reason.isEmpty ? "simmer down ends it." : defining.reason,
                actionable: true))
            ledger.event("remind", now: ctx.now, [
                ("owner", .string(defining.owner)),
                ("running", .int(ctx.now - defining.started)),
            ])
        }
        return outcome
    }
}
