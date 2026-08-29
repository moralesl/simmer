import Foundation

/// One claim: a deadline, a reason, a battery floor, and a name on it.
/// A claim's id IS its owner (CONTRACTS.md § the claims ledger) — one live claim per owner,
/// and no actor can address another's by construction.
///
/// Persisted as a flat format=2 key=value file so the menu bar can read a
/// countdown without `jq`. Written temp-file-then-rename, never edited in
/// place, so the guard can never read half a claim.
public struct Claim: Sendable, Equatable {
    public var id: String
    public var owner: String
    /// Epoch; 0 = no deadline ("forever").
    public var until: Int
    public var started: Int
    public var reason: String
    public var minBattery: Int
    public var requireAC: Bool
    /// Keep the screen lit too (--display-on). The app holds the display
    /// assertion; the claim just records the ask.
    public var displayOn: Bool
    /// Warn-once flag against the aggregate deadline.
    public var warned: Bool
    /// Pre-floor warning (floor + 10 points), re-arms when the battery climbs out.
    public var prewarned: Bool
    /// Epoch of the last open-ended reminder.
    public var reminded: Int
    /// A pid recorded by the v0.1 spike's detached caffeinate. v1 spawns
    /// nothing, but retiring a spike-written claim still cleans up its child.
    public var legacyCaffeinatePid: Int

    public static let format = 2
    public static let defaultMinBattery = 20

    /// Past this, a bare duration gets a sentence about it. Half a day is the
    /// line where "how long I need" stops being plausible as a number of
    /// minutes: `simmer 2000` is 33 h 20 min and is far more likely to be a
    /// typo for `--until 20:00`. Not a refusal — overnight is a first-class
    /// case, which is why `--require-ac` exists.
    public static let longHaulSeconds = 12 * 3600

    /// The far end of any epoch this tool will believe. A claim is bounded by
    /// `Durations.maxSeconds` when it is taken, so nothing legitimate comes
    /// near 2100 — and a number past it is not a deadline, it is damage.
    public static let maxEpoch = 4_102_444_800   // 2100-01-01

    /// **Every numeric field is range-checked here, because this is the one
    /// place a Claim is born** — `parse` calls it, so a corrupt record on disk
    /// cannot get a value past it either.
    ///
    /// Swift's arithmetic traps rather than wrapping, so a field read straight
    /// out of a file and then added to, subtracted from, or narrowed is a
    /// crash waiting on whichever surface touches it first. `started=<Int.min>`
    /// took `budget` down with exit 133 through `now - since`, and
    /// `caffeinate=<Int.max>` took `guard` and `down --all` down through
    /// `pid_t(…)`, which is Int32. Exit 133 is not in the contract's published
    /// table, and a guard that dies on a tick stops handing the machine back.
    ///
    /// Out of range is treated as "this field is not a value", never clamped
    /// to the nearest plausible one — a deadline of 2099 invented out of
    /// `Int.max` would be a guarantee nobody asked for. `until` is the one
    /// with a direction to choose, and it expires: a record this tool cannot
    /// read must not be able to hold the machine awake, and the guard retires
    /// it on the next tick.
    public init(owner: String, until: Int, started: Int, reason: String = "",
                minBattery: Int = Claim.defaultMinBattery, requireAC: Bool = false,
                displayOn: Bool = false, warned: Bool = false, prewarned: Bool = false,
                reminded: Int = 0, legacyCaffeinatePid: Int = 0) {
        func epoch(_ value: Int, orElse fallback: Int) -> Int {
            (0...Claim.maxEpoch).contains(value) ? value : fallback
        }
        self.id = Claim.sanitizedId(owner)
        self.owner = Claim.singleLine(owner, limit: Claim.maxOwnerLength)
        // 1 rather than 0: 0 means "no deadline" and would turn damage into
        // the strongest claim there is. 1 is 1970, so it is already over.
        self.until = epoch(until, orElse: 1)
        self.started = epoch(started, orElse: 0)
        self.reason = Claim.singleLine(reason, limit: Claim.maxReasonLength)
        self.minBattery = (0...100).contains(minBattery) ? minBattery : Claim.defaultMinBattery
        self.requireAC = requireAC
        self.displayOn = displayOn
        self.warned = warned
        self.prewarned = prewarned
        self.reminded = epoch(reminded, orElse: 0)
        // Narrowed to pid_t (Int32) by every caller that uses it, and a pid is
        // positive. Out of range means there is no child to clean up.
        self.legacyCaffeinatePid =
            (1...Int(Int32.max)).contains(legacyCaffeinatePid) ? legacyCaffeinatePid : 0
    }

    /// Anything not filename-safe becomes an underscore. The owner is echoed
    /// back verbatim from inside the file, so the sanitising stays invisible.
    ///
    /// **Flattening alone is not enough, and this is the reason the
    /// fingerprint below exists.** The map is many-to-one: `agent:a/b` and
    /// `agent:a_b` both flattened to `agent:a_b`, so the second actor's claim
    /// silently replaced the first's — a two-hour claim destroyed by an
    /// unrelated one-minute one, with nothing said. Every non-ASCII name
    /// collapsed the same way (`agent:über` and `agent:öber` → `agent:_ber`),
    /// which is not a contrived case for a tool whose author writes German.
    ///
    /// That is the one rule this tool cannot break — "no surface may cost a
    /// caller awake time it already holds" (AGENTS.md) — failing at the exact
    /// place the whole ownership model rests on, since "no actor can address
    /// another's claim" is only true while the owner→id map keeps them apart.
    ///
    /// So the id is the owner **unchanged** whenever the owner is already
    /// filename-safe and short enough — which is every claim any existing
    /// machine holds, so no filename moves and no migration is owed. Only a
    /// name that had to be altered carries a fingerprint of the ORIGINAL, and
    /// that suffix is what keeps two owners that flatten alike apart.
    ///
    /// A fingerprint is collision-*resistant*, not injective, and saying so is
    /// the honest version: two mangled owners can still meet, at even odds
    /// around 77,000 distinct ones on a single Mac. The failure it replaces
    /// needed two.
    /// **Case is part of the flattening, because APFS says it is.** Two ids
    /// that differ only in case are one file on a stock Mac, so `Terminal`
    /// addressed `terminal`'s claim: it destroyed a human's four-hour claim,
    /// replaced it with a one-minute one, said nothing, and left no `retire`
    /// event — the audit trail could not show the claim had ever died. And it
    /// inverted human primacy on the way through, since `isHumanOwnerName`
    /// matched exactly and so read the capitalised name as a non-human actor.
    ///
    /// `Makefile:app` already carries this rule for the two executables —
    /// "APFS is case-insensitive, so Simmer and the CLI simmer would silently
    /// be the same file". The ledger is the same filesystem.
    ///
    /// The test that was meant to catch it compared ids as Swift strings,
    /// which is a stricter notion of distinct than the filesystem's; it now
    /// compares them folded, the way the disk will.
    public static func sanitizedId(_ owner: String) -> String {
        let flattened = String(owner.map { char in
            char.isASCII && (char.isLetter || char.isNumber || "._:-".contains(char)) ? char : "_"
        })
        // Flattening maps every non-ASCII scalar to "_", so `flattened` is
        // pure ASCII — its character count IS its byte count, and lowercasing
        // it cannot change either.
        let folded = flattened.lowercased()
        let overlong = folded.count > idStemBudget
        // **The passthrough and the fingerprinted forms must not overlap.**
        // A fingerprinted id — `agent:a_b-e6a27fc6` — is built only from
        // characters the safe set allows, so it is itself a perfectly valid
        // owner, and naming yourself one mapped straight onto somebody else's
        // claim file: a six-hour claim replaced by a one-minute one, with no
        // retire event and a green `doctor`. Read the victim's id out of
        // `status --json` and claim under it; that is the whole attack.
        //
        // So an owner that already looks like an id is fingerprinted rather
        // than passed through, which is what makes the two sets disjoint —
        // every fingerprinted id ends in `-<8 hex>` and no passthrough one
        // does. Done this way rather than by changing the separator because
        // no existing claim file moves: only a name shaped like an id is
        // affected, and one of those was never addressable by its owner
        // anyway.
        guard folded != owner || overlong || isReservedShape(folded) else { return folded }
        let stem = overlong ? String(folded.prefix(idStemBudget)) : folded
        return "\(stem)-\(fingerprint(owner))"
    }

    /// Names the claims directory reads as meaning something, rather than as
    /// the name of a claim. **A passthrough id may never wear one of these**,
    /// or two things that must be distinguishable become the same string.
    ///
    /// There are two, and they arrived a day apart from opposite directions:
    ///
    /// - `-<8 hex>` is what `sanitizedId` appends when it had to alter an
    ///   owner. Without this rule, reading a victim's id out of `status
    ///   --json` and claiming under it landed on their file.
    /// - `.tmp.<pid>` is what pre-0.2.0 releases staged under, so `Ledger`
    ///   treats a file wearing it as crash debris: uncounted, and swept by the
    ///   guard. Without this rule, `--owner agent:eval.tmp.12` — a job number,
    ///   not an attack — was claimed at exit 0, left the switch on with
    ///   `claim_count: 0`, and was deleted within thirty seconds.
    ///
    /// The second was introduced by the fix for the first's sibling, which is
    /// why the two live here together now: a shape-based classifier over this
    /// directory has to be disjoint from the id space, and the only way that
    /// keeps being true is if adding a third shape means editing the same
    /// list both readers consult.
    static func isReservedShape(_ id: String) -> Bool {
        reservedShapePatterns.contains {
            id.range(of: $0, options: .regularExpression) != nil
        }
    }

    static let reservedShapePatterns = [
        "-[0-9a-f]{8}$",        // a fingerprinted id
        #"\.tmp\.[0-9]+$"#,     // a pre-0.2.0 half-written record
    ]

    /// How much of a mangled owner survives into its id.
    ///
    /// **The ceiling is not `NAME_MAX`.** It is `NAME_MAX` (255 on APFS) minus
    /// the `.tmp.<pid>` suffix `Ledger.atomicWrite` writes under before
    /// renaming into place, because a claim that fits its final name and not
    /// its temporary one never lands. An id of exactly 255 was measured
    /// failing for that reason.
    ///
    /// And it failed by naming the wrong thing: "could not record the claim in
    /// …/claims", which sends the reader to `simmer doctor` — where the claims
    /// directory reports itself writable, because it is. Truncating instead is
    /// only safe because the fingerprint is taken over the WHOLE owner, so
    /// cutting the stem cannot merge two names that differ only past the cut.
    /// The staged name is `.<id>.tmp.<pid>` — a leading dot and the suffix.
    static let idTempSuffix = 1 + ".tmp.".count + 8   // macOS pids are ≤ 5 digits
    static let idBudget = 255 - idTempSuffix
    static let idStemBudget = idBudget - 1 - 8    // the "-" and the fingerprint

    /// The two fields that are copied into the record verbatim, made unable to
    /// carry a line ending.
    ///
    /// The format is newline-delimited `key=value` and the parser is
    /// last-key-wins, so a newline inside `reason` wrote claim fields:
    /// `-r "build⏎until=0"` printed "simmering until 00:12 (30 min)" and
    /// persisted a claim that never expires. A commit message, or any text an
    /// agent composed, is a plausible source — and this tool is driven by
    /// agents, which makes it an ordinary input rather than an attack.
    ///
    /// Normalised here rather than at the CLI so that every path into a claim
    /// goes through it, and so what a surface prints is what the ledger holds.
    /// Refusing was the alternative; a reason is a one-line label for a menu
    /// bar, so folding the whitespace keeps the text the caller meant and
    /// still cannot express a second record.
    /// And a length, because both are labels. A reason is a phrase in a menu
    /// bar and a status line; nothing stopped it being twenty thousand
    /// characters, which reached the menu-bar title, every `status` line, and
    /// every agent's context. `simmer run` records the command it wraps as the
    /// reason, so a long one-liner gets there without anyone typing it.
    ///
    /// Generous on purpose: past these lengths the text has stopped being a
    /// label, and the ellipsis says so rather than pretending it fits.
    public static let maxReasonLength = 200
    public static let maxOwnerLength = 128

    static func singleLine(_ text: String, limit: Int) -> String {
        let folded = String(text.map { char in
            char.isNewline || char.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) })
                ? " " : char
        }).trimmingCharacters(in: .whitespaces)
        guard folded.count > limit else { return folded }
        return String(folded.prefix(limit - 1)) + "…"
    }

    /// A stable fingerprint of the raw owner, in hex so it is filename-safe.
    ///
    /// Hand-rolled FNV-1a and deliberately NOT Swift's `Hasher`, which is
    /// seeded per process: an id that came out different on the next
    /// invocation would leave every actor unable to address the claim it had
    /// just written, which is a worse bug than the one this fixes.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261            // FNV offset basis
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash.multipliedReportingOverflow(by: 16_777_619).partialValue
        }
        return String(format: "%08x", hash)
    }

    /// The same value, with every range re-applied and the id kept.
    ///
    /// `until` and the rest are `var`s, and `extend`, `cap` and `run`'s
    /// renewer all move them after the initialiser has had its say — so a
    /// deadline could be walked past `maxEpoch` one extension at a time and
    /// written out, and the NEXT read folded it to expired. The claim's
    /// deadline moved backwards and nothing said so.
    ///
    /// The id is carried across rather than recomputed: crash debris and
    /// pre-migration records live under names their owner no longer resolves
    /// to, and rebuilding would rename them out from under themselves.
    func revalidated() -> Claim {
        var copy = Claim(owner: owner, until: until, started: started, reason: reason,
                         minBattery: minBattery, requireAC: requireAC, displayOn: displayOn,
                         warned: warned, prewarned: prewarned, reminded: reminded,
                         legacyCaffeinatePid: legacyCaffeinatePid)
        copy.id = id
        return copy
    }

    // MARK: format=2 codec

    public func serialized() -> String {
        var lines = [
            "format=\(Claim.format)",
            "id=\(id)",
            "owner=\(owner)",
            "until=\(until)",
            "started=\(started)",
            "reason=\(reason)",
            "min_battery=\(minBattery)",
            "require_ac=\(requireAC ? 1 : 0)",
            "display=\(displayOn ? 1 : 0)",
            "warned=\(warned ? 1 : 0)",
            "prewarned=\(prewarned ? 1 : 0)",
            "reminded=\(reminded)",
        ]
        // Carried through, never created: the spike's second clock.
        if legacyCaffeinatePid != 0 { lines.append("caffeinate=\(legacyCaffeinatePid)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether this text is a claim record at all.
    ///
    /// `parse` is lenient by design — unknown keys are ignored so fields can be
    /// append-only — and leniency about UNKNOWN keys turned into leniency about
    /// there being no known ones. Anything readable in `claims/` became a claim:
    /// no `until` means 0, and 0 means no deadline, so a `.DS_Store` or an
    /// editor's swap file enumerated as an open-ended claim and the guard
    /// flipped the switch on for it, indefinitely.
    ///
    /// The migration then laundered it. `.DS_Store` is filename-safe under the
    /// old rule and resolves to `.ds_store-<fingerprint>` under the new one, so
    /// `migrateClaimIds` renamed it into a canonically-named file — which the
    /// soundness check reads as a claim whose owner CAN address it, and passes.
    /// Two mechanisms built to protect this directory each made the junk in it
    /// look more legitimate.
    ///
    /// So a record has to say it is one. Every claim simmer has ever written
    /// carries `format=` on its own line; nothing else in the directory does.
    public static func looksLikeRecord(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            guard line.hasPrefix("format=") else { return false }
            return Int(line.dropFirst("format=".count)) != nil
        }
    }

    /// Unknown keys are ignored — that is what lets fields be append-only.
    ///
    /// **The id is the file's NAME, never the `id=` line inside it.** A record
    /// that could rename itself is a record no one can address: `write` and
    /// `removeClaim` key on the id, so a claim whose parsed id had drifted from
    /// its filename was written to one path and deleted from another. It then
    /// survived `down`, survived `down --all`, and had its `retire` event
    /// appended by every guard tick for as long as the machine ran.
    ///
    /// Two ways to get there, and the reason this is a parser rule rather than
    /// a check at either call site:
    ///
    /// - the record wrote it — `reason` is copied in verbatim and the parser is
    ///   last-key-wins, so a reason carrying a newline and `id=` set it; and
    /// - nobody wrote it — a crash between `atomicWrite`'s temp file and its
    ///   rename left a second file whose contents named the *original* id, so
    ///   every tick wrote it faithfully back out under that name. The debris
    ///   resurrected the claim it was a copy of, indefinitely.
    ///
    /// Naming the file is what settles it: a claim lives at exactly one path,
    /// and that path is the only thing that says who it is. `id=` stays in the
    /// record because `cat claims/<x>` should still read as a whole claim — it
    /// is a copy for a reader, not an authority for the parser.
    public static func parse(_ text: String, fallbackId: String) -> Claim {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        let id = fallbackId
        let owner = fields["owner"].flatMap { $0.isEmpty ? nil : $0 } ?? id
        var claim = Claim(
            owner: owner,
            until: Int(fields["until"] ?? "") ?? 0,
            started: Int(fields["started"] ?? "") ?? 0,
            reason: fields["reason"] ?? "",
            minBattery: Int(fields["min_battery"] ?? "") ?? Claim.defaultMinBattery,
            requireAC: fields["require_ac"] == "1",
            displayOn: fields["display"] == "1",
            warned: fields["warned"] == "1",
            prewarned: fields["prewarned"] == "1",
            reminded: Int(fields["reminded"] ?? "") ?? 0,
            legacyCaffeinatePid: Int(fields["caffeinate"] ?? "") ?? 0
        )
        claim.id = id
        return claim
    }
}
