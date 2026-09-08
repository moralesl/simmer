import Foundation
import Testing
@testable import SimmerCore

/// Structural decisions that nothing in the code can express, and that a
/// person can therefore undo by accident in one line. They were prose in a
/// document; they are assertions now, which is the only form that survives a
/// contributor who has not read the document.
@Suite struct StructureTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The compiled-in version has a CHANGELOG section, always.
    ///
    /// Bumping `Version.swift` and writing the notes are one act, not two: the
    /// bump is what a release IS, and notes written afterwards are written from
    /// `git log` by someone reconstructing decisions they were present for.
    /// This fails in the pull request that bumps the version, which is where it
    /// costs one line to fix.
    ///
    /// It also makes the release workflow's job small — by tag time the notes
    /// already exist and the only new question is whether the tag agrees with
    /// this string, which is a question only a tag can answer.
    @Test func theVersionHasItsOwnChangelogSection() throws {
        let changelog = try Self.read("CHANGELOG.md")
        let heading = "## \(SimmerVersion.string) — "
        #expect(changelog.contains(heading),
                "CHANGELOG.md has no \"\(heading)<date>\" section for the version in Version.swift")
    }

    /// Work in flight collects under one heading, so the release commit renames
    /// it rather than inventing notes.
    ///
    /// Not a check that it is non-empty: a release commit legitimately leaves it
    /// empty, and a rule that forbade that would be a rule to work around on
    /// exactly the commit that matters most.
    @Test func thereIsSomewhereForUnreleasedNotesToGo() throws {
        let changelog = try Self.read("CHANGELOG.md")
        #expect(changelog.contains("## Unreleased"),
                "CHANGELOG.md lost its Unreleased section — the next change has nowhere to land")
    }

    /// The sugar layer's verb list and the parser's subcommand list must name
    /// exactly the same verbs.
    ///
    /// They are two hand-kept lists in two files, and disagreeing in either
    /// direction is silent. A subcommand the normaliser does not know is
    /// unreachable — `simmer update` was read as a duration and diagnosed as
    /// "did not understand the duration: update", with the command right there
    /// in the binary. A verb the normaliser knows with nothing behind it is the
    /// raw parser's "Unexpected argument", the one refusal in the surface that
    /// names no fix.
    ///
    /// Derived from the source rather than from a third list, because a gate
    /// with its own copy of the answer is a fourth thing to keep in step.
    @Test func theSugarLayerAndTheParserKnowTheSameVerbs() throws {
        let normalize = try Self.read("Sources/SimmerCLI/Normalize.swift")
        guard let literal = normalize.components(separatedBy: "static let verbs: Set<String> = [")
            .dropFirst().first?.components(separatedBy: "]").first else {
            #expect(Bool(false), "Normalize.verbs is not a set literal any more")
            return
        }
        let sugarVerbs = Set(Self.quoted(in: literal))

        let cli = try Self.read("Sources/SimmerCLI/CLI.swift")
        guard let declared = cli.components(separatedBy: "subcommands: [")
            .dropFirst().first?.components(separatedBy: "]").first else {
            #expect(Bool(false), "SimmerRoot declares no subcommands array")
            return
        }
        let types = declared.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasSuffix(".self") }
            .map { String($0.dropLast(".self".count)) }
        #expect(types.count > 5, "the subcommand list did not parse: \(types)")

        // `commandName` is what the verb is actually called, and it does not
        // always follow from the type name (`NotifyTestCLI` is `notify-test`).
        var parserVerbs = Set<String>()
        let sources = (try? FileManager.default.contentsOfDirectory(
            at: Self.repoRoot.appendingPathComponent("Sources/SimmerCLI"),
            includingPropertiesForKeys: nil)) ?? []
        let allCLISource = sources.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        for type in types {
            guard let afterStruct = allCLISource.components(separatedBy: "struct \(type)")
                .dropFirst().first,
                  let name = Self.quoted(in: afterStruct.components(separatedBy: "commandName: ")
                      .dropFirst().first?.components(separatedBy: ",").first ?? "").first else {
                #expect(Bool(false), "no commandName found for \(type)")
                continue
            }
            parserVerbs.insert(name)
        }

        let sugarOnly = sugarVerbs.subtracting(parserVerbs)
        let parserOnly = parserVerbs.subtracting(sugarVerbs)
        #expect(sugarVerbs == parserVerbs,
                "sugar knows \(sugarOnly) with nothing behind it; the parser has \(parserOnly) that sugar swallows")
    }

    /// Which verbs refuse `--json` is answered in three places, and they must
    /// answer the same.
    ///
    /// Two of the three were already gated against each other:
    /// `everyVerbHonoursJSON` walks the whole verb list and
    /// `theVerbsWithoutAMachineAnswerSaySo` enumerates the refusers, and T4's
    /// brief said in as many words that two lists of one question are two
    /// lists that can come to disagree. It stopped one reader short. The third
    /// is the law — `docs/CONTRACTS.md` — and it named two verbs for a release
    /// while the code refused five, so an implementation written to the law
    /// accepts `guard --json`, prints nothing and exits 0: the exact defect
    /// 0.3.2 fixed, reintroduced by the document that is supposed to prevent
    /// it. `CLI.swift`'s doc comment, the fourth, said "the two commands".
    ///
    /// Gated in BOTH directions, by set equality rather than containment. A
    /// missing word is the drift that happened; a surplus one is a verb the
    /// law promises has no machine answer while the code answers happily, and
    /// a caller who believes the law then never asks. Neither is the safe
    /// direction, so neither is allowed.
    ///
    /// The enumeration in the acceptance suite is the source: it is the one of
    /// the three that a wrong answer makes red on its own.
    @Test func theThreeListsOfWhichVerbsRefuseJSONNameTheSameVerbs() throws {
        let acceptance = try Self.read("Tests/SimmerAcceptanceTests/MachineOutputTests.swift")
        guard let rows = acceptance
            .components(separatedBy: "func theVerbsWithoutAMachineAnswerSaySo").dropFirst().first?
            .components(separatedBy: "for invocation in [").dropFirst().first?
            .components(separatedBy: "]] {").first else {
            #expect(Bool(false), "theVerbsWithoutAMachineAnswerSaySo no longer enumerates invocations")
            return
        }
        // Each row is a whole invocation; the verb is its first literal.
        let refused = Set(rows.components(separatedBy: "[").dropFirst()
            .compactMap { Self.quoted(in: $0).first })
        #expect(refused.count > 1, "the enumeration did not parse: \(refused)")

        // The law. Fences skipped, and exactly one prose line may carry it —
        // two would mean the gate is holding one of them in step and letting
        // the other drift.
        let sentences = Self.unfencedLines(of: try Self.read("docs/CONTRACTS.md"))
            .filter { $0.contains("have none and **refuse** the flag") }
        #expect(sentences.count == 1,
                "docs/CONTRACTS.md states which verbs refuse --json on \(sentences.count) prose lines")
        let law = Set(sentences.flatMap { Self.backticked(in: $0) })
        #expect(law == refused,
                "docs/CONTRACTS.md names \(law.subtracting(refused)) that nothing refuses, and omits \(refused.subtracting(law))")

        // And `refuseJSON`'s own doc comment, the reader that said "the two
        // commands" through 0.3.2.
        let comment = Self.scriptLines(of: try Self.read("Sources/SimmerCLI/CLI.swift"))
            .filter { $0.contains("///") && $0.contains("no machine answer") }
        #expect(comment.count == 1,
                "refuseJSON's doc comment names its verbs on \(comment.count) lines")
        // The list may wrap, so read from the anchor line to the end of that
        // sentence rather than from the anchor line alone.
        let documented = Set(Self.backticked(in: Self.docCommentSentence(
            startingAt: "no machine answer",
            in: try Self.read("Sources/SimmerCLI/CLI.swift"))))
        #expect(documented == refused,
                "refuseJSON's comment names \(documented.subtracting(refused)) that nothing refuses, and omits \(refused.subtracting(documented))")
    }

    /// One sentence of a doc comment, from the line holding `anchor` to the
    /// first `.` that ends it — because a list of five verbs wraps, and a
    /// reader of the anchor line alone answers about half of it. Adversarial
    /// case 3: a wrapped item read one line at a time is an item silently
    /// truncated.
    static func docCommentSentence(startingAt anchor: String, in source: String) -> String {
        let lines = scriptLines(of: source)
        guard let start = lines.firstIndex(where: { $0.contains("///") && $0.contains(anchor) })
        else { return "" }
        var sentence = ""
        for line in lines[start...] {
            guard let marker = line.range(of: "///") else { break }
            let text = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            sentence += (sentence.isEmpty ? "" : " ") + text
            if text.contains(".") { break }
        }
        // The sentence ends at its full stop; what follows on that line is the
        // next one, and reading it in is how `--json` — the flag, not a verb —
        // joined the list this gate compares.
        if let stop = sentence.firstIndex(of: ".") { sentence = String(sentence[..<stop]) }
        return sentence
    }

    /// The setup window's two update captions are one line each.
    ///
    /// They were paragraphs — eight sentences and an environment variable under
    /// a checkbox, in a window whose other three rows are a title and one line
    /// — and prose asking for brevity is prose. What a person needs in order to
    /// tick the box stays on screen; the rest is one click away in the FAQ, and
    /// the length is the part a gate can hold.
    ///
    /// 78 characters is what fits on one rendered line at 11pt in the 460pt
    /// label, measured on the window itself rather than assumed.
    @Test func theUpdateCaptionsAreOneLineEach() throws {
        let source = try Self.read("Sources/SimmerApp/SetupWindow.swift")
        for caption in ["updateCaption", "autoCaption"] {
            guard let declaration = source
                .components(separatedBy: "let \(caption) = NSTextField(wrappingLabelWithString:")
                .dropFirst().first?
                .components(separatedBy: ")").first else {
                #expect(Bool(false), "\(caption) is not a wrapping label any more")
                continue
            }
            let literals = Self.quoted(in: declaration)
            #expect(literals.count == 1,
                    "\(caption) is \(literals.count) concatenated literals — one line is one literal")
            let text = literals.joined()
            #expect(text.count <= 78,
                    "\(caption) is \(text.count) characters and wraps onto a second line: \(text)")
        }
    }

    /// "Learn more…" points at a heading that exists.
    ///
    /// The captions above are short because the detail moved into
    /// `docs/FAQ.md`, and the only way back to it from a Mac with no terminal
    /// open is that link. A renamed heading does not break it loudly: GitHub
    /// serves the page and silently ignores an anchor it cannot resolve, so the
    /// person who clicked lands at the top of the FAQ and reads about
    /// `caffeinate` instead. Only a gate notices.
    @Test func theLearnMoreLinkLandsOnAHeadingTheFAQStillHas() throws {
        let source = try Self.read("Sources/SimmerApp/SetupWindow.swift")
        guard let url = Self.quoted(in: source.components(separatedBy: "static let updateFAQURL")
            .dropFirst().first ?? "").first,
              let anchor = url.components(separatedBy: "#").dropFirst().first, !anchor.isEmpty else {
            #expect(Bool(false), "SetupWindow.updateFAQURL is not a literal URL with an anchor")
            return
        }
        #expect(url.contains("docs/FAQ.md"), "the link left the FAQ: \(url)")

        // GitHub's rule for the anchor it generates from a heading: lowercased,
        // punctuation dropped, spaces to hyphens.
        let headings = try Self.read("docs/FAQ.md")
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("#") }
            .map { heading -> String in
                let words = heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                return String(words.map { $0 == " " ? "-" : $0 }
                    .filter { $0.isLetter || $0.isNumber || $0 == "-" })
            }
        #expect(headings.contains(anchor),
                "docs/FAQ.md has no heading whose anchor is #\(anchor) — the link scrolls nowhere. It has: \(headings)")
    }

    /// Every double-quoted string in a fragment of Swift source.
    /// The tail of `bootstrap.sh` as *both* gates over it need to read it:
    /// the last line that is neither blank nor a comment, and where it is.
    ///
    /// Two gates read that tail and they disagreed. `theInstallerIsTruncationSafe`
    /// (`SudoRuleTests.swift`) reads the last non-empty, non-`#` line, so a
    /// trailing comment is legal there — which it is: everything is inside
    /// functions and a comment after the call cannot run. `BootstrapFetchTests`
    /// read the last non-empty line and then dropped it, so that same trailing
    /// comment left `main "$@"` in the "library", and sourcing it ran
    /// `build_and_install`, `install_sudo_rule` and `launch_app` on the
    /// tester's Mac (R3 finding 2). One reader answers both now, so a legal
    /// tail cannot be legal to one gate and an installer to the other.
    ///
    /// `.whitespacesAndNewlines`, not `.whitespaces`: under CRLF every line
    /// carries a trailing `\r`, and a reader that does not trim it answers
    /// about `main "$@"\r`.
    static func lastRealLine(of script: String) -> (index: Int, text: String)? {
        let lines = scriptLines(of: script)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let index = lines.lastIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else { return nil }
        return (index, lines[index])
    }

    /// The `` `token` `` spellings on one line of markdown or of a doc
    /// comment. Odd-numbered fragments of a split on the backtick are what
    /// sat between a pair of them.
    static func backticked(in line: String) -> [String] {
        line.components(separatedBy: "`").enumerated()
            .filter { $0.offset % 2 == 1 }
            .map(\.element)
            .filter { !$0.isEmpty }
    }

    /// Swift with its line comments removed, so an absence check reads CODE.
    ///
    /// An absence proof that reads the whole file answers about the sentence
    /// explaining why the thing is absent: `retire`'s own comment names the
    /// second `fileExists` it no longer makes, and the first version of
    /// `retireDecidesFromTheRemovalsAnswerAndNotASecondStat` was red against
    /// the fix it was written for. Line comments only, and a `//` inside a
    /// string literal would be cut with them — no reader here has one.
    static func codeOnly(of source: String) -> String {
        scriptLines(of: source).map { line -> String in
            guard let marker = line.range(of: "//") else { return line }
            return String(line[..<marker.lowerBound])
        }.joined(separator: "\n")
    }

    /// A markdown document's PROSE lines, fenced blocks dropped.
    ///
    /// A gate that reads a document's own examples as the thing it documents
    /// has been written three times in three weeks here: `docs/CONTRACTS.md`
    /// quotes JSON objects and shell transcripts that hold the same words its
    /// law does, and a reader that counts them is answering about the
    /// examples.
    static func unfencedLines(of markdown: String) -> [String] {
        var prose: [String] = []
        var inFence = false
        for line in scriptLines(of: markdown) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence { prose.append(line) }
        }
        return prose
    }

    /// A shell script split into its lines — CRLF included.
    ///
    /// `split(separator: "\n")` cannot do this: in Swift `"\r\n"` is ONE
    /// Character, a grapheme cluster, so it matches neither `"\n"` nor
    /// `"\r"` and a CRLF script splits into a single line. Every reader of
    /// its tail then answers about the whole file, which is how the first
    /// version of `lastRealLine` read `bootstrap.sh` as one line whose text
    /// was the entire script (caught by the CRLF row of
    /// `theLibraryDropsTheCallHoweverTheTailIsWritten`). `isNewline` is true
    /// for the cluster, for a bare `\r` and for `\n` alike.
    static func scriptLines(of script: String) -> [String] {
        script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    static func quoted(in fragment: String) -> [String] {
        var found: [String] = []
        var current: String?
        for character in fragment {
            if character == "\"" {
                if let value = current { found.append(value); current = nil } else { current = "" }
            } else if current != nil {
                current?.append(character)
            }
        }
        return found
    }

    /// macOS binds a notification grant to the executable that asked. With two
    /// executables in one bundle, each reads its own state — so a CLI that
    /// links UserNotifications asks questions about the wrong binary and gets
    /// "not determined" forever, while the app's banners work fine. The CLI
    /// therefore must not link the notification code at all; it enqueues into
    /// the spool and the app posts.
    @Test func theCLICannotReachTheNotificationCentre() throws {
        let manifest = try Self.read("Package.swift")
        // Each .executableTarget( … ) block on its own, so the CLI's
        // dependency list cannot be confused with the app's or with the
        // product declarations above them.
        let blocks = manifest.components(separatedBy: ".executableTarget(").dropFirst()
        let cliTarget = blocks.first { $0.contains(#"name: "simmer""#) }
        #expect(cliTarget != nil, "could not find the simmer executable target")
        #expect(cliTarget?.contains("SimmerNotifyKit") == false)
        #expect(cliTarget?.contains("SimmerCore") == true)
        // The app, by contrast, is the one thing that may post.
        let appTarget = blocks.first { $0.contains(#"name: "simmer-app""#) }
        #expect(appTarget?.contains("SimmerNotifyKit") == true)

        // And no source file in the CLI may import it either.
        let cliSources = (try? FileManager.default.contentsOfDirectory(
            at: Self.repoRoot.appendingPathComponent("Sources/SimmerCLI"),
            includingPropertiesForKeys: nil)) ?? []
        #expect(!cliSources.isEmpty)
        for file in cliSources where file.pathExtension == "swift" {
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!source.contains("import UserNotifications"), "\(file.lastPathComponent)")
            #expect(!source.contains("import SimmerNotifyKit"), "\(file.lastPathComponent)")
        }
    }

    /// APFS is case-insensitive by default, so `Contents/MacOS/Simmer` and
    /// `Contents/MacOS/simmer` are the SAME FILE: the second copy silently
    /// overwrites the first and the "app" then runs the CLI's main, prints a
    /// status line and exits. Nothing errors and the bundle even signs, so only
    /// an assertion catches it.
    @Test func theBundlesTwoExecutablesHaveCaseDistinctNames() throws {
        let makefile = try Self.read("Makefile")
        #expect(makefile.contains("Contents/MacOS/simmer-app"))
        #expect(makefile.contains("Contents/MacOS/simmer"))
        #expect(!makefile.contains("Contents/MacOS/Simmer"))

        // The plist must name the app binary, not the CLI.
        let plist = try Self.read("app/Info.plist.template")
        #expect(plist.contains("simmer-app"))

        // Case-insensitively distinct: the two names must not collide.
        #expect("simmer-app".lowercased() != "simmer".lowercased())
    }

    /// Uninstalling deletes the guard, the app, and the CLI binary the
    /// `~/.local/bin` symlink points at — every mechanism on the Mac that can
    /// put the sleep switch back. Run with a claim live, the old recipe left
    /// `pmset -a disablesleep 1` on: no expiry, no indicator, survives reboots
    /// (PLATFORM-FACTS.md), named as the vulnerability in SECURITY.md, and the
    /// recovery command written down nowhere.
    ///
    /// So the recipe hands the machine back first and stops if it could not,
    /// and every path out of here names the manual revert. Asserted because a
    /// Makefile has no type system and this is one line away from being true
    /// again.
    /// launchd hands an agent none of the installing shell's environment, so
    /// the ledger's location has to be written into the plist. Without it a
    /// shell exporting XDG_STATE_HOME gave the guard one ledger and the CLI
    /// another, settling one switch against each other every thirty seconds,
    /// converging never — and no check anywhere went red. Three lines have to
    /// agree for that not to come back, and none of them is type-checked.
    @Test func theGuardIsToldWhichLedgerToRead() throws {
        let template = try Self.read("launchd/guard.plist.template")
        #expect(template.contains("EnvironmentVariables"))
        #expect(template.contains("XDG_STATE_HOME"))
        #expect(template.contains("@STATE_HOME@"))

        let makefile = try Self.read("Makefile")
        #expect(makefile.contains("@STATE_HOME@|$(STATE_HOME)"),
                "the placeholder is in the template but nothing substitutes it")
        #expect(makefile.contains("STATE_HOME   ?="))
        // The same default as SimmerEnvironment.stateDir, which is the whole
        // point: a guard that falls back differently is the original bug.
        #expect(makefile.contains("$(HOME)/.local/state"))
        let environment = try Self.read("Sources/SimmerCore/Seam/Environment.swift")
        #expect(environment.contains(".local/state"))
    }

    /// `run`'s renewer reads `finished`, then builds a context, reads the
    /// claim and consults the cap — and every one of those is time for
    /// `cleanup()` to retire the claim underneath it. The write then put the
    /// claim back, and the guard held the switch on for a dead process until
    /// the chunk ran out, up to forty-five minutes.
    ///
    /// `cleanup` sets `finished` under this same lock BEFORE it retires
    /// anything, so holding the lock across the write leaves only the two
    /// orders that are correct. A unit test cannot reach a race; this asserts
    /// the shape that removes it, which is the only form that survives someone
    /// tidying the lock away.
    /// The other half of the bundle has the guard's bug: an app launched from
    /// the Dock inherits none of the shell's environment, so a shell exporting
    /// XDG_STATE_HOME put the app on one ledger and the CLI on another — two
    /// halves settling the same switch against each other, converging never.
    /// Both version keys move with the release.
    ///
    /// `CFBundleShortVersionString` was substituted and `CFBundleVersion` was
    /// the literal `1`, forever — so every build looked like the same build to
    /// LaunchServices, which is the registry that decides which copy of an app
    /// is the current one.
    @Test func theBundleCarriesTheVersionInBothKeys() throws {
        let plist = try Self.read("app/Info.plist.template")
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            guard let range = plist.range(of: "<key>\(key)</key>") else {
                Issue.record("no \(key) in the bundle template")
                continue
            }
            let after = plist[range.upperBound...].prefix(60)
            #expect(after.contains("@VERSION@"), "\(key) does not move with the release")
        }
    }

    /// `make install` replaces the bundle under a running app, so the process
    /// keeps executing the old binary — menu bar, event tick and notification
    /// identity all one version behind the ledger, with nothing saying so, and
    /// `open` afterwards just activates the process that is already there.
    @Test func installQuitsTheAppBeforeReplacingIt() throws {
        let makefile = try Self.read("Makefile")
        let body = (makefile.components(separatedBy: "\ninstall: app").last ?? "")
            .components(separatedBy: "\nuninstall:").first ?? ""
        guard let quit = body.range(of: "to quit"),
              let replace = body.range(of: "cp -R $(STAGED_APP) $(APP)") else {
            Issue.record("install no longer both quits and replaces")
            return
        }
        #expect(quit.lowerBound < replace.lowerBound)
        #expect(body.contains("pgrep -qx simmer-app"))
    }

    /// The bundle is the same bundle whichever checkout assembled it, so the
    /// only way to know which one did is for `make install` to write it down.
    /// Without it, `doctor` and `update` both named `~/.local/share/simmer`
    /// whatever the truth was — a directory that is not on a Mac installed
    /// from somebody's own checkout, so its repair command could not be run
    /// and `update --apply` refused.
    ///
    /// Three lines have to agree, and none of them is type-checked.
    @Test func theBundleRecordsWhichCheckoutInstalledIt() throws {
        let plist = try Self.read("app/Info.plist.template")
        #expect(plist.contains("SimmerInstallSource"))
        #expect(plist.contains("@INSTALL_SOURCE@"))

        let makefile = try Self.read("Makefile")
        #expect(makefile.contains("@INSTALL_SOURCE@|$(CURDIR)"),
                "the placeholder is in the template but nothing substitutes it")

        let install = try Self.read("Sources/SimmerCore/Model/Install.swift")
        #expect(install.contains("SimmerInstallSource"),
                "the plist carries it and nothing reads it")
    }

    @Test func theAppIsToldWhichLedgerToRead() throws {
        let plist = try Self.read("app/Info.plist.template")
        #expect(plist.contains("SimmerStateHome"))
        #expect(plist.contains("@STATE_HOME@"))

        let makefile = try Self.read("Makefile")
        #expect(makefile.contains("@STATE_HOME@|$(STATE_HOME)"),
                "the placeholder is in the template but nothing substitutes it")

        let appState = try Self.read("Sources/SimmerApp/AppState.swift")
        #expect(appState.contains("SimmerStateHome"),
                "the plist carries it and the app never reads it")
        #expect(appState.contains("XDG_STATE_HOME"))
    }

    /// A running Simmer.app outlives the files it was launched from, keeps its
    /// menu bar, and one click re-arms `disablesleep` — with the sudoers rule
    /// still in place and nothing left on the Mac able to turn it off.
    @Test func uninstallQuitsTheAppBeforeDeletingIt() throws {
        let makefile = try Self.read("Makefile")
        let body = (makefile.components(separatedBy: "\nuninstall:").last ?? "")
            .components(separatedBy: "\nclean:").first ?? ""
        #expect(body.contains("to quit"))
        guard let quit = body.range(of: "to quit"),
              let removal = body.range(of: "rm -rf $(APP)") else {
            Issue.record("uninstall no longer quits the app or removes the bundle")
            return
        }
        #expect(quit.lowerBound < removal.lowerBound,
                "the app is deleted before it is asked to quit")
    }

    /// **The sweep assertion.** `sudo -nl <command>` answers whether a command
    /// is permitted, not whether it is permitted WITHOUT a password, so it
    /// exits 0 on every admin Mac through the stock `(ALL) ALL` entry. It was
    /// replaced in `doctor` and `uninstall` and left in the installer and the
    /// setup window — the fourth time in this branch a rule landed at only the
    /// call sites its author had in hand.
    ///
    /// So the rule is asserted over the whole tree rather than at the places
    /// someone remembered. The listing form — `-nl` with no command — is what
    /// every caller must use.
    @Test func nothingAsksSudoAboutASingleCommandAnyMore() throws {
        var offenders: [String] = []
        for relative in ["Sources", "bootstrap.sh"] {
            let root = Self.repoRoot.appendingPathComponent(relative)
            let files: [URL]
            if relative.hasSuffix(".sh") {
                files = [root]
            } else {
                files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }
                    .filter { $0.pathExtension == "swift" }) ?? []
            }
            for file in files {
                let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                // Comments only: `SudoRule` documents the abandoned probe at
                // length, and that prose is the reason nobody reintroduces it.
                // Excluding the whole file would blind this to a real call
                // site in the one place most likely to grow one.
                let source = raw.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { line in
                        let t = line.trimmingCharacters(in: .whitespaces)
                        return !t.hasPrefix("//") && !t.hasPrefix("#")
                    }
                    .joined(separator: "\n")
                // `-nl` followed by anything other than the end of the argument
                // list is a question about one command.
                if source.contains(#""-nl", "/usr/bin/pmset""#)
                    || source.range(of: #"sudo -nl [/-]"#, options: .regularExpression) != nil {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty, "still probing one command: \(offenders)")
    }

    /// The claim has to land BEFORE the switch flips.
    ///
    /// The other order leaves a window where the switch is on and the ledger
    /// is empty — the exact orphan a tick is built to heal — so a guard in
    /// that gap turned the switch back off under a caller who had just been
    /// told "lid may close" at exit 0. This order's window is the mirror: a
    /// claim on disk with the switch not yet on, where a tick turns it on,
    /// which was going to happen anyway. Both orders race; only one races
    /// toward the answer.
    ///
    /// Asserted on the source because the window is microseconds and no
    /// harness here could trigger it reliably — which is exactly the kind of
    /// ordering someone tidies back the other way.
    /// One owner-kind table, in two languages. A kind that gets 🚀 in the
    /// extension and 🤖 in the core is the human/non-human distinction
    /// blurring depending on where you look — and removing Alfred reached the
    /// renderer, the CLI, the roadmap and the human-name set, but not the
    /// agents' own law or the fourth renderer.
    /// **The sweep, for the sudoers path.** There is one rule file per user
    /// now and there was one per machine when every surface was written, so a
    /// caller naming a path directly reports "no rule" for an install that is
    /// right there. That is the fourth recurrence of "the rule reached the
    /// call sites its author had in hand", so it is asserted over the tree
    /// rather than at the places someone remembered.
    @Test func nothingOutsideSudoRuleNamesTheRuleFileDirectly() throws {
        var offenders: [String] = []
        let root = Self.repoRoot.appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SudoRule.swift" }) ?? []
        for file in files {
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            // The DIRECTORY is fine — "sudo grep -rn NOPASSWD /etc/sudoers.d/"
            // is advice, not a path this tool acts on. A named FILE is not.
            if code.contains("/etc/sudoers.d/simmer") || code.contains("SudoRule.path")
                || code.contains("SudoRule.legacyPath") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these name a rule path instead of asking SudoRule: \(offenders)")
    }

    @Test func theOwnerFacesAgreeAcrossLanguages() throws {
        let core = try Self.read("Sources/SimmerCore/Model/StatusTitle.swift")
        let extensionSource = try Self.read("integrations/raycast/src/claims.tsx")
        let agents = try Self.read("AGENTS.md")
        for gone in ["alfred"] {
            #expect(!core.contains("\"\(gone)\""), "core still knows \(gone)")
            #expect(!extensionSource.contains("\"\(gone)\""), "the extension still knows \(gone)")
            #expect(!agents.contains("`\(gone)`"), "AGENTS.md still names \(gone)")
        }
        // And every name the binary calls human is one the extension faces the
        // same way.
        let environment = try Self.read("Sources/SimmerCore/Seam/Environment.swift")
        for human in ["terminal", "menubar", "raycast"] {
            #expect(environment.contains("\"\(human)\""))
            #expect(extensionSource.contains("\"\(human)\""), "the extension has no face for \(human)")
        }
    }

    @Test func aClaimIsRecordedBeforeTheSwitchIsFlipped() throws {
        let source = try Self.read("Sources/SimmerCore/Commands/ClaimCommand.swift")
        let claimFn = source.components(separatedBy: "public static func claim(").last ?? ""
        let body = claimFn.components(separatedBy: "public static func extend(").first ?? claimFn
        guard let write = body.range(of: "ctx.ledger.write(claim)"),
              let flip = body.range(of: "ctx.power.setDisableSleep(true)") else {
            Issue.record("claim no longer both records and flips — re-read this test")
            return
        }
        #expect(write.lowerBound < flip.lowerBound,
                "the switch is flipped before the claim exists, which a guard tick reads as an orphan")
        // And a switch that will not move takes the claim back rather than
        // leaving a promise nothing is keeping.
        #expect(body.contains("removeClaim(id: claim.id, ifStillMatching: claim)"))
    }

    /// `retire`'s silence is decided by the removal's own answer, never by a
    /// second question to the filesystem.
    ///
    /// A second `fileExists` is a second point in time, and the answers
    /// disagree exactly in the race the ERROR line exists for: the record
    /// changed under the tick and then went, so the stat said "not there" and
    /// the one failure worth reporting was silenced. No fixture can reach
    /// that window once it is closed — with the reason taken from the call
    /// that took the decision there is nothing between the two — so what is
    /// asserted is the shape, which is the thing that can come back.
    @Test func retireDecidesFromTheRemovalsAnswerAndNotASecondStat() throws {
        let source = try Self.read("Sources/SimmerCore/Model/Ledger.swift")
        guard let after = source.components(separatedBy: "public func retire(").dropFirst().first,
              let whole = after.components(separatedBy: "\n    }").first else {
            Issue.record("retire is not a function of Ledger any more — re-read this test")
            return
        }
        // Comments stripped: this function's own comment names the
        // `fileExists` it stopped making, and an absence proof that reads it
        // is answering about the explanation.
        let body = Self.codeOnly(of: whole)
        #expect(body.contains("outcomeOfRemovingClaim"),
                "retire is back to a Bool that cannot say why it failed")
        #expect(!body.contains("fileExists"),
                "retire asks the filesystem a second time, and the two answers disagree in the one race the ERROR line is for")
    }

    @Test func theRunRenewerWritesUnderTheLockItChecksUnder() throws {
        let source = try Self.read("Sources/SimmerCLI/RunCLI.swift")
        let renewer = source.components(separatedBy: "func startRenewer()").last ?? ""
        let body = renewer.components(separatedBy: "func cleanup()").first ?? renewer

        guard let write = body.range(of: "ctx.ledger.write(claim)") else {
            Issue.record("the renewer no longer writes the claim — re-read this test")
            return
        }
        let before = body[..<write.lowerBound]
        let after = body[write.upperBound...]
        // A lock is taken before the write and released after it...
        #expect(before.contains("done.lock()"))
        #expect(after.contains("done.unlock()"))
        // ...and `finished` is re-read inside it, not only at the top of the
        // loop, which is the check that was there and did not help.
        let insideLock = before.components(separatedBy: "done.lock()").last ?? ""
        #expect(insideLock.contains("finished"),
                "the write is under the lock but nothing re-checks finished inside it")
    }

    /// The gate has to key on the INSTALLED reality, not on this invocation's
    /// variables, and it has to notice a seam.
    ///
    /// It hung off `$(BIN_DIR)/simmer`, so an install done with a different
    /// BIN_DIR or PREFIX made both the hand-back and the refusal silently
    /// untrue while the removals below — fixed paths — ran anyway. And it
    /// grepped `sleep_disabled=0` while `status` prints `seamed=1` on the next
    /// line: under a leaked SIMMER_FAKE_PMSET the gate was reading a file in
    /// /tmp and calling it the machine.
    @Test func theUninstallGateReadsTheMachineAndNotTheEnvironment() throws {
        let makefile = try Self.read("Makefile")
        let body = (makefile.components(separatedBy: "\nuninstall:").last ?? "")
            .components(separatedBy: "\nclean:").first ?? ""
        // Which binary: from the LaunchAgent, which records what was installed.
        #expect(body.contains("PlistBuddy"))
        #expect(body.contains("$(AGENT_PLIST)"))
        // The seam is a refusal, not a detail.
        #expect(body.contains("seamed=0"))
        #expect(body.contains("-u SIMMER_FAKE_PMSET"))
        // And no binary at all means refuse, rather than skip the gate.
        #expect(body.contains("no installed simmer binary found"))
    }

    /// The quit is an AppleEvent: TCC can refuse it silently and it fails in
    /// any non-interactive context. `-osascript … 2>/dev/null` on its own was
    /// a hope, not a step — so it is verified, the way `install` verifies its
    /// bootout, before the bundle the app is running from is deleted.
    @Test func uninstallVerifiesTheAppActuallyQuit() throws {
        let makefile = try Self.read("Makefile")
        let body = (makefile.components(separatedBy: "\nuninstall:").last ?? "")
            .components(separatedBy: "\nclean:").first ?? ""
        guard let check = body.range(of: "pgrep -qx simmer-app"),
              let removal = body.range(of: "rm -rf $(APP)") else {
            Issue.record("uninstall no longer checks for the app or removes the bundle")
            return
        }
        #expect(check.lowerBound < removal.lowerBound)
        #expect(body.contains("still running and would outlive"))
    }

    /// One bundle id, in two files that cannot see each other. A quit sent to
    /// the wrong id silently does nothing, which is the failure mode with no
    /// symptom.
    @Test func theBundleIdIsTheSameInTheMakefileAndTheBinary() throws {
        let makefile = try Self.read("Makefile")
        let runtime = try Self.read("Sources/SimmerCLI/Runtime.swift")
        guard let line = makefile.split(separator: "\n").first(where: {
            $0.hasPrefix("BUNDLE_ID")
        }) else {
            Issue.record("no BUNDLE_ID in the Makefile")
            return
        }
        let id = line.components(separatedBy: "?=").last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        #expect(!id.isEmpty)
        #expect(runtime.contains("\"\(id)\""), "Runtime does not carry \(id)")
        #expect(runtime.contains("\"\(id).guard\""), "the guard label drifted from the bundle id")
    }

    @Test func uninstallHandsTheMachineBackBeforeRemovingTheMeansToDoIt() throws {
        let makefile = try Self.read("Makefile")
        let recipe = makefile.components(separatedBy: "\nuninstall:").last ?? ""
        let body = recipe.components(separatedBy: "\nclean:").first ?? ""
        #expect(body.contains("down --all"))
        #expect(body.contains("sleep_disabled=0"))
        #expect(body.contains("pmset -a disablesleep 0"))
        // The release has to come before the first removal, or it is decoration.
        let release = body.range(of: "down --all")
        let firstRemoval = body.range(of: "launchctl bootout")
        #expect(release != nil && firstRemoval != nil)
        if let release, let firstRemoval {
            #expect(release.lowerBound < firstRemoval.lowerBound)
        }

        // And the CLI's own account of what to remove says the same, for
        // anyone following its printed commands instead of the target.
        let cli = try Self.read("Sources/SimmerCLI/UninstallCLI.swift")
        #expect(cli.contains("pmset -a disablesleep 0"))
        #expect(cli.contains("simmer down --all"))
    }

    /// The command lines of one target, and nothing else.
    ///
    /// A recipe is the tab-indented run of lines after `<target>:`, which is
    /// what `make` itself reads — and the distinction matters here: the
    /// `print-test-flags` block has `$(TEST_FLAGS)` in its own COMMENT
    /// explaining what it must never become, and a reader that took the whole
    /// region between two targets would be satisfied by that comment while the
    /// recipe echoed something else entirely. Comments and blank lines inside
    /// the run are dropped for the same reason.
    ///
    /// Lines come from `scriptLines`, the one reader of that question in this
    /// file: `components(separatedBy: "\n")` does split a CRLF file, but it
    /// leaves a trailing `\r` on every line for the caller to remember to
    /// trim, and a caller that forgets answers about `$(TEST_FLAGS)\r`. Two
    /// spellings of "split a text file into lines" in one suite is the seam
    /// the drift comes through — `split(separator: "\n")` is a third and
    /// cannot do it at all, because `"\r\n"` is ONE Character in Swift
    /// (measured: 3 lines, 3 lines, 1 line). `isNewline` also covers a
    /// `\r`-only file, which no hand-rolled trim did.
    ///
    /// A recipe line continued with a trailing `\` is ONE command to `make`,
    /// so it is one command here too — counting the physical lines would
    /// refuse a wrapped command that is perfectly correct.
    ///
    /// Absent is not empty and doubled is not "the one I picked": a target
    /// that is gone, and a target defined twice, both return nil. `make`
    /// keeps the LAST of two recipes for one target and warns; a reader that
    /// silently took either one would be guessing which of two answers the
    /// build uses, so the caller records an issue instead.
    static func makeRecipe(of target: String, in makefile: String) -> [String]? {
        let lines = scriptLines(of: makefile)
        let headers = lines.indices.filter { lines[$0].hasPrefix(target + ":") }
        guard headers.count == 1, let start = headers.first else { return nil }

        var commands: [String] = []
        var continued = false
        for line in lines[(start + 1)...] {
            guard line.hasPrefix("\t") else { break }
            let command = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if command.isEmpty || (!continued && command.hasPrefix("#")) { continue }
            if continued {
                commands[commands.endIndex - 1] += " " + command
            } else {
                commands.append(command)
            }
            continued = command.hasSuffix("\\")
        }
        return commands.map {
            $0.replacingOccurrences(of: "\\", with: " ")
                .components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// `test` and `print-test-flags` pass the same flags because they name the
    /// same variable, and this is the only thing keeping that true.
    ///
    /// On a CLT-only Mac `swift test` finds no `Testing.framework` and fails to
    /// compile every suite — and has been seen exiting 0 while doing it, a
    /// green gate over nothing. `TEST_FLAGS` is what fixes that, and
    /// `print-test-flags` exists so a FILTERED run can be spelled by hand
    /// (`swift test $(make -s print-test-flags) --filter X`) instead of every
    /// contributor reading the flags out of the Makefile again.
    ///
    /// Which makes it a second place the flags are named. The failure with no
    /// symptom is a refactor moving `test` to a new variable and leaving this
    /// one echoing the old: both targets keep working, `make test` is green,
    /// and the filtered run silently builds with different flags than the lane
    /// it claims to narrow — or with none, and reports its compile failure as
    /// a test failure.
    ///
    /// So the assertion is on the variable NAME in both recipes, never on the
    /// flag values: the flags are derived from `xcode-select -p` and are
    /// legitimately empty under a selected Xcode, and CI runs both.
    @Test func theFilteredRunPrintsTheFlagsTheTestLaneUses() throws {
        let makefile = try Self.read("Makefile")

        guard let lane = Self.makeRecipe(of: "test", in: makefile),
              let printer = Self.makeRecipe(of: "print-test-flags", in: makefile) else {
            Issue.record("the Makefile has no single `test` or `print-test-flags` recipe")
            return
        }

        // One command each, so "and nothing else" is a property and not a
        // reading of the current text.
        #expect(lane.count == 1, "the test lane is no longer one command: \(lane)")
        #expect(printer.count == 1, "print-test-flags prints more than one thing: \(printer)")
        #expect(lane.first?.hasPrefix("swift test ") == true,
                "the test lane is no longer a `swift test` invocation: \(lane)")
        #expect(printer.first?.hasPrefix("@echo ") == true,
                "print-test-flags must be a bare @echo — anything else it emits becomes an argument to `swift test`: \(printer)")

        // The pair, stated as the pair: whatever the variable is called, both
        // recipes call it THAT. Names, never values — the flags are derived
        // from `xcode-select -p` and are legitimately empty under an Xcode.
        let variables = { (recipe: [String]) in
            recipe.joined(separator: " ").components(separatedBy: "$(")
                .dropFirst().compactMap { $0.components(separatedBy: ")").first }
        }
        #expect(!variables(lane).isEmpty, "the test lane passes no flags variable at all: \(lane)")
        #expect(variables(lane) == variables(printer),
                "the two recipes name different variables: \(variables(lane)) vs \(variables(printer))")

        // And a file of that name in the checkout must not shadow the target.
        // Every `.PHONY:` line, because more than one is legal and a reader
        // that took the first would refuse a target listed on the second.
        let phony = makefile.components(separatedBy: "\n")
            .filter { $0.hasPrefix(".PHONY:") }
            .flatMap { $0.components(separatedBy: .whitespaces) }
        #expect(!phony.isEmpty, "the Makefile has no .PHONY line")
        #expect(phony.contains("print-test-flags"), ".PHONY does not list print-test-flags")

        // CONTRIBUTING has to carry the spelling, or the target is a secret.
        let contributing = try Self.read("CONTRIBUTING.md")
        #expect(contributing.contains("make -s print-test-flags"),
                "CONTRIBUTING never tells anyone the filtered run exists")
    }

    /// The reader above, held to the four Makefile shapes that have each
    /// defeated a text gate in this repository's history — asserted over
    /// synthetic text, because the only way to drive them against the real
    /// `Makefile` is to edit it, and evidence that has to be produced by hand
    /// is evidence nobody reproduces.
    @Test func theRecipeReaderIsNotFooledByTheShapesThatFoolTextGates() {
        // Plain.
        #expect(Self.makeRecipe(of: "test", in: "test:\n\tswift test $(TEST_FLAGS)\n")
                == ["swift test $(TEST_FLAGS)"])

        // CRLF — the same answer, not a trailing \r glued to the variable.
        #expect(Self.makeRecipe(of: "test", in: "test:\r\n\tswift test $(TEST_FLAGS)\r\n")
                == ["swift test $(TEST_FLAGS)"])

        // And CR alone, which `components(separatedBy: "\n")` read as one line.
        #expect(Self.makeRecipe(of: "test", in: "test:\r\tswift test $(TEST_FLAGS)\r")
                == ["swift test $(TEST_FLAGS)"])

        // A comment inside the block, holding the very variable the gate looks
        // for. One command, and it is the recipe's, not the comment's.
        #expect(Self.makeRecipe(of: "p", in: """
        # echoes $(TEST_FLAGS) and must never become a second definition
        p:
        \t@echo -Xswiftc -F
        """) == ["@echo -Xswiftc -F"])

        // Wrapped: one logical command over three physical lines.
        #expect(Self.makeRecipe(of: "test", in: "test:\n\tswift test \\\n\t  $(TEST_FLAGS) \\\n\t  --parallel\n")
                == ["swift test $(TEST_FLAGS) --parallel"])

        // Doubled: make keeps the LAST and warns, so neither is "the" answer.
        #expect(Self.makeRecipe(of: "p", in: "p:\n\t@echo FIRST\n\np:\n\t@echo LAST\n") == nil)

        // Absent is nil, not [] — the caller must be able to tell the target
        // being gone from a target with an empty recipe.
        #expect(Self.makeRecipe(of: "print-test-flags", in: "test:\n\tswift test\n") == nil)
        #expect(Self.makeRecipe(of: "p", in: "p:\n\nq:\n\t@echo q\n") == [])

        // A target whose name is a prefix of another must not answer for it.
        #expect(Self.makeRecipe(of: "test", in: "test-release:\n\t@echo release\n") == nil)
    }

    /// Every `-o` argument of a `ray build` in a shell command line, in each
    /// spelling oclif accepts: `-o dist`, `-o=dist`, `-odist`,
    /// `--output dist`, `--output=dist`.
    ///
    /// All of them, not the last one: which occurrence oclif keeps is its
    /// business, and a gate that picks one is guessing. A flag with nothing
    /// after it comes back as the empty string, because a flag present with no
    /// value is a different fact from no flag at all and the two must not
    /// arrive here as the same answer.
    static func outputArguments(in command: String) -> [String] {
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var found: [String] = []
        for (index, token) in tokens.enumerated() {
            for flag in ["-o", "--output"] where token.hasPrefix(flag) {
                let rest = token.dropFirst(flag.count)
                if rest.isEmpty {
                    found.append(index + 1 < tokens.count ? tokens[index + 1] : "")
                } else if rest.hasPrefix("=") {
                    found.append(String(rest.dropFirst()))
                } else if flag == "-o" {
                    found.append(String(rest))
                }
                // `--outputs` and friends are some other flag, not this one.
                break
            }
        }
        return found
    }

    /// One `ray build` command line, held to the property.
    ///
    /// Every `-o` it carries, not the last one: which occurrence oclif keeps
    /// is its business, and a gate that picks one is guessing.
    ///
    /// The path is judged as it is *written*, and a written path that expands
    /// is not judgeable: npm runs every script through `sh`, so
    /// `-o $HOME/.config/raycast/extensions/simmer` and `-o ${HOME}/x` reach
    /// the process as absolute paths and carry neither a `/` nor a `~` for
    /// this to refuse. Measured, not assumed — a probe script through
    /// `npm run` printed `/Users/luis/.config/raycast/extensions/simmer` from
    /// the first and `/Users/luis/x` from the second. So a `$` anywhere in the
    /// argument is refused outright rather than expanded here: substitution is
    /// the shell's, and a gate that tries to predict it is guessing about
    /// somebody else's environment. That also covers `$(…)` and `${…}`.
    static func expectStaysInsideTheCheckout(_ command: String, run by: String) {
        let outputs = outputArguments(in: command)
        guard !outputs.isEmpty else {
            Issue.record("\(by) carries no -o; without one, ray build writes into ~/.config/raycast: \(command)")
            return
        }
        for output in outputs {
            #expect(!output.isEmpty,
                    "\(by) passes -o with no value: \(command)")
            #expect(!output.hasPrefix("/"),
                    "\(by) writes to the absolute path \(output): \(command)")
            #expect(!output.hasPrefix("~"),
                    "\(by) writes under $HOME, where the registered copy lives: \(command)")
            #expect(!output.contains("$"),
                    "\(by) has a shell expansion in \(output), which sh resolves before ray sees it")
            #expect(!output.split(separator: "/").contains(".."),
                    "\(by) climbs out of the checkout via \(output): \(command)")
        }
    }

    /// `npm run build` cannot write outside the checkout it is run in.
    ///
    /// `ray build`'s output directory *defaults* to
    /// `~/.config/raycast/extensions/<name>/` — the copy Raycast has
    /// registered on this Mac — and `-e dist` names the environment, not a
    /// path. So `ray build -e dist`, which is how this repository spelled the
    /// script until 2026-09-08, replaced the registered extension with a
    /// one-shot artifact of whichever checkout it ran in: it did exactly that
    /// at 09:31 and 09:32 that day from a worktree, and the registered copy
    /// had to be put back by hand at 12:07.
    ///
    /// R1 finding 4 is why this is a test and not a fourth paragraph of prose.
    /// The correction was written into the README, into
    /// `RaycastExtension.fixLines` and into a memory — and nothing anywhere
    /// went red if the `-o` never reached the script.
    ///
    /// The *property*, not the string `-o dist`: a test that greps for the
    /// literal is green on `-o dist` and blind to a later `-o ~/…`. What has
    /// to hold is that the path is relative and stays inside the extension
    /// directory, so a leading `/`, a leading `~` and any `..` component are
    /// all refused — `-o ../../../../.config/raycast/extensions/simmer`
    /// reaches the very directory this exists to protect, and even a
    /// harmless-looking `-o ../dist` would drop build output outside the
    /// `dist/` that `integrations/raycast/.gitignore:2` covers.
    ///
    /// **Two readers over one file, because one of them is not enough.** The
    /// parser is the precise one: `"build"` is not a key only `scripts` may
    /// hold, and a value may be spelled without the space after the colon, so
    /// a text grep answers about the wrong string. But `JSONSerialization`
    /// keeps the *first* of two identical keys and npm keeps the *last* — so a
    /// `package.json` carrying `"build"` twice, safe copy first, hands the
    /// parser the safe command while `npm run build` runs the unsafe one.
    /// Verified both ways rather than reasoned: `npm pkg get scripts.build`
    /// returns the last, this parser returns the first. The sweep over the raw
    /// text is what closes that — it holds *every* `ray build` in the file to
    /// the property, whichever key won — and it truncates at the enclosing
    /// string's closing quote, so a command it cannot read carries no `-o` and
    /// goes red rather than passing.
    ///
    /// Neither reader touches the README, whose own Development block is a
    /// fenced example of the very command this looks for. Needs no `ray` — CI
    /// is Linux and `ray` is macOS-only.
    @Test func theRaycastBuildStaysInsideItsOwnCheckout() throws {
        let manifest = "integrations/raycast/package.json"
        let text = try Self.read(manifest)

        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard let scripts = (parsed as? [String: Any])?["scripts"] as? [String: String] else {
            Issue.record("\(manifest) has no scripts object of strings this can read")
            return
        }
        guard scripts["build"] != nil else {
            Issue.record("\(manifest) declares no `build` script for `npm run build` to run")
            return
        }
        let building = scripts.filter { $0.value.contains("ray build") }.sorted { $0.key < $1.key }
        guard !building.isEmpty else {
            Issue.record("no script in \(manifest) invokes `ray build`; if it moved, move this gate")
            return
        }
        for (name, command) in building {
            Self.expectStaysInsideTheCheckout(command, run: "`npm run \(name)`")
        }

        for tail in text.components(separatedBy: "ray build").dropFirst() {
            let command = "ray build" + (tail.components(separatedBy: "\"").first ?? "")
            Self.expectStaysInsideTheCheckout(command, run: "a `ray build` in \(manifest)")
        }
    }
}

/// What `bootstrap.sh`'s `fetch()` does to a checkout that is already there.
///
/// `bash -n` and the readers above only look at the script as text, so the one
/// thing this function has to get right was proved once by hand and then
/// unprotected: it swallowed every failed fast-forward so that a TAG could
/// pass, which also swallowed a diverged BRANCH, printed "updated the existing
/// checkout" over the stale tree, and handed that tree to `make install`. The
/// installer said it had updated and then installed somebody's unpushed local
/// work as the release, at exit 0.
///
/// Driven the way the script itself cannot be: everything in `bootstrap.sh`
/// lives inside functions and the last line is `main "$@"`
/// (`theInstallerIsTruncationSafe` is the gate on that), so dropping that one
/// line leaves a library, and `fetch` can be called without
/// `build_and_install` or the sudo step ever running. Nothing is built,
/// nothing is installed, and the origin is a `git init` under the test's own
/// temp directory — no network.
@Suite struct BootstrapFetchTests {
    /// Why a script cannot be turned into a sourceable library.
    ///
    /// A thrown error and not a failed `#require`, because the STOP is the
    /// property under test and a recorded expectation cannot state it:
    /// `#expect(throws:)` catches the throw a `#require` makes, and the issue
    /// it recorded on the way out still fails the test (measured). The
    /// alternative, `withKnownIssue`, leaves `make test` reporting a known
    /// issue forever, which is a red the reader learns to ignore.
    ///
    /// It stops just as hard as `#require` did: every caller reaches it
    /// through `try`, so a `bootstrap.sh` whose tail this helper does not
    /// recognise fails the suite before anything is written or sourced.
    enum UnsourceableScript: Error, CustomStringConvertible, Equatable {
        case noCodeAtAll
        case tailIsNotTheCall(String)
        case aSecondCallSurvives

        var description: String {
            switch self {
            case .noCodeAtAll:
                return "bootstrap.sh has no code left in it at all"
            case .tailIsNotTheCall(let tail):
                return "bootstrap.sh no longer ends in main \"$@\" — it ends in \(tail)"
            case .aSecondCallSurvives:
                return "a second main \"$@\" survived the strip, and sourcing it would install"
            }
        }
    }

    /// The script minus its `main "$@"`, which is what makes it sourceable.
    ///
    /// Every check here throws rather than recording, because each one IS the
    /// safety argument for the next line: `#expect` records a failure and lets
    /// the removal, the write and the `.` run anyway, which is how a tail this
    /// helper did not recognise became an installer sourced on the tester's
    /// Mac (R3 finding 2). Where the assertion is the reason the next
    /// statement is safe, it has to stop.
    ///
    /// The tail is read through `StructureTests.lastRealLine`, the one reader
    /// `theInstallerIsTruncationSafe` uses too, so a trailing comment is legal
    /// to both gates or to neither.
    static func libraryText(of script: String) throws -> String {
        // The same split `lastRealLine` indexes into, or the index it
        // returns names a different line here.
        var lines = StructureTests.scriptLines(of: script)
        guard let tail = StructureTests.lastRealLine(of: script) else {
            throw UnsourceableScript.noCodeAtAll
        }
        guard tail.text == "main \"$@\"" else {
            throw UnsourceableScript.tailIsNotTheCall(tail.text)
        }
        lines.remove(at: tail.index)
        // A call in a COMMENT is not a call, which is why the comparison is
        // against the trimmed line rather than a `contains`.
        guard !lines.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "main \"$@\""
        }) else {
            throw UnsourceableScript.aSecondCallSurvives
        }
        return lines.joined(separator: "\n")
    }

    static func library(at url: URL) throws {
        try libraryText(of: try StructureTests.read("bootstrap.sh"))
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// The tail shapes `bootstrap.sh` is allowed to have, each yielding a
    /// library with no call in it — and the shape that must stop the helper
    /// rather than be silently trimmed into one.
    @Test func theLibraryDropsTheCallHoweverTheTailIsWritten() throws {
        let body = "fetch() {\n  :\n}\n\nmain \"$@\""
        for (shape, script) in [
            ("bare", body),
            ("trailing newline", body + "\n"),
            ("trailing comment", body + "\n# installed by curl | bash\n"),
            ("trailing blank lines", body + "\n\n\n"),
            ("CRLF throughout", body.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"),
            ("a second call in a comment", body + "\n# main \"$@\" used to live here\n"),
        ] {
            let library = try Self.libraryText(of: script)
            #expect(!library.split(separator: "\n").contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "main \"$@\""
            }, "\(shape): the library still calls main — sourcing it installs simmer")
            #expect(library.contains("fetch() {"), "\(shape): the library lost its functions")
        }
        // And the stop itself: a tail that is not the call must fail the
        // helper, not be dropped anyway. Named exactly, so the test states
        // WHICH refusal it expects rather than "something went wrong".
        #expect(throws: Self.UnsourceableScript.tailIsNotTheCall("build_and_install")) {
            _ = try Self.libraryText(of: body + "\nbuild_and_install\n")
        }
        #expect(throws: Self.UnsourceableScript.aSecondCallSurvives) {
            _ = try Self.libraryText(of: body + "\nmain \"$@\"\n")
        }
        #expect(throws: Self.UnsourceableScript.noCodeAtAll) {
            _ = try Self.libraryText(of: "# a comment and nothing else\n\n")
        }
    }

    struct Result { let out: String, code: Int32 }

    /// `fetch` alone, under the three environment variables it reads.
    static func fetch(ref: String, into dir: URL, from origin: URL, library: URL) -> Result {
        let result = Shell.run("/usr/bin/env", [
            "SIMMER_REPO=\(origin.path)", "SIMMER_REF=\(ref)", "SIMMER_DIR=\(dir.path)",
            // Hermetic: git must not need this machine's identity or config.
            "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
            "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
            "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
            "bash", "-c", ". '\(library.path)'; fetch",
        ])
        return Result(out: result.stdout + result.stderr, code: result.status)
    }

    @discardableResult
    static func git(_ args: [String]) -> String {
        let result = Shell.run("/usr/bin/env", [
            "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
            "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
            "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
            "/usr/bin/git",
        ] + args)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func fetchTellsATagFromABranchAndRefusesADivergedCheckout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-bootstrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("lib.sh")
        try Self.library(at: library)

        let origin = root.appendingPathComponent("origin")
        Self.git(["init", "--quiet", "--initial-branch=main", origin.path])
        try "one".write(to: origin.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        Self.git(["-C", origin.path, "add", "f"])
        Self.git(["-C", origin.path, "commit", "--quiet", "-m", "one"])
        Self.git(["-C", origin.path, "tag", "v9.9.9"])

        let checkout = root.appendingPathComponent("co")
        func clone(_ ref: String) {
            try? FileManager.default.removeItem(at: checkout)
            Self.git(["clone", "--quiet", "--branch", ref, origin.path, checkout.path])
        }

        // A TAG is already exactly what it says: nothing to fast-forward, and
        // the script must not claim it updated anything.
        clone("v9.9.9")
        let tag = Self.fetch(ref: "v9.9.9", into: checkout, from: origin, library: library)
        #expect(tag.code == 0, "\(tag.out)")
        #expect(tag.out.contains("at v9.9.9"), "\(tag.out)")
        #expect(!tag.out.contains("updated"), "claimed an update it did not perform: \(tag.out)")

        // A BRANCH behind its upstream fast-forwards, and "updated" is true.
        clone("main")
        try "two".write(to: origin.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        Self.git(["-C", origin.path, "commit", "--quiet", "-am", "two"])
        let behind = Self.fetch(ref: "main", into: checkout, from: origin, library: library)
        #expect(behind.code == 0, "\(behind.out)")
        #expect(behind.out.contains("updated the existing checkout"), "\(behind.out)")
        #expect(Self.git(["-C", checkout.path, "log", "-1", "--format=%s"]) == "two",
                "said it updated and did not")

        // A BRANCH that has DIVERGED is the whole reason this exists: it must
        // die, name the way out, and leave the tree alone — because the next
        // thing `main` does is `make -C "$DIR" install`.
        try "local".write(to: checkout.appendingPathComponent("g"),
                          atomically: true, encoding: .utf8)
        Self.git(["-C", checkout.path, "add", "g"])
        Self.git(["-C", checkout.path, "commit", "--quiet", "-m", "local work"])
        try "three".write(to: origin.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        Self.git(["-C", origin.path, "commit", "--quiet", "-am", "three"])
        let diverged = Self.fetch(ref: "main", into: checkout, from: origin, library: library)
        #expect(diverged.code != 0, "a diverged checkout passed: \(diverged.out)")
        #expect(!diverged.out.contains("updated the existing checkout"), "\(diverged.out)")
        // A refusal that names no fix is the one thing the surface forbids —
        // and a refusal that names TWO is the same failure from the other
        // side. Dropping `2>/dev/null` from the merge is what made this
        // divergence visible at all, and it also printed git's nine-line
        // "hint: Diverging branches can't be fast-forwarded, need to specify
        // how to reconcile them" above simmer's one line, telling the reader
        // to set `pull.rebase` when the fix is `git -C $DIR status`.
        #expect(diverged.out.contains("local commits"), "\(diverged.out)")
        #expect(diverged.out.contains("git -C \(checkout.path) status"), "\(diverged.out)")
        #expect(!diverged.out.contains("hint:"),
                "git's own hint block competes with simmer's refusal: \(diverged.out)")
        // One line, in simmer's voice: the refusal is what `die` printed and
        // nothing else. `step`'s own progress lines are the rest of it, so
        // only stderr-shaped git chatter is counted out.
        #expect(!diverged.out.contains("Diverging branches"), "\(diverged.out)")
        #expect(!diverged.out.lowercased().contains("pull.rebase"), "\(diverged.out)")
        #expect(Self.git(["-C", checkout.path, "log", "-1", "--format=%s"]) == "local work",
                "the checkout was moved under a refusal")

        // And a TAG while that same branch is still diverged: a tag checkout is
        // detached, so the branch is irrelevant and this must not refuse.
        Self.git(["-C", origin.path, "tag", "v9.9.10"])
        let tagOverDiverged = Self.fetch(ref: "v9.9.10", into: checkout,
                                         from: origin, library: library)
        #expect(tagOverDiverged.code == 0, "\(tagOverDiverged.out)")
        #expect(tagOverDiverged.out.contains("at v9.9.10"), "\(tagOverDiverged.out)")
    }
}


/// Every banner this tool constructs carries informative text.
///
/// macOS accepts a `UNMutableNotificationContent` with a title and no
/// informative text, reports no error, and never presents it — which is
/// indistinguishable from a banner that worked. That is the whole of the 0.3.1
/// "Install it now" silence, and the fix was applied by hand twice: to the
/// start banner of the click (T1) and then to the ending banner of the SAME
/// click (R2 finding 1). `git grep 'body: ""'` could not see the second one,
/// because there the empty string was a `var` assigned three lines later.
///
/// So the property is asserted over the source instead of the spelling being
/// searched for. The reader below is a pure function of source text, which is
/// what lets `theBannerTextReaderSeesTheShapesThatShipped` prove it red on the
/// shapes that actually shipped — the `var` included.
///
/// Its own suite, which is this file's convention rather than a departure from
/// it: `StructureTests` and `BootstrapFetchTests` are already two.
@Suite struct BannerTextTests {
    /// What source text can say about one field of a `NotificationRequest(…)`.
    ///
    /// Three answers, not two. `unknown` is a parameter, a pattern binding, a
    /// property or a call, and this reader may not pretend to know its value;
    /// folding unknown into either neighbour is how `// ""`, a missing-file
    /// check and `2>/dev/null || true` each handed a fallback the decision.
    enum BannerText: Equatable { case empty, text, unknown }

    /// One construction, and the two fields that decide whether macOS will
    /// present it. `title` is not one of them: a title-only banner is exactly
    /// the one that never appears.
    struct BannerSite: Equatable {
        var line: Int
        /// The enclosing `func`, so the list of undecidable sites below is
        /// pinned to something that does not move when a line does.
        var function: String
        var subtitle: BannerText
        var body: BannerText
        /// Red. The reader can see that both fields are empty or emptiable.
        var isSilent: Bool { subtitle == .empty && body == .empty }
        /// Green on the text itself, rather than on an absence of evidence.
        var isDecided: Bool { subtitle == .text || body == .text }
    }

    /// Comments blanked, string literals kept, offsets and newlines unchanged
    /// — so a line number still means a line, and a doc comment that shows the
    /// very syntax this reader looks for cannot be read as a construction
    /// (adversarial case 4: three gates in three weeks read a document's own
    /// examples as items).
    static func blankingComments(_ chars: [Character]) -> [Character] {
        var out = chars
        func at(_ i: Int) -> Character? { i >= 0 && i < chars.count ? chars[i] : nil }
        var i = 0, blockDepth = 0
        var inLiteral = false, inMultiline = false
        while i < chars.count {
            let c = chars[i]
            if blockDepth > 0 {
                if c == "/", at(i + 1) == "*" {
                    blockDepth += 1; out[i] = " "; out[i + 1] = " "; i += 2; continue
                }
                if c == "*", at(i + 1) == "/" {
                    blockDepth -= 1; out[i] = " "; out[i + 1] = " "; i += 2; continue
                }
                if !c.isNewline { out[i] = " " }
                i += 1
                continue
            }
            if inMultiline {
                if c == "\"", at(i + 1) == "\"", at(i + 2) == "\"" { inMultiline = false; i += 3 }
                else { i += 1 }
                continue
            }
            if inLiteral {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inLiteral = false }
                i += 1
                continue
            }
            if c == "\"", at(i + 1) == "\"", at(i + 2) == "\"" { inMultiline = true; i += 3; continue }
            if c == "\"" { inLiteral = true; i += 1; continue }
            if c == "/", at(i + 1) == "/" {
                // `isNewline`, never `== "\n"`: Swift grapheme-clusters CRLF
                // into ONE Character, so the literal comparison never matches
                // in a CRLF file and this would blank the rest of it
                // (adversarial case 2).
                while i < chars.count, !chars[i].isNewline { out[i] = " "; i += 1 }
                continue
            }
            if c == "/", at(i + 1) == "*" {
                blockDepth = 1; out[i] = " "; out[i + 1] = " "; i += 2; continue
            }
            i += 1
        }
        return out
    }

    /// The balanced argument list of the call whose `(` sits at `open`, one
    /// string per argument — so a construction wrapped across five lines is
    /// read whole (adversarial case 3: a renderer read the first line and
    /// dropped the rest in silence).
    static func argumentList(_ chars: [Character], open: Int) -> [String] {
        func at(_ j: Int) -> Character? { j < chars.count ? chars[j] : nil }
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var inLiteral = false, inMultiline = false
        var i = open
        while i < chars.count {
            let c = chars[i]
            if inMultiline {
                if c == "\"", at(i + 1) == "\"", at(i + 2) == "\"" {
                    inMultiline = false; current += "\"\"\""; i += 3
                } else { current.append(c); i += 1 }
                continue
            }
            if inLiteral {
                if c == "\\" {
                    current.append(c)
                    if let next = at(i + 1) { current.append(next) }
                    i += 2
                    continue
                }
                if c == "\"" { inLiteral = false }
                current.append(c)
                i += 1
                continue
            }
            if c == "\"", at(i + 1) == "\"", at(i + 2) == "\"" {
                inMultiline = true; current += "\"\"\""; i += 3; continue
            }
            if c == "\"" { inLiteral = true; current.append(c); i += 1; continue }
            if c == "(" || c == "[" || c == "{" {
                depth += 1
                if depth > 1 { current.append(c) }
                i += 1
                continue
            }
            if c == ")" || c == "]" || c == "}" {
                depth -= 1
                if depth == 0 { pieces.append(current); return pieces }
                current.append(c)
                i += 1
                continue
            }
            if c == ",", depth == 1 { pieces.append(current); current = ""; i += 1; continue }
            current.append(c)
            i += 1
        }
        return pieces
    }

    /// The text of the argument labelled `label`, or nil when it is absent —
    /// which is not the same thing at the call site, but is the same banner:
    /// the initialiser defaults both fields to "".
    static func argument(_ pieces: [String], label: String) -> String? {
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(label + ":") else { continue }
            return String(trimmed.dropFirst(label.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The content of `expr` when it is exactly one string literal.
    static func wholeStringLiteral(_ expr: String) -> String? {
        let chars = Array(expr)
        guard chars.count >= 2, chars.first == "\"", chars.last == "\"" else { return nil }
        var i = 1
        while i < chars.count - 1 {
            if chars[i] == "\\" { i += 2; continue }
            // A second literal: a concatenation, or a multi-line literal.
            // Both are answered further down.
            if chars[i] == "\"" { return nil }
            i += 1
        }
        return String(chars[1..<(chars.count - 1)])
    }

    /// The two branches of a top-level `a ? b : c`, if that is what this is.
    static func ternaryBranches(_ expr: String) -> (String, String)? {
        let chars = Array(expr)
        var depth = 0, question = -1, colon = -1
        var inLiteral = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inLiteral {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inLiteral = false }
                i += 1
                continue
            }
            if c == "\"" { inLiteral = true; i += 1; continue }
            if c == "(" || c == "[" || c == "{" { depth += 1; i += 1; continue }
            if c == ")" || c == "]" || c == "}" { depth -= 1; i += 1; continue }
            if depth == 0, c == "?" {
                // Neither `??` nor `foo?.bar` nor `as?` opens a ternary.
                if i + 1 < chars.count, chars[i + 1] == "?" || chars[i + 1] == "." {
                    i += 2
                    continue
                }
                if question < 0 { question = i }
                i += 1
                continue
            }
            if depth == 0, c == ":", question >= 0, colon < 0 { colon = i }
            i += 1
        }
        guard question >= 0, colon > question else { return nil }
        return (String(chars[(question + 1)..<colon]), String(chars[(colon + 1)...]))
    }

    static func isIdentifier(_ expr: String) -> Bool {
        guard let first = expr.first, first.isLetter || first == "_" else { return false }
        return expr.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The initialiser of the last `var`/`let <name> = …` in `scope`, which the
    /// caller bounds to the enclosing `func` — so a same-named variable in a
    /// neighbouring function cannot answer for this one, in either direction.
    static func declaration(of name: String, in scope: String) -> String? {
        var found: String?
        for keyword in ["var ", "let "] {
            var from = scope.startIndex
            while let range = scope.range(of: keyword + name, range: from..<scope.endIndex) {
                from = range.upperBound
                let rest = scope[range.upperBound...]
                guard let equals = rest.firstIndex(of: "=") else { continue }
                // `var bodyText = …` must not answer for `body`, and a type
                // annotation is not an initialiser.
                guard rest[rest.startIndex..<equals].allSatisfy({ $0 == " " }) else { continue }
                let after = rest[rest.index(after: equals)...]
                guard after.first != "=" else { continue }
                found = String(after.prefix { !$0.isNewline })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return found
    }

    /// Whether a literal's content is blank once the escapes that MEAN
    /// whitespace are read as whitespace: `body: "\t"` passes every `isEmpty`
    /// check and is presented as nothing (adversarial case 10).
    static func isBlankLiteral(_ content: String) -> Bool {
        var text = content
        for escape in ["\\t", "\\n", "\\r", "\\0"] {
            text = text.replacingOccurrences(of: escape, with: " ")
        }
        // Anything still escaped is a real character (`\\`, `\"`).
        return !text.contains("\\")
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether any string literal in VALUE position in `expr` has a character
    /// in it — the answer for a concatenation.
    ///
    /// Literals nested inside `(` or `[` do not count, and that is the whole
    /// point: `object["subtitle"] as? String ?? ""` carries a non-empty
    /// literal, and it is a dictionary KEY. Counting it read the spool
    /// deserialiser — the one construction whose text comes out of a file — as
    /// proof of text.
    static func containsNonEmptyLiteral(_ expr: String) -> Bool {
        let chars = Array(expr)
        var i = 0, depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == "[" { depth += 1; i += 1; continue }
            if c == ")" || c == "]" { depth -= 1; i += 1; continue }
            guard c == "\"" else { i += 1; continue }
            var content = ""
            i += 1
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\" {
                    content.append(chars[i])
                    if i + 1 < chars.count { content.append(chars[i + 1]) }
                    i += 2
                    continue
                }
                content.append(chars[i])
                i += 1
            }
            i += 1
            if depth == 0, !isBlankLiteral(content) { return true }
        }
        return false
    }

    /// `expr` as this reader sees it. A bare identifier is resolved against the
    /// enclosing function's own declarations, which is the whole reason the
    /// reader exists rather than a grep: the blocker was `var body = ""`
    /// assigned three lines later, and the grep came back clean.
    static func classify(_ expr: String?, scope: String, depth: Int = 0) -> BannerText {
        // Absent. The initialiser defaults both fields to "", so an argument
        // nobody passed is an empty one — the same banner, not a third case.
        guard let raw = expr?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return .empty }
        guard depth < 4 else { return .unknown }

        if let content = wholeStringLiteral(raw) {
            if content.contains("\\(") { return .text }
            return isBlankLiteral(content) ? .empty : .text
        }
        // Either branch empty makes the banner emptiable, which is the same
        // risk as an empty literal: `applied()`'s subtitle is
        // `reopened ? "…" : ""` and goes out blank whenever there was no app
        // running to relaunch — which is how the ending banner managed to be
        // title-only rather than merely body-less.
        if let (left, right) = ternaryBranches(raw) {
            let a = classify(left, scope: scope, depth: depth + 1)
            let b = classify(right, scope: scope, depth: depth + 1)
            if a == .empty || b == .empty { return .empty }
            return a == .text && b == .text ? .text : .unknown
        }
        if isIdentifier(raw) {
            guard let initialiser = declaration(of: raw, in: scope) else { return .unknown }
            return classify(initialiser, scope: scope, depth: depth + 1)
        }
        return containsNonEmptyLiteral(raw) ? .text : .unknown
    }

    /// Every `NotificationRequest(…)` construction in one file, as source text
    /// can see it.
    static func bannerSites(in source: String) -> [BannerSite] {
        let code = blankingComments(Array(source))
        let needle = Array("NotificationRequest(")
        var sites: [BannerSite] = []
        var line = 1
        var i = 0
        while i < code.count {
            if code[i].isNewline { line += 1; i += 1; continue }
            guard i + needle.count <= code.count,
                  Array(code[i..<(i + needle.count)]) == needle
            else { i += 1; continue }
            // `UNNotificationRequest(` is UserNotifications' own type: it takes
            // a `content`, not a body, and it is what ours is translated INTO.
            let previous = i > 0 ? code[i - 1] : " "
            guard !(previous.isLetter || previous.isNumber || previous == "_") else {
                i += needle.count
                continue
            }
            var scopeStart = 0
            var j = i - 5
            while j >= 0 {
                if code[j] == "f", code[j + 1] == "u", code[j + 2] == "n",
                   code[j + 3] == "c", code[j + 4] == " " {
                    scopeStart = j
                    break
                }
                j -= 1
            }
            let scope = String(code[scopeStart..<i])
            let name = String(scope.dropFirst("func ".count).prefix {
                $0.isLetter || $0.isNumber || $0 == "_"
            })
            let pieces = argumentList(code, open: i + needle.count - 1)
            sites.append(BannerSite(
                line: line,
                function: name.isEmpty ? "(top level)" : name,
                subtitle: classify(argument(pieces, label: "subtitle"), scope: scope),
                body: classify(argument(pieces, label: "body"), scope: scope)))
            i += needle.count
        }
        return sites
    }

    static func swiftFiles(under relativePath: String) -> [URL] {
        let root = StructureTests.repoRoot.appendingPathComponent(relativePath)
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        return all.sorted { $0.path < $1.path }
    }

    /// The reader itself, against the shapes that actually shipped. A gate is
    /// only worth its green if it can be shown red, and the two shapes that
    /// reached a release are both here.
    @Test func theBannerTextReaderSeesTheShapesThatShipped() {
        func silent(_ source: String) -> [Bool] { Self.bannerSites(in: source).map(\.isSilent) }

        // 0.3.1's banner, and R2 finding 2: both fields an empty literal.
        #expect(silent(#"let x = NotificationRequest(title: "t", subtitle: "", body: "")"#) == [true])
        // Absent is the same banner as empty — the initialiser defaults both.
        #expect(silent(#"let x = NotificationRequest(title: "t")"#) == [true])
        // Case 10: whitespace is not text, however it is spelled.
        #expect(silent(#"let x = NotificationRequest(title: "t", body: " ")"#) == [true])
        #expect(silent(#"let x = NotificationRequest(title: "t", body: "\t\n")"#) == [true])
        // One field is enough, in either slot.
        #expect(silent(#"let x = NotificationRequest(title: "t", body: "done")"#) == [false])
        #expect(silent(#"let x = NotificationRequest(title: "t", subtitle: "done")"#) == [false])

        // Case 9, the blocker: `var body = ""` assigned three lines later,
        // which is what `git grep 'body: ""'` came back clean on.
        let shipped = """
        func applied(_ plan: Plan) -> NotificationRequest {
            var subtitle = reopened ? "Simmer.app was relaunched" : ""
            var body = ""
            if let failure { body = failure }
            return NotificationRequest(title: "t", subtitle: subtitle, body: body)
        }
        """
        #expect(silent(shipped) == [true], "the reader must see the shape that shipped")
        // …and the fix, which is one line of it.
        #expect(silent(shipped.replacingOccurrences(
            of: #"var body = """#,
            with: #"var body = "You are on 0.3.3 now.""#)) == [false])
        // A `var` in a NEIGHBOURING function may not answer for this one.
        #expect(silent("""
        func other() { var body = "" }
        func mine() -> NotificationRequest {
            var body = "landed"
            return NotificationRequest(title: "t", body: body)
        }
        """) == [false])

        // Case 4: a doc comment holding the very syntax the reader looks for.
        #expect(silent("""
        /// Never write NotificationRequest(title: "t", subtitle: "", body: "").
        /* NotificationRequest(title: "t", body: "") is wrong too. */
        let x = NotificationRequest(title: "t", body: "real")
        """) == [false], "a comment is not a construction")
        // …and a `//` inside a string literal does not start a comment.
        #expect(silent(#"let x = NotificationRequest(title: "https://x", body: "")"#) == [true])

        // Case 3: one construction wrapped across lines, fields in an order
        // nobody planned for.
        #expect(silent("""
        let x = NotificationRequest(
            title: "t",
            sound: false,
            body: "the body",
            subtitle: "")
        """) == [false])

        // Case 2: CRLF reads the same as LF, and the line numbers agree.
        let lf = """
        func a() -> NotificationRequest {
            // a comment
            return NotificationRequest(title: "t", body: "")
        }
        """
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(Self.bannerSites(in: lf) == Self.bannerSites(in: crlf))
        #expect(Self.bannerSites(in: lf).map(\.line) == [3])
        #expect(Self.bannerSites(in: lf).map(\.function) == ["a"])

        // UN's own type is not ours.
        #expect(Self.bannerSites(in: """
        let x = UNNotificationRequest(identifier: "i", content: c, trigger: nil)
        """).isEmpty)

        // Case 5, and the reason `unknown` is its own answer: a body out of a
        // parameter is neither proof of text nor proof of silence, and the
        // gate says which of the two it has.
        let fromAway = Self.bannerSites(in: """
        func copied(_ command: String) -> NotificationRequest {
            NotificationRequest(title: "Copied to clipboard", subtitle: "", body: command)
        }
        """)
        #expect(fromAway.map(\.body) == [.unknown])
        #expect(fromAway.map(\.isSilent) == [false])
        #expect(fromAway.map(\.isDecided) == [false])
        // A concatenation and an interpolation are both text.
        #expect(Self.bannerSites(
            in: #"let x = NotificationRequest(title: "t", body: "a " + "b")"#)
            .map(\.body) == [.text])
        #expect(Self.bannerSites(
            in: #"let x = NotificationRequest(title: "t", body: "on \(target) now")"#)
            .map(\.body) == [.text])
    }

    /// The sites this reader cannot decide, named rather than waved through:
    /// an unknown folded into a pass is a gate that proves nothing.
    ///
    /// Each takes its text from a parameter, a pattern binding or the spool
    /// file, and each is caught at runtime instead —
    /// `NotificationRequest.hasInformativeText` is consulted by
    /// `Ledger.drainNotifications`, which drops such an entry and says so in
    /// the log, and by `BundleNotifier.post`, the app's own last gate.
    ///
    /// Keyed by function rather than by line, so an edit above one of them
    /// does not turn this into a list to re-number.
    static let bannersWhoseTextComesFromElsewhere = [
        // A failed spawn: `error.localizedDescription`.
        "AppState.swift:applyUpdate",
        // The spool deserialiser — three fields out of a file, the one
        // construction here whose text no source reader can decide.
        "Ledger.swift:drainNotifications",
        // `body: command`, the thing that was copied.
        "MenuModel.swift:copied",
        // `subtitle: why`, a required parameter. `grep -rn 'Engine.settle('
        // Sources/` finds SEVEN callers: six pass a non-empty literal (one of
        // them an interpolation with a non-empty prefix, `CapCommand.swift:152`)
        // and the seventh, `ReleaseCommand.swift:13`, passes a local `why`
        // whose three feeders are the literals "reverted by hand" and
        // "released by hand". So no caller can make it empty — but none of
        // that is visible at the construction, which is why it is listed here
        // rather than counted as text.
        "Settle.swift:settle",
        // `subtitle: step.described` and `body: sentence`, the latter out of
        // `failureSentence`, which has no arm that returns an empty string.
        "UpdateCommand.swift:applyFailed",
        // `body: sentence` and `body: why`, bound out of an `ApplyResult`.
        "UpdateCommand.swift:applyOutcome",
        // The `.unknown` arm's `body: report.error`, which `check` guarantees
        // is never empty ("no release information").
        "UpdateCommand.swift:notification",
    ]

    /// The gate. No `NotificationRequest` this tool constructs may reach
    /// `UNUserNotificationCenter` with neither subtitle nor body.
    @Test func everyBannerThisToolConstructsCarriesInformativeText() throws {
        var silent: [String] = []
        var undecided: Set<String> = []
        var total = 0
        let files = Self.swiftFiles(under: "Sources")
        #expect(files.count > 10, "found \(files.count) source files; the reader read nothing")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for site in Self.bannerSites(in: source) {
                total += 1
                if site.isSilent { silent.append("\(file.lastPathComponent):\(site.line)") }
                else if !site.isDecided {
                    undecided.insert("\(file.lastPathComponent):\(site.function)")
                }
            }
        }
        // A reader that suddenly finds nothing is the failure a gate cannot
        // notice by itself.
        #expect(total >= 25, "found only \(total) NotificationRequest constructions")
        #expect(silent.isEmpty, """
        a banner with neither subtitle nor body is one macOS accepts and never presents \
        (T1, R2 finding 1): \(silent.sorted())
        """)
        #expect(undecided.sorted() == Self.bannersWhoseTextComesFromElsewhere, """
        the sites whose text this reader cannot decide have changed. Give the new one a \
        literal subtitle or body, or add it to `bannersWhoseTextComesFromElsewhere` with \
        the reason its value cannot be empty: \(undecided.sorted())
        """)
    }

    /// The runtime half, at the type: both readers of the property must keep
    /// reading it, and **both must say so where the result is read**. A gate
    /// that refuses in silence is the defect it was built to catch wearing a
    /// different hat — nothing appears either way, and `add` would not have
    /// complained about the original.
    ///
    /// **What this asserts is the wiring, not the drop.** `Package.swift`
    /// gives `SimmerCoreTests` only `SimmerCore` and `SimmerAcceptanceTests`
    /// only the `simmer` executable — which by
    /// `theCLICannotReachTheNotificationCentre` may not link
    /// `SimmerNotifyKit` at all — so no test target in this package can call
    /// `BundleNotifier.post` or `Notifier.post`, with or without a seam on
    /// `available`.
    ///
    /// The DECISION is therefore kept one module lower, where it is driven on
    /// values: `NotificationRequest.hasInformativeText`
    /// (`whitespaceIsNotInformativeText`, `everyVerdictsBannerHasInformativeText`).
    /// These two belts only consult it, and consulting is what source text
    /// can honestly prove.
    @Test func theTwoLastGatesRefuseOutLoud() throws {
        let notifier = try StructureTests.read("Sources/SimmerNotifyKit/BundleNotifier.swift")
        let text = notifier.range(of: "guard request.hasInformativeText else { return .noInformativeText }")
        #expect(text != nil, "BundleNotifier.post is the last thing between a banner and UN")
        // And it comes FIRST, which is the load-bearing half. `available` is
        // `Bundle.main.bundleIdentifier != nil` — nil in a `swift test`
        // binary — so a text refusal ordered after it answers `.unbundled`
        // about a defect in the request and can never be driven, whatever
        // else changes about this package's test topology. Both spellings are
        // unique in the file: the other two `available` guards return `()`
        // and a `String`, not `.unbundled`.
        let bundled = notifier.range(of: "guard available else { return .unbundled }")
        #expect(bundled != nil)
        if let text, let bundled {
            #expect(text.lowerBound < bundled.lowerBound, """
            the text refusal must precede the `available` guard: after it, a request with \
            no informative text is answered `.unbundled`, which is a fact about the process \
            and not about the banner
            """)
        }
        // …and its caller turns that answer into a line. `PostResult` exists
        // so the refusal is distinguishable from being unbundled, which is a
        // steady state and not an event.
        let app = try StructureTests.read("Sources/SimmerApp/Notifier.swift")
        #expect(app.contains("== .noInformativeText"))
        #expect(app.contains("did not post a banner with no informative text"))

        let ledger = try StructureTests.read("Sources/SimmerCore/Model/Ledger.swift")
        #expect(ledger.contains("guard request.hasInformativeText else {"),
                "the spool is the channel every CLI banner arrives on")
        #expect(ledger.contains("dropped a banner with no informative text"))
    }
}
