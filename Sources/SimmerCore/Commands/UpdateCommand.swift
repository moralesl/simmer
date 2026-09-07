import Foundation

/// "Is there a newer simmer, and what do I type?" — the one place that decides
/// the wording, for all four surfaces that ask it.
///
/// It reports; it never updates. An update replaces a running app and the
/// binary the guard's LaunchAgent points at, and it can be asked for while a
/// claim is live — so the command a person can read first is the right shape,
/// exactly as it is for `simmer uninstall`.
public enum UpdateCommand {
    public enum Verdict: String, Sendable {
        /// Running the newest release.
        case current
        /// A newer release exists.
        case available
        /// Newer than the newest release — a checkout whose version has been
        /// bumped past the last tag. Not a state to nag about.
        case ahead
        /// The check could not answer. The only one that exits non-zero.
        case unknown
    }

    /// Everything the four surfaces render from. Computed once, in core, so
    /// the menu bar, the launcher row, `doctor` and the terminal cannot
    /// disagree about what "up to date" means — the same reason `render` draws
    /// the launcher surfaces here rather than in each integration.
    public struct Report: Sendable {
        public var verdict: Verdict
        public var installed: String
        /// The newest release tag as published (`v0.3.0`), empty when unknown.
        public var latest: String
        public var error: String
        public var install: Install
        /// `CFBundleShortVersionString` of the installed `Simmer.app`, when
        /// there is one to read.
        public var appVersion: String?
        /// When the answer being reported was obtained.
        public var checkedAt: Int
        /// The answer came from the cache rather than from a fresh look.
        public var fromCache: Bool
        public var now: Int

        public var updateAvailable: Bool { verdict == .available }

        /// The CLI and the app are the same binary — `make install` symlinks
        /// `~/.local/bin/simmer` at the copy inside the bundle — so a
        /// disagreement here means one of them was replaced and the other was
        /// not. Under a package manager that upgrades the CLI and leaves the
        /// bundle alone, that is the normal outcome rather than an accident,
        /// which is why it is a field and not a footnote.
        public var appDrift: Bool {
            guard let appVersion, !appVersion.isEmpty else { return false }
            return appVersion != installed
        }

        /// The release, spelled the way `installed` is spelled.
        ///
        /// `latest` holds the tag as published — `v0.3.0` — because that is
        /// the string a caller hands to `git checkout` or matches against a
        /// release page. A sentence that puts `v0.3.0` next to `0.2.0` reads
        /// like two different kinds of thing, so the human surfaces drop the
        /// prefix and the machine surface keeps it.
        public var latestDisplay: String {
            SemanticVersion(latest).map(String.init(describing:)) ?? latest
        }

        public var cacheAge: Int { max(0, now - checkedAt) }

        /// The release's own page — where the notes are, for someone deciding
        /// whether to install it.
        ///
        /// Composed, never fetched. simmer makes exactly one outbound request
        /// (CONTRACTS.md § One outbound request) and this adds none: a URL is
        /// handed to the browser, which is the program whose job that is.
        ///
        /// Nil unless `latest` parses as a version. It arrives as the last
        /// path component of a redirect and survives a round-trip through a
        /// `key=value` cache file, so it is not a string to interpolate into
        /// something that gets opened without asking what it is first.
        public var releaseNotesURL: String? {
            guard !latest.isEmpty, SemanticVersion(latest) != nil else { return nil }
            return "\(Install.repositoryURL)/releases/tag/\(latest)"
        }
    }

    /// Ask the source, or read what the last ask recorded.
    ///
    /// `cached: true` never touches the network — it is what `doctor`, the
    /// menu and a launcher row use, so that the only surface which can make a
    /// person wait is the one they explicitly typed.
    public static func check(now: Int,
                             installed: String,
                             install: Install,
                             appVersion: String?,
                             ledger: Ledger,
                             source: ReleaseSource,
                             cached: Bool,
                             seamed: Bool = false) -> Report {
        if cached {
            // A record written under a seam answers about the seam. An
            // unseamed surface — the menu bar, `doctor` on a real install —
            // must not repeat it as news about the repository: a
            // `SIMMER_FAKE_LATEST` left exported in a shell rc would otherwise
            // put "Update available: 9.9.9" in a person's menu until the next
            // day. The reverse is fine, and useful: a seamed reader may read
            // its own seamed record.
            guard let record = ledger.readUpdateRecord(), !(record.seamed && !seamed) else {
                return Report(verdict: .unknown, installed: installed, latest: "",
                              error: ledger.readUpdateRecord() == nil
                                  ? "not checked yet — run simmer update"
                                  : "the last check was seamed — run simmer update",
                              install: install, appVersion: appVersion,
                              checkedAt: 0, fromCache: true, now: now)
            }
            return report(now: now, installed: installed, install: install,
                          appVersion: appVersion, latest: record.latest,
                          error: record.error, checkedAt: record.checkedAt, fromCache: true)
        }

        let lookup = source.newestRelease()
        var latest = "", error = ""
        switch lookup {
        case .tag(let tag): latest = tag
        case .unavailable(let reason): error = reason
        }
        // Written even when the look-up failed: "we tried and could not tell"
        // is the answer the other surfaces need, and without recording it the
        // menu would show "not checked yet" forever on a machine that has been
        // checking every day and failing.
        ledger.writeUpdateRecord(.init(checkedAt: now, installed: installed,
                                       latest: latest, error: error, seamed: seamed))
        return report(now: now, installed: installed, install: install,
                      appVersion: appVersion, latest: latest, error: error,
                      checkedAt: now, fromCache: false)
    }

    private static func report(now: Int, installed: String, install: Install,
                               appVersion: String?, latest: String, error: String,
                               checkedAt: Int, fromCache: Bool) -> Report {
        var report = Report(verdict: .unknown, installed: installed, latest: latest,
                            error: error, install: install, appVersion: appVersion,
                            checkedAt: checkedAt, fromCache: fromCache, now: now)
        guard error.isEmpty, !latest.isEmpty else {
            report.verdict = .unknown
            if report.error.isEmpty { report.error = "no release information" }
            return report
        }
        guard let mine = SemanticVersion(installed), let theirs = SemanticVersion(latest) else {
            report.verdict = .unknown
            report.error = "cannot compare \(installed) with \(latest)"
            return report
        }
        if mine < theirs {
            report.verdict = .available
        } else if theirs < mine {
            report.verdict = .ahead
        } else {
            report.verdict = .current
        }
        return report
    }

    // MARK: applying it
    //
    // `--apply` runs the update instead of printing it, for the person who has
    // no terminal to paste into — which is most of the people the menu bar
    // exists for. Three properties make it something this tool can honestly
    // offer:
    //
    //   1. **It never pipes the network into a shell.** The printed command for
    //      a bundle install is `curl … | bash`, and an app running THAT on
    //      someone's behalf is a different kind of thing entirely. The same
    //      install already has the installer's checkout on disk, so the plan
    //      updates that and runs `make install` — local files, and the same
    //      recipe `bootstrap.sh` would have run.
    //   2. **It needs no root.** `make install` never touches sudo; the
    //      privileged rule is installed once, by a human, and an update does
    //      not renew it. So "simmer never gives itself root" is untouched.
    //   3. **It refuses rather than guesses.** A developer's own checkout is
    //      not machinery to be moved onto a tag, and an install this cannot
    //      place is not one to run commands in.

    /// Which part of the update a step is doing.
    ///
    /// Carried as a field rather than recognised from the command line,
    /// because "does this argument list contain `fetch`" is a classification
    /// that goes wrong silently the first time a plan changes shape — and what
    /// it decides is the sentence a person reads when the update breaks.
    ///
    /// A one-step Homebrew plan is `.installing`: `brew upgrade` fetches,
    /// builds and installs, and the sentences are worded to be true of both
    /// plans.
    public enum ApplyPhase: String, Sendable, Equatable {
        case fetching
        case switching
        case installing
        /// `make install` quits Simmer.app before replacing it, so something
        /// has to bring it back. Not part of installing: when only this fails
        /// the update landed, and the exit code says so.
        case relaunching
    }

    /// One thing to run. Held as data so the decision is testable without
    /// anything being executed — the seam is in the runner, not in here.
    public struct ApplyStep: Sendable, Equatable {
        public let executable: String
        public let arguments: [String]
        public let workingDirectory: String?
        public let phase: ApplyPhase

        public init(executable: String, arguments: [String], phase: ApplyPhase,
                    workingDirectory: String? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.phase = phase
            self.workingDirectory = workingDirectory
        }

        /// What a person reads in the output and in the log.
        public var described: String {
            ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
                .joined(separator: " ")
        }
    }

    public struct ApplyPlan: Sendable, Equatable {
        public let steps: [ApplyStep]
        /// The release this plan installs, for the sentence at the end.
        public let target: String
        /// The bundle to reopen afterwards — `make install` quits the running
        /// app before replacing it, so something has to bring it back.
        public let reopenBundle: String?
    }

    public enum ApplyDecision: Sendable, Equatable {
        case run(ApplyPlan)
        /// Nothing to install. Exit 0: being current is the good outcome.
        case nothingToDo(String)
        /// This install cannot be updated in place, and the reason names the
        /// way that works instead. Exit 1.
        case refused(String)
    }

    /// Where `bootstrap.sh` puts the checkout it installs from. Machinery, not
    /// a project anyone works in — which is exactly why moving it onto a tag is
    /// fair game, and why a developer's own checkout is not.
    public static let installerCheckout = ".local/share/simmer"

    public static func applyPlan(for report: Report,
                                 home: String,
                                 exists: (String) -> Bool) -> ApplyDecision {
        switch report.verdict {
        case .current:
            return .nothingToDo("simmer \(report.installed) is already the newest release")
        case .ahead:
            return .nothingToDo(
                "simmer \(report.installed) is ahead of the newest release (\(report.latestDisplay))")
        case .unknown:
            return .refused("cannot tell whether there is anything to install — \(report.error)")
        case .available:
            break
        }

        switch report.install.kind {
        case .homebrew:
            // Homebrew owns this copy, so `brew` is the only correct verb —
            // and the formula is what knows how to build it.
            guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: exists)
            else {
                return .refused("this is a Homebrew install but brew is not where it usually is — run: \(report.install.updateCommand)")
            }
            return .run(ApplyPlan(
                steps: [ApplyStep(executable: brew, arguments: ["upgrade", "simmer"],
                                  phase: .installing)],
                target: report.latestDisplay,
                reopenBundle: report.install.bundle))

        case .checkout:
            // Somebody's working repository. It may hold local commits, an
            // unfinished branch, or a stash, and `git checkout v0.3.0` in it
            // would be simmer rearranging someone's desk. The person running
            // from a checkout has a terminal by definition.
            return .refused(
                "this is your own checkout — update it yourself: \(report.install.updateCommand)")

        case .bundle, .unknown:
            let checkout = URL(fileURLWithPath: home)
                .appendingPathComponent(installerCheckout).path
            guard exists(checkout + "/.git"), exists(checkout + "/Makefile") else {
                return .refused(
                    "no installer checkout at ~/\(installerCheckout), so there is nothing here to build from — run: \(report.install.updateCommand)")
            }
            // The tag, not a branch: this checkout tracks releases, which is
            // what `bootstrap.sh` left it on. `--tags --force` because a tag
            // can legitimately have moved on the remote and a stale local one
            // would silently install the wrong thing.
            return .run(ApplyPlan(
                steps: [
                    ApplyStep(executable: "/usr/bin/git",
                              arguments: ["-C", checkout, "fetch", "--tags", "--force", "--quiet"],
                              phase: .fetching),
                    ApplyStep(executable: "/usr/bin/git",
                              arguments: ["-C", checkout, "checkout", "--quiet", report.latest],
                              phase: .switching),
                    // NOTES=0: the epilogue tells a reader to do things this
                    // path has already done or is about to do.
                    ApplyStep(executable: "/usr/bin/make",
                              arguments: ["-C", checkout, "install", "NOTES=0"],
                              phase: .installing),
                ],
                target: report.latestDisplay,
                reopenBundle: report.install.bundle))
        }
    }

    /// What the plan says it will do, before it does it.
    public static func applyPreamble(_ plan: ApplyPlan, installed: String) -> [String] {
        ["▸ updating simmer \(installed) → \(plan.target)"]
            + plan.steps.map { "   \($0.described)" }
    }

    /// Bringing the app back after `make install` replaced it. Composed here
    /// rather than in the CLI so it carries a phase like every other step and
    /// its failure reaches the same sentence.
    public static func reopenStep(bundle: String) -> ApplyStep {
        ApplyStep(executable: "/usr/bin/open", arguments: [bundle], phase: .relaunching)
    }

    /// `relaunchFailure` is the stderr tail of a reopen that did not work.
    /// Exit stays 0 and `applied` stays true: the update landed, and a menu
    /// bar that did not come back is a sentence to read, not a failed install
    /// for a caller to retry.
    public static func applied(_ plan: ApplyPlan, reopened: Bool,
                               relaunchFailure: String? = nil,
                               updateCommand: String = "") -> Outcome {
        var outcome = Outcome()
        outcome.stdout = ["✅ simmer \(plan.target) installed"
            + (reopened ? " · Simmer.app relaunched" : "")]
        var subtitle = reopened ? "Simmer.app was relaunched" : ""
        var body = ""
        if let relaunchFailure {
            let sentence = failureSentence(phase: .relaunching, plan: plan,
                                           updateCommand: updateCommand)
            outcome.stdout.append("⚠️  \(sentence)")
            outcome.stdout.append("   \(reopenStep(bundle: plan.reopenBundle ?? "").described)"
                + " failed — \(relaunchFailure)")
            subtitle = "Simmer.app did not come back"
            body = sentence
        }
        outcome.notifications = [NotificationRequest(
            title: "simmer \(plan.target) installed",
            subtitle: subtitle, body: body, sound: false)]
        return outcome
    }

    /// What did not finish, and what to do about it — in that order, because
    /// the person reading this is not the person who wrote the plan.
    ///
    /// `git -C … checkout --quiet v0.9.0 failed — fatal: reference is not a
    /// tree` is the whole of what this used to say. It names a command nobody
    /// typed, in a checkout most people do not know they have, and leaves the
    /// two questions that matter — did anything change, and what do I do —
    /// entirely to the reader.
    public static func failureSentence(phase: ApplyPhase, plan: ApplyPlan,
                                       updateCommand: String) -> String {
        let target = "simmer \(plan.target)"
        let terminal = updateCommand.isEmpty ? "" : " Run: \(updateCommand)"
        switch phase {
        case .fetching:
            return "Could not fetch \(target). Nothing on this Mac was changed.\(terminal)"
        case .switching:
            return "Could not switch to \(target). Nothing was installed.\(terminal)"
        case .installing:
            // Deliberately not "was fetched but not installed": that is untrue
            // of the one-step Homebrew plan, which does both at once.
            return "Could not install \(target). The copy you are running is untouched.\(terminal)"
        case .relaunching:
            // The update DID land, so `updateCommand` would be the wrong
            // instruction here — the thing left undone is opening the app.
            let bundle = plan.reopenBundle
            return "\(target) is installed, but Simmer.app did not come back."
                + (bundle.map { " Open it again: open \($0)" } ?? "")
        }
    }

    /// A step failed. Names what did not finish and what to do, because
    /// "the update failed" sends a person to a log they do not know the
    /// location of — and the failing command stays on the second line, where
    /// it is evidence rather than the whole message.
    public static func applyFailed(step: ApplyStep, detail: String,
                                   plan: ApplyPlan, updateCommand: String) -> Outcome {
        let sentence = failureSentence(phase: step.phase, plan: plan,
                                       updateCommand: updateCommand)
        var outcome = Outcome.failure(sentence)
        outcome.stderr.append("   \(step.described) failed — \(detail)")
        outcome.notifications = [NotificationRequest(
            title: "The simmer update did not finish",
            subtitle: step.described, body: sentence, sound: false)]
        return outcome
    }

    /// What `--apply` actually did. All four endings, so that deciding which
    /// one happened and deciding what to say about it are separate jobs.
    public enum ApplyResult: Sendable {
        case nothingToDo(String)
        case refused(String)
        case failed(step: ApplyStep, detail: String, plan: ApplyPlan)
        /// `relaunchFailure` is the stderr tail of a reopen that did not work.
        /// Still `installed`: the update landed, and a menu bar that did not
        /// come back is a sentence to read rather than a failure to retry.
        case installed(plan: ApplyPlan, reopened: Bool, relaunchFailure: String? = nil)
    }

    /// The whole answer for one `--apply`, human or machine, exit code
    /// included — the counterpart to `jsonOutcome` for the check.
    ///
    /// It exists because the CLI used to assemble this itself: take an Outcome
    /// from here, or an empty one, and set `stdout` on it inside `UpdateCLI`'s
    /// own switch. In the RELEASE build that answer did not survive the trip:
    /// markers either side of one call show one line where the CLI built it
    /// and an EMPTY array where `Runtime.emit` read it, with every step of the
    /// plan run and the exit code correct. Both supported macOS versions,
    /// `--json` and human alike, including the endings that run no steps.
    ///
    /// `-Onone` prints, the debug build prints, and the check path — whose
    /// Outcome is built here and delivered unmodified — always printed. Why an
    /// optimised build drops it is NOT pinned: `doctor --json` builds its
    /// Outcome in the CLI in the same shape and has never lost a byte, so this
    /// is not a rule about where Outcomes may be built. It is one place fewer
    /// for the answer to go missing, and `make test-release` is what would see
    /// it if it went missing again.
    ///
    /// It is also where this belonged: SimmerCore stays pure and the CLI is a
    /// renderer over it (AGENTS.md, iron rules). Four surfaces render an
    /// update; none of them should own the shape of its answer.
    public static func applyOutcome(_ result: ApplyResult, report: Report,
                                    seamed: Bool, json: Bool) -> Outcome {
        switch result {
        case .nothingToDo(let sentence):
            guard json else {
                var outcome = Outcome()
                outcome.stdout = ["✅ \(sentence)"]
                return outcome
            }
            return jsonApplyOutcome(report, seamed: seamed, applied: false,
                                    plan: nil, error: nil, exit: 0)

        case .refused(let why):
            guard json else { return Outcome.failure(why) }
            return jsonApplyOutcome(report, seamed: seamed, applied: false,
                                    plan: nil, error: why, exit: 1)

        case .failed(let step, let detail, let plan):
            // `applyFailed` writes the sentence naming the part that stopped;
            // `apply_error` keeps the failing command and its detail, which is
            // what a caller has always parsed. Two audiences, one place.
            let failure = applyFailed(step: step, detail: detail, plan: plan,
                                      updateCommand: report.install.updateCommand)
            guard json else { return failure }
            var outcome = jsonApplyOutcome(
                report, seamed: seamed, applied: false, plan: plan,
                error: "\(step.described): \(detail)", exit: 1)
            outcome.notifications = failure.notifications
            return outcome

        case .installed(let plan, let reopened, let relaunchFailure):
            // `applied: true` and exit 0 even when the relaunch failed: the
            // update landed, and `apply_error` is for one that could not be
            // made. The sentence reaches the person through the human lines
            // and the banner.
            let human = applied(plan, reopened: reopened,
                                relaunchFailure: relaunchFailure,
                                updateCommand: report.install.updateCommand)
            guard json else { return human }
            var outcome = jsonApplyOutcome(report, seamed: seamed, applied: true,
                                           plan: plan, error: nil, exit: 0)
            outcome.notifications = human.notifications
            return outcome
        }
    }

    /// One object, one exit code, built where the object is built.
    private static func jsonApplyOutcome(_ report: Report, seamed: Bool,
                                         applied: Bool, plan: ApplyPlan?,
                                         error: String?, exit: Int32) -> Outcome {
        var outcome = Outcome()
        outcome.stdout = [applyJSON(report, seamed: seamed, applied: applied,
                                    plan: plan, error: error).serialized()]
        outcome.exit = exit
        return outcome
    }

    public static func applyJSON(_ report: Report, seamed: Bool,
                                 applied: Bool, plan: ApplyPlan?,
                                 error: String?) -> JSONValue {
        var fields: [(String, JSONValue)] = []
        for (key, value) in objectFields(json(report, seamed: seamed)) {
            fields.append((key, value))
        }
        // Overwrite `action`: this call did something, or refused to.
        fields = fields.map { key, value in
            key == "action"
                ? (key, .string(applied ? "updated" : (error == nil ? "checked" : "refused")))
                : (key, value)
        }
        fields.append(("applied", .bool(applied)))
        fields.append(("steps", .array((plan?.steps ?? []).map { .string($0.described) })))
        if let error { fields.append(("apply_error", .string(error))) }
        return .object(fields)
    }

    /// `JSONValue` is an enum, and `applyJSON` needs the check's fields plus a
    /// few of its own rather than a second hand-kept copy of the list.
    private static func objectFields(_ value: JSONValue) -> [(String, JSONValue)] {
        if case .object(let fields) = value { return fields }
        return []
    }

    // MARK: what each surface shows

    /// The terminal answer. Exit 0 whenever the check completed — a newer
    /// version existing is not a failure, which is the same reading that keeps
    /// it out of `doctor`'s red rows.
    public static func humanOutcome(_ report: Report) -> Outcome {
        var outcome = Outcome()
        switch report.verdict {
        case .current:
            outcome.stdout = ["✅ simmer \(report.installed) is the newest release"]
        case .available:
            outcome.stdout = [
                "⬆️  simmer \(report.latestDisplay) is out — you have \(report.installed)",
            ]
        case .ahead:
            outcome.stdout = [
                "✅ simmer \(report.installed) — ahead of the newest release (\(report.latestDisplay))",
            ]
        case .unknown:
            outcome.stdout = ["⚠️  cannot tell whether \(report.installed) is current — \(report.error)"]
            outcome.exit = 1
        }

        outcome.stdout.append("   \(report.install.describedSource)")

        if report.verdict == .available {
            outcome.stdout.append("   update with:    \(report.install.updateCommand)")
            if let notes = report.releaseNotesURL {
                // Under the command, not above it: the command is what most
                // people came for, and the notes are what the careful ones
                // want first. Both are readable before anything happens.
                outcome.stdout.append("   release notes:  \(notes)")
            }
        }
        if report.appDrift {
            outcome.stdout.append(contentsOf: appDriftLines(report))
        }
        if report.fromCache, report.checkedAt > 0 {
            outcome.stdout.append("   checked \(Durations.human(report.cacheAge)) ago")
        }
        return outcome
    }

    /// Two lines rather than one, because the fix is not the same as the fix
    /// for being out of date: the newest release may already be on the disk
    /// with only half of it in place.
    public static func appDriftLines(_ report: Report) -> [String] {
        let app = report.appVersion ?? "?"
        return [
            "   ⚠️  Simmer.app is \(app) but this CLI is \(report.installed)",
            "       the bundle was not replaced — \(report.install.updateCommand)",
        ]
    }

    /// One line for a status surface: the menu's conditional row, and the
    /// launcher's accessory. Nil when there is nothing to say, which is what
    /// keeps the row conditional in one place instead of in each surface.
    public static func statusLine(_ report: Report) -> String? {
        if report.appDrift {
            return "Simmer.app is \(report.appVersion ?? "?") · CLI is \(report.installed)"
        }
        guard report.verdict == .available else { return nil }
        return "Update available: \(report.latestDisplay)"
    }

    /// The banner for a check somebody asked for by hand.
    ///
    /// Silent, and not actionable: there is no Extend/Release to offer and
    /// nothing about an available release needs a sound. The once-a-day
    /// background check reuses this banner through `announcement`, and posts
    /// it at most once per new version — which is the difference between
    /// telling someone what they asked, telling them something once, and
    /// interrupting them daily with the same news.
    public static func notification(_ report: Report) -> NotificationRequest {
        switch report.verdict {
        case .available:
            return NotificationRequest(
                title: "simmer \(report.latestDisplay) is available",
                subtitle: "you have \(report.installed)",
                body: report.install.updateCommand, sound: false)
        case .current:
            return NotificationRequest(
                title: "simmer \(report.installed) is up to date",
                subtitle: "", body: "", sound: false)
        case .ahead:
            return NotificationRequest(
                title: "simmer \(report.installed) is ahead of the newest release",
                subtitle: "newest is \(report.latestDisplay)", body: "", sound: false)
        case .unknown:
            return NotificationRequest(
                title: "Could not check for updates",
                subtitle: "", body: report.error, sound: false)
        }
    }

    /// One banner per new version — the decision, so that the app only posts.
    ///
    /// The once-a-day check updates the menu and, until now, said nothing at
    /// all: a colleague who never opens the menu bar could be months behind
    /// with no way to find out. "News, once" is the narrow thing between that
    /// silence and nagging — the same version is never announced twice, so the
    /// cost of the feature is one banner per release, ever.
    public struct Announcement: Sendable, Equatable {
        public let notification: NotificationRequest
        /// The tag to record as announced. `latest` as published, matching
        /// what `readAnnouncedUpdate` compares against.
        public let announced: String
    }

    /// Nil unless this check is news. Nothing announces when:
    ///
    /// - there is no newer release (`current`, `ahead`, `unknown`) — a
    ///   downgrade is not news and a failed check has nothing to say;
    /// - this tag has been announced before, whoever's check found it;
    /// - the process is seamed, because then the answer is about a
    ///   `SIMMER_FAKE_LATEST` and not about the repository. A cached seamed
    ///   record is already discarded by an unseamed reader in `check`; this
    ///   closes the same door on the fresh path.
    public static func announcement(_ report: Report, lastAnnounced: String,
                                    seamed: Bool) -> Announcement? {
        guard !seamed, report.verdict == .available, !report.latest.isEmpty,
              report.latest != lastAnnounced else { return nil }
        // The manual check's banner, reused: it already names the version in
        // the title and how to get it in the body, which is exactly what this
        // one has to say. Two wordings for one fact is how the four surfaces
        // came to be rendered from here in the first place.
        return Announcement(notification: notification(report), announced: report.latest)
    }

    /// The menu bar's footer: what you are running, and what is out there.
    ///
    /// Always present, unlike the update row above it. A menu that shows the
    /// installed version and says nothing about the newest one answers half of
    /// the only question anyone asks it, and the missing half is the half you
    /// cannot get at without a terminal.
    public static func footerLine(_ report: Report) -> String {
        switch report.verdict {
        case .current:
            return "simmer \(report.installed) · newest"
        case .available:
            return "simmer \(report.installed) · newest is \(report.latestDisplay)"
        case .ahead:
            return "simmer \(report.installed) · ahead of \(report.latestDisplay)"
        case .unknown:
            // Deliberately not the error text: this line is four words wide in
            // a menu, and "not checked" is the actionable half of every reason
            // the check could fail.
            return report.checkedAt == 0
                ? "simmer \(report.installed) · not checked yet"
                : "simmer \(report.installed) · last check failed"
        }
    }

    public static func json(_ report: Report, seamed: Bool) -> JSONValue {
        .object([
            ("action", .string("checked")),
            ("verdict", .string(report.verdict.rawValue)),
            ("installed", .string(report.installed)),
            // The tag as published, `v` and all — the string a caller would
            // hand to `git checkout` or compare against a release page.
            ("latest", report.latest.isEmpty ? .null : .string(report.latest)),
            ("update_available", .bool(report.updateAvailable)),
            ("provenance", .string(report.install.kind.rawValue)),
            ("update_command", .string(report.install.updateCommand)),
            ("app_version", report.appVersion.map { JSONValue.string($0) } ?? .null),
            ("app_drift", .bool(report.appDrift)),
            ("checked_at", .int(report.checkedAt)),
            ("cached", .bool(report.fromCache)),
            ("error", report.error.isEmpty ? .null : .string(report.error)),
            ("seamed", .bool(seamed)),
            // Appended, like every field after the first release: the page
            // for `latest`, or null when there is no release to point at.
            ("release_notes_url", report.releaseNotesURL.map { JSONValue.string($0) } ?? .null),
        ])
    }

    public static func jsonOutcome(_ report: Report, seamed: Bool) -> Outcome {
        var outcome = Outcome()
        outcome.stdout = [json(report, seamed: seamed).serialized()]
        if report.verdict == .unknown { outcome.exit = 1 }
        return outcome
    }
}
