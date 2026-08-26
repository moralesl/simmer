import Foundation
import Testing

/// `make skill` renders the agent protocol out of AGENTS.md into a Claude Code
/// skill, so an agent that has never seen this repository still gets the rules.
/// Generated rather than kept as a second copy — a copy drifts, and the only
/// reader who would notice is the agent holding the stale one.
///
/// That makes the extraction a silent single point of failure: rename a heading
/// and the recipe still exits 0, still writes a file, and writes an empty or a
/// too-generous one. `make install` would then hand agents either nothing or the
/// contributor rules. These tests run the real recipe and check what came out.
///
/// In the unit suite rather than the acceptance one: the subject is this
/// repository's own generator, not the built binary's contract. `StructureTests`
/// sits here for the same reason.
@Suite struct SkillTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Run `make skill` into a throwaway directory and return the result.
    /// SKILL_DIR is the same variable `install` and `uninstall` use, so this
    /// exercises the production recipe and never touches the real ~/.claude.
    static func generate() throws -> String {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }

        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        make.arguments = ["-C", repoRoot.path, "skill", "SKILL_DIR=\(out.path)"]
        make.standardOutput = FileHandle.nullDevice
        make.standardError = FileHandle.nullDevice
        try make.run()
        make.waitUntilExit()
        #expect(make.terminationStatus == 0, "`make skill` exited \(make.terminationStatus)")

        return try String(contentsOf: out.appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    /// The frontmatter Claude Code needs to load it at all, and a description
    /// that says when to reach for it — a skill nothing triggers is a skill
    /// nothing reads, which would waste the whole exercise.
    @Test func theSkillIsLoadableAndSaysWhenToUseIt() throws {
        let skill = try Self.generate()

        #expect(skill.hasPrefix("---\n"), "no opening frontmatter fence")
        let parts = skill.components(separatedBy: "---\n")
        #expect(parts.count >= 3, "frontmatter is not closed")
        let frontmatter = parts[1]
        #expect(frontmatter.contains("name: simmer"))
        #expect(frontmatter.contains("description: \""))
        // The trigger words an agent's own situation would match on.
        #expect(frontmatter.lowercased().contains("use before"))
        #expect(frontmatter.contains("simmer"))
        // Frontmatter is one block at the top, not sprinkled through the body.
        #expect(!parts[2].contains("name: simmer"))
    }

    /// The protocol half, all of it. Each string below is an obligation or a
    /// trap an agent gets wrong without being told — losing any of them to a
    /// heading rename is the failure this test exists to catch.
    @Test func theSkillCarriesTheWholeProtocol() throws {
        let skill = try Self.generate()

        for required in [
            "budget --need",            // ask before starting
            "exit 3",                   // and what the answer means
            "--owner agent:",           // claim under your own name
            "SIMMER_HUMAN",             // never claim human authority
            "down --all",               // what you may not do
            "clipped_by_cap",           // the success that is not what you asked for
            "seconds_left",             // the field with three shapes
            "pmset -a disablesleep",    // never do this by hand
            "XDG_STATE_HOME",           // how to sandbox your own tests
        ] {
            #expect(skill.contains(required), "the skill lost: \(required)")
        }
        // Anti-vacuity: an empty extraction passes nothing above, but a recipe
        // that emitted the entire page would pass all of it.
        #expect(skill.count > 2000, "only \(skill.count) characters — extraction too small")
    }

    /// And nothing from the contributor half. An agent on some other machine has
    /// no checkout, cannot run `make`, and must not be told about bundle ids —
    /// every line it cannot act on is a line that buries one it can.
    @Test func theSkillStopsAtTheContributorHalf() throws {
        let skill = try Self.generate()

        for leaked in [
            "# Changing simmer",
            "Iron rules",
            "xcodebuild",
            "SimmerCore stays pure",
            "Bundle ids are spent",
            "make test-raycast",
        ] {
            #expect(!skill.contains(leaked), "the contributor half leaked: \(leaked)")
        }
    }

    /// The recipe depends on two exact headings and on the protocol coming
    /// first. Reordering the page or renaming a heading breaks the extraction
    /// with a zero exit code, so the shape it relies on is asserted here rather
    /// than discovered by an agent reading an empty skill.
    @Test func thePageKeepsTheShapeTheRecipeExtractsFrom() throws {
        let page = try String(contentsOf: Self.repoRoot.appendingPathComponent("AGENTS.md"),
                              encoding: .utf8)
        let lines = page.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let using = lines.firstIndex(of: "# Using simmer"),
              let changing = lines.firstIndex(of: "# Changing simmer")
        else {
            Issue.record("AGENTS.md must keep the exact headings `# Using simmer` and `# Changing simmer` — `make skill` extracts between them")
            return
        }
        #expect(using < changing, "the protocol must come first; the skill is the text before `# Changing simmer`")
        #expect(changing - using > 40, "the protocol section is suspiciously short")
    }
}
