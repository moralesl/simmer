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

    /// The two conditions, each refused by name. Uncommitted work and an
    /// unfinished branch are exactly what "simmer does not rearrange somebody's
    /// desk" was about, and every refusal carries the command that works.
    @Test func aCheckoutThatIsNotReadyIsRefusedWithTheReason() {
        let cases: [(UpdateCommand.CheckoutState?, String)] = [
            (.init(branch: "main", defaultBranch: "main", clean: false), "uncommitted changes"),
            (.init(branch: "feat/x", defaultBranch: "main", clean: true), "is on feat/x, not main"),
            (.init(branch: "", defaultBranch: "main", clean: true), "is not on a branch"),
            (.init(branch: "main", defaultBranch: "", clean: true), "which branch is default"),
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

    /// And a reopen that worked says exactly what it always said.
    @Test func aRelaunchThatWorkedIsUnchanged() throws {
        let outcome = UpdateCommand.applied(plan(), reopened: true)
        #expect(outcome.stdout == ["✅ simmer 0.9.0 installed · Simmer.app relaunched"])
        #expect(try #require(outcome.notifications.first).body.isEmpty)
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
