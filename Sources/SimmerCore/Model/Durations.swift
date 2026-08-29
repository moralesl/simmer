import Foundation

/// Durations: 90 · 90m · 2h · 1h30m · 45min · 30s · 2H · 2h15 · 1d.
/// Bare number = minutes; a trailing bare number after a unit = minutes.
/// Days exist because overnight is a first-class case — `--require-ac` was
/// added for exactly it — and "1d" is how a person spells it.
public enum Durations {
    /// The longest a claim may be asked for. Not a policy about how long
    /// anyone should hold the machine — the cap and the battery floor are
    /// that — but the line past which a number stops being a duration
    /// somebody meant.
    ///
    /// It exists because the arithmetic below is Swift's, which TRAPS on
    /// overflow rather than wrapping: `simmer 106751991167300d` killed the
    /// process with SIGTRAP and exit 133, against a contract whose exit-code
    /// table is published as complete, from ten entry points, in release
    /// builds. And below the trap there was no bound at all — `simmer
    /// 153722867280912930s` was accepted at exit 0 and recorded a deadline
    /// four billion years out.
    ///
    /// A year is far past any real use and still nowhere near the range where
    /// `now + seconds` can overflow, so one constant closes both.
    public static let maxSeconds = 365 * 86_400

    public static func parse(_ text: String) -> Int? {
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }

        /// Every multiply and add in one place, and neither may trap.
        func add(_ total: Int, _ n: Int, times unit: Int) -> Int? {
            let (scaled, scaleOverflowed) = n.multipliedReportingOverflow(by: unit)
            guard !scaleOverflowed else { return nil }
            let (sum, sumOverflowed) = total.addingReportingOverflow(scaled)
            guard !sumOverflowed, sum <= maxSeconds else { return nil }
            return sum
        }

        if t.allSatisfy(\.isNumber) {
            guard let n = Int(t), n > 0 else { return nil }
            return add(0, n, times: 60)
        }
        var total = 0
        var matchedUnit = false
        var i = t.startIndex
        while i < t.endIndex {
            var j = i
            while j < t.endIndex, t[j].isNumber { j = t.index(after: j) }
            // `Int(…)` is nil for a run of digits too long to be an Int, which
            // is a refusal rather than a trap and so needs no separate case.
            guard j > i, let n = Int(t[i..<j]) else { return nil }
            var k = j
            while k < t.endIndex, t[k].isLetter { k = t.index(after: k) }
            let unit = String(t[j..<k])
            let scale: Int
            if unit.isEmpty {
                // "2h15" — a trailing bare number means minutes, and only at the end.
                guard k == t.endIndex else { return nil }
                scale = 60
            } else {
                switch unit {
                case "d", "day", "days": scale = 86_400
                case "h", "hour", "hours": scale = 3600
                case "m", "min", "minute", "minutes": scale = 60
                case "s", "sec", "second", "seconds": scale = 1
                default: return nil
                }
                matchedUnit = true
            }
            guard let next = add(total, n, times: scale) else { return nil }
            total = next
            i = k
        }
        return (matchedUnit && total > 0) ? total : nil
    }

    /// HH:MM → epoch. If the time is already behind us, tomorrow is meant.
    /// Computed from `now` (fake-aware); the wall-clock date it lands on uses
    /// the real local timezone, which is the absolute-formatting half of the
    /// SIMMER_FAKE_NOW contract.
    public static func parseUntil(_ text: String, now: Int) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (1...2).contains(parts[0].count), parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let nowDate = Date(timeIntervalSince1970: TimeInterval(now))
        var components = calendar.dateComponents([.year, .month, .day], from: nowDate)
        components.hour = h
        components.minute = m
        components.second = 0
        guard let target = calendar.date(from: components) else { return nil }
        // Tomorrow is the same wall clock on the next calendar day, which is
        // not always 86,400 seconds later. Adding the constant meant that on
        // the evening the clocks go forward, `--until 23:00` landed at 00:00
        // the day AFTER tomorrow; on the evening they go back, it landed at
        // 22:00 — an hour less awake time than was asked for, silently, which
        // CONTRACTS.md calls the one failure this tool exists to prevent.
        //
        // Twice a year, on the two nights of the year when an overnight run is
        // least likely to be watched.
        if Int(target.timeIntervalSince1970) <= now {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: target)
            else { return nil }
            return Int(tomorrow.timeIntervalSince1970)
        }
        return Int(target.timeIntervalSince1970)
    }

    /// "1 h 20 min" · "45 min" · "under 1 min"
    public static func human(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min" }
        return "under 1 min"
    }

    /// "1h20" · "42m" — for the menu bar.
    public static func short(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return String(format: "%dh%02d", h, m) }
        return "\(m)m"
    }
}

/// Absolute formatting. Deliberately NOT behind SIMMER_FAKE_NOW: the fake
/// moves relative arithmetic, not what a given epoch reads as on this Mac.
public enum Formats {
    public static func hhmm(_ epoch: Int) -> String {
        formatted(epoch, "HH:mm")
    }

    public static func logStamp(_ epoch: Int) -> String {
        formatted(epoch, "yyyy-MM-dd HH:mm:ss")
    }

    /// "23:00" · "08:00 tomorrow" · "08:00 on Wed 20 Jan".
    ///
    /// A deadline on another calendar day is the one case where a bare HH:mm
    /// misleads: `simmer --until 08:00` typed at 09:00 means tomorrow, and
    /// "until 08:00" reads as a time already gone. The day comparison is
    /// relative arithmetic, so it reads the passed-in (fake-aware) `now`.
    public static func hhmmDated(_ epoch: Int, now: Int) -> String {
        let time = hhmm(epoch)
        switch calendarDaysApart(from: now, to: epoch) {
        case ..<1: return time
        case 1: return "\(time) tomorrow"
        default: return "\(time) on \(formatted(epoch, "EEE d MMM"))"
        }
    }

    private static func calendarDaysApart(from: Int, to: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(from)))
        let end = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(to)))
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    private static func formatted(_ epoch: Int, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
