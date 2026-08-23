import Foundation
import Testing

/// The machine surfaces are the contract: --machine, --json, the exit codes,
/// events.jsonl and the format=1 migration. Human sentences may be reworded;
/// nothing here may drift without a major version.
@Suite struct BudgetTests {
    @Test func nothingClaimedIsThreeNotOne() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["budget"])
        #expect(result.code == 3)
        #expect(result.out.contains("nothing claimed"))
        // With --need it still refuses at 3 — an absent guarantee, not a small one.
        #expect(sim.run(["budget", "--need", "5m"]).code == 3)
    }

    @Test func budgetExitCodesAnswerTheDecision() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "test"])
        #expect(sim.run(["budget", "--need", "20m"]).code == 0)
        #expect(sim.run(["budget", "--need", "40m"]).code == 1)
        #expect(sim.run(["budget"]).code == 0)
    }

    @Test func budgetSecondsIsBareAndMinusOneMeansNoDeadline() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["forever", "--owner", "test"])
        let result = sim.run(["budget", "--seconds"])
        #expect(result.out.trimmingCharacters(in: .whitespacesAndNewlines) == "-1")
        #expect(result.code == 0)
    }

    @Test func budgetJSONShapes() {
        let sim = Sim(); defer { sim.tearDown() }
        // Nothing claimed: fits false under --need, seconds_left null.
        var object = sim.json(sim.run(["budget", "--need", "5m", "--json"]))
        #expect(object["fits"] as? Bool == false)
        #expect(object["seconds_left"] is NSNull)
        // No --need: no question to answer.
        object = sim.json(sim.run(["budget", "--json"]))
        #expect(object["fits"] is NSNull)

        sim.run(["30m", "--owner", "test"])
        object = sim.json(sim.run(["budget", "--need", "20m", "--json"]))
        #expect(object["fits"] as? Bool == true)
        #expect(object["seconds_left"] as? Int == 1800)
        #expect(object["state"] as? String == "active")
        #expect(object["need_seconds"] as? Int == 1200)
        #expect(object["claim_count"] as? Int == 1)
    }

    @Test func budgetToleratesOwnerAndReason() {
        let sim = Sim(); defer { sim.tearDown() }
        // The spike shipped a bug where --owner made budget exit 1. Never again.
        let result = sim.run(["budget", "--owner", "agent", "-r", "why"])
        #expect(result.code == 3)
        #expect(!result.err.contains("error"))
    }
}

@Suite struct StatusOutputTests {
    static let machineKeys = ["state", "until", "left", "left_short", "reason",
                              "min_battery", "battery", "on_battery", "sleep_disabled",
                              "since", "owner", "claim_count", "cap"]

    @Test func machineEmitsEveryFieldEveryTime() {
        let sim = Sim(); defer { sim.tearDown() }
        for scenario in [[], ["30m", "--owner", "test"]] {
            if !scenario.isEmpty { sim.run(scenario) }
            let keys = sim.run(["status", "--machine"]).lines
                .compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
            #expect(keys == Self.machineKeys)
        }
    }

    @Test func jsonIsParseableWithNumbersAsNumbers() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "-r", "why \"quoted\" · text", "--owner", "test"])
        let object = sim.json(sim.run(["status", "--json"]))
        #expect(object["state"] as? String == "active")
        #expect(object["until"] as? Int == Sim.epoch + 1800)
        #expect(object["left"] as? Int == 1800)
        #expect(object["battery"] as? Int == 80)
        #expect(object["sleep_disabled"] as? Int == 1)
        #expect(object["capped"] as? Bool == false)
        #expect(object["reason"] as? String == "why \"quoted\" · text")
        let claims = object["claims"] as? [[String: Any]]
        #expect(claims?.count == 1)
        #expect(claims?.first?["owner"] as? String == "test")
        #expect(claims?.first?["human"] as? Bool == false)
        #expect(object["version"] is String)
    }

    @Test func aLiveClaimWithTheSwitchOffIsSaidOutLoud() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "test"])
        sim.setSwitch(false)
        #expect(sim.run(["status"]).out.contains("the lid will not hold"))
    }

    @Test func mutatingCommandsSpeakJSONToo() {
        let sim = Sim(); defer { sim.tearDown() }
        var object = sim.json(sim.run(["30m", "--owner", "test", "--json"]))
        #expect(object["action"] as? String == "claimed")
        #expect((object["claim"] as? [String: Any])?["owner"] as? String == "test")
        object = sim.json(sim.run(["+10m", "--owner", "test", "--json"]))
        #expect(object["action"] as? String == "extended")
        object = sim.json(sim.run(["down", "--owner", "test", "--json"]))
        #expect(object["action"] as? String == "released")
        #expect((object["released"] as? [String])?.first == "test")
        object = sim.json(sim.run(["cap", "10m", "--owner", "terminal", "--json"]))
        #expect(object["action"] as? String == "cap_set")
        // A refusal with --json is still machine-readable, and still exit 1.
        let refused = sim.run(["30m", "--owner", "test", "--json"], now: Sim.epoch + 700)
        #expect(refused.code == 1)
        #expect(sim.json(refused)["action"] as? String == "refused")
    }
}

@Suite struct MigrationTests {
    @Test func aFormatOneLeaseIsReadOnceConvertedAndDeleted() {
        let sim = Sim(); defer { sim.tearDown() }
        // The lease IS the fixture here — it is the foreign input being migrated.
        let lease = sim.stateDir.appendingPathComponent("lease")
        try! FileManager.default.createDirectory(at: sim.stateDir, withIntermediateDirectories: true)
        try! """
        format=1
        until=\(Sim.epoch + 3600)
        started=\(Sim.epoch - 600)
        reason=mid-upgrade build
        min_battery=25
        caffeinate=0
        warned=0
        reminded=\(Sim.epoch - 600)
        owner=luis
        """.write(to: lease, atomically: true, encoding: .utf8)

        let machine = sim.run(["status", "--machine"]).out
        #expect(machine.contains("state=active"))
        #expect(machine.contains("owner=luis"))
        #expect(sim.hasClaim("luis"))
        #expect(sim.claimField("luis", "min_battery") == "25")
        #expect(!FileManager.default.fileExists(atPath: lease.path))
        #expect(sim.events(named: "migrate").count == 1)
    }
}

@Suite struct EventStreamTests {
    @Test func everyTransitionLandsInEventsJSONL() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "-r", "build", "--owner", "test"])
        sim.run(["+10m", "--owner", "test"])
        sim.run(["down", "--owner", "test"])
        let names = sim.events().compactMap { $0["event"] as? String }
        // Chronological: the switch goes on before the claim file lands.
        #expect(names == ["switch_on", "claim", "extend", "retire", "release", "switch_off"])
        // Readable and complete: v, both timestamps, and the details.
        for event in sim.events() {
            #expect(event["v"] as? Int == 1)
            #expect(event["ts"] as? Int == Sim.epoch)
            #expect(event["ts_human"] is String)
        }
        let claim = sim.events(named: "claim").first
        #expect(claim?["owner"] as? String == "test")
        #expect(claim?["reason"] as? String == "build")
        #expect(claim?["until"] as? Int == Sim.epoch + 1800)
    }
}

@Suite struct RunTests {
    @Test func exitCodesPassThroughUntouched() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["run", "--", "true"]).code == 0)
        #expect(sim.run(["run", "--", "false"]).code == 1)
        #expect(sim.run(["run", "--", "sh", "-c", "exit 7"]).code == 7)
    }

    @Test func theClaimLivesExactlyAsLongAsTheCommand() {
        let sim = Sim(); defer { sim.tearDown() }
        let probe = sim.root.appendingPathComponent("during.txt").path
        let result = sim.run(["run", "-r", "probe", "--",
                              "sh", "-c", "ls '\(sim.claimsDir.path)' > '\(probe)'"])
        #expect(result.code == 0)
        let during = (try? String(contentsOfFile: probe, encoding: .utf8)) ?? ""
        #expect(during.contains("run:"))
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
    }

    @Test func maxBoundsTheFirstChunkAndChunkIsConfigurable() {
        let sim = Sim(); defer { sim.tearDown() }
        let probe = sim.root.appendingPathComponent("claim.txt").path
        sim.run(["run", "--max", "10m", "--",
                 "sh", "-c", "cat '\(sim.claimsDir.path)'/* > '\(probe)'"])
        var contents = (try? String(contentsOfFile: probe, encoding: .utf8)) ?? ""
        #expect(contents.contains("until=\(Sim.epoch + 600)"))

        sim.run(["run", "--",
                 "sh", "-c", "cat '\(sim.claimsDir.path)'/* > '\(probe)'"],
                env: ["SIMMER_RUN_CHUNK": "90s"])
        contents = (try? String(contentsOfFile: probe, encoding: .utf8)) ?? ""
        #expect(contents.contains("until=\(Sim.epoch + 90)"))
    }

    @Test func runRefusesBelowTheFloorBeforeRunningAnything() {
        let sim = Sim(); defer { sim.tearDown() }
        let probe = sim.root.appendingPathComponent("ran.txt").path
        let result = sim.run(["run", "--", "sh", "-c", "touch '\(probe)'"],
                             env: ["SIMMER_FAKE_BATTERY": "10:1"])
        #expect(result.code == 1)
        #expect(!FileManager.default.fileExists(atPath: probe))
    }
}

@Suite struct RenderTests {
    @Test func swiftBarShowsTheAggregateAndTheActions() {
        let sim = Sim(); defer { sim.tearDown() }
        let idle = sim.run(["render", "swiftbar"]).out
        #expect(idle.contains("Stay awake for…"))
        sim.run(["45m", "-r", "brew", "--owner", "test"])
        let active = sim.run(["render", "swiftbar"]).out
        #expect(active.contains("Simmering until"))
        #expect(active.contains("brew"))
        #expect(active.contains("param1=\"down\""))
    }

    @Test func raycastIsOneLine() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["45m", "--owner", "test"])
        let result = sim.run(["render", "raycast"])
        #expect(result.lines.count == 1)
        #expect(result.out.contains("☕"))
    }

    @Test func alfredEmitsValidScriptFilterJSON() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["45m", "--owner", "test"])
        let object = sim.json(sim.run(["render", "alfred", "+30m"]))
        let items = object["items"] as? [[String: Any]]
        #expect((items?.count ?? 0) > 1)
        #expect(items?.first?["title"] is String)
    }
}

@Suite struct SurfaceTests {
    @Test func versionAndHelpExitZero() {
        let sim = Sim(); defer { sim.tearDown() }
        let version = sim.run(["--version"])
        #expect(version.code == 0)
        #expect(version.out.contains("simmer"))
        let help = sim.run(["--help"])
        #expect(help.code == 0)
        #expect(help.out.contains("EXIT CODES ARE API"))
    }

    @Test func unknownOptionsAreExitOneNotSixtyFour() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["status", "--bogus"]).code == 1)
        #expect(sim.run(["--not-a-thing"]).code == 1)
    }

    @Test func launcherTrailersAreToleratedEverywhere() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "test"])
        // Alfred appends `-r <reason> --owner <name>` to whatever the filter
        // produced, whether the command has any use for them or not.
        #expect(sim.run(["down", "-r", "reason", "--owner", "test"]).code == 0)
        #expect(sim.run(["cap", "-r", "reason", "--owner", "terminal"]).code == 0)
        #expect(sim.run(["log", "5", "-r", "reason", "--owner", "x"]).code == 0)
    }

    @Test func logTailsTheGuardsActions() {
        let sim = Sim(); defer { sim.tearDown() }
        let empty = sim.run(["log"])
        #expect(empty.out.contains("no log yet"))
        sim.run(["30m", "--owner", "test"])
        sim.run(["down", "--owner", "test"])
        let log = sim.run(["log", "10"]).out
        #expect(log.contains("claim test"))
        #expect(log.contains("released by hand"))
    }
}
