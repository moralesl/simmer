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

    @Test func aHumanHoldingNothingIsPointedAtAllAndNothingMoves() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "-r", "bot", "--owner", "agent"])
        let result = sim.run(["down", "--owner", "terminal"])
        #expect(result.code == 1)
        // Told whose the claims are, and handed the explicit spelling.
        #expect(result.err.contains("agent"))
        #expect(result.err.contains("down --all"))
        #expect(sim.claimCount == 1)
        #expect(sim.switchValue == "1")
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

@Suite struct OwnerCaseTests {
    /// APFS folds case, so `Terminal` and `terminal` were one claim file. The
    /// second claim destroyed the first — a four-hour human claim replaced by
    /// a one-minute one, no refusal, no stderr, and no `retire` event, so the
    /// audit trail could not show that the claim had ever died.
    @Test func aCapitalisedNameCannotTakeOverAHumansClaim() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["4h", "-r", "overnight render", "--owner", "terminal"]).code == 0)
        #expect(sim.run(["1m", "-r", "quick lint", "--owner", "Terminal"]).code == 0)

        let status = sim.run(["status", "--machine"]).out
        #expect(status.contains("claim_count=2"))
        // The human's four hours is still the deadline that holds.
        #expect(status.contains("left_short=4h00"))
        #expect(sim.run(["status"]).out.contains("overnight render"))
    }

    /// And the capitalised spelling is the same person, not a second actor
    /// that outranks them — `Terminal` is what the app calls itself.
    @Test func theHumanNamesAreRecognisedWhateverTheirCase() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["cap", "10m", "--owner", "Terminal"]).code == 0)
        #expect(sim.run(["cap", "off", "--owner", "MenuBar"]).code == 0)
        #expect(sim.run(["cap", "10m", "--owner", "agent:evals"]).code == 1)
    }
}

@Suite struct CapTests {
    /// `cap off` announced the lift on stdout, in `--json` and on the event
    /// stream without checking that the file had gone — so a passed cap could
    /// survive its own lift and go on refusing every claim while naming this
    /// command as the way out of it.
    @Test func capOffRefusesRatherThanAnnounceALiftThatDidNotHappen() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["cap", "10m", "--owner", "terminal"]).code == 0)
        sim.freezeState()
        let lift = sim.run(["cap", "off", "--owner", "terminal", "--json"])
        #expect(lift.code == 1)
        #expect(!lift.out.contains("cap_lifted"))
        sim.unfreezeState()
        #expect(sim.capUntil != nil)
        #expect(sim.run(["cap", "off", "--owner", "terminal"]).code == 0)
        #expect(sim.capUntil == nil)
    }

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

    @Test func aPassedCapKeepsRefusingAndNamesBothWaysOut() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        let claim = sim.run(["30m", "--owner", "terminal"], now: Sim.epoch + 700)
        #expect(claim.code == 1)
        // Two exits, and the refusal must name both: the one that costs a
        // command, and the one that costs nothing.
        #expect(claim.err.contains("cap off"))
        #expect(claim.err.contains("09:00"))
        sim.run(["cap", "off", "--owner", "terminal"], now: Sim.epoch + 700)
        let afterLift = sim.run(["30m", "--owner", "terminal"], now: Sim.epoch + 700)
        #expect(afterLift.code == 0)
    }

    /// The morning-after rule. A ceiling set on Tuesday evening answered a
    /// question about Tuesday night; on Wednesday it is a lockout nobody chose,
    /// and the surface explaining how to undo it was a toast seen hours ago.
    /// So it stops applying on its own — no command, nothing to remember.
    @Test func aCapLiftsItselfAtTheNextRollover() {
        let sim = Sim(); defer { sim.tearDown() }
        // Sim.epoch is 09:00 Berlin, so a 10-minute cap expires at the FOLLOWING
        // 09:00 — the first rollover strictly after the ceiling itself.
        sim.run(["cap", "10m", "--owner", "terminal"])
        let rollover = Sim.epoch + 86_400

        // The whole night in between is still a real gate: that is the half of
        // the bargain the person who set the cap was actually buying.
        #expect(sim.run(["30m", "--owner", "agent"], now: rollover - 60).code == 1)

        // And at the rollover it is simply gone — for claiming...
        #expect(sim.run(["30m", "--owner", "agent"], now: rollover).code == 0)
        // ...and for every surface that reports it.
        #expect(sim.run(["cap"], now: rollover).out.contains("no cap"))
        let status = sim.json(sim.run(["status", "--json"], now: rollover))
        #expect(status["cap"] as? Int == 0)
    }

    /// Releasing claims never lifts the ceiling — correct, and invisible until
    /// it refuses you hours later. Every release path says so, because a rule
    /// that holds for "release everything" and not for "release mine" is one
    /// nobody can predict.
    @Test func everyReleaseSaysTheCeilingStays() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "3h", "--owner", "terminal"])
        sim.run(["1h", "--owner", "terminal"])
        sim.run(["1h", "--owner", "agent:evals"])

        let mine = sim.run(["down", "--owner", "terminal"])
        #expect(mine.out.contains("ceiling stays"))
        #expect(mine.out.contains("09:00"))   // and when it stops standing

        let all = sim.run(["down", "--all", "--owner", "terminal"])
        #expect(all.out.contains("ceiling stays"))

        // No cap, no note: this must not become a line on every release.
        sim.run(["cap", "off", "--owner", "terminal"])
        sim.run(["1h", "--owner", "terminal"])
        #expect(!sim.run(["down", "--owner", "terminal"]).out.contains("ceiling"))
    }

    /// Machine callers get the same fact as a number, so a surface composing
    /// its own sentence never hardcodes the rollover hour.
    @Test func theAggregateTailCarriesWhenTheCapLifts() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "3h", "--owner", "terminal"])
        let claimed = sim.json(sim.run(["30m", "--owner", "terminal", "--json"]))
        #expect(claimed["cap_expires"] as? Int == Sim.epoch + 86_400)

        sim.run(["cap", "off", "--owner", "terminal"])
        let uncapped = sim.json(sim.run(["extend", "+10m", "--owner", "terminal", "--json"]))
        #expect(uncapped["cap_expires"] as? Int == 0)
    }

    /// The read path retires an expired cap, but the file would sit in the
    /// state directory looking live. The guard sweeps it, on an idle Mac too —
    /// which is exactly where a spent ceiling waits.
    @Test func theGuardSweepsAnExpiredCapAndSaysSo() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        #expect(sim.capUntil != nil)

        sim.run(["guard"], now: Sim.epoch + 3600)
        #expect(sim.capUntil != nil)   // the night is not over yet

        sim.run(["guard"], now: Sim.epoch + 86_400)
        #expect(sim.capUntil == nil)
        #expect(sim.events().contains { $0["event"] as? String == "cap_expired" })
    }

    /// A cap written before caps expired carries no `expires` key. It must
    /// retire on the same rule as any other, or the upgrade would strand
    /// precisely the ceiling this change exists to release.
    @Test func aCapFileFromBeforeExpiryStillRetires() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        let file = sim.stateDir.appendingPathComponent("cap")
        let legacy = (try? String(contentsOf: file, encoding: .utf8))!
            .split(separator: "\n").filter { !$0.hasPrefix("expires=") }
            .joined(separator: "\n") + "\n"
        try! legacy.write(to: file, atomically: true, encoding: .utf8)
        #expect(!legacy.contains("expires="))

        #expect(sim.run(["30m", "--owner", "agent"], now: Sim.epoch + 700).code == 1)
        #expect(sim.run(["30m", "--owner", "agent"], now: Sim.epoch + 86_400).code == 0)
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

/// One claim per owner is the rule, and replacing your own is how you move a
/// deadline. The gap was that nothing said when a replacement made the
/// deadline EARLIER — and under the anonymous default the two claims usually
/// belong to two different callers.
@Suite struct ReplacementTests {
    /// Two agents that both forget `--owner` are both "script". A one-minute
    /// claim replaced a four-hour one and the only sign was a nudge about
    /// slots, which says nothing about what was just lost. AGENTS.md: "no
    /// surface may cost a caller awake time it already holds."
    @Test func anAnonymousClaimThatShortensAnotherSaysSo() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["4h", "-r", "long eval"]).code == 0)
        let second = sim.run(["1m", "-r", "quick thing"])
        #expect(second.code == 0)
        #expect(second.err.contains("already held a claim"))
        #expect(second.err.contains("long eval"))
        #expect(second.err.contains("both of you need --owner"))
    }

    /// A named caller shortening its own deadline is ordinary — one line, not
    /// the collision warning.
    @Test func anOwnedClaimThatShortensItsOwnSaysItMoreQuietly() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "eval", "--owner", "agent:evals"])
        let second = sim.run(["10m", "-r", "eval", "--owner", "agent:evals"])
        #expect(second.code == 0)
        #expect(second.err.contains("replaces your earlier claim"))
        #expect(!second.err.contains("both of you need"))
    }

    /// Extending says nothing: nobody lost anything.
    @Test func aReplacementThatLengthensIsSilent() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "-r", "eval", "--owner", "agent:evals"])
        let longer = sim.run(["4h", "-r", "eval", "--owner", "agent:evals"])
        #expect(longer.code == 0)
        #expect(!longer.err.contains("replaces"))
        #expect(!longer.err.contains("already held"))
    }

    /// Trading an open-ended claim for a deadline is a shortening, and the one
    /// case where comparing epochs the naive way gets it backwards.
    @Test func replacingAnOpenEndedClaimWithADeadlineCounts() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["forever", "-r", "render", "--owner", "agent:render"])
        let bounded = sim.run(["30m", "-r", "render", "--owner", "agent:render"])
        #expect(bounded.err.contains("no deadline"))
        // And the other way round is not.
        let back = sim.run(["forever", "-r", "render", "--owner", "agent:render"])
        #expect(!back.err.contains("replaces"))
    }
}
