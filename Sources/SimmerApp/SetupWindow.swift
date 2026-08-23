import AppKit
import ServiceManagement
import SimmerCore
import UserNotifications

/// `simmer doctor` made visible: three rows, three buttons, live status. The
/// natural home for the privileged step — the riskiest part of onboarding
/// becomes obvious instead of paragraphs in a terminal (DESIGN-NOTES).
final class SetupWindow: NSObject {
    static let shared = SetupWindow()
    static let sudoersPath = "/etc/sudoers.d/simmer"

    /// The exact two-line rule, shown in full before it is asked for.
    static var sudoersRule: String {
        let user = NSUserName()
        return """
        # simmer — flip the sleep switch without a password; nothing else.
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
        """
    }

    private var window: NSWindow?
    private let sudoRow = SetupRow(title: "Sleep switch", buttonTitle: "Set up…")
    private let notifyRow = SetupRow(title: "Notifications", buttonTitle: "Ask again")
    private let loginRow = SetupRow(title: "Start at login", buttonTitle: "Enable")
    private var notifyStatus: UNAuthorizationStatus = .notDetermined

    func show() {
        if window == nil { build() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shown automatically only while something still needs a human.
    func showIfNeeded() {
        sudoState { ok, _ in
            Notifier.shared.authorizationStatus { status in
                DispatchQueue.main.async {
                    if !ok || status != .authorized { self.show() }
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
            + "“pmset -a disablesleep” and nothing else — shown in full before "
            + "you are asked for your password.")
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
                                     button: "Set up…")
                } else {
                    self.sudoRow.set(.warn, "Needs one administrator password", button: "Set up…")
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
        if SMAppService.mainApp.status == .enabled {
            loginRow.set(.ok, "The menu bar comes back after a restart", button: nil)
        } else {
            loginRow.set(.off, "Not enabled — the launchd guard runs either way", button: "Enable")
        }
    }

    /// Own file AND capability, difference reported — never adopt a
    /// stranger's grant silently (LEARNINGS.md).
    private func sudoState(_ completion: @escaping (_ ok: Bool, _ foreign: Bool) -> Void) {
        DispatchQueue.global().async {
            let ownFile = FileManager.default.fileExists(atPath: Self.sudoersPath)
            let capability = Shell.run("/usr/bin/sudo",
                                       ["-nl", "/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0
            completion(ownFile && capability, !ownFile && capability)
        }
    }

    // MARK: actions

    @objc private func setUpSudo() {
        let alert = NSAlert()
        alert.messageText = "Install simmer's sudo rule?"
        alert.informativeText = "This exact rule, and nothing else, goes to "
            + "\(Self.sudoersPath):\n\n\(Self.sudoersRule)"
        alert.addButton(withTitle: "Install (asks for your password)")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global().async {
            // Written unprivileged, validated with visudo BEFORE it lands —
            // a malformed file in /etc/sudoers.d can break sudo entirely.
            let tmp = "/private/tmp/simmer-sudoers-\(getpid())"
            try? (Self.sudoersRule + "\n").write(toFile: tmp, atomically: true, encoding: .utf8)
            let privileged = "/usr/sbin/visudo -c -f \(tmp) >/dev/null && "
                + "/usr/bin/install -m 0440 -o root -g wheel \(tmp) \(Self.sudoersPath) && "
                + "/bin/rm -f \(tmp)"
            _ = Shell.run("/usr/bin/osascript",
                          ["-e", "do shell script \"\(privileged)\" with administrator privileges"])
            try? FileManager.default.removeItem(atPath: tmp)
            DispatchQueue.main.async { self.refresh() }
        }
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
