import Foundation

/// The three power reads and the one power write, plus thermal and the
/// lock-screen grace — everything the machine can tell simmer or simmer can do
/// to the machine. Tests substitute this wholesale; the CLI and the app get a
/// SeamPowerSystem that honours SIMMER_FAKE_* per facet.
public protocol PowerSystem: Sendable {
    /// Is `pmset -a disablesleep 1` currently in force?
    func sleepDisabled() -> Bool
    /// Flip the switch. Returns false when it could not (no sudo rule, say).
    func setDisableSleep(_ on: Bool) -> Bool
    /// 0–100, nil when unreadable (a Mac with no battery).
    func batteryPercent() -> Int?
    func onBattery() -> Bool
    /// macOS's own estimate of seconds until the battery is empty, or nil when
    /// it has none — on AC, or while it is still calibrating after a wake.
    ///
    /// Deliberately the system's number and not one simmer computes: it is the
    /// same estimate the menu bar shows, it already accounts for the current
    /// load, and inventing a second discharge model would be guesswork wearing
    /// a number's clothes.
    func batterySecondsRemaining() -> Int?
    /// Any thermal warning level counts — heat ends everything (CONTRACTS.md).
    func thermalPressure() -> Bool
    /// Seconds the screen stays unlocked after the lid closes; nil = unreadable.
    func lockDelaySeconds() -> Int?
}

/// A fully in-memory power system for unit tests. Reference semantics so a
/// test can flip state mid-scenario and settle()/tick() observe it.
public final class TestPowerSystem: PowerSystem, @unchecked Sendable {
    public var disabled: Bool
    public var battery: Int?
    public var battPower: Bool
    public var thermal: Bool
    public var lockDelay: Int?
    /// nil = macOS has no estimate, which is a real and common state.
    public var secondsRemaining: Int?
    /// Set false to simulate a missing sudo rule.
    public var switchWritable: Bool = true
    public private(set) var switchWrites: [Bool] = []

    public init(disabled: Bool = false, battery: Int? = 80, onBattery: Bool = false,
                thermal: Bool = false, lockDelay: Int? = 0, secondsRemaining: Int? = nil) {
        self.disabled = disabled
        self.battery = battery
        self.battPower = onBattery
        self.thermal = thermal
        self.lockDelay = lockDelay
        self.secondsRemaining = secondsRemaining
    }

    public func sleepDisabled() -> Bool { disabled }
    public func setDisableSleep(_ on: Bool) -> Bool {
        switchWrites.append(on)
        guard switchWritable else { return false }
        disabled = on
        return true
    }
    public func batteryPercent() -> Int? { battery }
    public func onBattery() -> Bool { battPower }
    public func batterySecondsRemaining() -> Int? { secondsRemaining }
    public func thermalPressure() -> Bool { thermal }
    public func lockDelaySeconds() -> Int? { lockDelay }
}

/// The production power system: each facet independently honours its
/// SIMMER_FAKE_* variable and falls back to the real probe, exactly like the
/// contract's seam table — a test may fake the battery while leaving the
/// switch real, or vice versa.
public struct SeamPowerSystem: PowerSystem {
    let env: [String: String]
    let allowInteractiveSudo: Bool
    private static let pmset = "/usr/bin/pmset"

    public init(env: [String: String], allowInteractiveSudo: Bool) {
        self.env = env
        self.allowInteractiveSudo = allowInteractiveSudo
    }

    public func sleepDisabled() -> Bool {
        if let file = env["SIMMER_FAKE_PMSET"] {
            let value = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "0"
            return value.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        let out = Shell.run(Self.pmset, ["-g", "live"]).stdout
        return out.range(of: #"SleepDisabled\s*1"#, options: .regularExpression) != nil
    }

    public func setDisableSleep(_ on: Bool) -> Bool {
        if let file = env["SIMMER_FAKE_PMSET"] {
            return (try? (on ? "1" : "0").write(toFile: file, atomically: true, encoding: .utf8)) != nil
        }
        let value = on ? "1" : "0"
        // The guard runs unattended and must never ask for a password: -n or
        // nothing. Interactively a prompt is fine, once.
        if Shell.run("/usr/bin/sudo", ["-n", Self.pmset, "-a", "disablesleep", value]).status == 0 {
            return true
        }
        guard allowInteractiveSudo else { return false }
        FileHandle.standardError.write(Data(
            "simmer: needs sudo once (to stop being asked: simmer doctor)\n".utf8))
        return Shell.runInheritingIO("/usr/bin/sudo", [Self.pmset, "-a", "disablesleep", value]) == 0
    }

    public func batteryPercent() -> Int? {
        if let fake = env["SIMMER_FAKE_BATTERY"] {
            return Int(fake.split(separator: ":").first ?? "")
        }
        let out = Shell.run(Self.pmset, ["-g", "batt"]).stdout
        guard let range = out.range(of: #"[0-9]+%"#, options: .regularExpression) else { return nil }
        return Int(out[range].dropLast())
    }

    public func onBattery() -> Bool {
        if let fake = env["SIMMER_FAKE_BATTERY"] {
            return fake.split(separator: ":").last.map(String.init) == "1"
        }
        return Shell.run(Self.pmset, ["-g", "batt"]).stdout.contains("'Battery Power'")
    }

    public func batterySecondsRemaining() -> Int? {
        if let fake = env["SIMMER_FAKE_BATTERY_TIME"] {
            // "none" is the calibrating state, which has to be expressible:
            // it is what pmset reports for minutes after every wake.
            return fake == "none" ? nil : Int(fake)
        }
        // A faked battery has no real estimate to offer. Without this, a test
        // that fakes "on battery" and says nothing about the time fell through
        // to the REAL pmset — so the facet was half seamed, and the half that
        // leaked was invisible on any Mac that happened to be plugged in.
        //
        // Found by running the suite unplugged: a test asserting `fits == true`
        // at a faked 21% started failing because it had picked up this
        // machine's actual 8:46 remaining. On AC it would have passed forever.
        guard env["SIMMER_FAKE_BATTERY"] == nil else { return nil }
        // Charging, pmset still prints a "0:00 remaining" — about the charge,
        // not the discharge. Only a discharging battery has an estimate worth
        // reading, so the AC case answers nil before any parsing happens.
        guard onBattery() else { return nil }
        return Self.parseRemaining(Shell.run(Self.pmset, ["-g", "batt"]).stdout)
    }

    /// `85%; discharging; 3:42 remaining` → 13320. `(no estimate)` → nil.
    /// Split out so it can be tested against real pmset lines without a Mac
    /// that happens to be unplugged at the time.
    static func parseRemaining(_ out: String) -> Int? {
        guard let range = out.range(of: #"[0-9]+:[0-9]{2} remaining"#,
                                    options: .regularExpression) else { return nil }
        let parts = out[range].split(separator: " ")[0].split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let seconds = h * 3600 + m * 60
        // pmset prints 0:00 both for "no idea yet" and for "about to die"; the
        // second is not something to bet unattended work on either way.
        return seconds > 0 ? seconds : nil
    }

    public func thermalPressure() -> Bool {
        if let fake = env["SIMMER_FAKE_THERMAL"] {
            return (Int(fake) ?? 0) > 0
        }
        let out = Shell.run(Self.pmset, ["-g", "therm"]).stdout
        return out.range(of: #"(?i)thermal warning level\s*[=:]\s*[1-9]"#,
                         options: .regularExpression) != nil
    }

    public func lockDelaySeconds() -> Int? {
        if let fake = env["SIMMER_FAKE_LOCKDELAY"] {
            return Int(fake)
        }
        // sysadminctl reports to stderr; "immediate"/"off" carry no number.
        let result = Shell.run("/usr/sbin/sysadminctl", ["-screenLock", "status"])
        let out = result.stdout + result.stderr
        if out.contains("immediate") { return 0 }
        guard let range = out.range(of: #"[0-9]+ second"#, options: .regularExpression) else { return nil }
        return Int(out[range].split(separator: " ").first ?? "")
    }
}

/// Small synchronous process runner for the real probes. Lives in SimmerCore
/// because the seam does — Foundation only, no AppKit.
public enum Shell {
    public static func run(_ path: String, _ args: [String]) -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ("", "\(error)", 127) }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self),
                process.terminationStatus)
    }

    /// For interactive sudo: the prompt must reach the user's tty.
    public static func runInheritingIO(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        do { try process.run() } catch { return 127 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
