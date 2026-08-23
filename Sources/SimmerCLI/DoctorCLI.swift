import ArgumentParser
import Foundation
import SimmerCore

/// Runtime checks only: doctor is the installed binary talking about the
/// running system, so it works with no repo checked out.
///
/// Every check lands in `rows` before anything is printed, so the human report
/// and `--json` are two renderings of one list rather than two lists that can
/// disagree about what was checked.
struct DoctorCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Is everything wired up? Guard, sudo rule, notifications — fires a test banner.")

    @OptionGroup var common: CommonOptions

    /// A check, or a line that is deliberately *not* a check. The distinction
    /// is load-bearing: a report where a permanently-red line sits next to a
    /// real failure teaches the reader to skim both.
    struct Row {
        /// Stable machine key. Snake case, append-only, like every other
        /// machine field.
        let id: String
        let label: String
        /// nil = informational, never counted as a failure.
        let ok: Bool?
        /// Extra human lines, printed under the label.
        var detail: [String] = []
    }

    func run() throws {
        let env = Runtime.environment()
        let ctx = Runtime.context(ownerFlag: common.owner)
        // Where bootstrap.sh puts the checkout. doctor is the installed binary
        // talking about the running system, so it cannot assume a repo — but
        // it can name the one path the installer always uses.
        let installerHint = "~/.local/share/simmer"
        let seamed = env.env["SIMMER_FAKE_PMSET"] != nil
        var rows: [Row] = []

        let guardLoaded = Shell.run("/bin/launchctl",
                                    ["print", "gui/\(getuid())/\(Runtime.guardLabel)"]).status == 0
        rows.append(Row(id: "guard_loaded",
                        label: "guard loaded (\(Runtime.guardLabel))", ok: guardLoaded))

        // The sudoers check looks for simmer's OWN file AND the capability,
        // and reports the difference. Checking only the capability is how the
        // spike silently adopted a grant left by the tool's previous name and
        // told people to remove a file that never existed (PLATFORM-FACTS.md).
        if seamed {
            rows.append(Row(id: "sudo_rule",
                            label: "SIMMER_FAKE_PMSET is set — the sudo rule is not being checked",
                            ok: nil))
        } else {
            let ownFile = FileManager.default.fileExists(atPath: "/etc/sudoers.d/simmer")
            // -nl asks whether the command is *allowed*, without running it
            // and without ever prompting.
            let capability = Shell.run("/usr/bin/sudo",
                                       ["-nl", "/usr/bin/pmset", "-a", "disablesleep", "0"]).status == 0
            switch (ownFile, capability) {
            case (true, true):
                rows.append(Row(id: "sudo_rule",
                                label: "passwordless pmset rule (/etc/sudoers.d/simmer)", ok: true))
            case (false, true):
                rows.append(Row(
                    id: "sudo_rule",
                    label: "the pmset capability is granted, but not by simmer's own file.",
                    ok: nil,
                    detail: [
                        "Something else grants it — find it: sudo grep -rn disablesleep /etc/sudoers.d/",
                        "Not adopting it. Install simmer's own rule: see the README's install step.",
                    ]))
            case (true, false):
                rows.append(Row(
                    id: "sudo_rule",
                    label: "passwordless pmset rule (/etc/sudoers.d/simmer exists but sudo refuses — run 'sudo visudo -c')",
                    ok: false))
            case (false, false):
                rows.append(Row(
                    id: "sudo_rule",
                    label: "passwordless pmset rule (missing — the command to install it is below)",
                    ok: false))
            }
        }

        // The app's heartbeat, never UNUserNotificationCenter from here: this
        // executable would be told about its own never-granted state
        // (PLATFORM-FACTS.md — that misread cost a wrong diagnosis once already).
        let appStatus = ctx.ledger.readAppStatus()
        let appRunning = appStatus.map {
            Shell.run("/bin/ps", ["-p", String($0.pid)]).status == 0
        } ?? false
        // Under the seam there is no app and there is not meant to be one: a
        // hermetic sandbox and CI would otherwise report a permanent failure
        // for a component the test deliberately did not install, which makes
        // `doctor` the one command that can never be green. Informational
        // there, a real check on a real machine.
        rows.append(Row(id: "app_running",
                        label: seamed
                            ? "Simmer.app not expected under SIMMER_FAKE_PMSET — not checked"
                            : "Simmer.app running (posts every banner, draws the menu bar)",
                        ok: seamed ? nil : appRunning))
        if appRunning, let appStatus {
            rows.append(Row(id: "notifications_authorized",
                            label: "notifications authorized for Simmer",
                            ok: appStatus.notify == "authorized"))
        }

        rows.append(Row(id: "claims_writable", label: "claims directory writable",
                        ok: FileManager.default.isWritableFile(atPath: ctx.ledger.claimsDir.path)))

        // 60s of grace is a deliberate choice a human can make; five minutes
        // is a laptop that walks away unlocked.
        let lockDelay = ctx.power.lockDelaySeconds()
        rows.append(Row(id: "lock_delay", label: "screen locks within 60s of lid close",
                        ok: (lockDelay ?? 999) <= 60))

        // Informational, never red: a passed cap is a human decision working
        // as intended, and a permanently red line teaches people to skim.
        if let cap = ctx.ledger.readCap() {
            rows.append(Row(
                id: "cap",
                label: cap.until <= ctx.now
                    ? "the cap (\(Formats.hhmm(cap.until))) has passed — nothing new can be claimed until 'simmer cap off'"
                    : "cap in force: nothing past \(Formats.hhmm(cap.until))",
                ok: nil))
        }

        let failures = rows.filter { $0.ok == false }.count

        if common.json {
            let checks = rows.map { row in
                JSONValue.object([
                    ("id", .string(row.id)),
                    ("label", .string(row.label)),
                    // null for informational — a reader must be able to tell
                    // "not applicable here" from "fine", which is the whole
                    // reason this row type has three states and not two.
                    ("ok", row.ok.map { JSONValue.bool($0) } ?? .null),
                ])
            }
            var appNotify = "unknown"
            if let appStatus, appRunning { appNotify = appStatus.notify }
            else if !appRunning { appNotify = "app_not_running" }
            Runtime.deliver({
                var outcome = Outcome()
                outcome.stdout = [JSONValue.object([
                    ("healthy", .bool(failures == 0)),
                    ("failures", .int(failures)),
                    ("version", .string(Runtime.version)),
                    ("seam_active", .bool(seamed)),
                    ("app_running", .bool(appRunning)),
                    ("notify", .string(appNotify)),
                    ("checks", .array(checks)),
                    ("status", Commands.statusObject(ctx: ctx)),
                ]).serialized()]
                outcome.exit = Int32(failures > 0 ? 1 : 0)
                return outcome
            }())
        }

        print("simmer \(Runtime.version)")
        print("===================")
        for row in rows {
            switch row.ok {
            case .some(true): print("✅ \(row.label)")
            case .some(false): print("❌ \(row.label)")
            case .none: print("ℹ️  \(row.label)")
            }
            for line in row.detail { print("    \(line)") }
        }

        print("")
        print("State:")
        for line in Commands.status(mode: .human, ctx: ctx).stdout { print("  \(line)") }
        print("  (machine-readable: simmer status --json · simmer budget --json · simmer doctor --json)")
        print("")

        if failures > 0 {
            print("Anything red above is fixed by re-running the installer:")
            print("  make -C \(installerHint) install")
            print("")
            // The sudo rule is the one thing simmer will not do for you: it
            // needs root, and simmer never escalates its own privileges. So
            // print the command in full rather than describing it — a rule
            // someone can read before running is the whole point (SudoRule).
            if !seamed, !FileManager.default.fileExists(atPath: SudoRule.path) {
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
