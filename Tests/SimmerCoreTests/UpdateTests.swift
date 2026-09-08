import Foundation
import Testing

@testable import SimmerCore

/// The comparison, the provenance and the four verdicts — everything about
/// "is there a newer simmer" that does not need a process.
@Suite struct SemanticVersionTests {
    @Test(arguments: [
        ("0.2.0", "0.2.0"), ("v0.2.0", "0.2.0"), ("V1.0.0", "1.0.0"),
        ("1.2", "1.2.0"), ("3", "3.0.0"),
        ("0.3.0-dev", "0.3.0-dev"), ("v1.0.0-rc.2", "1.0.0-rc.2"),
        ("1.2.3+build7", "1.2.3"),
    ])
    func theSpellingsSimmerActuallyHolds(_ input: String, _ expected: String) {
        #expect(SemanticVersion(input).map(String.init(describing:)) == expected)
    }

    /// nil rather than a guess: a wrong parse here reports an update that does
    /// not exist, or hides one that does.
    @Test(arguments: ["", "v", "latest", "main", "0.2.x", "1.2.3.4", "-1.0.0", "0..1"])
    func anythingElseIsNoVersion(_ input: String) {
        #expect(SemanticVersion(input) == nil, "\(input) parsed")
    }

    @Test func orderIsNumericNotLexical() {
        #expect(SemanticVersion("0.9.0")! < SemanticVersion("0.10.0")!)
        #expect(SemanticVersion("v0.2.0")! < SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("0.2.0")! == SemanticVersion("v0.2.0")!)
    }

    /// The maintainer's daily case: a working tree bumped past the last tag
    /// must not be told to "update" to something older, and a prerelease of
    /// the version ranks below the release itself.
    @Test func aPrereleaseRanksBelowItsRelease() {
        #expect(SemanticVersion("0.3.0-dev")! < SemanticVersion("0.3.0")!)
        #expect(SemanticVersion("0.2.0")! < SemanticVersion("0.3.0-dev")!)
        #expect(SemanticVersion("1.0.0-rc.1")! < SemanticVersion("1.0.0-rc.2")!)
    }
}

@Suite struct InstallProvenanceTests {
    /// Everything exists, for the cases where the walk up the tree is not the
    /// thing under test.
    private let all: (String) -> Bool = { _ in true }
    private let nothing: (String) -> Bool = { _ in false }
    /// A home with nothing under it, so provenance is decided by the path
    /// alone in the cases that are about the path alone.
    private let home = "/Users/nobody"

    @Test func aFormulasCellarIsHomebrewEvenThoughItHoldsABundle() {
        let install = Install.detect(
            executablePath: "/opt/homebrew/Cellar/simmer/0.3.0/Simmer.app/Contents/MacOS/simmer",
            home: home, exists: all)
        // The order matters: the `.app` test would otherwise claim this and
        // print the one-paste installer to the one person whose package
        // manager already knows how to update them.
        #expect(install.kind == .homebrew)
        #expect(install.updateCommand == "brew upgrade simmer")
    }

    @Test func anInstalledBundleIsTheOnePasteInstaller() {
        let install = Install.detect(
            executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
            home: home, exists: nothing)
        #expect(install.kind == .bundle)
        #expect(install.bundle == "/Applications/Simmer.app")
        #expect(install.updateCommand.contains("bootstrap.sh"))
    }

    @Test func aCheckoutIsGitPullAndMakeInstall() {
        let root = "/Users/x/src/simmer"
        let install = Install.detect(executablePath: "\(root)/.build/debug/simmer", home: home) {
            $0 == "\(root)/Package.swift" || $0 == "\(root)/.git"
        }
        #expect(install.kind == .checkout)
        #expect(install.repoRoot == root)
        #expect(install.updateCommand == "cd \(root) && git pull && make install")
    }

    /// A `Package.swift` with no `.git` beside it is somebody else's vendored
    /// package, and `git pull` in it would be an instruction about the wrong
    /// repository.
    @Test func aPackageWithoutAGitDirectoryIsNotACheckout() {
        let install = Install.detect(executablePath: "/opt/vendored/.build/debug/simmer",
                                     home: home) {
            $0.hasSuffix("Package.swift")
        }
        #expect(install.kind == .unknown)
        #expect(install.updateCommand.contains("bootstrap.sh"))
    }

    /// A directory called `Foo.app` that is not a bundle must not be read as
    /// one — the reason the walk looks at path extensions rather than
    /// string-matching ".app".
    @Test func onlyARealBundlePathCounts() {
        #expect(Install.detect(executablePath: "/tmp/notanapp/simmer",
                               home: home, exists: nothing).kind == .unknown)
    }
}

/// Where a bundle says it came from, and what that changes.
///
/// `make install` stamps `$(CURDIR)` into the bundle's `Info.plist`. Before
/// it did, every bundle was assumed to have come from the installer's
/// checkout at `~/.local/share/simmer` — so a Mac installed from a
/// maintainer's own checkout was told to repair itself in a directory that is
/// not there, and `update --apply` refused for the same reason.
@Suite struct InstallSourceTests {
    private let app = "/Users/luis/Applications/Simmer.app/Contents/MacOS/simmer"
    private let home = "/Users/luis"
    private let mine = "/Users/luis/workspace/tools/simmer"

    private func detect(recorded: String?, present: [String]) -> Install {
        Install.detect(executablePath: app, home: home,
                       exists: { path in present.contains(where: { path.hasPrefix($0) }) },
                       plist: { _ in recorded.map { [Install.sourceKey: $0] } ?? [:] })
    }

    @Test func aBundleBuiltInSomebodysCheckoutIsUpdatedThroughThatCheckout() {
        let install = detect(recorded: mine, present: [mine])
        #expect(install.kind == .bundle, "provenance is still bundle — the stamp is a second axis")
        #expect(install.source == .checkout(mine))
        #expect(install.updateCommand == "cd \(mine) && git pull && make install")
        #expect(install.repairCommand == "make -C \(mine) install")
        #expect(install.describedSource.contains(mine))
    }

    /// `bootstrap.sh` runs `make -C ~/.local/share/simmer install`, so the
    /// installer stamps the same key with its own path — and that path is the
    /// one shape simmer may move onto a tag.
    @Test func theInstallersOwnCheckoutIsStillTheInstallers() {
        let installer = "\(home)/\(Install.installerCheckout)"
        let install = detect(recorded: installer, present: [installer])
        #expect(install.source == .installer(installer))
        #expect(install.updateCommand.contains("bootstrap.sh"))
    }

    /// A bundle installed by a simmer older than the stamp. The installer's
    /// checkout is where those came from if they came from anywhere, so the
    /// answer is exactly what it was before the stamp existed.
    @Test func aBundleWithNoStampFallsBackToTheInstallersCheckout() {
        let installer = "\(home)/\(Install.installerCheckout)"
        #expect(detect(recorded: nil, present: [installer]).source == .installer(installer))
        #expect(detect(recorded: nil, present: []).source == .none)
    }

    /// The directory that installed this copy has been moved or deleted.
    /// Named, because "there is no checkout" is true and useless.
    @Test func aSourceThatIsGoneIsNamedRatherThanForgotten() {
        let install = detect(recorded: mine, present: [])
        #expect(install.source == .gone(mine))
        #expect(install.repairCommand == nil)
        #expect(install.updateCommand.contains("bootstrap.sh"))
        #expect(install.describedSource.contains("no longer there"))
    }

    /// The machine surface gets two new fields rather than a fifth
    /// `provenance` value: every reader switches on that one exhaustively.
    @Test func provenanceKeepsItsFourValues() {
        for source in [detect(recorded: mine, present: [mine]),
                       detect(recorded: nil, present: []),
                       detect(recorded: mine, present: [])] {
            #expect(source.kind == .bundle)
        }
    }
}

/// The record knows which version wrote it.
///
/// Two minutes after 0.3.0 was installed, `doctor` said "simmer 0.3.0 is ahead
/// of the newest release (0.2.0)" and the menu footer said "newest" — both
/// computed from an answer 0.2.0 had cached before the 0.3.0 tag existed.
@Suite struct UpdateRecordIdentityTests {
    private func ledger() -> Ledger {
        Ledger(stateDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-record-\(UUID().uuidString)"))
    }

    private func install() -> Install {
        Install.detect(executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
                       home: "/Users/nobody", exists: { _ in false })
    }

    private func check(installed: String, ledger: Ledger, cached: Bool,
                       latest: String = "v0.2.0", now: Int = 1_800_000_000)
        -> UpdateCommand.Report {
        UpdateCommand.check(now: now, installed: installed, install: install(),
                            appVersion: nil, ledger: ledger,
                            source: FakeReleaseSource(value: latest), cached: cached)
    }

    @Test func aFreshCheckRecordsTheBinaryThatMadeIt() {
        let led = ledger()
        _ = check(installed: "0.2.0", ledger: led, cached: false)
        #expect(led.readUpdateRecord(writtenBy: "0.2.0")?.installed == "0.2.0")
        #expect(led.readUpdateRecord(writtenBy: "0.3.0") == nil)
    }

    /// The whole bug, in one case: 0.2.0 recorded "the newest release is
    /// v0.2.0", 0.3.0 was installed over it, and the cached read turned that
    /// into "you are ahead of the newest release".
    @Test func aRecordFromTheVersionYouReplacedIsNotAnAnswer() {
        let led = ledger()
        _ = check(installed: "0.2.0", ledger: led, cached: false, latest: "v0.2.0")

        let after = check(installed: "0.3.0", ledger: led, cached: true)
        #expect(after.verdict == .unknown, "0.2.0's answer was repeated as 0.3.0's")
        #expect(after.error.contains("not checked yet"))
        #expect(UpdateCommand.footerLine(after) == "simmer 0.3.0 · not checked yet")
    }

    @Test func theBinaryThatWroteItMayStillReadIt() {
        let led = ledger()
        _ = check(installed: "0.2.0", ledger: led, cached: false, latest: "v0.9.0")
        let again = check(installed: "0.2.0", ledger: led, cached: true)
        #expect(again.verdict == .available)
        #expect(again.fromCache)
    }

    /// A record older than the day the app refreshes on says so, and only
    /// then: a note on every line teaches the reader to ignore it.
    @Test func aCachedAnswerOlderThanADayCarriesItsAge() {
        let led = ledger()
        _ = check(installed: "0.2.0", ledger: led, cached: false, latest: "v0.2.0")

        let sameDay = check(installed: "0.2.0", ledger: led, cached: true,
                            now: 1_800_000_000 + 3 * 3600)
        #expect(UpdateCommand.cacheNote(sameDay) == "")
        #expect(UpdateCommand.footerLine(sameDay) == "simmer 0.2.0 · newest")

        let weekLater = check(installed: "0.2.0", ledger: led, cached: true,
                              now: 1_800_000_000 + 7 * 86_400)
        #expect(UpdateCommand.cacheNote(weekLater).contains("checked"))
        #expect(UpdateCommand.footerLine(weekLater).contains("(checked"))
    }
}

@Suite struct UpdateVerdictTests {
    private func ledger() -> Ledger {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-update-\(UUID().uuidString)")
        return Ledger(stateDir: dir)
    }

    private func check(installed: String, latest: String, cached: Bool = false,
                       ledger: Ledger? = nil, seamed: Bool = false,
                       appVersion: String? = nil) -> UpdateCommand.Report {
        UpdateCommand.check(
            now: 1_800_000_000, installed: installed,
            install: Install.detect(executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
                                    home: "/Users/nobody", exists: { _ in false }),
            appVersion: appVersion, ledger: ledger ?? self.ledger(),
            source: FakeReleaseSource(value: latest), cached: cached, seamed: seamed)
    }

    @Test func theFourVerdicts() {
        #expect(check(installed: "0.2.0", latest: "v0.3.0").verdict == .available)
        #expect(check(installed: "0.2.0", latest: "v0.2.0").verdict == .current)
        #expect(check(installed: "0.3.0", latest: "v0.2.0").verdict == .ahead)
        #expect(check(installed: "0.2.0", latest: "error").verdict == .unknown)
    }

    /// `update_available` is the field a caller switches on, so only one
    /// verdict may set it — "ahead" is not an update to install.
    @Test func onlyAvailableCountsAsAvailable() {
        #expect(check(installed: "0.2.0", latest: "v0.3.0").updateAvailable)
        #expect(!check(installed: "0.3.0", latest: "v0.2.0").updateAvailable)
        #expect(!check(installed: "0.2.0", latest: "v0.2.0").updateAvailable)
        #expect(!check(installed: "0.2.0", latest: "error").updateAvailable)
    }

    /// Every one of the answer row's titles puts a value from the report into
    /// its sentence, so a verdict that arrives with that value empty draws a
    /// degenerate one: `"Update available:  — you have 0.3.2"`,
    /// `"…is ahead of the newest release ()"`, `"Could not check for updates — "`.
    /// `MenuModel.answerGroup` (`MenuModel.swift:403`) says in prose that
    /// `check` never answers that way and draws the titles unguarded; this is
    /// the assertion that says it. R2 nit 6.
    ///
    /// The last row is the one that can actually happen. A record whose
    /// `latest` and `error` are both empty is a legal ledger state — a file
    /// written before the `error` field existed, or a truncated one — and the
    /// cache path reads it straight back into `report`. What stops the
    /// degenerate title there is one line, `UpdateCommand.swift:161`: delete
    /// `if report.error.isEmpty { report.error = "no release information" }`
    /// and this row goes red with an empty reason, which is the menu drawing
    /// "Could not check for updates — " and sending the reader to a terminal.
    ///
    /// The `Set` line is what keeps the loop from being vacuous: all four
    /// verdicts have to be in the sweep for the switch to have looked at them.
    @Test func noVerdictArrivesWithHalfOfItsSentenceEmpty() {
        let blank = ledger()
        blank.writeUpdateRecord(.init(checkedAt: 1_800_000_000, latest: "", error: "",
                                      installed: "0.2.0"))
        let reports = [
            check(installed: "0.2.0", latest: "v0.3.0"),                // available
            check(installed: "0.2.0", latest: "v0.2.0"),                // current
            check(installed: "0.3.0", latest: "v0.2.0"),                // ahead
            check(installed: "0.2.0", latest: "error"),                 // the source said why
            check(installed: "0.2.0", latest: ""),                      // nothing was asked
            check(installed: "0.2.0", latest: "nightly"),               // cannot compare
            check(installed: "0.2.0", latest: "v0.3.0", cached: true),  // never checked
            check(installed: "0.2.0", latest: "v0.3.0", cached: true, ledger: blank),
        ]
        #expect(Set(reports.map(\.verdict.rawValue))
            == ["available", "current", "ahead", "unknown"])
        for report in reports {
            switch report.verdict {
            case .available, .ahead:
                #expect(!report.latestDisplay.isEmpty,
                        "\(report.verdict.rawValue) with no release to name")
            case .unknown:
                #expect(!report.error.isEmpty, "unknown with no reason to give")
            case .current:
                // The only title that names neither: it is about the install.
                break
            }
        }
    }

    /// A tag that is not a version is a question this cannot answer, not a
    /// reason to claim currency.
    @Test func anUnparseableTagIsUnknownRatherThanCurrent() {
        let report = check(installed: "0.2.0", latest: "nightly")
        #expect(report.verdict == .unknown)
        #expect(report.error.contains("nightly"))
    }

    @Test func theAnswerIsCachedAndTheCacheIsRead() {
        let led = ledger()
        #expect(check(installed: "0.2.0", latest: "v0.3.0", ledger: led).fromCache == false)
        let cached = check(installed: "0.2.0", latest: "error", cached: true, ledger: led)
        // Read from the record, so the source's `error` never got a look in.
        #expect(cached.verdict == .available)
        #expect(cached.latest == "v0.3.0")
        #expect(cached.fromCache)
    }

    @Test func aCacheThatWasNeverWrittenSaysSoRatherThanClaimingCurrency() {
        let report = check(installed: "0.2.0", latest: "v0.3.0", cached: true)
        #expect(report.verdict == .unknown)
        #expect(report.error.contains("not checked yet"))
    }

    /// A `SIMMER_FAKE_LATEST` left exported in a shell rc would otherwise put
    /// "Update available: 9.9.9" in a person's menu bar until the next day.
    @Test func anUnseamedReaderDoesNotBelieveASeamedRecord() {
        let led = ledger()
        _ = check(installed: "0.2.0", latest: "v9.9.9", ledger: led, seamed: true)

        let unseamed = check(installed: "0.2.0", latest: "error", cached: true, ledger: led)
        #expect(unseamed.verdict == .unknown)
        #expect(unseamed.error.contains("seamed"))

        // Its own record is fine to read: the suite needs the cache path
        // reachable, and a seamed reader is already only being told about a seam.
        let seamed = check(installed: "0.2.0", latest: "error", cached: true,
                           ledger: led, seamed: true)
        #expect(seamed.verdict == .available)
    }

    /// The CLI is normally the binary inside the bundle — one file — so a
    /// disagreement means one of them was replaced and the other was not.
    @Test func theBundleAndTheCLIDisagreeing() {
        let drifted = check(installed: "0.2.0", latest: "v0.2.0", appVersion: "0.1.0")
        #expect(drifted.appDrift)
        // Drift outranks the release line: the newest release may already be
        // on the disk with only half of it in place.
        #expect(UpdateCommand.statusLine(drifted)?.contains("0.1.0") == true)

        #expect(!check(installed: "0.2.0", latest: "v0.2.0", appVersion: "0.2.0").appDrift)
        #expect(!check(installed: "0.2.0", latest: "v0.2.0", appVersion: nil).appDrift)
    }

    /// Nothing to say is said in one place, so every surface stays quiet
    /// together.
    @Test func theStatusLineIsNilWhenThereIsNothingToReport() {
        #expect(UpdateCommand.statusLine(check(installed: "0.2.0", latest: "v0.2.0")) == nil)
        #expect(UpdateCommand.statusLine(check(installed: "0.3.0", latest: "v0.2.0")) == nil)
        #expect(UpdateCommand.statusLine(check(installed: "0.2.0", latest: "error")) == nil)
        #expect(UpdateCommand.statusLine(check(installed: "0.2.0", latest: "v0.3.0"))
                == "Update available: 0.3.0")
    }

    /// The human SENTENCES drop the tag's `v` so a line does not put `v0.3.0`
    /// next to `0.2.0`; the machine field keeps it, and so does the release
    /// page's URL — a prettified tag there is a 404.
    @Test func theTagIsSpelledForItsAudience() {
        let report = check(installed: "0.2.0", latest: "v0.3.0")
        #expect(report.latest == "v0.3.0")
        #expect(report.latestDisplay == "0.3.0")
        let sentences = UpdateCommand.humanOutcome(report).stdout
            .filter { !$0.contains("://") }
            .joined(separator: "\n")
        #expect(sentences.contains("0.3.0"))
        #expect(!sentences.contains("v0.3.0"))
        #expect(report.releaseNotesURL?.hasSuffix("v0.3.0") == true,
                "the URL is the one place the tag stays verbatim")
    }

    /// Exit 0 whenever the check completed. A newer release is an answer.
    @Test func onlyAFailedCheckIsNonZero() {
        #expect(UpdateCommand.humanOutcome(check(installed: "0.2.0", latest: "v0.3.0")).exit == 0)
        #expect(UpdateCommand.humanOutcome(check(installed: "0.2.0", latest: "v0.2.0")).exit == 0)
        #expect(UpdateCommand.humanOutcome(check(installed: "0.3.0", latest: "v0.2.0")).exit == 0)
        #expect(UpdateCommand.humanOutcome(check(installed: "0.2.0", latest: "error")).exit == 1)
    }

    /// An available update prints the command; the others have nothing to
    /// print, and a "run this" line under "you are up to date" would be noise
    /// that teaches people to stop reading the block.
    @Test func onlyAnAvailableUpdatePrintsACommand() {
        let available = UpdateCommand.humanOutcome(check(installed: "0.2.0", latest: "v0.3.0"))
        #expect(available.stdout.contains { $0.contains("bootstrap.sh") })
        let current = UpdateCommand.humanOutcome(check(installed: "0.2.0", latest: "v0.2.0"))
        #expect(!current.stdout.contains { $0.contains("bootstrap.sh") })
    }
}

@Suite struct UpdateInTheMenuTests {
    private func menu(_ install: MenuInstall) -> [MenuItemModel] {
        MenuModel.build(aggregate: Aggregate.compute(claims: [], cap: nil, now: 1000,
                                                     sleepDisabled: false),
                        batteryLine: "battery 80%, on AC", install: install)
    }

    @Test func theRowIsThereOnlyWhenThereIsSomethingToSay() {
        let quiet = menu(MenuInstall(version: "0.2.0", canHandBackUnattended: true))
        #expect(!quiet.contains { $0.title.contains("Update available") })

        let loud = menu(MenuInstall(version: "0.2.0", canHandBackUnattended: true,
                                    updateLine: "Update available: 0.3.0",
                                    updateCommand: "brew upgrade simmer"))
        #expect(loud.first?.title == "Update available: 0.3.0")
        // It hands the command out rather than running it — the same shape
        // "Copy as CLI command" uses.
        #expect(loud.first?.children.first?.action == .copyCLI("brew upgrade simmer"))
    }

    /// An item that appears only when it has news is an item nobody can find
    /// when they want to ask.
    @Test func askingIsAlwaysPossible() {
        for install in [MenuInstall(version: "0.2.0", canHandBackUnattended: true),
                        MenuInstall(version: "0.2.0", canHandBackUnattended: false,
                                    updateLine: "Update available: 0.3.0",
                                    updateCommand: "brew upgrade simmer")] {
            #expect(menu(install).contains { $0.action == .checkForUpdates })
        }
    }

    /// The state header is what the menu is for, and it stays the one bold
    /// line even when an update row sits above it.
    @Test func theUpdateRowDoesNotCompeteWithTheStateHeader() {
        let items = menu(MenuInstall(version: "0.2.0", canHandBackUnattended: true,
                                     updateLine: "Update available: 0.3.0",
                                     updateCommand: "brew upgrade simmer"))
        #expect(items.first?.isProminent == false)
        #expect(items.filter(\.isProminent).count == 1)
    }
}

/// What `--apply` will and will not do. The decision is data, so all of it is
/// assertable without anything being built, downloaded or installed.
@Suite struct UpdateApplyTests {
    /// `installerCheckout` is whether `~/.local/share/simmer` is on this
    /// fixture's disk. It belongs here rather than in the `exists` a test
    /// hands to `applyPlan`, because the bundle's source is placed when the
    /// binary is placed — one decision, made once, exactly as it is on a Mac.
    private func report(installed: String, latest: String, kind: Install.Kind,
                        home: String = "/Users/x",
                        installerCheckout: Bool = true) -> UpdateCommand.Report {
        let path: String
        switch kind {
        case .homebrew: path = "/opt/homebrew/Cellar/simmer/9.9.9/Simmer.app/Contents/MacOS/simmer"
        case .bundle: path = "\(home)/Applications/Simmer.app/Contents/MacOS/simmer"
        case .checkout: path = "\(home)/src/simmer/.build/debug/simmer"
        case .unknown: path = "/tmp/simmer"
        }
        let installer = "\(home)/\(Install.installerCheckout)"
        let install = Install.detect(executablePath: path, home: home) {
            if kind == .checkout { return $0.hasSuffix("Package.swift") || $0.hasSuffix(".git") }
            return installerCheckout && $0.hasPrefix(installer)
        }
        #expect(install.kind == kind, "fixture placed as \(install.kind)")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-apply-\(UUID().uuidString)")
        return UpdateCommand.check(
            now: 1_800_000_000, installed: installed, install: install, appVersion: nil,
            ledger: Ledger(stateDir: dir), source: FakeReleaseSource(value: latest),
            cached: false, seamed: false)
    }

    /// Every path exists, which is the interesting case for the bundle plan.
    private let all: (String) -> Bool = { _ in true }
    private let nothing: (String) -> Bool = { _ in false }

    @Test func beingCurrentIsNothingToDoRatherThanARefusal() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.2.0", kind: .bundle),
            exists: all)
        guard case .nothingToDo(let sentence) = decision else {
            #expect(Bool(false), "\(decision)"); return
        }
        #expect(sentence.contains("already the newest"))
    }

    @Test func beingAheadIsAlsoNothingToDo() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.9.0", latest: "v0.2.0", kind: .bundle),
            exists: all)
        guard case .nothingToDo = decision else { #expect(Bool(false), "\(decision)"); return }
    }

    /// Not knowing whether there is an update is not a licence to install one.
    @Test func aFailedCheckRefusesRatherThanInstallingAnything() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "error", kind: .bundle),
            exists: all)
        guard case .refused = decision else { #expect(Bool(false), "\(decision)"); return }
    }

    /// The bundle install — the colleague case, and the only one where nobody
    /// has a terminal open.
    @Test func aBundleInstallUpdatesTheInstallersCheckout() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .bundle),
            exists: all)
        guard case .run(let plan) = decision else { #expect(Bool(false), "\(decision)"); return }

        #expect(plan.target == "0.3.0")
        #expect(plan.steps.count == 3)
        #expect(plan.steps[0].described.contains("fetch --tags"))
        // The TAG, not a branch: this checkout tracks releases.
        #expect(plan.steps[1].described.contains("checkout --quiet v0.3.0"))
        #expect(plan.steps[2].described.contains("install NOTES=0"))
        // Something has to bring the menu bar back — `make install` quits it.
        #expect(plan.reopenBundle == "/Users/x/Applications/Simmer.app")
    }

    /// The release's files come from the remote the release was read from, not
    /// from whatever cloned this checkout.
    ///
    /// The two were the same remote by coincidence, and on a maintainer's Mac
    /// they are not: `origin` there is a dev checkout whose `main` lags the
    /// release, so the fetch succeeded, the tag was not in it, and the switch
    /// failed with `pathspec 'v0.3.3' did not match any file(s) known to git`
    /// (8 Sep 2026, twice). The remote is asserted as an ARGUMENT of the
    /// fetch, because a fetch with no remote argument is the defect.
    @Test func theInstallerFetchNamesTheReleasesOwnRemote() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .bundle),
            exists: all)
        guard case .run(let plan) = decision else { #expect(Bool(false), "\(decision)"); return }

        let fetch = plan.steps[0]
        #expect(fetch.arguments.last == Install.repositoryURL, "\(fetch.arguments)")
        // `--force`, kept and pinned: a tag can legitimately have moved on the
        // remote, and a stale local one installs the wrong thing in silence.
        #expect(fetch.arguments.contains("--force"), "\(fetch.arguments)")

        // And the plan carries it as data, with the tag as published and the
        // checkout — the three things the failure sentence names, so that
        // nothing downstream re-derives them from an argument list.
        #expect(plan.releaseFetch == UpdateCommand.ReleaseFetch(
            tag: "v0.3.0", checkout: "/Users/x/.local/share/simmer",
            remote: Install.repositoryURL))
    }

    /// Somebody's own checkout keeps fetching its own `origin`, and carries no
    /// `releaseFetch`: what that plan installs is what its default branch
    /// holds, so its upstream is the only remote that answers the question.
    @Test func aCheckoutsOwnPlanStillFetchesItsOwnOrigin() {
        let decision = UpdateCommand.applyPlan(
            for: checkoutBundle(), exists: all,
            checkoutState: { _ in .init(branch: "main", defaultBranch: "main", clean: true) })
        guard case .run(let plan) = decision else { #expect(Bool(false), "\(decision)"); return }

        #expect(plan.releaseFetch == nil)
        #expect(plan.steps[0].described == "git -C \(mine) fetch --quiet")
        #expect(!plan.steps[0].described.contains(Install.repositoryURL))
    }

    /// The honesty property, asserted rather than promised: the printed command
    /// for a bundle install pipes a script from the internet into bash, and an
    /// app doing THAT on someone's behalf is a different kind of thing. The
    /// plan uses the checkout that install already has.
    @Test func noPlanEverPipesTheNetworkIntoAShell() {
        var plans = 0
        for kind in [Install.Kind.bundle, .homebrew, .checkout, .unknown] {
            let decision = UpdateCommand.applyPlan(
                for: report(installed: "0.2.0", latest: "v0.3.0", kind: kind),
                exists: all)
            guard case .run(let plan) = decision else { continue }
            plans += 1
            for step in plan.steps {
                #expect(!step.described.contains("curl"), "\(kind): \(step.described)")
                #expect(!step.described.contains("bash"), "\(kind): \(step.described)")
                #expect(!step.described.contains("|"), "\(kind): \(step.described)")
            }
        }
        // Counted, because `continue` past a refusal makes a green run and a
        // run that asserted NOTHING indistinguishable: a regression turning
        // every provenance into a refusal would have passed this silently.
        #expect(plans > 0, "no provenance produced a plan, so nothing above was checked")
    }

    /// No checkout to build from, so there is nothing to run — and the refusal
    /// carries the command that does work.
    @Test func aBundleWithNoInstallerCheckoutRefusesWithTheCommand() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .bundle,
                        installerCheckout: false),
            exists: nothing)
        guard case .refused(let why) = decision else { #expect(Bool(false), "\(decision)"); return }
        #expect(why.contains("bootstrap.sh"))
    }

    /// Somebody's working repository, which may hold local commits, an
    /// unfinished branch or a stash. `git checkout v0.3.0` in it would be
    /// simmer rearranging someone's desk — and a person running from a checkout
    /// has a terminal by definition.
    @Test func aDevelopersOwnCheckoutIsNeverTouched() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .checkout),
            exists: all)
        guard case .refused(let why) = decision else { #expect(Bool(false), "\(decision)"); return }
        #expect(why.contains("your own checkout"))
        #expect(why.contains("make install"))
    }

    /// A bundle assembled in somebody's own checkout, on a clean tree, on the
    /// branch the remote calls default: `git pull && make install`, which is
    /// the command that copy already prints. "A developer's own checkout is
    /// never moved onto a tag" was about local commits and unfinished
    /// branches, not about every checkout — and while it covered this shape
    /// too, a Mac installed from a checkout had a menu item that could only
    /// ever report a refusal.
    @Test func aCleanCheckoutBundleIsPulledAndRebuilt() {
        let decision = UpdateCommand.applyPlan(
            for: checkoutBundle(), exists: all,
            checkoutState: { _ in .init(branch: "main", defaultBranch: "main", clean: true) })
        guard case .run(let plan) = decision else { #expect(Bool(false), "\(decision)"); return }

        #expect(plan.steps.count == 3)
        #expect(plan.steps[0].described == "git -C \(mine) fetch --quiet")
        #expect(plan.steps[1].described == "git -C \(mine) merge --ff-only --quiet @{u}")
        #expect(plan.steps[2].described == "make -C \(mine) install NOTES=0")
        // No tag is checked out, so the version this lands is whatever the
        // branch holds. Claiming the exact one would be a claim nobody made.
        #expect(plan.target == "0.3.0 or newer")
        #expect(plan.reopenBundle == "/Users/luis/Applications/Simmer.app")
    }

    /// The conditions, each refused by name. Uncommitted work and an
    /// unfinished branch are exactly what "simmer does not rearrange somebody's
    /// desk" was about, and every refusal carries the command that works.
    @Test func aCheckoutThatIsNotReadyIsRefusedWithTheReason() {
        let cases: [(UpdateCommand.CheckoutState?, String)] = [
            (.init(branch: "main", defaultBranch: "main", clean: false), "uncommitted changes"),
            (.init(branch: "feat/x", defaultBranch: "main", clean: true), "is on feat/x, not main"),
            (.init(branch: "", defaultBranch: "main", clean: true), "is not on a branch"),
            (.init(branch: "main", defaultBranch: "", clean: true), "which branch is default"),
            (.init(branch: "main", defaultBranch: "main", clean: true, aheadOfUpstream: 2),
             "has 2 commits that main has not pushed"),
            (.init(branch: "main", defaultBranch: "main", clean: true, aheadOfUpstream: nil),
             "tracks nothing"),
            (nil, "cannot read the checkout"),
        ]
        for (state, expected) in cases {
            let decision = UpdateCommand.applyPlan(for: checkoutBundle(), exists: all,
                                                   checkoutState: { _ in state })
            guard case .refused(let why) = decision else {
                #expect(Bool(false), "\(String(describing: state)): \(decision)")
                continue
            }
            #expect(why.contains(expected), "\(why)")
            #expect(why.contains("cd \(mine) && git pull && make install"), "\(why)")
        }
    }

    /// The condition that clean-and-on-default does not cover, and the one
    /// this refusal exists for in the first place.
    ///
    /// A developer's checkout with local commits is clean and on `main`, so
    /// the first two conditions pass it — and the plan's own steps do not
    /// catch it either: `git merge --ff-only @{u}` SUCCEEDS against an
    /// upstream that is already an ancestor, because that is a no-op. So the
    /// plan ran to the end, `make install` shipped the unreleased tree, and
    /// `--apply` reported success naming a release the installed binary does
    /// not report. Verified against real `git`, not assumed.
    @Test func aCheckoutWithUnpushedCommitsIsRefusedAndTheCountIsNamed() {
        let decision = UpdateCommand.applyPlan(
            for: checkoutBundle(), exists: all,
            checkoutState: { _ in
                .init(branch: "main", defaultBranch: "main", clean: true, aheadOfUpstream: 1)
            })
        guard case .refused(let why) = decision else { #expect(Bool(false), "\(decision)"); return }
        #expect(why.contains("has 1 commit that main has not pushed"),
                "one commit is singular, and the count is what tells somebody which state they are in: \(why)")
        #expect(why.contains("would install those rather than the release"), "\(why)")
        #expect(why.contains("git -C \(mine) push"), "the refusal names the command that clears it: \(why)")
    }

    /// In step with the upstream is the shape the plan is for, and it still
    /// runs — the new condition must not refuse the case it was built around.
    @Test func aCheckoutInStepWithItsUpstreamStillRuns() {
        let decision = UpdateCommand.applyPlan(
            for: checkoutBundle(), exists: all,
            checkoutState: { _ in
                .init(branch: "main", defaultBranch: "main", clean: true, aheadOfUpstream: 0)
            })
        guard case .run(let plan) = decision else { #expect(Bool(false), "\(decision)"); return }
        #expect(plan.steps.count == 3)
    }

    /// The seam's fourth field, including what a typo in it must do.
    ///
    /// A malformed count answering "in step" would be the one wrong answer
    /// that lets the plan run — so it answers "cannot read this checkout",
    /// which refuses. Same reason `SIMMER_FAKE_APPLY_FAIL` fails nothing on a
    /// typo rather than failing something.
    @Test(arguments: [
        // (the seam value, the branch it names, how far ahead, readable at all)
        ("main:main:clean", "main", 0, true),
        ("main:main:clean:0", "main", 0, true),
        ("main:main:clean:3", "main", 3, true),
        ("main:main:clean:none", "main", nil, true),
        ("main:main:clean:soon", "", nil, false),
        ("main:main:clean:-1", "", nil, false),
        ("main:main", "", nil, false),
    ])
    func theCheckoutSeamReadsAnOptionalAheadCount(
        value: String, branch: String, ahead: Int?, readable: Bool
    ) {
        let state = FakeCheckoutProbe(value: value).state(of: "/anywhere")
        guard readable else {
            #expect(state == nil, "\(value) should not have been readable: \(String(describing: state))")
            return
        }
        #expect(state?.branch == branch)
        #expect(state?.aheadOfUpstream == ahead)
    }

    /// Three fields still mean exactly what they meant. The seam is a
    /// contracted surface (CONTRACTS.md § The test seam), so the fourth field
    /// is added, never required.
    @Test func theOldThreeFieldSeamValueIsUnchanged() {
        let state = FakeCheckoutProbe(value: "main:main:clean").state(of: "/anywhere")
        #expect(state == UpdateCommand.CheckoutState(branch: "main", defaultBranch: "main",
                                                     clean: true, aheadOfUpstream: 0))
    }

    /// The directory that installed this copy is gone. Refused, and the
    /// refusal names which directory rather than saying there never was one.
    @Test func aBundleWhoseSourceVanishedIsRefusedByName() {
        let install = Install.detect(
            executablePath: "/Users/luis/Applications/Simmer.app/Contents/MacOS/simmer",
            home: "/Users/luis", exists: { _ in false },
            plist: { _ in [Install.sourceKey: mine] })
        let decision = UpdateCommand.applyPlan(for: report(install: install), exists: nothing)
        guard case .refused(let why) = decision else { #expect(Bool(false), "\(decision)"); return }
        #expect(why.contains(mine))
        #expect(why.contains("bootstrap.sh"))
    }

    private var mine: String { "/Users/luis/workspace/tools/simmer" }

    private func checkoutBundle() -> UpdateCommand.Report {
        let install = Install.detect(
            executablePath: "/Users/luis/Applications/Simmer.app/Contents/MacOS/simmer",
            home: "/Users/luis", exists: { $0.hasPrefix(mine) },
            plist: { _ in [Install.sourceKey: mine] })
        #expect(install.source == .checkout(mine))
        return report(install: install)
    }

    private func report(install: Install) -> UpdateCommand.Report {
        UpdateCommand.check(
            now: 1_800_000_000, installed: "0.2.0", install: install, appVersion: nil,
            ledger: Ledger(stateDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("simmer-apply-\(UUID().uuidString)")),
            source: FakeReleaseSource(value: "v0.3.0"), cached: false, seamed: false)
    }

    @Test func homebrewUpgradesThroughBrew() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .homebrew),
            exists: { $0 == "/opt/homebrew/bin/brew" })
        guard case .run(let plan) = decision else { #expect(Bool(false), "\(decision)"); return }
        #expect(plan.steps.map(\.described) == ["brew upgrade simmer"])
    }

    @Test func homebrewWithoutBrewRefusesRatherThanGuessingAPath() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .homebrew),
            exists: nothing)
        guard case .refused = decision else { #expect(Bool(false), "\(decision)"); return }
    }

    /// The footer answers both halves of "am I current", in every state, so a
    /// menu-only reader never has to open a terminal to find out.
    @Test func theFooterNamesBothVersions() {
        #expect(UpdateCommand.footerLine(report(installed: "0.2.0", latest: "v0.3.0", kind: .bundle))
                == "simmer 0.2.0 · newest is 0.3.0")
        #expect(UpdateCommand.footerLine(report(installed: "0.3.0", latest: "v0.3.0", kind: .bundle))
                == "simmer 0.3.0 · newest")
        #expect(UpdateCommand.footerLine(report(installed: "0.9.0", latest: "v0.3.0", kind: .bundle))
                == "simmer 0.9.0 · ahead of 0.3.0")
        #expect(UpdateCommand.footerLine(report(installed: "0.2.0", latest: "error", kind: .bundle))
                .hasSuffix("last check failed"))
    }

    /// The menu offers to install only where there is a plan. Offering it where
    /// `applyPlan` refuses would be a button that reports a refusal — which is
    /// worse than no button, because the person clicked it expecting an install.
    @Test func theMenuOffersInstallOnlyWhereThereIsAPlan() {
        func menu(_ canApply: Bool) -> [MenuItemModel] {
            MenuModel.build(
                aggregate: Aggregate.compute(claims: [], cap: nil, now: 1000, sleepDisabled: false),
                batteryLine: "battery 80%, on AC",
                install: MenuInstall(version: "0.2.0", canHandBackUnattended: true,
                                     updateLine: "Update available: 0.3.0",
                                     updateCommand: "brew upgrade simmer",
                                     versionLine: "simmer 0.2.0 · newest is 0.3.0",
                                     canApplyUpdate: canApply))
        }
        let offered = menu(true).first?.children.map(\.action) ?? []
        #expect(offered.contains(.applyUpdate))
        #expect(offered.contains(.copyCLI("brew upgrade simmer")))

        let copyOnly = menu(false).first?.children.map(\.action) ?? []
        #expect(!copyOnly.contains(.applyUpdate))
        #expect(copyOnly.contains(.copyCLI("brew upgrade simmer")))
    }

    /// The footer is the last row and it is never empty — a menu that has not
    /// checked anything still says which version it is.
    @Test func theFooterIsAlwaysTheLastRow() {
        let items = MenuModel.build(
            aggregate: Aggregate.compute(claims: [], cap: nil, now: 1000, sleepDisabled: false),
            batteryLine: "battery 80%, on AC",
            install: MenuInstall(version: "0.2.0", canHandBackUnattended: true))
        #expect(items.last?.title == "simmer 0.2.0")
    }
}

/// One banner per new version, and never the same one twice.
///
/// The once-a-day check used to update the menu and say nothing, so a
/// colleague who never opens the menu bar could be months behind silently.
/// What stops "news" from becoming "nagging" is entirely in this decision, so
/// every way it could announce twice has a test.
@Suite struct UpdateAnnouncementTests {
    private func report(installed: String, latest: String,
                        seamed: Bool = false) -> UpdateCommand.Report {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-announce-\(UUID().uuidString)")
        return UpdateCommand.check(
            now: 1_800_000_000, installed: installed,
            install: Install.detect(executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
                                    home: "/Users/nobody", exists: { _ in false }),
            appVersion: nil, ledger: Ledger(stateDir: dir),
            source: FakeReleaseSource(value: latest), cached: false, seamed: seamed)
    }

    @Test func aNewerReleaseNobodyHasBeenToldAboutIsNews() throws {
        let announcement = try #require(UpdateCommand.announcement(
            report(installed: "0.2.0", latest: "v0.3.0"), lastAnnounced: "", seamed: false))

        #expect(announcement.announced == "v0.3.0", "the tag as published, `v` and all")
        // The title names the version and the body names how to get it — the
        // manual check's banner, because two wordings for one fact is what
        // rendering every surface from here exists to prevent.
        #expect(announcement.notification.title.contains("0.3.0"))
        #expect(announcement.notification.body.contains("bootstrap.sh"))
        #expect(announcement.notification.sound == false, "news is not an alarm")
    }

    /// The whole point: the cost of this feature is one banner per release,
    /// ever, and that is what makes it something the app may do unasked.
    @Test func theSameVersionIsNeverAnnouncedTwice() {
        #expect(UpdateCommand.announcement(
            report(installed: "0.2.0", latest: "v0.3.0"),
            lastAnnounced: "v0.3.0", seamed: false) == nil)
    }

    /// …and the one after it still is. A record that suppressed everything
    /// once it existed would be indistinguishable from the old silence.
    @Test func theNextVersionAfterAnAnnouncedOneIsNewsAgain() throws {
        let announcement = try #require(UpdateCommand.announcement(
            report(installed: "0.2.0", latest: "v0.4.0"),
            lastAnnounced: "v0.3.0", seamed: false))
        #expect(announcement.announced == "v0.4.0")
    }

    /// Nothing to say: being current, being ahead of the newest release, and a
    /// check that could not answer. A downgrade in particular is not news —
    /// the maintainer's own working tree is ahead of the last tag every day.
    @Test func onlyANewerReleaseAnnouncesAtAll() {
        #expect(UpdateCommand.announcement(
            report(installed: "0.2.0", latest: "v0.2.0"),
            lastAnnounced: "", seamed: false) == nil)
        #expect(UpdateCommand.announcement(
            report(installed: "0.3.0", latest: "v0.2.0"),
            lastAnnounced: "", seamed: false) == nil)
        #expect(UpdateCommand.announcement(
            report(installed: "0.2.0", latest: "error"),
            lastAnnounced: "", seamed: false) == nil)
    }

    /// A `SIMMER_FAKE_LATEST` left exported in a shell rc must not put
    /// "simmer 9.9.9 is available" in a person's notification centre. `check`
    /// already discards a seamed record on the cached path; this is the same
    /// door on the fresh one.
    @Test func aSeamedCheckAnnouncesNothing() {
        #expect(UpdateCommand.announcement(
            report(installed: "0.2.0", latest: "v9.9.9", seamed: true),
            lastAnnounced: "", seamed: true) == nil)
    }
}

/// The announced version is its own fact on disk, because `update-check` is
/// overwritten by every check — including the ones nobody sees.
@Suite struct AnnouncedUpdateRecordTests {
    private func ledger() -> Ledger {
        Ledger(stateDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-announced-\(UUID().uuidString)"))
    }

    @Test func nothingAnnouncedReadsAsEmptyRatherThanFailing() {
        #expect(ledger().readAnnouncedUpdate() == "")
    }

    @Test func whatWasAnnouncedSurvivesTheNextCheck() {
        let ledger = self.ledger()
        ledger.writeAnnouncedUpdate("v0.3.0", now: 1_800_000_000)
        // A later check finds the same release again and rewrites its own
        // record; the announcement is a different file and is untouched.
        ledger.writeUpdateRecord(.init(checkedAt: 1_800_003_600,
                                       latest: "v0.3.0", error: ""))
        #expect(ledger.readAnnouncedUpdate() == "v0.3.0")
    }

    /// A tag is free-ish text arriving from a redirect, and this record is a
    /// newline-delimited key=value file — the shape a `--owner` newline once
    /// walked straight through.
    @Test func aTagCannotForgeASecondLine() {
        let ledger = self.ledger()
        ledger.writeAnnouncedUpdate("v0.3.0\nannounced_at=0", now: 1_800_000_000)
        #expect(!ledger.readAnnouncedUpdate().contains("\n"))
    }
}

/// The release's own page, so a person can read what is in a version before
/// installing it. Composed from the tag; simmer fetches nothing for it.
@Suite struct ReleaseNotesURLTests {
    private func report(installed: String, latest: String) -> UpdateCommand.Report {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-notes-\(UUID().uuidString)")
        return UpdateCommand.check(
            now: 1_800_000_000, installed: installed,
            install: Install.detect(executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
                                    home: "/Users/nobody", exists: { _ in false }),
            appVersion: nil, ledger: Ledger(stateDir: dir),
            source: FakeReleaseSource(value: latest), cached: false, seamed: false)
    }

    @Test func itIsTheTagsOwnPage() {
        #expect(report(installed: "0.2.0", latest: "v0.3.0").releaseNotesURL
            == "\(Install.repositoryURL)/releases/tag/v0.3.0")
    }

    /// The tag as published, `v` and all — the human surfaces drop the prefix
    /// and this one must not, or the URL is a 404.
    @Test func theTagIsNotPrettifiedIntoAWrongURL() {
        let url = report(installed: "0.2.0", latest: "v0.3.0").releaseNotesURL ?? ""
        #expect(url.hasSuffix("/v0.3.0"), "\(url)")
    }

    /// It is there for every verdict that named a release, not only for an
    /// update: "what is in the version I am running" is the same question.
    @Test func beingCurrentStillHasAPageToPointAt() {
        #expect(report(installed: "0.3.0", latest: "v0.3.0").releaseNotesURL != nil)
        #expect(report(installed: "0.4.0", latest: "v0.3.0").releaseNotesURL != nil)
    }

    /// Nothing to point at, rather than a URL ending in nothing.
    @Test func aCheckThatNamedNoReleaseHasNoPage() {
        #expect(report(installed: "0.2.0", latest: "error").releaseNotesURL == nil)
    }

    /// `latest` is the last path component of a redirect, round-tripped
    /// through a `key=value` cache file, and this value is handed to something
    /// that opens it. So it is a version or it is nothing.
    @Test(arguments: ["main", "latest", "../../../etc", "v0.3.0 x", "0.2.x"])
    func aTagThatIsNotAVersionIsNotTurnedIntoAURL(_ tag: String) {
        let url = report(installed: "0.2.0", latest: tag).releaseNotesURL
        #expect(url == nil, "composed \(url ?? "nil") from \(tag)")
    }

    /// It goes under the install command: the command is what most people came
    /// for, the notes are what the careful ones want first.
    @Test func theHumanAnswerPrintsItBelowTheCommand() throws {
        let lines = UpdateCommand.humanOutcome(report(installed: "0.2.0", latest: "v0.3.0")).stdout
        let command = try #require(lines.firstIndex { $0.contains("update with:") })
        let notes = try #require(lines.firstIndex { $0.contains("release notes:") })
        #expect(command < notes)
        #expect(lines[notes].contains("/releases/tag/v0.3.0"))
    }

    /// And not at all when there is nothing to install — the line exists to be
    /// read before an install, and being current is most people most days.
    @Test func thereIsNoNotesLineWhenThereIsNothingToInstall() {
        let lines = UpdateCommand.humanOutcome(report(installed: "0.3.0", latest: "v0.3.0")).stdout
        #expect(!lines.contains { $0.contains("release notes:") })
    }
}

/// The menu's update group: the two things you do with a version you have not
/// got — read what is in it, or install it — and the command, still, for a
/// terminal.
@Suite struct ReleaseNotesInTheMenuTests {
    private func menu(_ install: MenuInstall) -> [MenuItemModel] {
        MenuModel.build(aggregate: Aggregate.compute(claims: [], cap: nil, now: 1000,
                                                     sleepDisabled: false),
                        batteryLine: "battery 80%, on AC", install: install)
    }

    private let notesURL = "https://github.com/moralesl/simmer/releases/tag/v0.3.0"

    private func updateGroup(canApply: Bool, notes: String?) -> MenuItemModel? {
        menu(MenuInstall(version: "0.2.0", canHandBackUnattended: true,
                         updateLine: "Update available: 0.3.0",
                         updateCommand: "brew upgrade simmer",
                         canApplyUpdate: canApply, releaseNotesURL: notes)).first
    }

    @Test func theRowOpensThePageTheReportNamed() throws {
        let children = try #require(updateGroup(canApply: true, notes: notesURL)?.children)
        let row = try #require(children.first { $0.title == "Release notes…" })
        #expect(row.action == .openReleaseNotes(notesURL))
    }

    /// A menu that only offers to install it asks for a decision it gives you
    /// nothing to make, so the notes come before the install.
    @Test func readingComesBeforeInstalling() throws {
        let children = try #require(updateGroup(canApply: true, notes: notesURL)?.children)
        let install = try #require(children.firstIndex { $0.action == .applyUpdate })
        let notes = try #require(children.firstIndex { $0.title == "Release notes…" })
        #expect(install < notes, "install first, then what is in it")
        // And the command to copy stays last, below the separator.
        #expect(children.last?.action == .copyCLI("brew upgrade simmer"))
    }

    /// Conditional on there being a page, like every other row in this group.
    @Test func noPageMeansNoRow() throws {
        let children = try #require(updateGroup(canApply: true, notes: nil)?.children)
        #expect(!children.contains { $0.title == "Release notes…" })
    }

    /// A checkout cannot be installed into, and the notes are still worth
    /// reading — so the group must not lose its separator when the only thing
    /// above it is the notes row.
    @Test func aCheckoutStillGetsTheNotesAndTheCommand() throws {
        let children = try #require(updateGroup(canApply: false, notes: notesURL)?.children)
        #expect(children.first?.title == "Release notes…")
        #expect(children.contains { $0.isSeparator })
        #expect(children.last?.action == .copyCLI("brew upgrade simmer"))
    }

    /// Nothing above it at all: no plan, no page. The group is then exactly
    /// what it was before this row existed — one command to copy.
    @Test func withNeitherThereIsNoStraySeparator() throws {
        let children = try #require(updateGroup(canApply: false, notes: nil)?.children)
        #expect(children.count == 1)
        #expect(children.first?.action == .copyCLI("brew upgrade simmer"))
    }
}

/// A person reading "git -C … checkout --quiet v0.9.0 failed — fatal:
/// reference is not a tree" learns a command they did not type, in a checkout
/// they may not know they have, and neither of the two things that matter: did
/// anything change, and what do I do now.
@Suite struct ApplyFailureSentenceTests {
    private func plan(kind: Install.Kind = .bundle) -> UpdateCommand.ApplyPlan {
        UpdateCommand.ApplyPlan(
            steps: [], target: "0.9.0",
            reopenBundle: kind == .checkout ? nil : "/Applications/Simmer.app")
    }

    private func sentence(_ phase: UpdateCommand.ApplyPhase,
                          updateCommand: String = "brew upgrade simmer") -> String {
        UpdateCommand.failureSentence(phase: phase, plan: plan(),
                                      updateCommand: updateCommand)
    }

    /// Every sentence names the version, says whether anything changed, and
    /// ends with something to do. Those three are the whole point of it.
    ///
    /// `plan()` carries no `releaseFetch`, and that is what these three rows
    /// are about: a plan that fetched no release from a remote it was told
    /// about. The **one exception** to the last expectation is the `switching`
    /// sentence of a plan that did — `theSwitchingSentenceDoesNotSendThemBackToTheRemoteThatFailed` —
    /// and the ban on `git ` below is about which command, not about git. What this row
    /// refuses is the failing command — the thing nobody typed, which belongs
    /// on the second line as evidence. What that sentence ends in is a **look**
    /// and not a fix: `git -C <checkout> status`, read-only, true whether the
    /// tag is absent or the tree is dirty, and named because the fix this
    /// phase would otherwise print fetches the remote that just failed.
    /// A command in the message earns its place by being the reader's next
    /// step; the pin and its exception say the same thing from two sides.
    @Test(arguments: [UpdateCommand.ApplyPhase.fetching, .switching, .installing])
    func eachInstallPhaseSaysWhatHappenedAndWhatToRun(_ phase: UpdateCommand.ApplyPhase) {
        let text = sentence(phase)
        #expect(text.contains("simmer 0.9.0"), "\(text)")
        #expect(text.contains("Run: brew upgrade simmer"), "\(text)")
        #expect(!text.contains("git "), "a command nobody typed is not the message")
    }

    /// The three are distinguishable, which is the reason the phase is a field
    /// at all — one sentence for three failures would name none of them.
    @Test func theThreeInstallPhasesReadDifferently() {
        let all = [sentence(.fetching), sentence(.switching), sentence(.installing)]
        #expect(Set(all).count == 3, "\(all)")
        #expect(sentence(.fetching).contains("Nothing on this Mac was changed"))
        #expect(sentence(.switching).contains("Nothing was installed"))
        #expect(sentence(.installing).contains("untouched"))
    }

    /// Homebrew's plan is one step that fetches, builds and installs, and it
    /// is `.installing`. A sentence claiming the release "was fetched but not
    /// installed" would be false of it.
    @Test func theInstallingSentenceIsTrueOfAOneStepPlanToo() {
        #expect(!sentence(.installing).contains("fetched"))
    }

    /// The update landed; what did not finish is the app coming back. Telling
    /// someone to re-run the installer here would be the wrong instruction,
    /// so this is the one phase that does not.
    @Test func theRelaunchSentenceNamesTheAppAndNotTheInstaller() {
        let text = sentence(.relaunching)
        #expect(text.contains("is installed"), "\(text)")
        #expect(text.contains("open /Applications/Simmer.app"), "\(text)")
        #expect(!text.contains("brew upgrade"), "the install worked — do not send them round again")
    }

    /// A plan with no bundle to reopen still gets a whole sentence rather than
    /// one ending in a dangling "open ".
    @Test func aPlanWithNoBundleStillEndsItsSentence() {
        let text = UpdateCommand.failureSentence(
            phase: .relaunching, plan: plan(kind: .checkout), updateCommand: "")
        #expect(text.hasSuffix("."), "\(text)")
        #expect(!text.contains("open "), "\(text)")
    }

    /// The plan of a bundle install: it fetched a release from a remote, so
    /// there is a tag, a checkout and a remote to name.
    private func installerPlan(
        tag: String = "v0.9.0",
        checkout: String = "/Users/x/.local/share/simmer",
        remote: String = "https://github.com/moralesl/simmer"
    ) -> UpdateCommand.ApplyPlan {
        UpdateCommand.ApplyPlan(
            steps: [], target: "0.9.0", reopenBundle: "/Applications/Simmer.app",
            releaseFetch: .init(tag: tag, checkout: checkout, remote: remote))
    }

    /// The 8 Sep sentence, and what it could not tell anybody.
    ///
    /// "Could not switch to simmer 0.3.3. Nothing was installed." was true of
    /// an install checkout whose `origin` lagged the release — and equally
    /// true of a dirty tree, a moved tag and a disk that filled up. What it
    /// now adds is where it looked: the tag, the checkout, and the remote it
    /// fetched from.
    @Test func theSwitchingSentenceNamesTheTagTheCheckoutAndTheRemote() {
        let text = UpdateCommand.failureSentence(
            phase: .switching, plan: installerPlan(),
            updateCommand: "curl -fsSL https://github.com/moralesl/simmer/raw/main/bootstrap.sh | bash")

        #expect(text.contains("Could not switch to simmer 0.9.0"), "\(text)")
        #expect(text.contains("Nothing was installed"), "\(text)")
        #expect(text.contains("the tag v0.9.0"), "\(text)")
        #expect(text.contains("/Users/x/.local/share/simmer"), "\(text)")
        #expect(text.contains("after fetching from https://github.com/moralesl/simmer"), "\(text)")
        // The two clauses a truncated banner body must still show come first.
        #expect(text.hasPrefix("Could not switch to simmer 0.9.0. Nothing was installed."),
                "a banner truncates its tail, so the tail is the diagnostic half: \(text)")
    }

    /// It says where it looked, never why it failed.
    ///
    /// The same arm is reached by a dirty tree or a stray file in that
    /// checkout — Luis's own is on a detached HEAD — so a sentence asserting
    /// "the tag is not there" would be a lie about those. git's own words are
    /// the second line, which `theFailingCommandIsTheSecondLineNotTheFirst`
    /// pins.
    @Test func theSwitchingSentenceClaimsNoCause() {
        let text = UpdateCommand.failureSentence(
            phase: .switching, plan: installerPlan(), updateCommand: "")
        for cause in ["is not in", "does not exist", "missing", "not there", "lags", "dirty",
                      "because"] {
            #expect(!text.contains(cause),
                    "a sentence composed from the plan cannot know the cause: \(text)")
        }
    }

    /// And it never recommends the place that just failed.
    ///
    /// The update command for a bundle install is the one-paste installer,
    /// which fetches the same remote the plan just fetched — so a failure
    /// sentence ending in `Run: curl … | bash` sent Luis to a command that
    /// failed for the identical reason. What it names instead reads the
    /// checkout and stays true whatever the cause.
    @Test func theSwitchingSentenceDoesNotSendThemBackToTheRemoteThatFailed() {
        let installer = "curl -fsSL https://github.com/moralesl/simmer/raw/main/bootstrap.sh | bash"
        let text = UpdateCommand.failureSentence(
            phase: .switching, plan: installerPlan(), updateCommand: installer)

        #expect(!text.contains("curl"), "\(text)")
        #expect(!text.contains("| bash"), "\(text)")
        #expect(!text.contains("Run: "), "\(text)")
        #expect(text.hasSuffix("Look with: git -C /Users/x/.local/share/simmer status"), "\(text)")
    }

    /// The fetch that never got that far: the remote it TRIED is the fact this
    /// sentence exists for on the day GitHub is unreachable while `origin` is
    /// perfectly fine — the case a plan fetching `origin` never had.
    @Test func theFetchingSentenceNamesTheRemoteItTried() {
        let text = UpdateCommand.failureSentence(
            phase: .fetching, plan: installerPlan(), updateCommand: "brew upgrade simmer")
        #expect(text.contains("Could not fetch simmer 0.9.0 from https://github.com/moralesl/simmer"),
                "\(text)")
        #expect(text.contains("Nothing on this Mac was changed"), "\(text)")
        // Nothing was fetched, so the retry is not a recommendation of a
        // failure: it stays.
        #expect(text.contains("Run: brew upgrade simmer"), "\(text)")
    }

    /// A plan that fetched no release from a remote it was told about — the
    /// one-step Homebrew plan, a checkout fast-forwarding its own upstream —
    /// says exactly what it said before, byte for byte.
    @Test func aPlanWithNoReleaseFetchKeepsItsOldSentences() {
        #expect(UpdateCommand.failureSentence(phase: .fetching, plan: plan(),
                                              updateCommand: "brew upgrade simmer")
            == "Could not fetch simmer 0.9.0. Nothing on this Mac was changed. "
                + "Run: brew upgrade simmer")
        #expect(UpdateCommand.failureSentence(phase: .switching, plan: plan(),
                                              updateCommand: "brew upgrade simmer")
            == "Could not switch to simmer 0.9.0. Nothing was installed. "
                + "Run: brew upgrade simmer")
    }

    /// T1's deliverable 4, pinned by equality because nothing pinned its
    /// order: the phase first — which part stopped is what decides whether
    /// anything on this Mac changed — then the command, then git's own words.
    /// The sentence above is for the person; this line is what makes the click
    /// answerable tomorrow, and it is how the 8 Sep failure was diagnosed in
    /// one read.
    @Test func theLogLineIsPhaseThenCommandThenGitsOwnWords() {
        let step = UpdateCommand.ApplyStep(
            executable: "/usr/bin/git",
            arguments: ["-C", "/Users/x/.local/share/simmer", "checkout", "--quiet", "v0.9.0"],
            phase: .switching)
        #expect(UpdateCommand.applyLogSentence(
            .failed(step: step,
                    detail: "error: pathspec 'v0.9.0' did not match any file(s) known to git",
                    plan: installerPlan()))
            == "update: 0.9.0 failed while switching — "
                + "git -C /Users/x/.local/share/simmer checkout --quiet v0.9.0: "
                + "error: pathspec 'v0.9.0' did not match any file(s) known to git")
    }

    /// The sentence is the message; the failing command and its stderr tail
    /// stay underneath it as evidence, and in the banner's subtitle.
    @Test func theFailingCommandIsTheSecondLineNotTheFirst() throws {
        let step = UpdateCommand.ApplyStep(
            executable: "/usr/bin/git",
            arguments: ["-C", "/x", "checkout", "--quiet", "v0.9.0"], phase: .switching)
        let outcome = UpdateCommand.applyFailed(
            step: step, detail: "fatal: reference is not a tree",
            plan: plan(), updateCommand: "brew upgrade simmer")

        #expect(outcome.exit == 1)
        #expect(outcome.stderr.count == 2, "\(outcome.stderr)")
        #expect(outcome.stderr[0].contains("Could not switch to simmer 0.9.0"))
        #expect(outcome.stderr[1].contains("git -C /x checkout --quiet v0.9.0 failed"))
        #expect(outcome.stderr[1].contains("fatal: reference is not a tree"),
                "the stderr tail is kept verbatim")

        let banner = try #require(outcome.notifications.first)
        #expect(banner.title == "The simmer update did not finish")
        #expect(banner.subtitle == step.described)
        #expect(banner.body.contains("Could not switch to simmer 0.9.0"),
                "the banner gets the sentence")
    }

    /// A reopen that failed is not a failed install: the exit code, the
    /// success line and `applied` all stay as they were, and the sentence is
    /// added rather than substituted.
    @Test func aFailedRelaunchIsSaidWithoutBecomingAFailure() throws {
        let outcome = UpdateCommand.applied(
            plan(), reopened: false, relaunchFailure: "The application cannot be opened.",
            updateCommand: "brew upgrade simmer")

        #expect(outcome.exit == 0, "the update landed")
        #expect(outcome.stdout.first == "✅ simmer 0.9.0 installed")
        #expect(outcome.stdout.contains { $0.contains("did not come back") })
        #expect(outcome.stdout.contains { $0.contains("The application cannot be opened.") })
        let banner = try #require(outcome.notifications.first)
        #expect(banner.title == "simmer 0.9.0 installed")
        #expect(banner.body.contains("did not come back"))
    }

    /// And a reopen that worked says the good ending, out loud.
    ///
    /// This assertion used to read `body.isEmpty` — it pinned the defect as
    /// the contract (R2 finding 1). The empty body was never "what it always
    /// said": it was the reason nobody ever saw the click finish.
    @Test func aRelaunchThatWorkedSaysTheGoodEnding() throws {
        let outcome = UpdateCommand.applied(plan(), reopened: true)
        #expect(outcome.stdout == ["✅ simmer 0.9.0 installed · Simmer.app relaunched"])
        let banner = try #require(outcome.notifications.first)
        #expect(banner.body == "You are on 0.9.0 now.")
    }
}

/// The phase is a field on the step rather than something recognised from its
/// arguments, and the plans have to keep filling it in correctly — it decides
/// which sentence a person reads on the worst day this feature has.
@Suite struct ApplyPhaseTests {
    private func report(kind: Install.Kind, home: String = "/Users/x") -> UpdateCommand.Report {
        let path = kind == .homebrew
            ? "/opt/homebrew/Cellar/simmer/9.9.9/Simmer.app/Contents/MacOS/simmer"
            : "\(home)/Applications/Simmer.app/Contents/MacOS/simmer"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-phase-\(UUID().uuidString)")
        return UpdateCommand.check(
            now: 1_800_000_000, installed: "0.2.0",
            install: Install.detect(executablePath: path, home: home,
                                    exists: { _ in true }),
            appVersion: nil, ledger: Ledger(stateDir: dir),
            source: FakeReleaseSource(value: "v9.9.9"), cached: false, seamed: false)
    }

    private func steps(_ kind: Install.Kind) -> [UpdateCommand.ApplyStep] {
        guard case .run(let plan) = UpdateCommand.applyPlan(
            for: report(kind: kind), exists: { _ in true })
        else { #expect(Bool(false), "no plan for \(kind)"); return [] }
        return plan.steps
    }

    @Test func theBundlePlanIsFetchThenSwitchThenInstall() {
        #expect(steps(.bundle).map(\.phase) == [.fetching, .switching, .installing])
    }

    /// One step that does all three, so it is the last one — the phase whose
    /// sentence says the running copy is untouched.
    @Test func homebrewsOneStepIsInstalling() {
        #expect(steps(.homebrew).map(\.phase) == [.installing])
    }

    /// No plan may leave a step on a phase that describes something else, and
    /// every phase a plan uses must be one whose sentence is written.
    @Test func noStepIsMisfiled() {
        for kind in [Install.Kind.bundle, .homebrew] {
            for step in steps(kind) {
                #expect(step.phase != .relaunching, "\(kind) has no relaunch in its steps")
            }
        }
        #expect(UpdateCommand.reopenStep(bundle: "/Applications/Simmer.app").phase == .relaunching)
    }
}


/// The plan's own steps, run by real `git`, against repositories this test
/// makes — the case that got through every other test in this file.
///
/// Everything above asserts what the plan SAYS. On 8 Sep 2026 the plan said
/// something correct-looking and did nothing useful: `git fetch --tags --force`
/// in the install checkout, then `git checkout v0.3.3`, with the fetch reading
/// the checkout's `origin` and the release read from GitHub. Both steps were
/// right about themselves and wrong together, and no assertion over an
/// argument list could see it. So the fixture is the shape of Luis's Mac —
/// a "release" repository that has the tag, a "dev" clone that lags it, and an
/// installer checkout cloned from dev — and the steps are executed.
///
/// Hermetic by construction, not by promise: `runStep` refuses any step whose
/// arguments name a remote with a scheme, so a test that forgot to point the
/// plan at its fixture cannot quietly reach github.com. The suite proves that
/// guard by feeding it the real plan's own fetch step
/// (`theGuardRefusesTheRealPlansOwnRemote`), which it must refuse.
@Suite struct ApplyPlanAgainstRealGitTests {
    /// A step naming a remote this suite may not reach. A thrown error rather
    /// than a recorded expectation, because the check IS the reason the next
    /// line is safe to run — `#expect` would record the issue and then spawn
    /// the process anyway.
    enum StepWouldLeaveTheFixture: Error, CustomStringConvertible, Equatable {
        case remoteWithAScheme(String)

        var description: String {
            switch self {
            case .remoteWithAScheme(let argument):
                return "a step in this suite names \(argument) — the fixtures are plain paths, "
                    + "and a suite that calls itself hermetic does not spawn git at a URL"
            }
        }
    }

    /// git with none of the tester's identity or configuration, which is the
    /// one hermetic git this target has: `BootstrapFetchTests` established it
    /// and a second spelling of it would be a second thing to keep in step.
    @discardableResult
    static func git(_ args: [String]) -> String { BootstrapFetchTests.git(args) }

    static let hermeticEnvironment = [
        "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
        "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
        "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
    ]

    /// One of the plan's steps, verbatim, under that environment.
    static func runStep(_ step: UpdateCommand.ApplyStep) throws -> (out: String, code: Int32) {
        for argument in step.arguments
        where argument.contains("://") || argument.hasPrefix("git@") {
            throw StepWouldLeaveTheFixture.remoteWithAScheme(argument)
        }
        let result = Shell.run("/usr/bin/env",
                               hermeticEnvironment + [step.executable] + step.arguments)
        return (result.stdout + result.stderr, result.status)
    }

    /// The three repositories of 8 Sep, in a temporary directory.
    ///
    /// `release` is what GitHub holds: the commit the tag names. `dev` is a
    /// clone taken before that tag existed — a maintainer's checkout between
    /// pulls. `checkout` is the install checkout, cloned from `dev`, so its
    /// `origin` is the one that lags. `home` is what `Install.detect` is given,
    /// with symlinks resolved because `/var/folders` is one.
    struct Fixture {
        let root: URL, release: URL, dev: URL, checkout: URL, home: String

        static func make(tagged: Bool = true) throws -> Fixture {
            let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("simmer-origin-\(UUID().uuidString)").path)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let release = root.appendingPathComponent("release")
            git(["init", "--quiet", "--initial-branch=main", release.path])
            // A Makefile, because `applyPlan` refuses a checkout that has no
            // `.git` and no `Makefile` to build from — the clone needs it.
            try "install:\n\t@true\n".write(to: release.appendingPathComponent("Makefile"),
                                            atomically: true, encoding: .utf8)
            git(["-C", release.path, "add", "Makefile"])
            git(["-C", release.path, "commit", "--quiet", "-m", "the release before the release"])

            // The clone is taken HERE, before the tag: that is what "origin
            // lags" means, and doing it in this order is what makes the
            // fixture the Mac rather than a description of it.
            let dev = root.appendingPathComponent("dev")
            git(["clone", "--quiet", release.path, dev.path])

            try "0.9.0".write(to: release.appendingPathComponent("VERSION"),
                              atomically: true, encoding: .utf8)
            git(["-C", release.path, "add", "VERSION"])
            git(["-C", release.path, "commit", "--quiet", "-m", "release 9.9.9"])
            if tagged { git(["-C", release.path, "tag", "v9.9.9"]) }

            let checkout = root.appendingPathComponent(".local/share/simmer")
            try FileManager.default.createDirectory(
                at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
            git(["clone", "--quiet", dev.path, checkout.path])
            return Fixture(root: root, release: release, dev: dev, checkout: checkout,
                           home: root.path)
        }

        /// What the install checkout's `origin` actually is — printed by the
        /// test rather than assumed, because the whole defect was a wrong
        /// assumption about this one value.
        var checkoutOrigin: String {
            ApplyPlanAgainstRealGitTests.git(["-C", checkout.path, "remote", "get-url", "origin"])
        }

        var checkoutHead: String {
            ApplyPlanAgainstRealGitTests.git(["-C", checkout.path, "rev-parse", "HEAD"])
        }

        func releaseCommit(_ ref: String) -> String {
            ApplyPlanAgainstRealGitTests.git(["-C", release.path, "rev-parse", ref])
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    /// A bundle install whose installer checkout is the fixture's, and a plan
    /// that fetches the release from the fixture's release repository.
    private func makePlan(_ fixture: Fixture, releaseRemote: String? = nil,
                      latest: String = "v9.9.9") -> UpdateCommand.ApplyPlan? {
        let install = Install.detect(
            executablePath: "\(fixture.home)/Applications/Simmer.app/Contents/MacOS/simmer",
            home: fixture.home)
        #expect(install.source == .installer(fixture.checkout.path),
                "the fixture is not placed as an installer checkout: \(install.source)")
        let report = UpdateCommand.check(
            now: 1_800_000_000, installed: "0.2.0", install: install, appVersion: nil,
            ledger: Ledger(stateDir: fixture.root.appendingPathComponent("state")),
            source: FakeReleaseSource(value: latest), cached: false, seamed: false)
        let decision = UpdateCommand.applyPlan(
            for: report, exists: { FileManager.default.fileExists(atPath: $0) },
            releaseRemote: releaseRemote ?? fixture.release.path)
        guard case .run(let plan) = decision else {
            #expect(Bool(false), "no plan: \(decision)")
            return nil
        }
        return plan
    }

    /// First, the defect — on real `git`, in this fixture, so that the test
    /// below is measured against a failure rather than against nothing.
    ///
    /// This is the 0.3.2 plan, spelled out: fetch tags from `origin`, then
    /// check out the tag. It is Luis's 16:20, twice, including git's own words.
    @Test func fetchingOriginInThisFixtureFailsExactlyAsItDidOnHisMac() throws {
        let fixture = try Fixture.make(); defer { fixture.tearDown() }
        #expect(fixture.checkoutOrigin == fixture.dev.path,
                "the install checkout's origin is the one that lags")

        let old = UpdateCommand.ApplyStep(
            executable: "/usr/bin/git",
            arguments: ["-C", fixture.checkout.path, "fetch", "--tags", "--force", "--quiet"],
            phase: .fetching)
        let fetched = try Self.runStep(old)
        #expect(fetched.code == 0, "the fetch itself succeeded — that was never the failure")

        let switched = try Self.runStep(UpdateCommand.ApplyStep(
            executable: "/usr/bin/git",
            arguments: ["-C", fixture.checkout.path, "checkout", "--quiet", "v9.9.9"],
            phase: .switching))
        #expect(switched.code != 0, "origin lags and the tag was found anyway")
        #expect(switched.out.contains("pathspec 'v9.9.9' did not match"),
                "git's own words, and the line in simmer.log that made this readable: \(switched.out)")
    }

    /// And the fix: the same checkout, the same two steps, the remote the
    /// release was read from. The tag arrives and the checkout ends on it.
    @Test func theReleasesRemoteInstallsTheReleaseThroughACheckoutWhoseOriginLags() throws {
        let fixture = try Fixture.make(); defer { fixture.tearDown() }
        let plan = try #require(makePlan(fixture))

        // The plan is the real one: three steps, and `make install` is not run
        // here — this suite is about the two git steps.
        #expect(plan.steps.count == 3)
        #expect(plan.releaseFetch == .init(tag: "v9.9.9", checkout: fixture.checkout.path,
                                           remote: fixture.release.path))

        let fetched = try Self.runStep(plan.steps[0])
        #expect(fetched.code == 0, "\(fetched.out)")
        let switched = try Self.runStep(plan.steps[1])
        #expect(switched.code == 0, "\(switched.out)")

        #expect(fixture.checkoutHead == fixture.releaseCommit("v9.9.9"),
                "the checkout is not on the release's commit")
        #expect(Self.git(["-C", fixture.checkout.path, "describe", "--tags"]) == "v9.9.9")
        // And `origin` is untouched by all of it: fetching a URL updates no
        // remote-tracking branch, which is exactly right for a checkout that
        // only ever sits on tags.
        #expect(fixture.checkoutOrigin == fixture.dev.path)
    }

    /// The inversion: the release's own remote does not have the tag either.
    /// Nothing is installed, and the sentence names all three of the things
    /// that decide what a person does next.
    @Test func aTagMissingEverywhereIsRefusedWithTheCheckoutTheRemoteAndTheTag() throws {
        let fixture = try Fixture.make(tagged: false); defer { fixture.tearDown() }
        let plan = try #require(makePlan(fixture))
        let before = fixture.checkoutHead

        #expect(try Self.runStep(plan.steps[0]).code == 0, "the fetch has nothing to fail on")
        let switched = try Self.runStep(plan.steps[1])
        #expect(switched.code != 0, "a tag that exists nowhere was switched to")
        #expect(fixture.checkoutHead == before, "the checkout was moved under a failure")

        let sentence = UpdateCommand.failureSentence(
            phase: .switching, plan: plan,
            updateCommand: "curl -fsSL https://github.com/moralesl/simmer/raw/main/bootstrap.sh | bash")
        #expect(sentence.contains(fixture.checkout.path), "\(sentence)")
        #expect(sentence.contains(fixture.release.path), "\(sentence)")
        #expect(sentence.contains("v9.9.9"), "\(sentence)")
        #expect(!sentence.contains("curl"), "\(sentence)")
    }

    /// A tag that moved. `--force` is in the plan for exactly this, and this
    /// is what pins it: the local `v9.9.9` points somewhere else, and the
    /// release's is what gets installed.
    ///
    /// Without `--force` the fetch REFUSES the tag update and exits non-zero,
    /// so the ending is a wrong install either way — silently the stale one
    /// before `--force`, and a failed update without it.
    @Test func aLocalTagThatMovedIsReplacedRatherThanInstalled() throws {
        let fixture = try Fixture.make(); defer { fixture.tearDown() }
        let stale = fixture.checkoutHead
        Self.git(["-C", fixture.checkout.path, "tag", "v9.9.9", stale])
        #expect(Self.git(["-C", fixture.checkout.path, "rev-parse", "v9.9.9"]) == stale)

        let plan = try #require(makePlan(fixture))
        #expect(try Self.runStep(plan.steps[0]).code == 0)
        #expect(try Self.runStep(plan.steps[1]).code == 0)

        #expect(fixture.checkoutHead == fixture.releaseCommit("v9.9.9"),
                "the stale local tag was installed instead of the release")
        #expect(fixture.checkoutHead != stale)
    }

    /// The release's remote is unreachable while `origin` is perfectly fine —
    /// an offline maintainer, or GitHub down. The fetch fails, nothing is
    /// changed, and the `.fetching` sentence names the remote it tried; a plan
    /// that fetched `origin` never had this case at all.
    @Test func anUnreachableReleaseRemoteFailsFetchingAndNamesIt() throws {
        let fixture = try Fixture.make(); defer { fixture.tearDown() }
        let gone = fixture.root.appendingPathComponent("not-a-repository").path
        let plan = try #require(makePlan(fixture, releaseRemote: gone))
        let before = fixture.checkoutHead

        let fetched = try Self.runStep(plan.steps[0])
        #expect(fetched.code != 0, "a fetch from nowhere succeeded: \(fetched.out)")
        #expect(fixture.checkoutHead == before, "nothing on this Mac was changed")

        let sentence = UpdateCommand.failureSentence(phase: .fetching, plan: plan,
                                                     updateCommand: "")
        #expect(sentence.contains(gone), "the sentence names the remote it tried: \(sentence)")
        #expect(sentence.contains("Nothing on this Mac was changed"), "\(sentence)")
    }

    /// And the reverse: `origin` is gone while the release's remote answers.
    /// The old plan could not install here at all; this one does not consult
    /// `origin`, so it installs the release.
    @Test func anOriginThatVanishedDoesNotStopTheInstall() throws {
        let fixture = try Fixture.make(); defer { fixture.tearDown() }
        try FileManager.default.removeItem(at: fixture.dev)
        let plan = try #require(makePlan(fixture))

        #expect(try Self.runStep(plan.steps[0]).code == 0,
                "the plan consulted the origin it does not need")
        #expect(try Self.runStep(plan.steps[1]).code == 0)
        #expect(fixture.checkoutHead == fixture.releaseCommit("v9.9.9"))
    }

    /// The hermetic guard, inverted: the real plan's own fetch step names
    /// `https://github.com/moralesl/simmer`, and this suite must refuse to run
    /// it. Without this the guard is decoration — every step above happens to
    /// carry a plain path, so nothing would have exercised it.
    @Test func theGuardRefusesTheRealPlansOwnRemote() throws {
        let fixture = try Fixture.make(); defer { fixture.tearDown() }
        let plan = try #require(makePlan(fixture, releaseRemote: Install.repositoryURL))
        #expect(throws: StepWouldLeaveTheFixture.remoteWithAScheme(Install.repositoryURL)) {
            _ = try Self.runStep(plan.steps[0])
        }
        // The steps that name no remote stay runnable, or the guard would have
        // made the suite green by refusing everything.
        #expect(throws: Never.self) { _ = try Self.runStep(plan.steps[1]) }
    }
}
