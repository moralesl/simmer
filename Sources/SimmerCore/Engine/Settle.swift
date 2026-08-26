import Foundation

/// The ONLY place that decides whether the switch stays on. Every mutation
/// ends here: a claim can be added or retired anywhere, and this one function
/// reads the ledger afterwards and puts the switch where it says it belongs.
/// That is what turns contract guarantee 2 — "no code path leaves disablesleep
/// on without something scheduled to turn it off" — from a promise into a
/// property. It reads state and settles, never applies a delta, so two callers
/// racing is harmless.
public enum Engine {
    /// Returns ok=false when the switch could not be moved — the failure
    /// branch matters more than the success one: without the sudo rule the
    /// machine simply stays awake, and that must never be quiet.
    @discardableResult
    public static func settle(ctx: Context, why: String) -> (ok: Bool, outcome: Outcome) {
        var outcome = Outcome()
        let aggregate = ctx.aggregate()

        if aggregate.count == 0 {
            if ctx.power.sleepDisabled() {
                if ctx.power.setDisableSleep(false) {
                    ctx.ledger.log("sleep allowed again (\(why))", now: ctx.now)
                    ctx.ledger.event("switch_off", now: ctx.now, [("why", .string(why))])
                    // A standing ceiling outlives every claim, and this is
                    // the moment someone concludes they have cleared
                    // everything — "Release everything" most of all. The body
                    // is free and the belief is expensive, so it is said here,
                    // once, for every path that hands the machine back rather
                    // than only the one that prompted it.
                    var banner = NotificationRequest(
                        title: "⏾ Sleep allowed again", subtitle: why)
                    if let cap = ctx.ledger.readCap(now: ctx.now) {
                        banner.body = cap.until <= ctx.now
                            ? "⛔ cap \(Formats.hhmm(cap.until)) has passed · nothing new until \(Formats.hhmm(cap.expires))"
                            : "⛔ the \(Formats.hhmm(cap.until)) ceiling stays · lifts itself at \(Formats.hhmm(cap.expires))"
                    }
                    outcome.notifications.append(banner)
                } else {
                    ctx.ledger.log("ERROR: could not revert disablesleep (\(why))", now: ctx.now)
                    outcome.notifications.append(NotificationRequest(
                        title: "⚠️ simmer could not release",
                        subtitle: "disablesleep is still on",
                        body: "Run 'simmer doctor' in a terminal."))
                    return (false, outcome)
                }
            }
        } else if !ctx.power.sleepDisabled() {
            if ctx.power.setDisableSleep(true) {
                ctx.ledger.log("restored disablesleep with \(aggregate.count) claim(s) live",
                               now: ctx.now)
                ctx.ledger.event("switch_on", now: ctx.now,
                                 [("why", .string("restored, \(aggregate.count) claim(s) live"))])
            } else {
                ctx.ledger.log("ERROR: could not set disablesleep with \(aggregate.count) claim(s) live",
                               now: ctx.now)
                return (false, outcome)
            }
        }
        return (true, outcome)
    }
}
