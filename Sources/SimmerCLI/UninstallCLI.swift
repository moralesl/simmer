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
        let ctx = Runtime.context(ownerFlag: common.owner)
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

        // The agent skill, listed only where it exists. It is written by
        // `make install` ONLY on a Mac that already has ~/.claude, so naming it
        // as "not there" everywhere else would imply simmer tried and failed.
        let skill = home.appendingPathComponent(".claude/skills/simmer").path
        let skillInstalled = fm.fileExists(atPath: skill)
        if skillInstalled {
            outcome.stdout.append("   \(skill)  — present (the agent protocol, generated from AGENTS.md)")
        }
        outcome.stdout.append("")

        if fm.fileExists(atPath: checkout + "/Makefile") {
            outcome.stdout.append("Remove them — no password needed, it only touches your own files:")
            outcome.stdout.append("")
            outcome.stdout.append("   make -C \(checkout) uninstall")
        } else {
            // The checkout is how `make uninstall` knows what to remove. Gone
            // (or installed some other way), the paths above are still the
            // whole footprint, so name them rather than a target that cannot
            // run.
            outcome.stdout.append("The checkout that carries the uninstall target is not at \(checkout).")
            outcome.stdout.append("These lines do the same thing:")
            outcome.stdout.append("")
            outcome.stdout.append("   launchctl bootout gui/$(id -u)/\(Runtime.guardLabel)")
            outcome.stdout.append("   rm -f \(plist) \(home.appendingPathComponent(".local/bin/simmer").path)")
            outcome.stdout.append("   rm -rf \(app)\(skillInstalled ? " \(skill)" : "")")
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
            //
            // Read from the LISTING. `sudo -nl <command>` answers whether the
            // command is permitted, not whether it is permitted without a
            // password, so through the stock `(ALL) ALL` entry it said yes on
            // every admin Mac — and this sentence sent people hunting for a
            // grant that was never there.
            let listing = Shell.run("/usr/bin/sudo", ["-nl"])
            if listing.status == 0,
               SudoRule.grants(inListing: listing.stdout).hasSimmersOwn {
                outcome.stdout.append("   Something else on this Mac still grants the pmset capability — not simmer's to remove.")
                outcome.stdout.append("   Find it with: sudo grep -rn disablesleep /etc/sudoers /etc/sudoers.d/")
            }
        }
        outcome.stdout.append("")
        outcome.stdout.append("Your state stays put — delete it too if you want the log and the claims gone:")
        outcome.stdout.append("   rm -rf \(env.stateDir.path)")

        // Removing simmer removes every mechanism on this Mac that can put the
        // sleep switch back, and the switch has no expiry, no indicator, and
        // survives reboots (PLATFORM-FACTS.md). `make uninstall` hands the
        // machine back first and refuses to continue if it could not — but
        // someone following the raw commands above skips that, so the last
        // word here is the one that gets them out of it either way.
        outcome.stdout.append("")
        if ctx.power.sleepDisabled() {
            outcome.stdout.append("⚠️  Right now this Mac is being held awake. Hand it back BEFORE removing")
            outcome.stdout.append("   simmer, or nothing here will be able to afterwards:")
            outcome.stdout.append("")
            outcome.stdout.append("   simmer down --all")
        } else {
            outcome.stdout.append("Nothing is holding the Mac awake, so it is a safe moment to remove it.")
        }
        outcome.stdout.append("   If sleep ever stops working after this: sudo pmset -a disablesleep 0")

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
