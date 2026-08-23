import Foundation
import Testing

/// Notification routing, tested hermetically: SIMMER_NOTIFIER_APP points at a
/// fake bundle whose `simmer` is a shell script appending its arguments to a
/// log. What lands there is exactly what the CLI would have handed the real
/// bundle — identity, once-ness and silence are all assertable without a
/// single real banner. (The seam rule again: this posting path is a side
/// effect outside the process, so it too must be substitutable.)
extension Sim {
    /// Installs the capture bundle; returns the log it writes and the env to run with.
    func installFakeNotifier() -> (log: URL, env: [String: String]) {
        let app = root.appendingPathComponent("FakeSimmer.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try! FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("notify.log")
        let script = "#!/bin/sh\necho \"$@\" >> \"\(log.path)\"\n"
        let binary = macos.appendingPathComponent("simmer")
        try! script.write(to: binary, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: binary.path)
        return (log, ["SIMMER_NOTIFY": "bundle", "SIMMER_NOTIFIER_APP": app.path])
    }

    func notifyLines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

@Suite struct NotificationRoutingTests {
    @Test func aClaimPostsExactlyOneBannerThroughTheBundle() {
        let sim = Sim(); defer { sim.tearDown() }
        let (log, env) = sim.installFakeNotifier()
        sim.run(["15m", "--owner", "terminal"], env: env)
        let lines = sim.notifyLines(log)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("notify-post") == true)
        #expect(lines.first?.contains("Simmering until") == true)
    }

    @Test func aRepeatClickInsideTheSameMinuteIsNotNews() {
        let sim = Sim(); defer { sim.tearDown() }
        let (log, env) = sim.installFakeNotifier()
        // The double-banner from the first live install: two menu clicks,
        // seconds apart, both formatting the same HH:MM.
        sim.run(["15m", "--owner", "menubar"], env: env)
        sim.run(["15m", "--owner", "menubar"], now: Sim.epoch + 7, env: env)
        #expect(sim.notifyLines(log).count == 1)
        // Moving the deadline across a minute IS news again.
        sim.run(["15m", "--owner", "menubar"], now: Sim.epoch + 120, env: env)
        #expect(sim.notifyLines(log).count == 2)
    }

    @Test func aClaimInsideALongerOneIsSilent() {
        let sim = Sim(); defer { sim.tearDown() }
        let (log, env) = sim.installFakeNotifier()
        sim.run(["2h", "--owner", "terminal"], env: env)
        sim.run(["30m", "--owner", "agent"], env: env)
        #expect(sim.notifyLines(log).count == 1) // only the first changed the promise
    }

    @Test func theDeadlineWarningReachesTheBundleOnce() {
        let sim = Sim(); defer { sim.tearDown() }
        let (log, env) = sim.installFakeNotifier()
        sim.run(["30m", "--owner", "terminal"], env: env)
        sim.run(["guard"], now: Sim.epoch + 1600, env: env)
        sim.run(["guard"], now: Sim.epoch + 1700, env: env)
        let warnings = sim.notifyLines(log).filter { $0.contains("left") }
        #expect(warnings.count == 1)
    }

    @Test func releasingSaysSleepAllowedAgain() {
        let sim = Sim(); defer { sim.tearDown() }
        let (log, env) = sim.installFakeNotifier()
        sim.run(["15m", "--owner", "terminal"], env: env)
        sim.run(["down", "--owner", "terminal"], env: env)
        #expect(sim.notifyLines(log).last?.contains("Sleep allowed again") == true)
    }

    @Test func noneMeansSilenceAndMissingBundleMeansSilence() {
        let sim = Sim(); defer { sim.tearDown() }
        let (log, env) = sim.installFakeNotifier()
        var muted = env
        muted["SIMMER_NOTIFY"] = "none"
        sim.run(["15m", "--owner", "terminal"], env: muted)
        #expect(sim.notifyLines(log).isEmpty)
        // No bundle installed: dropped, never re-routed to a borrowed identity.
        sim.run(["1h", "--owner", "terminal"],
                env: ["SIMMER_NOTIFY": "bundle",
                      "SIMMER_NOTIFIER_APP": sim.root.appendingPathComponent("NoSuch.app").path])
        #expect(sim.notifyLines(log).isEmpty)
    }
}
