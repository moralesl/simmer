import Foundation
import Testing

/// Written fresh against CONTRACTS.md. Every scenario drives the built binary
/// through its public surface; state files are only ever *read* back — a
/// fixture that mutates state behind the implementation is how the spike's
/// suite leaked (PLATFORM-FACTS.md).
@Suite struct DurationTests {
    @Test(arguments: ["90", "90m", "1h", "1h30m", "45min", "2h15", "30s", "2H", "1d", "1d12h"])
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
        // Same calendar day: no day qualifier to add.
        #expect(!result.out.contains("tomorrow"))
    }

    /// A deadline on another day must say so. The fixed epoch is 09:00 in
    /// Europe/Berlin, so 08:00 means tomorrow — and "until 08:00" alone reads
    /// as a time that has already gone.
    @Test func aDeadlineOnAnotherDaySaysWhichDay() {
        let sim = Sim(); defer { sim.tearDown() }
        let wrapped = sim.run(["--until", "08:00", "--owner", "test"])
        #expect(wrapped.code == 0)
        #expect(wrapped.out.contains("tomorrow"))
        #expect(sim.claimField("test", "until") == String(Sim.epoch + 23 * 3600))
        // Status agrees with the claim that made it.
        #expect(sim.run(["status"]).out.contains("tomorrow"))
        // A day-long claim lands tomorrow too, by the same rule.
        #expect(sim.run(["1d", "--owner", "long"]).out.contains("tomorrow"))
        #expect(sim.claimField("long", "until") == String(Sim.epoch + 86_400))
    }

    /// The switch flips before the claim file lands. If the claim cannot be
    /// recorded, nothing holds the machine awake and nothing schedules it back
    /// down — so this must refuse and hand the switch back, never print a
    /// deadline for a claim that does not exist.
    @Test func aClaimThatCannotBeRecordedIsRefusedNotAnnounced() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.freezeClaims()
        let result = sim.run(["2h", "-r", "doomed", "--owner", "test"])
        #expect(result.code == 1)
        #expect(result.err.contains("could not record the claim"))
        #expect(!result.out.contains("simmering until"))
        // The machine is left as it was found.
        #expect(sim.switchValue == "0")
        sim.unfreezeClaims()
        #expect(sim.claimCount == 0)
        #expect(sim.run(["status"]).out.contains("sleep allowed"))
    }

    @Test func releasingTheLastClaimSaysTheMachineCanSleepAgain() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "test"])
        let result = sim.run(["down", "--owner", "test"])
        #expect(result.out.contains("sleep allowed again"))
        #expect(sim.switchValue == "0")
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

    @Test func extendAddsToMyClaimAndTouchesNobodyElses() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"])
        sim.run(["30m", "--owner", "agent"])
        let othersUntil = sim.claimField("terminal", "until")
        let extend = sim.run(["+10m", "--owner", "agent"], now: Sim.epoch + 60)
        #expect(extend.code == 0)
        #expect(sim.claimField("terminal", "until") == othersUntil)
        // Added to the deadline it had (epoch+1800), NOT set to now+10m.
        #expect(sim.claimField("agent", "until") == String(Sim.epoch + 1800 + 600))
        #expect(extend.out.contains("10 min added"))
    }

    /// The regression this semantics change exists for: `+15m` on a long claim
    /// used to leave fifteen minutes and call it "extended", discarding hours
    /// of awake time — the one failure the whole tool exists to prevent.
    @Test func extendingALongClaimByALittleNeverShortensIt() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "overnight eval", "--owner", "agent:evals"])
        let before = Int(sim.claimField("agent:evals", "until") ?? "0") ?? 0
        let result = sim.run(["+15m", "--owner", "agent:evals"])
        #expect(result.code == 0)
        let after = Int(sim.claimField("agent:evals", "until") ?? "0") ?? 0
        #expect(after == before + 900)
        #expect(after > before)
    }

    /// A claim whose deadline has passed but which the guard has not retired
    /// yet: adding to the stale deadline would land the extension in the past,
    /// producing a still-expired claim reported as extended.
    @Test func extendingAStaleDeadlineCountsFromNow() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["10m", "--owner", "agent"])
        let late = Sim.epoch + 3600
        let result = sim.run(["+10m", "--owner", "agent"], now: late)
        #expect(result.code == 0)
        #expect(sim.claimField("agent", "until") == String(late + 600))
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

/// A bare duration past half a day says so — and says the useful thing, which
/// differs by power source.
///
/// `simmer 2000` is 33 h 20 min and is a far likelier typo for `--until 20:00`
/// than an intention. Never a refusal: overnight is a first-class case.
@Suite struct LongHaulTests {
    @Test func onBatteryTheNoteNamesTheFloorNotAFlagYouCannotUse() {
        let sim = Sim(); defer { sim.tearDown() }
        let out = sim.run(["2000", "--owner", "test"],
                          env: ["SIMMER_FAKE_BATTERY": "80:1"]).out
        #expect(out.contains("note:"), "\(out)")
        #expect(out.contains("floor ends this"), "\(out)")
        // --require-ac is refused outright on battery, so recommending it here
        // would be advice the reader cannot act on.
        #expect(!out.contains("--require-ac"), "\(out)")
    }

    @Test func onACTheNoteRecommendsRequireAC() {
        let sim = Sim(); defer { sim.tearDown() }
        let out = sim.run(["2000", "--owner", "test"],
                          env: ["SIMMER_FAKE_BATTERY": "80:0"]).out
        #expect(out.contains("--require-ac"), "\(out)")
    }

    @Test func aClaimThatAlreadyAskedForACIsNotToldTo() {
        let sim = Sim(); defer { sim.tearDown() }
        let out = sim.run(["1d", "--require-ac", "--owner", "test"],
                          env: ["SIMMER_FAKE_BATTERY": "80:0"]).out
        #expect(out.contains("ends if the charger is unplugged"), "\(out)")
        #expect(!out.contains("note: over"), "\(out)")
    }

    /// The threshold has to leave ordinary claims alone — the note is worth
    /// nothing if it fires on a two-hour build.
    @Test func ordinaryDurationsGetNoNote() {
        let sim = Sim(); defer { sim.tearDown() }
        for duration in ["30m", "2h", "8h"] {
            let out = sim.run([duration, "--owner", "test"],
                              env: ["SIMMER_FAKE_BATTERY": "80:1"]).out
            #expect(!out.contains("note:"), "\(duration): \(out)")
        }
    }

    /// `forever` has no deadline to compare, and must not divide by an epoch
    /// of 0 — which would read as a very long claim indeed.
    @Test func foreverGetsNoLongHaulNote() {
        let sim = Sim(); defer { sim.tearDown() }
        let out = sim.run(["forever", "--owner", "test"],
                          env: ["SIMMER_FAKE_BATTERY": "80:1"]).out
        #expect(!out.contains("note:"), "\(out)")
    }
}
