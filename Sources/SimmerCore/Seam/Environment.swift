import Foundation

/// The ONE place any SIMMER_* or XDG_STATE_HOME variable is read.
///
/// Every side effect outside the process goes through what this type hands out
/// (CONTRACTS.md, the test seam): the clock, the four power reads, the one
/// power write, state location, owner identity and notification routing. The
/// v0.1 spike leaked 222 orphaned `caffeinate` processes because one side
/// effect skipped its seam — nothing here is optional.
public struct SimmerEnvironment: Sendable {
    public let env: [String: String]
    public let isTTY: Bool
    /// The path integrations should exec — SIMMER_BIN, else the running binary.
    public let binPath: String

    public init(env: [String: String], isTTY: Bool, executablePath: String) {
        self.env = env
        self.isTTY = isTTY
        self.binPath = env["SIMMER_BIN"] ?? executablePath
    }

    // MARK: the clock — SIMMER_FAKE_NOW

    /// Epoch seconds. Relative arithmetic reads from here; absolute formatting
    /// (Formats.hhmm etc.) is deliberately unaffected by the fake.
    public func now() -> Int {
        if let fake = env["SIMMER_FAKE_NOW"], let epoch = Int(fake) { return epoch }
        return Int(Date().timeIntervalSince1970)
    }

    // MARK: state — XDG_STATE_HOME

    public var stateDir: URL {
        let base: URL
        if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state")
        }
        return base.appendingPathComponent("simmer")
    }

    // MARK: who is asking, and whether they are a person

    /// SIMMER_OWNER, else a terminal is a terminal, else a script — which is
    /// also what an agent looks like unless it says otherwise.
    /// `explicit` records whether the caller *named* itself (flag or env);
    /// the anonymous-claimer nudge keys off it.
    public func resolveOwner(flag: String?) -> (owner: String, explicit: Bool) {
        if let flag, !flag.isEmpty { return (flag, true) }
        if let envOwner = env["SIMMER_OWNER"], !envOwner.isEmpty { return (envOwner, true) }
        return (isTTY ? "terminal" : "script", false)
    }

    /// Human primacy, mechanically: enforced against honest actors, not as a
    /// security boundary (CONTRACTS.md § D1).
    public func callerIsHuman(owner: String) -> Bool {
        if env["SIMMER_HUMAN"] == "1" { return true }
        return Self.isHumanOwnerName(owner)
    }

    public static func isHumanOwnerName(_ owner: String) -> Bool {
        ["terminal", "menubar", "raycast", "alfred"].contains(owner)
    }

    // MARK: run's renewal clocks

    public var runChunkSeconds: Int? {
        Durations.parse(env["SIMMER_RUN_CHUNK"] ?? "45m")
    }
    public var runIntervalSeconds: Int? {
        Durations.parse(env["SIMMER_RUN_INTERVAL"] ?? "20m")
    }

    // MARK: notifications

    /// SIMMER_NOTIFY: auto | bundle | osascript | say | none.
    public var notifyTransport: String { env["SIMMER_NOTIFY"] ?? "auto" }

    public var notifierAppPath: String {
        env["SIMMER_NOTIFIER_APP"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Simmer.app").path
    }

    // MARK: the power seam

    public func makePowerSystem() -> PowerSystem {
        SeamPowerSystem(env: env, allowInteractiveSudo: isTTY && env["SIMMER_NONINTERACTIVE"] != "1")
    }
}
