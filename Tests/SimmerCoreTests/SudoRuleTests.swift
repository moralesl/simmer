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
        // The shared file 0.1.0 wrote. Still the fallback for a username
        // `#includedir` cannot represent, and still what an old install has.
        #expect(SudoRule.legacyPath == "/etc/sudoers.d/simmer")

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
        #expect(command.contains(SudoRule.intendedPath(for: "someone")))
        #expect(command.contains("mktemp"))
    }

    /// bootstrap.sh cannot import Swift, so it carries its own copy of the
    /// rule. This is the gate that keeps the copy honest — the failure mode is
    /// an installer writing a rule the app then reports as foreign.
    @Test func theInstallerAndTheAppAgreeOnTheRule() throws {
        let bootstrap = try Self.read("bootstrap.sh")
        #expect(bootstrap.contains(SudoRule.capability))
        #expect(bootstrap.contains("# simmer — flip the sleep switch without a password; nothing else."))
        // The installer composes the per-user name; both halves must agree on
        // the directory and the prefix.
        #expect(bootstrap.contains("/etc/sudoers.d/simmer-$SUDOERS_USER"))
        #expect(bootstrap.contains(SudoRule.legacyPath))
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

/// What sudo actually grants, read from the listing rather than guessed from
/// an exit code.
///
/// `sudo -nl <command>` reports whether a command is PERMITTED, not whether it
/// is permitted without a password — so through the stock `(ALL) ALL` entry it
/// exits 0 on every admin Mac. Measured on one: `sudo -nv` says there is no
/// timestamp and `sudo -nl /bin/sh` still exits 0. `doctor` read that as a
/// granted capability, and told people it came from somebody else's file.
@Suite struct SudoGrantWidthTests {
    /// The real listing from a Mac with simmer installed, verbatim.
    static let installed = """
    Matching Defaults entries for luis on MacBook-Pro-von-Luis:
        env_reset, env_keep+=BLOCKSIZE, lecture_file=/etc/sudo_lecture, !log_allowed

    User luis may run the following commands on MacBook-Pro-von-Luis:
        (ALL) ALL
        (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
    """

    @Test func theStockAdminEntryIsNotAPasswordlessGrant() {
        let grants = SudoRule.grants(inListing: Self.installed)
        // `(ALL) ALL` requires a password. It is the entry that made the old
        // exit-code check answer yes on machines that granted nothing.
        #expect(grants.passwordless == SudoRule.commands)
        #expect(grants.hasSimmersOwn)
        #expect(grants.beyondWhatSimmerNeeds.isEmpty)
        #expect(!grants.hasBlanketGrant)
    }

    @Test func aMacWithNoSimmerRuleGrantsNothing() {
        let listing = """
        User luis may run the following commands on host:
            (ALL) ALL
        """
        let grants = SudoRule.grants(inListing: listing)
        #expect(grants.passwordless.isEmpty)
        #expect(!grants.hasSimmersOwn)
    }

    /// The thing the check exists to notice: a grant wider than the two.
    @Test func aWidenedPmsetGrantIsSeenAsWider() {
        let listing = """
        User luis may run the following commands on host:
            (root) NOPASSWD: /usr/bin/pmset
        """
        let grants = SudoRule.grants(inListing: listing)
        #expect(!grants.hasSimmersOwn)          // the two exact spellings are not there
        #expect(grants.beyondWhatSimmerNeeds == ["/usr/bin/pmset"])
    }

    @Test func aBlanketPasswordlessGrantIsNamedAsOne() {
        let listing = """
        User luis may run the following commands on host:
            (ALL) NOPASSWD: ALL
        """
        let grants = SudoRule.grants(inListing: listing)
        #expect(grants.hasBlanketGrant)
        #expect(!grants.beyondWhatSimmerNeeds.isEmpty)
    }

    /// Simmer's own two, plus somebody else's — which is not simmer's to fix,
    /// but is exactly what "nothing has more grants than it needs" means.
    @Test func anotherToolsPasswordlessRuleShowsUpBesideSimmersOwn() {
        let listing = """
        User luis may run the following commands on host:
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
            (root) NOPASSWD: /usr/local/bin/some-agent --daemon
        """
        let grants = SudoRule.grants(inListing: listing)
        #expect(grants.hasSimmersOwn)
        #expect(grants.beyondWhatSimmerNeeds == ["/usr/local/bin/some-agent --daemon"])
    }

    /// Tag stacking and an explicit PASSWD: reset, both of which sudo emits.
    @Test func tagsAreReadInOrder() {
        let listing = """
        User luis may run the following commands on host:
            (root) NOPASSWD: SETENV: /usr/bin/thing
            (root) NOPASSWD: /usr/bin/a, PASSWD: /usr/bin/b
        """
        let grants = SudoRule.grants(inListing: listing)
        #expect(grants.passwordless.contains("/usr/bin/thing"))
        #expect(!grants.passwordless.contains("/usr/bin/b"))
    }

    /// The Defaults block above the rules must never be mistaken for one — it
    /// is full of commas and colons and would otherwise parse as commands.
    @Test func theDefaultsBlockIsNotARuleList() {
        let listing = """
        Matching Defaults entries for luis on host:
            env_reset, env_keep+="A B", NOPASSWD_LOOKING_THING: x, y

        User luis may run the following commands on host:
            (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
        """
        #expect(SudoRule.grants(inListing: listing).passwordless == ["/usr/bin/pmset -a disablesleep 1"])
    }

    /// The capability string is still assembled from the same two commands, so
    /// bootstrap.sh and this file cannot drift (CI asserts they agree).
    @Test func theCapabilityStringIsBuiltFromTheCommandList() {
        #expect(SudoRule.capability ==
                "ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
    }
}

/// One file per USER. The shared `/etc/sudoers.d/simmer` held a single
/// `<user> ALL=(root) NOPASSWD: …` line, so a second admin running the
/// documented one-paste install overwrote the first admin's — no malice, and
/// the loser's guard then failed `sudo -n pmset` on every tick, forever.
@Suite struct SudoRulePerUserTests {
    @Test func eachUserGetsTheirOwnFile() {
        #expect(SudoRule.path(for: "luis") == "/etc/sudoers.d/simmer-luis")
        #expect(SudoRule.path(for: "alice") != SudoRule.path(for: "bob"))
        #expect(SudoRule.installCommand(user: "luis").contains("/etc/sudoers.d/simmer-luis"))
    }

    /// `#includedir` ignores any filename containing a dot, so a username with
    /// one cannot have a file there at all — and mangling it into a name that
    /// could collide with another user's is the mistake this codebase has made
    /// twice already with claim ids. It falls back to the shared name, which
    /// is the only thing sudo will actually read for them.
    @Test(arguments: ["first.last", "ad\\user", "hé", "", "a b"])
    func aNameSudoCannotRepresentIsNotInvented(_ user: String) {
        #expect(SudoRule.path(for: user) == nil)
        #expect(SudoRule.installCommand(user: user).contains(SudoRule.legacyPath))
    }

    /// An install from 0.1.0 is still found, so `doctor` and `uninstall` can
    /// point at it rather than reporting no rule at all.
    @Test func theSharedFileIsStillLookedFor() {
        #expect(SudoRule.candidatePaths(for: "luis")
            == ["/etc/sudoers.d/simmer-luis", "/etc/sudoers.d/simmer"])
    }

    /// The rule's TEXT is per-user either way — that has always been true, and
    /// it is what makes the shared file lossy in the first place.
    @Test func theRuleNamesTheUserItIsFor() {
        #expect(SudoRule.text(user: "alice").contains("alice ALL=(root) NOPASSWD:"))
        #expect(!SudoRule.text(user: "alice").contains("bob"))
    }
}
