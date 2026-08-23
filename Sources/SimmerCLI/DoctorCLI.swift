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
        // told people to remove a file that never existed (LEARNINGS.md).
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
                check("passwordless pmset rule (missing — the installer prints the exact two lines)", false)
            }
        }

        let bundleBinary = Notify.bundleBinary(env: env)
        if FileManager.default.isExecutableFile(atPath: bundleBinary) {
            let status = Shell.run(bundleBinary, ["notify-post", "--status"])
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check("notifier bundle authorized", status == "authorized")
        } else {
            check("notification fallback (osascript)",
                  FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript"))
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
            print("Anything red above is fixed by re-running the installer — except the")
            print("sudo rule, which needs root and is therefore yours to run. The installer")
            print("prints the exact two-line rule before asking.")
            print("")
        }

        // Which channel is about to be used matters more than a generic
        // warning: they fail for completely different reasons.
        if FileManager.default.isExecutableFile(atPath: bundleBinary) {
            let status = Shell.run(bundleBinary, ["notify-post", "--status"])
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            switch status {
            case "authorized":
                print("Notifications post as \"Simmer\", with simmer's own icon.")
            case "notDetermined":
                print("Simmer's permission banner is pending — click Allow when it appears")
                print("(launching Simmer.app fires it again).")
            default:
                print("Notifications for \"Simmer\" were DENIED. Re-enable in")
                print("System Settings > Notifications > Simmer.")
            }
        } else {
            print("No Simmer.app installed, so banners post as \"Script Editor\".")
            print("Fix: make install (builds and registers the bundle).")
        }
        print("")
        if env.notifyTransport == "none" {
            print("SIMMER_NOTIFY=none — not firing a test banner.")
        } else {
            print("Firing one now.")
            Notify.post(NotificationRequest(title: "simmer doctor",
                                            subtitle: "notifications are working",
                                            body: "This banner is the test."), env: env)
        }
        throw ExitCode(failures > 0 ? 1 : 0)
    }
}
