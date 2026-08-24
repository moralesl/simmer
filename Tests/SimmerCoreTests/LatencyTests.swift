import Foundation
import Testing
@testable import SimmerCore

/// What the menu bar's freshness rests on: when a redraw is due from time
/// passing, and being told when the ledger changed instead of asking.
@Suite struct RefreshScheduleTests {
    func active(left: Int, count: Int = 1) -> Aggregate {
        let now = 1_000_000
        var claims = [Claim(owner: "a", until: now + left, started: now - 60)]
        for index in 1..<max(count, 1) {
            claims.append(Claim(owner: "b\(index)", until: now + left - 10, started: now - 60))
        }
        return Aggregate.compute(claims: claims, cap: nil, now: now, sleepDisabled: true)
    }

    /// The title shows floor(left/60), so the next change is one second after
    /// the current minute is used up — never a fixed interval.
    @Test func aCountdownIsRedrawnExactlyWhenTheMinuteChanges() {
        #expect(StatusTitle.secondsUntilChange(active(left: 125)) == 6)
        #expect(StatusTitle.secondsUntilChange(active(left: 120)) == 1)
        #expect(StatusTitle.secondsUntilChange(active(left: 121)) == 2)
        #expect(StatusTitle.secondsUntilChange(active(left: 3599)) == 60)

        // Proof rather than arithmetic: the title before the due moment and at
        // it must differ, and must NOT differ one second earlier.
        for left in [61, 125, 599, 3601] {
            let due = StatusTitle.secondsUntilChange(active(left: left))
            #expect(StatusTitle.render(active(left: left)).text
                == StatusTitle.render(active(left: left - due + 1)).text)
            #expect(StatusTitle.render(active(left: left)).text
                != StatusTitle.render(active(left: left - due)).text)
        }
    }

    /// Turning orange is a change too, and it happens mid-minute.
    @Test func theUrgentThresholdGetsItsOwnRedraw() {
        #expect(StatusTitle.secondsUntilChange(active(left: 330)) == 30)
        #expect(StatusTitle.render(active(left: 301)).urgent == false)
        #expect(StatusTitle.render(active(left: 300)).urgent == true)
        // Inside the window the minute boundary governs again.
        #expect(StatusTitle.secondsUntilChange(active(left: 290)) == 51)
    }

    /// The property the app's expiry handling rests on: following this
    /// schedule, the last wake of an active claim lands in the second AFTER
    /// the deadline — so the process that knows when the deadline is settles
    /// the switch then, instead of leaving the machine held awake by nobody
    /// until the guard's next pass.
    @Test func theLastWakeLandsJustAfterTheDeadline() {
        for start in [45, 61, 125, 301, 900, 3600] {
            var left = start
            var wakes = 0
            while left > 0 {
                left -= StatusTitle.secondsUntilChange(active(left: left))
                wakes += 1
                #expect(wakes < 200, "the schedule must converge, not crawl")
            }
            // Exactly one second past the deadline, never more.
            #expect(left == -1)
        }
    }

    @Test func nothingIsScheduledWhenNothingCanChangeOnItsOwn() {
        let idle = Aggregate.compute(claims: [], cap: nil, now: 1000, sleepDisabled: false)
        let orphan = Aggregate.compute(claims: [], cap: nil, now: 1000, sleepDisabled: true)
        let forever = Aggregate.compute(claims: [Claim(owner: "a", until: 0, started: 0)],
                                        cap: nil, now: 1000, sleepDisabled: true)
        for aggregate in [idle, orphan, forever] {
            #expect(StatusTitle.secondsUntilChange(aggregate) == StatusTitle.noScheduledChange)
        }
        // A caller clamps that to its own backstop; it must not be negative or
        // zero, which would spin a timer.
        #expect(StatusTitle.noScheduledChange > 0)
    }

    /// An expired claim is not part of the aggregate at all, so the title has
    /// already stopped counting it down — there is no stale minute to repaint,
    /// which is why the countdown never shows time that has gone.
    @Test func anExpiredClaimLeavesNothingToCountDown() {
        let expired = active(left: 0)
        #expect(expired.count == 0)
        #expect(expired.state != .active)
        #expect(StatusTitle.render(expired).detail.isEmpty)

        // The guard inside the schedule is for a hand-built aggregate — a
        // caller must never be handed a zero or negative interval, which
        // would spin a timer.
        var handBuilt = Aggregate()
        handBuilt.state = .active
        handBuilt.left = 0
        #expect(StatusTitle.secondsUntilChange(handBuilt) == 1)
        handBuilt.left = -30
        #expect(StatusTitle.secondsUntilChange(handBuilt) == 1)
    }
}

@Suite struct LedgerWatcherTests {
    /// Waits for the watcher to report, up to a timeout — the whole point is
    /// that this returns in milliseconds rather than at the next poll.
    func waitForChange(timeout: TimeInterval = 3.0,
                       setUp: (Ledger) -> Void,
                       change: (Ledger) -> Void) -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-watch-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        setUp(ledger)

        let fired = DispatchSemaphore(value: 0)
        let watcher = LedgerWatcher(ledger: ledger, debounce: 0.05) { fired.signal() }
        watcher.start()
        defer { watcher.stop() }
        // Let the sources arm before touching anything.
        Thread.sleep(forTimeInterval: 0.2)

        change(ledger)
        return fired.wait(timeout: .now() + timeout) == .success
    }

    @Test func aClaimAppearingIsReportedAtOnce() {
        #expect(waitForChange(setUp: { _ in }) { ledger in
            ledger.write(Claim(owner: "test", until: 2000, started: 1000))
        })
    }

    @Test func aClaimBeingReleasedIsReportedAtOnce() {
        #expect(waitForChange(setUp: { ledger in
            ledger.write(Claim(owner: "test", until: 2000, started: 1000))
        }, change: { ledger in
            ledger.removeClaim(id: "test")
        }))
    }

    /// The cap is written temp-file-then-rename, which replaces the watched
    /// inode. Without re-arming, the first cap change would also be the last
    /// one ever seen.
    @Test func theWatchSurvivesTheCapBeingReplaced() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-watch-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        ledger.writeCap(until: 5000, setBy: "terminal", now: 1000)

        let count = Counter()
        let watcher = LedgerWatcher(ledger: ledger, debounce: 0.05) { count.increment() }
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.2)

        for value in [6000, 7000] {
            ledger.writeCap(until: value, setBy: "terminal", now: 1000)
            Thread.sleep(forTimeInterval: 0.4)
        }
        // Both replacements seen, not just the first.
        #expect(count.value >= 2)
    }

    @Test func stoppingEndsTheReports() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-watch-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let count = Counter()
        let watcher = LedgerWatcher(ledger: ledger, debounce: 0.05) { count.increment() }
        watcher.start()
        Thread.sleep(forTimeInterval: 0.2)
        watcher.stop()
        Thread.sleep(forTimeInterval: 0.1)

        ledger.write(Claim(owner: "test", until: 2000, started: 1000))
        Thread.sleep(forTimeInterval: 0.4)
        #expect(count.value == 0)
    }
}

/// A counter usable from the watcher's queue and the test's thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
