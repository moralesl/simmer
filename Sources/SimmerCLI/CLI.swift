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
}

struct SimmerRoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simmer",
        abstract: "Keeps this Mac awake for a bounded time — lid closed — then lets it sleep again.",
        subcommands: [ClaimCLI.self, ExtendCLI.self, ReleaseCLI.self, CapCLI.self,
                      StatusCLI.self, BudgetCLI.self, RunCLI.self, GuardCLI.self,
                      DoctorCLI.self, LogCLI.self, RenderCLI.self,
                      NotifyTestCLI.self, NotifyPostCLI.self]
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

    @Option(name: .customLong("min-battery"),
            help: "Release below this battery percentage (on battery only).")
    var minBattery: Int = Claim.defaultMinBattery

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
        let input = ClaimInput(
            durationText: forever ? nil : duration,
            untilText: until,
            forever: forever,
            reason: common.reason ?? "",
            minBattery: minBattery,
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
        Runtime.deliver(Commands.logTail(count, ctx: ctx))
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
        let ctx = Runtime.context(ownerFlag: common.owner)
        Runtime.deliver(Commands.render(surface: surface,
                                        query: query.joined(separator: " "), ctx: ctx))
    }
}

// MARK: notify-post (hidden) — post as the bundle this binary lives in

struct NotifyPostCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify-post", shouldDisplay: false)

    @Argument var title: String = ""
    @Argument var subtitle: String = ""
    @Argument var body: String = ""

    @Flag(name: .customLong("silent")) var silent = false
    @Flag(name: .customLong("status"),
          help: "Print the authorization status instead of posting.")
    var status = false

    func run() throws {
        if status {
            print(Notify.authorizationStatus())
            throw ExitCode.success
        }
        throw ExitCode(Notify.postAsBundle(title: title, subtitle: subtitle,
                                           body: body, sound: !silent))
    }
}

// MARK: notify-test

struct NotifyTestCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify-test",
        abstract: "Fire one notification through every transport — whichever you SEE is the one that works.")

    @OptionGroup var common: CommonOptions

    func run() throws {
        let env = Runtime.environment()
        print("Firing one notification through each transport.")
        print("Whichever you SEE is the one that works. Then set it, e.g.:")
        print("  echo 'export SIMMER_NOTIFY=osascript' >> ~/.zshrc")
        print("")
        let bundleBinary = Notify.bundleBinary(env: env)
        if FileManager.default.isExecutableFile(atPath: bundleBinary) {
            let status = Shell.run(bundleBinary, ["notify-post", "--status"])
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = Shell.run(bundleBinary, ["notify-post", "simmer via bundle",
                                         "transport test", "the pot icon means use bundle"])
            print("  bundle     sent (status: \(status))")
        } else {
            print("  bundle     skipped — Simmer.app not installed (make install)")
        }
        Notify.post(NotificationRequest(title: "simmer via osascript",
                                        subtitle: "transport test",
                                        body: "if you see this, use osascript"),
                    env: SimmerEnvironment(env: ["SIMMER_NOTIFY": "osascript"],
                                           isTTY: false, executablePath: env.binPath))
        print("  osascript  sent")
        print("")
        print("Nothing at all? The menu bar always shows the truth and cannot be")
        print("suppressed — SIMMER_NOTIFY=none is a legitimate choice.")
    }
}
