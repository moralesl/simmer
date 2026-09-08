import Foundation
import Testing
@testable import SimmerCore

// The menu bar's title and menu are pure models (StatusTitle, MenuModel) so
// the app's face is tested here, not eyeballed. The app only draws them.

@Suite struct StatusTitleTests {
    func aggregate(state: Aggregate.State, left: Int = 0, count: Int = 1) -> Aggregate {
        var a = Aggregate()
        a.state = state
        a.left = left
        a.leftShort = Durations.short(left)
        a.count = count
        return a
    }

    @Test func theTitleSaysWhoNotOnlyHowLong() {
        #expect(StatusTitle.render(aggregate(state: .idle, count: 0)).text == "🍲")
        #expect(StatusTitle.render(aggregate(state: .orphan, count: 0)).text == "⚠️")
        #expect(StatusTitle.render(aggregate(state: .active, left: 2520)).text == "🍲 42m")
        #expect(StatusTitle.render(aggregate(state: .active, left: 4800, count: 3)).text == "🍲 1h20·3")
        #expect(StatusTitle.render(aggregate(state: .forever, count: 2)).text == "🍲 ∞·2")
    }

    @Test func underFiveMinutesIsUrgent() {
        #expect(StatusTitle.render(aggregate(state: .active, left: 299)).urgent)
        #expect(!StatusTitle.render(aggregate(state: .active, left: 301)).urgent)
        #expect(!StatusTitle.render(aggregate(state: .forever)).urgent)
    }
}

@Suite struct PromiseChangeTests {
    func aggregate(_ state: Aggregate.State, until: Int) -> Aggregate {
        var a = Aggregate()
        a.state = state
        a.until = until
        return a
    }

    @Test func secondsInsideTheSameMinuteAreNotNews() {
        let before = aggregate(.active, until: 1_800_000_600)
        let after = aggregate(.active, until: 1_800_000_607)
        #expect(!promiseChangedMaterially(from: before, to: after))
    }

    @Test func crossingAMinuteOrChangingStateIs() {
        #expect(promiseChangedMaterially(from: aggregate(.active, until: 1_800_000_600),
                                         to: aggregate(.active, until: 1_800_000_660)))
        #expect(promiseChangedMaterially(from: aggregate(.idle, until: 0),
                                         to: aggregate(.active, until: 1_800_000_600)))
        #expect(promiseChangedMaterially(from: aggregate(.active, until: 1_800_000_600),
                                         to: aggregate(.forever, until: 0)))
    }
}

@Suite struct MenuModelTests {
    func claim(_ owner: String, until: Int) -> Claim {
        Claim(owner: owner, until: until, started: 10)
    }

    func build(claims: [Claim], cap: CapRecord? = nil, switchOn: Bool = true) -> [MenuItemModel] {
        let aggregate = Aggregate.compute(claims: claims, cap: cap, now: 100,
                                          sleepDisabled: switchOn)
        return MenuModel.build(aggregate: aggregate, batteryLine: "battery 80%, on AC",
                               install: MenuInstall(version: "0.0.0-test",
                                                    canHandBackUnattended: true))
    }

    func titles(_ items: [MenuItemModel]) -> [String] {
        items.filter { !$0.isSeparator }.map(\.title)
    }

    @Test func idleLeadsWithTruthThenOffersClaims() {
        let items = build(claims: [], switchOn: false)
        #expect(items.first?.title.contains("Sleep allowed") == true)
        #expect(items.contains { $0.action == .claim("30m") })
        #expect(items.contains { $0.action == .claim("2h") })
        // forever demoted to the power layer
        let forever = items.first { $0.action == .claimForever }
        #expect(forever?.isAlternate == true)
        // Quit is the last thing you can DO. The install rows sit below it and
        // carry no action — a version you cannot click is the point.
        #expect(items.compactMap(\.action).last == .quit)
        #expect(items.last?.action == nil)
    }

    @Test func activeLeadsWithWhyThenActs() {
        let items = build(claims: [claim("terminal", until: 4000),
                                   claim("agent:evals", until: 2000)])
        #expect(items.first?.title.hasPrefix("Awake until") == true)
        #expect(items.first?.title.contains("2 claims") == true)
        // one info row per claim, with the glyph of the door it came through
        #expect(items.contains { $0.title.contains("🤖 agent:evals") && $0.action == nil })
        #expect(items.contains { $0.title.contains("⌨️ terminal") && $0.action == nil })
        // The menu bar holds nothing here, so "more" has to start by taking a
        // claim — there is nothing of its own to add to.
        #expect(items.contains { $0.action == .claim("15m") && !$0.isAlternate })
        #expect(items.contains { $0.action == .claim("3h") && $0.isAlternate })
    }

    /// "Awake 15 more minutes" must ADD fifteen minutes. Routed through
    /// `.claim` it set the deadline to now+15m, so on a long claim the item
    /// quietly cut hours off — the label promised one thing and the verb did
    /// another. Once the menu bar holds a claim, "more" means extend.
    @Test func moreTimeExtendsTheMenuBarsOwnClaimRatherThanReplacingIt() {
        let items = build(claims: [claim("menubar", until: 40_000),
                                   claim("agent:evals", until: 2000)])
        #expect(items.contains { $0.action == .extend("15m") && !$0.isAlternate })
        #expect(items.contains { $0.action == .extend("3h") && $0.isAlternate })
        #expect(!items.contains { $0.action == .claim("15m") })
    }

    /// One table, read by every surface. A new owner kind getting a different
    /// face in the menu than in `simmer status` is the drift this prevents.
    @Test func everyOwnerKindHasItsOwnFace() {
        #expect(Owners.glyph("menubar") == "🖥️")
        #expect(Owners.glyph("terminal") == "⌨️")
        #expect(Owners.glyph("raycast") == "🚀")
                #expect(Owners.glyph("run:4821") == "⚙️")
        #expect(Owners.glyph("agent:evals") == "🤖")
        // The anonymous non-tty fallback is its own thing: an actor that did
        // not name itself, which a robot face would hide.
        #expect(Owners.glyph("script") == "📜")
        // Anything unrecognised reads as an automated caller, not as a person:
        // failing toward "not human" is the safe direction for a glyph whose
        // job is telling you which of these claims is yours.
        #expect(Owners.glyph("jenkins-worker-3") == "🤖")
        // Every human owner name must be visually distinct from every
        // non-human one — the whole point of splitting 👤 apart.
        let humanFaces = Set(["terminal", "menubar", "raycast"].map(Owners.glyph))
        let otherFaces = Set(["agent:x", "run:1", "script", "whatever"].map(Owners.glyph))
        #expect(humanFaces.isDisjoint(with: otherFaces))
    }

    @Test func releaseNamesItsBlastRadius() {
        // menubar holds nothing: the only release ends everyone's, says how
        // many, and carries the explicit-all action (bare release refuses).
        var items = build(claims: [claim("terminal", until: 4000),
                                   claim("agent", until: 2000)])
        #expect(items.contains { $0.title == "Release everything (2)" && $0.action == .releaseAll && !$0.isAlternate })

        // menubar holds one of several: both releases visible, mine first.
        items = build(claims: [claim("menubar", until: 4000), claim("agent", until: 2000)])
        #expect(items.contains { $0.title == "Release mine" && $0.action == .releaseMine })
        #expect(items.contains { $0.title == "Release everything (2)" && $0.action == .releaseAll && !$0.isAlternate })

        // menubar alone: no drama needed.
        items = build(claims: [claim("menubar", until: 4000)])
        #expect(items.contains { $0.title == "Release my claim" })
    }

    @Test func orphanOffersTheTwoHonestExits() {
        let items = build(claims: [], switchOn: true)
        #expect(items.first?.title.contains("nothing claiming it") == true)
        #expect(items.contains { $0.title == "Allow sleep now" })
        #expect(items.contains { $0.action == .claim("1h") })
    }

    @Test func theCapIsAlwaysThereAndAlwaysHonest() {
        var items = build(claims: [])
        let unset = items.first { $0.title == "Nothing past…" }
        #expect(unset?.children.count == 4)
        #expect(unset?.children.contains { $0.action == .capSet("23:00") } == true)

        items = build(claims: [claim("terminal", until: 4000)],
                      cap: CapRecord(until: 3000, setBy: "terminal", setAt: 0, expires: Cap.rollover(after: 3000)))
        let set = items.first { $0.title.hasPrefix("Nothing past ") }
        #expect(set?.children.first?.action == .capLift)
    }

    @Test func everyMenuTeachesTheCLI() {
        let withClaims = build(claims: [claim("terminal", until: 4000)])
        let copy = withClaims.first { $0.title == "Copy as CLI command" }
        let commands = copy?.children.map(\.title) ?? []
        #expect(commands.contains("simmer down"))
        #expect(commands.contains("simmer status --json"))
        let idle = build(claims: [], switchOn: false)
        let idleCopy = idle.first { $0.title == "Copy as CLI command" }
        #expect(idleCopy?.children.contains { $0.title == "simmer cap 23:00" } == true)
    }
}


/// What the menu says about the INSTALL rather than about the claims. Both
/// facts are ones a person cannot get at from the menu bar otherwise.
@Suite struct MenuInstallFooter {
    func menu(_ install: MenuInstall) -> [MenuItemModel] {
        MenuModel.build(aggregate: Aggregate(), batteryLine: "battery 80%, on AC",
                        install: install)
    }

    /// An upgrade replaces the app underneath a running one, so "the version I
    /// installed" is not a safe assumption about the version in the menu bar.
    @Test func theRunningVersionIsAlwaysShown() {
        let items = menu(MenuInstall(version: "0.2.0", canHandBackUnattended: true))
        #expect(items.contains { $0.title == "simmer 0.2.0" })
    }

    /// Without the rule the guard still runs and still decides correctly, and
    /// then cannot move the switch — so the lid closing ends the work it was
    /// supposed to protect, and nothing else on this menu hints at it.
    @Test func aMissingSleepSwitchPermissionIsSaidOutLoud() {
        let warned = menu(MenuInstall(version: "0.2.0", canHandBackUnattended: false))
        let row = warned.first { $0.title.contains("cannot hand it back") }
        #expect(row != nil)
        #expect(row?.isProminent == true, "a warning nobody can see is not a warning")
        #expect(row?.action == .openSetup, "it has to lead somewhere")

        // And it is absent when the rule is there, rather than always-on noise.
        let quiet = menu(MenuInstall(version: "0.2.0", canHandBackUnattended: true))
        #expect(!quiet.contains { $0.title.contains("cannot hand it back") })
    }

    /// Last, and after the actions: a claim is why anyone opened this menu.
    @Test func theInstallRowsComeAfterEverythingAboutTheClaim() {
        let items = menu(MenuInstall(version: "0.2.0", canHandBackUnattended: false))
        guard let quit = items.firstIndex(where: { $0.title == "Quit Simmer" }),
              let version = items.firstIndex(where: { $0.title == "simmer 0.2.0" }),
              let warning = items.firstIndex(where: { $0.title.contains("cannot hand it back") })
        else {
            Issue.record("the menu no longer carries all three rows")
            return
        }
        #expect(quit < warning)
        #expect(warning < version)
    }
}

/// The one menu action with no visible consequence of its own: the menu
/// closes, the clipboard has changed, and without this nothing says so.
@Suite struct CopyFeedbackTests {
    @Test func aCopyAnswersWithWhatItCopied() throws {
        let outcome = MenuModel.copied("simmer budget --need 20m")
        let banner = try #require(outcome.notifications.first)

        #expect(banner.title == "Copied to clipboard")
        // The command in the body: what got copied is the fact worth
        // checking, and a title long enough for the one-paste installer is a
        // title macOS truncates.
        #expect(banner.body == "simmer budget --need 20m")
        #expect(banner.sound == false, "a copy is not worth a sound")
        #expect(banner.actionable == false, "there is no Extend/Release to offer")
    }

    /// Exactly one, and nothing else: this is a banner, not a mutation. A
    /// stdout line here would be a line no surface prints and no test reads.
    @Test func itSaysNothingElseAndChangesNothing() {
        let outcome = MenuModel.copied("simmer down")
        #expect(outcome.notifications.count == 1)
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.exit == 0)
    }

    /// Every row that carries a `.copyCLI` gets the same feedback, because the
    /// renderer answers the action rather than the row — including the update
    /// group's command and the long one-paste installer line.
    @Test func everyCopyableRowInTheMenuHasSomethingToSay() {
        let items = MenuModel.build(
            aggregate: Aggregate.compute(claims: [], cap: nil, now: 1000, sleepDisabled: false),
            batteryLine: "battery 80%, on AC",
            install: MenuInstall(version: "0.2.0", canHandBackUnattended: true,
                                 updateLine: "Update available: 0.3.0",
                                 updateCommand: "curl -fsSL https://example.test/bootstrap.sh | bash"))
        let commands = (items + items.flatMap(\.children)).compactMap { item -> String? in
            if case .copyCLI(let command) = item.action { return command }
            return nil
        }
        #expect(commands.count >= 5, "found \(commands)")
        for command in commands {
            #expect(MenuModel.copied(command).notifications.first?.body == command)
        }
    }
}

/// The minute or two `make install` takes, in the one channel that is always
/// there. `MenuInstall` is declared in `MenuModel.swift`, so its rows are
/// tested here with the rest of the presentation model; `UpdateTests.swift`
/// keeps the suites about the *release check* that feeds it.
@Suite struct InstallingRowTests {
    private func menu(_ install: MenuInstall) -> [MenuItemModel] {
        MenuModel.build(aggregate: Aggregate.compute(claims: [], cap: nil, now: 1000,
                                                     sleepDisabled: false),
                        batteryLine: "battery 80%, on AC", install: install)
    }

    private func available(installing: String?) -> MenuInstall {
        MenuInstall(version: "0.3.1", canHandBackUnattended: true,
                    updateLine: "Update available: 0.3.2",
                    updateCommand: "brew upgrade simmer",
                    canApplyUpdate: true,
                    releaseNotesURL: "https://example.test/v0.3.2",
                    installing: installing)
    }

    /// The click closed the menu and nothing on screen changed. The next open
    /// is the first chance to say what is happening, and it has to take it.
    @Test func theRowSaysWhatIsBeingInstalled() throws {
        let row = try #require(menu(available(installing: "0.3.2")).first)
        #expect(row.title == "Installing 0.3.2…")
        #expect(row.symbol == "arrow.down.circle.fill")
    }

    /// Disabled by construction rather than by a flag: a row with no action
    /// and no children is what the renderer draws as an information row, with
    /// its ink kept (StatusItemController.render).
    @Test func theRowCannotBeClickedAtAll() throws {
        let row = try #require(menu(available(installing: "0.3.2")).first)
        #expect(row.action == nil)
        #expect(row.children.isEmpty)
        #expect(row.isSeparator == false)
    }

    /// Case 10, answered in the model: a second "Install it now" would spawn a
    /// second child against the same checkout, two `make install` runs racing
    /// for one bundle. There is no such item while one is running.
    @Test func thereIsNothingLeftToClickTwice() {
        let items = menu(available(installing: "0.3.2"))
        let all = items + items.flatMap(\.children)
        #expect(!all.contains { $0.action == .applyUpdate })
        #expect(!all.contains { $0.title == "Install it now" })
        // And the group it replaced is gone with it — a row offering release
        // notes for a version that is already being installed is a stale menu.
        #expect(!items.contains { $0.title.contains("Update available") })
    }

    /// Absent and empty are different answers. An install whose target this
    /// reader cannot name is still an install, and dropping the fact because
    /// the version string is empty is exactly the fallback-on-unknown trap.
    @Test func anInstallWithNoNamedTargetStillSaysItIsInstalling() throws {
        let row = try #require(menu(available(installing: "")).first)
        #expect(row.title == "Installing simmer…")

        // nil is the other answer, and it restores the whole group.
        let quiet = try #require(menu(available(installing: nil)).first)
        #expect(quiet.title == "Update available: 0.3.2")
        #expect(quiet.children.contains { $0.action == .applyUpdate })
    }

    /// The record outlives the check that produced it: the app is quit and
    /// relaunched during an install, and the first thing the new process has
    /// is a state directory and no fresh report at all.
    @Test func theRowDoesNotNeedAnUpdateLineToBeThere() throws {
        let row = try #require(menu(MenuInstall(version: "0.3.1",
                                                canHandBackUnattended: true,
                                                installing: "0.3.2")).first)
        #expect(row.title == "Installing 0.3.2…")
    }

    /// The state header stays the one bold line, exactly as the update row it
    /// replaces was made not to compete with it.
    @Test func theInstallingRowDoesNotCompeteWithTheStateHeader() {
        let items = menu(available(installing: "0.3.2"))
        #expect(items.first?.isProminent == false)
        #expect(items.filter(\.isProminent).count == 1)
    }

    /// The plan that installs a branch names its target "0.3.2 or newer", and
    /// the row says what the plan says rather than inventing a tidier version.
    @Test func theRowRepeatsThePlansOwnTargetVerbatim() throws {
        let row = try #require(menu(available(installing: "0.3.2 or newer")).first)
        #expect(row.title == "Installing 0.3.2 or newer…")
    }
}

/// The one to three seconds between clicking **Check for Updates…** and the
/// answer, in the row that asked — and the four answers themselves.
///
/// Beside `InstallingRowTests` and shaped like it, because they are the two
/// facts about this Mac that take over the same row and the model is what
/// decides which of them wins.
@Suite struct CheckingRowTests {
    private func menu(_ install: MenuInstall) -> [MenuItemModel] {
        MenuModel.build(aggregate: Aggregate.compute(claims: [], cap: nil, now: 1000,
                                                     sleepDisabled: false),
                        batteryLine: "battery 80%, on AC", install: install)
    }

    /// The fixture of T8's frames: 0.3.2 installed, 0.3.3 published.
    private func install(checking: Bool = false, checked: MenuCheckAnswer? = nil,
                         installing: String? = nil, updateLine: String? = nil) -> MenuInstall {
        MenuInstall(version: "0.3.2", canHandBackUnattended: true,
                    updateLine: updateLine,
                    updateCommand: "cd ~/.local/share/simmer && git pull && make install",
                    canApplyUpdate: true,
                    releaseNotesURL: "https://example.test/v0.3.3",
                    installing: installing, checking: checking, checked: checked)
    }

    private func check(_ install: MenuInstall) -> MenuItemModel? {
        menu(install).first { $0.role == .checkForUpdates }
    }

    // MARK: while the check runs

    @Test func theTopRowSaysACheckIsRunning() throws {
        let items = menu(install(checking: true))
        let row = try #require(items.first)
        #expect(row.title == "Checking for updates…")
        #expect(row.role == .updateGroup)
        // The spinner is the app's to draw, so the model asks for one and names
        // no symbol: a still glyph on a row that waits is what reads as stuck.
        #expect(row.showsSpinner)
        #expect(row.symbol == nil)
        // First, above the state header, where "Update available" and
        // "Installing…" already live — and followed by their separator.
        #expect(items.count > 1 && items[1].isSeparator)
    }

    /// An information row: no action, no children. It cannot be clicked, and it
    /// keeps its ink — `isUnavailable` is the other row, below.
    @Test func theCheckingRowIsInformationAndNotDimmed() throws {
        let row = try #require(menu(install(checking: true)).first)
        #expect(row.action == nil)
        #expect(row.children.isEmpty)
        #expect(row.isUnavailable == false)
    }

    /// Case 10, answered in the model: a second click during the check cannot
    /// reach an action, because the row has none while the check runs.
    @Test func theCheckRowHasNoActionWhileACheckIsRunning() throws {
        let row = try #require(check(install(checking: true)))
        #expect(row.action == nil)
        #expect(row.isUnavailable)
        #expect(row.title == "Check for Updates…")

        // And it comes straight back afterwards, or the menu item is spent
        // after one use.
        let idle = try #require(check(install()))
        #expect(idle.action == .checkForUpdates)
        #expect(idle.isUnavailable == false)
    }

    /// `isUnavailable` and an action are contradictory instructions to the
    /// renderer — one says "draw it dead", the other "route the click". The
    /// model composes both in one place so they cannot disagree; this is the
    /// assertion that says so for every row of every menu the fixtures reach.
    @Test func noRowIsBothUnavailableAndClickable() {
        for checking in [true, false] {
            for checked in [nil, MenuCheckAnswer(verdict: .available, latest: "0.3.3"),
                            MenuCheckAnswer(verdict: .current),
                            MenuCheckAnswer(verdict: .unknown, error: "offline")] {
                let items = menu(install(checking: checking, checked: checked))
                let all = items + items.flatMap(\.children)
                #expect(!all.contains { $0.isUnavailable && $0.action != nil })
                // And a spinner is only ever asked for on a row that waits.
                #expect(!all.contains { $0.showsSpinner && $0.action != nil })
            }
        }
    }

    // MARK: the four answers

    @Test func availableIsTodaysUpdateRowWithTheFramesWording() throws {
        let items = menu(install(checked: MenuCheckAnswer(verdict: .available,
                                                          latest: "0.3.3")))
        let row = try #require(items.first)
        #expect(row.title == "Update available: 0.3.3 — you have 0.3.2")
        #expect(row.role == .updateGroup)
        #expect(row.symbol == "arrow.down.circle.fill")
        // The same submenu the standing update row has, in the same order: the
        // answer to the question IS that row, not a second thing that looks
        // like it.
        #expect(row.children.map(\.title) == ["Install it now", "Release notes…", "",
                                              "cd ~/.local/share/simmer && git pull && make install"])
        #expect(row.children.contains { $0.action == .applyUpdate })
    }

    @Test func currentSaysSoAndNamesTheVersion() throws {
        let row = try #require(menu(install(checked: MenuCheckAnswer(verdict: .current,
                                                                     latest: "0.3.2"))).first)
        #expect(row.title == "simmer 0.3.2 is already the newest release")
        #expect(row.action == nil)
        #expect(row.children.isEmpty)
    }

    @Test func aheadSaysWhatThereIsNothingToDoAbout() throws {
        let row = try #require(menu(install(checked: MenuCheckAnswer(verdict: .ahead,
                                                                     latest: "0.3.1"))).first)
        #expect(row.title == "simmer 0.3.2 is ahead of the newest release (0.3.1)")
        #expect(row.action == nil)
    }

    /// The reason, in the row. A row that says only "could not check" sends a
    /// person to a terminal to find out what this one already knows — and the
    /// dash puts the reason in secondary ink for free (`informationTitle`).
    @Test func unknownCarriesTheReasonItCouldNotTell() throws {
        let row = try #require(menu(install(checked: MenuCheckAnswer(
            verdict: .unknown,
            error: "A server with the specified hostname could not be found."))).first)
        #expect(row.title == "Could not check for updates — "
            + "A server with the specified hostname could not be found.")
    }

    /// A check that was refused before it started is an answer too, with the
    /// reason the caller was given. Silence here is a spinner that never stops.
    @Test func aCheckThatNeverRanAnswersWithTheReason() throws {
        let answer = MenuCheckAnswer.didNotRun("SIMMER_NO_UPDATE_CHECK is set")
        #expect(answer.verdict == .unknown)
        let row = try #require(menu(install(checked: answer)).first)
        #expect(row.title == "Could not check for updates — SIMMER_NO_UPDATE_CHECK is set")
    }

    // MARK: two facts, one row

    /// Case 12. An unattended install under way while somebody clicks Check:
    /// the model decides, and it decides for the install — the row that takes
    /// minutes and the one nothing else can report. The controller must not
    /// have an opinion of its own about this.
    @Test func anInstallUnderWayOutranksACheck() throws {
        let row = try #require(menu(install(checking: true, installing: "0.3.3")).first)
        #expect(row.title == "Installing 0.3.3…")
        #expect(row.showsSpinner == false)
        // And with an answer standing as well, it is still the install's row.
        let both = try #require(menu(install(checked: MenuCheckAnswer(verdict: .current),
                                             installing: "0.3.3")).first)
        #expect(both.title == "Installing 0.3.3…")
    }

    /// A check under way outranks the answer to the check before it, and an
    /// answer outranks the standing update line it was asked about — otherwise
    /// the row would show yesterday's news while today's question is open.
    @Test func theCheckOutranksItsOwnLastAnswerAndTheStandingLine() throws {
        let checking = try #require(menu(install(
            checking: true, checked: MenuCheckAnswer(verdict: .current),
            updateLine: "Update available: 0.3.3")).first)
        #expect(checking.title == "Checking for updates…")

        let answered = try #require(menu(install(
            checked: MenuCheckAnswer(verdict: .current, latest: "0.3.2"),
            updateLine: "Update available: 0.3.3")).first)
        #expect(answered.title == "simmer 0.3.2 is already the newest release")

        // Nothing asked, and the standing line is what the row says — today's
        // menu, unchanged.
        let quiet = try #require(menu(install(updateLine: "Update available: 0.3.3")).first)
        #expect(quiet.title == "Update available: 0.3.3")
        #expect(quiet.role == .updateGroup)
    }

    /// Nothing asked and nothing to say: no group row at all, which is the
    /// ordinary case on a Mac that is up to date — and the case that makes the
    /// controller insert a row into a menu that is already open.
    @Test func aQuietMenuHasNoUpdateGroupRow() {
        let items = menu(install())
        #expect(!items.contains { $0.role == .updateGroup })
        #expect(items.first?.isProminent == true)
    }

    /// The state header stays the one bold line, exactly as the update row and
    /// the Installing row were made not to compete with it.
    @Test func noAnswerCompetesWithTheStateHeader() {
        for checked in [MenuCheckAnswer(verdict: .available, latest: "0.3.3"),
                        MenuCheckAnswer(verdict: .current),
                        MenuCheckAnswer(verdict: .ahead, latest: "0.3.1"),
                        MenuCheckAnswer(verdict: .unknown, error: "offline")] {
            let items = menu(install(checked: checked))
            #expect(items.first?.isProminent == false)
            #expect(items.filter(\.isProminent).count == 1)
        }
        let checking = menu(install(checking: true))
        #expect(checking.first?.isProminent == false)
        #expect(checking.filter(\.isProminent).count == 1)
    }

    /// Exactly one of each role in any menu the app can draw: the controller
    /// finds both rows with `first(where:)`, and a second row wearing either
    /// role would leave one of them unreachable and un-mutated.
    @Test func eachRoleNamesAtMostOneRow() {
        for checking in [true, false] {
            for installing in [nil, "0.3.3"] {
                for line in [nil, "Update available: 0.3.3"] {
                    let items = menu(install(checking: checking,
                                             checked: MenuCheckAnswer(verdict: .available,
                                                                      latest: "0.3.3"),
                                             installing: installing, updateLine: line))
                    #expect(items.filter { $0.role == .updateGroup }.count == 1)
                    #expect(items.filter { $0.role == .checkForUpdates }.count == 1)
                }
            }
        }
    }
}

/// The file behind that row: written by the app before the child starts, read
/// back only by the version that wrote it, and ended three ways.
@Suite struct InstallInProgressTests {
    private func ledger() -> Ledger {
        Ledger(stateDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-installing-\(UUID().uuidString)"))
    }

    private let now = 1_800_000_000

    @Test func whatWasWrittenIsWhatIsRead() throws {
        let led = ledger()
        led.writeInstallInProgress(target: "0.3.2", now: now, installed: "0.3.1")
        let record = try #require(led.readInstallInProgress(writtenBy: "0.3.1", now: now))
        #expect(record.target == "0.3.2")
        #expect(record.startedAt == now)
        #expect(record.installed == "0.3.1")
    }

    @Test func noRecordAtAllIsNil() {
        #expect(ledger().readInstallInProgress(writtenBy: "0.3.1", now: now) == nil)
    }

    /// Case 12. The app that comes back IS the new version, so the record it
    /// left behind is invisible to it — the same seam `update-check` uses, and
    /// the reason nothing has to delete anything on the success path.
    @Test func aRecordFromTheVersionYouReplacedIsNotAnAnswer() {
        let led = ledger()
        led.writeInstallInProgress(target: "0.3.2", now: now, installed: "0.3.1")
        #expect(led.readInstallInProgress(writtenBy: "0.3.2", now: now) == nil)
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now) != nil)
    }

    /// Case 11's backstop. A row saying "Installing…" forever is a lie, and
    /// the one hole the other two ends leave — a child killed outright while
    /// the app was quit — closes on the clock.
    @Test func anAncientRecordIsNotAnAnswer() {
        let led = ledger()
        led.writeInstallInProgress(target: "0.3.2", now: now, installed: "0.3.1")
        let edge = now + Ledger.InstallInProgress.maxAge
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: edge - 1) != nil)
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: edge) == nil)
    }

    /// Case 14, and R2 finding 6: `now - startedAt < maxAge` is also true of
    /// every timestamp in the FUTURE, so a clock jump — or a hand-written
    /// record — claimed to be installing forever. The one-sided comparison
    /// was the immortal record that refusing to default an ABSENT
    /// `started_at` was there to prevent, left open on the other side.
    ///
    /// Driven through the renderer as well as the reader, because "no record"
    /// is only the right answer if the row it produces is true: `Update
    /// available: 0.3.2` is true whether or not something is installing.
    @Test func aRecordFromTheFutureIsNotAnAnswerEither() throws {
        let led = ledger()
        // Written by a clock a day fast, read by one that is right.
        led.writeInstallInProgress(target: "0.3.2", now: now + 86_400, installed: "0.3.1")
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now) == nil)
        // One second ahead is already not an answer: there is no tolerance to
        // tune, because simmer writes `env.now()` and nothing legitimate is
        // ever ahead of the reader.
        led.writeInstallInProgress(target: "0.3.2", now: now + 1, installed: "0.3.1")
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now) == nil)
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now + 1) != nil)

        let install = MenuInstall(
            version: "0.3.1", canHandBackUnattended: true,
            updateLine: "Update available: 0.3.2",
            updateCommand: "brew upgrade simmer", canApplyUpdate: true,
            releaseNotesURL: "https://example.test/v0.3.2",
            installing: led.readInstallInProgress(writtenBy: "0.3.1", now: now)?.target)
        let row = try #require(MenuModel.build(
            aggregate: Aggregate.compute(claims: [], cap: nil, now: 1000,
                                         sleepDisabled: false),
            batteryLine: "battery 80%, on AC", install: install).first)
        #expect(row.title == "Update available: 0.3.2")
        #expect(!row.children.isEmpty, "the row a person can act on came back")
    }

    @Test func clearingItEndsTheState() {
        let led = ledger()
        led.writeInstallInProgress(target: "0.3.2", now: now, installed: "0.3.1")
        led.clearInstallInProgress()
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now) == nil)
        // Idempotent: the app's terminationHandler and the child's own ending
        // both clear it, and either may be second.
        led.clearInstallInProgress()
    }

    /// Case 5, at the file. `target=` empty is "installing, target unnamed" —
    /// a record, not the absence of one.
    @Test func anEmptyTargetIsStillARecord() throws {
        let led = ledger()
        led.writeInstallInProgress(target: "", now: now, installed: "0.3.1")
        let record = try #require(led.readInstallInProgress(writtenBy: "0.3.1", now: now))
        #expect(record.target == "")
    }

    /// Case 3. One logical entry across two lines would leave the second half
    /// parsed as a key nobody wrote, so the write folds it before it lands.
    @Test func aTargetWithNewlinesIsFoldedIntoOneLine() throws {
        let led = ledger()
        led.writeInstallInProgress(target: "0.3.2\ninstalled=9.9.9", now: now,
                                  installed: "0.3.1")
        let record = try #require(led.readInstallInProgress(writtenBy: "0.3.1", now: now))
        #expect(!record.target.contains("\n"))
        #expect(record.installed == "0.3.1", "the fold must not let a value forge a key")
    }

    /// Case 2. Nothing simmer writes has CRLF, and a hand-edited file must not
    /// put a carriage return inside the version the menu renders or inside the
    /// version it compares against.
    @Test func aCRLFRecordReadsTheSameAsAUnixOne() throws {
        let led = ledger()
        try FileManager.default.createDirectory(at: led.stateDir,
                                                withIntermediateDirectories: true)
        try "target=0.3.2\r\nstarted_at=\(now)\r\ninstalled=0.3.1\r\n"
            .write(to: led.updateInProgressFile, atomically: true, encoding: .utf8)
        let record = try #require(led.readInstallInProgress(writtenBy: "0.3.1", now: now))
        #expect(record.target == "0.3.2")
        #expect(record.installed == "0.3.1")
    }

    /// Case 7. Two answers to one question is not an answer, and the safe
    /// direction is to claim nothing: the row falls back to "Update
    /// available", which is true whether or not something is installing.
    @Test func aDoubledKeyMakesTheRecordUnreadable() throws {
        let led = ledger()
        try FileManager.default.createDirectory(at: led.stateDir,
                                                withIntermediateDirectories: true)
        try "target=0.3.2\ntarget=9.9.9\nstarted_at=\(now)\ninstalled=0.3.1\n"
            .write(to: led.updateInProgressFile, atomically: true, encoding: .utf8)
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now) == nil)
    }

    /// A record with no timestamp is unknown, not now: defaulting it would
    /// make a hand-written file immortal against the age check.
    @Test func aRecordWithoutAStartIsNotAnAnswer() throws {
        let led = ledger()
        try FileManager.default.createDirectory(at: led.stateDir,
                                                withIntermediateDirectories: true)
        try "target=0.3.2\ninstalled=0.3.1\n"
            .write(to: led.updateInProgressFile, atomically: true, encoding: .utf8)
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now) == nil)

        try "target=0.3.2\nstarted_at=\ninstalled=0.3.1\n"
            .write(to: led.updateInProgressFile, atomically: true, encoding: .utf8)
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now) == nil)
    }

    /// Case 1. A symlink where the record goes must not be a write into
    /// whatever it points at. `atomicWrite` replaces the item at the path, so
    /// the link is what gets replaced and the target is untouched.
    @Test func aSymlinkedRecordIsReplacedRatherThanWrittenThrough() throws {
        let led = ledger()
        try FileManager.default.createDirectory(at: led.stateDir,
                                                withIntermediateDirectories: true)
        let elsewhere = led.stateDir.appendingPathComponent("elsewhere")
        try "untouched".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: led.updateInProgressFile,
                                                   withDestinationURL: elsewhere)

        led.writeInstallInProgress(target: "0.3.2", now: now, installed: "0.3.1")

        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "untouched")
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now)?.target == "0.3.2")
        let type = try FileManager.default.attributesOfItem(
            atPath: led.updateInProgressFile.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular, "the link is gone, not followed")
    }

    /// Case 1, the other half: a symlinked state DIRECTORY is the shape a
    /// throwaway XDG_STATE_HOME on a Mac already has (/var → /private/var), so
    /// it has to work rather than be refused.
    @Test func aSymlinkedStateDirectoryWorks() throws {
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-real-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let led = Ledger(stateDir: link)
        led.writeInstallInProgress(target: "0.3.2", now: now, installed: "0.3.1")
        #expect(led.readInstallInProgress(writtenBy: "0.3.1", now: now)?.target == "0.3.2")
        #expect(Ledger(stateDir: real)
            .readInstallInProgress(writtenBy: "0.3.1", now: now)?.target == "0.3.2")
    }
}

/// The banner behind the app's **Check for Updates…** — every arm of it.
///
/// `announcement` only ever passes `.available`, so the other three arms read
/// as unreachable and two of them were written with `body: ""`. The menu item
/// calls `notification(_:)` directly (`StatusItemController.swift:193`) and
/// "you are up to date" is its commonest answer, so the commonest answer to
/// the item Luis clicked at 10:4x was a banner macOS never presents
/// (R2 finding 2).
@Suite struct CheckBannerTests {
    private func report(installed: String, latest: String) -> UpdateCommand.Report {
        UpdateCommand.check(
            now: 1_800_000_000, installed: installed,
            install: Install.detect(executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
                                    home: "/Users/nobody", exists: { _ in false }),
            appVersion: nil,
            ledger: Ledger(stateDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("simmer-check-banner-\(UUID().uuidString)")),
            source: FakeReleaseSource(value: latest), cached: false)
    }

    @Test func beingUpToDateIsAnAnswerAndNotSilence() {
        let banner = UpdateCommand.notification(report(installed: "0.3.2", latest: "v0.3.2"))
        #expect(banner.title == "simmer 0.3.2 is up to date")
        #expect(banner.body == "Nothing to install.")
        #expect(banner.sound == false)
    }

    /// The property, over all four verdicts at once — the shape the structure
    /// gate enforces on the source, asserted here on the values. A check that
    /// cannot answer is the one arm whose text comes from `report.error`, and
    /// `check` guarantees that is never empty ("no release information").
    @Test func everyVerdictsBannerHasInformativeText() {
        for (installed, latest) in [("0.3.1", "v0.3.2"), ("0.3.2", "v0.3.2"),
                                    ("0.4.0", "v0.3.2"), ("0.3.2", "error")] {
            let banner = UpdateCommand.notification(report(installed: installed, latest: latest))
            #expect(banner.hasInformativeText, """
            a banner with neither subtitle nor body is one macOS never presents: \
            \(installed) vs \(latest) — \(banner)
            """)
        }
    }

    @Test func beingAheadOfTheNewestReleaseSaysThereIsNothingToDo() {
        let banner = UpdateCommand.notification(report(installed: "0.4.0", latest: "v0.3.2"))
        #expect(banner.title.contains("ahead"))
        #expect(banner.subtitle == "newest is 0.3.2")
        #expect(banner.body == "Nothing to install; a downgrade is not an update.")
    }
}

/// What the child says about an install, in the two channels a click can
/// reach: the spool and the log.
@Suite struct ApplyFeedbackTests {
    private func plan(target: String = "0.3.2") -> UpdateCommand.ApplyPlan {
        UpdateCommand.ApplyPlan(
            steps: [UpdateCommand.ApplyStep(executable: "/usr/bin/make",
                                            arguments: ["-C", "/tmp/x", "install"],
                                            phase: .installing)],
            target: target, reopenBundle: "/Applications/Simmer.app")
    }

    /// The whole defect of 0.3.1, in one assertion. The banner nobody ever saw
    /// was the only one this tool posts with an empty body, and on macOS a
    /// notification with no informative text is accepted and never presented.
    /// The three strings are asserted by EQUALITY, not for being non-empty
    /// (R2 finding 4). T1's report claimed "the exact strings in that table
    /// are the ones the suite pins" and they were not: rows 1e and 1f were
    /// pinned as non-empty only. Luis chose each of them from a three-column
    /// table while the screenshots that would have shown them were deferred,
    /// so this suite is standing in for the rendering — which it cannot do
    /// while it only knows that something is there.
    @Test func theStartingBannerCarriesABody() {
        let banner = UpdateCommand.startingNotification(plan(), installed: "0.3.1")
        // Row 1d.
        #expect(banner.title == "Installing simmer 0.3.2…")
        // Row 1e.
        #expect(banner.subtitle == "Simmer.app will quit and come back")
        // Row 1f. An empty body is a banner macOS never shows, which is why
        // this row exists at all.
        #expect(banner.body == "Building 0.3.2 from source — a minute or two. "
            + "You are on 0.3.1 until it lands.")
        #expect(banner.sound == false, "an update is not worth a sound")
        #expect(banner.actionable == false, "there is no Extend/Release to offer")
    }

    /// The same defect at the OTHER end of the same click (R2 finding 1). The
    /// start banner got a body in 0.3.2 and the ending banner did not, so
    /// every good apply finished with title + subtitle + `body: ""` — and
    /// when the app was not running to relaunch, the subtitle was empty too:
    /// a title-only banner, which is no informative text at all.
    @Test func theEndingBannerCarriesABodyOnBothArms() throws {
        let good = try #require(UpdateCommand.applied(plan(), reopened: true)
            .notifications.first)
        #expect(good.title == "simmer 0.3.2 installed")
        #expect(good.body == "You are on 0.3.2 now.")
        #expect(!good.subtitle.isEmpty)

        // Case 11's other half: the app was not running, so there is nothing
        // to say about a relaunch and the subtitle is legitimately empty. The
        // body is then the whole message, which is why it may not be.
        let quiet = try #require(UpdateCommand.applied(plan(), reopened: false)
            .notifications.first)
        #expect(quiet.subtitle.isEmpty)
        #expect(quiet.body == "You are on 0.3.2 now.")

        // Case 11: the relaunch-failed arm still names the failure and is not
        // the success sentence — the update landed, the menu bar did not.
        let failed = try #require(UpdateCommand.applied(
            plan(), reopened: false, relaunchFailure: "LSOpenURLs error -600")
            .notifications.first)
        #expect(failed.subtitle == "Simmer.app did not come back")
        #expect(failed.body.contains("did not come back"))
        #expect(failed.body != "You are on 0.3.2 now.")
    }

    /// Case 13: with notifications denied the menu row is the only channel,
    /// and it must not be the only one that names the version either.
    @Test func everyChannelNamesTheVersion() {
        let banner = UpdateCommand.startingNotification(plan(), installed: "0.3.1")
        #expect(banner.title.contains("0.3.2"))
        #expect(UpdateCommand.applyLogSentence(starting: plan(), owner: "menubar")
            .contains("0.3.2"))
    }

    @Test func theStartLineNamesWhoAskedForIt() {
        #expect(UpdateCommand.applyLogSentence(starting: plan(), owner: "menubar")
            == "update: installing 0.3.2 for menubar")
    }

    /// Case 9. A refusal from a click reaches a process whose stdout and
    /// stderr are both /dev/null, so before this it reached nobody at all.
    @Test func aRefusalIsSaidOutLoudAndWrittenDown() throws {
        let why = "the checkout at /x has 2 commits that main has not pushed"
        let outcome = UpdateCommand.applyOutcome(
            .refused(why), report: report(), seamed: false, json: false)
        let banner = try #require(outcome.notifications.first)
        // Row 1g, which was pinned nowhere at all (R2 finding 4).
        #expect(banner.title == "simmer did not install the update")
        #expect(banner.body == why, "the sentence names the way that works instead")
        #expect(outcome.exit == 1)
        #expect(UpdateCommand.applyLogSentence(.refused(why)) == "update: refused — \(why)")
    }

    /// The same, through `--json`: a machine caller loses no field and a
    /// person at the same Mac still gets the banner.
    @Test func aRefusalSaysItInJSONToo() throws {
        let outcome = UpdateCommand.applyOutcome(
            .refused("nope"), report: report(), seamed: false, json: true)
        #expect(try #require(outcome.notifications.first).body == "nope")
        #expect(outcome.stdout.first?.contains("\"apply_error\"") == true)
        #expect(outcome.exit == 1)
    }

    @Test func nothingToDoIsAlsoAnAnswerSomebodyClickedFor() throws {
        let sentence = "simmer 0.3.2 is already the newest release"
        let outcome = UpdateCommand.applyOutcome(
            .nothingToDo(sentence), report: report(), seamed: false, json: false)
        #expect(try #require(outcome.notifications.first).body == sentence)
        #expect(outcome.exit == 0)
    }

    /// Case 11. Which phase stopped is what decides whether anything on this
    /// Mac changed, so it is the first thing on the line.
    @Test func aFailureLineNamesThePhaseAndTheCommand() {
        let step = UpdateCommand.ApplyStep(executable: "/usr/bin/make",
                                           arguments: ["-C", "/tmp/x", "install"],
                                           phase: .installing)
        let line = UpdateCommand.applyLogSentence(
            .failed(step: step, detail: "error: no such module", plan: plan()))
        #expect(line.contains("installing"))
        #expect(line.contains("make -C /tmp/x install"))
        #expect(line.contains("error: no such module"))
    }

    @Test func theEndingLineSaysWhetherTheAppCameBack() {
        #expect(UpdateCommand.applyLogSentence(.installed(plan: plan(), reopened: true))
            == "update: installed 0.3.2 · Simmer.app relaunched")
        #expect(UpdateCommand.applyLogSentence(
            .installed(plan: plan(), reopened: false,
                       relaunchFailure: "LSOpenURLs error -600"))
            .contains("did not come back"))
    }

    /// Case 8. Every number on these lines is a Swift `Int` interpolation and
    /// not a formatter, so a German locale cannot put a comma in one — and the
    /// only numbers in the record file go through the same path.
    @Test func noLineCarriesALocalisedNumber() {
        let led = Ledger(stateDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-locale-\(UUID().uuidString)"))
        led.writeInstallInProgress(target: "0.3.2", now: 1_800_000_000, installed: "0.3.1")
        let text = (try? String(contentsOf: led.updateInProgressFile, encoding: .utf8)) ?? ""
        // The whole line, so a separator on either side of the number fails:
        // `1.800.000.000` and `1,800,000,000` are both wrong, and a German
        // locale produces the first.
        #expect(text.split(separator: "\n").contains("started_at=1800000000"))
    }

    private func report() -> UpdateCommand.Report {
        UpdateCommand.check(
            now: 1_800_000_000, installed: "0.3.1",
            install: Install.detect(executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
                                    home: "/Users/nobody", exists: { _ in false }),
            appVersion: nil,
            ledger: Ledger(stateDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("simmer-report-\(UUID().uuidString)")),
            source: FakeReleaseSource(value: "v0.3.2"), cached: false)
    }
}
