import Foundation
import Testing

/// Written fresh against CONTRACTS.md. Every scenario drives the built binary
/// through its public surface; state files are only ever *read* back — a
/// fixture that mutates state behind the implementation is how the spike's
/// suite leaked (LEARNINGS.md).
@Suite struct DurationTests {
    @Test(arguments: ["90", "90m", "1h", "1h30m", "45min", "2h15", "30s", "2H"])
    func acceptsDuration(_ text: String) {
        let sim = Sim(); defer { sim.tearDown() }
        // budget parses without claiming anything; exit 3 = parsed fine, no claim.
        let result = sim.run(["budget", "--need", text])
        #expect(result.code == 3)
        #expect(!result.combined.contains("did not understand"))
    }

    @Test(arguments: ["5x7", "abc", "1h2x", "0m"])
    func rejectsDuration(_ text: String) {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["budget", "--need", text])
        #expect(result.code == 1)
        #expect(result.combined.contains("did not understand"))
    }
}

@Suite struct ClaimTests {
    @Test func takeSetsSwitchAndDownClearsIt() {
        let sim = Sim(); defer { sim.tearDown() }
        let take = sim.run(["30m", "-r", "take", "--owner", "test"])
        #expect(take.code == 0)
        #expect(sim.switchValue == "1")
        #expect(sim.run(["status"]).out.contains("take"))
        let down = sim.run(["down", "--owner", "test"])
        #expect(down.code == 0)
        #expect(sim.switchValue == "0")
    }

    @Test func refusesBelowTheFloorWithoutTouchingTheSwitch() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["30m", "--min-battery", "20", "--owner", "test"],
                             env: ["SIMMER_FAKE_BATTERY": "10:1"])
        #expect(result.code == 1)
        #expect(result.err.contains("floor"))
        #expect(sim.switchValue == "0")
    }

    @Test func requireACRefusesOnBattery() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["30m", "--require-ac", "--owner", "test"],
                             env: ["SIMMER_FAKE_BATTERY": "90:1"])
        #expect(result.code == 1)
        #expect(result.err.contains("on battery"))
    }

    @Test func noDurationIsARefusalNotACrash() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["claim", "--owner", "test"])
        #expect(result.code == 1)
        #expect(result.err.contains("no duration given"))
    }

    @Test func untilTakesAnAbsoluteTime() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["--until", "23:59", "--owner", "test"])
        #expect(result.code == 0)
        let until = Int(sim.claimField("test", "until") ?? "") ?? 0
        #expect(until > Sim.epoch)
        #expect((until - Sim.epoch) <= 86_400)
    }

    @Test func fakeClockDrivesRelativeArithmetic() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["1h", "--owner", "fn"])
        #expect(sim.claimField("fn", "until") == String(Sim.epoch + 3600))
        #expect(sim.run(["budget", "--seconds"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines) == "3600")
        // The log is stamped from the fake clock (absolute formatting of the
        // fake epoch — 2027 in Europe/Berlin).
        sim.run(["extend", "+5m", "--owner", "fn"])
        let log = sim.run(["log", "5"]).out
        #expect(log.contains("2027-01-15"))
    }

    @Test func claimsAreCountedNotOwned() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "-r", "human", "--owner", "terminal"])
        sim.run(["30m", "-r", "bot", "--owner", "agent"])
        #expect(sim.claimCount == 2)
        // The aggregate is the latest deadline.
        let left = sim.run(["status", "--machine"]).lines
            .first { $0.hasPrefix("left=") }.flatMap { Int($0.dropFirst(5)) } ?? 0
        #expect(left > 7000)
        #expect(sim.run(["status", "--machine"]).out.contains("claim_count=2"))
        let status = sim.run(["status"]).out
        #expect(status.contains("agent · bot"))
        #expect(status.contains("terminal · human"))
    }

    @Test func takingAgainReplacesOnlyMyOwnClaim() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "-r", "human", "--owner", "terminal"])
        sim.run(["30m", "-r", "bot", "--owner", "agent"])
        sim.run(["45m", "-r", "bot2", "--owner", "agent"])
        #expect(sim.claimCount == 2)
        #expect(sim.claimField("terminal", "reason") == "human")
        #expect(sim.claimField("agent", "reason") == "bot2")
        // Replacing your own claim keeps its original start time.
        sim.run(["1h", "-r", "again", "--owner", "agent"], now: Sim.epoch + 100)
        #expect(sim.claimField("agent", "started") == String(Sim.epoch))
    }

    @Test func extendMovesOnlyMyClaimFromNow() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"])
        sim.run(["30m", "--owner", "agent"])
        let othersUntil = sim.claimField("terminal", "until")
        let extend = sim.run(["+10m", "--owner", "agent"], now: Sim.epoch + 60)
        #expect(extend.code == 0)
        #expect(sim.claimField("terminal", "until") == othersUntil)
        // From now, not from the old deadline.
        #expect(sim.claimField("agent", "until") == String(Sim.epoch + 60 + 600))
    }

    @Test func extendNeedsAClaimOfYourOwn() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"])
        let result = sim.run(["+10m", "--owner", "nobody"])
        #expect(result.code == 1)
        #expect(result.err.contains("no claim of yours"))
    }

    @Test func extendUnderAForeverClaimNeverFormatsEpochZero() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["forever", "-r", "n", "--owner", "agent"])
        sim.run(["1h", "-r", "m", "--owner", "terminal"])
        let result = sim.run(["+30m", "--owner", "terminal"])
        #expect(result.out.contains("until further notice"))
        #expect(!result.out.contains("01:00"))
    }

    @Test func forceIsADocumentedNoOp() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["20m", "--owner", "agent", "--force"])
        #expect(result.code == 0)
        #expect(result.err.contains("no longer does anything"))
    }

    @Test func releasingMineLeavesTheirsAndTheLastOneOutFlipsTheSwitch() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"])
        sim.run(["45m", "--owner", "agent"])
        sim.run(["down", "--owner", "agent"])
        #expect(sim.hasClaim("terminal"))
        #expect(!sim.hasClaim("agent"))
        #expect(sim.switchValue == "1")
        sim.run(["down", "--owner", "terminal"])
        #expect(sim.switchValue == "0")
    }

    @Test func anonymousNonTTYClaimerGetsOneNudge() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["15m"])
        #expect(result.code == 0)
        #expect(result.err.contains("claimed as \"script\""))
        #expect(result.err.contains("--owner agent:"))
    }

    @Test func foreverClaimIsOpenEnded() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["forever", "-r", "long", "--owner", "test"])
        #expect(result.code == 0)
        #expect(result.out.contains("no deadline"))
        #expect(sim.claimField("test", "until") == "0")
        #expect(sim.run(["status", "--machine"]).out.contains("state=forever"))
    }
}
