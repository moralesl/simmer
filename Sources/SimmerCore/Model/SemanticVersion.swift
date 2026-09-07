import Foundation

/// Comparing "0.2.0" with the newest release tag, which is the whole question
/// `simmer update` answers.
///
/// Deliberately not in `Version.swift`: the Makefile extracts the one version
/// string from that file with `sed -n 's/.*string = "\(.*\)".*/\1/p'`, so a
/// second `string = "…"` anywhere in it would make `$(VERSION)` two lines and
/// stamp a broken Info.plist. One line in one file, and everything else about
/// versions lives here.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// `-dev`, `-rc.1`, … with the leading dash removed. Empty for a release.
    public let prerelease: String

    /// Tolerates the two spellings simmer actually holds: a bare version as
    /// `SimmerVersion.string` writes it, and a `v`-prefixed git tag as the
    /// repository publishes it. Anything else is nil rather than a guess — a
    /// wrong parse here would report an update that does not exist, or hide
    /// one that does.
    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        // Build metadata is not part of precedence in semver, and simmer has
        // never published any. Dropped rather than parsed.
        body = String(body.split(separator: "+", maxSplits: 1).first ?? "")
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let numbers = parts.first, !numbers.isEmpty else { return nil }
        prerelease = parts.count > 1 ? String(parts[1]) : ""

        let fields = numbers.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        var values = [0, 0, 0]
        for (index, field) in fields.enumerated() {
            guard let value = Int(field), value >= 0, !field.isEmpty else { return nil }
            values[index] = value
        }
        (major, minor, patch) = (values[0], values[1], values[2])
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease)"
    }

    /// Semver precedence: the numeric triple first, and a prerelease ranks
    /// BELOW the release it leads up to. `0.3.0-dev < 0.3.0` matters for the
    /// one case a maintainer hits daily — a working tree whose version has
    /// already been bumped past the newest tag must not be told to update to
    /// something older than what it is running.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease == rhs.prerelease { return false }
        if lhs.prerelease.isEmpty { return false }   // a release outranks its own prereleases
        if rhs.prerelease.isEmpty { return true }
        return lhs.prerelease.compare(rhs.prerelease, options: .numeric) == .orderedAscending
    }
}
