import AppKit
import ServiceManagement
import SimmerCore
import UserNotifications

/// `simmer doctor` made visible: three rows, three buttons, live status. The
/// riskiest part of onboarding becomes legible here instead of being
/// paragraphs in a terminal (CONTRACTS.md § v1 surface additions).
///
/// The privileged step is shown, not performed: simmer never escalates its own
/// privileges (`SudoRule` says why).
final class SetupWindow: NSObject {
    static let shared = SetupWindow()
    static var sudoersPath: String { SudoRule.path }

    /// The exact two-line rule, shown in full — one source, shared with
    /// `simmer doctor` and the installer.
    static var sudoersRule: String { SudoRule.text(user: NSUserName()) }

    private var window: NSWindow?
    private let sudoRow = SetupRow(title: "Sleep switch", buttonTitle: "Copy command…")
    private let notifyRow = SetupRow(title: "Notifications", buttonTitle: "Ask again")
    private let loginRow = SetupRow(title: "Start at login", buttonTitle: "Enable")
    private var notifyStatus: UNAuthorizationStatus = .notDetermined

    func show() {
        if window == nil { build() }
        observeOnce()
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var observing = false

    /// Every row re-reads on any signal that one of them may have moved.
    ///
    /// Each of the three buttons used to refresh after its own action, and
    /// nothing else ever did — so the rows were only ever correct about the
    /// button you last pressed. The permission prompt a person actually answers
    /// on first launch is requested by `Notifier.setUp()`, not by this window,
    /// so clicking Allow left "Waiting for you to click Allow" on screen until
    /// some unrelated button was pressed and refreshed all three at once. The
    /// `.denied` row's "Open Settings" was the same dead end from the other
    /// direction: nothing re-read anything when you came back.
    ///
    /// Two signals rather than three buttons:
    ///   · the heartbeat, which already re-reads both values every three
    ///     seconds and now says so when one changes — this is the one that
    ///     catches an answer given to a banner nobody here asked for;
    ///   · becoming active, which catches whatever was changed in System
    ///     Settings while we were in the background, including the sudo rule
    ///     installed in a terminal.
    private func observeOnce() {
        guard !observing else { return }
        observing = true
        for name in [Notification.Name.simmerSetupChanged,
                     NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                // Only while on screen: `refresh` shells out to `sudo -nl` for
                // the first row, and that must not run for a window nobody is
                // looking at.
                guard let self, self.window?.isVisible == true else { return }
                self.refresh()
            }
        }
    }

    /// Shown automatically only while something still needs a human.
    ///
    /// The login item counts. It was left out, so the window never opened for
    /// it — and on the happy path (bootstrap installs the sudo rule, the person
    /// clicks Allow) there was no occasion on which anyone was shown that
    /// row at all.
    func showIfNeeded() {
        let loginNeedsAHuman = SMAppService.mainApp.status == .requiresApproval
        sudoState { ok, _ in
            Notifier.shared.authorizationStatus { status in
                DispatchQueue.main.async {
                    if !ok || status != .authorized || loginNeedsAHuman { self.show() }
                }
            }
        }
    }

    // MARK: layout

    private func build() {
        sudoRow.button.target = self
        sudoRow.button.action = #selector(setUpSudo)
        notifyRow.button.target = self
        notifyRow.button.action = #selector(notifyAction)
        loginRow.button.target = self
        loginRow.button.action = #selector(enableLoginItem)

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let heading = NSTextField(labelWithString: "Simmer needs three things, once.")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let subheading = NSTextField(labelWithString:
            "Everything here is reversible, and nothing is asked twice.")
        subheading.font = .systemFont(ofSize: 11)
        subheading.textColor = .secondaryLabelColor
        let headingStack = NSStackView(views: [heading, subheading])
        headingStack.orientation = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = 2
        let header = NSStackView(views: [icon, headingStack])
        header.orientation = .horizontal
        header.spacing = 12

        let rows = NSStackView(views: [sudoRow.view, separator(), notifyRow.view,
                                       separator(), loginRow.view])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        for row in [sudoRow, notifyRow, loginRow] {
            row.view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        let hint = NSTextField(wrappingLabelWithString:
            "The sleep switch is a two-line sudo rule scoped to exactly "
            + "“pmset -a disablesleep” and nothing else. simmer shows you the "
            + "command and you run it — it never gives itself root.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 460

        let content = NSStackView(views: [header, rows, hint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        rows.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Simmer Setup"
        window.contentView = content
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: live status

    private func refresh() {
        sudoState { ok, foreign in
            DispatchQueue.main.async {
                if ok {
                    self.sudoRow.set(.ok, "Password-free rule in place", button: nil)
                } else if foreign {
                    self.sudoRow.set(.warn, "Granted by something else — simmer installs its own rule",
                                     button: "Copy command…")
                } else {
                    self.sudoRow.set(.warn, "Needs one command, run by you", button: "Copy command…")
                }
            }
        }
        Notifier.shared.authorizationStatus { status in
            DispatchQueue.main.async {
                self.notifyStatus = status
                switch status {
                case .authorized, .provisional:
                    self.notifyRow.set(.ok, "Banners arrive as Simmer, with the pot icon", button: nil)
                case .denied:
                    self.notifyRow.set(.bad, "Denied — macOS remembers that per app",
                                       button: "Open Settings")
                default:
                    self.notifyRow.set(.warn, "Waiting for you to click Allow", button: "Ask again")
                }
            }
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            loginRow.set(.ok, "The menu bar comes back after a restart", button: nil)
        case .requiresApproval:
            // Registered, and macOS wants the person to say yes — a different
            // situation from "nobody asked", and it needs different advice.
            loginRow.set(.warn, "Waiting for your approval in System Settings > Login Items",
                         button: "Open Settings")
        default:
            // Reachable when registration was attempted and did not take, or
            // when it was turned off on purpose — which simmer does not undo.
            loginRow.set(.off, "Off — no menu bar and no banners after a restart",
                         button: "Enable")
        }
    }

    /// Own file AND capability, difference reported — never adopt a
    /// stranger's grant silently (PLATFORM-FACTS.md).
    private func sudoState(_ completion: @escaping (_ ok: Bool, _ foreign: Bool) -> Void) {
        DispatchQueue.global().async {
            let ownFile = FileManager.default.fileExists(atPath: Self.sudoersPath)
            let capability = SudoRule.grants(inListing:
                                       Shell.run("/usr/bin/sudo", ["-nl"]).stdout).hasSimmersOwn
            completion(ownFile && capability, !ownFile && capability)
        }
    }

    // MARK: actions

    /// Hands the human the command instead of running it. simmer composes it,
    /// shows the rule in full, and copies it — the person reads it and runs it
    /// in their own shell, where they can see exactly what asked for root.
    @objc private func setUpSudo() {
        let alert = NSAlert()
        alert.messageText = "One command, run by you"
        alert.informativeText = """
            simmer needs to flip one switch as root — \
            `pmset -a disablesleep` — and nothing else. This exact rule goes \
            to \(Self.sudoersPath):

            \(Self.sudoersRule)

            simmer does not give itself root. Copy the command, paste it in \
            Terminal, and read it before you run it: it validates the rule \
            with visudo before installing it.
            """
        alert.addButton(withTitle: "Copy the command")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SudoRule.installCommand(user: NSUserName()),
                                       forType: .string)
        sudoRow.set(.warn, "Command copied — paste it in Terminal, then reopen this window",
                    button: "Copy again")
    }

    @objc private func notifyAction() {
        if notifyStatus == .denied {
            // Asking again cannot help: the verdict is cached. Take the human
            // to the one place that can change it.
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
            return
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        // The app is the ONLY place that may request authorization — it is
        // LaunchServices-launched, so the request arrives as a real banner.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                DispatchQueue.main.async { self.refresh() }
            }
    }

    @objc private func enableLoginItem() {
        try? SMAppService.mainApp.register()
        refresh()
    }
}

/// One setup row: status symbol · title · detail — button.
private final class SetupRow {
    enum Status {
        case ok, warn, off, bad
        var symbol: (name: String, color: NSColor) {
            switch self {
            case .ok: return ("checkmark.circle.fill", .systemGreen)
            case .warn: return ("exclamationmark.triangle.fill", .systemYellow)
            case .off: return ("circle", .tertiaryLabelColor)
            case .bad: return ("xmark.circle.fill", .systemRed)
            }
        }
    }

    let view: NSStackView
    let button: NSButton
    private let statusImage = NSImageView()
    private let detailLabel: NSTextField

    init(title: String, buttonTitle: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        button = NSButton(title: buttonTitle, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        statusImage.widthAnchor.constraint(equalToConstant: 20).isActive = true
        statusImage.heightAnchor.constraint(equalToConstant: 20).isActive = true

        view = NSStackView(views: [statusImage, text, NSView(), button])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 10
    }

    func set(_ status: Status, _ detail: String, button title: String?) {
        let (name, color) = status.symbol
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        statusImage.image = image
        statusImage.contentTintColor = color
        detailLabel.stringValue = detail
        if let title {
            button.isHidden = false
            button.title = title
        } else {
            button.isHidden = true
        }
    }
}
