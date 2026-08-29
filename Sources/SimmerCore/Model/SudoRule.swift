import Foundation

/// The one privileged thing simmer needs, as text — the single source for the
/// app's setup window, `simmer doctor` and `bootstrap.sh`.
///
/// Nothing here executes anything, and nothing in simmer escalates its own
/// privileges. It composes the exact command, shows it in full, and a human
/// runs it in their own shell.
///
/// That is the whole design: an app that asks the system for root and then
/// runs a shell string it built itself is a construct which has to be read
/// very carefully before it can be trusted — for an operation that happens
/// once, in front of a person who is already at a keyboard. A command the
/// human can read before running is smaller, and honest about who decides.
public enum SudoRule {
    public static let path = "/etc/sudoers.d/simmer"

    /// The two invocations simmer makes, and the whole of what it asks for.
    /// The source the capability string is built from, so there is one list
    /// rather than a string and a copy of it that can drift apart.
    public static let commands = [
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset -a disablesleep 0",
    ]

    /// The capability, spelled exactly as sudoers will see it. Scoped to the
    /// two invocations above and nothing else — no wildcard, no other binary,
    /// no other pmset subcommand.
    public static let capability =
        "ALL=(root) NOPASSWD: " + commands.joined(separator: ", ")

    /// The two lines that land in `path`, comment included.
    public static func text(user: String) -> String {
        """
        # simmer — flip the sleep switch without a password; nothing else.
        \(user) \(capability)
        """
    }


    // MARK: reading what sudo actually grants
    //
    /// **`sudo -nl <command>` does not answer the question simmer was asking
    /// it.** It reports whether the command is PERMITTED, not whether it is
    /// permitted without a password — so on any Mac whose user is an admin it
    /// returns 0 through the stock `(ALL) ALL` entry, with or without simmer's
    /// rule. `doctor` therefore reported "the pmset capability is granted, but
    /// not by simmer's own file" on a machine that granted nothing, and
    /// `uninstall` told people to go hunting for a stranger's rule that did
    /// not exist. Measured: `sudo -nv` says there is no timestamp, and
    /// `sudo -nl /bin/sh` still exits 0.
    ///
    /// The listing form — `sudo -nl` with no command — enumerates the rules
    /// themselves, needs no password on macOS, and says which entries carry
    /// NOPASSWD. That is the authoritative answer, and this is its parser.
    /// Nothing here runs sudo; the caller does, and hands the text in.
    public struct Grants: Equatable, Sendable {
        /// Every command granted without a password, in listing order.
        public var passwordless: [String]

        /// Exactly the two simmer asks for are granted.
        public var hasSimmersOwn: Bool {
            SudoRule.commands.allSatisfy(passwordless.contains)
        }

        /// Anything passwordless beyond the two. `ALL` here means a blanket
        /// passwordless root grant, which is the one worth saying out loud.
        public var beyondWhatSimmerNeeds: [String] {
            passwordless.filter { !SudoRule.commands.contains($0) }
        }

        public var hasBlanketGrant: Bool {
            passwordless.contains { $0 == "ALL" || $0.hasSuffix(") ALL") }
        }
    }

    /// Parse `sudo -nl` output. Entries look like
    /// `    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0`
    /// — an optional runas group, then zero or more tags, then a comma-list of
    /// commands. Only the header's own section is read, so the `Defaults`
    /// block above it cannot be mistaken for a rule.
    public static func grants(inListing listing: String) -> Grants {
        var passwordless: [String] = []
        var inRules = false
        for raw in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.contains("may run the following commands") { inRules = true; continue }
            guard inRules else { continue }
            // Rules are indented; anything flush-left starts a new section.
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { inRules = false }
                continue
            }
            var entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            // Drop the runas group, e.g. "(root) " or "(ALL : ALL) ".
            if entry.hasPrefix("("), let close = entry.firstIndex(of: ")") {
                entry = String(entry[entry.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            // Tags run until the last one; NOPASSWD anywhere among them makes
            // the commands that follow passwordless.
            var isPasswordless = false
            while let colon = entry.firstIndex(of: ":") {
                let tag = String(entry[..<colon]).trimmingCharacters(in: .whitespaces)
                guard tag.allSatisfy({ $0.isUppercase || $0 == "_" }), !tag.isEmpty else { break }
                if tag == "NOPASSWD" { isPasswordless = true }
                if tag == "PASSWD" { isPasswordless = false }
                entry = String(entry[entry.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard isPasswordless, !entry.isEmpty else { continue }
            passwordless.append(contentsOf: entry.components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        return Grants(passwordless: passwordless)
    }

    /// A paste-able command that installs the rule, and cannot leave a broken
    /// one behind: the file is written unprivileged, `visudo -c` validates it
    /// BEFORE it is installed, and only then does it land as root-owned 0440.
    /// A malformed file in /etc/sudoers.d can break `sudo` entirely
    /// (PLATFORM-FACTS.md), so validation-before-landing is not optional.
    public static func installCommand(user: String) -> String {
        let rule = text(user: user)
        return "tmp=$(mktemp) && printf '%s\\n' '\(rule)' > \"$tmp\" && "
            + "sudo visudo -c -f \"$tmp\" && "
            + "sudo install -m 0440 -o root -g wheel \"$tmp\" \(path); rm -f \"$tmp\""
    }
}
