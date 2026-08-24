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

    /// The capability, spelled exactly as sudoers will see it. Scoped to the
    /// two invocations simmer makes and nothing else — no wildcard, no other
    /// binary, no other pmset subcommand.
    public static let capability =
        "ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"

    /// The two lines that land in `path`, comment included.
    public static func text(user: String) -> String {
        """
        # simmer — flip the sleep switch without a password; nothing else.
        \(user) \(capability)
        """
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
