import Foundation
import Testing

/// "Your process keeps running; your guarantee is gone, and nothing tells you"
/// (AGENTS.md). These tests are about the moment that changes: the release.
/// `simmer down` answers `held` — was the caller's claim live until this very
/// call — and `lapsed`, what ended it when it was not, read back from the
/// `retire` event's new `by` field.
///
/// The exit code moves for exactly one shape: a caller whose claim ENDED,
/// asking to release while others still hold. That used to be refused as
/// reaching for someone else's time; it is now exit 0 with the lapse, because
/// nothing was asked that could be refused. A caller with no history at all
/// is still refused, and that is asserted here too.
@Suite struct LapseTests {
    @Test func aClaimReleasedByItsOwnerHeld() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["30m", "--owner", "agent:x"]).code == 0)
        let down = sim.run(["down", "--owner", "agent:x", "--json"])
        #expect(down.code == 0)
        // Raw text: `as? Bool` would accept a 0/1 that the contract forbids.
        #expect(down.out.contains("\"held\":true"))
        #expect(down.out.contains("\"lapsed\":null"))
        let retire = sim.events(named: "retire")
        #expect(retire.count == 1)
        #expect(retire.first?["by"] as? String == "agent:x")
    }

    @Test func aClaimTheGuardEndedIsReportedAsLapsedAtRelease() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["30m", "--owner", "agent:x"]).code == 0)
        #expect(sim.run(["guard"], now: Sim.epoch + 1801).code == 0)
        #expect(sim.claimCount == 0)

        let down = sim.run(["down", "--owner", "agent:x", "--json"], now: Sim.epoch + 1900)
        #expect(down.code == 0)
        #expect(down.out.contains("\"action\":\"released\""))
        #expect(down.out.contains("\"released\":[]"))
        #expect(down.out.contains("\"held\":false"))
        let lapsed = sim.json(down)["lapsed"] as? [String: Any]
        #expect(lapsed?["why"] as? String == "time is up")
        #expect(lapsed?["by"] as? String == "guard")
        #expect(lapsed?["at"] as? Int == Sim.epoch + 1801)
        #expect(lapsed?["until"] as? Int == Sim.epoch + 1800)

        let human = sim.run(["down", "--owner", "agent:x"], now: Sim.epoch + 1900)
        #expect(human.code == 0)
        #expect(human.out.contains("may have slept"))
        #expect(human.out.contains("time is up"))
    }

    @Test func theBatteryFloorIsALapseToo() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["2h", "--min-battery", "20", "--owner", "agent:x"],
                        env: ["SIMMER_FAKE_BATTERY": "90:1"]).code == 0)
        sim.run(["guard"], now: Sim.epoch + 60, env: ["SIMMER_FAKE_BATTERY": "15:1"])
        let down = sim.run(["down", "--owner", "agent:x", "--json"], now: Sim.epoch + 120)
        #expect(down.code == 0)
        let lapsed = sim.json(down)["lapsed"] as? [String: Any]
        let why = lapsed?["why"] as? String
        #expect(why?.contains("below floor") == true, "why was \(why ?? "absent")")
        #expect(lapsed?["by"] as? String == "guard")
    }

    /// The one exit code that moves. An honest agent whose claim the guard
    /// ended was told "these are not yours to end" at exit 1 — true about
    /// the other claims, false about the agent, and silent about the lapse.
    @Test func aLapseIsReportedAtExitZeroWhileOthersStillHold() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["30m", "--owner", "agent:x"]).code == 0)
        #expect(sim.run(["4h", "--owner", "terminal"]).code == 0)
        sim.run(["guard"], now: Sim.epoch + 1801)
        #expect(sim.claimCount == 1)

        let down = sim.run(["down", "--owner", "agent:x", "--json"], now: Sim.epoch + 1900)
        #expect(down.code == 0)
        #expect(down.out.contains("\"held\":false"))
        #expect(down.out.contains("\"released\":[]"))
        #expect(down.out.contains("\"claim_count\":1"))
        // The other claim is untouched, and the human sentence says so.
        #expect(sim.claimCount == 1)
        #expect(sim.switchValue == "1")
        let human = sim.run(["down", "--owner", "agent:x"], now: Sim.epoch + 1900)
        #expect(human.out.contains("still live"))
        #expect(!human.combined.contains("not yours"))
    }

    /// Reaching for a release with no claim and no history is still a
    /// refusal: the lapse path answers only about a claim that existed.
    @Test func aCallerWithNoHistoryIsStillRefused() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["4h", "--owner", "terminal"]).code == 0)
        let down = sim.run(["down", "--owner", "agent:never", "--json"])
        #expect(down.code == 1)
        #expect(down.out.contains("\"action\":\"refused\""))
        #expect(!down.out.contains("\"held\""))
    }

    /// A caller who claimed again after a lapse knew about it — `budget` said
    /// exit 3 — so the release answers about the claim being handed back, not
    /// about history.
    @Test func aFreshClaimAfterALapseHeld() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["30m", "--owner", "agent:x"]).code == 0)
        sim.run(["guard"], now: Sim.epoch + 1801)
        #expect(sim.run(["30m", "--owner", "agent:x"], now: Sim.epoch + 1900).code == 0)
        let down = sim.run(["down", "--owner", "agent:x", "--json"], now: Sim.epoch + 2000)
        #expect(down.code == 0)
        #expect(down.out.contains("\"held\":true"))
        #expect(down.out.contains("\"lapsed\":null"))
    }

    /// Releasing twice is not a lapse: the owner ended it, and the event says
    /// so. The second call keeps its old answer, with the two fields appended.
    @Test func releasingWhatYouAlreadyReleasedIsNotALapse() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["30m", "--owner", "agent:x"]).code == 0)
        #expect(sim.run(["down", "--owner", "agent:x"]).code == 0)
        let again = sim.run(["down", "--owner", "agent:x", "--json"], now: Sim.epoch + 60)
        #expect(again.code == 0)
        #expect(again.out.contains("\"released\":[]"))
        #expect(again.out.contains("\"held\":false"))
        #expect(again.out.contains("\"lapsed\":null"))
        #expect(sim.run(["down", "--owner", "agent:x"], now: Sim.epoch + 60).out.contains("nothing to release"))
    }

    /// A person ending everyone's claims is recorded as the person, and the
    /// agent whose claim went learns who took it and why.
    @Test func downAllRecordsThePersonAndTheAgentLearnsIt() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["2h", "--owner", "terminal"]).code == 0)
        #expect(sim.run(["2h", "--owner", "agent:x"]).code == 0)
        let all = sim.run(["down", "--all", "--owner", "terminal", "--json"], now: Sim.epoch + 60)
        #expect(all.code == 0)
        #expect(all.out.contains("\"held\":true"))   // the person's own claim was among them
        let byField = Set(sim.events(named: "retire").compactMap { $0["by"] as? String })
        #expect(byField == ["terminal"])

        let down = sim.run(["down", "--owner", "agent:x", "--json"], now: Sim.epoch + 120)
        #expect(down.code == 0)
        let lapsed = sim.json(down)["lapsed"] as? [String: Any]
        #expect(lapsed?["by"] as? String == "terminal")
        #expect(lapsed?["why"] as? String == "released by hand (all)")
    }

    /// `run` has no `--json`, so the same fact reaches its caller as one
    /// stderr line — and only when the guard actually ended the claim under
    /// the running command. Live clock: the wrapped command runs the guard
    /// itself once the one-second budget has passed.
    @Test func runSaysWhenTheGuardEndedItsClaimUnderneathTheCommand() {
        let sim = Sim(); defer { sim.tearDown() }
        let live: [String: String] = ["SIMMER_FAKE_NOW": "",
                                      "SIMMER_RUN_CHUNK": "60s",
                                      "SIMMER_RUN_INTERVAL": "10s"]
        let result = sim.run(["run", "--max", "1s", "--", "sh", "-c",
                              "sleep 1.5; '\(Sim.binary)' guard; sleep 0.3"],
                             env: live)
        #expect(result.code == 0, "the command's own exit code passes through")
        #expect(result.err.contains("the Mac may have slept since"), "stderr was: \(result.err)")
        #expect(result.err.contains("the command was not interrupted"))
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
    }
}
