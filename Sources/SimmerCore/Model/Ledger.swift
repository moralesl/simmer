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

    /// False when the claim did not reach disk. Callers that already announced
    /// awake time MUST check: the switch flips before the claim file lands, so
    /// a swallowed failure is the one state where simmer says "simmering
    /// until 11:00" about a claim that does not exist. The guard would heal it
    /// within 30s — toward sleep, the safe direction — but the sentence was
    /// still a lie, and honesty is not something the next tick can restore.
    @discardableResult
    public func write(_ claim: Claim) -> Bool {
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

    /// False when the cap did not reach disk — same argument as `write`: a
    /// ceiling that was announced but not recorded is worse than a refusal.
    @discardableResult
    public func writeCap(until: Int, setBy: String, now: Int) -> Bool {
        let text = "format=\(Claim.format)\nuntil=\(until)\nset_by=\(setBy)\nset_at=\(now)\n"
        return atomicWrite(text, to: capFile)
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

    // MARK: the notification spool — the CLI's channel TO the app
    //
    // macOS binds notification authorization to the executable that asked,
    // so only the app can post (LEARNINGS.md). CLI and guard append their
    // banners here; the app drains and posts within seconds. App not
    // running = no banners, which is honest: the menu bar is gone too.

    public var spoolFile: URL { stateDir.appendingPathComponent("notify-spool.jsonl") }
    public var appStatusFile: URL { stateDir.appendingPathComponent("app.status") }

    public func enqueueNotification(_ request: NotificationRequest, now: Int) {
        let json = JSONValue.object([
            ("v", .int(1)),
            ("ts", .int(now)),
            ("title", .string(request.title)),
            ("subtitle", .string(request.subtitle)),
            ("body", .string(request.body)),
            ("sound", .bool(request.sound)),
            ("actionable", .bool(request.actionable)),
        ])
        append(json.serialized() + "\n", to: spoolFile)
    }

    /// Claims the whole spool atomically (rename), so a racing append lands
    /// in a fresh file instead of being lost mid-read. Entries older than
    /// `maxAge` are dropped: they queued while the app was not running, and
    /// a stale banner is worse than none.
    public func drainNotifications(now: Int, maxAge: Int = 120) -> [NotificationRequest] {
        let draining = spoolFile.appendingPathExtension("draining")
        guard (try? FileManager.default.moveItem(at: spoolFile, to: draining)) != nil,
              let text = try? String(contentsOf: draining, encoding: .utf8) else { return [] }
        defer { try? FileManager.default.removeItem(at: draining) }
        var requests: [NotificationRequest] = []
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any] else { continue }
            let ts = object["ts"] as? Int ?? 0
            if now - ts > maxAge {
                log("dropped a stale banner (queued \(now - ts)s ago): \(object["title"] as? String ?? "?")",
                    now: now)
                continue
            }
            requests.append(NotificationRequest(
                title: object["title"] as? String ?? "",
                subtitle: object["subtitle"] as? String ?? "",
                body: object["body"] as? String ?? "",
                sound: object["sound"] as? Bool ?? true,
                actionable: object["actionable"] as? Bool ?? false))
        }
        return requests
    }

    // MARK: the app's heartbeat — what doctor reads instead of asking UN
    //
    // The CLI must never ask UNUserNotificationCenter anything: it would be
    // told about ITS OWN executable's (never-granted) state, which is the
    // misread that produced a wrong LEARNINGS entry before this file existed.

    /// A heartbeat, so a failed write is not worth reporting: the next one is
    /// three seconds away, and doctor treats a missing or stale file as "the
    /// app is not talking" — which is exactly what it would mean.
    public func writeAppStatus(notifyStatus: String, now: Int) {
        _ = atomicWrite("pid=\(getpid())\nnotify=\(notifyStatus)\nts=\(now)\n", to: appStatusFile)
    }

    public struct AppStatus {
        public var pid: Int
        public var notify: String
        public var ts: Int
    }

    public func readAppStatus() -> AppStatus? {
        guard let text = try? String(contentsOf: appStatusFile, encoding: .utf8) else { return nil }
        var pid = 0, ts = 0
        var notify = "unknown"
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            switch key {
            case "pid": pid = Int(value) ?? 0
            case "notify": notify = value
            case "ts": ts = Int(value) ?? 0
            default: break
            }
        }
        return AppStatus(pid: pid, notify: notify, ts: ts)
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

    /// Temp file then rename, so a racing reader never sees half a record.
    /// Returns whether the record actually landed; the temp file is cleaned up
    /// on the failure path rather than left behind next to real state.
    private func atomicWrite(_ text: String, to url: URL) -> Bool {
        let tmp = url.appendingPathExtension("tmp.\(getpid())")
        do {
            try text.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
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
