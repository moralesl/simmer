import Foundation
import Testing
@testable import SimmerCore

/// The privileged step, gated mechanically. These are the checks that keep a
/// future edit from widening what simmer asks for, from letting the installer
/// and the app drift apart on the rule text, or from quietly reintroducing
/// self-escalation — each of which is a decision, not a detail.
@Suite struct SudoRuleTests {
    /// The repository this test file lives in: Tests/SimmerCoreTests/<file>.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func theCapabilityIsExactlyTwoInvocationsAndNothingElse() {
        // No wildcard, no bare pmset, no second binary. If this assertion has
        // to change, the scope of what simmer asks for is changing with it.
        #expect(SudoRule.capability ==
            "ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
        #expect(!SudoRule.capability.contains("*"))
        #expect(!SudoRule.capability.contains("ALL:ALL"))
        #expect(SudoRule.path == "/etc/sudoers.d/simmer")

        let text = SudoRule.text(user: "someone")
        #expect(text.hasPrefix("# simmer"))
        #expect(text.contains("someone \(SudoRule.capability)"))
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test func theInstallCommandValidatesBeforeItLands() {
        let command = SudoRule.installCommand(user: "someone")
        // visudo -c must come before install, or a typo can break sudo
        // entirely (PLATFORM-FACTS.md).
        let validate = command.range(of: "visudo -c")
        let install = command.range(of: "install -m 0440 -o root -g wheel")
        #expect(validate != nil)
        #expect(install != nil)
        if let validate, let install { #expect(validate.upperBound < install.lowerBound) }
        // Landing as root-owned 0440 is what makes sudoers accept it at all.
        #expect(command.contains(SudoRule.path))
        #expect(command.contains("mktemp"))
    }

    /// bootstrap.sh cannot import Swift, so it carries its own copy of the
    /// rule. This is the gate that keeps the copy honest — the failure mode is
    /// an installer writing a rule the app then reports as foreign.
    @Test func theInstallerAndTheAppAgreeOnTheRule() throws {
        let bootstrap = try Self.read("bootstrap.sh")
        #expect(bootstrap.contains(SudoRule.capability))
        #expect(bootstrap.contains("# simmer — flip the sleep switch without a password; nothing else."))
        #expect(bootstrap.contains(SudoRule.path))
    }

    /// simmer never escalates its own privileges. `osascript … with
    /// administrator privileges` is how that would come back — as an
    /// app-composed shell string running as root — so its absence is asserted
    /// rather than remembered.
    @Test func nothingEscalatesItsOwnPrivileges() throws {
        for relativePath in ["bootstrap.sh", "Sources/SimmerApp/SetupWindow.swift"] {
            let source = try Self.read(relativePath)
            #expect(!source.contains("with administrator privileges"))
            #expect(!source.contains("AuthorizationExecuteWithPrivileges"))
            #expect(!source.lowercased().contains("osascript"))
        }
    }

    /// The installer must survive being cut off mid-download: everything is
    /// inside functions, invoked by one call on the last line.
    @Test func theInstallerIsTruncationSafe() throws {
        let bootstrap = try Self.read("bootstrap.sh")
        #expect(bootstrap.contains("main() {"))
        let lastRealLine = bootstrap
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(lastRealLine == "main \"$@\"")
    }
}
