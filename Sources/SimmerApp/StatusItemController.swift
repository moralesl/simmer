import AppKit
import SimmerCore

/// A thin renderer: the title comes from StatusTitle, the menu from
/// MenuModel — both pure, both tested in SimmerCoreTests. This file only
/// turns models into AppKit and clicks into Commands.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private var watcher: LedgerWatcher?

    /// Even with the watcher armed, redraw at least this often: a cap appearing
    /// for the first time is not watched (LedgerWatcher says why), and a missed
    /// file event must not be able to freeze the menu bar indefinitely. It
    /// matches the LaunchAgent's cadence, so this is the same worst case the
    /// guard already has.
    private static let backstopSeconds = 30

    func setUp() {
        menu.delegate = self
        statusItem.menu = menu
        refreshTitle()

        // The ledger changing is an event, not something to poll for: `simmer
        // 2h` in a terminal now reaches the menu bar in milliseconds, and
        // anything the CLI queued is posted at the same moment instead of
        // waiting for the spool timer.
        let watcher = LedgerWatcher(ledger: AppState.shared.context().ledger) {
            DispatchQueue.main.async {
                Notifier.shared.drainSpool()
                AppState.shared.updateAssertions()
                NotificationCenter.default.post(name: .simmerStateChanged, object: nil)
            }
        }
        watcher.start()
        self.watcher = watcher

        NotificationCenter.default.addObserver(forName: .simmerStateChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    func refreshTitle() {
        guard let button = statusItem.button else { return }
        let aggregate = AppState.shared.aggregate()
        scheduleNextRefresh(aggregate)
        let model = StatusTitle.render(aggregate)
        let title = NSMutableAttributedString(string: model.glyph)
        if !model.detail.isEmpty {
            // Monospaced digits so a live countdown does not jitter the menu bar.
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                        weight: .medium),
            ]
            if model.urgent { attributes[.foregroundColor] = NSColor.systemOrange }
            title.append(NSAttributedString(string: " " + model.detail, attributes: attributes))
        }
        button.attributedTitle = title
    }

    /// Sleep until the title would actually say something different, rather
    /// than on a round number. A minute-resolution countdown on a 10-second
    /// timer is wrong twice over: it repaints six times a minute while nothing
    /// changes, and the one repaint that matters still lands late.
    private func scheduleNextRefresh(_ aggregate: Aggregate) {
        refreshTimer?.invalidate()
        let due = min(StatusTitle.secondsUntilChange(aggregate), Self.backstopSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(due, 1)),
                                            repeats: false) { [weak self] _ in
            // A tick, not just a redraw. The app knows exactly when the
            // deadline is, so it is the process that should act on it: a
            // deadline crossing is settled here and now instead of waiting for
            // the LaunchAgent's next pass. Without this there is a window
            // after every expiry where the switch is on with nothing claiming
            // it — true, alarming to read in the menu, and entirely avoidable.
            // tick() is idempotent, so the guard arriving later is harmless.
            AppState.shared.tick()
            self?.refreshTitle()
        }
    }

    // Built lazily so the menu is current at click time.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ctx = AppState.shared.context()
        let percent = ctx.power.batteryPercent().map(String.init) ?? "?"
        let batteryLine = "battery \(percent)%, \(ctx.power.onBattery() ? "on battery" : "on AC")"
        // Read per menu open, not cached: the rule can be installed from the
        // setup window while this menu is the thing that sent you there, and a
        // stale "no permission" row would then be the lie.
        let update = AppState.shared.cachedUpdateReport()
        let install = MenuInstall(version: ctx.version,
                                  canHandBackUnattended: SudoRule.installedPath() != nil,
                                  updateLine: UpdateCommand.statusLine(update),
                                  updateCommand: update.install.updateCommand,
                                  versionLine: UpdateCommand.footerLine(update),
                                  canApplyUpdate: AppState.shared.canApplyUpdate(update))
        let model = MenuModel.build(aggregate: ctx.aggregate(), batteryLine: batteryLine,
                                    install: install)
        for entry in model {
            menu.addItem(render(entry))
        }
    }

    private func render(_ model: MenuItemModel) -> NSMenuItem {
        if model.isSeparator { return .separator() }
        let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
        if let symbol = model.symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if model.isAlternate {
            item.isAlternate = true
            item.keyEquivalentModifierMask = .option
        }
        if !model.children.isEmpty {
            let submenu = NSMenu()
            for child in model.children { submenu.addItem(render(child)) }
            item.submenu = submenu
        } else if let action = model.action {
            item.target = self
            item.action = #selector(runAction(_:))
            item.representedObject = ActionBox(action)
        } else {
            // Information rows: auto-disabled (no action), but NOT dimmed —
            // an attributed title keeps its ink, and "2 claims" in
            // disabled-gray reads as "nothing here". Learned from use.
            item.isEnabled = false
            item.attributedTitle = informationTitle(model)
        }
        return item
    }

    private func informationTitle(_ model: MenuItemModel) -> NSAttributedString {
        let menuFont = NSFont.menuFont(ofSize: 0)
        if model.isProminent {
            return NSAttributedString(string: model.title, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.boldSystemFont(ofSize: menuFont.pointSize),
            ])
        }
        let title = NSMutableAttributedString(string: model.title, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: menuFont,
        ])
        // The trailing "— until 17:00" is context, not the point: secondary ink.
        if let range = model.title.range(of: " — ", options: .backwards) {
            let nsRange = NSRange(range.lowerBound..<model.title.endIndex, in: model.title)
            title.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                               range: nsRange)
        }
        return title
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        switch box.action {
        case .claim(let duration):
            AppState.shared.perform { Commands.claim(ClaimInput(durationText: duration), ctx: $0) }
        case .extend(let duration):
            AppState.shared.perform { Commands.extend(duration, json: false, ctx: $0) }
        case .claimForever:
            AppState.shared.perform { Commands.claim(ClaimInput(forever: true), ctx: $0) }
        case .releaseMine:
            AppState.shared.perform { Commands.release(all: false, json: false, ctx: $0) }
        case .releaseAll:
            AppState.shared.perform { Commands.release(all: true, json: false, ctx: $0) }
        case .capSet(let value):
            AppState.shared.perform { Commands.cap(value, json: false, ctx: $0) }
        case .capLift:
            AppState.shared.perform { Commands.cap("off", json: false, ctx: $0) }
        case .copyCLI(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case .openSetup:
            SetupWindow.shared.show()
        case .checkForUpdates:
            // The answer arrives after the menu has closed, so it has to come
            // back through the one channel the app already owns: a banner.
            // Posting it is not a downgrade of the "no notification for the
            // background check" decision — this one was asked for by hand.
            AppState.shared.refreshUpdateCheck(force: true) { report in
                Notifier.shared.post([UpdateCommand.notification(report)])
            }
        case .applyUpdate:
            AppState.shared.applyUpdate()
        case .quit:
            NSApp.terminate(nil)
        }
        refreshTitle()
    }
}

private final class ActionBox {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}
