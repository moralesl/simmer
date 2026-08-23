import AppKit
import SimmerCore

/// The menu bar: ambient truth at zero clicks, the 80% actions at one click,
/// ⌥ as the power layer, and "Copy as CLI" so the menu teaches the CLI
/// instead of hiding it (DESIGN-NOTES, adopted).
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var refreshTimer: Timer?

    func setUp() {
        menu.delegate = self
        statusItem.menu = menu
        refreshTitle()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
        NotificationCenter.default.addObserver(forName: .simmerStateChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    // MARK: the title — who, not only how long

    func refreshTitle() {
        guard let button = statusItem.button else { return }
        let aggregate = AppState.shared.aggregate()
        switch aggregate.state {
        case .idle:
            button.attributedTitle = NSAttributedString(string: "🍲")
        case .orphan:
            button.attributedTitle = NSAttributedString(string: "⚠️")
        case .forever, .active:
            var text = aggregate.state == .forever ? "∞" : aggregate.leftShort
            // Three characters answer "is that only me?" at zero clicks.
            if aggregate.count > 1 { text += "·\(aggregate.count)" }
            let urgent = aggregate.state == .active && aggregate.left <= 300
            let attributes: [NSAttributedString.Key: Any] = urgent
                ? [.foregroundColor: NSColor.systemOrange] : [:]
            let title = NSMutableAttributedString(string: "🍲 ")
            title.append(NSAttributedString(string: text, attributes: attributes))
            button.attributedTitle = title
        }
    }

    // MARK: the menu — lead with why, then act

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ctx = AppState.shared.context()
        let aggregate = ctx.aggregate()

        switch aggregate.state {
        case .idle:
            header(Present2.batteryHeader("Sleep allowed", ctx))
            menu.addItem(.separator())
            addClaimActions()
        case .orphan:
            header("Sleep is disabled with nothing claiming it")
            header("Nobody is scheduled to hand it back — is the guard running?")
            menu.addItem(.separator())
            action("Allow sleep now", key: "") {
                Commands.release(all: false, json: false, ctx: $0)
            }
            action("Turn it into a 1 hour claim", key: "") {
                Commands.claim(ClaimInput(durationText: "1h"), ctx: $0)
            }
        case .active, .forever:
            let untilText = aggregate.until == 0
                ? "until further notice" : "until \(Formats.hhmm(aggregate.until))"
            let claims = aggregate.count == 1 ? "1 claim" : "\(aggregate.count) claims"
            header("Awake \(untilText) — \(claims)")
            menu.addItem(.separator())
            for entry in aggregate.live {
                let deadline = entry.effectiveUntil == 0
                    ? "no deadline" : "until \(Formats.hhmm(entry.effectiveUntil))"
                let reason = entry.claim.reason.isEmpty ? "" : " · \(entry.claim.reason)"
                header("\(Present2.glyph(entry.claim.owner)) \(entry.claim.owner)\(reason) — \(deadline)")
            }
            menu.addItem(.separator())
            // "Extend" takes/replaces the menu bar's OWN claim — the only way
            // to guarantee more time without touching anyone else's (D1).
            action("Awake 15 more minutes", key: "e") {
                Commands.claim(ClaimInput(durationText: "15m"), ctx: $0)
            }
            alternate("Awake 3 more hours") {
                Commands.claim(ClaimInput(durationText: "3h"), ctx: $0)
            }
            addReleaseActions(aggregate)
        }

        menu.addItem(.separator())
        addCapSection(aggregate)
        menu.addItem(.separator())
        addCopyAsCLI(aggregate)
        menu.addItem(NSMenuItem(title: "Setup…", action: #selector(openSetup),
                                keyEquivalent: "").withTarget(self))
        menu.addItem(NSMenuItem(title: "Quit Simmer", action:
                #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addClaimActions() {
        header("Keep awake for…")
        for (label, duration) in [("30 minutes", "30m"), ("1 hour", "1h"), ("2 hours", "2h")] {
            action(label, key: "") {
                Commands.claim(ClaimInput(durationText: duration), ctx: $0)
            }
        }
        action("4 hours", key: "") {
            Commands.claim(ClaimInput(durationText: "4h"), ctx: $0)
        }
        // `forever` demoted to the power layer: with a cap available,
        // --until <cap> is strictly better in almost every case.
        alternate("Until further notice") {
            Commands.claim(ClaimInput(forever: true), ctx: $0)
        }
    }

    private func addReleaseActions(_ aggregate: Aggregate) {
        let mineExists = aggregate.live.contains { $0.claim.owner == "menubar" }
        let everything = "Release everything (\(aggregate.count))"
        if mineExists && aggregate.count > 1 {
            action("Release mine", key: "") {
                Commands.release(all: false, json: false, ctx: $0)
            }
            alternate(everything) {
                Commands.release(all: true, json: false, ctx: $0)
            }
        } else if mineExists {
            action("Release my claim", key: "") {
                Commands.release(all: false, json: false, ctx: $0)
            }
        } else {
            // A human holding no claim: releasing means releasing everyone's,
            // so the blast radius is in the label (DESIGN-NOTES).
            action(everything, key: "") {
                Commands.release(all: false, json: false, ctx: $0)
            }
        }
    }

    private func addCapSection(_ aggregate: Aggregate) {
        if aggregate.cap != 0 {
            let submenu = NSMenu()
            submenu.addItem(actionItem("Lift the cap") {
                Commands.cap("off", json: false, ctx: $0)
            })
            let item = NSMenuItem(title: "Nothing past \(Formats.hhmm(aggregate.cap))",
                                  action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        } else {
            let submenu = NSMenu()
            for (label, value) in [("Tonight 22:00", "22:00"), ("Tonight 23:00", "23:00"),
                                   ("In 1 hour", "1h"), ("In 3 hours", "3h")] {
                submenu.addItem(actionItem(label) {
                    Commands.cap(value, json: false, ctx: $0)
                })
            }
            let item = NSMenuItem(title: "Nothing past…", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    /// The agent-tool bridge in one feature: every menu action has a CLI
    /// spelling, and the menu hands it out instead of hiding it.
    private func addCopyAsCLI(_ aggregate: Aggregate) {
        let submenu = NSMenu()
        var commands = [
            "simmer 1h -r \"why\"",
            "simmer status --json",
            "simmer budget --need 20m",
        ]
        if aggregate.count > 0 { commands.insert("simmer down", at: 1) }
        if aggregate.cap == 0 { commands.append("simmer cap 23:00") }
        else { commands.append("simmer cap off") }
        for command in commands {
            let item = NSMenuItem(title: command, action: #selector(copyCommand(_:)),
                                  keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Copy as CLI command", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    // MARK: plumbing

    private func header(_ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func actionItem(_ title: String,
                            _ command: @escaping (Context) -> Outcome) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CommandBox(command)
        return item
    }

    private func action(_ title: String, key: String,
                        _ command: @escaping (Context) -> Outcome) {
        let item = actionItem(title, command)
        item.keyEquivalent = key
        menu.addItem(item)
    }

    private func alternate(_ title: String, _ command: @escaping (Context) -> Outcome) {
        let item = actionItem(title, command)
        item.isAlternate = true
        item.keyEquivalentModifierMask = .option
        menu.addItem(item)
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        AppState.shared.perform(box.command)
        refreshTitle()
    }

    @objc private func copyCommand(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.title, forType: .string)
    }

    @objc private func openSetup() {
        SetupWindow.shared.show()
    }
}

private final class CommandBox {
    let command: (Context) -> Outcome
    init(_ command: @escaping (Context) -> Outcome) { self.command = command }
}

extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}

enum Present2 {
    static func glyph(_ owner: String) -> String {
        if owner == "run" || owner.hasPrefix("run:") { return "⚙" }
        if SimmerEnvironment.isHumanOwnerName(owner) { return "👤" }
        return "🤖"
    }

    static func batteryHeader(_ prefix: String, _ ctx: Context) -> String {
        let percent = ctx.power.batteryPercent().map(String.init) ?? "?"
        let source = ctx.power.onBattery() ? "on battery" : "on AC"
        return "\(prefix) — battery \(percent)%, \(source)"
    }
}
