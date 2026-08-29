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

    /// The version `make skill` stamped into the generated protocol.
    /// nil when the marker is absent, which is its own diagnosis.
    static func stampedVersion(in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("simmer-protocol") {
            for field in line.split(separator: " ") where field.hasPrefix("version=") {
                let value = field.dropFirst("version=".count)
                return value.isEmpty ? nil : String(value)
            }
        }
        return nil
    }

    /// The state directory the installed LaunchAgent will actually use: its
    /// own `EnvironmentVariables`, or the default it would fall back to.
    ///
    /// nil when no guard is installed — there is then nothing to disagree
    /// with, and a row about it would be a row about nothing. Uses
    /// `homeDirectoryForCurrentUser` for both the plist path and the fallback
    /// because launchd resolves the agent's `~` from the passwd entry, not
    /// from anybody's exported HOME.
    static func guardLedger() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent(
            "Library/LaunchAgents/\(Runtime.guardLabel).plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        let declared = (root["EnvironmentVariables"] as? [String: String])?["XDG_STATE_HOME"]
        let base = declared.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/state")
        return base.appendingPathComponent("simmer").path
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

        // Both of these are facts about the LaunchAgent installed on THIS Mac,
        // so they are seam-gated the way `app_running` is. Reporting
        // "✅ guard loaded" from the real launchctl during a fully seamed run
        // is an answer about a different machine than the one the rest of the
        // report describes.
        if seamed {
            rows.append(Row(id: "guard_loaded",
                            label: "SIMMER_FAKE_PMSET is set — the guard is not being checked",
                            ok: nil))
        } else {
            let guardLoaded = Shell.run("/bin/launchctl",
                                        ["print", "gui/\(getuid())/\(Runtime.guardLabel)"]).status == 0
            rows.append(Row(id: "guard_loaded",
                            label: "guard loaded (\(Runtime.guardLabel))", ok: guardLoaded))

            // A LaunchAgent inherits nothing from the shell that installed it,
            // so the ledger it reads is whatever its own plist says. When that
            // disagrees with the one this process is using, the two settle the
            // same global switch against each other every thirty seconds and
            // never converge — `down` says "sleep allowed again" and the next
            // tick turns it back on — while every other row here stays green.
            if let theirs = Self.guardLedger() {
                let ours = env.stateDir.path
                rows.append(Row(
                    id: "guard_ledger",
                    label: theirs == ours
                        ? "guard reads the same ledger as this shell"
                        : "guard reads a DIFFERENT ledger — it has \(theirs), this shell has \(ours). Re-run 'make install' from this shell, or unset XDG_STATE_HOME",
                    ok: theirs == ours))
            }
        }

        // The sudoers check looks for simmer's OWN file AND the capability,
        // and reports the difference. Checking only the capability is how the
        // spike silently adopted a grant left by the tool's previous name and
        // told people to remove a file that never existed (PLATFORM-FACTS.md).
        if seamed {
            rows.append(Row(id: "sudo_rule",
                            label: "SIMMER_FAKE_PMSET is set — the sudo rule is not being checked",
                            ok: nil))
        } else {
            let ownFile = FileManager.default.fileExists(atPath: SudoRule.path)
            // The LISTING, not `-nl <command>`. The latter answers whether the
            // command is permitted, not whether it is permitted without a
            // password, so on any admin Mac it returns 0 through the stock
            // `(ALL) ALL` entry — which is how this check reported a grant on
            // a machine that granted nothing. The listing enumerates the rules
            // themselves and needs no password.
            let listing = Shell.run("/usr/bin/sudo", ["-nl"])
            let readable = listing.status == 0
            let grants = SudoRule.grants(inListing: listing.stdout)
            let capability = readable && grants.hasSimmersOwn

            // What the user asked simmer to promise: the grant is the two
            // invocations and nothing else. Informational, never a failure —
            // another tool's passwordless rule is not simmer's to fix, and a
            // permanently red line teaches people to skim the whole report.
            let extra = grants.beyondWhatSimmerNeeds
            if !readable {
                rows.append(Row(
                    id: "sudo_width",
                    label: "could not read what sudo grants ('sudo -nl' failed) — not guessing.",
                    ok: nil,
                    detail: ["Check it by hand: sudo -l"]))
            } else if grants.hasBlanketGrant {
                rows.append(Row(
                    id: "sudo_width",
                    label: "this account can run ANY command as root without a password.",
                    ok: nil,
                    detail: [
                        "That is far wider than the two invocations simmer asks for, and not simmer's doing.",
                        "Find the rule: sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/",
                    ]))
            } else if !extra.isEmpty {
                rows.append(Row(
                    id: "sudo_width",
                    label: "\(extra.count) passwordless grant(s) beyond the two simmer asks for.",
                    ok: nil,
                    detail: extra.map { "  \($0)" }
                        + ["Find them: sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/"]))
            } else if capability {
                rows.append(Row(id: "sudo_width",
                                label: "the passwordless grant is exactly the two simmer asks for",
                                ok: true))
            }

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
            case (true, false) where !readable:
                rows.append(Row(
                    id: "sudo_rule",
                    label: "/etc/sudoers.d/simmer exists; whether sudo honours it could not be read.",
                    ok: nil))
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
        // Both halves: the pid is still a process, AND the heartbeat behind it
        // is recent. The pid alone vouches for whatever holds that pid now
        // (Ledger.AppStatus.heartbeatIsFresh).
        let appRunning = appStatus.map {
            Shell.run("/bin/ps", ["-p", String($0.pid)]).status == 0
                && $0.heartbeatIsFresh(now: ctx.now)
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
            // Read from the heartbeat for the same reason `notify` is: only the
            // app can answer it, and this executable asking would learn about
            // the wrong subject.
            //
            // Off is reported, never red. The guard hands the switch back
            // either way, so nothing here is broken — what is lost is the menu
            // bar and every banner after the next restart, which is worth a
            // line precisely because nothing else would ever mention it. A
            // permanently red row teaches people to skim the whole report.
            switch appStatus.login {
            case "enabled":
                rows.append(Row(id: "login_item",
                                label: "opens at login (menu bar and banners survive a restart)",
                                ok: nil))
            case "requiresApproval":
                rows.append(Row(id: "login_item",
                                label: "opens at login — waiting for your approval in System Settings > Login Items",
                                ok: nil))
            case "unknown":
                break
            default:
                rows.append(Row(
                    id: "login_item",
                    label: "does NOT open at login — after a restart there is no menu bar and no banners until you open Simmer. The guard still works. Enable it in Simmer's setup window.",
                    ok: nil))
            }
        }

        // Created 0700/0600, and nothing re-tightens a directory that already
        // existed — so the mode is worth reporting rather than assuming. A
        // reason carries customer and project names and the log keeps every
        // one of them, dated. Informational: a wider mode is the user's to
        // decide about, and a permanently red row teaches people to skim.
        if let mode = (try? FileManager.default.attributesOfItem(
            atPath: ctx.ledger.stateDir.path))?[.posixPermissions] as? Int, mode & 0o077 != 0 {
            rows.append(Row(
                id: "state_mode",
                label: String(format: "state directory is mode %03o — readable beyond you.", mode),
                ok: nil,
                detail: ["Tighten it: chmod -R go-rwx \(ctx.ledger.stateDir.path)"]))
        }

        rows.append(Row(id: "claims_writable", label: "claims directory writable",
                        ok: FileManager.default.isWritableFile(atPath: ctx.ledger.claimsDir.path)))

        // Writable was the only thing asked about what is IN there, and both
        // defects that held a Mac awake indefinitely were shapes in this
        // directory — one of them for ten simulated days under a green report.
        // A file nothing can act on is a failure: it is the exact state where
        // every other surface still says fine.
        let unsound = ctx.ledger.unsoundClaimFiles()
        if unsound.isEmpty {
            rows.append(Row(id: "claims_sound",
                            label: "every claim file is one its owner can address", ok: true))
        } else {
            rows.append(Row(
                id: "claims_sound",
                label: "\(unsound.count) file(s) in the claims directory that no owner can release.",
                ok: false,
                detail: unsound.map { "  \($0.name) — \($0.why)" }
                    + ["End them with: simmer down --all   (a person's command)"]))
        }

        // The agent protocol, which is the one installed thing whose going
        // stale is completely silent: agents keep reading it and it keeps
        // looking fine. Never red — an out-of-date document is not a broken
        // install, and a permanently red row teaches people to skim the report
        // (the same reasoning as `login_item` and `cap` above).
        //
        // Omitted entirely where there is no ~/.claude: `make install` does not
        // create it, so reporting on a protocol this Mac was never going to
        // have would be a line about nothing.
        if FileManager.default.fileExists(atPath: env.claudeHome.path) {
            let skill = env.skillDir.appendingPathComponent("SKILL.md")
            let installerSkill = "make -C \(installerHint) skill"
            if let text = try? String(contentsOf: skill, encoding: .utf8) {
                switch Self.stampedVersion(in: text) {
                case Runtime.version:
                    rows.append(Row(id: "agent_protocol",
                                    label: "agent protocol installed and current (\(Runtime.version))",
                                    ok: true))
                case .some(let stale):
                    rows.append(Row(
                        id: "agent_protocol",
                        label: "agent protocol is from simmer \(stale); this is \(Runtime.version).",
                        ok: nil,
                        detail: [
                            "Agents on this Mac are reading the older protocol. Regenerate:",
                            "  \(installerSkill)",
                        ]))
                case nil:
                    rows.append(Row(
                        id: "agent_protocol",
                        label: "agent protocol present, but not generated by simmer — no version stamp.",
                        ok: nil,
                        detail: [
                            "Hand-edited, or written by a simmer older than the stamp. Replace it:",
                            "  \(installerSkill)",
                        ]))
                }
            } else {
                rows.append(Row(
                    id: "agent_protocol",
                    label: "agent protocol not installed — agents here do not know the claim rules.",
                    ok: nil,
                    detail: ["  \(installerSkill)"]))
            }
        }

        // 60s of grace is a deliberate choice a human can make; five minutes
        // is a laptop that walks away unlocked.
        let lockDelay = ctx.power.lockDelaySeconds()
        rows.append(Row(id: "lock_delay", label: "screen locks within 60s of lid close",
                        ok: (lockDelay ?? 999) <= 60))

        // Informational, never red: a passed cap is a human decision working
        // as intended, and a permanently red line teaches people to skim.
        if let cap = ctx.ledger.readCap(now: ctx.now) {
            rows.append(Row(
                id: "cap",
                label: cap.until <= ctx.now
                    ? "the cap (\(Formats.hhmm(cap.until))) has passed — nothing new until it lifts itself at \(Formats.hhmm(cap.expires))"
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
