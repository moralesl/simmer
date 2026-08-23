import Foundation

/// One claim: a deadline, a reason, a battery floor, and a name on it.
/// A claim's id IS its owner (CONTRACTS.md § D1) — one live claim per owner,
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

    public init(owner: String, until: Int, started: Int, reason: String = "",
                minBattery: Int = Claim.defaultMinBattery, requireAC: Bool = false,
                displayOn: Bool = false, warned: Bool = false, prewarned: Bool = false,
                reminded: Int = 0, legacyCaffeinatePid: Int = 0) {
        self.id = Claim.sanitizedId(owner)
        self.owner = owner
        self.until = until
        self.started = started
        self.reason = reason
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
    public static func sanitizedId(_ owner: String) -> String {
        String(owner.map { char in
            char.isASCII && (char.isLetter || char.isNumber || "._:-".contains(char)) ? char : "_"
        })
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
    public static func parse(_ text: String, fallbackId: String) -> Claim {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        let id = fields["id"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackId
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
