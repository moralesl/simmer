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
