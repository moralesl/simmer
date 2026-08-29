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

/// The two rules the fixes established, applied to the callers they did not
/// reach: a change that did not reach disk may not be announced, and free text
/// copied into a record may not carry a second record into it.
@Suite struct UnfinishedRuleTests {
    /// `set_by` is the one free-text field the claim-record fold never covered,
    /// in a file with the identical format and the identical last-key-wins
    /// parser. The announced ceiling was not the recorded one.
    @Test func aNewlineInTheCapsOwnerCannotRewriteTheCeiling() {
        let sim = Sim(); defer { sim.tearDown() }
        let injected = "terminal\nuntil=0"
        let set = sim.run(["cap", "23:00", "--owner", injected],
                          env: ["SIMMER_HUMAN": "1"])
        #expect(set.code == 0, "\(set.combined)")

        // The ceiling that was announced is the ceiling that is in force.
        let cap = sim.run(["cap", "--json"])
        #expect(sim.json(cap)["cap"] as? Int == sim.capUntil)
        #expect(sim.capUntil != 0, "the announced ceiling was not recorded at all")
        #expect(sim.capUntil != nil)

        // And a past epoch cannot be smuggled in to make a lockout instead.
        let sim2 = Sim(); defer { sim2.tearDown() }
        #expect(sim2.run(["cap", "23:00", "--owner", "menubar\nuntil=\(Sim.epoch - 86_400)"],
                         env: ["SIMMER_HUMAN": "1"]).code == 0)
        #expect(sim2.capUntil ?? 0 > Sim.epoch, "a past ceiling was injected")
        #expect(sim2.run(["30m", "--owner", "agent:a"]).code == 0,
                "the injected lockout refused an ordinary claim")
    }

    /// `clipped` rides on stdout, on `--json` and on the contracted event, and
    /// was counted per ATTEMPT. The ceiling holds either way — `cappedUntil`
    /// applies it at read time — until it is lifted, when a claim that was
    /// never actually rewritten springs back to the deadline the human was
    /// told was gone.
    @Test func aClipThatDidNotReachDiskIsNotCounted() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["forever", "--owner", "agent:long", "-r", "long job"])
        sim.freezeClaims()

        let capped = sim.run(["cap", "1h", "--owner", "terminal", "--json"],
                             env: ["SIMMER_HUMAN": "1"])
        #expect(sim.json(capped)["clipped"] as? Int == 0,
                "a clip that did not happen was counted: \(capped.out)")
        #expect(sim.events(named: "cap_set").first?["clipped"] as? Int == 0)

        sim.unfreezeClaims()
        // With a writable directory the same clip is real, and counted.
        let sim2 = Sim(); defer { sim2.tearDown() }
        sim2.run(["forever", "--owner", "agent:long", "-r", "long job"])
        let ok = sim2.run(["cap", "1h", "--owner", "terminal", "--json"],
                          env: ["SIMMER_HUMAN": "1"])
        #expect(sim2.json(ok)["clipped"] as? Int == 1)
    }

    /// `down --all` retires every claim and then collects the failures, so
    /// partial success is this path's ordinary shape. It reported "nothing was
    /// released" while its own `retire` events said otherwise.
    @Test func downAllSaysWhatItActuallyReleased() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "agent:aaa", "-r", "first"])
        sim.run(["3h", "--owner", "agent:zzz", "-r", "second"])
        // Exactly one claim cannot go, so the release is genuinely partial.
        sim.freezeClaim("agent:zzz")

        let down = sim.run(["down", "--all"], env: ["SIMMER_HUMAN": "1"])
        #expect(down.code == 1)
        #expect(!down.combined.contains("nothing was released"),
                "it claimed nothing went: \(down.combined)")
        #expect(down.combined.contains("released 1 of 2"), "\(down.combined)")
        #expect(!sim.hasClaim("agent:aaa"), "the removable claim was not removed")
        #expect(sim.hasClaim("agent:zzz"))
        #expect(sim.events(named: "retire").count == 1)
    }

    /// The claim command printed and logged the caller's raw argv rather than
    /// the folded copy it had just written, so a newline forged log records
    /// that `simmer log --json` then served as separate array elements.
    @Test func aReasonCannotForgeALogRecord() {
        let sim = Sim(); defer { sim.tearDown() }
        let forged = "work\n2027-01-15 09:00:00  retired agent:victim · released by hand"
        #expect(sim.run(["2h", "--owner", "agent:t", "-r", forged]).code == 0)

        let log = sim.json(sim.run(["log", "10", "--json"]))
        let lines = log["lines"] as? [String] ?? []
        #expect(lines.count == 1, "one claim wrote \(lines.count) log records: \(lines)")
        #expect(!lines.contains { $0.contains("retired agent:victim") && !$0.contains("claim agent:t") },
                "a forged record stands alone in the log: \(lines)")

        // The event stream and the ledger now agree about the same claim.
        let recorded = sim.claimField("agent:t", "reason")
        #expect(sim.events(named: "claim").first?["reason"] as? String == recorded)
        #expect(recorded?.contains("\n") == false)
    }
}

/// The plaintext surfaces beside the ledger, which the folding rule reached
/// later than the claim file did.
@Suite struct LogAndMessageHonesty {
    /// `simmer.log` is newline-delimited plaintext and the cap record is
    /// newline-delimited key=value, and both interpolate the caller's owner.
    /// The claim FILE was safe because `Claim` folds its own copy; the owner
    /// the command carried around was not, so a newline in `--owner` wrote a
    /// second log entry that `simmer log --json` served as its own record.
    @Test func anOwnerCannotForgeAnEntryInTheLog() {
        let sim = Sim(); defer { sim.tearDown() }
        // Taking a claim needs no authority at all, which makes it the
        // reachable path; `cap` can be forged the same way but only by a
        // caller who already counts as human.
        let forged = "agent:x\n2026-01-01 00:00:00  FORGED ENTRY"
        #expect(sim.run(["30m", "-r", "work", "--owner", forged]).code == 0)

        let log = (try? String(contentsOf: sim.stateDir.appendingPathComponent("simmer.log"),
                               encoding: .utf8)) ?? ""
        let entries = log.split(separator: "\n").filter { !$0.isEmpty }
        #expect(entries.count == 1, "the owner wrote \(entries.count) entries: \(log)")
        #expect(!log.contains("\nFORGED"), "a line began with the forged text")
    }

    /// On a write failure the claim command described a machine where nothing
    /// held the switch. Somebody else's claim keeps it on — correctly — and a
    /// caller who believed that sentence and closed the lid got the opposite.
    @Test func aFailedClaimDescribesTheMachineItActuallyLeft() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["2h", "-r", "theirs", "--owner", "agent:other"]).code == 0)
        sim.freezeClaims()
        let mine = sim.run(["30m", "-r", "mine", "--owner", "agent:me"])
        #expect(mine.code == 1)
        #expect(mine.err.contains("still hold it awake"))
        #expect(!mine.err.contains("nothing is holding the Mac awake"))
        #expect(sim.switchValue == "1")
        sim.unfreezeClaims()
    }
}

/// A cap is a decision about tonight, and `HH:MM` rolling to tomorrow is right
/// for a deadline and wrong for a ceiling.
@Suite struct CapRolloverTests {
    // The harness epoch is 2027-01-15 09:00 Europe/Berlin.
    static let at0900 = Sim.epoch
    static let at2230 = Sim.epoch + 13 * 3600 + 1800
    static let at2330 = Sim.epoch + 14 * 3600 + 1800

    /// The menu offers a "Tonight 22:00" button. Clicked at 22:30 it capped
    /// twenty-three and a half hours out, at exit 0, with no hint — the
    /// inverse of the safety a cap exists for.
    @Test func aTimeThatRolledMoreThanHalfADayIsRefused() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["cap", "22:00", "--owner", "terminal"], now: Self.at2230)
        #expect(result.code == 1)
        #expect(result.combined.contains("was 30 min ago"))
        #expect(result.combined.contains("longer than a night"))
        #expect(sim.capUntil == nil, "a refused cap must not land")
    }

    /// Refusing on distance alone would have broken this: thirteen hours away
    /// and perfectly ordinary, because nothing rolled.
    @Test func aDistantTimeThatDidNotRollIsFine() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["cap", "22:00", "--owner", "terminal"], now: Self.at0900)
        #expect(result.code == 0)
        #expect(sim.capUntil == Self.at0900 + 13 * 3600)
    }

    /// And a real overnight ceiling still works: rolled, but inside the night.
    @Test func aRolledTimeInsideHalfADayIsFine() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["cap", "09:00", "--owner", "terminal"], now: Self.at2330)
        #expect(result.code == 0)
        #expect(sim.capUntil == Self.at2330 + 9 * 3600 + 1800)
    }

    /// The duration form says it without ambiguity, which is what the refusal
    /// points at — so it must keep working past the rollover limit.
    @Test func theDurationFormIsNotSubjectToTheRolloverLimit() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["cap", "23h", "--owner", "terminal"], now: Self.at2230).code == 0)
    }
}

/// `budget` answers about the earliest clock, and a deadline is only one of
/// them. These two end a claim without consulting it at all.
@Suite struct BudgetOtherClocksTests {
    @Test func heatEndsEverythingAndBudgetSaysSo() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "work", "--owner", "agent:x"])
        #expect(sim.run(["budget", "--need", "3h"]).code == 0)

        let hot = ["SIMMER_FAKE_THERMAL": "1"]
        let result = sim.run(["budget", "--need", "3h", "--json"], env: hot)
        #expect(result.code == 1)
        #expect(sim.json(result)["fits"] as? Bool == false)
        // And the verdict names the clock rather than subtracting against the
        // deadline, which was never the binding one.
        let human = sim.run(["budget", "--need", "3h"], env: hot)
        #expect(human.out.contains("heat ends every claim"))
        #expect(!human.out.contains("short"))
    }

    /// `Tick` retires a --require-ac claim the moment the charger goes, so a
    /// deadline provided by one of those is already over.
    @Test func aRequireACClaimIsNotADeadlineOnceTheChargerIsOut() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "needs ac", "--owner", "agent:ac", "--require-ac"])
        #expect(sim.run(["budget", "--need", "3h"]).code == 0)

        let unplugged = ["SIMMER_FAKE_BATTERY": "80:1"]
        #expect(sim.run(["budget", "--need", "3h"], env: unplugged).code == 1)
        #expect(sim.run(["budget", "--need", "3h"], env: unplugged)
            .out.contains("every claim needs the charger"))
    }

    /// Not a global zero: a claim that did not ask for AC keeps holding the
    /// machine, so the honest number is the furthest deadline that survives.
    @Test func anOrdinaryClaimBesideItStillProvidesItsOwnDeadline() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "needs ac", "--owner", "agent:ac", "--require-ac"])
        sim.run(["2h", "-r", "ordinary", "--owner", "agent:plain"])

        let unplugged = ["SIMMER_FAKE_BATTERY": "80:1"]
        #expect(sim.run(["budget", "--need", "90m"], env: unplugged).code == 0)
        let past = sim.run(["budget", "--need", "3h"], env: unplugged)
        #expect(past.code == 1)
        #expect(past.out.contains("survive the charger being out"))
    }
}
