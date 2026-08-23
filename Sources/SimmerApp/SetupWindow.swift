import AppKit
import ServiceManagement
import SimmerCore

/// `simmer doctor` made visible: three rows, three buttons, live ticks. The
/// natural home for the privileged step — the riskiest part of onboarding
/// becomes obvious instead of paragraphs in a terminal (DESIGN-NOTES).
final class SetupWindow: NSObject {
    static let shared = SetupWindow()

    private var window: NSWindow?
    private var sudoLabel = NSTextField(labelWithString: "")
    private var notifyLabel = NSTextField(labelWithString: "")
    private var loginLabel = NSTextField(labelWithString: "")

    static let sudoersPath = "/etc/sudoers.d/simmer"

    /// The exact two-line rule, shown in full before it is asked for.
    static var sudoersRule: String {
        let user = NSUserName()
        return """
        # simmer — flip the sleep switch without a password; nothing else.
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
        """
    }

    func show() {
        if window == nil { build() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shown automatically only while something still needs a human.
    func showIfNeeded() {
        sudoState { sudoOK in
            Notifier.shared.authorizationStatus { status in
                DispatchQueue.main.async {
                    if !sudoOK || status != .authorized { self.show() }
                }
            }
        }
    }

    // MARK: the three rows

    private func build() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let title = NSTextField(labelWithString: "Simmer needs three things, once:")
        title.font = .boldSystemFont(ofSize: 13)
        content.addArrangedSubview(title)

        content.addArrangedSubview(row(sudoLabel, "Set up…", #selector(setUpSudo)))
        content.addArrangedSubview(row(notifyLabel, "Ask again", #selector(askNotifications)))
        content.addArrangedSubview(row(loginLabel, "Enable", #selector(enableLoginItem)))

        let hint = NSTextField(wrappingLabelWithString:
            "The sleep switch needs one administrator password to install a two-line "
            + "sudo rule scoped to exactly `pmset -a disablesleep` and nothing else. "
            + "The rule is shown in full before you are asked.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 420
        content.addArrangedSubview(hint)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Simmer Setup"
        window.contentView = content
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
    }

    private func row(_ label: NSTextField, _ buttonTitle: String,
                     _ selector: Selector) -> NSView {
        let button = NSButton(title: buttonTitle, target: self, action: selector)
        let stack = NSStackView(views: [label, NSView(), button])
        stack.orientation = .horizontal
        stack.distribution = .fill
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        return stack
    }

    private func refresh() {
        sudoState { ok, foreign in
            DispatchQueue.main.async {
                self.sudoLabel.stringValue = ok
                    ? "✅ Sleep switch — password-free rule in place"
                    : foreign
                        ? "⚠️ Sleep switch — granted by something else, not simmer's own rule"
                        : "⚠️ Sleep switch — needs one administrator password"
            }
        }
        Notifier.shared.authorizationStatus { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .provisional:
                    self.notifyLabel.stringValue = "✅ Notifications — allowed"
                case .denied:
                    self.notifyLabel.stringValue = "❌ Notifications — denied (System Settings > Notifications > Simmer)"
                default:
                    self.notifyLabel.stringValue = "⚠️ Notifications — waiting for permission"
                }
            }
        }
        let login = SMAppService.mainApp.status == .enabled
        loginLabel.stringValue = login
            ? "✅ Start at login — enabled"
            : "○ Start at login — not enabled"
    }

    private func sudoState(_ completion: @escaping (Bool) -> Void) {
        sudoState { ok, _ in completion(ok) }
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
            // Validate BEFORE installing — a malformed file in /etc/sudoers.d
            // can break sudo entirely (LEARNINGS.md). visudo -c runs inside
            // the same privileged step, gating the install.
            let rule = Self.sudoersRule.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            set -e
            tmp=$(mktemp /private/tmp/simmer-sudoers.XXXXXX)
            printf '%s\\n' "\(rule)" > "$tmp"
            /usr/sbin/visudo -c -f "$tmp" > /dev/null
            /usr/bin/install -m 0440 -o root -g wheel "$tmp" \(Self.sudoersPath)
            rm -f "$tmp"
            """
            let escaped = script
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            _ = Shell.run("/usr/bin/osascript",
                          ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc private func askNotifications() {
        UNUserNotificationCenterShim.requestAgain { self.refresh() }
    }

    @objc private func enableLoginItem() {
        try? SMAppService.mainApp.register()
        refresh()
    }
}

import UserNotifications

enum UNUserNotificationCenterShim {
    static func requestAgain(_ completion: @escaping () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { return completion() }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                DispatchQueue.main.async(execute: completion)
            }
    }
}
