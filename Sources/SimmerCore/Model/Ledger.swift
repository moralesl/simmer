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
            // A name a pre-0.2.0 `atomicWrite` left behind. Those releases
            // staged inside this directory, so a crash between the write and
            // the rename left a COPY of a real claim — `format=` and all, so
            // it reads as a record — that goes on holding the switch and that
            // the guard has no deadline to heal an open-ended one by.
            .filter { !Ledger.isWriteDebris($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      // Not everything in a directory is a record of what is in
                      // it. A file that never said it was a claim does not get
                      // to hold the machine awake because `until` defaulted.
                      Claim.looksLikeRecord(text) else { return nil }
                return Claim.parse(text, fallbackId: url.lastPathComponent)
            }
    }

    /// `<id>.tmp.<pid>`, which is what pre-0.2.0 releases staged under before
    /// renaming into place. Nothing writes this shape any more — the staging
    /// moved to `stateDir` — so a file wearing it in `claims/` is debris by
    /// construction, and it is simmer's own to clear away.
    public static func isWriteDebris(_ name: String) -> Bool {
        // The pattern lives with the other reserved shape, in `Claim`, because
        // `sanitizedId` has to refuse to MINT one and this has to recognise
        // one — and the two staying in step is the whole property. Spelled out
        // here as its own function anyway: the classifier and the id-minter
        // are different jobs that happen to share a list.
        name.range(of: #"\.tmp\.[0-9]+$"#, options: .regularExpression) != nil
            && Claim.isReservedShape(name)
    }

    /// Remove what a crashed write of an older version left behind. Called by
    /// the guard, because a Mac that has been through one is not going to get
    /// there by itself: the file holds the switch, and only `down --all` could
    /// reach it once it was no longer counted as a claim.
    @discardableResult
    public func sweepWriteDebris(now: Int) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: claimsDir, includingPropertiesForKeys: nil)) ?? []
        var swept = 0
        for url in files where Ledger.isWriteDebris(url.lastPathComponent) {
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            log("cleared write debris from an older version: \(url.lastPathComponent)", now: now)
            swept += 1
        }
        return swept
    }

    /// Every filename in the claims directory, debris included — for tests
    /// and for `doctor`, both of which need to see what enumeration hides.
    public func claimFileNamesForTests() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: claimsDir.path)) ?? []).sorted()
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
    /// Write only while what is on disk is still what the caller read.
    ///
    /// The delete half of this got its compare in round 5, because a tick
    /// unlinking by filename destroyed a renewal that landed after its
    /// snapshot. The write half three lines away kept the same shape: a tick
    /// reads `claims()` once, then writes claims back to stamp `warned`,
    /// `prewarned` or `reminded` — and an `extend` or a `down` that lands in
    /// between is overwritten by the older copy. `extend` returns exit 0 and
    /// says the deadline moved; the deadline did not move.
    ///
    /// Same discriminator as `removeClaim`, for the same reason: `until` and
    /// `started` are what a renewal moves, and comparing whole records would
    /// refuse every write once a newer version added a field.
    @discardableResult
    public func write(_ claim: Claim, ifStillMatching expected: Claim) -> Bool {
        let url = claimsDir.appendingPathComponent(claim.id)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Gone since the snapshot — released, retired, swept. Writing now
            // would put it back, which is the resurrection half of the same
            // bug.
            return false
        }
        let current = Claim.parse(text, fallbackId: claim.id)
        guard current.until == expected.until, current.started == expected.started else {
            return false
        }
        return write(claim)
    }

    @discardableResult
    public func write(_ claim: Claim) -> Bool {
        // Re-checked here, not only at birth: every field is a `var` and three
        // commands move `until` after the initialiser has had its say. This is
        // the one door onto disk, so it is where the ranges are enforced
        // rather than trusted.
        atomicWrite(claim.revalidated().serialized(),
                    to: claimsDir.appendingPathComponent(claim.id))
    }

    /// False when the record is still on disk. A claim that is already gone
    /// counts as removed — the guard and a human can race for the same claim,
    /// and both should be told the truth, which is that it is not there.
    ///
    /// Same argument as `write` and `writeCap`, from the other end: `down`
    /// swallowed this failure and announced a release anyway, so the response
    /// contradicted itself in one line — "released" beside `claim_count: 1` —
    /// while the Mac stayed awake against an explicit instruction to let go.
    /// Remove a claim, optionally only while it is still the claim that was
    /// read.
    ///
    /// A tick reads `claims()` once and then unlinks by filename, so an
    /// `extend` landing in between was deleted by a decision taken before it
    /// existed — `extend` returned exit 0 and the renewed claim was gone. The
    /// snapshot is unavoidable; acting on it without looking again is not.
    ///
    /// `until` and `started` are the comparison because they are what a
    /// renewal moves. Comparing whole records would refuse to delete anything
    /// a newer version had added a field to, which is the opposite failure.
    public func removeClaim(id: String, ifStillMatching expected: Claim? = nil) -> Bool {
        let url = claimsDir.appendingPathComponent(id)
        if let expected {
            // Gone since the snapshot is NOT "still matching" — same answer
            // `write(_:ifStillMatching:)` gives from the other side. Two ticks
            // can coincide, and the one that lost the race used to fall
            // through to the unconditional path below, answer true, and have
            // `retire` record the same ending twice on the event stream.
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
            let current = Claim.parse(text, fallbackId: id)
            guard current.until == expected.until, current.started == expected.started else {
                return false
            }
        }
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
        Ledger.endLegacyCaffeinate(claim)
        // Retire what was actually read: if it moved under us, the decision
        // to end it was taken about a claim that no longer exists.
        guard removeClaim(id: claim.id, ifStillMatching: claim) else {
            // Quiet when the file is simply gone: a coinciding tick already
            // retired it and recorded the ending — a second ERROR line about
            // an outcome that is correct would teach the log's reader to skim.
            if FileManager.default.fileExists(atPath: claimsDir.appendingPathComponent(claim.id).path) {
                log("ERROR: could not retire \(claim.owner) · \(why) — it changed under us, or \(claimsDir.appendingPathComponent(claim.id).path) is still there",
                    now: now)
            }
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

    /// Signal the caffeinate a v0.1 spike claim recorded — **only if the pid
    /// still belongs to a caffeinate.**
    ///
    /// It was an unchecked `kill`, and a pid is reused. The record can outlive
    /// the process by weeks (a claim whose machine was hard-powered-off), and
    /// by then the number names whatever the kernel handed it out to next —
    /// somebody's editor, somebody's build. simmer would have SIGTERMed it and
    /// called that cleaning up.
    ///
    /// Two callers, one implementation: the same rule landing at only the call
    /// sites its author had in hand is how four of these came back.
    static func endLegacyCaffeinate(_ claim: Claim) {
        guard claim.legacyCaffeinatePid > 0 else { return }
        let pid = pid_t(claim.legacyCaffeinatePid)
        // `ps -o comm=` is the identity this can actually establish. A pid
        // that is not running answers nothing, which is also a refusal.
        let name = Shell.run("/bin/ps", ["-p", String(pid), "-o", "comm="])
        guard name.status == 0,
              name.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                  .hasSuffix("caffeinate") else { return }
        kill(pid, SIGTERM)
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
        // The same discipline `Claim.init` applies to a claim record, at the
        // cap's own parser chokepoint: out of range is "this field is not a
        // value", never clamped. Swift arithmetic traps rather than wrapping,
        // and both `until` and `expires` feed date math on every surface that
        // asks about the cap — `Claim` got this check and the cap never did.
        //
        // The accepted range is `Claim`'s own, so this cannot refuse a record
        // `Claim.init` would have taken. The direction differs, and has to:
        // an unreadable CLAIM becomes `until = 1`, already over, because
        // damage must not hold the machine awake. An unreadable CEILING
        // becomes no ceiling, because damage must not refuse a caller awake
        // time either — a lockout invented out of `Int.max` is the failure
        // this tool exists to prevent, arriving from the other side.
        func epoch(_ value: Int) -> Int { (0...Claim.maxEpoch).contains(value) ? value : 0 }
        until = epoch(until)
        setAt = epoch(setAt)
        expires = epoch(expires)
        // `expires` is contracted strictly after `until`; a value that is not
        // is damage, and re-deriving it keeps the ceiling real for its night.
        if expires <= until { expires = 0 }
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
        // Discarded on purpose: the log is where a failure elsewhere is
        // reported, so there is nowhere left for a failure OF the log to go.
        _ = append("\(Formats.logStamp(now))  \(message)\n", to: logFile)
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
        _ = append(JSONValue.object(pairs).serialized() + "\n", to: eventsFile)
    }

    // MARK: the notification spool — the CLI's channel TO the app
    //
    // macOS binds notification authorization to the executable that asked,
    // so only the app can post (PLATFORM-FACTS.md). CLI and guard append their
    // banners here; the app drains and posts within seconds. App not
    // running = no banners, which is honest: the menu bar is gone too.

    public var spoolFile: URL { stateDir.appendingPathComponent("notify-spool.jsonl") }
    public var appStatusFile: URL { stateDir.appendingPathComponent("app.status") }
    public var updateCheckFile: URL { stateDir.appendingPathComponent("update-check") }
    /// Present = the app's once-a-day check is off. A stamp file rather than a
    /// preference, for the reason `login-item.offered` is one: the app keeps no
    /// UserDefaults, all of its state is here, and `doctor` can then read a
    /// person's decision without asking the app whether it is running.
    public var updateCheckOffFile: URL { stateDir.appendingPathComponent("update-check.off") }
    /// The newest release a person has been TOLD about — a different fact from
    /// what the last check found, and therefore its own file.
    ///
    /// `update-check` is overwritten by every check, including the ones nobody
    /// sees; this survives them, because it records what was said rather than
    /// what was read. Keeping it as a field in that record would mean every
    /// writer of the check had to carry the announcement forward, and
    /// `UpdateCommand.check` has no business knowing what has been announced.
    public var updateAnnouncedFile: URL { stateDir.appendingPathComponent("update-announced") }
    /// The release the once-a-day check has already tried to install by
    /// itself, `key=value`.
    ///
    /// A third fact about the same tag, and therefore a third file: what the
    /// last check FOUND, what a person has been TOLD, and what this Mac has
    /// TRIED. Written before the attempt starts, because the attempt replaces
    /// this app and there is nothing left here afterwards to write it.
    ///
    /// Still seeing that release on the next daily check means the attempt did
    /// not land, and one retry a day is one failure banner a day — the exact
    /// repetition `update-announced` exists to prevent for the other half of
    /// this feature.
    public var updateAttemptedFile: URL { stateDir.appendingPathComponent("update-attempted") }

    /// Returns whether the banner is now somebody else's to post. False is a
    /// banner that will never arrive, and the only caller that can still say
    /// something about it is the one that asked (`UpdateCLI`, R2 finding 8).
    @discardableResult
    public func enqueueNotification(_ request: NotificationRequest, now: Int) -> Bool {
        let json = JSONValue.object([
            ("v", .int(1)),
            ("ts", .int(now)),
            ("title", .string(request.title)),
            ("subtitle", .string(request.subtitle)),
            ("body", .string(request.body)),
            ("sound", .bool(request.sound)),
            ("actionable", .bool(request.actionable)),
        ])
        return append(json.serialized() + "\n", to: spoolFile)
    }

    /// Claims the whole spool atomically (rename), so a racing append lands
    /// in a fresh file instead of being lost mid-read. Entries older than
    /// `maxAge` are dropped: they queued while the app was not running, and
    /// a stale banner is worse than none.
    public func drainNotifications(now: Int, maxAge: Int = 120) -> [NotificationRequest] {
        let draining = spoolFile.appendingPathExtension("draining")
        // A sentinel already present is a drain that never finished: the
        // `defer` below only runs in-process, so a crash between the rename
        // and the sweep strands the file — and `moveItem` refuses an existing
        // destination, so one stranded sentinel was every future banner,
        // silently, forever. Its lines are requests that were never posted;
        // they are drained too, and `maxAge` — not the crash — decides which
        // of them still deserve a banner.
        var text = (try? String(contentsOf: draining, encoding: .utf8)) ?? ""
        // Unconditional, and keyed on the sentinel EXISTING rather than on
        // what it holds. Removing it only when it read as non-empty leaves
        // exactly the same immortality behind for the shapes that read as
        // empty: a crash between the rename of an empty spool and the sweep,
        // a directory or a dangling symlink wearing the name (`fileExists`
        // answers false for the latter and `moveItem` still refuses it a
        // destination), a permission that denies the read but not the unlink.
        // `try?` swallows the not-there case, which is the common one.
        try? FileManager.default.removeItem(at: draining)
        // Terminate the recovered half before the fresh one is appended. Every
        // record `enqueueNotification` writes ends in a newline, but the crash
        // that stranded this file can have landed mid-`write` — and a partial
        // record glued to the first whole one is a single line that parses as
        // neither, so BOTH are dropped. The spool is line-delimited; the
        // boundary between two reads of it has to be one too.
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if (try? FileManager.default.moveItem(at: spoolFile, to: draining)) != nil {
            // Armed the moment the sentinel exists, not after the read.
            // Registered below the read, its own failure path stranded the
            // file it was there to remove.
            defer { try? FileManager.default.removeItem(at: draining) }
            text += (try? String(contentsOf: draining, encoding: .utf8)) ?? ""
        }
        guard !text.isEmpty else { return [] }
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
            let request = NotificationRequest(
                title: object["title"] as? String ?? "",
                subtitle: object["subtitle"] as? String ?? "",
                body: object["body"] as? String ?? "",
                sound: object["sound"] as? Bool ?? true,
                actionable: object["actionable"] as? Bool ?? false)
            // The one construction in this codebase whose text a reader
            // cannot decide: these three fields come out of a file. A banner
            // with no informative text is accepted by `add` and never
            // presented, so posting it is a no-op that looks like a delivery
            // — and the whole 0.3.1 diagnosis is that nobody could tell the
            // difference. Dropped here, out loud, the way a stale one is:
            // whatever went wrong upstream leaves a line a person can find.
            guard request.hasInformativeText else {
                log("dropped a banner with no informative text (macOS never presents one): "
                        + "\(object["title"] as? String ?? "?")", now: now)
                continue
            }
            requests.append(request)
        }
        return requests
    }

    // MARK: the last release check
    //
    // Cached so that the surfaces which are not the one doing the asking —
    // `doctor`, a launcher row, the menu — never make a network call of their
    // own. One check a day answers all of them, and a stale answer is labelled
    // rather than refreshed behind someone's back.

    public struct UpdateRecord: Sendable, Equatable {
        public var checkedAt: Int
        /// The newest release tag, or empty when the check could not answer.
        public var latest: String
        /// Why it could not answer. Empty on success.
        public var error: String
        /// A `SIMMER_FAKE_*` was in force when this was written, so it is an
        /// answer about a seam and not about the repository. Recorded rather
        /// than suppressed: the suite needs the cache path to be reachable,
        /// and an unseamed reader needs to know not to believe this one.
        public var seamed: Bool
        /// The version of the binary that wrote this. Empty for a record
        /// written before the field existed.
        ///
        /// `latest` is a fact about the repository; the *verdict* is a
        /// comparison against whoever asked, and the two are cached in one
        /// file. Two minutes after 0.3.0 was installed, `doctor` said "simmer
        /// 0.3.0 is ahead of the newest release (0.2.0)" and the menu footer
        /// said "newest" — both computed from an answer 0.2.0 had recorded
        /// before the 0.3.0 tag existed. So the writer is recorded, and a
        /// reader that is not the writer treats the record as absent.
        public var installed: String

        public init(checkedAt: Int, latest: String, error: String,
                    seamed: Bool = false, installed: String = "") {
            self.checkedAt = checkedAt
            self.latest = latest
            self.error = error
            self.seamed = seamed
            self.installed = installed
        }

        /// A day, matching the app's tick. Older than this is reported with
        /// its age instead of being trusted as current.
        public static let maxAge = 24 * 60 * 60

        public func isFresh(now: Int) -> Bool {
            checkedAt > 0 && now - checkedAt < Self.maxAge
        }
    }

    public func writeUpdateRecord(_ record: UpdateRecord) {
        // key=value like the cap and the heartbeat, not JSON: nothing outside
        // simmer reads this file. `simmer update --json` is how a launcher or
        // a script asks, so the cache format stays an implementation detail
        // and not a fifth machine surface to keep append-only.
        _ = atomicWrite("""
        checked=\(record.checkedAt)
        latest=\(Claim.singleLine(record.latest, limit: 64))
        error=\(Claim.singleLine(record.error, limit: 200))
        seamed=\(record.seamed ? 1 : 0)
        installed=\(Claim.singleLine(record.installed, limit: 64))

        """, to: updateCheckFile)
    }

    /// The last check, **only if this binary is the one that made it.**
    ///
    /// The version is an argument rather than something read here because
    /// `Ledger` knows about files, not about who is running: `SimmerVersion`
    /// is the CLI's and the app's answer, and a seamed suite drives both. A
    /// record written by another version is nil — the same shape as no record
    /// at all, so every caller already handles it: `doctor` says "not checked
    /// yet", the menu footer says the same, and the app's daily check fires
    /// instead of skipping on a freshness stamp it did not write.
    public func readUpdateRecord(writtenBy version: String) -> UpdateRecord? {
        guard let text = try? String(contentsOf: updateCheckFile, encoding: .utf8) else { return nil }
        var checked = 0
        var latest = "", error = "", installed = ""
        var seamed = false
        // CRLF is one Character in Swift; see `readInstallInProgress`.
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "checked": checked = Int(value) ?? 0
            case "latest": latest = value
            case "error": error = value
            case "seamed": seamed = value == "1"
            case "installed": installed = value
            default: break
            }
        }
        guard checked > 0, installed == version else { return nil }
        return UpdateRecord(checkedAt: checked, latest: latest,
                            error: error, seamed: seamed, installed: installed)
    }

    /// The release tag the person has already been told about, or empty when
    /// nothing has been announced yet.
    public func readAnnouncedUpdate() -> String {
        readTag(from: updateAnnouncedFile)
    }

    public func writeAnnouncedUpdate(_ tag: String, now: Int) {
        _ = atomicWrite("""
        latest=\(Claim.singleLine(tag, limit: 64))
        announced_at=\(now)

        """, to: updateAnnouncedFile)
    }

    /// The release an unattended install has already been started for, or
    /// empty when none has.
    public func readAttemptedUpdate() -> String {
        readTag(from: updateAttemptedFile)
    }

    public func writeAttemptedUpdate(_ tag: String, now: Int) {
        _ = atomicWrite("""
        latest=\(Claim.singleLine(tag, limit: 64))
        attempted_at=\(now)

        """, to: updateAttemptedFile)
    }

    /// Forget it, so the next daily check tries again.
    ///
    /// Called from `setAutoUpdate(enabled: true)` rather than from each of its
    /// callers: a person turning unattended installs on is asking for an
    /// attempt, and a switch that silently stays stood down from a failure
    /// three weeks ago is not a switch. One place decides, because the CLI and
    /// the setup window are two callers and this is one rule.
    public func clearAttemptedUpdate() {
        try? FileManager.default.removeItem(at: updateAttemptedFile)
    }

    // MARK: the install that is under way
    //
    // A fourth fact about the same tag, and therefore a fourth file: what the
    // last check FOUND, what a person has been TOLD, what this Mac has TRIED
    // by itself — and now what is happening RIGHT NOW.
    //
    // It exists because `make install` takes a minute or two during which the
    // only visible thing simmer does is disappear from the menu bar. A banner
    // is the wrong sole channel for that: it can be suppressed by Focus, it
    // cannot be re-read after it fades, and nothing simmer can read says
    // whether it was ever shown. The menu is what a person opens when a banner
    // is missed, so the menu has to know.

    public struct InstallInProgress: Sendable, Equatable {
        /// What is being installed, as a person reads it (`0.3.2`, or
        /// `0.3.2 or newer` for the plan that installs a branch). Empty is a
        /// legitimate value and NOT the same as no record: it means an install
        /// is under way whose target this reader cannot name, and the row says
        /// "Installing simmer…" rather than dropping the fact.
        public var target: String
        public var startedAt: Int
        /// The version of the binary that started it. Read back by that
        /// version only, exactly as `update-check` is — and here it is what
        /// ends the state: the app that comes back IS the new version, so the
        /// record it left behind is invisible to it and the row is honest
        /// again without anything having to delete anything.
        public var installed: String

        public init(target: String, startedAt: Int, installed: String) {
            self.target = target
            self.startedAt = startedAt
            self.installed = installed
        }

        /// The backstop, not the mechanism. Three things end this state
        /// first: the child reports its own refusal or failure and clears it,
        /// the app sees the child exit and clears it, and coming back as a
        /// different version makes it unreadable. This closes the one hole
        /// those leave — a child killed outright while the app was quit — and
        /// is deliberately longer than a slow cold `make install`.
        public static let maxAge = 15 * 60
    }

    public var updateInProgressFile: URL { stateDir.appendingPathComponent("update-in-progress") }

    public func writeInstallInProgress(target: String, now: Int, installed: String) {
        _ = atomicWrite("""
        target=\(Claim.singleLine(target, limit: 64))
        started_at=\(now)
        installed=\(Claim.singleLine(installed, limit: 64))

        """, to: updateInProgressFile)
    }

    public func clearInstallInProgress() {
        try? FileManager.default.removeItem(at: updateInProgressFile)
    }

    /// The install under way, **only if this binary is the one that started
    /// it** and it started recently enough to still be plausible.
    ///
    /// A key that appears twice makes the record nil rather than picking one:
    /// two answers to one question is not an answer, and the safe direction
    /// here is to claim nothing — the row falls back to "Update available",
    /// which is true whether or not something is installing.
    public func readInstallInProgress(writtenBy version: String, now: Int) -> InstallInProgress? {
        guard let text = try? String(contentsOf: updateInProgressFile, encoding: .utf8)
        else { return nil }
        var fields: [String: String] = [:]
        // `whereSeparator: \.isNewline` and NOT `separator: "\n"`: Swift
        // grapheme-clusters CRLF into a SINGLE Character, which is not equal
        // to "\n", so splitting on the literal returns a CRLF file as one
        // unparseable line — and a reader that answers nil to a whole file is
        // a menu row that never appears.
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            guard fields[key] == nil else { return nil }
            fields[key] = String(parts[1])
        }
        guard let startedText = fields["started_at"], let startedAt = Int(startedText),
              startedAt > 0, let installed = fields["installed"], installed == version
        else { return nil }
        // Two-sided, and that is the whole of it: `now - startedAt < maxAge`
        // is also true of every timestamp in the future, so a `started_at` of
        // now + 86400 claimed to be installing forever — the immortal record
        // the refusal to default an ABSENT `started_at` was there to prevent,
        // left open on the other side (R2 finding 6).
        //
        // A future stamp reads as no record, which sends the row back to
        // `Update available` — true whether or not something is installing,
        // and the same direction every other unreadable shape here takes. It
        // does make the row clickable again, but that is the 15-minute
        // backstop's behaviour too, and both are backstops: the child clears
        // this record on every ending it reaches.
        guard (0..<InstallInProgress.maxAge).contains(now - startedAt) else { return nil }
        // `target` absent and `target=` empty are the same answer on purpose:
        // an install whose target this reader cannot name is still an install.
        return InstallInProgress(target: fields["target"] ?? "",
                                startedAt: startedAt, installed: installed)
    }

    /// `latest=` out of one of the two tag files. Both hold one fact about one
    /// tag in the same shape, so they are read by the same three lines.
    private func readTag(from file: URL) -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        // CRLF is one Character in Swift; see `readInstallInProgress`.
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0] == "latest" { return String(parts[1]) }
        }
        return ""
    }

    /// Whether the app may check on its own. A person's answer, not a seam —
    /// `SIMMER_NO_UPDATE_CHECK=1` is the environment's way to say the same
    /// thing for one process (SimmerEnvironment).
    public var backgroundUpdateChecksEnabled: Bool {
        !FileManager.default.fileExists(atPath: updateCheckOffFile.path)
    }

    public func setBackgroundUpdateChecks(enabled: Bool) {
        if enabled {
            try? FileManager.default.removeItem(at: updateCheckOffFile)
        } else {
            _ = atomicWrite("off\n", to: updateCheckOffFile)
        }
    }

    /// Present = the person has asked for the once-a-day check to *install*
    /// what it finds, without anybody clicking.
    ///
    /// The name spells the "on" where `update-check.off` spells the "off",
    /// because each file's absence has to be the safe default: checking is on
    /// unless turned off, installing is off unless turned on. One fact per
    /// file, and `doctor` reads both without asking the app anything.
    public var autoUpdateOnFile: URL { stateDir.appendingPathComponent("auto-update.on") }

    /// Whether an unattended install is permitted at all. **Off by default** —
    /// a tool whose whole promise is "nothing happens to your Mac that you did
    /// not ask for" does not replace its own binary on a default install.
    public var autoUpdateEnabled: Bool {
        FileManager.default.fileExists(atPath: autoUpdateOnFile.path)
    }

    public func setAutoUpdate(enabled: Bool) {
        if enabled {
            _ = atomicWrite("on\n", to: autoUpdateOnFile)
            // Asking for it is asking for an attempt: a release this Mac
            // stood down from weeks ago must not still be stood down from
            // when somebody turns the switch on again.
            clearAttemptedUpdate()
        } else {
            try? FileManager.default.removeItem(at: autoUpdateOnFile)
        }
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

        /// A pid alone vouches for whatever holds that pid NOW. `app.status`
        /// is never removed on exit, so after a crash or a reboot the number
        /// in it belongs to some other process — pid 1 among them — and every
        /// row underneath reported the dead app's last known verdict as
        /// current. The app rewrites this file every three seconds, so a
        /// minute is a long time in its own terms.
        public static let maxHeartbeatAge = 60

        public func heartbeatIsFresh(now: Int) -> Bool {
            now - ts <= Self.maxHeartbeatAge && ts > 0
        }
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
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  // Never rename something that was not a claim to begin with:
                  // giving junk a canonical name is how it stopped looking like
                  // junk to every check downstream of here.
                  Claim.looksLikeRecord(text) else { continue }
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

    // MARK: the invariant the claims directory is supposed to hold

    /// A claim file that no surface can act on, and what is wrong with it.
    ///
    /// Both defects that held this Mac awake indefinitely were shapes IN this
    /// directory — a leftover temp file that re-wrote itself every tick, and a
    /// record whose `id=` line renamed it out from under its own filename —
    /// and `doctor` reported ✅ over both, for ten simulated days. It checked
    /// that the directory was writable and never that what was in it made
    /// sense. This is the check that would have caught them from the outside,
    /// without a review.
    ///
    /// Two conditions, both of which mean a specific thing went wrong and
    /// neither of which has an innocent cause:
    ///
    /// - **not a claim at all** — no `format=` line. Crash debris, a stray
    ///   file, something's editor backup.
    /// - **unaddressable** — the recorded owner does not resolve to the name
    ///   the record is stored under, so `simmer down --owner <them>` looks
    ///   somewhere else and only `down --all` can end it.
    ///
    /// An owner stored at the truncation limit is deliberately NOT reported.
    /// `owner` is folded to `maxOwnerLength` while the id is fingerprinted
    /// over the whole original string, so such a record genuinely cannot
    /// reconstruct its own name — the same asymmetry `migrateClaimIds` had to
    /// reason about. Unverifiable is not damaged, and a row that goes red on a
    /// legitimate case teaches people to skim the report.
    public func unsoundClaimFiles() -> [(name: String, why: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: claimsDir, includingPropertiesForKeys: nil)) ?? []
        var found: [(name: String, why: String)] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            guard Claim.looksLikeRecord(text) else {
                found.append((name, "not a claim record — it has no format= line, and is ignored"))
                continue
            }
            let claim = Claim.parse(text, fallbackId: name)
            guard claim.owner.count < Claim.maxOwnerLength else { continue }
            let resolved = Claim.sanitizedId(claim.owner)
            if resolved != name {
                found.append((name, "its owner \"\(claim.owner)\" resolves to \(resolved), so only 'down --all' can end it"))
            }
        }
        return found
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
        // A symlink where a record belongs is removed, never followed and
        // never left in place. `replaceItemAt` against one fails outright, so
        // the record silently did not get written — the menu simply never said
        // "Installing…" — and following it instead would put simmer's state
        // wherever the link points, which is how a write under a bin directory
        // lands in a repository. `attributesOfItem` does not follow links, so
        // this asks about the path and not about its target.
        if let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type]
            as? FileAttributeType, type != .typeRegular {
            try? FileManager.default.removeItem(at: url)
        }
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
    ///
    /// Returns whether the line actually landed. It used to return void, and
    /// the diff that made this the SOLE channel for the starting banner made
    /// that a defect: an `O_NOFOLLOW` refusal or a full disk lost the banner
    /// and wrote nothing about it anywhere (R2 finding 8). A short write
    /// counts as a failure too — a half-written JSONL line is not a banner.
    private func append(_ text: String, to url: URL) -> Bool {
        // O_NOFOLLOW: these are append-only records inside a directory the
        // user owns, and a symlink dropped in their place would redirect every
        // future line somewhere else entirely.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let data = Array(text.utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return written == data.count
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
