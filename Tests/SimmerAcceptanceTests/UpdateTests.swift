import Foundation
import Testing

/// `simmer update` through the binary: the exit codes, the machine fields, and
/// the two promises that are easy to break by accident — that `--cached` never
/// reaches the network, and that being out of date never turns `doctor` red.
///
/// Every run in this suite is seamed (Harness sets `SIMMER_FAKE_PMSET`), and a
/// seamed process with no `SIMMER_FAKE_LATEST` reads nothing over the network.
/// That is what makes this suite hermetic without anyone having to remember an
/// extra variable.
@Suite struct UpdateTests {
    private func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test func aNewerReleaseIsReportedAndExitsZero() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["update", "--json"], env: ["SIMMER_FAKE_LATEST": "v9.9.9"])

        #expect(result.code == 0, "a newer release is an answer, not a failure: \(result.combined)")
        let json = object(result.out)
        #expect(json["action"] as? String == "checked")
        #expect(json["verdict"] as? String == "available")
        #expect(json["latest"] as? String == "v9.9.9")
        #expect(json["update_available"] as? Bool == true)
        #expect((json["update_command"] as? String)?.isEmpty == false)
    }

    @Test func beingCurrentExitsZeroToo() {
        let sim = Sim(); defer { sim.tearDown() }
        let version = sim.run(["--version"]).out
            .replacingOccurrences(of: "simmer ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = sim.run(["update", "--json"], env: ["SIMMER_FAKE_LATEST": "v\(version)"])

        #expect(result.code == 0)
        #expect(object(result.out)["verdict"] as? String == "current")
        #expect(object(result.out)["update_available"] as? Bool == false)
    }

    /// The one non-zero exit: the check could not be made. A caller can then
    /// tell "you are current" from "nobody knows".
    @Test func aCheckThatCouldNotBeMadeExitsOneAndStillAnswersJSON() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["update", "--json"], env: ["SIMMER_FAKE_LATEST": "error"])

        #expect(result.code == 1)
        let json = object(result.out)
        #expect(json["verdict"] as? String == "unknown")
        #expect(json["latest"] is NSNull)
        #expect((json["error"] as? String)?.isEmpty == false)
    }

    /// `--cached` is what `doctor`, the menu and a launcher row use, so it must
    /// answer from the record alone. Here the source is primed with an answer
    /// it is not allowed to look at.
    @Test func cachedNeverConsultsTheSource() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["update", "--cached", "--json"],
                             env: ["SIMMER_FAKE_LATEST": "v9.9.9"])

        #expect(result.code == 1)
        let json = object(result.out)
        #expect(json["verdict"] as? String == "unknown")
        #expect(json["cached"] as? Bool == true)
        #expect((json["error"] as? String)?.contains("not checked yet") == true)
    }

    @Test func aCheckIsRecordedForTheOtherSurfacesToRead() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["update"], env: ["SIMMER_FAKE_LATEST": "v9.9.9"])

        // No SIMMER_FAKE_LATEST at all this time: the answer can only have
        // come from the record.
        let cached = sim.run(["update", "--cached", "--json"])
        #expect(cached.code == 0)
        #expect(object(cached.out)["latest"] as? String == "v9.9.9")
        #expect(object(cached.out)["cached"] as? Bool == true)
    }

    /// Asserted against the raw text: `JSONSerialization` bridges `0`/`1` to
    /// `Bool`, so a typed assertion would let exactly this drift through.
    @Test func theYesNoFieldsAreRealBooleans() {
        let sim = Sim(); defer { sim.tearDown() }
        let out = sim.run(["update", "--json"], env: ["SIMMER_FAKE_LATEST": "v9.9.9"]).out

        #expect(out.contains("\"update_available\":true"))
        #expect(out.contains("\"app_drift\":false"))
        #expect(out.contains("\"seamed\":true"))
    }

    /// Provenance decides the instruction, and `SIMMER_BIN` is the seam that
    /// lets this be asserted without a Homebrew install under the tester.
    @Test func homebrewIsToldToUseHomebrew() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(
            ["update", "--json"],
            env: ["SIMMER_FAKE_LATEST": "v9.9.9",
                  "SIMMER_BIN": "/opt/homebrew/Cellar/simmer/9.9.9/Simmer.app/Contents/MacOS/simmer"])

        let json = object(result.out)
        #expect(json["provenance"] as? String == "homebrew")
        #expect(json["update_command"] as? String == "brew upgrade simmer")
    }

    /// Out of date is not a broken install. A row that could go red for it
    /// would teach the reader to skim the rows that mean something.
    @Test func anAvailableUpdateNeverChangesDoctorsVerdict() {
        let sim = Sim(); defer { sim.tearDown() }
        let before = sim.run(["doctor", "--json"]).code
        sim.run(["update"], env: ["SIMMER_FAKE_LATEST": "v9.9.9"])
        let after = sim.run(["doctor", "--json"])

        #expect(after.code == before, "an available update moved doctor's exit code")
        let checks = (object(after.out)["checks"] as? [[String: Any]]) ?? []
        guard let row = checks.first(where: { $0["id"] as? String == "update" }) else {
            #expect(Bool(false), "no update row in doctor --json: \(after.out.prefix(400))")
            return
        }
        #expect(row["ok"] is NSNull, "the update row is informational, never a check")
        #expect((row["label"] as? String)?.contains("9.9.9") == true)
    }

    /// `doctor` answers "is this install wired up", and that must have the
    /// same answer on a train as in the office.
    @Test func doctorNeverMakesTheCheckItself() {
        let sim = Sim(); defer { sim.tearDown() }
        // The source is primed; `doctor` is not allowed to look at it.
        let result = sim.run(["doctor", "--json"], env: ["SIMMER_FAKE_LATEST": "v9.9.9"])
        let checks = (object(result.out)["checks"] as? [[String: Any]]) ?? []
        let row = checks.first { $0["id"] as? String == "update" }
        #expect((row?["label"] as? String)?.contains("not checked yet") == true,
                "doctor answered from the network: \(row?["label"] ?? "no row")")
    }

    /// Every command reachable from a launcher tolerates a trailing reason and
    /// owner, whether or not it has any use for them (CONTRACTS.md).
    @Test func itToleratesTheLauncherTail() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["update", "-r", "why", "--owner", "raycast"],
                             env: ["SIMMER_FAKE_LATEST": "v9.9.9"])
        #expect(result.code == 0, "\(result.combined)")
    }
}

/// `--apply` through the binary. Every step is recorded rather than run
/// (`SIMMER_FAKE_APPLY`), which is what lets the suite assert the plan a real
/// install would execute without building or installing anything.
@Suite struct UpdateApplyTests {
    private func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// A bundle install with the installer's checkout on disk — the colleague
    /// case, and the only one where nobody has a terminal open.
    private func bundleInstall(_ sim: Sim) -> [String: String] {
        let checkout = sim.root.appendingPathComponent(".local/share/simmer")
        try? FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try? "all:\n".write(to: checkout.appendingPathComponent("Makefile"),
                            atomically: true, encoding: .utf8)
        return ["SIMMER_BIN": sim.root
            .appendingPathComponent("Applications/Simmer.app/Contents/MacOS/simmer").path]
    }

    @Test func applyRunsThePlanAndSaysWhatItRan() throws {
        let sim = Sim(); defer { sim.tearDown() }
        let log = sim.root.appendingPathComponent("apply.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        var env = bundleInstall(sim)
        env["SIMMER_FAKE_LATEST"] = "v9.9.9"
        env["SIMMER_FAKE_APPLY"] = log.path
        let result = sim.run(["update", "--apply", "--json"], env: env)

        #expect(result.code == 0, "\(result.combined)")
        let json = object(result.out)
        #expect(json["action"] as? String == "updated")
        #expect(json["applied"] as? Bool == true)
        #expect((json["steps"] as? [String])?.count == 3)

        let ran = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let lines = ran.split(separator: "\n").map(String.init)
        #expect(lines.count == 3, "recorded: \(lines)")
        #expect(lines[0].contains("fetch --tags"))
        #expect(lines[1].contains("checkout --quiet v9.9.9"))
        #expect(lines[2].contains("install NOTES=0"))
    }

    /// The property that makes this something simmer can honestly offer: the
    /// printed command for a bundle install pipes a script from the internet
    /// into bash, and what actually RUNS never does.
    @Test func whatRunsIsNeverAScriptPipedFromTheNetwork() throws {
        let sim = Sim(); defer { sim.tearDown() }
        let log = sim.root.appendingPathComponent("apply.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        var env = bundleInstall(sim)
        env["SIMMER_FAKE_LATEST"] = "v9.9.9"
        env["SIMMER_FAKE_APPLY"] = log.path
        let result = sim.run(["update", "--apply", "--json"], env: env)

        // The command it would have PRINTED does pipe curl into bash…
        #expect((object(result.out)["update_command"] as? String)?.contains("curl") == true)
        // …and nothing it RAN does.
        let ran = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(!ran.contains("curl"))
        #expect(!ran.contains("bash"))
        #expect(!ran.isEmpty, "nothing was recorded at all")
    }

    /// Nothing to install is exit 0. Being current is the good outcome, and a
    /// caller that treats it as a failure would retry forever.
    @Test func applyingWhenCurrentDoesNothingAndSucceeds() {
        let sim = Sim(); defer { sim.tearDown() }
        let version = sim.run(["--version"]).out
            .replacingOccurrences(of: "simmer ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var env = bundleInstall(sim)
        env["SIMMER_FAKE_LATEST"] = "v\(version)"

        let result = sim.run(["update", "--apply", "--json"], env: env)
        #expect(result.code == 0)
        #expect(object(result.out)["applied"] as? Bool == false)
        #expect(object(result.out)["action"] as? String == "checked")
    }

    /// A working repository is not machinery: it may hold local commits, an
    /// unfinished branch or a stash.
    @Test func applyRefusesInSomebodysOwnCheckout() {
        let sim = Sim(); defer { sim.tearDown() }
        // The suite's own binary runs from a checkout, so no fixture is needed
        // — just no SIMMER_BIN pointing at a bundle.
        let result = sim.run(["update", "--apply", "--json"],
                             env: ["SIMMER_FAKE_LATEST": "v9.9.9"])

        #expect(result.code == 1)
        let json = object(result.out)
        #expect(json["action"] as? String == "refused")
        #expect(json["applied"] as? Bool == false)
        #expect((json["apply_error"] as? String)?.isEmpty == false)
    }

    /// Honoured or refused, never accepted and dropped. Applying what a cached
    /// answer said could install a release that has since been pulled.
    @Test func applyAndCachedTogetherAreRefused() {
        let sim = Sim(); defer { sim.tearDown() }
        let result = sim.run(["update", "--apply", "--cached"],
                             env: ["SIMMER_FAKE_LATEST": "v9.9.9"])
        #expect(result.code == 1)
        #expect(result.err.contains("--cached"), "\(result.err)")
    }

    /// Not knowing whether there is an update is not a licence to install one.
    @Test func applyRefusesWhenTheCheckCouldNotBeMade() throws {
        let sim = Sim(); defer { sim.tearDown() }
        let log = sim.root.appendingPathComponent("apply.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        var env = bundleInstall(sim)
        env["SIMMER_FAKE_LATEST"] = "error"
        env["SIMMER_FAKE_APPLY"] = log.path
        let result = sim.run(["update", "--apply"], env: env)

        #expect(result.code == 1)
        #expect((try? String(contentsOf: log, encoding: .utf8)) == "",
                "something was run despite not knowing whether to")
    }
}
