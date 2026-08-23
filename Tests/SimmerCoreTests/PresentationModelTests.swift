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
        return MenuModel.build(aggregate: aggregate, batteryLine: "battery 80%, on AC")
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
        #expect(items.last?.action == .quit)
    }

    @Test func activeLeadsWithWhyThenActs() {
        let items = build(claims: [claim("terminal", until: 4000),
                                   claim("agent:evals", until: 2000)])
        #expect(items.first?.title.hasPrefix("Awake until") == true)
        #expect(items.first?.title.contains("2 claims") == true)
        // one info row per claim, with its glyph
        #expect(items.contains { $0.title.contains("🤖 agent:evals") && $0.action == nil })
        #expect(items.contains { $0.title.contains("👤 terminal") && $0.action == nil })
        // extend acts on the menubar's OWN claim, ⌥ for the big step
        #expect(items.contains { $0.action == .claim("15m") && !$0.isAlternate })
        #expect(items.contains { $0.action == .claim("3h") && $0.isAlternate })
    }

    @Test func releaseNamesItsBlastRadius() {
        // menubar holds nothing: the only release ends everyone's, and says how many.
        var items = build(claims: [claim("terminal", until: 4000),
                                   claim("agent", until: 2000)])
        #expect(items.contains { $0.title == "Release everything (2)" && !$0.isAlternate })

        // menubar holds one of several: mine is primary, everything is ⌥.
        items = build(claims: [claim("menubar", until: 4000), claim("agent", until: 2000)])
        #expect(items.contains { $0.title == "Release mine" && $0.action == .releaseMine })
        #expect(items.contains { $0.title == "Release everything (2)" && $0.isAlternate })

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
                      cap: CapRecord(until: 3000, setBy: "terminal", setAt: 0))
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
