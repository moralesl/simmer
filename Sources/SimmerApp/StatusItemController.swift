import AppKit
import SimmerCore

/// A thin renderer: the title comes from StatusTitle, the menu from
/// MenuModel — both pure, both tested in SimmerCoreTests. This file only
/// turns models into AppKit and clicks into Commands.
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

    func refreshTitle() {
        guard let button = statusItem.button else { return }
        let model = StatusTitle.render(AppState.shared.aggregate())
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

    // Built lazily so the menu is current at click time.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ctx = AppState.shared.context()
        let percent = ctx.power.batteryPercent().map(String.init) ?? "?"
        let batteryLine = "battery \(percent)%, \(ctx.power.onBattery() ? "on battery" : "on AC")"
        let model = MenuModel.build(aggregate: ctx.aggregate(), batteryLine: batteryLine)
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
