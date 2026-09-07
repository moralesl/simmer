import Foundation

/// How this copy of simmer got onto the Mac — and therefore which command
/// updates it.
///
/// "What is the newest release" and "how do you install it" are two questions,
/// and only the first has one answer. Telling a Homebrew user to re-run the
/// one-paste installer would put a second, unmanaged copy next to the managed
/// one; telling someone with a checkout to `brew upgrade` names a formula they
/// do not have. So the version comparison is shared and the instruction is
/// derived from the path the binary is actually running from — and, for a
/// bundle, from the checkout the bundle itself records having been built in.
public struct Install: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// A formula's Cellar. `brew upgrade` owns this copy.
        case homebrew
        /// Inside `Simmer.app` — what `make install` and `bootstrap.sh` leave
        /// behind, with `~/.local/bin/simmer` a symlink into the bundle.
        case bundle
        /// A `swift build` product in a source checkout.
        case checkout
        /// Somewhere else entirely — copied by hand, or a path this cannot
        /// place. Named rather than guessed.
        case unknown
    }

    /// The checkout this copy can be rebuilt from, once the running binary has
    /// been placed.
    ///
    /// The bundle is the same bundle whichever checkout assembled it, so the
    /// path is not something to infer: `make install` stamps `$(CURDIR)` into
    /// the bundle's `Info.plist` and this reads it back. Without that stamp
    /// every bundle was assumed to have come from the installer's checkout,
    /// and a Mac installed from a maintainer's own checkout was told to repair
    /// itself in a directory that does not exist there.
    public enum Source: Sendable, Equatable {
        /// The checkout `bootstrap.sh` maintains at `~/.local/share/simmer`.
        /// Machinery rather than a project anyone works in, which is what
        /// makes moving it onto a tag fair game.
        case installer(String)
        /// A checkout somebody works in, which ran `make install` itself.
        case checkout(String)
        /// A source was recorded and is not there any more — the directory was
        /// moved, renamed or deleted after it installed this copy.
        case gone(String)
        /// Nothing on this Mac to point at: Homebrew, or a bundle with no
        /// source recorded and no installer checkout on disk.
        case none

        /// The checkout to run commands in, or nil when there is not one.
        public var path: String? {
            switch self {
            case .installer(let path), .checkout(let path): return path
            case .gone, .none: return nil
            }
        }

        /// The path this copy is associated with, present or not — so a
        /// caller can report *which* directory went missing rather than only
        /// that one did.
        public var namedPath: String? {
            switch self {
            case .installer(let path), .checkout(let path), .gone(let path): return path
            case .none: return nil
            }
        }

        /// The machine surface's word for this, and the reason `provenance`
        /// did not grow a fifth value: `provenance` is a closed set every
        /// reader switches on exhaustively (`integrations/raycast/src/
        /// simmer.ts` among them), and adding to it would break each of them.
        public var name: String {
            switch self {
            case .installer: return "installer"
            case .checkout: return "checkout"
            case .gone: return "gone"
            case .none: return "none"
            }
        }
    }

    public let kind: Kind
    /// The binary with every symlink resolved. `~/.local/bin/simmer` is a
    /// symlink into the bundle, so the unresolved path places nothing.
    public let executable: String
    /// The `.app` this binary lives in, when it lives in one.
    public let bundle: String?
    /// The checkout root — the directory holding `Package.swift`.
    public let repoRoot: String?
    /// What the bundle says it was built from, verbatim and unchecked. Nil for
    /// anything that is not a bundle, and for a bundle installed by a simmer
    /// older than the stamp.
    public let recordedSource: String?
    /// `recordedSource` placed against this Mac.
    public let source: Source
    /// `CFBundleShortVersionString` of the enclosing bundle, read once when
    /// this copy was placed.
    public let bundleShortVersion: String?

    /// The repository every surface names. One constant, because
    /// `bootstrap.sh` prints the same URL and a second spelling of it would be
    /// a second thing to keep in step.
    public static let repositoryURL = "https://github.com/moralesl/simmer"

    /// Where `bootstrap.sh` puts the checkout it installs from, relative to
    /// `$HOME`.
    public static let installerCheckout = ".local/share/simmer"

    /// The key `make install` stamps the installing checkout into.
    public static let sourceKey = "SimmerInstallSource"

    public static func detect(executablePath: String,
                              home: String,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                              plist: (String) -> [String: Any]? = Install.readPlist)
        -> Install {
        let real = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path

        // Homebrew first: a formula installs the bundle inside its Cellar, so
        // the `.app` test below would otherwise claim it and print the wrong
        // update command to the one class of user whose package manager
        // already knows how to update them.
        if real.contains("/Cellar/simmer/") || real.contains("/Cellar/simmer@") {
            let app = appBundle(containing: real)
            return Install(kind: .homebrew, executable: real, bundle: app, repoRoot: nil,
                           recordedSource: nil, source: .none,
                           bundleShortVersion: app.flatMap { shortVersion(of: $0, plist: plist) })
        }

        if let app = appBundle(containing: real) {
            let info = plist(app)
            let recorded = (info?[sourceKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Install(kind: .bundle, executable: real, bundle: app, repoRoot: nil,
                           recordedSource: recorded,
                           source: place(recorded: recorded, home: home, exists: exists),
                           bundleShortVersion: info?["CFBundleShortVersionString"] as? String)
        }

        if let root = checkoutRoot(containing: real, exists: exists) {
            return Install(kind: .checkout, executable: real, bundle: nil, repoRoot: root,
                           recordedSource: nil, source: .checkout(root),
                           bundleShortVersion: nil)
        }

        // Not in a bundle and not in a checkout, so there is no stamp to read
        // — but the installer's checkout may still be on this Mac, and it is
        // what `bootstrap.sh` would repair from.
        return Install(kind: .unknown, executable: real, bundle: nil, repoRoot: nil,
                       recordedSource: nil,
                       source: place(recorded: nil, home: home, exists: exists),
                       bundleShortVersion: nil)
    }

    /// The recorded path, against what is actually on this Mac.
    ///
    /// Only the directory's existence is asked here. What that directory can
    /// still *do* is two further questions with two different answers — the
    /// Raycast row needs an `integrations/raycast/package.json` and nothing
    /// else, an update plan needs `.git` and a `Makefile` — and each is asked
    /// where it is used. Collapsing them here is how "there is no checkout to
    /// compare against" came to be printed about a directory that was there.
    ///
    /// A recorded directory that is gone is `.gone` rather than "no checkout":
    /// "the directory you installed from has moved" is the sentence that
    /// explains the machine, and it names which one.
    private static func place(recorded: String?, home: String,
                              exists: (String) -> Bool) -> Source {
        let installer = URL(fileURLWithPath: home)
            .appendingPathComponent(installerCheckout).path
        guard let recorded else {
            // No stamp: a bundle from before the stamp existed, or one this
            // cannot read. The installer's checkout is where those came from
            // if they came from anywhere, so it is the one path worth trying.
            return exists(installer) ? .installer(installer) : .none
        }
        guard exists(recorded) else { return .gone(recorded) }
        return isSamePath(recorded, installer) ? .installer(recorded) : .checkout(recorded)
    }

    /// The recorded path against the installer's, symlinks resolved.
    ///
    /// `make` reports `$(CURDIR)` with symlinks already resolved, and a home
    /// directory behind one — a `~` moved to another volume — would otherwise
    /// make `bootstrap.sh`'s own checkout read as somebody's working
    /// repository. It would then be pulled rather than moved onto the tag,
    /// and, being on a detached tag, refused. The same resolution
    /// `Install.detect` already does to the executable path.
    private static func isSamePath(_ one: String, _ other: String) -> Bool {
        one == other
            || URL(fileURLWithPath: one).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: other).resolvingSymlinksInPath().path
    }

    /// The enclosing `.app`, by walking up from `…/Contents/MacOS/simmer`.
    /// String-matching `.app` alone would also match a directory someone
    /// happens to have called that.
    private static func appBundle(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { return url.path }
        }
        return nil
    }

    /// The checkout root: the nearest ancestor holding both `Package.swift`
    /// and `.git`. Both, because a `Package.swift` on its own is any Swift
    /// package — including one vendored inside somebody else's tree — and
    /// `git pull` in it would be an instruction about the wrong repository.
    private static func checkoutRoot(containing path: String,
                                     exists: (String) -> Bool) -> String? {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path != "/" {
            if exists(url.appendingPathComponent("Package.swift").path),
               exists(url.appendingPathComponent(".git").path) {
                return url.path
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// A bundle's `Info.plist`, as a dictionary. The one place this file is
    /// read, so the version and the recorded source cost one read between them.
    public static func readPlist(bundle: String) -> [String: Any]? {
        let plist = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return root
    }

    private static func shortVersion(of bundle: String,
                                     plist: (String) -> [String: Any]?) -> String? {
        plist(bundle)?["CFBundleShortVersionString"] as? String
    }

    /// The exact command that updates THIS copy — shown, never run.
    ///
    /// `simmer uninstall` established the shape and the reason: an operation
    /// that happens rarely, in front of a person who is already at a keyboard,
    /// is better as a command they can read first than as a button that
    /// rebuilds and replaces a running app on their behalf. It matters more
    /// here than there, because an update can land while a claim is live.
    public var updateCommand: String {
        switch kind {
        case .homebrew:
            return "brew upgrade simmer"
        case .checkout:
            return "cd \(repoRoot ?? ".") && git pull && make install"
        case .bundle, .unknown:
            // A bundle built in somebody's own checkout is updated the way
            // that checkout is updated. Sending them to `bootstrap.sh`
            // instead would leave a second, unmanaged copy beside the one
            // they build — the same mistake as telling a Homebrew user to
            // paste the installer.
            if case .checkout(let path) = source {
                return "cd \(path) && git pull && make install"
            }
            return "curl -fsSL \(Self.repositoryURL)/raw/main/bootstrap.sh | bash"
        }
    }

    /// What puts this copy back the way it should be, from what is already on
    /// disk — the answer to `doctor`'s "anything red above is fixed by".
    ///
    /// Not the same question as `updateCommand`: repairing is re-running the
    /// install this copy came from, at the version it already has, and only
    /// where there is still a checkout to run it in.
    public var repairCommand: String? {
        switch kind {
        case .homebrew:
            return "brew reinstall simmer"
        case .checkout, .bundle, .unknown:
            return source.path.map { "make -C \($0) install" }
        }
    }

    /// `CFBundleShortVersionString` of the bundle this binary lives in.
    ///
    /// Only ever the enclosing bundle — never `/Applications/Simmer.app` as a
    /// fallback. A binary running from a checkout has no bundle in play, and
    /// reaching for the one that happens to be installed would make every
    /// answer depend on the machine underneath the caller, which is the same
    /// mistake `SIMMER_SKILL_DIR` exists to prevent for the agent protocol.
    public func bundleVersion() -> String? { bundleShortVersion }

    /// One line of context for the command above, so a person can tell whether
    /// simmer placed them correctly before they paste it.
    public var describedSource: String {
        switch kind {
        case .homebrew:
            return "installed by Homebrew"
        case .checkout:
            return "running from the checkout at \(repoRoot ?? "?")"
        case .bundle:
            let app = bundle.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Simmer.app"
            switch source {
            case .checkout(let path):
                return "installed as \(app) from the checkout at \(path)"
            case .gone(let path):
                return "installed as \(app) from \(path), which is no longer there"
            case .installer, .none:
                return "installed as \(app)"
            }
        case .unknown:
            return "installed at \(executable)"
        }
    }
}
