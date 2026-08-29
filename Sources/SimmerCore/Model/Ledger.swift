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

    /// Created 0700, and every record inside it 0600.
    ///
    /// The default was 0755/0644 — world-readable — while SECURITY.md
    /// describes this directory as belonging to the user who owns it. A reason
    /// is free text a person or an agent writes about what they are doing, so
    /// in practice it carries customer names, project names and ticket
    /// numbers; the log and the event stream keep every one of them, dated.
    /// Nothing needs to read this but its owner.
    ///
    /// Applied at creation only. An existing directory keeps the mode it has —
    /// tightening someone's state behind their back is not this function's
    /// call — and `doctor` reports the wider mode instead.
    public init(stateDir: URL) {
        self.stateDir = stateDir
        try? FileManager.default.createDirectory(
            at: claimsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
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

    /// False when the record is still on disk. A claim that is already gone
    /// counts as removed — the guard and a human can race for the same claim,
    /// and both should be told the truth, which is that it is not there.
    ///
    /// Same argument as `write` and `writeCap`, from the other end: `down`
    /// swallowed this failure and announced a release anyway, so the response
    /// contradicted itself in one line — "released" beside `claim_count: 1` —
    /// while the Mac stayed awake against an explicit instruction to let go.
    public func removeClaim(id: String) -> Bool {
        let url = claimsDir.appendingPathComponent(id)
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Retire: clean up a spike-written claim's recorded caffeinate child,
    /// remove the file, log why. The switch is settle()'s job, never this one's.
    ///
    /// False when the file did not go. The `retire` event is emitted only on
    /// the true path, so the stream never records an ending that did not
    /// happen — the log carries the failure, because inventing an event kind
    /// for it would change a contracted surface.
    public func retire(_ claim: Claim, why: String, now: Int) -> Bool {
        if claim.legacyCaffeinatePid > 0 {
            kill(pid_t(claim.legacyCaffeinatePid), SIGTERM)
        }
        guard removeClaim(id: claim.id) else {
            log("ERROR: could not retire \(claim.owner) · \(why) — \(claimsDir.appendingPathComponent(claim.id).path) is still there",
                now: now)
            return false
        }
        let reasonPart = claim.reason.isEmpty ? "" : " (\(claim.reason))"
        log("retired \(claim.owner)\(reasonPart) · \(why)", now: now)
        event("retire", now: now, [
            ("owner", .string(claim.owner)),
            ("reason", .string(claim.reason)),
            ("until", .int(claim.until)),
            ("why", .string(why)),
        ])
        return true
    }

    // MARK: the cap

    /// The cap **as it is in force right now**, which is the only form any
    /// caller should ever see. Past its rollover it reports as no cap at all:
    /// a ceiling is a decision about one night, and once the night is over
    /// that decision has been served, not forgotten.
    ///
    /// Taking `now` is deliberate. An argument-less read would let a new
    /// caller reintroduce yesterday's ceiling by accident, which is exactly
    /// the trap this replaced.
    public func readCap(now: Int) -> CapRecord? {
        guard let cap = storedCap(), now < cap.expires else { return nil }
        return cap
    }

    /// What is on disk, expired or not — for the guard's sweep alone. Every
    /// other caller wants `readCap(now:)`.
    public func storedCap() -> CapRecord? {
        guard let text = try? String(contentsOf: capFile, encoding: .utf8) else { return nil }
        var until = 0, setAt = 0, expires = 0
        var setBy = ""
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            switch key {
            case "until": until = Int(value) ?? 0
            case "set_by": setBy = value
            case "set_at": setAt = Int(value) ?? 0
            case "expires": expires = Int(value) ?? 0
            default: break
            }
        }
        guard until != 0 else { return nil }
        // A file written before caps expired carries no `expires`. Deriving it
        // here is what retires those caps on first read rather than stranding
        // them — the migration is the default, not a step anyone runs.
        return CapRecord(until: until, setBy: setBy, setAt: setAt,
                         expires: expires != 0 ? expires : Cap.rollover(after: until))
    }

    /// False when the cap did not reach disk — same argument as `write`: a
    /// ceiling that was announced but not recorded is worse than a refusal.
    /// The rollover is recorded rather than recomputed on every read, so a cap
    /// keeps the expiry it was set with even if the constant later moves.
    @discardableResult
    public func writeCap(until: Int, setBy: String, now: Int) -> Bool {
        // `set_by` is free text copied into a newline-delimited record whose
        // parser is last-key-wins — the same shape, in the same format, that a
        // reason had. `Claim.singleLine` was put in `Claim`'s initialiser so
        // every path into a CLAIM goes through it; the cap is not a claim, so
        // it went around. `--owner $'terminal\nuntil=0'` printed "⛔ nothing
        // past 23:00" at exit 0 and recorded no ceiling at all; a past epoch
        // instead recorded a lockout, announced identically.
        let owner = Claim.singleLine(setBy, limit: Claim.maxOwnerLength)
        let text = """
            format=\(Claim.format)
            until=\(until)
            set_by=\(owner)
            set_at=\(now)
            expires=\(Cap.rollover(after: until))

            """
        return atomicWrite(text, to: capFile)
    }

    /// False when the ceiling is still on disk. The asymmetry with `writeCap`
    /// five lines up — whose failure was checked, above a comment saying why —
    /// is what made this the worse half: `cap off` announced the lift on
    /// stdout, in `--json` and on the event stream, and a passed cap that
    /// survived its own lift then refused every new claim while naming the
    /// command that had just succeeded as the fix.
    public func clearCap() -> Bool {
        do {
            try FileManager.default.removeItem(at: capFile)
            return true
        } catch {
            return !FileManager.default.fileExists(atPath: capFile.path)
        }
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
    // so only the app can post (PLATFORM-FACTS.md). CLI and guard append their
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
        guard (try? FileManager.default.moveItem(at: spoolFile, to: draining)) != nil
        else { return [] }
        // Armed the moment the sentinel exists, not after the read. Registered
        // below the read, its own failure path stranded the file it was there
        // to remove — and a spool that can never be moved into place again is
        // every banner, silently, forever.
        defer { try? FileManager.default.removeItem(at: draining) }
        guard let text = try? String(contentsOf: draining, encoding: .utf8) else { return [] }
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
    // misread this split exists to prevent (PLATFORM-FACTS.md).

    /// A heartbeat, so a failed write is not worth reporting: the next one is
    /// three seconds away, and doctor treats a missing or stale file as "the
    /// app is not talking" — which is exactly what it would mean.
    ///
    /// `login` rides along for the same reason `notify` does: only the app can
    /// answer it (SMAppService is bundle-scoped and the app is the bundle's
    /// main app), and the CLI asking for itself would learn about the wrong
    /// thing. One channel, already beating, rather than a second way to ask.
    public func writeAppStatus(notifyStatus: String, loginStatus: String, now: Int) {
        _ = atomicWrite("pid=\(getpid())\nnotify=\(notifyStatus)\nlogin=\(loginStatus)\nts=\(now)\n",
                        to: appStatusFile)
    }

    public struct AppStatus {
        public var pid: Int
        public var notify: String
        /// `enabled` · `notRegistered` · `requiresApproval` · `notFound` ·
        /// `unknown` when written by a version that predates the field.
        public var login: String
        public var ts: Int
    }

    public func readAppStatus() -> AppStatus? {
        guard let text = try? String(contentsOf: appStatusFile, encoding: .utf8) else { return nil }
        var pid = 0, ts = 0
        var notify = "unknown"
        var login = "unknown"
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            switch key {
            case "pid": pid = Int(value) ?? 0
            case "notify": notify = value
            case "login": login = value
            case "ts": ts = Int(value) ?? 0
            default: break
            }
        }
        return AppStatus(pid: pid, notify: notify, login: login, ts: ts)
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
        // The lease is deleted only once the claim it became is on disk.
        // Deleting it either way lost the awake time it carried and logged a
        // success about it — the one outcome this function exists to prevent.
        guard write(claim) else {
            log("ERROR: could not migrate the format=1 lease — it is left in place, and will be tried again",
                now: now)
            return
        }
        try? FileManager.default.removeItem(at: leaseFile)
        log("migrated a format=1 lease into claim \(claim.id)", now: now)
        event("migrate", now: now, [
            ("owner", .string(claim.owner)),
            ("until", .int(claim.until)),
        ])
    }

    /// Claim files the previous release wrote under a name this one no longer
    /// resolves to.
    ///
    /// `sanitizedId` folds case before deciding whether an owner is already
    /// filename-safe, because APFS reads `Terminal` and `terminal` as one file
    /// and the ledger is the same filesystem. That was right. What it did not
    /// account for is that 0.1.0 had already written claims under mixed-case
    /// owners: `agent:CI-nightly` was filename-safe then and resolves to
    /// `agent:ci-nightly-<fingerprint>` now — a different NAME, not a case
    /// variant, so the filesystem does not reunite them.
    ///
    /// The orphan kept enumerating and kept holding the switch while its own
    /// owner got "you hold no claim"; `guard` had no deadline to heal an
    /// open-ended one by, and `doctor` stayed green. The same owner's next
    /// claim did not replace it, it doubled it.
    ///
    /// So the file moves to the name its owner resolves to now. One claim per
    /// owner is the rule, so a collision keeps the later deadline rather than
    /// either file in particular — no path through a migration may cost a
    /// caller awake time it already holds (AGENTS.md).
    ///
    /// Same discipline as `migrateLease`: the old file goes only once the new
    /// one is on disk, and a failed write leaves both in place to be tried
    /// again next run rather than logging a success about a claim that went
    /// nowhere. `migrate` is reused rather than a new event kind invented on a
    /// contracted stream.
    public func migrateClaimIds(now: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: claimsDir, includingPropertiesForKeys: nil)) ?? []
        for url in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            var claim = Claim.parse(text, fallbackId: name)
            let resolved = Claim.sanitizedId(claim.owner)
            // Move only files the PREVIOUS algorithm would have written for
            // this owner. "the name is not what we would write now" is the
            // tempting condition and it is wrong: `owner` is stored truncated
            // to `maxOwnerLength` while the id is fingerprinted over the whole
            // string, so a long owner's record cannot reconstruct its own id
            // and would be renamed to a name nobody can address. Asking what
            // 0.1.0 would have produced is the question that has an answer.
            guard !resolved.isEmpty, resolved != name, Ledger.legacyId(claim.owner) == name
            else { continue }

            claim.id = resolved
            var keep = claim
            let target = claimsDir.appendingPathComponent(resolved)
            if let rivalText = try? String(contentsOf: target, encoding: .utf8) {
                let rival = Claim.parse(rivalText, fallbackId: resolved)
                if Ledger.outlasts(rival, claim) { keep = rival }
            }
            guard write(keep) else {
                log("ERROR: could not migrate claim \(name) to \(resolved) — it is left in place, and will be tried again",
                    now: now)
                continue
            }
            try? FileManager.default.removeItem(at: url)
            log("migrated claim \(name) into \(resolved)", now: now)
            event("migrate", now: now, [
                ("owner", .string(keep.owner)),
                ("until", .int(keep.until)),
            ])
        }
    }

    /// `Claim.sanitizedId` exactly as 0.1.0 shipped it — no case folding, and
    /// that release's stem budget, which was one character wider because the
    /// temp file had not yet gained its leading dot.
    ///
    /// **Frozen. Never refactor this to share code with the current one**: its
    /// whole job is to disagree with it, and the day the two are made to agree
    /// is the day the migration silently stops recognising anything.
    static func legacyId(_ owner: String) -> String {
        let flattened = String(owner.map { char in
            char.isASCII && (char.isLetter || char.isNumber || "._:-".contains(char)) ? char : "_"
        })
        let stemBudget = 255 - (".tmp.".count + 8) - 1 - 8
        let overlong = flattened.count > stemBudget
        guard flattened != owner || overlong else { return flattened }
        let stem = overlong ? String(flattened.prefix(stemBudget)) : flattened
        return "\(stem)-\(Claim.fingerprint(owner))"
    }

    /// An open-ended claim outlasts every dated one, and ties with another
    /// open-ended one rather than displacing it.
    static func outlasts(_ a: Claim, _ b: Claim) -> Bool {
        if a.until == 0 { return b.until != 0 }
        if b.until == 0 { return false }
        return a.until > b.until
    }

    // MARK: primitives

    /// Temp file then rename, so a racing reader never sees half a record.
    /// Returns whether the record actually landed; the temp file is cleaned up
    /// on the failure path rather than left behind next to real state.
    ///
    /// **The temp file is staged in `stateDir`, never in `claims/`.** Staging
    /// it beside its destination put a second file into the one directory that
    /// is enumerated as the list of live claims, and `claims()` cannot tell
    /// them apart: both are regular files, both parse. The cleanup on the
    /// failure path above is in-process only, so anything that ends the
    /// process between the write and the rename — SIGKILL, a panic, power
    /// loss — leaves that file behind as a claim nothing can remove.
    ///
    /// `stateDir` is enumerated by nobody, so debris there is inert. The
    /// leading dot says the same thing to a person reading the directory.
    private func atomicWrite(_ text: String, to url: URL) -> Bool {
        let tmp = stateDir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid())")
        do {
            try text.write(to: tmp, atomically: false, encoding: .utf8)
            // Set on the temp file, so the record is never briefly world-
            // readable between landing and being tightened.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: tmp.path)
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
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
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
    /// When the ceiling stops applying on its own. Always strictly after
    /// `until`, so the gate is real for the whole night it was set for.
    public var expires: Int

    public init(until: Int, setBy: String, setAt: Int, expires: Int) {
        self.until = until
        self.setBy = setBy
        self.setAt = setAt
        self.expires = expires
    }
}

/// Where the cap's self-lifting rule lives.
///
/// A cap answers "nothing past 23:00" — a statement about tonight. Leaving it
/// standing the next morning turns one evening's decision into a lockout the
/// person who set it has to remember to undo, and the surface that told them
/// how is a notification they saw eleven hours ago. So the ceiling lifts
/// itself at the next rollover, and the refusal in between says when.
public enum Cap {
    /// The morning the night is over. Not configurable on purpose: a knob
    /// here is one more thing to hold in your head, which is the problem.
    public static let rolloverTime = "09:00"

    /// The first rollover strictly after `until`. One rule, no special cases —
    /// which does mean a *daytime* cap (`simmer cap 2h` at 11:00) stays a gate
    /// until the following morning. That is rare, deliberate, and still ends
    /// by itself; splitting the rule to shave it would cost more than it buys.
    public static func rollover(after until: Int) -> Int {
        // parseUntil already rolls to the next occurrence and goes through
        // Calendar, so this inherits its DST correctness rather than adding a
        // second, worse date calculation.
        Durations.parseUntil(rolloverTime, now: until) ?? until + 86_400
    }
}

/// A claim's deadline as the machine will actually honour it: no deadline plus
/// a cap is a deadline; a deadline past the cap is the cap.
public func cappedUntil(_ until: Int, cap: CapRecord?) -> Int {
    guard let cap else { return until }
    if until == 0 || until > cap.until { return cap.until }
    return until
}
