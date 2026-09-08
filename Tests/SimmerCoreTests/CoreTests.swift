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
    /// The round trip is through a FILE, and a claim's file is named for its
    /// id — so the id comes back from the name it was stored under, which is
    /// exactly what `Ledger` passes in.
    @Test func roundTrip() {
        let claim = Claim(owner: "agent:funnel", until: 100, started: 50,
                          reason: "a reason · with = signs", minBattery: 35,
                          requireAC: true, displayOn: true, warned: true,
                          prewarned: false, reminded: 42)
        let parsed = Claim.parse(claim.serialized(), fallbackId: claim.id)
        #expect(parsed == claim)
    }

    /// A record may not rename itself. `write` and `removeClaim` key on the
    /// id, so a parsed id that disagrees with the filename is a claim written
    /// to one path and deleted from another — unreleasable through every
    /// surface, and re-retired by every guard tick for as long as it lives.
    @Test func theIdInsideARecordIsNotAuthoritative() {
        let text = "format=2\nid=zzz\nowner=agent:evals\nuntil=9\n"
        #expect(Claim.parse(text, fallbackId: "agent:evals").id == "agent:evals")
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
            // Case: one file on APFS, and the pair that inverted human primacy.
            "Terminal", "TERMINAL", "agent:Evals",
            // Traversal, which must stay neutralised AND stay distinguishable.
            "../../../../tmp/pwned", ".._.._.._.._tmp_pwned",
            // Safe names, to prove the two kinds cannot meet either.
            "terminal", "menubar", "agent:evals", "run:1", "run:2",
            // Longer than a filename may be: truncation must not merge them.
            String(repeating: "x", count: 400) + "/one",
            String(repeating: "x", count: 400) + "/two",
        ]
        // Folded, because that is the comparison the disk makes. Comparing
        // ids as Swift strings is a stricter notion of distinct than APFS's,
        // and the gap between the two is where `Terminal` sat: two ids, one
        // file, and the claim that got there first was gone without a trace.
        var seen: [String: String] = [:]
        for owner in owners {
            let id = Claim.sanitizedId(owner)
            let onDisk = id.lowercased()
            #expect(seen[onDisk] == nil,
                    "owners \(seen[onDisk] ?? "?") and \(owner) share the claim file \(id)")
            seen[onDisk] = owner
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

    /// The other half, and the one that was missing: a removal that did not
    /// happen must say so, because the callers above it announce.
    @Test func aClaimThatCannotBeRemovedReportsFalse() {
        let (ledger, dir) = makeReadOnlyLedger()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: ledger.claimsDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        // Planted before the freeze would need the freeze undone; instead take
        // the claim first, then freeze — which is the real shape anyway.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: ledger.claimsDir.path)
        let claim = Claim(owner: "terminal", until: 2000, started: 900)
        #expect(ledger.write(claim))
        try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: ledger.claimsDir.path)

        #expect(ledger.removeClaim(id: claim.id) == false)
        #expect(ledger.retire(claim, why: "released by hand", now: 1000) == false)
        #expect(ledger.claims().count == 1)
        // And no `retire` event for an ending that did not happen.
        let events = (try? String(contentsOf: ledger.eventsFile, encoding: .utf8)) ?? ""
        #expect(!events.contains("\"retire\""))
    }

    /// A claim someone else already retired is gone, which is what the caller
    /// asked for — a race with the guard is not a failure.
    @Test func removingAClaimThatIsAlreadyGoneSucceeds() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-rm-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ledger.removeClaim(id: "nobody") == true)
    }

    /// The cap's lift is checked the way its write already was.
    @Test func aCapThatCannotBeLiftedReportsFalse() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-cap-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(ledger.writeCap(until: 3000, setBy: "terminal", now: 1000))
        try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: dir.path)
        #expect(ledger.clearCap() == false)
        #expect(ledger.storedCap() != nil)
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

/// A crash between `atomicWrite`'s temp file and its rename is the one failure
/// the function cannot clean up after itself — the cleanup runs in a process
/// that is already gone. So where the temp file lives is what decides whether
/// the debris is inert or is a claim nothing can remove.
@Suite struct CrashDebris {
    func makeLedger() -> (Ledger, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-debris-\(UUID().uuidString)")
        return (Ledger(stateDir: dir), dir)
    }

    /// Staged in `stateDir`, which nothing enumerates. Before, it was staged
    /// beside its destination — inside the one directory that IS the list of
    /// live claims, where `claims()` cannot tell a record from a half-written
    /// copy of one because both are regular files and both parse.
    @Test func debrisFromAnInterruptedWriteIsNotALiveClaim() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ledger.write(Claim(owner: "terminal", until: 2000, started: 900)))
        let record = try! String(contentsOf: ledger.claimsDir.appendingPathComponent("terminal"),
                                 encoding: .utf8)
        try! record.write(to: ledger.stateDir.appendingPathComponent(".terminal.tmp.4242"),
                          atomically: true, encoding: .utf8)

        #expect(ledger.claims().count == 1)
        ledger.retire(ledger.claims()[0], why: "released by hand", now: 1000)
        #expect(ledger.claims().isEmpty)
    }

    /// Debris a version that staged inside `claims/` already left on a real
    /// machine is a COPY of a real claim — `format=` and all — so it read as a
    /// record and went on holding the switch, with no deadline for the guard
    /// to heal an open-ended one by. It is not counted at all now: nothing
    /// writes that shape any more, so a file wearing it is debris by
    /// construction.
    @Test func debrisLeftByAnOlderVersionHoldsNothing() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = ledger.claimsDir.appendingPathComponent("terminal.tmp.4242")
        try! "format=2\nid=terminal\nowner=terminal\nuntil=0\nstarted=900\n"
            .write(to: stale, atomically: true, encoding: .utf8)

        #expect(ledger.claims().isEmpty)
        #expect(Ledger.isWriteDebris("terminal.tmp.4242"))
        #expect(!Ledger.isWriteDebris("terminal"))
        #expect(!Ledger.isWriteDebris("agent:a_b-e6a27fc6"))
    }

    /// And the guard clears it, because once it stopped being counted nothing
    /// else could reach it — `down --all` retires claims, and this is not one.
    @Test func theGuardSweepsWhatACrashedWriteLeft() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try! "format=2\nid=terminal\nowner=terminal\nuntil=0\nstarted=900\n"
            .write(to: ledger.claimsDir.appendingPathComponent("terminal.tmp.4242"),
                   atomically: true, encoding: .utf8)
        #expect(ledger.write(Claim(owner: "agent:x", until: 2000, started: 900)))

        #expect(ledger.sweepWriteDebris(now: 1000) == 1)
        #expect(ledger.claimFileNamesForTests().sorted() == ["agent:x"],
                "a real claim beside it must be untouched")
        #expect(ledger.sweepWriteDebris(now: 1000) == 0, "and it is idempotent")
    }

    /// And it cannot bring itself back. A tick that updates a flag writes the
    /// claim out again; keyed on the `id=` line, that wrote the debris back
    /// under the name of the claim it was a copy of — so releasing the claim
    /// recreated it, every thirty seconds, for as long as the Mac ran.
    /// The resurrection this used to guard against is now unreachable a step
    /// earlier: a tick never reads the debris, so there is nothing for it to
    /// write back out under the name of the claim it copied. Asserted from the
    /// tick's side, which is where the loop actually was.
    @Test func aTickCannotWriteDebrisBackOutAsARealClaim() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try! "format=2\nid=terminal\nowner=terminal\nuntil=2000\nstarted=900\n"
            .write(to: ledger.claimsDir.appendingPathComponent("terminal.tmp.4242"),
                   atomically: true, encoding: .utf8)

        // Everything a tick iterates over — and it is empty.
        for var claim in ledger.claims() {
            claim.warned = true
            _ = ledger.write(claim)
        }
        #expect(!FileManager.default.fileExists(
            atPath: ledger.claimsDir.appendingPathComponent("terminal").path))
        #expect(ledger.claims().isEmpty)
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

/// What the tool tells a caller about the machine, when it is not looking at
/// the machine — and what it leaves lying around while it does.
@Suite struct SeamAndStateHygiene {
    /// SIMMER_BIN lands in the `bash=` of every SwiftBar row and in the
    /// commands `copyAsCLI` hands out. Honoured unconditionally, one
    /// environment variable decided what a person's menu bar runs when they
    /// click it. It is a test seam, so it is gated like one.
    @Test func simmerBinIsOnlyHonouredWhenThePowerSeamIsActive() {
        let loose = SimmerEnvironment(env: ["SIMMER_BIN": "/tmp/evil"],
                                      isTTY: false, executablePath: "/usr/local/bin/simmer")
        #expect(loose.binPath == "/usr/local/bin/simmer")

        let seamed = SimmerEnvironment(env: ["SIMMER_BIN": "/tmp/evil",
                                             "SIMMER_FAKE_PMSET": "/tmp/switch"],
                                       isTTY: false, executablePath: "/usr/local/bin/simmer")
        #expect(seamed.binPath == "/tmp/evil")
    }

    /// Any SIMMER_FAKE_* means the answers are about a seam. `doctor` said so;
    /// `status` and `budget` — the two surfaces the agent protocol points at —
    /// did not.
    @Test func anyFakeVariableMarksTheEnvironmentAsSeamed() {
        for key in ["SIMMER_FAKE_PMSET", "SIMMER_FAKE_BATTERY", "SIMMER_FAKE_NOW",
                    "SIMMER_FAKE_THERMAL", "SIMMER_FAKE_LOCKDELAY"] {
            #expect(SimmerEnvironment(env: [key: "x"], isTTY: false,
                                      executablePath: "simmer").isSeamed, "\(key)")
        }
        #expect(!SimmerEnvironment(env: ["SIMMER_OWNER": "agent:x"], isTTY: false,
                                   executablePath: "simmer").isSeamed)
    }

    /// A seamed process reads nothing from the network, because
    /// `makeReleaseSource` hands it a source that cannot reach it. The menu
    /// bar's daily-check guard rests on that one layer down — "the seam bars
    /// the network in `makeReleaseSource`", `AppState.swift:126` — and nothing
    /// asserted it, so the comment was the whole guarantee.
    ///
    /// All three answers, because the interesting one is the middle: told what
    /// to answer, a fake; seamed and not told, a source that reads nothing;
    /// neither, the real one. The seamed source's own answer is asserted too,
    /// since "not GitHub" would also be satisfied by something that hangs.
    @Test func aSeamedProcessGetsAReleaseSourceThatCannotReachTheNetwork() {
        func source(_ env: [String: String]) -> ReleaseSource {
            SimmerEnvironment(env: env, isTTY: false,
                              executablePath: "/usr/local/bin/simmer").makeReleaseSource()
        }
        #expect(source(["SIMMER_FAKE_NOW": "1800000000"]) is SeamedReleaseSource)
        #expect(source(["SIMMER_FAKE_LATEST": "v9.9.9"]) is FakeReleaseSource)
        #expect(source(["SIMMER_OWNER": "agent:x"]) is GitHubReleaseSource)
        #expect(source(["SIMMER_FAKE_PMSET": "/tmp/switch"]).newestRelease()
            == .unavailable("seamed — set SIMMER_FAKE_LATEST to answer this without the network"))
    }

    /// A reason is free text about what someone is doing, so it carries
    /// customer names, project names and ticket numbers — and the log and the
    /// event stream keep every one of them, dated. SECURITY.md describes this
    /// directory as the owner's; the mode said otherwise.
    @Test func theStateDirectoryAndItsRecordsAreOwnerOnly() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-perm-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ledger.write(Claim(owner: "agent:x", until: 2000, started: 900,
                                   reason: "customer ACME migration")))
        ledger.log("something", now: 1000)
        ledger.event("test", now: 1000, [])

        func mode(_ url: URL) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        }
        #expect(mode(ledger.claimsDir) == 0o700)
        #expect(mode(ledger.claimsDir.appendingPathComponent("agent:x")) == 0o600)
        #expect(mode(ledger.logFile) == 0o600)
        #expect(mode(ledger.eventsFile) == 0o600)
    }

    /// A label, not a document. Twenty thousand characters reached the
    /// menu-bar title, every status line and every agent's context — and
    /// `simmer run` records the command it wraps, so a long one-liner gets
    /// there without anyone typing it.
    @Test func aReasonAndAnOwnerAreBoundedInLength() {
        let claim = Claim(owner: String(repeating: "o", count: 5_000),
                          until: 0, started: 0,
                          reason: String(repeating: "r", count: 20_000))
        #expect(claim.reason.count == Claim.maxReasonLength)
        #expect(claim.reason.hasSuffix("…"))
        #expect(claim.owner.count == Claim.maxOwnerLength)
        // Short ones are untouched, ellipsis and all.
        let ordinary = Claim(owner: "agent:evals", until: 0, started: 0, reason: "nightly eval")
        #expect(ordinary.reason == "nightly eval")
        #expect(ordinary.owner == "agent:evals")
    }
}

@Suite struct BatteryEstimateParsing {
    /// Real pmset lines. The discharging one cannot be observed on a Mac that
    /// happens to be plugged in, which is why the parser is separable.
    @Test func pmsetLinesAreReadOrHonestlyRefused() {
        #expect(SeamPowerSystem.parseRemaining(
            " -InternalBattery-0 (id=5439587)\t85%; discharging; 3:42 remaining present: true") == 13_320)
        #expect(SeamPowerSystem.parseRemaining(
            " -InternalBattery-0 (id=5439587)\t85%; discharging; (no estimate) present: true") == nil)
        // Charging prints 0:00 — about the charge, not the discharge.
        #expect(SeamPowerSystem.parseRemaining(
            " -InternalBattery-0 (id=5439587)\t99%; finishing charge; 0:00 remaining present: true") == nil)
        #expect(SeamPowerSystem.parseRemaining("Now drawing from 'AC Power'") == nil)
    }
}

/// A facet is faked wholesale or not at all. Half of one is worse than
/// neither: it passes on the machine the developer happens to be using.
@Suite struct SeamFacetIsolation {
    /// `SIMMER_FAKE_BATTERY` without `SIMMER_FAKE_BATTERY_TIME` used to fall
    /// through to the real `pmset -g batt`, so a test that faked "21%, on
    /// battery" read THIS Mac's actual time-to-empty. It went unnoticed
    /// because a plugged-in Mac has no estimate to leak — the suite only
    /// turned red when it was run unplugged.
    @Test func aFakedBatteryNeverReadsTheRealOne() {
        let faked = SeamPowerSystem(env: ["SIMMER_FAKE_BATTERY": "21:1"],
                                    allowInteractiveSudo: false)
        #expect(faked.batteryPercent() == 21)
        #expect(faked.onBattery())
        #expect(faked.batterySecondsRemaining() == nil)
    }

    /// And the time is expressible on its own terms, including the state pmset
    /// is in for the first minute after every unplug.
    @Test func theFakedBatteryCarriesItsOwnEstimate() {
        func system(_ time: String) -> SeamPowerSystem {
            SeamPowerSystem(env: ["SIMMER_FAKE_BATTERY": "60:1", "SIMMER_FAKE_BATTERY_TIME": time],
                            allowInteractiveSudo: false)
        }
        #expect(system("2400").batterySecondsRemaining() == 2400)
        #expect(system("none").batterySecondsRemaining() == nil)
    }
}

/// `doctor` asked whether the claims directory was WRITABLE and never whether
/// what was in it made sense. Both defects that held a Mac awake indefinitely
/// were shapes in this directory, and one of them survived ten simulated days
/// under a fully green report.
@Suite struct ClaimsDirectorySoundness {
    func makeLedger() -> (Ledger, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-sound-\(UUID().uuidString)")
        return (Ledger(stateDir: dir), dir)
    }

    @Test func anOrdinaryLedgerIsSound() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ledger.write(Claim(owner: "agent:evals", until: 2000, started: 900)))
        #expect(ledger.write(Claim(owner: "terminal", until: 3000, started: 900)))
        #expect(ledger.unsoundClaimFiles().isEmpty)
    }

    /// The crash debris a pre-0.2.0 write left inside `claims/`.
    @Test func aLeftoverTempFileIsNamed() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try! "format=2\nid=terminal\nowner=terminal\nuntil=2000\nstarted=900\n"
            .write(to: ledger.claimsDir.appendingPathComponent("terminal.tmp.4242"),
                   atomically: true, encoding: .utf8)
        let unsound = ledger.unsoundClaimFiles()
        #expect(unsound.count == 1)
        #expect(unsound.first?.name == "terminal.tmp.4242")
        #expect(unsound.first?.why.contains("only 'down --all'") == true)
    }

    /// A record that renamed itself out from under its filename — the shape
    /// `-r "build⏎id=zzz"` produced, unreleasable through every surface.
    @Test func aRecordStoredUnderTheWrongNameIsNamed() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try! "format=2\nid=zzz\nowner=agent:evals\nuntil=2000\nstarted=900\n"
            .write(to: ledger.claimsDir.appendingPathComponent("zzz"),
                   atomically: true, encoding: .utf8)
        #expect(ledger.unsoundClaimFiles().first?.name == "zzz")
    }

    @Test func aFileThatIsNotAClaimAtAllIsNamed() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        try! "hello".write(to: ledger.claimsDir.appendingPathComponent("notes.txt"),
                           atomically: true, encoding: .utf8)
        let unsound = ledger.unsoundClaimFiles()
        #expect(unsound.first?.why.contains("no format=") == true)
    }

    /// The one case that must NOT be reported. `owner` is stored folded to
    /// maxOwnerLength while the id is fingerprinted over the WHOLE original
    /// string, so such a record cannot reconstruct its own name — the same
    /// asymmetry migrateClaimIds had to reason about. Unverifiable is not
    /// damaged, and a row that goes red on a legitimate claim is worse than no
    /// row at all.
    @Test func aTruncatedOwnerIsUnverifiableNotUnsound() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "o", count: Claim.maxOwnerLength + 200)
        let claim = Claim(owner: long, until: 2000, started: 900)
        #expect(ledger.write(claim))
        // The record genuinely cannot round-trip its own id...
        #expect(Claim.sanitizedId(claim.owner) != claim.id)
        // ...and is therefore not reported as damage.
        #expect(ledger.unsoundClaimFiles().isEmpty)
    }
}

/// Swift's arithmetic traps rather than wrapping, so a number read straight
/// out of a file and then added to, subtracted from, or narrowed is a crash
/// waiting on whichever surface touches it first. `Claim`'s initialiser is
/// where every claim is born — `parse` included — so it is where the ranges
/// are, rather than at the sites that would have trapped.
@Suite struct CorruptRecordRanges {
    @Test func anEpochOutsideAnyPlausibleRangeExpiresRatherThanPersists() {
        // 1, not 0: 0 means "no deadline" and would turn damage into the
        // strongest claim there is.
        for bad in [Int.max, Int.min, -1, Claim.maxEpoch + 1] {
            let claim = Claim(owner: "agent:x", until: bad, started: 0)
            #expect(claim.until == 1, "until=\(bad)")
        }
        // And the ordinary values are untouched, including "forever".
        #expect(Claim(owner: "a", until: 0, started: 0).until == 0)
        #expect(Claim(owner: "a", until: 1_800_000_000, started: 0).until == 1_800_000_000)
    }

    @Test func aStartedOrRemindedOutsideRangeFallsBackToZero() {
        for bad in [Int.max, Int.min, -1] {
            #expect(Claim(owner: "a", until: 100, started: bad).started == 0)
            #expect(Claim(owner: "a", until: 100, started: 0, reminded: bad).reminded == 0)
        }
    }

    /// Narrowed to pid_t — Int32 — by both callers that use it, and a pid is
    /// positive. This is what took `guard` and `down --all` down with exit 133.
    @Test func aCaffeinatePidOutsidePidRangeMeansThereIsNoChild() {
        for bad in [Int.max, Int.min, 0, -1, Int(Int32.max) + 1] {
            #expect(Claim(owner: "a", until: 100, started: 0,
                          legacyCaffeinatePid: bad).legacyCaffeinatePid == 0, "\(bad)")
        }
        #expect(Claim(owner: "a", until: 100, started: 0,
                      legacyCaffeinatePid: 4821).legacyCaffeinatePid == 4821)
    }

    @Test func aBatteryFloorOutsideZeroToHundredFallsBackToTheDefault() {
        for bad in [Int.max, Int.min, -1, 101] {
            #expect(Claim(owner: "a", until: 100, started: 0,
                          minBattery: bad).minBattery == Claim.defaultMinBattery, "\(bad)")
        }
        #expect(Claim(owner: "a", until: 100, started: 0, minBattery: 0).minBattery == 0)
        #expect(Claim(owner: "a", until: 100, started: 0, minBattery: 100).minBattery == 100)
    }

    /// The whole point of putting it in the initialiser: a record on disk
    /// cannot get a value past it either.
    @Test func aParsedRecordGoesThroughTheSameRanges() {
        let text = """
            format=2
            id=agent:x
            owner=agent:x
            until=9223372036854775807
            started=-9223372036854775808
            min_battery=9223372036854775807
            caffeinate=2147483648
            """
        let claim = Claim.parse(text, fallbackId: "agent:x")
        #expect(claim.until == 1)
        #expect(claim.started == 0)
        #expect(claim.minBattery == Claim.defaultMinBattery)
        #expect(claim.legacyCaffeinatePid == 0)
    }
}

/// The records beside the claims: what goes into them, and what reading them
/// is allowed to conclude.
@Suite struct RecordsBesideTheClaims {
    func makeLedger() -> (Ledger, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-side-\(UUID().uuidString)")
        return (Ledger(stateDir: dir), dir)
    }

    /// `app.status` is never removed on exit, so its pid outlives the app and
    /// is eventually held by something else — pid 1 among them. `ps -p` said
    /// yes to that, and every row underneath reported the dead app's last
    /// known verdict as current.
    @Test func aStaleHeartbeatIsNotARunningApp() {
        let status = Ledger.AppStatus(pid: 1, notify: "authorized", login: "enabled", ts: 0)
        #expect(!status.heartbeatIsFresh(now: 1_800_000_000))
        // Written a moment ago by an app that is actually there.
        let live = Ledger.AppStatus(pid: 4821, notify: "authorized", login: "enabled",
                                    ts: 1_800_000_000 - 3)
        #expect(live.heartbeatIsFresh(now: 1_800_000_000))
        // And the boundary is the boundary, not a bit past it.
        let old = Ledger.AppStatus(pid: 4821, notify: "authorized", login: "enabled",
                                   ts: 1_800_000_000 - Ledger.AppStatus.maxHeartbeatAge - 1)
        #expect(!old.heartbeatIsFresh(now: 1_800_000_000))
    }

    /// The log and the event stream are append-only records inside a directory
    /// the user owns. A symlink dropped in their place would redirect every
    /// future line somewhere else entirely — silently, because the failure
    /// path in `append` is deliberately quiet.
    @Test func theLogDoesNotFollowASymlinkOutOfTheStateDirectory() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let elsewhere = dir.appendingPathComponent("ELSEWHERE")
        try? FileManager.default.removeItem(at: ledger.logFile)
        try! FileManager.default.createSymbolicLink(at: ledger.logFile, withDestinationURL: elsewhere)

        ledger.log("a line that must not travel", now: 1000)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
    }
}

/// Round 5: three of the four blockers were the same defect — a value checked
/// at birth, or read into a snapshot, then changed through a second path that
/// skipped the check.
@Suite struct InvariantsThatSurviveASecondPath {
    /// A fingerprinted id is built only from characters the safe set allows,
    /// so it is itself a valid owner — and naming yourself one mapped onto
    /// somebody else's claim file. Read the victim's id out of `status --json`
    /// and claim under it; that was the whole attack.
    @Test func anIdIsNeverAlsoAnOwnerThatMapsToIt() {
        for owner in ["agent:a/b", "agent:über", "../../tmp/pwned", "Terminal",
                      String(repeating: "x", count: 400)] {
            let id = Claim.sanitizedId(owner)
            #expect(Claim.sanitizedId(id) != id,
                    "owner \"\(id)\" maps onto \(owner)'s claim file")
        }
    }

    /// **The property, over both reserved shapes.** A name the claims
    /// directory reads as meaning something — a fingerprint suffix, a
    /// pre-0.2.0 temp suffix — must never also be a name `sanitizedId` will
    /// mint. The first collision let one owner take another's file; the second
    /// let the guard delete a live claim thirty seconds after it was taken.
    ///
    /// Written over a generated space rather than a list, because both
    /// collisions were found by someone thinking of a name nobody had listed.
    @Test func noOwnerEverResolvesToAReservedShape() {
        var owners = ["agent:eval.tmp.12", "ci.tmp.42", "agent:build.tmp.99",
                      "x-deadbeef", "agent:a/b", "Terminal", "agent:über",
                      "terminal", "run:4821", "agent:evals"]
        // And the shapes composed with each other, which is where a rule that
        // handles one at a time comes apart.
        for base in ["job", "agent:job", "a.b_c"] {
            for suffix in [".tmp.1", ".tmp.999999", "-0123abcd", "-ffffffff",
                           ".tmp.7-abcdef01", "-abcdef01.tmp.7"] {
                owners.append(base + suffix)
            }
        }
        for owner in owners {
            let id = Claim.sanitizedId(owner)
            #expect(!Ledger.isWriteDebris(id),
                    "owner \"\(owner)\" resolves to \(id), which the guard sweeps as debris")
            // Only a MINTED id can be forged: where the owner passed through
            // untouched, `id == owner` is the point — it is what means no
            // existing claim file ever moves.
            if id != owner {
                #expect(Claim.sanitizedId(id) != id,
                        "owner \"\(id)\" maps onto \(owner)'s claim file")
            }
        }
    }

    /// Stated as the property rather than the instances: the two forms this
    /// function can return must not overlap.
    @Test func theTwoIdFormsAreDisjoint() {
        // Everything fingerprinted ends in a dash and eight hex digits...
        #expect(Claim.sanitizedId("agent:a/b").range(
            of: "-[0-9a-f]{8}$", options: .regularExpression) != nil)
        // ...and nothing passed through unchanged does.
        for safe in ["terminal", "agent:evals", "run:4821", "a.b_c-d:e"] {
            #expect(Claim.sanitizedId(safe) == safe)
            #expect(safe.range(of: "-[0-9a-f]{8}$", options: .regularExpression) == nil)
        }
    }

    /// `until` is a var and three commands move it after the initialiser has
    /// had its say, so a deadline could be walked past `maxEpoch` one
    /// extension at a time — and the next read folded it to expired. The
    /// deadline moved backwards and nothing said so.
    @Test func theLedgerWillNotWriteAValueThatFailedItsOwnRanges() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-reval-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var claim = Claim(owner: "agent:x", until: 1_800_000_000, started: 1_700_000_000)
        claim.until = Claim.maxEpoch + 86_400        // the mutation the check missed
        #expect(ledger.write(claim))

        // What lands is what the ranges allow, so a re-read cannot disagree
        // with what was written.
        let readBack = ledger.claims().first
        #expect(readBack?.until == 1)
        #expect(readBack?.until == Claim(owner: "agent:x", until: Claim.maxEpoch + 86_400,
                                         started: 0).until)
    }

    /// The write half of the same TOCTOU, three lines from the delete half
    /// that got its compare in round 5. A tick reads `claims()` once, then
    /// writes claims back to stamp `warned` / `prewarned` / `reminded` — and
    /// an `extend` that lands in between is overwritten by the older copy,
    /// after `extend` returned exit 0 saying the deadline moved.
    ///
    /// Deterministic on purpose: the race itself is a coin flip that neither I
    /// nor a 300-iteration harness could reliably trigger, so the primitive is
    /// what gets pinned rather than the timing.
    @Test func writingAClaimThatMovedUnderUsIsRefused() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-cas-write-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ledger.write(Claim(owner: "agent:x", until: 1_800_000_000, started: 1_700_000_000)))
        let snapshot = ledger.claims()[0]           // what a tick would hold

        // The extend that lands between the snapshot and the write.
        var renewed = snapshot
        renewed.until += 7200
        #expect(ledger.write(renewed))

        // The tick now stamps a flag on ITS copy and writes it back.
        var stale = snapshot
        stale.warned = true
        #expect(ledger.write(stale, ifStillMatching: snapshot) == false)
        #expect(ledger.claims().first?.until == renewed.until, "the renewal was overwritten")

        // And a write against what is actually there still lands.
        var current = ledger.claims()[0]
        current.warned = true
        #expect(ledger.write(current, ifStillMatching: ledger.claims()[0]))
        #expect(ledger.claims().first?.warned == true)
    }

    /// A claim released since the snapshot must not come back. This is the
    /// resurrection half: `down --all` announced the release, and the tick's
    /// remind-write put an open-ended claim back with nothing to end it.
    @Test func writingAClaimThatIsGoneDoesNotResurrectIt() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-cas-gone-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ledger.write(Claim(owner: "agent:x", until: 0, started: 1_700_000_000)))
        let snapshot = ledger.claims()[0]
        #expect(ledger.retire(snapshot, why: "released by hand", now: 1_800_000_000))

        var stale = snapshot
        stale.reminded = 1_800_000_000
        #expect(ledger.write(stale, ifStillMatching: snapshot) == false)
        #expect(ledger.claims().isEmpty, "a released claim came back")
    }

    /// A tick reads `claims()` once and then unlinks by filename, so a renewal
    /// landing in between was deleted by a decision taken before it existed:
    /// `extend` returned exit 0 and the renewed claim was gone.
    @Test func retiringAClaimThatMovedUnderUsIsRefused() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-cas-\(UUID().uuidString)")
        let ledger = Ledger(stateDir: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = Claim(owner: "agent:x", until: 1_800_000_000, started: 1_700_000_000)
        #expect(ledger.write(original))
        let snapshot = ledger.claims()[0]           // what a tick would hold

        // The renewal that lands between the snapshot and the unlink.
        var renewed = snapshot
        renewed.until += 3600
        #expect(ledger.write(renewed))

        #expect(ledger.retire(snapshot, why: "time is up", now: 1_800_000_001) == false)
        #expect(ledger.claims().first?.until == renewed.until, "the renewal was deleted")

        // And retiring what is actually there still works.
        #expect(ledger.retire(ledger.claims()[0], why: "time is up", now: 1_800_000_001))
        #expect(ledger.claims().isEmpty)
    }
}

/// The shapes a crash or a coinciding tick leaves behind — each one must
/// degrade toward "try again", never toward silence or a doubled record.
@Suite struct CrashAndRaceDebris {
    func makeLedger() -> (Ledger, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-race-\(UUID().uuidString)")
        return (Ledger(stateDir: dir), dir)
    }

    /// A spool fixture with informative text in it, because a drain now drops
    /// an entry without any — macOS never presents one, so posting it was a
    /// no-op indistinguishable from a delivery. These tests are about the
    /// mechanics of draining, and a title-only fixture would be a shape the
    /// tool no longer produces keeping its reader looking healthy
    /// (adversarial case 6).
    func banner(_ title: String) -> NotificationRequest {
        NotificationRequest(title: title, body: "what happened, in a sentence")
    }

    /// A drain that dies between the rename and the sweep strands
    /// `notify-spool.jsonl.draining` — and `moveItem` refuses an existing
    /// destination, so one stranded sentinel used to be every future banner,
    /// silently, forever. The pre-floor warnings ride this spool, and they are
    /// the stated condition for allowing an open-ended claim.
    @Test func aStrandedDrainSentinelIsRecoveredNotFatal() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = ledger.spoolFile.appendingPathExtension("draining")
        // The stranded half: a request a crashed drain read but never posted.
        ledger.enqueueNotification(banner("stranded"), now: 1000)
        try? FileManager.default.moveItem(at: ledger.spoolFile, to: sentinel)
        // The fresh half, queued after the crash.
        ledger.enqueueNotification(banner("fresh"), now: 1010)

        let drained = ledger.drainNotifications(now: 1020)
        #expect(drained.map(\.title).sorted() == ["fresh", "stranded"])
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        // And the NEXT drain still works — the sentinel is gone, not immortal.
        ledger.enqueueNotification(banner("later"), now: 1030)
        #expect(ledger.drainNotifications(now: 1040).map(\.title) == ["later"])
        // The crash does not extend a banner's life: age still decides.
        ledger.enqueueNotification(banner("old"), now: 1050)
        try? FileManager.default.moveItem(at: ledger.spoolFile, to: sentinel)
        #expect(ledger.drainNotifications(now: 5000).isEmpty)
    }

    /// The recovery is keyed on the sentinel EXISTING, not on what it holds.
    ///
    /// Reading it first and removing it only when the read came back non-empty
    /// leaves the whole defect standing for every shape that reads as empty —
    /// a crash between the rename of an empty spool and the sweep, a dangling
    /// symlink wearing the name (`fileExists` says false, `moveItem` still
    /// refuses it a destination), a mode that denies the read but not the
    /// unlink. Each one is the same immortal sentinel, and each one costs
    /// every future banner. The pre-floor warning is the one this tool cannot
    /// afford to drop: it is the stated condition for an open-ended claim.
    @Test func anEmptyStrandedSentinelIsNotImmortalEither() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = ledger.spoolFile.appendingPathExtension("draining")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect((try? Data().write(to: sentinel)) != nil)

        ledger.enqueueNotification(banner("after the crash"), now: 1000)
        #expect(ledger.drainNotifications(now: 1010).map(\.title) == ["after the crash"])
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))

        // A dangling symlink is the same story from the other side: nothing to
        // read, nothing `fileExists` will admit to, and still a destination
        // `moveItem` refuses.
        try? FileManager.default.createSymbolicLink(
            atPath: sentinel.path, withDestinationPath: dir.appendingPathComponent("gone").path)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path), "the link dangles")
        ledger.enqueueNotification(banner("after the link"), now: 1020)
        #expect(ledger.drainNotifications(now: 1030).map(\.title) == ["after the link"])

        // A directory wearing the name is the same destination `moveItem`
        // refuses, and `removeItem` clears it — so the drain recovers rather
        // than going quiet for good.
        try? FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        ledger.enqueueNotification(banner("after the dir"), now: 1040)
        #expect(ledger.drainNotifications(now: 1050).map(\.title) == ["after the dir"])
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    /// A sentinel that is a symlink to the SPOOL ITSELF is not both halves of
    /// one drain.
    ///
    /// The read follows the link and takes the spool's lines as the recovered
    /// half; the unlink then takes the LINK and leaves the spool; the rename
    /// puts the same file back under the same name and it is read again. Every
    /// banner posted twice — a duplicate, which is the one direction the
    /// review of the symlink shapes did not consider: it answered for a link
    /// to a file elsewhere, where the target's lines post once and the target
    /// survives, and that answer is still right.
    ///
    /// Fixtures through `banner(_:)` like every other drain test here: a
    /// title-only request is dropped by the drain's text gate, so it would
    /// assert the mechanics of draining over a shape the tool no longer
    /// produces (adversarial case 6, and this test was the tenth fixture —
    /// written against the tip before that gate landed).
    @Test func aSentinelLinkedToTheSpoolIsNotBothHalvesOfOneDrain() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = ledger.spoolFile.appendingPathExtension("draining")
        ledger.enqueueNotification(banner("one-entry"), now: 1000)
        try? FileManager.default.createSymbolicLink(
            atPath: sentinel.path, withDestinationPath: ledger.spoolFile.path)

        #expect(ledger.drainNotifications(now: 1010).map(\.title) == ["one-entry"],
                "one entry, one banner")
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(!FileManager.default.fileExists(atPath: ledger.spoolFile.path),
                "the spool was drained, so it is gone")
        // And the drain is not poisoned for the next one.
        ledger.enqueueNotification(banner("after"), now: 1020)
        #expect(ledger.drainNotifications(now: 1030).map(\.title) == ["after"])

        // A HARD link to the spool is the same file under two names, and it
        // is the shape a path comparison cannot see: there is no target to
        // resolve, both names are the file. Same double post, same fix — the
        // identity of the FILE rather than of the name.
        let hard = ledger.spoolFile.appendingPathExtension("draining")
        ledger.enqueueNotification(banner("hard-linked"), now: 1060)
        #expect((try? FileManager.default.linkItem(at: ledger.spoolFile, to: hard)) != nil,
                "the fixture could not make a hard link")
        #expect(ledger.drainNotifications(now: 1070).map(\.title) == ["hard-linked"],
                "one entry, one banner")
        #expect(!FileManager.default.fileExists(atPath: hard.path))
        ledger.enqueueNotification(banner("after the hard link"), now: 1080)
        #expect(ledger.drainNotifications(now: 1090).map(\.title) == ["after the hard link"])

        // The shape it must not be confused with: a link to a real file
        // ELSEWHERE is a genuine stranded half. Its lines post, the link
        // goes, and the target survives.
        let elsewhere = dir.appendingPathComponent("stranded.jsonl")
        ledger.enqueueNotification(banner("stranded"), now: 1040)
        try? FileManager.default.moveItem(at: ledger.spoolFile, to: elsewhere)
        try? FileManager.default.createSymbolicLink(
            atPath: sentinel.path, withDestinationPath: elsewhere.path)
        ledger.enqueueNotification(banner("fresh"), now: 1040)
        #expect(ledger.drainNotifications(now: 1050).map(\.title) == ["stranded", "fresh"])
        #expect(FileManager.default.fileExists(atPath: elsewhere.path),
                "a file outside the spool was deleted by a drain")
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    /// The crash can land mid-`write`, so the stranded half can end without a
    /// newline. The spool is line-delimited and the boundary between two reads
    /// of it has to be one too: a partial record glued to the first whole one
    /// parses as neither, and dropping the fresh record as collateral is the
    /// recovery costing a banner it was written to save.
    @Test func aTruncatedStrandedHalfDoesNotSwallowTheFreshOne() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = ledger.spoolFile.appendingPathExtension("draining")
        ledger.enqueueNotification(banner("torn"), now: 1000)
        // What a `write` cut in half leaves: a record with no newline, and in
        // this case no closing brace either.
        let whole = (try? String(contentsOf: ledger.spoolFile, encoding: .utf8)) ?? ""
        #expect(!whole.isEmpty)
        try? String(whole.dropLast(4)).write(to: sentinel, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: ledger.spoolFile)

        ledger.enqueueNotification(banner("whole"), now: 1010)
        // The torn record is unreadable and goes; the whole one behind it must
        // not go with it.
        #expect(ledger.drainNotifications(now: 1020).map(\.title) == ["whole"])
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    /// The one construction whose text no source reader can decide — the
    /// spool deserialiser reads three fields out of a file — so the property
    /// is checked on the values instead.
    ///
    /// A banner with neither subtitle nor body is accepted by
    /// `UNUserNotificationCenter.add`, reports no error and is never
    /// presented, which is the whole of the 0.3.1 silence. Dropped here, out
    /// loud, the way a stale one is: whatever went wrong upstream leaves a
    /// line a person can find.
    @Test func aBannerWithNoInformativeTextIsDroppedAndSaidSo() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        ledger.enqueueNotification(NotificationRequest(title: "title only"), now: 1000)
        // Case 10: whitespace passes an `isEmpty` check and is presented as
        // nothing, so it is the same banner.
        ledger.enqueueNotification(
            NotificationRequest(title: "blank", subtitle: " ", body: "\n"), now: 1000)
        ledger.enqueueNotification(banner("real"), now: 1000)

        #expect(ledger.drainNotifications(now: 1010).map(\.title) == ["real"])
        let log = (try? String(contentsOf: ledger.logFile, encoding: .utf8)) ?? ""
        #expect(log.contains("dropped a banner with no informative text"), "\(log)")
        #expect(log.contains("title only"), "the line names which one: \(log)")
        #expect(log.contains("blank"), "\(log)")
        // A drop is not a refusal to drain: the spool is still claimed whole.
        #expect(ledger.drainNotifications(now: 1010).isEmpty)
    }

    /// The property at the type, over the pairs that decide it.
    @Test func whitespaceIsNotInformativeText() {
        #expect(!NotificationRequest(title: "t").hasInformativeText)
        #expect(!NotificationRequest(title: "t", subtitle: " ", body: "\t").hasInformativeText)
        #expect(!NotificationRequest(title: "t", body: "\n ").hasInformativeText)
        #expect(NotificationRequest(title: "t", body: ".").hasInformativeText)
        #expect(NotificationRequest(title: "t", subtitle: "s").hasInformativeText)
    }

    /// Two ticks can coincide, and both used to record the same ending:
    /// `removeClaim` answered true for a file that was already gone, and
    /// `retire` emits its contracted event on every true.
    @Test func aCoincidingRetireRecordsOneEnding() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claim = Claim(owner: "agent:eval", until: 2000, started: 900)
        #expect(ledger.write(claim))
        let snapshot = ledger.claims()[0]
        #expect(ledger.retire(snapshot, why: "time is up", now: 2001))
        // The tick that lost the race, acting on the same snapshot.
        #expect(ledger.retire(snapshot, why: "time is up", now: 2001) == false)
        let events = (try? String(contentsOf: ledger.eventsFile, encoding: .utf8)) ?? ""
        #expect(events.components(separatedBy: "\"retire\"").count == 2,
                "one ending, one event: \(events)")
        // And no ERROR about it either — the outcome is correct, and a log
        // line for every lost race teaches the reader to skim.
        let log = (try? String(contentsOf: ledger.logFile, encoding: .utf8)) ?? ""
        #expect(!log.contains("ERROR"), "\(log)")
    }

    /// The three answers a removal can give, and which one `retire` is quiet
    /// about.
    ///
    /// `false` was two answers wearing one word — "it changed under us" and
    /// "it was never there" — and `retire` told them apart with a SECOND
    /// `fileExists`, after the removal had already answered. A genuine
    /// `extend`-landed-under-the-tick whose file then went between the two
    /// questions read as the harmless one and was silenced, which is the only
    /// case the ERROR line exists for.
    @Test func aRemovalSaysWhyItDidNotHappenAndRetireSilencesOnlyTheGoneOne() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claim = Claim(owner: "agent:eval", until: 2000, started: 900)
        #expect(ledger.write(claim))
        let snapshot = ledger.claims()[0]

        // `.changed` — an `extend` landed between the snapshot and the tick.
        let extended = Claim(owner: snapshot.owner, until: 5000, started: snapshot.started)
        #expect(ledger.write(extended))
        #expect(ledger.outcomeOfRemovingClaim(id: snapshot.id, ifStillMatching: snapshot)
                == .changed)
        #expect(ledger.retire(snapshot, why: "time is up", now: 2001) == false)
        var log = (try? String(contentsOf: ledger.logFile, encoding: .utf8)) ?? ""
        #expect(log.contains("ERROR: could not retire agent:eval"),
                "the one case the ERROR line is for was silenced: \(log)")
        var events = (try? String(contentsOf: ledger.eventsFile, encoding: .utf8)) ?? ""
        #expect(!events.contains("\"retire\""), "an ending that did not happen: \(events)")
        // The renewed claim is untouched — the whole point of the snapshot.
        #expect(ledger.claims().map(\.until) == [5000])

        // …and the window the old code decided in: the record changed, and
        // then went. The answer is taken from the read that saw it change, so
        // the file being absent a moment later cannot turn the ERROR off.
        let record = ledger.claimsDir.appendingPathComponent(snapshot.id)
        let changedThenVanished = ledger
            .outcomeOfRemovingClaim(id: snapshot.id, ifStillMatching: snapshot)
        try? FileManager.default.removeItem(at: record)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(changedThenVanished == .changed,
                "the second question is what the old code answered with")

        // `.gone` — nothing there, and nothing said about it.
        #expect(ledger.outcomeOfRemovingClaim(id: snapshot.id, ifStillMatching: snapshot)
                == .gone)
        try? FileManager.default.removeItem(at: ledger.logFile)
        #expect(ledger.retire(snapshot, why: "time is up", now: 2002) == false)
        log = (try? String(contentsOf: ledger.logFile, encoding: .utf8)) ?? ""
        #expect(!log.contains("ERROR"), "a correct outcome was reported as one: \(log)")

        // `.removed` — the ending happened, so it is recorded.
        #expect(ledger.write(extended))
        #expect(ledger.outcomeOfRemovingClaim(id: extended.id, ifStillMatching: extended)
                == .removed)
        #expect(ledger.write(extended))
        #expect(ledger.retire(extended, why: "released by hand", now: 5001))
        events = (try? String(contentsOf: ledger.eventsFile, encoding: .utf8)) ?? ""
        #expect(events.components(separatedBy: "\"retire\"").count == 2, "\(events)")
    }

    /// `removingAClaimThatIsAlreadyGoneSucceeds` above is `down`'s truth.
    /// With a snapshot in hand the answer flips: gone is not "still matching",
    /// same as `write(_:ifStillMatching:)` from the other side.
    @Test func aVanishedClaimIsNotStillMatching() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claim = Claim(owner: "agent:x", until: 2000, started: 900)
        #expect(ledger.removeClaim(id: claim.id, ifStillMatching: claim) == false)
        #expect(ledger.removeClaim(id: claim.id) == true)
    }

    /// Re-derived against the addressing the claim-id fix left behind, because
    /// "gone" is a statement about a FILENAME and that fix changed which
    /// filename an owner gets.
    ///
    /// `Terminal` used to pass through as its own id, which on APFS is
    /// `terminal`'s file; it now folds and fingerprints to
    /// `terminal-<fingerprint>`, a name of its own that nothing has written.
    /// So the snapshot form has to answer false for it — and, more to the
    /// point, must not answer about the neighbour it used to collide with. A
    /// true here would be `retire` recording an ending for a claim that is
    /// still holding the machine awake, under a name that never took one.
    @Test func aFoldedOwnerIsGoneOnItsOwnNameNotTheNeighboursFile() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let human = Claim(owner: "terminal", until: 4000, started: 900)
        #expect(ledger.write(human))
        let folded = Claim(owner: "Terminal", until: 4000, started: 900)
        #expect(folded.id != human.id, "the claim-id fix folds and fingerprints: \(folded.id)")

        #expect(ledger.removeClaim(id: folded.id, ifStillMatching: folded) == false)
        #expect(ledger.retire(folded, why: "time is up", now: 4001) == false)
        // The human's claim is untouched, and its ending was never recorded.
        #expect(ledger.claims().map(\.id) == [human.id])
        let events = (try? String(contentsOf: ledger.eventsFile, encoding: .utf8)) ?? ""
        #expect(!events.contains("\"retire\""), "\(events)")
    }

    /// `Claim` got its range check at the parser chokepoint (a corrupt field
    /// traps whichever surface does arithmetic on it first, at exit 133); the
    /// cap record never did, and `until` and `expires` feed the same math.
    @Test func aCorruptCapRecordCannotTrapArithmetic() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let overflow = "format=2\nuntil=9223372036854775807\nset_by=x\nset_at=1000\nexpires=9223372036854775807\n"
        try? overflow.write(to: ledger.capFile, atomically: true, encoding: .utf8)
        #expect(ledger.storedCap() == nil)
        #expect(ledger.readCap(now: 1000) == nil)

        // `expires` is contracted strictly after `until`; a value that is not
        // is damage, and it is re-derived so the ceiling stays real for its
        // own night rather than lapsing early.
        let inverted = "format=2\nuntil=3000\nset_by=x\nset_at=1000\nexpires=2000\n"
        try? inverted.write(to: ledger.capFile, atomically: true, encoding: .utf8)
        #expect(ledger.storedCap()?.expires == Cap.rollover(after: 3000))
    }

    /// The range check must not become a wrong REFUSAL: it accepts exactly
    /// what `Claim.init` accepts, so no record a claim would have been built
    /// from is thrown away here. `maxEpoch` itself is the boundary both sides
    /// take, and the second-to-last epoch is an ordinary value.
    ///
    /// The two directions differ deliberately. An unreadable claim becomes
    /// `until = 1` — already over, so damage cannot hold the machine awake.
    /// An unreadable ceiling becomes NO ceiling, because the other direction
    /// is a lockout invented out of `Int.max` that refuses every claim, and
    /// costing a caller awake time is the failure this tool exists to prevent
    /// (AGENTS.md).
    @Test func theCapAcceptsEveryEpochAClaimWouldAccept() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The boundary, which `Claim.init` takes as a value.
        #expect(Claim(owner: "x", until: Claim.maxEpoch, started: 0).until == Claim.maxEpoch)
        let atTheEdge = "format=2\nuntil=\(Claim.maxEpoch)\nset_by=x\nset_at=1000\n"
            + "expires=\(Claim.maxEpoch)\n"
        try? atTheEdge.write(to: ledger.capFile, atomically: true, encoding: .utf8)
        // `expires == until` is not "strictly after", so it is re-derived —
        // but the ceiling itself survives, which is what must not be refused.
        #expect(ledger.storedCap()?.until == Claim.maxEpoch)

        // And one past it is damage on both sides.
        #expect(Claim(owner: "x", until: Claim.maxEpoch + 1, started: 0).until == 1)
        let pastTheEdge = "format=2\nuntil=\(Claim.maxEpoch + 1)\nset_by=x\nset_at=1000\n"
        try? pastTheEdge.write(to: ledger.capFile, atomically: true, encoding: .utf8)
        #expect(ledger.storedCap() == nil)

        // A negative epoch is out of range at both ends of the same interval.
        let negative = "format=2\nuntil=-1\nset_by=x\nset_at=1000\nexpires=-1\n"
        try? negative.write(to: ledger.capFile, atomically: true, encoding: .utf8)
        #expect(ledger.storedCap() == nil)
    }

    /// An `expires` that is too FAR out is damage too, and it was the one
    /// shape both checks let through: `until` and `expires` each in range,
    /// `expires` strictly after `until`, and mutually inconsistent.
    ///
    /// `until=1000000, expires=4102444800` read back live and
    /// `ClaimCommand.swift:96` then refused every claim and every extend
    /// until 2100 — the lockout the comment above this check exists to
    /// prevent, arriving from the other side. `writeCap` cannot produce it
    /// (`expires` is always `Cap.rollover(after: until)`, ≤ 24 h out), so it
    /// takes a corrupt file, and re-deriving keeps the ceiling real for its
    /// own night instead of stranding it for 75 years.
    @Test func aCapWhoseExpiryIsTooFarOutIsDamageAndIsReDerived() {
        let (ledger, dir) = makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let overWide = "format=2\nuntil=1000000\nset_by=x\nset_at=1000\nexpires=4102444800\n"
        try? overWide.write(to: ledger.capFile, atomically: true, encoding: .utf8)
        #expect(ledger.storedCap()?.expires == Cap.rollover(after: 1_000_000),
                "a cap whose expiry is in 2100 locks every claim out until then")
        // And the ceiling itself survives — the direction that must not
        // become a wrong refusal.
        #expect(ledger.storedCap()?.until == 1_000_000)

        // The boundary, which is why the check is `>` and not `>=`: the value
        // `writeCap` itself produces must read back unchanged.
        let onTheRollover = "format=2\nuntil=1000000\nset_by=x\nset_at=1000\n"
            + "expires=\(Cap.rollover(after: 1_000_000))\n"
        try? onTheRollover.write(to: ledger.capFile, atomically: true, encoding: .utf8)
        #expect(ledger.storedCap()?.expires == Cap.rollover(after: 1_000_000))

        // Asserted through `writeCap` as well, so the boundary is the real
        // one rather than this test's arithmetic agreeing with itself.
        #expect(ledger.writeCap(until: 3000, setBy: "terminal", now: 1000))
        #expect(ledger.storedCap()?.expires == Cap.rollover(after: 3000),
                "a cap round-trip through writeCap lost its expiry")
    }
}
