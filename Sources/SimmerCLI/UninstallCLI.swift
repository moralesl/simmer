import ArgumentParser
import Foundation
import SimmerCore

/// `simmer uninstall` — closing the loop the one-paste installer opened.
///
/// The documented removal was `make -C ~/.local/share/simmer uninstall`, which
/// asks someone who installed with a single paste to know where the installer
/// put a checkout and that `make` is involved at all. Neither is something the
/// install taught them.
///
/// It composes the commands and shows them rather than running them, which is
/// the pattern `SudoRule` and the setup window already use for the privileged
/// step — and here it also avoids a binary deleting the bundle it is executing
/// from, since `~/.local/bin/simmer` is a symlink into `Simmer.app`.
///
/// It reports what is actually present as it goes, so it doubles as the answer
/// to "what did simmer put on this machine".
struct UninstallCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Show exactly what simmer installed, and the commands that remove it.")

    @OptionGroup var common: CommonOptions

    func run() throws {
        // Instructions for a person. `doctor --json` is the machine-readable
        // account of what is installed and working.
        common.refuseJSON("uninstall", insteadUse: "simmer doctor --json")

        let env = Runtime.environment()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        var outcome = Outcome()

        // Where the installer put the checkout, honouring the same override
        // bootstrap.sh reads, so the two cannot disagree about the path.
        let checkout = env.env["SIMMER_DIR"]
            ?? home.appendingPathComponent(".local/share/simmer").path

        // The bundle this binary is running from, when there is one — a
        // reinstall under a different PREFIX must not send anyone to the wrong
        // Simmer.app. Falls back to where `make install` puts it.
        let app = Self.enclosingAppBundle(of: env.binPath)
            ?? home.appendingPathComponent("Applications/Simmer.app").path

        func mark(_ path: String) -> String {
            fm.fileExists(atPath: path) ? "present" : "not there"
        }

        outcome.stdout.append("simmer installed these, and nothing else:")
        outcome.stdout.append("   \(app)  — \(mark(app))")
        outcome.stdout.append("   \(home.appendingPathComponent(".local/bin/simmer").path)  — \(mark(home.appendingPathComponent(".local/bin/simmer").path))")
        let plist = home.appendingPathComponent(
            "Library/LaunchAgents/\(Runtime.guardLabel).plist").path
        outcome.stdout.append("   \(plist)  — \(mark(plist))")
        outcome.stdout.append("")

        if fm.fileExists(atPath: checkout + "/Makefile") {
            outcome.stdout.append("Remove them — no password needed, it only touches your own files:")
            outcome.stdout.append("")
            outcome.stdout.append("   make -C \(checkout) uninstall")
        } else {
            // The checkout is how `make uninstall` knows what to remove. Gone
            // (or installed some other way), the three paths above are still
            // the whole footprint, so name them rather than a target that
            // cannot run.
            outcome.stdout.append("The checkout that carries the uninstall target is not at \(checkout).")
            outcome.stdout.append("These three lines do the same thing:")
            outcome.stdout.append("")
            outcome.stdout.append("   launchctl bootout gui/$(id -u)/\(Runtime.guardLabel)")
            outcome.stdout.append("   rm -f \(plist) \(home.appendingPathComponent(".local/bin/simmer").path)")
            outcome.stdout.append("   rm -rf \(app)")
        }
        outcome.stdout.append("")

        // Root, and therefore yours. simmer only ever removes what simmer
        // wrote, and it never escalates its own privileges (SECURITY.md).
        if fm.fileExists(atPath: SudoRule.path) {
            outcome.stdout.append("Then the sudo rule, which needs root and so is yours to run:")
            outcome.stdout.append("")
            outcome.stdout.append("   sudo rm \(SudoRule.path)")
        } else {
            outcome.stdout.append("There is no \(SudoRule.path) to remove.")
            // A capability with no file behind it belongs to something else,
            // and telling someone to delete a stranger's grant would be wrong.
            if Shell.run("/usr/bin/sudo",
                         ["-nl", "/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0 {
                outcome.stdout.append("   Something else on this Mac still grants the pmset capability — not simmer's to remove.")
                outcome.stdout.append("   Find it with: sudo grep -rn disablesleep /etc/sudoers /etc/sudoers.d/")
            }
        }
        outcome.stdout.append("")
        outcome.stdout.append("Your state stays put — delete it too if you want the log and the claims gone:")
        outcome.stdout.append("   rm -rf \(env.stateDir.path)")

        Runtime.deliver(outcome)
    }

    /// The `.app` a path sits inside, if any. `~/.local/bin/simmer` is a
    /// symlink into the bundle, and `binPath` deliberately keeps the symlink
    /// unresolved, so resolve it here before walking up.
    static func enclosingAppBundle(of path: String) -> String? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { return url.path }
        }
        return nil
    }
}
