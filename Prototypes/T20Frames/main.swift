// T20Frames — the harness for T20's two frames, and for the four AppKit
// questions the T8 probe left open.
//
// It is NOT a second implementation of the row: it compiles
// `Sources/SimmerApp/MenuRowView.swift` verbatim and builds its titles from
// `SimmerCore.MenuModel`, so what it draws is what the app draws. What it adds
// is a status item of its own — which is the only way a click can be made at
// all: a menu that belongs to another process cannot be opened or clicked
// without Accessibility (`AXIsProcessTrusted() == false` on this Mac, measured
// 2026-09-08), and a second `simmer-app` run unseamed writes real power state
// through its launch `tick()`. So the pixels are the app's and the click is
// this harness's, and the frames say so.
//
// Build: see build.sh beside this file.
// Usage: T20Frames measure
//        T20Frames capture-checking <png>
//        T20Frames capture-answer <png>

import AppKit
import SimmerCore

// MARK: - the fixture
//
// T8's fixture, unchanged, so the frames of the built row are comparable with
// the frames Luis chose from: the same two version numbers in the same rows.
enum Fixture {
    static let installed = "0.3.2"
    static let latest = "0.3.3"

    static func install(checking: Bool, checked: MenuCheckAnswer?) -> MenuInstall {
        MenuInstall(version: installed, canHandBackUnattended: true,
                    updateLine: "Update available: \(latest)",
                    updateCommand: "cd ~/.local/share/simmer && git pull && make install",
                    versionLine: "simmer \(installed) — newest is \(latest)",
                    canApplyUpdate: true,
                    releaseNotesURL: "https://github.com/moralesl/simmer/releases/tag/v\(latest)",
                    checking: checking, checked: checked)
    }

    /// The rows the app would draw, from the model, for a Mac with no claims.
    static func rows(checking: Bool, checked: MenuCheckAnswer? = nil) -> [MenuItemModel] {
        MenuModel.build(
            aggregate: Aggregate.compute(claims: [], cap: nil,
                                         now: Int(Date().timeIntervalSince1970),
                                         sleepDisabled: false),
            batteryLine: "battery 80%, on AC",
            install: install(checking: checking, checked: checked))
    }
}

// MARK: - capture helpers (T8Probe's, unchanged)

func menuWindow(pid: pid_t) -> (id: CGWindowID, rect: CGRect)? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    var best: (CGWindowID, CGRect, Int)?
    for window in list {
        guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
              let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
              let id = window[kCGWindowNumber as String] as? CGWindowID,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"],
              width > 40, height > 20
        else { continue }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let area = Int(width * height)
        if best == nil || area > best!.2 { best = (id, rect, area) }
    }
    guard let best else { return nil }
    return (best.0, best.1)
}

func buttonRect(_ button: NSStatusBarButton?) -> CGRect? {
    guard let button, let window = button.window, let main = NSScreen.screens.first
    else { return nil }
    let onScreen = window.convertToScreen(button.frame)
    return CGRect(x: onScreen.minX, y: main.frame.maxY - onScreen.maxY,
                  width: onScreen.width, height: onScreen.height)
}

@discardableResult
func capture(to path: String, pid: pid_t, button: NSStatusBarButton?) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    var how = "screencapture -x -t png  (whole screen — no menu window found)"
    var args = ["-x", "-t", "png", path]
    if let window = menuWindow(pid: pid) {
        var rect = window.rect
        if let button = buttonRect(button) { rect = rect.union(button) }
        rect = rect.insetBy(dx: -12, dy: -12)
        rect = CGRect(x: max(0, rect.minX - 64), y: 0,
                      width: rect.width + 64, height: rect.maxY)
        args = ["-x", "-o", "-t", "png",
                "-R", "\(Int(rect.minX)),0,\(Int(rect.width)),\(Int(rect.maxY))", path]
        how = "screencapture -x -o -t png -R \(Int(rect.minX)),0,\(Int(rect.width)),\(Int(rect.maxY))"
    }
    process.arguments = args
    try? process.run()
    process.waitUntilExit()
    return how
}

// MARK: - the harness

final class Harness: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let pid = ProcessInfo.processInfo.processIdentifier

    var mode = ""
    var outPaths: [String] = []
    var openNow = false
    var closes = 0
    var clickedHandlerRuns = 0
    /// Kept the way the controller keeps them: found by role, mutated in place.
    var updateGroupItem: NSMenuItem?
    var checkItem: NSMenuItem?
    var checkRowView: MenuRowView?

    func setUp() {
        // Case 16, T8's case 13: the frame carries its own provenance. `T20` in
        // the menu bar is this harness and nothing else — the installed app's
        // status item is the 🍲 beside it, untouched.
        statusItem.button?.title = "T20"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .bold)
        menu.delegate = self
        statusItem.menu = menu
        rebuild(checking: false)
    }

    /// The controller's `menuNeedsUpdate` and `render`, on the same model rows.
    func rebuild(checking: Bool, checked: MenuCheckAnswer? = nil) {
        menu.removeAllItems()
        updateGroupItem = nil
        checkItem = nil
        checkRowView = nil
        for row in Fixture.rows(checking: checking, checked: checked) {
            let item = render(row)
            menu.addItem(item)
            if row.role == .updateGroup { updateGroupItem = item }
            if row.role == .checkForUpdates { checkItem = item }
        }
    }

    /// `StatusItemController.apply`, branch for branch.
    ///
    /// It is a copy and it is named as one: the controller's own version cannot
    /// be called from here — its status item and its menu are `private`, and a
    /// menu that belongs to another process cannot be opened without
    /// Accessibility. What the frames must not be is a second *drawing* of the
    /// row, and they are not: the view is `Sources/SimmerApp/MenuRowView.swift`
    /// itself, the titles are `SimmerCore.MenuModel`'s, and the branches below
    /// are the same four with the same properties. If they drift, the frames go
    /// stale, which is what a frame is for.
    func render(_ model: MenuItemModel) -> NSMenuItem {
        if model.isSeparator { return .separator() }
        let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
        if let symbol = model.symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if !model.children.isEmpty {
            let submenu = NSMenu()
            for child in model.children { submenu.addItem(render(child)) }
            item.submenu = submenu
        } else if model.action != nil {
            // A no-op target, because `NSMenu.autoenablesItems` disables any
            // item whose action nothing responds to — and a frame full of gray
            // rows that are black in the app would be a picture of the harness.
            item.target = self
            item.action = #selector(noop(_:))
        } else {
            item.isEnabled = false
            let font = NSFont.menuFont(ofSize: 0)
            if model.isUnavailable {
                item.attributedTitle = NSAttributedString(string: model.title, attributes: [
                    .foregroundColor: NSColor.disabledControlTextColor, .font: font,
                ])
            } else {
                let title = NSMutableAttributedString(string: model.title, attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: model.isProminent
                        ? NSFont.boldSystemFont(ofSize: font.pointSize) : font,
                ])
                if let range = model.title.range(of: " — ", options: .backwards) {
                    let nsRange = NSRange(range.lowerBound..<model.title.endIndex,
                                          in: model.title)
                    title.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                       range: nsRange)
                }
                item.attributedTitle = title
            }
        }
        guard model.role == .checkForUpdates || model.showsSpinner else { return item }
        let view = MenuRowView(title: model.title, symbol: model.symbol,
                               spinning: model.showsSpinner,
                               isUnavailable: model.isUnavailable,
                               onClick: model.action == nil ? nil : { [weak self] in
                                   self?.clickedHandlerRuns += 1
                               })
        view.autoresizingMask = [.width]
        item.view = view
        if model.role == .checkForUpdates { checkRowView = view }
        return item
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) { openNow = true }
    func menuDidClose(_ menu: NSMenu) { openNow = false; closes += 1 }

    func after(_ seconds: Double, _ body: @escaping () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func noop(_ sender: Any?) {}

    func say(_ step: String) {
        print("\(step)\topen=\(openNow)\tcloses=\(closes)"
            + "\twindow=\(menuWindow(pid: pid) != nil)\titems=\(menu.numberOfItems)")
    }
}

// MARK: - measure
//
// The four mutations the T8 probe did not make, each inside one open menu, each
// followed by the same two observables: is the menu still open, and has
// `menuDidClose` fired. The probe settled plain title/image mutation (12/0);
// what a `checking` row actually needs is a VIEW swapped in and out, a submenu
// attached while tracking, and — if the update group is absent when the click
// arrives — a row inserted at the top of a menu that is already up.

extension Harness {
    func runMeasure() {
        let steps: [(String, () -> Void)] = [
            ("0-baseline", {}),
            ("1-title", { self.updateGroupItem?.title = "Checking for updates…" }),
            ("2-view-in", {
                self.updateGroupItem?.view = MenuRowView(title: "Checking for updates…",
                                                         symbol: nil, spinning: true,
                                                         onClick: nil)
            }),
            ("3-view-out", {
                self.updateGroupItem?.view = nil
                self.updateGroupItem?.title = "Update available: 0.3.3 — you have 0.3.2"
                self.updateGroupItem?.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                                      accessibilityDescription: nil)
            }),
            ("4-submenu", {
                let submenu = NSMenu()
                submenu.addItem(NSMenuItem(title: "Install it now", action: nil, keyEquivalent: ""))
                self.updateGroupItem?.submenu = submenu
            }),
            ("5-hidden-on", { self.updateGroupItem?.isHidden = true }),
            ("6-hidden-off", { self.updateGroupItem?.isHidden = false }),
            ("7-insert-at-0", {
                let row = NSMenuItem(title: "Checking for updates…", action: nil, keyEquivalent: "")
                row.view = MenuRowView(title: "Checking for updates…", symbol: nil,
                                       spinning: true, onClick: nil)
                self.menu.insertItem(row, at: 0)
                self.menu.insertItem(.separator(), at: 1)
            }),
            ("8-remove-inserted", {
                self.menu.removeItem(at: 1)
                self.menu.removeItem(at: 0)
            }),
            ("9-synthetic-click-on-the-custom-row", {
                // Whether a click can be made at all without Accessibility.
                // `CGEvent.post` needs it; `NSApp.postEvent` puts an event in
                // this process's own queue, which a tracking menu may or may
                // not pull from. Measured rather than assumed, because the one
                // thing no unit test can reach is whether a real click on a
                // custom-view row keeps the menu open.
                guard let view = self.checkRowView, let window = view.window else {
                    print("   no window for the check row — cannot post an event")
                    return
                }
                let inWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                                            to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: inWindow, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }),
        ]
        run(steps, 0)
        statusItem.button?.performClick(nil)
    }

    private func run(_ steps: [(String, () -> Void)], _ index: Int) {
        guard index < steps.count else {
            after(0.6) {
                print("handler-runs=\(self.clickedHandlerRuns)")
                print("AXIsProcessTrusted=\(AXIsProcessTrusted())")
                // Case 15. What the row was for free as a plain NSMenuItem, and
                // what it is now: the label and role are set on the view (a
                // menu item with a view exposes the view), the item keeps its
                // own title, which is what type-select and a key equivalent
                // still use, and it keeps a target and an action, which is what
                // a Return on the highlighted row still performs. What no
                // in-process measurement can reach is VoiceOver's own
                // announcement — that needs Accessibility, printed above.
                let item = self.checkItem
                let view = self.checkRowView
                print("checkRow.item.title=\(item?.title ?? "-")"
                    + " hasAction=\(item?.action != nil)"
                    + " hasTarget=\(item?.target != nil)"
                    + " isEnabled=\(item?.isEnabled ?? false)")
                print("checkRow.view.accessibilityLabel=\(view?.accessibilityLabel() ?? "-")"
                    + " role=\(view?.accessibilityRole()?.rawValue ?? "-")"
                    + " isElement=\(view?.isAccessibilityElement() ?? false)"
                    + " enabled=\(view?.isAccessibilityEnabled() ?? false)")
                self.menu.cancelTracking()
                NSApp.terminate(nil)
            }
            return
        }
        let (name, body) = steps[index]
        // 0.9 s for the menu to be up before the first step, then a beat
        // between them so a dismissal has time to be observed rather than
        // raced past.
        after(index == 0 ? 0.9 : 0.35) {
            body()
            self.say(name)
            self.run(steps, index + 1)
        }
    }
}

// MARK: - capture

extension Harness {
    /// One frame per run: `screencapture` itself dismisses an open menu (T8's
    /// finding), so the checking frame and the answer frame cannot come from
    /// one open. That the change happens with the menu still open is what
    /// `measure` proves; a frame only shows what it looks like.
    func runCapture(answer: MenuCheckAnswer?, delay: Double = 1.1) {
        rebuild(checking: answer == nil, checked: answer)
        // The pointer out of the menu before the shutter, and back afterwards.
        // Whichever row it happens to rest on draws highlighted, and a frame
        // where one row is blue for no reason is a frame about the pointer: the
        // two frames of a pair have to differ in the one row that changed.
        let savedPointer = NSEvent.mouseLocation
        after(delay - 0.3) {
            if let screen = NSScreen.screens.first {
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.maxX - 40,
                                                  y: screen.frame.maxY - 40))
            }
        }
        after(delay) {
            print("open-before-capture=\(self.openNow)")
            // Case 16: which process is in the frame. On a crowded menu bar
            // macOS hides an overflowing status item while `performClick` still
            // opens its menu, so whether the harness's own `T20` title is
            // visible above the menu is evidence the capture line has to carry
            // rather than something a reader can assume from the picture.
            print("statusItem.isVisible=\(self.statusItem.isVisible)"
                + " button.frame=\(self.statusItem.button?.frame ?? .zero)"
                + " window=\(self.statusItem.button?.window?.frame ?? .zero)")
            let how = capture(to: self.outPaths[0], pid: self.pid, button: self.statusItem.button)
            print("capture -> \(self.outPaths[0])\n  \(how)")
            self.after(0.5) {
                print("open-after-capture=\(self.openNow) closes=\(self.closes)")
                self.menu.cancelTracking()
                CGWarpMouseCursorPosition(
                    CGPoint(x: savedPointer.x,
                            y: (NSScreen.screens.first?.frame.maxY ?? 0) - savedPointer.y))
                NSApp.terminate(nil)
            }
        }
        statusItem.button?.performClick(nil)
    }
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else {
    FileHandle.standardError.write(Data("""
    usage: T20Frames measure | capture-checking <png> | capture-answer <png>

    """.utf8))
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let harness = Harness()
harness.mode = mode
harness.outPaths = Array(args.dropFirst())

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        harness.setUp()
        harness.after(0.8) {
            switch harness.mode {
            case "measure": harness.runMeasure()
            case "capture-checking":
                // Two delays, so two runs can be diffed: an indeterminate
                // NSProgressIndicator inside a tracking menu either turns or
                // sits still, and the frame is the only thing that can say
                // which (menu tracking runs in its own run-loop mode, where a
                // hand-rolled timer would not fire at all).
                harness.runCapture(answer: nil,
                                   delay: Double(args.dropFirst(2).first ?? "") ?? 1.1)
            case "capture-answer":
                harness.runCapture(answer: MenuCheckAnswer(verdict: .available,
                                                           latest: Fixture.latest))
            case "capture-current":
                harness.runCapture(answer: MenuCheckAnswer(verdict: .current,
                                                           latest: Fixture.installed))
            case "capture-unknown":
                harness.runCapture(answer: MenuCheckAnswer(
                    verdict: .unknown,
                    error: "A server with the specified hostname could not be found."))
            default:
                FileHandle.standardError.write(Data("unknown mode \(harness.mode)\n".utf8))
                exit(2)
            }
        }
        // A hard stop: a harness that hangs must not sit in the menu bar.
        harness.after(120) { NSApp.terminate(nil) }
    }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
