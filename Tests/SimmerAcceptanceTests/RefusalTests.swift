import Foundation
import Testing

/// `refused_by` and exit 2 — CONTRACTS.md § Exit codes and § Surface
/// guarantees. A refusal names what refused, because the caller's next move
/// depends on it and `error` is a sentence nobody may parse: a typo is fixed
/// and retried, a cap is reported and never retried, and both used to arrive
/// as the same object at the same exit 1.
///
/// One scenario per kind, each through the built binary, each asserting the
/// field together with the exit code that goes with it.
@Suite struct RefusalKindTests {
    /// The `refused_by` of one refusing call, after checking the object around
    /// it and the exit code.
    private func refusedBy(_ sim: Sim, _ args: [String], now: Int = Sim.epoch,
                           env: [String: String] = [:], exit: Int32) -> String? {
        let result = sim.run(args + ["--json"], now: now, env: env)
        #expect(result.code == exit, "\(args) exited \(result.code), want \(exit): \(result.combined)")
        let object = sim.json(result)
        #expect(object["action"] as? String == "refused", "\(args): \(result.out)")
        #expect(!(object["error"] as? String ?? "").isEmpty, "\(args): refused with no sentence")
        return object["refused_by"] as? String
    }

    @Test(arguments: [
        ["budget", "--nede", "30m"],             // the parser: an unknown flag
        ["budget", "--need", "abc"],             // a value that does not parse
        ["claim", "5x7", "--owner", "agent"],
        ["claim", "30m", "--min-battery", "200", "--owner", "agent"],
        ["extend", "--owner", "agent"],          // how much?
        ["cap", "soon", "--owner", "terminal"],
        ["update", "--apply", "--cached"],
        ["update", "--auto", "maybe"],
    ])
    func theCallItselfIsUsageAndExitsTwo(_ args: [String]) {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(refusedBy(sim, args, exit: 2) == "usage")
        #expect(sim.claimCount == 0)
    }

    /// A deadline past 2100 is further than this tool holds one, so the
    /// argument asks for something no call can have — the call, not the
    /// machine, is what has to change. Nothing tested this path before.
    @Test func anExtensionPastTheLastDeadlineIsUsage() {
        let sim = Sim(); defer { sim.tearDown() }
        let lateIn2099 = 4_102_444_800 - 2 * 86_400
        #expect(sim.run(["1d", "--owner", "agent"], now: lateIn2099).code == 0)
        #expect(refusedBy(sim, ["+2d", "--owner", "agent"], now: lateIn2099, exit: 2) == "usage")
    }

    @Test func aPassedCapIsTheCap() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        #expect(refusedBy(sim, ["30m", "--owner", "agent"], now: Sim.epoch + 700, exit: 1) == "cap")
    }

    @Test func aClaimAlreadyAtTheCapIsTheCap() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        sim.run(["2h", "--owner", "agent"]) // lands clipped at the cap
        #expect(refusedBy(sim, ["+1h", "--owner", "agent"], exit: 1) == "cap")
    }

    @Test func aBatteryAtItsFloorIsTheFloor() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(refusedBy(sim, ["30m", "--owner", "agent"],
                          env: ["SIMMER_FAKE_BATTERY": "12:1"], exit: 1) == "floor")
        #expect(sim.switchValue == "0")
    }

    @Test func requireACOnBatteryIsTheCharger() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(refusedBy(sim, ["30m", "--require-ac", "--owner", "agent"],
                          env: ["SIMMER_FAKE_BATTERY": "80:1"], exit: 1) == "charger")
        #expect(sim.switchValue == "0")
    }

    @Test(arguments: [["cap", "1h"], ["cap", "off"], ["down", "--all"]])
    func whatOnlyAPersonMayDoIsAuthority(_ args: [String]) {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"])
        #expect(refusedBy(sim, args + ["--owner", "agent"], exit: 1) == "authority")
        #expect(sim.claimCount == 1)
    }

    @Test func extendingWithNothingToExtendIsNoClaim() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(refusedBy(sim, ["+30m", "--owner", "agent"], exit: 1) == "no_claim")
    }

    @Test(arguments: ["agent", "terminal"])
    func releasingWhenOnlyOthersHoldIsNoClaim(_ caller: String) {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "agent:other"])
        #expect(refusedBy(sim, ["down", "--owner", caller], exit: 1) == "no_claim")
        #expect(sim.claimCount == 1)
    }

    @Test func extendingAnOpenEndedClaimIsNoDeadline() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["forever", "--owner", "agent"])
        #expect(refusedBy(sim, ["+5m", "--owner", "agent"], exit: 1) == "no_deadline")
    }

    @Test func aClaimThatCannotBeRecordedIsTheSystem() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.freezeClaims()
        #expect(refusedBy(sim, ["30m", "--owner", "agent"], exit: 1) == "system")
        #expect(sim.switchValue == "0")
    }

    @Test func aSwitchThatWillNotMoveIsTheSystem() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.freezeSwitch()
        #expect(refusedBy(sim, ["30m", "--owner", "agent"], exit: 1) == "system")
        #expect(sim.claimCount == 0)
    }

    @Test func aReleaseThatCannotBeRecordedIsTheSystem() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "agent"])
        sim.freezeClaims()
        #expect(refusedBy(sim, ["down", "--owner", "agent"], exit: 1) == "system")
    }
}

/// Exit 2 is the call itself, on every verb — including the ones with no JSON
/// form, which say so on stderr.
@Suite struct UsageExitTests {
    @Test(arguments: [
        ["--not-a-thing"],
        ["status", "--bogus"],
        ["budget", "--need", "abc"],
        ["log", "--bogus"],
        ["doctor", "--bogus"],
        ["render", "bogus"],
        ["render", "raycast", "--json"],     // a verb with no JSON form
        ["run", "echo", "hi"],                // the command, but no `--`
        ["update", "--apply", "--cached"],
    ])
    func aUsageErrorExitsTwo(_ args: [String]) {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(args)
        #expect(result.code == 2, "\(args) exited \(result.code): \(result.combined)")
        #expect(!result.err.isEmpty, "\(args): a usage error with nothing said")
    }

    /// The case that made this worth a contract change. `budget`'s 1 means
    /// "not enough time left — wind down", so a typo in `--need` used to tell
    /// an agent with two hours in hand to stop working.
    @Test func aTypoInBudgetIsNotABudget() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "agent"])
        #expect(sim.run(["budget", "--need", "30m"]).code == 0)
        #expect(sim.run(["budget", "--need", "30mm"]).code == 2)
        #expect(sim.run(["budget", "--nede", "30m"]).code == 2)
    }

    /// `run` refuses its own arguments before anything starts, so its 2 can
    /// never be the command's.
    @Test func runRefusesItsOwnArgumentsBeforeStartingAnything() {
        let sim = Sim(); defer { sim.tearDown() }
        let marker = sim.root.appendingPathComponent("ran")
        let result = sim.run(["run", "--max", "abc", "--", "touch", marker.path])
        #expect(result.code == 2, "\(result.combined)")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(sim.claimCount == 0)
    }
}
