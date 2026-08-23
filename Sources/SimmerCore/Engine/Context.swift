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

    public init(now: Int, power: PowerSystem, ledger: Ledger, owner: String,
                ownerExplicit: Bool, isHuman: Bool, isTTY: Bool,
                version: String, binPath: String) {
        self.now = now
        self.power = power
        self.ledger = ledger
        self.owner = owner
        self.ownerExplicit = ownerExplicit
        self.isHuman = isHuman
        self.isTTY = isTTY
        self.version = version
        self.binPath = binPath
    }

    public func aggregate() -> Aggregate {
        Aggregate.compute(claims: ledger.claims(), cap: ledger.readCap(),
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

    public static func failure(_ message: String, exit: Int32 = 1,
                               json: Bool = false) -> Outcome {
        var outcome = Outcome()
        outcome.exit = exit
        if json {
            outcome.stdout = [JSONValue.object([
                ("action", .string("refused")),
                ("error", .string(message)),
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

/// A notification the boundary should post. The sound rides inside the
/// notification payload (UNNotificationSound in the app / bundle path) — v1
/// spawns no afplay children, or children of any other kind.
public struct NotificationRequest: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var body: String
    public var sound: Bool

    public init(title: String, subtitle: String = "", body: String = "", sound: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
    }
}
