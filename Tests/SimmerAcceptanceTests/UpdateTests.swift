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
