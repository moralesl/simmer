import Foundation
import Testing
@testable import SimmerCore

// Unit tests for the internals the CLI surface cannot reach directly:
// parsing tables, the claim codec, aggregate tie rules, settle against an
// in-memory power system. The acceptance suite owns the contract; this suite
// owns the mechanics.

@Suite struct DurationParsing {
    @Test func table() {
        #expect(Durations.parse("90") == 5400)
        #expect(Durations.parse("90m") == 5400)
        #expect(Durations.parse("1h") == 3600)
        #expect(Durations.parse("1h30m") == 5400)
        #expect(Durations.parse("45min") == 2700)
        #expect(Durations.parse("2h15") == 8100)
        #expect(Durations.parse("30s") == 30)
        #expect(Durations.parse("2H") == 7200)
        #expect(Durations.parse("1h2m3s") == 3723)
        #expect(Durations.parse("5x7") == nil)
        #expect(Durations.parse("abc") == nil)
        #expect(Durations.parse("1h2x") == nil)
        #expect(Durations.parse("") == nil)
        #expect(Durations.parse("0") == nil)
        #expect(Durations.parse("0m") == nil)
        #expect(Durations.parse("15a4h") == nil) // a bare number only at the end
        // Days: overnight is a first-class case, and "1d" is how it is spelled.
        #expect(Durations.parse("1d") == 86_400)
        #expect(Durations.parse("2days") == 172_800)
        #expect(Durations.parse("1d12h") == 129_600)
        #expect(Durations.parse("1d30") == 88_200) // trailing bare number = minutes
        #expect(Durations.parse("0d") == nil)
    }

    /// A deadline on another calendar day must never render as a bare HH:mm:
    /// "until 08:00" for a time 23 hours away reads as a time already gone.
    @Test func aDeadlineOnAnotherDaySaysWhichDay() {
        // 2027-01-15 09:00 Europe/Berlin, the acceptance suite's fixed epoch.
        let now = 1_800_000_000
        #expect(Formats.hhmmDated(now + 3600, now: now) == Formats.hhmm(now + 3600))
        #expect(!Formats.hhmmDated(now + 3600, now: now).contains("tomorrow"))
        #expect(Formats.hhmmDated(now + 86_400, now: now).hasSuffix(" tomorrow"))
        // Beyond tomorrow, name the date — "tomorrow" would be a lie and a
        // bare time would be worse.
        let far = Formats.hhmmDated(now + 3 * 86_400, now: now)
        #expect(far.contains(" on "))
        #expect(!far.contains("tomorrow"))
    }

    @Test func untilRollsToTomorrowWhenBehindUs() {
        let now = 1_800_000_000
        let target = Durations.parseUntil("12:00", now: now)!
        #expect(target > now)
        #expect(target - now <= 86_400)
        #expect(Durations.parseUntil("24:00", now: now) == nil)
        #expect(Durations.parseUntil("7:60", now: now) == nil)
        #expect(Durations.parseUntil("nope", now: now) == nil)
        #expect(Durations.parseUntil("7:5", now: now) == nil) // minutes need two digits
    }

    @Test func formatting() {
        #expect(Durations.human(4800) == "1 h 20 min")
        #expect(Durations.human(2700) == "45 min")
        #expect(Durations.human(30) == "under 1 min")
        #expect(Durations.human(-5) == "under 1 min")
        #expect(Durations.short(4800) == "1h20")
        #expect(Durations.short(2520) == "42m")
        #expect(Durations.short(3660) == "1h01")
    }
}

@Suite struct ClaimCodec {
    @Test func roundTrip() {
        let claim = Claim(owner: "agent:funnel", until: 100, started: 50,
                          reason: "a reason · with = signs", minBattery: 35,
                          requireAC: true, displayOn: true, warned: true,
                          prewarned: false, reminded: 42)
        let parsed = Claim.parse(claim.serialized(), fallbackId: "x")
        #expect(parsed == claim)
    }

    @Test func unknownKeysAreIgnoredFieldsAreAppendOnly() {
        let text = "format=2\nid=a\nowner=a\nuntil=9\nnovel_field=hello\n"
        let parsed = Claim.parse(text, fallbackId: "a")
        #expect(parsed.until == 9)
        #expect(parsed.minBattery == Claim.defaultMinBattery)
    }

    @Test func sanitizedIdEchoesOwnerVerbatimInside() {
        let claim = Claim(owner: "weird owner/name", until: 0, started: 0)
        #expect(claim.id.hasPrefix("weird_owner_name-"))
        #expect(Claim.parse(claim.serialized(), fallbackId: claim.id).owner == "weird owner/name")
    }

    /// An owner that needs no flattening keeps the id it has always had.
    ///
    /// This is the compatibility half of the fingerprint: every claim any
    /// machine currently holds was written by an actor naming itself in the
    /// safe set, so no filename moves and no migration is owed. If this fails,
    /// every live claim on every installed copy became unaddressable by the
    /// actor that wrote it.
    @Test func aFilenameSafeOwnerIsItsOwnIdUntouched() {
        for owner in ["terminal", "menubar", "agent:evals", "run:4821",
                      "agent:cp-funnel", "script", "a.b_c-d:e"] {
            #expect(Claim.sanitizedId(owner) == owner)
        }
    }

    /// The property the whole ownership model rests on: two different actors
    /// must never be handed the same claim file. It used to be false — every
    /// pair below collided, and the loser lost awake time it already held,
    /// silently (CONTRACTS.md § the claims ledger; AGENTS.md, the "no surface
    /// may cost a caller awake time it already holds" rule).
    @Test func distinctOwnersNeverShareAClaimId() {
        let owners = [
            // The pair that was actually reproduced against the built binary.
            "agent:a/b", "agent:a_b",
            // Every separator a real caller reaches for.
            "agent:a b", "agent:a\tb", "agent:a|b", "agent:a\\b", "agent:a,b",
            // Non-ASCII: all of these flattened to the same underscores.
            "agent:über", "agent:öber", "agent:ober", "agent:发布", "agent:тест",
            // Traversal, which must stay neutralised AND stay distinguishable.
            "../../../../tmp/pwned", ".._.._.._.._tmp_pwned",
            // Safe names, to prove the two kinds cannot meet either.
            "terminal", "menubar", "agent:evals", "run:1", "run:2",
            // Longer than a filename may be: truncation must not merge them.
            String(repeating: "x", count: 400) + "/one",
            String(repeating: "x", count: 400) + "/two",
        ]
        var seen: [String: String] = [:]
        for owner in owners {
            let id = Claim.sanitizedId(owner)
            #expect(seen[id] == nil,
                    "owners \(seen[id] ?? "?") and \(owner) share the claim id \(id)")
            seen[id] = owner
        }
        #expect(seen.count == owners.count)
    }

    /// An id has to survive as a filename on APFS, whatever the owner was —
    /// and the budget it has to fit is the one the temp-file rename leaves,
    /// not `NAME_MAX` itself (`Claim.idBudget`).
    @Test func aClaimIdIsAlwaysAUsableFilename() {
        for owner in ["agent:evals", "agent:a/b", String(repeating: "ü", count: 500),
                      String(repeating: "x", count: 500)] {
            let id = Claim.sanitizedId(owner)
            #expect(!id.isEmpty)
            #expect(id.utf8.count <= Claim.idBudget, "\(id.utf8.count) bytes")
            #expect(!id.contains("/"))
            #expect(id != "." && id != "..")
        }
    }

    /// The fingerprint must not move between processes — `Hasher` is seeded
    /// per process and would have made an id unaddressable by its own writer.
    /// Asserted as a literal, which is the only way this test can fail if
    /// someone swaps the implementation for a seeded one.
    @Test func theFingerprintIsStableAcrossProcesses() {
        #expect(Claim.fingerprint("") == "811c9dc5")          // FNV-1a offset basis
        #expect(Claim.fingerprint("a") == "e40c292c")
        #expect(Claim.fingerprint("foobar") == "bf9cf968")
    }

    @Test func spikeWrittenClaimWithCaffeinatePidParses() {
        let text = "format=2\nid=t\nowner=t\nuntil=99\ncaffeinate=4242\n"
        #expect(Claim.parse(text, fallbackId: "t").legacyCaffeinatePid == 4242)
    }
}

@Suite struct CapMath {
    @Test func cappedUntilRules() {
        let cap = CapRecord(until: 100, setBy: "terminal", setAt: 0, expires: Cap.rollover(after: 100))
        #expect(cappedUntil(0, cap: cap) == 100)     // forever under a cap = the cap
        #expect(cappedUntil(200, cap: cap) == 100)   // past the cap = the cap
        #expect(cappedUntil(50, cap: cap) == 50)     // inside the cap = untouched
        #expect(cappedUntil(0, cap: nil) == 0)
        #expect(cappedUntil(200, cap: nil) == 200)
    }
}

@Suite struct AggregateRules {
    func claim(_ owner: String, until: Int, reason: String = "") -> Claim {
        Claim(owner: owner, until: until, started: 10, reason: reason)
    }

    @Test func theLatestDeadlineDefinesTheAggregate() {
        let aggregate = Aggregate.compute(
            claims: [claim("a", until: 100, reason: "short"),
                     claim("b", until: 200, reason: "long")],
            cap: nil, now: 50, sleepDisabled: true)
        #expect(aggregate.state == .active)
        #expect(aggregate.until == 200)
        #expect(aggregate.owner == "b")
        #expect(aggregate.reason == "long")
        #expect(aggregate.count == 2)
    }

    @Test func expiredClaimsAreNotCounted() {
        let aggregate = Aggregate.compute(
            claims: [claim("a", until: 40), claim("b", until: 200)],
            cap: nil, now: 50, sleepDisabled: true)
        #expect(aggregate.count == 1)
        #expect(aggregate.until == 200)
    }

    @Test func foreverWinsOnlyWhenNothingCapsIt() {
        var aggregate = Aggregate.compute(
            claims: [claim("a", until: 0), claim("b", until: 200)],
            cap: nil, now: 50, sleepDisabled: true)
        #expect(aggregate.state == .forever)
        #expect(aggregate.leftShort == "∞")
        #expect(aggregate.owner == "a")

        aggregate = Aggregate.compute(
            claims: [claim("a", until: 0), claim("b", until: 200)],
            cap: CapRecord(until: 300, setBy: "t", setAt: 0, expires: Cap.rollover(after: 300)),
            now: 50, sleepDisabled: true)
        #expect(aggregate.state == .active)
        #expect(aggregate.until == 300)
        #expect(aggregate.capped)
    }

    @Test func emptyLedgerIsIdleOrOrphanByTheSwitch() {
        #expect(Aggregate.compute(claims: [], cap: nil, now: 0, sleepDisabled: false).state == .idle)
        #expect(Aggregate.compute(claims: [], cap: nil, now: 0, sleepDisabled: true).state == .orphan)
    }

    @Test func tiesResolveByStableOrderNotArrivalOrder() {
        // Two claims, identical deadlines: the first in id order defines.
        let first = Aggregate.compute(
            claims: [claim("alpha", until: 100), claim("beta", until: 100)],
            cap: nil, now: 50, sleepDisabled: true)
        #expect(first.owner == "alpha")
    }
}

@Suite struct SettleMechanics {
    func makeContext(power: TestPowerSystem) -> Context {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-core-\(UUID().uuidString)")
        return Context(now: 1000, power: power, ledger: Ledger(stateDir: dir),
                       owner: "test", ownerExplicit: true, isHuman: false,
                       isTTY: false, version: "test", binPath: "simmer")
    }

    @Test func settleTurnsTheSwitchOffWhenNothingIsLive() {
        let power = TestPowerSystem(disabled: true)
        let ctx = makeContext(power: power)
        let (ok, outcome) = Engine.settle(ctx: ctx, why: "test")
        #expect(ok)
        #expect(!power.disabled)
        #expect(outcome.notifications.first?.title.contains("Sleep allowed") == true)
    }

    @Test func settleRestoresTheSwitchUnderALiveClaim() {
        let power = TestPowerSystem(disabled: false)
        let ctx = makeContext(power: power)
        ctx.ledger.write(Claim(owner: "test", until: 2000, started: 900))
        let (ok, _) = Engine.settle(ctx: ctx, why: "test")
        #expect(ok)
        #expect(power.disabled)
    }

    @Test func aFailedRevertIsLoudAndNotOK() {
        let power = TestPowerSystem(disabled: true)
        power.switchWritable = false
        let ctx = makeContext(power: power)
        let (ok, outcome) = Engine.settle(ctx: ctx, why: "test")
        #expect(!ok)
        #expect(outcome.notifications.first?.title.contains("could not release") == true)
    }

    @Test func settleIsIdempotent() {
        let power = TestPowerSystem(disabled: false)
        let ctx = makeContext(power: power)
        ctx.ledger.write(Claim(owner: "test", until: 2000, started: 900))
        Engine.settle(ctx: ctx, why: "one")
        Engine.settle(ctx: ctx, why: "two")
        // The second pass found the switch already right and wrote nothing.
        #expect(power.switchWrites.count == 1)
    }
}

/// A write that does not land must be reported, never swallowed: the switch
/// flips before the claim file does, so a silent failure is the one state
/// where simmer announces awake time nothing is holding.
@Suite struct LedgerWriteFailures {
    /// A claims directory that exists but cannot be written to — the shape a
    /// wrong owner or a restrictive umask produces.
    func makeReadOnlyLedger() -> (Ledger, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-ro-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir) // creates claims/
        try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: ledger.claimsDir.path)
        return (ledger, dir)
    }

    @Test func aClaimThatCannotBeWrittenReturnsFalse() {
        let (ledger, dir) = makeReadOnlyLedger()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: ledger.claimsDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(ledger.write(Claim(owner: "test", until: 2000, started: 900)) == false)
        #expect(ledger.claims().isEmpty)
    }

    @Test func aWritableLedgerStillReturnsTrue() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-rw-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ledger.write(Claim(owner: "test", until: 2000, started: 900)) == true)
        #expect(ledger.writeCap(until: 3000, setBy: "terminal", now: 1000) == true)
        #expect(ledger.claims().count == 1)
        #expect(ledger.readCap(now: 1000)?.until == 3000)
    }

    /// No leftovers next to real state when a write fails.
    @Test func aFailedWriteLeavesNoTempFileBehind() {
        let (ledger, dir) = makeReadOnlyLedger()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: ledger.claimsDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        _ = ledger.write(Claim(owner: "test", until: 2000, started: 900))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: ledger.claimsDir.path)) ?? []
        #expect(entries.isEmpty)
    }
}

@Suite struct WarnFlagTransfer {
    @Test func aNewDefiningClaimGetsItsOwnWarning() {
        let power = TestPowerSystem(disabled: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-core-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        // b defines the aggregate (later deadline); a is shorter.
        ledger.write(Claim(owner: "a", until: 1500, started: 0))
        ledger.write(Claim(owner: "b", until: 1700, started: 0))

        func context(now: Int) -> Context {
            Context(now: now, power: power, ledger: ledger, owner: "guard",
                    ownerExplicit: true, isHuman: false, isTTY: false,
                    version: "test", binPath: "simmer")
        }

        // Inside b's warn window: the flag lands on b.
        var outcome = Tick.run(ctx: context(now: 1450))
        #expect(outcome.notifications.contains { $0.subtitle.contains("then this Mac sleeps") })
        #expect(ledger.claim(owner: "b")?.warned == true)
        #expect(ledger.claim(owner: "a")?.warned == false)

        // b released; a becomes the aggregate and gets its OWN warning
        // instead of inheriting a spent flag.
        ledger.retire(ledger.claim(owner: "b")!, why: "test", now: 1460)
        outcome = Tick.run(ctx: context(now: 1460))
        #expect(outcome.notifications.contains { $0.subtitle.contains("then this Mac sleeps") })
        #expect(ledger.claim(owner: "a")?.warned == true)
    }
}

@Suite struct JSONEscaping {
    @Test func controlCharactersAndQuotesSurvive() {
        let value = JSONValue.object([("k", .string("a\"b\\c\nd\te\u{01}"))])
        let data = Data(value.serialized().utf8)
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(parsed?["k"] == "a\"b\\c\nd\te\u{01}")
    }
}
