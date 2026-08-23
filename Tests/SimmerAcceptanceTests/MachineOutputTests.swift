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

    /// The exit code is the API, but a person at a terminal cannot see one:
    /// fit and no-fit must not print the identical sentence.
    @Test func budgetSaysTheVerdictInWordsToo() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["1h", "--owner", "test"])

        let fits = sim.run(["budget", "--need", "20m"])
        #expect(fits.code == 0)
        #expect(fits.out.contains("fits"))
        #expect(!fits.out.contains("does not fit"))

        let doesNot = sim.run(["budget", "--need", "90m"])
        #expect(doesNot.code == 1)
        #expect(doesNot.out.contains("does not fit"))
        #expect(doesNot.out.contains("30 min short"))

        // Without --need there is no question, so no verdict is invented.
        let bare = sim.run(["budget"])
        #expect(!bare.out.contains("fits"))
        // --seconds and --json stay machine-only: no prose added to either.
        #expect(sim.run(["budget", "--need", "20m", "--seconds"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines) == "3600")
        #expect(!sim.run(["budget", "--need", "20m", "--json"]).out.contains("fits ("))
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

    /// Booleans are booleans, on every machine surface, and the same field
    /// never has two types. Asserted against the raw text: JSONSerialization
    /// bridges 0/1 to Bool, so `as? Bool` would have accepted the very drift
    /// this test exists to catch.
    @Test func yesNoFieldsAreBooleansNotOnesAndZeros() {
        let sim = Sim(); defer { sim.tearDown() }
        let claimed = sim.run(["2h", "-r", "ac", "--require-ac", "--owner", "test", "--json"]).out
        #expect(claimed.contains("\"require_ac\":true"))
        #expect(!claimed.contains("\"require_ac\":1"))
        #expect(claimed.contains("\"human\":false"))

        let status = sim.run(["status", "--json"]).out
        #expect(status.contains("\"require_ac\":true"))
        #expect(!status.contains("\"require_ac\":1"))

        // events.jsonl has always written it as a boolean; one field with two
        // types across two surfaces of one binary is the drift being fenced.
        let events = sim.events(named: "claim")
        #expect(events.last?["require_ac"] as? Bool == true)
        let eventText = (try? String(contentsOf: sim.stateDir.appendingPathComponent("events.jsonl"),
                                     encoding: .utf8)) ?? ""
        #expect(eventText.contains("\"require_ac\":true"))

        // The no-flag case is `false`, not absent and not 0.
        let plain = sim.run(["1h", "--owner", "other", "--json"]).out
        #expect(plain.contains("\"require_ac\":false"))
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

    /// The renewer thread, exercised rather than assumed: an initial chunk is
    /// short on purpose so a SIGKILLed runner self-expires, which only works
    /// if something keeps moving the deadline while the command lives.
    ///
    /// Real clock — an empty SIMMER_FAKE_NOW falls back to it — because a
    /// frozen clock cannot express "later", and renewal is entirely about
    /// later. The only unhermetic thing here is time passing.
    @Test func theRenewerMovesTheDeadlineWhileTheCommandRuns() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["run", "-r", "renewing", "--", "sleep", "2.5"],
                             env: ["SIMMER_FAKE_NOW": "",
                                   "SIMMER_RUN_CHUNK": "60s",
                                   "SIMMER_RUN_INTERVAL": "1s"])
        #expect(result.code == 0)
        let log = sim.run(["log", "20"], env: ["SIMMER_FAKE_NOW": ""]).out
        #expect(log.contains("run: renewed until"))
        // And it still cleaned up after itself: nothing left holding the Mac.
        #expect(sim.claimCount == 0)
        #expect(sim.switchValue == "0")
    }

    /// A renewal is a claim like any other, so the human ceiling outranks it —
    /// the path that would otherwise let a long `run` walk past a cap one
    /// renewal at a time.
    @Test func renewalNeverWalksPastTheCap() {
        let sim = Sim(); defer { sim.tearDown() }
        let live: [String: String] = ["SIMMER_FAKE_NOW": ""]
        sim.run(["cap", "30s", "--owner", "terminal"], env: live)
        guard let cap = sim.capUntil else { #expect(Bool(false), "no cap written"); return }

        let probe = sim.root.appendingPathComponent("after-renewals.txt").path
        sim.run(["run", "--", "sh", "-c", "sleep 2.5; cat '\(sim.claimsDir.path)'/run:* > '\(probe)'"],
                env: live.merging(["SIMMER_RUN_CHUNK": "60s",
                                   "SIMMER_RUN_INTERVAL": "1s"]) { _, new in new })
        let contents = (try? String(contentsOfFile: probe, encoding: .utf8)) ?? ""
        let until = contents.split(separator: "\n")
            .first { $0.hasPrefix("until=") }
            .flatMap { Int($0.dropFirst(6)) }
        #expect(until != nil)
        // Renewals ran (interval 1s over 2.5s) and every one of them stopped
        // at the ceiling rather than at now+chunk.
        #expect((until ?? 0) <= cap)
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

    /// Every verb the sugar layer recognises must have a subcommand behind it.
    /// A name with nothing behind it reaches the raw parser, whose "Unexpected
    /// argument" is the one refusal in the surface that names no fix — so the
    /// gate is mechanical rather than a promise to remember.
    @Test(arguments: ["claim", "extend", "release", "cap", "status", "budget",
                      "run", "guard", "doctor", "log", "render", "notify-test"])
    func everyDocumentedVerbResolves(_ verb: String) {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run([verb, "--help"])
        #expect(result.code == 0)
        #expect(!result.combined.contains("Unexpected argument"))
    }

    /// `--json` is either honoured or refused — never accepted and dropped.
    ///
    /// `--help` and CONTRACTS.md both promised "--json on every command" while
    /// `log`, `doctor`, `notify-test` and `render` accepted the flag, printed
    /// prose and exited 0. A caller cannot tell that from a flag that worked,
    /// so the promise was worse than no promise. This walks the whole verb list
    /// rather than the four that were wrong: a new command cannot join the
    /// surface without answering the question one way or the other.
    @Test(arguments: ["claim", "extend", "release", "cap", "status", "budget",
                      "doctor", "log", "render", "notify-test"])
    func everyVerbHonoursJSON(_ verb: String) {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"]) // something for them to describe
        // Arguments each verb needs to get past its own parser.
        let extras: [String: [String]] = [
            "claim": ["30m"], "extend": ["10m"], "cap": ["1h"], "render": ["raycast"],
        ]
        let result = sim.run([verb] + (extras[verb] ?? []) + ["--json", "--owner", "terminal"])

        let stdout = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty else {
            // The refusing verbs say so on stderr and exit non-zero. Silence
            // plus exit 0 is the failure mode this test exists for.
            #expect(result.code != 0, "\(verb) --json produced nothing and exited 0")
            #expect(result.err.contains("no JSON form"), "\(verb): \(result.err)")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) != nil,
                "\(verb) --json emitted non-JSON on stdout: \(stdout.prefix(120))")
    }

    @Test func theTwoVerbsWithoutAMachineAnswerSaySo() {
        let sim = Sim(); defer { sim.tearDown() }
        for verb in [["notify-test"], ["render", "raycast"]] {
            let result = sim.run(verb + ["--json"])
            #expect(result.code == 1)
            #expect(result.err.contains("no JSON form"))
            // A refusal that names no fix is the one thing the surface forbids.
            #expect(result.err.contains("simmer"))
            #expect(result.out.isEmpty)
        }
    }

    @Test func logJSONIsAnArrayEvenWhenEmpty() {
        let sim = Sim(); defer { sim.tearDown() }
        let empty = sim.json(sim.run(["log", "--json"]))
        #expect(empty["lines"] as? [String] == [])
        #expect(empty["count"] as? Int == 0)
        sim.run(["30m", "--owner", "test"])
        let after = sim.json(sim.run(["log", "--json"]))
        #expect((after["count"] as? Int ?? 0) > 0)
        #expect((after["lines"] as? [String] ?? []).contains { $0.contains("claim test") })
    }

    /// doctor's health answer, for an agent diagnosing itself. Under the seam
    /// the app is deliberately absent, so its row must be informational — a
    /// check that can never pass in a sandbox makes doctor the one command CI
    /// can never assert on.
    @Test func doctorJSONReportsChecksAndIsNotRedForAnAbsentAppUnderTheSeam() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["doctor", "--json"])
        let object = sim.json(result)
        #expect(object["version"] != nil)
        #expect(object["seam_active"] as? Bool == true)
        let checks = object["checks"] as? [[String: Any]] ?? []
        #expect(!checks.isEmpty)
        let appRow = checks.first { $0["id"] as? String == "app_running" }
        #expect(appRow != nil)
        #expect(appRow?["ok"] is NSNull, "the app check must be informational under the seam")
        // The nested status object is the same shape `status --json` emits.
        let status = object["status"] as? [String: Any] ?? [:]
        #expect(status["state"] as? String == "idle")
        #expect(status["claims"] as? [Any] != nil)
    }

    /// A floor outside 0–100 is not a battery level, and used to survive to be
    /// compared against one ("battery 80% <= floor 200%" describes the wrong
    /// problem). The attached `=` form throughout: a value beginning with `-`
    /// is genuinely ambiguous in separated form, and every parser rejects it.
    @Test func minBatteryOutsideZeroToHundredIsRefusedInSimmersOwnVoice() {
        let sim = Sim(); defer { sim.tearDown() }
        // No empty-string case: `--min-battery=` is a missing value, which the
        // parser owns and diagnoses before simmer sees anything.
        for bad in ["abc", "200", "101", "-5", "12.5"] {
            let result = sim.run(["1h", "--min-battery=\(bad)", "--owner", "test", "--json"])
            #expect(result.code == 1, "--min-battery=\(bad) was accepted")
            // The contracted refusal object, on stdout, for every bad value —
            // ArgumentParser's own diagnosis wrote nothing there at all.
            let object = sim.json(result)
            #expect(object["action"] as? String == "refused", "--min-battery=\(bad)")
            // And never the parser's voice, which names a subcommand nobody typed.
            #expect(!result.combined.contains("Usage: simmer claim"))
        }
        // The boundaries themselves are legal. The harness runs on AC, where a
        // floor is recorded and simply never applies.
        #expect(sim.run(["1h", "--min-battery=0", "--owner", "a"]).code == 0)
        #expect(sim.run(["1h", "--min-battery=100", "--owner", "b"]).code == 0)
        #expect(sim.claimField("b", "min_battery") == "100")
    }

    @Test func anUnknownWordIsRefusedWithAFixNotAParserDump() {
        let sim = Sim(); defer { sim.tearDown() }
        for word in ["notify-post", "wibble", "statuss"] {
            let result = sim.run([word])
            #expect(result.code == 1)
            #expect(!result.combined.contains("Unexpected argument"))
            // claim owns the diagnosis, and it names what good input looks like.
            #expect(result.err.contains("did not understand the duration"))
            #expect(result.err.contains("2h"))
        }
    }

    @Test func helpDescribesTheSurfaceThatExists() {
        let sim = Sim(); defer { sim.tearDown() }
        let help = sim.run(["--help"]).out
        #expect(help.contains("simmer render"))
        #expect(help.contains("1d"))
        #expect(help.contains("uninstall"))
        // v1 has exactly one transport: the app posts, or nothing does.
        #expect(!help.contains("per transport"))
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
