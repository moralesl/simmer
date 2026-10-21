// lid-assertion — the experiment behind one PLATFORM-FACTS row:
//
//   Does a ROOT-held IOPM assertion carrying `AppliesOnLidClose` keep an
//   Apple-silicon MacBook awake with the lid closed?
//
// PLATFORM-FACTS closed the UNPRIVILEGED half on 2026-08-22: the property
// returns kIOReturnNotPrivileged (0xe00002c1) for a non-root process. Whether
// a root process holding it actually holds the lid was never measured, and the
// answer decides whether simmer's mechanism could be an assertion that dies
// with its holder instead of a persistent `pmset -a disablesleep` flag.
//
// Nothing here writes to the machine: an assertion is released when the
// process exits, whichever way it exits. A hard ceiling on --hold bounds it.
//
//   ./lid-assertion --control --hold 150 --log control.log   # no property: expect sleep
//   sudo ./lid-assertion --hold 150 --log root.log           # the question
//   ./lid-assertion --analyse root.log                       # re-read a log later
//
// Protocol: start it, close the lid within ten seconds, leave it closed for at
// least a minute, open it. The summary says whether the machine slept while
// the lid was closed, read from two clocks: mach_absolute_time stops during
// sleep, mach_continuous_time does not, so their drift IS the seconds asleep.
import Foundation
import IOKit.pwr_mgt

let interval: TimeInterval = 5
let maxHold = 600

struct Options {
    var control = false
    var hold = 150
    var log = "lid-assertion.log"
    var analyse: String?
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: lid-assertion [--control] [--hold SECONDS] [--log FILE]
           lid-assertion --analyse FILE
      --control   take the SAME assertion WITHOUT AppliesOnLidClose (expect: sleeps)
      --hold N    seconds to hold it, default 150, ceiling \(maxHold)
      --log FILE  one line per 5 s sample; the summary is computed from it

    """.utf8))
    exit(64)
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--control": o.control = true
        case "--hold":
            guard let v = args.first, let n = Int(v), n > 0 else { usage() }
            args.removeFirst(); o.hold = min(n, maxHold)
        case "--log":
            guard let v = args.first else { usage() }
            args.removeFirst(); o.log = v
        case "--analyse":
            guard let v = args.first else { usage() }
            args.removeFirst(); o.analyse = v
        default: usage()
        }
    }
    return o
}

// Two clocks, both in seconds.
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func seconds(_ ticks: UInt64) -> Double {
    Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}
func absoluteNow() -> Double { seconds(mach_absolute_time()) }
func continuousNow() -> Double { seconds(mach_continuous_time()) }

// AppleClamshellState on IOPMrootDomain: Yes while the lid is closed.
func lidClosed() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    p.arguments = ["-r", "-k", "AppleClamshellState", "-d", "4"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "?" }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    if out.contains("\"AppleClamshellState\" = Yes") { return "closed" }
    if out.contains("\"AppleClamshellState\" = No") { return "open" }
    return "?"
}

struct Sample { var wall: Double; var abs: Double; var cont: Double; var lid: String }

func parseLog(_ path: String) -> [Sample] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        var wall = 0.0, abs = 0.0, cont = 0.0, lid = "?"
        for field in line.split(separator: " ") {
            let kv = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "wall": wall = Double(kv[1]) ?? 0
            case "abs": abs = Double(kv[1]) ?? 0
            case "cont": cont = Double(kv[1]) ?? 0
            case "lid": lid = kv[1]
            default: break
            }
        }
        return wall > 0 ? Sample(wall: wall, abs: abs, cont: cont, lid: lid) : nil
    }
}

func summarise(_ samples: [Sample], mode: String) {
    guard samples.count >= 2 else { print("summary: fewer than two samples — nothing to say"); return }
    let first = samples[0], last = samples[samples.count - 1]
    let wallSpan = last.wall - first.wall
    // Seconds the machine spent asleep: the continuous clock kept counting,
    // the absolute one did not.
    let asleep = (last.cont - first.cont) - (last.abs - first.abs)
    var maxGap = 0.0
    for i in 1..<samples.count { maxGap = max(maxGap, samples[i].wall - samples[i - 1].wall) }
    let closedSamples = samples.filter { $0.lid == "closed" }.count
    let closedSeconds = Double(closedSamples) * interval
    print("summary (\(mode)):")
    print(String(format: "  samples=%d  wall_span=%.0fs  lid_closed_observed≈%.0fs  max_gap_between_samples=%.1fs  asleep=%.1fs",
                 samples.count, wallSpan, closedSeconds, maxGap, asleep))
    if closedSeconds < 60 {
        print("  verdict: INCONCLUSIVE — the lid was closed for under a minute of samples")
    } else if asleep < interval {
        print("  verdict: STAYED AWAKE while the lid was closed")
    } else {
        print(String(format: "  verdict: SLEPT %.0fs while the lid was closed", asleep))
    }
}

let options = parse()

if let path = options.analyse {
    summarise(parseLog(path), mode: "analysis of \(path)")
    exit(0)
}

let mode = options.control ? "control: PreventSystemSleep WITHOUT AppliesOnLidClose"
                           : "PreventSystemSleep WITH AppliesOnLidClose"
print("lid-assertion · \(mode) · uid=\(getuid()) · hold=\(options.hold)s · log=\(options.log)")

var properties: [String: Any] = [
    kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventSystemSleep as String,
    kIOPMAssertionNameKey as String: "simmer spike: lid assertion (\(options.control ? "control" : "AppliesOnLidClose"))",
    kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
]
if !options.control {
    // Not in the public header: the key is the string PLATFORM-FACTS measured with.
    properties["AppliesOnLidClose"] = true
}

var assertion: IOPMAssertionID = 0
let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &assertion)
if result != kIOReturnSuccess {
    let hex = String(format: "0x%08x", UInt32(bitPattern: result))
    let name = result == kIOReturnNotPrivileged ? " (kIOReturnNotPrivileged)" : ""
    print("assertion REFUSED: \(hex)\(name)")
    exit(2)
}
print("assertion held (id \(assertion)). Close the lid now; open it again after a minute or more.")

// No signal handlers, on purpose: the kernel releases an IOPM assertion when
// its process ends, however it ends, so Ctrl-C needs no help — and neither
// IOPMAssertionRelease nor print is async-signal-safe, so a handler that
// called them would be the one thing here that could deadlock.

FileManager.default.createFile(atPath: options.log, contents: nil)
guard let handle = FileHandle(forWritingAtPath: options.log) else {
    print("cannot write \(options.log)"); exit(1)
}
let deadline = Date().addingTimeInterval(TimeInterval(options.hold))
let formatter = ISO8601DateFormatter()
while Date() < deadline {
    let line = String(format: "ts=%@ wall=%.3f abs=%.3f cont=%.3f lid=%@ uid=%d\n",
                      formatter.string(from: Date()), Date().timeIntervalSince1970,
                      absoluteNow(), continuousNow(), lidClosed(), getuid())
    handle.write(Data(line.utf8))
    FileHandle.standardOutput.write(Data(line.utf8))
    Thread.sleep(forTimeInterval: interval)
}
try? handle.close()
IOPMAssertionRelease(assertion)
print("released.")
summarise(parseLog(options.log), mode: mode)
