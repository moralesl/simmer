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

    // MARK: the check somebody asked for by hand
    //
    // Three facts this process owns, and the two rows it mutates while the
    // menu is up. They are here rather than in the ledger because that is what
    // they are: a click made in THIS menu, one to three seconds long. A second
    // copy of the app has no business drawing a spinner for a check it is not
    // making, and nothing has to be cleaned up if this process dies.

    /// A hand-asked check is running.
    private var checking = false
    /// What the last one answered, until the menu it was asked in closes.
    private var answer: MenuCheckAnswer?
    /// That answer has been on screen, so closing the menu retires it. A
    /// verdict is news for as long as somebody has just asked for it; left to
    /// stand, "already the newest release" would head the menu until the app
    /// restarts.
    private var answerWasSeen = false
    private var menuIsOpen = false
    /// Found by role at render time, never by title or index: the click mutates
    /// these two in place, and `removeAllItems()` is what closes a tracking
    /// menu (`Prototypes/T8Probe`). Weak, because the next fresh open builds
    /// new ones and this must not keep the old menu's items alive.
    private weak var updateGroupItem: NSMenuItem?
    private weak var checkItem: NSMenuItem?

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
    //
    // The ONE place that rebuilds: `removeAllItems()` closes a menu that is
    // tracking, which is why every change made while the menu is up mutates
    // the items that are already there (`applyUpdateGroup`). AppKit calls this
    // before a menu is shown, so a menu closed by Escape mid-check and opened
    // again arrives here and reads `checking` — the row is there too.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateGroupItem = nil
        checkItem = nil
        for entry in rows() {
            let item = render(entry)
            menu.addItem(item)
            switch entry.role {
            case .updateGroup: updateGroupItem = item
            case .checkForUpdates: checkItem = item
            case nil: break
            }
        }
    }

    /// The menu as the model says it should be, right now.
    private func rows() -> [MenuItemModel] {
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
                                  canApplyUpdate: AppState.shared.canApplyUpdate(update),
                                  releaseNotesURL: update.releaseNotesURL,
                                  // Read per menu open like the sudo rule
                                  // above: the click that started the install
                                  // is what closed this menu, and the next
                                  // open is the first chance to say so.
                                  installing: AppState.shared.installInProgress(),
                                  checking: checking, checked: answer)
        return MenuModel.build(aggregate: ctx.aggregate(), batteryLine: batteryLine,
                               install: install)
    }

    private func render(_ model: MenuItemModel) -> NSMenuItem {
        if model.isSeparator { return .separator() }
        let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
        apply(model, to: item)
        return item
    }

    /// One row's model onto one row of AppKit — for a row being built, and for
    /// a row being changed under an open menu.
    ///
    /// Every property the model can decide is set on every call, including
    /// back to nothing: a row that becomes an information row must lose the
    /// action it had, and the one that becomes the answer must lose the
    /// spinner's view. A mutation that only sets what it needs leaves the last
    /// state's leftovers behind, which is the shape of bug that makes a menu
    /// look right and behave like the row before it.
    private func apply(_ model: MenuItemModel, to item: NSMenuItem) {
        item.view = nil
        item.title = model.title
        item.attributedTitle = nil
        item.image = model.symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        item.isAlternate = model.isAlternate
        item.keyEquivalentModifierMask = model.isAlternate ? .option : []
        item.target = nil
        item.action = nil
        item.representedObject = nil
        item.submenu = nil
        item.isEnabled = true

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
            //
            // `isUnavailable` is the other row with no action: an action row
            // with nothing to do right now, which does belong in disabled ink.
            // Both arrive here as "no action" and they must not look alike.
            item.isEnabled = false
            item.attributedTitle = model.isUnavailable
                ? NSAttributedString(string: model.title, attributes: [
                    .foregroundColor: NSColor.disabledControlTextColor,
                    .font: NSFont.menuFont(ofSize: 0),
                ])
                : informationTitle(model)
        }

        // The two rows the app draws itself. The Check row, because a click on
        // a standard item ends the menu and this one must not; the spinner row,
        // because there is no SF Symbol that turns.
        //
        // The item keeps its target and action alongside the view: a view in a
        // menu item "can receive all mouse events as normal, but keyboard
        // events are not supported" (AppKit, Views in Menu Items), so the mouse
        // goes through the view and keeps the menu open, while a Return on the
        // highlighted row still performs the item's action — which closes the
        // menu and answers with the banner, exactly as 0.3.3 does. Keyboard
        // access is not made worse by this row being drawn by hand.
        guard model.role == .checkForUpdates || model.showsSpinner else { return }
        let view = MenuRowView(title: model.title, symbol: model.symbol,
                               spinning: model.showsSpinner,
                               isUnavailable: model.isUnavailable,
                               onClick: model.action == nil ? nil : { [weak self, weak item] in
                                   guard let self, let item else { return }
                                   self.runAction(item)
                               })
        // "The menu item will always be at least as wide as its view, but it
        // may be wider" (AppKit, Views in Menu Items) — so the highlight has to
        // follow the row's width rather than the title's.
        view.autoresizingMask = [.width]
        item.view = view
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
            // The menu is already closing, so the banner is the only place
            // this can be said. What to say is `MenuModel.copied`'s decision.
            Notifier.shared.post(MenuModel.copied(command).notifications)
        case .openSetup:
            SetupWindow.shared.show()
        case .checkForUpdates:
            startCheck()
        case .applyUpdate:
            AppState.shared.applyUpdate()
        case .openReleaseNotes(let url):
            // The browser fetches the notes; simmer does not. Its one
            // outbound request stays the `HEAD` that names the newest tag
            // (CONTRACTS.md § One outbound request).
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .quit:
            NSApp.terminate(nil)
        }
        refreshTitle()
    }

    // MARK: the check, answered in the row that asked

    /// The click that leaves the menu open.
    ///
    /// Nothing here closes or rebuilds the menu: the row is mutated in place
    /// and the check runs off the main thread, so the menu is still up when it
    /// comes back one to three seconds later. That is the whole of T8's option
    /// c, and the reason the row is a view at all.
    private func startCheck() {
        // An install already under way wins, and the model is what says so —
        // its Installing row replaces this group. Starting a check on top of it
        // would take away the one channel that is certain while `make install`
        // runs. A second click during a check cannot get here at all: the row
        // has no action while `checking`.
        guard !checking, AppState.shared.installInProgress() == nil else { return }
        checking = true
        answer = nil
        answerWasSeen = false
        applyUpdateGroup()

        if let why = AppState.shared.refreshUpdateCheck(force: true, then: { [weak self] report in
            self?.finish(report)
        }) {
            // Refused before it started — the seam, the environment, the
            // person's own switch. Every one of those used to be silence, and
            // silence under this row is a spinner that never stops: the
            // Installing-forever lie of 0.3.2, arriving through the one path
            // nobody clicks by hand.
            checking = false
            answer = .didNotRun(why)
            deliverAnswer(banner: nil)
        }
    }

    private func finish(_ report: UpdateCommand.Report) {
        checking = false
        answer = MenuCheckAnswer(verdict: report.verdict, latest: report.latestDisplay,
                                 error: report.error)
        deliverAnswer(banner: UpdateCommand.notification(report))
    }

    /// The answer is visible on every path: the row while the menu is open, the
    /// banner while it is not — never neither, and never both. A banner beside
    /// a row that already says it is the repetition "one banner per new
    /// version" exists to prevent.
    private func deliverAnswer(banner: NotificationRequest?) {
        if menuIsOpen {
            answerWasSeen = true
            applyUpdateGroup()
        } else if let banner {
            Notifier.shared.post([banner])
        }
        refreshTitle()
    }

    /// Bring the update group and the Check row in line with the model, without
    /// rebuilding the menu.
    ///
    /// Measured on a tracking menu before it was written this way: a title, an
    /// image, a view in, a view out, a submenu attached, `isHidden` both ways,
    /// an insert at the top and a remove — nine mutations inside one open menu,
    /// zero closes (`Prototypes/T20Frames measure`, on top of the T8 probe's
    /// twelve). What closes a tracking menu is `removeAllItems()`, and that is
    /// only in `menuNeedsUpdate`.
    private func applyUpdateGroup() {
        let model = rows()
        if let checkItem, let check = model.first(where: { $0.role == .checkForUpdates }) {
            apply(check, to: checkItem)
        }
        let group = model.first { $0.role == .updateGroup }
        switch (updateGroupItem, group) {
        case (let item?, let group?):
            apply(group, to: item)
        case (let item?, nil):
            // The answer was retired and there is nothing left to say. The row
            // goes with its separator, or the menu keeps a blank at the top.
            let index = menu.index(of: item)
            if index >= 0 {
                if index + 1 < menu.numberOfItems, menu.item(at: index + 1)?.isSeparatorItem == true {
                    menu.removeItem(at: index + 1)
                }
                menu.removeItem(at: index)
            }
            updateGroupItem = nil
        case (nil, let group?):
            // Nothing to mutate: the menu had no update group when the click
            // arrived — the ordinary case on a Mac that is up to date. So the
            // row is inserted, which a tracking menu survives (measured above).
            let item = render(group)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            updateGroupItem = item
        case (nil, nil):
            break
        }
    }

    // MARK: NSMenuDelegate — is anybody looking

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        if answer != nil { answerWasSeen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if answerWasSeen {
            answer = nil
            answerWasSeen = false
        }
        // The items belong to the menu that has just gone; the next open builds
        // its own. Holding them would be a mutation aimed at a menu nobody can
        // see.
        updateGroupItem = nil
        checkItem = nil
    }
}

private final class ActionBox {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}
