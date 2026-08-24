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
    /// Set false to simulate a missing sudo rule.
    public var switchWritable: Bool = true
    public private(set) var switchWrites: [Bool] = []

    public init(disabled: Bool = false, battery: Int? = 80, onBattery: Bool = false,
                thermal: Bool = false, lockDelay: Int? = 0) {
        self.disabled = disabled
        self.battery = battery
        self.battPower = onBattery
        self.thermal = thermal
        self.lockDelay = lockDelay
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
