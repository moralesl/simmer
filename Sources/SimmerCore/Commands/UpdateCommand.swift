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
        /// Whether an unattended install is permitted — the person's own
        /// switch, read here so that every surface rendering this report says
        /// the same thing about it. Off by default (`Ledger.autoUpdateEnabled`).
        public var autoUpdate: Bool = false
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
            // `writtenBy:` is the other half of the same rule, for the same
            // reason: a record is an answer somebody's binary computed, and
            // only the binary that computed it can repeat it as its own. A
            // record written by the version this one replaced is discarded
            // here, so the first `doctor` after an install says "not checked
            // yet" rather than a verdict about a version that no longer runs.
            let record = ledger.readUpdateRecord(writtenBy: installed)
            guard let record, !(record.seamed && !seamed) else {
                return Report(verdict: .unknown, installed: installed, latest: "",
                              error: record == nil
                                  ? "not checked yet — run simmer update"
                                  : "the last check was seamed — run simmer update",
                              install: install, appVersion: appVersion,
                              checkedAt: 0, fromCache: true,
                              autoUpdate: ledger.autoUpdateEnabled, now: now)
            }
            return report(now: now, installed: installed, install: install,
                          appVersion: appVersion, latest: record.latest,
                          error: record.error, checkedAt: record.checkedAt, fromCache: true,
                          autoUpdate: ledger.autoUpdateEnabled)
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
        ledger.writeUpdateRecord(.init(checkedAt: now, latest: latest,
                                       error: error, seamed: seamed,
                                       installed: installed))
        return report(now: now, installed: installed, install: install,
                      appVersion: appVersion, latest: latest, error: error,
                      checkedAt: now, fromCache: false,
                      autoUpdate: ledger.autoUpdateEnabled)
    }

    private static func report(now: Int, installed: String, install: Install,
                               appVersion: String?, latest: String, error: String,
                               checkedAt: Int, fromCache: Bool, autoUpdate: Bool) -> Report {
        var report = Report(verdict: .unknown, installed: installed, latest: latest,
                            error: error, install: install, appVersion: appVersion,
                            checkedAt: checkedAt, fromCache: fromCache,
                            autoUpdate: autoUpdate, now: now)
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
    //   3. **It refuses rather than guesses.** No checkout is moved onto a tag
    //      except the installer's own, which exists for nothing else; a
    //      checkout somebody works in is pulled only when it is clean and on
    //      its default branch, and an install this cannot place is not one to
    //      run commands in at all.

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

    /// Where a plan gets the release's files from, when it gets them from a
    /// git remote it was told about rather than from a checkout's own
    /// upstream: the tag it asks for, the checkout it puts it in, and the
    /// remote it asks.
    ///
    /// It exists because those three were the whole of a failure nobody could
    /// read. `update --apply` asked GitHub which release exists and asked the
    /// install checkout's **`origin`** for that release's files, and the two
    /// are only the same remote by coincidence: `origin` is whatever cloned
    /// the checkout, and on a maintainer's Mac that is a dev checkout whose
    /// `main` lags the release by however long it has been since the last
    /// pull. On 8 Sep 2026 that cost two clicks and a `pathspec 'v0.3.3' did
    /// not match any file(s) known to git`, with the failure banner
    /// recommending the one-paste installer, which fetched the same `origin`
    /// and would have failed the same way.
    ///
    /// One optional value rather than three optional fields on the plan: the
    /// three are known together or not at all, so a plan with no release
    /// fetch — Homebrew's single `brew upgrade`, a checkout fast-forwarding
    /// its own upstream — stays distinguishable from one whose remote came
    /// back empty. Absent and defaulted-to-empty are the pair that hands a
    /// fallback the decision.
    public struct ReleaseFetch: Sendable, Equatable {
        /// The tag as published — `v0.3.3` — which is what `git checkout` is
        /// handed and what the sentence names.
        public let tag: String
        /// The checkout the tag is fetched into and switched in.
        public let checkout: String
        /// The remote the release was learned about from, and therefore the
        /// one that has its files.
        public let remote: String

        public init(tag: String, checkout: String, remote: String) {
            self.tag = tag
            self.checkout = checkout
            self.remote = remote
        }
    }

    public struct ApplyPlan: Sendable, Equatable {
        public let steps: [ApplyStep]
        /// The release this plan installs, for the sentence at the end.
        public let target: String
        /// The bundle to reopen afterwards — `make install` quits the running
        /// app before replacing it, so something has to bring it back.
        public let reopenBundle: String?
        /// The remote this plan fetches the release from, with the tag and the
        /// checkout, or nil when the plan fetches no release from a remote it
        /// was told about. Carried as data so the sentence and the machine
        /// surface can name it without re-deriving it from a step's arguments
        /// — the classification `ApplyPhase` exists to avoid.
        public let releaseFetch: ReleaseFetch?

        public init(steps: [ApplyStep], target: String, reopenBundle: String?,
                    releaseFetch: ReleaseFetch? = nil) {
            self.steps = steps
            self.target = target
            self.reopenBundle = reopenBundle
            self.releaseFetch = releaseFetch
        }
    }

    public enum ApplyDecision: Sendable, Equatable {
        case run(ApplyPlan)
        /// Nothing to install. Exit 0: being current is the good outcome.
        case nothingToDo(String)
        /// This install cannot be updated in place, and the reason names the
        /// way that works instead. Exit 1.
        case refused(String)
    }

    /// A checkout as it stands, so that deciding whether to touch it is a
    /// decision about data. `CheckoutProbe` is the seam that fills it in.
    public struct CheckoutState: Sendable, Equatable {
        /// The branch checked out, or empty when the head is detached.
        public let branch: String
        /// What the remote calls its default branch, or empty when that
        /// cannot be read locally.
        public let defaultBranch: String
        /// Nothing uncommitted — `git status --porcelain` says nothing.
        public let clean: Bool
        /// Commits on this branch that the upstream does not have, or nil
        /// when there is no upstream to compare against.
        ///
        /// Read before the fetch, so it is measured against the local idea of
        /// the remote — which is the safe direction: a commit that IS pushed
        /// but whose push this checkout has not seen counts as ahead and
        /// refuses, and a local commit counts as ahead however stale the
        /// remote ref is. The error is always towards refusing.
        public let aheadOfUpstream: Int?

        /// `aheadOfUpstream` defaults to 0 — in step with the upstream — so
        /// that every existing caller keeps meaning what it meant.
        public init(branch: String, defaultBranch: String, clean: Bool,
                    aheadOfUpstream: Int? = 0) {
            self.branch = branch
            self.defaultBranch = defaultBranch
            self.clean = clean
            self.aheadOfUpstream = aheadOfUpstream
        }
    }

    /// `releaseRemote` is the remote the release was read from, and it is a
    /// parameter rather than a constant read in here for two reasons: the
    /// real-`git` test points it at a fixture repository on disk, and the day
    /// an install records the remote it was bootstrapped from (`SIMMER_REPO`,
    /// a fork or a mirror) this is the one line that has to change.
    public static func applyPlan(for report: Report,
                                 exists: (String) -> Bool,
                                 checkoutState: (String) -> CheckoutState? = { _ in nil },
                                 releaseRemote: String = Install.repositoryURL)
        -> ApplyDecision {
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
            switch report.install.source {
            case .none:
                return .refused(
                    "no checkout on this Mac to build from — run: \(report.install.updateCommand)")

            case .gone(let path):
                // Named, rather than folded into "no checkout": the person
                // moved or deleted the directory this copy was installed
                // from, and knowing which one it was is what makes the
                // sentence actionable.
                return .refused(
                    "the checkout this was installed from (\(path)) is not there any more — run: \(report.install.updateCommand)")

            case .installer(let checkout):
                guard buildable(checkout, exists: exists) else {
                    return .refused(
                        "the installer checkout at \(checkout) has no .git and Makefile to build "
                            + "from — run: \(report.install.updateCommand)")
                }
                // The tag, not a branch: this checkout tracks releases, which
                // is what `bootstrap.sh` left it on. `--tags --force` because
                // a tag can legitimately have moved on the remote and a stale
                // local one would silently install the wrong thing.
                //
                // And from `releaseRemote` — the remote the release was read
                // from — rather than from `origin`, which is whatever cloned
                // this checkout. A normal install's `origin` IS that remote,
                // so naming it changes nothing there; on the Mac whose origin
                // is a dev checkout it is the difference between installing
                // the release and `pathspec 'v0.3.3' did not match`. Fetching
                // a URL updates no remote-tracking branch, which is exactly
                // right for a checkout that only ever sits on tags.
                return .run(ApplyPlan(
                    steps: [
                        ApplyStep(executable: "/usr/bin/git",
                                  arguments: ["-C", checkout, "fetch", "--tags", "--force",
                                              "--quiet", releaseRemote],
                                  phase: .fetching),
                        ApplyStep(executable: "/usr/bin/git",
                                  arguments: ["-C", checkout, "checkout", "--quiet", report.latest],
                                  phase: .switching),
                        // NOTES=0: the epilogue tells a reader to do things
                        // this path has already done or is about to do.
                        ApplyStep(executable: "/usr/bin/make",
                                  arguments: ["-C", checkout, "install", "NOTES=0"],
                                  phase: .installing),
                    ],
                    target: report.latestDisplay,
                    reopenBundle: report.install.bundle,
                    releaseFetch: ReleaseFetch(tag: report.latest, checkout: checkout,
                                               remote: releaseRemote)))

            case .checkout(let checkout):
                guard buildable(checkout, exists: exists) else {
                    return .refused(
                        "the checkout at \(checkout) has no .git and Makefile to build from "
                            + "— run: \(report.install.updateCommand)")
                }
                return checkoutPlan(for: report, checkout: checkout,
                                    state: checkoutState(checkout))
            }
        }
    }

    /// `git -C` and `make -C` are what a plan runs there, so these are exactly
    /// the two things that have to be present.
    private static func buildable(_ path: String, exists: (String) -> Bool) -> Bool {
        exists(path + "/.git") && exists(path + "/Makefile")
    }

    /// A bundle built in somebody's own checkout, updated the way that person
    /// would update it: pull the default branch and re-run `make install`.
    ///
    /// "A developer's own checkout is never moved onto a tag" was about local
    /// commits and unfinished branches, not about every checkout — a clean
    /// tree sitting on the branch the remote calls default is the one shape
    /// where `git pull` is the same command the person would type, and
    /// refusing there left a Mac installed from a checkout with a menu item
    /// that could only ever report a refusal.
    ///
    /// So the conditions are checked rather than assumed, and every refusal
    /// names the one that failed plus the command that always works.
    /// Nothing here is a fetch of the remote's opinion: `origin/HEAD` is read
    /// locally, so a checkout that cannot answer refuses instead of waiting.
    private static func checkoutPlan(for report: Report, checkout: String,
                                     state: CheckoutState?) -> ApplyDecision {
        let yourself = "update it yourself: \(report.install.updateCommand)"
        guard let state else {
            return .refused("cannot read the checkout at \(checkout) — \(yourself)")
        }
        guard state.clean else {
            return .refused(
                "the checkout at \(checkout) has uncommitted changes, and simmer does not "
                    + "rearrange somebody's desk — \(yourself)")
        }
        guard !state.branch.isEmpty else {
            return .refused("the checkout at \(checkout) is not on a branch — \(yourself)")
        }
        guard !state.defaultBranch.isEmpty else {
            return .refused(
                "cannot tell which branch is default in the checkout at \(checkout) — \(yourself)")
        }
        guard state.branch == state.defaultBranch else {
            return .refused(
                "the checkout at \(checkout) is on \(state.branch), not \(state.defaultBranch) "
                    + "— \(yourself)")
        }
        // Clean and on the default branch is not the same as "has nothing of
        // its own". A checkout with local commits is the case this whole
        // refusal exists for, and it was the one shape that got through:
        // `git merge --ff-only @{u}` SUCCEEDS against an upstream that is
        // already an ancestor — it is a no-op — so the plan ran to the end,
        // `make install` shipped the developer's unreleased tree as the
        // update, and the success line named a release the installed binary
        // does not report.
        guard let ahead = state.aheadOfUpstream else {
            return .refused(
                "the branch \(state.branch) in the checkout at \(checkout) tracks nothing, so "
                    + "there is no upstream to update from — \(yourself)")
        }
        guard ahead == 0 else {
            return .refused(
                "the checkout at \(checkout) has \(ahead) commit\(ahead == 1 ? "" : "s") that "
                    + "\(state.branch) has not pushed, and installing it would install those "
                    + "rather than the release — push them first (git -C \(checkout) push), or "
                    + "\(yourself)")
        }
        // `origin`, deliberately, and no `releaseFetch`: this checkout is
        // somebody's own repository and what it installs is what its default
        // branch holds, so its own upstream is the only remote that answers
        // the question. The installer arm's remote is the release's because
        // that checkout tracks releases and nothing else.
        return .run(ApplyPlan(
            steps: [
                ApplyStep(executable: "/usr/bin/git",
                          arguments: ["-C", checkout, "fetch", "--quiet"],
                          phase: .fetching),
                // `git pull --ff-only`, spelled as its two halves so that a
                // failure lands on the phase it belongs to: a merge that
                // cannot fast-forward has installed nothing, and that is the
                // sentence `switching` already says.
                ApplyStep(executable: "/usr/bin/git",
                          arguments: ["-C", checkout, "merge", "--ff-only", "--quiet", "@{u}"],
                          phase: .switching),
                ApplyStep(executable: "/usr/bin/make",
                          arguments: ["-C", checkout, "install", "NOTES=0"],
                          phase: .installing),
            ],
            // "or newer", because this plan installs what the branch holds
            // rather than the tag: the release is what made it worth doing,
            // and claiming the exact version would be a claim nobody checked.
            target: "\(report.latestDisplay) or newer",
            reopenBundle: report.install.bundle))
    }

    /// What the plan says it will do, before it does it.
    public static func applyPreamble(_ plan: ApplyPlan, installed: String) -> [String] {
        ["▸ updating simmer \(installed) → \(plan.target)"]
            + plan.steps.map { "   \($0.described)" }
    }

    /// The banner for an install that has just started.
    ///
    /// Enqueued into the spool by the child rather than posted by the app, for
    /// the reason the spool exists: `make install` quits `Simmer.app`, so the
    /// only process guaranteed to be alive across the whole update is the
    /// child, and a file is the only channel that survives the poster being
    /// replaced mid-flight.
    ///
    /// It carries a body, and that is not decoration. Every banner this tool
    /// has ever been seen to show has one; the one banner nobody has ever seen
    /// — the app's own "Updating simmer…" — was the only one posted with
    /// `body: ""`. On macOS a `UNMutableNotificationContent` with no
    /// informative text is accepted by `add` and never presented, which is
    /// indistinguishable from a banner that worked (BRIDGE § Done, T1).
    public static func startingNotification(_ plan: ApplyPlan,
                                            installed: String) -> NotificationRequest {
        NotificationRequest(
            title: "Installing simmer \(plan.target)…",
            subtitle: "Simmer.app will quit and come back",
            body: "Building \(plan.target) from source — a minute or two. "
                + "You are on \(installed) until it lands.",
            sound: false)
    }

    /// One line for `simmer.log`, per apply, per ending — so that "I clicked
    /// Install it now and something happened" is answerable tomorrow.
    ///
    /// The log is listed in CONTRACTS.md § State but is not a machine surface:
    /// `--json` is how anything else asks, so this wording is free to change
    /// the way every other human sentence is.
    public static func applyLogSentence(starting plan: ApplyPlan, owner: String) -> String {
        "update: installing \(plan.target) for \(owner)"
    }

    /// The line for a banner that could not even be queued.
    ///
    /// `simmer.log` is a DIFFERENT file from `notify-spool.jsonl`, which is
    /// the point: the case that loses the banner is a symlink or a full disk
    /// at the spool, and one channel has to survive it (R2 finding 8). It
    /// names the file, because `append` knows only that the line did not land
    /// and `ls -l` in the state directory answers why.
    public static func applyLogSentence(bannerNotQueued plan: ApplyPlan) -> String {
        "update: could not queue the installing banner for \(plan.target) "
            + "— check notify-spool.jsonl in this directory"
    }

    public static func applyLogSentence(_ result: ApplyResult) -> String {
        switch result {
        case .nothingToDo(let sentence):
            return "update: nothing to install — \(sentence)"
        case .refused(let why):
            return "update: refused — \(why)"
        case .failed(let step, let detail, let plan):
            // The phase first: which part stopped is the fact that decides
            // whether anything on this Mac changed, and the command is the
            // evidence behind it.
            return "update: \(plan.target) failed while \(step.phase.rawValue) "
                + "— \(step.described): \(detail)"
        case .installed(let plan, let reopened, let relaunchFailure):
            let app = relaunchFailure.map { "Simmer.app did not come back — \($0)" }
                ?? (reopened ? "Simmer.app relaunched" : "Simmer.app was not running")
            return "update: installed \(plan.target) · \(app)"
        }
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
        // The last word of the click, and it has to arrive. Title + subtitle
        // + `body: ""` is character-for-character the 0.3.1 shape this
        // command's own diagnosis blames for the silence — and with the app
        // not running the subtitle is empty too, so the ending was a
        // title-only banner: no informative text at all, accepted by `add`,
        // never presented (R2 finding 1). The `relaunchFailure` branch below
        // overwrites it, because a menu bar that did not come back is the
        // more important sentence.
        var body = "You are on \(plan.target) now."
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
    ///
    /// Where the plan fetched a release from a remote (`releaseFetch`), the
    /// two install phases also say WHERE it looked — the tag, the checkout and
    /// the remote — because that is the whole of what the 8 Sep failure could
    /// not tell anybody: "Could not switch to simmer 0.3.3. Nothing was
    /// installed." is true of a checkout whose origin lags the release and of
    /// three other things.
    ///
    /// Where it looked, and never **why** it failed. The same arm is reached
    /// by a dirty tree or a stray file in that checkout, and a sentence
    /// asserting "the tag is not there" would be a lie about those; git's own
    /// words are on the second line, where `applyFailed` puts them. For the
    /// same reason the switching case says `Look with:` rather than
    /// `Run: <updateCommand>` — the update command for a bundle install is the
    /// one-paste installer, which fetches the very remote that just failed to
    /// yield the tag, and recommending it is how this defect recommended
    /// itself. `git … status` reads the checkout and is true whatever the
    /// cause.
    public static func failureSentence(phase: ApplyPhase, plan: ApplyPlan,
                                       updateCommand: String) -> String {
        let target = "simmer \(plan.target)"
        let terminal = updateCommand.isEmpty ? "" : " Run: \(updateCommand)"
        switch phase {
        case .fetching:
            // The remote it TRIED, which is the fact this sentence exists for
            // on the day GitHub is unreachable while `origin` is fine — a
            // plan that fetched `origin` never had that case at all.
            let from = plan.releaseFetch.map { " from \($0.remote)" } ?? ""
            return "Could not fetch \(target)\(from). Nothing on this Mac was changed.\(terminal)"
        case .switching:
            guard let fetch = plan.releaseFetch else {
                return "Could not switch to \(target). Nothing was installed.\(terminal)"
            }
            // The two clauses that answer "what happened" and "did anything
            // change" stay first and stay as they were: a banner truncates
            // its body, and what gets cut has to be the diagnostic tail.
            return "Could not switch to \(target). Nothing was installed. "
                + "Looked for the tag \(fetch.tag) in the checkout at \(fetch.checkout), "
                + "after fetching from \(fetch.remote). "
                + "Look with: git -C \(fetch.checkout) status"
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
            // A banner on both branches, because the caller that cannot read
            // either stream is the menu: `applyUpdate` spawns the child with
            // stdout and stderr on /dev/null, so before this the two endings
            // that install nothing were completely silent from a click —
            // the menu bar simply never changed and never said why.
            var banner = Outcome()
            banner.notifications = [NotificationRequest(
                title: "Nothing to install",
                subtitle: "", body: sentence, sound: false)]
            guard json else {
                banner.stdout = ["✅ \(sentence)"]
                return banner
            }
            var outcome = jsonApplyOutcome(report, seamed: seamed, applied: false,
                                           plan: nil, error: nil, exit: 0)
            outcome.notifications = banner.notifications
            return outcome

        case .refused(let why):
            // The refusal sentence names the way that works instead, so it is
            // the whole message and belongs in the body rather than being
            // summarised in a title nobody can act on.
            let notifications = [NotificationRequest(
                title: "simmer did not install the update",
                subtitle: "", body: why, sound: false)]
            guard json else {
                var failure = Outcome.failure(why)
                failure.notifications = notifications
                return failure
            }
            var outcome = jsonApplyOutcome(report, seamed: seamed, applied: false,
                                           plan: nil, error: why, exit: 1)
            outcome.notifications = notifications
            return outcome

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

    /// " (checked 3d ago)", or "" while the cached answer is still young.
    ///
    /// The one place the age is worded, so the menu footer, `doctor`'s row and
    /// a launcher accessory cannot each decide differently. Empty inside the
    /// day the app's check refreshes on: a note on every line teaches the
    /// reader to ignore it, and the case worth marking is the Mac whose app
    /// has not run — where "newest" is a sentence about the week before last.
    ///
    /// A record written by another version does not reach here at all: it is
    /// discarded in `check`, and the verdict is `unknown`.
    public static func cacheNote(_ report: Report) -> String {
        guard report.fromCache, report.checkedAt > 0,
              report.cacheAge >= Ledger.UpdateRecord.maxAge else { return "" }
        return " (checked \(Durations.human(report.cacheAge)) ago)"
    }

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
        return "Update available: \(report.latestDisplay)\(cacheNote(report))"
    }

    /// The banner for a check somebody asked for by hand.
    ///
    /// Silent, and not actionable: there is no Extend/Release to offer and
    /// nothing about an available release needs a sound. The once-a-day
    /// background check reuses this banner through `announcement`, and posts
    /// it at most once per new version — which is the difference between
    /// telling someone what they asked, telling them something once, and
    /// interrupting them daily with the same news.
    ///
    /// **Every arm carries informative text.** `announcement` only ever
    /// passes `.available`, so the other three arms looked unreachable and
    /// two of them were written with `body: ""` — but the app's **Check for
    /// Updates…** calls this directly (`StatusItemController.swift:193`), and
    /// "you are up to date" is that item's commonest answer. A banner with no
    /// informative text is accepted by `add` and never presented, so the
    /// commonest answer to the menu item Luis used was silence (R2 finding 2).
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
                subtitle: "", body: "Nothing to install.", sound: false)
        case .ahead:
            // The subtitle already carries text, so this arm was presented —
            // but "ahead" is the one verdict that leaves a person wondering
            // whether they are meant to do something, and the answer is no.
            return NotificationRequest(
                title: "simmer \(report.installed) is ahead of the newest release",
                subtitle: "newest is \(report.latestDisplay)",
                body: "Nothing to install; a downgrade is not an update.", sound: false)
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
        let age = cacheNote(report)
        switch report.verdict {
        case .current:
            return "simmer \(report.installed) · newest\(age)"
        case .available:
            return "simmer \(report.installed) · newest is \(report.latestDisplay)\(age)"
        case .ahead:
            return "simmer \(report.installed) · ahead of \(report.latestDisplay)\(age)"
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
            // Whether the daily check is allowed to install what it finds.
            // A caller that wants to know why nothing happened on a Mac with
            // a release waiting reads this before anything else.
            ("auto_update", .bool(report.autoUpdate)),
            // The checkout behind this copy, and how it was placed. Two new
            // fields rather than a fifth `provenance` value, because that one
            // is a closed set every reader switches on exhaustively — see
            // CONTRACTS.md § Machine-readable output.
            ("install_source",
             report.install.source.namedPath.map { JSONValue.string($0) } ?? .null),
            ("install_source_kind", .string(report.install.source.name)),
        ])
    }

    public static func jsonOutcome(_ report: Report, seamed: Bool) -> Outcome {
        var outcome = Outcome()
        outcome.stdout = [json(report, seamed: seamed).serialized()]
        if report.verdict == .unknown { outcome.exit = 1 }
        return outcome
    }
}
