import Foundation
import Testing

@testable import SimmerCore

/// Whether the registered Raycast extension is behind the checkout — decided
/// against fixtures, with the two filesystem reads passed in, so no machine
/// has to be in any particular state.
///
/// The row this feeds is informational in every state and absent in most of
/// them, so the cases worth pinning are the ones where it must stay quiet:
/// no Raycast, no extension, nothing to compare against.
@Suite struct RaycastExtensionTests {
    /// A manifest with the commands named, shaped like a real one — Raycast
    /// copies each command's declaration into the registered copy verbatim,
    /// which is what makes comparing them sound.
    private func manifest(_ commands: [String], subtitle: String = "") -> Data {
        let declarations = commands.map { name in
            """
            {"name":"\(name)","title":"Simmer \(name)","mode":"view"\
            \(subtitle.isEmpty ? "" : ",\"subtitle\":\"\(subtitle)\"")}
            """
        }
        return Data("""
        {"name":"simmer","title":"Simmer","commands":[\(declarations.joined(separator: ","))]}
        """.utf8)
    }

    /// A world: which directories list what, and which paths read as what.
    private struct World {
        var dirs: [String: [String]] = [:]
        var files: [String: Data] = [:]

        func verdict(extensionsDir: String = "/home/.config/raycast/extensions",
                     comparison: RaycastExtension.Comparison
                         = .against("/home/.local/share/simmer")) -> RaycastExtension.Verdict {
            RaycastExtension.inspect(extensionsDir: extensionsDir, comparison: comparison,
                                     read: { files[$0] }, entries: { dirs[$0] })
        }
    }

    private static let extensions = "/home/.config/raycast/extensions"
    private static let installed = "\(extensions)/simmer"
    private static let declared =
        "/home/.local/share/simmer/integrations/raycast/package.json"

    private func world(installedCommands: [String], built: [String],
                       declaredCommands: [String],
                       installedSubtitle: String = "", declaredSubtitle: String = "") -> World {
        var world = World()
        world.dirs[Self.extensions] = ["simmer", "some-other-extension"]
        world.dirs[Self.installed] = built.map { "\($0).js" }
            + built.map { "\($0).js.map" } + ["package.json", "assets"]
        world.files["\(Self.installed)/package.json"] =
            manifest(installedCommands, subtitle: installedSubtitle)
        world.files[Self.declared] = manifest(declaredCommands, subtitle: declaredSubtitle)
        return world
    }

    @Test func matchingManifestsAreCurrent() {
        let six = ["status", "claims", "claim", "extend", "release", "cap"]
        let verdict = world(installedCommands: six, built: six, declaredCommands: six).verdict()
        #expect(verdict == .current(commands: 6))
    }

    /// The case this row exists for, and the case that was live on the
    /// maintainer's Mac when it was written: a release added a command and
    /// nothing rebuilt the extension, so the command is simply not in the
    /// root search and nothing anywhere says so.
    @Test func aCommandTheCheckoutDeclaresAndRaycastDoesNotHave() {
        let six = ["status", "claims", "claim", "extend", "release", "cap"]
        let verdict = world(installedCommands: six, built: six,
                            declaredCommands: six + ["check-updates"]).verdict()
        #expect(verdict == .stale(missing: ["check-updates"], changed: []))
    }

    /// In the manifest and never built is not a command anybody can run, so
    /// both halves have to agree before it counts as present. `.js.map` sits
    /// beside every built command and must not be mistaken for one.
    @Test func aCommandInTheManifestWithNothingBuiltIsMissing() {
        let verdict = world(installedCommands: ["status", "claims"], built: ["status"],
                            declaredCommands: ["status", "claims"]).verdict()
        #expect(verdict == .stale(missing: ["claims"], changed: []))
    }

    /// The same commands declaring different things — a retitled command, a
    /// changed refresh interval, a new argument. Caught because the
    /// declaration is compared, not just the name.
    @Test func aCommandThatChangedWhatItDeclares() {
        let two = ["status", "claims"]
        let verdict = world(installedCommands: two, built: two, declaredCommands: two,
                            installedSubtitle: "", declaredSubtitle: "↵ once to start").verdict()
        #expect(verdict == .stale(missing: [], changed: ["status", "claims"]))
    }

    /// Key order is not a change. Two manifests that say the same thing in a
    /// different order would otherwise report every command as changed.
    @Test func keyOrderIsNotAChange() {
        var world = World()
        world.dirs[Self.extensions] = ["simmer"]
        world.dirs[Self.installed] = ["status.js", "package.json"]
        world.files["\(Self.installed)/package.json"] = Data("""
        {"commands":[{"mode":"view","title":"Simmer status","name":"status"}]}
        """.utf8)
        world.files[Self.declared] = Data("""
        {"commands":[{"name":"status","title":"Simmer status","mode":"view"}]}
        """.utf8)
        #expect(world.verdict() == .current(commands: 1))
    }

    /// An uninstalled Raycast is not a finding, and a row about it would be a
    /// row about nothing — the same rule that omits `agent_protocol` where
    /// there is no `~/.claude`.
    @Test func noRaycastMeansNoRow() {
        var world = World()
        world.files[Self.declared] = manifest(["status"])
        #expect(world.verdict() == .absent)
    }

    @Test func noExtensionMeansNoRow() {
        var world = World()
        world.dirs[Self.extensions] = ["some-other-extension"]
        world.files[Self.declared] = manifest(["status"])
        #expect(world.verdict() == .absent)
    }

    /// Raycast keeps a support directory per extension under the same name
    /// whether or not one is registered, so a directory with no manifest in it
    /// is not evidence of an install.
    @Test func aDirectoryWithNoManifestIsNotAnInstall() {
        var world = World()
        world.dirs[Self.extensions] = ["simmer"]
        world.dirs[Self.installed] = ["com.raycast.api.cache"]
        world.files[Self.declared] = manifest(["status"])
        #expect(world.verdict() == .absent)
    }

    /// The live case on the maintainer's Mac: the installer's checkout sat at
    /// a tag from before the extension existed, so there is no
    /// `integrations/raycast` to compare against. ℹ, never red — "I cannot
    /// tell" is not "you are broken".
    @Test func aCheckoutWithNoExtensionInItCannotBeCompared() {
        var world = World()
        world.dirs[Self.extensions] = ["simmer"]
        world.dirs[Self.installed] = ["status.js", "package.json"]
        world.files["\(Self.installed)/package.json"] = manifest(["status"])
        guard case .unknown(let why) = world.verdict() else {
            #expect(Bool(false), "\(world.verdict())")
            return
        }
        #expect(why.contains("integrations/raycast"))
    }

    /// A formula builds in a prefix `brew` cleans up, so there is no checkout
    /// on this Mac at all.
    @Test func homebrewHasNoCheckoutToCompareAgainst() {
        var world = World()
        world.dirs[Self.extensions] = ["simmer"]
        world.dirs[Self.installed] = ["status.js", "package.json"]
        world.files["\(Self.installed)/package.json"] = manifest(["status"])
        let brew = RaycastExtension.Comparison
            .impossible("a Homebrew install has no checkout to compare it against")
        guard case .unknown(let why) = world.verdict(comparison: brew) else {
            #expect(Bool(false), "\(world.verdict(comparison: brew))")
            return
        }
        #expect(why.contains("Homebrew"))
    }

    /// A manifest that is not one answers nothing rather than guessing —
    /// `dist/` debris, a half-written file, a directory Raycast is mid-build in.
    @Test func anUnreadableManifestIsNotAFinding() {
        var world = World()
        world.dirs[Self.extensions] = ["simmer"]
        world.dirs[Self.installed] = ["status.js", "package.json"]
        world.files["\(Self.installed)/package.json"] = Data("not json".utf8)
        world.files[Self.declared] = manifest(["status"])
        #expect(world.verdict() == .absent)
    }

    /// Which checkout follows provenance, for the same reason
    /// `updateCommand` does: the answer depends on how this copy got here —
    /// and, for a bundle, on the checkout the bundle itself records.
    @Test func theCheckoutFollowsProvenance() {
        let installer = "/Users/x/\(Install.installerCheckout)"
        let bundle = Install.detect(
            executablePath: "/Applications/Simmer.app/Contents/MacOS/simmer",
            home: "/Users/x",
            exists: { $0.hasPrefix(installer) })
        #expect(RaycastExtension.comparison(for: bundle) == .against(installer))

        // Only the root carries both markers; the intermediate directories
        // must not, or the walk up the tree stops at the first one.
        let own = Install.detect(
            executablePath: "/Users/dev/simmer/.build/debug/simmer",
            home: "/Users/dev",
            exists: { ["/Users/dev/simmer/Package.swift", "/Users/dev/simmer/.git"].contains($0) })
        #expect(RaycastExtension.comparison(for: own) == .against("/Users/dev/simmer"))

        let brew = Install.detect(
            executablePath: "/opt/homebrew/Cellar/simmer/0.3.0/Simmer.app/Contents/MacOS/simmer",
            home: "/Users/x",
            exists: { _ in true })
        guard case .impossible(let why) = RaycastExtension.comparison(for: brew) else {
            #expect(Bool(false), "Homebrew has no checkout to compare against")
            return
        }
        #expect(why.contains("Homebrew"))
    }

    /// A bundle assembled in somebody's own checkout is compared against THAT
    /// checkout. Before the bundle recorded where it came from, this row said
    /// "~/.local/share/simmer has no integrations/raycast to compare it
    /// against" on a Mac whose checkout was sitting one directory away.
    @Test func aBundleFromACheckoutIsComparedAgainstIt() {
        let mine = "/Users/luis/workspace/tools/simmer"
        let bundle = Install.detect(
            executablePath: "/Users/luis/Applications/Simmer.app/Contents/MacOS/simmer",
            home: "/Users/luis",
            exists: { $0.hasPrefix(mine) },
            plist: { _ in [Install.sourceKey: mine] })
        #expect(RaycastExtension.comparison(for: bundle) == .against(mine))
    }

    /// The directory it was installed from is gone. "There is no checkout" is
    /// true and useless; naming the one that went missing is what a person
    /// can act on.
    @Test func aVanishedSourceIsNamedRatherThanCalledAbsent() {
        let bundle = Install.detect(
            executablePath: "/Users/luis/Applications/Simmer.app/Contents/MacOS/simmer",
            home: "/Users/luis",
            exists: { _ in false },
            plist: { _ in [Install.sourceKey: "/Users/luis/old/simmer"] })
        guard case .impossible(let why) = RaycastExtension.comparison(for: bundle) else {
            #expect(Bool(false), "a checkout that is not there cannot be compared against")
            return
        }
        #expect(why.contains("/Users/luis/old/simmer"))
    }

    /// The fix is `npm run dev`, not `npm run build`, because a doctor row
    /// that hands out a command which does not fix the thing it reported is
    /// worse than no row. `ray build` is not even the harmless alternative it
    /// reads as: with no `-o` it writes into the registered extension itself.
    @Test func theFixRegistersRatherThanJustBuilds() {
        let lines = RaycastExtension.fixLines(checkout: "/Users/x/.local/share/simmer")
        #expect(lines.joined().contains("npm run dev"))
        #expect(!lines.joined().contains("npm run build"))
        #expect(lines.joined().contains("integrations/raycast"))
    }
}
