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

    @Test func aFormulasCellarIsHomebrewEvenThoughItHoldsABundle() {
        let install = Install.detect(
            executablePath: "/opt/homebrew/Cellar/simmer/0.3.0/Simmer.app/Contents/MacOS/simmer",
            exists: all)
        // The order matters: the `.app` test would otherwise claim this and
        // print the one-paste installer to the one person whose package
        // manager already knows how to update them.
        #expect(install.kind == .homebrew)
        #expect(install.updateCommand == "brew upgrade simmer")
    }

    @Test func anInstalledBundleIsTheOnePasteInstaller() {
        let install = Install.detect(
            executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer", exists: nothing)
        #expect(install.kind == .bundle)
        #expect(install.bundle == "/Applications/Simmer.app")
        #expect(install.updateCommand.contains("bootstrap.sh"))
    }

    @Test func aCheckoutIsGitPullAndMakeInstall() {
        let root = "/Users/x/src/simmer"
        let install = Install.detect(executablePath: "\(root)/.build/debug/simmer") {
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
        let install = Install.detect(executablePath: "/opt/vendored/.build/debug/simmer") {
            $0.hasSuffix("Package.swift")
        }
        #expect(install.kind == .unknown)
        #expect(install.updateCommand.contains("bootstrap.sh"))
    }

    /// A directory called `Foo.app` that is not a bundle must not be read as
    /// one — the reason the walk looks at path extensions rather than
    /// string-matching ".app".
    @Test func onlyARealBundlePathCounts() {
        #expect(Install.detect(executablePath: "/tmp/notanapp/simmer", exists: nothing).kind
                == .unknown)
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
                                    exists: { _ in false }),
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

    /// The human lines drop the tag's `v` so a sentence does not put `v0.3.0`
    /// next to `0.2.0`; the machine field keeps it.
    @Test func theTagIsSpelledForItsAudience() {
        let report = check(installed: "0.2.0", latest: "v0.3.0")
        #expect(report.latest == "v0.3.0")
        #expect(report.latestDisplay == "0.3.0")
        let human = UpdateCommand.humanOutcome(report).stdout.joined(separator: "\n")
        #expect(human.contains("0.3.0"))
        #expect(!human.contains("v0.3.0"))
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
    private func report(installed: String, latest: String, kind: Install.Kind,
                        home: String = "/Users/x") -> UpdateCommand.Report {
        let path: String
        switch kind {
        case .homebrew: path = "/opt/homebrew/Cellar/simmer/9.9.9/Simmer.app/Contents/MacOS/simmer"
        case .bundle: path = "\(home)/Applications/Simmer.app/Contents/MacOS/simmer"
        case .checkout: path = "\(home)/src/simmer/.build/debug/simmer"
        case .unknown: path = "/tmp/simmer"
        }
        let install = Install.detect(executablePath: path) {
            kind == .checkout && ($0.hasSuffix("Package.swift") || $0.hasSuffix(".git"))
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
            home: "/Users/x", exists: all)
        guard case .nothingToDo(let sentence) = decision else {
            #expect(Bool(false), "\(decision)"); return
        }
        #expect(sentence.contains("already the newest"))
    }

    @Test func beingAheadIsAlsoNothingToDo() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.9.0", latest: "v0.2.0", kind: .bundle),
            home: "/Users/x", exists: all)
        guard case .nothingToDo = decision else { #expect(Bool(false), "\(decision)"); return }
    }

    /// Not knowing whether there is an update is not a licence to install one.
    @Test func aFailedCheckRefusesRatherThanInstallingAnything() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "error", kind: .bundle),
            home: "/Users/x", exists: all)
        guard case .refused = decision else { #expect(Bool(false), "\(decision)"); return }
    }

    /// The bundle install — the colleague case, and the only one where nobody
    /// has a terminal open.
    @Test func aBundleInstallUpdatesTheInstallersCheckout() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .bundle),
            home: "/Users/x", exists: all)
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
        for kind in [Install.Kind.bundle, .homebrew, .checkout, .unknown] {
            let decision = UpdateCommand.applyPlan(
                for: report(installed: "0.2.0", latest: "v0.3.0", kind: kind),
                home: "/Users/x", exists: all)
            guard case .run(let plan) = decision else { continue }
            for step in plan.steps {
                #expect(!step.described.contains("curl"), "\(kind): \(step.described)")
                #expect(!step.described.contains("bash"), "\(kind): \(step.described)")
                #expect(!step.described.contains("|"), "\(kind): \(step.described)")
            }
        }
    }

    /// No checkout to build from, so there is nothing to run — and the refusal
    /// carries the command that does work.
    @Test func aBundleWithNoInstallerCheckoutRefusesWithTheCommand() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .bundle),
            home: "/Users/x", exists: nothing)
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
            home: "/Users/x", exists: all)
        guard case .refused(let why) = decision else { #expect(Bool(false), "\(decision)"); return }
        #expect(why.contains("your own checkout"))
        #expect(why.contains("make install"))
    }

    @Test func homebrewUpgradesThroughBrew() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .homebrew),
            home: "/Users/x", exists: { $0 == "/opt/homebrew/bin/brew" })
        guard case .run(let plan) = decision else { #expect(Bool(false), "\(decision)"); return }
        #expect(plan.steps.map(\.described) == ["brew upgrade simmer"])
    }

    @Test func homebrewWithoutBrewRefusesRatherThanGuessingAPath() {
        let decision = UpdateCommand.applyPlan(
            for: report(installed: "0.2.0", latest: "v0.3.0", kind: .homebrew),
            home: "/Users/x", exists: nothing)
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
