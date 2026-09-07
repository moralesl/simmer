import Foundation

/// What a checkout looks like right now — the read that decides whether
/// `update --apply` may move somebody's own repository.
///
/// Behind the seam like every other outside-the-process read (CONTRACTS.md §
/// The test seam), and for the usual reason: this one spawns `git` in a
/// directory the tester chose, and a suite that calls itself hermetic cannot
/// have a probe that answers about whatever repository the fixture path
/// happens to resolve to. A seamed process with no `SIMMER_FAKE_CHECKOUT`
/// reads nothing, exactly as `ReleaseSource` reads nothing without
/// `SIMMER_FAKE_LATEST`.
public protocol CheckoutProbe: Sendable {
    /// Nil when the directory cannot be read as a git checkout at all — which
    /// is a refusal, never a licence to run commands in it anyway.
    func state(of path: String) -> UpdateCommand.CheckoutState?
}

/// `git`, four read-only questions, no network.
///
/// `origin` by name rather than "the first remote": the default branch is only
/// meaningful against the remote the checkout was cloned from, and a
/// checkout with several remotes is one where guessing is the wrong move.
/// Where `refs/remotes/origin/HEAD` is absent — a `--single-branch` clone, or
/// a remote added by hand — the default branch reads empty and the plan
/// refuses with that as the reason, rather than asking the network.
public struct GitCheckoutProbe: CheckoutProbe {
    public let git: String
    public init(git: String = "/usr/bin/git") { self.git = git }

    public func state(of path: String) -> UpdateCommand.CheckoutState? {
        let status = Shell.run(git, ["-C", path, "status", "--porcelain"])
        guard status.status == 0 else { return nil }
        return UpdateCommand.CheckoutState(
            branch: read(["-C", path, "symbolic-ref", "--quiet", "--short", "HEAD"]),
            defaultBranch: withoutRemote(read(["-C", path, "symbolic-ref", "--quiet", "--short",
                                               "refs/remotes/origin/HEAD"])),
            clean: status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            aheadOfUpstream: aheadOfUpstream(path))
    }

    /// How many commits this branch has that its upstream does not.
    ///
    /// Nil when there is no upstream — `rev-list` exits non-zero with "no
    /// upstream configured", and a branch tracking nothing has nothing to
    /// update FROM, which refuses rather than guessing at `origin/main`.
    ///
    /// Local, like every other read here: it compares against this checkout's
    /// idea of the remote rather than fetching one. Stale in the safe
    /// direction — a pushed commit this checkout has not seen the push of
    /// counts as ahead and refuses.
    private func aheadOfUpstream(_ path: String) -> Int? {
        let result = Shell.run(git, ["-C", path, "rev-list", "--count", "@{upstream}..HEAD"])
        guard result.status == 0 else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `origin/main` → `main`. By prefix, so a branch called
    /// `fix/origin/thing` does not lose its middle.
    private func withoutRemote(_ ref: String) -> String {
        ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
    }

    /// Empty for anything that did not answer: a detached head and a missing
    /// `origin/HEAD` are both "cannot say", and both refuse downstream.
    private func read(_ arguments: [String]) -> String {
        let result = Shell.run(git, arguments)
        guard result.status == 0 else { return "" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `SIMMER_FAKE_CHECKOUT=main:main:clean` — branch, the remote's default
/// branch, and `clean` or `dirty`. `absent` answers nil, which is the
/// unreadable case.
///
/// A fourth field says how far ahead of its upstream the branch is:
/// `main:main:clean:2` for two unpushed commits, `main:main:clean:none` for a
/// branch that tracks nothing. **Optional, and absent means zero**, so every
/// three-field value written before this existed still says exactly what it
/// said — the seam is a contracted surface (CONTRACTS.md § The test seam) and
/// contracted surfaces are append-only.
public struct FakeCheckoutProbe: CheckoutProbe {
    public let value: String
    public init(value: String) { self.value = value }

    public func state(of path: String) -> UpdateCommand.CheckoutState? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }

        // A fourth field that is neither `none` nor a number is a typo, and a
        // typo must not quietly mean "in step" — that is the value that lets
        // the plan run.
        var ahead: Int? = 0
        if parts.count == 4 {
            if parts[3] == "none" {
                ahead = nil
            } else if let count = Int(parts[3]), count >= 0 {
                ahead = count
            } else {
                return nil
            }
        }
        return UpdateCommand.CheckoutState(branch: parts[0], defaultBranch: parts[1],
                                           clean: parts[2] == "clean",
                                           aheadOfUpstream: ahead)
    }
}

/// Seamed, but not told what to answer. See the note on `CheckoutProbe`.
public struct SeamedCheckoutProbe: CheckoutProbe {
    public init() {}
    public func state(of path: String) -> UpdateCommand.CheckoutState? { nil }
}
