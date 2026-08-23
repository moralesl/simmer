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
}
