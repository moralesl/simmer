import ArgumentParser
import Foundation
import SimmerCore

/// Shared by every subcommand: the contract requires each command reachable
/// from a launcher to tolerate a trailing `-r <reason> --owner <name>`,
/// whether or not it has a use for either.
struct CommonOptions: ParsableArguments {
    @Option(name: [.customShort("r"), .customLong("reason")],
            help: "What this is for; shown in the menu bar and the log.")
    var reason: String?

    @Option(name: .customLong("owner"),
            help: "Who is asking. Names your claim; agents: --owner agent:<work>.")
    var owner: String?

    @Flag(name: .customLong("json"), help: "One JSON object instead of prose.")
    var json = false

    /// For the two commands that have no machine answer. Accepting `--json`
    /// and then ignoring it is the worst of the three options: the caller
    /// cannot tell it from a flag that worked, which is how `--help` came to
    /// promise a surface that four commands did not have.
    func refuseJSON(_ command: String, insteadUse alternative: String) {
        guard json else { return }
        Runtime.deliver(.failure(
            "\(command) has no JSON form — its output is for a person. Use \(alternative).",
            json: false))
    }
}

struct SimmerRoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simmer",
        abstract: "Keeps this Mac awake for a bounded time — lid closed — then lets it sleep again.",
        subcommands: [ClaimCLI.self, ExtendCLI.self, ReleaseCLI.self, CapCLI.self,
                      StatusCLI.self, BudgetCLI.self, RunCLI.self, GuardCLI.self,
                      DoctorCLI.self, LogCLI.self, RenderCLI.self, NotifyTestCLI.self,
                      UninstallCLI.self]
    )
}

// MARK: claim

struct ClaimCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claim",
        abstract: "Claim awake time (or replace your own claim). `simmer 2h` is sugar for this.")

    @Argument(help: "How long: 90, 90m, 2h, 1h30m — or 'forever'.")
    var duration: String?

    @Option(name: .customLong("until"), help: "An absolute time, HH:MM, instead of a length.")
    var until: String?

    // Taken as text and validated below, exactly as `budget --need` is. Left
    // as an Int, ArgumentParser diagnoses a bad value in its own voice, prints
    // a usage block naming the internal `simmer claim` spelling nobody typed,
    // and — the part that matters — writes nothing to stdout, so a `--json`
    // caller gets an empty stream instead of the contracted refusal object.
    @Option(name: .customLong("min-battery"),
            help: "Release below this battery percentage, 0–100 (on battery only).")
    var minBattery: String?

    @Flag(name: .customLong("require-ac"),
          help: "End the claim the moment the charger is unplugged.")
    var requireAC = false

    @Flag(name: .customLong("display-on"), help: "Keep the screen lit too.")
    var displayOn = false

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: .hidden) // accepted and inert — claims cannot collide
    var force = false

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = Runtime.context(ownerFlag: common.owner)
        let forever = duration == "forever"
        var floor = Claim.defaultMinBattery
        if let minBattery {
            // A floor outside 0–100 is not a battery level, so it is refused
            // for what it is rather than surviving to be compared against one
            // ("battery 80% <= floor 200%" described the wrong problem).
            guard let value = Int(minBattery), (0...100).contains(value) else {
                Runtime.deliver(.failure(
                    "--min-battery wants a whole percentage, 0–100: \(minBattery)",
                    json: common.json))
            }
            floor = value
        }
        let input = ClaimInput(
            durationText: forever ? nil : duration,
            untilText: until,
            forever: forever,
            reason: common.reason ?? "",
            minBattery: floor,
            requireAC: requireAC,
            displayOn: displayOn,
            force: force,
            json: common.json)
        Runtime.deliver(Commands.claim(input, ctx: ctx))
    }
}

// MARK: extend

struct ExtendCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extend",
        abstract: "Move YOUR claim's deadline: +20m means 20 minutes from now.")

    @Argument(help: "How much more, counted from now: 20m, +1h …")
    var duration: String?

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = Runtime.context(ownerFlag: common.owner)
        guard let duration, !duration.isEmpty, duration != "+" else {
            Runtime.deliver(.failure("extend by how much? 'simmer +20m'", json: common.json))
        }
        Runtime.deliver(Commands.extend(duration, json: common.json, ctx: ctx))
    }
}

// MARK: release

struct ReleaseCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Hand YOUR claim back. `simmer down` is the everyday spelling.")

    @Flag(name: .customLong("all"), help: "Hand everything back (humans only).")
    var all = false

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = Runtime.context(ownerFlag: common.owner)
        Runtime.deliver(Commands.release(all: all, json: common.json, ctx: ctx))
    }
}

// MARK: cap

struct CapCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cap",
        abstract: "The human ceiling: nothing past HH:MM, whoever asks. 'cap off' lifts it.")

    @Argument(help: "HH:MM, a duration, or 'off'. Empty: report the cap.")
    var value: String?

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = Runtime.context(ownerFlag: common.owner)
        Runtime.deliver(Commands.cap(value, json: common.json, ctx: ctx))
    }
}

// MARK: status

struct StatusCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Every live claim, and when the machine actually sleeps. Bare `simmer` does this.")

    @Flag(name: .customLong("machine"), help: "Flat key=value lines.")
    var machine = false

    @Flag(name: .customLong("porcelain"), help: .hidden) // kept, undocumented
    var porcelain = false

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = Runtime.context(ownerFlag: common.owner)
        let mode: StatusMode = common.json ? .json : ((machine || porcelain) ? .machine : .human)
        Runtime.deliver(Commands.status(mode: mode, ctx: ctx))
    }
}

// MARK: budget

struct BudgetCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "budget",
        abstract: "Room to start something? Exit 0 fits · 1 not enough · 3 nothing claimed at all.")

    @Option(name: .customLong("need"), help: "Does this much still fit before the deadline?")
    var need: String?

    @Flag(name: .customLong("seconds"), help: "Bare seconds left (-1 = no deadline).")
    var seconds = false

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = Runtime.context(ownerFlag: common.owner)
        var needSeconds = 0
        if let need {
            guard let parsed = Durations.parse(need) else {
                Runtime.deliver(.failure("did not understand the duration: \(need)", json: common.json))
            }
            needSeconds = parsed
        }
        Runtime.deliver(Commands.budget(needSeconds: needSeconds, bareSeconds: seconds,
                                        json: common.json, ctx: ctx))
    }
}

// MARK: guard

struct GuardCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guard",
        abstract: "One guard pass: retire what is over, settle the switch. Runs under launchd.")

    @OptionGroup var common: CommonOptions

    func run() throws {
        // Unattended: must never prompt for a password — sudo -n or nothing.
        let ctx = Runtime.context(ownerFlag: common.owner, interactive: false)
        Runtime.deliver(Tick.run(ctx: ctx))
    }
}

// MARK: log

struct LogCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log", abstract: "What the guard has actually done.")

    @Argument(help: "How many lines (default 20).")
    var count: Int = 20

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = Runtime.context(ownerFlag: common.owner)
        Runtime.deliver(Commands.logTail(count, json: common.json, ctx: ctx))
    }
}

// MARK: render

struct RenderCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Draw a launcher surface from the ledger: swiftbar, raycast or alfred.")

    @Argument(help: "swiftbar | raycast | alfred")
    var surface: String

    @Argument(parsing: .remaining, help: "Query text (alfred).")
    var query: [String] = []

    @OptionGroup var common: CommonOptions

    func run() throws {
        // render's surfaces ARE its machine output — swiftbar, raycast and
        // alfred each have their own contract. A fourth one nobody asked for
        // would be the drift the append-only rule exists to stop.
        common.refuseJSON("render", insteadUse: "simmer status --json")
        let ctx = Runtime.context(ownerFlag: common.owner)
        Runtime.deliver(Commands.render(surface: surface,
                                        query: query.joined(separator: " "), ctx: ctx))
    }
}

// MARK: notify-test

struct NotifyTestCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify-test",
        abstract: "Queue one test banner for the app — Simmer is the only identity that posts.")

    @OptionGroup var common: CommonOptions

    func run() throws {
        // A diagnostic whose whole output is an explanation of what to click.
        // `doctor --json` is the machine-readable health answer.
        common.refuseJSON("notify-test", insteadUse: "simmer doctor --json")
        let ctx = Runtime.context(ownerFlag: common.owner)
        // The app is the only poster (its executable holds the grant), so the
        // honest test is: enqueue, then report what the app last said about
        // itself — never ask UNUserNotificationCenter from this process,
        // which would be told about ITS OWN never-granted state.
        ctx.ledger.enqueueNotification(NotificationRequest(
            title: "simmer notify-test",
            subtitle: "notifications are working",
            body: "This banner is the test — pot icon, buttons and all.",
            actionable: true), now: ctx.now)

        guard let status = ctx.ledger.readAppStatus(),
              Shell.run("/bin/ps", ["-p", String(status.pid)]).status == 0 else {
            print("Queued — but Simmer.app is not running, so nobody will post it.")
            print("open -a Simmer  (banners and the menu bar live in the app)")
            throw ExitCode(1)
        }
        switch status.notify {
        case "authorized":
            print("Queued — the banner arrives as \"Simmer\" within a few seconds.")
        case "notDetermined":
            print("Queued — but macOS is still waiting for you to click Allow on")
            print("Simmer's permission banner. open -a Simmer shows it again.")
            throw ExitCode(1)
        case "denied":
            print("Queued — but notifications for \"Simmer\" are DENIED.")
            print("Re-enable in System Settings > Notifications > Simmer.")
            throw ExitCode(1)
        default:
            print("Queued — the app has not reported its permission state yet.")
        }
        print("")
        print("Notifications are optional either way: the menu bar always shows the")
        print("truth and cannot be suppressed — SIMMER_NOTIFY=none is a legitimate choice.")
    }
}
