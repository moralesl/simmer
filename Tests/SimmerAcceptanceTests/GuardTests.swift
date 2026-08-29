import Foundation
import Testing

/// The guard's branches — deadline crossings, the battery floor, the charger,
/// thermal, warn-once, the reminder interval. Reachable only because of
/// SIMMER_FAKE_NOW and the power seam; without them these are the least
/// verified paths in the tool (PLATFORM-FACTS.md).
@Suite struct GuardTests {
    @Test func aDeadlineCrossingRetiresTheClaimAndHandsBackTheSwitch() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "test"])
        #expect(sim.switchValue == "1")
        let result = sim.run(["guard"], now: Sim.epoch + 1801)
        #expect(result.code == 0)
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
        let retire = sim.events(named: "retire")
        #expect(retire.count == 1)
        #expect(retire.first?["why"] as? String == "time is up")
    }

    @Test func eachClaimRetiresOnItsOwnFloor() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--min-battery", "60", "--owner", "picky"])
        sim.run(["2h", "--min-battery", "20", "--owner", "modest"])
        sim.run(["guard"], env: ["SIMMER_FAKE_BATTERY": "50:1"])
        // The 60% floor retired; the 20% floor did not get dragged down with it.
        #expect(!sim.hasClaim("picky"))
        #expect(sim.hasClaim("modest"))
        #expect(sim.switchValue == "1")
    }

    @Test func theFloorOnlyAppliesOnBattery() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--min-battery", "60", "--owner", "test"])
        sim.run(["guard"], env: ["SIMMER_FAKE_BATTERY": "50:0"]) // 50%, on AC
        #expect(sim.hasClaim("test"))
    }

    @Test func requireACEndsTheClaimWhenTheChargerGoes() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["8h", "--require-ac", "--owner", "overnight"])
        sim.run(["2h", "--owner", "other"])
        sim.run(["guard"], env: ["SIMMER_FAKE_BATTERY": "90:1"])
        #expect(!sim.hasClaim("overnight"))
        #expect(sim.hasClaim("other"))
    }

    @Test func thermalPressureEndsEverythingAtOnce() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"])
        sim.run(["forever", "--owner", "agent"])
        let result = sim.run(["guard"], env: ["SIMMER_FAKE_THERMAL": "2"])
        #expect(result.code == 0)
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
        #expect(sim.events(named: "thermal_release").count == 1)
    }

    /// "Thermal ends everything, unconditionally" (CONTRACTS.md) — so when a
    /// claim file will not unlink, the one thing the guard may not do is say
    /// it did. It stayed at exit 0 and appended `thermal_release` every tick
    /// while the Mac was held awake under heat, which for an open-ended claim
    /// is indefinitely.
    @Test func thermalPressureThatEndsNothingSaysNothing() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["forever", "--owner", "terminal", "-r", "overnight training"])
        #expect(sim.switchValue == "1")
        sim.freezeClaims()

        for _ in 0..<3 {
            let tick = sim.run(["guard"], env: ["SIMMER_FAKE_THERMAL": "3"])
            #expect(tick.code == 1, "a guard that ended nothing under heat exited \(tick.code)")
        }
        #expect(sim.switchValue == "1", "the switch moved with a claim still live")
        #expect(sim.events(named: "thermal_release").isEmpty,
                "a release that did not happen was announced \(sim.events(named: "thermal_release").count) time(s)")

        // And once the claim can actually go, it goes — and is announced once.
        sim.unfreezeClaims()
        #expect(sim.run(["guard"], env: ["SIMMER_FAKE_THERMAL": "3"]).code == 0)
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
        #expect(sim.events(named: "thermal_release").count == 1)
    }

    /// The same rule one branch over. A missing sudo rule is a persistent
    /// state, not a transient one, so an `orphan_heal` per failed tick is a
    /// false event every thirty seconds for as long as the Mac runs.
    @Test func anOrphanHealThatFailedIsNotRecorded() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.setSwitch(true)                   // the switch on with nothing claiming it
        sim.freezeSwitch()                    // and no sudo rule to move it back

        for _ in 0..<3 {
            #expect(sim.run(["guard"]).code == 1)
        }
        #expect(sim.switchValue == "1")
        #expect(sim.events(named: "orphan_heal").isEmpty)

        sim.unfreezeSwitch()
        #expect(sim.run(["guard"]).code == 0)
        #expect(sim.switchValue == "0")
        #expect(sim.events(named: "orphan_heal").count == 1)
    }

    @Test func preFloorWarnsOnceAndReArms() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "test"]) // floor 20, warning window below 30
        sim.run(["guard"], env: ["SIMMER_FAKE_BATTERY": "28:1"])
        #expect(sim.events(named: "prefloor_warn").count == 1)
        #expect(sim.claimField("test", "prewarned") == "1")
        // Still in the window: no second warning.
        sim.run(["guard"], env: ["SIMMER_FAKE_BATTERY": "27:1"])
        #expect(sim.events(named: "prefloor_warn").count == 1)
        // The charger returns, the battery climbs out: the warning re-arms...
        sim.run(["guard"], env: ["SIMMER_FAKE_BATTERY": "45:0"])
        #expect(sim.claimField("test", "prewarned") == "0")
        // ...so unplugging again warns again.
        sim.run(["guard"], env: ["SIMMER_FAKE_BATTERY": "28:1"])
        #expect(sim.events(named: "prefloor_warn").count == 2)
    }

    @Test func theDeadlineWarningFiresExactlyOnce() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "test"])
        sim.run(["guard"], now: Sim.epoch + 1600) // 200s left, inside the window
        #expect(sim.events(named: "warn").count == 1)
        #expect(sim.claimField("test", "warned") == "1")
        sim.run(["guard"], now: Sim.epoch + 1700)
        #expect(sim.events(named: "warn").count == 1)
    }

    /// A deadline chosen from inside the warning window is its own warning.
    /// `simmer 1m` used to answer itself seconds later with "under 1 min left ·
    /// simmer +30m extends it", which is the tool talking to itself.
    @Test func aDeadlineSetInsideTheWindowDoesNotWarn() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["1m", "--owner", "test"])
        #expect(sim.claimField("test", "warned") == "1")
        sim.run(["guard"], now: Sim.epoch + 15)
        #expect(sim.events(named: "warn").isEmpty)
        // It still ends on time, and says so — the end is news, the countdown is not.
        sim.run(["guard"], now: Sim.epoch + 61)
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")

        // Staying inside the window is the same choice, made knowingly: a
        // small addition to a claim that is nearly over leaves it nearly over.
        //
        // Since extend ADDS, a long claim can no longer be dragged into the
        // warning window by extending it — that case is now unreachable rather
        // than merely handled.
        sim.run(["1m", "--owner", "other"])
        sim.run(["+2m", "--owner", "other"], now: Sim.epoch + 10)
        #expect(sim.claimField("other", "until") == String(Sim.epoch + 60 + 120))
        #expect(sim.claimField("other", "warned") == "1")
        sim.run(["guard"], now: Sim.epoch + 40)
        #expect(sim.events(named: "warn").isEmpty)
    }

    /// A cap landing inside the window is also a deliberate act by a person who
    /// has just read what it means.
    @Test func aCapInsideTheWindowDoesNotWarnTheClaimsItClips() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "agent"])
        sim.run(["cap", "3m", "--owner", "terminal"])
        #expect(sim.claimField("agent", "warned") == "1")
        sim.run(["guard"], now: Sim.epoch + 30)
        #expect(sim.events(named: "warn").isEmpty)
    }

    @Test func extendingReArmsTheDeadlineWarning() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "test"])
        sim.run(["guard"], now: Sim.epoch + 1600)
        #expect(sim.events(named: "warn").count == 1)
        // extend ADDS: the 30m claim due at epoch+1800 becomes due at
        // epoch+3600, whatever o'clock the extension happened to be typed at.
        sim.run(["+30m", "--owner", "test"], now: Sim.epoch + 1600)
        #expect(sim.claimField("test", "warned") == "0")
        #expect(sim.claimField("test", "until") == String(Sim.epoch + 3600))
        sim.run(["guard"], now: Sim.epoch + 3600 - 200) // inside the new window
        #expect(sim.events(named: "warn").count == 2)
    }

    @Test func openEndedTimeRemindsEveryThirtyMinutes() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["forever", "--owner", "test"])
        sim.run(["guard"], now: Sim.epoch + 100)
        #expect(sim.events(named: "remind").isEmpty)
        sim.run(["guard"], now: Sim.epoch + 1801)
        #expect(sim.events(named: "remind").count == 1)
        sim.run(["guard"], now: Sim.epoch + 1900) // interval not elapsed again
        #expect(sim.events(named: "remind").count == 1)
        sim.run(["guard"], now: Sim.epoch + 3700)
        #expect(sim.events(named: "remind").count == 2)
    }

    @Test func theGuardRestoresASwitchSomethingTurnedOff() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "test"])
        sim.setSwitch(false) // a stray `pmset -a disablesleep 0` by hand
        sim.run(["guard"], now: Sim.epoch + 60)
        #expect(sim.switchValue == "1")
    }

    @Test func aCapClippedClaimDiesAtTheCapNotItsOwnDeadline() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "10m", "--owner", "terminal"])
        sim.run(["2h", "--owner", "agent"])
        sim.run(["guard"], now: Sim.epoch + 601)
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
    }
}
