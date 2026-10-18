import Foundation
import Testing
@testable import SimmerCore

/// The boot-time heal, gated mechanically: what the daemon may do (put the
/// switch back, nothing else), that the installer and the binary carry the
/// same plist, and that no surface names the daemon's path except the one
/// type that owns it — the same discipline `SudoRuleTests` holds the rule to.
@Suite struct BootHealTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func theDaemonOnlyEverPutsTheSwitchBack() throws {
        let data = Data(BootHeal.plist.utf8)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try #require(object as? [String: Any])
        #expect(dict["Label"] as? String == BootHeal.label)
        #expect(dict["ProgramArguments"] as? [String] == ["/usr/bin/pmset", "-a", "disablesleep", "0"])
        #expect(dict["RunAtLoad"] as? Bool == true)
        // Once at boot, nothing else: no interval, no keep-alive, no watch.
        for key in ["StartInterval", "KeepAlive", "WatchPaths", "StartCalendarInterval"] {
            #expect(dict[key] == nil, "\(key) would make this a second guard")
        }
        #expect(!BootHeal.plist.contains("disablesleep 1"))
        #expect(BootHeal.path == "/Library/LaunchDaemons/\(BootHeal.label).plist")
        #expect(BootHeal.label.hasPrefix("io.github.moralesl.simmer."))
    }

    @Test func theInstallCommandValidatesBeforeItLandsAndNeverLoads() {
        let command = BootHeal.installCommand
        let validate = command.range(of: "plutil -lint")
        let install = command.range(of: "install -m 0644 -o root -g wheel")
        #expect(validate != nil)
        #expect(install != nil)
        if let validate, let install { #expect(validate.upperBound < install.lowerBound) }
        #expect(command.contains(BootHeal.path))
        #expect(command.contains("mktemp"))
        // Loading it now would run the heal under a live claim; boot is its job.
        #expect(!command.contains("launchctl"))
        // Every plist line travels inside the one-liner, verbatim.
        for line in BootHeal.plistLines {
            #expect(command.contains("'\(line)'"), "the install command dropped: \(line)")
        }
    }

    /// bootstrap.sh cannot import Swift, so it carries its own copy of the
    /// plist. Line for line, or an installer writes a daemon `doctor` then
    /// reports as somebody else's.
    @Test func theInstallerAndTheBinaryAgreeOnTheDaemon() throws {
        let bootstrap = try Self.read("bootstrap.sh")
        for line in BootHeal.plistLines {
            #expect(bootstrap.contains(line), "bootstrap.sh is missing the plist line: \(line)")
        }
        #expect(bootstrap.contains(BootHeal.path))
        #expect(bootstrap.contains("plutil -lint"))
        #expect(!bootstrap.contains("launchctl bootstrap system"))
    }

    /// The sweep, for the daemon's path: every surface asks `BootHeal`.
    @Test func nothingOutsideBootHealNamesTheDaemonDirectly() throws {
        var offenders: [String] = []
        let root = Self.repoRoot.appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "BootHeal.swift" }) ?? []
        for file in files {
            let code = (try? String(contentsOf: file, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n") ?? ""
            if code.contains("/Library/LaunchDaemons") || code.contains("boot-heal") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "these name the daemon instead of asking BootHeal: \(offenders)")
    }

    /// The Makefile's uninstall epilogue and SECURITY.md both say what simmer
    /// asks for; the daemon is part of that answer now.
    @Test func theDocumentsNameTheSecondPrivilegedFile() throws {
        for relativePath in ["SECURITY.md", "Makefile", "README.md"] {
            let text = try Self.read(relativePath)
            #expect(text.contains(BootHeal.path), "\(relativePath) does not name \(BootHeal.path)")
        }
    }
}
