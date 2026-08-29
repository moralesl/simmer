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
    /// The path integrations should exec: the running binary, or SIMMER_BIN
    /// **when a power seam is already active**.
    ///
    /// It goes into the `bash=` of every SwiftBar row and into the commands
    /// `copyAsCLI` hands out, so an unconditional override let one environment
    /// variable decide what a person's menu bar runs when they click it. It
    /// exists for the suite, which always seams the power system too, and it
    /// is redundant in a real install — the running binary is already the
    /// installed path, symlink and all. So it is gated like the seam it is.
    public let binPath: String

    public init(env: [String: String], isTTY: Bool, executablePath: String) {
        self.env = env
        self.isTTY = isTTY
        let seamed = env["SIMMER_FAKE_PMSET"] != nil
        self.binPath = (seamed ? env["SIMMER_BIN"] : nil) ?? executablePath
    }

    /// True when any SIMMER_FAKE_* variable is set — the switch is a file, the
    /// battery is a string, and nothing this process says about the machine is
    /// about the machine.
    ///
    /// `doctor` already announced this; `status` and `budget` did not, and
    /// those are the two surfaces AGENTS.md tells an agent to trust before it
    /// starts hours of unattended work. Under a stray export — a shell rc, an
    /// .envrc, a harness that leaked, a command copied out of the test docs —
    /// `budget --need 30m` answered `fits: true` at exit 0 about a Mac that
    /// will sleep the moment the lid closes. That is the one answer the exit
    /// codes exist to make impossible.
    public var isSeamed: Bool {
        env.keys.contains { $0.hasPrefix("SIMMER_FAKE_") }
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

    // MARK: the agent protocol — SIMMER_SKILL_DIR

    /// Where `make skill` renders the agent protocol, so `doctor` can notice a
    /// stale one. Seamed like everything else: `homeDirectoryForCurrentUser`
    /// reads the passwd entry and ignores `HOME`, so without this variable a
    /// hermetic test would inspect the developer's own installed skill and pass
    /// or fail on machine state.
    ///
    /// `HOME` is consulted before the passwd entry for the same reason.
    public var skillDir: URL {
        if let override = env["SIMMER_SKILL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/skills/simmer")
    }

    /// The parent that must already exist for the protocol to be installable.
    /// `make install` writes the skill only where this is present — creating it
    /// on a Mac that does not use Claude Code would be litter.
    public var claudeHome: URL {
        skillDir.deletingLastPathComponent().deletingLastPathComponent()
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
    /// security boundary (CONTRACTS.md § the claims ledger).
    public func callerIsHuman(owner: String) -> Bool {
        if env["SIMMER_HUMAN"] == "1" { return true }
        return Self.isHumanOwnerName(owner)
    }

    /// Case-insensitively, because these are names of surfaces a person sits
    /// at rather than identifiers: `Terminal` is the app's own spelling, and
    /// reading it as a different, non-human actor is what let a capitalised
    /// name outrank the human it shares a claim file with on APFS.
    public static func isHumanOwnerName(_ owner: String) -> Bool {
        ["terminal", "menubar", "raycast", "alfred"].contains(owner.lowercased())
    }

    // MARK: run's renewal clocks

    public var runChunkSeconds: Int? {
        Durations.parse(env["SIMMER_RUN_CHUNK"] ?? "45m")
    }
    public var runIntervalSeconds: Int? {
        Durations.parse(env["SIMMER_RUN_INTERVAL"] ?? "20m")
    }

    // MARK: notifications

    /// SIMMER_NOTIFY: `none` silences; anything else is the one transport
    /// there is. v1 has exactly one — the CLI enqueues into the spool under
    /// `stateDir` and Simmer.app posts, because the grant belongs to the app's
    /// executable (PLATFORM-FACTS.md). The multi-transport world the spike had
    /// (osascript, say, a borrowed bundle) is gone: simmer posts under its own
    /// identity or not at all, so there is nothing left to choose between and
    /// no SIMMER_NOTIFIER_APP override to honour (CONTRACTS.md § test seam).
    public var notifyTransport: String { env["SIMMER_NOTIFY"] ?? "auto" }

    // MARK: the power seam

    public func makePowerSystem() -> PowerSystem {
        SeamPowerSystem(env: env, allowInteractiveSudo: isTTY && env["SIMMER_NONINTERACTIVE"] != "1")
    }
}
