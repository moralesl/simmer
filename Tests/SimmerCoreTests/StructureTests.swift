import Foundation
import Testing
@testable import SimmerCore

/// Two structural decisions that nothing in the code can express, and that a
/// person can therefore undo by accident in one line. They were prose in a
/// document; they are assertions now, which is the only form that survives a
/// contributor who has not read the document.
@Suite struct StructureTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// macOS binds a notification grant to the executable that asked. With two
    /// executables in one bundle, each reads its own state — so a CLI that
    /// links UserNotifications asks questions about the wrong binary and gets
    /// "not determined" forever, while the app's banners work fine. The CLI
    /// therefore must not link the notification code at all; it enqueues into
    /// the spool and the app posts.
    @Test func theCLICannotReachTheNotificationCentre() throws {
        let manifest = try Self.read("Package.swift")
        // Each .executableTarget( … ) block on its own, so the CLI's
        // dependency list cannot be confused with the app's or with the
        // product declarations above them.
        let blocks = manifest.components(separatedBy: ".executableTarget(").dropFirst()
        let cliTarget = blocks.first { $0.contains(#"name: "simmer""#) }
        #expect(cliTarget != nil, "could not find the simmer executable target")
        #expect(cliTarget?.contains("SimmerNotifyKit") == false)
        #expect(cliTarget?.contains("SimmerCore") == true)
        // The app, by contrast, is the one thing that may post.
        let appTarget = blocks.first { $0.contains(#"name: "simmer-app""#) }
        #expect(appTarget?.contains("SimmerNotifyKit") == true)

        // And no source file in the CLI may import it either.
        let cliSources = (try? FileManager.default.contentsOfDirectory(
            at: Self.repoRoot.appendingPathComponent("Sources/SimmerCLI"),
            includingPropertiesForKeys: nil)) ?? []
        #expect(!cliSources.isEmpty)
        for file in cliSources where file.pathExtension == "swift" {
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!source.contains("import UserNotifications"), "\(file.lastPathComponent)")
            #expect(!source.contains("import SimmerNotifyKit"), "\(file.lastPathComponent)")
        }
    }

    /// APFS is case-insensitive by default, so `Contents/MacOS/Simmer` and
    /// `Contents/MacOS/simmer` are the SAME FILE: the second copy silently
    /// overwrites the first and the "app" then runs the CLI's main, prints a
    /// status line and exits. Nothing errors and the bundle even signs, so only
    /// an assertion catches it.
    @Test func theBundlesTwoExecutablesHaveCaseDistinctNames() throws {
        let makefile = try Self.read("Makefile")
        #expect(makefile.contains("Contents/MacOS/simmer-app"))
        #expect(makefile.contains("Contents/MacOS/simmer"))
        #expect(!makefile.contains("Contents/MacOS/Simmer"))

        // The plist must name the app binary, not the CLI.
        let plist = try Self.read("app/Info.plist.template")
        #expect(plist.contains("simmer-app"))

        // Case-insensitively distinct: the two names must not collide.
        #expect("simmer-app".lowercased() != "simmer".lowercased())
    }

    /// Uninstalling deletes the guard, the app, and the CLI binary the
    /// `~/.local/bin` symlink points at — every mechanism on the Mac that can
    /// put the sleep switch back. Run with a claim live, the old recipe left
    /// `pmset -a disablesleep 1` on: no expiry, no indicator, survives reboots
    /// (PLATFORM-FACTS.md), named as the vulnerability in SECURITY.md, and the
    /// recovery command written down nowhere.
    ///
    /// So the recipe hands the machine back first and stops if it could not,
    /// and every path out of here names the manual revert. Asserted because a
    /// Makefile has no type system and this is one line away from being true
    /// again.
    @Test func uninstallHandsTheMachineBackBeforeRemovingTheMeansToDoIt() throws {
        let makefile = try Self.read("Makefile")
        let recipe = makefile.components(separatedBy: "\nuninstall:").last ?? ""
        let body = recipe.components(separatedBy: "\nclean:").first ?? ""
        #expect(body.contains("down --all"))
        #expect(body.contains("sleep_disabled=0"))
        #expect(body.contains("pmset -a disablesleep 0"))
        // The release has to come before the first removal, or it is decoration.
        let release = body.range(of: "down --all")
        let firstRemoval = body.range(of: "launchctl bootout")
        #expect(release != nil && firstRemoval != nil)
        if let release, let firstRemoval {
            #expect(release.lowerBound < firstRemoval.lowerBound)
        }

        // And the CLI's own account of what to remove says the same, for
        // anyone following its printed commands instead of the target.
        let cli = try Self.read("Sources/SimmerCLI/UninstallCLI.swift")
        #expect(cli.contains("pmset -a disablesleep 0"))
        #expect(cli.contains("simmer down --all"))
    }
}
