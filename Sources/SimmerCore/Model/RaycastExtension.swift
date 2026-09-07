import Foundation

/// The one installed part of simmer that `make install` never touches.
///
/// The extension in `integrations/raycast/` is a fourth renderer over the same
/// contract, but it is TypeScript with its own npm tree, registered with
/// Raycast by `npm run dev` and built by Raycast rather than by the Makefile.
/// So an update can move the CLI, the app, the guard and the agent protocol
/// forward and leave the launcher surface exactly where it was — silently, in
/// the same way a stale agent protocol is silent: the commands keep working,
/// the ones that were added are simply not there, and nothing anywhere says so.
///
/// This is what `doctor` reads to say so. Informational, never red, for the
/// reason `agent_protocol` is: an out-of-date renderer is not a broken install,
/// and a row that can go red for it teaches the reader to skim the rows that
/// mean something.
///
/// **There is no version to compare.** Raycast's own documentation is explicit
/// — "during development, developers do not declare a version property in the
/// manifest" — so an extension carries no version, no build stamp and no tag.
/// What both sides do carry is the *manifest*: Raycast copies each command's
/// declaration into the registered copy verbatim, so the comparison is the set
/// of commands and what each one declares. That is a fact rather than an
/// inference, and — unlike comparing build and source timestamps — it stays
/// true when the extension was registered from a different checkout than the
/// one this binary knows about, which is the normal case for a bundle install.
public enum RaycastExtension {
    /// `name` in the manifest, which is also the directory Raycast builds the
    /// extension into.
    public static let name = "simmer"

    /// Where a checkout keeps the extension's source.
    public static let checkoutSubpath = "integrations/raycast"

    /// Where a locally built extension lands, relative to `$HOME`.
    ///
    /// Established by looking on a Mac that has it: `~/.config/raycast/
    /// extensions/<name>/` holds the built `<command>.js` per command plus the
    /// manifest Raycast registered. `~/Library/Application Support/
    /// com.raycast.macos/extensions/<name>/` is a different thing — the
    /// extension's own support/cache path — and Raycast's databases are
    /// encrypted, so neither is a place to read this from.
    public static let extensionsSubpath = ".config/raycast/extensions"

    /// The commands a manifest declares, and what each one declares.
    ///
    /// The declaration is held as its canonical JSON text rather than as a
    /// parsed shape: this type compares, it never renders, and a canonical
    /// string cannot quietly ignore a field that Raycast cares about and this
    /// model has not heard of.
    struct Manifest: Equatable {
        var declarations: [String: String]
        /// Declared order, so the report names commands the way the manifest does.
        var order: [String]

        init?(_ data: Data) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commands = root["commands"] as? [[String: Any]]
            else { return nil }
            var declarations: [String: String] = [:]
            var order: [String] = []
            for command in commands {
                guard let name = command["name"] as? String, !name.isEmpty else { continue }
                order.append(name)
                declarations[name] = Self.canonical(command)
            }
            guard !order.isEmpty else { return nil }
            self.declarations = declarations
            self.order = order
        }

        /// Key-sorted JSON, so two manifests that say the same thing in a
        /// different key order compare equal.
        private static func canonical(_ command: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: command, options: [.sortedKeys])
            else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// No row at all. Raycast is not installed, or the extension is not —
        /// an uninstalled launcher is not a finding, and a line about it would
        /// be a line about nothing (the same rule that omits `agent_protocol`
        /// where there is no `~/.claude`).
        case absent
        /// The registered extension declares everything the checkout does.
        case current(commands: Int)
        /// `missing`: declared in the checkout, and not something the
        /// registered copy can run — absent from its manifest, or in it with no
        /// built `<name>.js` beside it.
        /// `changed`: present on both sides, declaring different things.
        case stale(missing: [String], changed: [String])
        /// The extension is installed and one side cannot be read. ℹ, never
        /// red: "I cannot tell" is not "you are broken".
        case unknown(String)
    }

    /// Which checkout this extension is supposed to match.
    ///
    /// Derived from provenance for the same reason `updateCommand` is: the
    /// answer depends on how this copy got here, never on a preference. A
    /// Homebrew install has no checkout on disk at all — the formula builds in
    /// a prefix `brew` cleans up — so there is nothing to compare against, and
    /// that is an absence rather than a fault.
    public static func checkout(for install: Install, home: String) -> String? {
        switch install.kind {
        case .checkout:
            return install.repoRoot
        case .bundle, .unknown:
            return URL(fileURLWithPath: home)
                .appendingPathComponent(UpdateCommand.installerCheckout).path
        case .homebrew:
            return nil
        }
    }

    /// The verdict, with the two filesystem reads passed in.
    ///
    /// Closures rather than direct calls, exactly as `Install.detect` and
    /// `applyPlan` take `exists`: the decision is then testable against
    /// fixtures that no machine has to be in, and the seam
    /// (`SIMMER_FAKE_RAYCAST`) has one place to substitute.
    ///
    /// `entries` returns nil for anything that is not a readable directory,
    /// which is how "Raycast is not installed" and "the extension is not
    /// registered" are told apart from each other.
    public static func inspect(extensionsDir: String,
                               checkout: String?,
                               read: (String) -> Data?,
                               entries: (String) -> [String]?) -> Verdict {
        guard entries(extensionsDir) != nil else { return .absent }
        let installedDir = URL(fileURLWithPath: extensionsDir)
            .appendingPathComponent(name).path
        guard let built = entries(installedDir) else { return .absent }
        guard let installedData = read(installedDir + "/package.json"),
              let installed = Manifest(installedData)
        else {
            // The directory is there and the manifest is not: Raycast keeps a
            // support directory per extension under this name whether or not
            // an extension is registered, so this is not evidence of an
            // install. Absent, not unknown.
            return .absent
        }

        guard let checkout else {
            return .unknown("the Raycast extension is registered, "
                + "but a Homebrew install has no checkout to compare it against")
        }
        let declaredPath = URL(fileURLWithPath: checkout)
            .appendingPathComponent(checkoutSubpath)
            .appendingPathComponent("package.json").path
        guard let declaredData = read(declaredPath), let declared = Manifest(declaredData) else {
            return .unknown("the Raycast extension is registered, but \(checkout) "
                + "has no \(checkoutSubpath) to compare it against")
        }

        // A command Raycast has in its manifest but never built is a command
        // that is not there, so both halves have to agree before it counts as
        // present. `.js.map` files sit beside the built commands and do not
        // end in `.js`.
        let compiled = Set(built.filter { $0.hasSuffix(".js") }.map { String($0.dropLast(3)) })
        var missing: [String] = []
        var changed: [String] = []
        for command in declared.order {
            guard let theirs = installed.declarations[command], compiled.contains(command) else {
                missing.append(command)
                continue
            }
            if theirs != declared.declarations[command] { changed.append(command) }
        }
        guard missing.isEmpty, changed.isEmpty else {
            return .stale(missing: missing, changed: changed)
        }
        return .current(commands: declared.order.count)
    }

    /// `doctor`'s sentence, and the fix under it.
    ///
    /// The fix is `npm run dev`, not `npm run build`. `ray build` produces the
    /// store's artifact and registers nothing; `ray develop` is what hands the
    /// built extension to Raycast — and it needs a live TTY, so it is a
    /// command a person runs in a terminal and then interrupts, which is what
    /// `integrations/raycast/README.md` documents and what this must not
    /// contradict.
    public static func fixLines(checkout: String) -> [String] {
        ["  cd \(checkout)/\(checkoutSubpath) && npm ci && npm run dev",
         "  it needs a terminal; ⌃C once Raycast has it — integrations/raycast/README.md"]
    }
}
