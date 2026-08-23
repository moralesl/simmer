import Foundation
import Testing

/// The guard's branches — deadline crossings, the battery floor, the charger,
/// thermal, warn-once, the reminder interval. Reachable only because of
/// SIMMER_FAKE_NOW and the power seam; without them these are the least
/// verified paths in the tool (LEARNINGS.md § 4).
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

    @Test func extendingReArmsTheDeadlineWarning() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "test"])
        sim.run(["guard"], now: Sim.epoch + 1600)
        #expect(sim.events(named: "warn").count == 1)
        sim.run(["+30m", "--owner", "test"], now: Sim.epoch + 1600)
        #expect(sim.claimField("test", "warned") == "0")
        sim.run(["guard"], now: Sim.epoch + 1600 + 1501) // inside the new window
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
