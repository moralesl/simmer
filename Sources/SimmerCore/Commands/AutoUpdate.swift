import Foundation

/// The unattended half of `update`: may the once-a-day check install what it
/// just found, with nobody at the keyboard?
///
/// `update --apply` exists for the person who has no terminal to paste into.
/// This exists for the copy nobody opens at all — a colleague's Mac, where the
/// menu bar is the only surface and "there is an update" has been sitting in it
/// for three weeks. It is off by default, because a tool whose promise is that
/// nothing happens to your Mac unless you asked does not replace its own
/// binary on a default install.
///
/// The whole decision lives here, as a pure function, for the reason
/// `applyPlan` does: what makes an unattended install safe is a rule that can
/// be read and tested without anything being installed. The app calls it and
/// obeys it; it does not have a second opinion.
///
/// **The one thing it must never do is interrupt work.** An update quits
/// `Simmer.app`, replaces the binary the guard's LaunchAgent points at, and
/// takes a minute or two to compile — while a claim is live that is exactly the
/// lid-closed, walked-away window simmer exists to protect. So a live claim
/// is a refusal, and `Aggregate.compute` is what says whether one is live:
/// the single place that knows what is held (AGENTS.md, iron rules — a surface
/// that reads the ledger itself becomes a second implementation of it).
public enum AutoUpdate {
    /// Why not now. Four reasons, enumerated rather than collapsed into one
    /// boolean, because "nothing happened" is the answer a person gets from
    /// their menu bar and each of these needs a different thing done about it:
    /// turn it on, nothing to do, wait, or read the refusal.
    public enum NotNow: String, Sendable, Equatable {
        /// The person has not asked for unattended installs.
        case off
        /// Already current, or ahead of the newest release.
        case nothingNewer
        /// Someone — a person, an agent, a `run` — is holding this Mac awake.
        case claimIsLive
        /// There is something to install and no way to install it here: a
        /// developer's own checkout, a bundle with no installer checkout, or a
        /// check that could not be made.
        case planRefused
    }

    public enum Decision: Sendable, Equatable {
        case apply(UpdateCommand.ApplyPlan)
        /// The reason, and the sentence that names it for a log or a menu.
        case notNow(NotNow, String)
    }

    /// Pure: the person's switch, the check's answer, what is held, and the
    /// plan — one decision out.
    ///
    /// The order of the four questions is the order in which they stop
    /// mattering. `off` first, so a Mac whose owner said no is never asked
    /// what it is holding; `nothingNewer` next, because with nothing to
    /// install there is no decision to make; only then the claim, which is the
    /// one reason that will be gone by tomorrow.
    public static func decide(enabled: Bool,
                              report: UpdateCommand.Report,
                              aggregate: Aggregate,
                              plan: UpdateCommand.ApplyDecision) -> Decision {
        guard enabled else {
            return .notNow(.off, "unattended updates are off — turn them on with simmer update --auto on")
        }
        guard report.verdict == .available else {
            return .notNow(.nothingNewer, report.verdict == .unknown
                ? "cannot tell whether there is anything to install — \(report.error)"
                : "simmer \(report.installed) has nothing newer to install")
        }
        guard aggregate.count == 0 else {
            // Named rather than counted: "3 claims" tells a reader nothing
            // about whether to wait, and the owner and the countdown do.
            return .notNow(.claimIsLive, "\(aggregate.owner) is holding this Mac awake"
                + (aggregate.leftShort.isEmpty ? "" : " (\(aggregate.leftShort) left)")
                + " — simmer \(report.latestDisplay) waits for the next daily check")
        }
        switch plan {
        case .run(let plan):
            return .apply(plan)
        case .nothingToDo(let sentence):
            return .notNow(.nothingNewer, sentence)
        case .refused(let why):
            return .notNow(.planRefused, why)
        }
    }

    /// What `simmer update --auto <on|off|status>` answers.
    ///
    /// `backgroundChecksEnabled` is not decoration. Unattended installs ride
    /// on the once-a-day check — that is the only thing in simmer that looks
    /// for a release without being asked — so with the check off, `--auto on`
    /// is a switch that does nothing. Saying so is the difference between a
    /// setting and a promise nobody keeps.
    public static func settingOutcome(enabled: Bool, changed: Bool,
                                      backgroundChecksEnabled: Bool) -> Outcome {
        var outcome = Outcome()
        outcome.stdout = [enabled
            ? "✅ unattended updates are on — a new release installs itself when nothing is claimed"
            : "✅ unattended updates are off — simmer update --apply installs one when you ask"]
        if enabled {
            outcome.stdout.append(
                "   never while a claim is live; a skipped release is retried at the next daily check")
            if !backgroundChecksEnabled {
                outcome.stdout.append(
                    "   ⚠️  the once-a-day check is off, so nothing will install until it is back on")
                outcome.stdout.append(
                    "       Simmer Setup → “Check for a newer simmer once a day”, or unset SIMMER_NO_UPDATE_CHECK")
            }
        }
        if enabled, changed {
            outcome.stdout.append("   roll a bad release back: docs/FAQ.md § A release broke something")
        }
        return outcome
    }

    /// `--auto`'s machine answer. `action` follows `cap`'s two-verb shape —
    /// the direction is part of what happened, not a field to read afterwards.
    public static func settingJSON(enabled: Bool, changed: Bool,
                                   backgroundChecksEnabled: Bool, seamed: Bool) -> JSONValue {
        .object([
            ("action", .string(changed ? (enabled ? "auto_update_on" : "auto_update_off") : "checked")),
            ("auto_update", .bool(enabled)),
            // The dependency, as a field: a caller that turns this on and
            // wants to know whether it can ever fire needs both booleans, and
            // asking two commands for them is how the two drift.
            ("background_check", .bool(backgroundChecksEnabled)),
            ("seamed", .bool(seamed)),
        ])
    }
}
