import Foundation
import Testing

/// Notification routing, tested hermetically at the spool: the app is the
/// only process that ever posts (macOS binds the grant to the executable —
/// PLATFORM-FACTS.md), so what the CLI and the guard *enqueue* is exactly the
/// contract to assert. Once-ness, silence and the action buttons are all
/// here, without a single real banner.
extension Sim {
    func spoolEntries() -> [[String: Any]] {
        guard let text = try? String(contentsOf: stateDir.appendingPathComponent("notify-spool.jsonl"),
                                     encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func spoolTitles() -> [String] {
        spoolEntries().compactMap { $0["title"] as? String }
    }

    /// The default harness env mutes notifications; these tests turn them on.
    static let notifying = ["SIMMER_NOTIFY": "app"]
}

@Suite struct NotificationRoutingTests {
    @Test func aClaimQueuesExactlyOneActionableBanner() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["15m", "--owner", "terminal"], env: Sim.notifying)
        let entries = sim.spoolEntries()
        #expect(entries.count == 1)
        #expect((entries.first?["title"] as? String)?.contains("Simmering until") == true)
        // The Extend/Release buttons ride on CLI-triggered banners too.
        #expect(entries.first?["actionable"] as? Bool == true)
        #expect(entries.first?["v"] as? Int == 1)
        #expect(entries.first?["ts"] as? Int == Sim.epoch)
    }

    /// The menu bar has no text channel — `AppState.perform` posts
    /// notifications and throws stdout away — so "the ceiling is still there"
    /// arrives inside the banner sleep-allowed was already posting. One click,
    /// one banner: a second one competing with it is how banners get dismissed
    /// unread.
    @Test func handingTheMachineBackSaysTheCeilingSurvivedIt() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["cap", "3h", "--owner", "menubar"])
        sim.run(["1h", "--owner", "menubar"])
        let before = sim.spoolEntries().count

        sim.run(["down", "--owner", "menubar"], env: Sim.notifying)
        let posted = Array(sim.spoolEntries().dropFirst(before))
        #expect(posted.count == 1)
        #expect((posted.first?["title"] as? String)?.contains("Sleep allowed again") == true)
        let body = posted.first?["body"] as? String ?? ""
        #expect(body.contains("ceiling stays"))
        #expect(body.contains("09:00"))   // and when it stops standing
    }

    /// ...and only when there is a ceiling to survive. A line on every release
    /// would be the noise that teaches people to skim the banner.
    @Test func handingItBackWithNoCapAddsNothing() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["1h", "--owner", "menubar"])
        let before = sim.spoolEntries().count
        sim.run(["down", "--owner", "menubar"], env: Sim.notifying)
        let posted = Array(sim.spoolEntries().dropFirst(before))
        #expect(posted.count == 1)
        #expect((posted.first?["body"] as? String ?? "").isEmpty)
    }

    @Test func aRepeatClickInsideTheSameMinuteIsNotNews() {
        let sim = Sim(); defer { sim.tearDown() }
        // The double-banner from the first live install: two clicks, seconds
        // apart, both formatting the same HH:MM.
        sim.run(["15m", "--owner", "menubar"], env: Sim.notifying)
        sim.run(["15m", "--owner", "menubar"], now: Sim.epoch + 7, env: Sim.notifying)
        #expect(sim.spoolEntries().count == 1)
        // Moving the deadline across a minute IS news again.
        sim.run(["15m", "--owner", "menubar"], now: Sim.epoch + 120, env: Sim.notifying)
        #expect(sim.spoolEntries().count == 2)
    }

    @Test func aClaimInsideALongerOneIsSilent() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["2h", "--owner", "terminal"], env: Sim.notifying)
        sim.run(["30m", "--owner", "agent"], env: Sim.notifying)
        #expect(sim.spoolEntries().count == 1) // only the first changed the promise
    }

    @Test func theGuardQueuesItsWarningOnce() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["30m", "--owner", "terminal"], env: Sim.notifying)
        sim.run(["guard"], now: Sim.epoch + 1600, env: Sim.notifying)
        sim.run(["guard"], now: Sim.epoch + 1700, env: Sim.notifying)
        let warnings = sim.spoolEntries().filter {
            ($0["title"] as? String)?.contains("left") == true
        }
        #expect(warnings.count == 1)
        #expect(warnings.first?["actionable"] as? Bool == true)
    }

    @Test func releasingSaysSleepAllowedAgainWithoutButtons() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["15m", "--owner", "terminal"], env: Sim.notifying)
        sim.run(["down", "--owner", "terminal"], env: Sim.notifying)
        let last = sim.spoolEntries().last
        #expect((last?["title"] as? String)?.contains("Sleep allowed again") == true)
        // Nothing to extend or release on an idle machine: no buttons.
        #expect(last?["actionable"] as? Bool == false)
    }

    @Test func noneMeansNothingIsEvenQueued() {
        let sim = Sim(); defer { sim.tearDown() }
        sim.run(["15m", "--owner", "terminal"]) // harness default: SIMMER_NOTIFY=none
        #expect(sim.spoolEntries().isEmpty)
    }

    @Test func notifyTestQueuesAndTellsTheTruthAboutTheApp() {
        let sim = Sim(); defer { sim.tearDown() }
        // No app heartbeat: queued, but the caller is told nobody will post it.
        let result = sim.run(["notify-test"], env: Sim.notifying)
        #expect(result.code == 1)
        #expect(result.out.contains("not running"))
        #expect(sim.spoolTitles().contains("simmer notify-test"))
    }
}
