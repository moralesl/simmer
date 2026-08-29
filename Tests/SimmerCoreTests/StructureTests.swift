import Foundation
import Testing
@testable import SimmerCore

/// Two structural decisions that nothing in the code can express, and that a
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
}
