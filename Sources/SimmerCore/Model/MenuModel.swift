import Foundation

/// The menu bar's content as a pure model — built here, tested here, and only
/// *drawn* by the app. Same move that keeps the CLI thin: logic that lives in
/// AppKit is logic the suite cannot reach.
public enum MenuAction: Equatable, Sendable {
    /// Take/replace the menu bar's own claim — the only way to guarantee more
    /// time without touching anyone else's (CONTRACTS.md § the claims ledger).
    case claim(String)
    /// Add to the menu bar's own claim. Distinct from `.claim` because "Awake
    /// 15 more minutes" must ADD fifteen minutes: routed through `.claim` it
    /// set the deadline to now+15m, so the item quietly cut a long claim short
    /// — the label promised one thing and the verb did another.
    case extend(String)
    case claimForever
    case releaseMine
    case releaseAll
    case capSet(String)
    case capLift
    case copyCLI(String)
    case openSetup
    /// Ask now, rather than waiting for the app's once-a-day look.
    case checkForUpdates
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

/// What the menu says about the INSTALL, as opposed to about the claims.
///
/// Both facts are ones a person cannot get at from the menu bar otherwise:
/// which version is actually running — the app is replaced under itself on
/// upgrade, so "the one I installed" is not a safe assumption — and whether
/// the guard can hand the switch back while nobody is at the keyboard, which
/// is the entire promise and which silently is not true without the sudo rule.
public struct MenuInstall: Sendable, Equatable {
    public var version: String
    /// The passwordless rule is in place. Without it the guard still runs and
    /// still decides correctly, and then cannot move the switch.
    public var canHandBackUnattended: Bool
    /// `UpdateCommand.statusLine` of the LAST check — nil when there is
    /// nothing to say, which is what makes the row conditional here rather
    /// than in the renderer.
    public var updateLine: String?
    /// What updating this copy would take, for the row to hand out.
    public var updateCommand: String

    public init(version: String, canHandBackUnattended: Bool,
                updateLine: String? = nil, updateCommand: String = "") {
        self.version = version
        self.canHandBackUnattended = canHandBackUnattended
        self.updateLine = updateLine
        self.updateCommand = updateCommand
    }
}

public enum MenuModel {
    /// Lead with why, then act: header first, the claims, the
    /// 80% actions, the cap, then the bridge to the CLI.
    public static func build(aggregate: Aggregate, batteryLine: String,
                             install: MenuInstall) -> [MenuItemModel] {
        var items: [MenuItemModel] = []

        // First, and only when there is something to say. A newer release is
        // not what the menu is FOR — the state header below is — so this row
        // is not drawn bold and does not compete with it; it carries a symbol
        // and a submenu instead, the same shape "Copy as CLI command" uses,
        // because the useful thing to do with it is to take the command away
        // to a terminal.
        if let line = install.updateLine {
            items.append(MenuItemModel(
                title: line, symbol: "arrow.down.circle.fill",
                children: [MenuItemModel(title: install.updateCommand,
                                         action: .copyCLI(install.updateCommand))]))
            items.append(.separator)
        }

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
            // "more" means more. Whether the menu bar already holds a claim
            // decides which verb delivers that: extend adds to one that
            // exists, and with none of its own there is nothing to add to, so
            // the first press takes one.
            let mine = aggregate.live.first { $0.claim.owner == "menubar" }
            let more: (String) -> MenuAction = { mine == nil ? .claim($0) : .extend($0) }
            items.append(MenuItemModel(title: "Awake 15 more minutes",
                                       symbol: "cup.and.saucer.fill", action: more("15m")))
            items.append(MenuItemModel(title: "Awake 3 more hours",
                                       symbol: "cup.and.saucer.fill", action: more("3h"),
                                       isAlternate: true))
            items.append(contentsOf: releaseItems(aggregate))
        }

        items.append(.separator)
        items.append(capItem(aggregate))
        items.append(.separator)
        items.append(copyAsCLI(aggregate))
        // Always here, in the same place, whether or not there is an update:
        // an item that appears only when it has news is an item nobody can
        // find when they want to ask.
        items.append(MenuItemModel(title: "Check for Updates…", symbol: "arrow.down.circle",
                                   action: .checkForUpdates))
        items.append(MenuItemModel(title: "Setup…", symbol: "gearshape", action: .openSetup))
        items.append(MenuItemModel(title: "Quit Simmer", action: .quit))

        // Last, and quiet. A claim is why anyone opened this menu; the install
        // is what they need when something is wrong with it.
        items.append(.separator)
        if !install.canHandBackUnattended {
            // Worth interrupting for: the guard runs, decides correctly, and
            // then cannot move the switch — so the lid closing ends the work
            // it was supposed to protect, and nothing else on this menu hints
            // at it.
            items.append(MenuItemModel(
                title: "No sleep-switch permission — the guard cannot hand it back",
                symbol: "exclamationmark.triangle.fill",
                action: .openSetup, isProminent: true))
        }
        items.append(MenuItemModel(title: "simmer \(install.version)"))
        return items
    }

    static func releaseItems(_ aggregate: Aggregate) -> [MenuItemModel] {
        let mineExists = aggregate.live.contains { $0.claim.owner == "menubar" }
        // Destructive actions name their blast radius.
        let everything = "Release everything (\(aggregate.count))"
        if mineExists && aggregate.count > 1 {
            // Both visible: the ⌥-alternate hid "everything" from the person
            // it exists for, and the title already names its blast radius.
            return [MenuItemModel(title: "Release mine", symbol: "moon.zzz.fill",
                                  action: .releaseMine),
                    MenuItemModel(title: everything, symbol: "moon.zzz.fill",
                                  action: .releaseAll)]
        }
        if mineExists {
            return [MenuItemModel(title: "Release my claim", symbol: "moon.zzz.fill",
                                  action: .releaseMine)]
        }
        // A human holding no claim: the only release on offer is everyone's,
        // and the title says so. (Bare release refuses this case by design.)
        return [MenuItemModel(title: everything, symbol: "moon.zzz.fill",
                              action: .releaseAll)]
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
