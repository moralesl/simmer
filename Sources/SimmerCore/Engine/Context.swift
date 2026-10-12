import Foundation

/// Everything a command invocation needs, resolved once at the boundary (CLI
/// or app) and passed in — SimmerCore holds no globals.
public struct Context {
    public var now: Int
    public var power: PowerSystem
    public var ledger: Ledger
    public var owner: String
    /// Did the caller name itself (--owner or SIMMER_OWNER)? The anonymous-
    /// claimer nudge keys off this.
    public var ownerExplicit: Bool
    public var isHuman: Bool
    public var isTTY: Bool
    public var version: String
    /// What integrations should exec — the SwiftBar renderer embeds it.
    public var binPath: String
    /// A SIMMER_FAKE_* variable is set, so nothing this process reports about
    /// the machine is about the machine. Every machine surface says so.
    public var isSeamed: Bool

    public init(now: Int, power: PowerSystem, ledger: Ledger, owner: String,
                ownerExplicit: Bool, isHuman: Bool, isTTY: Bool,
                version: String, binPath: String, isSeamed: Bool = false) {
        self.now = now
        self.power = power
        self.ledger = ledger
        // Folded here for the same reason `Claim` folds its own copy: this
        // string is interpolated into `simmer.log`, which is newline-delimited
        // plaintext, and into the cap record, which is newline-delimited
        // key=value. The claim FILE was safe and the log was not, so a newline
        // in --owner forged whole entries that `simmer log --json` then served
        // to machine readers as separate records. One place, because the last
        // rule that landed with only its author's call sites in hand missed
        // four. `sanitizedId` maps a newline and a space to the same
        // underscore, so no claim id moves.
        self.owner = Claim.singleLine(owner, limit: Claim.maxOwnerLength)
        self.ownerExplicit = ownerExplicit
        self.isHuman = isHuman
        self.isTTY = isTTY
        self.version = version
        self.binPath = binPath
        self.isSeamed = isSeamed
    }

    public func aggregate() -> Aggregate {
        Aggregate.compute(claims: ledger.claims(), cap: ledger.readCap(now: now),
                          now: now, sleepDisabled: power.sleepDisabled())
    }
}

/// What a command wants shown, posted and returned. SimmerCore never prints;
/// the CLI and the app both render from this — which is what makes "the app
/// and the CLI cannot disagree" structural rather than aspirational.
public struct Outcome {
    public var stdout: [String] = []
    public var stderr: [String] = []
    public var exit: Int32 = 0
    public var notifications: [NotificationRequest] = []

    public init() {}

    /// Every refusal names what refused, because the caller's next move
    /// depends on it and `error` is a sentence nobody may parse. A typo is
    /// fixed and retried; a cap is reported and never retried — and both used
    /// to arrive as the same object at the same exit 1, so the only way to
    /// tell them apart was the prose the contract says may be reworded.
    ///
    /// `refusal` has no default on purpose: a new refusal cannot ship without
    /// someone deciding which kind it is.
    public static func failure(_ message: String, by refusal: Refusal, exit: Int32? = nil,
                               json: Bool = false) -> Outcome {
        var outcome = Outcome()
        outcome.exit = exit ?? refusal.exitCode
        if json {
            outcome.stdout = [JSONValue.object([
                ("action", .string("refused")),
                ("error", .string(message)),
                ("refused_by", .string(refusal.rawValue)),
            ]).serialized()]
        } else {
            outcome.stderr = ["simmer: \(message)"]
        }
        return outcome
    }

    public mutating func merge(_ other: Outcome) {
        stdout.append(contentsOf: other.stdout)
        stderr.append(contentsOf: other.stderr)
        notifications.append(contentsOf: other.notifications)
        if other.exit != 0 { exit = other.exit }
    }
}

/// What refused — `refused_by` in the refusal object, and the exit code that
/// goes with it. The raw values are machine surface: append-only, and listed in
/// CONTRACTS.md and AGENTS.md, which `StructureTests` holds in step with this.
public enum Refusal: String, CaseIterable, Sendable {
    /// The call itself: an unknown flag, a missing argument, a value that does
    /// not parse. The only kind that exits 2 — fix the call and try again.
    case usage
    /// The person's ceiling. Report it and stop; never retry with more.
    case cap
    /// The battery is at or below the claim's floor.
    case floor
    /// `--require-ac`, and the Mac is on battery.
    case charger
    /// Something only a person may do: set or lift the cap, `down --all`.
    case authority
    /// The caller holds no claim for this to act on.
    case noClaim = "no_claim"
    /// The caller's claim is open-ended, so there is no deadline to add to.
    case noDeadline = "no_deadline"
    /// simmer could not do what it was asked: a record that did not reach the
    /// disk, a switch that would not move, an update that could not be done.
    case system

    public var exitCode: Int32 { self == .usage ? 2 : 1 }
}

/// A notification the app should post — the app is the ONLY poster: macOS
/// binds the authorization to the executable that asked, so the CLI reading
/// "its own" state inside the same bundle sees notDetermined forever
/// (PLATFORM-FACTS.md). CLI and guard enqueue these into the spool; the app
/// drains and posts. The sound rides inside the payload — no afplay
/// children, or children of any other kind.
public struct NotificationRequest: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var body: String
    public var sound: Bool
    /// Carries the Extend/Release buttons. True for "you still hold time"
    /// banners; false when there is nothing sensible to extend or release.
    public var actionable: Bool

    public init(title: String, subtitle: String = "", body: String = "", sound: Bool = true,
                actionable: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
        self.actionable = actionable
    }

    /// Whether macOS will present this at all.
    ///
    /// `UNMutableNotificationContent` with a title and no informative text is
    /// accepted by `add`, reports no error, and is never shown — which is
    /// indistinguishable from a banner that worked. That is the whole of the
    /// 0.3.1 "Install it now" silence, and it shipped twice: at the start
    /// banner (T1) and, in the same click, at the ending banner (R2 finding
    /// 1). So it is a property of the type now rather than a thing to
    /// remember at 26 construction sites.
    ///
    /// Whitespace is not text: `body: " "` passes any `isEmpty` check and is
    /// presented as nothing.
    public var hasInformativeText: Bool {
        !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
