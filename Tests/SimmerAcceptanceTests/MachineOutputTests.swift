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
                              "since", "owner", "claim_count", "cap", "cap_expires",
                              // Whether everything above describes this Mac or
                              // a seam. The suite always runs seamed, so this
                              // is 1 here and 0 on a real machine.
                              "seamed"]

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

    /// One claim, and it is not yours: the summary line has to say whose.
    ///
    /// This is the flagship read — with an agent holding the only claim, the
    /// person typing `simmer` got the reason and no owner, while `simmer down`
    /// in the same state named "🤖 agent:evals" while ending it. The surface
    /// that told you the most was the one that destroyed the thing.
    @Test func oneForeignClaimIsAttributedOnTheSummaryLine() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "-r", "eval batch", "--owner", "agent:evals"])

        let seenByAnother = sim.run(["status"], env: ["SIMMER_OWNER": "terminal"]).out
        #expect(seenByAnother.contains("agent:evals"), "\(seenByAnother)")
        #expect(seenByAnother.contains("🤖"), "\(seenByAnother)")
        #expect(seenByAnother.contains("eval batch"), "\(seenByAnother)")

        // Your own claim needs no attribution — that would be noise.
        let seenByTheHolder = sim.run(["status"], env: ["SIMMER_OWNER": "agent:evals"]).out
        #expect(!seenByTheHolder.contains("🤖"), "\(seenByTheHolder)")
        #expect(seenByTheHolder.contains("eval batch"), "\(seenByTheHolder)")

        // With several claims the rows carry it; the summary line stays clean.
        sim.run(["1h", "--owner", "terminal"])
        let several = sim.run(["status"], env: ["SIMMER_OWNER": "terminal"]).lines
        #expect(several.first?.contains("agent:evals") == false, "\(several)")
        #expect(several.contains { $0.contains("🤖 agent:evals") }, "\(several)")
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
        owner=sam
        """.write(to: lease, atomically: true, encoding: .utf8)

        let machine = sim.run(["status", "--machine"]).out
        #expect(machine.contains("state=active"))
        #expect(machine.contains("owner=sam"))
        #expect(sim.hasClaim("sam"))
        #expect(sim.claimField("sam", "min_battery") == "25")
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
    /// The wrapped command owns stdout, byte for byte.
    ///
    /// `simmer run` announced its claim on stdout, so it landed in the middle
    /// of the command's output: `X=$(simmer run -- ./build)` and
    /// `simmer run -- ./gen.sh > out.json` both silently captured three lines
    /// of simmer prose. `caffeinate`, which this is a drop-in for, adds nothing
    /// to either stream.
    @Test func theWrappedCommandOwnsStdout() {
        let sim = Sim(); defer { sim.tearDown() }
        let direct = sim.run(["run", "--", "sh", "-c", "printf 'a\\nb\\n'"])

        #expect(direct.out == "a\nb\n", "stdout was \(direct.out.debugDescription)")
        // The claim still has to be announced — on stderr, where commentary on
        // the run belongs. Silence would be the other way to pass this test and
        // the wrong one.
        #expect(direct.err.contains("simmering"), "the claim went unannounced: \(direct.err)")
    }

    /// A command that writes nothing leaves stdout empty — the strictest form
    /// of the same rule, and the one a redirect into a parser depends on.
    @Test func aSilentCommandLeavesStdoutEmpty() {
        let sim = Sim(); defer { sim.tearDown() }
        #expect(sim.run(["run", "--", "true"]).out.isEmpty)
    }

    /// The reason names the command, not just the program.
    ///
    /// It was `command[0]` alone, so `npm test` and `npm run build` both
    /// recorded "npm" — two live runs appeared in `simmer status` as two
    /// identical rows, which is precisely the moment the reason has a job to do.
    @Test func theRunReasonNamesTheWholeCommand() {
        let sim = Sim(); defer { sim.tearDown() }
        let probe = sim.root.appendingPathComponent("seen.txt").path
        sim.run(["run", "--", "sh", "-c", "\(Sim.binary) status --json > '\(probe)'"])
        let text = (try? String(contentsOf: URL(fileURLWithPath: probe), encoding: .utf8)) ?? ""

        #expect(text.contains("sh -c"), "the reason lost the arguments: \(text.prefix(200))")
        // -r still wins over the derived description.
        let probe2 = sim.root.appendingPathComponent("seen2.txt").path
        sim.run(["run", "-r", "chosen", "--",
                 "sh", "-c", "\(Sim.binary) status --json > '\(probe2)'"])
        let text2 = (try? String(contentsOf: URL(fileURLWithPath: probe2), encoding: .utf8)) ?? ""
        #expect(text2.contains("\"reason\":\"chosen\""), "\(text2.prefix(200))")
    }

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
    /// SwiftBar splits a row at the first `|` and reads what follows as
    /// parameters — `bash=` among them. So a pipe in a reason or an owner did
    /// not decorate the row, it replaced what the row DOES: a line that only
    /// reported something became a menu item that runs a command when the
    /// person clicks it, under a label that says something else.
    ///
    /// `simmer run` records the command it wraps as the reason, so an ordinary
    /// `simmer run -- sh -c 'a | b'` reaches this without anybody meaning to.
    @Test func aPipeInAReasonCannotTurnARowIntoAnAction() {
        let sim = Sim(); defer { sim.tearDown() }
        let payload = #"build | bash="/bin/sh" param1="-c" param2="touch /tmp/pwned""#
        sim.run(["45m", "-r", payload, "--owner", "test"])
        sim.run(["45m", "-r", "second", "--owner", #"agent:b | color=red"#])

        for line in sim.run(["render", "swiftbar"]).lines {
            // At most one delimiter per row: the one simmer wrote. A second
            // would let the text before it open a parameter list of its own.
            #expect(line.filter { $0 == "|" }.count <= 1, "two delimiters in: \(line)")
            // The payload may still READ as `bash=…` — it is inert label text
            // now, which is the point. What matters is the parameter half,
            // after the delimiter: nothing there may name a foreign binary.
            guard let delimiter = line.firstIndex(of: "|") else { continue }
            let parameters = String(line[line.index(after: delimiter)...])
            if parameters.contains("bash=") {
                #expect(parameters.contains("bash=\"\(Sim.binary)\""), "foreign bash= in: \(line)")
            }
        }
    }

    /// Raycast needs none of that — it emits one plain line. This
    /// asserts the difference is real rather than assumed.
    
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

    /// Every action a launcher surface emits must name a binary that exists.
    ///
    /// This is asserted through a PATH shim, because the bug it catches is only
    /// reachable that way: found on PATH, `argv[0]` is the bare word "simmer",
    /// and the old code joined that to the working directory. Every `bash=`
    /// path in the SwiftBar surface pointed at `<cwd>/simmer` — nothing, on any
    /// real machine. The rest of the suite execs an absolute path, which is the
    /// one invocation shape that hid it.
    @Test func swiftBarActionsPointAtABinaryThatExists() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.runThroughPATH(["45m", "-r", "brew", "--owner", "test"])
        let out = sim.runThroughPATH(["render", "swiftbar"]).out

        var checked = 0
        for line in out.split(separator: "\n") {
            guard let start = line.range(of: "bash=\"") else { continue }
            guard let end = line[start.upperBound...].firstIndex(of: "\"") else { continue }
            let path = String(line[start.upperBound..<end])
            checked += 1
            #expect(FileManager.default.isExecutableFile(atPath: path),
                    "render swiftbar points at \(path), which is not executable")
        }
        // A surface that emitted no actions at all would pass the loop above
        // vacuously — the assertion is that the actions exist AND resolve.
        #expect(checked > 0, "render swiftbar emitted no bash= actions to check")
    }

    @Test func raycastIsOneLine() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["45m", "--owner", "test"])
        let result = sim.run(["render", "raycast"])
        #expect(result.lines.count == 1)
        #expect(result.out.contains("☕"))
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
        // A launcher action appends `-r <reason> --owner <name>` to whatever it
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
                      "run", "guard", "doctor", "log", "render", "notify-test",
                      "uninstall"])
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
                      "doctor", "log", "render", "notify-test", "uninstall"])
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

    /// A refusal from the PARSER is still a refusal, and a `--json` caller is
    /// owed the object for it.
    ///
    /// `everyVerbHonoursJSON` above walks the verb list, so it only ever sees
    /// input the parser accepts. Malformed input took a different path and
    /// exited 1 with an empty stdout stream — which a caller cannot distinguish
    /// from a command that worked and had nothing to say. Every row here
    /// produced zero bytes on stdout before this gate existed.
    @Test(arguments: [
        ["-5m"],                       // reads as an option, not a duration
        ["--nonsense"],
        ["-x"],
        ["claim", "--min-battery"],     // option present, value missing
        ["run", "echo", "hi"],          // the command, but no `--`
        ["extend", "--until"],
    ])
    func aParseFailureStillAnswersJSON(_ args: [String]) {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(args + ["--json"])

        #expect(result.code == 1, "\(args) exited \(result.code), want 1")
        let stdout = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!stdout.isEmpty, "\(args) --json wrote nothing to stdout")
        guard let object = try? JSONSerialization.jsonObject(with: Data(stdout.utf8))
                as? [String: Any] else {
            #expect(Bool(false), "\(args) --json emitted non-JSON: \(stdout.prefix(120))")
            return
        }
        #expect(object["action"] as? String == "refused", "\(args): \(stdout.prefix(120))")
        // The diagnosis has to be IN the object — an empty `error` would pass
        // a shape check while telling the caller nothing.
        let error = object["error"] as? String ?? ""
        #expect(!error.isEmpty, "\(args): refused with an empty error")
        // Usage text names internal subcommand spellings nobody typed; it
        // belongs on a human's stderr, not in a contracted field.
        #expect(!error.contains("Usage:"), "\(args): usage text leaked into error")
    }

    /// `run` joined these two: its stdout belongs to the command it wraps, so
    /// there is no stream left to put an object on. It had been accepting
    /// `--json`, printing prose and exiting 0 — the one verb
    /// `everyVerbHonoursJSON` skips, and therefore the one place the rule went
    /// unenforced.
    @Test func theVerbsWithoutAMachineAnswerSaySo() {
        let sim = Sim(); defer { sim.tearDown() }
        // Each row is the whole invocation: for `run` the flag has to sit
        // BEFORE the terminator, because everything after `--` belongs to the
        // command — which is itself the behaviour under test here.
        for invocation in [["notify-test", "--json"],
                           ["render", "raycast", "--json"],
                           ["run", "--json", "--", "true"],
                           ["uninstall", "--json"]] {
            let result = sim.run(invocation)
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

/// `budget` answers "is there room to start" — and a deadline is not the only
/// way the room runs out. On battery it is rarely the first.
@Suite struct BudgetAgainstTheFloorTests {
    /// Four hours of deadline, one point above the floor that ends the claim.
    /// `fits` still answers about the deadline, by contract; what changed is
    /// that the other ending is on the surface instead of needing a second
    /// call to `status`.
    @Test func budgetShowsTheFloorThatWillEndTheClaimFirst() {
        let sim = Sim(); defer { sim.tearDown() }
        let onBattery = ["SIMMER_FAKE_BATTERY": "21:1"]
        sim.run(["4h", "-r", "long", "--owner", "agent:x", "--min-battery", "20"], env: onBattery)

        let object = sim.json(sim.run(["budget", "--need", "3h", "--json"], env: onBattery))
        #expect(object["fits"] as? Bool == true)
        #expect(object["battery"] as? Int == 21)
        #expect(object["on_battery"] as? Int == 1)
        #expect(object["min_battery"] as? Int == 20)

        let human = sim.run(["budget", "--need", "3h"], env: onBattery)
        #expect(human.err.contains("floor of 20%"))
    }

    /// On AC, none of it applies and none of it is said.
    @Test func budgetSaysNothingAboutAFloorItIsNotNear() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "long", "--owner", "agent:x"])
        let human = sim.run(["budget", "--need", "3h"])
        #expect(human.code == 0)
        #expect(!human.err.contains("floor of"))
    }

    /// The seam is named on the surface an agent is told to trust, not only in
    /// `doctor`: a leaked SIMMER_FAKE_* made `fits: true` a statement about a
    /// file in /tmp.
    @Test func budgetNamesTheSeamItIsAnsweringAbout() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "--owner", "agent:x"])
        #expect(sim.json(sim.run(["budget", "--need", "1h", "--json"]))["seamed"] as? Bool == true)
        #expect(sim.run(["budget", "--need", "1h"]).err.contains("test seam"))
        // --bare-seconds is one number by contract, and stays one number.
        #expect(sim.run(["budget", "--seconds"]).out.split(separator: "\n").count == 1)
    }
}

/// The guarantee is the EARLIEST of the clocks, and a deadline is only one of
/// them. On battery the floor is usually the first to arrive.
///
/// **The seam below was checked against real hardware**, unplugged, on
/// 2026-08-28 — because a fake battery proving a battery feature is exactly
/// the shape that passes while the real path is broken. What the Mac said,
/// and what simmer made of it:
///
///     pmset: 100%; discharging; 8:46 remaining      → 31,560s to empty
///     floor 20%  → battery_seconds_left  25,248s    (31,560 × 80/100)
///     floor 90%  → battery_seconds_left   3,156s    (31,560 × 10/100)
///
/// and each of the four states the estimate can be in was observed live:
/// `(no estimate)` for the first ~40s after unplugging (null, deadline answers
/// alone), the estimate binding later than the deadline (nothing changes), the
/// estimate binding FIRST (refused, naming the battery), and the same under an
/// open-ended claim (refused, `seconds_left` still -1).
@Suite struct BudgetAgainstTheBatteryClockTests {
    /// 4h of deadline, and macOS says 40 minutes to empty from 60% with a
    /// floor of 20% — so two thirds of that, ~27 min, is the real guarantee.
    /// `fits` used to answer about the deadline alone and said yes to three
    /// hours of work the guard would end in half an hour.
    static let dying = ["SIMMER_FAKE_BATTERY": "60:1", "SIMMER_FAKE_BATTERY_TIME": "2400"]

    @Test func aNeedBeyondTheBatteryFloorDoesNotFit() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "long", "--owner", "agent:x", "--min-battery", "20"], env: Self.dying)

        let result = sim.run(["budget", "--need", "3h", "--json"], env: Self.dying)
        #expect(result.code == 1)
        let object = sim.json(result)
        #expect(object["fits"] as? Bool == false)
        // seconds_left keeps its contracted meaning: the DEADLINE clock.
        #expect(object["seconds_left"] as? Int == 14400)
        // The second clock is its own field. 2400 * (60-20)/60 = 1600.
        #expect(object["battery_seconds_left"] as? Int == 1600)

        // And the human line names the clock that runs out first, rather than
        // reporting a shortfall against time the caller does have.
        let human = sim.run(["budget", "--need", "3h"], env: Self.dying)
        #expect(human.out.contains("battery reaches its floor"))
        #expect(!human.out.contains("short"))
    }

    /// Inside the battery's own window it still fits — this must not become a
    /// blanket refusal whenever the charger is out.
    @Test func aNeedInsideTheBatteryWindowStillFits() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "long", "--owner", "agent:x", "--min-battery", "20"], env: Self.dying)
        let result = sim.run(["budget", "--need", "20m", "--json"], env: Self.dying)
        #expect(result.code == 0)
        #expect(sim.json(result)["fits"] as? Bool == true)
    }

    /// An open-ended claim has no deadline at all, so the battery is the only
    /// clock there is — and `fits` was unconditionally true.
    @Test func anOpenEndedClaimIsStillBoundedByTheBattery() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["forever", "-r", "render", "--owner", "agent:x"], env: Self.dying)
        let result = sim.run(["budget", "--need", "3h", "--json"], env: Self.dying)
        #expect(result.code == 1)
        #expect(sim.json(result)["fits"] as? Bool == false)
        // -1 still means "no deadline". That contract did not move.
        #expect(sim.json(result)["seconds_left"] as? Int == -1)
    }

    /// macOS has no estimate for minutes after every wake. Nothing is invented
    /// to fill the gap: the deadline answers alone, as it always did.
    @Test func noEstimateMeansTheDeadlineAnswersAlone() {
        let sim = Sim(); defer { sim.tearDown() }
        let calibrating = ["SIMMER_FAKE_BATTERY": "60:1", "SIMMER_FAKE_BATTERY_TIME": "none"]
        sim.run(["4h", "-r", "long", "--owner", "agent:x"], env: calibrating)
        let result = sim.run(["budget", "--need", "3h", "--json"], env: calibrating)
        #expect(result.code == 0)
        #expect(sim.json(result)["battery_seconds_left"] is NSNull)
    }

    /// On AC there is no second clock and nothing changes.
    @Test func onACTheAnswerIsTheDeadlineAndNothingElse() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "long", "--owner", "agent:x"])
        let object = sim.json(sim.run(["budget", "--need", "3h", "--json"]))
        #expect(object["fits"] as? Bool == true)
        #expect(object["battery_seconds_left"] is NSNull)
    }
}

/// `budget` answers about the earliest clock there is. The battery clock has
/// to behave like a clock at both ends — including the end where it has
/// already run out, which is where it used to disappear.
@Suite struct BatteryClockEdgeTests {
    /// The answer must not get BETTER as the battery gets worse. Dropping the
    /// clock at or below the floor made 20% and 5% answer "fits" at exit 0
    /// while 21% answered "does not fit" at exit 1.
    @Test func theAnswerIsMonotonicAcrossTheFloor() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "--owner", "agent:evals", "-r", "long eval"])

        for percent in [25, 21, 20, 12, 5] {
            let result = sim.run(["budget", "--need", "3h", "--json"],
                                 env: ["SIMMER_FAKE_BATTERY": "\(percent):1",
                                       "SIMMER_FAKE_BATTERY_TIME": "900"])
            let object = sim.json(result)
            #expect(object["fits"] as? Bool == false,
                    "at \(percent)% on battery with a 20% floor: \(result.out)")
            #expect(result.code == 1, "at \(percent)%: exit \(result.code)")
            #expect(object["battery_seconds_left"] != nil)
        }
    }

    /// At or below the floor the clock has run out; that is `0`, not absent.
    /// The floor is decided from the percentage alone, BEFORE any estimate is
    /// read — because `pmset` has none for minutes after every wake, and the
    /// zero-at-the-floor verdict used to sit behind that read. Below the floor
    /// with no estimate therefore fell out as "no constraint", and `budget`
    /// answered `fits: true` at exit 0 about a claim the next guard tick ends.
    ///
    /// `Tick` retires on `percent <= minBattery` and consults no clock to do
    /// it. Neither does this.
    @Test(arguments: ["15:1", "20:1", "1:1"])
    func belowTheFloorIsZeroEvenWithNoEstimateAtAll(_ battery: String) {
        let sim = Sim(); defer { sim.tearDown() }
        // Claimed on AC, so the claim exists; the battery is what moved.
        sim.run(["4h", "-r", "long run", "--owner", "agent:x", "--min-battery", "20"])

        // No SIMMER_FAKE_BATTERY_TIME: exactly the state after a wake.
        let drained = ["SIMMER_FAKE_BATTERY": battery]
        let result = sim.run(["budget", "--need", "30m", "--json"], env: drained)
        #expect(result.code == 1, "\(battery) answered exit \(result.code)")
        let object = sim.json(result)
        #expect(object["fits"] as? Bool == false)
        #expect(object["battery_seconds_left"] as? Int == 0)
        #expect(object["seconds_left"] as? Int == 14400)   // the deadline is untouched

        // And the person is told which clock ran out.
        let human = sim.run(["budget", "--need", "30m"], env: drained)
        #expect(human.err.contains("at or under the floor"))
        #expect(human.out.contains("already at its floor"))
    }

    /// 0% is the same verdict and not a division problem.
    @Test func aFlatBatteryIsZeroAndNotAnError() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "-r", "long run", "--owner", "agent:x", "--min-battery", "20"])
        let result = sim.run(["budget", "--need", "30m", "--json"],
                             env: ["SIMMER_FAKE_BATTERY": "0:1"])
        #expect(result.code == 1)
        #expect(sim.json(result)["battery_seconds_left"] as? Int == 0)
    }

    @Test func atTheFloorTheBatteryClockIsZeroRatherThanMissing() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "--owner", "agent:evals"])
        let object = sim.json(sim.run(["budget", "--need", "1m", "--json"],
                                      env: ["SIMMER_FAKE_BATTERY": "20:1",
                                            "SIMMER_FAKE_BATTERY_TIME": "900"]))
        #expect(object["battery_seconds_left"] as? Int == 0)
    }

    /// With nothing claimed there is no floor to be a number of seconds from —
    /// `min_battery` is the default, not a decision anybody made.
    @Test func anIdleMacHasNoBatteryClock() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["budget", "--need", "10m", "--json"],
                             env: ["SIMMER_FAKE_BATTERY": "60:1",
                                   "SIMMER_FAKE_BATTERY_TIME": "3600"])
        #expect(result.code == 3)
        #expect(sim.json(result)["battery_seconds_left"] is NSNull)
    }

    /// The estimate arrives from outside the process, so the arithmetic on it
    /// is checked. This trapped with SIGTRAP and exit 133 — a code outside the
    /// published table — which is the class the duration ceiling closed.
    @Test(arguments: ["9223372036854775807", "999999999999999999", "-3600"])
    func aHostileBatteryEstimateNeverTrapsAndNeverGoesNegative(_ estimate: String) {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["4h", "--owner", "agent:evals"])
        let result = sim.run(["budget", "--need", "1h", "--json"],
                             env: ["SIMMER_FAKE_BATTERY": "60:1",
                                   "SIMMER_FAKE_BATTERY_TIME": estimate])
        #expect(result.code != 133, "exit 133 for \(estimate)")
        #expect(result.code == 0 || result.code == 1, "exit \(result.code) for \(estimate)")
        if let seconds = sim.json(result)["battery_seconds_left"] as? Int {
            #expect(seconds >= 0, "\(seconds) seconds for \(estimate)")
        }
    }
}
