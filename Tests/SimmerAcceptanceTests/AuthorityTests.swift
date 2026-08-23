import Foundation
import Testing

/// Human primacy and the cap — CONTRACTS.md § D1. A human may release ANY
/// claim, an agent only its own; the cap clips every claim present and future,
/// and a passed cap keeps refusing until a human moves it.
@Suite struct HumanPrimacyTests {
    @Test func anAgentCannotDownAll() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "-r", "human", "--owner", "terminal"])
        sim.run(["30m", "-r", "bot", "--owner", "agent"])
        let result = sim.run(["down", "--all", "--owner", "agent"])
        #expect(result.code == 1)
        #expect(result.err.contains("only a person"))
        // ...and is told whose the claims are; nothing was released.
        #expect(result.err.contains("terminal"))
        #expect(sim.claimCount == 2)
    }

    @Test func anAgentHoldingNothingIsRefused() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "-r", "bot", "--owner", "agent"])
        let result = sim.run(["down", "--owner", "stranger"])
        #expect(result.code == 1)
        #expect(result.err.contains("not yours"))
        #expect(sim.claimCount == 1)
    }

    @Test func aHumanMayReleaseAnything() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"])
        sim.run(["30m", "--owner", "agent"])
        let result = sim.run(["down", "--all", "--owner", "terminal"])
        #expect(result.code == 0)
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
    }

    @Test func aHumanHoldingNothingClearsAllAndIsToldWhose() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "-r", "bot", "--owner", "agent"])
        let result = sim.run(["down", "--owner", "terminal"])
        #expect(result.code == 0)
        #expect(result.out.contains("agent"))
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
    }

    @Test func simmerHumanGrantsAuthorityRegardlessOfOwner() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "agent"])
        let result = sim.run(["down", "--all", "--owner", "ci"],
                             env: ["SIMMER_HUMAN": "1"])
        #expect(result.code == 0)
        #expect(sim.claimCount == 0)
    }
}

@Suite struct OrphanTests {
    @Test func revertingAnOrphanIsAllowedToAnyone() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.setSwitch(true) // set by hand, nothing claiming it
        #expect(sim.run(["status", "--machine"]).out.contains("state=orphan"))
        let result = sim.run(["down", "--owner", "agent"]) // an agent, on purpose
        #expect(result.code == 0)
        #expect(sim.switchValue == "0")
    }

    @Test func theGuardHealsAnOrphan() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.setSwitch(true)
        let result = sim.run(["guard"])
        #expect(result.code == 0)
        #expect(sim.switchValue == "0")
        #expect(sim.events(named: "orphan_heal").count == 1)
    }
}

@Suite struct CapTests {
    @Test func onlyAHumanSetsOrLiftsTheCap() {
        let sim = Sim(); defer { sim.tearDown() }
        let set = sim.run(["cap", "10m", "--owner", "agent"])
        #expect(set.code == 1)
        #expect(set.err.contains("only a person"))
        sim.run(["cap", "10m", "--owner", "terminal"])
        let lift = sim.run(["cap", "off", "--owner", "agent"])
        #expect(lift.code == 1)
        let humanLift = sim.run(["cap", "off", "--owner", "terminal"])
        #expect(humanLift.code == 0)
    }

    @Test func theCapClipsExistingClaimsImmediately() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "agent"])
        let result = sim.run(["cap", "10m", "--owner", "terminal"])
        #expect(result.code == 0)
        #expect(result.out.contains("clipped 1 claim"))
        #expect(sim.claimField("agent", "until") == String(Sim.epoch + 600))
    }

    @Test func newClaimsAreClippedAndSaySo() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        let result = sim.run(["2h", "--owner", "agent", "--json"])
        #expect(result.code == 0)
        let object = sim.json(result)
        #expect(object["clipped_by_cap"] as? Bool == true)
        #expect(object["until"] as? Int == Sim.epoch + 600)
        #expect(object["capped"] as? Bool == true)
    }

    @Test func extendAtTheCapIsRefused() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        sim.run(["2h", "--owner", "agent"]) // lands clipped at the cap
        let result = sim.run(["+1h", "--owner", "agent"])
        #expect(result.code == 1)
        #expect(result.err.contains("already at the cap"))
    }

    @Test func aPassedCapKeepsRefusingAndNamesTheFix() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        let claim = sim.run(["30m", "--owner", "terminal"], now: Sim.epoch + 700)
        #expect(claim.code == 1)
        #expect(claim.err.contains("cap off"))
        // ...in every surface: extend hits the same wall.
        sim.run(["cap", "off", "--owner", "terminal"], now: Sim.epoch + 700)
        let afterLift = sim.run(["30m", "--owner", "terminal"], now: Sim.epoch + 700)
        #expect(afterLift.code == 0)
    }

    @Test func foreverUnderACapIsADeadlineNotALie() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "1h", "--owner", "terminal"])
        sim.run(["forever", "--owner", "agent"])
        let machine = sim.run(["status", "--machine"]).out
        #expect(machine.contains("state=active"))
        #expect(machine.contains("until=\(Sim.epoch + 3600)"))
    }

    @Test func budgetTellsTheTruthAboutTheCap() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "30m", "--owner", "terminal"])
        sim.run(["2h", "--owner", "agent"])
        let result = sim.run(["budget", "--need", "1h", "--json"])
        #expect(result.code == 1) // does not fit
        let object = sim.json(result)
        #expect(object["fits"] as? Bool == false)
        #expect(object["capped"] as? Bool == true)
        // The human answer names the cap, so an agent reports it instead of
        // retrying with a bigger number.
        let prose = sim.run(["budget", "--need", "1h"])
        #expect(prose.out.contains("cap"))
    }
}
