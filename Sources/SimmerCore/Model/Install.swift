import Foundation

/// How this copy of simmer got onto the Mac — and therefore which command
/// updates it.
///
/// "What is the newest release" and "how do you install it" are two questions,
/// and only the first has one answer. Telling a Homebrew user to re-run the
/// one-paste installer would put a second, unmanaged copy next to the managed
/// one; telling someone with a checkout to `brew upgrade` names a formula they
/// do not have. So the version comparison is shared and the instruction is
/// derived from the path the binary is actually running from.
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

    public let kind: Kind
    /// The binary with every symlink resolved. `~/.local/bin/simmer` is a
    /// symlink into the bundle, so the unresolved path places nothing.
    public let executable: String
    /// The `.app` this binary lives in, when it lives in one.
    public let bundle: String?
    /// The checkout root — the directory holding `Package.swift`.
    public let repoRoot: String?

    /// The repository every surface names. One constant, because
    /// `bootstrap.sh` prints the same URL and a second spelling of it would be
    /// a second thing to keep in step.
    public static let repositoryURL = "https://github.com/moralesl/simmer"

    public static func detect(executablePath: String,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> Install {
        let real = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path

        // Homebrew first: a formula installs the bundle inside its Cellar, so
        // the `.app` test below would otherwise claim it and print the wrong
        // update command to the one class of user whose package manager
        // already knows how to update them.
        if real.contains("/Cellar/simmer/") || real.contains("/Cellar/simmer@") {
            return Install(kind: .homebrew, executable: real,
                           bundle: appBundle(containing: real), repoRoot: nil)
        }

        if let app = appBundle(containing: real) {
            return Install(kind: .bundle, executable: real, bundle: app, repoRoot: nil)
        }

        if let root = checkoutRoot(containing: real, exists: exists) {
            return Install(kind: .checkout, executable: real, bundle: nil, repoRoot: root)
        }

        return Install(kind: .unknown, executable: real, bundle: nil, repoRoot: nil)
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
            let root = repoRoot ?? "."
            return "cd \(root) && git pull && make install"
        case .bundle, .unknown:
            return "curl -fsSL \(Self.repositoryURL)/raw/main/bootstrap.sh | bash"
        }
    }

    /// `CFBundleShortVersionString` of the bundle this binary lives in.
    ///
    /// Only ever the enclosing bundle — never `/Applications/Simmer.app` as a
    /// fallback. A binary running from a checkout has no bundle in play, and
    /// reaching for the one that happens to be installed would make every
    /// answer depend on the machine underneath the caller, which is the same
    /// mistake `SIMMER_SKILL_DIR` exists to prevent for the agent protocol.
    public func bundleVersion() -> String? {
        guard let bundle else { return nil }
        let plist = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return root["CFBundleShortVersionString"] as? String
    }

    /// One line of context for the command above, so a person can tell whether
    /// simmer placed them correctly before they paste it.
    public var describedSource: String {
        switch kind {
        case .homebrew: return "installed by Homebrew"
        case .bundle: return "installed as \(bundle.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Simmer.app")"
        case .checkout: return "running from the checkout at \(repoRoot ?? "?")"
        case .unknown: return "installed at \(executable)"
        }
    }
}
