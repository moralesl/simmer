import Foundation

/// The second privileged thing simmer asks for, as text — the single source
/// for `doctor`, `uninstall` and `bootstrap.sh`, exactly as `SudoRule` is for
/// the sudoers rule.
///
/// `pmset -a disablesleep` survives a reboot (PLATFORM-FACTS.md), and the
/// guard that puts it back is a LaunchAgent in one user's login session. So
/// between a reboot and that login nothing on the Mac can hand the switch
/// back: a crash during a claim, then a restart, left the machine awake at the
/// login window with the lid closed for as long as nobody logged in. This
/// daemon is the one line that closes that gap — it runs once at boot, before
/// any login, and puts the switch back. A claim that is still live is restored
/// by the user's guard at login, which is what the ledger says should happen.
///
/// It is not a second guard: it holds no opinion about claims, ticks on
/// nothing, and never turns the switch ON. It is `RunAtLoad` and nothing else.
///
/// Nothing here executes anything, and nothing in simmer escalates its own
/// privileges: the plist is shown in full and a human installs it, in the same
/// `sudo` session as the sudoers rule.
public enum BootHeal {
    public static let label = "io.github.moralesl.simmer.boot-heal"

    /// System domain, so launchd runs it at boot with no user logged in.
    public static let path = "/Library/LaunchDaemons/\(label).plist"

    /// The whole of what the daemon does. The same invocation the sudoers rule
    /// already grants, run as root by launchd instead.
    public static let command = ["/usr/bin/pmset", "-a", "disablesleep", "0"]

    /// The plist, line by line. No `KeepAlive`, no `StartInterval`: once, at
    /// load, which for a daemon is boot. `launchctl bootstrap` is deliberately
    /// not part of installing it — that would run the heal immediately, under
    /// a claim that may be live, and the user's guard would then spend a tick
    /// putting the switch back. Loaded at the next boot is exactly its job.
    public static let plistLines: [String] = [
        #"<?xml version="1.0" encoding="UTF-8"?>"#,
        #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
        #"<plist version="1.0">"#,
        "<dict>",
        "\t<key>Label</key>",
        "\t<string>\(label)</string>",
        "\t<key>ProgramArguments</key>",
        "\t<array>",
    ] + command.map { "\t\t<string>\($0)</string>" } + [
        "\t</array>",
        "\t<key>RunAtLoad</key>",
        "\t<true/>",
        "</dict>",
        "</plist>",
    ]

    public static var plist: String { plistLines.joined(separator: "\n") + "\n" }

    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// A paste-able command that installs the daemon and cannot leave a broken
    /// one behind: written unprivileged, `plutil -lint` validates it BEFORE it
    /// lands, and only then does it land root-owned 0644 — the ownership and
    /// mode launchd requires before it will load anything from that directory.
    public static var installCommand: String {
        let quoted = plistLines.map(shellQuoted).joined(separator: " ")
        return "tmp=$(mktemp) && printf '%s\\n' \(quoted) > \"$tmp\" && "
            + "plutil -lint \"$tmp\" && "
            + "sudo install -m 0644 -o root -g wheel \"$tmp\" \(path); rm -f \"$tmp\""
    }

    /// One shell word, whatever the text: single-quoted, with any single quote
    /// inside it spelled `'\''` (close, escaped quote, reopen). No plist line
    /// carries one today, and a future label or comment that did would
    /// otherwise break the one-liner at the shell level — silently, into a
    /// plist that is not this one.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Removal needs root too, so these are shown, never run — like the rule.
    public static let removeCommands = [
        "sudo launchctl bootout system/\(label)",
        "sudo rm \(path)",
    ]
}
