import ArgumentParser
import Foundation
import SimmerCore

/// Runtime checks only: doctor is the installed binary talking about the
/// running system, so it works with no repo checked out.
struct DoctorCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Is everything wired up? Guard, sudo rule, notifications — fires a test banner.")

    @OptionGroup var common: CommonOptions

    func run() throws {
        let env = Runtime.environment()
        let ctx = Runtime.context(ownerFlag: common.owner)
        // Where bootstrap.sh puts the checkout. doctor is the installed binary
        // talking about the running system, so it cannot assume a repo — but
        // it can name the one path the installer always uses.
        let installerHint = "~/.local/share/simmer"
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            print("\(ok ? "✅" : "❌") \(label)")
            if !ok { failures += 1 }
        }

        print("simmer \(Runtime.version)")
        print("===================")

        let guardLoaded = Shell.run("/bin/launchctl",
                                    ["print", "gui/\(getuid())/\(Runtime.guardLabel)"]).status == 0
        check("guard loaded (\(Runtime.guardLabel))", guardLoaded)

        // The sudoers check looks for simmer's OWN file AND the capability,
        // and reports the difference. Checking only the capability is how the
        // spike silently adopted a grant left by the tool's previous name and
        // told people to remove a file that never existed (PLATFORM-FACTS.md).
        if env.env["SIMMER_FAKE_PMSET"] != nil {
            print("ℹ️  SIMMER_FAKE_PMSET is set — the sudo rule is not being checked")
        } else {
            let ownFile = FileManager.default.fileExists(atPath: "/etc/sudoers.d/simmer")
            // -nl asks whether the command is *allowed*, without running it
            // and without ever prompting.
            let capability = Shell.run("/usr/bin/sudo",
                                       ["-nl", "/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0
            switch (ownFile, capability) {
            case (true, true):
                check("passwordless pmset rule (/etc/sudoers.d/simmer)", true)
            case (false, true):
                print("⚠️  the pmset capability is granted, but not by simmer's own file.")
                print("    Something else grants it — find it: sudo grep -rn disablesleep /etc/sudoers.d/")
                print("    Not adopting it. Install simmer's own rule: see the README's install step.")
            case (true, false):
                check("passwordless pmset rule (/etc/sudoers.d/simmer exists but sudo refuses — run 'sudo visudo -c')", false)
            case (false, false):
                check("passwordless pmset rule (missing — the command to install it is below)", false)
            }
        }

        // The app's heartbeat, never UNUserNotificationCenter from here: this
        // executable would be told about its own never-granted state
        // (PLATFORM-FACTS.md — that misread cost a wrong diagnosis once already).
        let appStatus = ctx.ledger.readAppStatus()
        let appRunning = appStatus.map {
            Shell.run("/bin/ps", ["-p", String($0.pid)]).status == 0
        } ?? false
        check("Simmer.app running (posts every banner, draws the menu bar)", appRunning)
        if appRunning, let appStatus {
            check("notifications authorized for Simmer", appStatus.notify == "authorized")
        }

        check("claims directory writable",
              FileManager.default.isWritableFile(atPath: ctx.ledger.claimsDir.path))

        // 60s of grace is a deliberate choice a human can make; five minutes
        // is a laptop that walks away unlocked.
        let lockDelay = ctx.power.lockDelaySeconds()
        check("screen locks within 60s of lid close", (lockDelay ?? 999) <= 60)

        // Informational, never red: a passed cap is a human decision working
        // as intended, and a permanently red line teaches people to skim.
        if let cap = ctx.ledger.readCap() {
            if cap.until <= ctx.now {
                print("ℹ️  the cap (\(Formats.hhmm(cap.until))) has passed — nothing new can be claimed until 'simmer cap off'")
            } else {
                print("ℹ️  cap in force: nothing past \(Formats.hhmm(cap.until))")
            }
        }

        print("")
        print("State:")
        for line in Commands.status(mode: .human, ctx: ctx).stdout { print("  \(line)") }
        print("  (machine-readable: simmer status --json · simmer budget --json)")
        print("")

        if failures > 0 {
            print("Anything red above is fixed by re-running the installer:")
            print("  make -C \(installerHint) install")
            print("")
            // The sudo rule is the one thing simmer will not do for you: it
            // needs root, and simmer never escalates its own privileges. So
            // print the command in full rather than describing it — a rule
            // someone can read before running is the whole point (SudoRule).
            if env.env["SIMMER_FAKE_PMSET"] == nil,
               !FileManager.default.fileExists(atPath: SudoRule.path) {
                print("The sudo rule needs root, so it is yours to run. This exact rule:")
                print("")
                for line in SudoRule.text(user: NSUserName()).split(separator: "\n") {
                    print("    \(line)")
                }
                print("")
                print("installs with (validates before it lands, so a typo cannot break sudo):")
                print("")
                print("    \(SudoRule.installCommand(user: NSUserName()))")
                print("")
            }
        }

        // The exact state matters more than a generic warning: pending and
        // denied fail for completely different reasons, with different fixes.
        if !appRunning {
            print("Simmer.app is not running, so no banners at all — simmer never")
            print("borrows another app's identity. Fix: open -a Simmer (or make install).")
        } else {
            switch appStatus?.notify {
            case "authorized":
                print("Notifications post as \"Simmer\", with simmer's own icon.")
            case "notDetermined":
                print("Simmer's permission banner is pending — open -a Simmer and click")
                print("Allow when it appears. Until then, no banners: simmer posts under")
                print("its own name or not at all.")
            default:
                print("Notifications for \"Simmer\" were DENIED. Re-enable in")
                print("System Settings > Notifications > Simmer. Until then, no banners:")
                print("simmer posts under its own name or not at all.")
            }
        }
        print("")
        if env.notifyTransport == "none" {
            print("SIMMER_NOTIFY=none — not queuing a test banner.")
        } else {
            print("Queuing one now — the app posts it within a few seconds.")
            Runtime.emit({
                var outcome = Outcome()
                outcome.notifications.append(NotificationRequest(
                    title: "simmer doctor",
                    subtitle: "notifications are working",
                    body: "This banner is the test."))
                return outcome
            }())
        }
        throw ExitCode(failures > 0 ? 1 : 0)
    }
}
