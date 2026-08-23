import Foundation

/// The claims directory, the cap, the log and the event stream — everything
/// under `$XDG_STATE_HOME/simmer/`. All writes are temp-file + rename (claims,
/// cap) or single-line O_APPEND (log, events), so a racing reader never sees
/// half a record. Two tickers racing is a design requirement, not a hope.
public struct Ledger: Sendable {
    public let stateDir: URL
    public var claimsDir: URL { stateDir.appendingPathComponent("claims") }
    public var capFile: URL { stateDir.appendingPathComponent("cap") }
    public var leaseFile: URL { stateDir.appendingPathComponent("lease") }
    public var logFile: URL { stateDir.appendingPathComponent("simmer.log") }
    public var eventsFile: URL { stateDir.appendingPathComponent("events.jsonl") }

    public init(stateDir: URL) {
        self.stateDir = stateDir
        try? FileManager.default.createDirectory(at: claimsDir, withIntermediateDirectories: true)
    }

    // MARK: claims

    /// Sorted by filename — alphabetical and therefore stable, so ties in the
    /// aggregate resolve the same way on every run and in every implementation.
    public func claims() -> [Claim] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: claimsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Claim.parse(text, fallbackId: url.lastPathComponent)
            }
    }

    public func claimFile(owner: String) -> URL {
        claimsDir.appendingPathComponent(Claim.sanitizedId(owner))
    }

    public func claim(owner: String) -> Claim? {
        let url = claimFile(owner: owner)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Claim.parse(text, fallbackId: url.lastPathComponent)
    }

    public func write(_ claim: Claim) {
        atomicWrite(claim.serialized(), to: claimsDir.appendingPathComponent(claim.id))
    }

    public func removeClaim(id: String) {
        try? FileManager.default.removeItem(at: claimsDir.appendingPathComponent(id))
    }

    /// Retire: clean up a spike-written claim's recorded caffeinate child,
    /// remove the file, log why. The switch is settle()'s job, never this one's.
    public func retire(_ claim: Claim, why: String, now: Int) {
        if claim.legacyCaffeinatePid > 0 {
            kill(pid_t(claim.legacyCaffeinatePid), SIGTERM)
        }
        removeClaim(id: claim.id)
        let reasonPart = claim.reason.isEmpty ? "" : " (\(claim.reason))"
        log("retired \(claim.owner)\(reasonPart) · \(why)", now: now)
        event("retire", now: now, [
            ("owner", .string(claim.owner)),
            ("reason", .string(claim.reason)),
            ("until", .int(claim.until)),
            ("why", .string(why)),
        ])
    }

    // MARK: the cap

    public func readCap() -> CapRecord? {
        guard let text = try? String(contentsOf: capFile, encoding: .utf8) else { return nil }
        var until = 0, setAt = 0
        var setBy = ""
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            switch key {
            case "until": until = Int(value) ?? 0
            case "set_by": setBy = value
            case "set_at": setAt = Int(value) ?? 0
            default: break
            }
        }
        guard until != 0 else { return nil }
        return CapRecord(until: until, setBy: setBy, setAt: setAt)
    }

    public func writeCap(until: Int, setBy: String, now: Int) {
        let text = "format=\(Claim.format)\nuntil=\(until)\nset_by=\(setBy)\nset_at=\(now)\n"
        atomicWrite(text, to: capFile)
    }

    public func clearCap() {
        try? FileManager.default.removeItem(at: capFile)
    }

    // MARK: log + events

    public func log(_ message: String, now: Int) {
        append("\(Formats.logStamp(now))  \(message)\n", to: logFile)
    }

    /// One JSON object per transition, append-only (CONTRACTS.md § State).
    /// `ts_human` repeats the timestamp readably so the stream can be read
    /// without a converter; fields are append-only like every machine surface.
    public func event(_ name: String, now: Int, _ fields: [(String, JSONValue)]) {
        var pairs: [(String, JSONValue)] = [
            ("v", .int(1)),
            ("ts", .int(now)),
            ("ts_human", .string(Formats.logStamp(now))),
            ("event", .string(name)),
        ]
        pairs.append(contentsOf: fields)
        append(JSONValue.object(pairs).serialized() + "\n", to: eventsFile)
    }

    // MARK: migration from the single lease (format=1)

    /// Read once, converted, deleted. Someone upgrading mid-lease must not
    /// silently lose awake time — and must never end up with both shapes on
    /// disk, which is how a guard learns to disagree with the CLI.
    public func migrateLease(now: Int) {
        guard let text = try? String(contentsOf: leaseFile, encoding: .utf8) else { return }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        let owner = fields["owner"].flatMap { $0.isEmpty ? nil : $0 } ?? "legacy"
        var claim = Claim(
            owner: owner,
            until: Int(fields["until"] ?? "") ?? 0,
            started: Int(fields["started"] ?? "") ?? 0,
            reason: fields["reason"] ?? "",
            minBattery: Int(fields["min_battery"] ?? "") ?? Claim.defaultMinBattery,
            warned: fields["warned"] == "1",
            reminded: Int(fields["reminded"] ?? "") ?? 0,
            legacyCaffeinatePid: Int(fields["caffeinate"] ?? "") ?? 0
        )
        // An owner who already holds a claim keeps it; the lease lands as "legacy".
        if FileManager.default.fileExists(atPath: claimFile(owner: owner).path) {
            claim.id = "legacy"
            claim.owner = "legacy"
        }
        write(claim)
        try? FileManager.default.removeItem(at: leaseFile)
        log("migrated a format=1 lease into claim \(claim.id)", now: now)
        event("migrate", now: now, [
            ("owner", .string(claim.owner)),
            ("until", .int(claim.until)),
        ])
    }

    // MARK: primitives

    private func atomicWrite(_ text: String, to url: URL) {
        let tmp = url.appendingPathExtension("tmp.\(getpid())")
        try? text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// POSIX O_APPEND, not seek-then-write: the app's event tick and the
    /// LaunchAgent tick may append concurrently, and only kernel-level append
    /// keeps their lines whole.
    private func append(_ text: String, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let data = Array(text.utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}

public struct CapRecord: Sendable, Equatable {
    public var until: Int
    public var setBy: String
    public var setAt: Int

    public init(until: Int, setBy: String, setAt: Int) {
        self.until = until
        self.setBy = setBy
        self.setAt = setAt
    }
}

/// A claim's deadline as the machine will actually honour it: no deadline plus
/// a cap is a deadline; a deadline past the cap is the cap.
public func cappedUntil(_ until: Int, cap: CapRecord?) -> Int {
    guard let cap else { return until }
    if until == 0 || until > cap.until { return cap.until }
    return until
}
