import Foundation

/// Drives the BUILT `simmer` binary under the seam variables — the acceptance
/// suite for any implementation of CONTRACTS.md, not just this one. Honours
/// SIMMER_BIN, so it can be pointed at another binary and must still go green.
///
/// Hermetic: its own state directory per instance, the sleep switch is a file,
/// battery/thermal/lock-delay are env, notifications are routed to none, and
/// the clock is SIMMER_FAKE_NOW. No sudo, no real power state touched.
struct Sim {
    /// A fixed epoch far from now, so nothing accidentally passes because the
    /// wall clock happens to be near a boundary. 2027-01-15 in Europe.
    static let epoch = 1_800_000_000

    let root: URL
    let pmsetFile: URL
    var stateDir: URL { root.appendingPathComponent("state/simmer") }
    var claimsDir: URL { stateDir.appendingPathComponent("claims") }

    /// The switch lives in its own directory so a test can make it
    /// UNMOVABLE — the state a Mac without the sudo rule is in, where
    /// `setDisableSleep` simply fails. Nothing could express that before,
    /// which is why `orphan_heal` was recorded for heals that never happened.
    var switchDir: URL { root.appendingPathComponent("switch") }

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simmer-accept-\(UUID().uuidString)")
        pmsetFile = root.appendingPathComponent("switch/pmset")
        try! FileManager.default.createDirectory(
            at: root.appendingPathComponent("switch"), withIntermediateDirectories: true)
        try! "0".write(to: pmsetFile, atomically: true, encoding: .utf8)
    }

    func tearDown() {
        // A test may have frozen the claims directory; a 0500 directory cannot
        // be emptied, so restore it before removing the tree. State first —
        // a frozen parent is what stops the child's permissions being changed.
        unfreezeState()
        unfreezeClaims()
        unfreezeSwitch()
        unfreezeEveryClaim()
        try? FileManager.default.removeItem(at: root)
    }

    /// ONE claim that cannot be removed, with the rest of the directory
    /// working normally — which is the only way to observe a partial release.
    /// Freezing the whole directory makes every claim fail together, and that
    /// is precisely the case `down --all` already handled.
    func freezeClaim(_ id: String) {
        try? FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: claimsDir.appendingPathComponent(id).path)
    }

    /// Immutable files survive `removeItem`, so tearDown clears the flag from
    /// everything rather than asking each test to remember which it set.
    private func unfreezeEveryClaim() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: claimsDir.path)) ?? [] {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: claimsDir.appendingPathComponent(name).path)
        }
    }

    /// `pmset -a disablesleep` failing is the ordinary shape of a Mac with no
    /// sudoers rule: the ledger moves, the switch does not. `write(atomically:)`
    /// stages beside the file, so a read-only parent is exactly that failure.
    func freezeSwitch() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: switchDir.path)
    }

    func unfreezeSwitch() {
        guard FileManager.default.fileExists(atPath: switchDir.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: switchDir.path)
    }

    /// Make the claims directory unwritable — the shape a wrong owner or a
    /// restrictive umask produces on a real machine. State is only ever *read*
    /// back elsewhere in this suite; this changes permissions, never records.
    func freezeClaims() {
        // The directory is created by the binary's first run, so create it
        // here when the test freezes it before ever invoking simmer —
        // chmod on a missing path silently does nothing.
        try? FileManager.default.createDirectory(at: claimsDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: claimsDir.path)
    }

    func unfreezeClaims() {
        guard FileManager.default.fileExists(atPath: claimsDir.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: claimsDir.path)
    }

    /// The same shape one level up, for the records that live beside `claims/`
    /// rather than inside it — the cap above all, whose lift is the other
    /// place a surface announced a removal it had not managed.
    func freezeState() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: stateDir.path)
    }

    func unfreezeState() {
        guard FileManager.default.fileExists(atPath: stateDir.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: stateDir.path)
    }

    var capUntil: Int? {
        guard let text = try? String(contentsOf: stateDir.appendingPathComponent("cap"),
                                     encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("until=") {
            return Int(line.dropFirst(6))
        }
        return nil
    }

    private final class BundleMarker {}

    static let binary: String = {
        if let bin = ProcessInfo.processInfo.environment["SIMMER_BIN"] { return bin }
        // The test bundle lives in the products directory; walk up from it.
        var dir = Bundle(for: BundleMarker.self).bundleURL
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("simmer").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("no simmer binary found — build it, or set SIMMER_BIN")
    }()

    struct Result {
        var out: String
        var err: String
        var code: Int32
        var lines: [String] { out.split(separator: "\n").map(String.init) }
        var combined: String { out + err }
    }

    /// Run the binary. `now` defaults to the fixed epoch; `env` overrides win.
    /// `launcher` and `cwd` exist for `runThroughPATH`; everything else execs
    /// the binary directly from the products directory.
    @discardableResult
    func run(_ args: [String], now: Int = Sim.epoch,
             env overrides: [String: String] = [:],
             launcher: String? = nil, cwd: URL? = nil) -> Result {
        var environment: [String: String] = [
            // A controlled PATH so the binary's own probes stay deterministic.
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.path,
            "TZ": "Europe/Berlin",
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "SIMMER_FAKE_PMSET": pmsetFile.path,
            "SIMMER_FAKE_BATTERY": "80:0",
            "SIMMER_FAKE_THERMAL": "0",
            "SIMMER_FAKE_LOCKDELAY": "0",
            "SIMMER_FAKE_NOW": String(now),
            "SIMMER_NOTIFY": "none",
        ]
        for (key, value) in overrides { environment[key] = value }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher ?? Sim.binary)
        process.arguments = args
        process.environment = environment
        if let cwd { process.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try! process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self),
                      code: process.terminationStatus)
    }

    /// Run the binary the way an installed copy is actually run: found on PATH,
    /// so `argv[0]` is the bare word "simmer" and the working directory is
    /// somewhere else entirely.
    ///
    /// Every other method here execs an absolute path, which is the one shape
    /// that made a cwd-relative `argv[0]` look correct. That is why a dead
    /// `bash=` path in every `render` action survived a green suite: the seam
    /// substitutes the machine, but nothing was substituting the *invocation*.
    @discardableResult
    func runThroughPATH(_ args: [String], now: Int = Sim.epoch,
                        env overrides: [String: String] = [:]) -> Result {
        let shim = root.appendingPathComponent("shim")
        try? FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        let link = shim.appendingPathComponent("simmer")
        if !FileManager.default.fileExists(atPath: link.path) {
            try? FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: URL(fileURLWithPath: Sim.binary))
        }
        var environment = overrides
        environment["PATH"] = "\(shim.path):/usr/bin:/bin:/usr/sbin:/sbin"
        // A working directory that deliberately does NOT hold the binary:
        // resolving argv[0] against it must not produce a real file by luck.
        return run(["simmer"] + args, now: now, env: environment,
                   launcher: "/usr/bin/env", cwd: root)
    }

    // MARK: state inspection — reads only; all mutations go through the binary

    var switchValue: String {
        (try? String(contentsOf: pmsetFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    func setSwitch(_ on: Bool) {
        try! (on ? "1" : "0").write(to: pmsetFile, atomically: true, encoding: .utf8)
    }

    var claimCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: claimsDir.path)) ?? []).count
    }

    func claimField(_ id: String, _ key: String) -> String? {
        guard let text = try? String(contentsOf: claimsDir.appendingPathComponent(id),
                                     encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("\(key)=") {
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }

    func hasClaim(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: claimsDir.appendingPathComponent(id).path)
    }

    /// Parsed events.jsonl — the transition record.
    func events() -> [[String: Any]] {
        guard let text = try? String(contentsOf: stateDir.appendingPathComponent("events.jsonl"),
                                     encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func events(named name: String) -> [[String: Any]] {
        events().filter { $0["event"] as? String == name }
    }

    func json(_ result: Result) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any]) ?? [:]
    }

    /// The one fixture in this suite that WRITES state, and the reason is that
    /// no current binary can produce what it writes: a claim file under a name
    /// only a previous release would have chosen.
    ///
    /// Everything else here drives the public surface precisely so a fixture
    /// cannot drift from the implementation. A migration has no public surface
    /// to drive — the input is the state an older version left on disk — so
    /// the alternative is not a cleaner test, it is no test, which is how the
    /// orphaned-claim defect shipped in the first place.
    ///
    /// The record shape is 0.1.0's, taken from `Claim.serialized()` at that
    /// tag; keep it frozen even if the current writer gains fields, because
    /// what upgrades in the field is the old shape and not today's.
    func plantLegacyClaim(named name: String, owner: String,
                          until: Int, reason: String = "legacy work") {
        try? FileManager.default.createDirectory(at: claimsDir, withIntermediateDirectories: true)
        let record = """
            format=2
            id=\(name)
            owner=\(owner)
            until=\(until)
            started=\(Sim.epoch - 3600)
            reason=\(reason)
            min_battery=20

            """
        try! record.write(to: claimsDir.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
    }
}
