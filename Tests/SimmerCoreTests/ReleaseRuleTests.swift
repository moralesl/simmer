import Foundation
import Testing

/// The version rule, exercised as a table.
///
/// `scripts/release.sh next-version` is what decides whether the next release
/// is a patch, a minor or a major, and CI writes that number into a pull
/// request nobody re-derives by hand. A rule that decides a version number
/// without a test is a rule that publishes the wrong one silently — a minor
/// announced as a patch is a contract change nobody was told about.
///
/// It lives here rather than in a `scripts/*.test.sh` lane of its own because
/// `swift test` is this repository's one test command and every CI leg already
/// runs it. A fourth lane, for one script, would be a second thing to remember
/// and a second thing to forget — and this is the same kind of assertion
/// `StructureTests` already makes about files rather than code.
@Suite struct ReleaseRuleTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    struct Result {
        let out: String, err: String, code: Int32

        /// One `key=value` line from the output, which is the shape every
        /// machine surface in this repository speaks.
        func value(_ key: String) -> String? {
            out.split(separator: "\n")
                .first { $0.hasPrefix("\(key)=") }
                .map { String($0.dropFirst(key.count + 1)) }
        }
    }

    /// A throwaway CHANGELOG and Version.swift, so the rule is asked about
    /// fixtures rather than about whatever this checkout happens to say today.
    static func run(_ args: [String], changelog: String, version: String = "0.3.0") -> Result {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-release-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let changelogPath = dir.appendingPathComponent("CHANGELOG.md")
        let versionPath = dir.appendingPathComponent("Version.swift")
        try! changelog.write(to: changelogPath, atomically: true, encoding: .utf8)
        try! """
        public enum SimmerVersion {
            public static let string = "\(version)"
        }
        """.write(to: versionPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = repoRoot.appendingPathComponent("scripts/release.sh")
        process.arguments = args + [
            "--changelog", changelogPath.path,
            "--version-file", versionPath.path,
        ]
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try! process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self),
                      code: process.terminationStatus)
    }

    /// A CHANGELOG whose `## Unreleased` section holds exactly `body`.
    static func changelog(unreleased body: String) -> String {
        """
        # Changelog

        ## Unreleased
        \(body)
        ## 0.3.0 — 2026-09-07

        ### Added

        - the release before this one

        """
    }

    // ── the rule ────────────────────────────────────────────────────────────

    /// docs/RELEASING.md § What a version number means, one row at a time.
    ///
    /// The two headings that mean "minor" are the two CONTRACTS.md governs —
    /// the machine surface and the test seam — and they are read as a
    /// DECLARATION, not as a hint. Prose under `### Added` is never inspected:
    /// "adds a `--json` field" and "adds a menu row" are the same sentence to
    /// a machine, and guessing wrong in the permissive direction ships a
    /// contract change announced as a bug fix.
    @Test(arguments: [
        // (what the Unreleased section holds, the bump it earns, the version)
        ("", "none", ""),
        ("\n", "none", ""),
        ("\n### Fixed\n\n- a crash on an empty ledger\n", "patch", "0.3.1"),
        ("\n### Added\n\n- a menu row that copies\n", "patch", "0.3.1"),
        ("\n### Machine surface\n\n- `update --json` gains `release_notes_url`\n", "minor", "0.4.0"),
        ("\n### The test seam\n\n- `SIMMER_FAKE_LOCKDELAY`\n", "minor", "0.4.0"),
        // Two headings, one of them a surface: the surface wins.
        ("\n### Fixed\n\n- a crash\n\n### Machine surface\n\n- a new field\n", "minor", "0.4.0"),
        // A heading with nothing under it is somebody's leftover scaffolding.
        ("\n### Machine surface\n\n### Fixed\n\n- a crash\n", "patch", "0.3.1"),
    ])
    func theBumpIsDecidedByTheHeadingsUnderUnreleased(
        body: String, bump: String, version: String
    ) {
        let result = Self.run(["next-version"], changelog: Self.changelog(unreleased: body))
        #expect(result.code == 0, "release.sh next-version failed: \(result.err)")
        #expect(result.value("bump") == bump, "wrong bump for:\(body)")
        #expect(result.value("current") == "0.3.0")
        if version.isEmpty {
            #expect(result.value("version") == nil,
                    "nothing to release, so there must be no version to release it as")
        } else {
            #expect(result.value("version") == version)
        }
    }

    /// A major is never inferred. Removing a field, renaming one and changing
    /// one's type all read exactly like adding one, so the only honest source
    /// is a person saying so — the `release: major` label on the release pull
    /// request, or the workflow's dispatch input.
    @Test func aMajorIsDeclaredAndNeverInferred() {
        let removal = Self.changelog(unreleased: """

            ### Machine surface

            - `status --machine` no longer prints `seamed`

            """)
        #expect(Self.run(["next-version"], changelog: removal).value("bump") == "minor",
                "prose cannot be read for removals — without the label this is a minor")
        #expect(Self.run(["next-version", "--bump", "major"], changelog: removal).value("version") == "1.0.0")
    }

    /// A declaration overrules the rule in **either** direction, including
    /// downwards.
    ///
    /// 0.3.1 shipped that way: an entry under `### Machine surface` made it a
    /// minor by the rule, and it went out as a patch because a person decided
    /// it should. A rule with no override is a rule that gets worked around
    /// outside the mechanism, where nothing records who decided or what the
    /// rule had said — so the override is a label, both halves of CI read it,
    /// and `rule_bump` carries what the rule had said so the pull request can
    /// print both.
    @Test(arguments: [
        // (what is declared, the version, what the rule said underneath)
        ("patch", "0.3.1", "minor"),
        ("minor", "0.4.0", nil),      // agrees with the rule; nothing was overruled
        ("major", "1.0.0", "minor"),
    ])
    func aDeclarationOverrulesTheRuleInEitherDirection(
        declared: String, version: String, ruleBump: String?
    ) {
        let surface = Self.changelog(unreleased: """

            ### Machine surface

            - `doctor --json` gains a field

            """)
        #expect(Self.run(["next-version"], changelog: surface).value("version") == "0.4.0",
                "the rule on its own reads a machine-surface entry as a minor")

        let result = Self.run(["next-version", "--bump", declared], changelog: surface)
        #expect(result.value("bump") == declared)
        #expect(result.value("version") == version)
        #expect(result.value("rule_bump") == ruleBump,
                "an overruled rule has to be reported, or the override is invisible")
    }

    /// A declared bump on an empty section is still nothing. A label is an
    /// instruction about a release, not a reason to invent one.
    @Test(arguments: ["major", "minor", "patch"])
    func aDeclarationDoesNotConjureAReleaseOutOfNothing(declared: String) {
        let result = Self.run(["next-version", "--bump", declared],
                              changelog: Self.changelog(unreleased: "\n"))
        #expect(result.value("bump") == "none")
        #expect(result.value("version") == nil)
    }

    /// A bump nobody defined is refused rather than guessed at.
    @Test func anUnknownBumpIsRefused() {
        let result = Self.run(["next-version", "--bump", "sideways"],
                              changelog: Self.changelog(unreleased: "\n### Fixed\n\n- a crash\n"))
        #expect(result.code != 0)
        #expect(result.err.contains("--bump takes major, minor or patch"))
    }

    // ── the declaration in the CHANGELOG ────────────────────────────────────

    /// A release declares its own number, next to the notes that earned it.
    ///
    /// The label was the only override at first, and that made the mechanism's
    /// first act in front of somebody a wrong number to be corrected: 0.3.1
    /// would have opened as 0.4.0 and been relabelled. A declaration under
    /// `## Unreleased` travels with the change, in the pull request that makes
    /// it, reviewed by whoever reviews the notes — so the release pull request
    /// opens right.
    ///
    /// `<!-- release: patch -->` rather than a visible line: it is an
    /// instruction to CI and not a note to whoever reads the release, a
    /// visible "released as a patch" under a heading called *Unreleased* is a
    /// claim about something that has not happened, and a `.md` diff is raw
    /// markdown — so it is perfectly visible exactly where it is reviewed.
    @Test(arguments: [
        // (what sits under ## Unreleased, the bump, the version)
        ("\n<!-- release: patch -->\n\n### Machine surface\n\n- a field\n", "patch", "0.3.1"),
        ("\n<!-- release: minor -->\n\n### Fixed\n\n- a crash\n", "minor", "0.4.0"),
        ("\n<!-- release: major -->\n\n### Fixed\n\n- a crash\n", "major", "1.0.0"),
        // Placement is not policed: anywhere in the section is the section.
        ("\n### Fixed\n\n- a crash\n\n<!-- release: minor -->\n", "minor", "0.4.0"),
        // Spacing inside the comment is a person typing, not a different
        // instruction.
        ("\n<!--release:patch-->\n\n### Machine surface\n\n- a field\n", "patch", "0.3.1"),
    ])
    func theChangelogDeclaresItsOwnBump(body: String, bump: String, version: String) {
        let result = Self.run(["next-version"], changelog: Self.changelog(unreleased: body))
        #expect(result.code == 0, "\(result.err)")
        #expect(result.value("bump") == bump)
        #expect(result.value("version") == version)
    }

    /// Prose about the syntax is not the syntax.
    ///
    /// This is not hypothetical: the CHANGELOG entry announcing this feature
    /// sits under `## Unreleased` and says the words `<!-- release: patch -->`
    /// in the middle of a sentence, in the same section as the real
    /// declaration. Anything but a whole-line match would have read that as a
    /// second declaration and refused the release that introduced the feature.
    @Test func onlyAWholeLineIsADeclaration() {
        let result = Self.run(["next-version"], changelog: Self.changelog(unreleased: """

            <!-- release: patch -->

            ### Releasing

            - One line under `## Unreleased` — `<!-- release: patch -->`, `minor` or
              `major` — declares the number. Text mentioning `<!-- release: major -->`
              is text.

            ### Machine surface

            - a field, so the rule reads a minor and the declaration overrules it

            """))
        #expect(result.code == 0, "prose was read as a declaration: \(result.err)")
        #expect(result.value("bump") == "patch")
        #expect(result.value("declared_by") == "changelog")
    }

    /// Precedence, and the reason for it: the label is the LATER decision,
    /// taken looking at the release pull request itself, where the CHANGELOG
    /// declaration was taken with the notes before there was a release to look
    /// at. Both beat the category rule, which is the only one of the three
    /// that guessed — and whichever won has to say so, or an override is
    /// indistinguishable from the rule having agreed all along.
    @Test func aLabelOverrulesAChangelogDeclarationAndTheOutputSaysWhich() {
        let declared = Self.changelog(unreleased: """

            <!-- release: patch -->

            ### Machine surface

            - a field

            """)

        let fromFile = Self.run(["next-version"], changelog: declared)
        #expect(fromFile.value("version") == "0.3.1")
        #expect(fromFile.value("declared_by") == "changelog")
        #expect(fromFile.value("rule_bump") == "minor")

        let fromLabel = Self.run(["next-version", "--bump", "major"], changelog: declared)
        #expect(fromLabel.value("version") == "1.0.0", "the label is the later decision, so it wins")
        #expect(fromLabel.value("declared_by") == "label")
        #expect(fromLabel.value("rule_bump") == "minor",
                "the rule is still what was overruled, whoever did the overruling")

        // A label agreeing with the file is not an override of anything.
        let agreeing = Self.run(["next-version", "--bump", "patch"], changelog: declared)
        #expect(agreeing.value("version") == "0.3.1")
        #expect(agreeing.value("declared_by") == "label")
    }

    /// Nothing was declared, so nothing claims to have been.
    @Test func anUndeclaredReleaseReportsNoDeclaration() {
        let result = Self.run(["next-version"],
                              changelog: Self.changelog(unreleased: "\n### Fixed\n\n- a crash\n"))
        #expect(result.value("bump") == "patch")
        #expect(result.value("declared_by") == nil)
        #expect(result.value("rule_bump") == nil)
    }

    /// A misspelling is refused, never ignored.
    ///
    /// Ignoring it ships the release at whatever the rule said while somebody
    /// believes they declared otherwise — which is exactly the failure this
    /// mechanism exists to prevent, arrived at through the mechanism itself.
    @Test(arguments: [
        ("\n<!-- release: sideways -->\n\n### Fixed\n\n- a crash\n",
         "a bump is major, minor or patch"),
        ("\n<!-- release: patch -->\n<!-- release: major -->\n\n### Fixed\n\n- a crash\n",
         "declares more than one bump"),
    ])
    func aMalformedDeclarationIsRefused(body: String, refusal: String) {
        let result = Self.run(["next-version"], changelog: Self.changelog(unreleased: body))
        #expect(result.code != 0, "this should not have passed: \(result.out)")
        #expect(result.err.contains(refusal), "the refusal said: \(result.err)")
    }

    /// A declaration in a section that is already released is somebody's
    /// history, not an instruction. Only `## Unreleased` is read.
    @Test func onlyTheUnreleasedSectionIsReadForADeclaration() {
        let result = Self.run(["next-version"], changelog: """
        # Changelog

        ## Unreleased

        ### Fixed

        - a crash

        ## 0.3.0 — 2026-09-07

        <!-- release: major -->

        - the release before this one

        """)
        #expect(result.value("bump") == "patch")
        #expect(result.value("version") == "0.3.1")
    }

    /// The declaration is CONSUMED by the rename, in both directions: it must
    /// not reach the published notes, where it would be a directive to CI in
    /// something people read, and it must not stay in the fresh
    /// `## Unreleased`, where it would be a decision nobody took repeating
    /// itself at the next release.
    @Test func writeConsumesTheDeclaration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-consume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let changelogPath = dir.appendingPathComponent("CHANGELOG.md")
        let versionPath = dir.appendingPathComponent("Version.swift")
        try Self.changelog(unreleased: """

            <!-- release: patch -->

            ### Machine surface

            - a field

            """)
            .write(to: changelogPath, atomically: true, encoding: .utf8)
        try """
        public enum SimmerVersion {
            public static let string = "0.3.0"
        }
        """.write(to: versionPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = Self.repoRoot.appendingPathComponent("scripts/release.sh")
        process.arguments = ["write", "0.3.1", "--date", "2026-09-08",
                             "--changelog", changelogPath.path,
                             "--version-file", versionPath.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let written = try String(contentsOf: changelogPath, encoding: .utf8)
        #expect(!written.contains("release: patch"),
                "the declaration survived the rename:\n\(written)")
        #expect(written.contains("- a field"), "the notes have to survive it, though")
        #expect(!written.contains("\n\n\n"),
                "consuming the line should not leave a doubled blank:\n\(written)")
    }

    // ── the labels, read once for both halves of CI ─────────────────────────

    /// `bump-label` is the single reader of the release pull request's labels.
    ///
    /// Two halves of CI ask this question — the job that WRITES the number and
    /// the `release-check` leg that RE-DERIVES it on the pull request — and a
    /// second implementation is exactly how they would come to disagree on the
    /// one pull request where it matters. The disagreement is not theoretical:
    /// before this existed, an overridden number was red on `release-check`
    /// and therefore unmergeable.
    @Test(arguments: [
        // (the labels a pull request carries, what they declare)
        (["bug", "release: patch"], "patch"),
        (["release: major"], "major"),
        (["release: minor", "release: minor"], "minor"),   // one label, twice
        (["bug", "documentation"], ""),                     // nothing declared
        ([], ""),
        (["release: majorish"], ""),                        // not the label
        (["Release: Major"], ""),                           // nor is this
    ])
    func theLabelsAreReadOnce(labels: [String], declared: String) throws {
        #expect(try Self.bumpLabel(labels).out.trimmingCharacters(in: .whitespacesAndNewlines) == declared)
    }

    /// Two different bump labels is not a bump to choose between — it is two
    /// people who have not spoken to each other. Picking one silently is the
    /// one answer that publishes somebody's number without their knowing.
    @Test func twoDifferentBumpLabelsAreRefused() throws {
        let result = try Self.bumpLabel(["release: patch", "release: major"])
        #expect(result.code != 0)
        #expect(result.err.contains("more than one bump label"))
        #expect(result.err.contains("major patch"), "the refusal names them: \(result.err)")
    }

    /// Label names on stdin, the way `gh pr list --jq` hands them over.
    static func bumpLabel(_ labels: [String]) throws -> Result {
        let process = Process()
        process.executableURL = repoRoot.appendingPathComponent("scripts/release.sh")
        process.arguments = ["bump-label"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data(labels.joined(separator: "\n").utf8))
        try inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self),
                      code: process.terminationStatus)
    }

    /// The bump is arithmetic on the version in `Version.swift`, and a minor
    /// zeroes the patch while a major zeroes both.
    @Test(arguments: [
        ("1.4.9", "\n### Fixed\n\n- a crash\n", "1.4.10"),
        ("1.4.9", "\n### Machine surface\n\n- a field\n", "1.5.0"),
    ])
    func theNextVersionIsArithmeticOnTheCurrentOne(
        current: String, body: String, next: String
    ) {
        let result = Self.run(["next-version"],
                              changelog: Self.changelog(unreleased: body), version: current)
        #expect(result.value("version") == next)
    }

    // ── what a release commit writes ────────────────────────────────────────

    /// `write` renames `## Unreleased` and leaves a fresh empty one above it,
    /// so the next change has somewhere to land — the thing step 2 of the old
    /// hand-cut procedure asked a person to remember.
    @Test func writeRenamesUnreleasedAndLeavesAFreshOneAboveIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let changelogPath = dir.appendingPathComponent("CHANGELOG.md")
        let versionPath = dir.appendingPathComponent("Version.swift")
        try Self.changelog(unreleased: "\n### Fixed\n\n- a crash\n")
            .write(to: changelogPath, atomically: true, encoding: .utf8)
        try """
        public enum SimmerVersion {
            public static let string = "0.3.0"
        }
        """.write(to: versionPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = Self.repoRoot.appendingPathComponent("scripts/release.sh")
        process.arguments = ["write", "0.3.1", "--date", "2026-09-08",
                             "--changelog", changelogPath.path,
                             "--version-file", versionPath.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let written = try String(contentsOf: changelogPath, encoding: .utf8)
        #expect(written.contains("## 0.3.1 — 2026-09-08"))
        #expect(written.contains("## Unreleased"))
        let unreleasedAt = written.range(of: "## Unreleased")!.lowerBound
        let sectionAt = written.range(of: "## 0.3.1 — ")!.lowerBound
        #expect(unreleasedAt < sectionAt,
                "a fresh Unreleased below the new section would put the next change inside a published release")
        #expect(written.contains("- a crash"), "the notes must move into the release, not vanish")

        let version = try String(contentsOf: versionPath, encoding: .utf8)
        #expect(version.contains("\"0.3.1\""))
        #expect(!version.contains("\"0.3.0\""), "the old version must be gone, not merely joined")
    }

    /// Version.swift and the CHANGELOG move together or not at all — the
    /// invariant `StructureTests` asserts, made unbreakable by giving the two
    /// edits one command instead of two steps in a document.
    @Test func writeRefusesToWriteASectionThatAlreadyExists() throws {
        let result = Self.run(["write", "0.3.0", "--date", "2026-09-08"],
                              changelog: Self.changelog(unreleased: "\n### Fixed\n\n- a crash\n"))
        #expect(result.code != 0)
        #expect(result.err.contains("already has a '## 0.3.0' section"))
    }

    // ── the check the release pull request has to pass ──────────────────────

    /// An ordinary pull request does not move the version, and the check has
    /// nothing to ask of it beyond the heading the next change needs.
    @Test func checkPassesAnOrdinaryPullRequest() {
        let result = Self.run(["check", "--released", "0.1.0 0.2.0 0.3.0"],
                              changelog: Self.changelog(unreleased: "\n### Fixed\n\n- a crash\n"))
        #expect(result.code == 0, "\(result.err)")
        #expect(result.out.contains("already released"))
    }

    /// The three ways a release pull request can be wrong, each named.
    @Test(arguments: [
        // (the CHANGELOG, the fragment the refusal must name)
        ("""
         # Changelog

         ## Unreleased

         ## 0.3.0 — 2026-09-07

         - the release before this one

         """, "no '## 0.3.1 — <date>' section"),
        ("""
         # Changelog

         ## Unreleased

         ## 0.3.1 — soon

         - something

         """, "not YYYY-MM-DD"),
        ("""
         # Changelog

         ## Unreleased

         ## 0.3.1 — 2026-09-08

         ## 0.3.0 — 2026-09-07

         - the release before this one

         """, "is empty"),
    ])
    func checkRefusesAReleaseThatIsNotOne(changelog: String, refusal: String) {
        let result = Self.run(["check", "--released", "0.1.0 0.2.0 0.3.0"],
                              changelog: changelog, version: "0.3.1")
        #expect(result.code != 0, "this should not have passed:\n\(result.out)")
        #expect(result.err.contains(refusal), "the refusal said: \(result.err)")
    }

    /// A declaration that outlived the rename would put a directive to CI in
    /// the published notes and repeat a one-release decision at the next one.
    @Test func checkRefusesADeclarationThatSurvivedTheRename() {
        let result = Self.run(["check", "--released", "0.1.0 0.2.0 0.3.0"],
                              changelog: """
                              # Changelog

                              ## Unreleased

                              ## 0.3.1 — 2026-09-08

                              <!-- release: patch -->

                              - something

                              """, version: "0.3.1")
        #expect(result.code != 0)
        #expect(result.err.contains("still carries a release declaration"), "\(result.err)")
    }

    /// The label case, which is the whole reason this check is required rather
    /// than advisory: `release: major` added after CI computed the number
    /// leaves a pull request that says 0.3.1 where the rule now says 1.0.0,
    /// and nothing else in the repository would notice.
    @Test func checkRefusesAVersionTheRuleDisagreesWith() {
        let result = Self.run(["check", "--released", "0.1.0 0.2.0 0.3.0",
                               "--expect-version", "1.0.0"],
                              changelog: """
                              # Changelog

                              ## Unreleased

                              ## 0.3.1 — 2026-09-08

                              ### Machine surface

                              - `status --machine` no longer prints `seamed`

                              """,
                              version: "0.3.1")
        #expect(result.code != 0)
        #expect(result.err.contains("the version rule says this release is 1.0.0, not 0.3.1"))
    }

    // ── the workflow's one structural rule ──────────────────────────────────

    /// Every job in `release-pr.yml` that can write is gated on `main`.
    ///
    /// `decide` is read-only and deliberately runs from anywhere: dispatching
    /// it from a branch is a useful dry run of what a release would be. Every
    /// job below it writes relative to whatever ref the run checked out, and
    /// from a feature branch that meant building `release/next` out of that
    /// branch — a pull request whose diff was the branch, titled `release:
    /// X.Y.Z` — and, in the tag job, tagging and publishing a bumped version
    /// from a commit nobody released. That one has no way back.
    ///
    /// A one-line `if:` is exactly the kind of thing a later edit drops without
    /// anyone noticing, and no test that runs the workflow can exist, so this
    /// reads the file. It asserts the RULE rather than a list of job names:
    /// a job added tomorrow with `contents: write` and no guard fails here,
    /// which is the only version of this check worth having.
    @Test func everyJobThatWritesIsGatedOnMain() throws {
        let workflow = try Self.read(".github/workflows/release-pr.yml")
        let jobs = Self.jobs(in: workflow)

        #expect(jobs["decide"] != nil, "release-pr.yml lost its decide job, and with it the guard everything reads")
        let decide = jobs["decide"] ?? ""
        #expect(!Self.writes(decide),
                "decide must stay read-only — it is the one job that runs from any ref")
        #expect(decide.contains("refs/heads/main"),
                "decide no longer computes the guard, so nothing below it can be gated on anything")

        let writers = jobs.filter { $0.key != "decide" && Self.writes($0.value) }
        #expect(writers.count >= 3,
                "expected the branch, tag and publish jobs to declare write access; found \(writers.keys.sorted()) — if they were renamed, say so here, and if they stopped declaring it, this check has quietly stopped covering them")

        for (name, body) in writers.sorted(by: { $0.key < $1.key }) {
            #expect(body.contains("needs.decide.outputs.act == 'true'"),
                    "job \(name) can write but is not gated on main")
        }
    }

    /// The `jobs:` mapping, split into one block per job id. Two spaces of
    /// indent is a job key; anything more indented belongs to it.
    static func jobs(in workflow: String) -> [String: String] {
        var jobs: [String: String] = [:]
        var current: String?
        var inJobs = false
        for line in workflow.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "jobs:" { inJobs = true; continue }
            guard inJobs else { continue }
            // A job key: exactly two spaces, a name, a colon, nothing after it.
            if line.hasPrefix("  "), !line.hasPrefix("   "),
               line.hasSuffix(":"), !line.dropFirst(2).contains(" ") {
                current = String(line.dropFirst(2).dropLast())
                jobs[current!] = ""
                continue
            }
            if let current { jobs[current, default: ""] += line + "\n" }
        }
        return jobs
    }

    /// Whether a job asks for a permission that reaches outside its own run.
    static func writes(_ job: String) -> Bool {
        ["contents: write", "pull-requests: write", "actions: write", "packages: write"]
            .contains { job.contains($0) }
    }

    /// A fresh `## Unreleased` written BELOW the new section would send every
    /// later note into a release that has already been published.
    @Test func checkRefusesAnUnreleasedHeadingBelowTheRelease() {
        let result = Self.run(["check", "--released", "0.1.0 0.2.0 0.3.0"],
                              changelog: """
                              # Changelog

                              ## 0.3.1 — 2026-09-08

                              - something

                              ## Unreleased

                              """,
                              version: "0.3.1")
        #expect(result.code != 0)
        #expect(result.err.contains("below the 0.3.1 section"))
    }
}
