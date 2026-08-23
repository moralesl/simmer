import Foundation

/// The menu bar's content as a pure model — built here, tested here, and only
/// *drawn* by the app. Same move that keeps the CLI thin: logic that lives in
/// AppKit is logic the suite cannot reach.
public enum MenuAction: Equatable, Sendable {
    /// Take/replace the menu bar's own claim — the only way to guarantee more
    /// time without touching anyone else's (CONTRACTS § D1).
    case claim(String)
    case claimForever
    case releaseMine
    case releaseAll
    case capSet(String)
    case capLift
    case copyCLI(String)
    case openSetup
    case quit
}

public struct MenuItemModel: Equatable, Sendable {
    public var title: String
    /// SF Symbol name, drawn as the item's image.
    public var symbol: String?
    /// nil = an information row. Information is NOT dimmed: the renderer
    /// gives it real label colors, because "2 claims" in disabled-gray reads
    /// as "nothing here" — which is exactly how it got misread in use.
    public var action: MenuAction?
    /// Shown only while ⌥ is held — the power layer.
    public var isAlternate: Bool
    /// The one leading line that answers "what is my Mac doing" — drawn bold.
    public var isProminent: Bool
    public var children: [MenuItemModel]
    public var isSeparator: Bool

    public static let separator = MenuItemModel(title: "", isSeparator: true)

    public init(title: String, symbol: String? = nil, action: MenuAction? = nil,
                isAlternate: Bool = false, isProminent: Bool = false,
                children: [MenuItemModel] = [], isSeparator: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.action = action
        self.isAlternate = isAlternate
        self.isProminent = isProminent
        self.children = children
        self.isSeparator = isSeparator
    }

    static func header(_ title: String, prominent: Bool = false) -> MenuItemModel {
        MenuItemModel(title: title, isProminent: prominent)
    }
}

public enum MenuModel {
    /// Lead with why, then act (DESIGN-NOTES): header first, the claims, the
    /// 80% actions, the cap, then the bridge to the CLI.
    public static func build(aggregate: Aggregate, batteryLine: String) -> [MenuItemModel] {
        var items: [MenuItemModel] = []

        switch aggregate.state {
        case .idle:
            items.append(.header("Sleep allowed — \(batteryLine)", prominent: true))
            items.append(.separator)
            items.append(.header("Keep awake for…"))
            for (title, duration) in [("30 minutes", "30m"), ("1 hour", "1h"), ("2 hours", "2h")] {
                items.append(MenuItemModel(title: title, symbol: "cup.and.saucer.fill",
                                           action: .claim(duration)))
            }
            items.append(MenuItemModel(title: "4 hours", symbol: "cup.and.saucer.fill",
                                       action: .claim("4h")))
            // `forever` demoted to the power layer: with a cap available,
            // a deadline is strictly better in almost every case.
            items.append(MenuItemModel(title: "Until further notice", symbol: "infinity",
                                       action: .claimForever, isAlternate: true))

        case .orphan:
            items.append(.header("Sleep is disabled with nothing claiming it", prominent: true))
            items.append(.header("Nobody is scheduled to hand it back — is the guard running?"))
            items.append(.separator)
            items.append(MenuItemModel(title: "Allow sleep now", symbol: "moon.zzz.fill",
                                       action: .releaseMine))
            items.append(MenuItemModel(title: "Turn it into a 1 hour claim",
                                       symbol: "cup.and.saucer.fill", action: .claim("1h")))

        case .active, .forever:
            let untilText = aggregate.until == 0
                ? "until further notice" : "until \(Formats.hhmm(aggregate.until))"
            let claims = aggregate.count == 1 ? "1 claim" : "\(aggregate.count) claims"
            items.append(.header("Awake \(untilText) — \(claims)", prominent: true))
            items.append(.separator)
            for entry in aggregate.live {
                let deadline = entry.effectiveUntil == 0
                    ? "no deadline" : "until \(Formats.hhmm(entry.effectiveUntil))"
                let reason = entry.claim.reason.isEmpty ? "" : " · \(entry.claim.reason)"
                items.append(.header("\(Owners.glyph(entry.claim.owner)) \(entry.claim.owner)\(reason) — \(deadline)"))
            }
            items.append(.separator)
            items.append(MenuItemModel(title: "Awake 15 more minutes",
                                       symbol: "cup.and.saucer.fill", action: .claim("15m")))
            items.append(MenuItemModel(title: "Awake 3 more hours",
                                       symbol: "cup.and.saucer.fill", action: .claim("3h"),
                                       isAlternate: true))
            items.append(contentsOf: releaseItems(aggregate))
        }

        items.append(.separator)
        items.append(capItem(aggregate))
        items.append(.separator)
        items.append(copyAsCLI(aggregate))
        items.append(MenuItemModel(title: "Setup…", symbol: "gearshape", action: .openSetup))
        items.append(MenuItemModel(title: "Quit Simmer", action: .quit))
        return items
    }

    static func releaseItems(_ aggregate: Aggregate) -> [MenuItemModel] {
        let mineExists = aggregate.live.contains { $0.claim.owner == "menubar" }
        // Destructive actions name their blast radius (DESIGN-NOTES).
        let everything = "Release everything (\(aggregate.count))"
        if mineExists && aggregate.count > 1 {
            return [MenuItemModel(title: "Release mine", symbol: "moon.zzz.fill",
                                  action: .releaseMine),
                    MenuItemModel(title: everything, symbol: "moon.zzz.fill",
                                  action: .releaseAll, isAlternate: true)]
        }
        if mineExists {
            return [MenuItemModel(title: "Release my claim", symbol: "moon.zzz.fill",
                                  action: .releaseMine)]
        }
        // A human holding no claim: releasing means releasing everyone's —
        // bare release carries human authority and does exactly that.
        return [MenuItemModel(title: everything, symbol: "moon.zzz.fill",
                              action: .releaseMine)]
    }

    static func capItem(_ aggregate: Aggregate) -> MenuItemModel {
        if aggregate.cap != 0 {
            return MenuItemModel(title: "Nothing past \(Formats.hhmm(aggregate.cap))",
                                 symbol: "hand.raised.fill",
                                 children: [MenuItemModel(title: "Lift the cap",
                                                          action: .capLift)])
        }
        var children = [MenuItemModel]()
        for (title, value) in [("Tonight 22:00", "22:00"), ("Tonight 23:00", "23:00"),
                               ("In 1 hour", "1h"), ("In 3 hours", "3h")] {
            children.append(MenuItemModel(title: title, action: .capSet(value)))
        }
        return MenuItemModel(title: "Nothing past…", symbol: "hand.raised.fill",
                             children: children)
    }

    /// The agent-tool bridge in one feature: every menu action has a CLI
    /// spelling, and the menu hands it out instead of hiding it.
    static func copyAsCLI(_ aggregate: Aggregate) -> MenuItemModel {
        var commands = [
            "simmer 1h -r \"why\"",
            "simmer status --json",
            "simmer budget --need 20m",
        ]
        if aggregate.count > 0 { commands.insert("simmer down", at: 1) }
        commands.append(aggregate.cap == 0 ? "simmer cap 23:00" : "simmer cap off")
        return MenuItemModel(title: "Copy as CLI command", symbol: "terminal",
                             children: commands.map {
                                 MenuItemModel(title: $0, action: .copyCLI($0))
                             })
    }
}
