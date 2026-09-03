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
