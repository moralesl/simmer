import Foundation

/// What the newest published release is — the one thing `simmer update`
/// cannot work out locally, and therefore the one side effect it has.
///
/// Behind the seam like every other outside-the-process read (CONTRACTS.md §
/// The test seam). `SIMMER_FAKE_LATEST` substitutes the answer, and a process
/// that is seamed at all and has NOT been given one reads nothing: while a
/// `SIMMER_FAKE_*` variable is in force, nothing this process reports is about
/// this machine, and a live network read would be the single exception. That
/// is also what keeps the suite hermetic without a rule anyone has to
/// remember — the leaked-`caffeinate` lesson, applied before rather than
/// after.
public enum ReleaseLookup: Sendable, Equatable {
    /// The newest release tag, as published — `v0.3.0`.
    case tag(String)
    /// No answer, and the reason in a form a person can act on. Never an
    /// exception: "is there a newer version" is a question whose answer may
    /// legitimately be "cannot tell right now", and a tool that cannot reach
    /// GitHub is not a tool in trouble.
    case unavailable(String)
}

public protocol ReleaseSource: Sendable {
    func newestRelease() -> ReleaseLookup
}

/// GitHub's own `releases/latest` redirect: one `HEAD` request, and the tag is
/// the last path component of where it lands.
///
/// Chosen over `git ls-remote` (which `bootstrap.sh` uses, having git in hand
/// already) and over `api.github.com`. No subprocess, so there is a real
/// request timeout rather than a child to reap; no JSON; and no dependency on
/// git being on PATH, which a future Homebrew formula or any binary
/// distribution would put out of reach. `api.github.com` would answer the same
/// question inside a 60-per-hour unauthenticated budget shared with every
/// other tool on the machine.
public struct GitHubReleaseSource: ReleaseSource {
    public let repositoryURL: String
    public let timeout: TimeInterval
    public let userAgent: String

    public init(repositoryURL: String = Install.repositoryURL,
                timeout: TimeInterval = 3,
                userAgent: String = "simmer/\(SimmerVersion.string)") {
        self.repositoryURL = repositoryURL
        self.timeout = timeout
        self.userAgent = userAgent
    }

    public func newestRelease() -> ReleaseLookup {
        guard let url = URL(string: repositoryURL + "/releases/latest") else {
            return .unavailable("\(repositoryURL) is not a URL")
        }

        // Three seconds, and the deadline is the whole point: this runs in
        // front of a person waiting for a menu to open or a prompt to come
        // back. A check that cannot answer quickly has already failed at the
        // job it was added for, and "could not tell" is a perfectly good
        // answer to print.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let outcome = Locked<ReleaseLookup>(.unavailable("the check did not finish"))
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            defer { done.signal() }
            if let error {
                // The system's own message names the host and the reason
                // ("A server with the specified hostname could not be
                // found."), which is more use than a sentence of ours that
                // flattens every failure into "offline".
                outcome.set(.unavailable(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome.set(.unavailable("no answer from \(url.host ?? "github.com")"))
                return
            }
            guard http.statusCode == 200, let landed = http.url else {
                outcome.set(.unavailable("\(url.host ?? "github.com") answered \(http.statusCode)"))
                return
            }
            // `…/releases/latest` redirects to `…/releases/tag/v0.3.0`, and
            // URLSession followed it, so the tag is where we landed. A
            // repository with no published release does NOT redirect — it
            // answers 404 — which is the case above, correctly, rather than a
            // tag parsed out of the word "latest".
            let tag = landed.lastPathComponent
            guard SemanticVersion(tag) != nil else {
                return outcome.set(.unavailable("\(url.host ?? "github.com") named no release"))
            }
            outcome.set(.tag(tag))
        }
        task.resume()
        // The timeout above is URLSession's, and it is the one that governs;
        // this wait is bounded slightly wider so a session that does answer at
        // the deadline is not cut off half a millisecond before it does.
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return .unavailable("no answer from \(url.host ?? "github.com") within \(Int(timeout))s")
        }
        return outcome.get()
    }
}

/// `SIMMER_FAKE_LATEST=v0.3.0` — or `=error` for the offline path, which needs
/// a test of its own precisely because it is the branch nobody sees until the
/// day GitHub is unreachable.
public struct FakeReleaseSource: ReleaseSource {
    public let value: String
    public init(value: String) { self.value = value }

    public func newestRelease() -> ReleaseLookup {
        value == "error" || value.isEmpty
            ? .unavailable("SIMMER_FAKE_LATEST=\(value.isEmpty ? "(empty)" : value)")
            : .tag(value)
    }
}

/// Seamed, but not told what to answer. See the note on `ReleaseLookup`.
public struct SeamedReleaseSource: ReleaseSource {
    public init() {}
    public func newestRelease() -> ReleaseLookup {
        .unavailable("seamed — set SIMMER_FAKE_LATEST to answer this without the network")
    }
}

/// A box, so the completion handler can hand a value back across the wait
/// without `nonisolated(unsafe)` on a var. Small enough to keep here.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
