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

    public init(owner: String, until: Int, started: Int, reason: String = "",
                minBattery: Int = Claim.defaultMinBattery, requireAC: Bool = false,
                displayOn: Bool = false, warned: Bool = false, prewarned: Bool = false,
                reminded: Int = 0, legacyCaffeinatePid: Int = 0) {
        self.id = Claim.sanitizedId(owner)
        self.owner = Claim.singleLine(owner, limit: Claim.maxOwnerLength)
        self.until = until
        self.started = started
        self.reason = Claim.singleLine(reason, limit: Claim.maxReasonLength)
        self.minBattery = minBattery
        self.requireAC = requireAC
        self.displayOn = displayOn
        self.warned = warned
        self.prewarned = prewarned
        self.reminded = reminded
        self.legacyCaffeinatePid = legacyCaffeinatePid
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
        guard folded != owner || overlong else { return folded }
        let stem = overlong ? String(folded.prefix(idStemBudget)) : folded
        return "\(stem)-\(fingerprint(owner))"
    }

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
