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
    /// Install it, for the person who has no terminal to paste into — which is
    /// most of the people this menu exists for. Offered only where
    /// `UpdateCommand.applyPlan` has a plan: a developer's own checkout is not
    /// machinery for simmer to move onto a tag.
    case applyUpdate
    /// Open the release's own page in the browser — the notes, for someone
    /// deciding whether to install it. Carries the URL rather than composing
    /// one in the renderer, so the menu and `update --json` point at the same
    /// page by construction.
    case openReleaseNotes(String)
    case quit
}

/// Which of the menu's rows this is, for the app that has to find it again.
///
/// The click on **Check for Updates…** mutates the update-group row while the
/// menu is open — never a rebuild, because `removeAllItems()` is what closes a
/// tracking menu (`Prototypes/T8Probe`, 12 in-place mutations, 0 closes) — so
/// the renderer has to be able to name those two rows without matching on
/// their titles or trusting their index. A title is wording, which changes with
/// every verdict; an index is arithmetic over the whole menu.
public enum MenuRole: Equatable, Sendable {
    /// The top row: the update, the install under way, the check, the answer.
    case updateGroup
    /// The row that asks. It keeps this role while the check runs, which is
    /// exactly when it has no action to be found by.
    case checkForUpdates
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
    /// The renderer draws a running progress indicator where the image would
    /// go. A check takes one to three seconds and the row it answers in is on
    /// screen for all of them: a still symbol there says "stuck", which is the
    /// reading 0.3.2's own Installing row earned.
    public var showsSpinner: Bool
    /// An action row with nothing to do *right now* — drawn in disabled ink and
    /// not clickable.
    ///
    /// Distinct from an information row, which also has no action and
    /// deliberately keeps its ink (see `action`). Both would otherwise arrive
    /// at the renderer as "no action", and "Check for Updates…" in full label
    /// ink that does nothing when clicked is the row that looks broken.
    public var isUnavailable: Bool
    public var role: MenuRole?

    public static let separator = MenuItemModel(title: "", isSeparator: true)

    public init(title: String, symbol: String? = nil, action: MenuAction? = nil,
                isAlternate: Bool = false, isProminent: Bool = false,
                children: [MenuItemModel] = [], isSeparator: Bool = false,
                showsSpinner: Bool = false, isUnavailable: Bool = false,
                role: MenuRole? = nil) {
        self.title = title
        self.symbol = symbol
        self.action = action
        self.isAlternate = isAlternate
        self.isProminent = isProminent
        self.children = children
        self.isSeparator = isSeparator
        self.showsSpinner = showsSpinner
        self.isUnavailable = isUnavailable
        self.role = role
    }

    static func header(_ title: String, prominent: Bool = false) -> MenuItemModel {
        MenuItemModel(title: title, isProminent: prominent)
    }
}

/// The answer a hand-asked check came back with, for the row that asked.
///
/// The verdict is `UpdateCommand.Verdict` itself rather than a second enum
/// beside it: four verdicts in two spellings is two things to keep in step, and
/// the menu's job here is to say what the check said. `latest` is the display
/// spelling (`0.3.3`, not `v0.3.3`) because it goes in a sentence next to
/// `installed`, and `error` is the reason a check that could not answer gives —
/// carried rather than flattened, so the row can name it (a row saying only
/// "could not check" sends a person to a terminal to find out why).
public struct MenuCheckAnswer: Sendable, Equatable {
    public var verdict: UpdateCommand.Verdict
    public var latest: String
    public var error: String

    public init(verdict: UpdateCommand.Verdict, latest: String = "", error: String = "") {
        self.verdict = verdict
        self.latest = latest
        self.error = error
    }

    /// The answer for a check that never ran.
    ///
    /// `AppState.refreshUpdateCheck` has three ways to say no — the seam, the
    /// environment, the person's own switch — and a click that is refused by
    /// one of them used to be silence. Under the row this ticket adds, silence
    /// is a spinner that never stops: the Installing-forever lie of 0.3.2,
    /// arriving through the one path nobody tests by hand. So a check that did
    /// not start is an answer with a reason, like any other check that could
    /// not tell.
    public static func didNotRun(_ why: String) -> MenuCheckAnswer {
        MenuCheckAnswer(verdict: .unknown, error: why)
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
    /// `UpdateCommand.footerLine` — the version, and what is newest, in one
    /// line. Falls back to the bare version when nothing has been checked at
    /// all, so the footer is never empty.
    public var versionLine: String?
    /// There is a plan to run — so the menu may offer to run it rather than
    /// only hand over a command that needs a terminal.
    public var canApplyUpdate: Bool
    /// `UpdateCommand.Report.releaseNotesURL` — nil when there is no release
    /// to point at, which is what keeps the row conditional here rather than
    /// in the renderer.
    public var releaseNotesURL: String?

    /// An install this Mac has already started, and the release it installs.
    ///
    /// `nil` is "nothing is installing"; a non-nil value — **including the
    /// empty string** — is "an install is under way", the empty case being one
    /// whose target this reader cannot name. Absent and empty are different
    /// answers here on purpose: folding them together would drop the one fact
    /// the row exists to carry.
    ///
    /// It is here rather than derived from `updateLine` because it is a fact
    /// about this Mac and not about the repository: `Ledger.readInstallInProgress`
    /// answers it, and the app is what asks.
    public var installing: String?

    /// A check somebody asked for by hand is running, right now, in this
    /// process.
    ///
    /// The sibling of `installing`, and a fact about this Mac for the same
    /// reason — but an in-process one, not a file: it lasts one to three
    /// seconds, it belongs to the click that started it, and a second copy of
    /// the app has no business showing a spinner for a check it is not making.
    /// The app asks; this decides what the menu says while it waits.
    public var checking: Bool
    /// What the last hand-asked check answered, until the menu it was asked in
    /// has been closed again. Nil is "nothing was asked", which is the state
    /// every menu opens in.
    public var checked: MenuCheckAnswer?

    public init(version: String, canHandBackUnattended: Bool,
                updateLine: String? = nil, updateCommand: String = "",
                versionLine: String? = nil, canApplyUpdate: Bool = false,
                releaseNotesURL: String? = nil, installing: String? = nil,
                checking: Bool = false, checked: MenuCheckAnswer? = nil) {
        self.version = version
        self.canHandBackUnattended = canHandBackUnattended
        self.updateLine = updateLine
        self.updateCommand = updateCommand
        self.versionLine = versionLine
        self.canApplyUpdate = canApplyUpdate
        self.releaseNotesURL = releaseNotesURL
        self.installing = installing
        self.checking = checking
        self.checked = checked
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
        // An install already under way replaces the whole group, and it is
        // checked FIRST: `make install` takes a minute or two, and for that
        // minute the menu is the only channel that is certain to be there —
        // a banner can be suppressed by Focus, and nothing simmer can read
        // says whether it was shown (PLATFORM-FACTS.md § Notifications).
        //
        // No submenu and no action, so it renders as an information row:
        // there is nothing left to install, nothing to copy that would not be
        // a second install, and a clickable "Install it now" while one is
        // running is an invitation to start a second child.
        // The order is the precedence, and it is the model's to decide: an
        // install under way outranks a check somebody started (two facts
        // claiming one row — `installing` wins, because it is the one that
        // takes minutes and the one nothing else can report), a check under way
        // outranks the answer to the check before it, and an answer outranks
        // the standing update line it was asked about.
        if let target = install.installing {
            items.append(MenuItemModel(
                title: target.isEmpty ? "Installing simmer…" : "Installing \(target)…",
                symbol: "arrow.down.circle.fill", role: .updateGroup))
            items.append(.separator)
        } else if install.checking {
            // No symbol: the renderer puts a running spinner where the image
            // would be. An information row, so it cannot be clicked, and one
            // to three seconds is exactly as long as it is there for.
            items.append(MenuItemModel(title: "Checking for updates…",
                                       showsSpinner: true, role: .updateGroup))
            items.append(.separator)
        } else if let answer = install.checked {
            items.append(contentsOf: answerGroup(answer, install: install))
        } else if let line = install.updateLine {
            items.append(contentsOf: updateGroup(title: line, install: install))
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
        // No action while a check is running, so a second click cannot start a
        // second one: the model takes the action away rather than the renderer
        // disabling a row that still carries it. `isUnavailable` is what makes
        // that visible — the renderer draws it in disabled ink instead of the
        // full label ink an information row keeps.
        items.append(MenuItemModel(title: "Check for Updates…", symbol: "arrow.down.circle",
                                   action: install.checking ? nil : .checkForUpdates,
                                   isUnavailable: install.checking,
                                   role: .checkForUpdates))
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
        // The one line that answers both halves of "am I current": what is
        // installed, and what is out there. `simmer update` says it in a
        // terminal; this is the same sentence for someone who has not got one.
        items.append(MenuItemModel(title: install.versionLine ?? "simmer \(install.version)"))
        return items
    }

    /// Today's update row, and the group it leads: the row itself, its
    /// submenu, and the separator under it.
    ///
    /// Extracted so the answer to a hand-asked check IS this row rather than a
    /// second one that looks like it — an `.available` verdict and a standing
    /// update line are the same news, and a menu with two shapes for it would
    /// drift apart at the first change to either.
    static func updateGroup(title: String, install: MenuInstall) -> [MenuItemModel] {
        var children: [MenuItemModel] = []
        if install.canApplyUpdate {
            // First, and named as the action it is. It runs the same
            // command the row hands out — no root, no download piped into
            // a shell — and it is the only path here that does not require
            // a terminal.
            children.append(MenuItemModel(title: "Install it now",
                                          symbol: "arrow.down.circle",
                                          action: .applyUpdate))
        }
        // Above the separator with "Install it now", because it is the
        // other thing you do with a version you have not got: read what
        // is in it first. A menu that only offers to install it asks for
        // a decision it gives you nothing to make.
        if let notes = install.releaseNotesURL {
            children.append(MenuItemModel(title: "Release notes…",
                                          symbol: "doc.text",
                                          action: .openReleaseNotes(notes)))
        }
        if install.canApplyUpdate || install.releaseNotesURL != nil {
            children.append(.separator)
        }
        children.append(MenuItemModel(title: install.updateCommand,
                                      action: .copyCLI(install.updateCommand)))
        return [MenuItemModel(title: title, symbol: "arrow.down.circle.fill",
                              children: children, role: .updateGroup),
                .separator]
    }

    /// The four answers, in the row that asked.
    ///
    /// Three of the four sentences are ones this tool already says — `.current`
    /// and `.ahead` are `UpdateCommand.applyPlan`'s own `nothingToDo` wording,
    /// `.unknown` is the title and body of its banner joined by the dash this
    /// menu already draws in secondary ink — so the menu and the terminal
    /// answer a question the same way. `.available` is the one new sentence,
    /// and it is the one Luis picked from a frame: the release, then what you
    /// have, because "0.3.3 is available" leaves the second half to memory.
    static func answerGroup(_ answer: MenuCheckAnswer, install: MenuInstall) -> [MenuItemModel] {
        switch answer.verdict {
        case .available:
            return updateGroup(
                title: "Update available: \(answer.latest) — you have \(install.version)",
                install: install)
        case .current:
            return [MenuItemModel(title: "simmer \(install.version) is already the newest release",
                                  role: .updateGroup), .separator]
        case .ahead:
            return [MenuItemModel(
                title: "simmer \(install.version) is ahead of the newest release "
                    + "(\(answer.latest))", role: .updateGroup), .separator]
        case .unknown:
            // The reason, always. "Could not check for updates" alone is the
            // row that sends someone to a terminal to find out what this one
            // already knows.
            return [MenuItemModel(title: "Could not check for updates — \(answer.error)",
                                  role: .updateGroup), .separator]
        }
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

    /// What a row that hands over its command has to say afterwards.
    ///
    /// A pasteboard write is the one menu action with no visible consequence:
    /// the menu closes, the clipboard has changed, and nothing on screen says
    /// so — which is indistinguishable from a row that did nothing. Every
    /// other action in this menu answers, so this one does too.
    ///
    /// An `Outcome` rather than a bare `NotificationRequest` so it is the same
    /// shape, tested the same way, as every other banner this core decides;
    /// the app only renders it. Raycast needs none of this — its own
    /// `Action.CopyToClipboard` shows a HUD when it fires.
    public static func copied(_ command: String) -> Outcome {
        var outcome = Outcome()
        outcome.notifications = [NotificationRequest(
            // The command in the body, not the title: what got copied is the
            // fact worth checking, and a title long enough to hold `curl -fsSL
            // https://…/bootstrap.sh | bash` is a title macOS truncates.
            title: "Copied to clipboard", subtitle: "", body: command, sound: false)]
        return outcome
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
